#!/bin/bash
# release/publish-via-pve9.sh -- publish a release: pve9 builds it, this PC pushes it.
#
#   release/publish-via-pve9.sh [<dev-ref>] [--dry-run] [--no-lab]
#
#   <dev-ref>   default origin/main (fetched first); resolved here to a full SHA
#   --dry-run   build and check on pve9, fetch the commit here, do not push
#   --no-lab    do not self-update the lab hosts after the push
#
# Why (WORKFLOW W11, 2026-11-13): publish.sh's gates take 10+ minutes on Windows and seconds on
# pve9, but only this PC holds the GitHub credentials and the private name list. So:
#   1. pve9: a dev checkout at <dev-sha> runs release/publish-stage.sh, which runs publish.sh
#      --push with every gate; its push goes to a bare repository on pve9, not to GitHub. The
#      name list is sent on stdin and deleted there on exit.
#   2. here: the staged commit comes back as a git bundle; it must be exactly one commit on top
#      of the release repository's current main, with RELEASE-OF = <dev-sha>; then a plain
#      `git push` (never --force).
#   3. lab hosts self-update at once; production follows its update cron (W11.3).
#
# Needs: plink/pscp with the lab key (Pageant), ZFS_NAME_DENYLIST or the default path below.
set -euo pipefail
die() { echo "publish-via-pve9: $*" >&2; exit 1; }
HOST="${PUBLISH_HOST:-192.168.28.99}"
DEV_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
REL_URL="https://github.com/AdalbertKing/zfsbackup.git"
DL="${ZFS_NAME_DENYLIST:-/d/projekty/zfs-cron-configs/release-name-denylist.txt}"
LAB_HOSTS="${PUBLISH_LAB_HOSTS:-192.168.28.98 192.168.28.96 192.168.28.97}"
STAGE=/root/relstage

ref="origin/main" dry=0 lab=1
for a in "$@"; do
    case "$a" in
        --dry-run) dry=1 ;;
        --no-lab) lab=0 ;;
        -*) die "unknown option '$a'" ;;
        *) ref="$a" ;;
    esac
done
[ -r "$DL" ] && grep -qvE '^[[:space:]]*(#|$)' "$DL" || die "the private name list '$DL' is missing or empty"
repo="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$repo" fetch -q origin main
rev=$(git -C "$repo" rev-parse --verify "$ref^{commit}") || die "'$ref' is not a commit"
# A dry run may try a branch head (nothing is pushed); a real release comes from main.
[ "$dry" -eq 1 ] || git -C "$repo" merge-base --is-ancestor "$rev" origin/main \
    || die "$rev is not on origin/main -- a release comes from main"
t0=$(date +%s)
pl() { MSYS_NO_PATHCONV=1 plink -batch "root@$HOST" "$@"; }

echo "== 1/3 pve9 ($HOST): build ${rev:0:12} with every gate"
remote="set -e; d=$STAGE/dev; mkdir -p $STAGE
[ -d \$d/.git ] || git clone -q $DEV_URL \$d
git -C \$d fetch -q origin
git -C \$d checkout -q --detach $rev
bash \$d/release/publish-stage.sh $rev $STAGE"
out=$(pl "$remote" < "$DL") || die "the pve9 stage failed (its output is above)"
line=$(printf '%s\n' "$out" | grep '^STAGED ' | tail -n 1)
[ -n "$line" ] || die "pve9 did not report a staged commit"
read -r _ relsha base <<<"$line"
echo "   staged $relsha on top of $base ($(( $(date +%s) - t0 )) s)"

echo "== 2/3 here: fetch, check, push"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
lb="$tmp/out.bundle"; command -v cygpath >/dev/null && lb=$(cygpath -w "$lb")   # pscp is a Windows program
MSYS_NO_PATHCONV=1 pscp -batch -q "root@$HOST:$STAGE/out.bundle" "$lb" || die "cannot copy the bundle from pve9"
git clone -q "$REL_URL" "$tmp/rel"
cur=$(git -C "$tmp/rel" rev-parse HEAD)
[ "$cur" = "$base" ] || die "the release repository moved since pve9 built on it ($base -> $cur); run again"
git -C "$tmp/rel" fetch -q "$tmp/out.bundle" "refs/heads/main:refs/heads/staged"
[ "$(git -C "$tmp/rel" rev-parse staged)" = "$relsha" ] || die "the bundle does not hold $relsha"
[ "$(git -C "$tmp/rel" rev-parse staged^)" = "$base" ] || die "$relsha is not one commit on top of $base"
[ "$(git -C "$tmp/rel" show staged:RELEASE-OF | head -n 1)" = "$rev" ] || die "RELEASE-OF of $relsha is not $rev"
git -C "$tmp/rel" log -1 --format='   %h %s' staged
if [ "$dry" -eq 1 ]; then
    echo "   --dry-run: not pushed"
    exit 0
fi
git -C "$tmp/rel" push -q origin staged:main
[ "$(git ls-remote "$REL_URL" refs/heads/main | cut -f1)" = "$relsha" ] || die "after the push the release repository's main is not $relsha"
echo "   pushed: zfsbackup main = ${relsha:0:7} ($(( $(date +%s) - t0 )) s)"

[ "$lab" -eq 1 ] || exit 0
echo "== 3/3 lab hosts: self-update now (production: its update cron)"
for h in $LAB_HOSTS; do
    v=$(MSYS_NO_PATHCONV=1 timeout 120 plink -batch "root@$h" \
        '/root/.zfs-snapshot-all-update-state/update-control.sh --self-update >/dev/null 2>&1; for d in /root/zfs-snapshot-all /root/scripts/zfs-snapshot-all; do [ -d $d/.git ] && { echo "root:$(git -C $d log -1 --format=%h)"; break; }; done; id zfsbackup >/dev/null 2>&1 && echo "account:$(su -s /bin/sh zfsbackup -c "cd ~/zfs-snapshot-all && git pull -q --ff-only origin main && git log -1 --format=%h" 2>&1)"' 2>&1 | tr '\n' ' ') || true
    echo "   $h: ${v:-unreachable}"
done
