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
# Alerting must NEVER touch the host's real queue. Any script under test that
# hits a pool-health problem calls $NOTIFY_SCRIPT, which by default queues into
# /var/lib/zfs-snapshot-all/alert-queue.log -- and the 07:00 digest then mails
# it as if it were production. That happened for real on 2026-07-26: this
# suite's deliberately-broken-ssh cases made pool_health return UNKNOWN (an
# unreachable host genuinely IS unknown), and 12 such alerts reached the
# operator's inbox the next morning. Redirect both the queue and the notify
# script itself; env beats the config file since notify-fail v9.
export ZFS_ALERT_QUEUE="$TMPD/alert-queue.log"
export ZFS_ALERT_CONF="$TMPD/zfs-alert.conf"
cat > "$ZFS_ALERT_CONF" <<CONFEOF
ZFS_ALERT_MODE=daily
ZFS_WARN_MODE=daily
ZFS_ALERT_QUEUE=$TMPD/alert-queue.log
CONFEOF
export NOTIFY_SCRIPT="$TMPD/notify-fail-stub.sh"
printf '#!/bin/bash
printf "%%s\t%%s\n" "$1" "$2" >> "%s/alerts-seen.log"
' "$TMPD" > "$NOTIFY_SCRIPT"
chmod +x "$NOTIFY_SCRIPT"

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

# Captured variants, only for the cases that need to inspect what a run
# actually PRINTED (a warning), not just its exit code or the resulting ZFS
# state -- every other case in this suite only needs the latter, hence two
# separate helpers rather than changing run_send/run_get themselves.
OUT=""
run_send_out() { OUT="$("$SNAPSEND" "$@" 2>&1)"; RC=$?; }
run_get_out()  { OUT="$("$SNAPGET"  "$@" 2>&1)"; RC=$?; }

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

# --- structured (JSON-lines) stats log ---------------------------------------
# STATS_LOG moved from "key=value" free text to one JSON object per line so it
# can be queried with `jq` instead of regexed. Pin: valid JSON, and that
# duration_s/resumed keep JSON-native types (number/boolean) rather than
# becoming quoted strings that would need re-parsing anyway.
STATS_LAST="$(tail -1 "$STATS_LOG")"
if command -v jq >/dev/null 2>&1; then
    check "stats log: latest line is valid JSON" "0" \
          "$(echo "$STATS_LAST" | jq -e . >/dev/null 2>&1; echo $?)"
    check "stats log: dataset field round-trips the full send" "$POOL/src" \
          "$(echo "$STATS_LAST" | jq -r .dataset)"
    check "stats log: status field round-trips" "success" \
          "$(echo "$STATS_LAST" | jq -r .status)"
    check "stats log: duration_s is a JSON number, not a quoted string" "number" \
          "$(echo "$STATS_LAST" | jq -r '.duration_s | type')"
    check "stats log: resumed is a JSON boolean, not the string yes/no" "boolean" \
          "$(echo "$STATS_LAST" | jq -r '.resumed | type')"
else
    echo "SKIP stats log JSON checks (jq not installed)"
fi

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
# The naming trap this used to have: the CLI's -I *flag* did NOT control this
# -- it selected -R full-history behaviour on a FULL send, while incrementals
# used -I unconditionally regardless of the flag. Resolved: that flag is now
# -H, and -i has the literal zfs meaning instead -- pass -i to get
# `zfs send -i` (diff only) on an incremental, exactly like the real command.
# No flag at all still means -I (all intermediates), same as always.
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

# --- -i : skip intermediates, send only the diff to newest ------------------
# The mirror image of the test above: same setup, but -i must NOT carry the
# intermediate tier snapshots -- only the base (already on the target from the
# first send) and the newest land.
zfs create -p "$POOL/skipmid" || exit 1
run_send -m "auto_" "$POOL/skipmid" "$BK"
TSM="$(tgt_of skipmid)"
tick; zfs snapshot "$POOL/skipmid@tier_daily"
tick; zfs snapshot "$POOL/skipmid@tier_weekly"
tick; zfs snapshot "$POOL/skipmid@tier_final"
run_send -i -e "$POOL/skipmid" "$BK"
check "-i: exit code 0" "0" "$RC"
check "-i: intermediate tiers do NOT ride along" "no" \
      "$(zfs list -H -o name -t snapshot "$TSM" | grep -q '@tier_daily' \
         && echo yes || echo no)"
check "-i: the newest still lands" "yes" \
      "$(zfs list -H -o name -t snapshot "$TSM" | grep -q '@tier_final' && echo yes || echo no)"

# -i combined with -r: one atomic recursive stream, and the SAME elision
# applies tree-wide -- base and newest on every dataset in the subtree,
# intermediates on none. (Live-verified once already during design; pinned
# here so it stays true.)
zfs create -p "$POOL/skiprec" || exit 1
zfs create -p "$POOL/skiprec/child" || exit 1
run_send -r -m "auto_" "$POOL/skiprec" "$BK"
TSR="$(tgt_of skiprec)"
tick; zfs snapshot -r "$POOL/skiprec@mid"
tick; zfs snapshot -r "$POOL/skiprec@newest"
run_send -r -i -e "$POOL/skiprec" "$BK"
check "-i -r: parent skips the intermediate" "no" \
      "$(zfs list -H -o name -t snapshot "$TSR" | grep -q '@mid' && echo yes || echo no)"
check "-i -r: child skips the intermediate too" "no" \
      "$(zfs list -H -o name -t snapshot "$TSR/child" | grep -q '@mid' && echo yes || echo no)"
check "-i -r: parent still gains the newest" "yes" \
      "$(zfs list -H -o name -t snapshot "$TSR" | grep -q '@newest' && echo yes || echo no)"
check "-i -r: child still gains the newest" "yes" \
      "$(zfs list -H -o name -t snapshot "$TSR/child" | grep -q '@newest' && echo yes || echo no)"

# --- -T : auto-catch-up threshold --------------------------------------------
# The mechanism measures elapsed time against the dataset's OWN observed
# interval, so it is unit-agnostic -- a real gap of a couple of seconds
# between snapshots stands in for "hours" exactly as well as an actual hour
# would, letting this run in a normal test suite instead of waiting.
zfs create -p "$POOL/thresh" || exit 1
run_send -m "auto_" "$POOL/thresh" "$BK"
TT="$(tgt_of thresh)"
tick; zfs snapshot "$POOL/thresh@t2"
tick; zfs snapshot "$POOL/thresh@t3"
tick; zfs snapshot "$POOL/thresh@t4"
tick

# A high threshold: elapsed time since the common base is nowhere near
# threshold * own-interval, so -T must stand down and every intermediate
# still rides along, same as the default. -e with no -m: t2/t3/t4 don't carry
# the "auto_" prefix the first snapshot did, so a -m filter here would hide
# them from -e entirely and make this a no-op "already exists" skip instead
# of a real send -- bare -e picks the true newest regardless of name.
run_send -e -T 1000 "$POOL/thresh" "$BK"
check "-T high threshold: stands down, exit 0" "0" "$RC"
check "-T high threshold: intermediates still ride along" "yes" \
      "$(zfs list -H -o name -t snapshot "$TT" | grep -q '@t2' && echo yes || echo no)"

# Reset the target back to just the base and try again with a threshold of 1:
# more than 1 of the dataset's own (few-second) intervals has clearly elapsed,
# so -T must trigger and behave exactly like an explicit -i would.
zfs destroy -R "$TT"
FIRST_TT="$(zfs list -H -o name -s creation -t snapshot "$POOL/thresh" | head -1 | sed 's/.*@//')"
zfs send "$POOL/thresh@$FIRST_TT" | zfs recv -o canmount=noauto "$TT"
run_send -e -T 1 "$POOL/thresh" "$BK"
check "-T low threshold: triggers catch-up, exit 0" "0" "$RC"
check "-T low threshold: intermediates do NOT ride along" "no" \
      "$(zfs list -H -o name -t snapshot "$TT" | grep -q '@t2' && echo yes || echo no)"
check "-T low threshold: the newest still lands" "yes" \
      "$(zfs list -H -o name -t snapshot "$TT" | grep -q '@t4' && echo yes || echo no)"

# An explicit -i always wins over -T's inference -- -T must not even attempt
# its measurement once -i is already given.
zfs create -p "$POOL/threshwin" || exit 1
run_send -m "auto_" "$POOL/threshwin" "$BK"
TTW="$(tgt_of threshwin)"
tick; zfs snapshot "$POOL/threshwin@mid"
tick; zfs snapshot "$POOL/threshwin@newest"
run_send -e -i -T 1000 "$POOL/threshwin" "$BK"
check "-i wins over -T: intermediates skipped despite a stand-down threshold" "no" \
      "$(zfs list -H -o name -t snapshot "$TTW" | grep -q '@mid' && echo yes || echo no)"

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

# --- no -m: warned, not rejected ---------------------------------------------
# A missing prefix is legal -- the resulting snapshot just cannot be matched by
# any pattern-based delsnaps.sh retention job afterwards, so it accumulates
# forever unless something specifically targets it. Warned at verbosity 0 (a
# default cron run is the one place this mistake survives unnoticed), same
# reasoning as the container-parent warning.

zfs create -p "$POOL/nom1" || exit 1
run_send_out "$POOL/nom1" "$BK"
check "no -m: exit 0" "0" "$RC"
check "no -m: the warning fired" "1" "$(printf '%s' "$OUT" | grep -c 'no -m given')"
check "no -m: the new snapshot has a bare timestamp, no prefix" "1" \
      "$(zfs list -H -o name -t snapshot "$POOL/nom1" 2>/dev/null | grep -cE '@[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$')"

# -e with no -m must NOT warn: nothing new is being created here at all -- the
# newest snapshot on the dataset is picked up as-is, even one this tool never
# made (a manual `zfs snapshot`, another tool entirely). That is deliberate
# flexibility, not an oversight, so it gets no warning.
zfs create -p "$POOL/nom2" || exit 1
zfs snapshot "$POOL/nom2@made_by_something_else"
tick
run_send_out -e "$POOL/nom2" "$BK"
check "-e with no -m: exit 0" "0" "$RC"
check "-e with no -m: does NOT warn (existing snapshot reused, nothing created)" "0" \
      "$(printf '%s' "$OUT" | grep -c 'no -m given')"
check "-e with no -m: the pre-existing snapshot was the one sent" \
      "made_by_something_else" "$(snaps_of "$(tgt_of nom2)")"

# Baseline: -m given at all suppresses the warning, obviously.
zfs create -p "$POOL/nom3" || exit 1
run_send_out -m "auto_" "$POOL/nom3" "$BK"
check "-m given: does not warn" "0" "$(printf '%s' "$OUT" | grep -c 'no -m given')"

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

# snapget.sh v2.61+ is symmetric with snapsend.sh, not opposite-assigned:
# whichever side is READ is given literally (arg1); whichever side is
# WRITTEN gets an optional base for relocation (arg2, never a host prefix).
#
#   snapsend.sh <source>          <target-base>  -> target = <target-base>/<source>
#   snapget.sh  <literal-source>  <local-base>    -> target = <local-base>/<literal-source>
#
# So arg1 is always the dataset that gets READ in both scripts; arg2 is
# always the dataset that gets WRITTEN, relocatable via base in both. Pinning
# it here because getting it backwards is an easy and expensive mistake, and
# the failure is silent-ish: it just reports a missing source.
SRCBASE="$POOL/origin"
# v2.61 flip: arg1 is the literal source (created below at $SRCBASE/$POOL/<leaf>,
# unchanged from before), arg2 is now a LOCAL_BASE for relocation, not a base
# used to locate the source. Every pulled target through this whole section
# therefore lands at $PULLED/$SRCBASE/$POOL/<leaf> instead of the old bare
# $POOL/<leaf> -- defined once here, used by every case below.
LOCALPULL="$POOL/lp"
PULLED="$LOCALPULL/$SRCBASE"
zfs create -p "$SRCBASE/$POOL/pull" || exit 1
zfs snapshot "$SRCBASE/$POOL/pull@auto_1"
run_get -e -m "auto_" "$SRCBASE/$POOL/pull" "$LOCALPULL"
check "snapget: local pull lands the snapshot on the local target" "auto_1" \
      "$(snaps_of "$PULLED/$POOL/pull")"
check "snapget: exit 0" "0" "$RC"
check "snapget: target is created with canmount=noauto" "noauto" \
      "$(zfs get -H -o value canmount "$PULLED/$POOL/pull")"

tick; zfs snapshot "$SRCBASE/$POOL/pull@auto_2"
run_get -e -m "auto_" "$SRCBASE/$POOL/pull" "$LOCALPULL"
check "snapget: incremental pull adds the new snapshot" "auto_1 auto_2" \
      "$(snaps_of "$PULLED/$POOL/pull")"

zfs create -p "$SRCBASE/$POOL/pullnomatch" || exit 1
zfs snapshot "$SRCBASE/$POOL/pullnomatch@other_1"
run_get -e -m "automated_hourly_" "$SRCBASE/$POOL/pullnomatch" "$LOCALPULL"
check "snapget: no snapshot matching the prefix is an error" "1" "$RC"

# --- snapget mirror of the no -m warning -------------------------------------
GNOM1="$SRCBASE/$POOL/gnom1"
zfs create -p "$GNOM1" || exit 1
run_get_out "$GNOM1" "$LOCALPULL"
check "snapget no -m: exit 0" "0" "$RC"
check "snapget no -m: the warning fired" "1" "$(printf '%s' "$OUT" | grep -c 'no -m given')"

GNOM2="$SRCBASE/$POOL/gnom2"
zfs create -p "$GNOM2" || exit 1
zfs snapshot "${GNOM2}@made_by_something_else"
tick
run_get_out -e "$GNOM2" "$LOCALPULL"
check "snapget -e with no -m: does NOT warn" "0" "$(printf '%s' "$OUT" | grep -c 'no -m given')"
check "snapget -e with no -m: the pre-existing snapshot was the one pulled" \
      "made_by_something_else" "$(snaps_of "$PULLED/$POOL/gnom2")"
check "snapget: a doomed run does not create the local target" "no" \
      "$(zfs list -H -o name "$PULLED/$POOL/pullnomatch" >/dev/null 2>&1 && echo yes || echo no)"

# snapget carries the same -f ordering fix as snapsend; keep both guarded.
run_get -f -e -m "NO_SUCH_PREFIX_" "$SRCBASE/$POOL/pull" "$LOCALPULL"
check "snapget -f: a doomed forced run leaves the local target intact" "auto_1 auto_2" \
      "$(snaps_of "$PULLED/$POOL/pull")"

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
# U43: the push dry run plans the bookmark increment too (twin of the snapget check).
OUT="$("$SNAPSEND" -n -e "$POOL/bm1" "$BK" 2>&1)"
check "bookmark: push dry run (-n) plans INCREMENTAL from the bookmark, not FULL (U43)" "1" \
      "$(printf '%s\n' "$OUT" | grep -cE '^PLAN=INCREMENTAL base=[^ ]*#')"
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
run_get -e "$GSRC" "$LOCALPULL"
check "snapget bookmark: first pull lands @a" "a" "$(snaps_of "$PULLED/$POOL/pullbm")"

zfs destroy "${GSRC}@a"
tick
zfs snapshot "${GSRC}@c"
# U43 (owner 2026-10-20): the DRY RUN plans what the run will do -- the bookmark rescues
# the increment, so the plan must say INCREMENTAL with the bookmark as base, not FULL.
run_get_out -n -e "$GSRC" "$LOCALPULL"
check "snapget bookmark: dry run (-n) plans INCREMENTAL from the bookmark, not FULL (U43)" "1" \
      "$(printf '%s\n' "$OUT" | grep -cE '^PLAN=INCREMENTAL base=[^ ]*#')"
run_get -e "$GSRC" "$LOCALPULL"
check "snapget bookmark: exit 0 even though the common-base snapshot is gone from source" "0" "$RC"
check "snapget bookmark: local target keeps @a AND gains @c" "a c" "$(snaps_of "$PULLED/$POOL/pullbm")"

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
    run_get -w -e -m "auto_" "$SRCBASE/$POOL/rawpull" "$LOCALPULL"
    check "snapget -w: raw pull exits 0" "0" "$RC"
    check "snapget -w: the local target is encrypted" "aes-256-gcm" \
          "$(zfs get -H -o value encryption "$PULLED/$POOL/rawpull" 2>/dev/null)"

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

# --- W19: a plain stream into a target under an ENCRYPTED parent --------------
# Owner 2026-10-11 (encrypted replica medium), measured on pve9b: every mode
# failed, "zfs receive -F cannot be used to destroy an encrypted filesystem", because
# the engine pre-created the leaf, the leaf inherited the parent's encryption and
# the first FULL receive could not replace it. The receive now creates the leaf
# (it inherits the key), in both engines. Old code: rc 1 on the first send.
if mkenc "$POOL/encdst" 2>/dev/null; then
    zfs create "$POOL/w19src" && zfs snapshot "$POOL/w19src@auto_1"
    run_send -e -m "auto_" "$POOL/w19src" "$POOL/encdst"
    T19="$POOL/encdst/$POOL/w19src"
    check "W19: push, plain stream into an encrypted parent -- first send exits 0" "0" "$RC"
    check "W19: ...the target inherits the parent's encryption" "$POOL/encdst" \
          "$(zfs get -H -o value encryptionroot "$T19" 2>/dev/null)"
    check "W19: ...canmount=noauto restored on the recv-created leaf" "noauto" \
          "$(zfs get -H -o value canmount "$T19" 2>/dev/null)"
    tick; zfs snapshot "$POOL/w19src@auto_2"
    run_send -e -m "auto_" "$POOL/w19src" "$POOL/encdst"
    check "W19: push, incremental into the encrypted parent" "0:auto_1 auto_2" "$RC:$(snaps_of "$T19")"
    zfs create "$POOL/w19g" && zfs snapshot "$POOL/w19g@auto_1"
    run_get -e -m "auto_" "$POOL/w19g" "$POOL/encdst"
    check "W19: pull, plain stream into an encrypted parent -- first pull exits 0" "0:$POOL/encdst" \
          "$RC:$(zfs get -H -o value encryptionroot "$POOL/encdst/$POOL/w19g" 2>/dev/null)"
else
    echo "SKIP W19 encrypted-parent tests: this ZFS build cannot create encrypted datasets"
fi

# --- W14: a copy that discards only a replica's own snapshots ----------------
# only_replica_snaps decides whether "follows its source -- discarding" is said at
# level 2 (a replica's work) or level 0 (a real divergence).
w14() { ( . "$REPO/lib-zfs-snap.sh" >/dev/null 2>&1; only_replica_snaps "$@" ) && echo y || echo n; }
check "W14: only replica_ snapshots, nothing written -> quiet" "y" "$(w14 0 replica_2026-10-11_20-44-51 replica_2026-10-11_21-00-00)"
check "W14: a foreign snapshot among them -> loud" "n" "$(w14 0 replica_a manual_b)"
check "W14: bytes written on the copy -> loud" "n" "$(w14 4096 replica_a)"
check "W14: nothing to discard -> not the replica case" "n" "$(w14 0)"

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
run_get -Z -e -m "auto_" "$SRCBASE/$POOL/czpull" "$LOCALPULL"
check "snapget -Z: compressed pull exits 0" "0" "$RC"
check "snapget -Z: the snapshot landed locally" "auto_1" "$(snaps_of "$PULLED/$POOL/czpull")"

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
run_get -e -m "auto_" "$GSRC2" "$LOCALPULL"
check "snapget hold: successful pull releases the hold on the source" "no" \
      "$(held_by_us "${GSRC2}@auto_1" && echo yes || echo no)"

GSRC3="$SRCBASE/$POOL/holdfailpull"
GTGT3="$PULLED/$POOL/holdfailpull"
zfs create -p "$GSRC3" || exit 1
zfs snapshot "${GSRC3}@a"
run_get -e "$GSRC3" "$LOCALPULL"
zfs destroy "${GSRC3}@a"
tick
zfs snapshot "${GSRC3}@c"
zfs destroy "${GTGT3}@a"
zfs snapshot "${GTGT3}@rogue"
run_get -e "$GSRC3" "$LOCALPULL"
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
GTGT4="$PULLED/$POOL/guidpull"
zfs create -p "$GSRC4" || exit 1
zfs snapshot "${GSRC4}@a"
run_get -e "$GSRC4" "$LOCALPULL"
check "snapget guid-match: first pull lands @a" "a" "$(snaps_of "$GTGT4")"

zfs rename "${GTGT4}@a" "${GTGT4}@renamed"
tick
zfs snapshot "${GSRC4}@b"
run_get -e "$GSRC4" "$LOCALPULL"
check "snapget guid-match: exit 0 even though the local target's snapshot was renamed" "0" "$RC"
check "snapget guid-match: target keeps the renamed snapshot AND gains the new one" \
      "renamed b" "$(snaps_of "$GTGT4")"

# --- -j/--identifier: independent jobs to the same target get separate bookmarks
# record_send_bookmark folds -j into bookmark_target_tag, so two jobs that both
# send the SAME source to the SAME target under different identifiers must not
# clobber each other's incremental-base bookmark. Each send below advances the
# source with a fresh snapshot first, so every run is a real transfer (not the
# "already exists - skipping" early return, which never reaches
# record_send_bookmark at all). (Was -i; freed for skip-intermediates, see above.)

zfs create -p "$POOL/identsend" || exit 1
zfs snapshot "$POOL/identsend@a"
run_send -e -j jobA "$POOL/identsend" "$BK"
check "identifier: jobA initial send succeeds" "0" "$RC"

tick
zfs snapshot "$POOL/identsend@b"
run_send -e -j jobB "$POOL/identsend" "$BK"
check "identifier: jobB send (different identifier, same target) succeeds" "0" "$RC"
check "identifier: jobA and jobB now hold two DISTINCT bookmarks on the source" \
      "2" "$(zfs list -H -t bookmark -o name "$POOL/identsend" 2>/dev/null | wc -l)"

tick
zfs snapshot "$POOL/identsend@c"
run_send -e -j jobA "$POOL/identsend" "$BK"
check "identifier: jobA re-run succeeds" "0" "$RC"
check "identifier: jobA re-run refreshes its OWN bookmark, not a third" \
      "2" "$(zfs list -H -t bookmark -o name "$POOL/identsend" 2>/dev/null | wc -l)"

# snapget mirror -- record_send_bookmark still writes to the SOURCE dataset
# (here under $SRCBASE, standing in for the remote), tagged by the LOCAL pull
# target + identifier.
GSRC5="$SRCBASE/$POOL/identpull"
zfs create -p "$GSRC5" || exit 1
zfs snapshot "${GSRC5}@a"
run_get -e -j jobA "$GSRC5" "$LOCALPULL"
check "snapget identifier: jobA initial pull succeeds" "0" "$RC"

tick
zfs snapshot "${GSRC5}@b"
run_get -e -j jobB "$GSRC5" "$LOCALPULL"
check "snapget identifier: jobB pull (different identifier, same target) succeeds" "0" "$RC"
check "snapget identifier: jobA and jobB now hold two DISTINCT bookmarks on the source" \
      "2" "$(zfs list -H -t bookmark -o name "$GSRC5" 2>/dev/null | wc -l)"

tick
zfs snapshot "${GSRC5}@c"
run_get -e -j jobA "$GSRC5" "$LOCALPULL"
check "snapget identifier: jobA re-run succeeds" "0" "$RC"
check "snapget identifier: jobA re-run refreshes its OWN bookmark, not a third" \
      "2" "$(zfs list -H -t bookmark -o name "$GSRC5" 2>/dev/null | wc -l)"

# --- -X / -S: filtering the -R expansion -------------------------------------
# Both only make sense while -R is building the dataset list, so the first thing
# pinned is that they are REJECTED elsewhere rather than quietly ignored -- a
# filter that does nothing while looking like it worked is the worst outcome.

zfs create -p "$POOL/xtree" || exit 1
zfs create -p "$POOL/xtree/keep" || exit 1
zfs create -p "$POOL/xtree/swap" || exit 1
zfs create -p "$POOL/xtree/swap/inner" || exit 1

run_send -m "auto_" -X 'swap' "$POOL/xtree" "$BK"
check "-X without -R is rejected" "1" "$RC"
run_send -m "auto_" -S "$POOL/xtree" "$BK"
check "-S without -R is rejected" "1" "$RC"
run_send -m "auto_" -R -X '[' "$POOL/xtree" "$BK"
check "-X with a malformed regex is rejected before any work" "1" "$RC"
check "-X malformed: no snapshot was taken on the source" "0" \
      "$(count_snaps "$POOL/xtree")"

# Anchored on purpose: a bare 'swap' would also match "$POOL/xtree/swap/inner",
# because the pattern is unanchored and a descendant's name CONTAINS its
# parent's. That trap gets its own case below.
tick
run_send -m "auto_" -R -X 'swap$' "$POOL/xtree" "$BK"
check "-R -X: exit 0" "0" "$RC"
check "-R -X: the parent itself is still sent" "yes" \
      "$(zfs list -H -o name "$(tgt_of xtree)" >/dev/null 2>&1 && echo yes || echo no)"
check "-R -X: the non-matching child is sent" "yes" \
      "$(zfs list -H -o name "$(tgt_of xtree/keep)" >/dev/null 2>&1 && echo yes || echo no)"
# The excluded dataset must have no snapshot of its own on the SOURCE either --
# filtering happens before the snapshot is created, not just before the send.
check "-R -X: the matching child was never snapshotted" "0" \
      "$(count_snaps "$POOL/xtree/swap")"
# syncoid semantics: -X drops the matching dataset, NOT its descendants. The
# child still lands, and `zfs create -p` supplies the skipped level as an empty
# dataset so it has somewhere to go.
check "-R -X: a descendant of an excluded dataset is still sent" "yes" \
      "$(zfs list -H -o name "$(tgt_of xtree/swap/inner)" >/dev/null 2>&1 && echo yes || echo no)"
check "-R -X: the skipped level exists on the target but holds no snapshot" "0" \
      "$(count_snaps "$(tgt_of xtree/swap)")"

# The flip side, and the easiest -X mistake to make: UNANCHORED, the same
# pattern also matches every descendant, because a child's full name contains
# its parent's. Pinned as behaviour, not as an accident -- it is what syncoid's
# --exclude does too, and the fix is to anchor the pattern.
tick
zfs create -p "$POOL/utree/swap/inner" || exit 1
run_send -m "auto_" -R -X 'swap' "$POOL/utree" "$BK"
check "-R -X unanchored: exit 0" "0" "$RC"
check "-R -X unanchored: the matching dataset is excluded" "0" \
      "$(count_snaps "$POOL/utree/swap")"
check "-R -X unanchored: its descendant matches too and is ALSO excluded" "0" \
      "$(count_snaps "$POOL/utree/swap/inner")"

tick
zfs create -p "$POOL/stree" || exit 1
zfs create -p "$POOL/stree/a" || exit 1
zfs create -p "$POOL/stree/b" || exit 1
run_send -m "auto_" -R -S "$POOL/stree" "$BK"
check "-R -S: exit 0" "0" "$RC"
check "-R -S: the parent is NOT snapshotted" "0" "$(count_snaps "$POOL/stree")"
check "-R -S: child a is sent" "1" "$(count_snaps "$(tgt_of stree/a)")"
check "-R -S: child b is sent" "1" "$(count_snaps "$(tgt_of stree/b)")"

tick
run_send -m "auto_" -R -S -X 'stree/(a|b)' "$POOL/stree" "$BK"
check "-R -S -X: filtering everything out fails loudly instead of exiting 0" "1" "$RC"

tick
zfs create -p "$POOL/lonely" || exit 1
run_send -m "auto_" -R -S "$POOL/lonely" "$BK"
check "-R -S on a childless dataset is an error, not a silent no-op" "1" "$RC"
check "-R -S on a childless dataset takes no snapshot" "0" "$(count_snaps "$POOL/lonely")"

# Repeatability: two -X flags are OR-ed, a dataset goes if either matches.
tick
zfs create -p "$POOL/mtree" || exit 1
zfs create -p "$POOL/mtree/one" || exit 1
zfs create -p "$POOL/mtree/two" || exit 1
zfs create -p "$POOL/mtree/three" || exit 1
run_send -m "auto_" -R -X 'one$' -X 'two$' "$POOL/mtree" "$BK"
check "-X is repeatable: exit 0" "0" "$RC"
check "-X is repeatable: first pattern excluded" "0" "$(count_snaps "$POOL/mtree/one")"
check "-X is repeatable: second pattern excluded" "0" "$(count_snaps "$POOL/mtree/two")"
check "-X is repeatable: the unmatched child is still sent" "1" \
      "$(count_snaps "$(tgt_of mtree/three)")"

# snapget mirror. The name -X sees is the FULL source-side path exactly as
# given/discovered (v2.61+: arg1 IS that literal path now, nothing to strip)
# -- so a regex reads the same in both directions.
GX="$SRCBASE/$POOL/xpull"
zfs create -p "$GX" || exit 1
zfs create -p "$GX/keep" || exit 1
zfs create -p "$GX/swap" || exit 1

run_get -m "auto_" -X 'swap' "$GX" "$LOCALPULL"
check "snapget: -X without -R is rejected" "1" "$RC"

tick
run_get -m "auto_" -R -X 'swap' "$GX" "$LOCALPULL"
check "snapget -R -X: exit 0" "0" "$RC"
check "snapget -R -X: the non-matching child is pulled" "1" \
      "$(count_snaps "$PULLED/$POOL/xpull/keep")"
check "snapget -R -X: the matching child is not" "0" \
      "$(count_snaps "$PULLED/$POOL/xpull/swap")"
# Anchored against the full source path -- proves the match runs against $GX,
# not the local target name, where this pattern could never hit.
tick
run_get -m "auto_" -R -X "^$GX/keep$" "$GX" "$LOCALPULL"
check "snapget -R -X: regex is matched against the full source-side name" "0" "$RC"
check "snapget -R -X: full-path exclusion kept 'keep' at its previous snapshot" "1" \
      "$(count_snaps "$PULLED/$POOL/xpull/keep")"

tick
GS="$SRCBASE/$POOL/spull"
zfs create -p "$GS" || exit 1
zfs create -p "$GS/a" || exit 1
run_get -m "auto_" -R -S "$GS" "$LOCALPULL"
check "snapget -R -S: exit 0" "0" "$RC"
check "snapget -R -S: the parent is NOT snapshotted on the source" "0" "$(count_snaps "$GS")"
check "snapget -R -S: the child is pulled" "1" "$(count_snaps "$PULLED/$POOL/spull/a")"

# --- target ancestors are created canmount=noauto, not canmount=on -----------
# `zfs create -p` applies -o to the final dataset only, so every level it
# invents got canmount=on and ZFS tried to mount it. Root does not notice; a
# delegated non-root account cannot mount at all and the receive died with
# "Insufficient privileges". Root cannot reproduce the failure, so what is
# pinned here is the PROPERTY that makes it impossible.

zfs create -p "$POOL/anc" || exit 1
run_send -m "auto_" "$POOL/anc" "$BK/deep/deeper"
check "ancestors: send into a brand-new multi-level target path succeeds" "0" "$RC"
check "ancestors: an invented intermediate level is canmount=noauto" "noauto" \
      "$(zfs get -H -o value canmount "$BK/deep")"
check "ancestors: so is the level below it" "noauto" \
      "$(zfs get -H -o value canmount "$BK/deep/deeper")"
check "ancestors: the leaf still received its snapshot" "1" \
      "$(count_snaps "$BK/deep/deeper/$POOL/anc")"

# An ancestor that ALREADY exists must be left exactly as the operator set it --
# the helper creates missing levels, it does not normalise existing ones.
zfs create -o canmount=on "$BK/keepon" || exit 1
tick
zfs create -p "$POOL/anc2" || exit 1
run_send -m "auto_" "$POOL/anc2" "$BK/keepon/sub"
check "ancestors: send under a pre-existing ancestor succeeds" "0" "$RC"
check "ancestors: a pre-existing ancestor keeps its own canmount" "on" \
      "$(zfs get -H -o value canmount "$BK/keepon")"

# --- a failure BEFORE the transfer must not strand the hold ------------------
# The hold is taken right after the snapshot, i.e. before the target is created.
# Every early exit between those two points used to `return 1` without releasing
# it, so the source snapshot became un-prunable and `zfs destroy` reported the
# misleading "dataset is busy". Root rarely hits those paths; a delegated
# non-root account hit them on every run (it cannot mount an intermediate).
#
# Forced here by making target creation fail for a reason root also sees: a
# target path whose parent is a ZVOL, which cannot hold child datasets.

zfs create -V 16M -s "$POOL/blockparent" || exit 1
zfs create -p "$POOL/holdsrc" || exit 1
run_send -m "auto_" "$POOL/holdsrc" "$POOL/blockparent"
check "pre-transfer failure: the run reports failure" "1" "$RC"
SRCSNAP="$(zfs list -H -o name -t snapshot "$POOL/holdsrc" | tail -1)"
check "pre-transfer failure: a source snapshot was taken" "1" \
      "$(count_snaps "$POOL/holdsrc")"
check "pre-transfer failure: no hold is left on it" "" \
      "$(zfs holds -H "$SRCSNAP" | awk '{print $2}')"
check "pre-transfer failure: so the snapshot is destroyable" "0" \
      "$(zfs destroy "$SRCSNAP" >/dev/null 2>&1; echo $?)"

# --- ssh failure vs. missing dataset: two causes, two messages ---------------
# This suite is local-mode only (see the header) and stays that way. What is
# under test here is not ssh, it is OUR READING of ssh's exit status: 255 is
# ssh's own reserved code for a connection-level failure (auth, host key,
# unreachable, DNS) and `zfs list` never returns it, so the two cases are
# distinguishable -- and used not to be distinguished. Every remote probe in
# snapget.sh reported "Source dataset not found on remote host", which sends the
# reader to inspect a dataset that was there the whole time. That misdirection
# cost real debugging time twice on 2026-07-29 (once through a dropped -K, once
# reproduced deliberately with a wrong host key), and its lookalike in
# delsnaps.sh read an ssh failure as "nothing to prune".
#
# Forced with no peer, no network and no stub: -O ProxyCommand=/bin/false makes
# ssh fail at connect time with rc 255 in about 6ms, on any host, every time.
# The dataset named below is a REAL local one, so "not found" would be wrong
# twice over.
BADCONN=(-O "ProxyCommand=/bin/false")
PROBEDS="$SRCBASE/$POOL/pull"
said()   { printf '%s\n' "$OUT" | grep -q "$1" && echo yes || echo no; }

run_get_out "${BADCONN[@]}" -e -m "auto_" "root@127.0.0.1:$PROBEDS" "$LOCALPULL"
check "ssh 255, plain pull: exit 1" "1" "$RC"
check "ssh 255, plain pull: named as a connection failure" "yes" \
      "$(said 'CONNECTION-level failure')"
check "ssh 255, plain pull: does NOT blame the dataset" "no" \
      "$(said 'Source dataset not found')"
check "ssh 255, plain pull: ssh's own reason is quoted in the message" "yes" \
      "$(said 'ssh said:')"

run_get_out "${BADCONN[@]}" -R -m "auto_" "root@127.0.0.1:$PROBEDS" "$LOCALPULL"
check "ssh 255, -R expansion: exit 1" "1" "$RC"
check "ssh 255, -R expansion: named as a connection failure" "yes" \
      "$(said 'CONNECTION-level failure')"
check "ssh 255, -R expansion: does NOT blame the dataset" "no" \
      "$(said 'Source dataset not found')"

# The -R expansion makes TWO remote calls -- probe the named source, then list
# its descendants -- and a broken connection can only ever reach the first: if
# ssh is down, the probe fails and the listing never runs. So the listing half
# needs a connection that works for the probe and dies for the listing, which is
# the only thing this stub ssh exists for. It tests nothing about ssh; it puts
# the script in front of a 255 that is otherwise unreachable from one machine.
#
# On the reviewed base the listing's exit status was discarded outright, so a
# dead connection became an empty child list and the run blamed -X/-S ("filtered
# out every dataset") for a run that passed neither -- the same misdirection one
# layer down, and with more than one comma-separated source it silently narrows
# what gets pulled instead of failing.
mkdir -p "$TMPD/stubbin"
cat > "$TMPD/stubbin/ssh" <<'STUBEOF'
#!/bin/bash
# The remote command is always the last argument.
case "${!#}" in
    *"-t filesystem,volume -r "*) exit 255 ;;   # the -R descendant listing
    *)                            exit 0   ;;   # everything else: connected, fine
esac
STUBEOF
chmod +x "$TMPD/stubbin/ssh"
STUBPATH="$PATH"
PATH="$TMPD/stubbin:$PATH"
run_get_out -R -m "auto_" "root@127.0.0.1:$PROBEDS" "$LOCALPULL"
PATH="$STUBPATH"
check "ssh 255 on the -R listing: exit 1" "1" "$RC"
check "ssh 255 on the -R listing: named as a connection failure" "yes" \
      "$(said 'CONNECTION-level failure')"
check "ssh 255 on the -R listing: does NOT blame -X/-S" "no" \
      "$(said 'filtered out every dataset')"

# The other half of the contract: a probe that DID get an answer must still say
# "not found" and must not cry connection. Local mode is that answer -- ssh is
# not involved at all, so a missing dataset is unambiguous.
run_get_out -e -m "auto_" "$SRCBASE/$POOL/no-such-source" "$LOCALPULL"
check "answered probe, missing local source: exit 1" "1" "$RC"
check "answered probe, missing local source: says not found" "yes" \
      "$(said 'Source dataset not found')"
check "answered probe, missing local source: says nothing about ssh" "no" \
      "$(said 'CONNECTION-level failure')"

# --- P. PAIRED: in local mode the twins must be INDISTINGUISHABLE ------------
# Every case above pins ONE engine. This section runs the SAME argv through
# BOTH and asserts the same answer: exit code, what landed, what was refused.
# Local mode is the one mode in which push and pull do identical work -- no
# ssh on either side, the same `zfs send | zfs recv` -- so it is where a
# behavioural difference between them is a defect by construction, not a
# direction. Added 2026-09-07 (M-b of OWNER-ENGINE-MERGE-2026-09-07.md section
# 8), after push was found seventeen days behind pull on `-R -e` under a
# green drift alarm: 77 run_send and 28 run_get above, and not one assertion
# that compared the two.
#
# Both engines relocate under the base the same way: <base>/<full source name>.
PBK="$POOL/pbk"   # push writes here
PLP="$POOL/plp"   # pull writes here
pair_rc() {   # <label> <args...> -> RC_S / RC_G, OUT_S / OUT_G, and one check that they agree
    local label="$1"; shift
    run_send_out "$@" "$PBK"; RC_S=$RC; OUT_S="$OUT"
    run_get_out  "$@" "$PLP"; RC_G=$RC; OUT_G="$OUT"
    check "P $label: push and pull agree on the exit code" "$RC_G" "$RC_S"
}

# P1. -R -e over a subtree with scaffolding in it: the root and one path
# container carry no family, two leaves do. Pull skips the scaffolding and
# adopts the leaves (snapget v2.70, 2026-08-21); push did the same only from
# v2.73 -- before that it failed the whole run on the first family-less member.
zfs create -p "$POOL/pe/a" || exit 1
zfs create -p "$POOL/pe/mid/leaf" || exit 1
zfs snapshot "$POOL/pe/a@auto_1"
zfs snapshot "$POOL/pe/mid/leaf@auto_1"
pair_rc "-R -e over scaffolding" -R -e -m "auto_" "$POOL/pe"
check "P -R -e over scaffolding: the agreed answer is success (leaves adopted, scaffolding skipped)" "0" "$RC_S"
check "P -R -e over scaffolding: push adopted the deep leaf" "auto_1" "$(snaps_of "$PBK/$POOL/pe/mid/leaf")"
check "P -R -e over scaffolding: pull adopted the same" "$(snaps_of "$PBK/$POOL/pe/mid/leaf")" "$(snaps_of "$PLP/$POOL/pe/mid/leaf")"
check "P -R -e over scaffolding: push adopted the shallow leaf" "auto_1" "$(snaps_of "$PBK/$POOL/pe/a")"
check "P -R -e over scaffolding: the path container got no snapshot on either side" "0 0" \
      "$(count_snaps "$PBK/$POOL/pe/mid") $(count_snaps "$PLP/$POOL/pe/mid")"
check "P -R -e over scaffolding: the root got no snapshot on either side" "0 0" \
      "$(count_snaps "$PBK/$POOL/pe") $(count_snaps "$PLP/$POOL/pe")"

# P2. -R -e over NOTHING BUT scaffolding: every member skipped is not success.
zfs create -p "$POOL/pn/x" || exit 1
pair_rc "-R -e over scaffolding only" -R -e -m "auto_" "$POOL/pn"
check "P -R -e over scaffolding only: the agreed answer is failure -- nothing was adopted" "1" "$RC_S"
check "P -R -e over scaffolding only: push says so in the same words as pull" "yes" \
      "$(printf '%s\n' "$OUT_S" | grep -q 'nothing was adopted' && echo yes || echo no)"

# P3. The dry-run verdict is the same line from both engines.
zfs create -p "$POOL/pp" || exit 1
zfs snapshot "$POOL/pp@auto_1"
pair_rc "dry run" -n -e -m "auto_" "$POOL/pp"
check "P dry run: push prints a PLAN= line" "1" "$(printf '%s\n' "$OUT_S" | grep -c '^PLAN=')"
check "P dry run: the same verdict from both engines (target absent -> not incremental)" \
      "$(printf '%s\n' "$OUT_G" | grep -m1 -o '^PLAN=[A-Z]* base=[^ ]*')" \
      "$(printf '%s\n' "$OUT_S" | grep -m1 -o '^PLAN=[A-Z]* base=[^ ]*')"
check "P dry run: nothing landed on either side" "no no" \
      "$(zfs list -H -o name "$PBK/$POOL/pp" >/dev/null 2>&1 && echo yes || echo no) $(zfs list -H -o name "$PLP/$POOL/pp" >/dev/null 2>&1 && echo yes || echo no)"

# P4. Full, then incremental, adopting the source's own family (-e): the two
# targets end up holding the same snapshots as the source and as each other.
zfs create -p "$POOL/pi" || exit 1
zfs snapshot "$POOL/pi@auto_1"
pair_rc "first transfer" -e -m "auto_" "$POOL/pi"
check "P first transfer: the agreed answer is success" "0" "$RC_S"
zfs snapshot "$POOL/pi@auto_2"
pair_rc "incremental" -e -m "auto_" "$POOL/pi"
check "P incremental: the agreed answer is success" "0" "$RC_S"
check "P incremental: push holds what the source holds" "$(snaps_of "$POOL/pi")" "$(snaps_of "$PBK/$POOL/pi")"
check "P incremental: pull holds the same" "$(snaps_of "$PBK/$POOL/pi")" "$(snaps_of "$PLP/$POOL/pi")"

# P5. A target with NO common snapshot (case E of P-0): it exists and holds a
# snapshot the source never had. Both refuse in the same words and leave the
# copy alone -- ZFS refuses a full stream there even with -F, and push now says
# so before sending (P-0, owner 2026-10-08, ENGINE-FREEZE.md).
zfs create -p "$POOL/pd" || exit 1
zfs snapshot "$POOL/pd@auto_1"
zfs create -p "$PBK/$POOL/pd" || exit 1
zfs snapshot "$PBK/$POOL/pd@other"
zfs create -p "$PLP/$POOL/pd" || exit 1
zfs snapshot "$PLP/$POOL/pd@other"
pair_rc "diverged target" -e -m "auto_" "$POOL/pd"
check "P diverged target: the agreed answer is refusal" "1" "$RC_S"
check "P diverged target: pull left the copy's own snapshot in place" "other" "$(snaps_of "$PLP/$POOL/pd")"
check "P diverged target: push left the copy's own snapshot in place" "other" "$(snaps_of "$PBK/$POOL/pd")"
check "P diverged target: pull says why" "yes" \
      "$(printf '%s\n' "$OUT_G" | grep -q 'shares no common snapshot' && echo yes || echo no)"
check "P diverged target: push says why, in the same words" "yes" \
      "$(printf '%s\n' "$OUT_S" | grep -q 'shares no common snapshot' && echo yes || echo no)"

# P-0 (owner, 2026-10-08, "odmrazam, wariant D3"): A BACKUP COPY FOLLOWS ITS
# SOURCE. What sits on the copy after the common snapshot is surplus; both
# engines discard it with -F and say what, at level 0. Before: push did it
# silently, pull refused with a full resend (-f) as the only way out.
said_s() { printf '%s\n' "$OUT_S" | grep -q -- "$1" && echo yes || echo no; }
# The suite's pool is created with -m none: give the copy a mountpoint of its
# own, write, unmount, and push the txg out so written@ sees it.
write_into_copy() {
    local mp; mp="$TMPD/mnt.$(printf '%s' "$1" | tr '/' '_')"
    zfs set mountpoint="$mp" "$1" && zfs mount "$1" 2>/dev/null
    dd if=/dev/urandom of="$mp/stray" bs=64k count=4 2>/dev/null
    zfs umount "$1"; zpool sync "$POOL"
}
said_g() { printf '%s\n' "$OUT_G" | grep -q -- "$1" && echo yes || echo no; }

# P6. Case B: a snapshot taken by hand on the copy, after the common one.
zfs create -p "$POOL/pb" || exit 1
zfs snapshot "$POOL/pb@auto_1"
pair_rc "B first" -e -m "auto_" "$POOL/pb"
zfs snapshot "$PBK/$POOL/pb@manual"
zfs snapshot "$PLP/$POOL/pb@manual"
zfs snapshot "$POOL/pb@auto_2"
pair_rc "B manual snapshot on the copy" -e -m "auto_" "$POOL/pb"
check "P B: the agreed answer is success" "0" "$RC_S"
check "P B: push followed the source (manual gone)" "auto_1 auto_2" "$(snaps_of "$PBK/$POOL/pb")"
check "P B: pull the same" "auto_1 auto_2" "$(snaps_of "$PLP/$POOL/pb")"
check "P B: push names what it discarded" "yes" "$(said_s 'discarding 1 snapshot(s) after @auto_1 that the source no longer has: manual')"
check "P B: pull names it in the same words" "yes" "$(said_g 'discarding 1 snapshot(s) after @auto_1 that the source no longer has: manual')"

# P7. Case C: a write to the copy after the common snapshot.
zfs create -p "$POOL/pw" || exit 1
zfs snapshot "$POOL/pw@auto_1"
pair_rc "C first" -e -m "auto_" "$POOL/pw"
for _c in "$PBK/$POOL/pw" "$PLP/$POOL/pw"; do write_into_copy "$_c"; done
zfs snapshot "$POOL/pw@auto_2"
pair_rc "C write on the copy" -e -m "auto_" "$POOL/pw"
check "P C: the agreed answer is success" "0" "$RC_S"
check "P C: push followed the source" "auto_1 auto_2" "$(snaps_of "$PBK/$POOL/pw")"
check "P C: pull the same" "auto_1 auto_2" "$(snaps_of "$PLP/$POOL/pw")"
check "P C: push says it rolled back bytes" "yes" "$(said_s 'byte(s) written after @auto_1')"
check "P C: pull says the same" "yes" "$(said_g 'byte(s) written after @auto_1')"

# P8. Case D: the SOURCE was rolled back past a snapshot the copy holds.
zfs create -p "$POOL/pr" || exit 1
zfs snapshot "$POOL/pr@auto_1"
pair_rc "D first" -e -m "auto_" "$POOL/pr"
zfs snapshot "$POOL/pr@auto_2"
pair_rc "D second" -e -m "auto_" "$POOL/pr"
zfs rollback -r "$POOL/pr@auto_1"
zfs snapshot "$POOL/pr@auto_3"
pair_rc "D source rolled back" -e -m "auto_" "$POOL/pr"
check "P D: the agreed answer is success" "0" "$RC_S"
check "P D: push followed the source (auto_2 gone)" "auto_1 auto_3" "$(snaps_of "$PBK/$POOL/pr")"
check "P D: pull the same" "auto_1 auto_3" "$(snaps_of "$PLP/$POOL/pr")"
check "P D: push names the rolled-away snapshot" "yes" "$(said_s 'after @auto_1 that the source no longer has: auto_2')"
check "P D: pull names it" "yes" "$(said_g 'after @auto_1 that the source no longer has: auto_2')"

# P9-P10. Not a backup landing (-t, an exact path -- the restore direction): the
# same surplus is refused by both, and the copy is left as it was.
zfs create -p "$POOL/px" || exit 1
zfs snapshot "$POOL/px@auto_1"
run_send_out -t -e -m "auto_" "$POOL/px" "$PBK/xs"; RC_S=$RC
run_get_out  -t -e -m "auto_" "$POOL/px" "$PLP/xg"; RC_G=$RC
check "P -t first: both landed" "0 0" "$RC_S $RC_G"
# P10: an EMPTY snapshot on the exact path adds no bytes. Both receive
# without -F and keep it (snapget always did; push now matches).
zfs snapshot "$PBK/xs@manual"
zfs snapshot "$PLP/xg@manual"
zfs snapshot "$POOL/px@auto_2"
run_send_out -t -e -m "auto_" "$POOL/px" "$PBK/xs"; RC_S=$RC
run_get_out  -t -e -m "auto_" "$POOL/px" "$PLP/xg"; RC_G=$RC
check "P -t empty snapshot: both receive" "0 0" "$RC_S $RC_G"
check "P -t empty snapshot: push kept it" "auto_1 manual auto_2" "$(snaps_of "$PBK/xs")"
check "P -t empty snapshot: pull kept it" "auto_1 manual auto_2" "$(snaps_of "$PLP/xg")"
# P9: a WRITE on the exact path -- refused by both, the copy left as it was.
for _c in "$PBK/xs" "$PLP/xg"; do write_into_copy "$_c"; done
zfs snapshot "$POOL/px@auto_3"
run_send_out -t -e -m "auto_" "$POOL/px" "$PBK/xs"; RC_S=$RC; OUT_S="$OUT"
run_get_out  -t -e -m "auto_" "$POOL/px" "$PLP/xg"; RC_G=$RC; OUT_G="$OUT"
check "P -t write: both refuse" "1 1" "$RC_S $RC_G"
check "P -t write: push left the copy alone" "auto_1 manual auto_2" "$(snaps_of "$PBK/xs")"
check "P -t write: pull left the copy alone" "auto_1 manual auto_2" "$(snaps_of "$PLP/xg")"
check "P -t write: push says it is not a backup landing" "yes" "$(said_s 'is not a backup landing')"

# --- REV-20261104-186 F1/F4/F5/F6 ---------------------------------------------
# F1: the protected-snapshot listing before a force-full destroy is fail-closed.
# F4: the -F collision scan maps a nested target child by its FULL relative path.
# F5: a failed remote `zfs list` is not an empty list. F6: -m is a literal prefix.
# The shim style is test/delsnaps/run.sh's: a fake zfs first on PATH breaks ONE call,
# records every destroy, and execs the real zfs for the rest.
R186D="$(mktemp -d)"; mkdir -p "$R186D/bin" "$R186D/f5bin"
export R186_LOG="$R186D/destroys" R186_REAL="$(command -v zfs)"
cat > "$R186D/bin/zfs" <<'SHIM'
#!/bin/bash
if [ "$1" = destroy ]; then echo "destroy $*" >> "$R186_LOG"; fi
if [ -n "${F1_TGT:-}" ] && [ "$1 $2 $3 $4 $5 $6 $7" = "list -t snapshot -H -o name -r" ] \
   && [ "${!#}" = "$F1_TGT" ]; then
    echo "cannot iterate '$F1_TGT': simulated I/O error" >&2; exit 1
fi
# F1P_TGT: the EXISTENCE check of the target says "permission denied" (not "does not
# exist"), and the protected listing fails too (main masked that one with `|| true`).
if [ -n "${F1P_TGT:-}" ]; then
    if [ "$*" = "list -H -o name -- $F1P_TGT" ]; then
        echo "cannot open '$F1P_TGT': permission denied" >&2; exit 1
    fi
    if [ "$1 $2 $3 $4 $5 $6 $7" = "list -t snapshot -H -o name -r" ] && [ "${!#}" = "$F1P_TGT" ]; then
        echo "cannot open '$F1P_TGT': permission denied" >&2; exit 1
    fi
fi
# F1M_TGT: the protected listing succeeds but carries a line that is not a snapshot.
if [ -n "${F1M_TGT:-}" ] && [ "$1 $2 $3 $4 $5 $6 $7" = "list -t snapshot -H -o name -r" ] \
   && [ "${!#}" = "$F1M_TGT" ]; then
    "$R186_REAL" list -t snapshot -H -o name -d 1 -- "$F1M_TGT" | head -n 1
    echo "garbage-without-at"; exit 0
fi
# F4P_SRC: the existence check of ONE source child says "permission denied".
if [ -n "${F4P_SRC:-}" ] && [ "$*" = "list -H -o name -- $F4P_SRC" ]; then
    echo "cannot open '$F4P_SRC': permission denied" >&2; exit 1
fi
exec "$R186_REAL" "$@"
SHIM
chmod +x "$R186D/bin/zfs"

# The same argv through either engine; local mode, so both do identical work.
r186_run() {   # <send|get> <name> <engine args...> -> RC, OUT
    local eng="$1" name="$2"; shift 2
    if [ "$eng" = send ]; then run_send_out "$@" "$POOL/$name" "$BK"
    else run_get_out "$@" "$SRCBASE/$POOL/$name" "$LOCALPULL"; fi
}
r186_src() { if [ "$1" = send ]; then echo "$POOL/$2"; else echo "$SRCBASE/$POOL/$2"; fi; }
r186_tgt() { if [ "$1" = send ]; then echo "$BK/$POOL/$2"; else echo "$PULLED/$POOL/$2"; fi; }
r186_shim() {  # r186_run through the shim; F1_TGT (exported by the caller) names the call to break
    local p0="$PATH"; PATH="$R186D/bin:$PATH"; r186_run "$@"; PATH="$p0"
}
r186_said() { printf '%s\n' "$OUT" | grep -c -- "$1"; }

for eng in send get; do
    # F1a: the listing of the target's snapshots fails -> refuse BEFORE any destroy.
    # Old engines read the failure as "nothing reserved" and destroyed the target.
    zfs create -p "$(r186_src $eng f1a$eng)" || exit 1
    zfs snapshot "$(r186_src $eng f1a$eng)@auto_1"
    r186_run $eng f1a$eng -e -m "auto_"
    F1T="$(r186_tgt $eng f1a$eng)"
    tick; zfs snapshot "$(r186_src $eng f1a$eng)@auto_2"
    : > "$R186_LOG"; export F1_TGT="$F1T"
    r186_shim $eng f1a$eng -f -e -m "auto_"
    unset F1_TGT
    check "F1 $eng: listing fails -> rc != 0" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "F1 $eng: listing fails -> no destroy was issued" "0" "$(grep -c . "$R186_LOG")"
    check "F1 $eng: listing fails -> the target's snapshots are unchanged" "auto_1" "$(snaps_of "$F1T")"
    check "F1 $eng: listing fails -> the refusal is named" "yes" \
          "$([ "$(r186_said 'Refusing the destructive full transfer')" -ge 1 ] && echo yes || echo no)"

    # F1b: positive control through the SAME shim, nothing broken -> -f proceeds.
    zfs create -p "$(r186_src $eng f1b$eng)" || exit 1
    zfs snapshot "$(r186_src $eng f1b$eng)@auto_1"
    r186_run $eng f1b$eng -e -m "auto_"
    tick; zfs snapshot "$(r186_src $eng f1b$eng)@auto_2"
    : > "$R186_LOG"
    r186_shim $eng f1b$eng -f -e -m "auto_"
    check "F1 $eng control: shim, nothing broken -> -f rc 0, target rebuilt" "0|auto_2" \
          "$RC|$(snaps_of "$(r186_tgt $eng f1b$eng)")"
    check "F1 $eng control: the shim does see the destroy" "yes" \
          "$([ "$(grep -c . "$R186_LOG")" -ge 1 ] && echo yes || echo no)"

    # F1c: the existence check of the target is "permission denied" -> UNKNOWN, refuse.
    # The protected listing is failed too, so main (which masked it with `|| true`) destroys.
    zfs create -p "$(r186_src $eng f1c$eng)" || exit 1
    zfs snapshot "$(r186_src $eng f1c$eng)@auto_1"
    r186_run $eng f1c$eng -e -m "auto_"
    F1T="$(r186_tgt $eng f1c$eng)"
    tick; zfs snapshot "$(r186_src $eng f1c$eng)@auto_2"
    : > "$R186_LOG"; export F1P_TGT="$F1T"
    r186_shim $eng f1c$eng -f -e -m "auto_"
    unset F1P_TGT
    check "F1 $eng probe: existence check denied -> rc != 0" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "F1 $eng probe: existence check denied -> no destroy was issued" "0" "$(grep -c . "$R186_LOG")"
    check "F1 $eng probe: existence check denied -> the target's snapshots are unchanged" "auto_1" "$(snaps_of "$F1T")"
    check "F1 $eng probe: existence check denied -> the refusal is named" "yes" \
          "$([ "$(r186_said 'Refusing the destructive full transfer')" -ge 1 ] && echo yes || echo no)"
done

# F1d (send only): the protected listing is rc 0 but holds a line that is not a snapshot
# of the target -> the answer cannot be trusted, refuse. Main grepped it and destroyed.
zfs create -p "$POOL/f1dsend" || exit 1
zfs snapshot "$POOL/f1dsend@auto_1"
r186_run send f1dsend -e -m "auto_"
F1T="$(r186_tgt send f1dsend)"
tick; zfs snapshot "$POOL/f1dsend@auto_2"
: > "$R186_LOG"; export F1M_TGT="$F1T"
r186_shim send f1dsend -f -e -m "auto_"
unset F1M_TGT
check "F1 send malformed: rc != 0" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "F1 send malformed: no destroy was issued" "0" "$(grep -c . "$R186_LOG")"
check "F1 send malformed: the target's snapshots are unchanged" "auto_1" "$(snaps_of "$F1T")"
check "F1 send malformed: the refusal is named" "yes" \
      "$([ "$(r186_said 'Refusing the destructive full transfer')" -ge 1 ] && echo yes || echo no)"

# F4: nested root/a/b with a common snapshot. -F only acts together with -r (atomic
# recursion), so -r -F is used here. The old scan compared tgt/a/b with src/b (the
# basename hung under the root), saw "no such snapshot" and upgraded to a full resend.
for eng in send get; do
    S="$(r186_src $eng f4$eng)"; zfs create -p "$S/a/b" || exit 1
    zfs snapshot -r "$S@base"
    r186_run $eng f4$eng -r -e -m "base"
    T4="$(r186_tgt $eng f4$eng)"
    check "F4 $eng setup: initial -r transfer replicated the depth-2 child" "base" "$(snaps_of "$T4/a/b")"
    tick; zfs snapshot -r "$S@auto_2"
    r186_run $eng f4$eng -r -F -v 3 -e -m "auto_"
    check "F4 $eng: equal GUIDs at depth 2 -> rc 0" "0" "$RC"
    check "F4 $eng: equal GUIDs at depth 2 -> NOT upgraded to a full" "0" "$(r186_said 'Upgrading this run to a full')"
    check "F4 $eng: the incremental reached the depth-2 child" "base auto_2" "$(snaps_of "$T4/a/b")"

    # F4b control: a different @base on the target child -> a genuine mismatch is still found.
    S="$(r186_src $eng f4x$eng)"; zfs create -p "$S/a/b" || exit 1
    zfs snapshot -r "$S@base"
    r186_run $eng f4x$eng -r -e -m "base"
    T4="$(r186_tgt $eng f4x$eng)"
    zfs destroy "$T4/a/b@base" && zfs snapshot "$T4/a/b@base"
    tick; zfs snapshot -r "$S@auto_2"
    r186_run $eng f4x$eng -r -F -v 3 -e -m "auto_"
    check "F4 $eng control: a different @base on the target child -> upgraded to a full" "1" \
          "$(r186_said 'Upgrading this run to a full')"

    # F4c: two different parents, the same leaf name (root/a/x, root/b/x). The old basename
    # mapping compared both target leaves with root/x, so equal GUIDs looked like a collision.
    S="$(r186_src $eng f4d$eng)"; zfs create -p "$S/a/x" || exit 1; zfs create -p "$S/b/x" || exit 1
    zfs snapshot -r "$S@base"
    r186_run $eng f4d$eng -r -e -m "base"
    T4="$(r186_tgt $eng f4d$eng)"
    tick; zfs snapshot -r "$S@auto_2"
    r186_run $eng f4d$eng -r -F -v 3 -e -m "auto_"
    check "F4 $eng dup leaf: root/a/x + root/b/x with equal GUIDs -> rc 0" "0" "$RC"
    check "F4 $eng dup leaf: NOT upgraded to a full" "0" "$(r186_said 'Upgrading this run to a full')"
    check "F4 $eng dup leaf: the incremental reached both leaves" "base auto_2|base auto_2" \
          "$(snaps_of "$T4/a/x")|$(snaps_of "$T4/b/x")"
done

# F4d (send only): the existence check of a SOURCE child is "permission denied" -> the scan
# cannot complete, so it must NOT upgrade to a destroying full (main: basename bug upgraded).
S="$(r186_src send f4psend)"; zfs create -p "$S/a/b" || exit 1
zfs snapshot -r "$S@base"
r186_run send f4psend -r -e -m "base"
tick; zfs snapshot -r "$S@auto_2"
export F4P_SRC="$S/a/b"
r186_shim send f4psend -r -F -v 3 -e -m "auto_"
unset F4P_SRC
check "F4 send probe unknown: NOT upgraded to a full" "0" "$(r186_said 'Upgrading this run to a full')"
check "F4 send probe unknown: the scan says it could not complete" "yes" \
      "$([ "$(r186_said 'could not complete -- NOT upgrading')" -ge 1 ] && echo yes || echo no)"

# F5: get_sorted_snapshots lifted from each engine (+ probe_dataset and dataset_presence from the lib) and
# run with a fake ssh that executes its command locally, so the "remote" is this pool.
# The fake zfs fails `list -t snapshot` for ONE named dataset (F5_BAD).
cat > "$R186D/f5bin/ssh" <<'SHIM'
#!/bin/bash
# F5_SSH255: a dead transport -- exit 255 without running anything.
if [ -n "${F5_SSH255:-}" ]; then echo "ssh: connect to host somehost port 22: Connection refused" >&2; exit 255; fi
exec bash -c "${!#}"
SHIM
cat > "$R186D/f5bin/zfs" <<'SHIM'
#!/bin/bash
if [ "$1" = list ] && [ -n "${F5_BAD:-}" ] && [ "${!#}" = "$F5_BAD" ] \
   && printf '%s ' "$@" | grep -q -- ' -t snapshot '; then
    echo "cannot open '$F5_BAD': simulated failure" >&2; exit "${F5_RC:-1}"
fi
exec "$R186_REAL" "$@"
SHIM
chmod +x "$R186D/f5bin/ssh" "$R186D/f5bin/zfs"
r186_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }   # the suite-local twin of harness product_fn
zfs create -p "$POOL/f5ok" || exit 1
zfs create -p "$POOL/f5bad" || exit 1
zfs snapshot "$POOL/f5ok@auto_1"; zfs snapshot "$POOL/f5bad@auto_1"
tick; zfs snapshot "$POOL/f5ok@auto_2"
for engfile in "$SNAPSEND" "$SNAPGET"; do
    en="$(basename "$engfile" .sh)"
    { r186_fn "$engfile" get_sorted_snapshots; r186_fn "$REPO/lib-zfs-snap.sh" probe_dataset; r186_fn "$REPO/lib-zfs-snap.sh" dataset_presence; } > "$R186D/fn-$en.sh"
    [ -s "$R186D/fn-$en.sh" ] || { echo "cannot lift get_sorted_snapshots/probe_dataset for $en" >&2; exit 1; }
    f5() {   # <dataset> <bad-dataset-or-empty> -> "rc|names"
        local o r
        o=$( . "$R186D/fn-$en.sh"
             log() { echo "LOG $*" >&2; }
             remote_refused_by_gate() { return 1; }
             SSH_OPTS=(); RECURSIVE=0
             export F5_BAD="$2" PATH="$R186D/f5bin:$PATH"
             get_sorted_snapshots "$1" someuser somehost 2>/dev/null )
        r=$?
        printf '%s|%s' "$r" "$(printf '%s' "$o" | tr '\n' ' ' | sed 's/ $//')"
    }
    check "F5 $en: remote zfs list fails on an EXISTING dataset -> rc 1, no list" "1|" "$(f5 "$POOL/f5bad" "$POOL/f5bad")"
    # Exit 77 (neither "absent" nor transport) on an existing dataset, and a dead ssh (255).
    check "F5 $en: remote zfs list exits 77 on an EXISTING dataset -> rc 1, no list" "1|" \
          "$(F5_RC=77 f5 "$POOL/f5bad" "$POOL/f5bad")"
    check "F5 $en: ssh transport failure (255) -> rc 1, no list" "1|" \
          "$(F5_SSH255=1 f5 "$POOL/f5ok" "")"
    check "F5 $en: dataset that does not exist -> rc 0, empty list" "0|" "$(f5 "$POOL/f5nope" "")"
    check "F5 $en: two snapshots -> rc 0, oldest first" "0|auto_1 auto_2" "$(f5 "$POOL/f5ok" "")"
done

# F6: -m is a literal prefix. `.` used to match any character, so the newer
# dailyX2026_b was picked over daily.2026_a (it is also the newest regex match).
for eng in send get; do
    S="$(r186_src $eng f6$eng)"; zfs create -p "$S" || exit 1
    zfs snapshot "$S@daily.2026_a"
    tick; zfs snapshot "$S@dailyX2026_b"
    r186_run $eng f6$eng -e -m "daily.2026"
    check "F6 $eng: -m daily.2026 takes daily.2026_a, never the newer dailyX2026_b" "0|daily.2026_a" \
          "$RC|$(snaps_of "$(r186_tgt $eng f6$eng)")"

    # ZFS snapshot names allow only alphanumerics and -_.: (and a space), so a
    # bracket name is normally refused at creation; try it, and skip if it is.
    S="$(r186_src $eng f6m$eng)"; zfs create -p "$S" || exit 1
    if zfs snapshot "$S@d[a]ily_1" 2>/dev/null; then
        tick; zfs snapshot "$S@daily_2"
        r186_run $eng f6m$eng -e -m "d[a]ily"
        check "F6 $eng: -m 'd[a]ily' selects the literal d[a]ily_1, not daily_2" "0|d[a]ily_1" \
              "$RC|$(snaps_of "$(r186_tgt $eng f6m$eng)")"
    else
        echo "SKIP F6 $eng bracket case: this ZFS refuses [ ] in snapshot names"
    fi

    # F6 measurement: which of these characters does ZFS accept in a snapshot name? For each
    # accepted regex metachar a newer decoy the char-as-regex would match sits beside it
    # (X for '.', plain dx_2 for the rest); only the literal d<ch>x_1 may reach the target.
    f6i=0
    for ch in '.' '+' '*' '?' '^' '$' '\' '[' ']' '(' ')' '|' '{' '}' ':' '%' '-'; do
        f6i=$((f6i + 1)); S="$(r186_src $eng f6c$f6i$eng)"; zfs create -p "$S" || exit 1
        if ! zfs snapshot "$S@d${ch}x_1" 2>/dev/null; then
            echo "SKIP F6 '$ch': zfs rejects it in snapshot names"
            continue
        fi
        case "$ch" in
            '.') decoy="dXx_2" ;;
            ':'|'%'|'-') decoy="" ;;
            *) decoy="dx_2" ;;
        esac
        if [ -n "$decoy" ]; then tick; zfs snapshot "$S@$decoy"; fi
        r186_run $eng f6c$f6i$eng -e -m "d${ch}x"
        check "F6 $eng: -m 'd${ch}x' sends only the literal d${ch}x_1" "0|d${ch}x_1" \
              "$RC|$(snaps_of "$(r186_tgt $eng f6c$f6i$eng)")"
    done
done

# F5, round 3 (REV-186 verification of 92c81fcf): the -n CALLER, through the real engine.
# A pair with a common snapshot; one discovery step is broken at a time: the local filter
# (an awk that fails only on get_sorted_snapshots' program), the target listing in
# find_common_snapshot (1st call) or in the conflict scan (2nd call), the source listing in
# the conflict scan, the target's existence check ("permission denied" is not "absent").
# Each must end rc 2 with INCOMPLETE on stderr, the diagnostic, no PLAN= line, no conflict
# list, no destroy, the target untouched. Old engines answered rc 0/1 with
# an empty or partial picture. Controls: the healthy pair (rc 0, PLAN=INCREMENTAL) and a
# real conflict (rc 1, the extra snapshot listed).
mkdir -p "$R186D/f5cbin"
export R186D_C="$R186D/f5c.count" R186_AWK="$(command -v awk)"
cat > "$R186D/f5cbin/zfs" <<'SHIM'
#!/bin/bash
if [ -n "${F5C_DS:-}" ] && [ "$1" = list ] && [ "${!#}" = "$F5C_DS" ] \
   && [[ " $* " == *" -t snapshot "* ]] && [[ " $* " == *" -s creation "* ]]; then
    n=$(( $(cat "$R186D_C" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$R186D_C"
    if [ "$n" -gt "${F5C_SKIP:-0}" ]; then echo "cannot iterate '$F5C_DS': simulated I/O error" >&2; exit 1; fi
fi
# F5C_EX: the existence check of one dataset says "permission denied", not "does not exist".
if [ -n "${F5C_EX:-}" ] && { [ "$*" = "list -H -o name -- $F5C_EX" ] || [ "$*" = "list -H $F5C_EX" ]; }; then
    echo "cannot open '$F5C_EX': permission denied" >&2; exit 1
fi
if [ "$1" = destroy ]; then echo "destroy $*" >> "$R186_LOG"; fi
if [ "$1" = send ] && [ -n "${F5C_SENDLOG:-}" ]; then echo "send $*" >> "$F5C_SENDLOG"; fi
exec "$R186_REAL" "$@"
SHIM
cat > "$R186D/f5cbin/awk" <<'SHIM'
#!/bin/bash
if [ -n "${F5C_AWK:-}" ] && [ "$1" = -F ] && [ "$2" = @ ] && [ "$3" = 'NF > 1 {print $2}' ]; then
    exit 2
fi
exec "$R186_AWK" "$@"
SHIM
chmod +x "$R186D/f5cbin/zfs" "$R186D/f5cbin/awk"
f5c_run() {   # <send|get> <name> [engine args] -> RC, OUT of `-n -m auto_` through the f5c shims
    local p0="$PATH"; PATH="$R186D/f5cbin:$PATH"; rm -f "$R186D_C"
    r186_run "$1" "$2" "${@:3}" -n -m "auto_"; PATH="$p0"
}
f5c_plans() { printf '%s\n' "$OUT" | grep -c '^PLAN='; }
for eng in send get; do
    S="$(r186_src $eng f5c$eng)"; T="$(r186_tgt $eng f5c$eng)"
    zfs create -p "$S" || exit 1; zfs snapshot "$S@auto_1"
    r186_run $eng f5c$eng -e -m "auto_"
    check "F5c $eng: setup -- the pair has its common snapshot" "0|auto_1" "$RC|$(snaps_of "$T")"

    f5c_run $eng f5c$eng
    check "F5c $eng: control -- a healthy pair, -n rc 0 and one PLAN=INCREMENTAL" "0|1" \
          "$RC|$(printf '%s\n' "$OUT" | grep -c '^PLAN=INCREMENTAL base=auto_1 ')"
    zfs snapshot "$T@extra_1"
    f5c_run $eng f5c$eng
    check "F5c $eng: control -- a real conflict, -n rc 1 and the extra snapshot listed" "1|1" \
          "$RC|$(printf '%s\n' "$OUT" | grep -c "^$T@extra_1\$")"
    zfs destroy "$T@extra_1"

    for f5c in "filter|F5C_AWK=1|Could not filter the snapshot list" \
               "target listing in find_common_snapshot|F5C_DS=$T F5C_SKIP=0|Could not list the snapshots of '$T'" \
               "target listing in the conflict scan|F5C_DS=$T F5C_SKIP=1|Could not list the snapshots of '$T'" \
               "source listing in the conflict scan|F5C_DS=$S F5C_SKIP=1|Could not list the snapshots of '$S'" \
               "target existence check (permission denied)|F5C_EX=$T|Could not establish whether '$T'"; do
        what="${f5c%%|*}"; rest="${f5c#*|}"; envs="${rest%%|*}"; diag="${rest#*|}"
        d0=$(cat "$R186_LOG" 2>/dev/null | wc -l)
        # shellcheck disable=SC2086
        eval "export $envs"; f5c_run $eng f5c$eng; unset F5C_AWK F5C_DS F5C_SKIP F5C_EX
        d1=$(cat "$R186_LOG" 2>/dev/null | wc -l)
        calls=$(cat "$R186D_C" 2>/dev/null || echo 0)
        want_calls=0; case "$envs" in *SKIP=0*) want_calls=1 ;; *SKIP=1*) want_calls=2 ;; esac
        check "F5c $eng: $what fails -> rc 2, INCOMPLETE, the diagnostic, no PLAN=, no conflict list, no destroy, target as before" \
              "2|1|1|0|0|$want_calls|0|auto_1" \
              "$RC|$(printf '%s\n' "$OUT" | grep -c "^INCOMPLETE: ")|$([ "$(r186_said "$diag")" -gt 0 ] && echo 1 || echo 0)|$(f5c_plans)|$(printf '%s\n' "$OUT" | grep -c "^$T@")|$calls|$((d1 - d0))|$(snaps_of "$T")"
    done

    # The REAL run, the same unanswerable target: no base and no first copy -- no zfs send at
    # all, the diagnostic, rc != 0 (round 3 before this fix sent `-I <src>@` with an empty base).
    zfs snapshot "$S@auto_2"; : > "$R186D/f5c.sends"
    export F5C_EX="$T" F5C_SENDLOG="$R186D/f5c.sends"; p0="$PATH"; PATH="$R186D/f5cbin:$PATH"
    r186_run $eng f5c$eng -e -m "auto_"; PATH="$p0"; unset F5C_EX F5C_SENDLOG
    check "F5c $eng: real run, target existence check (permission denied) -> rc != 0, the diagnostic, no zfs send, target as before" \
          "1|1|0|auto_1" \
          "$([ "$RC" -ne 0 ] && echo 1 || echo 0)|$([ "$(r186_said "could not be compared")" -gt 0 ] && echo 1 || echo 0)|$(wc -l < "$R186D/f5c.sends")|$(snaps_of "$T")"
    zfs destroy "$S@auto_2"

    # -r: the parent's real conflict is found, then the child's listing fails. The failed
    # dataset prints NO conflict line (round 3 printed the parent's half of the list).
    S="$(r186_src $eng f5r$eng)"; T="$(r186_tgt $eng f5r$eng)"
    zfs create -p "$S/c" || exit 1; zfs snapshot -r "$S@auto_1"
    r186_run $eng f5r$eng -r -e -m "auto_"
    zfs snapshot "$T@extra_1"
    f5c_run $eng f5r$eng -r
    check "F5c $eng: control -r -- the parent's conflict is listed, rc 1" "1|1" \
          "$RC|$(printf '%s\n' "$OUT" | grep -c "^$T@extra_1\$")"
    export F5C_DS="$S/c" F5C_SKIP=0; f5c_run $eng f5r$eng -r; unset F5C_DS F5C_SKIP
    check "F5c $eng: -r, the child's listing fails after the parent's conflict -> rc 2, INCOMPLETE, no conflict line" \
          "2|1|0|auto_1 extra_1" \
          "$RC|$(printf '%s\n' "$OUT" | grep -c "^INCOMPLETE: ")|$(printf '%s\n' "$OUT" | grep -c "^$T")|$(snaps_of "$T")"
done

# F5, round 4 (REV-186 verification of a3cb5309): the GUID fallback of find_common_snapshot.
# get_snapshot_guids used to pipe `zfs list -o name,guid` (local or over ssh) into awk and
# return awk's status, so a failed listing was an EMPTY list and the fallback answered
# "null" (no common base). (1) The helper lifted from the lib, remote through the fake ssh of
# F5 above: a failed remote listing (rc 1 and 77), a dead transport (255) and a failed
# filter are rc 1 with no rows; a dataset with no snapshots and a healthy one are rc 0.
# (2) Through the real engines: the target's copy of the common snapshot is RENAMED, so the
# name scan finds nothing and only the GUID fallback finds the base. The GUID listing of the
# target, then of the source, then the GUID filter fails: -n ends rc 2, INCOMPLETE, the
# diagnostic, no PLAN=, no destroy; the real run sends nothing. Controls: the healthy -n
# plans INCREMENTAL from the GUID-found base, and the healthy real run sends it.
mkdir -p "$R186D/f5gbin"
cat > "$R186D/f5gbin/zfs" <<'SHIM'
#!/bin/bash
if [ -n "${F5G_DS:-}" ] && [ "$1" = list ] && [ "${!#}" = "$F5G_DS" ] && [[ " $* " == *" -o name,guid "* ]]; then
    echo "cannot iterate '$F5G_DS': simulated I/O error" >&2; exit "${F5G_RC:-1}"
fi
if [ "$1" = destroy ]; then echo "destroy $*" >> "$R186_LOG"; fi
if [ "$1" = send ] && [ -n "${F5G_SENDLOG:-}" ]; then echo "send $*" >> "$F5G_SENDLOG"; fi
exec "$R186_REAL" "$@"
SHIM
cat > "$R186D/f5gbin/awk" <<'SHIM'
#!/bin/bash
# The helper calls `awk -F'\t' '<program>'`: -F and its value are ONE word, the program the second.
if [ -n "${F5G_AWK:-}" ] && [ "$2" = '{split($1,a,"@"); print a[2]"\t"$2}' ]; then exit 2; fi
exec "$R186_AWK" "$@"
SHIM
chmod +x "$R186D/f5gbin/zfs" "$R186D/f5gbin/awk"
cp "$R186D/f5gbin/awk" "$R186D/f5bin/awk"
r186_fn "$REPO/lib-zfs-snap.sh" get_snapshot_guids > "$R186D/fn-guids.sh"
[ -s "$R186D/fn-guids.sh" ] || { echo "cannot lift get_snapshot_guids" >&2; exit 1; }
zfs create -p "$POOL/f5gempty" || exit 1
f5g() {   # <dataset> <bad-dataset-or-empty> -> "rc|rows" (remote, through the fake ssh)
    local o r
    o=$( . "$R186D/fn-guids.sh"
         log() { echo "LOG $*" >&2; }
         SSH_OPTS=(); RECURSIVE=0
         export F5_BAD="$2" PATH="$R186D/f5bin:$PATH"
         get_snapshot_guids "$1" someuser somehost 2>/dev/null )
    r=$?
    printf '%s|%s' "$r" "$(printf '%s' "$o" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
}
check "F5g lib: remote GUID listing fails on an EXISTING dataset -> rc 1, no rows" "1|" "$(f5g "$POOL/f5bad" "$POOL/f5bad")"
check "F5g lib: remote GUID listing exits 77 -> rc 1, no rows" "1|" "$(F5_RC=77 f5g "$POOL/f5bad" "$POOL/f5bad")"
check "F5g lib: ssh transport failure (255) -> rc 1, no rows" "1|" "$(F5_SSH255=1 f5g "$POOL/f5ok" "")"
check "F5g lib: the GUID filter fails -> rc 1, no rows" "1|" "$(F5G_AWK=1 f5g "$POOL/f5ok" "")"
check "F5g lib: control -- a dataset with no snapshots -> rc 0, no rows" "0|" "$(f5g "$POOL/f5gempty" "")"
check "F5g lib: control -- two snapshots -> rc 0, oldest first" "0|auto_1 auto_2" "$(f5g "$POOL/f5ok" "")"
f5g_run() {   # <send|get> <name> [engine args] -> RC, OUT through the f5g shims
    local p0="$PATH"; PATH="$R186D/f5gbin:$PATH"; r186_run "$@"; PATH="$p0"
}
for eng in send get; do
    S="$(r186_src $eng f5g$eng)"; T="$(r186_tgt $eng f5g$eng)"
    zfs create -p "$S" || exit 1; zfs snapshot "$S@auto_1"
    r186_run $eng f5g$eng -e -m "auto_"
    zfs rename "$T@auto_1" "$T@moved_1"
    tick; zfs snapshot "$S@auto_2"
    check "F5g $eng: setup -- the target's copy of the base is renamed" "0|moved_1" "$RC|$(snaps_of "$T")"
    f5g_run $eng f5g$eng -n -m "auto_"
    # Measured: the name-based conflict scan lists the renamed moved_1 (rc 1) -- unchanged
    # behaviour; the base itself comes from the GUID fallback.
    check "F5g $eng: control -- -n finds the base by GUID: PLAN=INCREMENTAL base=auto_1, rc 1 with moved_1 listed" "1|1|1" \
          "$RC|$(printf '%s\n' "$OUT" | grep -c '^PLAN=INCREMENTAL base=auto_1 ')|$(printf '%s\n' "$OUT" | grep -c "^$T@moved_1\$")"
    for f5g in "target GUID listing|F5G_DS=$T|Could not list the snapshot GUIDs of '$T'" \
               "source GUID listing|F5G_DS=$S|Could not list the snapshot GUIDs of '$S'" \
               "GUID filter|F5G_AWK=1|Could not filter the snapshot GUID list"; do
        what="${f5g%%|*}"; rest="${f5g#*|}"; envs="${rest%%|*}"; diag="${rest#*|}"
        d0=$(cat "$R186_LOG" 2>/dev/null | wc -l)
        # shellcheck disable=SC2086
        eval "export $envs"; f5g_run $eng f5g$eng -n -m "auto_"; unset F5G_DS F5G_AWK
        d1=$(cat "$R186_LOG" 2>/dev/null | wc -l)
        check "F5g $eng -n: $what fails -> rc 2, INCOMPLETE, the diagnostic, no PLAN=, no destroy, target as before" \
              "2|1|1|0|0|moved_1" \
              "$RC|$(printf '%s\n' "$OUT" | grep -c "^INCOMPLETE: ")|$([ "$(r186_said "$diag")" -gt 0 ] && echo 1 || echo 0)|$(printf '%s\n' "$OUT" | grep -c '^PLAN=')|$((d1 - d0))|$(snaps_of "$T")"
        : > "$R186D/f5g.sends"
        eval "export $envs"; export F5G_SENDLOG="$R186D/f5g.sends"
        f5g_run $eng f5g$eng -e -m "auto_"; unset F5G_DS F5G_AWK F5G_SENDLOG
        check "F5g $eng real run: $what fails -> rc != 0, the diagnostic, no zfs send, target as before" \
              "1|1|0|moved_1" \
              "$([ "$RC" -ne 0 ] && echo 1 || echo 0)|$([ "$(r186_said "$diag")" -gt 0 ] && echo 1 || echo 0)|$(wc -l < "$R186D/f5g.sends")|$(snaps_of "$T")"
    done
    f5g_run $eng f5g$eng -e -m "auto_"
    check "F5g $eng: control -- the healthy real run sends auto_2 on the GUID-found base" "0|moved_1 auto_2" "$RC|$(snaps_of "$T")"
done
rm -rf "$R186D"
unset R186_LOG R186_REAL

# --- summary ----------------------------------------------------------------

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
