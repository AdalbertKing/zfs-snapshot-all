#!/bin/bash

# Author: Wojciech Kr�l & Chat-GPT 4
# Email: lurk@lurk.com.pl
# Version: run with -V/--version; see git log for full changelog

# Description:
# This script deletes ZFS snapshots, in one of two mutually exclusive modes:
#   - age-based (lowercase flags): delete snapshots older than a threshold.
#   - count-based (uppercase flags): keep the N most recently created
#     snapshots matching the pattern, delete the rest.
#
# Each eligible snapshot is removed with a plain `zfs destroy` of exactly that
# snapshot -- nothing else is touched. To prune a whole dataset tree, use -R,
# which applies the SAME retention rule to every descendant dataset in turn
# (each keeps its own newest N / its own within-threshold snapshots). A plain
# destroy refuses to remove a snapshot that has dependent clones (e.g. a
# Proxmox linked-clone VM/CT disk); such a snapshot is reported and skipped
# rather than silently destroyed. Pass -F to override that ("clear-cut"): it
# switches to `zfs destroy -R`, which additionally destroys same-named
# snapshots on descendant datasets AND any clones, even outside the hierarchy.
# -F is deliberately opt-in because it can remove live clones.
#
# Datasets may live on a remote host: prefix an entry with "[user@]host:"
# (user defaults to root) and every zfs list/get/destroy for that dataset runs
# over ssh on that host. An entry is remote only when it has a ':' AND the part
# before it contains no '/', so plain local dataset names -- including the rare
# ones that legally contain a ':' (e.g. tank/data:backup) -- keep working
# exactly as before. Local and remote datasets can be mixed in one
# comma-separated list. The Proxmox-reserved-snapshot guard and all dry-run
# behaviour apply identically to remote datasets (names are filtered the same
# way after listing).

# Usage examples:
# 1. Delete snapshots older than 1 year and 6 months for datasets "tank/data1" and "tank/data2" recursively:
#    ./delsnaps.sh -R "tank/data1,tank/data2" "backup-" -y1 -m6 -d0 -h0
# 2. Delete snapshots older than 2 years without recursion for dataset "tank/data3":
#    ./delsnaps.sh "tank/data3" "snapshot-" -y2 -m0 -d0 -h0
# 3. Keep only the 12 most recent monthly snapshots for dataset "tank/data4":
#    ./delsnaps.sh "tank/data4" "monthly-" -M12
# 4. Keep only the 24 most recent hourly snapshots, recursively:
#    ./delsnaps.sh -R "tank/data5" "hourly-" -H24
# 5. Preview (no destroy) what -M12 would do on dataset "tank/data4":
#    ./delsnaps.sh -n "tank/data4" "monthly-" -M12
# 6. Keep the 12 most recent monthly snapshots on a remote host, over ssh port 2222:
#    ./delsnaps.sh -p2222 "backup@pve2:tank/data" "monthly-" -M12

# Options:
# -R                   : Recursively process child datasets (each with its own
#                        retention). This is the correct way to prune a subtree.
# -n                   : Dry-run. Print what would be deleted/kept; never calls
#                        `zfs destroy`. Can be combined with -R, in any order.
# -F                   : Clear-cut. Use `zfs destroy -R` instead of a plain
#                        destroy, cascading to same-named descendant snapshots
#                        and destroying dependent clones (even Proxmox linked
#                        clones). Dangerous, opt-in.
# -p <PORT>            : SSH port for remote datasets (default: 22).
# -k <FILE>            : Verify remote host keys against this known_hosts file
#                        (StrictHostKeyChecking=yes). Default when omitted is
#                        StrictHostKeyChecking=no, matching snapsend.sh/snapget.sh.
# Age-based (sum to one threshold date; snapshots older than it are deleted):
# -y <years>           : Number of years.
# -m <months>          : Number of months.
# -w <weeks>           : Number of weeks.
# -d <days>            : Number of days.
# -h <hours>           : Number of hours.
# Count-based (sum to one keep-count; only the N most recent are kept):
# -Y <count>           : Count contribution (years slot).
# -M <count>           : Count contribution (months slot).
# -W <count>           : Count contribution (weeks slot).
# -D <count>           : Count contribution (days slot).
# -H <count>           : Count contribution (hours slot).
# -V, --version        : Print version and exit.
# Age-based and count-based flags cannot be mixed in one invocation.

VERSION='v1.13'
EXIT_CODE=0
DRY_RUN=false
CLEARCUT=false
PORT=22
KNOWN_HOSTS_FILE=""
STATS_LOG="${STATS_LOG:-/root/scripts/zfs-snapshot-stats.log}"

# Snapshot name prefixes reserved by Proxmox VE itself (storage replication,
# offline migration, vzdump). These are created/consumed exclusively by pvesr
# and friends -- if this tool prunes one out from under them, the next
# replication/migration/backup run breaks with a snapshot-chain mismatch that
# this tool has no way to repair. Never eligible for deletion, no matter what
# pattern a caller passes in.
PROTECTED_PREFIXES=("__replicate_" "__migration__" "vzdump")

is_protected_snapshot() {
    local snapname="$1" prefix
    for prefix in "${PROTECTED_PREFIXES[@]}"; do
        [[ "$snapname" == "${prefix}"* ]] && return 0
    done
    return 1
}

# Run a zfs subcommand either locally or on a remote host. First two args are
# the remote user and host; an empty host means "run locally". The remaining
# args are passed to zfs verbatim. For remote execution each arg is wrapped in
# single quotes before being handed to the remote shell -- zfs dataset and
# snapshot names cannot contain single quotes, so this is safe, and quoting the
# flags too (e.g. '-H') is harmless. stdout, stderr and exit status all
# propagate to the caller exactly as a local `zfs` call would.
run_zfs() {
    local ruser="$1" rhost="$2"
    shift 2
    if [ -n "$rhost" ]; then
        local cmd="zfs" arg
        for arg in "$@"; do
            cmd+=" '${arg}'"
        done
        ssh "${SSH_OPTS[@]}" "$ruser@$rhost" "$cmd"
    else
        zfs "$@"
    fi
}

# Destroy exactly one snapshot (local or remote), returning zfs's exit status.
# Default is a plain `zfs destroy <snap>`: removes only that snapshot and, by
# design, FAILS if it has dependent clones instead of taking them down with it.
# Clear-cut mode (-F) uses `zfs destroy -R`, which cascades to same-named
# descendant snapshots and destroys dependent clones (even outside the
# hierarchy) -- the "wycinaj w pien" behaviour, opt-in because it can remove
# live clones.
destroy_one() {
    local snap="$1" ruser="$2" rhost="$3"
    if [ "$CLEARCUT" = true ]; then
        run_zfs "$ruser" "$rhost" destroy -R "$snap"
    else
        run_zfs "$ruser" "$rhost" destroy "$snap"
    fi
}

# Split a datasets-list entry into remote user/host/dataset. A remote entry is
# "[user@]host:dataset" (user defaults to root); results come back via the
# R_USER/R_HOST/R_DS globals (bash has no clean multi-value return).
#
# ZFS legally permits ':' inside dataset names, so a bare ':' cannot mean
# "remote" on its own without breaking local names like tank/data:backup.
# The distinguishing fact: the host part before the ':' never contains '/',
# whereas a local dataset name that carries a colon always has its pool/child
# '/' before that colon. So treat an entry as remote only when it has a ':'
# AND nothing before the first ':' looks like a path. An empty R_HOST => local.
parse_remote() {
    local elem="$1" remote_part
    # NB: compute remote_part on its own line -- doing it in the `local`
    # declaration above would expand ${elem%%:*} before elem is assigned.
    remote_part="${elem%%:*}"
    if [[ "$elem" == *:* && "$remote_part" != */* ]]; then
        R_DS="${elem#*:}"
        if [[ "$remote_part" == *@* ]]; then
            R_USER="${remote_part%%@*}"
            R_HOST="${remote_part#*@}"
        else
            R_USER="root"
            R_HOST="$remote_part"
        fi
    else
        R_USER=""
        R_HOST=""
        R_DS="$elem"
    fi
}

if [ "$1" == "-V" ] || [ "$1" == "--version" ]; then
    echo "$VERSION"
    exit 0
fi

# One line per processed dataset, appended to STATS_LOG. Best-effort: never
# lets a logging failure (e.g. unwritable path) break the actual prune.
emit_stats() {
    local dataset="$1" pattern="$2" status="$3" duration="$4" deleted="$5" kept="$6"
    {
        echo "$(date -u +%FT%TZ) script=$(basename "$0") dataset=${dataset} pattern=${pattern} status=${status} duration_s=${duration} deleted=${deleted} kept=${kept}"
    } >> "$STATS_LOG" 2>/dev/null || true
}

# Function to display script usage
usage() {
    echo "Usage: $0 [-R] [-n] [-F] [-p PORT] [-k known_hosts] <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>"
    echo "   or: $0 [-R] [-n] [-F] [-p PORT] [-k known_hosts] <comma-separated list of datasets> <pattern> -Y<count> -M<count> -W<count> -D<count> -H<count>"
    echo "   dataset entries may be remote: [user@]host:dataset (user defaults to root)"
    echo "   -F clear-cut: zfs destroy -R (also removes descendant snapshots and dependent clones)"
    exit 1
}

# Function to parse time arguments. Sets a package of vars for both modes
# plus age_flag_seen/count_flag_seen so the caller can tell which mode (if
# either) was actually requested and reject mixing the two.
parse_time_arguments() {
    years=0
    months=0
    weeks=0
    days=0
    hours=0
    keep_years=0
    keep_months=0
    keep_weeks=0
    keep_days=0
    keep_hours=0
    age_flag_seen=false
    count_flag_seen=false

    while getopts "y:m:w:d:h:Y:M:W:D:H:" opt; do
        case ${opt} in
            y )
                years=$OPTARG
                age_flag_seen=true
                ;;
            m )
                months=$OPTARG
                age_flag_seen=true
                ;;
            w )
                weeks=$OPTARG
                age_flag_seen=true
                ;;
            d )
                days=$OPTARG
                age_flag_seen=true
                ;;
            h )
                hours=$OPTARG
                age_flag_seen=true
                ;;
            Y )
                keep_years=$OPTARG
                count_flag_seen=true
                ;;
            M )
                keep_months=$OPTARG
                count_flag_seen=true
                ;;
            W )
                keep_weeks=$OPTARG
                count_flag_seen=true
                ;;
            D )
                keep_days=$OPTARG
                count_flag_seen=true
                ;;
            H )
                keep_hours=$OPTARG
                count_flag_seen=true
                ;;
            \? )
                usage
                ;;
        esac
    done

    if [ "$age_flag_seen" = true ] && [ "$count_flag_seen" = true ]; then
        echo "Error: cannot mix age-based (-y/-m/-w/-d/-h) and count-based (-Y/-M/-W/-D/-H) flags in one invocation" >&2
        exit 1
    fi
}

# Function to calculate the threshold date (age-based mode)
calculate_threshold_date() {
    echo $(date -d "-${years} years -${months} months -${weeks} weeks -${days} days -${hours} hours" +%s)
}

# Function to calculate the keep-count (count-based mode)
calculate_keep_count() {
    echo $((keep_years + keep_months + keep_weeks + keep_days + keep_hours))
}

# Function to delete snapshots. mode is "age" (param = threshold epoch
# seconds, delete anything older) or "count" (param = number of most
# recently created matching snapshots to keep, delete the rest).
delete_snapshots() {
    local ds="$1"
    local pat="$2"
    local mode="$3"
    local param="$4"
    local ruser="${5:-}"
    local rhost="${6:-}"
    local ds_start deleted_count=0 kept_count=0 ds_failed=0
    ds_start=$(date +%s)
    # Label used in stats/log output: prefix the host for remote datasets so a
    # single stats log covering several hosts stays unambiguous.
    local ds_label="$ds"
    [ -n "$rhost" ] && ds_label="${rhost}:${ds}"

    echo "Debug: Inside delete_snapshots function" >&2
    echo "Debug: Dataset = $ds_label" >&2
    echo "Debug: Pattern = $pat" >&2
    echo "Debug: Mode = $mode, Param = $param" >&2

    # List snapshots of THIS dataset only (non-recursive), oldest-first, then
    # keep only those whose snapshot name (the part after '@') starts with the
    # literal pattern. Oldest-first ordering matters for count mode, where the
    # last N entries in the filtered array are the ones to keep. Recursion
    # into children is handled by process_datasets_recursively so that each
    # dataset is processed exactly once (see -R handling).
    local all_snapshots
    all_snapshots=$(run_zfs "$ruser" "$rhost" list -H -o name -s creation -t snapshot "${ds}" 2>/dev/null)

    local filtered=()
    local line snapname
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        snapname="${line#*@}"
        if is_protected_snapshot "$snapname"; then
            echo "Debug: Skipping protected snapshot (reserved by Proxmox VE): ${line}" >&2
            continue
        fi
        if [[ "$snapname" == "${pat}"* ]]; then
            filtered+=("$line")
        fi
    done <<< "$all_snapshots"

    # If no snapshots are found, return early
    if [ "${#filtered[@]}" -eq 0 ]; then
        echo "No snapshots found for dataset $ds_label matching pattern $pat" >&2
        emit_stats "$ds_label" "$pat" "success" "$(( $(date +%s) - ds_start ))" 0 0
        return 0
    fi

    echo "Debug: Snapshots found: ${filtered[*]}" >&2

    if [ "$mode" = "count" ]; then
        local total="${#filtered[@]}"
        local keep=$param
        [ "$keep" -lt 0 ] && keep=0
        local to_delete=$((total - keep))
        [ "$to_delete" -lt 0 ] && to_delete=0

        local i=0 snapshot
        for snapshot in "${filtered[@]}"; do
            if [ "$i" -lt "$to_delete" ]; then
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would delete snapshot: ${snapshot}" >&2
                    deleted_count=$((deleted_count + 1))
                else
                    echo "Deleting snapshot: ${snapshot}" >&2
                    if destroy_one "${snapshot}" "$ruser" "$rhost"; then
                        deleted_count=$((deleted_count + 1))
                    else
                        echo "Error deleting snapshot: ${snapshot}" >&2
                        if [ "$CLEARCUT" = false ]; then
                            echo "  Hint: the snapshot may have dependent clones; a plain destroy refuses to remove those. Re-run with -F to clear-cut clones and descendants, or remove the clone manually first." >&2
                        else
                            echo "  Hint: -F must unmount any dependent clone before destroying it. On Linux, non-root users cannot unmount filesystem datasets even with full 'zfs allow' delegation -- if the clone is mounted (e.g. a live Proxmox VM/CT disk), -F requires root." >&2
                        fi
                        EXIT_CODE=1
                        ds_failed=1
                    fi
                fi
            else
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would keep snapshot: ${snapshot} (among last ${keep})" >&2
                else
                    echo "Keeping snapshot: ${snapshot} (among last ${keep})" >&2
                fi
                kept_count=$((kept_count + 1))
            fi
            i=$((i + 1))
        done
    else
        local snapshot creation_date_sec
        for snapshot in "${filtered[@]}"; do
            creation_date_sec=$(run_zfs "$ruser" "$rhost" get -H -p -o value creation "${snapshot}")

            echo "Debug: Snapshot = $snapshot, creation_date_sec = $creation_date_sec" >&2

            if [ "${creation_date_sec}" -lt "${param}" ]; then
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would delete snapshot: ${snapshot}" >&2
                    deleted_count=$((deleted_count + 1))
                else
                    echo "Deleting snapshot: ${snapshot}" >&2
                    if destroy_one "${snapshot}" "$ruser" "$rhost"; then
                        deleted_count=$((deleted_count + 1))
                    else
                        echo "Error deleting snapshot: ${snapshot}" >&2
                        if [ "$CLEARCUT" = false ]; then
                            echo "  Hint: the snapshot may have dependent clones; a plain destroy refuses to remove those. Re-run with -F to clear-cut clones and descendants, or remove the clone manually first." >&2
                        else
                            echo "  Hint: -F must unmount any dependent clone before destroying it. On Linux, non-root users cannot unmount filesystem datasets even with full 'zfs allow' delegation -- if the clone is mounted (e.g. a live Proxmox VM/CT disk), -F requires root." >&2
                        fi
                        EXIT_CODE=1
                        ds_failed=1
                    fi
                fi
            else
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would keep snapshot: ${snapshot} (newer than threshold)" >&2
                else
                    echo "Keeping snapshot: ${snapshot} (newer than threshold)" >&2
                fi
                kept_count=$((kept_count + 1))
            fi
        done
    fi

    local status
    if [ "$DRY_RUN" = true ]; then
        status="dryrun"
    elif [ "$ds_failed" -eq 0 ]; then
        status="success"
    else
        status="failed"
    fi
    emit_stats "$ds_label" "$pat" "$status" "$(( $(date +%s) - ds_start ))" "$deleted_count" "$kept_count"
}

# Function to recursively process datasets
process_datasets_recursively() {
    local base_ds="$1"
    local pat="$2"
    local mode="$3"
    local param="$4"
    local ruser="${5:-}"
    local rhost="${6:-}"

    delete_snapshots "${base_ds}" "${pat}" "${mode}" "${param}" "${ruser}" "${rhost}"

    # Fetch the full descendant list (local or over ssh) and drop base_ds itself
    # in bash rather than piping the remote output through grep -- keeps the
    # remote command a single quoted zfs call with no shell metacharacters.
    local all_datasets child
    all_datasets=$(run_zfs "$ruser" "$rhost" list -H -o name -t filesystem,volume -r "${base_ds}")
    for child in ${all_datasets}; do
        [ "$child" = "$base_ds" ] && continue
        echo "Debug: Processing child dataset = $child" >&2
        delete_snapshots "${child}" "${pat}" "${mode}" "${param}" "${ruser}" "${rhost}"
    done
}

# Main function to process datasets
process_datasets() {
    local recurse="$1"
    local datasets_list="$2"
    local pattern="$3"
    local mode="$4"
    local param="$5"

    IFS=',' read -r -a datasets <<< "$datasets_list"

    for dataset in "${datasets[@]}"; do
        # parse_remote sets R_USER/R_HOST/R_DS; R_HOST empty => local dataset.
        parse_remote "$dataset"
        if [ "$recurse" = true ]; then
            process_datasets_recursively "${R_DS}" "${pattern}" "${mode}" "${param}" "${R_USER}" "${R_HOST}"
        else
            delete_snapshots "${R_DS}" "${pattern}" "${mode}" "${param}" "${R_USER}" "${R_HOST}"
        fi
    done
}

command -v flock >/dev/null || { echo "Error: flock command not found." >&2; exit 1; }

# Check number of arguments
if [ "$#" -lt 3 ]; then
    usage
fi

recurse=false

# Consume leading option flags, in any order. -p/-k take an argument and accept
# both the split (-p 2222) and attached (-p2222) forms. Anything that is not a
# recognised flag ends the loop and is treated as the first positional
# (datasets list).
while [ "$#" -gt 0 ]; do
    case "$1" in
        -R) recurse=true; shift ;;
        -n) DRY_RUN=true; shift ;;
        -F) CLEARCUT=true; shift ;;
        -p) PORT="$2"; shift 2 ;;
        -p*) PORT="${1#-p}"; shift ;;
        -k) KNOWN_HOSTS_FILE="$2"; shift 2 ;;
        -k*) KNOWN_HOSTS_FILE="${1#-k}"; shift ;;
        *) break ;;
    esac
done

# Re-check argument count now that option flags have been consumed.
if [ "$#" -lt 2 ]; then
    usage
fi

# Get arguments
datasets_list="$1"
shift
pattern="$1"
shift

# Built once, used by every ssh invocation in run_zfs. Default (-k omitted) is
# StrictHostKeyChecking=no, matching snapsend.sh/snapget.sh. Only opt into -k on
# a host where KNOWN_HOSTS_FILE has already been populated (e.g. via
# ssh-keyscan) and the fingerprint verified out of band.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=no -p "$PORT")
fi

# ssh is only required when at least one dataset entry is remote (has a ':').
if [[ "$datasets_list" == *:* ]]; then
    command -v ssh >/dev/null || { echo "Error: ssh command not found but a remote dataset was requested." >&2; exit 1; }
fi

# Loud, one-time warning: -F uses `zfs destroy -R`, which takes down dependent
# clones (e.g. Proxmox linked-clone VM/CT disks) along with the snapshot.
if [ "$CLEARCUT" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "WARNING: clear-cut mode (-F) active: real runs would use 'zfs destroy -R', removing descendant snapshots AND dependent clones (even Proxmox linked clones)." >&2
    else
        echo "WARNING: clear-cut mode (-F) active: using 'zfs destroy -R' -- this also destroys descendant snapshots AND dependent clones (even Proxmox linked clones)." >&2
    fi
fi

# Single-instance lock keyed on the operation target (datasets + pattern), so
# two runs that would destroy the same snapshot set are serialized, while
# unrelated prune jobs (different datasets/pattern) run concurrently instead of
# blocking each other.
LOCK_KEY=$(printf '%s\0%s' "$datasets_list" "$pattern" | md5sum | cut -d' ' -f1)
LOCKDIR="${LOCKDIR:-/var/run}"
LOCKFILE="$LOCKDIR/$(basename "$0").${LOCK_KEY}.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Another instance targeting the same datasets/pattern is already running (lock: $LOCKFILE) - skipping this run" >&2
    emit_stats "$datasets_list" "$pattern" "skipped_lock" "0" "0" "0"
    exit 0
fi

# Parse time arguments
parse_time_arguments "$@"

if [ "$count_flag_seen" = true ]; then
    retain_mode="count"
    retain_param=$(calculate_keep_count)
    echo "Debug: mode=count keep_count=$retain_param" >&2
else
    retain_mode="age"
    retain_param=$(calculate_threshold_date)
    echo "Debug: mode=age threshold_date=$retain_param ($(date -d "@$retain_param"))" >&2
fi

# Process datasets
process_datasets "$recurse" "$datasets_list" "$pattern" "$retain_mode" "$retain_param"

exit "$EXIT_CODE"
