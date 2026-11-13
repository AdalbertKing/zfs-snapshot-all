#!/bin/bash
# ship.sh -- the last step before a Pull Request: push the branch and run the fast
# gate (impact.sh --verify) on the test host.
#
#   ./test/ship.sh
#
# Owner 2026-11-03 ("1-4 od razu"): no suite and no gate runs on the Windows box (verify did
# not finish there in 5 minutes; on pve9 it takes ~25 s).
#
#   1. push the current branch (refuses a dirty tree);
#   2. on the test host: fetch that branch, `impact.sh --verify` on the pushed head. Its rc
#      is ours.
#
# The PROJECT_STATUS digest step that used to sit between the two was removed with the
# digest itself (workflow V5, 2026-11-13).
#
# Same constraint as remote-suite.sh: the remote command is built here from the branch name,
# validated as a plain ref, and touches only the throwaway clone.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST="${REMOTE_SUITE_HOST:-192.168.28.99}"
CLONE="${REMOTE_SUITE_CLONE:-/tmp/tt/zfs-snapshot-all}"

die() { echo "ship: $*" >&2; exit 1; }
remote() { MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$1"; }

cd "$REPO" || die "no repository at $REPO"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != HEAD ] && [ "$branch" != main ] || die "on '$branch' -- ship a feature branch"
case "$branch" in *[!A-Za-z0-9./_-]*) die "'$branch' is not a plain branch name" ;; esac
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes -- commit them first"

git push -q -u origin "$branch" || die "push failed"

fetch="set -e
[ -d $CLONE/.git ] || git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git $CLONE
cd $CLONE
git restore . 2>/dev/null || true
git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git switch -q --detach origin/$branch"

out=$(remote "$fetch
./test/impact.sh --verify 2>&1; echo \"rc=\$?\"")
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
printf '%s\n' "$out" | grep -E 'DRIFT|FAIL|FROZEN|Changed since|consistent' | head -10
echo "ship: $(git rev-parse --short HEAD) -- verify on $HOST rc=${rc:-?}"
[ "${rc:-1}" = 0 ]
