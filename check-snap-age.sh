#!/bin/bash
set -o pipefail

# check-snap-age.sh
# Version: run with -V/--version; see git log for full changelog

# Description:
# Nagios-style staleness check for ZFS snapshots: for each dataset given, finds
# the newest snapshot whose name (the part after '@') starts with the given
# literal pattern, and compares its age against a warn/crit threshold. Exit
# code is the WORST severity seen across every dataset checked (0/1/2), so it
# plugs straight into gen-cron.sh's existing "... || notify-fail.sh" convention
# -- same as every snapsend.sh/delsnaps.sh line already does, just answering
# "did this land recently enough" instead of "did the transfer succeed".
#
# This does NOT create, send, or destroy anything -- read-only, no lock needed.
# Datasets are always local (the host running the cron line); unlike
# delsnaps.sh/snapsend.sh there is no remote/ssh mode, since a monitor check is
# meant to run on the same host that owns the schedule being verified.
#
# Usage: check-snap-age.sh [-R] [-v] <comma-separated datasets> <pattern> <warn> <crit>
#
# -R            : also check every descendant dataset (filesystem/volume) under
#                 each entry, evaluated independently against the SAME
#                 pattern/thresholds -- mirrors delsnaps.sh -R (one rule applied
#                 per-dataset, not a single aggregate check across the subtree).
# -v, --verbose : print a status line for every dataset checked, not just the
#                 ones that trip a threshold.
# -V, --version : print version and exit.
#
# <warn>/<crit> : duration strings, <N><unit> with unit m(inutes)/h(ours)/d(ays)
#                 -- e.g. 90m, 3h, 9d. crit must be >= warn.
#
# Exit codes (Nagios convention): 0=OK, 1=WARNING, 2=CRITICAL.
# A dataset with NO snapshot matching the pattern at all is CRITICAL (nothing
# has ever landed, or the pattern/dataset is wrong -- either way, worth paging).
#
# Example:
#   ./check-snap-age.sh "rpool/data/vm-106-disk-0" "automated_hourly" 90m 3h
#   ./check-snap-age.sh -R "hdd/backups/pve1" "automated_daily" 30h 48h

VERSION='v1.1'

if [ "${1:-}" = "-V" ] || [ "${1:-}" = "--version" ]; then
    echo "$VERSION"
    exit 0
fi

usage() {
    echo "Usage: $0 [-R] [-v] <comma-separated list of datasets> <pattern> <warn> <crit>" >&2
    echo "   warn/crit are durations like 90m, 3h, 9d" >&2
    exit 1
}

VERBOSE=false
RECURSE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -R) RECURSE=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        *) break ;;
    esac
done

[ "$#" -eq 4 ] || usage
DATASETS_LIST="$1"
PATTERN="$2"
WARN_ARG="$3"
CRIT_ARG="$4"

# Converts "<N><m|h|d>" to seconds; echoes the value or returns 1 on a
# malformed duration (caught once at startup so a typo fails loudly, not by
# silently comparing against 0).
parse_duration() {
    local s="$1"
    [[ "$s" =~ ^([0-9]+)([mhd])$ ]] || { echo "invalid duration '$s' (expected <N>m, <N>h, or <N>d)" >&2; return 1; }
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
    esac
}

WARN_SEC=$(parse_duration "$WARN_ARG") || exit 1
CRIT_SEC=$(parse_duration "$CRIT_ARG") || exit 1
[ "$CRIT_SEC" -ge "$WARN_SEC" ] || { echo "crit ($CRIT_ARG) must be >= warn ($WARN_ARG)" >&2; exit 1; }

# Formats a seconds count back into the same "<N><unit>" shorthand, picking the
# coarsest unit that divides evenly, purely for readable status lines.
fmt_duration() {
    local sec="$1"
    if [ "$((sec % 86400))" -eq 0 ]; then
        echo "$((sec / 86400))d"
    elif [ "$((sec % 3600))" -eq 0 ]; then
        echo "$((sec / 3600))h"
    else
        echo "$((sec / 60))m"
    fi
}

NOW=$(date +%s)
WORST=0   # 0=OK 1=WARN 2=CRIT, tracks the max across every dataset checked

# Checks one dataset (non-recursive: only ITS OWN snapshots, matching
# delsnaps.sh's "list -t snapshot <dataset>" semantics). Bumps WORST as needed
# and prints a status line (always in -v mode, otherwise only when non-OK).
#
# explicit=true for a dataset named directly on the command line: "nothing
# matches" there is always CRITICAL, the caller asked for this exact path.
# explicit=false for a -R discovered descendant: a dataset that has NEVER had
# ANY snapshot at all (not just none matching the pattern) is silently
# skipped -- it's almost always an intermediate container in the hierarchy
# (e.g. the parent of several real leaf datasets), not something meant to be
# monitored on its own. A descendant that HAS other snapshots but none
# matching the pattern is still a real finding and stays CRITICAL.
check_one() {
    local ds="$1" explicit="$2"
    local newest="" newest_epoch="" line snapname any_snap=false

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        any_snap=true
        snapname="${line#*@}"
        [[ "$snapname" == "${PATTERN}"* ]] && newest="$line"
    done < <(zfs list -H -o name -s creation -t snapshot "$ds" 2>/dev/null)

    if [ -z "$newest" ]; then
        if [ "$any_snap" = false ] && [ "$explicit" != true ]; then
            [ "$VERBOSE" = true ] && echo "SKIP dataset=$ds -- no snapshots at all (not an explicit target, likely a container node)" >&2
            return
        fi
        echo "CRITICAL dataset=$ds pattern=$PATTERN -- no snapshot found matching this pattern" >&2
        [ "$WORST" -lt 2 ] && WORST=2
        return
    fi

    newest_epoch=$(zfs get -H -p -o value creation "$newest" 2>/dev/null)
    local age=$((NOW - newest_epoch))
    local age_h=$((age / 3600))

    local sev=0 label="OK"
    if [ "$age" -ge "$CRIT_SEC" ]; then
        sev=2; label="CRITICAL"
    elif [ "$age" -ge "$WARN_SEC" ]; then
        sev=1; label="WARNING"
    fi
    [ "$WORST" -lt "$sev" ] && WORST=$sev

    if [ "$sev" -gt 0 ] || [ "$VERBOSE" = true ]; then
        echo "$label dataset=$ds pattern=$PATTERN newest=${newest#*@} age=${age_h}h (warn=$(fmt_duration "$WARN_SEC") crit=$(fmt_duration "$CRIT_SEC"))" >&2
    fi
}

# In -R mode the named dataset is a subtree ROOT, not necessarily a leaf that
# should hold matching snapshots itself (that's the whole point of -R: check
# whatever real leaves live under it) -- so it gets the same "empty container"
# leniency as its discovered descendants, not the explicit/mandatory check.
IFS=',' read -r -a DATASETS <<< "$DATASETS_LIST"
for ds in "${DATASETS[@]}"; do
    if [ "$RECURSE" = true ]; then
        check_one "$ds" false
        while IFS= read -r child; do
            [ -z "$child" ] || [ "$child" = "$ds" ] && continue
            check_one "$child" false
        done < <(zfs list -H -o name -t filesystem,volume -r "$ds" 2>/dev/null)
    else
        check_one "$ds" true
    fi
done

exit "$WORST"
