#!/bin/bash

# Author: Wojciech Kr�l & Chat-GPT 4
# Email: lurk@lurk.com.pl
# Version: run with -V/--version; see git log for full changelog

# Description:
# This script deletes ZFS snapshots, in one of two mutually exclusive modes:
#   - age-based (lowercase flags): delete snapshots older than a threshold.
#   - count-based (uppercase flags): keep the N most recently created
#     snapshots matching the pattern, delete the rest.

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

# Options:
# -R                   : Recursively process child datasets.
# -n                   : Dry-run. Print what would be deleted/kept; never calls
#                        `zfs destroy`. Can be combined with -R, in any order.
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

VERSION='v1.9'
EXIT_CODE=0
DRY_RUN=false
STATS_LOG="/root/scripts/zfs-snapshot-stats.log"

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
    echo "Usage: $0 [-R] [-n] <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>"
    echo "   or: $0 [-R] [-n] <comma-separated list of datasets> <pattern> -Y<count> -M<count> -W<count> -D<count> -H<count>"
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
    local ds_start deleted_count=0 kept_count=0 ds_failed=0
    ds_start=$(date +%s)

    echo "Debug: Inside delete_snapshots function" >&2
    echo "Debug: Dataset = $ds" >&2
    echo "Debug: Pattern = $pat" >&2
    echo "Debug: Mode = $mode, Param = $param" >&2

    # List snapshots of THIS dataset only (non-recursive), oldest-first, then
    # keep only those whose snapshot name (the part after '@') starts with the
    # literal pattern. Oldest-first ordering matters for count mode, where the
    # last N entries in the filtered array are the ones to keep. Recursion
    # into children is handled by process_datasets_recursively so that each
    # dataset is processed exactly once (see -R handling).
    local all_snapshots
    all_snapshots=$(zfs list -H -o name -s creation -t snapshot "${ds}" 2>/dev/null)

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
        echo "No snapshots found for dataset $ds matching pattern $pat" >&2
        emit_stats "$ds" "$pat" "success" "$(( $(date +%s) - ds_start ))" 0 0
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
                    zfs destroy -R "${snapshot}"
                    if [ $? -ne 0 ]; then
                        echo "Error deleting snapshot: ${snapshot}" >&2
                        EXIT_CODE=1
                        ds_failed=1
                    else
                        deleted_count=$((deleted_count + 1))
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
            creation_date_sec=$(zfs get -H -p -o value creation "${snapshot}")

            echo "Debug: Snapshot = $snapshot, creation_date_sec = $creation_date_sec" >&2

            if [ "${creation_date_sec}" -lt "${param}" ]; then
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would delete snapshot: ${snapshot}" >&2
                    deleted_count=$((deleted_count + 1))
                else
                    echo "Deleting snapshot: ${snapshot}" >&2
                    zfs destroy -R "${snapshot}"
                    if [ $? -ne 0 ]; then
                        echo "Error deleting snapshot: ${snapshot}" >&2
                        EXIT_CODE=1
                        ds_failed=1
                    else
                        deleted_count=$((deleted_count + 1))
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
    emit_stats "$ds" "$pat" "$status" "$(( $(date +%s) - ds_start ))" "$deleted_count" "$kept_count"
}

# Function to recursively process datasets
process_datasets_recursively() {
    local base_ds="$1"
    local pat="$2"
    local mode="$3"
    local param="$4"

    delete_snapshots "${base_ds}" "${pat}" "${mode}" "${param}"

    child_datasets=$(zfs list -H -o name -t filesystem,volume -r "${base_ds}" | grep -v "^${base_ds}$")
    for child in ${child_datasets}; do
        echo "Debug: Processing child dataset = $child" >&2
        delete_snapshots "${child}" "${pat}" "${mode}" "${param}"
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
        if [ "$recurse" = true ]; then
            process_datasets_recursively "${dataset}" "${pattern}" "${mode}" "${param}"
        else
            delete_snapshots "${dataset}" "${pattern}" "${mode}" "${param}"
        fi
    done
}

command -v flock >/dev/null || { echo "Error: flock command not found." >&2; exit 1; }

# Check number of arguments
if [ "$#" -lt 3 ]; then
    usage
fi

recurse=false

# Consume leading -R/-n flags, in either order.
while [ "$1" == "-R" ] || [ "$1" == "-n" ]; do
    case "$1" in
        -R) recurse=true ;;
        -n) DRY_RUN=true ;;
    esac
    shift
done

# Get arguments
datasets_list="$1"
shift
pattern="$1"
shift

# Single-instance lock keyed on the operation target (datasets + pattern), so
# two runs that would destroy the same snapshot set are serialized, while
# unrelated prune jobs (different datasets/pattern) run concurrently instead of
# blocking each other.
LOCK_KEY=$(printf '%s\0%s' "$datasets_list" "$pattern" | md5sum | cut -d' ' -f1)
LOCKFILE="/var/run/$(basename "$0").${LOCK_KEY}.lock"
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
