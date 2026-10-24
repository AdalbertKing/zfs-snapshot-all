#!/usr/bin/env bash
set -u

ZFSBACKUP="${1:-./zfs-backup.sh}"
ZFSBACKUP="$(cd "$(dirname "$ZFSBACKUP")" && pwd)/$(basename "$ZFSBACKUP")"
work=$(mktemp -d "${TMPDIR:-/tmp}/rev174.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
: > "$work/config"

prefix='21 * * * * /root/x/zfs-job.sh "h p prune (r-a)" --log=/root/cron.log -- /root/x/delsnaps.sh -L r'

write_block() { # <path> <command tail>
    {
        echo '# BEGIN zfs-backup-managed'
        printf '%s %s\n' "$prefix" "$2"
        echo '# END zfs-backup-managed'
    } > "$1"
}

write_block "$work/old.cron" '-P "vzdump:2" "tank/a" "automated_hourly" -H24'
printf '#!/usr/bin/env bash\ncat "%s"\n' "$work/old.cron" > "$work/bin/crontab"
chmod +x "$work/bin/crontab"

guard() { # <proposal> -> rc, diagnostic in $work/out
    local proposal="$1"
    PATH="$work/bin:$PATH" LOCAL_USER=zfsbackup PROPOSAL="$proposal" \
        bash -c '
            source "$1"
            gencron_as_target() { cat "$PROPOSAL"; }
            assert_target_block_not_clobbered "$2"
        ' _ "$ZFSBACKUP" "$work/config" > "$work/out" 2>&1
}

# Negative control: changing only the existing protection is destructive and
# the ordinary guard correctly refuses it.
write_block "$work/plain-change.cron" '-P "vzdump:0" "tank/a" "automated_hourly" -H24'
set +e
guard "$work/plain-change.cron"; plain_rc=$?
set -e

# U4's seventh exception should allow the new empty-pattern carrier and its
# generated protections, but it strips every -P while comparing identities.
# The unrelated, pre-existing vzdump floor can therefore change in the same
# proposal and the guard accepts the job as an ordinary prune_foreign rewrite.
write_block "$work/combined.cron" '-P "automated_daily:all" -P "replica_:2" -P "vzdump:0" "tank/a" "" -H24'
set +e
guard "$work/combined.cron"; combined_rc=$?
set -e
combined_out=$(cat "$work/out")

# Positive control: the intended U4-only transition remains accepted.
write_block "$work/u4-only.cron" '-P "automated_daily:all" -P "replica_:2" -P "vzdump:2" "tank/a" "" -H24'
set +e
guard "$work/u4-only.cron"; u4_rc=$?
set -e

printf 'plain_protection_change_rc=%s\n' "$plain_rc"
printf 'combined_foreign_and_protection_change_rc=%s\n' "$combined_rc"
printf 'u4_only_rc=%s\n' "$u4_rc"
printf 'combined_diagnostic=%s\n' "$(printf '%s' "$combined_out" | tr '\n' ' ')"

if [ "$plain_rc" -ne 0 ] && [ "$combined_rc" -eq 0 ] && [ "$u4_rc" -eq 0 ] \
   && printf '%s' "$combined_out" | grep -q 'foreign snapshots on this landing'; then
    echo 'REPRODUCED: prune_foreign exception hides an unrelated -P protection change'
    exit 0
fi

echo 'NOT REPRODUCED'
exit 1
