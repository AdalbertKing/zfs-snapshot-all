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

# Minimal JSON string escaping for values that come from config (dataset/
# target paths) rather than from a fixed set of literals we control.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# One JSON object per processed dataset, appended to STATS_LOG as JSON-lines
# (one line = one record, no top-level array) so history can be queried with
# `jq` instead of parsed with regex. Best-effort: never lets a logging
# failure (e.g. unwritable path) break the actual backup.
emit_stats() {
    local dataset="$1" target="$2" status="$3" duration="$4" resumed="${5:-no}"
    local resumed_bool="false"
    [ "$resumed" = "yes" ] && resumed_bool="true"
    {
        printf '{"time":"%s","script":"%s","dataset":"%s","target":"%s","status":"%s","duration_s":%s,"resumed":%s}\n' \
            "$(date -u +%FT%TZ)" "$(basename "$0")" \
            "$(json_escape "$dataset")" "$(json_escape "$target")" "$(json_escape "$status")" \
            "$duration" "$resumed_bool"
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
# The identity of ONE per-dataset job's state.
#
# Both state files used to be named after the target dataset with '/' turned
# into '_', which is not injective: tank/a_b and tank/a/b both became tank_a_b,
# and underscores in dataset names are ordinary (hdd/backuptest_targets collides
# with hdd/backuptest/targets). The name also omitted IDENTIFIER, so two jobs
# that -j exists precisely to keep apart shared one file.
#
# Sharing the resume counter is untidy. Sharing the IN-FLIGHT file is not: that
# file records which snapshot currently holds `zfs hold`, and one job clearing
# another's record means that hold is never released. A hold that outlives its
# job blocks pruning, and on a pvesr-replicated dataset it wedges PVE
# replication permanently -- see the hold/pvesr note in snapsend.sh.
#
# Same shape as the invocation lock, which had been doing this correctly all
# along: NUL-delimited fields so no value can impersonate a boundary, through a
# stable hash. Reported as F3 in docs/reviews/REV-20260729-001.md.
job_state_key() {
    local tgt="$1" src="${2:-}"
    printf '%s\0%s\0%s\0%s' "$(basename "$0")" "${IDENTIFIER:-}" "$src" "$tgt" \
        | md5sum | cut -d' ' -f1
}

# The pre-v3 name, kept only so the one-time handover below can find them.
legacy_state_file() {
    echo "${LOCKDIR:-/var/run}/$(basename "$0").$1.$(echo "$2" | tr '/' '_')"
}

# Resume-attempt counter is kept under LOCKDIR (same override as the lock), so a
# non-root run (LOCKDIR=~/run) can actually write it -- on the old hardcoded
# /var/run the counter was unwritable for non-root, reads always saw 0, the
# MAX_RESUME_ATTEMPTS guard never tripped, and a stuck resume was retried every
# run forever. LOCKDIR is set before process_dataset runs.
resume_state_file() {
    echo "${LOCKDIR:-/var/run}/$(basename "$0").resume-attempts.$(job_state_key "$1" "${2:-}")"
}

read_resume_attempts() {
    cat "$(resume_state_file "$1" "${2:-}")" 2>/dev/null || echo 0
}

increment_resume_attempts() {
    local f
    f=$(resume_state_file "$1" "${2:-}")
    echo "$(($(read_resume_attempts "$1" "${2:-}") + 1))" > "$f"
}

reset_resume_attempts() {
    rm -f "$(resume_state_file "$1" "${2:-}")"
}

###############################################################################
# HOLD-BASED PROTECTION FOR IN-FLIGHT SNAPSHOTS
###############################################################################
# A snapshot that is the source of a `zfs send` currently in flight -- or that
# a stuck receive_resume_token still depends on -- must not be pruned by a
# delsnaps.sh run that happens to land in the same window. `zfs hold` is the
# right primitive: it is enforced by ZFS itself (a plain `zfs destroy` on a
# held snapshot fails), and unlike anything tracked in this script's own
# state, it survives the process exiting, so it keeps protecting the
# snapshot across every subsequent cron invocation for as long as a resume
# stays stuck (see MAX_RESUME_ATTEMPTS above). Same HOLD_TAG is duplicated
# (not sourced) into delsnaps.sh so it can recognize a hold placed by this
# pair of scripts and report it as "in-flight, skipped" instead of the
# generic dependent-clone error -- keep the two in sync if this ever changes.
HOLD_TAG="zfssnapall_inflight"

# A dataset Proxmox VE replicates with `pvesr` must never be held, and this is
# the one exception to "a hold is free protection".
#
# pvesr moves data with `zfs send -Rpv | zfs recv -F` (PVE's ZFSPoolPlugin), and
# a forced receive of a REPLICATION stream is specified to destroy every
# destination snapshot the sending side no longer has. Since the source runs its
# own retention, that pruning happens on essentially every sync. A held snapshot
# cannot be destroyed, so the receive aborts -- and it does not merely skip one
# cycle, it stays broken until a human releases the hold.
#
# Seen in production 2026-07-25: leaked holds on pve2's replica of
# subvol-107-disk-0 stopped Nextcloud replication for 14h (FailCount 24), and on
# the way there ZFS had quietly renamed four snapshots it could not delete to
# `recv-<pid>-1`, which is what a forced receive does with a destination
# snapshot that refuses to go away.
#
# Skipping the hold here costs nothing real: the hold exists to stop
# delsnaps.sh pruning a snapshot mid-send, but on a pvesr-managed dataset the
# snapshot set is not ours to defend -- pvesr rewrites it to mirror the source
# on every sync, so a hold cannot win that race, only break the sync.
#
# The probe cannot tell a replication SOURCE from a TARGET (both carry
# `__replicate_` snapshots) and deliberately does not try: erring toward "skip
# the hold" trades a little pruning protection for never wedging replication,
# and on a source the hold was not buying much anyway -- pvesr there only
# destroys its OWN `__replicate_` bookkeeping snapshots, which this tool never
# holds.
declare -A PVESR_MANAGED_CACHE=()
is_pvesr_managed() {
    local ds="$1" remote_user="${2:-}" remote_host="${3:-}"
    local key="${remote_host}:${ds}" found
    if [ -z "${PVESR_MANAGED_CACHE[$key]+x}" ]; then
        if [ -n "$remote_host" ]; then
            found=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list -t snapshot -H -o name -d 1 '$ds' 2>/dev/null | grep -c '@__replicate_'" 2>/dev/null) || found=0
        else
            found=$(zfs list -t snapshot -H -o name -d 1 "$ds" 2>/dev/null | grep -c '@__replicate_') || found=0
        fi
        [[ "$found" =~ ^[0-9]+$ ]] || found=0
        if [ "$found" -gt 0 ]; then PVESR_MANAGED_CACHE[$key]=1; else PVESR_MANAGED_CACHE[$key]=0; fi
    fi
    [ "${PVESR_MANAGED_CACHE[$key]}" -eq 1 ]
}

# Best-effort: a hold that fails to apply (e.g. a non-root user missing the
# delegated 'hold' permission) must not abort a backup that would otherwise
# succeed -- it just runs without the extra protection.
hold_snapshot() {
    local snap="$1" remote_user="${2:-}" remote_host="${3:-}"
    if is_pvesr_managed "${snap%@*}" "$remote_user" "$remote_host"; then
        log 2 "Not holding $snap -- ${snap%@*} is replicated by Proxmox VE (pvesr); a hold there blocks its forced receive and wedges replication"
        return 0
    fi
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs hold '$HOLD_TAG' '$snap'" 2>/dev/null \
            || log 2 "Could not place hold on $snap (missing delegated 'hold'?) -- continuing without in-flight protection"
    else
        zfs hold "$HOLD_TAG" "$snap" 2>/dev/null \
            || log 2 "Could not place hold on $snap (missing delegated 'hold'?) -- continuing without in-flight protection"
    fi
}

# Best-effort in the other direction too: releasing a hold that is already
# gone (already released, or never got placed) is not an error worth failing
# a run over.
# Give up on a dataset that is already holding its in-flight snapshot: release
# the hold and forget the in-flight record, so a failure BEFORE the transfer
# starts does not strand an un-prunable snapshot forever.
#
# The transfer-failure path is different and deliberately keeps the hold when a
# resume token exists -- a later run needs that exact snapshot. Everything that
# fails earlier (target creation, ancestor creation, a refused force-full-send)
# has nothing to come back for. Found live: a delegated non-root run failing to
# create the target left a held snapshot behind on every attempt, and `zfs
# destroy` then reported the misleading "dataset is busy".
# The held snapshot lives on the SOURCE, which is local for snapsend but may be
# remote for snapget -- hence the optional remote args.
abort_held_snapshot() {
    local snap="$1" tgt_dataset="$2" remote_user="${3:-}" remote_host="${4:-}"
    release_snapshot "$snap" "$remote_user" "$remote_host"
    clear_inflight_snap "$tgt_dataset"
}

release_snapshot() {
    local snap="$1" remote_user="${2:-}" remote_host="${3:-}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs release '$HOLD_TAG' '$snap'" 2>/dev/null || true
    else
        zfs release "$HOLD_TAG" "$snap" 2>/dev/null || true
    fi
}

# Which exact snapshot is currently held for a given target -- tracked
# separately from the resume-attempt counter (same LOCKDIR, same per-target
# naming) because a stuck resume can span many cron invocations, and by the
# time it is abandoned or succeeds, process_dataset's local $snapshot variable
# from the ORIGINAL attempt is long gone. Reading `zfs holds` back and
# matching on tag would work too, but requires re-deriving the exact
# snapshot name from a possibly-remote host; recording it once, right where
# it is created, is simpler and avoids an extra round trip.
inflight_snap_file() {
    echo "${LOCKDIR:-/var/run}/$(basename "$0").inflight-snap.$(job_state_key "$1" "${2:-}")"
}

record_inflight_snap() {
    echo "$3" > "$(inflight_snap_file "$1" "${2:-}")" 2>/dev/null || true
}

read_inflight_snap() {
    cat "$(inflight_snap_file "$1" "${2:-}")" 2>/dev/null
}

clear_inflight_snap() {
    rm -f "$(inflight_snap_file "$1" "${2:-}")"
}

# One-time handover from the pre-v3 file names, run once per dataset before any
# state is read. Called for its effect; safe to run when there is nothing to do.
#
# The in-flight file is ADOPTED rather than deleted, and only when its CONTENT
# proves it belongs to this job: the recorded value is "<source-dataset>@<snap>",
# so the source it names either matches ours or it does not. That is what makes
# this safe where a rename could not be -- the old NAME is ambiguous by
# construction (that is the bug), but the old CONTENT is not. A file that is not
# ours is left where it is; the job it does belong to will claim it on its own
# next run.
#
# Deleting them instead would have been the obvious move and the wrong one: the
# recorded snapshot is what a later run releases the hold on, so dropping the
# record leaks exactly the hold this whole fix is about.
#
# The resume COUNTER is not adopted. Its content is a bare number, so nothing in
# it can say whose it is, and guessing is worse than starting over: the counter
# only guards against retrying a stuck resume forever, so a one-time reset costs
# at most one extra attempt cycle. The stale file is removed so it cannot
# accumulate.
adopt_legacy_state() {
    local tgt="$1" src="${2:-}" legacy new recorded
    legacy="$(legacy_state_file inflight-snap "$tgt")"
    new="$(inflight_snap_file "$tgt" "$src")"
    if [ -f "$legacy" ] && [ ! -f "$new" ]; then
        recorded="$(cat "$legacy" 2>/dev/null)"
        if [ -n "$recorded" ] && [ "${recorded%%@*}" = "$src" ]; then
            mv "$legacy" "$new" 2>/dev/null \
                && log 2 "adopted pre-v3 in-flight record for $src -> $tgt"
        fi
    fi
    legacy="$(legacy_state_file resume-attempts "$tgt")"
    [ -f "$legacy" ] && rm -f "$legacy"
    return 0
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

# Batch form of get_snapshot_guid: one "name<TAB>guid" line per snapshot,
# oldest first. Used by find_common_snapshot's GUID-fallback scan so a
# dataset with N snapshots costs one `zfs list` call instead of N `zfs get`
# calls. Mirrors get_sorted_snapshots' depth/RECURSIVE handling exactly --
# the two must walk the same set of snapshots or the fallback would compare
# a name-based list against a differently-scoped GUID list.
get_snapshot_guids() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    local depth_option="-d 1"
    [ "${RECURSIVE:-0}" -eq 1 ] && depth_option=""

    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name,guid -t snapshot -s creation $depth_option '$dataset' 2>/dev/null" \
            | awk -F'\t' '{split($1,a,"@"); print a[2]"\t"$2}'
    else
        zfs list -H -o name,guid -t snapshot -s creation $depth_option "$dataset" 2>/dev/null \
            | awk -F'\t' '{split($1,a,"@"); print a[2]"\t"$2}'
    fi
}

###############################################################################
# SSH FAILURE DISCRIMINATION -- "could not ask" vs "asked, and the answer is no"
###############################################################################
# A remote probe is one ssh call whose exit status carries two completely
# different events, and every call site here used to collapse both into a single
# "not found":
#
#   0      ssh connected, the check ran, the dataset IS there
#   1      ssh connected, the check ran, the dataset is NOT there
#   255    ssh never ran anything -- authentication failure, host key
#          verification failure, host unreachable/refused, DNS failure
#   other  ssh connected but the check itself could not run
#          (127 = no `zfs` in this account's PATH, 126 = not executable)
#
# 255 is ssh's own reserved status and `zfs list` never returns it, so for a
# probe whose remote command is a single `zfs list` it is an unambiguous
# discriminator. That is the whole trick; the rest is phrasing.
#
# Why this is worth a shared helper instead of an inline `-eq 255`: the wrong
# message has now cost real debugging time twice on the same day (2026-07-29).
# First when -K was being dropped by snapget's -R expansion (17e6ce1) -- ssh
# printed "Permission denied (publickey)" and snapget printed "Source dataset
# not found on remote host" for a dataset that existed and a key that worked.
# Then again, reproduced deliberately by pointing -k at a known_hosts file
# holding a wrong host key: ssh printed "Host key verification failed" and
# snapget still blamed the dataset. It is the same class as the delsnaps.sh bug
# where an ssh failure read as "nothing to prune" -- that one was silent, this
# one at least exited 1.
#
# An unreachable peer and a missing dataset call for opposite repairs (fix the
# link vs. fix the config), so one message covering both is worse than none: it
# sends the reader to the wrong half of the system.
REMOTE_PROBE_RC=0     # raw exit status of the last probe_dataset/remote_list
REMOTE_PROBE_ERR=""   # ssh's own local stderr from the last probe_dataset

# probe_dataset DATASET [REMOTE_USER] [REMOTE_HOST] [ROLE]
#   0  the dataset exists
#   1  ssh worked (or the check was local) and the dataset genuinely is not there
#   2  the question could not be answered -- the reason is already logged at
#      level 0. A caller must NEVER treat this as 1.
probe_dataset() {
    local dataset="$1" remote_user="${2:-}" remote_host="${3:-}" role="${4:-dataset}"
    REMOTE_PROBE_ERR=""
    if [ -z "$remote_host" ]; then
        zfs list -H "$dataset" >/dev/null 2>&1
        REMOTE_PROBE_RC=$?
        [ $REMOTE_PROBE_RC -eq 0 ] && return 0
        return 1
    fi
    # The remote command discards its own output ON THE REMOTE SIDE, so the
    # `2>&1` out here captures nothing but ssh's local diagnostics -- the one
    # line that says why. Worth capturing rather than letting it drift to stderr
    # unattached: in cron mail it would sit apart from the log line that draws a
    # conclusion from it, which is exactly how this survived twice.
    REMOTE_PROBE_ERR=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
        "zfs list -H '$dataset' >/dev/null 2>&1" 2>&1)
    REMOTE_PROBE_RC=$?
    case $REMOTE_PROBE_RC in
        0) return 0 ;;
        1) return 1 ;;
    esac
    local why="${REMOTE_PROBE_ERR//$'\n'/ | }"
    [ -n "$why" ] || why="(ssh printed nothing)"
    if [ $REMOTE_PROBE_RC -eq 255 ]; then
        log 0 "Cannot reach $remote_user@$remote_host over ssh (exit 255) while checking whether the $role '$dataset' exists -- a CONNECTION-level failure (authentication, host key, network or DNS), NOT a missing dataset. ssh said: $why"
    else
        log 0 "Reached $remote_user@$remote_host over ssh, but the existence check for the $role '$dataset' could not run (exit $REMOTE_PROBE_RC -- e.g. no 'zfs' in this account's PATH). Treating this as UNKNOWN, not as a missing dataset. Output: $why"
    fi
    return 2
}

# remote_list REMOTE_USER REMOTE_HOST WHAT CMD -- the listing counterpart.
# Echoes the remote command's stdout unchanged.
#   0  the listing is COMPLETE and can be trusted, including when it is empty
#      (that then genuinely means "nothing there")
#   2  ssh could not deliver a listing -- reason logged at level 0, and the
#      empty output must not be read as an answer
#
# rc 1 counts as a real (empty) answer, not as case 2: `zfs list` exits 1 for
# "no such dataset", which for a listing IS the empty result, and every caller
# below already passes `2>/dev/null` for exactly that case. 126/127/255 are
# different -- there the command never produced a listing at all.
#
# Unlike probe_dataset this does not capture ssh's stderr: here stdout is the
# payload, so ssh's own message is left to flow to this script's stderr as
# before, and the log line points at it.
remote_list() {
    local remote_user="$1" remote_host="$2" what="$3" cmd="$4"
    local out
    out=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$cmd")
    REMOTE_PROBE_RC=$?
    if [ $REMOTE_PROBE_RC -eq 0 ] || [ $REMOTE_PROBE_RC -eq 1 ]; then
        [ -n "$out" ] && printf '%s\n' "$out"
        return 0
    fi
    if [ $REMOTE_PROBE_RC -eq 255 ]; then
        log 0 "Cannot reach $remote_user@$remote_host over ssh (exit 255) while $what -- a CONNECTION-level failure (authentication, host key, network or DNS); ssh's own reason is on stderr above. Treating the result as UNKNOWN, not as an empty list."
    else
        log 0 "Reached $remote_user@$remote_host over ssh, but $what failed on the remote side (exit $REMOTE_PROBE_RC). Treating the result as UNKNOWN, not as an empty list."
    fi
    return 2
}

# True when the dataset exists. Needed by the -w (raw send) path: raw streams
# carry their own dataset properties, so the leaf target must be created by
# `zfs recv` rather than pre-created by us -- which means "target missing" is a
# normal first-send state there, not a failure, and has to be told apart from
# a genuine lookup error.
#
# Three-valued since the ssh-discrimination fix, because "the target is not
# there" and "I could not reach the host to look" lead to opposite actions and
# this function's answer feeds a first-send-vs-incremental decision:
#   0 exists, 1 genuinely absent, 2 could not determine (already logged).
# Remote callers MUST handle 2 separately -- `if ! target_exists ...` alone
# would read an unreachable host as a brand-new target and start a full send.
# snapget.sh's own calls pass no remote args (its target is always local), so
# they can never see 2.
target_exists() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    probe_dataset "$dataset" "$remote_user" "$remote_host" "target dataset"
}

# Warn when a dataset is only a container for its children and neither -r nor
# -R was given. This is the quietest way to end up with a useless backup: the
# send SUCCEEDS -- the parent is a real dataset and its (empty) contents ship
# fine -- so the run reports success, the stats log records success, and the
# staleness monitor is happy, while the data nobody explicitly named is simply
# absent from the target. Nothing anywhere else in the pipeline notices.
#
# `-d 1` on purpose: one level is enough to prove the dataset is a container,
# and it costs one cheap `zfs list` instead of walking the whole tree. The
# parent itself comes back in that listing too, so it is filtered out by exact
# name (grep -vxF, not an order assumption).
#
# WARNING, never fatal -- sending a parent alone is legitimate (its own
# properties and data still replicate, and a job may deliberately split parent
# and children across schedules). Logged at level 0 because a default-verbosity
# cron run is the one place this mistake survives unnoticed, and every
# production job today names a leaf, so this stays silent unless something is
# actually off.
warn_if_unrecursed_children() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"

    local children
    if [ -n "$remote_host" ]; then
        # An unreachable host used to land here as an empty listing, i.e. as
        # "this dataset has no children" -- the silent half of the ssh-status
        # class described above. remote_list says so instead; a warning we could
        # not compute is simply not issued.
        children=$(remote_list "$remote_user" "$remote_host" \
            "listing the children of '$dataset'" \
            "zfs list -H -o name -t filesystem,volume -r -d 1 '$dataset' 2>/dev/null") \
            || return 0
        children=$(printf '%s' "$children" | grep -vxF "$dataset")
    else
        children=$(zfs list -H -o name -t filesystem,volume -r -d 1 "$dataset" 2>/dev/null \
            | grep -vxF "$dataset")
    fi
    [ -z "$children" ] && return 0

    local count
    count=$(printf '%s\n' "$children" | wc -l)
    log 0 "WARNING: $dataset has $count child dataset(s) but neither -r nor -R was given -- only $dataset itself is being sent, its children are NOT. Add -R (independent per-dataset jobs) or -r (one atomic recursive stream) if you meant to include them."
    log 2 "Children not included: $(printf '%s' "$children" | tr '\n' ' ')"
    return 0
}

# Create every MISSING ancestor of TARGET, one level at a time, each with
# canmount=noauto. Existing levels are left exactly as they are.
#
# This exists because `zfs create -p` applies its -o properties to the FINAL
# dataset only: every level it invents along the way gets canmount=on, and ZFS
# then tries to mount it. On Linux an unprivileged user cannot mount at all --
# no amount of `zfs allow` grants CAP_SYS_ADMIN -- so a delegated account
# bootstrapping a multi-level target path failed with
#   cannot mount '<intermediate>': Insufficient privileges
# even though it was allowed to create the dataset. Found live on metropolis
# pve1 via `-X` on a middle dataset, which is precisely the case that asks for
# an intermediate to be created and left empty.
#
# Ancestors are pure structure -- they never receive a stream -- so noauto is
# right for them regardless of -U, which stays a property of the leaf.
ensure_target_ancestors() {
    local target="$1" remote_user="${2:-}" remote_host="${3:-}"
    local parent="${target%/*}"
    [ "$parent" = "$target" ] && return 0    # a bare pool name: nothing above it

    local -a parts=()
    local oldifs="$IFS"
    IFS='/' read -ra parts <<< "$parent"
    IFS="$oldifs"
    [ ${#parts[@]} -le 1 ] && return 0       # parent IS the pool

    local acc="${parts[0]}" i cmd=""
    for ((i = 1; i < ${#parts[@]}; i++)); do
        acc="$acc/${parts[$i]}"
        cmd+="zfs list -H '$acc' >/dev/null 2>&1 || zfs create -o canmount=noauto '$acc' || exit 1; "
    done
    [ -z "$cmd" ] && return 0

    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$cmd exit 0"
        local rc=$?
        # A write, not a probe -- but on a push this is the FIRST remote call
        # that can fail, so it is where the operator meets an unreachable peer.
        # The caller reports "Failed to create the ancestor path", which is true
        # and says nothing about why; 255 means we never got there at all, and
        # no amount of fixing permissions or names on the peer will help.
        [ $rc -eq 255 ] && log 0 "Cannot reach $remote_user@$remote_host over ssh (exit 255) while creating the ancestor path of '$target' -- a CONNECTION-level failure (authentication, host key, network or DNS), NOT a rejected create."
        return $rc
    fi
    sh -c "$cmd exit 0"
}

###############################################################################
# HOST VALIDATION -- refuse a loopback transfer (remote host is actually this
# same machine), and cache the answer per remote for the whole run
###############################################################################
# Byte-identical between snapsend.sh and snapget.sh before this moved here --
# the remote side of a run is the SAME host for every dataset in DATASETS, so
# calling this once per dataset (as both scripts did, from inside
# process_dataset) paid a full `ssh ... cat /etc/machine-id` round trip per
# dataset for an answer that cannot change mid-run. Cached here the same way
# pool_health/csend_pool_has already are: one entry per remote_user@remote_host,
# a real question asked at most once, everything after that a lookup.
declare -A VALIDATED_REMOTE_CACHE=()

validate_remote_host() {
    local remote_user="$1"
    local remote_host="$2"

    [ -z "$remote_host" ] && return 0  # Skip check for local transfers

    local key="$remote_user@$remote_host"
    [ -n "${VALIDATED_REMOTE_CACHE[$key]+x}" ] && return 0

    # Get local machine ID (works on systemd-based distros)
    local local_machine_id
    local_machine_id=$(cat /etc/machine-id 2>/dev/null || echo "UNKNOWN")

    # Get remote machine ID through SSH
    local remote_machine_id
    remote_machine_id=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
        "cat /etc/machine-id 2>/dev/null || echo 'UNKNOWN'" 2>/dev/null)

    # Core safety check
    if [[ "$local_machine_id" != "UNKNOWN" && "$local_machine_id" == "$remote_machine_id" ]]; then
        log 0 "CRITICAL: Remote host $remote_host has identical machine-id to local system"
        log 0 "This indicates loopback transfer attempt. Aborting."
        exit 1
    fi

    # Fallback check for non-systemd systems
    if [[ "$local_machine_id" == "UNKNOWN" ]]; then
        local local_hostname
        local_hostname=$(hostname -f)
        local remote_hostname
        remote_hostname=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "hostname -f")

        if [[ "$local_hostname" == "$remote_hostname" ]]; then
            log 0 "CRITICAL: Remote hostname matches local ($local_hostname)"
            log 0 "Possible loopback transfer. Use local mode instead."
            exit 1
        fi
    fi

    VALIDATED_REMOTE_CACHE["$key"]=1
}

# Echoes "yes" when COMPRESSOR is confirmed present on the remote host, "no"
# otherwise -- cached per (remote, compressor) for the whole run, same idiom as
# above: the remote does not gain or lose a binary mid-run, so this is a real
# `command -v` over ssh at most once per compressor per run, a lookup after
# that.
declare -A REMOTE_COMPRESSOR_CACHE=()

remote_has_compressor() {
    local remote_user="$1" remote_host="$2" compressor="$3" key val
    key="$remote_user@$remote_host/$compressor"
    if [ -n "${REMOTE_COMPRESSOR_CACHE[$key]+x}" ]; then
        printf '%s' "${REMOTE_COMPRESSOR_CACHE[$key]}"
        return 0
    fi
    if ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "command -v $compressor >/dev/null 2>&1"; then
        val=yes
    else
        val=no
    fi
    REMOTE_COMPRESSOR_CACHE["$key"]="$val"
    printf '%s' "$val"
}

# True when NAME matches any of the caller's EXCLUDE_PATTERNS (-X). The patterns
# are extended regexes matched unanchored against the full dataset name, which is
# syncoid's --exclude behaviour -- so `data/vm-1` catches `vm-10` too unless the
# caller anchors it. Reads the array from the caller's scope rather than taking
# it as arguments: both callers already keep it global, and passing an array
# through bash costs more clarity than it buys.
dataset_excluded() {
    local name="$1" pat
    [ ${#EXCLUDE_PATTERNS[@]} -eq 0 ] && return 1
    for pat in "${EXCLUDE_PATTERNS[@]}"; do
        printf '%s\n' "$name" | grep -Eq -- "$pat" && return 0
    done
    return 1
}

# Emit a dataset's `encryption` property ("off" for unencrypted). Empty when the
# dataset does not exist.
dataset_encryption() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value encryption '$dataset' 2>/dev/null"
    else
        zfs get -H -o value encryption "$dataset" 2>/dev/null
    fi
}

# Refuse a run whose rawness does not match what the existing target was seeded
# with. ZFS rejects these itself, but with messages that do not say what to do
# ("cannot perform raw receive on top of existing unencrypted dataset",
# "inherited key must be loaded"), and the refusal happens deep inside the pipe
# where it reads as a generic transfer failure.
#
# Verified on zfs-2.1.9: this only matters when the SOURCE is encrypted. For an
# unencrypted source, raw and non-raw streams interoperate freely in both
# directions and the two seedings are indistinguishable by property -- so the
# check deliberately does nothing there rather than guessing.
#
# Returns 0 to proceed, 1 to refuse. Skip it under -f, which destroys the target
# and therefore has no seeding left to conflict with.
check_raw_compatibility() {
    local src_dataset="$1" src_user="$2" src_host="$3"
    local tgt_dataset="$4" tgt_user="$5" tgt_host="$6"
    local raw="$7"

    local src_enc
    src_enc=$(dataset_encryption "$src_dataset" "$src_user" "$src_host")
    [ -z "$src_enc" ] && return 0
    [ "$src_enc" = "off" ] && return 0

    # Target absent = nothing seeded yet, any rawness is fine.
    local tgt_enc
    tgt_enc=$(dataset_encryption "$tgt_dataset" "$tgt_user" "$tgt_host")
    [ -z "$tgt_enc" ] && return 0

    if [ "$raw" -eq 1 ] && [ "$tgt_enc" = "off" ]; then
        log 0 "Refusing raw send: $src_dataset is encrypted ($src_enc) but the existing target $tgt_dataset is NOT ($tgt_enc)."
        log 0 "A raw stream cannot be received on top of an unencrypted dataset -- ZFS would reject it as \"cannot perform raw receive on top of existing unencrypted dataset\"."
        log 0 "The target was seeded by a non-raw run (note: a FAILED non-raw run also leaves an empty target behind). Either drop -w to keep sending decrypted, or destroy $tgt_dataset and let -w re-seed it from scratch."
        return 1
    fi

    if [ "$raw" -ne 1 ] && [ "$tgt_enc" != "off" ]; then
        log 0 "Refusing non-raw send: the existing target $tgt_dataset is encrypted ($tgt_enc), so it was seeded by a raw (-w) run."
        log 0 "A decrypted stream cannot be received into it -- ZFS would reject it as \"inherited key must be loaded\"."
        log 0 "Either add -w to keep this target raw, or destroy $tgt_dataset and let a non-raw run re-seed it."
        return 1
    fi

    return 0
}

###############################################################################
# SSH CONNECTION REUSE (ControlMaster)
###############################################################################
# One run makes many small ssh calls (timestamps, snapshot lists, property
# reads, target creation) plus the big transfer. Without multiplexing each of
# them pays a full handshake.
#
# Measured 2026-07-22, pve0 -> pve1 on a gigabit LAN: a bare `ssh host true`
# takes 150-230 ms, of which essentially all is handshake. With ControlMaster
# the same call costs ~8 ms, and the measured transfer throughput rose from
# 83.6 to 104.0 MB/s once the handshake stopped being counted inside it.
#
# Failure is non-fatal by construction: ControlMaster=auto falls back to an
# ordinary connection if the master cannot be created, so a bad socket path
# degrades to today's behaviour instead of breaking the run.

# Socket for the multiplexer. Lives in the tuning cache dir, NEVER in /var/run:
# that is tmpfs and, more importantly, not writable by the non-root zfsbackup
# account. Returns empty when no usable path exists, which disables reuse.
#
# The name is kept short on purpose -- a unix socket path is capped around 104
# characters, and ssh appends nothing but what we pass. Hence host_port rather
# than ssh's own %h/%p/%r tokens plus a long directory.
tune_control_path() {
    local host="$1"
    local dir safe p
    dir=$(tune_cache_dir) || return 0
    [ -n "$dir" ] || return 0
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    p="${dir}/cm.${safe}_${PORT:-22}"
    [ ${#p} -lt 100 ] && printf '%s' "$p"
}

# Appends multiplexing options to SSH_OPTS. Call once, AFTER SSH_OPTS is built
# and only when the run actually talks to a remote host. Sets TUNE_SOCK so the
# matching tune_ssh_close can shut the master down afterwards.
TUNE_SOCK=""
tune_ssh_enable() {
    local host="$1"
    [ -n "$host" ] || return 0
    TUNE_SOCK=$(tune_control_path "$host")
    if [ -z "$TUNE_SOCK" ]; then
        log 2 "ControlMaster disabled (no writable short socket path) -- each ssh call pays a full handshake"
        return 0
    fi
    SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=$TUNE_SOCK" -o ControlPersist=60)
    log 3 "ControlMaster socket: $TUNE_SOCK"
}

# Closes the multiplexer. Without this the master lingers for ControlPersist
# seconds after the script exits, holding a connection open for no reason.
# Best-effort: never fails the run.
tune_ssh_close() {
    local remote="$1"
    [ -n "$TUNE_SOCK" ] && [ -n "$remote" ] || return 0
    ssh -o "ControlPath=$TUNE_SOCK" -O exit "$remote" >/dev/null 2>&1 || true
    TUNE_SOCK=""
}

###############################################################################
# LINK TUNING (opt-in, -A)
###############################################################################
# Decides ONE thing: whether compressing the stream is worth it for this link
# and this data. That narrow scope is a measurement result, not an oversight --
# see the numbers below.
#
# Deliberately NOT tuned here:
#
#   mbuffer -m. Measured 2026-07-22, pve0 <-> pve1, 2 GB incompressible, real
#   `zfs recv` on the far side: 16M/128M/1G gave 109.9/109.3/109.8 MB/s to an
#   SSD target and 89.3/-/78.3-88.8 MB/s to a slow HDD target. A 64x change in
#   buffer size moved nothing beyond run-to-run noise, even in the slow-consumer
#   case that most favours a big buffer. Two sizing formulas (bandwidth x delay,
#   then bandwidth x recv-stall) were both refuted by that table, so there is
#   nothing here to tune -- just pick a small constant.
#
#   zstd level. On a slow link every level is far faster than the link, so the
#   highest ratio wins; but measured across levels the ratio barely moves
#   (1.293 -> 1.323 from -3 to -19, for 53x the CPU). Level choice is worth
#   ~2%, compress-or-not is worth ~29%. Only the latter is decided here.
#
# Everything degrades to the caller's existing settings: an unwritable cache,
# a failed probe, a missing snapshot, or a nonsensical measurement all leave
# COMPRESSION untouched rather than failing the backup.

TUNE_CACHE_TTL=$((7 * 24 * 3600))
TUNE_PROBE_VERSION=2
TUNE_SAMPLE_MB=64      # sample of a real `zfs send` stream used to measure ratio
TUNE_MARGIN_PCT=5      # below this gain, not worth burning CPU

# First writable persistent directory, or empty. NOT LOCKDIR: that is /var/run
# (tmpfs, wiped on reboot) for root but a real on-disk directory for the
# zfsbackup account, so a cache with a multi-day TTL would silently get two
# different lifetimes depending on who ran the script.
tune_cache_dir() {
    local candidates=() d
    if [ -n "${ZFS_SNAP_CACHE_DIR:-}" ]; then
        candidates=("$ZFS_SNAP_CACHE_DIR")
    else
        [ "$(id -u)" -eq 0 ] && candidates+=("/var/lib/zfs-snap")
        [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && candidates+=("$HOME/.cache/zfs-snap")
    fi
    for d in "${candidates[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        [ -w "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 0
}

# TWO caches, because the verdict has two inputs with different scopes.
#
#   linktune.<host>_<port>            MB/s the link can carry. A property of the
#                                     HOST (one host = one VPN link, agreed with
#                                     the operator), so every dataset in a run
#                                     shares it and only the first pays the probe.
#   streamtune.<host>_<port>.<hash>   ratio and pipeline rates. A property of the
#                                     DATA: the same host measured 2.34x on one
#                                     dataset and 1.29x on another. Keying this
#                                     per host too meant DATASETS[0]'s ratio
#                                     silently decided for every other dataset in
#                                     the run -- the bug this split fixes.
#
# The user@ part is stripped from the host in both, so root and zfsbackup share
# one measurement of the same link and the same data.
#
# What is cached is the MEASUREMENT, never the verdict: the verdict is recomputed
# from cached numbers on every run, so a change to TUNE_MARGIN_PCT or to
# tune_decide takes effect at once instead of after the TTL drains.
tune_cache_file() {
    local host="$1" dir safe
    dir=$(tune_cache_dir)
    [ -n "$dir" ] || return 1
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    printf '%s/linktune.%s_%s' "$dir" "$safe" "${PORT:-22}"
}

# Dataset is HASHED, not escaped. Names contain '/' and can be long, and any
# tr-style sanitiser would let 'tank/a-b' and 'tank/a_b' collapse onto one file,
# i.e. one dataset's ratio applied to another -- exactly the failure being fixed.
tune_stream_cache_file() {
    local host="$1" dataset="$2" dir safe hash
    dir=$(tune_cache_dir)
    [ -n "$dir" ] || return 1
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    hash=$(printf '%s' "$dataset" | md5sum | cut -c1-16)
    printf '%s/streamtune.%s_%s.%s' "$dir" "$safe" "${PORT:-22}" "$hash"
}

# Echoes a cached line if it is fresh AND was produced by the current probe
# method, returns 1 otherwise. The version must MATCH, not merely be present:
# bumping TUNE_PROBE_VERSION is the only way a change to HOW we measure can
# invalidate numbers from the old method, and without the comparison the field
# would be written and never read.
#
# ZFS_SNAP_RETUNE=1 forces a miss. Its name must stay in sync with the -A docs
# in both scripts; it is the only documented way to re-probe before the TTL.
tune_cache_read() {
    local f="$1" now="$2" line at ver
    [ "${ZFS_SNAP_RETUNE:-0}" -ne 1 ] || return 1
    [ -r "$f" ] || return 1
    line=$(cat "$f" 2>/dev/null) || return 1
    at=$(tune_field measured_at "$line")
    ver=$(tune_field probe_version "$line")
    [ -n "$at" ] && [ "$ver" = "$TUNE_PROBE_VERSION" ] || return 1
    [ $((now - at)) -lt $TUNE_CACHE_TTL ] && [ $((now - at)) -ge 0 ] || return 1
    printf '%s' "$line"
}

# Exact key match by splitting on whitespace, not a sed pattern: a regex loose
# enough to find `ratio=` also finds it inside `xratio=`, and the fields here
# deliberately share suffixes (raw_mbps, comp_mbps, link_mbps).
tune_field() {
    local k="$1" tok
    for tok in $2; do
        case "$tok" in
            "$k"=*) printf '%s' "${tok#*=}"; return 0 ;;
        esac
    done
    return 1
}

# Write-then-rename, and failure is swallowed: a cache that cannot be written is
# a slower next run, never a failed backup.
tune_cache_write() {
    local f="$1"; shift
    printf '%s\n' "$*" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
}

# Measures how fast this link moves incompressible bytes, in MB/s. Uses
# /dev/urandom precisely BECAUSE it is incompressible -- compressible probe data
# would measure the compressor instead of the link.
tune_probe_link() {
    local remote="$1" mb=32 t0 t1
    t0=$(date +%s.%N)
    dd if=/dev/urandom bs=1M count=$mb 2>/dev/null \
        | ssh "${SSH_OPTS[@]}" "$remote" "cat > /dev/null" 2>/dev/null || return 1
    t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" -v mb="$mb" \
        'BEGIN{d=b-a; if(d<=0){exit 1} printf "%.4f", mb/d}'
}

# Measures compression ratio and pipeline rate on a REAL `zfs send` stream from
# the dataset being backed up -- never on synthetic data. Ratio is a property of
# the DATA: the same host measured 2.34x on one dataset and 1.29x on another, so
# a table of ratios would be fiction.
#
# Three passes, not two. The first is a discarded warm-up: without it the first
# pass reads from disk and the second from ARC, so whichever runs second looks
# faster regardless of what it measures. That artefact was observed live
# (compressed pass "faster" than raw, which is arithmetically impossible).
#
# Streams throughout -- no temp files, so there is no way to fill a pool.
#
# Runs WHERE THE DATA IS. snapsend reads a local dataset, but snapget's source
# is the remote host and its compressor runs there too (snapget.sh:383,
# `ssh host "zfs send | $COMPRESS_PIPE"`), so probing locally would measure the
# wrong machine's disk and CPU entirely. Pass $2 to probe the remote side.
tune_probe_stream() {
    local dataset="$1" remote="${2:-}" script out raw_b raw_t comp_b comp_t

    # One self-contained snippet, run on whichever side owns the data, so the
    # sample never crosses the network -- only the four numbers come back.
    script='
      snap=$(zfs list -t snapshot -H -o name -s creation '"'$dataset'"' 2>/dev/null | tail -1)
      [ -n "$snap" ] || exit 1
      H="zfs send '"'"'$snap'"'"' 2>/dev/null | head -c '"$((TUNE_SAMPLE_MB * 1048576))"'"
      eval "$H | cat > /dev/null" || exit 1
      t0=$(date +%s.%N); rb=$(eval "$H | wc -c") || exit 1; t1=$(date +%s.%N)
      t2=$(date +%s.%N); cb=$(eval "$H | '"$COMPRESS_PIPE"' | wc -c") || exit 1; t3=$(date +%s.%N)
      echo "$rb $t0 $t1 $cb $t2 $t3"
    '
    if [ -n "$remote" ]; then
        out=$(ssh "${SSH_OPTS[@]}" "$remote" "$script" 2>/dev/null) || return 1
    else
        out=$(sh -c "$script" 2>/dev/null) || return 1
    fi

    local t0 t1 t2 t3
    read -r raw_b t0 t1 comp_b t2 t3 <<< "$out"
    [ -n "${t3:-}" ] || return 1
    [ "${raw_b:-0}" -gt 0 ] && [ "${comp_b:-0}" -gt 0 ] || return 1
    raw_t=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    comp_t=$(awk -v a="$t2" -v b="$t3" 'BEGIN{printf "%.4f", b-a}')

    awk -v rb="$raw_b" -v rt="$raw_t" -v cb="$comp_b" -v ct="$comp_t" 'BEGIN{
        if (rt<=0 || ct<=0) exit 1
        mb = rb/1048576
        raw = mb/rt; comp = mb/ct
        # Compression cannot make the source produce input bytes faster, so
        # comp > raw is always measurement error -- but the size of the error
        # says what kind, and only one kind is worth discarding.
        #
        # A LARGE excess means the runs were skewed (the artefact the warm-up
        # pass exists to prevent: one pass off disk, the next off ARC). Refuse,
        # rather than cache a lie for a week.
        if (comp > raw*1.5) exit 1
        # A SMALL one is expected and harmless. The two passes are not perfectly
        # symmetric -- the raw pass pushes all 64 MB into `wc`, the compressed
        # pass only the compressed bytes -- and a disk-bound source is noisy well
        # past a few percent (measured 88-120 MB/s for one unchanged setting).
        # Both effects grow exactly when compression works, so rejecting here
        # threw the measurement away on the datasets -A most needs to judge:
        # observed live on pve0 refusing both an incompressible dataset and a
        # highly compressible one, while ordinary VM disks (1.26x, 3.21x) passed.
        # Clamping keeps the usable part -- the true rate cannot exceed raw, so
        # raw is the honest estimate -- and errs against compression, never for it.
        if (comp > raw) comp = raw
        printf "%.4f %.4f %.4f", rb/cb, raw, comp
    }'
}

# Convert an mbuffer rate spec (the -b value: plain bytes/s, or a b/k/M/G
# suffix, 1024-based exactly like mbuffer's own parser) into MB/s, so it can be
# compared against a probed link speed. Emits nothing when there is no limit or
# the spec is unparseable; every caller reads that as "no cap".
bwlimit_to_mbps() {
    local spec="${1:-}"
    [ -n "$spec" ] || return 0
    awk -v s="$spec" 'BEGIN{
        n = s; sub(/[bkKmMgG]$/, "", n)
        if (n !~ /^[0-9]+$/) exit 0
        u = substr(s, length(s), 1)
        mult = 1
        if (u == "k" || u == "K") mult = 1024
        else if (u == "m" || u == "M") mult = 1048576
        else if (u == "g" || u == "G") mult = 1073741824
        printf "%.4f", (n * mult) / 1048576
    }'
}

# effective = min(what the pipeline can produce, what the link can carry).
# Both sides in MB/s of UNCOMPRESSED data delivered, so they are comparable.
tune_decide() {
    local link="$1" ratio="$2" raw="$3" comp="$4"
    awk -v l="$link" -v r="$ratio" -v raw="$raw" -v c="$comp" -v m="$TUNE_MARGIN_PCT" 'BEGIN{
        plain = (raw < l ? raw : l)
        wcomp = (c < l*r ? c : l*r)
        if (plain <= 0) exit 1
        gain = (wcomp/plain - 1) * 100
        printf "%s %.1f", (gain > m ? "yes" : "no"), gain
    }'
}

# Entry point. Sets COMPRESSION (and logs why). Never returns non-zero in a way
# that could abort the caller -- every failure path just leaves settings alone.
# $3 ("remote"/"local") says which side owns the DATA -- snapsend sends local
# data to a remote host, snapget pulls remote data to a local target. The link
# probe always targets the remote host either way; only the stream probe cares.
tune_apply() {
    local remote="$1" dataset="$2" data_side="${3:-local}"
    # Deliberately a SEPARATE statement: inside one `local`, every word is
    # expanded before any assignment happens, so `host="${remote#*@}"` on the
    # line above would read an empty `remote` and yield "". That silently made
    # the cache filename host-less, i.e. every host sharing one cache entry --
    # a measurement of one link being applied to another.
    local host="${remote#*@}"
    local lf sf now cached verdict gain link stream ratio raw comp stream_remote=""
    [ "$data_side" = "remote" ] && stream_remote="$remote"

    lf=$(tune_cache_file "$host") && sf=$(tune_stream_cache_file "$host" "$dataset") || {
        log 1 "Link tuning: no writable cache dir -- leaving compression settings as given"
        return 0
    }
    now=$(date +%s)

    # --- link: per host, so this probe runs once per run no matter how many
    #     datasets follow. 32 MB of urandom per dataset would be a real cost.
    if cached=$(tune_cache_read "$lf" "$now"); then
        link=$(tune_field link_mbps "$cached")
        log 3 "Link tuning: cached link=${link}MB/s for $host"
    else
        link=$(tune_probe_link "$remote") || {
            log 1 "Link tuning: link probe failed -- leaving compression settings as given"
            return 0
        }
        tune_cache_write "$lf" \
            "measured_at=$now probe_version=$TUNE_PROBE_VERSION link_mbps=$link host=$host"
    fi

    # --- stream: per host AND dataset, because the ratio is a property of the
    #     data. This is the whole point of the split.
    if cached=$(tune_cache_read "$sf" "$now"); then
        ratio=$(tune_field ratio "$cached")
        raw=$(tune_field raw_mbps "$cached")
        comp=$(tune_field comp_mbps "$cached")
        log 3 "Link tuning: cached ratio=${ratio} for $dataset"
    else
        stream=$(tune_probe_stream "$dataset" "$stream_remote") || {
            log 1 "Link tuning: stream probe failed or gave an implausible result -- leaving compression settings as given"
            return 0
        }
        read -r ratio raw comp <<< "$stream"
        tune_cache_write "$sf" \
            "measured_at=$now probe_version=$TUNE_PROBE_VERSION ratio=$ratio raw_mbps=$raw comp_mbps=$comp dataset=$dataset"
    fi

    # A truncated or hand-edited cache file parses to empty fields, and awk would
    # happily turn those into 0 and a confident "no". Checked here rather than
    # trusted, so a damaged cache degrades to the caller's settings like every
    # other failure path in this section.
    [ -n "$link" ] && [ -n "$ratio" ] && [ -n "$raw" ] && [ -n "$comp" ] || {
        log 1 "Link tuning: cached measurement unreadable -- leaving compression settings as given"
        return 0
    }

    # -b makes the link slower than the probe just measured, and the whole
    # compress-or-not verdict turns on link speed: throttled to 2 MB/s,
    # compressing is obviously worth it even though the probe clocked the LAN at
    # 110 MB/s. Applied to the value on its way into tune_decide rather than
    # cached with it -- the measurement is a property of the link and stays
    # valid for a week, the cap is a property of this one invocation.
    local cap
    cap=$(bwlimit_to_mbps "${BWLIMIT:-}")
    if [ -n "$cap" ] && awk -v c="$cap" -v l="$link" 'BEGIN{exit !(c>0 && c<l)}'; then
        log 2 "Link tuning: -b $BWLIMIT (${cap} MB/s) is below the measured ${link} MB/s -- deciding against the limit, not the raw link"
        link="$cap"
    fi

    # `read` succeeds on the empty output of a failed awk, so its exit status
    # says nothing about tune_decide. The verdict itself is what gets checked.
    read -r verdict gain <<< "$(tune_decide "$link" "$ratio" "$raw" "$comp")"
    [ -n "$verdict" ] || {
        log 1 "Link tuning: could not evaluate -- leaving compression settings as given"
        return 0
    }

    [ "$verdict" = "yes" ] && COMPRESSION=1 || COMPRESSION=0
    log 1 "Link tuning: $dataset link=${link}MB/s ratio=${ratio} -> compress=${verdict} (gain ${gain}%)"
    return 0
}

###############################################################################
# COMPRESSED SEND (zfs send -c)
###############################################################################
# Sends records as they already sit on disk instead of decompressing them to
# build the stream and recompressing them on receive. Measured 2026-07-22 with
# `zfs send -nP` against real production snapshots on pve0:
#
#   hdd/data/vm-101-disk-0             6.6 GB -> 5.5 GB   (-18%)
#   rpool/data/vm-100-disk-0         342.2 GB -> 249.1 GB (-27%)
#   hdd/lxc/subvol-102-disk-0          1.1 GB -> 0.6 GB   (-47%)
#   hdd/backups/pve1/rpool/ROOT/pve-1  4.0 GB -> 1.7 GB   (-56%)
#
# Unlike -z this is not a trade: there is no compressor in the pipe, so it costs
# no CPU -- it SAVES the decompress/recompress that a plain send pays on both
# ends. That is why it applies to local transfers too, where -z is dropped.
#
# On by default because of those numbers, and because probing on zfs-2.1.9 found
# no interaction to be careful about:
#   full / -I incremental / -R recursive / -w raw / compression=off source  all OK
#   resume tokens are INDIFFERENT to it -- a token from a -c send resumes with or
#     without -c, and a token from a plain send resumes with -c. (Note how much
#     kinder that is than -w, where adding the flag to a resume aborts with
#     SIGABRT -- see the comment in process_dataset.)
#   a target already fed PLAIN streams accepts a -c incremental, and a target fed
#     -c accepts a plain incremental again, so switching is reversible mid-history
#
# The ONE hazard is the receiving pool. Probed exactly:
#
#   target features        source compression=off | lz4 | zstd
#   none (zpool create -d)          fail    fail    fail
#   lz4_compress only                ok      ok     fail
#
# So lz4_compress is required for a compressed stream AT ALL, even from an
# uncompressed dataset -- the stream FORMAT is what is gated, not the payload --
# and zstd-compressed records additionally need zstd_compress. Failure is not
# subtle ("pool must be upgraded to receive this stream") but it happens at recv
# time, i.e. after the send has started, so it is checked up front instead.
#
# Set ZFS_SNAP_NO_COMPRESSED_SEND=1 to force plain sends. Deliberately an env var
# rather than a flag: the guard below already handles the only known failure, so
# a CLI flag would be one more thing to thread through gen-cron configs for a
# case that should not arise.

# Cache per (pool, remote) -- one zpool query per run, not per dataset.
declare -A CSEND_POOL_CACHE=()

# "enabled" and "active" both mean the pool can take it; "disabled" cannot.
csend_pool_has() {
    local pool="$1" feature="$2" remote="$3" key="$pool/$feature/$remote" val
    if [ -n "${CSEND_POOL_CACHE[$key]+x}" ]; then
        printf '%s' "${CSEND_POOL_CACHE[$key]}"
        return 0
    fi
    if [ -n "$remote" ]; then
        val=$(ssh "${SSH_OPTS[@]}" "$remote" "zpool get -H -o value feature@$feature '$pool'" 2>/dev/null)
    else
        val=$(zpool get -H -o value "feature@$feature" "$pool" 2>/dev/null)
    fi
    case "$val" in
        enabled|active) val=yes ;;
        *)              val=no  ;;   # disabled, absent, or the query failed
    esac
    CSEND_POOL_CACHE["$key"]="$val"
    printf '%s' "$val"
}

# Echoes "-c" when a compressed send is safe for this transfer, nothing
# otherwise. Never fails the caller: an unanswerable question (query error,
# unreadable property) resolves to a plain send, which always works.
#
# BOTH sides are parameters because the two scripts are mirror images --
# snapsend reads a local dataset and writes to a possibly-remote pool, snapget
# reads a remote dataset and writes locally. Passing the wrong one asks the wrong
# machine about its pool, which is the sort of mistake that only shows up as an
# unexplained fallback to plain sends.
compressed_send_flag() {
    local src_dataset="$1" tgt_dataset="$2" tgt_remote="${3:-}" src_remote="${4:-}" pool comp
    [ "${ZFS_SNAP_NO_COMPRESSED_SEND:-0}" -ne 1 ] || return 0

    pool="${tgt_dataset%%/*}"
    [ -n "$pool" ] || return 0

    [ "$(csend_pool_has "$pool" lz4_compress "$tgt_remote")" = "yes" ] || {
        log 2 "Compressed send unavailable: target pool '$pool' lacks feature@lz4_compress"
        return 0
    }

    if [ -n "$src_remote" ]; then
        comp=$(ssh "${SSH_OPTS[@]}" "$src_remote" "zfs get -H -o value compression '$src_dataset'" 2>/dev/null)
    else
        comp=$(zfs get -H -o value compression "$src_dataset" 2>/dev/null)
    fi
    case "$comp" in
        zstd*)
            [ "$(csend_pool_has "$pool" zstd_compress "$tgt_remote")" = "yes" ] || {
                log 2 "Compressed send unavailable: '$src_dataset' uses $comp but target pool '$pool' lacks feature@zstd_compress"
                return 0
            }
            ;;
    esac

    printf '%s' "-c"
}

###############################################################################
# POOL HEALTH -- alert on DEGRADED/FAULTED pools, source and target
###############################################################################
# Cache per (pool, remote) -- one zpool query per run, same idiom as
# csend_pool_has above.
declare -A POOL_HEALTH_CACHE=()

pool_health() {
    local pool="$1" remote="$2" key="$pool/$remote" val
    if [ -n "${POOL_HEALTH_CACHE[$key]+x}" ]; then
        printf '%s' "${POOL_HEALTH_CACHE[$key]}"
        return 0
    fi
    if [ -n "$remote" ]; then
        val=$(ssh "${SSH_OPTS[@]}" "$remote" "zpool list -H -o health '$pool'" 2>/dev/null)
    else
        val=$(zpool list -H -o health "$pool" 2>/dev/null)
    fi
    [ -n "$val" ] || val="UNKNOWN"
    POOL_HEALTH_CACHE["$key"]="$val"
    printf '%s' "$val"
}

# Checks the pool backing $dataset and, if it is not ONLINE, mails
# NOTIFY_SCRIPT directly -- bypassing process_dataset's own return code on
# purpose. A DEGRADED pool with a surviving mirror leg still sends fine, so
# tying this to transfer success would either mask a real disk failure behind
# a "job succeeded" exit code, or falsely report a working transfer as failed.
# notify-fail.sh's own cooldown (default 4h) keeps this from mailing every run
# even though the check itself runs on every invocation.
#
# remote_host="" means check locally. Called once per side from
# process_dataset in both snapsend.sh (local src always, remote tgt if any)
# and snapget.sh (remote src if any, local tgt always) -- one execution
# therefore reports BOTH ends of a push/pull from wherever it already runs,
# so the other side never needs its own separate pool-health cron/alert for
# the same relationship.
check_pool_health() {
    local dataset="$1" remote_user="${2:-}" remote_host="${3:-}"
    local pool health remote host_desc
    pool="${dataset%%/*}"
    [ -n "$pool" ] || return 0
    if [ -n "$remote_host" ]; then
        remote="$remote_user@$remote_host"
        host_desc="$remote_host"
    else
        remote=""
        host_desc="$(hostname -f 2>/dev/null || hostname)"
    fi
    health=$(pool_health "$pool" "$remote")
    [ "$health" = "ONLINE" ] && return 0
    log 0 "Pool '$pool' on $host_desc is $health"
    # Send the vdev table with the alert, not just the word DEGRADED. "pool
    # DEGRADED: rpool" tells the reader to go and log in; the config/status
    # excerpt tells them WHICH disk, and whether it is resilvering or dead. The
    # header lines (state/status/action) plus the tree are the useful part;
    # scan/errors detail can stay in the log.
    local detail=""
    if [ -n "$remote" ]; then
        detail=$(ssh "${SSH_OPTS[@]}" "$remote" "zpool status '$pool' 2>/dev/null | head -n 24")
    else
        detail=$(zpool status "$pool" 2>/dev/null | head -n 24)
    fi
    "$NOTIFY_SCRIPT" "$host_desc pool $health: $pool" "$detail" 2>/dev/null || true
}

###############################################################################
# CATCH-UP THRESHOLD (-T) -- auto-decide -i (skip intermediates) from how many
# of a dataset's OWN snapshot intervals have elapsed since the common base
###############################################################################
# -i (skip-intermediates) is a hard switch: -I (all intermediates) or -i (diff
# only), nothing in between. A THRESHOLD expressed in absolute time or an
# absolute snapshot count creates a cliff at an arbitrary line -- 23h offline
# on an hourly job keeps everything, 26h keeps nothing, for a 3-hour
# difference that means nothing on its own. The fix: express the threshold
# relative to THIS dataset's own observed cadence ("more than N of ITS OWN
# intervals have elapsed"), not an absolute number. The same threshold N then
# lands at a sensible place for every tier without per-tier configuration --
# N=24 means "about a day" for an hourly job (own interval ~1h) and "about
# 24 days" for a daily job (own interval ~24h), so a dataset offline 5 days
# on a daily cadence stays under threshold and keeps sending every daily,
# while an hourly dataset offline 26 hours crosses it and catches up in one
# diff. One number, two different absolute cliffs, both in the right place.
#
# Measured, not assumed (same house style as tune_apply's link/ratio probe):
# the interval is the gap between the two NEWEST snapshots on the SOURCE
# matching this run's own -m prefix (empty prefix = no filter, same
# convention -e's own lookup uses). Every unmeasurable case -- fewer than two
# matching snapshots, a zero/negative interval, a common snapshot whose own
# creation time can't be read -- resolves to "no", i.e. keep the safe default
# (-I, all intermediates). This never fails the caller.
auto_skip_intermediates() {
    local src_dataset="$1" message="$2" common_snapshot="$3" threshold="$4"
    local remote_user="${5:-}" remote_host="${6:-}"

    local listing
    if [ -n "$remote_host" ]; then
        listing=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -Hp -o name,creation -t snapshot -s creation -d 1 '$src_dataset' 2>/dev/null")
    else
        listing=$(zfs list -Hp -o name,creation -t snapshot -s creation -d 1 "$src_dataset" 2>/dev/null)
    fi
    [ -n "$listing" ] || { printf 'no'; return 0; }

    local -a names=() times=()
    local name time suffix
    while IFS=$'\t' read -r name time; do
        [ -z "$name" ] && continue
        suffix="${name##*@}"
        if [ -n "$message" ]; then
            case "$suffix" in
                "$message"*) ;;
                *) continue ;;
            esac
        fi
        names+=("$suffix")
        times+=("$time")
    done <<< "$listing"

    # Fewer than two matching snapshots: no cadence to measure yet (this run's
    # very first cycle for this prefix, or a message that matches nothing).
    [ ${#names[@]} -ge 2 ] || { printf 'no'; return 0; }

    local newest_t="${times[-1]}" prev_t="${times[-2]}"
    local own_interval=$(( newest_t - prev_t ))
    # Degenerate (two snapshots the same second, or a clock oddity): refuse to
    # guess rather than divide by -- effectively -- nothing.
    [ "$own_interval" -gt 0 ] || { printf 'no'; return 0; }

    # common_snapshot's creation time, reusing this same listing where
    # possible (it is almost always in there) -- a direct lookup only when it
    # is not, e.g. an older snapshot from before the current -m convention.
    local common_t="" i
    for ((i = 0; i < ${#names[@]}; i++)); do
        if [ "${names[$i]}" = "$common_snapshot" ]; then
            common_t="${times[$i]}"
            break
        fi
    done
    if [ -z "$common_t" ]; then
        if [ -n "$remote_host" ]; then
            common_t=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs get -Hp -o value creation '${src_dataset}@${common_snapshot}'" 2>/dev/null)
        else
            common_t=$(zfs get -Hp -o value creation "${src_dataset}@${common_snapshot}" 2>/dev/null)
        fi
    fi
    [ -n "$common_t" ] || { printf 'no'; return 0; }

    local elapsed=$(( $(date +%s) - common_t ))
    if [ "$elapsed" -gt $(( own_interval * threshold )) ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

###############################################################################
# QUIESCE (-q) -- application-consistent snapshots of Proxmox guests
###############################################################################
# A ZFS snapshot of a running guest is CRASH-consistent: the image is whatever
# the guest happened to have on its virtual disk at that instant, exactly as if
# the power had been cut. Databases survive that (they replay their WAL on
# start), but they pay a recovery, and anything not yet fsync'd is gone.
#
# Quiescing asks the guest to flush and hold still first. Two mechanisms, because
# Proxmox has two kinds of guest:
#
# WINDOWS GUESTS: THE FREEZE WINDOW IS HARD-LIMITED TO ~10 SECONDS. Measured on
# a live win2008 guest (pve1 VM 106, 2026-07-31) while testing the deadman: hold
# it longer and the guest agent answers
#     couldn't hold writes: fsfreeze is limited up to 10 seconds
# and the freeze lapses on its own. VSS imposes it, not qemu. This is fine for
# what this code does -- `zfs snapshot` is effectively instantaneous -- but it
# means nothing may be added between freeze and snapshot that could take
# seconds: no network round trip, no `zfs list`, no retry loop. It is also why
# the whole freeze/snapshot/thaw sequence runs in ONE remote invocation rather
# than three, and why a test that deliberately holds a Windows guest frozen to
# observe something else is testing an impossible state.
#
#   qemu (VM)  -- a real freeze. `qm guest cmd <id> fsfreeze-freeze` runs INSIDE the guest via
#                 qemu-guest-agent, which also runs /etc/qemu/fsfreeze-hook --
#                 that is where a database's own quiesce belongs (MySQL FLUSH
#                 TABLES WITH READ LOCK, Postgres backup mode). Without such a
#                 hook this flushes the guest's page cache and freezes its
#                 filesystems: filesystem-consistent, not application-consistent.
#   lxc  (CT)  -- CANNOT BE FROZEN AT ALL on this stack. Containers have no
#                 guest agent, and freezing their dataset from the host does not
#                 work either: ZFS does not implement the FIFREEZE ioctl, so
#                 `fsfreeze -f` on any ZFS mountpoint returns "Operation not
#                 supported" -- measured on pve0 against a live container subvol
#                 AND against a freshly created empty dataset, so it is ZFS-wide,
#                 not a property of one filesystem. The best available is a FLUSH:
#                 `pct exec <id> -- sync` pushes the container's dirty pages into
#                 ZFS before the snapshot. That is strictly weaker than a freeze
#                 -- writes are never blocked, so a write landing between the sync
#                 and the snapshot is still caught mid-flight -- and it is named
#                 `sync` rather than `fs` so nobody reads it as a freeze.
#
# THE FREEZE WINDOW MUST CONTAIN ONLY `zfs snapshot`. A frozen filesystem blocks
# writes, so a guest stays stalled for as long as the window is open. Taking the
# snapshot is instantaneous; SENDING it is not (342 GB in one production case).
# The caller is therefore expected to freeze, snapshot every dataset in ONE
# atomic `zfs snapshot` call, thaw, and only then transfer.
#
# THAW IS GUARANTEED, not best-effort. A guest left frozen is an outage, so
# quiesce_freeze_pending registers what it froze and quiesce_thaw_all is wired to an EXIT
# trap by the caller -- it runs on success, on failure, and on Ctrl-C.

# What is currently frozen, so the thaw is exact rather than a guess. Only VMs
# ever appear here: the container path flushes and returns, holding nothing.
declare -a QUIESCE_FROZEN=()
# Guests already handled in this run, VM or container alike. One guest owns
# several datasets (VM 107 has three disks, CT 102 has two), and quiescing is a
# property of the GUEST, not of the disk: freezing a VM twice would need thawing
# it twice, and re-syncing a container only widens the gap between the flush and
# the snapshot. Without this the second disk of a running VM hit the
# "already frozen" branch and shouted about it at log level 0.
declare -a QUIESCE_HANDLED=()
# VMs that quiesce_prepare decided to freeze but deliberately did NOT freeze yet.
# They are frozen by quiesce_freeze_pending, immediately before the snapshot --
# see the freeze-window block below for why the two are separated.
declare -a QUIESCE_PENDING_VMS=()

# Proxmox names guest disks vm-<id>-disk-N (VM) and subvol-<id>-disk-N (CT).
# That convention IS the dataset-to-guest mapping -- there is no property to ask.
# Anything that does not match belongs to no guest and is simply not quiesced.
quiesce_guest_id() {
    local ds="$1" leaf="${1##*/}"
    case "$leaf" in
        vm-*-disk-*|subvol-*-disk-*)
            leaf="${leaf#vm-}"; leaf="${leaf#subvol-}"
            printf '%s' "${leaf%%-disk-*}"
            ;;
        *) return 1 ;;
    esac
}

# ---- how guests are reached, decided ONCE ----------------------------------
#
# Two routes, exactly as the remote half below already had:
#
#   direct  -- root on this host: qm/pct straight up.
#   helper  -- a delegated account: everything through zfs-quiesce-helper, the
#              one command that account may run as root, installed by
#              `deploy.sh --backup-user=NAME --allow-quiesce`.
#
# The local path had only the first, and DEGRADED instead of failing when it was
# unavailable. Found on metropolis pve1, 2026-08-01, minutes after the managed
# block moved from root to the account: `qm status` as a non-root user dies with
# "Unable to load access control list" (exit 21), the old probe read that empty
# output as "not running", and every guest was logged as stopped. The snapshots
# were taken unfrozen, the job exited 0, and nothing alerted. Three running
# guests, a config asking for `quiesce = auto`, and a backup that quietly stopped
# being what it claimed to be -- the exact failure the comment above the remote
# path already claimed this path refused to produce.
#
# `-f /etc/pve/.../<id>.conf` is why it got that far: the directory is
# world-searchable, so guest DETECTION kept working for an account that cannot
# read a single byte of the file or reach the cluster IPC at all.
QUIESCE_HELPER="${QUIESCE_HELPER:-/usr/local/sbin/zfs-quiesce-helper}"
# Overridable so the suite can drive the real code against a fake /etc/pve
# instead of stubbing the function that reads it -- a stub cannot regress.
# Deliberately NOT a privilege boundary: it is on the caller's side of sudo, and
# a guest still has to pass the helper's own whitelist before anything freezes.
QUIESCE_PVE_DIR="${QUIESCE_PVE_DIR:-/etc/pve}"
QUIESCE_VIA=""

# Called before the first freeze. REFUSES rather than degrading: a caller that
# asked for -q and silently got a crash-consistent snapshot is worse off than one
# whose job failed loudly, because only the second one finds out.
quiesce_init() {   # <mode>
    [ "$1" = "no" ] && return 0
    [ -n "$QUIESCE_VIA" ] && return 0
    if [ "$(id -u)" = "0" ]; then
        if ! qm list >/dev/null 2>&1 && ! pct list >/dev/null 2>&1; then
            log 0 "Quiesce: running as root but neither qm nor pct works here -- is this a Proxmox host? Refusing to take a snapshot that would silently be crash-consistent."
            exit 3
        fi
        QUIESCE_VIA=direct
        return 0
    fi
    if [ -x "$QUIESCE_HELPER" ] && sudo -n "$QUIESCE_HELPER" status >/dev/null 2>&1; then
        QUIESCE_VIA=helper
        log 2 "Quiesce: reaching guests through $QUIESCE_HELPER (this account is not root)"
        return 0
    fi
    log 0 "Quiesce: this account is not root and cannot use $QUIESCE_HELPER through sudo, so it cannot freeze anything. Refusing rather than taking an unquiesced snapshot. Grant it with: deploy.sh --backup-user=$(id -un) --datasets=\"...\" --allow-quiesce"
    exit 3
}

# ONE line for both routes, the same shape the helper speaks and the remote
# script parses:
#   id=<n> kind=qemu|lxc|absent running=yes|no frozen=yes|no|unknown
#
# Returns non-zero when the state could NOT be determined, which is a different
# answer from "no" and must never again be collapsed into one. Measured on pve1:
# `qm status` exits 0 for a stopped guest and 21 when it cannot reach the
# cluster, so the two are distinguishable -- the old code just discarded it.
quiesce_guest_status() {   # <id>
    local id="$1"
    if [ "$QUIESCE_VIA" = helper ]; then
        sudo -n "$QUIESCE_HELPER" status "$id" 2>/dev/null || return 1
        return 0
    fi
    local kind st running=no frozen=unknown
    if   [ -f "$QUIESCE_PVE_DIR/qemu-server/${id}.conf" ]; then kind=qemu
    elif [ -f "$QUIESCE_PVE_DIR/lxc/${id}.conf" ];         then kind=lxc
    else printf 'id=%s kind=absent running=no frozen=unknown\n' "$id"; return 0; fi
    case "$kind" in
        qemu) st=$(qm  status "$id" 2>/dev/null) || return 1 ;;
        lxc)  st=$(pct status "$id" 2>/dev/null) || return 1 ;;
    esac
    case "$st" in *running*) running=yes ;; esac
    if [ "$kind" = qemu ] && [ "$running" = yes ]; then
        case "$(qm guest cmd "$id" fsfreeze-status 2>/dev/null)" in
            *frozen*) frozen=yes ;;
            *thawed*) frozen=no  ;;
        esac
    fi
    printf 'id=%s kind=%s running=%s frozen=%s\n' "$id" "$kind" "$running" "$frozen"
}

quiesce_field() {   # <status line> <name>
    local rest="${1#*$2=}"
    printf '%s' "${rest%% *}"
}

quiesce_do_freeze() {   # <id> <kind>
    if [ "$QUIESCE_VIA" = helper ]; then
        sudo -n "$QUIESCE_HELPER" freeze "$1" >/dev/null 2>&1
        return $?
    fi
    case "$2" in
        qemu) qm guest cmd "$1" fsfreeze-freeze >/dev/null 2>&1; return $? ;;
        lxc)  pct exec "$1" -- sync >/dev/null 2>&1; return $? ;;
    esac
    return 1
}

quiesce_do_thaw() {   # <id>
    if [ "$QUIESCE_VIA" = helper ]; then
        sudo -n "$QUIESCE_HELPER" thaw "$1" >/dev/null 2>&1
        return $?
    fi
    qm guest cmd "$1" fsfreeze-thaw >/dev/null 2>&1
    return $?
}

# Freezes whatever owns $1, if anything, and remembers it.
#
# Returns 0 when there is genuinely NOTHING TO QUIESCE -- a dataset that owns no
# guest, a guest that does not exist on this node, a guest that is switched off.
# In each of those the snapshot is as consistent as it can possibly be, and
# failing the backup would be failing it for succeeding.
#
# Everything else REFUSES (exit 3). REV-20260801-023: an unreachable agent, a
# guest already frozen by someone else, a freeze that did not take -- these are
# not "reasons to take an ordinary snapshot". They are the run failing to deliver
# the consistency class that `-q` asked for, and a caller who asked for -q and
# silently received crash-consistent is exactly the outcome this whole path
# exists to prevent. -q is not best-effort; if a best-effort policy is ever
# wanted it has to be a separately named mode that does not claim consistency.
# Pass 1: everything SLOW, and nothing that freezes a VM. Flushes containers,
# refuses on anything that means -q cannot be delivered, and records which VMs
# quiesce_freeze_pending should freeze later. Named `prepare` rather than
# `freeze` since REV-20260801-024 because that is now the whole distinction.
quiesce_prepare() {
    local ds="$1" mode="$2" id line kind running frozen
    [ "$mode" = "no" ] && return 0

    id=$(quiesce_guest_id "$ds") || { log 3 "Quiesce: '$ds' is not a Proxmox guest disk -- nothing to freeze"; return 0; }
    # Check AND mark here, as soon as the owning guest is known -- before the
    # running check, not after. The decision being deduplicated is "what do we do
    # about guest N", and that is settled once however it turns out. Marking only
    # on the freeze path left stopped guests to be re-examined per disk, which on
    # a recursive job over a whole pool means a `qm status` and a log line for
    # every disk of every stopped VM.
    case " ${QUIESCE_HANDLED[*]} " in
        *" $id "*) log 3 "Quiesce: guest $id already handled in this run"; return 0 ;;
    esac
    QUIESCE_HANDLED+=("$id")

    # quiesce_init already proved the route works, so a guest whose state cannot
    # be read now is a specific refusal -- most likely one that is outside this
    # account's quiesce whitelist -- and not a reason to snapshot it unfrozen.
    if ! line=$(quiesce_guest_status "$id"); then
        log 0 "Quiesce: could not determine the state of guest $id via ${QUIESCE_VIA:-direct}. If this account is delegated, that guest is probably outside its quiesce whitelist -- add its dataset to deploy.sh --datasets. Refusing rather than taking an unquiesced snapshot."
        exit 3
    fi
    kind=$(quiesce_field "$line" kind)
    running=$(quiesce_field "$line" running)
    frozen=$(quiesce_field "$line" frozen)

    [ "$kind" = absent ] && { log 2 "Quiesce: no guest $id on this node -- skipping"; return 0; }
    [ "$running" = yes ] || { log 3 "Quiesce: guest $id is not running -- nothing to freeze"; return 0; }

    # An explicit mode that does not fit this guest quiesces NOTHING, so under -q
    # it is a refusal like any other. Beyond the letter of REV-20260801-023,
    # which is about running QEMU guests -- but it is the same rule, and leaving
    # two known silent downgrades behind while fixing four would be pointless.
    case "$mode/$kind" in
        agent/lxc)  log 0 "Quiesce: guest $id is a container, which has no qemu-guest-agent, so 'quiesce=agent' would freeze nothing at all. Refusing rather than taking a snapshot that is not what was asked for -- use quiesce=sync or auto."; exit 3 ;;
        sync/qemu)  log 0 "Quiesce: guest $id is a VM; sync-in-guest is the container fallback and does nothing here, so 'quiesce=sync' would freeze nothing at all. Refusing rather than taking a snapshot that is not what was asked for -- use quiesce=agent or auto."; exit 3 ;;
    esac

    case "$kind" in
        qemu)
            # A freeze this run does not own is not this run's quiesce. We cannot
            # prove where its application boundary is, and we deliberately will
            # not thaw it -- so there is nothing here to report as success.
            case "$frozen" in
                yes) log 0 "Quiesce: guest $id was ALREADY frozen before this run started. This run does not own that freeze, cannot say what application state it captured, and will not thaw someone else's. Refusing. Investigate the guest -- most likely a previous run died between freeze and thaw -- and thaw it with 'qm guest cmd $id fsfreeze-thaw' once you know why."; exit 3 ;;
                unknown) log 0 "Quiesce: could not read fsfreeze-status for running VM $id (agent missing, disabled or busy), so whether a freeze would take is unknown. Refusing rather than taking a snapshot that may be crash-consistent while the log calls it quiesced."; exit 3 ;;
            esac
            # NOT frozen here. Deferred to quiesce_freeze_pending, which runs
            # immediately before the snapshot -- see the window note below.
            QUIESCE_PENDING_VMS+=("$id")
            log 2 "Quiesce: VM $id will be frozen just before the snapshot"
            ;;
        lxc)
            # A flush, not a freeze -- nothing is registered for thawing because
            # nothing is held. Weaker than a freeze by design (see the block
            # comment above), but it is what -q promises for a container, and a
            # flush that did not happen is still a promise not kept.
            #
            # Done HERE, in the slow pass, precisely because it is the slow part:
            # measured 16 s for one container on metropolis pve1.
            if quiesce_do_freeze "$id" lxc; then
                log 1 "Quiesce: flushed container $id (pct exec sync) -- ZFS cannot be frozen, so this is a flush, not a freeze"
            else
                log 0 "Quiesce: 'pct exec $id -- sync' failed, so the container's dirty pages were never pushed into ZFS. Refusing rather than reporting a quiesced backup that had no quiesce."
                exit 3
            fi
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# THE FREEZE WINDOW IS A DEADLINE, NOT A SEQUENCE (REV-20260801-024)
#
# Measured on metropolis pve1, 2026-08-01: VM 106 (ostype win10) frozen at
# 18:21:21, snapshot at 18:21:39 -- EIGHTEEN SECONDS, of which 16 were one
# `pct exec 101 -- sync`. VSS hard-limits a Windows freeze to ~10 s and releases
# it on its own; the guest agent says so out loud ("couldn't hold writes:
# fsfreeze is limited up to 10 seconds"). So the snapshot was almost certainly
# taken after the guest had already thawed itself, and every check in the code
# reported success, because the freeze DID take -- it just was not still in
# force when it mattered.
#
# A successful fsfreeze-freeze is therefore not evidence of anything by the time
# `zfs snapshot` runs. Three things follow, and all three are needed:
#
#   1. ORDER. Everything slow and non-freezing happens first (quiesce_prepare
#      above flushes containers and merely REMEMBERS which VMs to freeze). VMs
#      are frozen only immediately before the snapshot.
#   2. RE-CHECK. Every VM is asked again, right before `zfs snapshot`, whether
#      it is still frozen. Not frozen, or unreadable, aborts before the snapshot.
#   3. DEADLINE. The elapsed time from the first freeze is measured and logged,
#      and exceeding the budget is a FAILURE, not a warning -- a proxy for the
#      cases the re-check cannot see, and the only guard for a guest whose agent
#      cheerfully reports "frozen" it can no longer honour.
#
# The budget is deliberately well under the ~10 s VSS limit, and deliberately
# tunable: a host with several slow-to-freeze Windows guests in ONE job can
# exceed it legitimately, and the right answer there is a smaller job or a
# considered override, not a silently longer window.
QUIESCE_MAX_WINDOW="${QUIESCE_MAX_WINDOW:-5}"
QUIESCE_FREEZE_EPOCH=0

# Pass 2. Freezes every VM quiesce_prepare deferred. Refusals leave whatever is
# already frozen to the caller's EXIT trap, which is why the trap is installed
# before any of this runs.
quiesce_freeze_pending() {
    local id
    [ "${#QUIESCE_PENDING_VMS[@]}" -eq 0 ] && return 0
    QUIESCE_FREEZE_EPOCH=$(date +%s)
    for id in "${QUIESCE_PENDING_VMS[@]}"; do
        if quiesce_do_freeze "$id" qemu; then
            QUIESCE_FROZEN+=("qemu:$id")
            log 1 "Quiesce: froze VM $id via qemu-guest-agent"
        else
            log 0 "Quiesce: VM $id did not respond to fsfreeze-freeze (agent missing, disabled or busy). Refusing -- -q asked for a frozen snapshot and this would not be one."
            exit 3
        fi
    done
    QUIESCE_PENDING_VMS=()
    return 0
}

# Pass 3, and the whole point of the exercise: is the promise still true NOW?
# Returns non-zero and says why; the caller must not snapshot on a failure.
quiesce_still_frozen() {
    local entry gid line frozen elapsed=0
    [ "${#QUIESCE_FROZEN[@]}" -eq 0 ] && return 0

    for entry in "${QUIESCE_FROZEN[@]}"; do
        case "$entry" in qemu:*) gid="${entry#qemu:}" ;; *) continue ;; esac
        if ! line=$(quiesce_guest_status "$gid"); then
            log 0 "Quiesce: could not re-read the state of VM $gid immediately before the snapshot, so whether it is still frozen is unknown. Refusing."
            return 1
        fi
        frozen=$(quiesce_field "$line" frozen)
        if [ "$frozen" != yes ]; then
            log 0 "Quiesce: VM $gid is no longer frozen (fsfreeze-status: $frozen) at the moment of the snapshot. A Windows guest releases a VSS freeze after about 10 seconds on its own, so this snapshot would be crash-consistent while claiming otherwise. Refusing."
            return 1
        fi
    done

    # After the per-guest checks, not before: the checks themselves cost time,
    # and the number that matters is the one at the snapshot boundary.
    [ "$QUIESCE_FREEZE_EPOCH" -gt 0 ] && elapsed=$(( $(date +%s) - QUIESCE_FREEZE_EPOCH ))
    if [ "$elapsed" -gt "$QUIESCE_MAX_WINDOW" ]; then
        log 0 "Quiesce: the freeze window is ${elapsed}s, over the ${QUIESCE_MAX_WINDOW}s budget, and a Windows guest drops a VSS freeze at about 10s regardless of what fsfreeze-status says. Refusing rather than snapshotting on a freeze that may already be gone. Raise QUIESCE_MAX_WINDOW only if you know the guests involved can hold it."
        return 1
    fi
    log 1 "Quiesce: freeze window ${elapsed}s (budget ${QUIESCE_MAX_WINDOW}s), ${#QUIESCE_FROZEN[@]} VM(s) confirmed still frozen at the snapshot"
    return 0
}

# Which datasets to look for guests in. A RECURSIVE job names a PARENT --
# pve1's hourly job is `snapsend.sh -r rpool/data`, one line covering every VM on
# the pool -- and a parent's name matches no guest-disk pattern at all. Deriving
# guests from the argument alone therefore quiesced NOTHING on exactly the jobs
# that cover the most machines, while logging "not a Proxmox guest disk" and
# reporting success: a config that promised consistency and silently delivered
# none. So under -r the dataset is expanded to its children first.
#
# Only the NAMES are expanded. The snapshot itself stays a single recursive
# `zfs snapshot -r parent@snap`, which is already atomic across the whole tree.
quiesce_scope() {
    local ds="$1" recursive="${2:-0}"
    if [ "$recursive" -eq 1 ]; then
        zfs list -H -o name -r "$ds" 2>/dev/null
    else
        printf '%s\n' "$ds"
    fi
}

# Thaws everything this run froze, in reverse order, and empties the list so a
# second call is harmless -- the EXIT trap fires even after an explicit thaw.
# Every failure is shouted at log level 0: a guest that will not thaw is the one
# outcome here that is worse than no quiescing at all.
# Set when a thaw did not take. The caller must fail the run on it
# (REV-20260801-023): a guest left frozen is an outage, and an outage the job
# reported as a successful backup is an outage nobody goes looking for.
QUIESCE_THAW_FAILED=0

quiesce_thaw_all() {
    local i entry gid left=()
    for (( i=${#QUIESCE_FROZEN[@]}-1; i>=0; i-- )); do
        entry="${QUIESCE_FROZEN[$i]}"
        case "$entry" in
            qemu:*)
                gid="${entry#qemu:}"
                if quiesce_do_thaw "$gid"; then
                    log 1 "Quiesce: thawed VM $gid"
                    continue
                fi
                # One retry before giving up. The common cause of a first failure
                # is an agent still busy with the freeze, and the cost of asking
                # twice is nothing next to leaving a guest frozen.
                if quiesce_do_thaw "$gid"; then
                    log 0 "Quiesce: thawed VM $gid on the second attempt -- the first thaw failed, which is worth knowing"
                    continue
                fi
                QUIESCE_THAW_FAILED=1
                # KEPT, not dropped: this is the recovery state. The EXIT trap
                # calls this function again after an explicit mid-run call, so
                # keeping the id here IS the retry, and an emptied list would be
                # this run forgetting the one thing it must not forget.
                left+=("$entry")
                log 0 "Quiesce: FAILED TO THAW VM $gid -- that guest is still frozen and needs manual 'qm guest cmd $gid fsfreeze-thaw'"
                ;;
        esac
    done
    QUIESCE_FROZEN=("${left[@]}")
    QUIESCE_HANDLED=()
    QUIESCE_PENDING_VMS=()
    QUIESCE_FREEZE_EPOCH=0
    [ "$QUIESCE_THAW_FAILED" -eq 1 ] && return 1
    return 0
}

###############################################################################
# REMOTE QUIESCE -- the pull (snapget.sh) half of -q
###############################################################################
# Everything above freezes guests on THIS host. snapget.sh pulls: the guest
# lives on the REMOTE source, so the freeze, the snapshot and the thaw all have
# to happen over there. That is not "the same code with ssh in front of it",
# for two reasons that drove this whole design:
#
# 1. THE THAW MUST SURVIVE LOSING THE CONNECTION. Locally, an EXIT trap is
#    enough: the process that froze is the process that thaws. Over ssh it is
#    not -- a dropped link, a killed local job or a rebooted collector would
#    leave a PRODUCTION GUEST FROZEN, which is an outage, and strictly worse
#    than never having quiesced at all. So the freeze/snapshot/thaw sequence
#    runs ENTIRELY INSIDE ONE remote invocation, which carries its own EXIT
#    trap AND a setsid-detached deadman timer that thaws unconditionally if
#    the main path never gets there. The deadman's output is fully redirected:
#    a background process still holding the ssh channel's stdout would make
#    every quiesced run hang until it expired.
#
# 2. IT ALSO MAKES THE FREEZE WINDOW SHORTER. A frozen guest blocks writes, so
#    the window must contain only `zfs snapshot`. Doing it in one remote script
#    keeps network latency out of the window entirely, instead of paying a
#    round-trip per freeze, per snapshot and per thaw.
#
# PRIVILEGES -- measured, not assumed (pve1 192.168.11.11, 2026-07-30):
# `qm`/`pct` need root. A delegated pull account (the `--as=delegated` default,
# which is the whole point of the pairing model) cannot use them: it cannot
# even READ /etc/pve/qemu-server/<id>.conf, which is 0640 root:www-data, and
# `qm guest cmd` as a non-root user dies with "Unable to load access control
# list" because it cannot reach the PVE cluster IPC. Verified with a real
# throwaway account, not inferred from the mode bits.
#
# So remote quiesce needs either root (`--pair --as=root`) or the narrow helper:
# `deploy.sh --join <package> --allow-quiesce` on the SOURCE host installs
# zfs-quiesce-helper plus a sudo rule for that one script, scoped to the guests
# whose disks live under the datasets already delegated. Deliberately opt-in and
# decided locally: whoever can freeze can cause an outage by never thawing, and
# the thaw here is performed by a script the COLLECTOR streams. This function
# picks the route once, up front (QVIA), and does NOT
# silently fall back to a crash-consistent snapshot when the privileges are
# missing: it reports the specific reason and fails, because someone who asked
# for -q and quietly got crash-consistent is exactly the outcome the local
# quiesce path already refuses to produce.
#
# The remote script below is a CONSTANT. Every dataset/snapshot name reaches it
# as a positional PARAMETER (printf %q on the way out), never interpolated into
# the code it runs -- the project's "treat dataset and remote values as data,
# never execute them" rule. It deliberately re-implements the guest-detection
# logic above instead of sourcing this library: the peer may be on a different
# revision of the repo, and for a delegated account /root/scripts is unreadable
# anyway. Same reasoning as update-control.sh's duplicated state helpers.
#
# Exit codes: 0 ok, 3 insufficient privileges, 4 the atomic snapshot failed
# (guests were thawed either way), 1 anything else.
read -r -d '' ZFS_REMOTE_QUIESCE_SCRIPT <<'REMOTE_QUIESCE_EOF'
set -u
mode=$1; deadman=$2; rflag=$3; shift 3
nscope=$1; shift
scopes=(); i=0
while [ "$i" -lt "$nscope" ]; do scopes+=("$1"); shift; i=$((i+1)); done
nsnap=$1; shift
snaps=(); i=0
while [ "$i" -lt "$nsnap" ]; do snaps+=("$1"); shift; i=$((i+1)); done

# Two ways to reach a guest, decided ONCE here:
#
#   direct  -- we are root on the source: qm/pct straight up, as before.
#   helper  -- we are a delegated account: everything goes through
#              zfs-quiesce-helper, installed by `deploy.sh --join
#              --allow-quiesce`. That script is the only thing this account may
#              run as root, and it accepts guest ids, never commands.
#
# Privilege probe FIRST, before anything is frozen: a run that cannot thaw must
# never start freezing. `sudo -n` so a missing rule fails immediately instead of
# blocking on a password prompt that nothing will ever answer.
QHELPER=/usr/local/sbin/zfs-quiesce-helper
if [ "$(id -u)" = "0" ]; then
    QVIA=direct
    if ! qm list >/dev/null 2>&1 && ! pct list >/dev/null 2>&1; then
        echo "QERR running as root on the source host but neither qm nor pct works here -- is this a Proxmox host?" >&2
        exit 3
    fi
elif [ -x "$QHELPER" ] && sudo -n "$QHELPER" status >/dev/null 2>&1; then
    QVIA=helper
else
    echo "QERR this account cannot quiesce guests on the source host: it is not root, and $QHELPER is not usable through sudo. Re-pair with --as=root, or on the SOURCE host run: deploy.sh --join <package> --allow-quiesce" >&2
    exit 3
fi

# EVERY `return` below carries its status EXPLICITLY. `return` with no operand
# is NOT equivalent here, and the difference is a silent data-loss bug rather
# than a style point: thaw_all runs from the EXIT trap, and in a trap handler
# bash resolves a bare `return` against the status the shell was exiting with,
# not against the last command in the function. So `sudo ...; return` reported a
# FAILED thaw as success -- the id was dropped from the recovery list, the state
# file was deleted, the deadman was killed, and the run exited 0 with a
# PRODUCTION GUEST LEFT FROZEN. Exactly the failure REV-20260730-006 F3 was
# about, reintroduced through the refactor that fixed it.
#
# Measured 2026-07-31 on real hosts: bash 5.1.4 (Debian 11 / PVE 7) reproduces
# it, bash 5.3.9 does not. The dev box runs 5.3, so no local suite could ever
# have caught this -- only running it on the actual host did. test/quiesce
# therefore guards it statically instead (no bare `return` in this script).
#
# One line, one format, whichever way we got it:
#   id=<n> kind=qemu|lxc|absent running=yes|no frozen=yes|no|unknown
gq_status() {
    if [ "$QVIA" = helper ]; then
        sudo -n "$QHELPER" status "$1" 2>/dev/null
        return $?
    fi
    local id="$1" kind st running=no frozen=unknown
    if   [ -f "/etc/pve/qemu-server/$id.conf" ]; then kind=qemu
    elif [ -f "/etc/pve/lxc/$id.conf" ];        then kind=lxc
    else echo "id=$id kind=absent running=no frozen=unknown"; return 0; fi
    case "$kind" in
        qemu) st=$(qm  status "$id" 2>/dev/null) ;;
        lxc)  st=$(pct status "$id" 2>/dev/null) ;;
    esac
    case "$st" in *running*) running=yes ;; esac
    if [ "$kind" = qemu ] && [ "$running" = yes ]; then
        case "$(qm guest cmd "$id" fsfreeze-status 2>/dev/null)" in
            *frozen*) frozen=yes ;;
            *thawed*) frozen=no  ;;
        esac
    fi
    echo "id=$id kind=$kind running=$running frozen=$frozen"
}
gq_field() { # gq_field <status-line> <name>
    local rest="${1#*$2=}"
    printf '%s' "${rest%% *}"
}
gq_freeze() {
    if [ "$QVIA" = helper ]; then sudo -n "$QHELPER" freeze "$1" >/dev/null 2>&1; return $?; fi
    case "$2" in
        qemu) qm guest cmd "$1" fsfreeze-freeze >/dev/null 2>&1 ;;
        lxc)  pct exec "$1" -- sync >/dev/null 2>&1 ;;
    esac
}
gq_thaw() {
    if [ "$QVIA" = helper ]; then sudo -n "$QHELPER" thaw "$1" >/dev/null 2>&1; return $?; fi
    qm guest cmd "$1" fsfreeze-thaw >/dev/null 2>&1
}

frozen_file=$(mktemp) || { echo "QERR mktemp failed on the source host" >&2; exit 1; }

# The exact command a human needs if everything automatic has failed. It differs
# by route: a delegated account has no qm, so telling it to run one would be
# useless advice at the worst possible moment.
thaw_hint() {
    if [ "$QVIA" = helper ]; then echo "sudo -n $QHELPER thaw $1"
    else echo "qm guest cmd $1 fsfreeze-thaw"; fi
}

# REV-20260730-006 §4: this used to end with an unconditional `: > $frozen_file`,
# which wiped the state EVEN WHEN THE THAW HAD FAILED. The deadman then saw an
# empty file and did nothing -- the last automatic rescue path disappeared in
# exactly the case it exists for. Only ids that were actually thawed are removed
# now; the rest stay, so the deadman can keep retrying, and the run reports a
# failure instead of a success.
thaw_all() {
    [ -s "$frozen_file" ] || return 0
    local id rc=0 left
    left=$(mktemp "${frozen_file}.XXXXXX") || { echo "QERR mktemp failed while thawing -- leaving the frozen list untouched for the deadman" >&2; return 1; }
    while read -r id; do
        [ -n "$id" ] || continue
        if gq_thaw "$id"; then
            echo "QLOG thawed VM $id"
        else
            printf '%s\n' "$id" >> "$left"
            echo "QERR FAILED TO THAW VM $id -- it is STILL FROZEN. Manual fix on the source host: $(thaw_hint "$id")" >&2
            rc=1
        fi
    done < "$frozen_file"
    # ATOMIC replacement (REV-20260731-007 §2 F3): the deadman may read this
    # file at any moment. A truncate-then-write would give it a window in which
    # the list looks empty, and "empty" is exactly the state that makes it stand
    # down. mktemp put $left in the same directory, so rename cannot cross a
    # filesystem; the copy fallback exists only in case it somehow does.
    mv -f "$left" "$frozen_file" 2>/dev/null || {
        cat "$left" > "$frozen_file" 2>/dev/null; rm -f "$left"
    }
    return "$rc"
}

# Single exit path. Keeps the frozen list on disk whenever a guest is still
# frozen -- that file IS the deadman's mandate, so removing it would be the same
# bug as §4 in another place -- and only stops the deadman once nothing is left
# frozen.
on_exit() {
    local ec=$?
    thaw_all || ec=6
    if [ -s "$frozen_file" ]; then
        echo "QERR guest(s) still frozen; the deadman is left running to keep retrying: $(tr '\n' ' ' < "$frozen_file")" >&2
    else
        rm -f "$frozen_file"
        [ -n "${deadman_pid:-}" ] && kill "$deadman_pid" 2>/dev/null
    fi
    exit "$ec"
}
trap on_exit EXIT

# The deadman. setsid so a SIGHUP from a dying ssh session does not take it
# with us, and every stream redirected so it never holds the ssh channel open.
deadman_pid=""
# REV-20260730-006 §3: this used to warn and carry on freezing when setsid was
# missing. The whole design rests on the thaw surviving a lost connection, so a
# run that cannot arm the deadman must not freeze anything at all -- a warning
# is not a safety net.
if ! command -v setsid >/dev/null 2>&1; then
    echo "QERR setsid is not available on the source host, so the deadman cannot be detached -- refusing to freeze anything. Without it a dropped connection would leave a guest frozen indefinitely." >&2
    exit 3
fi
if true; then
    # Polls in short steps instead of one long `sleep $deadman`, for a reason
    # found in live testing (pve0->pve1, 2026-07-30): killing the setsid'd
    # wrapper does NOT kill its `sleep` child, so every quiesced run left a
    # stray `sleep 120` behind for the rest of the timeout. Harmless in
    # itself -- the state file is gone by then, so it would have done nothing
    # -- but it is litter, and a stale deadman outliving its run is exactly
    # the kind of thing that becomes a real bug the day an mktemp name gets
    # reused. The state file's EXISTENCE is the "this run is still going"
    # signal: the EXIT trap removes it on every normal path, so the deadman
    # notices within one poll and exits; if the run is SIGKILLed the trap
    # never runs, the file stays, and the deadman thaws exactly as intended.
    setsid bash -c '
        waited=0
        while [ "$waited" -lt "$1" ]; do
            [ -e "$2" ] || exit 0
            sleep 5
            waited=$((waited + 5))
        done
        [ -s "$2" ] || exit 0
        # REV-20260730-006 §4: retry, do not give up after one pass. A thaw can
        # fail because the agent is momentarily busy; one attempt and silence
        # would leave a production guest frozen for good.
        attempt=0
        while [ "$attempt" -lt 12 ] && [ -s "$2" ]; do
            attempt=$((attempt + 1))
            left=$(mktemp "$2.XXXXXX") || break
            while read -r gid; do
                [ -n "$gid" ] || continue
                # Thaw the same way the run froze -- a delegated account has no
                # qm, so a hardcoded qm here would mean the safety net silently
                # does nothing for exactly the accounts that need it.
                if [ "$3" = helper ]; then
                    sudo -n "$4" thaw "$gid" >/dev/null 2>&1 || printf '%s\n' "$gid" >> "$left"
                else
                    qm guest cmd "$gid" fsfreeze-thaw >/dev/null 2>&1 || printf '%s\n' "$gid" >> "$left"
                fi
            done < "$2"
            mv -f "$left" "$2" 2>/dev/null || { cat "$left" > "$2" 2>/dev/null; rm -f "$left"; }
            [ -s "$2" ] || break
            logger -t zfs-quiesce "DEADMAN: thaw attempt $attempt left guest(s) frozen: $(tr "\n" " " < "$2")" 2>/dev/null
            sleep 5
        done
        if [ -s "$2" ]; then
            logger -t zfs-quiesce "DEADMAN: GAVE UP after $attempt attempts -- guest(s) STILL FROZEN: $(tr "\n" " " < "$2") -- manual thaw required" 2>/dev/null
        else
            rm -f "$2"
            logger -t zfs-quiesce "DEADMAN: thawed guest(s) after ${1}s -- the controlling backup run vanished mid-window" 2>/dev/null
        fi
    ' _ "$deadman" "$frozen_file" "$QVIA" "$QHELPER" >/dev/null 2>&1 </dev/null &
    deadman_pid=$!
    # Armed, or we do not proceed: a pid that is already gone is not a safety net.
    if [ -z "$deadman_pid" ] || ! kill -0 "$deadman_pid" 2>/dev/null; then
        echo "QERR the deadman could not be started on the source host -- refusing to freeze anything" >&2
        exit 3
    fi
fi

guest_id() {
    local leaf=${1##*/}
    case "$leaf" in
        vm-*-disk-*|subvol-*-disk-*)
            leaf=${leaf#vm-}; leaf=${leaf#subvol-}
            printf '%s' "${leaf%%-disk-*}" ;;
        *) return 1 ;;
    esac
}
handled=" "
freeze_one() {
    local ds="$1" id info kind running frozen
    id=$(guest_id "$ds") || return 0
    case "$handled" in *" $id "*) return 0 ;; esac
    handled="$handled$id "
    # One status call, whichever way we can reach the guest. Reading
    # /etc/pve/*.conf directly is exactly what a delegated account cannot do
    # (0640 root:www-data), which is why this goes through gq_status.
    info=$(gq_status "$id")
    kind=$(gq_field "$info" kind)
    running=$(gq_field "$info" running)
    frozen=$(gq_field "$info" frozen)
    # Not a failure: there is nothing to quiesce. A dataset whose guest does not
    # live here is a replica, and a stopped guest is not writing.
    case "$kind" in
        qemu|lxc) ;;
        *) echo "QLOG no guest $id on the source host -- skipping"; return 0 ;;
    esac
    [ "$running" = yes ] || { echo "QLOG guest $id is not running -- nothing to freeze"; return 0; }
    # A failure: the operator named a mode this guest cannot honour, so the
    # quiesce they asked for is not going to happen. `auto` cannot land here --
    # it picks the method from the guest kind.
    case "$mode/$kind" in
        agent/lxc) echo "QERR guest $id is a container and cannot be frozen by qemu-guest-agent -- use quiesce=sync or auto" >&2; return 1 ;;
        sync/qemu) echo "QERR guest $id is a VM and 'sync' is the container fallback -- use quiesce=agent or auto" >&2; return 1 ;;
    esac
    case "$kind" in
        qemu)
            if [ "$frozen" = yes ]; then
                echo "QERR guest $id was ALREADY frozen before this run -- leaving it alone, someone should investigate. Refusing to snapshot: this run did not establish the freeze and must not claim it did." >&2
                return 1
            fi
            if gq_freeze "$id" qemu; then
                printf '%s\n' "$id" >> "$frozen_file"
                echo "QLOG froze VM $id via qemu-guest-agent"
            else
                echo "QERR VM $id did not respond to fsfreeze-freeze (agent missing, disabled or busy)" >&2
                return 1
            fi ;;
        lxc)
            if gq_freeze "$id" lxc; then
                echo "QLOG flushed container $id (sync) -- a flush, not a freeze: ZFS has no FIFREEZE"
            else
                echo "QERR flushing container $id failed" >&2
                return 1
            fi ;;
    esac
    return 0
}

# REV-20260730-006 §2: the result of every preparation is COLLECTED. This loop
# used to discard it, so a failed freeze printed QERR and the run went on to
# snapshot anyway and exit 0 -- an operator who asked for application-consistent
# got crash-consistent and was told it worked. If any discovered, running guest
# in scope could not be quiesced, no snapshot is taken at all; the EXIT trap
# still thaws whatever did get frozen.
prep_failed=0
for ds in "${scopes[@]}"; do
    freeze_one "$ds" || prep_failed=$((prep_failed + 1))
done
if [ "$prep_failed" -gt 0 ]; then
    echo "QERR $prep_failed guest(s) could not be quiesced -- NOT taking a snapshot, because it would be crash-consistent while reporting success" >&2
    exit 5
fi

# One atomic `zfs snapshot` per pool, exactly like the local path: a pool is
# the widest unit ZFS will snapshot atomically, and every guest stays frozen
# until the last group is done.
pools=""
for s in "${snaps[@]}"; do
    p=${s%%/*}
    case " $pools " in *" $p "*) ;; *) pools="$pools $p" ;; esac
done
rc=0
for p in $pools; do
    group=()
    for s in "${snaps[@]}"; do [ "${s%%/*}" = "$p" ] && group+=("$s"); done
    if [ -n "$rflag" ]; then
        zfs snapshot "$rflag" "${group[@]}" || { rc=4; break; }
    else
        zfs snapshot "${group[@]}" || { rc=4; break; }
    fi
done

# Thawing, stopping the deadman and deciding whether the frozen list may be
# removed all happen in on_exit -- ONE place, so every path out of this script
# (including a failed snapshot or a `set -u` abort) goes through it.
[ "$rc" -eq 0 ] || echo "QERR the atomic snapshot failed on the source host -- refusing to fall back to unquiesced snapshots" >&2
exit "$rc"
REMOTE_QUIESCE_EOF

# Runs the remote script. $1 user, $2 host, $3 mode, $4 recursive flag ("-r"
# or ""), $5 deadman seconds, then the scope datasets, then "--", then the
# snapshot names to create. Relays the remote's QLOG/QERR lines into this
# run's own log so a frozen-guest failure is as visible as a local one.
quiesce_remote_run() {
    local user="$1" host="$2" mode="$3" rflag="$4" deadman="$5"; shift 5
    local -a scopes=() snaps=()
    local seen_sep=0 a
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen_sep=1; continue; fi
        if [ "$seen_sep" -eq 0 ]; then scopes+=("$a"); else snaps+=("$a"); fi
    done
    local args
    args=$(printf '%q ' "$mode" "$deadman" "$rflag" "${#scopes[@]}" "${scopes[@]}" "${#snaps[@]}" "${snaps[@]}")
    local out rc
    out=$(printf '%s' "$ZFS_REMOTE_QUIESCE_SCRIPT" | ssh "${SSH_OPTS[@]}" "$user@$host" "bash -s -- $args" 2>&1); rc=$?
    local line
    while IFS= read -r line; do
        case "$line" in
            QLOG\ *) log 1 "Quiesce[$host]: ${line#QLOG }" ;;
            QERR\ *) log 0 "Quiesce[$host]: ${line#QERR }" ;;
            "")      ;;
            *)       log 2 "Quiesce[$host]: $line" ;;
        esac
    done <<< "$out"
    case "$rc" in
        0) return 0 ;;
        3) log 0 "Quiesce: $host cannot run remote quiesce safely (see the reason above) -- nothing was frozen. Either re-pair with --as=root, or on that host run: deploy.sh --join <package> --allow-quiesce."; return 3 ;;
        4) return 4 ;;
        5) log 0 "Quiesce: a guest on $host could not be quiesced, so NO snapshot was taken -- a crash-consistent snapshot reported as success is the outcome -q exists to prevent."; return 5 ;;
        6) log 0 "Quiesce: a guest on $host is STILL FROZEN after the thaw failed. The deadman is retrying; if it gives up, thaw it by hand -- the exact command is in the lines above."; return 6 ;;
        *) log 0 "Quiesce: the remote quiesce run failed on $host (exit $rc)"; return 1 ;;
    esac
}

# Short, stable per-target suffix for bookmark names -- lets one source
# dataset feed several targets without their bookmarks colliding or
# overwriting each other. Optional $2 (-i/--identifier) folds a second,
# independent job to the SAME target into the hash too, so it gets its own
# bookmark instead of clobbering the first job's incremental base.
bookmark_target_tag() {
    printf '%s\0%s' "$1" "${2:-}" | md5sum | cut -c1-8
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
    local identifier="${6:-}"
    local tag mark full
    tag=$(bookmark_target_tag "$tgt_dataset" "$identifier")
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
