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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
