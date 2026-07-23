#!/bin/bash
set -o pipefail

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
# -v, --verbose        : Verbose tracing (the old "Debug:" lines). Off by
#                        default; also enabled by DEBUG=1 in the environment.
# -F                   : Clear-cut. Use `zfs destroy -R` instead of a plain
#                        destroy, cascading to same-named descendant snapshots
#                        and destroying dependent clones (even Proxmox linked
#                        clones). Dangerous, opt-in.
# -B                   : Bookmark mode. Prune ZFS BOOKMARKS instead of
#                        snapshots (see BOOKMARK PRUNING below). Age-based
#                        only -- count-based flags are rejected in this mode.
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
#
# BOOKMARK PRUNING (-B):
# snapsend.sh/snapget.sh (see lib-zfs-snap.sh) leave a bookmark per target
# (named "tgt-<8 hex chars>") on the SOURCE dataset, refreshed on every
# successful transfer to that target. A target that stops being used
# (decommissioned VM, retired backup job) leaves its bookmark behind forever
# -- record_send_bookmark only ever replaces its OWN target's bookmark, it
# has no way to know another one is now orphaned. -B prunes bookmarks by age
# instead: a bookmark that has NOT been refreshed in the given threshold is
# almost certainly orphaned, since any still-active target gets its bookmark
# touched every time its job runs. Pick a threshold comfortably longer than
# the longest real backup cycle you run, or this can prune a bookmark that
# is just waiting out a long gap (an offline host, a paused job).
# Only age-based flags apply (count-based makes no sense here: exactly one
# bookmark exists per target at any time by design, there is nothing to keep
# "the N most recent" of). Same PATTERN argument as snapshot mode, matched
# against the bookmark name after '#' -- pass "tgt-" to match everything this
# tool itself creates. Bookmarks are never clones and have no dependents, so
# -F/clear-cut is a no-op in this mode: destruction is always a plain `zfs
# destroy dataset#mark`. The Proxmox-reserved-prefix guard does not apply
# (bookmarks are never __replicate_/__migration__/vzdump).
#
# Example: prune snapsend/snapget bookmarks untouched for 30+ days:
#   ./delsnaps.sh -B -R "tank/data" "tgt-" -d30

VERSION='v1.18'
EXIT_CODE=0
DRY_RUN=false
CLEARCUT=false
BOOKMARK_MODE=false
PORT=22
KNOWN_HOSTS_FILE=""
STATS_LOG="${STATS_LOG:-/root/scripts/zfs-snapshot-stats.log}"

# Must match HOLD_TAG in lib-zfs-snap.sh -- this script is standalone (no
# `source`), so the tag is duplicated rather than shared. A snapshot held
# under this tag is the source of a snapsend.sh/snapget.sh transfer currently
# in flight (or one a stuck receive_resume_token still depends on); pruning
# it out from under that transfer would break it, possibly unrecoverably if
# it also destroys the only remaining incremental base. `zfs destroy` already
# refuses a held snapshot on its own, but without recognizing the tag this
# script would report that refusal as an error needing -F, when it is
# actually working as designed -- see is_held_by_us.
HOLD_TAG="zfssnapall_inflight"
# Verbose tracing. Off by default so cron logs stay clean (the old behaviour
# printed every "Debug:" line unconditionally, flooding 2>>$CRON_LOG). Turn on
# with -v/--verbose on the command line or DEBUG=1 in the environment.
DEBUG="${DEBUG:-false}"

dbg() {
    [ "$DEBUG" = true ] && echo "Debug: $*" >&2
    return 0
}

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

# True if $snap carries a hold tagged HOLD_TAG -- i.e. snapsend.sh/snapget.sh
# currently has it in flight (or a stuck resume still depends on it). Checked
# BEFORE attempting destroy_one, rather than parsing zfs's (locale-dependent)
# error text after a failed destroy, so a protected snapshot is reported as an
# expected, temporary skip instead of an error requiring -F/investigation.
# `zfs holds` is a read-only listing, no extra delegation needed beyond what
# destroy_one already requires.
is_held_by_us() {
    local snap="$1" ruser="$2" rhost="$3" tags
    tags=$(run_zfs "$ruser" "$rhost" holds -H "$snap" 2>/dev/null | awk '{print $2}')
    [[ "$tags" == *"$HOLD_TAG"* ]]
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

# Minimal JSON string escaping for values that come from config (dataset
# list/pattern) rather than from a fixed set of literals we control.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# One JSON object per processed dataset, appended to STATS_LOG as JSON-lines
# -- same schema convention as snapsend.sh/snapget.sh's emit_stats in
# lib-zfs-snap.sh (kept as a separate copy here since delsnaps.sh is
# standalone / not sourced), with deleted/kept counts in place of resumed.
# Best-effort: never lets a logging failure break the actual prune.
emit_stats() {
    local dataset="$1" pattern="$2" status="$3" duration="$4" deleted="$5" kept="$6"
    {
        printf '{"time":"%s","script":"%s","dataset":"%s","pattern":"%s","status":"%s","duration_s":%s,"deleted":%s,"kept":%s}\n' \
            "$(date -u +%FT%TZ)" "$(basename "$0")" \
            "$(json_escape "$dataset")" "$(json_escape "$pattern")" "$(json_escape "$status")" \
            "$duration" "$deleted" "$kept"
    } >> "$STATS_LOG" 2>/dev/null || true
}

# Function to display script usage
usage() {
    echo "Usage: $0 [-R] [-n] [-F] [-v] [-p PORT] [-k known_hosts] <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>"
    echo "   or: $0 [-R] [-n] [-F] [-p PORT] [-k known_hosts] <comma-separated list of datasets> <pattern> -Y<count> -M<count> -W<count> -D<count> -H<count>"
    echo "   or: $0 -B [-R] [-n] [-p PORT] [-k known_hosts] <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>  (prune BOOKMARKS, age-based only)"
    echo "   dataset entries may be remote: [user@]host:dataset (user defaults to root)"
    echo "   -F clear-cut: zfs destroy -R (also removes descendant snapshots and dependent clones)"
    echo "   -B bookmark mode: prune snapsend.sh/snapget.sh's per-target bookmarks instead of snapshots"
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

    if [ "$BOOKMARK_MODE" = true ] && [ "$count_flag_seen" = true ]; then
        echo "Error: -B (bookmark mode) only supports age-based flags (-y/-m/-w/-d/-h) -- count-based retention doesn't apply to bookmarks (exactly one exists per target at a time by design)" >&2
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

    dbg "Inside delete_snapshots function"
    dbg "Dataset = $ds_label"
    dbg "Pattern = $pat"
    dbg "Mode = $mode, Param = $param"

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
            dbg "Skipping protected snapshot (reserved by Proxmox VE): ${line}"
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

    dbg "Snapshots found: ${filtered[*]}"

    if [ "$mode" = "count" ]; then
        local total="${#filtered[@]}"
        local keep=$param
        [ "$keep" -lt 0 ] && keep=0
        local to_delete=$((total - keep))
        [ "$to_delete" -lt 0 ] && to_delete=0

        local i=0 snapshot
        for snapshot in "${filtered[@]}"; do
            if [ "$i" -lt "$to_delete" ]; then
                if is_held_by_us "${snapshot}" "$ruser" "$rhost"; then
                    if [ "$DRY_RUN" = true ]; then
                        echo "[DRY-RUN] Would skip snapshot (in-flight, protected by hold '$HOLD_TAG'): ${snapshot}" >&2
                    else
                        echo "Skipping snapshot (in-flight, protected by hold '$HOLD_TAG'): ${snapshot} -- reconsidered next run" >&2
                    fi
                    kept_count=$((kept_count + 1))
                elif [ "$DRY_RUN" = true ]; then
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

            dbg "Snapshot = $snapshot, creation_date_sec = $creation_date_sec"

            if [ "${creation_date_sec}" -lt "${param}" ]; then
                if is_held_by_us "${snapshot}" "$ruser" "$rhost"; then
                    if [ "$DRY_RUN" = true ]; then
                        echo "[DRY-RUN] Would skip snapshot (in-flight, protected by hold '$HOLD_TAG'): ${snapshot}" >&2
                    else
                        echo "Skipping snapshot (in-flight, protected by hold '$HOLD_TAG'): ${snapshot} -- reconsidered next run" >&2
                    fi
                    kept_count=$((kept_count + 1))
                elif [ "$DRY_RUN" = true ]; then
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

# Prune bookmarks by age -- the -B counterpart to delete_snapshots' age
# branch. Bookmarks are never clones and have no dependents (no -F concept),
# aren't subject to the Proxmox-reserved-prefix guard (that's a snapshot-name
# convention), and count-based retention is meaningless for them (parse_time_
# arguments already rejects -Y/-M/-W/-D/-H with -B). See "BOOKMARK PRUNING"
# in the header comment for why age is the right signal for "orphaned".
delete_bookmarks() {
    local ds="$1"
    local pat="$2"
    local threshold="$3"
    local ruser="${4:-}"
    local rhost="${5:-}"
    local ds_start deleted_count=0 kept_count=0 ds_failed=0
    ds_start=$(date +%s)
    local ds_label="$ds"
    [ -n "$rhost" ] && ds_label="${rhost}:${ds}"

    dbg "Inside delete_bookmarks function"
    dbg "Dataset = $ds_label, Pattern = $pat, threshold = $threshold"

    local all_bookmarks
    all_bookmarks=$(run_zfs "$ruser" "$rhost" list -H -o name -t bookmark "${ds}" 2>/dev/null)

    local filtered=()
    local line markname
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        markname="${line#*#}"
        [[ "$markname" == "${pat}"* ]] && filtered+=("$line")
    done <<< "$all_bookmarks"

    if [ "${#filtered[@]}" -eq 0 ]; then
        echo "No bookmarks found for dataset $ds_label matching pattern $pat" >&2
        emit_stats "$ds_label" "$pat" "success" "$(( $(date +%s) - ds_start ))" 0 0
        return 0
    fi

    dbg "Bookmarks found: ${filtered[*]}"

    local mark creation_date_sec
    for mark in "${filtered[@]}"; do
        creation_date_sec=$(run_zfs "$ruser" "$rhost" get -H -p -o value creation "${mark}")

        dbg "Bookmark = $mark, creation_date_sec = $creation_date_sec"

        if [ "${creation_date_sec}" -lt "${threshold}" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "[DRY-RUN] Would delete bookmark: ${mark}" >&2
                deleted_count=$((deleted_count + 1))
            else
                echo "Deleting bookmark: ${mark}" >&2
                if run_zfs "$ruser" "$rhost" destroy "${mark}"; then
                    deleted_count=$((deleted_count + 1))
                else
                    echo "Error deleting bookmark: ${mark}" >&2
                    EXIT_CODE=1
                    ds_failed=1
                fi
            fi
        else
            if [ "$DRY_RUN" = true ]; then
                echo "[DRY-RUN] Would keep bookmark: ${mark} (newer than threshold)" >&2
            else
                echo "Keeping bookmark: ${mark} (newer than threshold)" >&2
            fi
            kept_count=$((kept_count + 1))
        fi
    done

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

# Dispatch to delete_bookmarks (-B) or delete_snapshots (default) for one
# dataset. mode/param are only meaningful for delete_snapshots -- delete_
# bookmarks takes just the age threshold, which is param in age mode (the
# only mode -B allows; parse_time_arguments already rejected count+-B).
prune_one() {
    local ds="$1" pat="$2" mode="$3" param="$4" ruser="${5:-}" rhost="${6:-}"
    if [ "$BOOKMARK_MODE" = true ]; then
        delete_bookmarks "${ds}" "${pat}" "${param}" "${ruser}" "${rhost}"
    else
        delete_snapshots "${ds}" "${pat}" "${mode}" "${param}" "${ruser}" "${rhost}"
    fi
}

# Function to recursively process datasets
process_datasets_recursively() {
    local base_ds="$1"
    local pat="$2"
    local mode="$3"
    local param="$4"
    local ruser="${5:-}"
    local rhost="${6:-}"

    prune_one "${base_ds}" "${pat}" "${mode}" "${param}" "${ruser}" "${rhost}"

    # Fetch the full descendant list (local or over ssh) and drop base_ds itself
    # in bash rather than piping the remote output through grep -- keeps the
    # remote command a single quoted zfs call with no shell metacharacters.
    local all_datasets child
    all_datasets=$(run_zfs "$ruser" "$rhost" list -H -o name -t filesystem,volume -r "${base_ds}")
    for child in ${all_datasets}; do
        [ "$child" = "$base_ds" ] && continue
        dbg "Processing child dataset = $child"
        prune_one "${child}" "${pat}" "${mode}" "${param}" "${ruser}" "${rhost}"
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
            prune_one "${R_DS}" "${pattern}" "${mode}" "${param}" "${R_USER}" "${R_HOST}"
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
        -B) BOOKMARK_MODE=true; shift ;;
        -v|--verbose) DEBUG=true; shift ;;
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
# Meaningless in bookmark mode (bookmarks have no clones/dependents; -B always
# does a plain `zfs destroy`), so say so instead of silently ignoring it.
if [ "$CLEARCUT" = true ] && [ "$BOOKMARK_MODE" = true ]; then
    echo "NOTE: -F has no effect in bookmark mode (-B) -- bookmarks have no clones or dependents, destruction is always a plain 'zfs destroy'." >&2
elif [ "$CLEARCUT" = true ]; then
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
[ -d "$LOCKDIR" ] && [ -w "$LOCKDIR" ] || { echo "Error: LOCKDIR '$LOCKDIR' is not a writable directory (create it or point LOCKDIR at one, e.g. LOCKDIR=~/run for a non-root run)." >&2; exit 1; }
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
    dbg "mode=count keep_count=$retain_param"
else
    retain_mode="age"
    retain_param=$(calculate_threshold_date)
    dbg "mode=age threshold_date=$retain_param ($(date -d "@$retain_param"))"
fi

# Process datasets
process_datasets "$recurse" "$datasets_list" "$pattern" "$retain_mode" "$retain_param"

exit "$EXIT_CODE"
