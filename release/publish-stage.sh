#!/bin/bash
# release/publish-stage.sh -- the pve9 half of release/publish-via-pve9.sh. Not run by hand.
#
#   release/publish-stage.sh <dev-sha> <stage-dir> < private-name-list
#
# Runs release/publish.sh with --push, so every gate it has runs here (review state, review
# coverage, scrub, name gate) -- on Linux, where they take seconds. The release clone fetches
# from the public release repository, but its PUSH URL is a bare repository on this host:
# publish.sh's final `git push` lands in <stage-dir>/out.git, never on GitHub. This host has no
# GitHub credentials on purpose. The private name list comes on stdin and is deleted on exit;
# it is never kept here (REV-20261107-192).
#
# Prints one line on success: "STAGED <release-sha> <published-base-sha>". The PC half fetches
# that commit as a bundle and pushes it.
set -euo pipefail
die() { echo "publish-stage: $*" >&2; exit 1; }
rev="${1:?usage: publish-stage.sh <dev-sha> <stage-dir>}"
st="${2:?usage: publish-stage.sh <dev-sha> <stage-dir>}"
case "$rev" in *[!0-9a-f]*|"") die "'$rev' is not a full SHA" ;; esac
[ "${#rev}" -eq 40 ] || die "'$rev' is not a full SHA"
dev="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(git -C "$dev" rev-parse HEAD)" = "$rev" ] || die "the dev checkout is not at $rev"

dl=$(mktemp); trap 'rm -f "$dl"' EXIT
cat > "$dl"
grep -qvE '^[[:space:]]*(#|$)' "$dl" || die "no private name list on stdin"

rel_url="https://github.com/AdalbertKing/zfsbackup.git"
rm -rf "$st/rel" "$st/out.git" "$st/out.bundle"
mkdir -p "$st"
git clone -q "$rel_url" "$st/rel"
base=$(git -C "$st/rel" rev-parse HEAD)
git init -q --bare "$st/out.git"
git -C "$st/out.git" fetch -q "$st/rel" "+refs/heads/main:refs/heads/main"
git -C "$st/rel" remote set-url --push origin "$st/out.git"

ZFS_NAME_DENYLIST="$dl" bash "$dev/release/publish.sh" "$rev" "$st/rel" --push >&2
out=$(git -C "$st/out.git" rev-parse refs/heads/main)
[ "$out" != "$base" ] || die "publish.sh made no new release commit (unchanged tree?) -- nothing to push"
[ "$(git -C "$st/out.git" rev-parse "$out^")" = "$base" ] || die "the staged commit is not one commit on top of the published release"
[ "$(git -C "$st/out.git" show "$out:RELEASE-OF" | head -n 1)" = "$rev" ] || die "the staged commit's RELEASE-OF is not $rev"
git -C "$st/out.git" bundle create -q "$st/out.bundle" "$base..refs/heads/main"
echo "STAGED $out $base"
