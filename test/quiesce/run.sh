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

# ...and it must NOT be run as root. Most of this suite drives the remote
# quiesce script, which picks its route from `id -u`: root goes straight to
# qm/pct, anyone else goes through sudo and the helper. Every stub here models
# the delegated route, so a root run reports ~42 failures that say nothing
# about the code -- measured on 2026-08-02 against an unmodified main, after
# running it on a host the obvious way. A suite whose wrong invocation looks
# exactly like a broken tree is worse than one that refuses.
if [ "$(id -u)" -eq 0 ]; then
    echo "This suite models a DELEGATED account and must not run as root:" >&2
    echo "the remote quiesce script would take the direct qm/pct route and" >&2
    echo "every helper assertion would fail for the wrong reason." >&2
    echo "Run it as an ordinary user, e.g.:  su - zfsbackup -c 'cd $PWD && ./test/quiesce/run.sh'" >&2
    exit 2
fi

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

# The consequence, which is the part that mattered: quiesce_prepare must not
# treat "could not ask" as "nothing to freeze here". What that costs the run is a
# separate question with two answers since 2026-08-27, so both are checked, and
# the pin is explicit: QUIESCE_DEGRADE is what a tier's `,strict` sets, and this
# half is the strict one. Exit 3 is the same code the remote path uses for
# "cannot quiesce", and the cron lines alert on any non-zero.
cp "$QP/bin/qm-denied" "$QP/qm"
out=$( PATH="$QP:$PATH"; QUIESCE_DEGRADE=0; QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-107-disk-0 auto 2>&1 ); rc=$?
check "priv: under ,strict an unreadable guest state fails the run" "3" "$rc"
case "$out" in
    *"could not determine the state of guest 107"*)
        check "priv: ...and says which guest, not just that something failed" "0" "0" ;;
    *)  check "priv: ...and says which guest, not just that something failed" "0" "1 ($out)" ;;
esac
# THE DEFAULT HALF, and the owner's 2026-08-27 direction at the site that
# produced it: a host where the account cannot read guest state is exactly what
# was measured on pve9/pve1/pve2. It must DEGRADE -- which is not the same as
# the skip this block exists to prevent, and the difference is checkable: a skip
# is silent and succeeds, a degradation announces itself and is recorded.
out=$( PATH="$QP:$PATH"; QUIESCE_DEGRADE=1; QUIESCE_DEGRADED=0; QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-107-disk-0 auto >/dev/null 2>&1
       printf '%s' "$QUIESCE_DEGRADED" )
check "priv: by default an unreadable guest state degrades instead" "1" "$out"
out=$( PATH="$QP:$PATH"; QUIESCE_DEGRADE=1; QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-107-disk-0 auto 2>&1 )
case "$out" in
    *DEGRADING*) check "priv: ...and says so, so it is not a silent skip" "0" "0" ;;
    *)           check "priv: ...and says so, so it is not a silent skip" "0" "1 ($out)" ;;
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

# No usable helper. Under ,strict: refuse, and name the command that fixes it.
out=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_DEGRADE=0; QUIESCE_VIA=""; QUIESCE_HELPER="$QP/nonexistent"
       quiesce_init auto 2>&1 ); rc=$?
check "init: under ,strict a non-root caller with no helper refuses" "3" "$rc"
case "$out" in
    *"--allow-quiesce"*) check "init: ...and names the deploy.sh grant" "0" "0" ;;
    *)                   check "init: ...and names the deploy.sh grant" "0" "1 ($out)" ;;
esac
# By default it degrades -- and STILL names the grant, because "you got a
# crash-consistent snapshot" is not an answer to "why can this account not reach
# the guests". Losing the remedy from the message is the way a degraded default
# turns a fixable misconfiguration into a permanent one.
out=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_DEGRADE=1; QUIESCE_VIA=""; QUIESCE_HELPER="$QP/nonexistent"
       quiesce_init auto 2>&1 ); rc=$?
check "init: by default a non-root caller with no helper degrades" "1" "$rc"
case "$out" in
    *"--allow-quiesce"*) check "init: ...and the remedy is still in the message" "0" "0" ;;
    *)                   check "init: ...and the remedy is still in the message" "0" "1 ($out)" ;;
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
out=$( PATH="$QP/bin:$QP:$PATH"; QUIESCE_DEGRADE=0; QUIESCE_VIA=helper; QUIESCE_HELPER="$QP/bin/helper-refuses"
       QUIESCE_HANDLED=(); QUIESCE_FROZEN=()
       quiesce_prepare hdd/data/vm-102-disk-0 auto 2>&1 ); rc=$?
check "init: under ,strict a guest outside the account's whitelist fails the run" "3" "$rc"
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

# PINNED STRICT for this whole block, and the pin is the point rather than a
# convenience: everything below is about the SHAPE of a refusal -- which code,
# which message, what was and was not touched on the way out -- and since
# 2026-08-27 a refusal is what a tier asks for with `,strict`. The same failures
# under the DEFAULT are checked in the degrade block further down, both halves,
# so nothing here is being avoided by pinning it.
#
# Two of the cases below refuse either way (a foreign freeze, a mode that cannot
# fit the guest) and are unaffected by the pin; that is asserted where it belongs,
# with the degrade default explicitly set to 1.
QUIESCE_DEGRADE=0
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

# 4b. The clock starts when a guest is actually FROZEN, not when we start
# asking. `fsfreeze-freeze` on a Windows guest takes ~4 s to return, all of it
# VSS preparing -- the guest is not frozen during it, and counting it put a
# healthy production job at "window 5s (budget 5s)", one second from failing.
# Found by reading the number on a live run, not by a test.
cat > "$WD/bin/helper-slowfreeze" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -z "${2:-}" ] && exit 0; cat "$WIN_STATUS" | sed "s/^id=[0-9]*/id=$2/"; exit 0 ;;
  freeze) sleep 3; exit 0 ;;
  thaw)   exit 0 ;;
esac
exit 2
STUB
chmod +x "$WD/bin/helper-slowfreeze"
res=$( PATH="$WD/bin:$PATH"; QUIESCE_PVE_DIR="$WD/pve"; QUIESCE_VIA=helper
       QUIESCE_HELPER="$WD/bin/helper-slowfreeze"
       QUIESCE_HANDLED=(); QUIESCE_FROZEN=(); QUIESCE_PENDING_VMS=(); QUIESCE_FREEZE_EPOCH=0
       QUIESCE_MAX_WINDOW=2
       echo "id=106 kind=qemu running=yes frozen=no" > "$WIN_STATUS"
       quiesce_prepare hdd/data/vm-106-disk-0 auto >/dev/null 2>&1
       quiesce_freeze_pending >/dev/null 2>&1
       echo "id=106 kind=qemu running=yes frozen=yes" > "$WIN_STATUS"
       quiesce_still_frozen >/dev/null 2>&1; echo "$?" )
check "window: a slow freeze CALL is not charged to the window it precedes" "0" "$res"

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
# REV-20260802-029: before EVERY pool, not once before the loop. ZFS cannot be
# atomic across pools, so a multi-pool job is N commands and a slow first one
# can eat the whole window -- the single check certified a boundary the second
# pool never had.
if grep -q 'if ! quiesce_still_frozen "pool ' "$REPO/snapsend.sh"; then
    check "window: snapsend re-checks before EVERY pool" "0" "0"
else
    check "window: snapsend re-checks before EVERY pool" "0" "1"
fi
if grep -q '^    if ! quiesce_still_frozen; then' "$REPO/snapsend.sh"; then
    check "window: ...and the single pre-loop check is gone" "0" "1"
else
    check "window: ...and the single pre-loop check is gone" "0" "0"
fi

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
shift
st="${QSTATE:-/tmp/qstate}.${2:-x}"
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          k="${QKIND:-qemu}"; [ "$2" = 200 ] && k=lxc
          f="${QFROZEN:-}"
          if [ -z "$f" ]; then f=no; [ -e "$st" ] && f=yes; fi
          [ -n "${QTHAWS_ITSELF:-}" ] && f=no
          echo "id=$2 kind=$k running=yes frozen=$f"; exit 0 ;;
  freeze) [ "$2" = "${QFREEZE_FAIL_ID:-}" ] && exit 1
          [ "$2" = 200 ] && sleep "${QSLOW_FLUSH:-0}"
          [ "$2" != 200 ] && sleep "${QSLOW_FREEZE:-0}"
          [ "${QFREEZE:-0}" = 0 ] && : > "$st"; exit "${QFREEZE:-0}" ;;
  thaw)   [ "${QTHAW:-0}" = 0 ] && rm -f "$st"; exit "${QTHAW:-0}" ;;
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
    TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" PATH="$RQ_D/bin:$PATH" \
        bash "$RQ_D/rq.sh" agent 30 "" 30 1 rpool/data/vm-100-disk-0 \
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
    # The stub keeps per-guest freeze state on disk since the boundary
    # re-check landed, so it must be wiped between cases -- otherwise case
    # N+1 opens with a guest case N left frozen and refuses with
    # "ALREADY frozen" instead of testing itself.
    rm -f "$RQ_D"/qs.*
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
st="${QSTATE:-/tmp/qstate}.${2:-x}"
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          k="${QKIND:-qemu}"; [ "$2" = 200 ] && k=lxc
          f="${QFROZEN:-}"
          if [ -z "$f" ]; then f=no; [ -e "$st" ] && f=yes; fi
          [ -n "${QTHAWS_ITSELF:-}" ] && f=no
          echo "id=$2 kind=$k running=yes frozen=$f"; exit 0 ;;
  freeze) [ "$2" = "${QFREEZE_FAIL_ID:-}" ] && exit 1
          [ "$2" = 200 ] && sleep "${QSLOW_FLUSH:-0}"
          [ "$2" != 200 ] && sleep "${QSLOW_FREEZE:-0}"
          [ "${QFREEZE:-0}" = 0 ] && : > "$st"; exit "${QFREEZE:-0}" ;;
  thaw)   [ "${QTHAW:-0}" = 0 ] && rm -f "$st"; exit "${QTHAW:-0}" ;;
esac
exit 1
EOF
chmod +x "$RQ_D/bin/sudo"

rq_run2() {   # rq_run2 <mode> -- env steers the stubs
    TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" PATH="$RQ_D/bin:$PATH" \
        bash "$RQ_D/rq.sh" "${1:-agent}" 30 "" 30 1 rpool/data/vm-100-disk-0 \
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
# 9, not 5, since 2026-08-26. Both codes mean "no snapshot"; the difference is
# what the LOCAL side is then allowed to do with it. 5 is degradable under
# `,degrade` and 9 is not, and a freeze somebody else established is the second
# thing the contract keeps fatal. Until this split existed, the PULL path
# degraded it while PUSH refused it.
check "err2: and the run fails FATALLY (9), not degradably" "9" "$rc"
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
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" PATH="$RQ_PATH" bash "$RQ_D/rq.sh" agent 30 "" 30 \
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
# 9 for the same reason as err2: a mode that cannot ever fit this guest is a
# config error, not a freeze that failed today, so `,degrade` must not cover it.
check "err6: and fails FATALLY (9), not degradably" "9" "$rc"

# 7. several guests, one freeze fails: no snapshot, and the one that WAS frozen
#    must not be left that way.
rq_reset 'exit 0'
cat > "$RQ_D/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$TRACE"
[ "$1" = "-n" ] && shift
shift
st="${QSTATE:-/tmp/qstate}.${2:-x}"
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          k="${QKIND:-qemu}"; [ "$2" = 200 ] && k=lxc
          f="${QFROZEN:-}"
          if [ -z "$f" ]; then f=no; [ -e "$st" ] && f=yes; fi
          [ -n "${QTHAWS_ITSELF:-}" ] && f=no
          echo "id=$2 kind=$k running=yes frozen=$f"; exit 0 ;;
  freeze) [ "$2" = "${QFREEZE_FAIL_ID:-}" ] && exit 1
          [ "$2" = 200 ] && sleep "${QSLOW_FLUSH:-0}"
          [ "$2" != 200 ] && sleep "${QSLOW_FREEZE:-0}"
          [ "${QFREEZE:-0}" = 0 ] && : > "$st"; exit "${QFREEZE:-0}" ;;
  thaw)   [ "${QTHAW:-0}" = 0 ] && rm -f "$st"; exit "${QTHAW:-0}" ;;
esac
exit 1
EOF
chmod +x "$RQ_D/bin/sudo"
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" QFREEZE_FAIL_ID=101 PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 30 2 rpool/data/vm-100-disk-0 rpool/data/vm-101-disk-0 \
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

# ---- the remote path gets the same contract (2026-08-02) -------------------
#
# The local path got ordering, a boundary re-check and a deadline in
# REV-20260801-024. This copy did not, and PROJECT_STATUS carried that as a
# named open item: the specific 18-second shape cannot occur here, because
# freeze/snapshot/thaw run in ONE invocation -- but `pct exec <id> -- sync` is
# just as slow over here, and a mixed scope orders exactly as badly.
#
# ONE stub for the whole section, because the previous version of this block
# defined a second one for the ordering case and the four cases after it
# silently kept using that -- passing or failing for reasons unrelated to what
# they claimed to test.

# 1. ORDER. A container in the same scope must be flushed BEFORE the VM is
# frozen. Asserted on the ORDER OF THE TRACE, with the flush made slow, not on
# the shape of the source.
rq_reset 'exit 0'
TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" QSLOW_FLUSH=2 PATH="$RQ_D/bin:$PATH" \
    bash "$RQ_D/rq.sh" auto 30 "" 30 2 rpool/data/vm-100-disk-0 rpool/data/subvol-200-disk-0 \
         1 rpool/data@t >/dev/null 2>&1
order=$(grep -oE 'helper (freeze|thaw) [0-9]+' "$RQ_D/trace" | head -2 | tr '\n' '|')
check "remote-window: the container is flushed BEFORE the VM is frozen" \
      "helper freeze 200|helper freeze 100|" "$order"

# 2. RE-CHECK. The guest lets go between the freeze and the snapshot -- the
# production failure -- and no snapshot may follow.
rq_reset 'exit 0'
out=$(QTHAWS_ITSELF=1 rq_run2); rc=$?
check "remote-window: a guest that thawed itself before the snapshot is caught" "5" "$rc"
check "remote-window: ...and no snapshot was taken" "no" "$(rq_snapshotted)"
case "$out" in *"no longer frozen before the snapshot of pool"*)
    check "remote-window: ...and the message says so" "y" "y" ;;
  *) check "remote-window: ...and the message says so" "y" "n ($out)" ;; esac

# 3. DEADLINE. Everything reports frozen and the clock still says the window is
# gone -- the case the re-check cannot see, because an agent will happily answer
# "frozen" about a freeze it can no longer honour. A slow freeze plus a 1s
# budget forces it.
rq_reset 'exit 0'
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" QSLOW_FREEZE=3 PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 1 2 rpool/data/vm-100-disk-0 rpool/data/vm-101-disk-0 \
           1 rpool/data@t 2>&1); rc=$?
case "$out" in *"over the 1s budget"*) check "remote-window: an over-budget window refuses" "y" "y" ;;
  *) check "remote-window: an over-budget window refuses" "y" "n ($out)" ;; esac
check "remote-window: ...and takes no snapshot" "no" "$(rq_snapshotted)"

# ...and the clock starts at the FIRST successful freeze, not when we start
# asking: a slow freeze call is VSS preparing, during which the guest is not
# frozen yet. Charging it to the window put a healthy production job one second
# from failing on 2026-08-01.
rq_reset 'exit 0'
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" QSLOW_FREEZE=2 PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 1 1 rpool/data/vm-100-disk-0 \
           1 rpool/data/vm-100-disk-0@t 2>&1); rc=$?
check "remote-window: a slow freeze CALL is not charged to the window" "0" "$rc"

# 4. The success path logs the measured duration, so the number is an assertion
# rather than something to be inferred from timestamps -- which is how this
# whole family of defects had to be found in the first place.
rq_reset 'exit 0'
out=$(rq_run2); rc=$?
check "remote-window: a freeze still in force and inside budget passes" "0" "$rc"
case "$out" in *"freeze window "*"budget"*"confirmed still frozen"*)
    check "remote-window: ...and the duration is logged" "y" "y" ;;
  *) check "remote-window: ...and the duration is logged" "y" "n ($out)" ;; esac

# 5. An unreadable fsfreeze-status on a RUNNING qemu guest is a refusal here
# too, not a freeze-and-hope (REV-20260801-023's rule, ported).
rq_reset 'exit 0'
out=$(QFROZEN=unknown rq_run2); rc=$?
check "remote-window: an unreadable fsfreeze-status refuses" "5" "$rc"
check "remote-window: ...and takes no snapshot" "no" "$(rq_snapshotted)"

# 6. The budget travels with the run rather than being hardcoded on the far
# side, so one host's slow guest does not force a fleet-wide default.
if grep -q 'local qwindow="${QUIESCE_MAX_WINDOW:-5}"' "$REPO/lib-zfs-snap.sh"; then
    check "remote-window: the budget is passed from the caller" "y" "y"
else
    check "remote-window: the budget is passed from the caller" "y" "n"
fi

# ---- the boundary belongs to EVERY pool, not to the run (REV-20260802-029) --
#
# ZFS is atomic within a pool and cannot be atomic across pools, so a job that
# spans two pools is two separate `zfs snapshot` commands. Checking the freeze
# once, before the loop, certified a boundary that only the FIRST command
# actually had: a slow or blocked first snapshot can consume the whole window,
# and the second pool is then taken outside a freeze nobody re-checked.
#
# This was REV-20260801-025 F1. It stayed open while F2 (the remote path) was
# done, and no response to REV-025 was ever written -- the reviewer had to raise
# it a second time. Recorded here because a finding that is silently carried is
# indistinguishable, from the outside, from one that was never read.

# REMOTE path. The zfs stub sleeps on the FIRST pool's snapshot, which is what
# makes the second pool's check fail on the deadline rather than on the guest.
rq_reset 'exit 0'
cat > "$RQ_D/bin/zfs" <<'EOF'
#!/bin/bash
echo "zfs $*" >> "$TRACE"
# Only the snapshot of the first pool is slow. `sleep` here stands in for a pool
# that is busy, resilvering, or simply large.
case "$*" in *tanka/*) sleep 3 ;; esac
exit 0
EOF
chmod +x "$RQ_D/bin/zfs"
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 1 1 rpool/data/vm-100-disk-0 \
           2 tanka/x@t tankb/y@t 2>&1); rc=$?
check "twopool-remote: the run refuses rather than snapshotting pool two" "5" "$rc"
check "twopool-remote: pool one WAS snapshotted (inside the window)" "1" \
      "$(grep -c 'zfs snapshot .*tanka/x@t' "$RQ_D/trace")"
check "twopool-remote: pool two was NEVER snapshotted" "0" \
      "$(grep -c 'tankb/y@t' "$RQ_D/trace")"
case "$out" in *"before the snapshot of pool tankb"*)
    check "twopool-remote: ...and the refusal names the pool it stopped at" "y" "y" ;;
  *) check "twopool-remote: ...and the refusal names the pool it stopped at" "y" "n ($out)" ;; esac
# Guaranteed thaw survives the refusal -- that is the one thing a mid-loop exit
# must not lose.
case "$(cat "$RQ_D/trace")" in *"helper thaw 100"*)
    check "twopool-remote: the guest is thawed on the refusal path" "y" "y" ;;
  *) check "twopool-remote: the guest is thawed on the refusal path" "y" "n" ;; esac

# ...and with a budget that the slow pool does not exhaust, BOTH pools are
# snapshotted -- so the refusal above is about the deadline, not about there
# being two pools.
rq_reset 'exit 0'
out=$(TRACE="$RQ_D/trace" QSTATE="$RQ_D/qs" PATH="$RQ_D/bin:$PATH" \
      bash "$RQ_D/rq.sh" agent 30 "" 30 1 rpool/data/vm-100-disk-0 \
           2 tanka/x@t tankb/y@t 2>&1); rc=$?
check "twopool-remote: inside budget, both pools are snapshotted" "0" "$rc"
check "twopool-remote: ...pool two included" "1" \
      "$(grep -c 'tankb/y@t' "$RQ_D/trace")"
# The window is reported per pool, so the number grows visibly instead of being
# quoted once for a run that took much longer.
check "twopool-remote: the window is reported for each pool" "2" \
      "$(printf '%s\n' "$out" | grep -c 'confirmed still frozen before the snapshot of pool')"

# LOCAL path: the same invariant, asserted where it lives. snapsend.sh cannot be
# driven end to end without root and ZFS, so this pins the structure -- the
# check inside the loop, and the thaw on its refusal path.
loop=$(sed -n '/for quiesce_pool in "\${!QUIESCE_SNAPS_BY_POOL\[@\]}"; do/,/^    done$/p' "$REPO/snapsend.sh")
case "$loop" in
    *'quiesce_still_frozen "pool '*) check "twopool-local: the check is INSIDE the per-pool loop" "0" "0" ;;
    *) check "twopool-local: the check is INSIDE the per-pool loop" "0" "1" ;;
esac
# ...and it must come before the zfs snapshot of that pool, not after it.
before=$(printf '%s\n' "$loop" | grep -n 'quiesce_still_frozen' | head -1 | cut -d: -f1)
after=$(printf '%s\n' "$loop" | grep -n 'zfs snapshot' | head -1 | cut -d: -f1)
if [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ]; then
    check "twopool-local: ...and before that pool's zfs snapshot" "0" "0"
else
    check "twopool-local: ...and before that pool's zfs snapshot" "0" "1"
fi
# The thaw moved into quiesce_abandon_set, which is the ONE exit for "this set
# will never be completed" -- so the assertion follows it there rather than
# looking for the call it used to make inline.
case "$loop" in
    *quiesce_abandon_set*) check "twopool-local: its refusal path goes through the abandon exit" "0" "0" ;;
    *) check "twopool-local: its refusal path goes through the abandon exit" "0" "1" ;;
esac
ab=$(sed -n '/^quiesce_abandon_set() {/,/^}$/p' "$REPO/lib-zfs-snap.sh")
case "$ab" in
    *quiesce_thaw_all*) check "twopool-local: ...and that exit still thaws" "0" "0" ;;
    *) check "twopool-local: ...and that exit still thaws" "0" "1" ;;
esac

# ---- an incomplete set is removed, not explained (REV-20260802-030) --------
#
# REV-029 made the boundary per-pool. That left this shape explicit: pool A is
# snapshotted inside a valid freeze, the boundary then fails, pool B is refused
# -- and pool A's snapshot survives. I argued that was safe because A was taken
# while the freeze held. That proves the consistency of A. It says nothing about
# leaving an incomplete SET in the namespace everything downstream reads:
#
#   * snapsend/snapget -e take src_snaps[-1], the NEWEST matching the prefix
#     (snapsend.sh, USE_EXISTING_SNAPSHOT branch). A later tier job would ship
#     pool A at T and pool B at T-1 as though both were the current tier;
#   * check-snap-age.sh compares the newest snapshot per dataset against a
#     threshold, so ONE missed interval on pool B sits inside the warn window
#     and nothing anywhere says "this set is partial";
#   * count-based retention gives the orphan a slot in pool A's ladder that has
#     no counterpart in B's.
#
# So the set is destroyed. Everything below drives the REAL remote script.
CL="$RQ_D"

# 1+2. Two pools, the deadline fails between them: pool B is never touched...
rq_reset 'exit 0'
cat > "$CL/bin/zfs" <<'EOF'
#!/bin/bash
echo "zfs $*" >> "$TRACE"
case "$*" in
  *snapshot*tanka/*) sleep 3 ;;
  *destroy*) [ -n "${QNODESTROY:-}" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$CL/bin/zfs"
out=$(TRACE="$CL/trace" QSTATE="$CL/qs" PATH="$CL/bin:$PATH" \
      bash "$CL/rq.sh" agent 30 "" 1 1 rpool/data/vm-100-disk-0 \
           2 tanka/x@t tankb/y@t 2>&1); rc=$?
check "cleanup: pool two is never snapshotted" "0" "$(grep -c 'snapshot.*tankb/y@t' "$CL/trace")"

# 3. ...and pool A's snapshot, created by THIS invocation, is removed again.
check "cleanup: the snapshot this run created is destroyed" "1" \
      "$(grep -c 'zfs destroy.*tanka/x@t' "$CL/trace")"
check "cleanup: and the run reports nothing committed" "5" "$rc"
case "$out" in *"nothing committed"*) check "cleanup: ...in those words" "y" "y" ;;
  *) check "cleanup: ...in those words" "y" "n ($out)" ;; esac

# Nothing that this run did not create may be touched. The ledger is written
# from what zfs confirmed, never derived, so the only destroy issued is for the
# one snapshot it made.
check "cleanup: exactly one destroy was issued, for exactly that snapshot" "1" \
      "$(grep -c '^zfs destroy' "$CL/trace")"

# 4. Cleanup itself fails -> a DISTINCT hard failure that names the survivor.
rq_reset 'exit 0'
out=$(TRACE="$CL/trace" QSTATE="$CL/qs" QNODESTROY=1 PATH="$CL/bin:$PATH" \
      bash "$CL/rq.sh" agent 30 "" 1 1 rpool/data/vm-100-disk-0 \
           2 tanka/x@t tankb/y@t 2>&1); rc=$?
check "cleanup: an unremovable survivor is a distinct exit code" "7" "$rc"
case "$out" in *"ROLLBACK INCOMPLETE"*) check "cleanup: ...announced as such" "y" "y" ;;
  *) check "cleanup: ...announced as such" "y" "n ($out)" ;; esac
case "$out" in *"tanka/x@t"*) check "cleanup: ...naming the exact snapshot that remains" "y" "y" ;;
  *) check "cleanup: ...naming the exact snapshot that remains" "y" "n ($out)" ;; esac
case "$out" in *"zfs destroy"*) check "cleanup: ...and the command to remove it" "y" "y" ;;
  *) check "cleanup: ...and the command to remove it" "y" "n" ;; esac
# The thaw must survive the worst path of all.
case "$(cat "$CL/trace")" in *"helper thaw 100"*)
    check "cleanup: the guest is thawed even when the rollback failed" "y" "y" ;;
  *) check "cleanup: the guest is thawed even when the rollback failed" "y" "n" ;; esac

# 5. A following NORMAL run is not influenced by the failed one: it creates and
# uses a complete set of its own. The failed run destroyed its snapshot, so the
# next run's ledger and namespace start clean.
rq_reset 'exit 0'
out=$(TRACE="$CL/trace" QSTATE="$CL/qs" PATH="$CL/bin:$PATH" \
      bash "$CL/rq.sh" agent 30 "" 30 1 rpool/data/vm-100-disk-0 \
           2 tanka/x2@t tankb/y2@t 2>&1); rc=$?
check "cleanup: the next run completes" "0" "$rc"
check "cleanup: ...snapshotting BOTH pools" "2" \
      "$(grep -c 'zfs snapshot' "$CL/trace")"
check "cleanup: ...and destroying nothing" "0" "$(grep -c '^zfs destroy' "$CL/trace")"

# A run that fails BEFORE creating anything says so rather than reporting a
# rollback it never had to do.
rq_reset 'exit 0'
out=$(QTHAWS_ITSELF=1 rq_run2); rc=$?
case "$out" in *"had created no snapshot yet"*)
    check "cleanup: a failure before the first pool says nothing was created" "y" "y" ;;
  *) check "cleanup: a failure before the first pool says nothing was created" "y" "n ($out)" ;; esac

# LOCAL path: same contract, pinned where it lives.
ab=$(sed -n '/^quiesce_abandon_set() {/,/^}$/p' "$REPO/lib-zfs-snap.sh")
case "$ab" in
    *quiesce_destroy_created*) check "cleanup-local: the abandon exit destroys what the run created" "0" "0" ;;
    *) check "cleanup-local: the abandon exit destroys what the run created" "0" "1" ;;
esac
case "$ab" in
    *"rc=7"*) check "cleanup-local: an incomplete rollback has its own exit code" "0" "0" ;;
    *) check "cleanup-local: an incomplete rollback has its own exit code" "0" "1" ;;
esac
# The ledger is appended only AFTER zfs confirms the snapshot, so it can never
# name something that does not exist -- which is what makes "never delete a
# pre-existing snapshot" true by construction rather than by care.
loop=$(sed -n '/for quiesce_pool in "\${!QUIESCE_SNAPS_BY_POOL\[@\]}"; do/,/^    done$/p' "$REPO/snapsend.sh")
snapline=$(printf '%s\n' "$loop" | grep -n 'zfs snapshot' | head -1 | cut -d: -f1)
ledgerline=$(printf '%s\n' "$loop" | grep -n 'QUIESCE_CREATED+=' | head -1 | cut -d: -f1)
if [ -n "$snapline" ] && [ -n "$ledgerline" ] && [ "$snapline" -lt "$ledgerline" ]; then
    check "cleanup-local: the ledger records only what zfs confirmed" "0" "0"
else
    check "cleanup-local: the ledger records only what zfs confirmed" "0" "1"
fi

# ---- the rollback report itself must not fail open (REV-20260802-031) ------
#
# The first version of abandon_set staged survivors in a SECOND temporary file.
# If that mktemp failed while a `zfs destroy` also failed, the survivor could
# not be recorded -- so the function printed "nothing committed" and returned
# the clean-rollback code while an ordinary-looking snapshot from an incomplete
# set was still there for the next -e job to pick up.
#
# The review asks for an injected failure of that mktemp. There is nothing left
# to inject: the file is GONE. Each survivor is printed the moment it is known
# and a flag -- which cannot fail to be set -- decides the exit code, so the
# failure mode is absent by construction rather than handled. That is asserted
# structurally, and the BEHAVIOUR it used to break is already covered by the
# cleanup section above (a failing destroy exits 7, names the survivor, thaws).
#
# A first attempt at the injection made mktemp fail globally, which also broke
# thaw_all's own mktemp -- the run exited 6 with the guest still frozen, and the
# assertion measured that instead of what it claimed to. Recorded because a too-
# broad injection passes or fails for the wrong reason just as silently as a
# too-narrow one.
# Both halves of the rollback: the per-snapshot work moved into abandon_one
# (REV-20260802-032) so the file inventory and the in-memory one cannot drift,
# and a guard that reads only one of the two would go quietly blind.
ab=$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | sed -n '/^abandon_one() {/,/^}$/p;/^abandon_set() {/,/^}$/p')
# CODE only. The first version of this check matched the word `mktemp` in the
# comment explaining why there is no mktemp -- a guard that breaks the moment
# someone documents the thing it guards is worse than no guard.
abcode=$(printf "%s" "$ab" | grep -vE "^[[:space:]]*#")
case "$abcode" in
    *mktemp*) check "failopen: abandon_set allocates no temporary file at all" "0" "1" ;;
    *)        check "failopen: abandon_set allocates no temporary file at all" "0" "0" ;;
esac
# The survivor is printed from the loop, so there is no window in which it is
# known but unrecorded.
case "$ab" in
    *'ROLLBACK INCOMPLETE'*) check "failopen: ...and reports each survivor as it is found" "0" "0" ;;
    *) check "failopen: ...and reports each survivor as it is found" "0" "1" ;;
esac
# "nothing committed" must be reachable only when the flag says so.
nc=$(printf '%s\n' "$ab" | grep -n 'nothing committed -- every snapshot' | cut -d: -f1)
fl=$(printf '%s\n' "$ab" | grep -n 'elif \[ "\$ab_failed" -eq 1 \]' | cut -d: -f1)
if [ -n "$nc" ] && [ -n "$fl" ] && [ "$fl" -lt "$nc" ]; then
    check "failopen: the clean-rollback message sits behind the failure flag" "0" "0"
else
    check "failopen: the clean-rollback message sits behind the failure flag" "0" "1"
fi

# ---- the rollback must account for the WHOLE set (REV-20260802-032) --------
#
# REV-031's second half was implemented as: on a failed ledger append, print
# THAT snapshot and exit 7 on the spot. REV-032 named exactly what that misses.
# `zfs snapshot` is atomic per POOL, so when an append fails the whole group
# already exists and earlier pools may exist too. The alarm listed one name out
# of a set, called itself ROLLBACK INCOMPLETE without attempting any rollback,
# and left the rest as ordinary snapshots for the next -e job to consume.
#
# The fix is not a second inventory for what the first could not hold. The
# ledger is now an ARRAY, like the local path has always used, so the storage
# that could fail is gone: there is one inventory, an append to it cannot fail,
# and nothing outside this shell ever needed a file. What is left to prove is
# that the ONE inventory is complete -- across pools, across group members --
# and that is what this section drives, through the real remote script.
#
# Trying to inject the old failure taught this section its shape: a stub that
# replaced the ledger file with a directory between pools also DESTROYED pool
# one's record, so the run could no longer name a snapshot it had really made.
# That is not an artefact of the stub. It is what a file-backed ledger is worth
# once writing to it stops working.
rq_reset 'exit 0'
cat > "$CL/bin/zfs" <<'EOF'
#!/bin/bash
echo "zfs $*" >> "$TRACE"
case "$*" in
  *snapshot*tankc/*) exit 1 ;;   # the third pool fails, after two succeeded
  *destroy*)
    # QNODESTROY is a LIST, so a survivor can be chosen per snapshot instead of
    # all-or-nothing -- otherwise "every survivor is named" and "the removed
    # ones are not" cannot be told apart.
    for n in ${QNODESTROY:-}; do
        case "$*" in *"$n"*) exit 1 ;; esac
    done ;;
esac
exit 0
EOF
chmod +x "$CL/bin/zfs"
lg_run() {   # <QNODESTROY list>
    rm -f "$CL/trace"
    QNODESTROY="$1" TRACE="$CL/trace" QSTATE="$CL/qs" PATH="$CL/bin:$PATH" \
      bash "$CL/rq.sh" agent 30 "" 30 1 rpool/data/vm-100-disk-0 \
           4 tanka/x@t tankb/y@t tankb/z@t tankc/w@t 2>&1
}

# A pool is one atomic call, so both of pool two's snapshots exist together --
# which is why the set, not the name, is the unit the rollback has to handle.
out=$(lg_run ""); rc=$?
check "ledger: a pool group is created in ONE atomic call" "1" \
      "$(grep -c 'zfs snapshot tankb/y@t tankb/z@t' "$CL/trace")"
check "ledger: the run stops at the pool that failed" "4" "$rc"

# Every member of the completed group goes, not just the first...
check "ledger: the whole group of the last completed pool is destroyed" "1" \
      "$(grep -c 'zfs destroy tankb/y@t' "$CL/trace")"
check "ledger: ...including its second member" "1" \
      "$(grep -c 'zfs destroy tankb/z@t' "$CL/trace")"
# ...and so does the pool completed before it.
check "ledger: ...and the snapshot from the EARLIER pool" "1" \
      "$(grep -c 'zfs destroy tanka/x@t' "$CL/trace")"
# Exactly three: nothing ordinary is left behind, and nothing is destroyed
# twice -- a double destroy would fail the second time and be reported as a
# survivor that is in fact already gone.
check "ledger: exactly three destroys, none repeated" "3" \
      "$(grep -c '^zfs destroy' "$CL/trace")"
# The pool that never got made is not invented as something to remove.
check "ledger: the pool that failed is never destroyed" "0" \
      "$(grep -c 'destroy tankc/w@t' "$CL/trace")"
case "$out" in *"nothing committed -- every snapshot"*)
    check "ledger: a complete rollback says nothing was committed" "y" "y" ;;
  *) check "ledger: a complete rollback says nothing was committed" "y" "n ($out)" ;; esac
case "$out" in *"ROLLBACK INCOMPLETE"*)
    check "ledger: ...and is NOT announced as incomplete" "y" "n ($out)" ;;
  *) check "ledger: ...and is NOT announced as incomplete" "y" "y" ;; esac
case "$(cat "$CL/trace")" in *"helper thaw 100"*)
    check "ledger: the guest is thawed" "y" "y" ;;
  *) check "ledger: the guest is thawed" "y" "n" ;; esac

# Now make the rollback itself fail -- one snapshot from the earlier pool and
# one from the middle of the last group, so a report that can only see part of
# the set is caught.
out=$(lg_run "tanka/x@t tankb/z@t"); rc=$?
check "ledger: an unremovable survivor is exit 7" "7" "$rc"
case "$out" in *"tanka/x@t"*)
    check "ledger: ...the survivor from the earlier pool is named" "y" "y" ;;
  *) check "ledger: ...the survivor from the earlier pool is named" "y" "n ($out)" ;; esac
case "$out" in *"tankb/z@t"*)
    check "ledger: ...the survivor from the last group is named too" "y" "y" ;;
  *) check "ledger: ...the survivor from the last group is named too" "y" "n ($out)" ;; esac
case "$out" in *"remove by hand: zfs destroy"*)
    check "ledger: ...each with the exact removal command" "y" "y" ;;
  *) check "ledger: ...each with the exact removal command" "y" "n ($out)" ;; esac
# Over-reporting is its own defect: it sends an operator hunting for a snapshot
# that does not exist, and the next real alarm gets read as noise.
case "$out" in *"removed tankb/y@t"*)
    check "ledger: ...and the one that WAS removed is not listed as a survivor" "y" "y" ;;
  *) check "ledger: ...and the one that WAS removed is not listed as a survivor" "y" "n ($out)" ;; esac
case "$(cat "$CL/trace")" in *"helper thaw 100"*)
    check "ledger: the guest is thawed even when the rollback failed" "y" "y" ;;
  *) check "ledger: the guest is thawed even when the rollback failed" "y" "n" ;; esac

# STRUCTURE. The failure class REV-031 and REV-032 are both about is gone
# rather than handled, so what has to be pinned is its absence.
#
# Temporary files still exist in this script, and must: the frozen list is read
# by the DEADMAN, another process entirely, so it has to be on disk. The
# created-snapshot inventory never was, which is why it does not.
stray=$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | grep -vE '^[[:space:]]*#' \
        | grep 'mktemp' | grep -cvE 'frozen_file|left=')
check "ledger: every temporary file left belongs to the frozen list" "0" "$stray"
check "ledger: nothing backs the created-snapshot inventory with a file" "0" \
      "$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | grep -c 'created_file')"
# One inventory, walked in one place, so there is no second home a survivor
# could hide in.
nrd=$(printf '%s\n' "$ab" | grep -c 'for s in "\${created\[@\]}"')
check "ledger: the rollback walks exactly one inventory" "1" "$nrd"
# Recorded only after zfs confirms: a planned name is not evidence that a
# snapshot exists, and cleanup that cannot tell the difference destroys on a
# guess. Same rule as the local path, asserted the same way.
snapl=$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | grep -n 'zfs snapshot "\${group\[@\]}"' | head -1 | cut -d: -f1)
addl=$(printf '%s\n' "$ZFS_REMOTE_QUIESCE_SCRIPT" | grep -n 'created+=' | head -1 | cut -d: -f1)
if [ -n "$snapl" ] && [ -n "$addl" ] && [ "$snapl" -lt "$addl" ]; then
    check "ledger: the inventory records only what zfs confirmed" "0" "0"
else
    check "ledger: the inventory records only what zfs confirmed" "0" "1"
fi

# The local path has no such mode -- QUIESCE_CREATED is a bash array and an
# append cannot fail -- which is why this section is remote-only. Pinned so the
# asymmetry stays a decision rather than becoming an oversight.
case "$(sed -n '/^quiesce_abandon_set() {/,/^}$/p' "$REPO/lib-zfs-snap.sh")" in
    *mktemp*) check "failopen: the local abandon path allocates nothing either" "0" "1" ;;
    *)        check "failopen: the local abandon path allocates nothing either" "0" "0" ;;
esac

# ---- a DISABLED pair gate is named, not guessed at -------------------------
#
# Measured on metropolis 2026-08-20: with the peer's gate disabled, the engine
# was handed
#     PAIR_DISABLED: relationship pve1 is disabled by administrator
# and reported "exit 93 -- e.g. no 'zfs' in this account's PATH", plus a pool
# alert saying that peer's pool was UNKNOWN. The answer was in hand and a
# different one was guessed -- the same family as the exit-255 confusion the
# probe block in the library exists to end.

check "gate: RC_DISABLED alone is recognised"      "0" "$(remote_refused_by_gate 93; echo $?)"
check "gate: the PAIR_DISABLED line alone is too"  "0" "$(remote_refused_by_gate 1 'PAIR_DISABLED: relationship x is disabled by administrator'; echo $?)"
# Controls in the other direction. A recogniser that says yes to everything
# would "fix" this by relabelling every remote failure as an administrative
# block -- which is the original bug wearing the opposite coat.
check "gate: an ordinary remote failure is NOT a gate refusal" "1" "$(remote_refused_by_gate 127 'bash: zfs: command not found'; echo $?)"
check "gate: a clean run is NOT a gate refusal"               "1" "$(remote_refused_by_gate 0 'ONLINE'; echo $?)"

# probe_dataset through an ssh stub that behaves exactly as the gate does.
probe_out=$(
    ssh() { echo "PAIR_DISABLED: relationship pve1 is disabled by administrator" >&2; return 93; }
    log() { shift; echo "$*"; }
    probe_dataset hdd/lab4/src zfsbackup-pve1 192.168.28.99 source 2>&1
)
case "$probe_out" in
    *"REFUSES this relationship"*"enable-client"*) check "gate: probe_dataset names the gate and the way back" "0" "0" ;;
    *) check "gate: probe_dataset names the gate and the way back" "0" "1"; echo "     got: $probe_out" ;;
esac
case "$probe_out" in
    *PATH*) check "gate: probe_dataset no longer blames the account's PATH" "0" "1"; echo "     got: $probe_out" ;;
    *)      check "gate: probe_dataset no longer blames the account's PATH" "0" "0" ;;
esac

# pool_health reports the refusal as its own state, and check_pool_health must
# raise NO storage alarm for it. An administrative block is not a disk fault,
# and mailing one as the other is how a real DEGRADED comes to be ignored.
ph=$(
    ssh() { return 93; }
    declare -A POOL_HEALTH_CACHE=()
    pool_health hdd zfsbackup-pve1@192.168.28.99
)
check "gate: pool_health reports PAIR-DISABLED, not UNKNOWN" "PAIR-DISABLED" "$ph"

# Found by the line above, and worth its own guard: both cache-keyed helpers
# used to build their key inside the same `local` that declared its inputs.
# Bash expands those words BEFORE the builtin runs, so the key was read from
# the OUTER scope -- unbound under set -u with no caller variable in sight, and
# silently the WRONG VALUE when one existed. It worked only because
# check_pool_health declares its own `local pool` immediately before calling.
# The stake is the cache key, so a wrong one crosses pools.
poisoned=$(
    pool=SOMEONE-ELSES-POOL         # exactly the dynamic-scope trap
    ssh() { printf 'ONLINE'; return 0; }
    declare -A POOL_HEALTH_CACHE=()
    pool_health hdd user@peer
    printf '|'
    printf '%s' "${!POOL_HEALTH_CACHE[*]}"
)
case "$poisoned" in
    "ONLINE|hdd/user@peer") check "scope: pool_health keys the cache on its ARGUMENT, not an outer 'pool'" "0" "0" ;;
    *) check "scope: pool_health keys the cache on its ARGUMENT, not an outer 'pool'" "0" "1"; echo "     got: $poisoned" ;;
esac
csend_poisoned=$(
    pool=SOMEONE-ELSES-POOL
    ssh() { printf 'active'; return 0; }
    declare -A CSEND_POOL_CACHE=()
    csend_pool_has hdd lz4_compress user@peer >/dev/null
    printf '%s' "${!CSEND_POOL_CACHE[*]}"
)
check "scope: csend_pool_has keys the cache on its ARGUMENT too" "hdd/lz4_compress/user@peer" "$csend_poisoned"

notify_marker="$TMPD/gate-notified"
printf '#!/bin/sh\ntouch "%s"\n' "$notify_marker" > "$TMPD/gate-notify"; chmod +x "$TMPD/gate-notify"
pool_out=$(
    ssh() { return 93; }
    declare -A POOL_HEALTH_CACHE=()
    NOTIFY_SCRIPT="$TMPD/gate-notify"
    log() { shift; echo "$*"; }
    check_pool_health hdd/lab4/src zfsbackup-pve1 192.168.28.99 2>&1
)
check "gate: a disabled peer raises NO pool alert" "1" "$([ -e "$notify_marker" ]; echo $?)"
case "$pool_out" in
    *"not allowed to ask"*) check "gate: check_pool_health says why it could not answer" "0" "0" ;;
    *) check "gate: check_pool_health says why it could not answer" "0" "1"; echo "     got: $pool_out" ;;
esac

# ============================================================================
# WHAT A FAILED FREEZE DOES. Reviewer contract of 2026-08-26 (PR #165), with the
# default INVERTED by owner direction on 2026-08-27: a failed freeze now takes
# the snapshot -- crash-consistent, `_crash_` in the name, exit 8 -- and
# `,strict` is the per-tier way back to refusing.
#
# Every assertion below still has its NEGATIVE half in the same block. That
# requirement did not change direction with the default: what used to need
# proving was that the fail-closed door could be opened deliberately, and what
# needs proving now is that `,strict` still shuts it.
# ============================================================================

# ---- the parser ------------------------------------------------------------
# The positive half is not decoration: `local raw="$1" mode="$raw"` expands every
# word before the builtin assigns any of them, so the first version of this
# parser rejected `auto` -- the value production uses -- while accepting every
# `,degrade` form. Only the bare modes catch that.
pm() {   # <value> -> "mode/degrade" or "REJECT"
    local v="$1"
    # QUIESCE_DEGRADE is poisoned rather than pre-set to either answer: a parser
    # path that forgot to assign it would otherwise read as whichever value this
    # helper happened to choose, which is exactly how a default flip hides.
    ( QUIESCE_MODE=""; QUIESCE_DEGRADE=9
      quiesce_parse_mode "$v" 2>/dev/null || { printf 'REJECT'; exit 0; }
      printf '%s/%s' "$QUIESCE_MODE" "$QUIESCE_DEGRADE" )
}
# THE OWNER'S 2026-08-27 DIRECTION, stated as the four bare modes. `auto` is the
# one production runs, and it must degrade WITHOUT anyone having written a
# qualifier -- that sentence is the whole change.
check "degrade-parse: bare agent degrades by default"  "agent/1" "$(pm agent)"
check "degrade-parse: bare sync degrades by default"   "sync/1"  "$(pm sync)"
check "degrade-parse: bare auto degrades by default"   "auto/1"  "$(pm auto)"
# `no` is the built-in -q value of both engines, so this line is what stands
# between the flip and every run in the fleet refusing at startup: `no` takes no
# qualifier, and it must still parse, and it must not claim to degrade -- nothing
# is ever frozen, so nothing can fail to freeze.
check "degrade-parse: bare no still parses, and does not degrade" "no/0" "$(pm no)"
# NEGATIVE HALF. `,strict` is now the only qualifier that changes anything, and
# it must restore the previous behaviour exactly.
check "degrade-parse: auto,strict refuses to degrade"  "auto/0"  "$(pm auto,strict)"
check "degrade-parse: agent,strict refuses to degrade" "agent/0" "$(pm agent,strict)"
check "degrade-parse: sync,strict refuses to degrade"  "sync/0"  "$(pm sync,strict)"
# COMPATIBILITY. `profiles/prod.conf` and every crontab generated since
# 2026-08-26 carry `,degrade`; it must keep parsing, and mean what it always did.
check "degrade-parse: auto,degrade still accepted"     "auto/1"  "$(pm auto,degrade)"
check "degrade-parse: agent,degrade still accepted"    "agent/1" "$(pm agent,degrade)"
check "degrade-parse: sync,degrade still accepted"     "sync/1"  "$(pm sync,degrade)"
# The errors. A qualifier on `no` asks for a policy about a freeze that never
# happens -- true of both spellings, and the message must name the one written.
# The rest are typos in the one field that decides fail-open against fail-closed,
# and must not be read as either half of themselves.
check "degrade-parse: no,degrade is refused"  "REJECT"  "$(pm no,degrade)"
check "degrade-parse: no,strict is refused"   "REJECT"  "$(pm no,strict)"
check "degrade-parse: a misspelled ,degrade is refused"  "REJECT" "$(pm auto,Degrade)"
check "degrade-parse: a misspelled ,strict is refused"   "REJECT" "$(pm auto,Strict)"
check "degrade-parse: a repeated ,degrade is refused"    "REJECT" "$(pm auto,degrade,degrade)"
check "degrade-parse: a repeated ,strict is refused"     "REJECT" "$(pm auto,strict,strict)"
check "degrade-parse: mixed qualifiers are refused"      "REJECT" "$(pm auto,strict,degrade)"
check "degrade-parse: an unknown qualifier is refused"   "REJECT" "$(pm auto,foo)"
check "degrade-parse: an unknown mode is still refused"  "REJECT" "$(pm bogus)"
# The message must name `,strict` where an operator will look for it -- the
# rejection of an unknown qualifier is the one place a typo lands.
qerr="$( ( quiesce_parse_mode auto,foo ) 2>&1 )"
case "$qerr" in
    *",strict"*) check "degrade-parse: the rejection names ',strict' as the way back" "y" "y" ;;
    *)           check "degrade-parse: the rejection names ',strict' as the way back" "y" "n ($qerr)" ;;
esac

# THE BUILT-IN, read without the parser. Sourcing the library must leave
# QUIESCE_DEGRADE at 1: quiesce_remote_run's rc mapping reads the VARIABLE, not
# the parser, and a library whose default stayed 0 would degrade on PUSH and
# refuse on PULL for the same configuration.
libdef="$( env -u QUIESCE_DEGRADE bash -c 'source ./lib-zfs-snap.sh >/dev/null 2>&1; printf %s "$QUIESCE_DEGRADE"' )"
check "degrade-default: the library's own default is 1" "1" "$libdef"
# NEGATIVE CONTROL for that: the environment still wins, or the suites could not
# pin the value and the assertion above would be measuring nothing.
libenv="$( QUIESCE_DEGRADE=0 bash -c 'source ./lib-zfs-snap.sh >/dev/null 2>&1; printf %s "$QUIESCE_DEGRADE"' )"
check "degrade-default: an environment value still overrides it" "0" "$libenv"

# ---- the name --------------------------------------------------------------
# The marker goes BETWEEN the family and the timestamp, and both halves of that
# sentence are load-bearing: after the family so retention and the age monitor
# still match by prefix, before the timestamp so `zfs list -s creation` ordering
# is untouched.
check "degrade-name: the marker follows the family" \
      "automated_daily_crash_" "$(quiesce_crash_message automated_daily_)"
check "degrade-name: a family written without its trailing _ gets one" \
      "automated_daily_crash_" "$(quiesce_crash_message automated_daily)"
check "degrade-name: an empty -m does not produce a leading _" \
      "crash_" "$(quiesce_crash_message '')"
# The property the frozen delsnaps.sh and check-snap-age.sh depend on, asserted
# as a property rather than as a string: the degraded name is still a member of
# the family the operator configured.
degname="tank/a@$(quiesce_crash_message automated_daily_)2026-08-26_20-50-40"
case "$degname" in
    tank/a@automated_daily_*) check "degrade-name: still matches the family prefix" "0" "0" ;;
    *) check "degrade-name: still matches the family prefix" "0" "1 ($degname)" ;;
esac
case "$degname" in
    *crash_2026-08-26_20-50-40) check "degrade-name: the timestamp stays last" "0" "0" ;;
    *) check "degrade-name: the timestamp stays last" "0" "1 ($degname)" ;;
esac

# ---- the gate --------------------------------------------------------------
# quiesce_degrade_gate is the only thing that may say "take a crash-consistent
# set instead". It says so only from a clean state, and the three ways of not
# being clean are each checked here.
gate() {   # <degrade> <created...> -> "rc|QUIESCE_DEGRADED|thawcalls"
    local deg="$1" zfsrc="$2" thawrc="$3" ncreated="$4" nfrozen="$5"
    ( QUIESCE_DEGRADE="$deg"; QUIESCE_DEGRADED=0
      QUIESCE_CREATED=(); QUIESCE_FROZEN=(); QUIESCE_HANDLED=(); QUIESCE_PENDING_VMS=()
      QUIESCE_THAW_FAILED=0; QUIESCE_FREEZE_EPOCH=0
      [ "$ncreated" -gt 0 ] && QUIESCE_CREATED=(tank/a@s1)
      [ "$nfrozen"  -gt 0 ] && QUIESCE_FROZEN=(qemu:106)
      thawcalls=0
      zfs() { return "$zfsrc"; }
      quiesce_do_thaw() { thawcalls=$((thawcalls+1)); return "$thawrc"; }
      log() { :; }
      quiesce_degrade_gate "" "a test reason"; rc=$?
      printf '%s|%s|%s' "$rc" "$QUIESCE_DEGRADED" "$thawcalls" )
}
# NEGATIVE CONTROL, and the most important line in this block: without the
# opt-in the gate must refuse, so every caller keeps the behaviour it had.
check "degrade-gate: without ,degrade it refuses"        "1|0|0" "$(gate 0 0 0 0 0)"
check "degrade-gate: without ,degrade nothing is thawed" "1|0|0" "$(gate 0 0 0 0 1)"
# The ordinary case: nothing created, nothing frozen -- quiesce_init and
# quiesce_prepare both fail here, before a single guest is touched.
check "degrade-gate: with ,degrade and a clean state it agrees" "0|1|0" "$(gate 1 0 0 0 0)"
# Frozen guests are thawed BEFORE it agrees, and the thaw is proven by the call
# count, not by the log line.
check "degrade-gate: it thaws what this run froze before agreeing" "0|1|1" "$(gate 1 0 0 0 1)"
# A thaw that did not take is an outage. Contract condition 3: still fatal.
check "degrade-gate: a failed thaw is still fatal" "1|0|2" "$(gate 1 0 1 0 1)"
# A rollback that left snapshots behind. Contract condition 4: still fatal,
# because a crash set on top of a half-finished quiesced one leaves two
# overlapping answers to what the current tier snapshot is.
check "degrade-gate: a failed rollback is still fatal" "1|0|0" "$(gate 1 1 0 1 0)"
# ...and it thaws anyway on the way out, because the cleanup failing must not
# leave a guest frozen.
check "degrade-gate: a failed rollback still thaws" "1|0|1" "$(gate 1 1 0 1 1)"
# The clean rollback: the snapshot this run made inside the window is destroyed
# and the gate agrees.
check "degrade-gate: a clean rollback lets it agree" "0|1|0" "$(gate 1 0 0 1 0)"

# THE TWO HALVES JOINED. Everything above tests the parser against a number and
# the gate against a number; neither notices if the number stops travelling
# between them. This runs the real parser on a real -q value and hands whatever
# it produced to the real gate -- the behaviour the owner asked for, stated end
# to end.
pmgate() {   # <-q value> -> "rc|QUIESCE_DEGRADED"
    local v="$1"
    ( quiesce_parse_mode "$v" >/dev/null 2>&1 || { printf 'PARSE-REJECT'; exit 0; }
      QUIESCE_DEGRADED=0
      QUIESCE_CREATED=(); QUIESCE_FROZEN=(); QUIESCE_HANDLED=(); QUIESCE_PENDING_VMS=()
      QUIESCE_THAW_FAILED=0; QUIESCE_FREEZE_EPOCH=0
      zfs() { return 0; }
      quiesce_do_thaw() { return 0; }
      log() { :; }
      quiesce_degrade_gate "" "a test reason"; rc=$?
      printf '%s|%s' "$rc" "$QUIESCE_DEGRADED" )
}
check "degrade-chain: -q auto alone degrades a failed freeze" "0|1" "$(pmgate auto)"
check "degrade-chain: -q auto,strict refuses it"              "1|0" "$(pmgate auto,strict)"
check "degrade-chain: -q auto,degrade still degrades"         "0|1" "$(pmgate auto,degrade)"

# ---- the local refusals that stay fatal ------------------------------------
# `,degrade` answers "the freeze did not happen THIS TIME". It does not answer
# "this guest is not the kind this mode can freeze" (a config error that will
# never fix itself) and it does not answer "somebody else's freeze is in place".
# run_refuse returns 3 for a refusal that exits, and 1 for one that degraded.
QUIESCE_DEGRADE=1
r=$(run_refuse "id=106 kind=qemu running=yes frozen=yes")
check "degrade-fatal: a foreign freeze is fatal even with ,degrade" "3" "${r%%|*}"
r=$(run_refuse "id=102 kind=lxc running=yes frozen=unknown" 0 hdd/lxc/subvol-102-disk-0 agent)
check "degrade-fatal: a mode that cannot fit the guest is fatal even with ,degrade" "3" "${r%%|*}"
# ...while the runtime failures in the same function DO degrade, which is what
# makes the two lines above a discrimination rather than a blanket refusal.
r=$(run_refuse "id=106 kind=qemu running=yes frozen=unknown")
check "degrade-local: an unreachable agent degrades with ,degrade" "1" "${r%%|*}"
r=$(run_refuse "id=106 kind=qemu running=yes frozen=no" 1)
check "degrade-local: a freeze that did not take degrades with ,degrade" "1" "${r%%|*}"
QUIESCE_DEGRADE=0
# The same two WITHOUT the opt-in: the negative half of the same discrimination.
r=$(run_refuse "id=106 kind=qemu running=yes frozen=unknown")
check "degrade-local: an unreachable agent is still fatal without ,degrade" "3" "${r%%|*}"
r=$(run_refuse "id=106 kind=qemu running=yes frozen=no" 1)
check "degrade-local: a freeze that did not take is still fatal without ,degrade" "3" "${r%%|*}"

# ---- the diagnosis must survive the degradation ----------------------------
# Found by this suite on 2026-08-27, immediately after the default was flipped,
# and it is the defect the flip creates rather than one it exposes.
#
# Every one of these sites used to read
#
#     quiesce_degrade_gate "" "<short reason>" && return 1
#     log 0 "<what is wrong, and the command that fixes it>"
#     exit 3
#
# so the sentence carrying the REMEDY was reachable only on the path that
# refused. Under the old default that path was the common one and nobody
# noticed. Under the new one the operator gets "DEGRADING" every night, a
# `_crash_` snapshot every night, and never the line saying that the account is
# missing `--allow-quiesce` or that the guest is off the whitelist. A backup
# that keeps working while dropping the reason it is worse is how a fixable
# misconfiguration becomes permanent.
#
# So: the diagnosis is logged BEFORE the gate at every site, and these
# assertions check the DEGRADING path, because the refusing path already had it.
QUIESCE_DEGRADE=1
r=$(run_refuse "id=106 kind=qemu running=yes frozen=unknown")
case "$r" in
    *"could not read fsfreeze-status for running VM 106"*)
        check "degrade-diag: an unreachable agent still says WHAT was unreadable" "0" "0" ;;
    *)  check "degrade-diag: an unreachable agent still says WHAT was unreadable" "0" "1 ($r)" ;;
esac
r=$(run_refuse "id=106 kind=qemu running=yes frozen=no" 1)
case "$r" in
    *"did not respond to fsfreeze-freeze"*)
        check "degrade-diag: a freeze that did not take still says so" "0" "0" ;;
    *)  check "degrade-diag: a freeze that did not take still says so" "0" "1 ($r)" ;;
esac
r=$(run_refuse "id=101 kind=lxc running=yes frozen=unknown" 1 "hdd/lxc/subvol-101-disk-0")
case "$r" in
    *"dirty pages were never pushed into ZFS"*)
        check "degrade-diag: a failed container flush still says what was lost" "0" "0" ;;
    *)  check "degrade-diag: a failed container flush still says what was lost" "0" "1 ($r)" ;;
esac
# NEGATIVE CONTROL for the three above: under ,strict the same runs must carry
# the same diagnosis. Without this pair the assertions would pass against a
# build that had simply moved the text into the gate's own message, which reads
# the same here and would lose the per-site remedy everywhere else.
QUIESCE_DEGRADE=0
r=$(run_refuse "id=106 kind=qemu running=yes frozen=unknown")
case "$r" in
    *"could not read fsfreeze-status for running VM 106"*)
        check "degrade-diag: ...and ,strict says exactly the same thing" "0" "0" ;;
    *)  check "degrade-diag: ...and ,strict says exactly the same thing" "0" "1 ($r)" ;;
esac
# A REFUSAL SAYS NOTHING WAS TAKEN. The degrading path announces a crash-
# consistent snapshot; the strict path must be equally explicit that there is no
# snapshot at all, or the two outcomes are told apart only by an exit code.
case "$r" in
    *"NOTHING was snapshotted"*)
        check "degrade-diag: ...and states that nothing was snapshotted" "0" "0" ;;
    *)  check "degrade-diag: ...and states that nothing was snapshotted" "0" "1 ($r)" ;;
esac

# STRUCTURAL, and deliberately not a string check: the four sites above are the
# ones this suite can drive without root or a Proxmox cluster, and there are six.
# A future seventh must not reintroduce the shape. Every `quiesce_degrade_gate`
# call in the library has to be preceded by a `log 0` line, so whatever it
# decides, the operator has already been told what happened.
gate_lines="$(grep -n 'quiesce_degrade_gate ""' "$REPO/lib-zfs-snap.sh" | cut -d: -f1)"
bad_sites=0; n_sites=0
for gl in $gate_lines; do
    n_sites=$((n_sites + 1))
    prev="$(sed -n "$((gl - 1))p" "$REPO/lib-zfs-snap.sh")"
    case "$prev" in
        *"log 0 "*) ;;
        *) bad_sites=$((bad_sites + 1)); echo "     line $gl is preceded by: $prev" ;;
    esac
done
check "degrade-diag: every gate site logs its diagnosis first" "0" "$bad_sites"
# ...and the count is asserted too, so a build that DELETED the sites would not
# pass the line above by having nothing left to check.
if [ "$n_sites" -ge 6 ]; then
    check "degrade-diag: ...at all six known sites" "0" "0"
else
    check "degrade-diag: ...at all six known sites" "0" "1 (found $n_sites)"
fi

# ---- the remote half -------------------------------------------------------
# Nothing crosses the ssh boundary except an exit code: the remote script is
# shipped and run by `bash -s`, so no function defined in the library exists over
# there. The whole degrade decision for PULL is therefore this mapping, and it
# rests on the remote script's own contract -- 3 means it refused before freezing
# anything, 5 means it rolled back and thawed cleanly (a failure in either turns
# 5 into 7 or 6). Everything else stays exactly as it was.
rrun() {   # <ssh rc> <degrade> -> "rc|QUIESCE_DEGRADED"
    local sshrc="$1" deg="$2"
    ( QUIESCE_DEGRADE="$deg"; QUIESCE_DEGRADED=0; SSH_OPTS=()
      ssh() { return "$sshrc"; }
      log() { :; }
      quiesce_remote_run u h auto "" 120 tank/a -- tank/a@s1 >/dev/null 2>&1; rc=$?
      printf '%s|%s' "$rc" "$QUIESCE_DEGRADED" )
}
for rc in 0 3 4 5 6 7 255; do
    case "$rc" in 255) want="1|0" ;; *) want="$rc|0" ;; esac
    check "degrade-remote: without ,degrade rc $rc is unchanged" "$want" "$(rrun "$rc" 0)"
done
check "degrade-remote: rc 3 (refused before freezing) becomes 8" "8|1" "$(rrun 3 1)"
check "degrade-remote: rc 5 (rolled back and thawed) becomes 8"  "8|1" "$(rrun 5 1)"
check "degrade-remote: rc 0 stays 0"                             "0|0" "$(rrun 0 1)"
# The four that must NOT degrade, each for its own reason: 4 is `zfs snapshot`
# itself failing (the crash snapshot would use the same command), 6 is a guest
# still frozen, 7 is a rollback that left snapshots behind, and 255 is ssh --
# a link failure, which must never be reported as a quiesce policy decision.
check "degrade-remote: rc 4 (the snapshot itself failed) stays fatal" "4|0" "$(rrun 4 1)"
check "degrade-remote: rc 6 (a guest is still frozen) stays fatal"    "6|0" "$(rrun 6 1)"
check "degrade-remote: rc 7 (rollback incomplete) stays fatal"        "7|0" "$(rrun 7 1)"
check "degrade-remote: an ssh failure is not a degradable quiesce failure" "1|0" "$(rrun 255 1)"

# ---- what the engines do with it -------------------------------------------
# The end-to-end (a degraded run that transfers and lands) needs real pools and
# is a LIVE obligation, not a suite. What is checked here is that both engines
# reach the same three decisions from the same helper, since a drift between
# push and pull is the failure mode this project has already paid for twice.
for eng in snapsend.sh snapget.sh; do
    grep -q 'quiesce_parse_mode "$QUIESCE" || exit 1' "$REPO/$eng" \
        && check "degrade-engine: $eng parses -q through the shared parser" "0" "0" \
        || check "degrade-engine: $eng parses -q through the shared parser" "0" "1"
    grep -q 'SNAP_MESSAGE="$(quiesce_crash_message "$MESSAGE")"' "$REPO/$eng" \
        && check "degrade-engine: $eng names the set through the shared builder" "0" "0" \
        || check "degrade-engine: $eng names the set through the shared builder" "0" "1"
    grep -q 'exit 8' "$REPO/$eng" \
        && check "degrade-engine: $eng has a distinct final status for it" "0" "0" \
        || check "degrade-engine: $eng has a distinct final status for it" "0" "1"
    # Contract condition 6: the degraded exit is decided AFTER the transfer, on
    # the otherwise-clean path only, so a real transfer error outranks it. If
    # this ever moved above the FAILED_DATASETS test, a failed run would report
    # 8 -- "degraded but delivered" -- while nothing was delivered.
    deg_line=$(grep -n 'QUIESCE_DEGRADED:-0' "$REPO/$eng" | tail -1 | cut -d: -f1)
    fail_line=$(grep -n 'if \[ ${#FAILED_DATASETS\[@\]} -gt 0 \]' "$REPO/$eng" | tail -1 | cut -d: -f1)
    if [ -n "$deg_line" ] && [ -n "$fail_line" ] && [ "$deg_line" -gt "$fail_line" ]; then
        check "degrade-engine: $eng decides rc 8 after the transfer verdict" "0" "0"
    else
        check "degrade-engine: $eng decides rc 8 after the transfer verdict" "0" "1 (deg=$deg_line fail=$fail_line)"
    fi
done

# ============================================================================
# ,degrade ACROSS THE SSH BOUNDARY -- the classifier composed with the mapping.
#
# The gap this closes, found in review on 428feb4f: the mapping tests above stub
# a ready-made rc (`ssh() { return 5; }`) and so prove only that 5 becomes 8.
# They never ask WHAT BECOMES A FIVE. The remote script collapsed every prep
# failure into one code, so a foreign freeze and an impossible mode -- both kept
# fatal on the PUSH path -- arrived as 5 and were degraded on PULL.
#
# So each case below RUNS the real remote classifier, takes the code it actually
# produced, and carries THAT through the local mapping. Nothing is assumed about
# which number a case produces; the number is measured and then composed.
# ============================================================================

# The sudo stub is redefined several times above; this is the one these cases
# use, and it adds one knob the others did not need: a status read that FAILS,
# as opposed to one that answers "absent".
cat > "$RQ_D/bin/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >> "$TRACE"
[ "$1" = "-n" ] && shift
shift
st="${QSTATE:-/tmp/qstate}.${2:-x}"
case "${1:-}" in
  status) [ $# -eq 1 ] && { echo "OK account=peer"; exit 0; }
          # The privilege probe above still succeeds -- what fails is reading a
          # PARTICULAR guest, which is what a whitelist miss looks like.
          [ -n "${QSTATUS_FAIL:-}" ] && exit 1
          k="${QKIND:-qemu}"; [ "$2" = 200 ] && k=lxc
          f="${QFROZEN:-}"
          if [ -z "$f" ]; then f=no; [ -e "$st" ] && f=yes; fi
          echo "id=$2 kind=$k running=yes frozen=$f"; exit 0 ;;
  freeze) [ "${QFREEZE:-0}" = 0 ] && : > "$st"; exit "${QFREEZE:-0}" ;;
  thaw)   [ "${QTHAW:-0}" = 0 ] && rm -f "$st"; exit "${QTHAW:-0}" ;;
esac
exit 1
STUB
chmod +x "$RQ_D/bin/sudo"

# --- foreign freeze: fatal, and STAYS fatal through the mapping -------------
rq_reset 'exit 0'
out=$(QFROZEN=yes rq_run2); rc_foreign=$?
check "pull-class: a foreign freeze takes no snapshot"        "no"   "$(rq_snapshotted)"
check "pull-class: ...and the classifier says FATAL (9)"      "9"    "$rc_foreign"
check "pull-class: ...and ,degrade does NOT rescue it"        "9|0"  "$(rrun "$rc_foreign" 1)"
check "pull-class: ...and without ,degrade it is unchanged"   "9|0"  "$(rrun "$rc_foreign" 0)"

# --- impossible mode for the guest kind: same class -------------------------
rq_reset 'exit 0'
out=$(QKIND=lxc rq_run2 agent); rc_mode=$?
check "pull-class: agent on a container takes no snapshot"    "no"   "$(rq_snapshotted)"
check "pull-class: ...and the classifier says FATAL (9)"      "9"    "$rc_mode"
check "pull-class: ...and ,degrade does NOT rescue it"        "9|0"  "$(rrun "$rc_mode" 1)"

# --- a real freeze failure: this one IS what ,degrade is for -----------------
# The positive half. Without it the three assertions above would also pass
# against a mapping that had simply stopped degrading anything at all.
rq_reset 'exit 0'
out=$(QFREEZE=1 rq_run2); rc_freeze=$?
check "pull-class: a freeze that did not take takes no snapshot" "no"  "$(rq_snapshotted)"
check "pull-class: ...and the classifier says DEGRADABLE (5)"    "5"   "$rc_freeze"
check "pull-class: ...and ,degrade DOES rescue it"               "8|1" "$(rrun "$rc_freeze" 1)"
check "pull-class: ...and without ,degrade it stays a refusal"   "5|0" "$(rrun "$rc_freeze" 0)"

# --- a status that cannot be READ is not "no guest here" --------------------
# The false-success branch: gq_status's exit code was discarded, an empty reply
# gave an empty kind, and the `*` arm reported the guest absent and returned
# SUCCESS -- so a helper that could not answer looked exactly like a host with
# nothing to freeze, and the run called itself quiesced.
rq_reset 'exit 0'
out=$(QSTATUS_FAIL=1 rq_run2); rc_stat=$?
check "pull-class: an unreadable guest status takes no snapshot" "no" "$(rq_snapshotted)"
if [ "$rc_stat" -eq 0 ]; then
    check "pull-class: ...and the run does NOT report success" "nonzero" "0"
else
    check "pull-class: ...and the run does NOT report success" "nonzero" "nonzero"
fi
case "$out" in
    *"could not determine the state of guest"*)
        check "pull-class: ...and says the status was unreadable, not 'no guest'" "y" "y" ;;
    *)  check "pull-class: ...and says the status was unreadable, not 'no guest'" "y" "n ($out)" ;;
esac
case "$out" in
    *"no guest 100 on the source host"*)
        check "pull-class: ...and does NOT claim the guest is absent" "y" "n ($out)" ;;
    *)  check "pull-class: ...and does NOT claim the guest is absent" "y" "y" ;;
esac
# It is a runtime failure, so it belongs to the degradable class -- the same
# answer the local path gives for the same cause.
check "pull-class: ...and it is DEGRADABLE (5), like its local twin" "5" "$rc_stat"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
