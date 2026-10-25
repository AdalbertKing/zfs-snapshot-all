#!/bin/bash
# release/publish.sh -- publish one dev revision into the release repository.
#
#   release/publish.sh <dev-rev> <release-checkout> [--push]
#
# Exports exactly the files release/MANIFEST names AT <dev-rev> (git archive -- never the
# working tree), scrubs them with release/scrub.sed (lab and customer addresses -> RFC 5737
# documentation addresses), puts release/README.md in as README.md, writes RELEASE-OF (the full
# dev SHA), and commits into <release-checkout> on top of its history. An unchanged tree makes
# no commit. --push pushes with a plain `git push` -- never --force: hosts follow the release
# repo with `merge --ff-only`, so its history only ever grows.
#
# Design: docs/project/DESIGN-REPO-WYDAN-2026-10-24.md.
set -euo pipefail

die() { echo "publish: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: release/publish.sh <dev-rev> <release-checkout> [--push]"
push=0; [ "${3:-}" = --push ] && push=1

dev=$(cd "$(dirname "$0")/.." && pwd)
rev=$(git -C "$dev" rev-parse --verify "$1^{commit}") || die "'$1' is not a commit of $dev"
dst="$2"
[ -d "$dst/.git" ] || die "$dst is not a git checkout (clone the release repo first)"
[ -z "$(git -C "$dst" status --porcelain)" ] || die "$dst has uncommitted changes -- refusing to mix them into a release"

# --- the file list, from the MANIFEST of THAT revision -------------------------------------
manifest=$(git -C "$dev" show "$rev:release/MANIFEST") || die "release/MANIFEST is not in $rev"
files=$(printf '%s\n' "$manifest" | awk '
    /^[ \t]*(#|$)/ { next }
    { sub(/[ \t]+$/, ""); print }' | while IFS= read -r line; do
        case "$line" in
            '!'*) printf -- '-%s\n' "${line#!}" ;;
            */)   git -C "$dev" ls-tree -r --name-only "$rev" -- "$line" | sed 's/^/+/' ;;
            *)    git -C "$dev" cat-file -e "$rev:$line" 2>/dev/null || { echo "!missing $line"; continue; }
                  printf '+%s\n' "$line" ;;
        esac
    done)
missing=$(printf '%s\n' "$files" | sed -n 's/^!missing //p')
[ -z "$missing" ] || die "MANIFEST names files that are not in $rev: $missing"
list=$(printf '%s\n' "$files" | awk '
    /^\+/ { keep[substr($0, 2)] = 1 }
    /^-/  { drop[substr($0, 2)] = 1 }
    END   { for (f in keep) { ok = 1; for (d in drop) if (f == d || index(f, d "/") == 1) ok = 0; if (ok) print f } }' | sort)
[ -n "$list" ] || die "the MANIFEST resolves to no files"

# --- export, scrub, README, RELEASE-OF -----------------------------------------------------
tmp=$(mktemp -d); all=$(mktemp -d); trap 'rm -rf "$tmp" "$all"' EXIT
# The whole revision once (modes kept), then only the listed paths are taken from it.
git -C "$dev" archive --format=tar "$rev" | tar -x -C "$all"
while IFS= read -r f; do
    mkdir -p "$tmp/$(dirname "$f")"
    cp -p "$all/$f" "$tmp/$f"
done <<< "$list"
git -C "$dev" show "$rev:release/scrub.sed" > "$tmp/.scrub.sed"
while IFS= read -r f; do
    [ -f "$tmp/$f" ] || continue
    grep -Iq . "$tmp/$f" 2>/dev/null || continue          # binary: left alone
    sed -i -f "$tmp/.scrub.sed" "$tmp/$f"
done <<< "$list"
rm -f "$tmp/.scrub.sed"
git -C "$dev" show "$rev:release/README.md" > "$tmp/README.md"
subject=$(git -C "$dev" log -1 --format=%s "$rev")
printf '%s\n' "$rev" > "$tmp/RELEASE-OF"

# Nothing the scrub is meant to remove may survive it (the private-range globs in the code,
# 10.*|192.168.*, are not addresses and do not match these).
left=$(grep -rIliE '192\.168\.(28|11)\.[0-9]|10\.98\.0\.[0-9]|metropolis' "$tmp" || true)
[ -z "$left" ] || die "after the scrub these still carry lab/customer addresses or names: $left"

# --- into the release checkout -------------------------------------------------------------
find "$dst" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$tmp/." "$dst/"
git -C "$dst" add -A
# Modes come from the dev TREE, not from the filesystem: on a checkout that does not track
# the executable bit (Windows, core.filemode=false) every script landed 100644, and cron
# calls them directly (measured on the first 1.0 publish, 2026-10-25: zfs-backup.sh,
# deploy.sh, gen-cron.sh 100644 in the release index).
while IFS=$'\t' read -r mode path; do
    case "$mode" in
        100755) git -C "$dst" update-index --chmod=+x -- "$path" ;;
        100644) git -C "$dst" update-index --chmod=-x -- "$path" ;;
    esac
done < <(git -C "$dev" ls-tree -r "$rev" | awk -F'\t' 'NR == FNR { want[$0] = 1; next }
             ($2 in want) { split($1, a, " "); print a[1] "\t" $2 }' <(printf '%s\n' "$list") -)
if git -C "$dst" diff --cached --quiet; then
    echo "publish: $dst already holds $rev's package -- no commit"
else
    git -C "$dst" commit -q -m "release of ${rev:0:12}: $subject" -m "Development revision: $rev"
    echo "publish: committed release of ${rev:0:12} in $dst ($(git -C "$dst" rev-parse --short HEAD))"
fi
if [ "$push" -eq 1 ]; then
    git -C "$dst" push origin HEAD:main
fi
