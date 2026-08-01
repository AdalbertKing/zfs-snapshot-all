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
# which quiesce_guest_status reports as kind=absent, not that the name is
# unrecognised.
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
# the flush and the snapshot. Driven through quiesce_prepare + quiesce_freeze_pending with a stubbed
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

# Guest detection reads /etc/pve, so point the REAL code at a fake tree rather
# than stubbing the function that does the reading -- a stubbed seam cannot
# regress, and this one did (see the 'privilege' section below).
FAKE_PVE="$TMPD/pve"
mkdir -p "$FAKE_PVE/qemu-server" "$FAKE_PVE/lxc"
: > "$FAKE_PVE/qemu-server/107.conf"
QUIESCE_PVE_DIR="$FAKE_PVE"

QUIESCE_HANDLED=()
QUIESCE_FROZEN=()
QUIESCE_PENDING_VMS=()
quiesce_prepare hdd/data/vm-107-disk-0 auto
quiesce_prepare hdd/data/vm-107-disk-1 auto
quiesce_prepare hdd/data/vm-107-disk-2 auto
# Pass 1 must not have frozen ANYTHING (REV-20260801-024) -- it only decides.
check "dedup: pass 1 freezes nothing at all" "0" "${#QUIESCE_FROZEN[@]}"
check "dedup: three disks of one VM are one pending freeze" "1" "${#QUIESCE_PENDING_VMS[@]}"
check "dedup: the guest is recorded once" "1" "${#QUIESCE_HANDLED[@]}"
quiesce_freeze_pending
check "dedup: pass 2 freezes it once" "1" "${#QUIESCE_FROZEN[@]}"
check "dedup: and it is the right one" "qemu:107" "${QUIESCE_FROZEN[0]:-<pusto>}"
check "dedup: the pending list is consumed" "0" "${#QUIESCE_PENDING_VMS[@]}"

quiesce_thaw_all
check "thaw: the frozen list is emptied" "0" "${#QUIESCE_FROZEN[@]}"
check "thaw: the handled list is emptied too, so a second run is clean" "0" "${#QUIESCE_HANDLED[@]}"

# A dataset owning no guest must not consume a slot or fail.
QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
quiesce_prepare rpool/data auto
check "no guest: nothing frozen" "0" "${#QUIESCE_FROZEN[@]}"
quiesce_prepare hdd/data/vm-107-disk-0 no
check "mode 'no': nothing frozen even for a real guest" "0" "${#QUIESCE_FROZEN[@]}"

# Wrong mode for the guest type (sync on a VM) freezes nothing at all, so since
# REV-20260801-023 it REFUSES rather than proceeding -- see the section on that
# below. Driven in a subshell because the refusal is an exit, not a return.
QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
( quiesce_prepare hdd/data/vm-107-disk-0 sync >/dev/null 2>&1 )
check "wrong mode: a VM is not sync-quiesced -- and the run refuses" "3" "$?"
check "wrong mode: nothing was frozen" "0" "${#QUIESCE_FROZEN[@]}"

# ---- the LOCAL path's privilege routing (2026-08-01) -----------------------
#
# Found live on metropolis pve1, minutes after the managed block moved from root
# to the delegated account. `qm status` as a non-root user does not print
# "stopped" -- it dies with "Unable to load access control list" and exit 21.
# The old probe threw stderr away and matched the empty output against
# *running*, so THREE RUNNING GUESTS were logged as "not running -- nothing to
# freeze", the snapshots were taken unfrozen, and snapsend exited 0.
#
# Nothing alerted, because from every angle the job had succeeded. A backup that
# quietly stops being application-consistent is the failure mode this project
# keeps finding, and it is always the same shape: a probe that cannot tell "no"
# from "I could not ask".
QP="$TMPD/priv"; mkdir -p "$QP/bin" "$QP/pve/qemu-server" "$QP/pve/lxc"
: > "$QP/pve/qemu-server/107.conf"
: > "$QP/pve/lxc/108.conf"

# `qm` that behaves like a real one reached by an account with no cluster
# access: exit 21, nothing on stdout.
cat > "$QP/bin/qm-denied" <<'STUB'
#!/bin/sh
echo "ipcc_send_rec[1] failed: Is a directory" >&2
echo "Unable to load access control list: Is a directory" >&2
exit 21
STUB
# ...and one that answers properly for a STOPPED guest: exit 0, "stopped".
cat > "$QP/bin/qm-stopped" <<'STUB'
#!/bin/sh
case "$1" in status) echo "status: stopped"; exit 0 ;; esac
exit 0
STUB
chmod +x "$QP/bin/qm-denied" "$QP/bin/qm-stopped"

QUIESCE_PVE_DIR="$QP/pve"
QUIESCE_VIA=direct

( PATH="$QP:$PATH"; cp "$QP/bin/qm-denied" "$QP/qm"; quiesce_guest_status 107 >/dev/null 2>&1 )
check "priv: a guest whose state cannot be READ is not reported as stopped" "1" "$?"

( PATH="$QP:$PATH"; cp "$QP/bin/qm-stopped" "$QP/qm"; quiesce_guest_status 107 2>/dev/null | grep -q 'running=no' )
check "priv: a guest that really IS stopped still reads running=no" "0" "$?"

# The consequence, which is the part that mattered: quiesce_prepare must REFUSE,
# not skip. Exit 3 is the same code the remote path uses for "cannot quiesce",
# and the cron lines alert on any non-zero.
cp "$QP/bin/qm-denied" "$QP/qm"
out=$( PATH="$QP:$PATH"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-107-disk-0 auto 2>&1 ); rc=$?
check "priv: an unreadable guest state fails the run instead of skipping the freeze" "3" "$rc"
case "$out" in
    *"could not determine the state of guest 107"*)
        check "priv: ...and says which guest, not just that something failed" "0" "0" ;;
    *)  check "priv: ...and says which guest, not just that something failed" "0" "1 ($out)" ;;
esac

# A stopped guest must stay an ordinary skip. The fix is about "could not ask",
# and turning every stopped VM into a failed backup would be a worse bug than
# the one being fixed.
cp "$QP/bin/qm-stopped" "$QP/qm"
( PATH="$QP:$PATH"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
  quiesce_prepare hdd/data/vm-107-disk-0 auto >/dev/null 2>&1 )
check "priv: a genuinely stopped guest is still just skipped" "0" "$?"

# ---- quiesce_init: the route is decided once, and refuses ------------------
#
# The local path had no notion of a delegated account at all -- that existed
# only in the remote script. So an account that could not reach a hypervisor
# never found out, per guest, forever.
cat > "$QP/bin/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { echo 1001; exit 0; }
[ "$1" = "-un" ] && { echo zfsbackup; exit 0; }
echo zfsbackup
STUB
cat > "$QP/bin/helper-ok" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -n "${2:-}" ] && echo "id=$2 kind=qemu running=yes frozen=no"; exit 0 ;;
  freeze|thaw) echo "$1 $2" >> "$HELPER_TRACE"; exit 0 ;;
esac
exit 2
STUB
cat > "$QP/bin/sudo" <<'STUB'
#!/bin/sh
# `sudo -n <cmd> ...` -- drop the flag and run it, which is what a working
# NOPASSWD rule amounts to for this test.
[ "$1" = "-n" ] && shift
exec "$@"
STUB
chmod +x "$QP/bin/id" "$QP/bin/helper-ok" "$QP/bin/sudo"

# No usable helper -> refuse, and name the command that fixes it.
out=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_VIA=""; QUIESCE_HELPER="$QP/nonexistent"
       quiesce_init auto 2>&1 ); rc=$?
check "init: a non-root caller with no helper refuses instead of degrading" "3" "$rc"
case "$out" in
    *"--allow-quiesce"*) check "init: ...and names the deploy.sh grant" "0" "0" ;;
    *)                   check "init: ...and names the deploy.sh grant" "0" "1 ($out)" ;;
esac

# A usable helper -> route through it.
via=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_VIA=""; QUIESCE_HELPER="$QP/bin/helper-ok"
       quiesce_init auto >/dev/null 2>&1; echo "$QUIESCE_VIA" )
check "init: a non-root caller WITH a helper routes through it" "helper" "$via"

# And on that route qm is never touched: the freeze and the thaw both go to the
# helper. Proven by tracing the helper, with a qm on PATH that would exit 21 if
# anything reached it.
cp "$QP/bin/qm-denied" "$QP/qm"
export HELPER_TRACE="$QP/trace"; : > "$HELPER_TRACE"
rc=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_VIA=helper; QUIESCE_HELPER="$QP/bin/helper-ok"
      QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
      quiesce_prepare hdd/data/vm-107-disk-0 auto >/dev/null 2>&1
      quiesce_freeze_pending >/dev/null 2>&1
      quiesce_thaw_all >/dev/null 2>&1
      echo "$?" )
check "init: on the helper route the freeze and thaw both reach the helper" \
      "freeze 107|thaw 107" "$(tr '\n' '|' < "$HELPER_TRACE" | sed 's/|$//')"

# A guest the helper REFUSES (outside this account's whitelist) is the pve1
# guest-102 case: its disk sits under a delegated parent, the config could name
# it, and the grant does not cover it. That must fail the run, not produce an
# unfrozen snapshot of it.
cat > "$QP/bin/helper-refuses" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -z "${2:-}" ] && exit 0
          echo "guest $2 is not on the quiesce whitelist" >&2; exit 2 ;;
esac
exit 2
STUB
chmod +x "$QP/bin/helper-refuses"
out=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_VIA=helper; QUIESCE_HELPER="$QP/bin/helper-refuses"
       QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-102-disk-0 auto 2>&1 ); rc=$?
check "init: a guest outside the account's whitelist fails the run" "3" "$rc"
case "$out" in
    *"whitelist"*) check "init: ...and points at the whitelist, not at the guest being down" "0" "0" ;;
    *)             check "init: ...and points at the whitelist, not at the guest being down" "0" "1 ($out)" ;;
esac

QUIESCE_PVE_DIR="$FAKE_PVE"
QUIESCE_VIA=""

# ---- REV-20260801-023: -q is not best-effort -------------------------------
#
# The routing fix above stopped the local path calling a running guest stopped.
# It left five branches that still DEGRADED: already-frozen, unreadable
# fsfreeze-status, a freeze that did not take, a container flush that failed,
# and a mode that fits no guest of that kind. Each one logged something and let
# the snapshot proceed, so a job that delivered crash-consistent data still
# exited 0 and still called itself quiesced.
#
# The rule is now binary: -q either delivered the consistency class it promised
# for this run, or the run failed. "Nothing to quiesce" -- no guest, no such
# guest, guest switched off -- stays a success, because there the snapshot is
# already as consistent as it can be.
RJ="$TMPD/refuse"; mkdir -p "$RJ/bin" "$RJ/pve/qemu-server" "$RJ/pve/lxc"
: > "$RJ/pve/qemu-server/106.conf"
: > "$RJ/pve/lxc/101.conf"

# The review's own reproduction: a delegated account, helper says the guest is
# running and ALREADY frozen.
mk_helper() {   # <status line> [freeze-rc]
    cat > "$RJ/bin/helper" <<STUB
#!/bin/sh
case "\$1" in
  status) [ -z "\${2:-}" ] && exit 0; echo "$1"; exit 0 ;;
  freeze) echo "freeze \$2" >> "\$HELPER_TRACE"; exit ${2:-0} ;;
  thaw)   echo "thaw \$2"   >> "\$HELPER_TRACE"; exit 0 ;;
esac
exit 2
STUB
    chmod +x "$RJ/bin/helper"
}
# A zfs that RECORDS being called, so "no snapshot was taken" is proven rather
# than assumed.
cat > "$RJ/bin/zfs" <<'STUB'
#!/bin/sh
echo "zfs $*" >> "$ZFS_TRACE"
exit 0
STUB
# The helper is reached as `sudo -n <helper> ...`, so without this every call
# fails because sudo is missing and every assertion below passes for entirely
# the wrong reason -- which is what happened the first time these were written.
cat > "$RJ/bin/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
STUB
chmod +x "$RJ/bin/zfs" "$RJ/bin/sudo"
export HELPER_TRACE="$RJ/htrace" ZFS_TRACE="$RJ/ztrace"

run_refuse() {   # <status line> [freeze-rc] -> prints "rc|<helper trace>|<zfs trace>"
    mk_helper "$1" "${2:-0}"
    : > "$HELPER_TRACE"; : > "$ZFS_TRACE"
    local out rc
    out=$( PATH="$RJ/bin:$PATH"
           QUIESCE_PVE_DIR="$RJ/pve"; QUIESCE_VIA=helper; QUIESCE_HELPER="$RJ/bin/helper"
           QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=(); QUIESCE_THAW_FAILED=0
           # Both passes, because since REV-20260801-024 the refusals are split
           # between them: everything except the freeze itself is decided in
           # pass 1, and the freeze that does not take is pass 2.
           quiesce_prepare "${3:-hdd/data/vm-106-disk-0}" "${4:-auto}" 2>&1 \
               && quiesce_freeze_pending 2>&1 ); rc=$?
    printf '%s|%s|%s|%s' "$rc" "$(tr '\n' ',' < "$HELPER_TRACE")" "$(tr '\n' ',' < "$ZFS_TRACE")" "$out"
}

r=$(run_refuse "id=106 kind=qemu running=yes frozen=yes")
check "refuse: an already-frozen guest fails the run" "3" "${r%%|*}"
case "$r" in
    *"ALREADY frozen before this run started"*)
        check "refuse: ...and says the freeze is not this run's" "0" "0" ;;
    *)  check "refuse: ...and says the freeze is not this run's" "0" "1 ($r)" ;;
esac
# Requirement 5 of the review: no thaw is attempted, because this run never
# acquired the freeze. Proven from the helper trace, not from the log text.
check "refuse: ...and does NOT thaw a freeze it does not own" "" "$(sed -n 's/^[0-9]*|\([^|]*\)|.*/\1/p' <<<"$r")"
# Requirements 1 and 2: nothing reached zfs, so no snapshot and no send.
check "refuse: ...and no zfs command ran at all" "" "$(sed -n 's/^[0-9]*|[^|]*|\([^|]*\)|.*/\1/p' <<<"$r")"

# The reviewer's second case, and the one the old comment blessed by name: a
# running VM whose agent will not answer. "Unreachable agent" was listed as a
# reason to take an ordinary snapshot. Under an explicit -q it is not.
r=$(run_refuse "id=106 kind=qemu running=yes frozen=unknown")
check "refuse: an unreadable fsfreeze-status fails the run" "3" "${r%%|*}"
case "$r" in
    *"could not read fsfreeze-status"*) check "refuse: ...and names the agent, not the guest" "0" "0" ;;
    *)                                  check "refuse: ...and names the agent, not the guest" "0" "1 ($r)" ;;
esac

# A freeze that was attempted and did not take.
r=$(run_refuse "id=106 kind=qemu running=yes frozen=no" 1)
check "refuse: a freeze that did not take fails the run" "3" "${r%%|*}"
check "refuse: ...after actually trying it" "freeze 106," "$(sed -n 's/^[0-9]*|\([^|]*\)|.*/\1/p' <<<"$r")"

# Containers cannot be frozen at all -- the promise is a FLUSH, and a flush that
# failed is still a promise not kept.
r=$(run_refuse "id=101 kind=lxc running=yes frozen=unknown" 1 "hdd/lxc/subvol-101-disk-0")
check "refuse: a container flush that failed fails the run" "3" "${r%%|*}"

# ...and the same guest with a working flush is an ordinary success, so the rule
# above is not just "everything fails now".
r=$(run_refuse "id=101 kind=lxc running=yes frozen=unknown" 0 "hdd/lxc/subvol-101-disk-0")
check "refuse: a container flush that worked is still a success" "0" "${r%%|*}"

# An explicit mode that fits no guest of that kind quiesces NOTHING. Beyond the
# letter of the review, same rule.
r=$(run_refuse "id=106 kind=qemu running=yes frozen=no" 0 "hdd/data/vm-106-disk-0" sync)
check "refuse: quiesce=sync on a VM fails instead of freezing nothing" "3" "${r%%|*}"
r=$(run_refuse "id=101 kind=lxc running=yes frozen=unknown" 0 "hdd/lxc/subvol-101-disk-0" agent)
check "refuse: quiesce=agent on a container fails instead of freezing nothing" "3" "${r%%|*}"

# NOTHING TO QUIESCE stays a success. This is the half that must not regress:
# failing a backup because the guest is switched off would be worse than the bug
# being fixed.
r=$(run_refuse "id=106 kind=qemu running=no frozen=unknown")
check "refuse: a switched-off guest is still an ordinary success" "0" "${r%%|*}"
r=$(run_refuse "id=106 kind=absent running=no frozen=unknown")
check "refuse: a guest that is not on this node is still an ordinary success" "0" "${r%%|*}"

# ---- a failed thaw must fail the run --------------------------------------
#
# A guest left frozen is an outage. An outage the job reported as a clean backup
# is an outage nobody goes looking for.
cat > "$RJ/bin/helper-nothaw" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -z "${2:-}" ] && exit 0; echo "id=$2 kind=qemu running=yes frozen=no"; exit 0 ;;
  freeze) exit 0 ;;
  thaw)   echo "thaw $2" >> "$HELPER_TRACE"; exit 1 ;;
esac
exit 2
STUB
chmod +x "$RJ/bin/helper-nothaw"
: > "$HELPER_TRACE"
res=$( PATH="$RJ/bin:$PATH"
       QUIESCE_PVE_DIR="$RJ/pve"; QUIESCE_VIA=helper; QUIESCE_HELPER="$RJ/bin/helper-nothaw"
       QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=(); QUIESCE_THAW_FAILED=0
       quiesce_prepare hdd/data/vm-106-disk-0 auto >/dev/null 2>&1
       quiesce_freeze_pending >/dev/null 2>&1
       quiesce_thaw_all >/dev/null 2>&1; rc=$?
       echo "$rc ${#QUIESCE_FROZEN[@]} $QUIESCE_THAW_FAILED" )
check "thaw-fail: quiesce_thaw_all reports the failure to its caller" "1" "$(echo "$res" | cut -d' ' -f1)"
check "thaw-fail: the guest STAYS on the recovery list, it is not forgotten" "1" "$(echo "$res" | cut -d' ' -f2)"
check "thaw-fail: and the flag is set for the caller to act on" "1" "$(echo "$res" | cut -d' ' -f3)"
# Retried once before giving up: the usual cause of a first failure is an agent
# still busy with the freeze it just performed.
check "thaw-fail: the thaw was retried before being called a failure" "2" \
      "$(grep -c 'thaw 106' "$HELPER_TRACE")"

# snapsend.sh must turn that into a non-zero exit rather than logging it.
grep -q 'if ! quiesce_thaw_all; then' "$REPO/snapsend.sh" \
    && ok_thaw=1 || ok_thaw=0
check "thaw-fail: snapsend fails the run on it instead of logging and continuing" "1" "$ok_thaw"

# ---- REV-20260801-024: the window is a deadline, not a sequence -------------
#
# Measured on metropolis pve1: VM 106 (ostype win10) frozen 18:21:21, snapshot
# 18:21:39. Eighteen seconds, sixteen of them one `pct exec 101 -- sync` running
# AFTER the freeze. VSS drops a Windows freeze at about 10 s on its own, so the
# snapshot was taken outside the window it claimed to be inside -- and every
# check passed, because the freeze DID take. It just was not still in force.
#
# So a successful fsfreeze-freeze proves nothing at snapshot time. Order,
# re-check and deadline are all three needed, and all three are tested here.
WD="$TMPD/window"; mkdir -p "$WD/bin" "$WD/pve/qemu-server" "$WD/pve/lxc"
: > "$WD/pve/qemu-server/106.conf"
: > "$WD/pve/lxc/101.conf"
export WIN_TRACE="$WD/trace" WIN_STATUS="$WD/status"

# One helper for all of it. The status it reports is read from a FILE, so a test
# can change the guest's mind between the freeze and the re-check -- which is
# exactly what a VSS timeout does in production.
cat > "$WD/bin/helper" <<'STUB'
#!/bin/sh
case "$1" in
  status)
    [ -z "${2:-}" ] && exit 0
    case "$2" in
      101) echo "id=101 kind=lxc running=yes frozen=unknown"; exit 0 ;;
    esac
    echo "$(cat "$WIN_STATUS")" | sed "s/^id=[0-9]*/id=$2/"
    exit "${STATUS_RC:-0}" ;;
  freeze)
    echo "freeze $2" >> "$WIN_TRACE"
    # A container flush is the SLOW one. Sleeping here is what makes "did the
    # flush happen before the freeze" a real ordering assertion rather than a
    # reading of the source.
    [ "$2" = 101 ] && sleep "${FLUSH_SECONDS:-0}"
    exit 0 ;;
  thaw) echo "thaw $2" >> "$WIN_TRACE"; exit 0 ;;
esac
exit 2
STUB
cat > "$WD/bin/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
STUB
chmod +x "$WD/bin/helper" "$WD/bin/sudo"

# 1. The slow container flush must happen BEFORE any VM is frozen.
#
# Asserted on the ORDER of the trace, not on the source: with the old code the
# freeze came first and the flush second, and that is precisely what produced
# the 18-second window.
echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
: > "$WIN_TRACE"
( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
  QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
  quiesce_prepare hdd/data/vm-106-disk-0 auto
  quiesce_prepare hdd/lxc/subvol-101-disk-0 auto
  quiesce_freeze_pending ) >/dev/null 2>&1
check "window: the container flush happens BEFORE the VM freeze" "freeze 101,freeze 106," \
      "$(tr '\n' ',' < "$WIN_TRACE")"

# ...and pass 1 on its own freezes no VM at all, whatever order the datasets
# arrive in.
: > "$WIN_TRACE"
( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
  QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
  quiesce_prepare hdd/data/vm-106-disk-0 auto ) >/dev/null 2>&1
check "window: pass 1 alone never freezes a VM" "0" "$(grep -c 'freeze 106' "$WIN_TRACE")"

# 2. The guest thaws itself between the freeze and the snapshot -- the actual
# production failure. The re-check must catch it and no snapshot may follow.
: > "$WIN_TRACE"
res=$( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
       QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
       echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
       quiesce_prepare hdd/data/vm-106-disk-0 auto >/dev/null 2>&1
       quiesce_freeze_pending >/dev/null 2>&1
       # VSS lets go here, exactly as it does after ~10s on a real Windows guest.
       echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
       out=$(quiesce_still_frozen 2>&1); echo "$?|$out" )
check "window: a guest that thawed itself before the snapshot is caught" "1" "${res%%|*}"
case "$res" in
    *"no longer frozen"*) check "window: ...and the message says so, not something generic" "0" "0" ;;
    *)                    check "window: ...and the message says so, not something generic" "0" "1 ($res)" ;;
esac

# 3. The status probe itself fails right before the snapshot. Unknown is not yes.
res=$( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
       QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
       echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
       quiesce_prepare hdd/data/vm-106-disk-0 auto >/dev/null 2>&1
       quiesce_freeze_pending >/dev/null 2>&1
       export STATUS_RC=2
       out=$(quiesce_still_frozen 2>&1); echo "$?|$out" )
check "window: an unreadable status right before the snapshot is caught" "1" "${res%%|*}"
case "$res" in
    *"could not re-read the state"*) check "window: ...and blames the probe, not the guest" "0" "0" ;;
    *)                               check "window: ...and blames the probe, not the guest" "0" "1 ($res)" ;;
esac

# 4. The DEADLINE. Everything reports frozen and the clock still says the window
# is gone -- the case the re-check cannot see, because an agent will happily
# answer "frozen" about a freeze it can no longer honour.
res=$( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
       QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=("qemu:106"); QUIESCE_PENDING_VMS=()
       echo "id=106 kind=qemu running=yes frozen=yes" > "$WIN_STATUS"
       QUIESCE_FROZEN=("qemu:106")
       QUIESCE_MAX_WINDOW=5
       QUIESCE_FREEZE_EPOCH=$(( $(date +%s) - 30 ))
       out=$(quiesce_still_frozen 2>&1); echo "$?|$out" )
check "window: an over-budget window fails even when every guest says frozen" "1" "${res%%|*}"
case "$res" in
    *"over the 5s budget"*) check "window: ...and reports the measured duration and the budget" "0" "0" ;;
    *)                      check "window: ...and reports the measured duration and the budget" "0" "1 ($res)" ;;
esac

# 5. The success path: still frozen, inside budget, and the duration is LOGGED
# rather than left to be inferred from timestamps -- which is how this defect
# had to be found in the first place.
res=$( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
       QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=("qemu:106"); QUIESCE_PENDING_VMS=()
       echo "id=106 kind=qemu running=yes frozen=yes" > "$WIN_STATUS"
       QUIESCE_FROZEN=("qemu:106"); QUIESCE_MAX_WINDOW=5
       QUIESCE_FREEZE_EPOCH=$(date +%s)
       VERBOSE=3
       out=$(quiesce_still_frozen 2>&1); echo "$?|$out" )
check "window: a freeze still in force and inside budget passes" "0" "${res%%|*}"
case "$res" in
    *"freeze window "*"budget"*) check "window: ...and the duration is logged, not left to be inferred" "0" "0" ;;
    *)                           check "window: ...and the duration is logged, not left to be inferred" "0" "1 ($res)" ;;
esac

# 6. Abort AFTER the freeze must still thaw everything this run owns. The
# refusals are exits, and the EXIT trap belongs to snapsend.sh -- so this drives
# the same shape: freeze two guests, fail, thaw from the trap.
: > "$WIN_TRACE"
( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
  QUIESCE_HELPER="$WD/bin/helper"; QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=()
  echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
  trap 'quiesce_thaw_all || :' EXIT
  quiesce_prepare hdd/data/vm-106-disk-0 auto
  quiesce_freeze_pending
  echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
  quiesce_still_frozen || exit 3 ) >/dev/null 2>&1
check "window: an abort after the freeze still thaws what this run froze" "3" "$?"
check "window: ...and the thaw actually reached the guest" "1" "$(grep -c 'thaw 106' "$WIN_TRACE")"

# 7. snapsend.sh must call the two new steps in the right places: freeze after
# the prepare loop, re-check before the snapshot loop, and refuse on failure.
sn=$(grep -n 'quiesce_freeze_pending\|quiesce_still_frozen\|zfs snapshot \$quiesce_recursive_flag' "$REPO/snapsend.sh" | cut -d: -f1 | tr '\n' ' ')
set -- $sn
if [ "$#" -ge 3 ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]; then
    check "window: snapsend freezes, re-checks, THEN snapshots -- in that order" "0" "0"
else
    check "window: snapsend freezes, re-checks, THEN snapshots -- in that order" "0" "1 (linie: $sn)"
fi
grep -q 'if ! quiesce_still_frozen; then' "$REPO/snapsend.sh" \
    && check "window: snapsend refuses the snapshot when the re-check fails" "0" "0" \
    || check "window: snapsend refuses the snapshot when the re-check fails" "0" "1"

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
