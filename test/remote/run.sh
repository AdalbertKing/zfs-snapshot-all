#!/bin/bash
# Two-host campaign: everything the single-host suites structurally cannot reach.
#
# test/snapsend/run.sh is local-mode only, by design -- validate_remote_host()
# refuses a loopback "replication" to the same machine, so ssh has never had a
# repeatable test at all. This is that test. It is still a MANUAL obligation in
# test/deps.conf (it needs a second real host), but running it is now one
# command instead of a remembered ritual.
#
# Usage, FROM the source host:
#   ./test/remote/run.sh --peer root@192.168.28.8
#   ./test/remote/run.sh --peer zfsbackup@192.168.28.8 \
#       --local-parent hdd/backuptest --peer-parent hdd/backuptest_targets
#
#   --peer          user@host of the OTHER machine (required)
#   --local-parent  where to build scratch here      (default rpool)
#   --peer-parent   where to build scratch there     (default hdd/backuptest_targets)
#
# SAFETY: every dataset this creates lives under <parent>/xcamp<PID>, refuses to
# start if that already exists, and is destroyed by an EXIT trap on both hosts
# even if a case fails partway. It never touches anything else. Run it against
# a scratch parent, never a production path.
#
# Data integrity is checked by comparing the snapshot GUID on both sides rather
# than by mounting and hashing: a GUID match proves the exact stream landed, and
# it is the only check that also works for the delegated account, which cannot
# mount anything. When this runs as root and the source mounted, one md5 is
# compared as well, as an anchor for the GUID argument itself.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
DELSNAPS="${DELSNAPS:-$REPO/delsnaps.sh}"

PEER=""
LPARENT="rpool"
RPARENT="hdd/backuptest_targets"

while [ $# -gt 0 ]; do
    case "$1" in
        --peer)         shift; PEER="${1:-}" ;;
        --local-parent) shift; LPARENT="${1:-}" ;;
        --peer-parent)  shift; RPARENT="${1:-}" ;;
        -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

[ -n "$PEER" ] || { echo "--peer user@host is required" >&2; exit 1; }
[ -x "$SNAPSEND" ] || { echo "cannot find executable snapsend.sh at $SNAPSEND" >&2; exit 1; }
[ -x "$SNAPGET" ]  || { echo "cannot find executable snapget.sh at $SNAPGET" >&2; exit 1; }
[ -x "$DELSNAPS" ] || { echo "cannot find executable delsnaps.sh at $DELSNAPS" >&2; exit 1; }
command -v zfs     >/dev/null || { echo "zfs not found" >&2; exit 1; }
command -v mbuffer >/dev/null || { echo "mbuffer not found -- snapsend refuses to run without it" >&2; exit 1; }

SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH "$PEER" true 2>/dev/null || { echo "cannot ssh to $PEER non-interactively" >&2; exit 1; }

TAG="xcamp$$"
LROOT="$LPARENT/$TAG"
RROOT="$RPARENT/$TAG"

zfs list -H "$LROOT"          >/dev/null 2>&1 && { echo "refusing to run: $LROOT exists here" >&2; exit 1; }
$SSH "$PEER" "zfs list -H '$RROOT'" >/dev/null 2>&1 && { echo "refusing to run: $RROOT exists on $PEER" >&2; exit 1; }
# Sync mode (section G) lands at the IDENTICAL path on the peer, not under
# $RROOT, so that name has to be free there too.
$SSH "$PEER" "zfs list -H '$LROOT'" >/dev/null 2>&1 && { echo "refusing to run: $LROOT exists on $PEER (sync mode needs it free)" >&2; exit 1; }

# Keep this run's bookkeeping out of the host's real logs and lock dir.
TMPD="$(mktemp -d)"
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

cleanup() {
    # Release first: a case that fails before its transfer leaves a held
    # snapshot, and `zfs destroy` would then report only "dataset is busy".
    local s
    for s in $(zfs list -H -o name -t snapshot -r "$LROOT" 2>/dev/null); do
        zfs release zfssnapall_inflight "$s" 2>/dev/null
    done
    zfs destroy -R "$LROOT" 2>/dev/null
    $SSH "$PEER" "for s in \$(zfs list -H -o name -t snapshot -r '$RROOT' 2>/dev/null); do zfs release zfssnapall_inflight \$s 2>/dev/null; done; zfs destroy -R '$RROOT' 2>/dev/null" 2>/dev/null
    # Sync mode (section G) lands at the IDENTICAL path, not under $RROOT --
    # its peer-side footprint lives under $LROOT instead, so that needs its
    # own release+destroy on the peer too.
    $SSH "$PEER" "for s in \$(zfs list -H -o name -t snapshot -r '$LROOT' 2>/dev/null); do zfs release zfssnapall_inflight \$s 2>/dev/null; done; zfs destroy -R '$LROOT' 2>/dev/null" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"; PASS=$((PASS + 1))
    else
        echo "FAIL $label"; echo "     expected: [$expected]"; echo "     actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# --- helpers ----------------------------------------------------------------

lz()  { zfs "$@" 2>/dev/null; }
rz()  { $SSH "$PEER" "zfs $*" 2>/dev/null; }

l_exists()  { zfs list -H "$1" >/dev/null 2>&1 && echo yes || echo no; }
r_exists()  { $SSH "$PEER" "zfs list -H '$1'" >/dev/null 2>&1 && echo yes || echo no; }
# Snapshots OF THIS DATASET (-d 1), not of its subtree: an excluded parent whose
# child was legitimately sent still has zero of its own, and a recursive count
# would say otherwise.
l_snaps()   { zfs list -H -o name -t snapshot -d 1 "$1" 2>/dev/null | wc -l; }
r_snaps()   { $SSH "$PEER" "zfs list -H -o name -t snapshot -d 1 '$1' 2>/dev/null | wc -l" 2>/dev/null; }
l_guid()    { zfs get -H -o value guid "$1" 2>/dev/null; }
r_guid()    { $SSH "$PEER" "zfs get -H -o value guid '$1'" 2>/dev/null; }
l_canmount(){ zfs get -H -o value canmount "$1" 2>/dev/null; }
r_canmount(){ $SSH "$PEER" "zfs get -H -o value canmount '$1'" 2>/dev/null; }

# Newest snapshot NAME (the @suffix) of a dataset.
l_newest() { zfs list -H -o name -s creation -t snapshot -d 1 "$1" 2>/dev/null | tail -1 | sed 's/.*@//'; }
r_newest() { $SSH "$PEER" "zfs list -H -o name -s creation -t snapshot -d 1 '$1' 2>/dev/null | tail -1 | sed 's/.*@//'"; }

# Build the standard shape: root + keep + swap + swap/inner. canmount=noauto
# throughout so this works unchanged for the delegated account, which cannot
# mount. Data is written only where a mountpoint is actually usable.
# Create DS and every missing level above it, each explicitly canmount=noauto.
# `zfs create -p` cannot be used here for the same reason snapsend.sh stopped
# using it: -p applies -o to the final dataset only, every level it invents gets
# canmount=on, and the delegated account then dies mounting it. The seeding of a
# test must not fail in the exact way the test exists to check.
mk_noauto() {
    local ds="$1" acc="" part
    local IFS=/
    for part in $ds; do
        acc="${acc:+$acc/}$part"
        [ "$acc" = "$part" ] && continue          # the pool itself
        zfs list -H "$acc" >/dev/null 2>&1 || zfs create -o canmount=noauto "$acc" || return 1
    done
    return 0
}

seed_local() {
    local root="$1" d mp
    for d in "" /keep /swap /swap/inner; do
        mk_noauto "$root$d" >/dev/null 2>&1 || return 1
    done
    for d in /keep /swap/inner; do
        if zfs mount "$root$d" >/dev/null 2>&1; then
            mp="$(zfs get -H -o value mountpoint "$root$d")"
            [ -d "$mp" ] && dd if=/dev/urandom of="$mp/f" bs=64k count=8 status=none 2>/dev/null
            zfs unmount "$root$d" >/dev/null 2>&1
        fi
    done
    return 0
}

seed_peer() {
    local root="$1"
    # Same level-by-level construction as mk_noauto, done remotely in one hop.
    $SSH "$PEER" "for d in '' /keep /swap /swap/inner; do
        ds='$root'\$d; acc=''
        IFS=/; for part in \$ds; do
            [ -z \"\$acc\" ] && { acc=\$part; continue; }
            acc=\$acc/\$part
            zfs list -H \"\$acc\" >/dev/null 2>&1 || zfs create -o canmount=noauto \"\$acc\" || exit 1
        done; unset IFS
    done" >/dev/null 2>&1
}

RC=0
send() { "$SNAPSEND" "$@" >"$TMPD/out" 2>&1; RC=$?; }
get()  { "$SNAPGET"  "$@" >"$TMPD/out" 2>&1; RC=$?; }
# Case-insensitive by default. It used to take flags, and `outgrep -i pattern`
# quietly searched for the string "-i" instead -- so the two cases expecting
# ZERO matches passed for the wrong reason, which is worse than failing.
outgrep() { grep -ci "$1" "$TMPD/out"; }

# snapshot names carry a per-second timestamp, so consecutive runs need spacing
tick() { sleep 1; }

echo "=== two-host campaign: $(hostname) -> $PEER"
echo "=== scratch: $LROOT (here) / $RROOT (there)"

SRC="$LROOT/src"
seed_local "$SRC" || { echo "could not seed the local source tree" >&2; exit 1; }

# ============================================================================
# A. snapsend, LOCAL target
# ============================================================================
echo "--- A. snapsend local"

send -m a1_ "$SRC" "$LROOT/a1"
check "A1 plain local: exit 0" "0" "$RC"
check "A1 plain local: target created" "yes" "$(l_exists "$LROOT/a1/$SRC")"
check "A1 plain local: exactly one snapshot" "1" "$(l_snaps "$LROOT/a1/$SRC")"
check "A1 plain local: snapshot GUID matches the source" \
      "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(l_guid "$LROOT/a1/$SRC@$(l_newest "$SRC")")"
check "A1 plain local: children NOT sent (no -r/-R)" "no" "$(l_exists "$LROOT/a1/$SRC/keep")"
check "A1 plain local: the container-parent warning fired" "1" "$(outgrep 'child dataset')"

tick
send -m a2_ -r "$SRC" "$LROOT/a2"
check "A2 -r local: exit 0" "0" "$RC"
check "A2 -r local: descendant landed" "yes" "$(l_exists "$LROOT/a2/$SRC/swap/inner")"
check "A2 -r local: leaf GUID matches" \
      "$(l_guid "$SRC/swap/inner@$(l_newest "$SRC/swap/inner")")" \
      "$(l_guid "$LROOT/a2/$SRC/swap/inner@$(l_newest "$SRC/swap/inner")")"

tick
send -m a3_ -R "$SRC" "$LROOT/a3"
check "A3 -R local: exit 0" "0" "$RC"
check "A3 -R local: every dataset landed" "4" \
      "$(zfs list -H -o name -r "$LROOT/a3" 2>/dev/null | grep -c "$SRC")"

tick
send -m a4_ -R -X 'swap$' "$SRC" "$LROOT/a4"
check "A4 -R -X local: exit 0" "0" "$RC"
check "A4 -R -X local: excluded dataset has no snapshot" "0" "$(l_snaps "$LROOT/a4/$SRC/swap")"
check "A4 -R -X local: its child still landed" "1" "$(l_snaps "$LROOT/a4/$SRC/swap/inner")"
check "A4 -R -X local: the intermediate level is canmount=noauto" "noauto" \
      "$(l_canmount "$LROOT/a4/$SRC/swap")"

tick
send -m a5_ -R -S "$SRC" "$LROOT/a5"
check "A5 -R -S local: exit 0" "0" "$RC"
check "A5 -R -S local: the parent itself was not snapshotted" "0" \
      "$(zfs list -H -o name -t snapshot -d 1 "$SRC" 2>/dev/null | grep -c 'a5_')"
check "A5 -R -S local: children were" "1" "$(l_snaps "$LROOT/a5/$SRC/keep")"

tick
send -m a6_ -z -v1 "$SRC" "$LROOT/a6"
check "A6 -z local: exit 0" "0" "$RC"
check "A6 -z local: compression is dropped, with a reason" "1" "$(outgrep 'compression ignored')"
check "A6 -z local: the transfer still lands" "1" "$(l_snaps "$LROOT/a6/$SRC")"

# ============================================================================
# B. snapsend, REMOTE target (the whole point of this file)
# ============================================================================
echo "--- B. snapsend remote (ssh)"

tick
send -m b1_ "$SRC" "$PEER:$RROOT/b1"
check "B1 plain remote: exit 0" "0" "$RC"
check "B1 plain remote: target created on the peer" "yes" "$(r_exists "$RROOT/b1/$SRC")"
check "B1 plain remote: GUID matches across the link" \
      "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$RROOT/b1/$SRC@$(l_newest "$SRC")")"
check "B1 plain remote: target created canmount=noauto" "noauto" "$(r_canmount "$RROOT/b1/$SRC")"

tick
send -m b2_ -z -v1 "$SRC" "$PEER:$RROOT/b2"
check "B2 -z remote: exit 0" "0" "$RC"
check "B2 -z remote: compression is NOT dropped over a link" "0" "$(outgrep 'compression ignored')"
check "B2 -z remote: GUID matches after a compressed transfer" \
      "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$RROOT/b2/$SRC@$(l_newest "$SRC")")"

tick
send -m b3_ -r "$SRC" "$PEER:$RROOT/b3"
check "B3 -r remote: exit 0" "0" "$RC"
check "B3 -r remote: leaf GUID matches" \
      "$(l_guid "$SRC/swap/inner@$(l_newest "$SRC/swap/inner")")" \
      "$(r_guid "$RROOT/b3/$SRC/swap/inner@$(l_newest "$SRC/swap/inner")")"

tick
send -m b4_ -R "$SRC" "$PEER:$RROOT/b4"
check "B4 -R remote: exit 0" "0" "$RC"
check "B4 -R remote: every dataset landed" "4" \
      "$($SSH "$PEER" "zfs list -H -o name -r '$RROOT/b4' 2>/dev/null" | grep -c "$SRC")"

tick
send -m b5_ -R -X 'swap$' "$SRC" "$PEER:$RROOT/b5"
check "B5 -R -X remote: exit 0" "0" "$RC"
check "B5 -R -X remote: excluded dataset has no snapshot" "0" "$(r_snaps "$RROOT/b5/$SRC/swap")"
check "B5 -R -X remote: its child still landed" "1" "$(r_snaps "$RROOT/b5/$SRC/swap/inner")"
check "B5 -R -X remote: the intermediate is canmount=noauto" "noauto" \
      "$(r_canmount "$RROOT/b5/$SRC/swap")"

tick
send -m b6_ -R -S "$SRC" "$PEER:$RROOT/b6"
check "B6 -R -S remote: exit 0" "0" "$RC"
check "B6 -R -S remote: the parent was not sent" "no" "$(r_exists "$RROOT/b6/$SRC@")"
check "B6 -R -S remote: children were" "1" "$(r_snaps "$RROOT/b6/$SRC/keep")"

tick
send -m b7_ -b 5M "$SRC" "$PEER:$RROOT/b7"
check "B7 -b remote: exit 0" "0" "$RC"
check "B7 -b remote: rate-limited transfer still lands" "1" "$(r_snaps "$RROOT/b7/$SRC")"

# Incremental: the second run must recognise the target and send a delta, and a
# third with nothing new must take the "already exists" path WITHOUT stranding
# the hold it took on the way in.
tick
zfs snapshot "$SRC@b8_pre_$$" >/dev/null 2>&1
send -m b8_ -e "$SRC" "$PEER:$RROOT/b8"
check "B8 incremental remote: first send (existing snapshot) exit 0" "0" "$RC"
tick
send -m b8_ -e "$SRC" "$PEER:$RROOT/b8"
check "B8 incremental remote: re-run with nothing new exits 0" "0" "$RC"
check "B8 incremental remote: no second copy appeared" "1" "$(r_snaps "$RROOT/b8/$SRC")"
check "B8 incremental remote: no hold left on the source snapshot" "" \
      "$(zfs holds -H "$SRC@b8_pre_$$" 2>/dev/null | awk '{print $2}')"
# One bookmark accumulates PER TARGET, and this source has served every case,
# so a total count asserts nothing about B8. Presence is the honest claim.
check "B8 incremental remote: the source carries a send bookmark" "yes" \
      "$([ "$(zfs list -H -t bookmark -o name -d 1 "$SRC" 2>/dev/null | wc -l)" -gt 0 ] && echo yes || echo no)"

# ============================================================================
# C. snapget, LOCAL source
# ============================================================================
echo "--- C. snapget local"
# v2.61+ model: arg1 is the LITERAL existing source (read side, given as-is,
# no base needed to find it); LOCAL_BASE (arg2) places the result. A
# same-host relocation has no sync form (source and target can never share a
# name), so LOCAL_BASE is always given -- the resulting target is
# LOCAL_BASE/<arg1's full name>, computed below rather than hand-typed, since
# that concatenation is exactly the behaviour under test.
CSRC="$LROOT/csrc"
CTGT_BASE="$LROOT/ctgt-area"
seed_local "$CSRC" || { echo "could not seed the local pull source" >&2; exit 1; }
CTGT="$CTGT_BASE/$CSRC"

tick
get -m c1_ "$CSRC" "$CTGT_BASE"
check "C1 plain local pull: exit 0" "0" "$RC"
check "C1 plain local pull: GUID matches" \
      "$(l_guid "$CSRC@$(l_newest "$CSRC")")" \
      "$(l_guid "$CTGT@$(l_newest "$CSRC")")"

tick
get -m c2_ -r "$CSRC" "$CTGT_BASE"
check "C2 -r local pull: exit 0" "0" "$RC"
check "C2 -r local pull: descendant landed" "yes" "$(l_exists "$CTGT/swap/inner")"

tick
get -m c3_ -R "$CSRC" "$CTGT_BASE"
check "C3 -R local pull: exit 0" "0" "$RC"
check "C3 -R local pull: every dataset present locally" "4" \
      "$(zfs list -H -o name -r "$CTGT" 2>/dev/null | wc -l)"

tick
CSRC2="$LROOT/csrc2"
seed_local "$CSRC2" >/dev/null
CTGT2="$CTGT_BASE/$CSRC2"
get -m c4_ -R -X 'swap$' "$CSRC2" "$CTGT_BASE"
check "C4 -R -X local pull: exit 0" "0" "$RC"
check "C4 -R -X local pull: excluded dataset was not pulled" "0" "$(l_snaps "$CTGT2/swap")"
check "C4 -R -X local pull: its child was" "1" "$(l_snaps "$CTGT2/swap/inner")"

# ============================================================================
# D. snapget, REMOTE source (ssh, the mirrored half of B)
# ============================================================================
echo "--- D. snapget remote (ssh)"
# v2.61+ model: arg1 is [user@]host:LITERAL_remote_name (exactly what `zfs
# list` shows on the peer); LOCAL_BASE (arg2) places the result here as
# LOCAL_BASE/<that literal name>.
DBASE="$RROOT/dbase"
DTGT_BASE="$LROOT/dtgt-area"
DSRC="$DBASE/dsrc"
seed_peer "$DSRC" || { echo "could not seed the remote pull source" >&2; exit 1; }
DTGT="$DTGT_BASE/$DSRC"

tick
get -m d1_ "$PEER:$DSRC" "$DTGT_BASE"
check "D1 plain remote pull: exit 0" "0" "$RC"
check "D1 plain remote pull: GUID matches across the link" \
      "$(r_guid "$DSRC@$(r_newest "$DSRC")")" \
      "$(l_guid "$DTGT@$(r_newest "$DSRC")")"
check "D1 plain remote pull: local target is canmount=noauto" "noauto" "$(l_canmount "$DTGT")"

tick
get -m d2_ -z -v1 "$PEER:$DSRC" "$DTGT_BASE"
check "D2 -z remote pull: exit 0" "0" "$RC"
check "D2 -z remote pull: compression is not dropped over a link" "0" "$(outgrep 'compression ignored')"

tick
DSRC3="$DBASE/dsrc3"
DTGT3="$DTGT_BASE/$DSRC3"
seed_peer "$DSRC3"
get -m d3_ -r "$PEER:$DSRC3" "$DTGT_BASE"
check "D3 -r remote pull: exit 0" "0" "$RC"
check "D3 -r remote pull: descendant landed locally" "yes" "$(l_exists "$DTGT3/swap/inner")"

tick
DSRC4="$DBASE/dsrc4"
DTGT4="$DTGT_BASE/$DSRC4"
seed_peer "$DSRC4"
get -m d4_ -R "$PEER:$DSRC4" "$DTGT_BASE"
check "D4 -R remote pull: exit 0" "0" "$RC"
check "D4 -R remote pull: every dataset present locally" "4" \
      "$(zfs list -H -o name -r "$DTGT4" 2>/dev/null | wc -l)"

tick
DSRC5="$DBASE/dsrc5"
DTGT5="$DTGT_BASE/$DSRC5"
seed_peer "$DSRC5"
get -m d5_ -R -X 'swap$' "$PEER:$DSRC5" "$DTGT_BASE"
check "D5 -R -X remote pull: exit 0" "0" "$RC"
check "D5 -R -X remote pull: excluded dataset not pulled" "0" "$(l_snaps "$DTGT5/swap")"
check "D5 -R -X remote pull: its child was" "1" "$(l_snaps "$DTGT5/swap/inner")"
# The regex is matched against the FULL source-side path, which only a remote
# run can really demonstrate: this pattern cannot match the local target name.
tick
DSRC6="$DBASE/dsrc6"
DTGT6="$DTGT_BASE/$DSRC6"
seed_peer "$DSRC6"
get -m d6_ -R -X "^$DSRC6/keep$" "$PEER:$DSRC6" "$DTGT_BASE"
check "D6 -R -X remote pull: full source path matched" "0" "$RC"
check "D6 -R -X remote pull: the full-path exclusion took effect" "no" "$(l_exists "$DTGT6/keep")"

tick
DSRC7="$DBASE/dsrc7"
DTGT7="$DTGT_BASE/$DSRC7"
seed_peer "$DSRC7"
get -m d7_ -R -S "$PEER:$DSRC7" "$DTGT_BASE"
check "D7 -R -S remote pull: exit 0" "0" "$RC"
check "D7 -R -S remote pull: the parent was not snapshotted on the source" "0" \
      "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d 1 '$DSRC7' 2>/dev/null | grep -c d7_")"
check "D7 -R -S remote pull: the child was pulled" "1" "$(l_snaps "$DTGT7/keep")"

# ============================================================================
# F. SSH option passthrough (-c/-K/-O), and that -O truly takes priority
# ============================================================================
echo "--- F. ssh option passthrough (-c/-K/-O)"

# Auto-detected rather than hardcoded, so the positive -K case works run as
# root (id_rsa) or as the delegated account (its own id_ed25519) without
# assuming which.
DEFAULT_KEY=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    [ -r "$k" ] && { DEFAULT_KEY="$k"; break; }
done

if [ -z "$DEFAULT_KEY" ]; then
    echo "F. skipped -- no readable default identity under \$HOME/.ssh to test -K against"
else
    FSRC="$LROOT/fssh"
    mk_noauto "$FSRC" >/dev/null 2>&1

    tick
    send -m f1_ -K "$DEFAULT_KEY" "$FSRC" "$PEER:$RROOT/f1"
    check "F1 -K with the real identity: exit 0" "0" "$RC"
    check "F1 -K with the real identity: GUID matches" \
          "$(l_guid "$FSRC@$(l_newest "$FSRC")")" "$(r_guid "$RROOT/f1/$FSRC@$(l_newest "$FSRC")")"

    # A throwaway, WRONG key + IdentitiesOnly=yes must fail auth cleanly. This is
    # the only way to prove -K actually reaches ssh instead of ssh quietly
    # falling back to the agent or the account's real default identity -- a
    # "positive" case alone cannot tell the two apart.
    WRONGKEY="$TMPD/wrong_id"
    ssh-keygen -q -t ed25519 -N '' -f "$WRONGKEY" >/dev/null 2>&1
    tick
    send -m f2_ -K "$WRONGKEY" "$FSRC" "$PEER:$RROOT/f2"
    check "F2 -K with a WRONG key + IdentitiesOnly=yes fails auth" "1" "$RC"
    check "F2 -K wrong key: nothing landed on the peer" "no" "$(r_exists "$RROOT/f2/$FSRC")"

    # -O is placed FIRST on the ssh command line specifically so it can
    # override -p -- the only way to prove that ordering claim is to give it an
    # option that CONFLICTS with -p and confirm -O wins (connection fails on the
    # bogus port instead of succeeding on the real one).
    tick
    send -m f3_ -O "Port=1" -p 22 "$FSRC" "$PEER:$RROOT/f3"
    check "F3 -O Port=1 overrides -p 22 and fails to connect" "1" "$RC"

    # The harmless case: an -O that does not conflict with anything else.
    tick
    send -m f4_ -O "ConnectTimeout=8" "$FSRC" "$PEER:$RROOT/f4"
    check "F4 -O with a harmless option still succeeds" "0" "$RC"
    check "F4 -O harmless: GUID matches" \
          "$(l_guid "$FSRC@$(l_newest "$FSRC")")" "$(r_guid "$RROOT/f4/$FSRC@$(l_newest "$FSRC")")"

    # delsnaps.sh's -c is brand new (v2.62/v1.21, no prior remote-cipher test
    # existed at all) -- proved end to end: a real cipher prunes a real remote
    # snapshot; a bogus cipher name makes ssh itself refuse the connection, and
    # delsnaps.sh now (v1.22) reports that as a FAILURE rather than "no
    # snapshots found". -H0 (count-based: keep the 0 most recent match), not
    # -h0 (age-based) -- age=0 raced against the snapshot's own creation
    # second and "kept" it as not yet older than the threshold, which is a
    # test bug this caught on the very first live run, not a delsnaps one.
    PROOT="$RROOT/dsprune"
    $SSH "$PEER" "zfs create -o canmount=noauto '$PROOT'" >/dev/null 2>&1
    $SSH "$PEER" "zfs snapshot '$PROOT@keep_1'" >/dev/null 2>&1
    tick
    $SSH "$PEER" "zfs snapshot '$PROOT@prune_target_1'" >/dev/null 2>&1
    "$DELSNAPS" -c aes128-ctr "$PEER:$PROOT" "prune_target_" -H0 >"$TMPD/ds.out" 2>&1
    check "F5 delsnaps.sh -c with a real cipher: exit 0" "0" "$?"
    check "F5 delsnaps.sh -c: only the targeted snapshot is gone, 'keep_1' survives" "1" \
          "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d1 '$PROOT' 2>/dev/null" | wc -l)"

    tick
    $SSH "$PEER" "zfs snapshot '$PROOT@prune_target_2'" >/dev/null 2>&1
    "$DELSNAPS" -c not-a-real-cipher "$PEER:$PROOT" "prune_target_" -H0 >"$TMPD/ds2.out" 2>&1
    check "F6 delsnaps.sh -c with a bogus cipher: ssh refuses, delsnaps fails" "1" "$?"
    check "F6 bogus cipher: the snapshot it would have pruned still exists" "1" \
          "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d1 '$PROOT' 2>/dev/null | grep -c prune_target_2")"
fi

# ============================================================================
# G. sync mode (bare user@host, no ':', no base -- mirrors to the identical
#    path instead of nesting under one). See snapsend.sh/snapget.sh headers.
# ============================================================================
echo "--- G. sync mode (bare user@host)"

tick
send -m g1_ "$SRC" "$PEER"
check "G1 snapsend sync: exit 0" "0" "$RC"
check "G1 snapsend sync: landed at the IDENTICAL path on the peer" "yes" "$(r_exists "$SRC")"
check "G1 snapsend sync: GUID matches" \
      "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$SRC@$(l_newest "$SRC")")"
check "G1 snapsend sync: nothing landed under \$RROOT (proves no base was applied)" "no" "$(r_exists "$RROOT/$SRC")"

tick
GSRC="$LROOT/gsync-src"
seed_peer "$GSRC" || { echo "could not seed the peer-side sync-pull source" >&2; exit 1; }
get -m g2_ "$PEER:$GSRC"
check "G2 snapget sync: exit 0" "0" "$RC"
check "G2 snapget sync: landed locally at the IDENTICAL path" "yes" "$(l_exists "$GSRC")"
check "G2 snapget sync: GUID matches" \
      "$(r_guid "$GSRC@$(r_newest "$GSRC")")" "$(l_guid "$GSRC@$(r_newest "$GSRC")")"

# Self-sync guard: validate_remote_host (lib-zfs-snap.sh) compares
# /etc/machine-id over ssh and refuses a "remote" that turns out to be this
# same host. Needs this host to be reachable under its own address via ssh --
# not guaranteed in every environment, so that precondition failing is a
# clearly-labelled SKIP, not a false FAIL of the feature itself.
tick
SELF_ADDR="$(whoami)@$(hostname -f 2>/dev/null || hostname)"
if $SSH "$SELF_ADDR" true 2>/dev/null; then
    send -m g3_ "$SRC" "$SELF_ADDR"
    check "G3 self-sync refused (machine-id guard fired)" "1" "$(outgrep 'identical machine-id')"
    # Pinning the ACTUAL current exit code, not the one it arguably should be:
    # the guard aborts but still exits 0, which would read as success in a real
    # cron line. Known wart, flagged separately, deliberately not "fixed" here --
    # this test documents today's real behavior, not an aspiration.
    check "G3 self-sync: exit code (known wart -- reads as success in cron)" "0" "$RC"
else
    echo "SKIP G3 self-sync check -- $SELF_ADDR is not reachable via ssh from itself in this environment"
fi

# ============================================================================
# E. hygiene -- what the campaign must leave behind: nothing
# ============================================================================
echo "--- E. hygiene"

HELD=0
for s in $(zfs list -H -o name -t snapshot -r "$LROOT" 2>/dev/null); do
    zfs holds -H "$s" 2>/dev/null | grep -q zfssnapall && HELD=$((HELD + 1))
done
check "E1 no in-flight hold survived any case (local)" "0" "$HELD"

check "E2 no in-flight hold survived on the peer" "0" \
      "$($SSH "$PEER" "c=0; for s in \$(zfs list -H -o name -t snapshot -r '$RROOT' 2>/dev/null); do zfs holds -H \$s 2>/dev/null | grep -q zfssnapall && c=\$((c+1)); done; echo \$c")"

# -t filesystem matters: a snapshot reports canmount as "-", and counting those
# as "not noauto" is how the first version of this check failed for no reason.
check "E3 every filesystem on the peer is canmount=noauto" "0" \
      "$($SSH "$PEER" "zfs get -H -o value canmount -t filesystem -r '$RROOT/b1' 2>/dev/null | grep -vc noauto")"

# The case that found a real gap. Under -r the descendants are created by
# `zfs recv` out of the recursive stream, carrying the SOURCE's canmount -- so a
# source child with canmount=on used to produce a MOUNTABLE child on the backup
# host, i.e. the no-mount default stopped at the leaf. Seeded deliberately with
# canmount=on, because a noauto source would pass this check while proving
# nothing. snapsend v2.60 closes the subtree after the receive.
tick
ONSRC="$LROOT/onsrc"
mk_noauto "$ONSRC" >/dev/null 2>&1
mk_noauto "$ONSRC/onchild" >/dev/null 2>&1
# Created noauto, then flipped: `zfs create -o canmount=on` would try to MOUNT
# it, which the delegated account cannot do -- and this case has to run as that
# account too. Setting the property afterwards mounts nothing.
zfs set canmount=on "$ONSRC/onchild" >/dev/null 2>&1
send -m e4_ -r "$ONSRC" "$PEER:$RROOT/e4"
check "E4 -r with a canmount=on source: exit 0" "0" "$RC"
check "E4 -r leaves no mountable descendant on the target" "noauto" \
      "$(r_canmount "$RROOT/e4/$ONSRC/onchild")"
check "E4 the source's own canmount is untouched" "on" "$(l_canmount "$ONSRC/onchild")"

# -R never had the gap: it pre-creates each target itself.
tick
send -m e5_ -R "$ONSRC" "$PEER:$RROOT/e5"
check "E5 -R with the same source is noauto too" "noauto" \
      "$(r_canmount "$RROOT/e5/$ONSRC/onchild")"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
