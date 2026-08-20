#!/bin/bash
# Drift alarm for the TWINNED functions of snapsend.sh and snapget.sh.
#
# WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
#
# snapsend.sh (push) and snapget.sh (pull) carry eight functions with the SAME
# NAME and the SAME SIGNATURE. They are not copies: measured 2026-08-04,
# process_dataset differs in 450 of ~550 lines and find_conflicting_snapshots
# in 53 of 57, because push reads locally and writes remotely while pull does
# the reverse -- the safety checks genuinely live on opposite sides.
#
# So this suite does NOT claim the twins are, or should become, identical. It
# claims something weaker and actually true: they are twins, and a fix landing
# in one is a QUESTION about the other. It pins a hash per copy and fails when
# one moves, so that question gets asked while the change is being written
# rather than after the other direction misbehaves in production.
#
# WHY A HASH ALARM AND NOT A MERGE
#
# The obvious alternative -- lift the near-identical ones into
# lib-zfs-snap.sh -- was considered and rejected 2026-08-04. Those functions
# take IDENTICAL parameter names in an IDENTICAL order (src_dataset,
# tgt_dataset, remote_user, remote_host) and differ only in which side the
# remote coordinates are attached to inside the body:
#
#     snapsend:  src = local,   tgt = remote
#     snapget:   src = remote,  tgt = local
#
# Merging them means introducing a direction parameter whose only failure mode
# is silent: getting it backwards asks the wrong host for a GUID, gets an empty
# answer, and can conclude a common base EXISTS when it does not -- fail-open,
# on the exact code path this project has already shipped three fail-open bugs
# on (-F refusing every first seed; written@ comparing "0B" to "0"; die inside
# $( )). And test/snapsend/run.sh is LOCAL MODE ONLY by design, so in the suite
# that would have to catch it, remote_user/remote_host are empty and both
# branches collapse to the same local call. The alarm buys most of the safety
# for none of that risk.
#
# WHAT COUNTS AS A CHANGE
#
# Comment-only and whitespace-only edits are normalised away: the twins carry
# deliberately different comment wording (snapsend's get_sorted_snapshots even
# says "Same reasoning as snapget.sh's copy of this function"), and tripping
# the alarm on prose would train people to bless without reading.
#
# Requires: nothing. Pure text tools, runs anywhere bash + coreutils does.
#
# Usage: ./run.sh [--bless]
#
#   --bless  rewrite the pinned baseline from the current tree. Per CLAUDE.md,
#            do NOT bless until the diff has been reviewed as an intentional
#            change -- blessing is how you record "I looked at the other twin
#            and decided", and it is worthless if it becomes reflex.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
BASELINE="${BASELINE:-$SCRIPT_DIR/twins.sha256}"

[ -r "$SNAPSEND" ] || { echo "cannot read snapsend.sh at $SNAPSEND" >&2; exit 1; }
[ -r "$SNAPGET" ]  || { echo "cannot read snapget.sh at $SNAPGET" >&2; exit 1; }

BLESS=0
for a in "$@"; do
    case "$a" in
        --bless) BLESS=1 ;;
        *) echo "unknown option $a (expected --bless)" >&2; exit 1 ;;
    esac
done

# The twinned set. Every function defined under the same name in both scripts.
# Keep this list exhaustive rather than curated: a name that exists in both and
# is NOT watched here is the one place drift gets to happen unobserved.
#
# It was NOT exhaustive until 2026-08-20. Twelve functions are defined under the
# same name in both scripts; eight were listed. The four that were missing --
# translate_long_options, opt_takes_arg, cluster_needs_next, declare_recursion --
# are byte-identical today (46/3/11/4 lines, zero diff), which is both why they
# were easy to overlook and why a later divergence in them would be hard to see.
#
# They differ IN KIND from the other eight, and that is worth stating rather
# than leaving to be rediscovered. The eight carry DIRECTION: push reads locally
# and writes remotely, pull the reverse, so their bodies legitimately disagree
# and the baseline pins each side separately. These four carry none -- they
# parse an option string and declare recursion.
#
# That does NOT make them candidates for lib-zfs-snap.sh. Merging the engines
# was considered and REJECTED on 2026-08-04 (docs/PROJECT_STATUS.md, and the
# twin-functions contract in test/deps.conf): the direction parameter a merge
# needs fails OPEN on common-base detection, and test/snapsend is LOCAL MODE
# ONLY by design, so the suite that would catch it structurally cannot. This
# suite is the alarm that decision chose INSTEAD of merging -- a gap in the
# alarm is a hole in that decision, not an argument against it.
#
# translate_long_options is the one to feel embarrassed about: its own comment
# argues that "a hand-kept list is a list that drifts, and a drift here is
# silent" -- while being a hand-kept second copy that nothing watched.
TWINS="
get_sorted_snapshots
find_conflicting_snapshots
find_recursive_name_collisions
validate_snapshot
find_common_snapshot
create_snapshot
transfer_data
process_dataset
translate_long_options
opt_takes_arg
cluster_needs_next
declare_recursion
"

# Space-separated form of the same list, for membership tests. $TWINS is
# newline-separated for readability and `case " $TWINS " in *" $fn "*` does not
# match across newlines -- which fails OPEN-looking (every pinned name reads as
# "not watched"), so the two forms are built here rather than at each use.
TWINS_FLAT="$(printf '%s' "$TWINS" | tr '\n' ' ')"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; local l; for l in "$@"; do echo "     $l"; done; FAIL=$((FAIL+1)); }

# Pull one function body out of a script: from `name() {` at column 1 to the
# next `}` at column 1. Then normalise -- strip CR (the tree is LF but a
# Windows checkout is not), drop comment-only and blank lines, strip trailing
# whitespace -- so the hash tracks behaviour and not prose.
extract() {   # <file> <function> -> normalised body on stdout
    tr -d '\r' < "$1" \
    | awk -v f="$2" '
        index($0, f "() {") == 1 { p = 1 }
        p { print }
        p && /^}$/ { exit }
      ' \
    | sed -e 's/[[:space:]]*$//' \
    | grep -v -e '^[[:space:]]*#' -e '^$'
}

hash_of() {   # <file> <function> -> sha256 or the literal ABSENT
    local body
    body="$(extract "$1" "$2")"
    # An empty extraction means the function is gone or was renamed. That must
    # be loud: a silent PASS here would mean the alarm quietly stopped covering
    # something, which is worse than never having had it.
    [ -n "$body" ] || { echo "ABSENT"; return; }
    printf '%s\n' "$body" | sha256sum | cut -d' ' -f1
}

# ---- --bless: rewrite the baseline -----------------------------------------
if [ "$BLESS" -eq 1 ]; then
    {
        echo "# Pinned hashes of the snapsend.sh/snapget.sh twinned functions."
        echo "# Regenerate with: ./test/twins/run.sh --bless"
        echo "# Blessing records a REVIEWED decision about both directions."
        echo "# Format: <function> <snapsend-sha256> <snapget-sha256>"
        for fn in $TWINS; do
            printf '%s %s %s\n' "$fn" "$(hash_of "$SNAPSEND" "$fn")" "$(hash_of "$SNAPGET" "$fn")"
        done
    } > "$BASELINE" || { echo "could not write $BASELINE" >&2; exit 1; }
    echo "blessed $BASELINE"
    exit 0
fi

[ -r "$BASELINE" ] || {
    echo "no baseline at $BASELINE -- create it with: ./test/twins/run.sh --bless" >&2
    exit 1
}

# ---- A. every twin still exists in both scripts ----------------------------
for fn in $TWINS; do
    hs="$(hash_of "$SNAPSEND" "$fn")"
    hg="$(hash_of "$SNAPGET" "$fn")"
    if [ "$hs" = ABSENT ] && [ "$hg" = ABSENT ]; then
        bad "A $fn exists in both scripts" \
            "gone from BOTH -- if it was retired on purpose, drop it from TWINS and bless"
    elif [ "$hs" = ABSENT ]; then
        bad "A $fn exists in both scripts" "gone from snapsend.sh, still in snapget.sh"
    elif [ "$hg" = ABSENT ]; then
        bad "A $fn exists in both scripts" "gone from snapget.sh, still in snapsend.sh"
    else
        ok "A $fn exists in both scripts"
    fi
done

# ---- B. neither copy moved without the other being considered --------------
#
# Three outcomes, and only the first is silent:
#   both pinned  -> nothing changed, nothing to ask
#   one moved    -> THE drift case. Did the same fix belong in the twin?
#   both moved   -> probably right, still needs the bless that says so.
while read -r fn want_s want_g; do
    case "$fn" in ''|'#'*) continue ;; esac
    case " $TWINS_FLAT " in
        *" $fn "*) ;;
        *) bad "B $fn is still watched" \
               "pinned in $BASELINE but not in this suite's TWINS list -- one of the two is stale"
           continue ;;
    esac
    got_s="$(hash_of "$SNAPSEND" "$fn")"
    got_g="$(hash_of "$SNAPGET" "$fn")"
    moved_s=0; moved_g=0
    [ "$got_s" = "$want_s" ] || moved_s=1
    [ "$got_g" = "$want_g" ] || moved_g=1

    if [ "$moved_s" -eq 0 ] && [ "$moved_g" -eq 0 ]; then
        ok "B $fn unchanged in both directions"
    elif [ "$moved_s" -eq 1 ] && [ "$moved_g" -eq 1 ]; then
        bad "B $fn changed in BOTH directions" \
            "that is usually correct -- confirm the two edits really are the same fix," \
            "then record the decision: ./test/twins/run.sh --bless"
    elif [ "$moved_s" -eq 1 ]; then
        bad "B $fn changed in snapsend.sh ONLY" \
            "snapget.sh's copy is untouched. Does the pull direction need the same fix?" \
            "If yes, fix it there too. If no -- say why in the commit -- then: ./test/twins/run.sh --bless"
    else
        bad "B $fn changed in snapget.sh ONLY" \
            "snapsend.sh's copy is untouched. Does the push direction need the same fix?" \
            "If yes, fix it there too. If no -- say why in the commit -- then: ./test/twins/run.sh --bless"
    fi
done < "$BASELINE"

# ---- C. the baseline covers the whole watched set --------------------------
# A twin added to TWINS but never blessed would otherwise pass section B by
# simply never being read out of the baseline file.
for fn in $TWINS; do
    if grep -q "^$fn " "$BASELINE"; then
        ok "C $fn is pinned in the baseline"
    else
        bad "C $fn is pinned in the baseline" \
            "watched by this suite but absent from $BASELINE -- bless to start tracking it"
    fi
done

# ---- D. both engines bound their ssh against a dead peer -------------------
# Not a twinned FUNCTION, but a property the twins must share for the same
# reason they exist: push and pull each build SSH_OPTS and shell out to a peer
# that can be down. Without a ConnectTimeout a bare connect blocks ~130s on the
# kernel SYN timeout (measured: ssh to a black-holed 10.x returns 255 after
# 129.6s); ServerAlive* covers one that dies mid-transfer. Both are present today
# (snapsend.sh:1830, snapget.sh:1813), but the suite that would exercise them
# needs root+zfs, so nothing in CI keeps a refactor from dropping one on ONE side
# only -- exactly the asymmetry this whole suite exists to catch. Counted, so a
# drop trips it.
for _eng in "$SNAPSEND" "$SNAPGET"; do
    _n=$(basename "$_eng")
    _ct=$(grep -c -- '-o ConnectTimeout' "$_eng")
    _sa=$(grep -c -- '-o ServerAliveInterval' "$_eng")
    if [ "$_ct" -ge 1 ] && [ "$_sa" -ge 1 ]; then
        ok "D $_n bounds its ssh against a dead peer (ConnectTimeout + ServerAlive)"
    else
        bad "D $_n bounds its ssh against a dead peer (ConnectTimeout + ServerAlive)" \
            "ConnectTimeout=$_ct ServerAlive=$_sa in $_n -- a dead peer would hang the transfer ~130s"
    fi
done

echo
echo "twins: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
