#!/bin/bash
set -o pipefail

# Author: Wojciech Król & Chat-GPT 4
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
#                        StrictHostKeyChecking=accept-new, matching snapsend.sh/snapget.sh.
# -c <CIPHER_SPEC>     : SSH cipher(s) to request (ssh -c). No-op with no remote
#                        dataset entry. Matches snapsend.sh/snapget.sh -c.
# -K <FILE>            : SSH private key to authenticate with (ssh -i, plus -o
#                        IdentitiesOnly=yes). Matches snapsend.sh/snapget.sh -K.
# -O <SSH_OPTION>      : Extra "ssh -o NAME=VALUE", verbatim. Repeatable.
#                        Matches snapsend.sh/snapget.sh -O (see there for why it
#                        is placed first on the ssh command line).
# -P <prefix>:<keep>   : How many of the NEWEST snapshots carrying a reserved
#                        prefix to protect, per dataset. Repeatable; a prefix
#                        not named keeps its default. Defaults are
#                        __replicate_/__migration__/vzdump = "all", i.e. the
#                        absolute protection this script has always had.
#                          -P "__replicate_:1"  keep the newest one, older ones
#                                               become eligible for the normal
#                                               pattern match
#                          -P "__replicate_:0"  no protection for that prefix
#                        Only relaxes the guard -- an older reserved snapshot
#                        still has to MATCH the run's pattern to be deleted, so
#                        a routine "automated_hourly_" run never touches one.
#                        Point: on a backup target that received a replication
#                        stream (-r/-I carry every snapshot), these accumulate
#                        forever and only the newest has any value.
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
# -G                    : GFS cascading ladder instead of a flat sum -- see
#                        "GFS LADDER" below. Count-based letters only.
#
# BOOKMARK PRUNING (-B):
# snapsend.sh/snapget.sh (see lib-zfs-snap.sh) leave a bookmark per target
# (named "tgt-<8 hex chars>", the hash covering target dataset + -j identifier
# if one was given) on the SOURCE dataset, refreshed on every successful
# transfer to that target. A target that stops being used
# (decommissioned VM, retired backup job) leaves its bookmark behind forever
# -- record_send_bookmark only ever replaces its OWN target's bookmark, it
# has no way to know another one is now orphaned. -B prunes bookmarks by age
# instead: a bookmark that has NOT been refreshed in the given threshold is
# almost certainly orphaned, since any still-active target gets its bookmark
# touched every time its job runs. Pick a threshold comfortably longer than
# the longest real backup cycle you run, or this can prune a bookmark that
# is just waiting out a long gap (an offline host, a paused job).
# Only age-based flags apply (count-based makes no sense here: exactly one
# bookmark exists per target+identifier pair at any time by design, there is
# nothing to keep "the N most recent" of). Same PATTERN argument as snapshot mode, matched
# against the bookmark name after '#' -- pass "tgt-" to match everything this
# tool itself creates. Bookmarks are never clones and have no dependents, so
# -F/clear-cut is a no-op in this mode: destruction is always a plain `zfs
# destroy dataset#mark`. The Proxmox-reserved-prefix guard does not apply
# (bookmarks are never __replicate_/__migration__/vzdump).
#
# Example: prune snapsend/snapget bookmarks untouched for 30+ days:
#   ./delsnaps.sh -B -R "tank/data" "tgt-" -d30
#
# GFS LADDER (-G):
# An alternative to plain count-based retention for a dataset with NO naming
# convention to lean on (e.g. snapshots taken with no -m on snapsend.sh/
# snapget.sh, all bare timestamps -- see the pattern="" case above). Reuses
# the same -H/-D/-W/-M/-Y letters, but instead of summing them into one flat
# keep-count, each one becomes its own rung of a cascading tower:
#   -H<N>  the N most recent HOURS, one snapshot kept per hour
#   -D<N>  the N DAYS right after that, one kept per day
#   -W<N>  the N WEEKS right after that, one kept per week
#   -M<N>  the N MONTHS right after that, one kept per month (30-day buckets)
#   -Y<N>  the N YEARS right after that, one kept per year (365-day buckets)
# Always in that order (H -> D -> W -> M -> Y); a letter not given simply has
# no rung. Each rung starts exactly where the previous one ends, so ranges
# never overlap -- a daily bucket can never re-pick a snapshot an hourly
# bucket already claimed. Within one bucket, the survivor is the NEWEST
# snapshot whose creation time falls inside it; an empty bucket (a gap in the
# source cadence) simply has no survivor -- nothing is invented to fill it.
# Anything older than the outermost requested rung, and anything inside a
# rung that isn't a bucket's survivor, is deleted (subject to the same
# reserved-prefix and in-flight-hold protections as every other mode).
#
# Opt-in and orthogonal to pattern -- works with a real pattern too, not only
# an empty one. Without -G, delsnaps.sh behaves exactly as it always has,
# INCLUDING combining multiple -H/-D/-W/-M/-Y into one flat summed keep-count
# (unchanged; -G only gives that combination a new meaning when asked for).
# Rejected outright: mixed with age-based lowercase flags (no ladder meaning
# for those), with -B (bookmarks have no "N representatives" concept), or
# given with no -H/-D/-W/-M/-Y at all (nothing to build a ladder from).
#
# Example: a dataset with thousands of unpruned bare-timestamp hourly
# snapshots, thin it into a classic tower in one shot:
#   ./delsnaps.sh -n -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3
# (drop -n to actually delete once the dry-run output looks right)

VERSION='v1.28'
EXIT_CODE=0
DRY_RUN=false
CLEARCUT=false
BOOKMARK_MODE=false
PORT=22
KNOWN_HOSTS_FILE=""
SSH_CIPHER=""
SSH_KEY=""
declare -a EXTRA_SSH_OPTS=()
declare -a PROTECT_SPECS=()
# -G: cascading GFS ladder instead of a flat summed count. GFS_KEEP holds the
# per-tier N (populated from keep_hours/keep_days/... after parse_time_arguments
# runs); GFS_NOW is the single anchor epoch for the whole invocation, set once
# before any dataset is processed so a multi-dataset/-R run shares one
# consistent "now" rather than drifting between datasets. GFS_UNIT_SECONDS are
# fixed-width bucket sizes, not calendar-aware -- every bucket within a tier is
# exactly the same width (a "month" is 30 days, a "year" 365), which is simpler
# and more uniform than real calendar months (28-31 days) at the cost of
# calendar precision this tool never needed anyway.
GFS_MODE=false
declare -A GFS_KEEP=()
# Preserves an environment-provided override (see the GFS_NOW assignment
# below, and its comment, for why) -- this bare declaration must NOT clobber
# it with an unconditional "", or the override would already be lost before
# the real logic ever reads it. Confirmed live: this exact bug shipped once.
GFS_NOW="${GFS_NOW:-}"
declare -Ar GFS_UNIT_SECONDS=( [H]=3600 [D]=86400 [W]=604800 [M]=2592000 [Y]=31536000 )
# Default paths follow the ACCOUNT, not root. A delegated non-root run cannot
# read anything under /root (0700), so defaulting there gave it a stats log it
# could not write ("Permission denied" once per dataset), a notify script it
# could not execute, and a lock dir it could not create -- while deploy.sh had
# already provisioned $HOME/run, $HOME/zfs-snapshot-stats.log (its logrotate
# stanza rotates exactly that path) and $HOME/notify-fail.sh for it. The two
# sides now agree. An explicit environment variable still wins over both.
if [ "$(id -u)" -eq 0 ]; then
    ZFS_SNAP_DEFAULT_STATS="/root/scripts/zfs-snapshot-stats.log"
    ZFS_SNAP_DEFAULT_NOTIFY="/root/scripts/notify-fail.sh"
    ZFS_SNAP_DEFAULT_LOCKDIR="/var/run"
else
    # HOME is set by cron and by `su`, but not by `env -i` or a bare systemd
    # unit -- fall back to the passwd entry rather than resolving "$HOME/run"
    # to "/run" and failing with a message that points at the wrong thing.
    _zfs_snap_home="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
    ZFS_SNAP_DEFAULT_STATS="$_zfs_snap_home/zfs-snapshot-stats.log"
    ZFS_SNAP_DEFAULT_NOTIFY="$_zfs_snap_home/notify-fail.sh"
    ZFS_SNAP_DEFAULT_LOCKDIR="$_zfs_snap_home/run"
fi
STATS_LOG="${STATS_LOG:-$ZFS_SNAP_DEFAULT_STATS}"

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
# and friends -- prune one out from under them and the next
# replication/migration/backup run breaks with a snapshot-chain mismatch this
# tool cannot repair.
#
# The value is HOW MANY of the newest matching snapshots to keep, per dataset:
#   all   -- protect every one (the default, and the pre-v1.25 behaviour)
#   <N>   -- protect the N newest, let anything older fall through to the
#            normal pattern match
#   0     -- no protection for that prefix at all
#
# Why a count and not a boolean: on the SOURCE, pvesr keeps exactly one of its
# own snapshots per dataset and removes the rest itself, so the distinction
# never comes up. On a BACKUP TARGET that received a replication stream (-r/-I
# carry every snapshot, not just the ones this tool made) nothing prunes them
# and they accumulate forever -- while only the newest common one has any value
# for a future incremental. Absolute protection made that garbage immortal.
#
# Defaults stay absolute so no existing invocation changes behaviour; -P is an
# opt-in relaxation, per prefix, leaving the prefixes it does not name alone.
declare -A PROTECT_KEEP=(
    ["__replicate_"]="all"
    ["__migration__"]="all"
    ["vzdump"]="all"
)

# Build the set of snapshots to protect FOR ONE DATASET. Per dataset, not
# globally: each dataset carries its own replication chain, so "the newest one"
# only means anything within a single dataset.
#
# Input is the dataset's snapshot list, oldest first (`zfs list -s creation`),
# so the N newest matching a prefix are simply the last N of the matches.
build_protected_set() {
    local all="$1" prefix keep line i n start
    declare -gA PROTECTED_NOW=()
    for prefix in "${!PROTECT_KEEP[@]}"; do
        keep="${PROTECT_KEEP[$prefix]}"
        [ "$keep" = "0" ] && continue
        local -a matching=()
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "${line#*@}" == "${prefix}"* ]] && matching+=("$line")
        done <<< "$all"
        n=${#matching[@]}
        [ "$n" -eq 0 ] && continue
        start=0
        if [ "$keep" != "all" ]; then
            start=$(( n - keep ))
            [ "$start" -lt 0 ] && start=0
        fi
        for ((i = start; i < n; i++)); do
            PROTECTED_NOW["${matching[$i]}"]=1
        done
        if [ "$keep" != "all" ] && [ "$start" -gt 0 ]; then
            dbg "Protection: '$prefix' keeping $keep newest of $n; $start older now prunable"
        fi
    done
}

# True when this exact snapshot is protected for the dataset currently being
# processed. Takes the FULL name (dataset@snap) because build_protected_set
# keys on it -- two datasets can legitimately hold the same snapshot name.
is_protected_snapshot() {
    [ -n "${PROTECTED_NOW[$1]:-}" ]
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
    # `--` is inserted right before the FINAL argument, which in every call
    # site in this script is the dataset/snapshot/bookmark name. Without it, a
    # name that happens to start with '-' is not passed to zfs as data -- zfs
    # has its own getopt-style parser and reads it as ONE OF ITS OWN flags.
    # Confirmed live: this script's own argument parsing can produce exactly
    # such a string by accident (an unrecognized flag like the lowercase "-r",
    # which does not exist here, ends up shifted into the dataset-list
    # position instead of erroring). Without --, `zfs list ... "-r"` is not
    # "dataset -r not found" -- zfs reads "-r" as ITS OWN recurse flag with no
    # target, and recurses from the implicit root: every dataset on the host,
    # not the one the caller meant. With --, the same call correctly fails
    # "dataset does not exist", which this script's own exit-code check (see
    # delete_snapshots/delete_bookmarks) already turns into a loud failure
    # instead of a silent, scope-widened "success".
    local -a args=("$@")
    local last=$(( ${#args[@]} - 1 ))
    local target="${args[$last]}"
    unset 'args[last]'
    if [ -n "$rhost" ]; then
        local cmd="zfs" arg
        for arg in "${args[@]}"; do
            cmd+=" '${arg}'"
        done
        cmd+=" -- '${target}'"
        ssh "${SSH_OPTS[@]}" "$ruser@$rhost" "$cmd"
    else
        zfs "${args[@]}" -- "$target"
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
    echo "Usage: $0 [-R] [-n] [-F] [-v] [-p PORT] [-k known_hosts] [-c CIPHER] [-K KEYFILE] [-O ssh_opt]... [-P prefix:keep]... <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>"
    echo "   or: $0 [-R] [-n] [-F] [-p PORT] [-k known_hosts] [-c CIPHER] [-K KEYFILE] [-O ssh_opt]... [-P prefix:keep]... <comma-separated list of datasets> <pattern> -Y<count> -M<count> -W<count> -D<count> -H<count>"
    echo "   or: $0 -B [-R] [-n] [-p PORT] [-k known_hosts] [-c CIPHER] [-K KEYFILE] [-O ssh_opt]... [-P prefix:keep]... <comma-separated list of datasets> <pattern> -y<years> -m<months> -w<weeks> -d<days> -h<hours>  (prune BOOKMARKS, age-based only)"
    echo "   or: $0 -G [-R] [-n] [-F] [-p PORT] [-k known_hosts] [-c CIPHER] [-K KEYFILE] [-O ssh_opt]... [-P prefix:keep]... <comma-separated list of datasets> <pattern> -H<N> -D<N> -W<N> -M<N> -Y<N>  (cascading GFS ladder, see header)"
    echo "   dataset entries may be remote: [user@]host:dataset (user defaults to root)"
    echo "   -F clear-cut: zfs destroy -R (also removes descendant snapshots and dependent clones)"
    echo "   -B bookmark mode: prune snapsend.sh/snapget.sh's per-target bookmarks instead of snapshots"
    echo "   -G GFS ladder: -H/-D/-W/-M/-Y become cascading tiers instead of a flat summed count"
    echo "   -c/-K/-O: SSH cipher / private key / extra -o option, same as snapsend.sh/snapget.sh"
    echo "   -P <prefix>:<keep>: protect only the <keep> newest reserved snapshots per dataset"
    echo "                       (default: __replicate_/__migration__/vzdump all protected)"
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
    # If the listing itself fails -- wrong SSH port/cipher/key, a revoked
    # authorized_keys entry, the host simply unreachable -- this must NOT look
    # like "the dataset just happens to have nothing to prune". Before this
    # check, it did: $? was never inspected, so an ssh failure produced empty
    # output exactly like a genuinely empty dataset, and the caller reported
    # "No snapshots found ... success". A retention job that keeps "succeeding"
    # while silently doing nothing is worse than one that fails loudly -- found
    # live while proving -c actually reaches ssh (a bogus cipher name made ssh
    # refuse the connection, and this is what was hiding that refusal).
    local all_snapshots
    if ! all_snapshots=$(run_zfs "$ruser" "$rhost" list -H -o name -s creation -t snapshot "${ds}" 2>/dev/null); then
        echo "Error: could not list snapshots for $ds_label -- ssh/zfs failed (check connectivity, -p/-k/-c/-K/-O, or that the dataset exists)" >&2
        emit_stats "$ds_label" "$pat" "failed" "$(( $(date +%s) - ds_start ))" 0 0
        # Set directly rather than relying on the caller to check this
        # function's return value -- prune_one/process_datasets_recursively
        # don't, the same way the destroy-failure paths below set it directly
        # instead of trusting their own caller.
        EXIT_CODE=1
        return 1
    fi

    # Which reserved snapshots are off-limits for THIS dataset, given the
    # per-prefix keep counts. Recomputed per dataset because "the N newest"
    # is only meaningful within one dataset's own chain.
    build_protected_set "$all_snapshots"

    local filtered=()
    local line snapname
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        snapname="${line#*@}"
        if is_protected_snapshot "$line"; then
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
    elif [ "$mode" = "gfs" ]; then
        # Cascading GFS ladder -- see the header comment ("GFS LADDER") for the
        # full design. Creation times are fetched up front (one call per
        # snapshot, same convention as age mode below) so every bucket
        # comparison afterward is a plain integer test, no repeated zfs calls.
        local -a gfs_times=()
        local snapshot
        for snapshot in "${filtered[@]}"; do
            gfs_times+=("$(run_zfs "$ruser" "$rhost" get -H -p -o value creation "${snapshot}")")
        done

        # Which snapshot (if any) survives each bucket, and its label (e.g.
        # "H#3") for the log line -- built tier by tier, cascading: each
        # tier's range starts exactly where the previous (finer) tier's range
        # ended, so ranges never overlap and a coarser tier can never re-pick
        # a snapshot a finer one already claimed.
        local -A gfs_survivor_label=()
        local gfs_cascade_end="$GFS_NOW" gfs_tier gfs_unit gfs_n gfs_tier_start
        local gfs_i gfs_bucket_hi gfs_bucket_lo gfs_idx gfs_best_name gfs_best_time gfs_t gfs_label
        for gfs_tier in H D W M Y; do
            gfs_n="${GFS_KEEP[$gfs_tier]:-0}"
            [ "$gfs_n" -gt 0 ] || continue
            gfs_unit="${GFS_UNIT_SECONDS[$gfs_tier]}"
            gfs_tier_start="$gfs_cascade_end"
            for ((gfs_i = 1; gfs_i <= gfs_n; gfs_i++)); do
                gfs_bucket_hi=$(( gfs_tier_start - (gfs_i - 1) * gfs_unit ))
                gfs_bucket_lo=$(( gfs_tier_start - gfs_i * gfs_unit ))
                gfs_best_name=""
                gfs_best_time=-1
                for ((gfs_idx = 0; gfs_idx < ${#filtered[@]}; gfs_idx++)); do
                    gfs_t="${gfs_times[$gfs_idx]}"
                    if [ "$gfs_t" -gt "$gfs_bucket_lo" ] && [ "$gfs_t" -le "$gfs_bucket_hi" ] \
                       && [ "$gfs_t" -gt "$gfs_best_time" ]; then
                        gfs_best_time="$gfs_t"
                        gfs_best_name="${filtered[$gfs_idx]}"
                    fi
                done
                gfs_label="${gfs_tier}#${gfs_i}"
                if [ -n "$gfs_best_name" ]; then
                    gfs_survivor_label["$gfs_best_name"]="$gfs_label"
                    dbg "GFS bucket $gfs_label ($(date -d "@$gfs_bucket_lo" '+%F %T') , $(date -d "@$gfs_bucket_hi" '+%F %T')]: keep $gfs_best_name"
                else
                    dbg "GFS bucket $gfs_label ($(date -d "@$gfs_bucket_lo" '+%F %T') , $(date -d "@$gfs_bucket_hi" '+%F %T')]: empty, no survivor"
                fi
            done
            gfs_cascade_end=$(( gfs_tier_start - gfs_n * gfs_unit ))
        done

        for snapshot in "${filtered[@]}"; do
            if [ -n "${gfs_survivor_label[$snapshot]:-}" ]; then
                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would keep snapshot: ${snapshot} (GFS ${gfs_survivor_label[$snapshot]})" >&2
                else
                    echo "Keeping snapshot: ${snapshot} (GFS ${gfs_survivor_label[$snapshot]})" >&2
                fi
                kept_count=$((kept_count + 1))
            elif is_held_by_us "${snapshot}" "$ruser" "$rhost"; then
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

    # Same reasoning as delete_snapshots: an ssh/zfs failure here must not read
    # as "no bookmarks to prune".
    local all_bookmarks
    if ! all_bookmarks=$(run_zfs "$ruser" "$rhost" list -H -o name -t bookmark "${ds}" 2>/dev/null); then
        echo "Error: could not list bookmarks for $ds_label -- ssh/zfs failed (check connectivity, -p/-k/-c/-K/-O, or that the dataset exists)" >&2
        emit_stats "$ds_label" "$pat" "failed" "$(( $(date +%s) - ds_start ))" 0 0
        EXIT_CODE=1
        return 1
    fi

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
        -G) GFS_MODE=true; shift ;;
        -v|--verbose) DEBUG=true; shift ;;
        -p) PORT="$2"; shift 2 ;;
        -p*) PORT="${1#-p}"; shift ;;
        -k) KNOWN_HOSTS_FILE="$2"; shift 2 ;;
        -k*) KNOWN_HOSTS_FILE="${1#-k}"; shift ;;
        -c) SSH_CIPHER="$2"; shift 2 ;;
        -c*) SSH_CIPHER="${1#-c}"; shift ;;
        -K) SSH_KEY="$2"; shift 2 ;;
        -K*) SSH_KEY="${1#-K}"; shift ;;
        -O) EXTRA_SSH_OPTS+=("$2"); shift 2 ;;
        -P) PROTECT_SPECS+=("$2"); shift 2 ;;
        -P*) PROTECT_SPECS+=("${1#-P}"); shift ;;
        *) break ;;
    esac
done

# -P <prefix>:<keep> -- override the protection keep-count for one reserved
# prefix. Repeatable; prefixes not named keep their default. Validated here so
# a typo fails before anything is destroyed, not halfway through a dataset.
for _spec in "${PROTECT_SPECS[@]}"; do
    case "$_spec" in
        *:*) ;;
        *) echo "Error: -P '$_spec' -- expected <prefix>:<keep>, e.g. -P '__replicate_:1'" >&2; exit 1 ;;
    esac
    _pfx="${_spec%:*}"
    _keep="${_spec##*:}"
    [ -n "$_pfx" ] || { echo "Error: -P '$_spec' has an empty prefix" >&2; exit 1; }
    case "$_keep" in
        all|0|[1-9]|[1-9][0-9]*) ;;
        *) echo "Error: -P '$_spec' -- keep must be 'all', 0, or a positive integer" >&2; exit 1 ;;
    esac
    PROTECT_KEEP["$_pfx"]="$_keep"
done

if [ -n "$SSH_KEY" ] && [ ! -r "$SSH_KEY" ]; then
    echo "Error: -K '$SSH_KEY' is not a readable file." >&2
    exit 1
fi

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
# StrictHostKeyChecking=accept-new, matching snapsend.sh/snapget.sh: trust the
# host key on first connection, refuse if it ever changes afterward. Only opt
# into -k on a host where KNOWN_HOSTS_FILE has already been populated (e.g. via
# ssh-keyscan) and the fingerprint verified out of band.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$PORT")
fi
[ -n "$SSH_CIPHER" ] && SSH_OPTS+=(-c "$SSH_CIPHER")

# -K/-O go at the FRONT, added last so nothing built above can out-rank them --
# OpenSSH keeps the FIRST value it sees for a given key (verified live in
# snapsend.sh's identical block: `-o Port=2222 -p 22` connects on 2222).
# delsnaps.sh has no ControlMaster multiplexing of its own to out-rank, unlike
# snapsend.sh/snapget.sh, but the same ordering keeps the three scripts' -O
# semantics identical rather than subtly different.
if [ -n "$SSH_KEY" ] || [ ${#EXTRA_SSH_OPTS[@]} -gt 0 ]; then
    declare -a _front_ssh_opts=()
    [ -n "$SSH_KEY" ] && _front_ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
    for _o in "${EXTRA_SSH_OPTS[@]}"; do _front_ssh_opts+=(-o "$_o"); done
    SSH_OPTS=("${_front_ssh_opts[@]}" "${SSH_OPTS[@]}")
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
LOCKDIR="${LOCKDIR:-$ZFS_SNAP_DEFAULT_LOCKDIR}"
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

# -G validation: checked here, after parse_time_arguments has already run, so
# age_flag_seen/count_flag_seen reflect exactly what was typed. Rejected
# rather than silently reinterpreted, same reasoning as every other flag
# conflict in this script -- a config mistake here is destructive, not cosmetic.
if [ "$GFS_MODE" = true ]; then
    if [ "$age_flag_seen" = true ]; then
        echo "Error: -G (GFS ladder) only takes count-based flags (-H/-D/-W/-M/-Y) -- age-based flags (-y/-m/-w/-d/-h) have no ladder meaning." >&2
        exit 1
    fi
    if [ "$BOOKMARK_MODE" = true ]; then
        echo "Error: -G (GFS ladder) does not apply to -B (bookmark mode) -- exactly one bookmark exists per target by design, there is nothing to build a ladder of representatives from." >&2
        exit 1
    fi
    if [ "$count_flag_seen" = false ]; then
        echo "Error: -G (GFS ladder) needs at least one of -H/-D/-W/-M/-Y -- none were given, nothing to build a ladder from." >&2
        exit 1
    fi
fi

if [ "$GFS_MODE" = true ]; then
    retain_mode="gfs"
    retain_param=0   # unused in gfs mode -- the real per-tier counts live in GFS_KEEP
    GFS_KEEP=( [H]="$keep_hours" [D]="$keep_days" [W]="$keep_weeks" [M]="$keep_months" [Y]="$keep_years" )
    # One anchor for the whole run, computed once -- a multi-dataset or -R
    # invocation shares a single consistent "now" instead of drifting slightly
    # between datasets processed moments apart. Overridable via the GFS_NOW
    # environment variable -- real snapshot creation times can't be backdated
    # on a live pool (see test/delsnaps/run.sh's age-mode tests for the same
    # constraint), but shifting the ANCHOR forward instead lets a test make a
    # snapshot created moments ago look e.g. 26 real hours old to the ladder,
    # exercising genuine cross-tier cascading without waiting. Same idiom as
    # ZFS_SNAP_RETUNE elsewhere in this project: a real value always wins,
    # this only ever fires when a test explicitly sets it.
    GFS_NOW="${GFS_NOW:-$(date +%s)}"
    dbg "mode=gfs now=$GFS_NOW keep=H:${keep_hours} D:${keep_days} W:${keep_weeks} M:${keep_months} Y:${keep_years}"
elif [ "$count_flag_seen" = true ]; then
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
