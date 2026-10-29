#!/bin/bash
# Exact-blob negative control for REV-20261029-183. Uses only a stub zfs.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-3dc6e1ae4d69daacd916805aeba6a06349e2832b}"

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

work="$(mktemp -d)" || exit 2
uid="$(id -u)"
cache="/tmp/zfs-snapshot-all-jobstats-snaps.$uid"
trap 'if [ -L "$cache" ] && [ "$(readlink "$cache")" = "$work/target" ]; then rm -f -- "$cache"; fi; rm -rf -- "$work"' EXIT

if [ -e "$cache" ] || [ -L "$cache" ]; then
    echo "ERROR: refusing to disturb existing cache path $cache" >&2
    exit 2
fi

mkdir -p "$work/bin" "$work/tree" || exit 2
git -C "$TARGET_REPO" archive "$TARGET_SHA" | tar -x -C "$work/tree" || exit 2
printf '%s\n' SENTINEL > "$work/target"

cat > "$work/bin/zfs" <<'STUB'
#!/bin/sh
printf 'tank/a@automated_hourly_2026-10-29_07-00-00\t4096\t1793257200\n'
STUB
chmod +x "$work/bin/zfs"

set +e
bash -c '
    tmp="/tmp/zfs-snapshot-all-jobstats-snaps.$(id -u).$$"
    ln -s "$1" "$tmp" || exit 2
    exec env PATH="$2/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$2/missing" \
        ZFS_CRON_LOGS="$2/missing.log" bash "$2/tree/zfs-backup.sh" \
        job-stats --json --vol-cache=300
' _ "$work/target" "$work" > "$work/out" 2> "$work/err"
rc=$?
set -e

after="$(head -c 200 "$work/target" 2>/dev/null)"
cache_link=no
[ -L "$cache" ] && [ "$(readlink "$cache")" = "$work/target" ] && cache_link=yes
printf 'sha=%s job_stats_rc=%s cache_is_target_symlink=%s\n' "$TARGET_SHA" "$rc" "$cache_link"
printf 'target_after=%s\n' "$after"

if [ "$after" != SENTINEL ] || [ "$cache_link" = yes ]; then
    echo 'FAIL: job-stats cache followed an attacker-controlled /tmp symlink'
    exit 1
fi

echo 'PASS: hostile cache symlink was not followed and target stayed unchanged'
