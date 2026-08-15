#!/bin/bash
# remote-suite.sh -- run ONE named test suite on the test host, and nothing else.
#
#   ./test/remote-suite.sh <suite> [ref]
#
# Why this exists rather than a plink call written out at each call site:
#
# An unattended agent needs to run suites on pve0, because they are too slow
# under MSYS. Granting it `plink -batch root@<host> *` in a permission rule would
# be the obvious way, and it is the wrong one: permission rules match a PREFIX of
# the command string, so everything after the matched prefix is unconstrained. A
# rule shaped like that is indistinguishable from unattended root on a production
# host.
#
# So the constraint lives in code instead. This script accepts a suite NAME, and
# builds the remote command itself. The name is validated against the suites that
# actually exist in this checkout, so it cannot carry shell metacharacters, a
# path, or a second command -- there is no argument an unattended caller can pass
# that turns this into "run something else on pve0".
#
# What it deliberately does NOT do: no writes outside the throwaway test clone, no
# crontab, no zpool, no zfs on production datasets. A suite that needs any of that
# is a suite a human runs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${REMOTE_SUITE_HOST:-192.168.11.10}"
CLONE="${REMOTE_SUITE_CLONE:-/root/zsa-test/repo}"

die() { echo "remote-suite: $*" >&2; exit 1; }

suite="${1:-}"
ref="${2:-origin/main}"
[ -n "$suite" ] || die "usage: $0 <suite> [ref]"

# The name must be one this checkout actually has. That is what makes it a NAME
# and not an argument: `foo; rm -rf /` names no suite, and neither does `../..`.
[ -d "$REPO/test/$suite" ] && [ -x "$REPO/test/$suite/run.sh" ] \
    || die "'$suite' is not a suite in this checkout (expected test/$suite/run.sh)"
case "$suite" in
    *[!a-z0-9]*) die "'$suite' is not a bare suite name" ;;
esac

# Same for the ref: a branch/tag/SHA, nothing that could continue the command.
case "$ref" in
    *[!A-Za-z0-9./_-]*) die "'$ref' is not a plain git ref" ;;
esac

# The full refspec matters. `git fetch origin main` writes only FETCH_HEAD, and
# several suites resolve origin/main as a ref -- without it dozens of assertions
# fail for a reason that has nothing to do with the code under test.
remote_cmd="set -e
cd $CLONE
git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git checkout -q -f -B remotesuite $ref
./test/$suite/run.sh"

MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$remote_cmd"
