#!/bin/bash
# Tests for relationship-scoped LOGICAL pause -- REV-20260804-045.
#
# Scope note, because it is the point of the review: this suite proves the
# ORCHESTRATION contract, not a security boundary. It asserts that a job which
# identifies itself with --pair-label stops before any side effect, and it
# asserts just as explicitly that a job WITHOUT the label is not stopped --
# test 15 in the review's list, and the documented bypass. Hard disable (a
# peer-side SSH gate) is not implemented and nothing here claims otherwise.
#
# No root, no ZFS, no network. The engines are run against PATH stubs that
# record every call and then fail, so "did it reach the data plane?" is a
# question about an empty vs non-empty trace file rather than about anything
# real being touched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-zfs-snap.sh}"
ZFSBACKUP="${ZFSBACKUP:-$REPO/zfs-backup.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
for f in "$LIB" "$ZFSBACKUP" "$SNAPGET" "$SNAPSEND"; do
    [ -r "$f" ] || { echo "cannot find $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PAIR_STATE_DIR="$WORK/relationships"
export LOCKDIR="$WORK/run"
export STATS_LOG="$WORK/stats.jsonl"
mkdir -p "$LOCKDIR"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $3" "actual:   $2"; fi; }

# ---------------------------------------------------------------------------
# PATH stubs: record, then fail. Recording proves the data plane was reached;
# failing guarantees nothing real is ever touched even if the gate regresses.
# ---------------------------------------------------------------------------
STUB="$WORK/bin"; mkdir -p "$STUB"
TRACE="$WORK/trace"
for c in zfs zpool mbuffer zstd pigz ssh flock; do
    cat > "$STUB/$c" <<EOF
#!/bin/bash
echo "$c \$*" >> "$TRACE"
exit 1
EOF
    chmod 0755 "$STUB/$c"
done
export PATH="$STUB:$PATH"

# ---------------------------------------------------------------------------
# 1. The validator, including the traversal cases the directory layout makes
#    dangerous. Loaded from the library -- the copy in zfs-backup.sh is checked
#    against this one in section 6.
# ---------------------------------------------------------------------------
VERBOSE=0; HOLD_TAG="zfssnapall_inflight"; IDENTIFIER=""
# shellcheck disable=SC1090
. "$LIB"

for good in pve2 metropolis-pve1 client.1 a_b A1 x; do
    if pair_label_valid "$good"; then ok "label accepted: '$good'"
    else bad "label accepted: '$good'" "rejected"; fi
done
# '..' and anything with '/' are the ones that matter: the label becomes a
# DIRECTORY component under $PAIR_STATE_DIR.
for bad_label in "" ".." "." "../x" "a/b" "-x" ".x" "a b" 'a;rm' 'a$x' "a'b" '`id`' "$(printf 'a\nb')"; do
    if pair_label_valid "$bad_label"; then bad "label rejected: '$bad_label'" "accepted"
    else ok "label rejected: '$bad_label'"; fi
done
long65="$(printf 'a%.0s' $(seq 1 65))"
if pair_label_valid "$long65"; then bad "label rejected: 65 chars" "accepted"; else ok "label rejected: 65 chars"; fi

# ---------------------------------------------------------------------------
# 2. pair_is_paused fails OPEN -- an absent state tree must never read as
#    "everything is paused", which would stop every backup on the host.
# ---------------------------------------------------------------------------
if pair_is_paused pve2; then bad "no marker => not paused" "reported paused"; else ok "no marker => not paused"; fi
if pair_is_paused ""; then bad "empty label => not paused" "reported paused"; else ok "empty label => not paused"; fi
if pair_is_paused ".."; then bad "invalid label => not paused" "reported paused"; else ok "invalid label => not paused"; fi

# ---------------------------------------------------------------------------
# 3. The verbs, driven through the real zfs-backup.sh helpers.
# ---------------------------------------------------------------------------
CLIENTS_FAKE="$WORK/clients"; mkdir -p "$CLIENTS_FAKE"
printf 'CLIENT_NAME="pve2"\nSTATE="active"\n'  > "$CLIENTS_FAKE/pve2.conf"
printf 'CLIENT_NAME="pve3"\nSTATE="active"\n'  > "$CLIENTS_FAKE/pve3.conf"

# Sourced (dispatch is guarded by BASH_SOURCE==$0) so the verbs can be called
# directly; CLIENTS_DIR is reassigned afterwards to point at the fake tree.
backup_verb() {   # <verb> [args...] -- runs in a subshell because die() exits
    ( # shellcheck disable=SC1090
      . "$ZFSBACKUP" >/dev/null 2>&1
      CLIENTS_DIR="$CLIENTS_FAKE"
      PAIR_STATE_DIR="$PAIR_STATE_DIR"
      case "$1" in
          pause)  shift; cmd_pause_client "$@" ;;
          resume) shift; cmd_resume_client "$@" ;;
      esac ) 2>&1
}

MARK_PVE2="$PAIR_STATE_DIR/pve2/paused"
MARK_PVE3="$PAIR_STATE_DIR/pve3/paused"

out=$(backup_verb pause pve2); rc=$?
check "pause-client exits 0" "$rc" "0"
if [ -f "$MARK_PVE2" ]; then ok "pause-client creates the marker"; else bad "pause-client creates the marker" "$out"; fi
n=$(find "$PAIR_STATE_DIR" -type f | wc -l)
check "pause-client creates exactly one file" "$n" "1"
if grep -q '^paused_at=' "$MARK_PVE2" 2>/dev/null; then ok "marker records paused_at"; else bad "marker records paused_at"; fi
perm=$(stat -c '%a' "$MARK_PVE2" 2>/dev/null)
check "marker is world-readable, not world-writable" "$perm" "644"
# No temp file may survive: a reader stats the marker, and a stray .paused.XXXX
# next to it would mean the atomic-rename discipline broke.
n=$(find "$PAIR_STATE_DIR" -name '.paused.*' | wc -l)
check "no temp file left behind" "$n" "0"

out=$(backup_verb pause pve2); rc=$?
check "repeated pause is a no-op success" "$rc" "0"
n=$(find "$PAIR_STATE_DIR" -type f | wc -l)
check "repeated pause creates nothing new" "$n" "1"

# Isolation: the whole reason the key is a label and not a host.
if pair_is_paused pve2; then ok "pve2 reads as paused"; else bad "pve2 reads as paused"; fi
if pair_is_paused pve3; then bad "pve3 unaffected by pve2's pause" "pve3 reads as paused"; else ok "pve3 unaffected by pve2's pause"; fi

out=$(backup_verb pause pve3 --reason="okno serwisowe"); rc=$?
check "pause with --reason exits 0" "$rc" "0"
if grep -q '^reason=okno serwisowe' "$MARK_PVE3" 2>/dev/null; then ok "marker records the reason"; else bad "marker records the reason"; fi

out=$(backup_verb resume pve3); rc=$?
check "resume-client exits 0" "$rc" "0"
if [ -e "$MARK_PVE3" ]; then bad "resume removes the marker" "still present"; else ok "resume removes the marker"; fi
if [ -e "$MARK_PVE2" ]; then ok "resume of pve3 left pve2 paused"; else bad "resume of pve3 left pve2 paused" "pve2 marker gone"; fi
out=$(backup_verb resume pve3); rc=$?
check "repeated resume is a no-op success" "$rc" "0"

# Refusals must not mutate the filesystem.
before=$(find "$PAIR_STATE_DIR" | sort)
for bad_label in ".." "a/b" "-x" "nosuchclient"; do
    out=$(backup_verb pause "$bad_label"); rc=$?
    if [ "$rc" -ne 0 ]; then ok "pause refuses '$bad_label'"; else bad "pause refuses '$bad_label'" "exit 0: $out"; fi
done
after=$(find "$PAIR_STATE_DIR" | sort)
check "refusals mutate nothing" "$after" "$before"

# ---------------------------------------------------------------------------
# 4. The engine gate. This is the load-bearing part: an empty trace proves the
#    run stopped before zfs, ssh, mbuffer, a compressor and even flock.
# ---------------------------------------------------------------------------
run_engine() {   # <script> <label-or-empty> -- returns rc, sets OUT
    local script="$1" label="${2:-}"
    : > "$TRACE"
    if [ -n "$label" ]; then
        OUT=$("$script" -N --pair-label "$label" tank/scratch 2>&1); return $?
    else
        OUT=$("$script" -N tank/scratch 2>&1); return $?
    fi
}

for eng in "$SNAPGET" "$SNAPSEND"; do
    n=$(basename "$eng")

    run_engine "$eng" pve2; rc=$?
    check "$n: paused run exits 0" "$rc" "0"
    case "$OUT" in
        *"SKIPPED: relationship pve2 is paused"*) ok "$n: prints the required SKIPPED line" ;;
        *) bad "$n: prints the required SKIPPED line" "$OUT" ;;
    esac
    case "$OUT" in
        *SKIPPED_PAUSED*) ok "$n: names the SKIPPED_PAUSED status" ;;
        *) bad "$n: names the SKIPPED_PAUSED status" "$OUT" ;;
    esac
    if [ -s "$TRACE" ]; then
        bad "$n: paused run touches NOTHING" "trace not empty:" "$(cat "$TRACE")"
    else
        ok "$n: paused run touches NOTHING (no zfs/ssh/mbuffer/flock)"
    fi
    if grep -q '"status":"SKIPPED_PAUSED"' "$STATS_LOG" 2>/dev/null; then
        ok "$n: stats log distinguishes SKIPPED_PAUSED"
    else
        bad "$n: stats log distinguishes SKIPPED_PAUSED" "$(cat "$STATS_LOG" 2>/dev/null)"
    fi
    : > "$STATS_LOG"

    # An unpaused relationship must be unaffected -- and must get past the gate.
    run_engine "$eng" pve3; rc=$?
    case "$OUT" in
        *"is paused"*) bad "$n: unpaused label runs" "gate fired: $OUT" ;;
        *) ok "$n: unpaused label runs" ;;
    esac
    if [ -s "$TRACE" ]; then ok "$n: unpaused run reaches the data plane"
    else bad "$n: unpaused run reaches the data plane" "trace empty; out: $OUT"; fi

    # THE DOCUMENTED BYPASS, asserted rather than left implicit: without the
    # label there is nothing to key on, so the run proceeds even though the
    # relationship is paused. This is what makes logical pause an orchestration
    # feature and not a security boundary.
    run_engine "$eng" ""; rc=$?
    case "$OUT" in
        *"is paused"*) bad "$n: unlabeled manual run is NOT blocked" "gate fired" ;;
        *) ok "$n: unlabeled manual run is NOT blocked (documented bypass)" ;;
    esac

    # A typo in a cron line must be loud, not silently unpausable forever.
    OUT=$("$eng" -N --pair-label "../evil" tank/scratch 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then ok "$n: rejects an invalid label"; else bad "$n: rejects an invalid label" "$OUT"; fi
    OUT=$("$eng" -N --pair-label 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then ok "$n: rejects --pair-label with no value"; else bad "$n: rejects --pair-label with no value" "$OUT"; fi

    # --pair-label must be invisible to everything downstream: it is stripped
    # from argv before getopts, so the positional arguments are unchanged.
    OUT=$("$eng" --pair-label pve3 2>&1); rc=$?
    case "$OUT" in
        *[Uu]"zycie"*|*"ycie:"*) ok "$n: label alone still fails the usage check" ;;
        *) bad "$n: label alone still fails the usage check" "$OUT" ;;
    esac
done

# ---------------------------------------------------------------------------
# 5. --pair-label=VALUE spelling, since a cron line may carry either form.
# ---------------------------------------------------------------------------
: > "$TRACE"
OUT=$("$SNAPGET" -N --pair-label=pve2 tank/scratch 2>&1)
case "$OUT" in
    *"is paused"*) ok "snapget.sh: --pair-label=VALUE is honoured" ;;
    *) bad "snapget.sh: --pair-label=VALUE is honoured" "$OUT" ;;
esac

# ---------------------------------------------------------------------------
# 6. THE DUPLICATION CONTRACT (test/deps.conf: pair-pause-state).
#    zfs-backup.sh writes the marker, lib-zfs-snap.sh reads it, and neither
#    includes the other. If the default path or the charset drifts, the gate
#    looks installed and silently never fires -- so it is asserted, not
#    reviewed.
# ---------------------------------------------------------------------------
lib_default=$(env -u PAIR_STATE_DIR bash -c '
    VERBOSE=0; HOLD_TAG=x; IDENTIFIER=""; . "$1" >/dev/null 2>&1
    printf "%s|%s" "$PAIR_STATE_DIR" "$(pair_paused_marker demo)"' _ "$LIB")
bk_default=$(env -u PAIR_STATE_DIR bash -c '
    . "$1" >/dev/null 2>&1
    printf "%s|%s" "$PAIR_STATE_DIR" "$(pair_paused_marker demo)"' _ "$ZFSBACKUP")
check "lib and zfs-backup agree on the state path" "$bk_default" "$lib_default"
case "$lib_default" in
    /etc/zfs-snapshot-all/relationships\|*) ok "default lives under /etc/zfs-snapshot-all" ;;
    *) bad "default lives under /etc/zfs-snapshot-all" "$lib_default" ;;
esac

for l in pve2 a_b ".." "a/b" "-x" "" "a b" "$long65"; do
    lv=$(bash -c 'VERBOSE=0; HOLD_TAG=x; IDENTIFIER=""; . "$1" >/dev/null 2>&1; pair_label_valid "$2" && echo y || echo n' _ "$LIB" "$l")
    bv=$(bash -c '. "$1" >/dev/null 2>&1; pair_label_valid "$2" && echo y || echo n' _ "$ZFSBACKUP" "$l")
    check "validators agree on '$l'" "$bv" "$lv"
    # client_name_valid must be the SAME namespace: a name that enrols but
    # cannot be paused is the drift this delegation exists to prevent.
    cv=$(bash -c '. "$1" >/dev/null 2>&1; client_name_valid "$2" && echo y || echo n' _ "$ZFSBACKUP" "$l")
    check "client_name_valid agrees on '$l'" "$cv" "$lv"
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
