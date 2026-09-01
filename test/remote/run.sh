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
#   --peer-key          the key to reach the peer with (default: the account's own)
#   --peer-known-hosts  the known_hosts to verify it against
#
# The last two are what makes the nonroot-account obligation runnable on a
# properly deployed account. `deploy.sh --join` gives it a dedicated key and a
# dedicated known_hosts PER PEER and leaves the default ~/.ssh/known_hosts
# empty, so a bare `ssh peer` from that account fails by design. Point these at
# the pairing files and the same credentials reach both this suite's own ssh
# and the engines it is testing:
#
#   ./test/remote/run.sh --peer zfsbackup-pve9@192.168.28.8 \
#       --local-parent hdd/backuptest --peer-parent hdd/backuptest_targets \
#       --peer-key ~/.ssh/pairing-192.168.28.8_ed25519 \
#       --peer-known-hosts ~/.ssh/pairing-192.168.28.8_known_hosts
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
# CREDENTIALS, because on this estate the delegated account HAS NONE by default
# and that is the design rather than a gap. `deploy.sh --join` gives an account a
# dedicated key and a dedicated known_hosts PER PEER, and leaves the default
# ~/.ssh/known_hosts empty -- so a bare `ssh peer` from that account fails, on
# purpose, while the relationship it was paired for works.
#
# Measured on pve9, 2026-09-01: `ssh zfsbackup@192.168.28.8` -> host key
# verification failed, while the same account with its pairing key and pairing
# known_hosts reached `zfsbackup-pve9@192.168.28.8` and answered `pve2`.
#
# Without these two options the nonroot-account obligation is only satisfiable
# on a host whose account has LOOSER trust than the deployment gives it, which
# is the wrong way round: the account this suite most needs to test is the one
# it could not reach.
PKEY=""
PKH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --peer)         shift; PEER="${1:-}" ;;
        --local-parent) shift; LPARENT="${1:-}" ;;
        --peer-parent)  shift; RPARENT="${1:-}" ;;
        --peer-key)     shift; PKEY="${1:-}" ;;
        --peer-known-hosts) shift; PKH="${1:-}" ;;
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
# ONE SET OF CREDENTIALS, TWO SPELLINGS. This suite opens ssh sessions of its
# own to check the far side, and the engines under test open theirs -- so the
# same key has to be handed to `ssh` as -i/-o and to snapsend/snapget/delsnaps
# as their own -K/-k/-O. Rendering both from one pair of options is the point:
# giving the checker credentials the engines do not have would produce a run
# where every assertion reads a far side the transfer could not reach.
PAIRFLAGS=()
if [ -n "$PKEY" ]; then
    SSH="$SSH -i $PKEY"
    PAIRFLAGS+=(-K "$PKEY")
fi
if [ -n "$PKH" ]; then
    SSH="$SSH -o UserKnownHostsFile=$PKH -o GlobalKnownHostsFile=/dev/null"
    PAIRFLAGS+=(-k "$PKH" -O GlobalKnownHostsFile=/dev/null)
fi
$SSH "$PEER" true 2>/dev/null || { echo "cannot ssh to $PEER non-interactively" >&2; exit 1; }

TAG="xcamp$$"
LROOT="$LPARENT/$TAG"
RROOT="$RPARENT/$TAG"

zfs list -H "$LROOT"          >/dev/null 2>&1 && { echo "refusing to run: $LROOT exists here" >&2; exit 1; }
$SSH "$PEER" "zfs list -H '$RROOT'" >/dev/null 2>&1 && { echo "refusing to run: $RROOT exists on $PEER" >&2; exit 1; }
# Sync mode (section G) lands at the IDENTICAL path on the peer, not under
# $RROOT, so that name has to be free there too.
$SSH "$PEER" "zfs list -H '$LROOT'" >/dev/null 2>&1 && { echo "refusing to run: $LROOT exists on $PEER (sync mode needs it free)" >&2; exit 1; }

# WHICH PARENTS EXISTED BEFORE US -- recorded here because cleanup cannot ask
# afterwards, and because "leave the host as you found it" is a property of the
# whole run, not of the $TAG level.
#
# Sync mode is what makes this necessary. It lands each side's tree at the
# IDENTICAL path on the other, so the initiator invents the PEER's parent path
# locally and the peer invents the initiator's. mk_noauto creates every missing
# level, and cleanup destroyed only the $TAG level under them -- so an invented
# parent stayed behind, empty, for good.
#
# Never showed on metropolis, where both hosts already had both parents. It
# showed the first time this ran from a host that did not: pve9, 2026-09-01,
# left `hdd/backuptest_targets` behind after a 145/0 run. That is the same
# family as the six trees the comment in cleanup() records being left on
# metropolis pve1 -- the $TAG level was given an owner then, the parent it
# hangs from was not.
#
# Only ever removed when we invented it AND it comes back empty, so a parent
# the operator keeps for their own scratch is never touched.
#
# TWO FLAGS, NOT FOUR, and the two that are missing are missing because they
# cannot happen. $LPARENT must exist HERE and $RPARENT must exist ON THE PEER --
# both are pre-flight refusals further down, added when a wrong --peer-parent
# made thirty ssh cases fail like a broken remote path. So neither can ever be
# invented on that side, and a cleanup branch for it would be a branch that
# never runs. The first cut of this block had one anyway; the verification run
# is what showed it, by refusing before it could fire.
RPARENT_EXISTED_LOCAL=1;  zfs list -H "$RPARENT" >/dev/null 2>&1 || RPARENT_EXISTED_LOCAL=0
LPARENT_EXISTED_PEER=1;   $SSH "$PEER" "zfs list -H '$LPARENT'" >/dev/null 2>&1 || LPARENT_EXISTED_PEER=0

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
    # Section H pulls in SYNC mode, which lands the peer's tree at the
    # IDENTICAL path on THIS host -- so $RROOT exists locally too, and nothing
    # here used to remove it. Every run since 2026-07-29 left one behind:
    # six trees on metropolis pve1 by 2026-08-02, in the same pool that holds
    # production backups. The peer side was always cleaned; it was the mirror
    # of the peer path on the initiator that had no owner.
    for s in $(zfs list -H -o name -t snapshot -r "$RROOT" 2>/dev/null); do
        zfs release zfssnapall_inflight "$s" 2>/dev/null
    done
    zfs destroy -R "$RROOT" 2>/dev/null
    $SSH "$PEER" "for s in \$(zfs list -H -o name -t snapshot -r '$RROOT' 2>/dev/null); do zfs release zfssnapall_inflight \$s 2>/dev/null; done; zfs destroy -R '$RROOT' 2>/dev/null" 2>/dev/null
    # Sync mode (section G) lands at the IDENTICAL path, not under $RROOT --
    # its peer-side footprint lives under $LROOT instead, so that needs its
    # own release+destroy on the peer too.
    $SSH "$PEER" "for s in \$(zfs list -H -o name -t snapshot -r '$LROOT' 2>/dev/null); do zfs release zfssnapall_inflight \$s 2>/dev/null; done; zfs destroy -R '$LROOT' 2>/dev/null" 2>/dev/null
    # ...and the PARENTS those roots hang from, when this run is what created
    # them. See the pre-flight block for why sync mode makes each side invent
    # the other's parent path, and what it left on pve9.
    #
    # Two conditions, both required. "We invented it" comes from the recorded
    # pre-flight answer -- a parent the operator keeps for their own scratch
    # must survive. "It is empty now" is checked rather than assumed, because a
    # concurrent second campaign under the same parent would otherwise have its
    # tree pulled out from under it: with `zfs destroy` (no -r, no -R) the worst
    # case is a refusal, not a loss.
    #
    # ONE LEVEL ONLY, stated rather than implied: if a parent needed several
    # levels invented (`hdd/a/b` where neither existed), this removes `b` and
    # leaves `a`. Walking further up would mean deciding how far is ours, and a
    # test harness guessing that on a production pool is a worse trade than an
    # empty dataset an operator can see and delete.
    [ "$RPARENT_EXISTED_LOCAL" = 0 ] && zfs destroy "$RPARENT" 2>/dev/null
    [ "$LPARENT_EXISTED_PEER" = 0 ] && $SSH "$PEER" "zfs destroy '$LPARENT'" 2>/dev/null
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
# The pairing flags go FIRST, so a case's own flags still win where they
# overlap, and the empty-array expansion is the ${a[@]+"${a[@]}"} idiom this
# repo uses everywhere: `"${PAIRFLAGS[@]}"` on an empty array is an unbound
# variable under `set -u`.
send() { "$SNAPSEND" ${PAIRFLAGS[@]+"${PAIRFLAGS[@]}"} "$@" >"$TMPD/out" 2>&1; RC=$?; }
get()  { "$SNAPGET"  ${PAIRFLAGS[@]+"${PAIRFLAGS[@]}"} "$@" >"$TMPD/out" 2>&1; RC=$?; }
# Case-insensitive by default. It used to take flags, and `outgrep -i pattern`
# quietly searched for the string "-i" instead -- so the two cases expecting
# ZERO matches passed for the wrong reason, which is worse than failing.
outgrep() { grep -ci "$1" "$TMPD/out"; }

# snapshot names carry a per-second timestamp, so consecutive runs need spacing
tick() { sleep 1; }

echo "=== two-host campaign: $(hostname) -> $PEER"
echo "=== scratch: $LROOT (here) / $RROOT (there)"

# Leftovers from EARLIER runs, named at the start.
#
# The teardown gap above went unnoticed from 2026-07-29 to 2026-08-02 because
# nothing ever looked. A suite whose own section E is titled "hygiene" should
# not be the thing quietly filling a pool, and the cheapest guard is to say so
# on the next run rather than to trust the fix forever.
stale_scratch() {   # <parent>
    zfs list -H -o name -d1 -r "$1" 2>/dev/null | grep -E "/xcamp[0-9]+$" | grep -v "/$TAG$"
}
# Both parents must EXIST before a single case runs.
#
# The defaults are metropolis-shaped -- `hdd/backuptest_targets` is a dataset
# that happens to exist on pve1/pve2 and on no other host. Run this against the
# 192.168.11.x cluster without --peer-parent and every local section passes
# while all thirty-odd ssh cases fail, which reads exactly like a broken
# remote path (measured 2026-08-02). The peer parent is the one thing this
# suite cannot create for itself: it belongs to the far host's layout.
zfs list -H "$LPARENT" >/dev/null 2>&1 || {
    echo "the local scratch parent '$LPARENT' does not exist on $(hostname)." >&2
    echo "Pass --local-parent <existing dataset>; the default is 'rpool'." >&2
    exit 2
}
$SSH "$PEER" "zfs list -H '$RPARENT'" >/dev/null 2>&1 || {
    echo "the peer scratch parent '$RPARENT' does not exist on $PEER (or the link is down)." >&2
    echo "Pass --peer-parent <existing dataset>. The default '$RPARENT' is the" >&2
    echo "metropolis layout; the 192.168.11.x hosts use 'rpool'." >&2
    echo "Without this check every ssh case fails and it looks like a code defect." >&2
    exit 2
}

stale=$( { stale_scratch "$LPARENT"; stale_scratch "$RPARENT"; } | sort -u )
if [ -n "$stale" ]; then
    echo "!!! scratch left by EARLIER runs is still here -- this suite should clean up after itself:"
    printf "        %s
" $stale
    echo "    (remove with: zfs destroy -R <name>)"
fi

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
    "$DELSNAPS" ${PAIRFLAGS[@]+"${PAIRFLAGS[@]}"} -c aes128-ctr "$PEER:$PROOT" "prune_target_" -H0 >"$TMPD/ds.out" 2>&1
    check "F5 delsnaps.sh -c with a real cipher: exit 0" "0" "$?"
    check "F5 delsnaps.sh -c: only the targeted snapshot is gone, 'keep_1' survives" "1" \
          "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d1 '$PROOT' 2>/dev/null" | wc -l)"

    tick
    $SSH "$PEER" "zfs snapshot '$PROOT@prune_target_2'" >/dev/null 2>&1
    "$DELSNAPS" ${PAIRFLAGS[@]+"${PAIRFLAGS[@]}"} -c not-a-real-cipher "$PEER:$PROOT" "prune_target_" -H0 >"$TMPD/ds2.out" 2>&1
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
# H. sync mode + recursion -- combinations G/B/D never separately exercised:
#    -r, -R, -R -X, -R -S all under SYNC addressing (no base at all), and
#    -R -S -X under BACKUP addressing as a real transfer (not just the
#    "excludes everything" error case covered elsewhere). The recursion/
#    filter machinery itself doesn't care whether a base was given -- it only
#    affects the final target name -- but that was never actually exercised
#    as these literal combined invocations before.
# ============================================================================
echo "--- H. sync mode + recursion combinations"

# H1: snapsend -r sync
H1SRC="$LROOT/h1src"
mk_noauto "$H1SRC" >/dev/null 2>&1
mk_noauto "$H1SRC/child" >/dev/null 2>&1
tick
send -m h1_ -r "$H1SRC" "$PEER"
check "H1 snapsend -r sync: exit 0" "0" "$RC"
check "H1 snapsend -r sync: landed at the identical path" "yes" "$(r_exists "$H1SRC")"
check "H1 snapsend -r sync: child landed too" "yes" "$(r_exists "$H1SRC/child")"
check "H1 snapsend -r sync: nothing under \$RROOT (proves no base)" "no" "$(r_exists "$RROOT/$H1SRC")"

# H2: snapsend -R sync, no pattern
H2SRC="$LROOT/h2src"
mk_noauto "$H2SRC" >/dev/null 2>&1
mk_noauto "$H2SRC/a" >/dev/null 2>&1
mk_noauto "$H2SRC/b" >/dev/null 2>&1
tick
send -m h2_ -R "$H2SRC" "$PEER"
check "H2 snapsend -R sync: exit 0" "0" "$RC"
check "H2 snapsend -R sync: every dataset landed at the identical path" "3" \
      "$($SSH "$PEER" "zfs list -H -o name -r '$H2SRC' 2>/dev/null" | wc -l)"

# H3: snapsend -R -X sync
H3SRC="$LROOT/h3src"
mk_noauto "$H3SRC" >/dev/null 2>&1
mk_noauto "$H3SRC/keep" >/dev/null 2>&1
mk_noauto "$H3SRC/swap" >/dev/null 2>&1
tick
send -m h3_ -R -X 'swap$' "$H3SRC" "$PEER"
check "H3 snapsend -R -X sync: exit 0" "0" "$RC"
check "H3 snapsend -R -X sync: excluded child has no snapshot" "0" "$(r_snaps "$H3SRC/swap")"
check "H3 snapsend -R -X sync: the kept child landed" "1" "$(r_snaps "$H3SRC/keep")"

# H4: snapsend -R -S sync
H4SRC="$LROOT/h4src"
mk_noauto "$H4SRC" >/dev/null 2>&1
mk_noauto "$H4SRC/a" >/dev/null 2>&1
tick
send -m h4_ -R -S "$H4SRC" "$PEER"
check "H4 snapsend -R -S sync: exit 0" "0" "$RC"
check "H4 snapsend -R -S sync: the parent itself was not snapshotted" "0" "$(r_snaps "$H4SRC")"
check "H4 snapsend -R -S sync: the child was" "1" "$(r_snaps "$H4SRC/a")"

# H5: snapsend -R -S -X BACKUP mode, a real transfer (not the empty-result
# error case) -- -S drops the parent, -X drops 'swap' but NOT its own child,
# both filters active on the same run, something still lands.
H5SRC="$LROOT/h5src"
mk_noauto "$H5SRC" >/dev/null 2>&1
mk_noauto "$H5SRC/keep" >/dev/null 2>&1
mk_noauto "$H5SRC/swap" >/dev/null 2>&1
mk_noauto "$H5SRC/swap/inner" >/dev/null 2>&1
tick
send -m h5_ -R -S -X 'swap$' "$H5SRC" "$PEER:$RROOT/h5"
check "H5 snapsend -R -S -X backup: exit 0" "0" "$RC"
check "H5 snapsend -R -S -X backup: the parent was not snapshotted" "0" \
      "$(r_snaps "$RROOT/h5/$H5SRC")"
check "H5 snapsend -R -S -X backup: 'keep' landed" "1" "$(r_snaps "$RROOT/h5/$H5SRC/keep")"
check "H5 snapsend -R -S -X backup: 'swap' itself was excluded" "0" "$(r_snaps "$RROOT/h5/$H5SRC/swap")"
check "H5 snapsend -R -S -X backup: 'swap/inner' still landed (exclude isn't recursive)" "1" \
      "$(r_snaps "$RROOT/h5/$H5SRC/swap/inner")"

# H6: snapget -r sync
H6SRC="$RROOT/h6src"
seed_peer "$H6SRC" >/dev/null
tick
get -m h6_ -r "$PEER:$H6SRC"
check "H6 snapget -r sync: exit 0" "0" "$RC"
check "H6 snapget -r sync: landed locally at the identical path" "yes" "$(l_exists "$H6SRC")"
check "H6 snapget -r sync: child landed too" "yes" "$(l_exists "$H6SRC/keep")"

# H7: snapget -R sync, no pattern
H7SRC="$RROOT/h7src"
seed_peer "$H7SRC" >/dev/null
tick
get -m h7_ -R "$PEER:$H7SRC"
check "H7 snapget -R sync: exit 0" "0" "$RC"
check "H7 snapget -R sync: every dataset present locally" "4" \
      "$(zfs list -H -o name -r "$H7SRC" 2>/dev/null | wc -l)"

# H8: snapget -R -X sync
H8SRC="$RROOT/h8src"
seed_peer "$H8SRC" >/dev/null
tick
get -m h8_ -R -X 'swap$' "$PEER:$H8SRC"
check "H8 snapget -R -X sync: exit 0" "0" "$RC"
check "H8 snapget -R -X sync: excluded dataset has no snapshot" "0" "$(l_snaps "$H8SRC/swap")"
check "H8 snapget -R -X sync: the kept child landed" "1" "$(l_snaps "$H8SRC/keep")"

# H9: snapget -R -S sync
H9SRC="$RROOT/h9src"
seed_peer "$H9SRC" >/dev/null
tick
get -m h9_ -R -S "$PEER:$H9SRC"
check "H9 snapget -R -S sync: exit 0" "0" "$RC"
check "H9 snapget -R -S sync: the parent was not snapshotted on the source" "0" \
      "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d 1 '$H9SRC' 2>/dev/null | grep -c h9_")"
check "H9 snapget -R -S sync: the child was pulled" "1" "$(l_snaps "$H9SRC/keep")"

# H10: snapget -R -S -X BACKUP mode, a real transfer
H10SRC="$RROOT/h10src"
seed_peer "$H10SRC" >/dev/null
H10TGT="$LROOT/h10tgt"
tick
get -m h10_ -R -S -X 'swap$' "$PEER:$H10SRC" "$H10TGT"
check "H10 snapget -R -S -X backup: exit 0" "0" "$RC"
check "H10 snapget -R -S -X backup: the parent was not snapshotted on the source" "0" \
      "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d 1 '$H10SRC' 2>/dev/null | grep -c h10_")"
check "H10 snapget -R -S -X backup: 'keep' landed" "1" "$(l_snaps "$H10TGT/$H10SRC/keep")"
check "H10 snapget -R -S -X backup: 'swap' itself was excluded" "0" "$(l_snaps "$H10TGT/$H10SRC/swap")"
check "H10 snapget -R -S -X backup: 'swap/inner' still landed" "1" \
      "$(l_snaps "$H10TGT/$H10SRC/swap/inner")"

# ============================================================================
# I. ssh could not connect vs. the dataset is not there -- two causes, two
#    messages. Needs a REAL peer: the point is that the same code path, over
#    the same working link, gives DIFFERENT answers for the two causes. One
#    machine can prove the connection half (test/snapsend/run.sh does) but not
#    that a live connection still reports a genuinely missing dataset as
#    missing.
# ============================================================================
echo "--- I. ssh failure vs. missing dataset"

# I1/I2 reproduce the live 2026-07-29 finding exactly: a known_hosts file
# holding a WRONG key for the peer, with StrictHostKeyChecking=yes (which is
# what -k selects). ssh prints "Host key verification failed" and exits 255, and
# snapget.sh used to answer "Source dataset not found on remote host: <name>"
# for a dataset that was sitting right there.
BADKH="$TMPD/bad_known_hosts"
ssh-keygen -q -t ed25519 -N '' -f "$TMPD/fake_hostkey" >/dev/null 2>&1
PEERHOST="${PEER#*@}"
printf '%s %s\n' "$PEERHOST" "$(cut -d' ' -f1,2 < "$TMPD/fake_hostkey.pub")" > "$BADKH"

ISRC="$RROOT/isrc"
$SSH "$PEER" "zfs create -o canmount=noauto '$ISRC'" >/dev/null 2>&1
$SSH "$PEER" "zfs snapshot '$ISRC@i_1'" >/dev/null 2>&1
check "I0 the source really does exist on the peer" "yes" "$(r_exists "$ISRC")"

# Presence, not a count: a single run legitimately meets the dead connection at
# more than one probe (the container-parent warning looks first, process_dataset
# looks again), and pinning an exact number would make this fail on a harmless
# reordering rather than on the behaviour it is here to protect.
outsays() { [ "$(outgrep "$1")" -gt 0 ] && echo yes || echo no; }

get -k "$BADKH" -e -m i1_ "$PEER:$ISRC" "$LROOT/i1"
check "I1 wrong host key, plain pull: exit 1" "1" "$RC"
check "I1 wrong host key: ssh itself said the host key failed" "yes" \
      "$(outsays 'host key verification failed')"
check "I1 wrong host key: reported as a CONNECTION-level failure" "yes" \
      "$(outsays 'CONNECTION-level failure')"
check "I1 wrong host key: does NOT claim the dataset is missing" "no" \
      "$(outsays 'source dataset not found')"
check "I1 wrong host key: nothing was pulled" "no" "$(l_exists "$LROOT/i1/$ISRC")"

get -k "$BADKH" -R -m i2_ "$PEER:$ISRC" "$LROOT/i2"
check "I2 wrong host key, -R expansion: exit 1" "1" "$RC"
check "I2 wrong host key, -R: reported as a CONNECTION-level failure" "yes" \
      "$(outsays 'CONNECTION-level failure')"
check "I2 wrong host key, -R: does NOT claim the dataset is missing" "no" \
      "$(outsays 'source dataset not found')"

# I3 is the half that only a working link can prove: same code, same peer, ssh
# connects fine, and the dataset genuinely is not there. This one MUST say "not
# found" -- a fix that renamed every failure into a connection problem would
# pass I1/I2 and fail here.
tick
get -e -m i3_ "$PEER:$RROOT/no-such-source-dataset" "$LROOT/i3"
check "I3 live connection, absent dataset: exit 1" "1" "$RC"
check "I3 live connection, absent dataset: says not found" "yes" \
      "$(outsays 'source dataset not found on remote host')"
check "I3 live connection, absent dataset: says nothing about the connection" "no" \
      "$(outsays 'CONNECTION-level failure')"

# I4: the push direction. snapsend.sh's source is always local, so it never had
# the wrong MESSAGE -- it had the silent version: target_exists() read an
# unreachable peer as "the target does not exist yet", i.e. as a first send, and
# went on to build a full stream for a host it had not reached.
ISENDSRC="$LROOT/isend"
mk_noauto "$ISENDSRC" >/dev/null 2>&1
tick
send -k "$BADKH" -m i4_ "$ISENDSRC" "$PEER:$RROOT/i4"
check "I4 wrong host key, push: exit 1" "1" "$RC"
check "I4 wrong host key, push: reported as a CONNECTION-level failure" "yes" \
      "$(outsays 'CONNECTION-level failure')"
check "I4 wrong host key, push: nothing landed on the peer" "no" \
      "$(r_exists "$RROOT/i4/$ISENDSRC")"

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
