#!/bin/bash
# Unit tests for the per-job state key in lib-zfs-snap.sh.
#
# Covers REV-20260729-001 F3: both state files used to be named after the target
# dataset with '/' turned into '_', which is not injective, and the name left
# IDENTIFIER out entirely -- so two jobs that -j exists to keep apart shared one
# file. Sharing the resume counter is untidy; sharing the IN-FLIGHT file means
# one job can clear the record of the snapshot another job is holding, and that
# hold is then never released.
#
# No root, no ZFS, no network: the library is sourced directly and only its
# naming and state-file functions are exercised, against a throwaway LOCKDIR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-zfs-snap.sh}"
[ -r "$LIB" ] || { echo "cannot find lib-zfs-snap.sh at $LIB" >&2; exit 1; }

LOCKDIR="$(mktemp -d)"
trap 'rm -rf "$LOCKDIR"' EXIT
export LOCKDIR
# The library brings its own log(), which reads VERBOSE -- set it before
# sourcing or `set -u` kills the first call that logs.
VERBOSE=0
HOLD_TAG="zfssnapall_inflight"
IDENTIFIER=""
# shellcheck disable=SC1090
. "$LIB"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

differ() {
    local what="$1" a="$2" b="$3"
    if [ "$a" != "$b" ]; then ok "$what"; else bad "$what" "both resolved to: $a"; fi
}
same() {
    local what="$1" a="$2" b="$3"
    if [ "$a" = "$b" ]; then ok "$what"; else bad "$what" "a: $a" "b: $b"; fi
}

# ---------------------------------------------------------------------------
# The collision the review names, verbatim
# ---------------------------------------------------------------------------
differ "distinct paths tank/a_b vs tank/a/b (resume)" \
    "$(resume_state_file tank/a_b)" "$(resume_state_file tank/a/b)"
differ "distinct paths tank/a_b vs tank/a/b (in-flight)" \
    "$(inflight_snap_file tank/a_b)" "$(inflight_snap_file tank/a/b)"

# The same shape out of this project's own tree, so the case does not read as
# hypothetical: underscores in dataset names are ordinary here.
differ "hdd/backuptest_targets vs hdd/backuptest/targets" \
    "$(inflight_snap_file hdd/backuptest_targets)" "$(inflight_snap_file hdd/backuptest/targets)"

# ---------------------------------------------------------------------------
# -j: independent jobs on the same pair
# ---------------------------------------------------------------------------
IDENTIFIER="hourly"; a_res="$(resume_state_file tank/t tank/s)"; a_inf="$(inflight_snap_file tank/t tank/s)"
IDENTIFIER="offsite"; b_res="$(resume_state_file tank/t tank/s)"; b_inf="$(inflight_snap_file tank/t tank/s)"
differ "-j hourly vs offsite, same pair (resume)"    "$a_res" "$b_res"
differ "-j hourly vs offsite, same pair (in-flight)" "$a_inf" "$b_inf"

# ---------------------------------------------------------------------------
# Stability and the source half of the identity
# ---------------------------------------------------------------------------
IDENTIFIER="hourly"
same "same logical job is stable across calls" \
    "$(resume_state_file tank/t tank/s)" "$(resume_state_file tank/t tank/s)"
differ "different source, same target" \
    "$(inflight_snap_file tank/t tank/s1)" "$(inflight_snap_file tank/t tank/s2)"

# NUL-delimited fields: no value may impersonate a field boundary by containing
# the separator that a naive join would have used.
differ "fields cannot be smuggled across the separator" \
    "$(inflight_snap_file "tank/t" "a:b")" "$(inflight_snap_file "tank/t:a" "b")"

# Both files of ONE job share the key, differing only in their purpose.
IDENTIFIER="hourly"
r="$(basename "$(resume_state_file tank/t tank/s)")"
i="$(basename "$(inflight_snap_file tank/t tank/s)")"
same "resume and in-flight share one key" "${r##*.}" "${i##*.}"

# ---------------------------------------------------------------------------
# One job must not be able to touch another's state
# ---------------------------------------------------------------------------
IDENTIFIER="hourly";  record_inflight_snap tank/t tank/s "tank/s@keep-me"
IDENTIFIER="offsite"; record_inflight_snap tank/t tank/s "tank/s@other"
IDENTIFIER="offsite"; clear_inflight_snap  tank/t tank/s
IDENTIFIER="hourly"
if [ "$(read_inflight_snap tank/t tank/s)" = "tank/s@keep-me" ]; then
    ok "clearing one job's in-flight record leaves the other's"
else
    bad "clearing one job's in-flight record leaves the other's" \
        "got: '$(read_inflight_snap tank/t tank/s)'"
fi

IDENTIFIER="hourly";  increment_resume_attempts tank/t tank/s
IDENTIFIER="offsite"; increment_resume_attempts tank/t tank/s
IDENTIFIER="offsite"; increment_resume_attempts tank/t tank/s
IDENTIFIER="hourly"
same "resume counters do not accumulate across jobs" "$(read_resume_attempts tank/t tank/s)" "1"
IDENTIFIER="offsite"
same "the other job kept its own count"              "$(read_resume_attempts tank/t tank/s)" "2"

# ---------------------------------------------------------------------------
# Handover from the pre-v3 names
# ---------------------------------------------------------------------------
IDENTIFIER="hourly"
rm -f "$LOCKDIR"/*
printf 'tank/s@inflight\n' > "$(legacy_state_file inflight-snap tank/t)"
printf '3\n'               > "$(legacy_state_file resume-attempts tank/t)"
adopt_legacy_state tank/t tank/s
same "legacy in-flight record is adopted when the content proves it is ours" \
    "$(read_inflight_snap tank/t tank/s)" "tank/s@inflight"
same "legacy resume counter is dropped, not guessed at" \
    "$(read_resume_attempts tank/t tank/s)" "0"
if [ ! -f "$(legacy_state_file resume-attempts tank/t)" ]; then
    ok "legacy resume counter is cleaned up"
else
    bad "legacy resume counter is cleaned up" "still present"
fi

# The case the ambiguous NAME cannot answer but the CONTENT can: a legacy file
# reachable from two different jobs must go to the one that actually wrote it.
rm -f "$LOCKDIR"/*
printf 'tank/other@inflight\n' > "$(legacy_state_file inflight-snap tank/t)"
adopt_legacy_state tank/t tank/s
if [ -z "$(read_inflight_snap tank/t tank/s)" ] \
   && [ -f "$(legacy_state_file inflight-snap tank/t)" ]; then
    ok "a legacy record belonging to another source is left for its owner"
else
    bad "a legacy record belonging to another source is left for its owner" \
        "adopted: '$(read_inflight_snap tank/t tank/s)'"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
