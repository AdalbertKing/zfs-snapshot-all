#!/bin/bash
# ship.sh -- the last step before a Pull Request: push the branch, and on the test host
# refresh the PROJECT_STATUS digest and run the fast gates (impact.sh --verify).
#
#   ./test/ship.sh
#
# Owner 2026-11-03 ("1-4 od razu"): no suite and no gate runs on the Windows box (verify did
# not finish there in 5 minutes; on pve9 it takes ~25 s), and the digest has to be the LAST
# commit (E112) -- it was redone by hand five times in one evening. This does both in one go:
#
#   1. push the current branch (refuses a dirty tree: the digest covers committed content);
#   2. on the test host: fetch that branch, `impact.sh --refresh-status`, read the digest;
#   3. here: write that digest into docs/PROJECT_STATUS.md; when it changed, commit and push;
#   4. on the test host again: `impact.sh --verify` on the pushed head. Its rc is ours.
#
# Same constraint as remote-suite.sh: the remote command is built here from the branch name,
# validated as a plain ref, and touches only the throwaway clone.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST="${REMOTE_SUITE_HOST:-192.168.28.99}"
CLONE="${REMOTE_SUITE_CLONE:-/tmp/tt/zfs-snapshot-all}"
STATUS=docs/PROJECT_STATUS.md

die() { echo "ship: $*" >&2; exit 1; }
remote() { MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$1"; }

cd "$REPO" || die "no repository at $REPO"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != HEAD ] && [ "$branch" != main ] || die "on '$branch' -- ship a feature branch"
case "$branch" in *[!A-Za-z0-9./_-]*) die "'$branch' is not a plain branch name" ;; esac
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes -- commit them first (the digest covers committed content)"

git push -q -u origin "$branch" || die "push failed"

fetch="set -e
[ -d $CLONE/.git ] || git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git $CLONE
cd $CLONE
git restore . 2>/dev/null || true
git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git switch -q --detach origin/$branch"

digest=$(remote "$fetch
./test/impact.sh --refresh-status >/dev/null 2>&1 || true
grep -o 'status-covers-digest: [0-9a-f]*' $STATUS | head -1 | cut -d' ' -f2
git restore $STATUS") || die "the test host could not compute the digest"
case "$digest" in ''|*[!0-9a-f]*) die "no digest from the test host (got '$digest')" ;; esac

if ! grep -q "status-covers-digest: $digest " "$STATUS"; then
    sed -i "s/<!-- status-covers-digest: [0-9a-f]* -->/<!-- status-covers-digest: $digest -->/" "$STATUS"
    git add "$STATUS"
    git commit -q -m "docs: PROJECT_STATUS digest (last commit before the PR, E112)" || die "digest commit failed"
    git push -q || die "push of the digest commit failed"
    echo "ship: digest $digest committed"
else
    echo "ship: digest $digest already current"
fi

out=$(remote "$fetch
./test/impact.sh --verify 2>&1; echo \"rc=\$?\"")
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
printf '%s\n' "$out" | grep -E 'DRIFT|FAIL|FROZEN|Changed since|consistent' | head -10
echo "ship: $(git rev-parse --short HEAD) -- verify on $HOST rc=${rc:-?}"
[ "${rc:-1}" = 0 ]
