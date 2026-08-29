#!/bin/bash
set -o pipefail
# cron2conf.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Description: the INVERSE of gen-cron.sh -- reads an ALREADY INSTALLED
# "# BEGIN zfs-backup-managed ... # END zfs-backup-managed" crontab block and
# reconstructs a config file that gen-cron.sh can regenerate it from.
#
# Why this exists: gen-cron.sh's config is the only record of WHY a cron line
# looks the way it does (which template, which retention tier) -- the crontab
# itself only has the RESOLVED result. If that config file is lost (moved,
# never committed, disk wiped) the jobs keep running but can never be
# regenerated or safely edited again. This tool reads the resolved result back
# out of the crontab and rebuilds a config that renders BYTE-IDENTICAL lines --
# verified by feeding its own output back through gen-cron.sh and diffing
# against the crontab it came from. It cannot recover the ORIGINAL config's
# structure (which datasets shared a template, what a tier was named) -- only
# an equivalent one, built from synthetic one-off templates. Re-run gen-cron.sh
# -c <recovered file> and diff against the live crontab before trusting it.
#
# Usage: cron2conf.sh [-f FILE | -u USER] [-o OUTFILE] [-V]
# Options:
#   -f <FILE>   Read a saved crontab dump from FILE (e.g. `crontab -l > FILE`
#               taken as a backup earlier). Default: read stdin.
#   -u <USER>   Read the live crontab of USER via `crontab -u USER -l`
#               (root only, unless USER is the current account).
#   -o <FILE>   Write the reconstructed config to FILE. Default: stdout.
#   -V          Print version and exit
#
# Exit status: 0 = reconstructed cleanly. 1 = fatal (no input, no managed
# block, or a line this tool does not recognize -- it refuses to guess).
# 2 = reconstructed, but one or more entities could not be represented (see
# stderr) and were left out of the written config; review before using it.
#
# LIMITATIONS (read before trusting the output):
#   - Line ORDER in the rendered block can differ from the original (cron does
#     not care what order independent job lines appear in a crontab -- but a
#     byte-for-byte diff will show reordering as noise). Compared as a SET,
#     the output is what this tool guarantees; always verify with:
#         gen-cron.sh -c <recovered.conf> | sort > /tmp/a
#         sed -n '/BEGIN zfs-backup-managed/,/END zfs-backup-managed/p' \
#             <the crontab it came from> | grep -v '^#' | sort > /tmp/b
#         diff /tmp/a /tmp/b
#   - The ORIGINAL section/template structure (which dataset used which named
#     tier) is not recoverable from resolved cron lines -- only an EQUIVALENT
#     structure using one-off synthetic templates (t1, t2, ...). The
#     regenerated crontab is identical; the config file reads nothing like a
#     hand-written one. Treat the output as a recovery baseline to tidy by
#     hand, not a restoration of the lost file.
#   - A scope that would need two [prune:] sections with different
#     recursive/clear_cut settings (gen-cron.sh has no way to express that --
#     the setting is per-section, not per-tier) is UNREPRESENTABLE. Reported
#     on stderr and left out of the config (exit 2), never silently merged.
#   - digest_schedule (if the digest line's own cron schedule was changed from
#     the "0 7 * * *" default) has no config-file field at all -- gen-cron.sh
#     only reads it from the DIGEST_SCHEDULE environment variable. Reported on
#     stderr as a reminder to set it when installing.
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v1.1'
SEP=$'\x1c'   # field separator inside one encoded entity string, matches gen-cron.sh

die() { echo "cron2conf.sh: error: $*" >&2; exit 1; }
warn() { echo "cron2conf.sh: warning: $*" >&2; WARNED=1; }
WARNED=0

usage() {
    cat <<'EOF'
cron2conf.sh -- reconstruct a gen-cron.sh config from an already-installed
managed crontab block (the inverse of gen-cron.sh).

Usage: cron2conf.sh [-f FILE | -u USER] [-o OUTFILE] [-V]
  -f <FILE>   Read a saved crontab dump from FILE. Default: stdin.
  -u <USER>   Read USER's live crontab via `crontab -u USER -l`.
  -o <FILE>   Write the reconstructed config to FILE. Default: stdout.
  -V          Print version and exit

Exit status: 0 clean, 1 fatal (unparseable input), 2 reconstructed with
entities left out -- see stderr. ALWAYS verify the result:
  gen-cron.sh -c <recovered.conf> | sort > /tmp/a
  sed -n '/BEGIN zfs-backup-managed/,/END zfs-backup-managed/p' <source> \
      | grep -v '^#' | sort > /tmp/b
  diff /tmp/a /tmp/b
See this script's own header comment for the full limitations list.
EOF
}

# Byte-identical to gen-cron.sh's trim(), and duplicated rather than shared for
# the same reason SEP is (see its comment above): this script is deployed
# standalone and sources nothing, so it cannot reach a library. Same structural
# argument delsnaps.sh gives for its copy of HOLD_TAG, and zfs-pair-gate.sh for
# its copy of the label check.
#
# Written down on 2026-08-20 only because it had NOT been: a duplication sweep
# flagged this as unexplained, which was fair. Every other deliberate copy in
# this repo carries its justification at the site, so an unexplained one reads
# as an oversight somebody should go and "fix".
#
# If it ever changes, gen-cron.sh's copy changes with it. cron2conf.sh parses
# what gen-cron.sh emits, so two different ideas of "trimmed" is a round-trip
# that silently stops round-tripping.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

INPUT_FILE=""
INPUT_USER=""
OUTFILE=""
while getopts "f:u:o:Vh" opt; do
    case $opt in
        f) INPUT_FILE="$OPTARG" ;;
        u) INPUT_USER="$OPTARG" ;;
        o) OUTFILE="$OPTARG" ;;
        V) echo "$VERSION"; exit 0 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
[ -n "$INPUT_FILE" ] && [ -n "$INPUT_USER" ] && die "-f and -u are mutually exclusive"
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [READ INPUT / EXTRACT THE MANAGED BLOCK]
###############################################################################
MARKER_BEGIN_PREFIX="# BEGIN zfs-backup-managed"
MARKER_END="# END zfs-backup-managed"

read_input() {
    if [ -n "$INPUT_USER" ]; then
        crontab -u "$INPUT_USER" -l 2>/dev/null || die "could not read crontab for user '$INPUT_USER' (crontab -u needs root, or run as that user with no -u)"
    elif [ -n "$INPUT_FILE" ]; then
        [ -f "$INPUT_FILE" ] || die "no such file: $INPUT_FILE"
        cat "$INPUT_FILE"
    else
        cat
    fi
}

declare -a BLOCK_LINES=()
extract_block() {
    local text in_block=0 line
    text="$(read_input)" || die "failed to read input"
    [ -n "$text" ] || die "empty input"
    while IFS= read -r line; do
        line="${line%$'\r'}"   # tolerate a CRLF dump without misreading it as content
        if [[ "$line" == "$MARKER_BEGIN_PREFIX"* ]]; then in_block=1; continue; fi
        if [ "$(trim "$line")" = "$MARKER_END" ]; then in_block=0; continue; fi
        [ "$in_block" -eq 1 ] || continue
        [[ "$line" == "# Source:"* ]] && continue
        [ -z "$(trim "$line")" ] && continue
        BLOCK_LINES+=("$line")
    done <<< "$text"
    [ "${#BLOCK_LINES[@]}" -gt 0 ] || die "no '$MARKER_BEGIN_PREFIX' ... '$MARKER_END' block found in the input"
}
###############################################################################
#END 2

###############################################################################
#BEGIN 3 [PER-LINE PARSING]
###############################################################################
# Splits CMD on the literal '"' character into array OUTVAR. Every quoted
# argument gen-cron.sh ever emits (prefix/src/dst/scope/pattern) is a ZFS
# dataset name, a snapshot-name prefix, or free-text notify label -- none of
# which legitimately contain a literal double quote -- so this is a safe,
# exact inverse of the printf '"%s"' quoting emit_* uses to build them.
qsplit() { local -n __out="$1"; IFS='"' read -ra __out <<< "$2"; }

# Since 2026-08-17 job_cron_line() wraps every send/prune line in ZFS-JOB
# BEGIN/END markers, so that a run dying before the engine starts still leaves a
# trace (see gen-cron.sh for the live finding that prompted it).
#
# Installed crontabs across the estate carry BOTH shapes at once -- the markers
# only appear on a host after its next --install -- and this tool exists
# precisely to recover a config from a crontab whose config file is gone, so
# refusing the shape it has not seen before would break it exactly when it is
# needed. Normalise to the classic envelope and parse that.
#
# Nothing is recovered FROM the markers: the label they carry is already
# recovered from the notify arguments, and the cron log path from the redirect.
# They are witness, not configuration, so dropping them loses nothing that
# regenerating the config would need.
strip_witness_markers() {
    local line="$1"
    local B=' echo "$(date -Is) ZFS-JOB BEGIN '
    [[ "$line" == *"$B"* ]] || { printf '%s' "$line"; return 0; }

    local sched="${line%%"$B"*}" rest="${line#*"$B"}"
    rest="${rest#*\" >>}"                 # drop LABEL", leaving CRONLOG; e=...
    rest="${rest#*; }"                    # drop the cron log path

    local M='e=$(mktemp 2>/dev/null) || e='
    [[ "$rest" == "$M"* ]] || { printf '%s' "$line"; return 0; }
    rest="${rest#"$M"}"                   # drop the fallback path, leaving ...; CMD
    rest="${rest#*; }"                    # now at CMD

    local E='; echo "$(date -Is) ZFS-JOB END '
    if [[ "$rest" == *"$E"* ]]; then
        local head="${rest%%"$E"*}" tail="${rest#*"$E"}"
        tail="${tail#*\" >>}"             # drop LABEL rc=$rc", leaving CRONLOG; [ $rc...
        tail="${tail#*; }"                # drop the cron log path
        rest="$head; $tail"
    fi
    printf '%s e=$(mktemp); %s' "$sched" "$rest"
}

# parse_job_envelope LINE -- the common wrapper job_cron_line() puts around
# every send/prune line. Sets SCHED/CMD/CRONLOG/NOTIFYSCRIPT/NOTIFY/DETAIL on
# success, returns 1 (leaves nothing set) if LINE does not match the shape.
parse_job_envelope() {
    local line
    line="$(strip_witness_markers "$1")"
    local D1=' e=$(mktemp); ' D2=' 2>"$e"; rc=$?; cat "$e" >>' D3='; [ $rc -ne 0 ] && ' D4=' "' D5='" "$(tail -n '
    [[ "$line" == *"$D1"* ]] || return 1
    SCHED="${line%%"$D1"*}"; local rest="${line#*"$D1"}"
    [[ "$rest" == *"$D2"* ]] || return 1
    CMD="${rest%%"$D2"*}"; rest="${rest#*"$D2"}"
    [[ "$rest" == *"$D3"* ]] || return 1
    CRONLOG="${rest%%"$D3"*}"; rest="${rest#*"$D3"}"
    [[ "$rest" == *"$D4"* ]] || return 1
    NOTIFYSCRIPT="${rest%%"$D4"*}"; rest="${rest#*"$D4"}"
    [[ "$rest" == *"$D5"* ]] || return 1
    NOTIFY="${rest%%"$D5"*}"; rest="${rest#*"$D5"}"
    DETAIL="$(trim "${rest%%\"*}")"
    return 0
}

# parse_monitor_envelope LINE -- emit_monitor()'s shape. Sets SCHED/CMD/
# CRONLOG/WARNSCRIPT/WARNTEXT/NOTIFYSCRIPT/NOTIFY/BROKEN on success.
parse_monitor_envelope() {
    local line="$1"
    local D1=' d=$(' D2=' 2>&1); rc=$?; [ -n "$d" ] && echo "$d" >>' D3='; [ $rc -eq 1 ] && '
    local D4=' "' D5='" "$d" 2>>' D6='; [ $rc -eq 2 ] && ' D9='; [ $rc -ge 3 ] && '
    [[ "$line" == *"$D1"* ]] || return 1
    SCHED="${line%%"$D1"*}"; local rest="${line#*"$D1"}"
    [[ "$rest" == *"$D2"* ]] || return 1
    CMD="${rest%%"$D2"*}"; rest="${rest#*"$D2"}"
    [[ "$rest" == *"$D3"* ]] || return 1
    CRONLOG="${rest%%"$D3"*}"; rest="${rest#*"$D3"}"
    [[ "$rest" == *"$D4"* ]] || return 1
    WARNSCRIPT="${rest%%"$D4"*}"; rest="${rest#*"$D4"}"
    [[ "$rest" == *"$D5"* ]] || return 1
    WARNTEXT="${rest%%"$D5"*}"; rest="${rest#*"$D5"}"
    [[ "$rest" == *"$D6"* ]] || return 1
    rest="${rest#*"$D6"}"
    [[ "$rest" == *"$D4"* ]] || return 1
    NOTIFYSCRIPT="${rest%%"$D4"*}"; rest="${rest#*"$D4"}"
    [[ "$rest" == *"$D5"* ]] || return 1
    NOTIFY="${rest%%"$D5"*}"; rest="${rest#*"$D5"}"
    [[ "$rest" == *"$D9"* ]] || return 1
    rest="${rest#*"$D9"}"
    [[ "$rest" == *"$D4"* ]] || return 1
    rest="${rest#*"$D4"}"
    [[ "$rest" == *"$D5"* ]] || return 1
    BROKEN="${rest%%"$D5"*}"
    return 0
}

# parse_digest_line LINE -- "$DIGEST_SCHEDULE $DIGEST_SCRIPT 2>>$CRON_LOG".
parse_digest_line() {
    local line="$1"
    [[ "$line" == *" 2>>"* ]] || return 1
    local head="${line%% 2>>*}"
    DG_CRONLOG="${line##* 2>>}"
    # head = "M H DOM MON DOW SCRIPT" -- 5 schedule fields, then the script path.
    # read -ra, NOT f=($head): the schedule fields are '*' cron wildcards, and an
    # unquoted array assignment glob-expands them against the CURRENT DIRECTORY.
    local -a f; read -ra f <<< "$head"
    [ "${#f[@]}" -eq 6 ] || return 1
    DG_SCHED="${f[0]} ${f[1]} ${f[2]} ${f[3]} ${f[4]}"
    DG_SCRIPT="${f[5]}"
    return 0
}

parse_send_cmd() {
    local cmd="$1"
    [[ "$cmd" == */snapsend.sh\ -m\ \"* ]] || return 1
    C_REPO="${cmd%%/snapsend.sh -m \"*}"
    local -a p; qsplit p "$cmd"
    local n=${#p[@]}
    { [ "$n" -eq 4 ] || [ "$n" -eq 6 ]; } || return 1
    C_PREFIX="${p[1]}"
    C_FLAGS="$(trim "${p[2]}")"
    C_SRC="${p[3]}"
    C_DST=""
    [ "$n" -eq 6 ] && C_DST="${p[5]}"
    return 0
}

parse_delsnaps_cmd() {
    local cmd="$1"
    [[ "$cmd" == */delsnaps.sh\ * ]] || return 1
    C_REPO="${cmd%%/delsnaps.sh *}"
    local rest="${cmd#*/delsnaps.sh }"
    C_MODE="prune"
    if [[ "$rest" == "-G "* ]]; then C_MODE="gfs"; rest="${rest#-G }"
    elif [[ "$rest" == "-B "* ]]; then C_MODE="bookmark"; rest="${rest#-B }"
    fi
    # -L and the ssh flags were missing entirely, and the consequence was not a
    # lost field: `rest` then still began with '-L', the quoted-scope check below
    # failed, parse_delsnaps_cmd returned 1, and the caller rejected the WHOLE
    # crontab with "unrecognized job line". One paused relationship anywhere on a
    # host made this tool useless for that host -- exactly as the pause rolls out
    # across the estate.
    C_RECURSIVE=0; C_CLEARCUT=0; C_PROTECT=""; C_PAIR_LABEL=""; C_SSHFLAGS=""
    while :; do
        if [[ "$rest" == "-R "* ]]; then C_RECURSIVE=1; rest="${rest#-R }"; continue; fi
        if [[ "$rest" == "-L "* ]]; then
            rest="${rest#-L }"; C_PAIR_LABEL="${rest%% *}"; rest="${rest#* }"; continue
        fi
        # The five options gen-cron's ssh_flags accept-list allows, each taking
        # a value. Order-independent on purpose: this reads what is there rather
        # than re-asserting the emitter's current sequence.
        if [[ "$rest" =~ ^(-p|-k|-c|-K|-O)\  ]]; then
            local _o="${rest%% *}"; rest="${rest#* }"
            local _v="${rest%% *}"; rest="${rest#* }"
            C_SSHFLAGS="${C_SSHFLAGS}${C_SSHFLAGS:+ }$_o $_v"; continue
        fi
        if [ "$C_MODE" != "bookmark" ] && [[ "$rest" == "-F "* ]]; then C_CLEARCUT=1; rest="${rest#-F }"; continue; fi
        if [[ "$rest" == '-P "'* ]]; then
            rest="${rest#-P \"}"
            local tok="${rest%%\"*}"
            C_PROTECT="${C_PROTECT}${tok},"
            rest="${rest#*\" }"
            continue
        fi
        break
    done
    [[ "$rest" == \"* ]] || return 1
    local -a p; qsplit p "$rest"
    [ "${#p[@]}" -ge 5 ] || return 1
    C_SCOPE="${p[1]}"
    C_PATTERN="${p[3]}"
    C_RETAIN="$(trim "${p[4]}")"
    return 0
}

parse_checkage_cmd() {
    local cmd="$1"
    [[ "$cmd" == */check-snap-age.sh\ * ]] || return 1
    C_REPO="${cmd%%/check-snap-age.sh *}"
    local rest="${cmd#*/check-snap-age.sh }"
    C_RECURSIVE=0
    if [[ "$rest" == "-R "* ]]; then C_RECURSIVE=1; rest="${rest#-R }"; fi
    # -L follows -R in gen-cron's emission order (REV-045): the relationship
    # label, reconstructed as the section's pair_label field below.
    C_PAIR_LABEL=""
    if [[ "$rest" == "-L "* ]]; then rest="${rest#-L }"; C_PAIR_LABEL="${rest%% *}"; rest="${rest#* }"; fi
    [[ "$rest" == \"* ]] || return 1
    local -a p; qsplit p "$rest"
    [ "${#p[@]}" -ge 5 ] || return 1
    C_SCOPE="${p[1]}"
    C_PATTERN="${p[3]}"
    local tail; tail="$(trim "${p[4]}")"
    C_WARN="${tail%% *}"
    C_CRIT="${tail#* }"
    return 0
}

# parse_notify_text TEXT -- "$host $tier $word ($label)" or without the
# trailing "(label)". Sets N_HOST/N_TIER/N_LABEL ('' if no label). $word is
# discarded: this tool never needs it back (notify_raw/notify_raw_prune paste
# the whole original string back verbatim for send/prune; monitor text is
# reconstructed from host+tier+label alone, since check-snap-age's three
# messages are fixed wording gen-cron.sh always uses).
parse_notify_text() {
    local text="$1"
    if [[ "$text" =~ ^([^\ ]+)\ ([^\ ]+)\ .+\ \((.*)\)$ ]]; then
        N_HOST="${BASH_REMATCH[1]}"; N_TIER="${BASH_REMATCH[2]}"; N_LABEL="${BASH_REMATCH[3]}"
        return 0
    fi
    if [[ "$text" =~ ^([^\ ]+)\ ([^\ ]+)\ .+$ ]]; then
        N_HOST="${BASH_REMATCH[1]}"; N_TIER="${BASH_REMATCH[2]}"; N_LABEL=""
        return 0
    fi
    return 1
}
###############################################################################
#END 3

# THE REMOVABLE-MEDIA BRACKET, taken back off.
#
# gen-cron wraps a replica job in
#
#   ( GATE attach POOL LABEL --dataset D; a=$?; if [ $a -eq 0 ]; then ENGINE;
#     m=$?; elif [ $a -eq 1 ]; then m=0; else m=$a; fi; GATE detach POOL LABEL;
#     d=$?; [ $m -ne 0 ] && exit $m; exit $d )
#
# so the command no longer begins with a path to snapsend.sh, and every parser
# below refused it -- which made the caller reject the WHOLE crontab as
# unrecognized. One replica job on a host and this tool was useless for that
# host, the same failure the -L work hit earlier the same day.
#
# Sets C_MEDIA_POOL / C_MEDIA_LABEL / C_MEDIA_DATASET / C_MEDIA_INNER, so the
# parsers that follow see the call they already know how to read.
#
# It SETS rather than echoes, and the caller must not wrap it in $( ). The first
# cut did, and every C_MEDIA_* assignment landed in the subshell and was gone by
# the time the caller read it -- the sections came out as [replica:] with no
# name, all three collapsed into one. The same trap test/linkfields/run.sh
# records in its own header.
C_MEDIA_POOL=""; C_MEDIA_LABEL=""; C_MEDIA_DATASET=""; C_MEDIA_INNER=""
unwrap_media_bracket() {   # <command> -> sets C_MEDIA_*; 0 if it was bracketed
    local cmd="$1"
    C_MEDIA_POOL=""; C_MEDIA_LABEL=""; C_MEDIA_DATASET=""; C_MEDIA_INNER=""
    case "$cmd" in
        "( "*"/zfs-media-gate.sh attach "*) ;;
        *) return 1 ;;
    esac
    local head="${cmd#*/zfs-media-gate.sh attach }"
    C_MEDIA_POOL="${head%% *}";  head="${head#* }"
    C_MEDIA_LABEL="${head%% *}"; head="${head#* }"
    case "$head" in
        "--dataset "*) head="${head#--dataset }"; C_MEDIA_DATASET="${head%%;*}" ;;
    esac
    # The engine sits between the `then` and the `; m=$?` that captures its
    # status -- taken by those two anchors rather than by counting fields,
    # because the engine's own arguments are quoted and contain spaces.
    local inner="${cmd#*; then }"
    inner="${inner%%; m=\$?; elif*}"
    [ -n "$inner" ] || return 1
    C_MEDIA_INNER="$inner"
    return 0
}

###############################################################################
#BEGIN 4 [CLASSIFY EVERY LINE INTO ENTITIES]
###############################################################################
declare -a SEND_E=()      # sched<SEP>flags<SEP>src<SEP>dst<SEP>prefix<SEP>notify
declare -a PRUNE_E=()     # sched<SEP>scope<SEP>pattern<SEP>retain<SEP>recursive<SEP>clearcut<SEP>protect<SEP>notify
declare -a GFS_E=()       # sched<SEP>scope<SEP>pattern<SEP>retain_parts<SEP>recursive<SEP>clearcut<SEP>protect<SEP>notify
declare -a BOOK_E=()      # sched<SEP>scope<SEP>pattern<SEP>age<SEP>recursive<SEP>notify
declare -a MON_E=()       # sched<SEP>scope<SEP>pattern<SEP>warn<SEP>crit<SEP>recursive<SEP>notify
declare -a REPL_E=()      # sched<SEP>label<SEP>source<SEP>dst<SEP>prefix<SEP>media<SEP>recursive<SEP>notify
DG_FOUND=0

REPO_DIR="" CRON_LOG="" NOTIFY_SCRIPT="" WARN_SCRIPT="" DIGEST_SCRIPT="" HOST_LABEL=""

classify_lines() {
    local line
    for line in "${BLOCK_LINES[@]}"; do
        if parse_job_envelope "$line"; then
            # A bracketed job is a replica onto removable media. Unwrapped
            # first, so the engine parsers below see the call they expect.
            if unwrap_media_bracket "$CMD"; then
                CMD="$C_MEDIA_INNER"
                parse_send_cmd "$CMD" || die "a removable-media job whose inner command is not snapsend.sh: $line"
                parse_notify_text "$NOTIFY" || die "cannot parse replica notify text: '$NOTIFY'"
                # A crontab may hold replicas and nothing else -- a host that
                # only carries copies of what it already has. Taken here rather
                # than in the send/prune/monitor sweep below, which never sees
                # these lines.
                [ -n "$HOST_LABEL" ] || HOST_LABEL="$N_HOST"
                REPO_DIR="${REPO_DIR:-$C_REPO}"; CRON_LOG="${CRON_LOG:-$CRONLOG}"; NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$NOTIFYSCRIPT}"
                local _rec=0
                case " $C_FLAGS " in *" -R "*) _rec=1 ;; esac
                REPL_E+=("${SCHED}${SEP}${C_MEDIA_LABEL}${SEP}${C_SRC}${SEP}${C_DST}${SEP}${C_PREFIX}${SEP}removable${SEP}${_rec}${SEP}${N_LABEL}")
                continue
            fi
            if parse_send_cmd "$CMD"; then
                REPO_DIR="${REPO_DIR:-$C_REPO}"; CRON_LOG="${CRON_LOG:-$CRONLOG}"; NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$NOTIFYSCRIPT}"
                SEND_E+=("${SCHED}${SEP}${C_FLAGS}${SEP}${C_SRC}${SEP}${C_DST}${SEP}${C_PREFIX}${SEP}${NOTIFY}")
                continue
            fi
            if parse_delsnaps_cmd "$CMD"; then
                REPO_DIR="${REPO_DIR:-$C_REPO}"; CRON_LOG="${CRON_LOG:-$CRONLOG}"; NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$NOTIFYSCRIPT}"
                case "$C_MODE" in
                    prune) PRUNE_E+=("${SCHED}${SEP}${C_SCOPE}${SEP}${C_PATTERN}${SEP}${C_RETAIN}${SEP}${C_RECURSIVE}${SEP}${C_CLEARCUT}${SEP}${C_PROTECT}${SEP}${NOTIFY}${SEP}${C_PAIR_LABEL}${SEP}${C_SSHFLAGS}") ;;
                    gfs)   GFS_E+=("${SCHED}${SEP}${C_SCOPE}${SEP}${C_PATTERN}${SEP}${C_RETAIN}${SEP}${C_RECURSIVE}${SEP}${C_CLEARCUT}${SEP}${C_PROTECT}${SEP}${NOTIFY}${SEP}${C_PAIR_LABEL}${SEP}${C_SSHFLAGS}") ;;
                    bookmark)
                        parse_notify_text "$NOTIFY" || die "cannot parse bookmark notify text: '$NOTIFY'"
                        BOOK_E+=("${SCHED}${SEP}${C_SCOPE}${SEP}${C_PATTERN}${SEP}${C_RETAIN}${SEP}${C_RECURSIVE}${SEP}${N_LABEL}${SEP}${C_PAIR_LABEL}${SEP}${C_SSHFLAGS}") ;;
                esac
                continue
            fi
            die "unrecognized job line (not snapsend.sh or delsnaps.sh): $line"
        fi
        if parse_monitor_envelope "$line"; then
            parse_checkage_cmd "$CMD" || die "monitor line does not call check-snap-age.sh: $line"
            WARN_SCRIPT="${WARN_SCRIPT:-$WARNSCRIPT}"; CRON_LOG="${CRON_LOG:-$CRONLOG}"
            MON_E+=("${SCHED}${SEP}${C_SCOPE}${SEP}${C_PATTERN}${SEP}${C_WARN}${SEP}${C_CRIT}${SEP}${C_RECURSIVE}${SEP}${NOTIFY}${SEP}${C_PAIR_LABEL}")
            continue
        fi
        if parse_digest_line "$line"; then
            DG_FOUND=1; DG_SCHED_V="$DG_SCHED"; DG_SCRIPT_V="$DG_SCRIPT"
            CRON_LOG="${CRON_LOG:-$DG_CRONLOG}"
            continue
        fi
        die "unrecognized line in managed block (not a send/prune/monitor/digest line this tool knows how to read): $line"
    done

    for e in "${SEND_E[@]}" "${PRUNE_E[@]}" "${MON_E[@]}"; do
        IFS="$SEP" read -r first rest <<< "$e"
        :
    done
    if [ -z "$HOST_LABEL" ]; then
        local e notify
        for e in "${SEND_E[@]}"; do
            notify="${e##*"$SEP"}"
            parse_notify_text "$notify" && { HOST_LABEL="$N_HOST"; break; }
        done
    fi
    if [ -z "$HOST_LABEL" ]; then
        # Named fields, not "the last one": notify stopped being last when
        # pair_label and ssh_flags were appended, and ${e##*SEP} would have
        # silently started reading ssh_flags as a notify string.
        local e notify _d
        for e in "${PRUNE_E[@]}"; do
            IFS="$SEP" read -r _d _d _d _d _d _d _d notify _d _d <<< "$e"
            parse_notify_text "$notify" && { HOST_LABEL="$N_HOST"; break; }
        done
    fi
    if [ -z "$HOST_LABEL" ]; then
        local e notify
        for e in "${MON_E[@]}"; do
            notify="${e##*"$SEP"}"
            parse_notify_text "$notify" && { HOST_LABEL="$N_HOST"; break; }
        done
    fi
    [ -n "$HOST_LABEL" ] || die "could not determine host_label -- no send/prune/monitor/replica line had parseable notify text"
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [RENDER A CONFIG FROM THE CLASSIFIED ENTITIES]
###############################################################################
TCOUNT=0
declare -a TEMPLATE_ORDER=()
declare -A TEMPLATE_FIELDS=()   # name -> newline-joined "key = value" lines
NEW_TEMPLATE_NAME=""

# new_template FIELD VALUE [FIELD VALUE ...] -- sets $NEW_TEMPLATE_NAME. NOT
# `name="$(new_template ...)"`: this mutates globals (TCOUNT/TEMPLATE_ORDER/
# TEMPLATE_FIELDS), and $(...) forks a subshell -- every mutation inside a
# command substitution is invisible to the caller once it returns, so every
# call would silently reuse TCOUNT=0 and "return" the same name (t1) forever.
new_template() {
    TCOUNT=$((TCOUNT+1))
    local name="t${TCOUNT}"
    local out="" k v
    while [ "$#" -ge 2 ]; do
        k="$1"; v="$2"; shift 2
        [ -n "$v" ] && out="${out}${k} = ${v}"$'\n'
    done
    TEMPLATE_FIELDS["$name"]="$out"
    TEMPLATE_ORDER+=("$name")
    NEW_TEMPLATE_NAME="$name"
}

declare -a SECTION_ORDER=()          # "kind<SEP>name", in first-use order
declare -A SECTION_SEEN=()
declare -A SECTION_TEMPLATES=()      # "kind<SEP>name" -> comma-joined template list
declare -A SECTION_FIELDS=()         # "kind<SEP>name" -> newline-joined "key = value" lines
SECTION_KEY=""

# get_section KIND NAME -- sets $SECTION_KEY. Same subshell trap as
# new_template: never call this as `key="$(get_section ...)"`.
get_section() {
    local kind="$1" name="$2"
    local key="${kind}${SEP}${name}"
    if [ -z "${SECTION_SEEN[$key]+x}" ]; then
        SECTION_SEEN["$key"]=1
        SECTION_ORDER+=("$key")
        SECTION_TEMPLATES["$key"]=""
        SECTION_FIELDS["$key"]=""
    fi
    SECTION_KEY="$key"
}
section_add_template() { local key="$1" t="$2"; SECTION_TEMPLATES["$key"]="${SECTION_TEMPLATES[$key]:+${SECTION_TEMPLATES[$key]},}${t}"; }
section_set_field() { local key="$1" k="$2" v="$3"; [ -n "$v" ] && SECTION_FIELDS["$key"]="${SECTION_FIELDS[$key]}${k} = ${v}"$'\n'; }

# ---- excluded (-P) sections: union of every distinct "prefix:keep" seen ----
build_excluded_sections() {
    local e protect_csv tok prefix keep
    declare -A seen=()
    for e in "${PRUNE_E[@]}" "${GFS_E[@]}"; do
        IFS="$SEP" read -r _ _ _ _ _ _ protect_csv _ _ _ <<< "$e"
        [ -n "$protect_csv" ] || continue
        local IFS_SAVE="$IFS"; IFS=','
        for tok in $protect_csv; do
            [ -n "$tok" ] || continue
            prefix="${tok%%:*}"; keep="${tok#*:}"
            if [ -n "${seen[$prefix]+x}" ] && [ "${seen[$prefix]}" != "$keep" ]; then
                warn "excluded prefix '$prefix' seen with two different keep counts ('${seen[$prefix]}' and '$keep') across delsnaps lines -- using '${seen[$prefix]}', check by hand"
            else
                seen["$prefix"]="$keep"
            fi
        done
        IFS="$IFS_SAVE"
    done
    local prefix
    for prefix in "${!seen[@]}"; do
        get_section excluded "$prefix"
        section_set_field "$SECTION_KEY" "keep" "${seen[$prefix]}"
    done
}

# Pull the recursion flag back OUT of a reconstructed flags string
# (REV-20260807-054). Since gen-cron.sh v4.27 recursion is the [dataset:]
# field 'recursive', and -r/-R in 'flags' is a hard error -- so leaving it
# where it was found would emit a config the real generator refuses.
#
# Sets C_REC to flat|atomic|"" and C_FLAGS_REST to what is left.
#
# Argument-aware for the same reason gen-cron's scanner is: a token following
# an option that takes one is an ARGUMENT, and `-m -R` names a prefix, not a
# recursion. The arg-letter set is the union across both engines, matching
# gen-cron.sh's FLAGS_ARG_LETTERS.
C2C_ARG_LETTERS='mlvjpkqQToxcbXKOL'
split_recursion() {   # <flags>
    local tok rest c want_arg=0
    C_REC=""; C_FLAGS_REST=""
    for tok in $1; do
        if [ "$want_arg" -eq 1 ]; then
            want_arg=0
            C_FLAGS_REST="${C_FLAGS_REST:+$C_FLAGS_REST }$tok"
            continue
        fi
        case "$tok" in
            -r) C_REC="atomic"; continue ;;
            -R) C_REC="flat";   continue ;;
            -?*)
                # Bundled forms are not something gen-cron.sh emits, but a
                # hand-edited crontab can hold one. Refuse rather than hand
                # back a config the generator will reject with a message
                # pointing at a file this tool wrote.
                rest="${tok#-}"
                while [ -n "$rest" ]; do
                    c="${rest%"${rest#?}"}"; rest="${rest#?}"
                    case "$c" in
                        r|R) die "cannot represent '$tok': recursion is bundled with other options. Split it into its own -$c before converting -- gen-cron.sh v4.27+ takes recursion as the [dataset:] field 'recursive', not as a flag" ;;
                    esac
                    case "$C2C_ARG_LETTERS" in *"$c"*) [ -n "$rest" ] || want_arg=1; rest="" ;; esac
                done
                ;;
        esac
        C_FLAGS_REST="${C_FLAGS_REST:+$C_FLAGS_REST }$tok"
    done
}

# ---- sends: one [dataset:] section per distinct src, one template per tier ----
build_send_sections() {
    local e sched flags src dst prefix notify prev
    for e in "${SEND_E[@]}"; do
        IFS="$SEP" read -r sched flags src dst prefix notify <<< "$e"
        split_recursion "$flags"
        get_section dataset "$src"
        if [ -n "$C_REC" ]; then
            # 'recursive' is a SECTION field, not a template one, so two tiers
            # of the same dataset disagreeing about it is unrepresentable --
            # and it would be a real defect in the source crontab, where one
            # tier walks the subtree and another does not.
            prev=""
            case "${SECTION_FIELDS[$SECTION_KEY]:-}" in
                *"recursive = flat"*)   prev=flat ;;
                *"recursive = atomic"*) prev=atomic ;;
            esac
            if [ -n "$prev" ] && [ "$prev" != "$C_REC" ]; then
                die "dataset '$src' has tiers with DIFFERENT recursion ('$prev' and '$C_REC'). A [dataset:] section declares recursion once for all its tiers, so this crontab cannot be represented as one section -- split it into separate configs, or make the tiers agree"
            fi
            section_set_field "$SECTION_KEY" "recursive" "$C_REC"
        fi
        new_template send_schedule "$sched" prefix "$prefix" flags "$C_FLAGS_REST" dst "$dst" notify_raw "$notify"
        section_add_template "$SECTION_KEY" "$NEW_TEMPLATE_NAME"
    done
}

# ---- prune + monitor merge ----
# 'prune = yes/no' is a SECTION-level field (every tier in a [prune:] section
# shares it), so a section can never mix real prune tiers with prune=no
# monitor-only tiers. A monitor merges into a matching prune TIER (same
# section) when (scope,recursive,pattern) line up; anything left over needs
# its own section, and that section must not collide with a real prune
# section's name (scope) -- see the header comment's UNREPRESENTABLE case.
declare -A PRUNE_BUCKET=()     # "scope<SEP>rec<SEP>cc" -> newline-joined PRUNE_E members
declare -a PRUNE_BUCKET_ORDER=()
declare -A SCOPE_VARIANTS=()   # scope -> space-joined set of "rec:cc" seen

build_prune_buckets() {
    local e sched scope pattern retain rec cc protect notify bkey
    for e in "${PRUNE_E[@]}"; do
        IFS="$SEP" read -r sched scope pattern retain rec cc protect notify plbl sshf <<< "$e"
        # pair_label and ssh_flags join the bucket key: a [prune:] section
        # carries ONE of each, so tiers that disagree cannot share a section.
        bkey="${scope}${SEP}${rec}${SEP}${cc}${SEP}${plbl}${SEP}${sshf}"
        if [ -z "${PRUNE_BUCKET[$bkey]+x}" ]; then
            PRUNE_BUCKET["$bkey"]=""
            PRUNE_BUCKET_ORDER+=("$bkey")
        fi
        PRUNE_BUCKET["$bkey"]="${PRUNE_BUCKET[$bkey]}${e}"$'\n'
        local variant="${rec}:${cc}"
        case " ${SCOPE_VARIANTS[$scope]:-} " in
            *" $variant "*) ;;
            *) SCOPE_VARIANTS["$scope"]="${SCOPE_VARIANTS[$scope]:-}${SCOPE_VARIANTS[$scope]:+ }$variant" ;;
        esac
    done
    local scope variants
    for scope in "${!SCOPE_VARIANTS[@]}"; do
        variants="${SCOPE_VARIANTS[$scope]}"
        if [ "$(printf '%s\n' $variants | wc -l)" -gt 1 ]; then
            warn "UNREPRESENTABLE: scope '$scope' needs prune tiers with different recursive/clear_cut settings ($variants) -- gen-cron.sh has no per-tier way to express that in one [prune:] section. Left out; split by hand."
        fi
    done
}

emit_prune_and_monitor_sections() {
    local bkey scope rec cc members line sched pattern retain protect notify
    for bkey in "${PRUNE_BUCKET_ORDER[@]}"; do
        IFS="$SEP" read -r scope rec cc <<< "$bkey"
        [ "$(printf '%s\n' ${SCOPE_VARIANTS[$scope]} | wc -l)" -gt 1 ] && continue   # unrepresentable, already warned
        get_section prune "$scope"
        local key="$SECTION_KEY"
        [ "$rec" = "1" ] && section_set_field "$key" recursive yes
        [ "$cc" = "1" ] && section_set_field "$key" clear_cut yes
        [ -n "$plbl" ] && section_set_field "$key" pair_label "$plbl"
        [ -n "$sshf" ] && section_set_field "$key" ssh_flags "$sshf"
        members="${PRUNE_BUCKET[$bkey]}"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            IFS="$SEP" read -r sched _ pattern retain _ _ protect notify _ _ <<< "$line"
            local mon_warn="" mon_crit="" mon_tier="" mon_label=""
            local midx match_idx=-1
            for midx in "${!MON_E[@]}"; do
                [ -n "${MON_USED[$midx]:-}" ] && continue
                local msched mscope mpattern mwarn mcrit mrec mnotify mplbl
                IFS="$SEP" read -r msched mscope mpattern mwarn mcrit mrec mnotify mplbl <<< "${MON_E[$midx]}"
                if [ "$mscope" = "$scope" ] && [ "$mrec" = "$rec" ] && [ "$mpattern" = "$pattern" ]; then
                    match_idx="$midx"; mon_warn="$mwarn"; mon_crit="$mcrit"
                    parse_notify_text "$mnotify" && { mon_tier="$N_TIER"; mon_label="$N_LABEL"; }
                    [ -n "$mplbl" ] && section_set_field "$key" pair_label "$mplbl"
                    break
                fi
            done
            [ "$match_idx" -ge 0 ] && MON_USED["$match_idx"]=1
            new_template prune_schedule "$sched" pattern "$pattern" retain "$retain" notify_raw_prune "$notify" \
                 tier_label "$mon_tier" notify "$mon_label" monitor_warn "$mon_warn" monitor_crit "$mon_crit"
            section_add_template "$key" "$NEW_TEMPLATE_NAME"
        done <<< "$members"
    done

    local midx
    for midx in "${!MON_E[@]}"; do
        [ -n "${MON_USED[$midx]:-}" ] && continue
        local msched mscope mpattern mwarn mcrit mrec mnotify mplbl
        IFS="$SEP" read -r msched mscope mpattern mwarn mcrit mrec mnotify mplbl <<< "${MON_E[$midx]}"
        if [ -n "${SCOPE_VARIANTS[$mscope]+x}" ]; then
            warn "UNREPRESENTABLE: monitor on scope '$mscope' pattern '$mpattern' could not be matched to an existing prune tier, and that scope is already a real [prune:] section -- co-locating would wrongly force prune=no onto it. Left out; add by hand."
            continue
        fi
        get_section prune "$mscope"
        local key="$SECTION_KEY"
        section_set_field "$key" prune no
        [ -n "$mplbl" ] && section_set_field "$key" pair_label "$mplbl"
        [ "$mrec" = "1" ] && section_set_field "$key" recursive yes
        parse_notify_text "$mnotify" || die "cannot parse monitor notify text: $mnotify"
        new_template pattern "$mpattern" tier_label "$N_TIER" notify "$N_LABEL" monitor_warn "$mwarn" monitor_crit "$mcrit"
        section_add_template "$key" "$NEW_TEMPLATE_NAME"
    done
}
declare -A MON_USED=()

# ---- gfs sections ----
build_gfs_sections() {
    local e sched scope pattern retain rec cc protect notify plbl sshf part
    for e in "${GFS_E[@]}"; do
        IFS="$SEP" read -r sched scope pattern retain rec cc protect notify plbl sshf <<< "$e"
        if [ -n "${SECTION_SEEN[prune${SEP}${scope}]+x}" ]; then
            warn "UNREPRESENTABLE: gfs prune on scope '$scope' collides with an existing [prune:$scope] section (different tiers there already claim that name) -- left out; merge by hand."
            continue
        fi
        get_section prune "$scope"
        local key="$SECTION_KEY"
        section_set_field "$key" gfs yes
        section_set_field "$key" gfs_pattern "$pattern"
        [ -n "$plbl" ] && section_set_field "$key" pair_label "$plbl"
        [ -n "$sshf" ] && section_set_field "$key" ssh_flags "$sshf"
        section_set_field "$key" pattern "$pattern"
        section_set_field "$key" prune_schedule "$sched"
        section_set_field "$key" notify_raw_prune "$notify"
        [ "$rec" = "1" ] && section_set_field "$key" recursive yes
        [ "$cc" = "1" ] && section_set_field "$key" clear_cut yes
        local IFS_SAVE="$IFS"; IFS=' '
        for part in $retain; do
            IFS="$IFS_SAVE"
            [ -n "$part" ] || continue
            new_template retain "$part"
            section_add_template "$key" "$NEW_TEMPLATE_NAME"
        done
        IFS="$IFS_SAVE"
    done
}

# ---- replica sections ----
#
# A replica is reconstructed as the [replica:] section it came from, not as a
# [dataset:] with a local dst: the two mean different things, and a round-trip
# that turned one into the other would hand the next reader a config claiming a
# backup relationship where there is only a copy.
build_replica_sections() {
    local e sched label source dst prefix media rec notify
    for e in "${REPL_E[@]+"${REPL_E[@]}"}"; do
        IFS="$SEP" read -r sched label source dst prefix media rec notify <<< "$e"
        get_section replica "$label"
        local key="$SECTION_KEY"
        section_set_field "$key" source "$source"
        section_set_field "$key" dst "$dst"
        section_set_field "$key" schedule "$sched"
        section_set_field "$key" prefix "$prefix"
        [ -n "$media" ] && section_set_field "$key" media "$media"
        [ "$rec" = "1" ] && section_set_field "$key" recursive yes
        [ -n "$notify" ] && [ "$notify" != "$label" ] && section_set_field "$key" notify "$notify"
    done
}

# ---- bookmark sections ----
build_bookmark_sections() {
    local e sched scope pattern age rec label plbl sshf
    for e in "${BOOK_E[@]}"; do
        IFS="$SEP" read -r sched scope pattern age rec label plbl sshf <<< "$e"
        get_section prune-bookmarks "$scope"
        local key="$SECTION_KEY"
        section_set_field "$key" schedule "$sched"
        section_set_field "$key" age "$age"
        [ "$pattern" != "tgt-" ] && section_set_field "$key" pattern "$pattern"
        [ "$rec" = "1" ] && section_set_field "$key" recursive yes
        [ -n "$plbl" ] && section_set_field "$key" pair_label "$plbl"
        [ -n "$sshf" ] && section_set_field "$key" ssh_flags "$sshf"
        section_set_field "$key" notify "$label"
    done
}

render_config() {
    local out="" T=$'\t'
    out+="[defaults]"$'\n'
    out+="${T}host_label = ${HOST_LABEL}"$'\n'
    [ -n "$REPO_DIR" ] && out+="${T}repo_dir = ${REPO_DIR}"$'\n'
    [ -n "$CRON_LOG" ] && out+="${T}cron_log = ${CRON_LOG}"$'\n'
    [ -n "$NOTIFY_SCRIPT" ] && out+="${T}notify_script = ${NOTIFY_SCRIPT}"$'\n'
    [ -n "$WARN_SCRIPT" ] && out+="${T}warn_script = ${WARN_SCRIPT}"$'\n'
    if [ "$DG_FOUND" -eq 1 ]; then
        out+="${T}digest_script = ${DG_SCRIPT_V}"$'\n'
        if [ "$DG_SCHED_V" != "0 7 * * *" ]; then
            warn "digest schedule '$DG_SCHED_V' differs from gen-cron.sh's default '0 7 * * *' -- there is no config field for it; set DIGEST_SCHEDULE=\"$DG_SCHED_V\" in the environment when running gen-cron.sh with this file"
        fi
    elif [ "${#MON_E[@]}" -gt 0 ]; then
        out+="${T}digest_script = none"$'\n'
    fi
    out+=$'\n'

    local t
    for t in "${TEMPLATE_ORDER[@]}"; do
        [ -n "${TEMPLATE_FIELDS[$t]}" ] || continue
        out+="[template:${t}]"$'\n'
        while IFS= read -r fl; do
            [ -n "$fl" ] && out+=$'\t'"${fl}"$'\n'
        done <<< "${TEMPLATE_FIELDS[$t]}"
        out+=$'\n'
    done

    local key kind name
    for key in "${SECTION_ORDER[@]}"; do
        IFS="$SEP" read -r kind name <<< "$key"
        out+="[${kind}:${name}]"$'\n'
        [ -n "${SECTION_TEMPLATES[$key]}" ] && out+="${T}use_template = ${SECTION_TEMPLATES[$key]}"$'\n'
        while IFS= read -r fl; do
            [ -n "$fl" ] && out+=$'\t'"${fl}"$'\n'
        done <<< "${SECTION_FIELDS[$key]}"
        out+=$'\n'
    done

    printf '%s' "$out"
}
###############################################################################
#END 5

###############################################################################
#BEGIN 6 [MAIN]
###############################################################################
extract_block
classify_lines
build_excluded_sections
build_send_sections
build_prune_buckets
emit_prune_and_monitor_sections
build_gfs_sections
build_bookmark_sections
build_replica_sections

RESULT="$(render_config)"
if [ -n "$OUTFILE" ]; then
    printf '%s' "$RESULT" > "$OUTFILE"
else
    printf '%s' "$RESULT"
fi

[ "$WARNED" -eq 1 ] && exit 2
exit 0
###############################################################################
#END 6
