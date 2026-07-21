#!/bin/bash
# Integration tests for snapsend.sh / snapget.sh, run against REAL throwaway
# ZFS pools backed by sparse files.
#
# Scope: LOCAL mode only. The remote (ssh) path cannot be exercised on one
# machine by design -- validate_remote_host() aborts when the far end reports
# the same /etc/machine-id, which is exactly what an ssh-to-localhost test
# would hit. That guard is deliberate (it prevents a loopback "replication"
# that would silently overwrite the source), so these tests cover the transfer
# and selection logic that local mode shares with remote mode, and leave the
# ssh plumbing to live use.
#
# Requires: root + zfs + mbuffer (so: run on a PVE host, not the dev machine).
#
# SAFETY -- identical posture to test/delsnaps/run.sh: PID-suffixed pool name,
# abort if it already exists, STATS_LOG/LOCKDIR redirected to a temp dir, and
# an EXIT trap that destroys the pool even if a test fails midway.
#
# Usage: ./run.sh     (override the scripts under test with SNAPSEND=/SNAPGET=)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"

[ -x "$SNAPSEND" ] || { echo "cannot find executable snapsend.sh at $SNAPSEND" >&2; exit 1; }
[ -x "$SNAPGET" ]  || { echo "cannot find executable snapget.sh at $SNAPGET" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root (creates a zpool)" >&2; exit 1; }
command -v zpool   >/dev/null || { echo "zpool not found -- run this on a host with ZFS" >&2; exit 1; }
command -v mbuffer >/dev/null || { echo "mbuffer not found -- snapsend.sh refuses to run without it" >&2; exit 1; }

POOL="sendtest$$"
TMPD="$(mktemp -d)"
IMG="$TMPD/pool.img"

zpool list -H -o name 2>/dev/null | grep -qx "$POOL" && {
    echo "refusing to run: a pool named '$POOL' already exists" >&2; exit 1; }

cleanup() {
    zpool destroy -f "$POOL" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

truncate -s 512M "$IMG"
zpool create -f -m none "$POOL" "$IMG" || { echo "zpool create failed" >&2; exit 1; }

export STATS_LOG="$TMPD/stats.log"
export LOCKDIR="$TMPD"

PASS=0
FAIL=0

# --- helpers ----------------------------------------------------------------

# snapsend.sh builds target paths as "<TARGET_BASE>/<source dataset>", which is
# why production ends up with names like hdd/backups/pve1/rpool/data. Mirror
# that nesting here rather than inventing a flatter layout the script never
# actually produces.
BK="$POOL/bk"
tgt_of() { echo "$BK/$POOL/$1"; }

snaps_of() {
    zfs list -H -o name -s creation -t snapshot "$1" 2>/dev/null \
        | sed 's/.*@//' | tr '\n' ' ' | sed 's/ $//'
}

count_snaps() {
    zfs list -H -o name -t snapshot "$1" 2>/dev/null | wc -l
}

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL $label"
        echo "     expected: [$expected]"
        echo "     actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

RC=0
run_send() { "$SNAPSEND" "$@" >/dev/null 2>&1; RC=$?; }
run_get()  { "$SNAPGET"  "$@" >/dev/null 2>&1; RC=$?; }

# snapshot names are built from `date +%Y-%m-%d_%H-%M-%S`, so two runs inside
# the same second would collide on an identical name. Space them out.
tick() { sleep 1; }

echo "=== snapsend.sh / snapget.sh integration tests (pool: $POOL) ==="

# --- full send, then incremental --------------------------------------------

zfs create -p "$POOL/src" || exit 1
run_send -m "auto_" "$POOL/src" "$BK"
T="$(tgt_of src)"
check "full send: target dataset is created" "yes" \
      "$(zfs list -H -o name "$T" >/dev/null 2>&1 && echo yes || echo no)"
check "full send: exactly one snapshot lands on the target" "1" "$(count_snaps "$T")"
check "full send: exit 0" "0" "$RC"
check "full send: source and target hold the same snapshot" \
      "$(snaps_of "$POOL/src")" "$(snaps_of "$T")"

# A freshly created target must be canmount=noauto -- that is what keeps it
# unmounted across receive's mount/unmount cycle and makes non-root delegated
# receive possible at all.
check "full send: target is created with canmount=noauto" "noauto" \
      "$(zfs get -H -o value canmount "$T")"

tick
run_send -m "auto_" "$POOL/src" "$BK"
check "incremental: second run adds the new snapshot" "2" "$(count_snaps "$T")"
check "incremental: target still matches source exactly" \
      "$(snaps_of "$POOL/src")" "$(snaps_of "$T")"

# --- incrementals carry intermediate snapshots ------------------------------

# This is the property pve0's whole archive design leans on: when a common base
# exists, snapsend sends `zfs send -I <base> <newest>`, which drags along EVERY
# snapshot in between -- so tiers created on the source between two runs (daily,
# weekly, ...) still reach the archive even though only the newest is named.
#
# Note the naming trap: the -I *flag* does NOT control this. It selects -R
# full-history behaviour on a FULL send. Incrementals use -I unconditionally.
zfs create -p "$POOL/mid" || exit 1
run_send -m "auto_" "$POOL/mid" "$BK"
TM="$(tgt_of mid)"
tick; zfs snapshot "$POOL/mid@tier_daily"
tick; zfs snapshot "$POOL/mid@tier_weekly"
tick
run_send -m "auto_" "$POOL/mid" "$BK"
check "incremental: intermediate tier snapshots ride along" "yes" \
      "$(zfs list -H -o name -t snapshot "$TM" | grep -q '@tier_daily' \
         && zfs list -H -o name -t snapshot "$TM" | grep -q '@tier_weekly' \
         && echo yes || echo no)"

# --- -e : use an existing snapshot instead of creating one ------------------

zfs create -p "$POOL/ex" || exit 1
zfs snapshot "$POOL/ex@auto_first"
run_send -e -m "auto_" "$POOL/ex" "$BK"
check "-e: sends an existing snapshot without creating a new one" \
      "auto_first" "$(snaps_of "$POOL/ex")"
check "-e: that snapshot reached the target" "auto_first" "$(snaps_of "$(tgt_of ex)")"

# -m under -e is a FILTER over existing snapshots, not a name to create. The
# newest snapshot matching the prefix wins -- not the newest snapshot overall.
# This is how per-tier anchoring works in production, where an archive run is
# pinned to automated_hourly_ even though newer daily/weekly snapshots exist.
zfs create -p "$POOL/anchor" || exit 1
zfs snapshot "$POOL/anchor@automated_hourly_1"
tick; zfs snapshot "$POOL/anchor@automated_daily_1"
run_send -e -m "automated_hourly_" "$POOL/anchor" "$BK"
check "-e -m: anchors on the newest snapshot MATCHING the prefix, not the newest overall" \
      "automated_hourly_1" "$(snaps_of "$(tgt_of anchor)")"

zfs create -p "$POOL/nomatch" || exit 1
zfs snapshot "$POOL/nomatch@other_1"
run_send -e -m "automated_hourly_" "$POOL/nomatch" "$BK"
check "-e -m: no snapshot matching the prefix is an error, not a silent full send" \
      "1" "$RC"

# A run that cannot succeed must not touch the target at all. process_dataset
# resolves the source snapshot BEFORE creating (or, under -f, destroying) the
# target, so a wrong -m prefix leaves nothing behind.
check "-e -m: a doomed run does not even create the target dataset" "no" \
      "$(zfs list -H -o name "$(tgt_of nomatch)" >/dev/null 2>&1 && echo yes || echo no)"

# --- local snapshot-only mode (no target argument) --------------------------

# One-argument form: snapshot in place, no transfer. This is what the relay
# host's config generates.
zfs create -p "$POOL/localonly" || exit 1
run_send -m "auto_" "$POOL/localonly"
check "local-only: creates a snapshot with no target argument" "1" \
      "$(count_snaps "$POOL/localonly")"
check "local-only: exit 0" "0" "$RC"

# --- -r recursion -----------------------------------------------------------

# Regression guard for a real production bug: an annual job was missing -r, so
# it snapshotted only the (empty) parent and never the VM disks underneath.
# Without -r the child MUST stay untouched; with -r it MUST be included.
zfs create -p "$POOL/norec/child" || exit 1
run_send -m "auto_" "$POOL/norec"
check "no -r: parent is snapshotted" "1" "$(count_snaps "$POOL/norec")"
check "no -r: child is NOT snapshotted (the missing-flag bug)" "0" \
      "$(count_snaps "$POOL/norec/child")"

zfs create -p "$POOL/rec/child" || exit 1
run_send -r -m "auto_" "$POOL/rec"
check "-r: parent is snapshotted" "1" "$(count_snaps "$POOL/rec")"
check "-r: child is snapshotted too" "1" "$(count_snaps "$POOL/rec/child")"

# --- idempotency ------------------------------------------------------------

# Re-sending when the target already holds the newest snapshot must be a
# no-op success, not an error and not a redundant transfer.
zfs create -p "$POOL/idem" || exit 1
zfs snapshot "$POOL/idem@auto_1"
run_send -e -m "auto_" "$POOL/idem" "$BK"
run_send -e -m "auto_" "$POOL/idem" "$BK"
check "idempotent: re-sending the same snapshot exits 0" "0" "$RC"
check "idempotent: target still holds exactly one snapshot" "1" \
      "$(count_snaps "$(tgt_of idem)")"

# --- dry run ----------------------------------------------------------------

zfs create -p "$POOL/dry" || exit 1
zfs snapshot "$POOL/dry@auto_1"
run_send -n -m "auto_" "$POOL/dry" "$BK"
check "dry-run: creates no snapshot on the source" "1" "$(count_snaps "$POOL/dry")"
check "dry-run: creates no target dataset" "no" \
      "$(zfs list -H -o name "$(tgt_of dry)" >/dev/null 2>&1 && echo yes || echo no)"

# --- force full send guards -------------------------------------------------

# -f destroys the target before re-sending. If the target carries snapshots
# reserved by Proxmox VE, that destroy would break replication/migration in a
# way this tool cannot repair -- so it must refuse and leave everything intact.
zfs create -p "$POOL/prot" || exit 1
zfs snapshot "$POOL/prot@auto_1"
run_send -e -m "auto_" "$POOL/prot" "$BK"
TP="$(tgt_of prot)"
zfs snapshot "$TP@__replicate_101-0_1"
run_send -f -e -m "auto_" "$POOL/prot" "$BK"
check "-f: refuses when the target holds a Proxmox-reserved snapshot" "1" "$RC"
check "-f: the reserved snapshot is still there after the refusal" "yes" \
      "$(zfs list -H -o name -t snapshot "$TP" | grep -q '@__replicate_' && echo yes || echo no)"

# On a clean target -f must actually work: wipe and re-send.
zfs create -p "$POOL/forced" || exit 1
zfs snapshot "$POOL/forced@auto_1"
run_send -e -m "auto_" "$POOL/forced" "$BK"
tick; zfs snapshot "$POOL/forced@auto_2"
run_send -f -e -m "auto_" "$POOL/forced" "$BK"
check "-f: rebuilds a clean target from scratch" "0" "$RC"
check "-f: target holds only the freshly sent snapshot" "auto_2" \
      "$(snaps_of "$(tgt_of forced)")"

# Regression guard for a destructive ordering bug: -f destroys the target
# before re-sending, and the source snapshot used to be resolved only AFTER
# that. So `-f -e -m <prefix matching nothing>` wiped every snapshot and all
# data on the target and only then failed with "no source snapshots matching
# message" -- the backup was gone until the next successful full send.
# Verified destructive on a live pool before the fix.
zfs create -p "$POOL/fsafe" || exit 1
zfs snapshot "$POOL/fsafe@auto_1"
run_send -e -m "auto_" "$POOL/fsafe" "$BK"
TF="$(tgt_of fsafe)"
run_send -f -e -m "NO_SUCH_PREFIX_" "$POOL/fsafe" "$BK"
check "-f: a doomed run exits 1 without destroying the target" "1" "$RC"
check "-f: the existing backup survives a doomed forced run" "auto_1" "$(snaps_of "$TF")"

# --- missing source ---------------------------------------------------------

run_send -m "auto_" "$POOL/does-not-exist" "$BK"
check "missing source dataset exits 1" "1" "$RC"

# --- snapget.sh (pull direction, local mode) --------------------------------

# snapget.sh takes the SAME argument shape as snapsend.sh but assigns the two
# positions the opposite way round, because it pulls instead of pushes:
#
#   snapsend.sh <source>  <target-base>   -> target = <target-base>/<source>
#   snapget.sh  <target>  <source-base>   -> source = <source-base>/<target>
#
# So the first argument is the dataset that gets WRITTEN in one script and the
# dataset that gets READ in the other. Pinning it here because getting it
# backwards is an easy and expensive mistake, and the failure is silent-ish:
# it just reports a missing source.
SRCBASE="$POOL/origin"
zfs create -p "$SRCBASE/$POOL/pull" || exit 1
zfs snapshot "$SRCBASE/$POOL/pull@auto_1"
run_get -e -m "auto_" "$POOL/pull" "$SRCBASE"
check "snapget: local pull lands the snapshot on the local target" "auto_1" \
      "$(snaps_of "$POOL/pull")"
check "snapget: exit 0" "0" "$RC"
check "snapget: target is created with canmount=noauto" "noauto" \
      "$(zfs get -H -o value canmount "$POOL/pull")"

tick; zfs snapshot "$SRCBASE/$POOL/pull@auto_2"
run_get -e -m "auto_" "$POOL/pull" "$SRCBASE"
check "snapget: incremental pull adds the new snapshot" "auto_1 auto_2" \
      "$(snaps_of "$POOL/pull")"

zfs create -p "$SRCBASE/$POOL/pullnomatch" || exit 1
zfs snapshot "$SRCBASE/$POOL/pullnomatch@other_1"
run_get -e -m "automated_hourly_" "$POOL/pullnomatch" "$SRCBASE"
check "snapget: no snapshot matching the prefix is an error" "1" "$RC"
check "snapget: a doomed run does not create the local target" "no" \
      "$(zfs list -H -o name "$POOL/pullnomatch" >/dev/null 2>&1 && echo yes || echo no)"

# snapget carries the same -f ordering fix as snapsend; keep both guarded.
run_get -f -e -m "NO_SUCH_PREFIX_" "$POOL/pull" "$SRCBASE"
check "snapget -f: a doomed forced run leaves the local target intact" "auto_1 auto_2" \
      "$(snaps_of "$POOL/pull")"

# --- summary ----------------------------------------------------------------

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
