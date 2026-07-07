#!/bin/bash
set -o pipefail
# snapget.sh (run with -V for version; see git log for full changelog) - twin of snapsend.sh
# ------------------------------------------------------------------------------
# Author: [Your Name]
# Refactored: March 17, 2026
# Description: ZFS snapshot manager with force full pull
#
# Usage: snapget.sh [options] DATASETS [REMOTE]
# Options:
#   -m <MESSAGE>      Use MESSAGE as prefix for snapshot name (to label snapshots)
#   -e               Use existing latest snapshot on source instead of creating a new one
#   -z               Compress data stream with pigz during transfer
#   -l <LEVEL>        Compression level for pigz (default: 6)
#   -v <LEVEL>        Verbosity level for logging (0=errors only, up to 4=debug)
#   -r               Recursive mode (include child datasets in send/recv)
#   -n               Dry-run mode (show conflicting snapshots without receiving)
#   -I               Full history receive (receive all snapshots if no common base)
#   -u               Unmount target filesystem(s) after receive
#   -f               Force full pull (destroy local target data and receive full snapshot)
#   -V               Print version and exit
#
# REMOTE format: [user@]host:dataset_path  (source side for pull replication).
# If REMOTE is omitted or has no ':', the operation is done locally from source path.
#
# Examples:
#   snapget.sh -v1 pool/data backuppool/data_backup
#   snapget.sh -r pool/data user@sourcehost:tank/backups/data
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v2.16'
MESSAGE=""
VERBOSE=0
COMPRESSION=0
COMPRESSION_LEVEL=6
BUFFER_SIZE="128k"
MEMORY="1G"
PORT=22
USE_EXISTING_SNAPSHOT=0
RECURSIVE=0
DRY_RUN=0
FULL_HISTORY_SEND=0
UNMOUNT=0
FORCE_FULL_SEND=0
declare -a CONFLICT_SNAPSHOTS=()
STATS_LOG="/root/scripts/zfs-snapshot-stats.log"
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [HELPER FUNCTIONS]
###############################################################################

###############################################################################
#BEGIN 2A [LOGGING FUNCTIONS]
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
#END 2A

###############################################################################
#BEGIN 2B [SNAPSHOT METADATA OPERATIONS]
###############################################################################
get_timestamp() {
    local dataset="$1"
    local snapshot="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"

    if [ -n "$remote_host" ]; then
        local ts
        ts=$(ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" \
            "zfs get -H -p -o value creation '${dataset}@${snapshot}' 2>/dev/null") || return 1
    else
        local ts
        ts=$(zfs get -H -p -o value creation "${dataset}@${snapshot}" 2>/dev/null) || return 1
    fi
    echo "$ts"
}
###############################################################################
#END 2B

###############################################################################
#BEGIN 2C [SNAPSHOT LIST OPERATIONS]
###############################################################################
get_sorted_snapshots() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"

    local depth_option="-d 1"
    [ $RECURSIVE -eq 1 ] && depth_option=""

    local snaps
    if [ -n "$remote_host" ]; then
        snaps=$(ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" \
            "zfs list -H -o name -t snapshot -s creation $depth_option '$dataset' 2>/dev/null | awk -F '@' '{print \$2}'") || return 1
    else
        snaps=$(zfs list -H -o name -t snapshot -s creation $depth_option "$dataset" 2>/dev/null | awk -F '@' '{print $2}') || return 1
    fi
    echo "$snaps"
}
###############################################################################
#END 2C

###############################################################################
#BEGIN 2D [CONFLICT DETECTION LOGIC]
###############################################################################
find_conflicting_snapshots() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    local parent_common="${5:-}"

    local src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host"))
    local tgt_snaps=($(get_sorted_snapshots "$tgt_dataset"))

    for tgt_snap in "${tgt_snaps[@]}"; do
        if [[ ! " ${src_snaps[*]} " == *" ${tgt_snap} "* ]] || ! validate_snapshot "$src_dataset" "$tgt_dataset" "$tgt_snap" "$remote_user" "$remote_host"; then
            CONFLICT_SNAPSHOTS+=("${tgt_dataset}@${tgt_snap}")
        fi
    done

    if [ $RECURSIVE -eq 1 ]; then
        local tgt_children
        tgt_children=$(zfs list -H -o name -r "$tgt_dataset" | grep -v "^${tgt_dataset}$")

        for tgt_child in $tgt_children; do
            local child_name="${tgt_child##*/}"
            local src_child="${src_dataset}/${child_name}"

            if [ -n "$remote_host" ]; then
                if ! ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "zfs list -H '$src_child' >/dev/null 2>&1"; then
                    local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child"))
                    for snap in "${tgt_child_snaps[@]}"; do
                        CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                    done
                    continue
                fi
            else
                if ! zfs list -H "$src_child" &>/dev/null; then
                    local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child"))
                    for snap in "${tgt_child_snaps[@]}"; do
                        CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                    done
                    continue
                fi
            fi

            local child_common
            child_common=$(find_common_snapshot "$src_child" "$tgt_child" "$remote_user" "$remote_host")

            if [[ "$child_common" == "null" ]] || [[ -n "$parent_common" && "$child_common" != "$parent_common" ]]; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child"))
                for snap in "${tgt_child_snaps[@]}"; do
                    CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                done
            fi

            find_conflicting_snapshots "$src_child" "$tgt_child" "$remote_user" "$remote_host" "$child_common"
        done
    fi
}
###############################################################################
#END 2D
###############################################################################
###############################################################################
#BEGIN 2F [HOST VALIDATION]
###############################################################################
validate_remote_host() {
    local remote_user="$1"
    local remote_host="$2"

    [ -z "$remote_host" ] && return 0  # Skip check for local transfers

    local local_machine_id
    local_machine_id=$(cat /etc/machine-id 2>/dev/null || echo "UNKNOWN")

    local remote_machine_id
    remote_machine_id=$(ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" \
        "cat /etc/machine-id 2>/dev/null || echo 'UNKNOWN'" 2>/dev/null)

    if [[ "$local_machine_id" != "UNKNOWN" && "$local_machine_id" == "$remote_machine_id" ]]; then
        log 0 "CRITICAL: Remote host $remote_host has identical machine-id to local system"
        log 0 "This indicates loopback transfer attempt. Aborting."
        exit 1
    fi

    if [[ "$local_machine_id" == "UNKNOWN" ]]; then
        local local_hostname
        local_hostname=$(hostname -f)
        local remote_hostname
        remote_hostname=$(ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "hostname -f")

        if [[ "$local_hostname" == "$remote_hostname" ]]; then
            log 0 "CRITICAL: Remote hostname matches local ($local_hostname)"
            log 0 "Possible loopback transfer. Use local mode instead."
            exit 1
        fi
    fi
}
###############################################################################
#END 2F

#END 2

###############################################################################
#BEGIN 3 [CORE LOGIC]
###############################################################################

###############################################################################
#BEGIN 3A [SNAPSHOT VALIDATION]
###############################################################################
validate_snapshot() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local snapshot="$3"
    local remote_user="$4"
    local remote_host="$5"

    local src_ts
    src_ts=$(get_timestamp "$src_dataset" "$snapshot" "$remote_user" "$remote_host")
    local tgt_ts
    tgt_ts=$(get_timestamp "$tgt_dataset" "$snapshot")

    if [ -z "$src_ts" ] || [ -z "$tgt_ts" ]; then
        return 1
    fi
    [ "$src_ts" -eq "$tgt_ts" ] && return 0 || return 1
}
###############################################################################
#END 3A

###############################################################################
#BEGIN 3B [SNAPSHOT MANAGEMENT]
###############################################################################
find_common_snapshot() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"

    local src_snaps
    src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host")) || return 1

    local tgt_snaps
    tgt_snaps=($(get_sorted_snapshots "$tgt_dataset")) || return 1

    for ((i=${#src_snaps[@]}-1; i>=0; i--)); do
        for ((j=${#tgt_snaps[@]}-1; j>=0; j--)); do
            if [[ "${src_snaps[$i]}" == "${tgt_snaps[$j]}" ]]; then
                validate_snapshot "$src_dataset" "$tgt_dataset" "${src_snaps[$i]}" "$remote_user" "$remote_host" && {
                    echo -n "${src_snaps[$i]}"
                    return 0
                }
            fi
        done
    done

    echo -n "null"
}

create_snapshot() {
    local dataset="$1"
    local remote_user="$2"
    local remote_host="$3"
    local snapshot_name="${dataset}@${MESSAGE}$(date '+%Y-%m-%d_%H-%M-%S')"
    local recursive_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_flag="-r"

    log 1 "Creating new source snapshot: $snapshot_name"
    if [ -n "$remote_host" ]; then
        ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" \
            "zfs snapshot $recursive_flag '$snapshot_name'" || return 1
    else
        zfs snapshot $recursive_flag "$snapshot_name" || return 1
    fi
    echo "$snapshot_name"
}
###############################################################################
#END 3B

###############################################################################
#BEGIN 3D [RESUMABLE TRANSFER SUPPORT]
###############################################################################
# If a prior zfs recv into $tgt_dataset was interrupted mid-stream, ZFS leaves
# a resume token on the TARGET dataset (receive_resume_token property). In
# snapget.sh the target is ALWAYS local (remote_host here refers to the
# SOURCE), so these helpers are always called with an empty remote_host/user
# -- kept as parameters anyway for symmetry with snapsend.sh's identical
# helpers. Resume via `zfs send -t <token>` (run on whichever side holds the
# source -- transfer_data() already routes that through ssh when needed);
# give up (via `zfs receive -A`, which discards only the partial state, not
# the dataset's existing history) after MAX_RESUME_ATTEMPTS failed attempts.
MAX_RESUME_ATTEMPTS=3

get_resume_token() {
    local tgt_dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    local token
    if [ -n "$remote_host" ]; then
        token=$(ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" \
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
        ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "zfs receive -A '$tgt_dataset'"
    else
        zfs receive -A "$tgt_dataset"
    fi
}

resume_state_file() {
    echo "/var/run/$(basename "$0").resume-attempts.$(echo "$1" | tr '/' '_')"
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
#END 3D

###############################################################################
#BEGIN 3C [DATA TRANSFER OPERATIONS]
###############################################################################
transfer_data() {
    local send_cmd="$1"
    local recv_cmd="$2"
    local remote_host="$3"
    local remote_user="$4"

    log 3 "EXECUTING TRANSFER:"
    log 3 "SEND CMD: $send_cmd"
    log 3 "RECV CMD: $recv_cmd"

    local recv_args
    IFS=' ' read -r -a recv_args <<< "$recv_cmd"

    if [ -n "$remote_host" ]; then
        if [ $COMPRESSION -eq 1 ]; then
            if ! ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "command -v pigz >/dev/null 2>&1"; then
                log 0 "Compression requested but pigz is not installed on remote host $remote_host"
                return 1
            fi
            if ! ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "$send_cmd | pigz -$COMPRESSION_LEVEL" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | pigz -d | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "$send_cmd" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | "${recv_args[@]}"; then
                return 1
            fi
        fi
    else
        local send_args
        IFS=' ' read -r -a send_args <<< "$send_cmd"
        if [ $COMPRESSION -eq 1 ]; then
            if ! "${send_args[@]}" | pigz -$COMPRESSION_LEVEL | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | pigz -d | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! "${send_args[@]}" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | "${recv_args[@]}"; then
                return 1
            fi
        fi
    fi
}
###############################################################################
#END 3C
###############################################################################
#END 3

###############################################################################
#BEGIN 4 [MAIN PROCESSING]
###############################################################################
process_dataset() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    STATS_RESUMED="no"
    validate_remote_host "$remote_user" "$remote_host"
    log 3 "================================================"
    log 3 "PROCESSING DATASET:"
    log 3 "SRC: $src_dataset"
    log 3 "TGT: $tgt_dataset"
    log 3 "REMOTE: $remote_user@$remote_host"
    log 3 "================================================"

    if [ $DRY_RUN -eq 1 ]; then
        local common_snapshot
        common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        find_conflicting_snapshots "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$common_snapshot"
        return 0
    fi

    if [[ "$src_dataset" == "$tgt_dataset" && -z "$remote_host" ]]; then
        log 1 "Running in local snapshot-only mode"
        snapshot=$(create_snapshot "$src_dataset" "$remote_user" "$remote_host") || return 1
        log 1 "Successfully created local snapshot: $snapshot"
        return 0
    fi

    if [ -n "$remote_host" ]; then
        if ! ssh -o StrictHostKeyChecking=no -p "$PORT" "$remote_user@$remote_host" "zfs list -H '$src_dataset' >/dev/null 2>&1"; then
            log 0 "Source dataset not found on remote host: $src_dataset"
            return 1
        fi
    else
        if ! zfs list -H "$src_dataset" &>/dev/null; then
            log 0 "Source dataset not found: $src_dataset"
            return 1
        fi
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        # target is always local in snapget.sh -- pass empty remote_user/host
        local resume_token
        resume_token=$(get_resume_token "$tgt_dataset" "" "")
        if [ -n "$resume_token" ]; then
            local attempts
            attempts=$(read_resume_attempts "$tgt_dataset")
            if [ "$attempts" -ge "$MAX_RESUME_ATTEMPTS" ]; then
                log 1 "Resume failed $attempts times for $tgt_dataset - abandoning stuck state"
                abandon_resume "$tgt_dataset" "" ""
                reset_resume_attempts "$tgt_dataset"
                log 1 "Abandoned - falling through to normal transfer logic"
            else
                increment_resume_attempts "$tgt_dataset"
                log 1 "Found resume token for $tgt_dataset - resuming interrupted transfer (attempt $((attempts + 1))/$MAX_RESUME_ATTEMPTS)"
                local resume_recv_flags="-F -s"
                [ $UNMOUNT -eq 1 ] && resume_recv_flags="$resume_recv_flags -u"
                local resume_send_cmd="zfs send -t $resume_token"
                local resume_recv_cmd="zfs recv $resume_recv_flags $tgt_dataset"
                log 4 "RAW RESUME SEND COMMAND: $resume_send_cmd"
                log 4 "RAW RESUME RECV COMMAND: $resume_recv_cmd"
                if transfer_data "$resume_send_cmd" "$resume_recv_cmd" "$remote_host" "$remote_user"; then
                    reset_resume_attempts "$tgt_dataset"
                    STATS_RESUMED="yes"
                    log 1 "Resumed transfer completed successfully"
                    return 0
                else
                    log 0 "Resume attempt failed"
                    return 1
                fi
            fi
        fi
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        log 2 "Creating target dataset: $tgt_dataset"
        zfs list "$tgt_dataset" >/dev/null 2>&1 || zfs create -p "$tgt_dataset" || return 1
    fi

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        log 1 "Force full pull activated (-f)"
        log 2 "Destroying all snapshots and data on local target dataset"

        log 4 "EXECUTING DESTROY LOCALLY"
        zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R "$@" 2>/dev/null || true' -- {} || true

        log 2 "Recreating target dataset"
        zfs create -p "$tgt_dataset" || return 1
    fi

    if [ "$USE_EXISTING_SNAPSHOT" -eq 1 ]; then
        local src_snaps
        src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host")) || return 1
        if [ ${#src_snaps[@]} -eq 0 ]; then
            log 0 "No source snapshots found"
            return 1
        fi

        if [ -n "$MESSAGE" ]; then
            src_snaps=($(printf "%s\n" "${src_snaps[@]}" | grep "^$MESSAGE"))
            if [ ${#src_snaps[@]} -eq 0 ]; then
                log 0 "No source snapshots matching message: $MESSAGE"
                return 1
            fi
        fi

        local latest_snap="${src_snaps[-1]}"
        snapshot="${src_dataset}@${latest_snap}"
    else
        snapshot=$(create_snapshot "$src_dataset" "$remote_user" "$remote_host") || return 1
        latest_snap="${snapshot##*@}"
    fi

    local tgt_snaps
    tgt_snaps=($(get_sorted_snapshots "$tgt_dataset")) || return 1

    log 3 "LATEST SOURCE SNAPSHOT: ${snapshot}"
    log 3 "EXISTING TARGET SNAPSHOTS:"
    for snap in "${tgt_snaps[@]}"; do
        log 3 "  ${tgt_dataset}@${snap}"
    done

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        log 1 "Force full pull activated (-f)"
        local common_snapshot="null"
    else
        if [[ " ${tgt_snaps[*]} " == *" ${latest_snap} "* ]]; then
            if validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
                log 1 "Snapshot already exists in target - skipping"
                return 0
            else
                log 1 "Snapshot exists but timestamps differ - forcing full pull"
                local common_snapshot="null"
            fi
        else
            local common_snapshot
            common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        fi
    fi

    local send_cmd
    local recursive_send_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_send_flag="-R"

    if [[ "$common_snapshot" != "null" ]]; then
        log 1 "Found valid common snapshot: ${src_dataset}@${common_snapshot}"
        send_cmd="zfs send $recursive_send_flag -I ${src_dataset}@${common_snapshot} $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history pull"
            send_cmd="zfs send $recursive_send_flag -R $snapshot"
        else
            log 1 "Performing standard full pull"
            send_cmd="zfs send $recursive_send_flag $snapshot"
        fi
    fi

    # -s makes ZFS SAVE partial receive state on interruption (and expose a
    # receive_resume_token) instead of rolling it back -- this is the
    # precondition for the resumable-transfer logic above to ever fire.
    local recv_flags="-F -s"
    [ $UNMOUNT -eq 1 ] && recv_flags="$recv_flags -u"
    local recv_cmd="zfs recv $recv_flags $tgt_dataset"

    log 4 "RAW REMOTE ZFS SEND COMMAND: $send_cmd"
    log 4 "RAW LOCAL ZFS RECV COMMAND: $recv_cmd"

    log 1 "Starting transfer..."
    transfer_data "$send_cmd" "$recv_cmd" "$remote_host" "$remote_user" || {
        log 0 "Transfer failed"
        return 1
    }

    log 1 "Transfer completed successfully"
    return 0
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [ENTRY POINT]
###############################################################################

###############################################################################
#BEGIN 5A [ARGUMENT PARSING]
###############################################################################
while getopts "m:ezl:v:rnIufV" opt; do
    case $opt in
        m) MESSAGE="$OPTARG";;
        e) USE_EXISTING_SNAPSHOT=1;;
        z) COMPRESSION=1;;
        l) COMPRESSION_LEVEL="$OPTARG";;
        v) VERBOSE="$OPTARG";;
        r) RECURSIVE=1;;
        n) DRY_RUN=1;;
        I) FULL_HISTORY_SEND=1;;
        u) UNMOUNT=1;;
        f) FORCE_FULL_SEND=1;;
        V) echo "$VERSION"; exit 0;;
        *)
            echo "Błąd: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -l -v -r -n -I -u -f -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

[ $# -ge 1 ] || { echo "Użycie: $0 [opcje] DATASETS [REMOTE]" >&2; exit 1; }
###############################################################################
#END 5A

if [ $COMPRESSION -eq 1 ] && ! command -v pigz >/dev/null; then
    log 0 "Compression requested but pigz is not installed."
    exit 1
fi
if ! command -v mbuffer >/dev/null; then
    log 0 "Required command 'mbuffer' not found. Install mbuffer to proceed."
    exit 1
fi

command -v zfs >/dev/null || { echo "Error: zfs command not found." >&2; exit 1; }
command -v flock >/dev/null || { echo "Error: flock command not found." >&2; exit 1; }

###############################################################################
#BEGIN 5A2 [SINGLE-INSTANCE LOCK]
###############################################################################
# Prevent two invocations that target the SAME datasets+remote from racing to
# send/recv into the same target dataset (e.g. a manual run overlapping with a
# scheduled cron run). The lock is keyed on the operation target (datasets +
# remote), NOT just the script name, so unrelated jobs (different datasets) run
# concurrently instead of blocking each other. Options (-v, -z, ...) are
# deliberately excluded from the key, so a manual run and a cron run of the same
# target still serialize even if their option formatting differs (-v3 vs -v 3).
LOCK_KEY=$(printf '%s\0%s' "$1" "${2:-}" | md5sum | cut -d' ' -f1)
LOCKFILE="/var/run/$(basename "$0").${LOCK_KEY}.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log 0 "Another instance targeting the same datasets is already running (lock: $LOCKFILE) - skipping this run"
    emit_stats "$1" "${2:-}" "skipped_lock" "0"
    exit 0
fi
###############################################################################
#END 5A2

###############################################################################
#BEGIN 5B [MAIN LOGIC]
###############################################################################
DATASETS=$1
REMOTE=${2:-}
IFS=',' read -ra DATASETS <<< "$DATASETS"

SOURCE_BASE=""
REMOTE_USER="root"
REMOTE_HOST=""

if [[ -n "$REMOTE" ]]; then
    if [[ "$REMOTE" == *":"* ]]; then
        IFS=':' read -r remote_part source_base <<< "$REMOTE"

        if [[ "$remote_part" == *"@"* ]]; then
            IFS='@' read -r REMOTE_USER REMOTE_HOST <<< "$remote_part"
        else
            REMOTE_HOST="$remote_part"
        fi

        SOURCE_BASE=$(echo "$source_base" | sed 's:^/+::; s:/+$::')
    else
        SOURCE_BASE="$REMOTE"
    fi
fi

declare -a FAILED_DATASETS=()
for dataset in "${DATASETS[@]}"; do
    if [ -n "$SOURCE_BASE" ]; then
        src_path="${SOURCE_BASE}/${dataset}"
    else
        src_path="$dataset"
    fi
    src_path=$(echo "$src_path" | sed 's:///*:/:g; s:^/::')

    log 1 "Processing: ${REMOTE_HOST:-local}:$src_path => $dataset"

    if [ $DRY_RUN -eq 1 ]; then
        process_dataset "$src_path" "$dataset" "$REMOTE_USER" "$REMOTE_HOST"
    else
        stats_start=$(date +%s)
        if process_dataset "$src_path" "$dataset" "$REMOTE_USER" "$REMOTE_HOST"; then
            emit_stats "$dataset" "$src_path" "success" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
        else
            emit_stats "$dataset" "$src_path" "failed" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
            FAILED_DATASETS+=("$dataset")
        fi
    fi
done

if [ $DRY_RUN -eq 1 ]; then
    if [ ${#CONFLICT_SNAPSHOTS[@]} -gt 0 ]; then
        printf "%s\n" "${CONFLICT_SNAPSHOTS[@]}" | sort -u
        exit 1
    else
        exit 0
    fi
else
    if [ ${#FAILED_DATASETS[@]} -gt 0 ]; then
        printf "%s\n" "${FAILED_DATASETS[@]}" >&2
        exit 1
    else
        echo "All datasets processed successfully" >&2
        exit 0
    fi
fi
###############################################################################
#END 5B
###############################################################################
#END 5
