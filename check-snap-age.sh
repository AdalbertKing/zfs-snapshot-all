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
# Usage: check-snap-age.sh [-R] [-v] [-L LABEL] <comma-separated datasets> <pattern> <warn> <crit>
#
# -R            : also check every descendant dataset (filesystem/volume) under
#                 each entry, evaluated independently against the SAME
#                 pattern/thresholds -- mirrors delsnaps.sh -R (one rule applied
#                 per-dataset, not a single aggregate check across the subtree).
# -v, --verbose : print a status line for every dataset checked, not just the
#                 ones that trip a threshold.
# -L <LABEL>    : the backup relationship (zfs-backup.sh client) these datasets
#                 belong to. While that relationship is paused (pause-client),
#                 exit OK with wording naming the pause -- staleness is the
#                 EXPECTED state of a deliberately stopped backup, not a page
#                 (REV-20260804-045). resume-client restores normal thresholds.
# -V, --version : print version and exit.
#
# <warn>/<crit> : duration strings, <N><unit> with unit m(inutes)/h(ours)/d(ays)
#                 -- e.g. 90m, 3h, 9d. crit must be >= warn.
#
# Exit codes (Nagios convention): 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN.
#
# A dataset with NO snapshot matching the pattern is judged by the age of the
# DATASET ITSELF, through the same warn/crit ladder (REV-20260807-056). It used
# to be an unconditional CRITICAL, which was wrong for a dataset younger than
# its own backup interval: a guest created after the last scheduled run, and
# snapshotted by pvesr or vzdump before the next one, was reported as a stale
# backup of something that had never had the chance to have one. Nothing was
# broken, and the daily digest carried a false line anyway.
# Measuring from creation puts the alarm where the promise is actually broken:
# a 10-minute-old dataset reads OK, a 3-day-old one with no backup still reads
# CRITICAL. Status lines say which of the two the age came from, because
# "age=72h" means different things in each case.
# A dataset whose creation time cannot be read is UNKNOWN, never a guessed age.
#
# UNKNOWN (3) means THE CHECK ITSELF could not answer the question -- bad
# arguments, missing zfs, a dataset that does not exist -- as opposed to
# "the answer is bad". This distinction matters because the caller cannot see
# it otherwise: a monitor that never runs looks exactly like a monitor that
# says everything is fine. Two concrete failures this prevents:
#   - a typo'd threshold (e.g. "90x") used to exit 1, which the cron idiom
#     read as WARNING and silently swallowed -- the check then never verified
#     anything again, forever, without a single alert.
#   - a non-executable script exits 126 from the shell, which the old
#     "exit >= 2" test reported as a stale-snapshot CRITICAL, sending a mail
#     whose text was simply untrue.
# Callers should treat 2 and 3 as separate alerts with separate wording
# (gen-cron.sh emits exactly that; see emit_monitor there).
#
# When several datasets are checked in one run, CRITICAL outranks UNKNOWN in
# the final exit code: a genuinely stale snapshot is more actionable than an
# unresolvable dataset name, and every finding is written to stderr anyway, so
# the detail survives in the log even when the exit code can only carry one.
#
# Example:
#   ./check-snap-age.sh "rpool/data/vm-106-disk-0" "automated_hourly" 90m 3h
#   ./check-snap-age.sh -R "hdd/backups/pve1" "automated_daily" 30h 48h

VERSION='v2.2'

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

if [ "${1:-}" = "-V" ] || [ "${1:-}" = "--version" ]; then
    echo "$VERSION"
    exit 0
fi

# Every startup failure below exits UNKNOWN, never WARNING/CRITICAL: at this
# point no snapshot has been examined, so any answer about staleness would be
# fabricated.
usage() {
    echo "Usage: $0 [-R] [-v] [-L LABEL] <comma-separated list of datasets> <pattern> <warn> <crit>" >&2
    echo "   warn/crit are durations like 90m, 3h, 9d" >&2
    exit "$EXIT_UNKNOWN"
}

command -v zfs >/dev/null || { echo "UNKNOWN -- 'zfs' command not found in PATH" >&2; exit "$EXIT_UNKNOWN"; }

VERBOSE=false
RECURSE=false
PAIR_LABEL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -R) RECURSE=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -L) PAIR_LABEL="${2:-}"; shift 2 ;;
        *) break ;;
    esac
done
case "$PAIR_LABEL" in
    *[!A-Za-z0-9._-]*) echo "UNKNOWN -- -L '$PAIR_LABEL' is not a valid relationship label (letters, digits, dot, dash, underscore only)" >&2; exit "$EXIT_UNKNOWN" ;;
esac

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

WARN_SEC=$(parse_duration "$WARN_ARG") || exit "$EXIT_UNKNOWN"
CRIT_SEC=$(parse_duration "$CRIT_ARG") || exit "$EXIT_UNKNOWN"
[ "$CRIT_SEC" -ge "$WARN_SEC" ] || { echo "UNKNOWN -- crit ($CRIT_ARG) must be >= warn ($WARN_ARG)" >&2; exit "$EXIT_UNKNOWN"; }

# REV-20260804-045 (logical pause): while the -L relationship is paused,
# staleness IS the expected state -- the backup was stopped on purpose, so
# aging snapshots must not page every monitor interval. OK with explicit
# wording, never silence: the line still lands in cron.log, and `status`
# shows the pause. Checked AFTER argument validation on purpose -- a
# malformed threshold stays a loud UNKNOWN even on a paused relationship.
# Resume deletes the marker and the very next run enforces thresholds again.
RELATIONSHIPS_DIR="${RELATIONSHIPS_DIR:-/var/lib/zfs-snapshot-all/relationships}"
if [ -n "$PAIR_LABEL" ] && [ -f "$RELATIONSHIPS_DIR/$PAIR_LABEL/paused" ]; then
    echo "OK -- relationship $PAIR_LABEL is paused (zfs-backup.sh pause-client); staleness is expected until resume-client"
    exit "$EXIT_OK"
fi

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
WORST=0       # 0=OK 1=WARN 2=CRIT -- max CHECK RESULT across every dataset
SAW_UNKNOWN=0 # tracked separately: UNKNOWN is not "worse CRITICAL", it is a
              # different axis (we failed to look, vs we looked and it's bad),
              # so it must not be folded into WORST by numeric max.

# Checks one dataset (non-recursive: only ITS OWN snapshots, matching
# delsnaps.sh's "list -t snapshot <dataset>" semantics). Bumps WORST as needed
# and prints a status line (always in -v mode, otherwise only when non-OK).
#
# explicit=true for a dataset named directly on the command line: "nothing
# matches" there is still judged, by dataset age -- the caller asked for this
# exact path, so it is answered rather than skipped.
# explicit=false for a -R discovered descendant: a dataset that has NEVER had
# ANY snapshot at all (not just none matching the pattern) is silently
# skipped -- it's almost always an intermediate container in the hierarchy
# (e.g. the parent of several real leaf datasets), not something meant to be
# monitored on its own. A descendant that HAS other snapshots but none
# matching the pattern is still a real finding and stays CRITICAL.
# The ONLY way a creation timestamp enters this script (REV-20260807-056 §4/§5).
#
# `zfs get` can fail, print nothing, or -- on a dataset destroyed between the
# list and the get -- print "-". Bash reads an empty or non-numeric value in
# arithmetic as 0, so the old inline `$((NOW - $(zfs get ...)))` turned a failed
# read into an age of the entire Unix epoch and reported CRITICAL with a
# fabricated number. Fail-closed, but a measurement nobody made.
#
# Echoes a validated epoch, or returns 1 and echoes nothing.
creation_epoch() {   # <dataset or snapshot>
    local v
    v="$(zfs get -H -p -o value creation "$1" 2>/dev/null)" || return 1
    case "$v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$v"
}

check_one() {
    local ds="$1" explicit="$2"
    local newest="" newest_epoch="" line snapname any_snap=false

    # A dataset that does not exist is UNKNOWN, not CRITICAL: "you asked about
    # something that isn't here" is a config/typo problem, and reporting it as
    # a stale snapshot would send a mail describing a backup failure that never
    # happened.
    if ! zfs list -H -o name -t filesystem,volume "$ds" >/dev/null 2>&1; then
        echo "UNKNOWN dataset=$ds -- does not exist (typo, or removed since the config was written)" >&2
        SAW_UNKNOWN=1
        return
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        any_snap=true
        snapname="${line#*@}"
        [[ "$snapname" == "${PATTERN}"* ]] && newest="$line"
    done < <(zfs list -H -o name -s creation -t snapshot "$ds" 2>/dev/null)

    local from_creation=false detail
    if [ -z "$newest" ]; then
        if [ "$any_snap" = false ] && [ "$explicit" != true ]; then
            [ "$VERBOSE" = true ] && echo "SKIP dataset=$ds -- no snapshots at all (not an explicit target, likely a container node)" >&2
            return
        fi
        # REV-20260807-056: a dataset cannot be late before it exists. This used
        # to be an unconditional CRITICAL, which reported a guest created after
        # the last scheduled run -- and snapshotted by pvesr or vzdump before
        # the next one -- as a stale backup of something that never had the
        # chance to have one. Measuring from the dataset's own creation puts the
        # alarm where the promise is actually broken, and gives this case the
        # WARNING band it never had.
        if ! newest_epoch="$(creation_epoch "$ds")"; then
            echo "UNKNOWN dataset=$ds -- no snapshot matches pattern=$PATTERN and the dataset's creation time could not be read, so its age is unknown" >&2
            SAW_UNKNOWN=1
            return
        fi
        from_creation=true
    else
        if ! newest_epoch="$(creation_epoch "$newest")"; then
            echo "UNKNOWN dataset=$ds -- the creation time of ${newest#*@} could not be read, so its age is unknown" >&2
            SAW_UNKNOWN=1
            return
        fi
    fi

    local age=$((NOW - newest_epoch))
    # A timestamp in the future (clock skew, a pool imported from a host whose
    # clock ran ahead) is not negative age, it is no evidence of staleness.
    [ "$age" -lt 0 ] && age=0
    local age_h=$((age / 3600))

    local sev=0 label="OK"
    if [ "$age" -ge "$CRIT_SEC" ]; then
        sev=2; label="CRITICAL"
    elif [ "$age" -ge "$WARN_SEC" ]; then
        sev=1; label="WARNING"
    fi
    [ "$WORST" -lt "$sev" ] && WORST=$sev

    # Provenance is part of the contract: an operator reading "age=72h" must not
    # have to work out whether that is the age of a snapshot or of the dataset.
    if [ "$from_creation" = true ]; then
        detail="pattern=$PATTERN -- no snapshot found matching this pattern; age measured from dataset creation"
    else
        detail="pattern=$PATTERN newest=${newest#*@}"
    fi

    if [ "$sev" -gt 0 ] || [ "$VERBOSE" = true ]; then
        echo "$label dataset=$ds $detail age=${age_h}h (warn=$(fmt_duration "$WARN_SEC") crit=$(fmt_duration "$CRIT_SEC"))" >&2
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

# CRITICAL outranks UNKNOWN (a real stale snapshot is the more actionable
# finding); UNKNOWN outranks WARNING (a check that could not run is worse news
# than one that ran and found things merely getting old). Every finding was
# already printed to stderr, so nothing is lost by the exit code collapsing to
# a single value.
if [ "$WORST" -eq "$EXIT_CRITICAL" ]; then
    exit "$EXIT_CRITICAL"
elif [ "$SAW_UNKNOWN" -eq 1 ]; then
    exit "$EXIT_UNKNOWN"
else
    exit "$WORST"
fi
