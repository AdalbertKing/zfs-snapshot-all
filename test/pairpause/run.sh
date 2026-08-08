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
    # The property is that the gate did NOT fire -- nothing more. The exit code
    # used to be part of this assertion, and it is scaffolding, not contract: an
    # ungated run fails LATER on a bogus dataset only where zfs is missing. On a
    # real host `zpool list` reports the unknown pool and the run ends rc=0, so
    # these six cases false-failed on every host while passing on the laptop.
    # Measured 2026-08-08 on metropolis pve1: identical 12/6 at 643238a, i.e.
    # before Stage 2 touched anything, so it was the assertion and not the code.
    if ! echo "$out" | grep -q "SKIPPED: relationship"; then
        ok "$sname: an unpaused label is not gated (run proceeds past the gate and fails later, no SKIPPED)"
    else
        bad "$sname: an unpaused label is not gated (run proceeds past the gate and fails later, no SKIPPED)" "rc=$rc" "$out"
    fi

    # An invocation that OMITS -L must behave identically to before the
    # feature existed, even with a marker on disk -- the documented
    # limitation of logical pause, asserted as behavior.
    out=$(RELATIONSHIPS_DIR="$REL" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK" \
          bash "$script" -n "$BOGUS" 2>&1); rc=$?
    # The property is that the gate did NOT fire -- nothing more. The exit code
    # used to be part of this assertion, and it is scaffolding, not contract: an
    # ungated run fails LATER on a bogus dataset only where zfs is missing. On a
    # real host `zpool list` reports the unknown pool and the run ends rc=0, so
    # these six cases false-failed on every host while passing on the laptop.
    # Measured 2026-08-08 on metropolis pve1: identical 12/6 at 643238a, i.e.
    # before Stage 2 touched anything, so it was the assertion and not the code.
    if ! echo "$out" | grep -q "SKIPPED: relationship"; then
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
    # The property is that the gate did NOT fire -- nothing more. The exit code
    # used to be part of this assertion, and it is scaffolding, not contract: an
    # ungated run fails LATER on a bogus dataset only where zfs is missing. On a
    # real host `zpool list` reports the unknown pool and the run ends rc=0, so
    # these six cases false-failed on every host while passing on the laptop.
    # Measured 2026-08-08 on metropolis pve1: identical 12/6 at 643238a, i.e.
    # before Stage 2 touched anything, so it was the assertion and not the code.
    if ! echo "$out" | grep -q "SKIPPED: relationship"; then
        ok "$sname: -L '' means no label, not a gate"
    else
        bad "$sname: -L '' means no label, not a gate" "rc=$rc" "$out"
    fi
done

# ---------------------------------------------------------------------------
# check-snap-age.sh -L (slice 3): while the relationship is paused, staleness
# is the EXPECTED state -- OK with explicit wording, never a page and never
# silence. The script requires zfs in PATH before parsing, so a stub stands
# in for it; the paused path exits before any zfs invocation, and the
# unpaused path is pushed only as far as its ordinary argument validation.
# ---------------------------------------------------------------------------
CSA="${CSA:-$REPO/check-snap-age.sh}"
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/zfs"; chmod +x "$STUB/zfs"
CSA_PATH="$STUB:$PATH"

out=$(PATH="$CSA_PATH" RELATIONSHIPS_DIR="$REL" bash "$CSA" -L alpha "tank/x" "automated_" 90m 3h 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "relationship alpha is paused" \
        && echo "$out" | grep -q "staleness is expected"; then
    ok "check-snap-age: paused label exits OK naming the pause, not silence"
else
    bad "check-snap-age: paused label exits OK naming the pause, not silence" "rc=$rc" "$out"
fi

# Unpaused label: the monitor must behave exactly as an unlabeled run -- here
# both die identically on the same malformed threshold (UNKNOWN=3), which
# also proves config errors stay loud even with -L present...
out=$(PATH="$CSA_PATH" RELATIONSHIPS_DIR="$REL" bash "$CSA" -L beta "tank/x" "automated_" 90x 3h 2>&1); rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -q "invalid duration"; then
    ok "check-snap-age: unpaused label falls through to normal validation (UNKNOWN on bad duration)"
else
    bad "check-snap-age: unpaused label falls through to normal validation (UNKNOWN on bad duration)" "rc=$rc" "$out"
fi

# ...and a PAUSED label with a malformed threshold is STILL a loud UNKNOWN:
# the pause suppresses expected staleness, not broken configuration.
out=$(PATH="$CSA_PATH" RELATIONSHIPS_DIR="$REL" bash "$CSA" -L alpha "tank/x" "automated_" 90x 3h 2>&1); rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -q "invalid duration"; then
    ok "check-snap-age: a paused label does not swallow a malformed threshold (still UNKNOWN)"
else
    bad "check-snap-age: a paused label does not swallow a malformed threshold (still UNKNOWN)" "rc=$rc" "$out"
fi

# A traversal label is UNKNOWN, before any path is probed.
out=$(PATH="$CSA_PATH" RELATIONSHIPS_DIR="$REL" bash "$CSA" -L "../alpha" "tank/x" "automated_" 90m 3h 2>&1); rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -q "not a valid relationship label"; then
    ok "check-snap-age: a path-traversal label is UNKNOWN, refused before any path is probed"
else
    bad "check-snap-age: a path-traversal label is UNKNOWN, refused before any path is probed" "rc=$rc" "$out"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
