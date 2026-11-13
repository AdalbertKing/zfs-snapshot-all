#!/bin/bash
# remote-suite.sh -- run ONE named test suite on the test host, and nothing else.
#
#   ./test/remote-suite.sh <suite> [ref] [only=<word>]
#
# Why this exists rather than a plink call written out at each call site:
#
# An unattended agent needs to run suites on the test host (pve9), because they are too slow
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
# that turns this into "run something else on the test host".
#
# What it deliberately does NOT do: no writes outside the throwaway test clone, no
# crontab, no zpool, no zfs on production datasets. A suite that needs any of that
# is a suite a human runs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# The test host is pve9 (lab). It used to default to a CUSTOMER production host (found
# 2026-11-03) -- suites never run there.
HOST="${REMOTE_SUITE_HOST:-192.168.28.99}"
CLONE="${REMOTE_SUITE_CLONE:-/tmp/tt/zfs-snapshot-all}"

die() { echo "remote-suite: $*" >&2; exit 1; }

suite="${1:-}"
ref="${2:-origin/main}"
[ -n "$suite" ] || die "usage: $0 <suite> [ref] [only=<word>] | $0 derive [ref] [threads]"

# PROTOCOL V4.4: `derive [ref] [threads]` prints the review state of <ref>
# (`reviewctl.sh --derive`), computed on the test host -- a whole derivation takes
# minutes under MSYS (E130). The driver is fresh main's reviewctl; the generator is
# <ref>'s own. Fixed words only, like the suite names.
if [ "$suite" = derive ]; then
    extra=""; driver="${REMOTE_DERIVE_DRIVER:-origin/main}"
    case "$driver" in *[!A-Za-z0-9./_-]*) die "'$driver' is not a plain git ref" ;; esac
    case "${3:-}" in "") ;; threads) extra=" --threads" ;; *) die "derive takes [ref] [threads], not '$3'" ;; esac
    case "$ref" in *[!A-Za-z0-9./_-]*) die "'$ref' is not a plain git ref" ;; esac
    remote_cmd="set -e
[ -d $CLONE/.git ] || git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git $CLONE
cd $CLONE
git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git checkout -q -f -B remotesuite $driver
./test/reviewctl.sh --derive $ref$extra"
    MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$remote_cmd"
    exit $?
fi

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

# Optional third word `only=<word>`: the suite runs only the sections whose header
# contains <word> (SUITE_ONLY, test/snapsend/run.sh). A plain word, like the rest.
only=""
case "${3:-}" in
    "") ;;
    only=*) only="${3#only=}"
            case "$only" in ""|*[!A-Za-z0-9_.-]*) die "'$3' is not only=<plain word>" ;; esac ;;
    *) die "third word may only be only=<word>, not '$3'" ;;
esac

fresh="${REMOTE_SUITE_FRESH:-}"
case "$fresh" in ""|1) ;; *) die "REMOTE_SUITE_FRESH is 1 or unset" ;; esac
budget="${REMOTE_SUITE_BUDGET:-600}"
case "$budget" in ""|*[!0-9]*) die "REMOTE_SUITE_BUDGET is a number of seconds" ;; esac

# The full refspec matters. `git fetch origin main` writes only FETCH_HEAD, and
# several suites resolve origin/main as a ref -- without it dozens of assertions
# fail for a reason that has nothing to do with the code under test.
# The clone lives in /tmp and is gone after a reboot of the test host (2026-11-07):
# recreate it instead of failing with an empty answer.
remote_cmd="set -e
[ -d $CLONE/.git ] || git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git $CLONE
cd $CLONE
git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
git checkout -q -f -B remotesuite $ref
set +e
# Owner, 2026-11-13: the rules were written down and still broken, so the code
# enforces two of them.
# 1. The same code never runs twice. The key is the tree without docs/ and *.md:
#    a commit that changes only prose returns the stored result at once.
#    REMOTE_SUITE_FRESH=1 forces a new run.
# 2. Every run is timed; past ${budget}s it says SLOW -- a slow suite is a defect
#    to measure (one engine call), not a wait.
key=\$(git ls-tree -r HEAD | grep -vP '\t(docs/|.*\.md\$)' | git hash-object --stdin)
cache=/var/tmp/remote-suite-cache/$suite${only:+-$only}-\$key
mkdir -p /var/tmp/remote-suite-cache
if [ -z \"$fresh\" ] && [ -f \"\$cache.log\" ]; then
    echo \"remote-suite: CACHED -- same code (tree \${key:0:12}) as the run of \$(date -r \"\$cache.log\" '+%F %T'); REMOTE_SUITE_FRESH=1 reruns\"
    cat \"\$cache.log\"; exit \$(cat \"\$cache.rc\")
fi
# A fresh progress directory per run (2026-11-13): suites left their records in the
# host's real one, and 2999 of them made every engine call 9.7 s instead of 0.4 s.
pd=\$(mktemp -d); t0=\$(date +%s)
ZFS_PROGRESS_DIR=\$pd ${only:+SUITE_ONLY=$only }./test/$suite/run.sh 2>&1 | tee \"\$cache.part\"
rc=\${PIPESTATUS[0]}
rm -rf \"\$pd\"
mv -f \"\$cache.part\" \"\$cache.log\"; echo \$rc > \"\$cache.rc\"
el=\$(( \$(date +%s) - t0 ))
echo \"remote-suite: $suite${only:+ only=$only} took \${el}s, rc=\$rc (tree \${key:0:12})\"
[ \$el -le $budget ] || echo \"remote-suite: SLOW -- \${el}s is over ${budget}s. Measure one engine call before running it again.\"
exit \$rc"

MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$remote_cmd"
