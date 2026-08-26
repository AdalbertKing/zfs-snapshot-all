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
names() {   # <engine-file> [crash] -> two snapshot names from two create_snapshot calls
    local src="$1" want_crash="${2:-}" out
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
        # And the prefix the run WRITES, which is not the same variable as the
        # family it MATCHES -- lifted the same way, for the same reason.
        eval "$(sed -n 's/^SNAP_MESSAGE=.*/&/p' "$src" | head -1)"
        if [ -n "$want_crash" ]; then
            eval "$(sed -n '/^quiesce_crash_message() {/,/^}/p' "$REPO/lib-zfs-snap.sh")"
            SNAP_MESSAGE="$(quiesce_crash_message "$MESSAGE")"
        fi
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

# ---- a degraded run names the whole set the same way, in BOTH directions ----
#
# Reviewer contract of 2026-08-26, control 2: "PUSH and PULL give the same name
# and the same final rc". The rc half needs a real transfer and is a live
# obligation; the NAME half is decided here, in create_snapshot, and is the half
# that can drift silently -- the two engines do not share this function, they
# duplicate it, which is exactly the drift test/twins exists to alarm on.
declare -A crashname=()
for engine in snapsend.sh snapget.sh; do
    if ! out="$(names "$REPO/$engine" crash)"; then
        bad "$engine: a degraded run could not be exercised"; continue
    fi
    a="$(printf '%s\n' "$out" | sed -n 1p | sed 's/.*@//')"
    b="$(printf '%s\n' "$out" | sed -n 2p | sed 's/.*@//')"
    crashname[$engine]="$a"
    # One coherent set: a degraded run must not mix marked and unmarked names.
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
        ok "$engine: a degraded run marks EVERY dataset, not the first ($a)"
    else
        bad "$engine: a degraded run marks EVERY dataset, not the first" "first=$a second=$b"
    fi
    case "$a" in
        automated_crash_*) ok "$engine: the marker sits between the family and the timestamp" ;;
        *) bad "$engine: the marker sits between the family and the timestamp" "got '$a'" ;;
    esac
    # The property delsnaps.sh and check-snap-age.sh rely on, stated as a
    # property: the degraded snapshot is still a member of the family.
    case "$a" in
        automated_*) ok "$engine: a degraded name still matches the configured family" ;;
        *) bad "$engine: a degraded name still matches the configured family" "got '$a'" ;;
    esac
done
if [ -n "${crashname[snapsend.sh]:-}" ] && [ "${crashname[snapsend.sh]:-}" = "${crashname[snapget.sh]:-}" ]; then
    ok "push and pull produce the SAME degraded name (${crashname[snapsend.sh]})"
else
    bad "push and pull produce the SAME degraded name" \
        "push=${crashname[snapsend.sh]:-<none>} pull=${crashname[snapget.sh]:-<none>}"
fi

# NEGATIVE CONTROL. Without the degrade step the same call must produce an
# UNMARKED name -- otherwise the four assertions above would pass against an
# engine that marked every snapshot it ever took.
for engine in snapsend.sh snapget.sh; do
    plain="$(names "$REPO/$engine" | sed -n 1p | sed 's/.*@//')"
    case "$plain" in
        *crash*) bad "$engine: an ordinary run is NOT marked" "got '$plain'" ;;
        automated_*) ok "$engine: an ordinary run is NOT marked ($plain)" ;;
        *) bad "$engine: an ordinary run is NOT marked" "got '$plain'" ;;
    esac
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
