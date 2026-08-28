#!/bin/bash
# ------------------------------------------------------------------------------
# zfs-media-gate.sh -- is the removable replica's medium here right now?
#
# A replica onto rotating media is a relationship whose target is DELIBERATELY
# absent most of the time: the disk is in a safe, in a car, or at the other site.
# Every other relationship in this package treats an unreachable target as a
# fault, because for them it is one. For this one it is the normal state, and
# saying so is the whole job of this file.
#
# It answers one question and changes nothing:
#
#   exit 0   the medium is here and the landing dataset exists -- run the job
#   exit 1   it is not -- skip the job, quietly, and record that we skipped
#
# The generated cron line reads that status, so a skipped run is not a failed
# run: no alert, no non-zero exit, and the job's own log carries one line saying
# which medium was missing and when it was last seen.
#
# WHY A SEPARATE FILE, and not a flag on the engines. The engines are frozen, and
# this is not a transfer decision -- it is a decision about whether to start one.
# It is the same shape as zfs-pair-gate: a small, single-purpose program that
# answers a question the big ones should not have to grow a branch for.
#
# WHAT IT DOES NOT DO. It does not import, export, mount or touch the pool. An
# operator plugs a disk in and takes it out; this only ever looks.
#
#   zfs-media-gate.sh <pool-or-dataset> <label> [--stats FILE] [--quiet]
# ------------------------------------------------------------------------------
set -uo pipefail

VERSION='v1.0'

usage() {
    echo "Usage: $0 <pool-or-dataset> <label> [--stats FILE] [--quiet]" >&2
    echo "  exit 0: the medium is present and the dataset exists" >&2
    echo "  exit 1: it is absent -- the caller should skip its job without alerting" >&2
    exit 2
}

TARGET=""; LABEL=""; STATS=""; QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help)    usage ;;
        --quiet)      QUIET=1; shift ;;
        --stats)      STATS="${2:-}"; shift 2 ;;
        --stats=*)    STATS="${1#--stats=}"; shift ;;
        -*)           echo "unknown option: $1" >&2; usage ;;
        *)            if   [ -z "$TARGET" ]; then TARGET="$1"
                      elif [ -z "$LABEL" ];  then LABEL="$1"
                      else echo "too many arguments: $1" >&2; usage
                      fi; shift ;;
    esac
done
[ -n "$TARGET" ] && [ -n "$LABEL" ] || usage

# A label is a directory name under /var/lib and it reaches a log line. Same
# charset as every other label in this package, checked here rather than
# assumed: this program runs from cron with whatever the generator wrote.
case "$LABEL" in
    *[!A-Za-z0-9._-]*) echo "zfs-media-gate: '$LABEL' is not a valid relationship label" >&2; exit 2 ;;
esac

command -v zfs   >/dev/null || { echo "zfs-media-gate: 'zfs' not found in PATH" >&2; exit 2; }
command -v zpool >/dev/null || { echo "zfs-media-gate: 'zpool' not found in PATH" >&2; exit 2; }

STATE_DIR="${MEDIA_STATE_DIR:-/var/lib/zfs-snapshot-all/media}"
SEEN="$STATE_DIR/$LABEL.last-seen"

say() { [ "$QUIET" -eq 1 ] || printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

emit() {   # <status> -- same schema as the engines' stats lines
    [ -n "$STATS" ] || return 0
    printf '{"time":"%s","script":"%s","dataset":"%s","label":"%s","status":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$(basename "$0")" "$TARGET" "$LABEL" "$1" \
        >> "$STATS" 2>/dev/null || true
}

# THE POOL FIRST, THEN THE DATASET, and the two are reported differently.
#
# "The disk is not plugged in" and "the disk is here but the dataset I was told
# to write to is not on it" are not the same event, and only the first is
# normal. The second means the wrong medium is in the slot, or somebody renamed
# something -- and an operator who is handed one message for both will treat the
# dangerous one as routine.
POOL="${TARGET%%/*}"

if ! zpool list -H -o name "$POOL" >/dev/null 2>&1; then
    last="never"
    [ -r "$SEEN" ] && last="$(cat "$SEEN" 2>/dev/null)"
    say "SKIPPED: medium for '$LABEL' is not here -- pool '$POOL' is not imported (last seen: $last). Nothing was run and nothing is wrong; plug it in and the next scheduled run catches up."
    emit skipped_absent
    exit 1
fi

if ! zfs list -H -o name "$TARGET" >/dev/null 2>&1; then
    say "REFUSING: pool '$POOL' IS imported but '$TARGET' is not on it. That is not an absent medium -- it is the wrong one, or the dataset was renamed or destroyed. Not skipping quietly: this needs a human."
    emit wrong_medium
    exit 2
fi

# Present. Record when, because "how long has this disk been away" is the
# question an operator actually asks, and nothing else in the package keeps it.
if mkdir -p "$STATE_DIR" 2>/dev/null; then
    date '+%Y-%m-%d %H:%M:%S' > "$SEEN" 2>/dev/null || true
fi
say "medium for '$LABEL' is present ($TARGET)"
emit present
exit 0
