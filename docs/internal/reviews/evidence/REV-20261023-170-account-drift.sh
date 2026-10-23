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

write_manifest() {
    printf 'PEER_JOIN_ACCOUNT="%s"\nPEER_JOIN_GRANTED_DATASETS="%s"\n' "$2" "$3" \
        > "$LAB/peers/$1.conf"
}
write_manifest one backup-one tank/a
write_manifest two backup-two tank/b

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
nsperms=receive,rollback,create,canmount,mountpoint,mount
cap() { [ -e "$LAB/caps/$1|$nsperms|tank%restore" ] && echo yes || echo no; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL %s: want [%s], got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

run --allow-restore=one; rc1=$?
run --allow-restore=two; rc2=$?
check 'both different-account grants are issued' '0|0' "$rc1|$rc2"
check 'both namespace tuples exist' 'yes|yes' "$(cap backup-one)|$(cap backup-two)"
check 'grant one records its original account' backup-one \
    "$(sed -n 's/^RESTORE_GRANT_ACCOUNT="\(.*\)"$/\1/p' "$LAB/grants/one")"

# Simulate the pairing manifest being re-imported/rejoined under another account.
# The immutable grant record still says backup-one and must win.
write_manifest one backup-two tank/a
: > "$ZFS_TRACE"
run --deny-restore=one; rcd=$?
check 'deny reports success' 0 "$rcd"
check 'the original account namespace is actually revoked' no "$(cap backup-one)"
check 'the other active account namespace remains' yes "$(cap backup-two)"

printf '%s\n' '--- revocation trace after manifest account drift ---'
cat "$ZFS_TRACE"
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
