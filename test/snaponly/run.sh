#!/bin/bash
# snapget.sh -s: source snapshots only, no transfer (REV-20261016-148).
#
# Drives the REAL snapget.sh command line end to end. ssh, zfs and zpool are
# stubs on PATH that append every call to a trace file, so each case asserts
# what the engine ASKED FOR -- not only its exit status. The ssh stub runs the
# remote command against the same zfs stub with REMOTE_SIDE=1, so a source-side
# call is traced as RZFS and a call on this host as ZFS.
#
# The property under test is the whole execution path: no target probe, no
# send/recv/hold/bookmark/destroy/rollback, no mbuffer, no mirror -- on success,
# under -r/-R, under quiesce and when something fails.
#
# Without root, ZFS or a network. On a host with no flock(1) (Git Bash), a
# pass-through flock stub is added; the lock itself is not what this tests.
#
#   ./test/snaponly/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
[ -r "$SNAPGET" ] || { echo "cannot read $SNAPGET" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
# A case about -s counts only if the engine ACCEPTED -s. Without this, every
# "nothing happened" assertion passes against an engine that simply does not
# know the option -- rc 1, empty trace -- and proves nothing (the review's
# last sentence). The last run's argv is kept by run() for this.
check() {   # <name> <condition-command...>
    local name="$1"; shift
    if [ "$LAST_HAS_S" -eq 1 ] && printf '%s' "$out" | grep -q 'Nieznana opcja'; then
        bad "$name" "the engine does not know -s (unknown-option refusal is not evidence)" "$out"
        return
    fi
    if "$@"; then ok "$name"; else bad "$name" "rc=$rc" "--- out:" "$out" "--- trace:" "$(cat "$TRACE" 2>/dev/null)"; fi
}
LAST_HAS_S=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
mkdir -p "$STUB" "$WORK/rel" "$WORK/lock"
TRACE="$WORK/trace"
ZFS_DATASETS="$WORK/datasets"
export TRACE ZFS_DATASETS

cat > "$STUB/zfs" <<'EOF'
#!/bin/bash
echo "${REMOTE_SIDE:+R}ZFS $*" >> "$TRACE"
last="${*: -1}"
case "$1" in
    list)
        case " $* " in
            *" -r "*)
                [ "${ZFS_LIST_FAIL:-0}" = 1 ] && { echo "listing failed" >&2; exit 2; }
                awk -v d="$last" '$0 == d || index($0, d "/") == 1' "$ZFS_DATASETS"
                exit 0 ;;
        esac
        grep -qxF -- "$last" "$ZFS_DATASETS" && { echo "$last"; exit 0; }
        exit 1 ;;
    snapshot)
        if [ -n "${ZFS_SNAP_FAIL:-}" ] && [ "${last%@*}" = "$ZFS_SNAP_FAIL" ]; then
            echo "cannot create snapshot '$last': permission denied" >&2; exit 1
        fi
        exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/zpool" <<'EOF'
#!/bin/bash
echo "${REMOTE_SIDE:+R}ZPOOL $*" >> "$TRACE"
echo ONLINE
EOF
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
# Skip ssh's own options; what is left is [user@]host and the remote command.
while [ $# -gt 0 ]; do
    case "$1" in
        -n|-T) shift ;;
        -o|-p|-i|-c|-O|-l) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
dest="$1"; shift
cmd="$*"
case "$cmd" in "") exit 0 ;; esac          # `ssh -O exit host` (closing the multiplexer)
echo "SSH $dest $cmd" >> "$TRACE"
[ "${SSH_GATE_REFUSE:-0}" = 1 ] && { echo "PAIR_DISABLED: relationship disabled on this host" >&2; exit 93; }
[ "${SSH_UNREACH:-0}" = 1 ] && { echo "ssh: connect to host: Connection timed out" >&2; exit 255; }
case "$cmd" in
    "bash -s --"*)
        cat >/dev/null
        echo "QUIESCE-WINDOW $cmd" >> "$TRACE"
        exit "${SSH_QUIESCE_RC:-0}" ;;
    *machine-id*) echo "remote-machine-id"; exit 0 ;;
    "hostname -f") echo "remote.example"; exit 0 ;;
esac
REMOTE_SIDE=1 bash -c "$cmd"
EOF
for _t in mbuffer zstd pigz; do
    printf '#!/bin/bash\necho "%s $*" >> "$TRACE"\ncat\n' "${_t^^}" > "$STUB/$_t"
done
command -v flock >/dev/null 2>&1 || printf '#!/bin/bash\nexit 0\n' > "$STUB/flock"
chmod +x "$STUB"/*

# A PATH with NO mbuffer/zstd/pigz anywhere, for the "does not need them" case.
# Built only from what this host really has, minus those three, and proven by
# the positive control below (an ordinary pull on the same PATH must refuse).
NODEP="$WORK/nodep"
mkdir -p "$NODEP"
for _f in zfs zpool ssh flock; do [ -e "$STUB/$_f" ] && cp "$STUB/$_f" "$NODEP/"; done
NODEP_PATH="$NODEP"
IFS=: read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
    [ -d "$_d" ] || continue
    if [ -e "$_d/mbuffer" ] || [ -e "$_d/zstd" ] || [ -e "$_d/pigz" ] || [ -e "$_d/mbuffer.exe" ] || [ -e "$_d/zstd.exe" ]; then
        _fd="$WORK/filtered$(printf '%s' "$_d" | md5sum | cut -c1-8)"
        mkdir -p "$_fd"
        for _x in "$_d"/*; do
            case "$(basename "$_x")" in mbuffer|mbuffer.exe|zstd|zstd.exe|pigz|pigz.exe|unpigz) continue ;; esac
            [ -x "$_x" ] && [ ! -d "$_x" ] && ln -s "$_x" "$_fd/" 2>/dev/null
        done
        NODEP_PATH="$NODEP_PATH:$_fd"
    else
        NODEP_PATH="$NODEP_PATH:$_d"
    fi
done

reset_world() {
    : > "$TRACE"
    rm -f "$WORK/stats.log"
    printf '%s\n' tank tank/vm-100-disk-0 tank/vm-101-disk-0 tank/vm-101-disk-0/extra tank/skipme > "$ZFS_DATASETS"
}

# run [ENV=...] -- <snapget args...>; sets rc and out.
run() {
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    LAST_HAS_S=0
    case " $* " in *" -s "*|*" -n -s "*) LAST_HAS_S=1 ;; esac
    out=$(env "${envs[@]+"${envs[@]}"}" PATH="${RUN_PATH:-$STUB:$PATH}" \
          RELATIONSHIPS_DIR="$WORK/rel" STATS_LOG="$WORK/stats.log" LOCKDIR="$WORK/lock" \
          NOTIFY_SCRIPT=/bin/true HOME="$WORK" \
          bash "$SNAPGET" "$@" 2>&1); rc=$?
}

snapcount()    { grep -c '^R\?ZFS snapshot' "$TRACE"; }
no_transfer()  { ! grep -Eq 'ZFS (send|recv|receive|hold|release|bookmark|destroy|rollback)|^MBUFFER|^ZSTD|^PIGZ' "$TRACE"; }
no_local_zfs() { ! grep -Eq '^(ZFS|ZPOOL) ' "$TRACE"; }
stat_status()  { grep -c "\"status\":\"$1\"" "$WORK/stats.log" 2>/dev/null; }

# ---- 1. source-only success, remote --------------------------------------
reset_world
run -- -s -m lab_ root@pve1:tank/vm-100-disk-0
check "remote -s: rc 0" [ "$rc" -eq 0 ]
check "remote -s: exactly one source snapshot, taken over ssh" \
    bash -c "[ \"\$(grep -c '^RZFS snapshot  *tank/vm-100-disk-0@lab_' '$TRACE')\" -eq 1 ] && [ \"\$(grep -c '^R\\?ZFS snapshot' '$TRACE')\" -eq 1 ]"
check "remote -s: no send/recv/hold/bookmark/destroy/rollback/mbuffer/compressor" no_transfer
check "remote -s: nothing at all asked of zfs/zpool on THIS host (no target probe)" no_local_zfs
check "remote -s: stats say snapshot_only with no target, never success" \
    bash -c "grep -q '\"status\":\"snapshot_only\"' '$WORK/stats.log' && grep -q '\"target\":\"\"' '$WORK/stats.log' && ! grep -q '\"status\":\"success\"' '$WORK/stats.log'"
check "remote -s: the log says nothing was transferred" \
    bash -c "printf '%s' \"\$1\" | grep -q 'nothing transferred'" _ "$out"
# tank/vm-100-disk-0 has no children here, so use one that has: the pull's
# warning says the children "are NOT" sent, a transfer claim (live proof).
reset_world
run -- -s -m lab_ root@pve1:tank/vm-101-disk-0
check "remote -s on a dataset with children: rc 0, no 'being sent' warning" \
    bash -c "[ $rc -eq 0 ] && ! printf '%s' \"\$1\" | grep -q 'being sent'" _ "$out"

# ---- 2. local source -----------------------------------------------------
reset_world
run -- -s -m lab_ tank/vm-100-disk-0
check "local -s: rc 0, one local snapshot, no ssh" \
    bash -c "[ $rc -eq 0 ] && [ \"\$(grep -c '^ZFS snapshot' '$TRACE')\" -eq 1 ] && ! grep -q '^SSH' '$TRACE'"
check "local -s: no transfer operations" no_transfer

# ---- 3. -r: one atomic recursive snapshot --------------------------------
reset_world
run -- -s -r -m lab_ root@pve1:tank/vm-101-disk-0
check "-s -r: rc 0 and ONE 'zfs snapshot -r' on the parent" \
    bash -c "[ $rc -eq 0 ] && [ \"\$(grep -c '^R\\?ZFS snapshot' '$TRACE')\" -eq 1 ] && grep -q '^RZFS snapshot -r tank/vm-101-disk-0@lab_' '$TRACE'"
check "-s -r: no transfer operations" no_transfer

# ---- 4. -R with -X and -S: the filtered set, one run suffix ----------------
reset_world
run -- -s -R -S -X skipme -m lab_ root@pve1:tank
check "-s -R -S -X: rc 0" [ "$rc" -eq 0 ]
check "-s -R -S -X: snapshots exactly the three selected descendants" \
    bash -c "s=\$(grep '^RZFS snapshot' '$TRACE' | sed 's/@.*//; s/^RZFS snapshot  *//' | sort | tr '\n' ' '); [ \"\$s\" = 'tank/vm-100-disk-0 tank/vm-101-disk-0 tank/vm-101-disk-0/extra ' ]"
check "-s -R: one run suffix for the whole set" \
    bash -c "[ \"\$(grep '^RZFS snapshot' '$TRACE' | sed 's/.*@//' | sort -u | wc -l)\" -eq 1 ]"
check "-s -R: no transfer operations, no local zfs" bash -c "! grep -Eq 'ZFS (send|recv|hold|destroy|rollback|bookmark)|^MBUFFER|^(ZFS|ZPOOL) ' '$TRACE'"

# ---- 5. a failed source listing under -R ----------------------------------
reset_world
run ZFS_LIST_FAIL=1 -- -s -R -m lab_ root@pve1:tank
check "-s -R, listing fails: rc nonzero, NO snapshot, the failure named" \
    bash -c "[ $rc -ne 0 ] && ! grep -q 'ZFS snapshot' '$TRACE' && printf '%s' \"\$1\" | grep -q 'expanding -R over the descendants'" _ "$out"

# ---- 6. per-member failure reaches the exit status ------------------------
reset_world
run ZFS_SNAP_FAIL=tank/vm-101-disk-0 -- -s -R -m lab_ root@pve1:tank
check "-s -R, one member's snapshot fails: rc 1" [ "$rc" -eq 1 ]
check "-s -R, one member fails: the source diagnostic is in the output" \
    bash -c "printf '%s' \"\$1\" | grep -q 'permission denied' && printf '%s' \"\$1\" | grep -q 'FAILED to create tank/vm-101-disk-0@'" _ "$out"
check "-s -R, one member fails: the others were still attempted, stats tell them apart" \
    bash -c "[ \"\$(grep -c '\"status\":\"snapshot_only_failed\"' '$WORK/stats.log')\" -eq 1 ] && [ \"\$(grep -c '\"status\":\"snapshot_only\"' '$WORK/stats.log')\" -ge 3 ]"

# ---- 7. unreachable source and a disabled pair gate -------------------------
reset_world
run SSH_UNREACH=1 -- -s -m lab_ root@pve1:tank/vm-100-disk-0
check "-s, unreachable source: rc nonzero, no snapshot, no snapshot_only stat" \
    bash -c "[ $rc -ne 0 ] && ! grep -q 'ZFS snapshot' '$TRACE' && ! grep -q '\"status\":\"snapshot_only\"' '$WORK/stats.log' 2>/dev/null"
reset_world
run SSH_GATE_REFUSE=1 -- -s -m lab_ root@pve1:tank/vm-100-disk-0
check "-s, peer gate disabled: rc nonzero and no snapshot" bash -c "[ $rc -ne 0 ] && ! grep -q 'ZFS snapshot' '$TRACE'"
check "-s, peer gate disabled: said as a refusal, not a missing dataset" \
    bash -c "printf '%s' \"\$1\" | grep -qi 'refuses\|disabled'" _ "$out"
reset_world
run SSH_GATE_REFUSE=1 -- -n -s -m lab_ root@pve1:tank/vm-100-disk-0
check "-n -s, peer gate disabled: no success plan" \
    bash -c "[ $rc -ne 0 ] && ! printf '%s' \"\$1\" | grep -q 'PLAN=SNAPSHOT-ONLY'" _ "$out"

# ---- 8. -L pause --------------------------------------------------------
reset_world
mkdir -p "$WORK/rel/clu"; printf 'PAUSED_AT=x\n' > "$WORK/rel/clu/paused"
run -- -s -L clu -m lab_ root@pve1:tank/vm-100-disk-0
check "-s -L paused: rc 0, SKIPPED, nothing traced, skipped_paused" \
    bash -c "[ $rc -eq 0 ] && printf '%s' \"\$1\" | grep -q 'SKIPPED: relationship clu is paused' && [ ! -s '$TRACE' ] && grep -q skipped_paused '$WORK/stats.log'" _ "$out"
rm -rf "$WORK/rel/clu"

# ---- 9. dry run ---------------------------------------------------------
reset_world
run -- -n -s -R -S -m lab_ root@pve1:tank/vm-101-disk-0
check "-n -s -R: rc 0 and one PLAN=SNAPSHOT-ONLY line per selected dataset" \
    bash -c "[ $rc -eq 0 ] && [ \"\$(printf '%s\n' \"\$1\" | grep -c '^PLAN=SNAPSHOT-ONLY src=')\" -eq 1 ] && printf '%s\n' \"\$1\" | grep -qx 'PLAN=SNAPSHOT-ONLY src=tank/vm-101-disk-0/extra'" _ "$out"
check "-n -s: creates nothing, no quiesce, no transfer, no local zfs (only read-only source discovery)" \
    bash -c "! grep -Eq 'ZFS (snapshot|send|recv|hold|destroy|rollback|bookmark)|QUIESCE-WINDOW|^MBUFFER|^(ZFS|ZPOOL) ' '$TRACE' && ! grep -Eq '^SSH [^ ]+ (zfs (snapshot|destroy|hold|rollback))' '$TRACE'"
check "-n -s: no stats record claims work was done" bash -c "[ ! -s '$WORK/stats.log' ]"
reset_world
run -- -n -s -m lab_ root@pve1:tank/nope
check "-n -s, source missing: rc nonzero, no plan" \
    bash -c "[ $rc -ne 0 ] && ! printf '%s' \"\$1\" | grep -q 'PLAN='" _ "$out"

# ---- 10. refusals: before ANY ssh, quiesce or snapshot ----------------------
for _flag in "-e" "-t" "-M" "-f" "-F" "-z" "-N" "-A" "-b 2M" "-H" "-i" "-w" "-U" "-u" "-x mountpoint" "-o -c" "-E foo" "-T 3" "-l 3" "-g" "-Z"; do
    reset_world
    # shellcheck disable=SC2086
    run -- -s $_flag -m lab_ root@pve1:tank/vm-100-disk-0
    check "-s $_flag: refused, rc 1, with nothing traced" \
        bash -c "[ $rc -eq 1 ] && [ ! -s '$TRACE' ] && printf '%s' \"\$1\" | grep -q -- '-s (snapshot-only) transfers nothing'" _ "$out"
done
reset_world
run -- -s -M -m lab_ -q agent root@pve1:tank/vm-100-disk-0
check "-s -M with -q: refused before the quiesce window and before any mirror" \
    bash -c "[ $rc -eq 1 ] && [ ! -s '$TRACE' ] && printf '%s' \"\$1\" | grep -q -- '-M cannot apply'" _ "$out"
reset_world
run -- -s -m lab_ root@pve1:tank/vm-100-disk-0 backup/base
check "-s with a target argument: refused, nothing traced" \
    bash -c "[ $rc -eq 1 ] && [ ! -s '$TRACE' ] && printf '%s' \"\$1\" | grep -q 'exactly one argument'" _ "$out"
reset_world
mkdir -p "$WORK/rel/clu"; printf 'PAUSED_AT=x\n' > "$WORK/rel/clu/paused"
run -- -s -M -L clu -m lab_ root@pve1:tank/vm-100-disk-0
check "-s -M on a PAUSED label: still refused (rc 1), not a quiet SKIPPED" \
    bash -c "[ $rc -eq 1 ] && [ ! -s '$TRACE' ] && ! printf '%s' \"\$1\" | grep -q SKIPPED && printf '%s' \"\$1\" | grep -q -- '-M cannot apply'" _ "$out"
rm -rf "$WORK/rel/clu"

# ---- 11. no mbuffer, no compressor anywhere on PATH --------------------------
reset_world
RUN_PATH="$NODEP_PATH" run -- -m lab_ root@pve1:tank/vm-100-disk-0 backup
check "control: on this PATH an ordinary pull refuses for missing mbuffer (the hiding works)" \
    bash -c "[ $rc -ne 0 ] && printf '%s' \"\$1\" | grep -q \"'mbuffer' not found\"" _ "$out"
reset_world
RUN_PATH="$NODEP_PATH" run -- -s -m lab_ root@pve1:tank/vm-100-disk-0
check "-s with no mbuffer/zstd/pigz on PATH: rc 0, one snapshot" \
    bash -c "[ $rc -eq 0 ] && [ \"\$(grep -c '^RZFS snapshot' '$TRACE')\" -eq 1 ]"
check "-s on a remote source: no compression default announced" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'Compression: zstd'" _ "$out"

# ---- 12. quiesce ------------------------------------------------------------
reset_world
run SSH_QUIESCE_RC=0 -- -s -q agent -m lab_ root@pve1:tank/vm-100-disk-0
check "-s -q, clean window: rc 0" [ "$rc" -eq 0 ]
check "-s -q, clean window: the window's snapshot is the only one (no second create)" \
    bash -c "grep -q '^QUIESCE-WINDOW' '$TRACE' && ! grep -q 'ZFS snapshot' '$TRACE'"
check "-s -q, clean window: one snapshot_only stat, no transfer" \
    bash -c "[ \"\$(grep -c '\"status\":\"snapshot_only\"' '$WORK/stats.log')\" -eq 1 ] && ! grep -Eq 'ZFS (send|recv|hold)|^MBUFFER' '$TRACE'"
reset_world
run SSH_QUIESCE_RC=5 -- -s -q agent -m lab_ root@pve1:tank/vm-100-disk-0
check "-s -q, degradable failure (default): rc 8" [ "$rc" -eq 8 ]
check "-s -q, degraded: the window first, then ONE crash-labelled snapshot" \
    bash -c "w=\$(grep -n '^QUIESCE-WINDOW' '$TRACE' | cut -d: -f1); s=\$(grep -n '^RZFS snapshot' '$TRACE' | cut -d: -f1); [ -n \"\$w\" ] && [ \"\$(grep -c '^RZFS snapshot' '$TRACE')\" -eq 1 ] && [ \"\$s\" -gt \"\$w\" ] && grep -q '^RZFS snapshot .*_crash_' '$TRACE'"
reset_world
run SSH_QUIESCE_RC=5 -- -s -q agent,strict -m lab_ root@pve1:tank/vm-100-disk-0
check "-s -q ,strict failure: rc 1 and NO unquiesced fallback snapshot" \
    bash -c "[ $rc -eq 1 ] && grep -q '^QUIESCE-WINDOW' '$TRACE' && ! grep -q 'ZFS snapshot' '$TRACE'"
reset_world
run -- -s -q agent -m lab_ tank/vm-100-disk-0
check "-s -q on a LOCAL source: refused, nothing snapshotted" \
    bash -c "[ $rc -eq 1 ] && ! grep -q 'ZFS snapshot' '$TRACE'"
reset_world
run -- -n -s -q agent -m lab_ tank/vm-100-disk-0
check "-n -s -q on a LOCAL source: refused too, no plan" \
    bash -c "[ $rc -eq 1 ] && ! printf '%s' \"\$1\" | grep -q 'PLAN='" _ "$out"

# ---- 13. the ordinary pull is untouched ---------------------------------------
reset_world
run -- -n -m lab_ root@pve1:tank/vm-100-disk-0 backup
check "no -s: a dry pull still plans a transfer (PLAN=FULL/INCREMENTAL), and does probe the local target" \
    bash -c "printf '%s\n' \"\$1\" | grep -Eq '^PLAN=(FULL|INCREMENTAL) base=[^ ]+ src=tank/vm-100-disk-0 tgt=backup/tank/vm-100-disk-0\$' && grep -q '^ZFS ' '$TRACE'" _ "$out"

echo
echo "snaponly: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
