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
[ $# -ge 2 ] || die "usage: release/publish.sh <dev-rev> <release-checkout> [--push] [--accept-open-review=REV-...,REV-...]"
push=0; accept_open=""
for a in "${@:3}"; do
    case "$a" in
        --push) push=1 ;;
        --accept-open-review=*) accept_open="${a#*=}" ;;
        *) die "unknown option '$a'" ;;
    esac
done

# REV-20261107-192: the customer and site names the name gate refuses are not in this public
# repository; they come from a private list named by $ZFS_NAME_DENYLIST. A pushed release
# reaches the public release repository, so it is never published with that check missing.
if [ "$push" -eq 1 ]; then
    [ -n "${ZFS_NAME_DENYLIST:-}" ] && [ -f "$ZFS_NAME_DENYLIST" ] && [ -r "$ZFS_NAME_DENYLIST" ] \
        && grep -qvE '^[[:space:]]*(#|$)' -- "$ZFS_NAME_DENYLIST" \
        || die "--push needs the private name list: set ZFS_NAME_DENYLIST to a readable file with at least one entry (see release/name-gate.sh)"
fi

dev=$(cd "$(dirname "$0")/.." && pwd)
rev=$(git -C "$dev" rev-parse --verify "$1^{commit}") || die "'$1' is not a commit of $dev"

# --- the Reviewer's gate, before anything is written (PROTOCOL V3.13) ----------------------
# Only a pushed release reaches hosts; a local commit into a throw-away checkout (CI, the
# release suite) is not a publication and is not gated.
accepted=""
if [ "$push" -eq 1 ]; then
    ledger=$(git -C "$dev" show "$rev:docs/internal/reviews/REVIEW_LEDGER.md") \
        || die "no REVIEW_LEDGER.md in $rev -- cannot check the Reviewer's gate"
    accepted=$(printf '%s\n' "$ledger" | bash "$dev/release/review-gate.sh" "$accept_open") \
        || die "the Reviewer's gate refused $rev (see above)"
fi
dst="$2"
[ -d "$dst/.git" ] || die "$dst is not a git checkout (clone the release repo first)"
[ -z "$(git -C "$dst" status --porcelain)" ] || die "$dst has uncommitted changes -- refusing to mix them into a release"

# --- the file list, from the MANIFEST of THAT revision -------------------------------------
# release/package-list.sh: the same resolution coverage-gate.sh compares between revisions.
list=$(bash "$dev/release/package-list.sh" "$dev" "$rev") || die "cannot resolve the package of $rev (see above)"

# --- every behaviour change was submitted (REV-20261112-195 F4) ---------------------------
# review-gate.sh judges the ledger's rows; a change nobody submitted has none and passed by
# absence (1.0.19). coverage-gate.sh compares the run-time package of the PUBLISHED release with
# this one. The published revision is read from the release repo's remote, never from the
# checkout's working RELEASE-OF: a run without --push writes and commits the candidate there, so
# a later --push would compare the candidate with itself (round 2, F4a). Every local commit not
# yet pushed lies between the two, so all of them are checked.
if [ "$push" -eq 1 ]; then
    git -C "$dst" fetch -q origin 2>/dev/null         || die "cannot fetch $dst's origin -- what hosts received last is unknown, so review coverage cannot be checked"
    pub=$(git -C "$dst" rev-parse -q --verify "refs/remotes/origin/main^{commit}")         || die "$dst's origin has no main -- what hosts received last is unknown, so review coverage cannot be checked"
    prev=$(git -C "$dst" show "$pub:RELEASE-OF" 2>/dev/null | head -n 1)
    [ -n "$prev" ] || die "the published release (origin/main of $dst) has no RELEASE-OF -- cannot tell what hosts received last, so cannot check review coverage"
    cov_rc=0
    printf '%s
' "$ledger" | bash "$dev/release/coverage-gate.sh" "$dev" "$prev" "$rev" || cov_rc=$?
    [ "$cov_rc" -eq 0 ] || die "the review-coverage gate refused $rev (rc $cov_rc, see above)"
fi

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
# A whitelist .gitignore, the same idea as the dev repo's: a host keeps its own files in the
# checkout (jobs.<host>.conf, backups of it, cron dumps), and without this every one of them is
# "untracked" -- update-control then refuses the next update as "not clean" (measured on the
# first switch to the release repo, 2026-10-25: pve2, pve9b, pve10, pve0, pve1 refused).
{
    printf '%s\n' '# Generated by release/publish.sh: only the published files are tracked.' '*' '!*/' \
        '!.gitignore' '!README.md' '!RELEASE-OF'
    printf '%s\n' "$list" | sed 's|^|!/|'
} > "$tmp/.gitignore"

# Nothing the scrub is meant to remove may survive it (the private-range globs in the code,
# 10.*|192.168.*, are not addresses and do not match these). The list and the Polish-letter
# fold live in release/name-gate.sh, shared with test/release.
# rc 2 (bad name list, grep failure) is not a pass: REV-20261107-192.
gate_rc=0; left=$(bash "$dev/release/name-gate.sh" "$tmp") || gate_rc=$?
[ "$gate_rc" -le 1 ] || die "the name gate could not run (rc $gate_rc, reason above) -- nothing published"
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
    git -C "$dst" commit -q -m "release of ${rev:0:12}: $subject" -m "Development revision: $rev" \
        ${accepted:+-m "$accepted"}
    echo "publish: committed release of ${rev:0:12} in $dst ($(git -C "$dst" rev-parse --short HEAD))"
fi
if [ "$push" -eq 1 ]; then
    # Reviewer F3 on PR #1127: an Owner override must never reach the release repo
    # unaudited. On the no-diff path above (the package was already committed by an earlier
    # run without --push) no new commit carries the `accepted:` lines, and a bare push would
    # publish the earlier commit without them. So the commit being pushed must carry every
    # accepted line, or nothing is pushed.
    if [ -n "$accepted" ]; then
        msg=$(git -C "$dst" log -1 --format=%B HEAD)
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s\n' "$msg" | grep -qxF -- "$line" \
                || die "refusing to push: HEAD of $dst does not record the Owner's override ('$line') -- it was committed by an earlier run; reset $dst to its origin and publish again with --push"
        done <<< "$accepted"
    fi
    git -C "$dst" push origin HEAD:main
fi
