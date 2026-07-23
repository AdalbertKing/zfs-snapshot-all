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
#   -z               Compress the data stream (default compressor: zstd).
#                    Ignored, with a log line, when the source is local: there
#                    is no link between the compressor and the decompressor,
#                    only a pipe on this same host, so it is pure CPU cost.
#   -Z               Compress with zstd explicitly (same as -z; kept for clarity)
#   -g               Compress with pigz instead -- the escape hatch for a host
#                    where zstd is missing or unwanted
#   -l <LEVEL>        Compression level (default: 3 for zstd, 6 for pigz -- each
#                    tool's own default; ranges differ, zstd 1-19 vs pigz 1-9)
#
# The compressor flags are last-one-wins, so appending one to an existing command
# is always well-defined.
#
# WHY zstd IS THE DEFAULT (measured 2026-07-22 on pve0, Xeon E5-1620 v2, 8 cores,
# against a real 1.5 GB `zfs send` stream of a production VM disk):
#
#     compressor      ratio    MB/s      effective MB/s over a 1Gbps link
#     zstd -3 -T0     2.34x     454      292   <- best overall
#     zstd -1 -T0     2.13x     739      266
#     zstd -9 -T0     2.48x      79       79
#     pigz -6         2.19x     143      143   <- the previous default
#     pigz -1         2.05x     265      256
#     lzop -1         1.67x     351      209
#
# zstd -3 beats the old pigz -6 default on BOTH axes at once: a better ratio AND
# ~3.2x the throughput, so this is not a speed-vs-size trade. Note the effective
# column: on a fast link the LINK is the bottleneck, so the higher ratio wins and
# zstd -3 beats even the faster zstd -1. Higher zstd levels only pay off below
# ~5 Mbps, and then by ~6% for 5.7x the CPU -- not worth a default.
# Requires the chosen compressor on BOTH ends (checked before transfer).
#   -v <LEVEL>        Verbosity level for logging (0=errors only, up to 4=debug)
#   -r               Recursive mode (include child datasets in send/recv)
#   -n               Dry-run mode (show conflicting snapshots without receiving)
#   -I               Full history receive (receive all snapshots if no common base)
#   -u               Unmount target filesystem(s) after receive
#   -f               Force full pull (destroy local target data and receive full snapshot)
#   -w               Raw send (zfs send -w on the REMOTE source): pull records
#                    exactly as they sit on disk. For an ENCRYPTED source this
#                    pulls ciphertext, so this host never needs the key -- and the
#                    source does not need it loaded either (a non-raw send of an
#                    encrypted dataset refuses with "dataset key must be loaded").
#                    A raw-received target comes up keystatus=unavailable and
#                    mounted=no; no -u needed. For an UNENCRYPTED source -w is
#                    effectively a no-op: verified on zfs-2.1.9 that raw and
#                    non-raw streams interoperate freely in both directions there.
#                    Rawness must NOT change mid-stream on an encrypted target.
#   -p <PORT>         SSH port to use (default: 22)
#   -k <FILE>         Verify remote host keys against this known_hosts file instead
#                     of blindly trusting them (StrictHostKeyChecking=no is the
#                     default when -k is omitted, unchanged from prior versions --
#                     only opt into -k if you've already populated FILE, e.g. via
#                     ssh-keyscan, and verified the fingerprint out of band)
#   -A               Auto-tune the link: measure it, then decide whether -z is
#                    worth it for THIS data. Opt-in, remote transfers only, and
#                    it can flip nothing but compression. Decided separately for
#                    EACH dataset, since the ratio is a property of the data.
#                    Cached 7 days -- link speed per host, ratio per dataset;
#                    ZFS_SNAP_RETUNE=1 forces a re-probe.
#
#                    In snapget the SOURCE is remote and its compressor runs
#                    there (see transfer_data), so the ratio is measured on the
#                    far side -- probing locally would measure the wrong
#                    machine's disk and CPU.
#
#                    Decides ONE thing on purpose: measured 2026-07-22,
#                    compress-or-not is worth ~29%, the zstd level ~2%, and
#                    mbuffer -m nothing at all. Ratio is measured on a real
#                    `zfs send` sample, never assumed (2.34x vs 1.29x on two
#                    datasets of the same host). Needs an existing snapshot to
#                    sample. Every failure path leaves your settings untouched.
#
#                    An explicit -z/-Z/-g WINS: -A stands down and honours it.
#   -V               Print version and exit
#
# COMPRESSED SEND is automatic (`zfs send -c`) and needs no flag: records are
# sent as they already sit on disk, instead of being decompressed to build the
# stream and recompressed on receive. Measured on real production snapshots
# 2026-07-22: streams 18-56% smaller (342 GB -> 249 GB on one VM disk). Unlike
# -z it costs no CPU -- it removes work rather than adding it -- so it applies to
# LOCAL transfers too. Skipped automatically when the target pool cannot take the
# stream (needs feature@lz4_compress at all, plus feature@zstd_compress for
# zstd-compressed records); set ZFS_SNAP_NO_COMPRESSED_SEND=1 to force plain.
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
VERSION='v2.35'
MESSAGE=""
VERBOSE=0
COMPRESSION=0
# Which compressor -z/-Z/-g selected, and whether -l was given explicitly. zstd
# is the default because it measured strictly better than pigz on this hardware
# -- see the benchmark table in the header. The level default differs per tool
# (zstd 3, pigz 6 -- each tool's own), so it can only be resolved after argument
# parsing.
COMPRESSOR="zstd"
COMPRESSION_LEVEL=6
COMPRESSION_LEVEL_SET=0
BUFFER_SIZE="128k"
# 16M, not the 1G this used to be. Measured 2026-07-22 against a real `zfs recv`
# -- 14 runs of 2 GB, both transfer paths, including the slow-consumer case that
# most favours a big buffer:
#
#   remote, SSD target:  16M 109.9 | 128M 109.3 | 1G 109.8 MB/s
#   remote, HDD target:  16M 89.3/86.6          | 1G 78.3/88.8
#   local,  HDD target:  16M 119.7/108.1/107.9/87.4 | 1G 100.3/117.0/117.6/88.5
#
# A 64x change moves nothing outside run-to-run noise -- and that noise (88 to
# 120 MB/s for one unchanged setting) is far larger than any gap between
# settings. So the old 1G bought no throughput; it just reserved memory that on
# these hosts belongs to the VMs.
#
# mbuffer's job is absorbing consumer stalls (a `zfs recv` txg commit), not
# holding the TCP window -- that is the kernel's, and bandwidth-delay product
# for these links is tens of KB. Two sizing formulas built on those ideas were
# tried and both were refuted by the table above, hence a flat constant.
MEMORY="16M"
PORT=22
USE_EXISTING_SNAPSHOT=0
RECURSIVE=0
DRY_RUN=0
FULL_HISTORY_SEND=0
UNMOUNT=0
FORCE_FULL_SEND=0
RAW_SEND=0
# -A: measure the link and the data, then decide whether compressing is worth
# it. Opt-in, and it can only ever flip COMPRESSION.
AUTOTUNE=0
# Set by -z/-Z/-g. Lets -A tell "user said nothing about compression" apart from
# "user explicitly asked for it" -- auto-tuning may fill the first case in, but
# must never silently overrule the second.
COMPRESSION_SET=0
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
        local ts
        ts=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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
                if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs list -H '$src_child' >/dev/null 2>&1"; then
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
    remote_machine_id=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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

    # A target that does not exist has no snapshots and therefore no common
    # base -- "null", not an error. This is reachable under -w, where the leaf
    # is created by recv rather than pre-created, so the first pull legitimately
    # runs against a target that is not there yet.
    local tgt_snaps
    if ! target_exists "$tgt_dataset"; then
        echo -n "null"
        return 0
    fi
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
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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
# MAX_RESUME_ATTEMPTS and the resume helpers (get_resume_token, abandon_resume,
# resume_state_file, read/increment/reset_resume_attempts) are byte-identical
# between snapsend.sh and snapget.sh, so they live in lib-zfs-snap.sh (sourced
# at the top). In snapget.sh the target is always local, so they're always
# called with an empty remote_host/user -- see the header comment there.
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
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "command -v $COMPRESSOR >/dev/null 2>&1"; then
                log 0 "Compression requested but $COMPRESSOR is not installed on remote host $remote_host"
                return 1
            fi
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$send_cmd | $COMPRESS_PIPE" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$send_cmd" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | "${recv_args[@]}"; then
                return 1
            fi
        fi
    else
        local send_args
        IFS=' ' read -r -a send_args <<< "$send_cmd"
        # COMPRESSION is forced to 0 for a local source in section 5B, so this
        # branch is not reachable in normal operation. Kept because it is the
        # correct pipeline if compression is ever wanted here; the policy of not
        # wanting it lives in one place, not spread into the transport layer.
        if [ $COMPRESSION -eq 1 ]; then
            if ! "${send_args[@]}" | $COMPRESS_PIPE | mbuffer -q -s $BUFFER_SIZE -m $MEMORY | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
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
        if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs list -H '$src_dataset' >/dev/null 2>&1"; then
            log 0 "Source dataset not found on remote host: $src_dataset"
            return 1
        fi
    else
        if ! zfs list -H "$src_dataset" &>/dev/null; then
            log 0 "Source dataset not found: $src_dataset"
            return 1
        fi
    fi

    # Checked here, before anything is created, snapshotted or (under -f)
    # destroyed: a rawness mismatch can never succeed, so a doomed run must not
    # leave side effects behind. Skipped under -f, which destroys the target and
    # so has no seeding left to conflict with. Orientation is mirrored vs
    # snapsend.sh: here the SOURCE may be remote and the target is always local.
    if [ $FORCE_FULL_SEND -ne 1 ]; then
        check_raw_compatibility "$src_dataset" "$remote_user" "$remote_host" \
                                "$tgt_dataset" "" "" \
                                "$RAW_SEND" || return 1
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
                # Giving up on this snapshot -- release whatever the original
                # failed attempt held on the (possibly remote) source, so it
                # can be pruned like normal again. A fresh $snapshot is about
                # to be resolved below.
                local stuck_snap
                stuck_snap=$(read_inflight_snap "$tgt_dataset")
                [ -n "$stuck_snap" ] && release_snapshot "$stuck_snap" "$remote_user" "$remote_host"
                clear_inflight_snap "$tgt_dataset"
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
                    # Resumed stream landed -- release the hold placed on the
                    # original attempt (this run never recomputes $snapshot).
                    local resumed_snap
                    resumed_snap=$(read_inflight_snap "$tgt_dataset")
                    [ -n "$resumed_snap" ] && release_snapshot "$resumed_snap" "$remote_user" "$remote_host"
                    clear_inflight_snap "$tgt_dataset"
                    log 1 "Resumed transfer completed successfully"
                    return 0
                else
                    log 0 "Resume attempt failed"
                    # Still under MAX_RESUME_ATTEMPTS -- leave the hold in
                    # place for the next attempt.
                    return 1
                fi
            fi
        fi
    fi

    # Work out WHAT is going to be pulled before touching the target in any
    # way. This ordering is load-bearing, not cosmetic: everything below either
    # creates the target dataset or, under -f, destroys it outright. Resolving
    # the source snapshot afterwards meant a run that could never succeed still
    # got that far -- `-f -e -m <prefix that matches nothing>` destroyed every
    # snapshot and all data on the local target and only THEN reported "no
    # source snapshots matching message". Same fix as snapsend.sh; keep the two
    # in step.
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

    # Hold it for the whole transfer window, including across a resume that
    # spans later cron runs -- see HOLD-BASED PROTECTION in lib-zfs-snap.sh.
    # Source may be remote here. Released on the success path below and in
    # the resume branch above; deliberately left held on failure so a stuck
    # resume keeps its source snapshot until it either succeeds or is
    # abandoned.
    hold_snapshot "$snapshot" "$remote_user" "$remote_host"
    record_inflight_snap "$tgt_dataset" "$snapshot"

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
        zfs list "$create_target" >/dev/null 2>&1 || zfs create -p -o canmount=noauto "$create_target" || return 1
    fi

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        log 1 "Force full pull activated (-f)"

        local protected_snaps
        protected_snaps=$(zfs list -t snapshot -H -o name -r "$tgt_dataset" 2>/dev/null | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        if [ -n "$protected_snaps" ]; then
            log 0 "Refusing force full pull: $tgt_dataset (or a descendant) holds snapshot(s) reserved by Proxmox VE (replication/migration/vzdump):"
            log 0 "$protected_snaps"
            log 0 "This target looks like it's managed by Proxmox VE outside this tool -- force full pull would destroy that state and break replication/migration/backup. Remove the conflicting job/snapshots yourself first if this is intentional."
            return 1
        fi

        log 2 "Destroying all snapshots and data on local target dataset"

        log 4 "EXECUTING DESTROY LOCALLY"
        zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R "$@" 2>/dev/null || true' -- {} || true

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
        zfs create -p -o canmount=noauto "$tgt_dataset" || {
            log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root."
            return 1
        }
        fi
    fi

    # Under -w the leaf target is deliberately NOT pre-created (recv builds it
    # from the raw stream), so on a first pull it does not exist yet and
    # get_sorted_snapshots fails -- `zfs list` on a missing dataset exits 1 and
    # pipefail propagates it. That is not an error here, it is the first-pull
    # case: a target that does not exist simply has no snapshots. Every other
    # mode still pre-creates the target, so a failure there remains a real one
    # and is still reported. Target is always local in snapget.sh.
    local tgt_snaps
    if [ $RAW_SEND -eq 1 ] && ! target_exists "$tgt_dataset"; then
        log 2 "Target does not exist yet -- raw receive will create it"
        tgt_snaps=()
    else
        tgt_snaps=($(get_sorted_snapshots "$tgt_dataset")) || return 1
    fi

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

    # -w rides along on every send path below EXCEPT the resume path above:
    # `zfs send -t <token>` already encodes rawness in the token, and passing -w
    # on top of it does not just error, it aborts (SIGABRT / rc=134,
    # "internal error: Invalid argument" on zfs-2.1.9). Verified, not assumed.
    #
    # send_cmd is interpolated into the remote ssh command string (and only
    # word-split locally), so an empty flag var collapses harmlessly either way --
    # same reason recursive_send_flag can be empty.
    local raw_send_flag=""
    [ $RAW_SEND -eq 1 ] && raw_send_flag="-w"

    # Mirrors snapsend.sh, with the sides swapped: here the SOURCE is remote and
    # the TARGET pool is local, so the arguments are the other way round. Getting
    # them backwards would ask the wrong machine about its pool and show up only
    # as an unexplained fallback to plain sends.
    local comp_send_flag
    comp_send_flag=$(compressed_send_flag "$src_dataset" "$tgt_dataset" ""                         "${remote_host:+${remote_user}@${remote_host}}")
    [ -n "$comp_send_flag" ] && log 3 "Compressed send: using zfs send -c"

    local bookmark_base=""
    if [[ "$common_snapshot" == "null" ]] && [ $RECURSIVE -ne 1 ]; then
        # No common snapshot survives on either end -- before giving up to a
        # FULL pull, check for a bookmark left by a prior run (see
        # lib-zfs-snap.sh). Target is always local in snapget.sh, so the head
        # GUID lookup gets no remote args; the source (where bookmarks live)
        # may be remote, mirrored the same way find_common_snapshot already is.
        local tgt_head_guid=""
        if [ ${#tgt_snaps[@]} -gt 0 ]; then
            tgt_head_guid=$(get_snapshot_guid "$tgt_dataset" "${tgt_snaps[-1]}")
        fi
        bookmark_base=$(find_bookmark_base "$src_dataset" "$tgt_head_guid" "$remote_user" "$remote_host")
    fi

    if [[ "$common_snapshot" != "null" ]]; then
        log 1 "Found valid common snapshot: ${src_dataset}@${common_snapshot}"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag -I ${src_dataset}@${common_snapshot} $snapshot"
    elif [ -n "$bookmark_base" ]; then
        log 1 "No common snapshot, but a bookmark still anchors an incremental: $bookmark_base"
        send_cmd="zfs send $raw_send_flag $comp_send_flag -i $bookmark_base $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history pull"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag -R $snapshot"
        else
            log 1 "Performing standard full pull"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $snapshot"
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
        [ $FORCE_FULL_SEND -eq 1 ] && log 0 "Hint: -f receives with a forced rollback, which needs to mount/unmount the (local) target. On Linux, non-root users cannot do that even with full 'zfs allow' delegation -- if this failed on a mount/unmount permission error, -f requires root."
        # Only keep the hold if it is actually still useful: a
        # receive_resume_token means the resume branch above will need this
        # exact source snapshot on a later run. Without one (e.g. zfs recv
        # refused outright, before writing anything -- "destination has
        # snapshots" and similar), nothing will ever come back to release it,
        # so release now instead of stranding it un-prunable forever. Target
        # is always local in snapget.sh.
        if [ -z "$(get_resume_token "$tgt_dataset" "" "")" ]; then
            release_snapshot "$snapshot" "$remote_user" "$remote_host"
            clear_inflight_snap "$tgt_dataset"
        fi
        return 1
    }

    # Transfer landed -- this snapshot is no longer "in flight", safe to prune
    # on the next delsnaps.sh run like any other.
    release_snapshot "$snapshot" "$remote_user" "$remote_host"
    clear_inflight_snap "$tgt_dataset"

    # Under -w the leaf was created by recv, not by us, so it never got
    # canmount=noauto at create time. Reapply it now: it is what keeps the
    # target unmounted across future receives and makes non-root incremental
    # receive possible. Best-effort -- an encrypted target is already unmounted
    # (keystatus=unavailable), so failing here costs nothing immediate. Target
    # is always local in snapget.sh.
    if [ $RAW_SEND -eq 1 ]; then
        zfs set canmount=noauto "$tgt_dataset" 2>/dev/null \
            || log 2 "Could not set canmount=noauto on $tgt_dataset (needs delegated 'canmount')"
    fi

    # Refresh the per-target bookmark to what was just sent, regardless of
    # which path got us here (-I, -i bookmark, or FULL) -- see
    # record_send_bookmark in lib-zfs-snap.sh. Source may be remote here.
    [ $RECURSIVE -ne 1 ] && record_send_bookmark "$src_dataset" "$latest_snap" "$tgt_dataset" "$remote_user" "$remote_host"

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
while getopts "m:ezZgl:v:rnIufwVp:k:A" opt; do
    case $opt in
        m) MESSAGE="$OPTARG";;
        A) AUTOTUNE=1;;
        e) USE_EXISTING_SNAPSHOT=1;;
        z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        Z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        g) COMPRESSION=1; COMPRESSOR="pigz"; COMPRESSION_SET=1;;
        l) COMPRESSION_LEVEL="$OPTARG"; COMPRESSION_LEVEL_SET=1;;
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
            echo "Błąd: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -Z -g -l -v -r -n -I -u -f -w -p -k -A -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

[ $# -ge 1 ] || { echo "Użycie: $0 [opcje] DATASETS [REMOTE]" >&2; exit 1; }
###############################################################################
#END 5A

# Resolve the compression level default now that the compressor and -l are both
# known: each tool keeps its OWN default (zstd 3, pigz 6) rather than sharing one
# number, because the scales are not comparable -- zstd 6 measured 4x slower than
# zstd 3 for 4% more ratio, so silently carrying pigz's 6 over to zstd would have
# made the new default look like a regression.
if [ "$COMPRESSOR" = "zstd" ] && [ $COMPRESSION_LEVEL_SET -eq 0 ]; then
    COMPRESSION_LEVEL=3
fi

# Built once, used by both pipeline branches. -T0 lets zstd use every core (pigz
# is already multi-threaded by default); -c forces stdout so neither tool can
# decide to write a file. COMPRESS_PIPE runs on the REMOTE source side here.
if [ "$COMPRESSOR" = "zstd" ]; then
    COMPRESS_PIPE="zstd -T0 -$COMPRESSION_LEVEL -c"
    DECOMPRESS_PIPE="zstd -d -c"
else
    COMPRESS_PIPE="pigz -$COMPRESSION_LEVEL"
    DECOMPRESS_PIPE="pigz -d"
fi

# Reported where the compressor is CHOSEN, not where it is used. COMPRESS_PIPE
# is invariant across datasets, so this belongs here rather than once per
# transfer -- and it keeps the flag-to-compressor mapping observable even for a
# local run, which no longer reaches the compressed pipeline at all.
[ $COMPRESSION -eq 1 ] && log 3 "COMPRESSOR: $COMPRESS_PIPE"

if [ $COMPRESSION -eq 1 ] && ! command -v "$COMPRESSOR" >/dev/null; then
    log 0 "Compression requested but $COMPRESSOR is not installed."
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

# Fail fast instead of hanging forever. Without these there is NO timeout of any
# kind on the ssh side, and the worst case is not a broken backup -- it is a
# silent one: a VPN that stops passing packets without closing the connection
# leaves ssh waiting indefinitely, so the cron job never exits, never returns
# non-zero, and never fires notify-fail.sh. Every later run then hits the flock
# and skips, so backups stop while everything still looks healthy.
#
# ConnectTimeout covers a dead peer at connect time; ServerAlive* covers one that
# dies mid-transfer (4 x 15s = ~60s). Together they turn that hang into an
# ordinary failure -- which alerts AND leaves a resume token for the next run.
#
# These do NOT fire on a merely slow link: sshd answers keepalives at the
# protocol level regardless of what the payload is doing.
SSH_OPTS+=(-o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

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

# A local pull has no link to save bytes on. The pipeline would be
#   zfs send | zstd -c | mbuffer | zstd -d -c | zfs recv
# i.e. compress and immediately decompress on the same machine, paying for both
# and gaining nothing -- there is no network between the two halves, only a pipe
# in memory. So -z/-Z/-g are dropped here rather than honoured, even though an
# explicit flag normally wins: this is not a preference we are overriding, it is
# an operation with no possible benefit. Mirrors snapsend.sh section 5B.
if [ $COMPRESSION -eq 1 ] && [ -z "$REMOTE_HOST" ]; then
    COMPRESSION=0
    [ $COMPRESSION_SET -eq 1 ] && \
        log 1 "Compression ignored: source is local, so compressing and decompressing on this same host would only cost CPU"
fi

# Connection reuse for every ssh call below. No-ops for a local run, and
# ControlMaster=auto falls back to an ordinary connection on failure.
tune_ssh_enable "$REMOTE_HOST"
trap 'tune_ssh_close "$REMOTE_USER@$REMOTE_HOST"' EXIT

# -A decides compress-or-not from a measurement, PER DATASET -- taken inside the
# loop below, not here, because the compression ratio is a property of the data
# and one dataset's ratio must not decide for the rest. Mirrors snapsend.sh
# section 5B; see the longer note there.
AUTOTUNE_ACTIVE=0
if [ $AUTOTUNE -eq 1 ] && [ -n "$REMOTE_HOST" ] && [ $DRY_RUN -ne 1 ]; then
    if [ $COMPRESSION_SET -eq 1 ]; then
        log 1 "Link tuning: -A ignored, compression was requested explicitly (-z/-Z/-g) -- honouring your flag"
    else
        AUTOTUNE_ACTIVE=1
        COMPRESSION_BASE=$COMPRESSION
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

    # "remote": snapget's source lives on the far side, so the ratio must be
    # measured there -- that is also where its compressor runs. And the name
    # probed is src_path, NOT dataset: dataset is the LOCAL target, which under
    # a SOURCE_BASE prefix does not exist on the remote at all, so the probe
    # would have found no snapshot and quietly given up on every tuned run.
    if [ $AUTOTUNE_ACTIVE -eq 1 ]; then
        COMPRESSION=$COMPRESSION_BASE
        tune_apply "$REMOTE_USER@$REMOTE_HOST" "$src_path" remote
    fi

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
