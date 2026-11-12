#!/bin/bash
# REV-20261112-196 live evidence: snapget -M on an isolated FILE-BACKED pool on pve9 (lab),
# the exact candidate engine from a fresh clone at $REF. A source snapshot renamed (same GUID)
# must keep its copy on the target; a snapshot really destroyed on the source must go.
# No production pool. Everything created here is destroyed at the end.
set -u
REF="${1:?ref}"
D=/tmp/r196live; IMG=/root/r196live; POOL=r196tgt
SRC=hdd/lab/r196src; DST=$POOL/rep; T=$DST/$SRC
rm -rf "$D"; git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git "$D" && cd "$D" && git checkout -q "$REF" || exit 9
echo "== identity: $(git rev-parse HEAD)  host $(hostname)  $(date '+%F %T')"
sha256sum snapget.sh lib-zfs-snap.sh lib-backup-common.sh
zfs version | head -1
gl() { echo "-- $1"; zfs list -H -t snapshot -o name,guid -s createtxg -d 1 "$1" 2>&1 | sed 's/^/   /'; }
both() { gl $SRC; gl $T; }
eng() {   # <label> <snapget options...>
    local l="$1"; shift
    echo "-- engine ($l): snapget.sh $* $SRC $DST"
    ./snapget.sh -v 3 "$@" "$SRC" "$DST" 2>&1 | grep -E 'SEND CMD|common snapshot|Mirror|kept|already|All datasets|ERROR|rror'
    echo "engine rc=${PIPESTATUS[0]}"
}
# --- setup
zpool destroy $POOL 2>/dev/null; zfs destroy -r $SRC 2>/dev/null; rm -rf $IMG
mkdir -p $IMG && truncate -s 1G $IMG/t.img && zpool create -o failmode=continue $POOL $IMG/t.img || exit 8
zfs create -p $SRC && dd if=/dev/urandom of=/$SRC/f1 bs=64k count=8 status=none
echo; echo "===== 1. two runs: the target holds two snapshots"
eng first -m replica_ -M; sleep 1
dd if=/dev/urandom of=/$SRC/f2 bs=64k count=4 status=none
eng second -m replica_ -M
both
old=$(zfs list -H -t snapshot -o name -s createtxg -d 1 $SRC | head -1 | sed 's/.*@//')
mid=$(zfs list -H -t snapshot -o name -s createtxg -d 1 $SRC | sed -n 2p | sed 's/.*@//')
sum_src=$(md5sum < /$SRC/.zfs/snapshot/$old/f1 | cut -c1-32)
echo "oldest: @$old (f1 md5 $sum_src)  second: @$mid"

echo; echo "===== 2. the OLDEST snapshot renamed on the source (same GUID), new work, -m -M"
zfs rename $SRC@$old $SRC@replica_renamed && echo "source: @$old -> @replica_renamed"
dd if=/dev/urandom of=/$SRC/f3 bs=64k count=2 status=none
both
eng third -m replica_ -M
both
echo "-- is the target's @$old a usable recovery point? clone it and read f1"
zfs clone $T@$old $POOL/r196chk && sum_tgt=$(md5sum < /$POOL/r196chk/f1 | cut -c1-32) && zfs destroy $POOL/r196chk
echo "target @$old f1 md5 ${sum_tgt:-NONE}  source @replica_renamed f1 md5 $sum_src  -> $([ "${sum_tgt:-}" = "$sum_src" ] && echo SAME || echo DIFFERENT)"

echo; echo "===== 3. no new work: -e -M (existing snapshots only)"
eng no-new-work -e -M
both

echo; echo "===== 4. a snapshot renamed on the TARGET (same GUID as the source's @$mid), -e -M"
zfs rename $T@$mid $T@${mid}_t && echo "target: @$mid -> @${mid}_t"
eng target-rename -e -M
both

echo; echo "===== 5. control: @$mid really destroyed on the source -- the mirror must remove its copy"
zfs destroy $SRC@$mid && echo "source: destroyed @$mid"
dd if=/dev/urandom of=/$SRC/f4 bs=64k count=1 status=none
eng true-deletion -m replica_ -M
both
# --- cleanup
zpool destroy $POOL; rm -rf $IMG; zfs destroy -r $SRC; rm -rf "$D"; echo "cleaned"
