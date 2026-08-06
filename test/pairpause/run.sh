#!/bin/bash
# Tests for the -L logical-pause preflight gate in snapget.sh/snapsend.sh
# (REV-20260804-045 slice 2).
#
# The gate sits between argument validation and EVERYTHING else -- lock,
# dependency checks, zfs, ssh -- which is what makes it testable here with no
# root, no ZFS and no network: a PAUSED run must exit 0 with the SKIPPED line
# before the script ever looks for zfs/mbuffer, and an UNPAUSED one must sail
# past the gate (and then fail on whatever this machine is missing, or on a
# deliberately nonexistent dataset on a machine that has real ZFS -- either
# way withOUT the SKIPPED line and withOUT mutating anything: -n plus a bogus
# dataset name keeps the far side of the gate read-only).
#
# Runs the REAL scripts end to end (no extraction): the gate's position in
# the file is the property under test, and only a full run can prove it.
#
#   ./test/pairpause/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
[ -r "$SNAPGET" ] && [ -r "$SNAPSEND" ] || { echo "cannot read snapget.sh/snapsend.sh under $REPO" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REL="$WORK/relationships"
mkdir -p "$REL/alpha"
printf 'PAUSED_AT="2026-08-06 12:00:00"\n' > "$REL/alpha/paused"

# A dataset name no real pool starts with, so on a host that DOES have zfs
# the un-gated path stays read-only ("dataset not found"), never a mutation.
BOGUS="pairpause-no-such-pool/nope"

for script in "$SNAPGET" "$SNAPSEND"; do
    sname="$(basename "$script")"

    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -L alpha "$BOGUS" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "SKIPPED: relationship alpha is paused"; then
        ok "$sname: paused label exits 0 with the SKIPPED line"
    else
        bad "$sname: paused label exits 0 with the SKIPPED line" "rc=$rc" "$out"
    fi
    if echo "$out" | grep -q "resume-client alpha"; then
        ok "$sname: the SKIPPED line names the resume command"
    else
        bad "$sname: the SKIPPED line names the resume command" "$out"
    fi
    # The skip is its own stats state -- never a fake success, never silent.
    if grep -q '"status":"skipped_paused"' "$WORK/stats.log" 2>/dev/null; then
        ok "$sname: the skip lands in the stats log as skipped_paused"
    else
        bad "$sname: the skip lands in the stats log as skipped_paused" "$(cat "$WORK/stats.log" 2>/dev/null)"
    fi
    rm -f "$WORK/stats.log"

    # Position proof: the paused exit happened BEFORE the dependency checks,
    # i.e. the same command WITHOUT the pause marker gets strictly further
    # (and fails on this machine's missing deps or the bogus dataset).
    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -n -L beta "$BOGUS" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q "SKIPPED: relationship"; then
        ok "$sname: an unpaused label is not gated (run proceeds past the gate and fails later, no SKIPPED)"
    else
        bad "$sname: an unpaused label is not gated (run proceeds past the gate and fails later, no SKIPPED)" "rc=$rc" "$out"
    fi

    # An invocation that OMITS -L must behave identically to before the
    # feature existed, even with a marker on disk -- the documented
    # limitation of logical pause, asserted as behavior.
    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -n "$BOGUS" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q "SKIPPED: relationship"; then
        ok "$sname: a label-less run is NOT gated (documented logical-pause limitation)"
    else
        bad "$sname: a label-less run is NOT gated (documented logical-pause limitation)" "rc=$rc" "$out"
    fi

    # Labels are validated before use -- a traversal cannot probe arbitrary
    # paths for a 'paused' file.
    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -L "../alpha" "$BOGUS" 2>&1); rc=$?
    if [ "$rc" -eq 1 ] && echo "$out" | grep -q "relationship label"; then
        ok "$sname: a path-traversal label is refused outright"
    else
        bad "$sname: a path-traversal label is refused outright" "rc=$rc" "$out"
    fi

    # An empty -L is 'no label', same as the project's blank-field=missing
    # convention -- not a gate against an empty-named relationship.
    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -n -L "" "$BOGUS" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q "SKIPPED: relationship"; then
        ok "$sname: -L '' means no label, not a gate"
    else
        bad "$sname: -L '' means no label, not a gate" "rc=$rc" "$out"
    fi
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
