#!/bin/bash
# Safe reproducer for REV-20261023-169. It intentionally supplies one temporary
# CLIENTS_DIR so the current suite exposes its cross-case record leak without
# ever falling back to /etc/zfs-snapshot-all.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLIENT_FIXTURE="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$CLIENT_FIXTURE" "$OUT"' EXIT

set +e
CLIENTS_DIR="$CLIENT_FIXTURE" bash "$REPO/test/localbackup/run.sh" >"$OUT" 2>&1
rc=$?
set -e

pass=0
fail=0
ok()  { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

[ "$rc" -ne 0 ] && ok "current suite returns nonzero" || bad "current suite returns nonzero"
grep -q '^PASS=156 FAIL=5$' "$OUT" \
    && ok "exact failure signature is 156 PASS / 5 FAIL" \
    || bad "exact failure signature is 156 PASS / 5 FAIL"
[ -f "$CLIENT_FIXTURE/lb.conf" ] \
    && ok "one-shot cases leaked the lb relationship record into their shared directory" \
    || bad "one-shot cases leaked the lb relationship record into their shared directory"
printf '%s\n' '--------------------------------------------'
printf 'PASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
