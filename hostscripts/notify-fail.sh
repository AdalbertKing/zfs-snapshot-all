#!/bin/bash
# notify-fail.sh v10 -- reports an ALERT-tier finding: a cron job that returned
# non-zero, a CRITICAL/UNKNOWN staleness result, or a DEGRADED/FAULTED pool.
#
# WHETHER IT MAILS NOW OR WAITS FOR THE DAILY DIGEST IS CONFIGURED, NOT BAKED IN.
# Set ZFS_ALERT_MODE in /root/scripts/zfs-alert.conf:
#   daily      (default) queue it; alert-digest.sh sends one mail a day
#   immediate  mail it right now, rate-limited per message via
#              ZFS_ALERT_COOLDOWN. Recommended while bringing a host up.
# A finding is reported through exactly one of the two paths, never both.
#
# Why daily is the default: the immediate path's cooldown is keyed on the
# MESSAGE, so every distinct finding keeps its own counter and two jobs failing
# in the same cron tick send two mails in the same second. Volume then scales
# with the number of distinct findings rather than with hosts, and an operator
# who filters that away is worse off than one who reads a single daily summary.
#
# Either way Proxmox's own ZED pool-health mail is untouched, so a disk actually
# dropping out still pages immediately through that separate path.
# Usage in cron:
#   ... || /root/scripts/notify-fail.sh "job description" "what it actually said"
#
# The SECOND argument is the finding itself: the failing command's own output, or
# check-snap-age.sh's verdict line carrying the real dataset, age and thresholds.
# Without it the digest can only report that something called "pve0 hourly backup
# (vm-101)" went wrong -- a label from the config, nothing anyone can act on --
# while the actual text went to cron.log where nobody reads it. Optional, so cron
# lines generated before v4.16 keep working unchanged.
JOB="$1"
DETAIL="${2:-}"
# Config file and env precedence live in alert-env.sh, installed beside this
# script by deploy.sh (root's /root/scripts, an account's $HOME): one copy in
# the repository, sourced here. Loud when absent: a run that cannot find its
# precedence rule would silently read the production queue under a test env.
# shellcheck disable=SC1091
. "$(dirname "$0")/alert-env.sh" || { echo "$0: cannot source alert-env.sh next to this script -- re-run deploy.sh" >&2; exit 1; }

MODE="${ZFS_ALERT_MODE:-daily}"
QUEUE="${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
# The address comes from zfs-alert.conf (ZFS_ALERT_EMAIL, written there by
# deploy.sh since the conf exists); root is the fallback for a host whose conf
# is gone, so the finding lands in a local mailbox rather than nowhere.
EMAIL="${ZFS_ALERT_EMAIL:-root}"

if [ "$MODE" != "immediate" ]; then
    # One line per finding: epoch, severity, text. Short single-line appends to
    # the same file from concurrent cron jobs do not interleave (under PIPE_BUF).
    # 0002, so that if THIS process is the one that recreates the queue after
    # the digest consumed it, the file lands group-writable. Both root and the
    # delegated account append here; whichever gets there first would otherwise
    # create it 0644 and lock the other one out until the next digest run.
    umask 0002
    # Four tab-separated columns now: epoch, severity, label, detail. A finding
    # has to stay ONE line -- concurrent appends from separate cron jobs are only
    # atomic while each write is a single short line (PIPE_BUF) -- so the detail
    # is flattened: tabs to spaces so the field split survives, newlines to \001,
    # which alert-digest.sh turns back into newlines. A control byte rather than
    # a backslash escape, because nothing in a ZFS error message can collide
    # with it and there is no un-escaping to get wrong.
    DETAIL_FLAT=$(printf '%s' "$DETAIL" | tr '\t' ' ' | tr '\n' '\001')
    printf '%s\tALERT\t%s\t%s\n' "$(date +%s)" "$JOB" "$DETAIL_FLAT" >> "$QUEUE"
    exit 0
fi

HOST=$(hostname -f 2>/dev/null || hostname)
NOW=$(date '+%Y-%m-%d %H:%M:%S')
NOW_EPOCH=$(date +%s)
STATE_DIR="${ZFS_ALERT_STATE_DIR:-/var/lib/zfs-snapshot-all/notify-state}"
COOLDOWN="${ZFS_ALERT_COOLDOWN:-14400}"
mkdir -p "$STATE_DIR"

KEY=$(printf '%s' "$JOB" | md5sum | cut -d' ' -f1)
LASTFILE="$STATE_DIR/$KEY"
if [ -f "$LASTFILE" ] && [ $(( NOW_EPOCH - $(cat "$LASTFILE") )) -lt "$COOLDOWN" ]; then
    # stderr, so the cron line's own 2>>cron.log swallows it. Unredirected, this
    # single line was itself a cron mail on every tick -- 96/day per monitor.
    echo "notify-fail.sh: suppressed repeat within cooldown -- ${JOB}" >&2
    exit 0
fi
echo "$NOW_EPOCH" > "$LASTFILE"

{
    printf "ZFS alert: '%s' na %s o %s.\n" "${JOB}" "${HOST}" "${NOW}"
    if [ -n "$DETAIL" ]; then
        printf '\nCo zglosilo zadanie:\n\n'
        printf '%s\n' "$DETAIL" | sed 's/^/    /'
    fi
    printf '\nPelny log: /root/scripts/cron.log na %s\n' "${HOST}"
} | mail -s "[ZFS BACKUP] ALERT: ${JOB} na ${HOST}" "$EMAIL"
