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

###############################################################################
# BOOKMARK-BACKED INCREMENTAL FALLBACK
###############################################################################
# A ZFS bookmark (dataset#mark) records only a snapshot's txg+GUID -- zero
# data blocks -- yet `zfs send -i` only needs that txg to compute a diff
# against a newer snapshot. So a bookmark survives deleting the snapshot it
# was made from and still anchors one more incremental. This is what saves a
# run from falling back to a FULL send when the common-base snapshot has
# already been pruned off the source (e.g. pvesr's ~12h retention on pve0)
# before this tool got around to shipping it onward.
#
# Scope for v1: single dataset only, no recursion. A recursive stream would
# need a bookmark (and a GUID match) on every child dataset, which none of
# this bookkeeping does yet -- callers gate these functions on
# `[ $RECURSIVE -ne 1 ]` and fall straight through to FULL otherwise.
#
# How syncoid avoids this problem: it doesn't send a single `-R` stream at
# all. `getchilddatasets()` enumerates the tree and `syncdataset()` -- the
# same single-dataset sync/bookmark logic used without -r -- runs once per
# child, in dependency order. So bookmarking "just works" per child with zero
# extra machinery, because recursion there is a loop over the single-dataset
# path, not a distinct code path. If -R here is ever replaced by an
# equivalent per-child loop calling process_dataset(), these functions need
# no changes to cover it -- confirmed by reading syncoid's source, 2026-07-22.
#
# NOT yet implemented: pruning of orphaned bookmarks (target retired, or
# just stale). Each successful transfer replaces the one bookmark it keeps
# per target, so these don't grow *per run* -- but a target dataset that
# stops being used entirely leaves its bookmark behind forever. Flagged as a
# follow-up, not silently forgotten.

# Emit the GUID of one dataset@snapshot. Mirrors get_timestamp's remote-vs-
# local branching but reads the `guid` property instead of `creation`.
get_snapshot_guid() {
    local dataset="$1"
    local snap="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"
    local guid
    if [ -n "$remote_host" ]; then
        guid=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value guid '${dataset}@${snap}' 2>/dev/null") || return 1
    else
        guid=$(zfs get -H -o value guid "${dataset}@${snap}" 2>/dev/null) || return 1
    fi
    [ -n "$guid" ] && echo "$guid"
}

# True when the dataset exists. Needed by the -w (raw send) path: raw streams
# carry their own dataset properties, so the leaf target must be created by
# `zfs recv` rather than pre-created by us -- which means "target missing" is a
# normal first-send state there, not a failure, and has to be told apart from
# a genuine lookup error.
target_exists() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name '$dataset' >/dev/null 2>&1"
    else
        zfs list -H -o name "$dataset" >/dev/null 2>&1
    fi
}

# Short, stable per-target suffix for bookmark names -- lets one source
# dataset feed several targets without their bookmarks colliding or
# overwriting each other.
bookmark_target_tag() {
    printf '%s' "$1" | md5sum | cut -c1-8
}

# Look for a bookmark on $src_dataset whose GUID matches $tgt_head_guid --
# the ZFS-level proof that the bookmark's txg is a valid incremental base for
# whatever the target currently holds. Echoes "src_dataset#mark" on a match,
# nothing otherwise. Deliberately GUID-only, never name-based: a stale or
# renamed bookmark (source rolled back, target rebuilt independently) has a
# different GUID and correctly falls through to FULL instead of being
# trusted on a guess.
find_bookmark_base() {
    local src_dataset="$1"
    local tgt_head_guid="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"
    [ -z "$tgt_head_guid" ] && return 0
    local marks
    if [ -n "$remote_host" ]; then
        marks=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -t bookmark -o name,guid '$src_dataset' 2>/dev/null")
    else
        marks=$(zfs list -H -t bookmark -o name,guid "$src_dataset" 2>/dev/null)
    fi
    [ -z "$marks" ] && return 0
    local name guid
    while IFS=$'\t' read -r name guid; do
        [ "$guid" = "$tgt_head_guid" ] && { echo "$name"; return 0; }
    done <<< "$marks"
}

# After a successful transfer, refresh the per-target bookmark on the SOURCE
# to the snapshot that was just sent. This is the insurance policy itself:
# if the source's own retention deletes that snapshot before the next run,
# the bookmark (metadata only) still anchors the next incremental. Only one
# bookmark is kept per target (the old one is destroyed first), so this
# doesn't accumulate across runs -- see the orphan-pruning gap noted above.
# Best-effort: a failure here (e.g. missing 'zfs allow bookmark,destroy'
# delegation for a non-root sender) logs a warning but does not fail the
# transfer that already succeeded.
record_send_bookmark() {
    local src_dataset="$1"
    local sent_snap="$2"
    local tgt_dataset="$3"
    local remote_user="${4:-}"
    local remote_host="${5:-}"
    local tag mark full
    tag=$(bookmark_target_tag "$tgt_dataset")
    mark="tgt-${tag}"
    full="${src_dataset}#${mark}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -t bookmark -o name '$full' >/dev/null 2>&1 && zfs destroy '$full'; zfs bookmark '${src_dataset}@${sent_snap}' '$full'" \
            || log 1 "Warning: failed to refresh bookmark $full on $remote_host (non-fatal)"
    else
        zfs list -H -t bookmark -o name "$full" >/dev/null 2>&1 && zfs destroy "$full"
        zfs bookmark "${src_dataset}@${sent_snap}" "$full" \
            || log 1 "Warning: failed to refresh bookmark $full (non-fatal)"
    fi
}
