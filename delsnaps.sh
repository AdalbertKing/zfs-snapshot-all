#!/bin/bash

# Author: Wojciech Kr�l & Chat-GPT 4
# Email: lurk@lurk.com.pl
# Version: run with -V/--version; see git log for full changelog

# Description:
# This script deletes ZFS snapshots based on a specified age threshold.

# Usage examples:
# 1. Delete snapshots older than 1 year and 6 months for datasets "tank/data1" and "tank/data2" recursively:
#    ./delsnaps.sh -R "tank/data1,tank/data2" "backup-" -y1 -m6 -d0 -h0
# 2. Delete snapshots older than 2 years without recursion for dataset "tank/data3":
#    ./delsnaps.sh "tank/data3" "snapshot-" -y2 -m0 -d0 -h0

# Options:
# -R                   : Recursively process child datasets.
# -y <years>           : Number of years.
# -m <months>          : Number of months.
# -w <weeks>           : Number of weeks.
# -d <days>            : Number of days.
# -h <hours>           : Number of hours.
# -V, --version        : Print version and exit.

VERSION='v1.6'
EXIT_CODE=0
STATS_LOG="/root/scripts/zfs-snapshot-stats.log"

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
    echo "Usage: $0 [-R] <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>"
    exit 1
}

# Function to parse time arguments
parse_time_arguments() {
    years=0
    months=0
    weeks=0
    days=0
    hours=0

    while getopts "y:m:w:d:h:" opt; do
        case ${opt} in
            y )
                years=$OPTARG
                ;;
            m )
                months=$OPTARG
                ;;
            w )
                weeks=$OPTARG
                ;;
            d )
                days=$OPTARG
                ;;
            h )
                hours=$OPTARG
                ;;
            \? )
                usage
                ;;
        esac
    done
}

# Function to calculate the threshold date
calculate_threshold_date() {
    echo $(date -d "-${years} years -${months} months -${weeks} weeks -${days} days -${hours} hours" +%s)
}

# Function to delete snapshots
delete_snapshots() {
    local ds="$1"
    local pat="$2"
    local th_date="$3"
    local ds_start deleted_count=0 kept_count=0 ds_failed=0
    ds_start=$(date +%s)

    echo "Debug: Inside delete_snapshots function" >&2
    echo "Debug: Dataset = $ds" >&2
    echo "Debug: Pattern = $pat" >&2

    # List snapshots of THIS dataset only (non-recursive), then keep only those
    # whose snapshot name (the part after '@') starts with the literal pattern.
    # Recursion into children is handled by process_datasets_recursively so that
    # each dataset is processed exactly once (see -R handling).
    local all_snapshots
    all_snapshots=$(zfs list -H -o name -t snapshot "${ds}" 2>/dev/null)

    local snapshots=""
    local line snapname
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        snapname="${line#*@}"
        if [[ "$snapname" == "${pat}"* ]]; then
            snapshots+="${line}"$'\n'
        fi
    done <<< "$all_snapshots"

    # If no snapshots are found, return early
    if [ -z "$snapshots" ]; then
        echo "No snapshots found for dataset $ds matching pattern $pat" >&2
        emit_stats "$ds" "$pat" "success" "$(( $(date +%s) - ds_start ))" 0 0
        return 0
    fi

    echo "Debug: Snapshots found: ${snapshots}" >&2

    while IFS= read -r snapshot; do
        [ -z "$snapshot" ] && continue
        creation_date_sec=$(zfs get -H -p -o value creation "${snapshot}")

        echo "Debug: Snapshot = $snapshot, creation_date_sec = $creation_date_sec" >&2

        if [ "${creation_date_sec}" -lt "${th_date}" ]; then
            echo "Deleting snapshot: ${snapshot}" >&2
            zfs destroy -R "${snapshot}"
            if [ $? -ne 0 ]; then
                echo "Error deleting snapshot: ${snapshot}" >&2
                EXIT_CODE=1
                ds_failed=1
            else
                deleted_count=$((deleted_count + 1))
            fi
        else
            echo "Keeping snapshot: ${snapshot} (newer than threshold)" >&2
            kept_count=$((kept_count + 1))
        fi
    done <<< "$snapshots"

    emit_stats "$ds" "$pat" "$([ "$ds_failed" -eq 0 ] && echo success || echo failed)" \
        "$(( $(date +%s) - ds_start ))" "$deleted_count" "$kept_count"
}

# Function to recursively process datasets
process_datasets_recursively() {
    local base_ds="$1"
    local pat="$2"
    local th_date="$3"

    delete_snapshots "${base_ds}" "${pat}" "${th_date}"

    child_datasets=$(zfs list -H -o name -t filesystem,volume -r "${base_ds}" | grep -v "^${base_ds}$")
    for child in ${child_datasets}; do
        echo "Debug: Processing child dataset = $child" >&2
        delete_snapshots "${child}" "${pat}" "${th_date}"
    done
}

# Main function to process datasets
process_datasets() {
    local recurse="$1"
    local datasets_list="$2"
    local pattern="$3"
    local threshold_date="$4"

    IFS=',' read -r -a datasets <<< "$datasets_list"

    for dataset in "${datasets[@]}"; do
        if [ "$recurse" = true ]; then
            process_datasets_recursively "${dataset}" "${pattern}" "${threshold_date}"
        else
            delete_snapshots "${dataset}" "${pattern}" "${threshold_date}"
        fi
    done
}

command -v flock >/dev/null || { echo "Error: flock command not found." >&2; exit 1; }

# Check number of arguments
if [ "$#" -lt 3 ]; then
    usage
fi

recurse=false

# Check if first argument is -R
if [ "$1" == "-R" ]; then
    recurse=true
    shift
fi

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

# Calculate threshold date
threshold_date=$(calculate_threshold_date)
echo "Debug: threshold_date = $threshold_date ($(date -d "@$threshold_date"))" >&2

# Process datasets
process_datasets "$recurse" "$datasets_list" "$pattern" "$threshold_date"

exit "$EXIT_CODE"
