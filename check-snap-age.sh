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
#
# REMOTE DATASETS (REV-20261017-152, round 2). A dataset entry may be
# "[user@]host:dataset", exactly as in delsnaps.sh (same parse, same -p/-k/-c/
# -K/-O meanings), and is then read over ssh on that host. The monitor still
# runs on the host that owns the SCHEDULE: for a snaponly relationship that is
# the collector, whose cron takes the snapshots on the source -- so the source
# is where the snapshots are, and the collector is where they are checked.
# Read-only means `zfs list` and `zfs get` and nothing else; the ssh is
# non-interactive and time-bounded, with stdin detached.
#
# EVERY READ IS CHECKED (REV-20261017-152 F4) -- remote and local alike. The
# snapshot list and the -R walk used to be read through `done < <(zfs ...)`,
# whose exit status is lost: a failed snapshot list after a successful
# existence probe fell back to the DATASET's age, and a failed walk silently
# checked no children. Over ssh both are ordinary events (a dropped link, a
# disabled pair gate). Now each command's status and output shape are checked
# before use; a failure is UNKNOWN, never an empty success.
#
# Usage: check-snap-age.sh [-R|--recursive] [-v] [-L LABEL] [-x PREFIX]... [-p PORT] [-k KNOWN_HOSTS] [-c CIPHER] [-K KEY] [-O OPTION]... <comma-separated datasets> <pattern> <warn> <crit>
#
# -R, --recursive : also check every descendant dataset (filesystem/volume) under
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
# -p/-k/-c/-K/-O: ssh port, pinned known_hosts file (StrictHostKeyChecking=yes;
#                 without -k accept-new), cipher, identity file, extra -o
#                 option -- the same five as delsnaps.sh/snapsend.sh/snapget.sh,
#                 used only for "[user@]host:dataset" entries.
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

VERSION='v2.5'

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
    echo "Usage: $0 [-R] [-v] [-L LABEL] [-x PREFIX]... [-p PORT] [-k KNOWN_HOSTS] [-c CIPHER] [-K KEY] [-O OPTION]... <comma-separated list of [user@host:]datasets> <pattern> <warn> <crit>" >&2
    echo "   warn/crit are durations like 90m, 3h, 9d" >&2
    exit "$EXIT_UNKNOWN"
}

VERBOSE=false
RECURSE=false
PAIR_LABEL=""
declare -a EXCLUDES=()
PORT=22
KNOWN_HOSTS_FILE=""
SSH_CIPHER=""
SSH_KEY=""
declare -a EXTRA_SSH_OPTS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        # --recursive is the long spelling of -R (Stage 2.3). Unlike the
        # transfer engines this script has ONE recursion mode, so there is no
        # =atomic/=flat to distinguish and the bare long form is the alias.
        -R|--recursive) RECURSE=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -L) PAIR_LABEL="${2:-}"; shift 2 ;;
        # -x PREFIX (repeatable): snapshots whose name starts with PREFIX are
        # INVISIBLE to this monitor -- they neither satisfy freshness nor raise
        # it. Built for DECLARED-PASSIVE relations (2026-08-23, LAB-E): the
        # watched family is "whatever the foreign system stamps", so the
        # positive pattern is '-' (any), and exclusions carve out the families
        # that must not count -- an aging excluded family must not page, and a
        # fresh excluded family must not paint a stale relation green.
        -x) EXCLUDES+=("${2:?-x requires a prefix}"); shift 2 ;;
        # ssh options for "[user@]host:dataset" entries -- delsnaps.sh's spellings.
        -p) PORT="${2:-}"; shift 2 ;;
        -p*) PORT="${1#-p}"; shift ;;
        -k) KNOWN_HOSTS_FILE="${2:-}"; shift 2 ;;
        -k*) KNOWN_HOSTS_FILE="${1#-k}"; shift ;;
        -c) SSH_CIPHER="${2:-}"; shift 2 ;;
        -c*) SSH_CIPHER="${1#-c}"; shift ;;
        -K) SSH_KEY="${2:-}"; shift 2 ;;
        -K*) SSH_KEY="${1#-K}"; shift ;;
        -O) EXTRA_SSH_OPTS+=("${2:?-O requires an ssh option}"); shift 2 ;;
        *) break ;;
    esac
done
case "$PORT" in ''|*[!0-9]*) echo "UNKNOWN -- -p '$PORT' is not a port number" >&2; exit "$EXIT_UNKNOWN" ;; esac
case "$PAIR_LABEL" in
    *[!A-Za-z0-9._-]*) echo "UNKNOWN -- -L '$PAIR_LABEL' is not a valid relationship label (letters, digits, dot, dash, underscore only)" >&2; exit "$EXIT_UNKNOWN" ;;
esac

[ "$#" -eq 4 ] || usage
DATASETS_LIST="$1"
PATTERN="$2"
WARN_ARG="$3"
CRIT_ARG="$4"

# Split a datasets-list entry into remote user/host/dataset -- delsnaps.sh's
# parse_remote, the same rule: remote only when there is a ':' AND nothing
# before it looks like a path (a local name may legally carry a ':' after its
# pool/child '/'). Results in R_USER/R_HOST/R_DS; an empty R_HOST = local.
parse_remote() {
    local elem="$1" remote_part
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
        R_USER=""; R_HOST=""; R_DS="$elem"
    fi
}

# Every entry is parsed and validated BEFORE anything is read. A remote name is
# handed to the far shell inside single quotes, so a quote (or any character a
# ZFS name cannot carry) is refused here rather than quoted around; host and
# user are data too, never a place for ssh options or shell syntax.
IFS=',' read -r -a DATASETS <<< "$DATASETS_LIST"
NEED_ZFS=false; NEED_SSH=false
for _e in "${DATASETS[@]}"; do
    parse_remote "$_e"
    if [ -n "$R_HOST" ]; then
        NEED_SSH=true
        [[ "$R_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$R_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
            || { echo "UNKNOWN -- '$_e': the user/host part is not a plain account and host name" >&2; exit "$EXIT_UNKNOWN"; }
        [[ "$R_DS" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/-]*$ ]] \
            || { echo "UNKNOWN -- '$_e': '$R_DS' is not a dataset name this monitor will send to a remote shell" >&2; exit "$EXIT_UNKNOWN"; }
    else
        NEED_ZFS=true
    fi
done
[ "$NEED_ZFS" = false ] || command -v zfs >/dev/null || { echo "UNKNOWN -- 'zfs' command not found in PATH" >&2; exit "$EXIT_UNKNOWN"; }
[ "$NEED_SSH" = false ] || command -v ssh >/dev/null || { echo "UNKNOWN -- a dataset is remote, but 'ssh' is not found in PATH" >&2; exit "$EXIT_UNKNOWN"; }

# ssh for remote entries, built like delsnaps.sh's: -k pins (StrictHostKeyChecking
# =yes), otherwise accept-new; -c cipher; -K/-O at the FRONT so they out-rank
# everything after them (OpenSSH keeps the first value). Non-interactive and
# bounded: a monitor that hangs on a password prompt or a dead link never
# reports, which looks exactly like a monitor that says everything is fine.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$PORT")
fi
[ -n "$SSH_CIPHER" ] && SSH_OPTS+=(-c "$SSH_CIPHER")
SSH_OPTS+=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
if [ -n "$SSH_KEY" ] || [ ${#EXTRA_SSH_OPTS[@]} -gt 0 ]; then
    declare -a _front_ssh_opts=()
    [ -n "$SSH_KEY" ] && _front_ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
    for _o in "${EXTRA_SSH_OPTS[@]}"; do _front_ssh_opts+=(-o "$_o"); done
    SSH_OPTS=("${_front_ssh_opts[@]}" "${SSH_OPTS[@]}")
fi

# An EMPTY pattern is refused (2026-08-20). The match below is
# `[[ "$snapname" == "${PATTERN}"* ]]`, so an empty pattern matches every
# snapshot on the dataset -- including ones this project did not make and does
# not control. On a Proxmox host that is not a theoretical set: pvesr keeps its
# own `__replicate_<job>_<epoch>__` bookkeeping snapshot and refreshes it on the
# replication schedule, and vzdump leaves its own behind.
#
# Measured live on pve2, 2026-08-20, same dataset, same instant:
#
#   pattern=automated_hourly -> newest=automated_hourly_2026-08-20_05-37-01  age=3h
#   pattern=                 -> newest=__replicate_107-0_1787198451__        age=2h
#
# So the empty pattern reported an age an hour YOUNGER by measuring someone
# else's snapshot. Had this project's own family stopped entirely, that monitor
# would have gone on reporting OK for as long as pvesr kept running. A staleness
# check that cannot go red is worse than no check: it occupies the place where a
# working one would be, and it reads as evidence of health.
#
# There is no "watch anything" use case to preserve. Every caller names the
# family it owns; gen-cron.sh cannot even emit this shape, because require_field
# already refuses a blank 'pattern' everywhere a monitor is derived. This closes
# the same hole for the hand-written invocations this script's own header tells
# operators to write for a remote scope.
#
# UNKNOWN, not WARNING/CRITICAL, for the reason stated above: no snapshot has
# been examined yet, so any staleness answer would be fabricated. Generated cron
# lines route rc>=3 to notify-fail as "monitor BROKEN", which is exactly what a
# monitor that cannot report is.
# '-' is the EXPLICIT any-snapshot mode (declared-passive relations watch the
# newest snapshot whatever its name, minus -x exclusions). Only the literal
# dash: an EMPTY pattern is still refused below, unchanged -- silence is not a
# declaration, and the original hole this guard closed stays closed.
if [ "$PATTERN" = "-" ]; then PATTERN=""; PATTERN_ANY=true; else PATTERN_ANY=false; fi
[ -n "$PATTERN" ] || [ "$PATTERN_ANY" = true ] || { echo "UNKNOWN -- the snapshot pattern is empty, which matches EVERY snapshot on the dataset including pvesr's __replicate_* and vzdump's own. A monitor scoped that wide reports the freshness of whatever else touches the pool and can never go red for this project's family, so it is refused rather than run. Pass the prefix of the family you actually own, e.g. 'automated_hourly'." >&2; exit "$EXIT_UNKNOWN"; }

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
# zread <user> <host> <zfs args...> -- one READ, on the host the entry names:
# locally for an empty host, over ssh otherwise. Never falls back from one to
# the other. stdout and the exit status propagate exactly as a local `zfs` call
# would. `--` goes before the final argument (the dataset/snapshot name), as in
# delsnaps.sh's run_zfs: a name starting with '-' is data, not a zfs flag.
# Remote arguments are single-quoted for the far shell, and an embedded quote
# is closed, escaped and reopened (''') -- POSIX, so whatever shell the account
# has reads it as one literal word. Every name that reaches here was validated
# first (the CLI entries above, read-back names by name_from_zfs_ok), so for a
# valid name the command text is exactly what it was; the escape is the second
# wall, not the first (REV-20261017-152 F4.1).
zread() {
    local ru="$1" rh="$2"; shift 2
    local -a a=("$@")
    local last=$(( ${#a[@]} - 1 ))
    local tgt="${a[$last]}"
    unset 'a[last]'
    if [ -n "$rh" ]; then
        local cmd="zfs" x q="'" e="'\\''"
        for x in "${a[@]}"; do cmd+=" '${x//"$q"/"$e"}'"; done
        cmd+=" -- '${tgt//"$q"/"$e"}'"
        # A WALL-CLOCK bound too: ServerAlive only notices a dead link -- sshd
        # keeps answering it while a zfs on the far side hangs (an import, a
        # suspended pool). timeout(1) turns that into exit 124 (UNKNOWN, "timed
        # out") instead of a monitor that never reports. CSA_SSH_TIMEOUT
        # (seconds) is for tests; the default leaves room for a large -R list.
        if command -v timeout >/dev/null 2>&1; then
            timeout -k 10 "${CSA_SSH_TIMEOUT:-120}" ssh -n "${SSH_OPTS[@]}" "$ru@$rh" "$cmd"
        else
            ssh -n "${SSH_OPTS[@]}" "$ru@$rh" "$cmd"
        fi
    else
        zfs "${a[@]}" -- "$tgt"
    fi
}

# Why a read failed, in words: over ssh the status says whether we were even
# let in. 255 = ssh itself (connection, authentication, host key); 93 = the
# relationship's pair gate refuses (disabled). Anything else = zfs answered
# with an error.
read_failure() {   # <host> <rc>
    if [ -n "$1" ] && [ "$2" = 255 ]; then
        printf 'could not reach %s over ssh (exit 255: connection, authentication or host key)' "$1"
    elif [ -n "$1" ] && [ "$2" = 93 ]; then
        printf "%s's pair gate refuses this relationship (disabled)" "$1"
    elif [ -n "$1" ] && { [ "$2" = 124 ] || [ "$2" = 137 ]; }; then
        printf 'the read on %s timed out (exit %s)' "$1" "$2"
    elif [ "$2" = 127 ]; then
        printf "'zfs' was not found%s (exit 127)" "${1:+ on $1}"
    else
        printf 'zfs failed (exit %s)' "$2"
    fi
}

# A NAME READ BACK FROM zfs is data from the far side, not a name this script
# chose: a snapshot `<ds>@<snap>` or a descendant `<ds>/...`, checked BEFORE it
# is used in any follow-up read (F4.1). The prefix check alone let
# `tank/vm@automated_'; printf x > f; #` through to the creation read, where the
# far shell ran it. Allowed: what a ZFS name component carries -- letters,
# digits, _ - : . and space (OpenZFS accepts space; it is quoted). A quote, a
# shell metacharacter, a newline: UNKNOWN, never used.
name_from_zfs_ok() {   # <kind: snapshot|child> <name> <root dataset>
    local kind="$1" n="$2" root="$3" rest
    case "$kind" in
        snapshot) [[ "$n" == "$root@"* ]] || return 1; rest="${n#"$root@"}"
                  [[ "$rest" =~ ^[A-Za-z0-9_.:\ -]+$ ]] ;;
        child)    [[ "$n" == "$root/"* ]] || return 1; rest="${n#"$root/"}"
                  [[ "$rest" =~ ^[A-Za-z0-9_.:\ -][A-Za-z0-9_.:/\ -]*$ ]] && [[ "$rest" != */ ]] && [[ "$rest" != *//* ]] ;;
        *) return 1 ;;
    esac
}

creation_epoch() {   # <user> <host> <dataset or snapshot>
    local v
    v="$(zread "$1" "$2" get -H -p -o value creation "$3" 2>/dev/null)" || return 1
    case "$v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$v"
}

check_one() {
    local ru="$1" rh="$2" ds="$3" explicit="$4"
    local shown="${rh:+$ru@$rh:}$ds"
    local newest="" newest_epoch="" line snapname any_snap=false out rc

    # A dataset that does not exist is UNKNOWN, not CRITICAL: "you asked about
    # something that isn't here" is a config/typo problem, and reporting it as
    # a stale snapshot would send a mail describing a backup failure that never
    # happened. Over ssh a failure to ASK is UNKNOWN too, and says which.
    out="$(zread "$ru" "$rh" list -H -o name -t filesystem,volume "$ds" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        # zfs answers "does not exist" with exit 1; every other status means
        # the question was never answered, and says why (255/93/124/127/...).
        if [ "$rc" = 1 ]; then
            echo "UNKNOWN dataset=$shown -- does not exist (typo, or removed since the config was written)" >&2
        else
            echo "UNKNOWN dataset=$shown -- $(read_failure "$rh" "$rc"); nothing was checked" >&2
        fi
        SAW_UNKNOWN=1
        return
    fi
    if [ "$out" != "$ds" ]; then
        echo "UNKNOWN dataset=$shown -- the existence check answered something other than the dataset name; not trusted" >&2
        SAW_UNKNOWN=1
        return
    fi

    # The snapshot list is read WHOLE and its status checked before a line is
    # used (F4): a failure here -- also one after partial output -- must not
    # fall through to "no matching snapshot", which measures the dataset's age.
    out="$(zread "$ru" "$rh" list -H -o name -s creation -t snapshot "$ds" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "UNKNOWN dataset=$shown -- its snapshot list could not be read: $(read_failure "$rh" "$rc")" >&2
        SAW_UNKNOWN=1
        return
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if ! name_from_zfs_ok snapshot "$line" "$ds"; then
            echo "UNKNOWN dataset=$shown -- the snapshot list holds '$line', which is not a well-formed snapshot of this dataset; not trusted, nothing read with it" >&2
            SAW_UNKNOWN=1
            return
        fi
        any_snap=true
        snapname="${line#*@}"
        local _ex _skip=false
        for _ex in "${EXCLUDES[@]:-}"; do
            [ -n "$_ex" ] && [[ "$snapname" == "${_ex}"* ]] && { _skip=true; break; }
        done
        [ "$_skip" = true ] && continue
        [[ "$snapname" == "${PATTERN}"* ]] && newest="$line"
    done <<< "$out"

    local from_creation=false detail
    if [ -z "$newest" ]; then
        if [ "$any_snap" = false ] && [ "$explicit" != true ]; then
            [ "$VERBOSE" = true ] && echo "SKIP dataset=$shown -- no snapshots at all (not an explicit target, likely a container node)" >&2
            return
        fi
        # REV-20260807-056: a dataset cannot be late before it exists. This used
        # to be an unconditional CRITICAL, which reported a guest created after
        # the last scheduled run -- and snapshotted by pvesr or vzdump before
        # the next one -- as a stale backup of something that never had the
        # chance to have one. Measuring from the dataset's own creation puts the
        # alarm where the promise is actually broken, and gives this case the
        # WARNING band it never had.
        if ! newest_epoch="$(creation_epoch "$ru" "$rh" "$ds")"; then
            echo "UNKNOWN dataset=$shown -- no snapshot matches pattern=${PATTERN:-(any)} and the dataset's creation time could not be read, so its age is unknown" >&2
            SAW_UNKNOWN=1
            return
        fi
        from_creation=true
    else
        if ! newest_epoch="$(creation_epoch "$ru" "$rh" "$newest")"; then
            echo "UNKNOWN dataset=$shown -- the creation time of ${newest#*@} could not be read, so its age is unknown" >&2
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
        detail="pattern=${PATTERN:-(any)} -- no snapshot found matching this pattern; age measured from dataset creation"
    else
        detail="pattern=${PATTERN:-(any)} newest=${newest#*@}"
    fi

    if [ "$sev" -gt 0 ] || [ "$VERBOSE" = true ]; then
                # Age in floored hours hid the minutes: with 12m/20m lab thresholds a
        # 21-minute breach printed "age=0h" next to CRITICAL, which reads as a
        # contradiction. Under two hours the minutes ARE the signal.
        local age_disp="${age_h}h"
        [ "$age" -lt 7200 ] && age_disp="$(( age / 60 ))m"
echo "$label dataset=$shown $detail age=${age_disp} (warn=$(fmt_duration "$WARN_SEC") crit=$(fmt_duration "$CRIT_SEC"))" >&2
    fi
}

# In -R mode the named dataset is a subtree ROOT, not necessarily a leaf that
# should hold matching snapshots itself (that's the whole point of -R: check
# whatever real leaves live under it) -- so it gets the same "empty container"
# leniency as its discovered descendants, not the explicit/mandatory check.
#
# The -R walk is read WHOLE and its status checked (F4): a failed walk used to
# check no children at all and say nothing. Each line must be the root or a
# child of it; anything else is not trusted.
for entry in "${DATASETS[@]}"; do
    parse_remote "$entry"
    ru="$R_USER"; rh="$R_HOST"; ds="$R_DS"
    if [ "$RECURSE" = true ]; then
        check_one "$ru" "$rh" "$ds" false
        out="$(zread "$ru" "$rh" list -H -o name -t filesystem,volume -r "$ds" 2>/dev/null)"; rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "UNKNOWN dataset=${rh:+$ru@$rh:}$ds -- its descendants could not be listed ($(read_failure "$rh" "$rc")); none of them was checked" >&2
            SAW_UNKNOWN=1
            continue
        fi
        # A COMPLETE walk names its root: `zfs list -r <root>` always prints it,
        # and the root was just found to exist. An rc-0 answer without it (empty,
        # or children only) is not a walk this script can trust -- it used to
        # check no child and say nothing (F4.2). UNKNOWN, and nothing under it.
        if ! printf '%s\n' "$out" | grep -qxF -- "$ds"; then
            echo "UNKNOWN dataset=${rh:+$ru@$rh:}$ds -- the descendant list does not contain the root itself, so it is not a complete walk; none of the descendants was checked" >&2
            SAW_UNKNOWN=1
            continue
        fi
        while IFS= read -r child; do
            [ -z "$child" ] || [ "$child" = "$ds" ] && continue
            if ! name_from_zfs_ok child "$child" "$ds"; then
                echo "UNKNOWN dataset=${rh:+$ru@$rh:}$ds -- the descendant list holds '$child', which is not a well-formed dataset under it; not trusted, not checked" >&2
                SAW_UNKNOWN=1
                continue
            fi
            check_one "$ru" "$rh" "$child" false
        done <<< "$out"
    else
        check_one "$ru" "$rh" "$ds" true
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
