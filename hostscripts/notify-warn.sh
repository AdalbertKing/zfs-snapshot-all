#!/bin/bash
# notify-warn.sh v8 -- reports a WARNING-tier monitor finding ("getting stale",
# past monitor_warn but not yet monitor_crit).
#
# Same queue and same line format as notify-fail.sh, differing only in the
# severity column -- that is what lets one digest cover both tiers in one mail.
# Controlled by ZFS_WARN_MODE in /root/scripts/zfs-alert.conf, separately from
# ZFS_ALERT_MODE: daily (default) or immediate. Leave it on daily unless you
# have a specific reason -- warnings are by definition the findings that are not
# urgent, so mailing them on sight is the fastest way to train someone to ignore
# the mailbox.
# Usage in cron:
#   ... ; [ $rc -eq 1 ] && /root/scripts/notify-warn.sh "label" "$verdict"
# The second argument is check-snap-age.sh's own verdict line -- dataset,
# pattern, newest snapshot, actual age, thresholds. See notify-fail.sh for why a
# label alone is not enough to act on.
JOB="$1"
DETAIL="${2:-}"
# Config file and env precedence live in alert-env.sh, installed beside this
# script by deploy.sh (root's /root/scripts, an account's $HOME): one copy in
# the repository, sourced here. Loud when absent: a run that cannot find its
# precedence rule would silently read the production queue under a test env.
# shellcheck disable=SC1091
. "$(dirname "$0")/alert-env.sh" || { echo "$0: cannot source alert-env.sh next to this script -- re-run deploy.sh" >&2; exit 1; }

QUEUE="${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
if [ "${ZFS_WARN_MODE:-daily}" = "immediate" ]; then
    HOST=$(hostname -f 2>/dev/null || hostname)
    {
        printf "ZFS warning: '%s' na %s o %s.\n" "${JOB}" "${HOST}" "$(date '+%Y-%m-%d %H:%M:%S')"
        [ -n "$DETAIL" ] && { printf '\nCo zglosil monitor:\n\n'; printf '%s\n' "$DETAIL" | sed 's/^/    /'; }
    } | mail -s "[ZFS BACKUP] WARNING: ${JOB} na ${HOST}" "${ZFS_ALERT_EMAIL:-root}"
    exit 0
fi
# See notify-fail.sh: keep a recreated queue writable by BOTH accounts.
umask 0002
DETAIL_FLAT=$(printf '%s' "$DETAIL" | tr '\t' ' ' | tr '\n' '\001')
printf '%s\tWARN\t%s\t%s\n' "$(date +%s)" "$JOB" "$DETAIL_FLAT" >> "$QUEUE"
