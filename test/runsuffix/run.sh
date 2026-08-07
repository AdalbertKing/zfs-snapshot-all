#!/bin/bash
# One snapshot suffix per RUN, not per dataset (Etap 2.1).
#
# The property: every dataset touched by one invocation gets the SAME name
# suffix, so the run is correlatable afterwards. Restore needs that -- a set of
# snapshots that cannot be identified as one run cannot be restored as one.
#
# Deterministic and local: `date` is stubbed to return a DIFFERENT value on each
# call, which is what a real run crossing a second boundary does. If the suffix
# were still computed inside create_snapshot, the stub alone would produce
# different names -- that is exactly what the negative control shows.
#
# No ZFS and no root: the function is extracted and its `zfs` call stubbed. The
# end-to-end property on real pools belongs to test/scenarios.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# names <engine-file> -> two snapshot names produced by two create_snapshot calls
names() {
    local src="$1" out
    out="$(
        cd "$TMPD" || exit 1
        # A date(1) that never repeats itself. Any implementation that calls it
        # per dataset cannot produce two equal names.
        # The counter lives in a FILE, not a variable: $(date ...) runs in a
        # subshell, so a shell variable is incremented in a child that then
        # exits, every call returns the same value, and the negative control
        # passes against the OLD code -- proving nothing. That is exactly what
        # the first version of this test did.
        : > ./n
        date() { printf 'x' >> ./n; printf 'STAMP%s
' "$(wc -c < ./n | tr -d ' ')"; }
        zfs()  { return 0; }
        log()  { :; }
        ssh()  { return 0; }
        MESSAGE="automated_"; RECURSIVE=0; SSH_OPTS=()
        # The run-level suffix, taken from the engine itself so the test cannot
        # drift from the definition it is pinning.
        eval "$(sed -n 's/^RUN_SUFFIX=.*/&/p' "$src" | head -1)"
        eval "$(sed -n '/^create_snapshot() {/,/^}/p' "$src")"
        create_snapshot "tank/a" "" ""
        create_snapshot "tank/b" "" ""
    )" || return 1
    printf '%s\n' "$out"
}

for engine in snapsend.sh snapget.sh; do
    src="$REPO/$engine"
    if ! out="$(names "$src")"; then bad "$engine: create_snapshot could not be exercised"; continue; fi
    a="$(printf '%s\n' "$out" | sed -n 1p | sed 's/.*@//')"
    b="$(printf '%s\n' "$out" | sed -n 2p | sed 's/.*@//')"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
        ok "$engine: two datasets in one run share the suffix ($a)"
    else
        bad "$engine: two datasets in one run share the suffix" "first=$a second=$b"
    fi
    # The format is a contract of its own: delsnaps patterns, monitor prefixes
    # and every installed cron line depend on it. Hoisting the call must not
    # have changed the shape.
    case "$a" in
        *STAMP*) ok "$engine: the suffix still comes from date(1), not a literal" ;;
        *)      bad "$engine: the suffix still comes from date(1), not a literal" "got '$a'" ;;
    esac
    case "$(printf '%s\n' "$out" | sed -n 1p)" in
        tank/a@automated_*) ok "$engine: name shape is <dataset>@<prefix><suffix>" ;;
        *) bad "$engine: name shape is <dataset>@<prefix><suffix>" "$(printf '%s\n' "$out" | sed -n 1p)" ;;
    esac
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
