#!/bin/bash
# REV-20261112-194 mediagate-live (Reviewer round 2): an isolated FILE-BACKED pool on pve9
# (lab), the exact candidate gate and engine from a fresh clone at $REF. No production pool,
# no physical unplug. Everything created here is destroyed at the end.
set -u
REF="${1:?ref}"
D=/tmp/r194live2; ST=/tmp/r194live2-state; IMG=/root/r194live2; POOL=r194med
SRC=hdd/lab/r194src; DST=$POOL/rep; T=$DST/$SRC
rm -rf "$D" "$ST"; git clone -q https://github.com/AdalbertKing/zfs-snapshot-all.git "$D" && cd "$D" && git checkout -q "$REF" || exit 9
echo "== identity: $(git rev-parse HEAD)  host $(hostname)  $(date '+%F %T')"
sha256sum zfs-media-gate.sh snapget.sh lib-zfs-snap.sh lib-backup-common.sh
zfs version | head -1
export MEDIA_STATE_DIR="$ST"
gl() { echo "-- $*"; zfs list -H -t snapshot,bookmark -o name,guid -r "$@" 2>&1 | sed 's/^/   /'; }
attach() { ./zfs-media-gate.sh attach $POOL r194 --dataset $DST --dir $IMG --source $SRC --prefix replica_; }
detach() { ./zfs-media-gate.sh detach $POOL r194 --dir $IMG --source $SRC --prefix replica_ --engine-rc "$1"; }
bracket() {   # the generated cron bracket, by hand
    zpool import -d $IMG $POOL 2>/dev/null && { echo "medium BEFORE the run:"; zfs list -H -t snapshot -o name,guid -r $DST 2>/dev/null | sed "s/^/   /"; zpool export $POOL; }
    attach; a=$?; echo "attach rc=$a"
    if [ $a -eq 0 ]; then ./snapget.sh -v 3 -m replica_ -M "$SRC" "$DST" 2>&1 | grep -E "SEND CMD|bookmark still anchors|common snapshot|Incremental|All datasets|ERROR|rror"; m=${PIPESTATUS[0]}; echo "engine rc=$m"
    elif [ $a -eq 1 ]; then m=0; else m=$a; fi
    detach $m; echo "detach rc=$?"
    zpool list -H -o name $POOL >/dev/null 2>&1 && echo "pool after bracket: IMPORTED" || echo "pool after bracket: exported"
}
# --- setup
zpool export $POOL 2>/dev/null; zfs destroy -r $SRC 2>/dev/null; rm -rf $IMG
mkdir -p $IMG && truncate -s 1G $IMG/m.img && zpool create -o failmode=continue $POOL $IMG/m.img && zfs create $DST && zpool export $POOL || exit 8
zfs create -p $SRC && dd if=/dev/urandom of=/$SRC/f1 bs=64k count=8 status=none
echo; echo "===== 1. first copy onto the exported medium"
bracket
echo; echo "===== 2. return after retention: the snapshot the medium holds is gone on the source, its bookmark stays"
held=$(zpool import -d $IMG $POOL && zfs list -H -t snapshot -o name -s createtxg $T | tail -1 | sed 's/.*@//'; zpool export $POOL)
echo "medium holds: @$held"
dd if=/dev/urandom of=/$SRC/f2 bs=64k count=4 status=none; zfs snapshot $SRC@replica_collector2
zfs destroy $SRC@$held && echo "source: destroyed @$held (retention)"
gl $SRC
bracket
zpool import -d $IMG $POOL; gl $T; zpool export $POOL
echo; echo "===== 3. F2: the medium's newest snapshot RENAMED on the source (same GUID, other name)"
zpool import -d $IMG $POOL; held=$(zfs list -H -t snapshot -o name -s createtxg $T | tail -1 | sed 's/.*@//'); zpool export $POOL
zfs rename $SRC@$held $SRC@replica_renamed && echo "source: @$held -> @replica_renamed"
gl $SRC
dd if=/dev/urandom of=/$SRC/f3 bs=64k count=2 status=none
bracket
zpool import -d $IMG $POOL; gl $T; zpool export $POOL
echo; echo "===== 4. control: NO common GUID (source rebuilt) -- refused, and an OPERATOR's import stays imported"
zfs destroy -r $SRC && zfs create -p $SRC && zfs snapshot $SRC@replica_newfamily
zpool import -d $IMG $POOL && echo "operator imported $POOL by hand"
attach; echo "attach rc=$?"
zpool list -H -o name $POOL >/dev/null 2>&1 && echo "pool after refusal: STILL IMPORTED (operator's)" || echo "pool after refusal: exported"
detach 2; echo "detach rc=$?"
zpool list -H -o name $POOL >/dev/null 2>&1 && echo "pool after detach: STILL IMPORTED (operator's)" || echo "pool after detach: exported"
# --- cleanup
zpool destroy $POOL; rm -rf $IMG; zfs destroy -r $SRC; rm -rf "$D" "$ST"; echo "cleaned"
