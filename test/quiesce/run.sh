#!/bin/bash
# Unit tests for the quiesce (-q) bookkeeping in lib-zfs-snap.sh.
#
# No Proxmox, no ZFS, no root, no running guest -- so this runs on the dev box as
# well as the hosts. That is deliberate: the parts of quiescing that can silently
# go wrong are all decisions, not mechanisms. Which guest a dataset belongs to,
# whether a guest is handled twice, and which datasets a recursive job even looks
# at were each responsible for a real defect, and none of them needs a hypervisor
# to test.
#
# What is NOT covered here, and cannot be: the freeze itself. `qm guest cmd` and
# `pct exec` need real running guests, and the only ones available are production
# -- those paths are verified by hand, with the operator's go-ahead, and the
# results live in the project memory rather than in an assertion.
#
# Usage: ./run.sh     (override the library under test with LIB=)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-zfs-snap.sh}"
[ -r "$LIB" ] || { echo "cannot read lib-zfs-snap.sh at $LIB" >&2; exit 1; }

VERBOSE=0
SSH_OPTS=()
# shellcheck disable=SC1090
source "$LIB"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
check() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        echo "PASS $desc"; PASS=$((PASS+1))
    else
        echo "FAIL $desc"; echo "     want: [$want]"; echo "     got:  [$got]"; FAIL=$((FAIL+1))
    fi
}

# --- quiesce_guest_id -------------------------------------------------------
# The Proxmox naming convention IS the dataset-to-guest mapping; there is no
# property to ask. So this parser is the whole mapping.

check "id: VM disk"                 "107" "$(quiesce_guest_id hdd/data/vm-107-disk-2)"
check "id: container subvol"        "102" "$(quiesce_guest_id hdd/lxc/subvol-102-disk-0)"
check "id: deep path"               "100" "$(quiesce_guest_id rpool/data/nested/vm-100-disk-0)"
check "id: bare leaf, no pool"      "101" "$(quiesce_guest_id vm-101-disk-0)"
check "id: multi-digit id"        "12345" "$(quiesce_guest_id rpool/data/vm-12345-disk-0)"

# The parent of a recursive job. Returning an id here would attach every guest
# job to whatever number happened to appear in a pool name.
quiesce_guest_id rpool/data >/dev/null
check "id: a parent dataset owns no guest" "1" "$?"
quiesce_guest_id hdd/backups/pve1 >/dev/null
check "id: a backup store owns no guest" "1" "$?"
# A RECEIVED copy has the same leaf name as the original. It must still parse --
# the guard against acting on it is that the guest does not exist on this node,
# checked separately by quiesce_guest_kind, not that the name is unrecognised.
check "id: a replica leaf parses like the original" "100" \
      "$(quiesce_guest_id hdd/backups/pve1/rpool/data/vm-100-disk-0)"
quiesce_guest_id hdd/mssql >/dev/null
check "id: an ordinary dataset owns no guest" "1" "$?"
quiesce_guest_id hdd/data/vm-107-disk >/dev/null
check "id: a near-miss name is rejected" "1" "$?"

# --- quiesce_scope ----------------------------------------------------------
# A recursive job names a PARENT, whose own name matches no guest. Expanding it
# is what makes -q work on the jobs that cover the most machines.

check "scope: without -r, just the dataset itself" "rpool/data" \
      "$(quiesce_scope rpool/data 0)"
check "scope: default is non-recursive" "rpool/data" \
      "$(quiesce_scope rpool/data)"

mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/sh
# Stands in for `zfs list -H -o name -r <ds>`: the parent, then two guest disks.
for a in "$@"; do last=$a; done
echo "$last"
echo "$last/vm-107-disk-0"
echo "$last/vm-107-disk-1"
STUB
chmod +x "$TMPD/bin/zfs"
PATH="$TMPD/bin:$PATH"

check "scope: with -r, the children too" "3" \
      "$(quiesce_scope rpool/data 1 | wc -l | tr -d ' ')"
check "scope: with -r, the guest disks are in there" "2" \
      "$(quiesce_scope rpool/data 1 | grep -c 'vm-107-disk')"

# --- dedup ------------------------------------------------------------------
# Quiescing is a property of the GUEST, not the disk. Freezing a VM twice would
# need thawing it twice, and re-syncing a container only widens the gap between
# the flush and the snapshot. Driven through quiesce_freeze with a stubbed
# Proxmox so no hypervisor is needed.

cat > "$TMPD/bin/qm" <<'STUB'
#!/bin/sh
# Argument positions matter and are easy to get wrong: it is `qm status <id>`
# but `qm guest cmd <id> <verb>`, so the verb is $4, not $3. Reading the wrong
# one makes the stub answer nothing, the freeze silently fail, and the test look
# like a code bug -- which is exactly what happened the first time.
case "$1" in
  status) echo "status: running" ;;
  guest)
    case "$4" in
      fsfreeze-status) echo thawed ;;
      fsfreeze-freeze) echo 2 ;;
      fsfreeze-thaw)   echo 2 ;;
    esac ;;
esac
STUB
cat > "$TMPD/bin/pct" <<'STUB'
#!/bin/sh
case "$1" in status) echo "status: running" ;; esac
STUB
chmod +x "$TMPD/bin/qm" "$TMPD/bin/pct"

# quiesce_guest_kind reads /etc/pve, so point it at a fake tree.
FAKE_PVE="$TMPD/pve"
mkdir -p "$FAKE_PVE/qemu-server" "$FAKE_PVE/lxc"
: > "$FAKE_PVE/qemu-server/107.conf"
quiesce_guest_kind() {
    [ -f "$FAKE_PVE/qemu-server/${1}.conf" ] && { printf 'qemu'; return 0; }
    [ -f "$FAKE_PVE/lxc/${1}.conf" ] && { printf 'lxc'; return 0; }
    return 1
}

QUIESCE_HANDLED=()
QUIESCE_FROZEN=()
quiesce_freeze hdd/data/vm-107-disk-0 auto
quiesce_freeze hdd/data/vm-107-disk-1 auto
quiesce_freeze hdd/data/vm-107-disk-2 auto
check "dedup: three disks of one VM freeze it once" "1" "${#QUIESCE_FROZEN[@]}"
check "dedup: the guest is recorded once" "1" "${#QUIESCE_HANDLED[@]}"
check "dedup: and it is the right one" "qemu:107" "${QUIESCE_FROZEN[0]:-<pusto>}"

quiesce_thaw_all
check "thaw: the frozen list is emptied" "0" "${#QUIESCE_FROZEN[@]}"
check "thaw: the handled list is emptied too, so a second run is clean" "0" "${#QUIESCE_HANDLED[@]}"

# A dataset owning no guest must not consume a slot or fail.
QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
quiesce_freeze rpool/data auto
check "no guest: nothing frozen" "0" "${#QUIESCE_FROZEN[@]}"
quiesce_freeze hdd/data/vm-107-disk-0 no
check "mode 'no': nothing frozen even for a real guest" "0" "${#QUIESCE_FROZEN[@]}"

# Wrong mode for the guest type (sync on a VM): says so and freezes nothing. Note
# the guest IS marked handled first -- dedup happens as soon as the owner is
# known. That is harmless because -q is one CLI flag for the whole run, so no
# second dataset can arrive with a mode that would have fitted.
QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
quiesce_freeze hdd/data/vm-107-disk-0 sync
check "wrong mode: a VM is not sync-quiesced" "0" "${#QUIESCE_FROZEN[@]}"

# ---- the REMOTE script's privilege routing --------------------------------
#
# $ZFS_REMOTE_QUIESCE_SCRIPT runs on the SOURCE host, as whatever account the
# pairing gave us. It picks its route once, up front: root uses qm/pct directly,
# a delegated account goes through zfs-quiesce-helper over sudo. Getting that
# wrong is not a cosmetic bug -- routing a delegated run at qm means the freeze
# never happens, and if the DEADMAN were routed wrong a production guest would
# stay frozen. Both are tested here with stubs; the real thing needs a PVE host
# (manual:quiesce-helper-live).
RQ_D="$TMPD/remote"; mkdir -p "$RQ_D/bin"
printf '%s' "$ZFS_REMOTE_QUIESCE_SCRIPT" > "$RQ_D/rq.sh"
# A real script body, not an empty file: the remote script gates on [ -x ], and
# on MSYS an empty file is not considered executable -- which would make this
# test pass for the wrong reason on Linux and fail for the wrong reason here.
# It is never executed directly; the sudo stub answers for it.
printf '#!/bin/sh\nexit 0\n' > "$RQ_D/helper"; chmod +x "$RQ_D/helper"
sed -i "s#^QHELPER=/usr/local/sbin/zfs-quiesce-helper#QHELPER=$RQ_D/helper#" "$RQ_D/rq.sh"

cat > "$RQ_D/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$TRACE"
[ "$1" = "-n" ] && shift
shift   # the helper path
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          echo "id=$2 kind=qemu running=yes frozen=no"; exit 0 ;;
  freeze|thaw) exit 0 ;;
esac
exit 1
EOF
# qm must never be reached by a delegated run: it would fail anyway, but the
# point is that the code did not even try the privileged path.
printf '#!/bin/bash\necho "qm $*" >> "$TRACE"\nexit 1\n'  > "$RQ_D/bin/qm"
printf '#!/bin/bash\necho "zfs $*" >> "$TRACE"\nexit 0\n' > "$RQ_D/bin/zfs"
printf '#!/bin/bash\nexit 0\n'                            > "$RQ_D/bin/setsid"
chmod +x "$RQ_D/bin/"*

rq_run() {
    TRACE="$RQ_D/trace" PATH="$RQ_D/bin:$PATH" \
        bash "$RQ_D/rq.sh" agent 30 "" 1 rpool/data/vm-100-disk-0 \
             1 rpool/data/vm-100-disk-0@t 2>&1
}

: > "$RQ_D/trace"
out=$(rq_run); rc=$?
check "remote: a delegated run completes through the helper" "0" "$rc"
case "$(cat "$RQ_D/trace")" in
    *"helper freeze 100"*) check "remote: freeze goes through the helper" "y" "y" ;;
    *) check "remote: freeze goes through the helper" "y" "n ($out)" ;;
esac
case "$(cat "$RQ_D/trace")" in
    *"helper thaw 100"*) check "remote: thaw goes through the helper" "y" "y" ;;
    *) check "remote: thaw goes through the helper" "y" "n" ;;
esac
if grep -q '^qm ' "$RQ_D/trace"; then
    check "remote: a delegated run never calls qm" "y" "n ($(grep '^qm ' "$RQ_D/trace" | head -1))"
else
    check "remote: a delegated run never calls qm" "y" "y"
fi

# No helper and not root: must refuse with 3 (the privilege code), BEFORE
# anything is frozen. Silently taking a crash-consistent snapshot instead is
# the exact outcome -q exists to prevent.
rm -f "$RQ_D/helper"   # gone entirely: not root, no helper
: > "$RQ_D/trace"
out=$(rq_run); rc=$?
check "remote: refuses (3) when it can neither be root nor use the helper" "3" "$rc"
case "$out" in
    *"--allow-quiesce"*) check "remote: the refusal names the fix" "y" "y" ;;
    *) check "remote: the refusal names the fix" "y" "n ($out)" ;;
esac

# ---- REV-20260730-006 §5: the ERROR branches -------------------------------
#
# The happy path and the SIGKILL+deadman case were verified live, but every
# branch below was fail-OPEN: a freeze that failed printed QERR, the run
# snapshotted anyway and exited 0. An operator who asked for
# application-consistent got crash-consistent and was told it worked. These are
# deterministic, so they belong here rather than in a live run.
#
# Each case re-stubs qm/pct/setsid and asserts on the TRACE: what matters is not
# only the exit code but whether `zfs snapshot` was reached at all.

rq_reset() {   # rq_reset <qm-body>
    : > "$RQ_D/trace"
    printf '#!/bin/bash\necho "qm $*" >> "$TRACE"\n%s\n' "$1" > "$RQ_D/bin/qm"
    printf '#!/bin/bash\nexit 0\n' > "$RQ_D/bin/setsid"
    printf '#!/bin/sh\nexit 0\n' > "$RQ_D/helper"
    chmod +x "$RQ_D/bin/qm" "$RQ_D/bin/setsid" "$RQ_D/helper"
}
rq_snapshotted() { grep -q '^zfs snapshot' "$RQ_D/trace" && echo yes || echo no; }

# The sudo stub drives the guest's behaviour, since a delegated run reaches the
# guest only through the helper. QSTATE/QFREEZE/QTHAW steer it per case.
cat > "$RQ_D/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$TRACE"
[ "$1" = "-n" ] && shift
shift
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          echo "id=$2 kind=${QKIND:-qemu} running=yes frozen=${QFROZEN:-no}"; exit 0 ;;
  freeze) exit "${QFREEZE:-0}" ;;
  thaw)   exit "${QTHAW:-0}" ;;
esac
exit 1
EOF
chmod +x "$RQ_D/bin/sudo"

rq_run2() {   # rq_run2 <mode> -- env steers the stubs
    TRACE="$RQ_D/trace" PATH="$RQ_D/bin:$PATH" \
        bash "$RQ_D/rq.sh" "${1:-agent}" 30 "" 1 rpool/data/vm-100-disk-0 \
             1 rpool/data/vm-100-disk-0@t 2>&1
}

# 1. freeze fails -> no snapshot.
rq_reset 'exit 0'
out=$(QFREEZE=1 rq_run2); rc=$?
check "err1: a failed freeze does not snapshot" "no" "$(rq_snapshotted)"
check "err1: and the run fails (5)" "5" "$rc"

# 2. the guest was already frozen -> no snapshot, and it is left alone.
rq_reset 'exit 0'
out=$(QFROZEN=yes rq_run2); rc=$?
check "err2: an already-frozen guest does not snapshot" "no" "$(rq_snapshotted)"
check "err2: and the run fails (5)" "5" "$rc"
case "$out" in *"ALREADY frozen"*) check "err2: and says why" "y" "y" ;;
   *) check "err2: and says why" "y" "n ($out)" ;; esac

# 3. no setsid -> nothing is frozen at all. The deadman is the whole safety
#    argument for freezing a production guest over a network.
#    Making setsid absent has to work in two different worlds, and the obvious
#    tricks fail in one each: emptying PATH takes mktemp with it (rc=127), and
#    copying the coreutils binaries into a private dir gives unusable .exe
#    stubs on MSYS. So: MSYS has no setsid at all, and removing our own stub is
#    enough; on Linux it does exist, and a symlink-only PATH excludes it while
#    keeping everything the script needs.
rq_reset 'exit 0'
rm -f "$RQ_D/bin/setsid"
if command -v setsid >/dev/null 2>&1; then
    MIN="$RQ_D/minbin"; mkdir -p "$MIN"
    for t in id mktemp cat rm tr sleep grep logger bash; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$MIN/$t"
    done
    cp "$RQ_D/bin/sudo" "$RQ_D/bin/qm" "$RQ_D/bin/zfs" "$MIN/"
    chmod +x "$MIN/sudo" "$MIN/qm" "$MIN/zfs"
    RQ_PATH="$MIN"
else
    RQ_PATH="$RQ_D/bin:$PATH"
fi
out=$(TRACE="$RQ_D/trace" PATH="$RQ_PATH" bash "$RQ_D/rq.sh" agent 30 "" \
          1 rpool/data/vm-100-disk-0 1 rpool/data/vm-100-disk-0@t 2>&1); rc=$?
check "err3: without setsid the run refuses (3)" "3" "$rc"
# REV-20260731-007 §2 F2 asks specifically for proof that no freeze CALL
# happens -- not merely that the log lacks the word. The trace is the evidence:
# every helper invocation is recorded there by the sudo stub.
if grep -qE 'freeze [0-9]+$' "$RQ_D/trace"; then
    check "err3: and issues no freeze call at all" "y" "n ($(grep -E 'freeze' "$RQ_D/trace" | head -1))"
else
    check "err3: and issues no freeze call at all" "y" "y"
fi

# 4. thaw fails -> the id STAYS in the deadman's file and the run is an error.
#    Before the fix the file was wiped unconditionally, so the deadman saw
#    nothing to do precisely when a guest was left frozen.
rq_reset 'exit 0'
out=$(QTHAW=1 rq_run2); rc=$?
check "err4: a failed thaw fails the run (6)" "6" "$rc"
case "$out" in *"STILL FROZEN"*) check "err4: and names the manual command" "y" "y" ;;
   *) check "err4: and names the manual command" "y" "n ($out)" ;; esac
case "$out" in *"deadman is left running"*) check "err4: and keeps the deadman armed" "y" "y" ;;
   *) check "err4: and keeps the deadman armed" "y" "n" ;; esac

# 5. the snapshot itself fails -> the trap still thaws.
rq_reset 'exit 0'
printf '#!/bin/bash\necho "zfs $*" >> "$TRACE"\nexit 1\n' > "$RQ_D/bin/zfs"
chmod +x "$RQ_D/bin/zfs"
out=$(rq_run2); rc=$?
check "err5: a failed snapshot is reported (4)" "4" "$rc"
case "$out" in *"thawed VM 100"*) check "err5: and the guest is thawed anyway" "y" "y" ;;
   *) check "err5: and the guest is thawed anyway" "y" "n ($out)" ;; esac
printf '#!/bin/bash\necho "zfs $*" >> "$TRACE"\nexit 0\n' > "$RQ_D/bin/zfs"
chmod +x "$RQ_D/bin/zfs"

# 6. a mode the guest cannot honour is a failure, not a note: the quiesce the
#    operator asked for is not going to happen.
rq_reset 'exit 0'
out=$(QKIND=lxc rq_run2 agent); rc=$?
check "err6: agent on a container does not snapshot" "no" "$(rq_snapshotted)"
check "err6: and fails (5)" "5" "$rc"

# 7. several guests, one freeze fails: no snapshot, and the one that WAS frozen
#    must not be left that way.
rq_reset 'exit 0'
cat > "$RQ_D/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$TRACE"
[ "$1" = "-n" ] && shift
shift
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          echo "id=$2 kind=qemu running=yes frozen=no"; exit 0 ;;
  freeze) [ "$2" = 101 ] && exit 1; exit 0 ;;   # the second guest refuses
  thaw)   exit 0 ;;
esac
exit 1
EOF
chmod +x "$RQ_D/bin/sudo"
out=$(TRACE="$RQ_D/trace" PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 2 rpool/data/vm-100-disk-0 rpool/data/vm-101-disk-0 \
           1 rpool/data/vm-100-disk-0@t 2>&1); rc=$?
check "err7: a partial freeze does not snapshot" "no" "$(rq_snapshotted)"
check "err7: and fails (5)" "5" "$rc"
case "$out" in *"thawed VM 100"*) check "err7: and the guest that DID freeze is thawed" "y" "y" ;;
   *) check "err7: and the guest that DID freeze is thawed" "y" "n ($out)" ;; esac

# ---- bare `return` in the remote script: a STATIC guard -------------------
#
# This one cannot be tested behaviourally on the dev box, and pretending
# otherwise would be worse than not testing it.
#
# thaw_all runs from the EXIT trap. In a trap handler bash resolves a bare
# `return` against the status the shell was exiting with, NOT against the last
# command in the function -- so `sudo ... ; return` reported a FAILED thaw as
# success, dropped the id from the recovery list, deleted the state file, killed
# the deadman and exited 0, leaving a production guest frozen. Found live on
# pve0 2026-07-31, after err4 below had been passing green for days.
#
# It passed because bash 5.1.4 (Debian 11 / PVE 7, i.e. every real host)
# reproduces the behaviour and bash 5.3.9 (this dev box) does not. A behavioural
# test here would go green on both the fixed and the broken code. So the guard
# is textual: no bare `return` may exist in the embedded script at all.
bare=$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | grep -nE '(^[[:space:]]*return[[:space:]]*$|;[[:space:]]*return[[:space:]]*(;|$))' || true)
if [ -z "$bare" ]; then
    check "no bare 'return' in the remote script (trap-handler status trap)" "y" "y"
else
    check "no bare 'return' in the remote script (trap-handler status trap)" "y" "n: $(printf '%s' "$bare" | tr '\n' ' ')"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
