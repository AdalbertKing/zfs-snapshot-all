#!/bin/bash
# Two-host campaign: everything the single-host suites structurally cannot reach.
#
# test/snapsend/run.sh and test/delsnaps/run.sh are local-mode only, by design --
# validate_remote_host() refuses a loopback "replication" to the same machine, so
# ssh has never had a repeatable test at all. This is that test: push
# (snapsend.sh), pull (snapget.sh) and prune (delsnaps.sh) over the link, plus
# the transport flags themselves. It is declared as the `remote` suite in
# test/deps.conf with "needs = a SECOND host" -- not runnable unattended, but one
# command rather than a remembered ritual.
#
# Sections: A/B snapsend local+remote, C/D snapget local+remote, F the ssh
# transport options, G delsnaps over ssh, E what must be left behind (nothing).
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
        -h|--help)      sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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

# Keep this run's bookkeeping out of the host's real logs and lock dir. The
# cache dir matters for the same reason plus one more: it is where the scripts
# put their ControlMaster sockets, so redirecting it here is what lets section F
# assert that none survive the run.
TMPD="$(mktemp -d)"
export STATS_LOG="$TMPD/stats.log"
export LOCKDIR="$TMPD"
export ZFS_SNAP_CACHE_DIR="$TMPD/cache"

cleanup() {
    # Release first: a case that fails before its transfer leaves a held
    # snapshot, and `zfs destroy` would then report only "dataset is busy".
    local s
    for s in $(zfs list -H -o name -t snapshot -r "$LROOT" 2>/dev/null); do
        zfs release zfssnapall_inflight "$s" 2>/dev/null
    done
    zfs destroy -R "$LROOT" 2>/dev/null
    $SSH "$PEER" "for s in \$(zfs list -H -o name -t snapshot -r '$RROOT' 2>/dev/null); do zfs release zfssnapall_inflight \$s 2>/dev/null; done; zfs destroy -R '$RROOT' 2>/dev/null" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"; PASS=$((PASS + 1))
    else
        echo "FAIL $label"; echo "     expected: [$expected]"; echo "     actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# For a case whose PRECONDITION is missing (no ssh-keyscan, sshd refusing a
# cipher the client offers). Counted and named, never silently dropped: a case
# that quietly disappears is indistinguishable from one that passed.
skip() {
    echo "SKIP $1 -- $2"; SKIP=$((SKIP + 1))
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
del()  { "$DELSNAPS" "$@" >"$TMPD/out" 2>&1; RC=$?; }
# Exit status as a word, for the cases that must FAIL: asserting a specific
# non-zero number would pin an implementation detail (which ssh error surfaced
# first), while "it refused" is the actual contract.
rcword() { [ "$RC" -eq 0 ] && echo zero || echo nonzero; }
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
# snapget's model is mirrored: source = <SOURCE_BASE>/<target dataset>, so the
# source tree has to be built at that exact nested path.
CBASE="$LROOT/cbase"
CTGT="$LROOT/ctgt"
seed_local "$CBASE/$CTGT" || { echo "could not seed the local pull source" >&2; exit 1; }

tick
get -m c1_ "$CTGT" "$CBASE"
check "C1 plain local pull: exit 0" "0" "$RC"
check "C1 plain local pull: GUID matches" \
      "$(l_guid "$CBASE/$CTGT@$(l_newest "$CBASE/$CTGT")")" \
      "$(l_guid "$CTGT@$(l_newest "$CBASE/$CTGT")")"

tick
get -m c2_ -r "$CTGT" "$CBASE"
check "C2 -r local pull: exit 0" "0" "$RC"
check "C2 -r local pull: descendant landed" "yes" "$(l_exists "$CTGT/swap/inner")"

tick
get -m c3_ -R "$CTGT" "$CBASE"
check "C3 -R local pull: exit 0" "0" "$RC"
check "C3 -R local pull: every dataset present locally" "4" \
      "$(zfs list -H -o name -r "$CTGT" 2>/dev/null | wc -l)"

tick
CTGT2="$LROOT/ctgt2"
seed_local "$CBASE/$CTGT2" >/dev/null
get -m c4_ -R -X 'swap$' "$CTGT2" "$CBASE"
check "C4 -R -X local pull: exit 0" "0" "$RC"
check "C4 -R -X local pull: excluded dataset was not pulled" "0" "$(l_snaps "$CTGT2/swap")"
check "C4 -R -X local pull: its child was" "1" "$(l_snaps "$CTGT2/swap/inner")"

# ============================================================================
# D. snapget, REMOTE source (ssh, the mirrored half of B)
# ============================================================================
echo "--- D. snapget remote (ssh)"
DBASE="$RROOT/dbase"
DTGT="$LROOT/dtgt"
seed_peer "$DBASE/$DTGT" || { echo "could not seed the remote pull source" >&2; exit 1; }

tick
get -m d1_ "$DTGT" "$PEER:$DBASE"
check "D1 plain remote pull: exit 0" "0" "$RC"
check "D1 plain remote pull: GUID matches across the link" \
      "$(r_guid "$DBASE/$DTGT@$(r_newest "$DBASE/$DTGT")")" \
      "$(l_guid "$DTGT@$(r_newest "$DBASE/$DTGT")")"
check "D1 plain remote pull: local target is canmount=noauto" "noauto" "$(l_canmount "$DTGT")"

tick
get -m d2_ -z -v1 "$DTGT" "$PEER:$DBASE"
check "D2 -z remote pull: exit 0" "0" "$RC"
check "D2 -z remote pull: compression is not dropped over a link" "0" "$(outgrep 'compression ignored')"

tick
DTGT3="$LROOT/dtgt3"
seed_peer "$DBASE/$DTGT3"
get -m d3_ -r "$DTGT3" "$PEER:$DBASE"
check "D3 -r remote pull: exit 0" "0" "$RC"
check "D3 -r remote pull: descendant landed locally" "yes" "$(l_exists "$DTGT3/swap/inner")"

tick
DTGT4="$LROOT/dtgt4"
seed_peer "$DBASE/$DTGT4"
get -m d4_ -R "$DTGT4" "$PEER:$DBASE"
check "D4 -R remote pull: exit 0" "0" "$RC"
check "D4 -R remote pull: every dataset present locally" "4" \
      "$(zfs list -H -o name -r "$DTGT4" 2>/dev/null | wc -l)"

tick
DTGT5="$LROOT/dtgt5"
seed_peer "$DBASE/$DTGT5"
get -m d5_ -R -X 'swap$' "$DTGT5" "$PEER:$DBASE"
check "D5 -R -X remote pull: exit 0" "0" "$RC"
check "D5 -R -X remote pull: excluded dataset not pulled" "0" "$(l_snaps "$DTGT5/swap")"
check "D5 -R -X remote pull: its child was" "1" "$(l_snaps "$DTGT5/swap/inner")"
# The regex is matched against the FULL source-side path, which only a remote
# run can really demonstrate: this pattern cannot match the local target name.
tick
DTGT6="$LROOT/dtgt6"
seed_peer "$DBASE/$DTGT6"
get -m d6_ -R -X "^$DBASE/$DTGT6/keep$" "$DTGT6" "$PEER:$DBASE"
check "D6 -R -X remote pull: full source path matched" "0" "$RC"
check "D6 -R -X remote pull: the full-path exclusion took effect" "no" "$(l_exists "$DTGT6/keep")"

tick
DTGT7="$LROOT/dtgt7"
seed_peer "$DBASE/$DTGT7"
get -m d7_ -R -S "$DTGT7" "$PEER:$DBASE"
check "D7 -R -S remote pull: exit 0" "0" "$RC"
check "D7 -R -S remote pull: the parent was not snapshotted on the source" "0" \
      "$($SSH "$PEER" "zfs list -H -o name -t snapshot -d 1 '$DBASE/$DTGT7' 2>/dev/null | grep -c d7_")"
check "D7 -R -S remote pull: the child was pulled" "1" "$(l_snaps "$DTGT7/keep")"

# ============================================================================
# F. the ssh transport options themselves -- -p, -c, -k, connection reuse
# ============================================================================
# These four were the last part of the ssh path with no test at all, and they
# share a failure mode that a happy-path check cannot see: a flag that never
# reaches ssh still produces a working transfer. So each one is asserted twice,
# once with a value that must work and once with a value that must be REFUSED.
# Only the refusal proves the flag was actually passed through.
#
# The refusal cases carry a second assertion for free: each one dies AFTER
# snapshotting the source but BEFORE the transfer, which is precisely the path
# that used to strand an in-flight hold. E1/E2 below are what catch that, so they
# are load-bearing for this section, not just a tidy-up.
echo "--- F. ssh transport options"

PEER_HOST="${PEER##*@}"

tick
send -m f1_ -p 22 "$SRC" "$PEER:$RROOT/f1"
check "F1 -p 22 remote: exit 0" "0" "$RC"
check "F1 -p 22 remote: GUID matches" \
      "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$RROOT/f1/$SRC@$(l_newest "$SRC")")"

tick
send -m f2_ -p 65000 "$SRC" "$PEER:$RROOT/f2"
check "F2 -p on a closed port: refused, not silently ignored" "nonzero" "$(rcword)"
check "F2 -p on a closed port: nothing was created there" "no" "$(r_exists "$RROOT/f2")"

# A cipher sshd is certain to have -- but if this build somehow lacks it, that is
# a precondition failure, not a defect in the flag, so it is skipped not failed.
CIPHER="aes128-gcm@openssh.com"
tick
if $SSH -c "$CIPHER" "$PEER" true 2>/dev/null; then
    send -m f3_ -c "$CIPHER" "$SRC" "$PEER:$RROOT/f3"
    check "F3 -c <cipher> remote: exit 0" "0" "$RC"
    check "F3 -c <cipher> remote: GUID matches after the negotiated cipher" \
          "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$RROOT/f3/$SRC@$(l_newest "$SRC")")"
else
    skip "F3 -c <cipher> remote" "$PEER does not accept $CIPHER"
fi

tick
send -m f4_ -c not-a-real-cipher "$SRC" "$PEER:$RROOT/f4"
check "F4 -c with a bogus cipher: refused" "nonzero" "$(rcword)"
check "F4 -c with a bogus cipher: nothing was created there" "no" "$(r_exists "$RROOT/f4")"

# -k switches on StrictHostKeyChecking=yes against a file WE name. The positive
# case needs a populated known_hosts, which is what ssh-keyscan is for.
KH="$TMPD/known_hosts"
tick
if command -v ssh-keyscan >/dev/null && ssh-keyscan -T 10 -p 22 -H "$PEER_HOST" >"$KH" 2>/dev/null && [ -s "$KH" ]; then
    send -m f5_ -k "$KH" "$SRC" "$PEER:$RROOT/f5"
    check "F5 -k with the peer's real key: exit 0" "0" "$RC"
    check "F5 -k with the peer's real key: GUID matches" \
          "$(l_guid "$SRC@$(l_newest "$SRC")")" "$(r_guid "$RROOT/f5/$SRC@$(l_newest "$SRC")")"
else
    skip "F5 -k with the peer's real key" "ssh-keyscan unavailable or returned nothing for $PEER_HOST"
fi

# The one that matters: an EMPTY known_hosts must make the run fail. If -k were
# dropped on the floor, StrictHostKeyChecking would stay "no" and this would
# happily succeed -- which is exactly the silent hole the flag exists to close.
: >"$TMPD/empty_hosts"
tick
send -m f6_ -k "$TMPD/empty_hosts" "$SRC" "$PEER:$RROOT/f6"
check "F6 -k with an empty known_hosts: refused (host key not trusted)" "nonzero" "$(rcword)"
check "F6 -k with an empty known_hosts: nothing was created there" "no" "$(r_exists "$RROOT/f6")"

# Connection reuse. -v3 is where the socket path is logged; the assertion that
# actually matters is the second one, since a master left running holds a
# connection open long after the run and used to be shared between runs.
tick
send -m f7_ -v3 "$SRC" "$PEER:$RROOT/f7"
check "F7 reuse: exit 0" "0" "$RC"
check "F7 reuse: a ControlMaster socket was set up for the run" "1" "$(outgrep 'ControlMaster socket')"
# The trailing .<pid> is the whole point: a socket named after the host alone is
# shared between concurrent runs, and closing it takes the other run's sessions
# down with it.
check "F7 reuse: the socket name is scoped to one run (trailing pid)" "1" \
      "$(grep -c 'ControlMaster socket:.*\.[0-9][0-9]*$' "$TMPD/out")"
check "F7 reuse: no socket survived the run" "0" \
      "$(ls "$ZFS_SNAP_CACHE_DIR" 2>/dev/null | grep -c '^cm')"

# snapget builds SSH_OPTS on its own, so the passthrough has to be proven there
# too -- the same flag on the pull side is a separate code path, not a rerun.
tick
if $SSH -c "$CIPHER" "$PEER" true 2>/dev/null; then
    FTGT="$LROOT/ftgt"
    seed_peer "$DBASE/$FTGT"
    get -m f8_ -p 22 -c "$CIPHER" "$FTGT" "$PEER:$DBASE"
    check "F8 snapget -p/-c remote pull: exit 0" "0" "$RC"
    check "F8 snapget -p/-c remote pull: GUID matches" \
          "$(r_guid "$DBASE/$FTGT@$(r_newest "$DBASE/$FTGT")")" \
          "$(l_guid "$FTGT@$(r_newest "$DBASE/$FTGT")")"
else
    skip "F8 snapget -p/-c remote pull" "$PEER does not accept $CIPHER"
fi

tick
get -m f9_ -p 65000 "$LROOT/f9tgt" "$PEER:$DBASE"
check "F9 snapget -p on a closed port: refused" "nonzero" "$(rcword)"
check "F9 snapget -p on a closed port: no local target appeared" "no" "$(l_exists "$LROOT/f9tgt")"

# ============================================================================
# G. delsnaps over ssh -- retention on the far end of the link
# ============================================================================
# The other half of "the ssh option": the scripts that PUSH over ssh have been
# exercised above, but the one that PRUNES over ssh had no coverage on either
# host. It is also the script that makes the most ssh calls -- one `zfs get
# creation` per candidate plus one per destroy.
echo "--- G. delsnaps over ssh"

GDS="$RROOT/gprune"
rz create -o canmount=noauto "$GDS"       >/dev/null 2>&1
rz create -o canmount=noauto "$GDS/child" >/dev/null 2>&1
# -r so parent and child get the same three names; spaced out because count-based
# retention orders by creation time and a tie is not an order.
for i in 1 2 3; do
    rz snapshot -r "$GDS@gp_$i" >/dev/null 2>&1
    [ "$i" -lt 3 ] && tick
done
check "G0 seeding: three snapshots on the peer" "3" "$(r_snaps "$GDS")"

del -n "$PEER:$GDS" gp_ -H1
check "G1 -n over ssh: exit 0" "0" "$RC"
check "G1 -n over ssh: says what it WOULD delete" "1" "$(outgrep 'would delete snapshot')"
check "G1 -n over ssh: destroyed nothing" "3" "$(r_snaps "$GDS")"

del "$PEER:$GDS" gp_ -H2
check "G2 -H2 over ssh: exit 0" "0" "$RC"
check "G2 -H2 over ssh: exactly two survive" "2" "$(r_snaps "$GDS")"
check "G2 -H2 over ssh: the OLDEST is the one that went" "no" "$(r_exists "$GDS@gp_1")"
check "G2 -H2 over ssh: the child was untouched (no -R)" "3" "$(r_snaps "$GDS/child")"

del "$PEER:$GDS" gp_ -d1
check "G3 age over ssh: exit 0" "0" "$RC"
check "G3 age over ssh: snapshots younger than the threshold are kept" "2" "$(r_snaps "$GDS")"

del -R "$PEER:$GDS" gp_ -H1
check "G4 -R over ssh: exit 0" "0" "$RC"
check "G4 -R over ssh: the parent kept one" "1" "$(r_snaps "$GDS")"
check "G4 -R over ssh: the child was pruned to one as well" "1" "$(r_snaps "$GDS/child")"

# The in-flight hold, recognised across the link: delsnaps.sh duplicates the
# lib's tag (hold-tag contract) and must report the refusal as by-design rather
# than as an error needing -F.
GHELD="$(r_newest "$GDS")"
rz hold zfssnapall_inflight "$GDS@$GHELD" >/dev/null 2>&1
del "$PEER:$GDS" gp_ -H0
check "G5 held snapshot over ssh: exit 0 (a skip is not an error)" "0" "$RC"
check "G5 held snapshot over ssh: named as in-flight" "1" "$(outgrep 'in-flight')"
check "G5 held snapshot over ssh: still there" "1" "$(r_snaps "$GDS")"
rz release zfssnapall_inflight "$GDS@$GHELD" >/dev/null 2>&1

# -B over ssh. A bookmark's age is its creation time, so "keep" is provable with
# a day's threshold and "prune" with a zero one; no clock faking needed.
GBK="$RROOT/gbook"
rz create -o canmount=noauto "$GBK" >/dev/null 2>&1
rz snapshot "$GBK@gb_1"             >/dev/null 2>&1
rz bookmark "$GBK@gb_1" "$GBK#tgt-deadbeef" >/dev/null 2>&1
check "G6 seeding: one bookmark on the peer" "1" \
      "$($SSH "$PEER" "zfs list -H -o name -t bookmark -d 1 '$GBK' 2>/dev/null | wc -l" 2>/dev/null)"

del -B "$PEER:$GBK" tgt- -d1
check "G6 -B over ssh: exit 0" "0" "$RC"
check "G6 -B over ssh: a fresh bookmark is kept" "1" \
      "$($SSH "$PEER" "zfs list -H -o name -t bookmark -d 1 '$GBK' 2>/dev/null | wc -l" 2>/dev/null)"

del -B "$PEER:$GBK" tgt- -h0
check "G7 -B over ssh: exit 0" "0" "$RC"
check "G7 -B over ssh: past the threshold it is destroyed" "0" \
      "$($SSH "$PEER" "zfs list -H -o name -t bookmark -d 1 '$GBK' 2>/dev/null | wc -l" 2>/dev/null)"
check "G7 -B over ssh: the snapshot it pointed at is untouched" "1" "$(r_snaps "$GBK")"

# An unreachable peer must FAIL the prune, not report success with nothing to do.
# This is the case that used to pass for the worst possible reason: the listing
# came back empty, "No snapshots found" was printed, status=success was logged and
# the exit code was 0 -- so retention could stop happening on a target for weeks
# without a single alert. It doubles as the -p passthrough check: if -p were
# dropped, this would reach port 22 and prune for real.
del -p 65000 "$PEER:$GDS" gp_ -H0
check "G8 unreachable peer: refused" "nonzero" "$(rcword)"
check "G8 unreachable peer: said it could not list, not 'nothing to prune'" "1" \
      "$(outgrep 'could not list snapshots')"
check "G8 unreachable peer: destroyed nothing" "1" "$(r_snaps "$GDS")"

del -R -p 65000 "$PEER:$GDS" gp_ -H0
check "G9 unreachable peer under -R: refused" "nonzero" "$(rcword)"
check "G9 unreachable peer under -R: destroyed nothing" "1" "$(r_snaps "$GDS")"

# Same distinction locally: a dataset that is simply gone (renamed, destroyed,
# a typo in the config) is a failure, not an empty prune.
del "$LROOT/definitely_not_here" gp_ -H1
check "G10 missing local dataset: refused" "nonzero" "$(rcword)"
check "G10 missing local dataset: named as a listing failure" "1" \
      "$(outgrep 'could not list snapshots')"

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

# Sockets are per run and closed on the way out; a leftover means a master is
# still holding a connection open. Checked here as well as in F7 because every
# section after F7 opens its own -- delsnaps.sh included, which is the one that
# relies on ssh unlinking the socket itself (it hands the %h template back to ssh
# rather than guessing the expanded filename), hence the tick first.
tick
check "E6 no ControlMaster socket survived the campaign" "0" \
      "$(ls "$ZFS_SNAP_CACHE_DIR" 2>/dev/null | grep -c '^cm')"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
