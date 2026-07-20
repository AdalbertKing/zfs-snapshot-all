#!/bin/bash
set -o pipefail
# gen-cron.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Description: generates a crontab block for snapsend.sh/delsnaps.sh from a
# host-local INI config file, instead of hand-editing scattered cron lines.
#
# Usage: gen-cron.sh [-c CONFIG] [--install] [-V]
# Options:
#   -c <FILE>   Config file to read (default: jobs.<hostname -s>.conf next to this script)
#   --install   Install the generated block into this user's crontab (idempotent:
#               replaces the existing managed block instead of appending). Without
#               this flag, the block is only printed to stdout for review.
#   -V          Print version and exit
#
# CONFIG FORMAT v4 -- typed sections. Every section header (except [defaults])
# carries an explicit TYPE prefix, split on the first ':'. The type declares
# WHICH operations that section runs; the name after ':' is a literal ZFS path
# or a tier name. There is NO magic: a target is always a path you wrote down.
# The script never infers "same VM, two copies" -- rpool/data/vm1 and
# hdd/backups/pve1/rpool/data/vm1 are two different, unrelated objects.
#
#   [defaults]
#       host_label = pve2                 # used to auto-build notify text
#       dst        = hdd/backups/pve2     # optional -- omit for local-only (no send target)
#
#   [template:<tier>]                     # a tier's full lifecycle (cadence + retention)
#       send_schedule    = <5-field cron>  # omit if this tier never sends
#       prefix           = <snapshot name prefix passed to snapsend.sh -m>
#       notify_word      = backup          # default "backup"; e.g. "snapshot" for local jobs
#       tier_label       = <word>          # display name for the tier in notify text
#                                          # (default: the tier itself; e.g. store_hourly -> hourly)
#       notify_raw       = <literal notify-fail.sh text, bypasses auto-synthesis>
#       prune_schedule   = <5-field cron>  # omit if this tier never prunes
#       pattern          = <snapshot name prefix delsnaps.sh matches>
#       keep             = <N>             # count-based retention -> -<TIER_LETTER><N>
#       retain           = <raw delsnaps.sh flags>  # e.g. "-H24"; mutually exclusive with keep
#       notify_raw_prune = <literal notify-fail.sh text for the prune line>
#
#   [dataset:<zfs/path>]                  # a dataset you own end-to-end
#       use_template = <tier>[,<tier>...]  # comma list -- one dataset can span several tiers
#       notify       = <short label>
#       flags        = <snapsend.sh flags>
#       flags_<tier> = <per-tier flags override>
#       ...any template field can be overridden here (dst, send_schedule,
#          prune_schedule, keep, retain, notify_raw, notify_raw_prune)
#     A dataset section runs, scoped to ITS OWN path, non-recursively:
#       create(+send)  if its tiers resolve send_schedule
#       self-prune     if its tiers resolve prune_schedule (retention defined
#                      right here, at the dataset, independent of every other)
#     Datasets sharing a resolved (send_schedule,dst,prefix,flags) merge into one
#     send line; datasets sharing a resolved (prune_schedule,pattern,keep/retain)
#     merge into one prune line that lists them BY FULL PATH, non-recursively.
#     Inline prune NEVER collapses to a recursive -R sweep.
#
#   [prune:<scope>]                       # standalone, additive prune of a scope
#       use_template = <tier>[,<tier>...]  # borrows each tier's prune policy
#       recursive    = yes|no              # default no; yes -> delsnaps.sh -R (subtree)
#       clear_cut    = yes|no              # default no; yes -> delsnaps.sh -F (destroy -R clones)
#       notify       = <short label>
#     For scopes you do NOT create locally: a backup store receiving pushes from
#     other hosts, foreign/received subtrees. Emits one delsnaps line per tier.
#
#   [monitor:<scope>]                     # RESERVED -- parsed, emits nothing yet
#       (overdue-snapshot alerting, next stage)
#
# flags="-f" (force full send) and flags="-n" (dry-run) are rejected at generate
# time: -f in a standing cron job means destroy-and-reseed the target every run,
# -n never actually sends anything -- neither makes sense as a recurring job.
#
# Every resolved prune operation is validated against every other operation on
# the SAME literal scope: since delsnaps.sh matches by literal string prefix, a
# pattern that is a prefix of (or equal to) another pattern on that scope would
# let one tier's snapshots leak into another tier's retention run. Rejected.
#
# prune-vs-inline overlap ("B" semantics): if a recursive [prune:S] and an inline
# [dataset:X] both cover the same snapshots, BOTH lines are emitted and both run;
# net effect is the strictest keep wins. The generator does NOT guard this --
# prune priority is deliberate user discipline, not enforced magic.
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v4.0'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
CRON_LOG="${CRON_LOG:-/root/scripts/cron.log}"
LOCKFILE="${GEN_CRON_LOCKFILE:-/var/run/gen-cron.install.lock}"
MARKER_BEGIN="# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)"
MARKER_END="# END zfs-backup-managed"

declare -a JOB_LINES=()
declare -a RETAIN_LINES=()

SEP=$'\x1c'   # field separator inside one encoded entity string
LSEP=$'\x1e'  # entity separator inside one group's member list

declare -A INI=()
declare -a SECTION_ORDER=()
declare -A SECTION_KIND=()    # header -> defaults|template|dataset|prune|monitor
declare -A SECTION_NAME=()    # header -> the name after ':' (path/tier/scope); "" for defaults
declare -A SEEN_SECTION=()
CUR_SECTION=""

declare -A TIER_LETTER=( [hourly]=H [daily]=D [weekly]=W [monthly]=M [yearly]=Y [annual]=Y )
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [HELPERS]
###############################################################################
die() { echo "gen-cron.sh: error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
gen-cron.sh -- generate a crontab block for snapsend.sh/delsnaps.sh from an
INI config of typed sections (config format v4).

Usage: gen-cron.sh [-c CONFIG] [--install] [-V]
  -c <FILE>   Config file (default: jobs.<hostname -s>.conf next to this script)
  --install   Install/replace the managed block in this user's crontab
              (idempotent). Without it, the block is printed to stdout.
  -V          Print version and exit
  -h          Print this help

Section types (header split on first ':'):
  [defaults]           host_label, optional dst
  [template:<tier>]    a tier's cadence + retention policy
  [dataset:<path>]     owned dataset: create+send + inline self-prune (own path)
  [prune:<scope>]      standalone additive prune (recursive=/clear_cut= opt-in)
  [monitor:<scope>]    reserved (overdue-snapshot alerting -- next stage)

See the comment header of this script for the full field reference.
EOF
}

# Rejects flags that never make sense in a standing/recurring cron job.
lint_flags() {
    local flags="$1" ctx="$2" tok
    for tok in $flags; do
        case "$tok" in
            -f) die "$ctx: flag -f (force full send) not allowed in a recurring job -- it would destroy and re-seed the target every run" ;;
            -n) die "$ctx: flag -n (dry-run) not allowed in a recurring job -- it never actually sends anything" ;;
        esac
    done
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
###############################################################################
#END 2

###############################################################################
#BEGIN 3 [INI PARSING + FIELD RESOLUTION]
###############################################################################
# Parses typed sections. The raw header string (e.g. "template:hourly",
# "dataset:rpool/data/vm-106-disk-0", or "defaults") is used verbatim as the
# INI key prefix and the section's identity -- kind+name together, so a
# [dataset:X] and a [prune:X] never collide.
parse_ini() {
    local file="$1" line trimmed key val hdr kind name
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        trimmed="$(trim "$line")"
        [ -z "$trimmed" ] && continue
        if [[ "$trimmed" =~ ^\[(.+)\]$ ]]; then
            hdr="$(trim "${BASH_REMATCH[1]}")"
            if [ "$hdr" = "defaults" ]; then
                kind="defaults"; name=""
            else
                case "$hdr" in
                    *:*) : ;;
                    *) die "section '[$hdr]' has no type prefix (expected defaults, or template:/dataset:/prune:/monitor: followed by a name)" ;;
                esac
                kind="$(trim "${hdr%%:*}")"
                name="$(trim "${hdr#*:}")"
                case "$kind" in
                    template|dataset|prune|monitor) : ;;
                    *) die "unknown section type '$kind' in '[$hdr]' (expected template/dataset/prune/monitor)" ;;
                esac
                [ -n "$name" ] || die "section '[$hdr]' has an empty name after '$kind:'"
            fi
            [ -z "${SEEN_SECTION[$hdr]+x}" ] || die "duplicate section '[$hdr]' in $file"
            SEEN_SECTION["$hdr"]=1
            CUR_SECTION="$hdr"
            SECTION_ORDER+=("$hdr")
            SECTION_KIND["$hdr"]="$kind"
            SECTION_NAME["$hdr"]="$name"
            continue
        fi
        if [[ "$trimmed" == *"="* ]] && [ -n "$CUR_SECTION" ]; then
            key="$(trim "${trimmed%%=*}")"
            val="$(trim "${trimmed#*=}")"
            INI["${CUR_SECTION}${SEP}${key}"]="$val"
        fi
    done < "$file"
}

ini_has() { [ -n "${INI[$1${SEP}$2]+x}" ]; }
ini_get() { printf '%s' "${INI[$1${SEP}$2]}"; }

# resolve_field FIELD DS TMPL DEFAULTS -- prints value, return 1 if unresolved.
# Any of DS/TMPL/DEFAULTS may be "" to skip that layer. Each is a section header.
resolve_field() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4"
    if [ -n "$ds" ] && ini_has "$ds" "$field"; then ini_get "$ds" "$field"; return 0; fi
    if [ -n "$tmpl" ] && ini_has "$tmpl" "$field"; then ini_get "$tmpl" "$field"; return 0; fi
    if [ -n "$defaults" ] && ini_has "$defaults" "$field"; then ini_get "$defaults" "$field"; return 0; fi
    return 1
}

# resolve_field_tiered FIELD TIER DS TMPL DEFAULTS -- checks a per-tier
# override on the dataset (field_<tier>) before falling back to resolve_field.
resolve_field_tiered() {
    local field="$1" tier="$2" ds="$3" tmpl="$4" defaults="$5"
    if [ -n "$ds" ] && ini_has "$ds" "${field}_${tier}"; then ini_get "$ds" "${field}_${tier}"; return 0; fi
    resolve_field "$field" "$ds" "$tmpl" "$defaults"
}

# resolve_keep_retain DS TMPL TIER -- sets $RESOLVED_RETAIN and returns 0 on
# success; on failure returns 1 and sets $KEEP_RETAIN_ERROR to the specific
# reason (ambiguous vs. neither set vs. unknown tier letter), or leaves it
# empty for the generic "neither resolved" case. Must be called WITHOUT
# $(...) command substitution -- it communicates via globals, and a subshell
# would silently discard both of them (subshells get copies, not references).
RESOLVED_RETAIN=""
KEEP_RETAIN_ERROR=""
resolve_keep_retain() {
    local ds="$1" tmpl="$2" tier="$3" keep="" retain="" have_keep=0 have_retain=0
    RESOLVED_RETAIN=""
    KEEP_RETAIN_ERROR=""
    if [ -n "$ds" ] && ini_has "$ds" "keep"; then keep="$(ini_get "$ds" keep)"; have_keep=1
    elif [ -n "$tmpl" ] && ini_has "$tmpl" "keep"; then keep="$(ini_get "$tmpl" keep)"; have_keep=1; fi
    if [ -n "$ds" ] && ini_has "$ds" "retain"; then retain="$(ini_get "$ds" retain)"; have_retain=1
    elif [ -n "$tmpl" ] && ini_has "$tmpl" "retain"; then retain="$(ini_get "$tmpl" retain)"; have_retain=1; fi
    if [ "$have_keep" -eq 1 ] && [ "$have_retain" -eq 1 ]; then
        KEEP_RETAIN_ERROR="both 'keep' and 'retain' resolved -- ambiguous, set only one"
        return 1
    fi
    if [ "$have_keep" -eq 0 ] && [ "$have_retain" -eq 0 ]; then
        return 1
    fi
    if [ "$have_keep" -eq 1 ]; then
        if [ -z "${TIER_LETTER[$tier]+x}" ]; then
            KEEP_RETAIN_ERROR="no retain-flag letter known for tier '$tier' -- use 'retain=' instead of 'keep=', or add it to TIER_LETTER"
            return 1
        fi
        RESOLVED_RETAIN="-${TIER_LETTER[$tier]}${keep}"
        return 0
    fi
    RESOLVED_RETAIN="$retain"
    return 0
}

notify_text() {
    local host="$1" tier="$2" kind="$3" label="$4"
    if [ -n "$label" ]; then
        printf '%s %s %s (%s)' "$host" "$tier" "$kind" "$label"
    else
        printf '%s %s %s' "$host" "$tier" "$kind"
    fi
}
###############################################################################
#END 3

###############################################################################
#BEGIN 3.5 [ENTITY BUILDING]
###############################################################################
# Walks dataset sections (create+send + inline self-prune, both scoped to the
# dataset's own path) and prune sections (standalone additive tasks). A tier
# contributes a send entity only if send_schedule resolves; an inline prune
# entity only if prune_schedule resolves (then pattern + keep/retain are
# required). monitor sections are parsed but produce nothing yet.
build_entities() {
    ini_has defaults host_label || die "[defaults] must set host_label (used to build notify text)"
    local host_label
    host_label="$(resolve_field host_label "" "" defaults)"

    declare -ga SEND_ENTITIES=()
    declare -ga INLINE_PRUNE_ENTITIES=()
    declare -ga PRUNE_SEC_ENTITIES=()
    declare -ga SCOPE_PATTERNS=()   # "scope<SEP>pattern" per resolved prune op, for overlap check

    local section kind name
    for section in "${SECTION_ORDER[@]}"; do
        kind="${SECTION_KIND[$section]}"
        name="${SECTION_NAME[$section]}"

        case "$kind" in
            defaults|monitor|template) continue ;;
            dataset) build_dataset "$section" "$name" "$host_label" ;;
            prune)   build_prune_section "$section" "$name" "$host_label" ;;
        esac
    done
}

# build_dataset SECTION_HEADER DATASET_PATH HOST_LABEL
build_dataset() {
    local ds="$1" ds_path="$2" host_label="$3"

    local tier_list
    tier_list="$(resolve_field use_template "$ds" "" "")" || die "[dataset:$ds_path] has no use_template"

    local -a tiers=()
    IFS=',' read -ra tiers <<< "$tier_list"
    local tier tmpl
    for tier in "${tiers[@]}"; do
        tier="$(trim "$tier")"
        tmpl="template:${tier}"
        [ "${SECTION_KIND[$tmpl]:-}" = "template" ] || die "[dataset:$ds_path] references unknown template '$tier' (expected a [template:$tier] section)"

        # Display name for notify text -- lets an internal tier id (e.g.
        # store_hourly) surface as a friendlier word (hourly) in alerts.
        # Never affects template lookup or the keep-retain tier letter.
        local ntier
        ntier="$(resolve_field tier_label "$ds" "$tmpl" "")" || ntier="$tier"

        # ---- send ----
        local send_schedule
        if send_schedule="$(resolve_field send_schedule "$ds" "$tmpl" defaults)"; then
            local dst prefix flags label raw_notify word notify
            dst="$(resolve_field dst "$ds" "$tmpl" defaults)" || dst=""
            prefix="$(resolve_field prefix "$ds" "$tmpl" defaults)" || die "[dataset:$ds_path] tier=$tier: send_schedule is set but 'prefix' did not resolve"
            flags="$(resolve_field_tiered flags "$tier" "$ds" "$tmpl" "")" || flags=""
            lint_flags "$flags" "[dataset:$ds_path] tier=$tier"
            label="$(resolve_field notify "$ds" "" "")" || label=""
            raw_notify="$(resolve_field notify_raw "$ds" "$tmpl" "")" || raw_notify=""
            word="$(resolve_field notify_word "" "$tmpl" "")" || word="backup"
            if [ -n "$raw_notify" ]; then
                notify="$raw_notify"
            else
                notify="$(notify_text "$host_label" "$ntier" "$word" "$label")"
            fi
            SEND_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${send_schedule}${SEP}${dst}${SEP}${prefix}${SEP}${flags}${SEP}${notify}${SEP}${label}")
        fi

        # ---- inline self-prune (own path, non-recursive) ----
        # prune_schedule is the deliberate "yes, prune this dataset" signal.
        local prune_schedule
        if prune_schedule="$(resolve_field prune_schedule "$ds" "$tmpl" defaults)"; then
            local pattern retain_flag plabel praw pnotify
            pattern="$(resolve_field pattern "$ds" "$tmpl" defaults)" || die "[dataset:$ds_path] tier=$tier: prune_schedule is set but 'pattern' did not resolve"
            resolve_keep_retain "$ds" "$tmpl" "$tier" || die "[dataset:$ds_path] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            plabel="$(resolve_field notify "" "$tmpl" "")" || plabel=""
            praw="$(resolve_field notify_raw_prune "" "$tmpl" "")" || praw=""
            if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
            INLINE_PRUNE_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}")
            SCOPE_PATTERNS+=("${ds_path}${SEP}${pattern}")
        fi
    done
}

# build_prune_section SECTION_HEADER SCOPE HOST_LABEL
build_prune_section() {
    local sec="$1" scope="$2" host_label="$3"

    local tier_list
    tier_list="$(resolve_field use_template "$sec" "" "")" || die "[prune:$scope] has no use_template"

    local recursive clearcut rec_raw cc_raw
    rec_raw="$(resolve_field recursive "$sec" "" "")" || rec_raw="no"
    cc_raw="$(resolve_field clear_cut "$sec" "" "")" || cc_raw="no"
    [ "$(trim "$rec_raw" | tr '[:upper:]' '[:lower:]')" = "yes" ] && recursive=1 || recursive=0
    [ "$(trim "$cc_raw"  | tr '[:upper:]' '[:lower:]')" = "yes" ] && clearcut=1  || clearcut=0

    local -a tiers=()
    IFS=',' read -ra tiers <<< "$tier_list"
    local tier tmpl
    for tier in "${tiers[@]}"; do
        tier="$(trim "$tier")"
        tmpl="template:${tier}"
        [ "${SECTION_KIND[$tmpl]:-}" = "template" ] || die "[prune:$scope] references unknown template '$tier' (expected a [template:$tier] section)"

        local ntier
        ntier="$(resolve_field tier_label "$sec" "$tmpl" "")" || ntier="$tier"

        local prune_schedule pattern retain_flag plabel praw pnotify
        prune_schedule="$(resolve_field prune_schedule "$sec" "$tmpl" defaults)" || die "[prune:$scope] tier=$tier: template has no prune_schedule"
        pattern="$(resolve_field pattern "$sec" "$tmpl" defaults)" || die "[prune:$scope] tier=$tier: prune_schedule is set but 'pattern' did not resolve"
        resolve_keep_retain "$sec" "$tmpl" "$tier" || die "[prune:$scope] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
        retain_flag="$RESOLVED_RETAIN"
        plabel="$(resolve_field notify "$sec" "$tmpl" "")" || plabel=""
        praw="$(resolve_field notify_raw_prune "$sec" "$tmpl" "")" || praw=""
        if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
        PRUNE_SEC_ENTITIES+=("${scope}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}${SEP}${recursive}${SEP}${clearcut}")
        SCOPE_PATTERNS+=("${scope}${SEP}${pattern}")
    done
}
###############################################################################
#END 3.5

###############################################################################
#BEGIN 3.6 [GROUPING]
###############################################################################
# Send groups by (schedule, dst, prefix, flags): identical resolved cadence and
# target -> one snapsend line. Inline prune groups by (schedule, pattern,
# retain): identical retention -> one delsnaps line listing the datasets by
# full path. Prune sections are emitted one line per tier, not grouped.
group_send() {
    declare -gA SEND_GROUPS=()
    declare -ga SEND_GROUP_ORDER=()
    local e ds tier schedule dst prefix flags notify label key
    for e in "${SEND_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label <<< "$e"
        key="${schedule}${SEP}${dst}${SEP}${prefix}${SEP}${flags}"
        [ -z "${SEND_GROUPS[$key]+x}" ] && SEND_GROUP_ORDER+=("$key")
        SEND_GROUPS["$key"]+="${e}${LSEP}"
    done
}

group_inline_prune() {
    declare -gA INLINE_PRUNE_GROUPS=()
    declare -ga INLINE_PRUNE_GROUP_ORDER=()
    local e ds tier pattern retain schedule notify key
    for e in "${INLINE_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier pattern retain schedule notify <<< "$e"
        key="${schedule}${SEP}${pattern}${SEP}${retain}"
        [ -z "${INLINE_PRUNE_GROUPS[$key]+x}" ] && INLINE_PRUNE_GROUP_ORDER+=("$key")
        INLINE_PRUNE_GROUPS["$key"]+="${e}${LSEP}"
    done
}
###############################################################################
#END 3.6

###############################################################################
#BEGIN 3.7 [SAME-SCOPE PATTERN OVERLAP CHECK]
###############################################################################
# delsnaps.sh matches snapshots by literal string prefix. If two resolved prune
# operations target the SAME literal scope and one pattern is a prefix of (or
# equal to) the other, a single snapshot could match both retention rules.
# Checked on the final resolved (scope, pattern) pairs collected in build.
validate_retain_patterns() {
    local -a scopes=() patterns=()
    local pair scope pattern
    for pair in "${SCOPE_PATTERNS[@]}"; do
        IFS="$SEP" read -r scope pattern <<< "$pair"
        scopes+=("$scope")
        patterns+=("$pattern")
    done

    local n="${#scopes[@]}" i j pi pj
    for ((i = 0; i < n; i++)); do
        for ((j = i + 1; j < n; j++)); do
            [ "${scopes[$i]}" = "${scopes[$j]}" ] || continue
            pi="${patterns[$i]}"
            pj="${patterns[$j]}"
            [ "$pi" = "$pj" ] && continue   # same tier resolved twice is not a conflict
            if [[ "$pi" == "$pj"* ]] || [[ "$pj" == "$pi"* ]]; then
                die "pattern overlap for scope='${scopes[$i]}': pattern='$pi' and pattern='$pj' -- one is a prefix of (or equal to) the other, so a single snapshot could match both retention rules. Use mutually exclusive prefixes."
            fi
        done
    done
}
###############################################################################
#END 3.7

###############################################################################
#BEGIN 3.8 [EMISSION]
###############################################################################
# Appends into JOB_LINES/RETAIN_LINES (consumed unchanged by generate_block
# in BEGIN 4) rather than printing directly.
emit_send() {
    local key list ds tier schedule dst prefix flags notify label
    for key in "${SEND_GROUP_ORDER[@]}"; do
        list="${SEND_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label <<< "${members[0]}"

        local src notify_out
        if [ "${#members[@]}" -eq 1 ]; then
            src="$ds"
            notify_out="$notify"
        else
            local -a datasets=() notifies=()
            local m mds mtier msch mdst mpre mflg mnot mlab
            for m in "${members[@]}"; do
                IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab <<< "$m"
                datasets+=("$mds")
                notifies+=("$mnot")
            done
            src="$(IFS=,; printf '%s' "${datasets[*]}")"

            local -a distinct=()
            local n found existing
            for n in "${notifies[@]}"; do
                found=0
                for existing in "${distinct[@]}"; do [ "$existing" = "$n" ] && found=1 && break; done
                [ "$found" -eq 0 ] && distinct+=("$n")
            done

            if [ "${#distinct[@]}" -eq 1 ]; then
                notify_out="${distinct[0]}"
            else
                local -a lseen=()
                local f2 e2
                for m in "${members[@]}"; do
                    IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab <<< "$m"
                    [ -z "$mlab" ] && continue
                    f2=0
                    for e2 in "${lseen[@]}"; do [ "$e2" = "$mlab" ] && f2=1 && break; done
                    [ "$f2" -eq 0 ] && lseen+=("$mlab")
                done
                local joined
                joined="$(IFS=+; printf '%s' "${lseen[*]}")"
                if [[ "$notify" == *"("* ]]; then
                    local host_tier="${notify%%(*}"
                    host_tier="$(trim "$host_tier")"
                    notify_out="${host_tier} (${joined})"
                else
                    notify_out="$notify"
                fi
            fi
        fi

        local cmd="$REPO_DIR/snapsend.sh -m \"$prefix\""
        [ -n "$flags" ] && cmd="$cmd $flags"
        cmd="$cmd \"$src\""
        [ -n "$dst" ] && cmd="$cmd \"$dst\""

        JOB_LINES+=("$schedule $cmd 2>>$CRON_LOG || $NOTIFY_SCRIPT \"$notify_out\"")
    done
}

# Inline prune: one delsnaps line per (schedule,pattern,retain) group, listing
# every member dataset BY FULL PATH, non-recursively. No -R, ever.
emit_inline_prune() {
    local key list ds tier pattern retain schedule notify
    for key in "${INLINE_PRUNE_GROUP_ORDER[@]}"; do
        list="${INLINE_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier pattern retain schedule notify <<< "${members[0]}"

        local -a targets=()
        local m mds mtier mpat mret msch mnot
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mds mtier mpat mret msch mnot <<< "$m"
            targets+=("$mds")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local cmd="$REPO_DIR/delsnaps.sh \"$joined\" \"$pattern\" $retain"
        RETAIN_LINES+=("$schedule $cmd 2>>$CRON_LOG || $NOTIFY_SCRIPT \"$notify\"")
    done
}

# Prune sections: one standalone delsnaps line per tier. recursive -> -R,
# clear_cut -> -F. Additive; no cross-check against inline prune (B semantics).
emit_prune_sections() {
    local e scope tier pattern retain schedule notify recursive clearcut
    for e in "${PRUNE_SEC_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope tier pattern retain schedule notify recursive clearcut <<< "$e"
        local flag="" fflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ "$clearcut" = "1" ] && fflag="-F "
        local cmd="$REPO_DIR/delsnaps.sh ${flag}${fflag}\"$scope\" \"$pattern\" $retain"
        RETAIN_LINES+=("$schedule $cmd 2>>$CRON_LOG || $NOTIFY_SCRIPT \"$notify\"")
    done
}
###############################################################################
#END 3.8

###############################################################################
#BEGIN 4 [BLOCK GENERATION]
###############################################################################
generate_block() {
    echo "$MARKER_BEGIN"
    echo "# Source: $CONFIG -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    local line
    for line in "${JOB_LINES[@]}"; do echo "$line"; done
    if [ "${#JOB_LINES[@]}" -gt 0 ] && [ "${#RETAIN_LINES[@]}" -gt 0 ]; then
        echo ""
    fi
    for line in "${RETAIN_LINES[@]}"; do echo "$line"; done
    echo "$MARKER_END"
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [IDEMPOTENT CRONTAB INSTALL]
###############################################################################
install_crontab() {
    command -v flock >/dev/null || die "flock command not found"
    command -v crontab >/dev/null || die "crontab command not found"

    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        die "another gen-cron.sh --install is already running (lock: $LOCKFILE) -- retry once it finishes"
    fi

    local current
    current="$(crontab -l 2>/dev/null)" || current=""

    local begin_count end_count
    begin_count=$(printf '%s\n' "$current" | grep -Fc "$MARKER_BEGIN")
    end_count=$(printf '%s\n' "$current" | grep -Fc "$MARKER_END")

    if [ "$begin_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
        die "malformed crontab: multiple '$MARKER_BEGIN'/'$MARKER_END' pairs found -- fix manually before retrying"
    fi
    if [ "$begin_count" -ne "$end_count" ]; then
        die "malformed crontab: found $begin_count BEGIN marker(s) but $end_count END marker(s) -- fix manually before retrying"
    fi

    local new_block
    new_block="$(generate_block)"

    local new_crontab="" line in_block=0
    if [ "$begin_count" -eq 1 ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "$MARKER_BEGIN" ]; then
                new_crontab+="$new_block"$'\n'
                in_block=1
                continue
            fi
            if [ "$line" = "$MARKER_END" ]; then
                in_block=0
                continue
            fi
            [ "$in_block" -eq 1 ] && continue
            new_crontab+="$line"$'\n'
        done <<<"$current"
    else
        if [ -n "$current" ]; then
            new_crontab="$current"$'\n\n'"$new_block"$'\n'
        else
            new_crontab="$new_block"$'\n'
        fi
    fi

    local new_crontab_norm
    new_crontab_norm="$(printf '%s' "$new_crontab")"

    if [ "$current" = "$new_crontab_norm" ]; then
        echo "gen-cron.sh: no changes -- crontab already up to date" >&2
        return 0
    fi

    printf '%s\n' "$new_crontab_norm" | crontab - || die "crontab install failed"
    echo "gen-cron.sh: crontab updated from $CONFIG" >&2
}
###############################################################################
#END 5

###############################################################################
#BEGIN 6 [MAIN]
###############################################################################
CONFIG=""
INSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see -h)" ;;
    esac
done

if [ -z "$CONFIG" ]; then
    CONFIG="$SCRIPT_DIR/jobs.$(hostname -s 2>/dev/null || hostname).conf"
fi
[ -f "$CONFIG" ] || die "config file not found: $CONFIG (pass -c to specify one)"

parse_ini "$CONFIG"
[ "${#SECTION_ORDER[@]}" -gt 0 ] || die "no sections found in $CONFIG"

build_entities
group_send
group_inline_prune
validate_retain_patterns
emit_send
emit_inline_prune
emit_prune_sections

[ "${#JOB_LINES[@]}" -gt 0 ] || [ "${#RETAIN_LINES[@]}" -gt 0 ] || die "no send/prune rules resolved from $CONFIG"

if [ "$INSTALL" -eq 1 ]; then
    install_crontab
else
    generate_block
fi
###############################################################################
#END 6
