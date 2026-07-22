#!/bin/bash
set -o pipefail
# snapsend.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Author: [Your Name]
# Refactored: April 04, 2025
# Description: ZFS snapshot manager with force full send
#
# Usage: snapsend.sh [options] DATASETS [REMOTE]
# Options:
#   -m <MESSAGE>      Use MESSAGE as prefix for snapshot name (to label snapshots)
#   -e               Use existing latest snapshot instead of creating a new one
#   -z               Compress data stream with pigz during transfer
#   -l <LEVEL>        Compression level for pigz (default: 6)
#   -v <LEVEL>        Verbosity level for logging (0=errors only, up to 4=debug)
#   -r               Recursive mode (include child datasets in send/recv)
#   -n               Dry-run mode (show conflicting snapshots without sending)
#   -I               Full history send (send all snapshots if no common base)
#   -u               Unmount target filesystem(s) after receive
#   -f               Force full send (destroy target data and send full snapshot)
#   -w               Raw send (zfs send -w): send records exactly as they sit on
#                    disk. For an ENCRYPTED source this ships ciphertext, so the
#                    target never needs the key -- and the source does not need it
#                    loaded either (a non-raw send of an encrypted dataset refuses
#                    with "dataset key must be loaded"). A raw-received target
#                    comes up keystatus=unavailable and mounted=no; no -u needed.
#                    For an UNENCRYPTED source -w is effectively a no-op: verified
#                    on zfs-2.1.9 that raw and non-raw streams interoperate freely
#                    in both directions there. Rawness must NOT change mid-stream
#                    on an encrypted target -- see the guardrail in process_dataset.
#   -p <PORT>         SSH port to use (default: 22)
#   -k <FILE>         Verify remote host keys against this known_hosts file instead
#                     of blindly trusting them (StrictHostKeyChecking=no is the
#                     default when -k is omitted, unchanged from prior versions --
#                     only opt into -k if you've already populated FILE, e.g. via
#                     ssh-keyscan, and verified the fingerprint out of band)
#   -V               Print version and exit
#
# REMOTE format: [user@]host:dataset_path  (for remote replication).
# If REMOTE is omitted or has no ':', the backup is done locally to the target path.
#
# Examples:
#   snapsend.sh -v1 pool/data backuppool/data_backup
#   snapsend.sh -r pool/data user@backuphost:tank/backups/data
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v2.27'
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
RAW_SEND=0
declare -a CONFLICT_SNAPSHOTS=()
STATS_LOG="${STATS_LOG:-/root/scripts/zfs-snapshot-stats.log}"
KNOWN_HOSTS_FILE=""

# Shared helpers (logging, stats, resumable-transfer bookkeeping) live in a
# sibling library so snapsend.sh and snapget.sh can't drift apart on them.
# Sourced here, right after config, so the functions exist before any call --
# they read globals (VERBOSE/STATS_LOG/LOCKDIR/SSH_OPTS) only when called, all
# of which are set by then.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -r "$LIB_DIR/lib-zfs-snap.sh" ]; then
    echo "Error: required library $LIB_DIR/lib-zfs-snap.sh not found (is the repo checkout complete?)" >&2
    exit 1
fi
# shellcheck source=lib-zfs-snap.sh
. "$LIB_DIR/lib-zfs-snap.sh"
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [HELPER FUNCTIONS]
###############################################################################

###############################################################################
#BEGIN 2B [SNAPSHOT METADATA OPERATIONS]
###############################################################################
get_timestamp() {
    local dataset="$1"
    local snapshot="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"
    
    if [ -n "$remote_host" ]; then
        local ts=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -p -o value creation '${dataset}@${snapshot}' 2>/dev/null") || return 1
    else
        local ts=$(zfs get -H -p -o value creation "${dataset}@${snapshot}" 2>/dev/null) || return 1
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
        snaps=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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
    
    local src_snaps=($(get_sorted_snapshots "$src_dataset"))
    local tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host"))

    for tgt_snap in "${tgt_snaps[@]}"; do
        if [[ ! " ${src_snaps[*]} " == *" ${tgt_snap} "* ]] || ! validate_snapshot "$src_dataset" "$tgt_dataset" "$tgt_snap" "$remote_user" "$remote_host"; then
            CONFLICT_SNAPSHOTS+=("${tgt_dataset}@${tgt_snap}")
        fi
    done

    if [ $RECURSIVE -eq 1 ]; then
        local tgt_children
        if [ -n "$remote_host" ]; then
            tgt_children=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list -H -o name -r '$tgt_dataset' 2>/dev/null" | grep -v "^${tgt_dataset}$")
        else
            tgt_children=$(zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | grep -v "^${tgt_dataset}$")
        fi

        for tgt_child in $tgt_children; do
            local child_name="${tgt_child##*/}"
            local src_child="${src_dataset}/${child_name}"
            
            if ! zfs list -H "$src_child" &>/dev/null; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child" "$remote_user" "$remote_host"))
                for snap in "${tgt_child_snaps[@]}"; do
                    CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                done
                continue
            fi

            local child_common=$(find_common_snapshot "$src_child" "$tgt_child" "$remote_user" "$remote_host")
            
            if [[ "$child_common" == "null" ]] || [[ -n "$parent_common" && "$child_common" != "$parent_common" ]]; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child" "$remote_user" "$remote_host"))
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
    
    local src_ts=$(get_timestamp "$src_dataset" "$snapshot")
    local tgt_ts=$(get_timestamp "$tgt_dataset" "$snapshot" "$remote_user" "$remote_host")
    
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
    src_snaps=($(get_sorted_snapshots "$src_dataset")) || return 1

    # A target that does not exist has no snapshots and therefore no common
    # base -- "null", not an error. This is reachable under -w, where the leaf
    # is created by recv rather than pre-created, so the first send legitimately
    # runs against a target that is not there yet.
    local tgt_snaps
    if ! target_exists "$tgt_dataset" "$remote_user" "$remote_host"; then
        echo -n "null"
        return 0
    fi
    tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host")) || return 1

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
    local snapshot_name="${dataset}@${MESSAGE}$(date '+%Y-%m-%d_%H-%M-%S')"
    local recursive_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_flag="-r"
    
    log 1 "Creating new snapshot: $snapshot_name"
    zfs snapshot $recursive_flag "$snapshot_name" || return 1
    echo "$snapshot_name"
}
###############################################################################
#END 3B

###############################################################################
#BEGIN 3D [RESUMABLE TRANSFER SUPPORT]
###############################################################################
# MAX_RESUME_ATTEMPTS and the resume helpers (get_resume_token, abandon_resume,
# resume_state_file, read/increment/reset_resume_attempts) are byte-identical
# between snapsend.sh and snapget.sh, so they live in lib-zfs-snap.sh (sourced
# at the top). See the header comment there.
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
    
    local send_args
    local recv_args
    IFS=' ' read -r -a send_args <<< "$send_cmd"
    IFS=' ' read -r -a recv_args <<< "$recv_cmd"
    
    if [ -n "$remote_host" ]; then
        if [ $COMPRESSION -eq 1 ]; then
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "command -v pigz >/dev/null 2>&1"; then
                log 0 "Compression requested but pigz is not installed on remote host $remote_host"
                return 1
            fi
            if ! "${send_args[@]}" | pigz -$COMPRESSION_LEVEL | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer -q -s $BUFFER_SIZE -m $MEMORY | pigz -d | $recv_cmd"; then
                return 1
            fi
        else
            if ! "${send_args[@]}" | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer -q -s $BUFFER_SIZE -m $MEMORY | $recv_cmd"; then
                return 1
            fi
        fi
    else
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
        local common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        find_conflicting_snapshots "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$common_snapshot"
        return 0
    fi

    if [[ "$src_dataset" == "$tgt_dataset" && -z "$remote_host" ]]; then
        log 1 "Running in local snapshot-only mode"
        snapshot=$(create_snapshot "$src_dataset") || return 1
        log 1 "Successfully created local snapshot: $snapshot"
        return 0
    fi

    if ! zfs list -H "$src_dataset" &>/dev/null; then
        log 0 "Source dataset not found: $src_dataset"
        return 1
    fi

    # Checked here, before anything is created, snapshotted or (under -f)
    # destroyed: a rawness mismatch can never succeed, so a doomed run must not
    # leave side effects behind. Skipped under -f, which destroys the target and
    # so has no seeding left to conflict with. Source is always local here.
    if [ $FORCE_FULL_SEND -ne 1 ]; then
        check_raw_compatibility "$src_dataset" "" "" \
                                "$tgt_dataset" "$remote_user" "$remote_host" \
                                "$RAW_SEND" || return 1
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        local resume_token
        resume_token=$(get_resume_token "$tgt_dataset" "$remote_user" "$remote_host")
        if [ -n "$resume_token" ]; then
            local attempts
            attempts=$(read_resume_attempts "$tgt_dataset")
            if [ "$attempts" -ge "$MAX_RESUME_ATTEMPTS" ]; then
                log 1 "Resume failed $attempts times for $tgt_dataset - abandoning stuck state"
                abandon_resume "$tgt_dataset" "$remote_user" "$remote_host"
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

    # Work out WHAT is going to be sent before touching the target in any way.
    # This ordering is load-bearing, not cosmetic: everything below either
    # creates the target dataset or, under -f, destroys it outright. Resolving
    # the source snapshot afterwards meant a run that could never succeed still
    # got that far -- `-f -e -m <prefix that matches nothing>` destroyed every
    # snapshot and all data on the target and only THEN reported "no source
    # snapshots matching message", leaving the backup gone until the next
    # successful full send. Confirmed live before the fix.
    if [ "$USE_EXISTING_SNAPSHOT" -eq 1 ]; then
        local src_snaps
        src_snaps=($(get_sorted_snapshots "$src_dataset")) || return 1
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
        snapshot=$(create_snapshot "$src_dataset") || return 1
        latest_snap="${snapshot##*@}"
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        log 2 "Creating target dataset: $tgt_dataset"
        # canmount=noauto: a freshly created target starts unmounted and stays
        # that way across zfs receive's own mount/unmount cycles. On Linux,
        # unprivileged users can't mount/unmount at all (unlike illumos), so
        # this is what makes non-root incremental receive into this dataset
        # possible afterward. Only applies to this leaf -- any -p-created
        # ancestor still needs to already exist for a non-root run to succeed.
        # Setting canmount here needs its own delegated 'canmount' property
        # permission (zfs allow) in addition to create/mount/receive -- it is
        # NOT bundled into the 'create' permission despite being set at
        # create time. Confirmed live: "permission denied" without it.
        #
        # EXCEPTION for -w: a raw stream carries the source dataset's own
        # properties, encryption included, so `zfs recv` has to CREATE the leaf
        # itself. Pre-creating it here makes it a plain unencrypted dataset and
        # ZFS then refuses the stream outright:
        #   "zfs receive -F cannot be used to destroy an encrypted filesystem
        #    or overwrite an unencrypted one with an encrypted one"
        # So under -w only the PARENT is ensured (ancestors must exist for a
        # non-root receive) and the leaf is left to recv. canmount=noauto is
        # reapplied after a successful transfer instead of at create time.
        local create_target="$tgt_dataset"
        [ $RAW_SEND -eq 1 ] && create_target="${tgt_dataset%/*}"
        if [ -n "$remote_host" ]; then
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list '$create_target' >/dev/null 2>&1 || zfs create -p -o canmount=noauto '$create_target'" || return 1
        else
            zfs list "$create_target" >/dev/null 2>&1 || zfs create -p -o canmount=noauto "$create_target" || return 1
        fi
    fi

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        log 1 "Force full send activated (-f)"

        local protected_snaps
        if [ -n "$remote_host" ]; then
            protected_snaps=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list -t snapshot -H -o name -r '$tgt_dataset' 2>/dev/null" | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        else
            protected_snaps=$(zfs list -t snapshot -H -o name -r "$tgt_dataset" 2>/dev/null | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        fi
        if [ -n "$protected_snaps" ]; then
            log 0 "Refusing force full send: $tgt_dataset (or a descendant) holds snapshot(s) reserved by Proxmox VE (replication/migration/vzdump):"
            log 0 "$protected_snaps"
            log 0 "This target looks like it's managed by Proxmox VE outside this tool -- force full send would destroy that state and break replication/migration/backup. Remove the conflicting job/snapshots yourself first if this is intentional."
            return 1
        fi

        log 2 "Destroying all snapshots and data on target dataset"

        local destroy_cmd="zfs list -H -o name -r \"$tgt_dataset\" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R \"\$@\" 2>/dev/null || true' -- {}"
        log 4 "RAW ZFS DESTROY COMMAND: $destroy_cmd"  # debug logging
        
        if [ -n "$remote_host" ]; then
            log 4 "EXECUTING DESTROY ON REMOTE: $remote_host"
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$destroy_cmd"
        else
            log 4 "EXECUTING DESTROY LOCALLY"
            zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R "$@" 2>/dev/null || true' -- {} || true
        fi

        # Under -w the leaf must be left for recv to create from the raw stream
        # (see the creation block above) -- recreating it plain here would put
        # back exactly the unencrypted dataset the raw stream cannot land on,
        # turning every -f -w run into a guaranteed failure. The destroy above
        # already removed the leaf; ancestors survive it, so recv has what it
        # needs.
        if [ $RAW_SEND -eq 1 ]; then
            log 2 "Not recreating target dataset (-w: raw receive creates it)"
        else
        log 2 "Recreating target dataset"
        local create_cmd="zfs create -p -o canmount=noauto \"$tgt_dataset\""
        log 4 "RAW ZFS CREATE COMMAND: $create_cmd"

        if [ -n "$remote_host" ]; then
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$create_cmd" || {
                log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root on $remote_host."
                return 1
            }
        else
            zfs create -p -o canmount=noauto "$tgt_dataset" || {
                log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root."
                return 1
            }
        fi
        fi
    fi

    # Under -w the leaf target is deliberately NOT pre-created (recv builds it
    # from the raw stream), so on a first send it does not exist yet and
    # get_sorted_snapshots fails -- `zfs list` on a missing dataset exits 1 and
    # pipefail propagates it. That is not an error here, it is the first-send
    # case: a target that does not exist simply has no snapshots. Every other
    # mode still pre-creates the target, so a failure there remains a real one
    # and is still reported.
    local tgt_snaps
    if [ $RAW_SEND -eq 1 ] && ! target_exists "$tgt_dataset" "$remote_user" "$remote_host"; then
        log 2 "Target does not exist yet -- raw receive will create it"
        tgt_snaps=()
    else
        tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host")) || return 1
    fi

    log 3 "LATEST SOURCE SNAPSHOT: ${snapshot}"
    log 3 "EXISTING TARGET SNAPSHOTS:"
    for snap in "${tgt_snaps[@]}"; do
        log 3 "  ${tgt_dataset}@${snap}"
    done

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        log 1 "Force full send activated (-f)"
        local common_snapshot="null"
    else
        if [[ " ${tgt_snaps[*]} " == *" ${latest_snap} "* ]]; then
            if validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
                log 1 "Snapshot already exists in target - skipping"
                return 0
            else
                log 1 "Snapshot exists but timestamps differ - forcing full send"
                local common_snapshot="null"
            fi
        else
            local common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        fi
    fi

    local send_cmd
    local recursive_send_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_send_flag="-R"

    # -w rides along on every send path below EXCEPT the resume path above:
    # `zfs send -t <token>` already encodes rawness in the token, and passing -w
    # on top of it does not just error, it aborts (SIGABRT / rc=134,
    # "internal error: Invalid argument" on zfs-2.1.9). Verified, not assumed.
    #
    # Note the two send_args word-splits in transfer_data use IFS=' ', and space
    # is IFS whitespace, so runs of spaces collapse -- an empty flag var leaves
    # no stray empty argument. Same reason recursive_send_flag can be empty.
    local raw_send_flag=""
    [ $RAW_SEND -eq 1 ] && raw_send_flag="-w"

    local bookmark_base=""
    if [[ "$common_snapshot" == "null" ]] && [ $RECURSIVE -ne 1 ]; then
        # No common snapshot survives on either end -- before giving up to a
        # FULL send, check for a bookmark left by a prior run (see
        # lib-zfs-snap.sh). Source is always local in snapsend.sh, so
        # find_bookmark_base gets no remote args; the target's head GUID is
        # queried with the same remote params tgt_snaps already used.
        local tgt_head_guid=""
        if [ ${#tgt_snaps[@]} -gt 0 ]; then
            tgt_head_guid=$(get_snapshot_guid "$tgt_dataset" "${tgt_snaps[-1]}" "$remote_user" "$remote_host")
        fi
        bookmark_base=$(find_bookmark_base "$src_dataset" "$tgt_head_guid")
    fi

    if [[ "$common_snapshot" != "null" ]]; then
        log 1 "Found valid common snapshot: ${src_dataset}@${common_snapshot}"
        send_cmd="zfs send $raw_send_flag $recursive_send_flag -I ${src_dataset}@${common_snapshot} $snapshot"
    elif [ -n "$bookmark_base" ]; then
        log 1 "No common snapshot, but a bookmark still anchors an incremental: $bookmark_base"
        send_cmd="zfs send $raw_send_flag -i $bookmark_base $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history send"
            send_cmd="zfs send $raw_send_flag $recursive_send_flag -R $snapshot"
        else
            log 1 "Performing standard full send"
            send_cmd="zfs send $raw_send_flag $recursive_send_flag $snapshot"
        fi
    fi

    # -s makes ZFS SAVE partial receive state on interruption (and expose a
    # receive_resume_token) instead of rolling it back -- this is the
    # precondition for the resumable-transfer logic above to ever fire.
    local recv_flags="-F -s"
    [ $UNMOUNT -eq 1 ] && recv_flags="$recv_flags -u"
    local recv_cmd="zfs recv $recv_flags $tgt_dataset"

    log 4 "RAW ZFS SEND COMMAND: $send_cmd"
    log 4 "RAW ZFS RECV COMMAND: $recv_cmd"

    log 1 "Starting transfer..."
    transfer_data "$send_cmd" "$recv_cmd" "$remote_host" "$remote_user" || {
        log 0 "Transfer failed"
        [ $FORCE_FULL_SEND -eq 1 ] && log 0 "Hint: -f receives with a forced rollback, which needs to mount/unmount the target. On Linux, non-root users cannot do that even with full 'zfs allow' delegation -- if this failed on a mount/unmount permission error, -f requires root${remote_host:+ on $remote_host}."
        return 1
    }

    # Under -w the leaf was created by recv, not by us, so it never got
    # canmount=noauto at create time. Reapply it now: it is what keeps the
    # target unmounted across future receives and makes non-root incremental
    # receive possible. Best-effort -- an encrypted target is already unmounted
    # (keystatus=unavailable), so failing here costs nothing immediate.
    if [ $RAW_SEND -eq 1 ]; then
        if [ -n "$remote_host" ]; then
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs set canmount=noauto '$tgt_dataset'" 2>/dev/null \
                || log 2 "Could not set canmount=noauto on $tgt_dataset (needs delegated 'canmount')"
        else
            zfs set canmount=noauto "$tgt_dataset" 2>/dev/null \
                || log 2 "Could not set canmount=noauto on $tgt_dataset (needs delegated 'canmount')"
        fi
    fi

    # Refresh the per-target bookmark to what was just sent, regardless of
    # which path got us here (-I, -i bookmark, or FULL) -- see
    # record_send_bookmark in lib-zfs-snap.sh. Source is always local here.
    [ $RECURSIVE -ne 1 ] && record_send_bookmark "$src_dataset" "$latest_snap" "$tgt_dataset"

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
while getopts "m:ezl:v:rnIufwVp:k:" opt; do
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
        w) RAW_SEND=1;;
        p) PORT="$OPTARG";;
        k) KNOWN_HOSTS_FILE="$OPTARG";;
        V) echo "$VERSION"; exit 0;;
        *)
            echo "B��d: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -l -v -r -n -I -u -f -w -p -k -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

[ $# -ge 1 ] || { echo "U�ycie: $0 [opcje] DATASETS [REMOTE]" >&2; exit 1; }
###############################################################################
#END 5A

# Verify required commands are available
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

# Built once, used by every ssh invocation below. Default (-k omitted) is
# UNCHANGED from prior versions: StrictHostKeyChecking=no. Only opt into -k on
# a host where KNOWN_HOSTS_FILE has already been populated (e.g. ssh-keyscan)
# and the fingerprint verified out of band -- e.g. a backup host reaching
# across an untrusted network, unlike the trusted-LAN default use case here.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=no -p "$PORT")
fi

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
LOCKDIR="${LOCKDIR:-/var/run}"
[ -d "$LOCKDIR" ] && [ -w "$LOCKDIR" ] || { echo "Error: LOCKDIR '$LOCKDIR' is not a writable directory (create it or point LOCKDIR at one, e.g. LOCKDIR=~/run for a non-root run)." >&2; exit 1; }
LOCKFILE="$LOCKDIR/$(basename "$0").${LOCK_KEY}.lock"
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

TARGET_BASE=""
REMOTE_USER="root"
REMOTE_HOST=""

if [[ -n "$REMOTE" ]]; then
    if [[ "$REMOTE" == *":"* ]]; then
        IFS=':' read -r remote_part target_base <<< "$REMOTE"
        
        if [[ "$remote_part" == *"@"* ]]; then
            IFS='@' read -r REMOTE_USER REMOTE_HOST <<< "$remote_part"
        else
            REMOTE_HOST="$remote_part"
        fi
        
        TARGET_BASE=$(echo "$target_base" | sed 's:^/+::; s:/+$::')
    else
        TARGET_BASE="$REMOTE"
    fi
fi

declare -a FAILED_DATASETS=()
for dataset in "${DATASETS[@]}"; do
    if [ -n "$TARGET_BASE" ]; then
        tgt_path="${TARGET_BASE}/${dataset}"
    else
        tgt_path="$dataset"
    fi
    tgt_path=$(echo "$tgt_path" | sed 's:///*:/:g; s:^/::')
    
    log 1 "Processing: $dataset => ${REMOTE_HOST:-local}:$tgt_path"
    
    if [ $DRY_RUN -eq 1 ]; then
        process_dataset "$dataset" "$tgt_path" "$REMOTE_USER" "$REMOTE_HOST"
    else
        stats_start=$(date +%s)
        if process_dataset "$dataset" "$tgt_path" "$REMOTE_USER" "$REMOTE_HOST"; then
            emit_stats "$dataset" "$tgt_path" "success" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
        else
            emit_stats "$dataset" "$tgt_path" "failed" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
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
