#!/bin/bash
# ------------------------------------------------------------------------------
# zfs-job.sh -- the envelope every generated cron line used to carry inline.
#
# WHY IT MOVED OUT OF THE LINE. Measured on pve9, 2026-08-30: the envelope is
# 336 characters and it is repeated in EVERY job, while cron refuses a command
# over 1000 bytes. An ordinary two-relationship host was already at 890 on its
# backup lines and 934 on a one-source replica; a second source on the replica
# reached 1160 and crontab(1) said only "command too long", which reached the
# operator as an install that rolled back for no stated reason.
#
# The first attempt shortened the PATHS instead, by naming them once as crontab
# variables. It bought ~140 bytes and cost something worth more: a line copied
# out of the crontab and run by hand -- which is what an admin does to diagnose
# a job -- stopped working, with `$ZSA_LOG: ambiguous redirect`. Owner's
# judgement, and it is right: the envelope is one third of every line and the
# paths are not the problem.
#
# So the envelope lives here and the line keeps its ENGINE COMMAND in plain
# sight:
#
#     30 2 * * * /path/zfs-job.sh "pve9 replica copy (weekly)" \
#                  --log=/root/scripts/cron.log \
#                  --notify=/root/scripts/notify-fail.sh -- <engine command>
#
# The line is self-contained: copy it, run it, it behaves exactly as cron runs
# it. Nothing is hidden -- what executes is still readable in `crontab -l` --
# and cron2conf.sh can still read the engine call back out of it.
#
# THE CONTRACT THIS PRESERVES, byte for byte in the log:
#
#   ZFS-JOB BEGIN <label>            on entry
#   <the command's stderr>           appended, whatever it was
#   ZFS-JOB END <label> rc=<n>       on exit, with the COMMAND's status
#   the notify script                called only when rc is not 0, with the
#                                    label and the last N lines of stderr
#
# AND IT EXITS 0 REGARDLESS. That is deliberate and is not laziness: the inline
# envelope ended in `rm -f "$e"`, so the line always exited 0, and cron mails
# whatever a job writes OR returns non-zero for. Alerting is the notify
# script's job precisely so that cron does not also mail -- exiting with the
# command's status here would add a second, unrate-limited mail per failure,
# which is the flood notify-fail.sh's cooldown exists to prevent.
# ------------------------------------------------------------------------------
set -u

VERSION='v1.0'

usage() {
    cat >&2 <<'EOF'
Usage: zfs-job.sh <label> [--log=FILE] [--notify=SCRIPT] [--detail=N] -- <command>...

  Runs <command>, brackets it with ZFS-JOB BEGIN/END markers in the log, and
  calls the notify script when it fails. Everything after -- is the command and
  is executed as given.

  --log     where the markers and the command's stderr go
            (default: <this script's parent dir>/cron.log)
  --notify  called as: <script> "<label>" "<last N lines of stderr>"
            (default: <this script's parent dir>/notify-fail.sh)
  --detail  how many trailing stderr lines the notification carries (default 8)

  Exits 0 whatever the command returned -- see the header for why. The
  command's own status is recorded in the END marker and is what decides
  whether anyone is notified.
EOF
    exit 2
}

# Defaults derived from where this script sits, because that is the one thing
# it can know without being told: the package is deployed to <base>/zfs-snapshot-all
# and writes its log and notify script to <base>/. True for root
# (/root/scripts/) and for a delegated account (/home/<acct>/) alike.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_base="$(dirname "$_here")"

LABEL=""; LOG="$_base/cron.log"; NOTIFY="$_base/notify-fail.sh"; DETAIL=8

while [ "$#" -gt 0 ]; do
    case "$1" in
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help)    usage ;;
        --log=*)      LOG="${1#--log=}"; shift ;;
        --notify=*)   NOTIFY="${1#--notify=}"; shift ;;
        --detail=*)   DETAIL="${1#--detail=}"; shift ;;
        --)           shift; break ;;
        -*)           echo "zfs-job: unknown option: $1" >&2; usage ;;
        *)            if [ -z "$LABEL" ]; then LABEL="$1"; shift
                      else echo "zfs-job: takes exactly one label" >&2; usage; fi ;;
    esac
done

[ -n "$LABEL" ] || { echo "zfs-job: no label" >&2; usage; }
[ "$#" -gt 0 ]  || { echo "zfs-job: nothing to run -- the command follows --" >&2; usage; }
case "$DETAIL" in ''|*[!0-9]*) echo "zfs-job: --detail takes a count" >&2; usage ;; esac

# The stderr file, and the fallback the inline envelope also had. A failing
# mktemp used to leave $e empty, which made `2>"$e"` an ambiguous redirect and
# the command never ran AT ALL -- silently. That is the 2026-08-09 signature the
# fallback exists to prevent, and it is kept here for the same reason.
e=$(mktemp 2>/dev/null) || e="$LOG.err.$$"

printf '%s ZFS-JOB BEGIN %s\n' "$(date -Is)" "$LABEL" >>"$LOG" 2>/dev/null

"$@" 2>"$e"
rc=$?

cat "$e" >>"$LOG" 2>/dev/null
printf '%s ZFS-JOB END %s rc=%s\n' "$(date -Is)" "$LABEL" "$rc" >>"$LOG" 2>/dev/null

if [ "$rc" -ne 0 ] && [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$LABEL" "$(tail -n "$DETAIL" "$e" 2>/dev/null)" 2>>"$LOG"
fi

rm -f "$e"
exit 0
