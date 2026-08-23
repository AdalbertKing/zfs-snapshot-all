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


# ---------------------------------------------------------------------------
# E. ssh -n ON EVERY READ, AND ON NONE OF THE FOUR THAT CARRY THE PAYLOAD.
#
# ssh without -n reads its stdin to EOF and hands it to the remote command.
# Every read-only call in the engines was doing that, which is why a
# confirmation prompt printed after engine work could not be answered from a
# pipe: `seed` and `activate` refused "not confirmed" whatever was fed in,
# because the engine had already drained the answer. On a terminal it works,
# so it only ever showed once something was scripted (issue #9, 2026-08-23).
#
# This guards BOTH directions, and the second matters more:
#   * a NEW read-only call without -n reintroduces the defect quietly;
#   * -n added to one of the four payload calls BREAKS THE TRANSFER -- the
#     stream, the throughput probe and the quiesce script all arrive on stdin.
#     A well-meaning sweep is exactly how that would happen, so the four are
#     named here rather than left to judgement.
# ---------------------------------------------------------------------------
# Matches an INVOCATION, not the word: a real call is followed by a flag or by
# the options array. Without that, help text ("ssh -c") and diagnostics ("over
# ssh (exit 255)") are counted as calls -- the first draft of this check
# reported five such lines as defects.
# A PAYLOAD call is one the DATA flows into: something pipes into it. That is a
# property of the line, so it is read off the line.
#
# This was a hardcoded list of line numbers for about an hour, until wiring live
# progress shifted every one of them and the check reported four healthy calls
# as defects. Same brittleness this suite diagnosed in test/localbackup this
# morning -- pinning a property to WHERE it lives instead of WHAT it is --
# committed again, by me, the same day. Line numbers are never the property.
ssh_receives_stdin() {   # <line> -> 0 when something pipes INTO this ssh
    case "${1%%ssh *}" in
        *"|"*) return 0 ;;
        *)     return 1 ;;
    esac
}
for f in "$SNAPSEND" "$SNAPGET" "$REPO/delsnaps.sh" "$REPO/lib-zfs-snap.sh"; do
    [ -r "$f" ] || continue
    name=$(basename "$f")
    missing=""; wrong=""; has_payload=no
    while IFS=: read -r ln rest; do
        [ -n "$ln" ] || continue
        case "$rest" in \#*|" "*\#*) continue ;; esac
        is_payload=no
        ssh_receives_stdin "$rest" && { is_payload=yes; has_payload=yes; }
        case "$rest" in
            *"ssh -n "*) [ "$is_payload" = yes ] && wrong="$wrong $ln" ;;
            *)           [ "$is_payload" = no  ] && missing="$missing $ln" ;;
        esac
    done <<EOF
$(grep -nE '(^|[^a-z_-])ssh (-[a-zA-Z]|"\$)' "$f" | grep -vE '\.ssh|ssh-keygen' | sed 's/:[[:space:]]*/:/')
EOF
    if [ -n "$missing" ]; then
        FAIL=$((FAIL+1)); echo "FAIL E $name: read-only ssh without -n at line(s):$missing"
        echo "     ssh without -n drains the operator's stdin, so any prompt after it is unanswerable from a pipe."
    else
        PASS=$((PASS+1)); echo "PASS E $name: every read-only ssh passes -n"
    fi
    if [ "$has_payload" = yes ] || [ -n "$wrong" ]; then
        if [ -n "$wrong" ]; then
            FAIL=$((FAIL+1)); echo "FAIL E $name: -n added to a PAYLOAD ssh at line(s):$wrong -- this breaks the transfer"
            echo "     those calls receive the send stream / probe data / quiesce script ON STDIN."
        else
            PASS=$((PASS+1)); echo "PASS E $name: the payload-carrying ssh calls still have no -n"
        fi
    fi
done


# ---------------------------------------------------------------------------
# F. LIVE TRANSFER PROGRESS -- the properties, not the plumbing.
#
# Three things must hold, and the middle one is the reason this is tested at
# all rather than eyeballed:
#
#   1. the progress lines zfs send -v -P really emits are recognised;
#   2. they are STRIPPED from the stderr a failure is diagnosed from -- the
#      alerting path takes `tail -n 8` of that stream, and a mail reading
#      "14:21:23 1842248" instead of the reason is worse than no progress;
#   3. real diagnostics SURVIVE the stripping. A filter that ate the error too
#      would pass test 2 and destroy alerting.
#
# The fixture is a verbatim capture from zfs-2.1.11, not a line typed for the
# test -- see feedback_assert_real_tool_output_not_fixtures: today alone, four
# defects survived because an assertion was pinned to a shape the tool had
# stopped emitting.
# ---------------------------------------------------------------------------
pg_tmp="$(mktemp -d)"
trap 'rm -rf "$pg_tmp"' EXIT
printf 'full\thdd/lab9src/deep@automated_hourly_2026-08-23_12-01-01\t8448112\n' >  "$pg_tmp/err"
printf 'size\t8448112\n'                                                       >> "$pg_tmp/err"
printf '14:21:23\t1842248\thdd/lab9src/deep@automated_hourly_2026-08-23_12-01-01\n' >> "$pg_tmp/err"
printf 'warning: cannot send: Invalid argument\n'                              >> "$pg_tmp/err"
printf '14:21:24\t2236400\thdd/lab9src/deep@automated_hourly_2026-08-23_12-01-01\n' >> "$pg_tmp/err"

( set +u; VERBOSE=0; ZFS_PROGRESS_DIR="$pg_tmp/prog"; export ZFS_PROGRESS_DIR
  . "$REPO/lib-zfs-snap.sh" 2>/dev/null
  cp "$pg_tmp/err" "$pg_tmp/stripped"
  progress_strip "$pg_tmp/stripped"
  pid=$(progress_watch "$pg_tmp/err" "hdd/x@s" "tank/dst" peer pull); sleep 3
  progress_done "$pid" "hdd/x@s" "tank/dst" ok
  cp "$(progress_path "tank/dst")" "$pg_tmp/record" 2>/dev/null
) >/dev/null 2>&1

if [ "$(wc -l < "$pg_tmp/stripped")" -eq 1 ] && grep -q 'Invalid argument' "$pg_tmp/stripped"; then
    PASS=$((PASS+1)); echo "PASS F progress lines are stripped from the stderr a failure is diagnosed from"
else
    FAIL=$((FAIL+1)); echo "FAIL F progress lines are stripped from the stderr a failure is diagnosed from"
    echo "     zostalo: $(cat "$pg_tmp/stripped" | tr '\n' '|')"
fi

if grep -q 'Invalid argument' "$pg_tmp/stripped"; then
    PASS=$((PASS+1)); echo "PASS F the real diagnostic SURVIVES the stripping"
else
    FAIL=$((FAIL+1)); echo "FAIL F the real diagnostic SURVIVES the stripping -- alerting would lose the reason"
fi

if [ -s "$pg_tmp/record" ] \
   && grep -q '"total_bytes":8448112' "$pg_tmp/record" \
   && grep -q '"done_bytes":2236400' "$pg_tmp/record"; then
    PASS=$((PASS+1)); echo "PASS F the record carries the total and the latest cumulative position"
else
    FAIL=$((FAIL+1)); echo "FAIL F the record carries the total and the latest cumulative position"
    echo "     rekord: $(cat "$pg_tmp/record" 2>/dev/null)"
fi

# One "state" key, not two. The first version of progress_done appended beside
# the running marker instead of replacing it, which is not a record -- it is a
# coin toss for whichever parser reads it.
if [ "$(grep -o '"state"' "$pg_tmp/record" 2>/dev/null | wc -l)" -eq 1 ] \
   && grep -q '"state":"ok"' "$pg_tmp/record" 2>/dev/null; then
    PASS=$((PASS+1)); echo "PASS F a finished record has exactly one state, and it is the final one"
else
    FAIL=$((FAIL+1)); echo "FAIL F a finished record has exactly one state, and it is the final one"
fi

# Both engines must splice -v -P into the REAL send command, and the push
# direction must never put -n on the ssh that RECEIVES the stream.
for eng in "$SNAPSEND" "$SNAPGET"; do
    n=$(basename "$eng")
    if grep -q 'zfs send -v -P ${send_cmd#zfs send }' "$eng"; then
        PASS=$((PASS+1)); echo "PASS F $n splices -v -P into the real send command"
    else
        FAIL=$((FAIL+1)); echo "FAIL F $n splices -v -P into the real send command"
    fi
done

# A SUCCESSFUL TRANSFER MUST NOT REPORT FAILURE.
#
# `[ $rc -ne 0 ] && return 1` as the LAST statement of a branch returns 1 when
# the test is false, and that becomes the function's exit status: every
# successful transfer reported "Transfer failed", with no reason, because there
# was none. Found by running a real push against the pre-change code as a
# control -- the same transfer succeeded there. CI was 30/30 at the time.
#
# The shape, not the spelling: no progress bookkeeping may end a branch with a
# bare test, in either engine.
for eng in "$SNAPSEND" "$SNAPGET"; do
    n=$(basename "$eng")
    if grep -qE '^\s*\[ \$_pg_rc -ne 0 \] &&' "$eng"; then
        FAIL=$((FAIL+1)); echo "FAIL F $n ends a branch with a bare test -- a successful transfer would report failure"
    else
        PASS=$((PASS+1)); echo "PASS F $n does not let progress bookkeeping decide the transfer's exit status"
    fi
done

# THE PROGRESS RECORD IS KEYED BY THE JOB'S TARGET -- STABLE ACROSS SNAPSHOTS
# AND RESUME.
#
# Two generations of this key failed, each caught by a discriminator: the
# mangled-name key collided (pool/a_b@s vs pool/a/b@s), and the
# (target, dataset) key was fed the SNAPSHOT by the engines, so one configured
# job produced a fresh record per run and a resume did not share identity with
# the run it resumed -- the reviewer's discriminator on #130, confirmed by
# measurement (three different hashes for one job) before being accepted.
#
# The contract now: same target = same record, whatever the snapshot or resume
# token; different target = different record. Source and snapshot are data
# INSIDE the record, never the key.
( set +u; VERBOSE=0; ZFS_PROGRESS_DIR="$pg_tmp/keys"; export ZFS_PROGRESS_DIR
  . "$REPO/lib-zfs-snap.sh" 2>/dev/null
  {
    printf '%s
' "$(progress_path 'tank/dst')"
    printf '%s
' "$(progress_path 'tank/dst')"
    printf '%s
' "$(progress_path 'tank/dstB')"
  } > "$pg_tmp/keys.txt"
) >/dev/null 2>&1
k1=$(sed -n 1p "$pg_tmp/keys.txt"); k2=$(sed -n 2p "$pg_tmp/keys.txt"); k3=$(sed -n 3p "$pg_tmp/keys.txt")
if [ -n "$k1" ] && [ "$k1" = "$k2" ]; then
    PASS=$((PASS+1)); echo "PASS F one job keeps ONE record across successive snapshots and resume (key = target)"
else
    FAIL=$((FAIL+1)); echo "FAIL F one job keeps ONE record across successive snapshots and resume (key = target)"
fi
if [ -n "$k1" ] && [ "$k1" != "$k3" ]; then
    PASS=$((PASS+1)); echo "PASS F the same source to two different targets gets two records"
else
    FAIL=$((FAIL+1)); echo "FAIL F the same source to two different targets gets two records"
fi
# The human identity must survive INSIDE the record.
( set +u; VERBOSE=0; ZFS_PROGRESS_DIR="$pg_tmp/keys"; export ZFS_PROGRESS_DIR
  . "$REPO/lib-zfs-snap.sh" 2>/dev/null
  printf 'size	10
' > "$pg_tmp/kerr"
  pid=$(progress_watch "$pg_tmp/kerr" "pool/src@s" "tank/dstA" peer pull); sleep 3
  progress_done "$pid" "pool/src@s" "tank/dstA" ok
  progress_mark_verified "tank/dstA" verified
  cp "$(progress_path 'tank/dstA')" "$pg_tmp/krec" 2>/dev/null
) >/dev/null 2>&1
if grep -q '"dataset":"pool/src@s"' "$pg_tmp/krec" 2>/dev/null    && grep -q '"target":"tank/dstA"' "$pg_tmp/krec" 2>/dev/null; then
    PASS=$((PASS+1)); echo "PASS F the hashed record still names its dataset and target inside"
else
    FAIL=$((FAIL+1)); echo "FAIL F the hashed record still names its dataset and target inside"
fi
# END-STATE: after the landed-GUID check the record says so. "ok" alone means
# only "the pipeline exited 0" -- an earlier freeze entry overclaimed this, and
# the distinct verified state is the correction.
if grep -q '"state":"verified"' "$pg_tmp/krec" 2>/dev/null; then
    PASS=$((PASS+1)); echo "PASS F a landed-GUID verification upgrades ok -> verified"
else
    FAIL=$((FAIL+1)); echo "FAIL F a landed-GUID verification upgrades ok -> verified"
    echo "     rekord: $(cat "$pg_tmp/krec" 2>/dev/null | cut -c1-160)"
fi
# LIVE AGGREGATE: a finished record must not inflate the relation's now-state.
( set +u; VERBOSE=0; ZFS_PROGRESS_DIR="$pg_tmp/agg"; export ZFS_PROGRESS_DIR
  mkdir -p "$pg_tmp/agg"
  printf '{"label":"x","state":"ok","total_bytes":100,"done_bytes":100,"updated_epoch":1}
' > "$pg_tmp/agg/a.json"
  printf '{"label":"x","state":"running","total_bytes":100,"done_bytes":25,"updated_epoch":%s}
' "$(date +%s)" > "$pg_tmp/agg/b.json"
  . "$REPO/zfs-backup.sh" 2>/dev/null
  cmd_progress --json > "$pg_tmp/agg.json" 2>/dev/null
) >/dev/null 2>&1
if grep -q '"total_bytes":100,"done_bytes":25' "$pg_tmp/agg.json" 2>/dev/null; then
    PASS=$((PASS+1)); echo "PASS F a finished record does not inflate the live relation aggregate (100/25, not 200/125)"
else
    FAIL=$((FAIL+1)); echo "FAIL F a finished record does not inflate the live relation aggregate (100/25, not 200/125)"
    echo "     agregat: $(grep -o "relations.*" "$pg_tmp/agg.json" 2>/dev/null | cut -c1-160)"
fi

# THE RECORD IS A DATA LAYER FOR MACHINES, NOT A STATUS LINE (owner direction,
# 2026-08-23): a future GUI/monitor must read per-job and per-relation state
# without scraping text. So the identity fields are pinned as a contract:
# relation label, mode+base derived from the REAL send command, job identity,
# and wire bytes that are -1 (unknown), never 0, when not measurable.
( set +u; VERBOSE=0; ZFS_PROGRESS_DIR="$pg_tmp/idkeys"; export ZFS_PROGRESS_DIR
  . "$REPO/lib-zfs-snap.sh" 2>/dev/null
  PAIR_LABEL=lab-rel
  progress_classify "zfs send -v -P -R -i hdd/a@prev hdd/a@now"; printf '%s %s\n' "$PG_MODE" "$PG_BASE" >  "$pg_tmp/cls"
  progress_classify "zfs send -t 1-abc-token";                   printf '%s %s\n' "$PG_MODE" "$PG_BASE" >> "$pg_tmp/cls"
  progress_classify "zfs send hdd/a@now";                        printf '%s %s\n' "$PG_MODE" "$PG_BASE" >> "$pg_tmp/cls"
  printf 'size\t100\n14:00:01\t40\tx\n' > "$pg_tmp/iderr"
  pid=$(progress_watch "$pg_tmp/iderr" "hdd/a@now" "tank/dst" peer pull incremental "hdd/a@prev"); sleep 3
  progress_done "$pid" "hdd/a@now" "tank/dst" ok
  cp "$(progress_path 'tank/dst')" "$pg_tmp/idrec" 2>/dev/null
) >/dev/null 2>&1
if [ "$(cat "$pg_tmp/cls" 2>/dev/null)" = "incremental hdd/a@prev
resume 1-abc-token
full " ]; then
    PASS=$((PASS+1)); echo "PASS F progress_classify reads mode and base off the real send command"
else
    FAIL=$((FAIL+1)); echo "FAIL F progress_classify reads mode and base off the real send command"
    echo "     dostal: $(tr '\n' '|' < "$pg_tmp/cls" 2>/dev/null)"
fi
if grep -q '"label":"lab-rel"' "$pg_tmp/idrec" 2>/dev/null \
   && grep -q '"mode":"incremental","base":"hdd/a@prev"' "$pg_tmp/idrec" \
   && grep -q '"job":"[0-9a-f]' "$pg_tmp/idrec" \
   && grep -q '"wire_bytes":-1' "$pg_tmp/idrec"; then
    PASS=$((PASS+1)); echo "PASS F the record carries relation, mode, base, job identity, and honest wire=-1"
else
    FAIL=$((FAIL+1)); echo "FAIL F the record carries relation, mode, base, job identity, and honest wire=-1"
    echo "     rekord: $(cat "$pg_tmp/idrec" 2>/dev/null | cut -c1-200)"
fi

echo
echo "twins: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
