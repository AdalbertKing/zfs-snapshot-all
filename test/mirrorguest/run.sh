#!/bin/bash
# snapget -M must pass the live-guest gate before any destroy, also when the
# newest source snapshot is ALREADY on the target (REV-20261017-150, P0).
#
# That path returns success from process_dataset before its own
# guest_disk_is_live call, and the main loop then ran mirror_target, which
# destroyed target-only snapshots under a RUNNING guest, rc 0.
#
# Drives the REAL snapget.sh CLI. zfs/zpool/ssh/qm are stubs that append every
# call to a trace; the snapshot "database" is a file: <side> <ds>@<snap> <guid>
# (R = source, L = this host). Fixture: source has @base, the target has @old
# and @base, the same GUID -- the already-present path. The guest config lives
# in a fake QUIESCE_PVE_DIR.
#
# Without root, ZFS or a network.
#
#   ./test/mirrorguest/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
[ -r "$SNAPGET" ] || { echo "cannot read $SNAPGET" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
check() {   # <name> <condition-command...>
    local name="$1"; shift
    if "$@"; then ok "$name"; else bad "$name" "rc=$rc" "--- out:" "$out" "--- trace:" "$(cat "$TRACE" 2>/dev/null)"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bin"
mkdir -p "$B" "$WORK/pve/qemu-server"
TRACE="$WORK/trace"
SNAPDB="$WORK/snaps"
export TRACE SNAPDB

cat > "$B/zfs" <<'EOF'
#!/bin/bash
side=L; [ -n "${REMOTE_SIDE:-}" ] && side=R
echo "${side}ZFS $*" >> "$TRACE"
last="${*: -1}"
case "$1" in
    list)
        case " $* " in
            *" -t snapshot "*)
                awk -v s="$side" -v d="$last" '$1==s && index($2, d "@")==1 {print $2}' "$SNAPDB"; exit 0 ;;
            *" -t bookmark "*) exit 0 ;;
        esac
        awk -v d="$last" '{split($2,a,"@"); if (a[1]==d) f=1} END {exit !f}' "$SNAPDB" && { echo "$last"; exit 0; }
        exit 1 ;;
    get)
        case " $* " in
            *" guid "*) awk -v s="$side" -v n="$last" '$1==s && $2==n {print $3}' "$SNAPDB"; exit 0 ;;
            *" encryption "*) echo off; exit 0 ;;
            *" written"*) echo 0; exit 0 ;;
        esac
        echo "-"; exit 0 ;;
    destroy) echo "DESTROYED $last" >> "$TRACE"; exit 0 ;;
esac
exit 0
EOF
cat > "$B/zpool" <<'EOF'
#!/bin/bash
echo "ZPOOL $*" >> "$TRACE"; echo ONLINE
EOF
cat > "$B/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in -n|-T) shift ;; -o|-p|-i|-c|-O|-l) shift 2 ;; -*) shift ;; *) break ;; esac
done
dest="$1"; shift; cmd="$*"
[ -n "$cmd" ] || exit 0
echo "SSH $dest $cmd" >> "$TRACE"
case "$cmd" in
    *machine-id*) echo remote-machine-id; exit 0 ;;
    "hostname -f") echo remote.example; exit 0 ;;
esac
REMOTE_SIDE=1 bash -c "$cmd"
EOF
cat > "$B/qm" <<'EOF'
#!/bin/bash
echo "QM $*" >> "$TRACE"
case "$1" in
    status) [ "${QM_FAIL:-0}" = 1 ] && exit 1; echo "status: ${QM_STATE:-running}"; exit 0 ;;
esac
exit 0
EOF
for _t in mbuffer zstd pigz; do printf '#!/bin/bash\ncat\n' > "$B/$_t"; done
command -v flock >/dev/null 2>&1 || printf '#!/bin/bash\nexit 0\n' > "$B/flock"
printf '#!/bin/bash\nexit 0\n' > "$B/logger"
chmod +x "$B"/*
echo "scsi0: local-zfs:vm-100-disk-0,size=1G" > "$WORK/pve/qemu-server/100.conf"

N=0
# run <dataset> [ENV=...] -- sets rc, out; one lock dir per call
run() {
    local ds="$1"; shift
    N=$((N + 1)); mkdir -p "$WORK/lock$N"
    : > "$TRACE"
    printf 'R %s@base 111\nL %s@old 222\nL %s@base 111\n' "$ds" "$ds" "$ds" > "$SNAPDB"
    out=$(env "$@" PATH="$B:$PATH" QUIESCE_PVE_DIR="$WORK/pve" STATS_LOG="$WORK/stats" \
          LOCKDIR="$WORK/lock$N" NOTIFY_SCRIPT=/bin/true HOME="$WORK" RELATIONSHIPS_DIR="$WORK/rel" \
          bash "$SNAPGET" -N -M -e "root@source:$ds" 2>&1); rc=$?
}
no_destroy()  { ! grep -q '^LZFS destroy\|^DESTROYED' "$TRACE"; }
asked_guest() { grep -q '^QM status 100' "$TRACE"; }
already()     { ! grep -q 'ZFS send\|ZFS recv\|ZFS receive' "$TRACE"; }

run tank/vm-100-disk-0 QM_STATE=running
check "running guest, snapshot already present: rc nonzero" [ "$rc" -ne 0 ]
check "running guest: the guest status WAS asked (qm status 100)" asked_guest
check "running guest: NO zfs destroy at all" no_destroy
check "running guest: the mirror says it refused" \
    bash -c "printf '%s' \"\$1\" | grep -q 'Mirror (-M) on .tank/vm-100-disk-0.: refused'" _ "$out"
check "running guest: it was the already-present path (no send/recv)" already

run tank/vm-100-disk-0 QM_FAIL=1
check "unknown guest status: rc nonzero, asked, NO destroy" \
    bash -c "[ $rc -ne 0 ] && grep -q '^QM status 100' '$TRACE' && ! grep -q '^LZFS destroy\|^DESTROYED' '$TRACE'"
check "unknown guest status: says it could not determine the guest's state" \
    bash -c "printf '%s' \"\$1\" | grep -q 'could not determine whether that guest is running'" _ "$out"

run tank/vm-100-disk-0 QM_STATE=stopped
check "control, stopped guest: rc 0, asked, exactly @old destroyed" \
    bash -c "[ $rc -eq 0 ] && grep -q '^QM status 100' '$TRACE' && [ \"\$(grep -c '^DESTROYED' '$TRACE')\" -eq 1 ] && grep -qx 'DESTROYED tank/vm-100-disk-0@old' '$TRACE'"

run tank/data QM_STATE=running
check "control, dataset that names no guest: rc 0, no guest query, exactly @old destroyed" \
    bash -c "[ $rc -eq 0 ] && ! grep -q '^QM ' '$TRACE' && [ \"\$(grep -c '^DESTROYED' '$TRACE')\" -eq 1 ] && grep -qx 'DESTROYED tank/data@old' '$TRACE'"

# LOCAL source (2026-10-20, the local copy on snapget): the target is a copy
# nested under the target base, so a target NAMED after a running guest is not
# that guest's disk -- the guest's disk is the source. Measured on pve10: a
# local copy of running CT 950 was refused as "the disk of guest 950". On main
# this case refuses; the remote cases above keep refusing.
N=$((N + 1)); mkdir -p "$WORK/lock$N"; : > "$TRACE"
printf 'L tank/vm-100-disk-0@base 111\nL tank/vm-100-disk-0@new 333\nL back/tank/vm-100-disk-0@base 111\n' > "$SNAPDB"
out=$(env QM_STATE=running PATH="$B:$PATH" QUIESCE_PVE_DIR="$WORK/pve" STATS_LOG="$WORK/stats" \
      LOCKDIR="$WORK/lock$N" NOTIFY_SCRIPT=/bin/true HOME="$WORK" RELATIONSHIPS_DIR="$WORK/rel" \
      bash "$SNAPGET" -N -e "tank/vm-100-disk-0" "back" 2>&1); rc=$?
check "local source, target named after a RUNNING guest: not refused as that guest's disk" \
    bash -c "! printf '%s' \"\$1\" | grep -q 'is the disk of guest'" _ "$out"
check "local source: the copy is received" bash -c "grep -q '^LZFS recv\|^LZFS receive' '$TRACE'"

echo
echo "mirrorguest: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
