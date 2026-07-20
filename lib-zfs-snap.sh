# lib-zfs-snap.sh -- shared helpers for snapsend.sh and snapget.sh
# ------------------------------------------------------------------------------
# NOT executable on its own -- meant to be `source`d. Holds only the helpers
# that were byte-for-byte identical in both scripts (logging, stats, and the
# resumable-transfer bookkeeping); every direction-specific function (send vs.
# pull) deliberately stays in each script, because that is where snapsend.sh and
# snapget.sh genuinely differ.
#
# These functions reference a few globals (VERBOSE, STATS_LOG, LOCKDIR,
# SSH_OPTS, and $0's basename). None are read at source time -- they are only
# used when the function is CALLED, which always happens after the sourcing
# script has set them up. So source this right after the global-config block.
# ------------------------------------------------------------------------------

###############################################################################
# LOGGING
###############################################################################
log() {
    local LEVEL=$1
    shift
    [ "$VERBOSE" -ge "$LEVEL" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# One line per processed dataset, appended to STATS_LOG. Best-effort: never
# lets a logging failure (e.g. unwritable path) break the actual backup.
emit_stats() {
    local dataset="$1" target="$2" status="$3" duration="$4" resumed="${5:-no}"
    {
        echo "$(date -u +%FT%TZ) script=$(basename "$0") dataset=${dataset} target=${target} status=${status} duration_s=${duration} resumed=${resumed}"
    } >> "$STATS_LOG" 2>/dev/null || true
}

###############################################################################
# RESUMABLE TRANSFER SUPPORT
###############################################################################
# If a prior zfs recv into $tgt_dataset was interrupted mid-stream, ZFS leaves
# a resume token on the TARGET dataset (receive_resume_token property). These
# helpers detect that, resume via `zfs send -t <token>`, and give up (via
# `zfs receive -A`, which discards only the partial state, not the dataset's
# existing history) after MAX_RESUME_ATTEMPTS failed resume attempts.
#
# In snapget.sh the target is ALWAYS local (its remote_host refers to the
# SOURCE), so get_resume_token/abandon_resume are always called there with an
# empty remote_host/user -- the parameters are kept anyway for symmetry with
# snapsend.sh, where the target can be remote.
MAX_RESUME_ATTEMPTS=3

get_resume_token() {
    local tgt_dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    local token
    if [ -n "$remote_host" ]; then
        token=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value receive_resume_token '$tgt_dataset' 2>/dev/null")
    else
        token=$(zfs get -H -o value receive_resume_token "$tgt_dataset" 2>/dev/null)
    fi
    if [ -n "$token" ] && [ "$token" != "-" ]; then
        echo "$token"
    fi
}

abandon_resume() {
    local tgt_dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    log 1 "Abandoning stuck resume state on $tgt_dataset (zfs receive -A)"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs receive -A '$tgt_dataset'"
    else
        zfs receive -A "$tgt_dataset"
    fi
}

# Resume-attempt counter is kept under LOCKDIR (same override as the lock), so a
# non-root run (LOCKDIR=~/run) can actually write it -- on the old hardcoded
# /var/run the counter was unwritable for non-root, reads always saw 0, the
# MAX_RESUME_ATTEMPTS guard never tripped, and a stuck resume was retried every
# run forever. LOCKDIR is set before process_dataset runs.
resume_state_file() {
    echo "${LOCKDIR:-/var/run}/$(basename "$0").resume-attempts.$(echo "$1" | tr '/' '_')"
}

read_resume_attempts() {
    cat "$(resume_state_file "$1")" 2>/dev/null || echo 0
}

increment_resume_attempts() {
    local f
    f=$(resume_state_file "$1")
    echo "$(($(read_resume_attempts "$1") + 1))" > "$f"
}

reset_resume_attempts() {
    rm -f "$(resume_state_file "$1")"
}
