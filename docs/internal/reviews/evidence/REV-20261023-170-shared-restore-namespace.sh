#!/usr/bin/env bash
# Safe reproducer: disposable records plus a stateful fake ZFS permission set.
# No live ZFS, network, accounts, cron, or installed paths are touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEPLOY="${DEPLOY:-$ROOT/deploy.sh}"
LAB="$(mktemp -d)"
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/bin" "$LAB/relationships/one" "$LAB/relationships/two" \
    "$LAB/peers" "$LAB/grants" "$LAB/clients" "$LAB/state" "$LAB/caps"

# Two relationships to the same peer normally share its zfsbackup-<peer>
# account.  Their scopes are disjoint but lie on the same pool.
printf '%s\n' 'PEER_JOIN_ACCOUNT="backup-shared"' \
    'PEER_JOIN_GRANTED_DATASETS="tank/a"' > "$LAB/peers/one.conf"
printf '%s\n' 'PEER_JOIN_ACCOUNT="backup-shared"' \
    'PEER_JOIN_GRANTED_DATASETS="tank/b"' > "$LAB/peers/two.conf"

cat > "$LAB/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "$LAB/bin/zfs" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ZFS_TRACE"
case "$1" in
    list) exit 0 ;;
    get) echo no; exit 0 ;;
    create|mount) exit 0 ;;
    allow|unallow)
        key="$(printf '%s|%s|%s' "$3" "$4" "$6" | tr / % )"
        [ "$1" = allow ] && : > "$ZFS_CAPS/$key" || rm -f "$ZFS_CAPS/$key"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$LAB/bin/id" "$LAB/bin/zfs"
export ZFS_TRACE="$LAB/trace" ZFS_CAPS="$LAB/caps"

run() {
    PATH="$LAB/bin:$PATH" PAIR_GATE_STATE_DIR="$LAB/relationships" \
        PEER_STATE_DIR="$LAB/peers" RESTORE_GRANT_DIR="$LAB/grants" \
        CLIENTS_DIR="$LAB/clients" RELATIONSHIPS_DIR="$LAB/state" \
        bash "$DEPLOY" "$@" >/dev/null 2>&1
}
cap="$LAB/caps/backup-shared|receive,rollback,create,canmount,mountpoint,mount|tank%restore"
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL %s: want [%s], got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

run --allow-restore=one; rc1=$?
run --allow-restore=two; rc2=$?
check 'both grants are issued' '0|0' "$rc1|$rc2"
check 'their shared namespace capability exists' yes "$([ -e "$cap" ] && echo yes || echo no)"

run --deny-restore=one; rcd=$?
check 'revoking the first grant reports success' 0 "$rcd"
check 'the second grant file is still active' yes "$([ -f "$LAB/grants/two" ] && echo yes || echo no)"
check 'but its shared namespace capability is gone (reproduced)' no \
    "$([ -e "$cap" ] && echo yes || echo no)"

printf '%s\n' '--- namespace command trace ---'
grep -- 'tank/restore' "$ZFS_TRACE"
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
