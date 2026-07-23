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

# Named up here, not where it is created: the trap has to know about it even if
# the suite dies before reaching the compressed-send block, or an aborted run
# leaves a stray pool on a production host.
NOLZ4="nolz4test$$"

cleanup() {
    zpool destroy -f "$POOL" 2>/dev/null
    zpool destroy -f "$NOLZ4" 2>/dev/null
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

# --- bookmark-backed incremental fallback ------------------------------------
# Bookmarks store only a snapshot's txg+GUID (no data blocks), so `zfs send -i`
# can still compute a diff against one after the snapshot itself is gone. This
# is what saves a run from falling back to FULL once the common-base snapshot
# has already been pruned off the source (e.g. pvesr's ~12h retention window).
#
# The key functional signal, used instead of grepping log text: `zfs recv`
# always runs with -F (forced rollback). If the bookmark match fails and the
# run falls through to a plain FULL send, -F rolls the target back to hold
# ONLY the incoming snapshot. If the bookmark match succeeds, the send is a
# real `-i` incremental, which does not roll back -- the target keeps its
# prior history AND gains the new snapshot. So "does the old snapshot survive
# alongside the new one" is a reliable proxy for "was the bookmark used."

zfs create -p "$POOL/bm1" || exit 1
zfs snapshot "$POOL/bm1@a"
run_send -e "$POOL/bm1" "$BK"
BM1T="$(tgt_of bm1)"
check "bookmark: first send lands @a on target" "a" "$(snaps_of "$BM1T")"

zfs destroy "$POOL/bm1@a"
tick
zfs snapshot "$POOL/bm1@c"
run_send -e "$POOL/bm1" "$BK"
check "bookmark: exit 0 even though the common-base snapshot is gone from source" "0" "$RC"
check "bookmark: target keeps @a AND gains @c (incremental via bookmark, not a forced-rollback full)" "a c" \
      "$(snaps_of "$BM1T")"
check "bookmark: source bookmark GUID now matches the newly sent @c" \
      "$(zfs get -H -p -o value guid "$POOL/bm1@c")" \
      "$(zfs list -H -t bookmark -o guid "$POOL/bm1" 2>/dev/null | head -1)"

# A bookmark whose GUID does NOT match the target's current head (e.g. someone
# rebuilt the target independently) must never be trusted on a name-only
# guess -- it must be silently skipped, falling through to the normal
# no-common-base path exactly like having no bookmark at all.
#
# That fallback path is a PLAIN full send (no -f), which -- pre-existing
# behaviour, nothing to do with bookmarks -- cannot land in a target that
# already holds unrelated snapshots: `zfs receive -F` only rolls back
# uncommitted filesystem changes, it does not destroy foreign snapshots the
# way -f's explicit destroy+recreate does. So the correct, safe outcome here
# is a clean failure that leaves the target untouched -- proof that the
# mismatched bookmark was never used (if it had been, the send would have
# used the wrong base and either errored differently or corrupted the
# stream, not failed with ZFS's own "destination has snapshots" refusal).
zfs create -p "$POOL/bm2" || exit 1
zfs snapshot "$POOL/bm2@a"
run_send -e "$POOL/bm2" "$BK"
BM2T="$(tgt_of bm2)"
zfs destroy "$POOL/bm2@a"
tick
zfs snapshot "$POOL/bm2@c"
zfs destroy "${BM2T}@a"
zfs snapshot "${BM2T}@rogue"
run_send -e "$POOL/bm2" "$BK"
check "bookmark: GUID mismatch is not used -- fails safely (pre-existing ZFS limit, not a bookmark bug)" "1" "$RC"
check "bookmark: GUID mismatch never touches the target (no wrong-base send happened)" "rogue" \
      "$(snaps_of "$BM2T")"

# snapget.sh mirror -- same mechanism, source may be the remote side there.
GSRC="$SRCBASE/$POOL/pullbm"
zfs create -p "$GSRC" || exit 1
zfs snapshot "${GSRC}@a"
run_get -e "$POOL/pullbm" "$SRCBASE"
check "snapget bookmark: first pull lands @a" "a" "$(snaps_of "$POOL/pullbm")"

zfs destroy "${GSRC}@a"
tick
zfs snapshot "${GSRC}@c"
run_get -e "$POOL/pullbm" "$SRCBASE"
check "snapget bookmark: exit 0 even though the common-base snapshot is gone from source" "0" "$RC"
check "snapget bookmark: local target keeps @a AND gains @c" "a c" "$(snaps_of "$POOL/pullbm")"

# --- -w raw send -------------------------------------------------------------
# A raw stream carries the SOURCE dataset's own properties, encryption included,
# so `zfs recv` must create the leaf target itself. Every other mode pre-creates
# it (with canmount=noauto), and a raw stream cannot land on a pre-created plain
# dataset -- ZFS refuses with "zfs receive -F cannot be used to ... overwrite an
# unencrypted one with an encrypted one". So -w takes a different creation path,
# and these tests pin it.
#
# Behaviour verified directly against zfs-2.1.9 before implementing: for an
# UNENCRYPTED source -w is effectively a no-op (raw and non-raw streams
# interoperate freely both ways), and rawness only becomes load-bearing once the
# source is encrypted.

RAWKEY="$TMPD/rawkey.bin"
dd if=/dev/urandom of="$RAWKEY" bs=32 count=1 status=none
chmod 400 "$RAWKEY"
mkenc() { zfs create -o encryption=on -o keyformat=raw -o keylocation="file://$RAWKEY" "$1"; }

if mkenc "$POOL/enc" 2>/dev/null; then
    zfs snapshot "$POOL/enc@auto_1"
    run_send -w -e -m "auto_" "$POOL/enc" "$BK"
    TE="$(tgt_of enc)"
    check "-w: raw send of an encrypted dataset exits 0" "0" "$RC"
    check "-w: ciphertext landed -- the target is itself encrypted" "aes-256-gcm" \
          "$(zfs get -H -o value encryption "$TE" 2>/dev/null)"
    # The whole point: the receiving side holds data it cannot read.
    check "-w: the target's key is unavailable" "unavailable" \
          "$(zfs get -H -o value keystatus "$TE" 2>/dev/null)"
    check "-w: the target is unmounted, so -u is not needed" "no" \
          "$(zfs get -H -o value mounted "$TE" 2>/dev/null)"
    # recv created the leaf, so canmount=noauto is reapplied afterwards instead
    # of at create time -- the property that makes non-root receive work.
    check "-w: canmount=noauto is restored after a recv-created target" "noauto" \
          "$(zfs get -H -o value canmount "$TE" 2>/dev/null)"

    tick; zfs snapshot "$POOL/enc@auto_2"
    run_send -w -e -m "auto_" "$POOL/enc" "$BK"
    check "-w: raw incremental exits 0" "0" "$RC"
    check "-w: incremental appended without rolling back history" "auto_1 auto_2" \
          "$(snaps_of "$TE")"

    # A non-raw send of an encrypted dataset needs the key loaded; a raw one does
    # not. This is the case -w exists for, so pin both halves.
    mkenc "$POOL/nokey"
    zfs snapshot "$POOL/nokey@auto_1"
    zfs unmount "$POOL/nokey" 2>/dev/null
    zfs unload-key "$POOL/nokey" 2>/dev/null
    run_send -e -m "auto_" "$POOL/nokey" "$BK"
    check "no -w: encrypted source with the key unloaded fails" "1" "$RC"

    # Deliberately a fresh dataset: the failed run above already pre-created its
    # target as a plain dataset, which would make this test measure the raw/
    # non-raw mismatch instead of the key-less raw send.
    mkenc "$POOL/nokey2"
    zfs snapshot "$POOL/nokey2@auto_1"
    zfs unmount "$POOL/nokey2" 2>/dev/null
    zfs unload-key "$POOL/nokey2" 2>/dev/null
    run_send -w -e -m "auto_" "$POOL/nokey2" "$BK"
    check "-w: encrypted source with the key unloaded succeeds" "0" "$RC"

    # -w must stay harmless on the unencrypted datasets that make up all current
    # production use -- adding the flag to a running job must not change anything.
    zfs create -p "$POOL/rawplain" || exit 1
    zfs snapshot "$POOL/rawplain@auto_1"
    run_send -w -e -m "auto_" "$POOL/rawplain" "$BK"
    check "-w on an unencrypted dataset still succeeds" "0" "$RC"
    check "-w on an unencrypted dataset leaves the target unencrypted" "off" \
          "$(zfs get -H -o value encryption "$(tgt_of rawplain)" 2>/dev/null)"

    mkenc "$POOL/rawtree"
    zfs create "$POOL/rawtree/child"
    run_send -w -r -m "auto_" "$POOL/rawtree" "$BK"
    check "-w -r: the child dataset landed on the target" "yes" \
          "$(zfs list -H -o name "$(tgt_of rawtree)/child" >/dev/null 2>&1 && echo yes || echo no)"

    # Same bookmark fallback as above, but on the raw path -- the -i base must
    # still anchor a real incremental rather than collapsing to a full send.
    mkenc "$POOL/rawbm"
    zfs snapshot "$POOL/rawbm@a"
    run_send -w -e "$POOL/rawbm" "$BK"
    zfs destroy "$POOL/rawbm@a"
    tick; zfs snapshot "$POOL/rawbm@c"
    run_send -w -e "$POOL/rawbm" "$BK"
    check "-w: bookmark fallback exits 0 with the common base gone" "0" "$RC"
    check "-w: bookmark fallback stayed incremental (kept @a, gained @c)" "a c" \
          "$(snaps_of "$(tgt_of rawbm)")"

    # snapget mirror.
    zfs create -o encryption=on -o keyformat=raw -o keylocation="file://$RAWKEY" \
        "$SRCBASE/$POOL/rawpull"
    zfs snapshot "$SRCBASE/$POOL/rawpull@auto_1"
    run_get -w -e -m "auto_" "$POOL/rawpull" "$SRCBASE"
    check "snapget -w: raw pull exits 0" "0" "$RC"
    check "snapget -w: the local target is encrypted" "aes-256-gcm" \
          "$(zfs get -H -o value encryption "$POOL/rawpull" 2>/dev/null)"

    # --- rawness-mismatch guardrail -----------------------------------------
    # ZFS rejects these itself, but deep inside the pipe and with messages that
    # do not say what to do. The guardrail refuses up front instead, BEFORE
    # anything is created or destroyed, so a doomed run leaves no side effects.

    # Adding -w to a job whose target was seeded non-raw.
    mkenc "$POOL/gmix1"
    zfs snapshot "$POOL/gmix1@auto_1"
    run_send -e -m "auto_" "$POOL/gmix1" "$BK"
    G1="$(tgt_of gmix1)"
    tick; zfs snapshot "$POOL/gmix1@auto_2"
    run_send -w -e -m "auto_" "$POOL/gmix1" "$BK"
    check "guardrail: -w onto a non-raw-seeded target is refused" "1" "$RC"
    check "guardrail: the refusal left the target untouched" "auto_1" "$(snaps_of "$G1")"

    # Dropping -w from a job whose target was seeded raw.
    mkenc "$POOL/gmix2"
    zfs snapshot "$POOL/gmix2@auto_1"
    run_send -w -e -m "auto_" "$POOL/gmix2" "$BK"
    G2="$(tgt_of gmix2)"
    tick; zfs snapshot "$POOL/gmix2@auto_2"
    run_send -e -m "auto_" "$POOL/gmix2" "$BK"
    check "guardrail: dropping -w on a raw-seeded target is refused" "1" "$RC"
    check "guardrail: that refusal also left the target untouched" "auto_1" "$(snaps_of "$G2")"

    # The stale-target case: a FAILED non-raw run still pre-creates an empty
    # plain target, which then blocks -w. The guardrail must name it rather
    # than letting ZFS emit "cannot perform raw receive on top of existing
    # unencrypted dataset" from inside the pipe.
    mkenc "$POOL/gstale"
    zfs snapshot "$POOL/gstale@auto_1"
    zfs unmount "$POOL/gstale" 2>/dev/null
    zfs unload-key "$POOL/gstale" 2>/dev/null
    run_send -e -m "auto_" "$POOL/gstale" "$BK"          # fails, leaves empty target
    run_send -w -e -m "auto_" "$POOL/gstale" "$BK"
    check "guardrail: an empty target left by a failed non-raw run is refused, not retried" \
          "1" "$RC"

    # -f destroys the target, so there is no seeding left to conflict with:
    # the guardrail must stand aside and let the run re-seed raw.
    run_send -f -w -e -m "auto_" "$POOL/gmix1" "$BK"
    check "guardrail: -f re-seeds raw over a non-raw target instead of refusing" "0" "$RC"
    check "-f -w: the rebuilt target is encrypted" "aes-256-gcm" \
          "$(zfs get -H -o value encryption "$G1" 2>/dev/null)"

    # An UNENCRYPTED source must never trip the guardrail -- verified on
    # zfs-2.1.9 that raw and non-raw interoperate freely there, and all current
    # production datasets are unencrypted.
    zfs create -p "$POOL/gplain" || exit 1
    zfs snapshot "$POOL/gplain@auto_1"
    run_send -e -m "auto_" "$POOL/gplain" "$BK"
    tick; zfs snapshot "$POOL/gplain@auto_2"
    run_send -w -e -m "auto_" "$POOL/gplain" "$BK"
    check "guardrail: adding -w to an unencrypted job is NOT refused" "0" "$RC"
    check "guardrail: that unencrypted job kept its history" "auto_1 auto_2" \
          "$(snaps_of "$(tgt_of gplain)")"
else
    echo "SKIP -w raw send tests: this ZFS build cannot create encrypted datasets"
fi

# --- compression: -z (pigz) vs -Z (zstd) ------------------------------------
# Both compressors sit in the same pipeline slot: send | COMPRESS | mbuffer |
# DECOMPRESS | recv -- but ONLY for a remote target. Since v2.32 a local send
# drops compression entirely (compressing and decompressing on one host cannot
# pay for itself), so what these local cases pin is the FLAG PARSING: which
# compressor and level each flag selects, reported at selection time via the
# COMPRESSOR log line. The pipeline itself is exercised by the remote path,
# which this suite deliberately does not cover -- see the header note on local
# mode. zstd is the default; -g must stay an opt-in escape hatch.

# Writes real data so the compressor has something to chew on; an empty dataset
# would pass even if the pipeline were nonsense.
fill() { dd if=/dev/urandom of="$1" bs=1M count=8 status=none 2>/dev/null; }

comp_case() {  # comp_case <label> <dataset-suffix> <flag...>
    local label="$1" name="$2"; shift 2
    zfs create -p "$POOL/$name" || return 1
    local mp; mp="$(zfs get -H -o value mountpoint "$POOL/$name")"
    [ "$mp" != "none" ] && [ -d "$mp" ] && fill "$mp/blob"
    zfs snapshot "$POOL/$name@auto_1"
    run_send "$@" -e -m "auto_" "$POOL/$name" "$BK"
    check "$label: exits 0" "0" "$RC"
    check "$label: the snapshot reached the target" "auto_1" "$(snaps_of "$(tgt_of "$name")")"
}

comp_case "-z (default=zstd)"  czdef   -z
comp_case "-Z (zstd)"          czzstd  -Z
comp_case "-g (pigz)"          czpigz  -g
comp_case "-Z -l 9 (zstd lvl)" czzstd9 -Z -l 9
comp_case "-g -l 1 (pigz lvl)" czpigz1 -g -l 1

# An incremental has to survive the compressed path too -- that is the shape
# every production job actually runs in.
tick; zfs snapshot "$POOL/czzstd@auto_2"
run_send -Z -e -m "auto_" "$POOL/czzstd" "$BK"
check "-Z: compressed incremental exits 0" "0" "$RC"
check "-Z: compressed incremental appended" "auto_1 auto_2" "$(snaps_of "$(tgt_of czzstd)")"

# zstd is the DEFAULT compressor as of 2026-07-22: benchmarked on a real 1.5 GB
# zfs send stream it beat pigz -6 on both ratio (2.34x vs 2.19x) and throughput
# (454 vs 143 MB/s), so plain -z must select it. Pinned via the verbose
# COMPRESSOR log line -- if someone flips the default back, this fails loudly.
zfs create -p "$POOL/clvl" || exit 1
zfs snapshot "$POOL/clvl@auto_1"
check "-z alone selects zstd at its own default level 3" "zstd -T0 -3 -c" \
      "$("$SNAPSEND" -z -e -m "auto_" -v 3 "$POOL/clvl" "$BK" 2>&1 \
         | sed -n 's/.*COMPRESSOR: //p' | head -1)"

# The level default is per-tool and NOT shared: zstd 3, pigz 6. The scales are
# not comparable -- carrying pigz's 6 over to zstd would cost ~4x the CPU for ~4%
# more ratio.
zfs create -p "$POOL/clvl2" || exit 1
zfs snapshot "$POOL/clvl2@auto_1"
check "-g without -l keeps pigz's own default level 6" "pigz -6" \
      "$("$SNAPSEND" -g -e -m "auto_" -v 3 "$POOL/clvl2" "$BK" 2>&1 \
         | sed -n 's/.*COMPRESSOR: //p' | head -1)"

# Compressor flags are last-one-wins rather than an error, so a config that
# appends a flag cannot end up in an undefined state.
zfs create -p "$POOL/clast" || exit 1
zfs snapshot "$POOL/clast@auto_1"
check "-z -g: last flag wins (pigz)" "pigz -6" \
      "$("$SNAPSEND" -z -g -e -m "auto_" -v 3 "$POOL/clast" "$BK" 2>&1 \
         | sed -n 's/.*COMPRESSOR: //p' | head -1)"
zfs create -p "$POOL/clast2" || exit 1
zfs snapshot "$POOL/clast2@auto_1"
check "-g -z: last flag wins (back to the zstd default)" "zstd -T0 -3 -c" \
      "$("$SNAPSEND" -g -z -e -m "auto_" -v 3 "$POOL/clast2" "$BK" 2>&1 \
         | sed -n 's/.*COMPRESSOR: //p' | head -1)"

# A local target must NOT compress (v2.32). The pipeline would be
# send | zstd -c | mbuffer | zstd -d -c | recv on one machine: both halves paid
# for, nothing between them but a pipe. This is the one case where an explicit
# -z does not win, so it is pinned in both directions -- the flag is still
# parsed (COMPRESSOR line above), and the transfer still succeeds, but the
# stand-down is announced rather than silent.
zfs create -p "$POOL/cloc" || exit 1
zfs snapshot "$POOL/cloc@auto_1"
cloc_out="$("$SNAPSEND" -z -e -m "auto_" -v 3 "$POOL/cloc" "$BK" 2>&1)"
check "-z on a local target: says it is ignoring compression" "yes" \
      "$(printf '%s' "$cloc_out" | grep -qi 'Compression ignored' && echo yes || echo no)"
check "-z on a local target: still selected a compressor before standing down" \
      "zstd -T0 -3 -c" \
      "$(printf '%s' "$cloc_out" | sed -n 's/.*COMPRESSOR: //p' | head -1)"
check "-z on a local target: the snapshot still reached the target" "auto_1" \
      "$(snaps_of "$(tgt_of cloc)")"

# Without an explicit flag there is nothing to announce -- staying quiet matters
# because every local cron job would otherwise log a line about a flag it never
# passed.
zfs create -p "$POOL/cloc2" || exit 1
zfs snapshot "$POOL/cloc2@auto_1"
check "local target without -z: stays quiet about compression" "no" \
      "$("$SNAPSEND" -e -m "auto_" -v 3 "$POOL/cloc2" "$BK" 2>&1 \
         | grep -qi 'Compression ignored' && echo yes || echo no)"

# snapget mirror: there the compressor runs on the (possibly remote) source.
zfs create -p "$SRCBASE/$POOL/czpull" || exit 1
zfs snapshot "$SRCBASE/$POOL/czpull@auto_1"
run_get -Z -e -m "auto_" "$POOL/czpull" "$SRCBASE"
check "snapget -Z: compressed pull exits 0" "0" "$RC"
check "snapget -Z: the snapshot landed locally" "auto_1" "$(snaps_of "$POOL/czpull")"

# --- compressed send (zfs send -c), automatic -----------------------------
# `-c` ships records as they already sit on disk. It has no flag: it is on
# whenever the target pool can take the stream. These tests pin BOTH halves of
# that -- that it is used, and that it stands down instead of failing when it
# cannot be.

zfs create -p "$POOL/csend" || exit 1
zfs snapshot "$POOL/csend@auto_1"
cs_out="$("$SNAPSEND" -e -m "auto_" -v 4 "$POOL/csend" "$BK" 2>&1)"
check "compressed send: used by default on a capable pool" "yes"       "$(printf '%s' "$cs_out" | grep -q 'Compressed send: using zfs send -c' && echo yes || echo no)"
check "compressed send: -c really reaches the zfs send command" "yes"       "$(printf '%s' "$cs_out" | grep 'RAW ZFS SEND COMMAND' | grep -q -- ' -c ' && echo yes || echo no)"
check "compressed send: the snapshot still arrived" "auto_1" "$(snaps_of "$(tgt_of csend)")"

zfs snapshot "$POOL/csend@auto_2"
cs_off="$(ZFS_SNAP_NO_COMPRESSED_SEND=1 "$SNAPSEND" -e -m "auto_" -v 4 "$POOL/csend" "$BK" 2>&1)"
check "compressed send: ZFS_SNAP_NO_COMPRESSED_SEND=1 forces plain" "no"       "$(printf '%s' "$cs_off" | grep 'RAW ZFS SEND COMMAND' | grep -q -- ' -c ' && echo yes || echo no)"
check "compressed send: forcing plain still transfers" "auto_1 auto_2" "$(snaps_of "$(tgt_of csend)")"

# A pool that cannot receive a compressed stream. Built feature-by-feature:
# `zpool create -d` disables everything, and extensible_dataset is then enabled
# because `zfs recv -s` (which this script always uses) needs it -- without that
# the receive fails for a reason unrelated to -c, which is exactly the confusion
# this construction avoids. lz4_compress stays off, and that is the one under test.
NOLZ4_IMG="$TMPD/nolz4.img"
if ! zpool list -H -o name 2>/dev/null | grep -qx "$NOLZ4"; then
    truncate -s 256M "$NOLZ4_IMG"
    if zpool create -f -d -m none "$NOLZ4" "$NOLZ4_IMG" 2>/dev/null        && zpool set feature@extensible_dataset=enabled "$NOLZ4" 2>/dev/null; then
        zfs snapshot "$POOL/csend@auto_3"
        nl_out="$("$SNAPSEND" -e -m "auto_" -v 3 "$POOL/csend" "$NOLZ4/store" 2>&1)"
        check "compressed send: stands down when the target pool lacks lz4_compress" "yes"               "$(printf '%s' "$nl_out" | grep -q 'lacks feature@lz4_compress' && echo yes || echo no)"
        check "compressed send: standing down still completes the transfer" "yes"               "$(printf '%s' "$nl_out" | grep -q 'Transfer completed successfully' && echo yes || echo no)"
        zpool destroy -f "$NOLZ4" 2>/dev/null
    else
        echo "SKIP compressed send: fallback cases (could not build a feature-poor pool)"
    fi
    rm -f "$NOLZ4_IMG"
fi

# --- hold-based protection for in-flight snapshots --------------------------
# snapsend.sh/snapget.sh place a `zfs hold zfssnapall_inflight` on the source
# snapshot for the duration of a transfer, so a delsnaps.sh run landing in the
# same window cannot prune out from under it (see lib-zfs-snap.sh). The hold
# must come OFF again once it is no longer needed, or every backup would
# leave behind a snapshot delsnaps.sh can never prune (not even with -F --
# holds block destroy regardless of -R).
#
# NOT covered here: a hold surviving because a genuine receive_resume_token
# was left behind (a truly interrupted mid-stream receive). That needs a
# deterministic way to kill `zfs receive` mid-transfer, which is inherently
# timing-sensitive -- left for manual verification rather than risking a
# flaky test. What IS covered: the hold comes off on a normal successful
# transfer, and it also comes off on a failure that leaves NO resume token
# (zfs receive refusing outright, before writing anything), which is exactly
# the scenario that would otherwise strand a snapshot forever.

held_by_us() {
    zfs holds -H "$1" 2>/dev/null | awk '{print $2}' | grep -qx "zfssnapall_inflight"
}

zfs create -p "$POOL/holdok" || exit 1
zfs snapshot "$POOL/holdok@auto_1"
run_send -e -m "auto_" "$POOL/holdok" "$BK"
check "hold: successful send releases the hold afterward" "no" \
      "$(held_by_us "$POOL/holdok@auto_1" && echo yes || echo no)"

# Same construction as the "bookmark: GUID mismatch" case above: a real `zfs
# receive` refusal ("destination has snapshots"), not an early guardrail
# return -- so the hold placed before the transfer attempt is genuinely
# exercised, and there is no resume token to keep it alive for.
zfs create -p "$POOL/holdfail" || exit 1
zfs snapshot "$POOL/holdfail@a"
run_send -e "$POOL/holdfail" "$BK"
HF="$(tgt_of holdfail)"
zfs destroy "$POOL/holdfail@a"
tick
zfs snapshot "$POOL/holdfail@c"
zfs destroy "${HF}@a"
zfs snapshot "${HF}@rogue"
run_send -e "$POOL/holdfail" "$BK"
check "hold: sanity -- the GUID-mismatch run really did fail" "1" "$RC"
check "hold: a non-resumable failure releases the hold (does not strand it)" "no" \
      "$(held_by_us "$POOL/holdfail@c" && echo yes || echo no)"

# snapget mirror.
GSRC2="$SRCBASE/$POOL/holdokpull"
zfs create -p "$GSRC2" || exit 1
zfs snapshot "${GSRC2}@auto_1"
run_get -e -m "auto_" "$POOL/holdokpull" "$SRCBASE"
check "snapget hold: successful pull releases the hold on the source" "no" \
      "$(held_by_us "${GSRC2}@auto_1" && echo yes || echo no)"

GSRC3="$SRCBASE/$POOL/holdfailpull"
zfs create -p "$GSRC3" || exit 1
zfs snapshot "${GSRC3}@a"
run_get -e "$POOL/holdfailpull" "$SRCBASE"
zfs destroy "${GSRC3}@a"
tick
zfs snapshot "${GSRC3}@c"
zfs destroy "$POOL/holdfailpull@a"
zfs snapshot "$POOL/holdfailpull@rogue"
run_get -e "$POOL/holdfailpull" "$SRCBASE"
check "snapget hold: sanity -- the GUID-mismatch pull really did fail" "1" "$RC"
check "snapget hold: a non-resumable failure releases the hold on the source" "no" \
      "$(held_by_us "${GSRC3}@c" && echo yes || echo no)"

# --- GUID-based common-snapshot matching (survives rename) ------------------
# find_common_snapshot's fast path matches by name. If the shared snapshot got
# renamed on either side since the last sync -- an admin tidy-up, or the
# dataset itself was `zfs rename`d -- the name lists no longer intersect, but
# the snapshot's GUID (its real ZFS identity) is unchanged by rename. The
# fallback scans GUIDs directly, so this still finds an incremental base
# instead of falling through to a full, rollback (-F) send.
#
# Same rollback-survival signal as the bookmark tests: a fallback FULL send
# uses -F, which would wipe the renamed snapshot off the target. If it
# survives alongside the newly-sent one, the GUID match -- not a full send --
# is what actually ran.

zfs create -p "$POOL/guidsend" || exit 1
zfs snapshot "$POOL/guidsend@a"
run_send -e "$POOL/guidsend" "$BK"
GST="$(tgt_of guidsend)"
check "guid-match: first send lands @a on target" "a" "$(snaps_of "$GST")"

zfs rename "${GST}@a" "${GST}@renamed"
tick
zfs snapshot "$POOL/guidsend@b"
run_send -e "$POOL/guidsend" "$BK"
check "guid-match: exit 0 even though the target's snapshot was renamed" "0" "$RC"
check "guid-match: target keeps the renamed snapshot AND gains the new one (incremental via GUID, not a rollback full)" \
      "renamed b" "$(snaps_of "$GST")"

# snapget mirror -- this time the rename happens on the LOCAL target.
GSRC4="$SRCBASE/$POOL/guidpull"
zfs create -p "$GSRC4" || exit 1
zfs snapshot "${GSRC4}@a"
run_get -e "$POOL/guidpull" "$SRCBASE"
check "snapget guid-match: first pull lands @a" "a" "$(snaps_of "$POOL/guidpull")"

zfs rename "$POOL/guidpull@a" "$POOL/guidpull@renamed"
tick
zfs snapshot "${GSRC4}@b"
run_get -e "$POOL/guidpull" "$SRCBASE"
check "snapget guid-match: exit 0 even though the local target's snapshot was renamed" "0" "$RC"
check "snapget guid-match: target keeps the renamed snapshot AND gains the new one" \
      "renamed b" "$(snaps_of "$POOL/guidpull")"

# --- summary ----------------------------------------------------------------

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
