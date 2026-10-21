#!/bin/bash
# Reviewer reproduction for REV-20261021-155.
# Uses the shipped capacity guard with fake zpool/zfs commands only. No pool,
# snapshot, cron entry, host or network is touched.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cron" "$T/peers"
cp "$REPO/hostscripts/capacity-guard.sh" "$T/guard.sh"
cp "$REPO/hostscripts/alert-env.sh" "$T/alert-env.sh"

printf '%s\n' '#!/bin/bash' \
  'case "$*" in' \
  '  "list -H -o name") echo tank ;;' \
  '  "list -H -o capacity tank") echo "$(cat "$PROBE/cap")%" ;;' \
  '  "sync tank") [ "${FAIL_SYNC:-0}" -eq 0 ] ;;' \
  'esac' > "$T/bin/zpool"
printf '%s\n' '#!/bin/bash' \
  'case "$*" in' \
  '  *"-t snapshot"*) cat "$PROBE/snaps" ;;' \
  '  *"-t bookmark"*) : ;;' \
  '  destroy*) echo "$2" >> "$PROBE/destroyed"; n=$(cat "$PROBE/cap"); echo $((n-1)) > "$PROBE/cap" ;;' \
  'esac' > "$T/bin/zfs"
printf '%s\n' '#!/bin/bash' 'printf "%s\n%s\n" "$1" "$2" >> "$PROBE/mail"' > "$T/bin/notify"
chmod +x "$T/bin/"* "$T/guard.sh"

printf '%s\n' \
  '# BEGIN zfs-backup-managed' \
  '1 * * * * /r/delsnaps.sh "tank/a" "automated_hourly_" -H24' \
  '# END zfs-backup-managed' > "$T/cron/root"
printf '%s\n' \
  $'tank/a@automated_hourly_1\t100\t0\t1001' \
  $'tank/a@automated_hourly_2\t200\t0\t1002' \
  $'tank/a@automated_hourly_3\t300\t0\t1003' \
  $'tank/a@automated_hourly_4\t400\t0\t1004' > "$T/snaps"
printf '[capacity]\nguard = on\nguard_at = 89\nguard_target = 85\nguard_min_keep = 1\n' > "$T/settings.ini"

run_guard() { # name enabled at target fail-sync
    local name="$1" enabled="$2" at="$3" target="$4" fail_sync="$5"
    rm -f "$T/destroyed" "$T/mail"
    echo 99 > "$T/cap"
    set +e
    PROBE="$T" PATH="$T/bin:$PATH" SETTINGS_FILE="$T/settings.ini" \
      ZFS_ALERT_CONF=/dev/null ZFS_GUARD_CRONTABS="$T/cron" ZFS_GUARD_PEERS="$T/peers" \
      ZFS_NOTIFY_SCRIPT="$T/bin/notify" ZFS_GUARD_LOCK="$T/lock-$name" \
      ZFS_GUARD="$enabled" ZFS_GUARD_AT="$at" ZFS_GUARD_TARGET="$target" \
      ZFS_GUARD_MIN_KEEP=1 FAIL_SYNC="$fail_sync" \
      bash "$T/guard.sh" > "$T/out-$name" 2>&1
    RC=$?
    set -e
    if [ -f "$T/destroyed" ]; then DESTROYS=$(wc -l < "$T/destroyed"); else DESTROYS=0; fi
}

PASS=0
FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1 -- rc=$RC destroys=$DESTROYS"; FAIL=$((FAIL+1)); }

set -e
run_guard off-control off 89 85 0
[ "$RC" -eq 0 ] && [ "$DESTROYS" -eq 0 ] && ok "disabled guard is inert" || bad "disabled guard is inert"

run_guard valid-control on 99 97 0
[ "$RC" -eq 0 ] && [ "$DESTROYS" -eq 3 ] && ok "valid thresholds exercise the destructive harness" || bad "valid thresholds exercise the destructive harness"

run_guard invalid-zero on 0 0 0
if [ "$RC" -ne 0 ] && [ "$DESTROYS" -eq 0 ] && grep -qi 'próg\|threshold\|ustaw' "$T/mail"; then
    ok "out-of-contract thresholds fail before zfs destroy"
else
    bad "out-of-contract thresholds fail before zfs destroy"
fi

run_guard sync-fails on 99 85 1
if [ "$RC" -ne 0 ] && [ "$DESTROYS" -le 1 ] && grep -qi 'sync' "$T/mail"; then
    ok "failed zpool sync stops the destructive loop and is reported"
else
    bad "failed zpool sync stops the destructive loop and is reported"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
