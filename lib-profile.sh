#!/bin/bash
###############################################################################
# lib-profile.sh -- the PROFILE BOUNDARY: what a profile may and may not own.
#
# REV-20260808-073 settled the split: the deployment/relationship owns WHAT and
# WHERE, the profile owns HOW. REV-20260808-076 required the rule to exist in
# production rather than inside a test.
#
# WHY THIS IS NOT A SCHEMA CHANGE
#
# CONFIG v4 legitimately allows `src`/`dst` in a `[template:]` -- measured on the
# fleet, pve0 runs `[template:vm_archive]` with `dst = hdd/backups/pve1` and two
# real dataset sections using it. A template is a DEPLOYMENT-owned construct.
#
# A profile is a RESTRICTED template. So the restriction belongs here, at the
# profile boundary, and never in gen-cron's schema -- narrowing that schema to
# constrain profiles would forbid deployment-owned topology in order to police
# profile-owned policy, collapsing the very distinction REV-073 drew.
#
# ONE SCHEMA AUTHORITY, ONE OWNERSHIP LIST
#
# Which field names EXIST is gen-cron's business and is read from
# `gen-cron.sh --dump-fields`. This file never restates them: a second copy of
# the field list would drift, and drift of exactly that kind is what REV-054 and
# the REV-074 follow-up both cost.
#
# What a profile may not OWN is a different contract, and it does live here.
#
# FAIL CLOSED
#
# Every entry point returns non-zero and sets PROFILE_ERR on the first
# violation, before any caller has a chance to mutate config, state or cron.
###############################################################################

PROFILE_ERR=""

###############################################################################
# NAMESPACING -- REV-20260809-079 / PER-SOURCE-PROFILE-SCENARIOS-2026-08-09
#
# A relationship may bind DIFFERENT profiles to different source roots, and all
# of them compose into ONE effective CONFIG v4 file. gen-cron.sh has a single
# global section namespace and refuses a duplicate `[template:NAME]` outright
# (measured, not assumed). Two profiles carrying the same native template name
# -- which every profile derived from the built-in one does -- would therefore
# make the config unusable.
#
# So profile-owned template names are namespaced DETERMINISTICALLY FROM THE
# FIRST EMISSION, never only once a second profile appears. Switching it on
# later would rewrite the FIRST source's template section and its use_template
# line as a side effect of adding a second source -- which is exactly the
# "adding a source must not silently change existing bindings" property the
# per-source design requires.
#
# The mapping is one-way but readable, so a human reading a generated config can
# see which profile a template came from:
#
#     profile "default", template "standard_hourly"
#         -> profile__default__standard_hourly
#
# What this deliberately does NOT do: reuse a host's existing bare
# `[template:standard_hourly]`. A hand-written section that happens to share a
# name is NOT this profile's template, and binding to it would silently adopt
# somebody else's policy. The cost is visible and accepted -- a host carrying
# legacy bare sections gains namespaced ones beside them, and the activation
# preview shows it.
# REV-20260809-081 F1: concatenation with a separator is NOT injective unless
# the separator cannot occur inside either component. The first version of this
# encoding forgot that, and the counterexample is exact:
#
#     profile "a__b", template "c"   ->  profile__a__b__c
#     profile "a",    template "b__c" ->  profile__a__b__c
#
# Two distinct (profile, template) pairs, one section identity. The collision
# the namespace exists to prevent had simply moved from the native names into
# the separator encoding. gen-cron would eventually refuse the duplicate
# section, which is fail-safe, but by then the useful diagnosis -- WHICH two
# profile/name pairs collided -- is gone.
#
# The fix is a restricted naming domain rather than a cleverer encoding: `__`
# is forbidden inside a profile name and inside a native template name, so the
# separator is unambiguous by construction and the encoding stays readable. A
# length-prefixed scheme would also be injective and is unreadable in a config a
# human has to audit.
#
# Compatibility checked before choosing it: the built-in profile's names are
# `standard_hourly` and `keep_hourly|daily|weekly|monthly`, all single
# underscores, and the profile name in use is `default`. Nothing valid today is
# refused by this rule.
PROFILE_NS_SEP='__'

profile_ns_name() {   # <profile> <template> -> namespaced name
    printf 'profile%s%s%s%s' "$PROFILE_NS_SEP" "$1" "$PROFILE_NS_SEP" "$2"
}

# One rule, applied to both encoded components. Fail closed: a name that could
# break the header or the encoding is refused, never sanitised -- silently
# rewriting a name would make the generated config disagree with the profile
# that produced it.
profile_component_ok() {   # <kind> <value>  -> 0 usable, else PROFILE_ERR set
    local kind="$1" v="$2"
    case "$v" in
        '') PROFILE_ERR="empty $kind name"; return 1 ;;
        *[!A-Za-z0-9_-]*)
            PROFILE_ERR="$kind name '$v' is not usable in a section header (letters, digits, _ and - only)"
            return 1 ;;
        *"$PROFILE_NS_SEP"*)
            PROFILE_ERR="$kind name '$v' contains '$PROFILE_NS_SEP', which is the namespace separator -- it would make two different profile/template pairs render to the same section identity (REV-20260809-081)"
            return 1 ;;
    esac
    return 0
}

profile_name_ok() {   # <profile>
    profile_component_ok profile "$1"
}

# Fields a profile must never carry, whatever the schema permits.
#
#   src, dst   topology -- the relationship's, not the policy's
#   flags      raw engine flags: an escape hatch around every native field
#   pair_label relationship identity
#   notify     relationship-owned notification routing
#
# and the three LINK fields split out of 'flags' (gen-cron.sh,
# link_flag_letter_present):
#
#   bandwidth   a cap on ONE link. A profile does not know which link it will
#   compression fly over -- the same retention serves a gigabit LAN and a
#   cipher      20 Mbit VPN -- so these belong to the pair of hosts, and are
#               written per relationship. Naming them made them expressible
#               in CONFIG v4; it must not make them inheritable from policy.
PROFILE_FORBIDDEN_FIELDS='src dst flags pair_label notify bandwidth compression cipher'

profile_schema_dump() {   # <gen-cron.sh path> <outfile> -> 0 ok
    PROFILE_ERR=""
    local gen="$1" out="$2"
    [ -x "$gen" ] || { PROFILE_ERR="cannot execute '$gen' to read the field schema"; return 1; }
    "$gen" --dump-fields > "$out" 2>/dev/null || {
        PROFILE_ERR="'$gen --dump-fields' failed -- refusing to validate a profile against an unknown schema"
        return 1
    }
    [ -s "$out" ] || { PROFILE_ERR="'$gen --dump-fields' produced nothing"; return 1; }
    return 0
}

profile_field_forbidden() {   # <field> -> 0 forbidden
    local f n
    f="$1"
    for n in $PROFILE_FORBIDDEN_FIELDS; do [ "$f" = "$n" ] && return 0; done
    return 1
}

# One line of a profile-owned stanza, in a known section kind.
profile_check_field() {   # <kind> <field> <schema dump> <where>
    local kind="$1" field="$2" dump="$3" where="$4"
    if ! grep -qxF "$kind $field" "$dump"; then
        PROFILE_ERR="$where: '$field' is not a $kind field in CONFIG v4"
        return 1
    fi
    if profile_field_forbidden "$field"; then
        PROFILE_ERR="$where: '$field' is relationship-owned and must not appear in a profile (REV-20260808-073)"
        return 1
    fi
    # A profile that overrode recursion on a prune scope would decide topology
    # of the prune, which is the deployment's.
    if [ "$kind" = prune ] && [ "$field" = recursive ]; then
        PROFILE_ERR="$where: a profile may not override 'recursive' on a prune section"
        return 1
    fi
    return 0
}

# A .inc fragment: bare stanza lines, no section headers of its own.
profile_validate_fragment() {   # <kind> <file> <schema dump>
    PROFILE_ERR=""
    local kind="$1" file="$2" dump="$3" raw field n=0
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile fragment '$file'"; return 1; }
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        # LF in the index, CRLF in a Windows working tree; and blank lines
        # between stanzas are legitimate. Strip the CR and skip whitespace-only
        # lines, or the contract fails for a reason that is not the contract.
        raw="${raw%$'\r'}"
        [ -z "${raw//[[:space:]]/}" ] && continue
        case "$raw" in
            '#'*) continue ;;
            *'['*|*']'*)
                PROFILE_ERR="$file:$n: a fragment may not carry a section header -- the deployment decides which sections exist"
                return 1 ;;
        esac
        field=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=.*$/\1/p')
        [ -n "$field" ] || { PROFILE_ERR="$file:$n: not a 'field = value' line"; return 1; }
        profile_check_field "$kind" "$field" "$dump" "$file:$n" || return 1
    done < "$file"
    return 0
}

# templates.conf: real [template:NAME] sections, validated FIELD BY FIELD.
#
# REV-20260808-076 found this file was checked only for section-header shape and
# then composed into a config gen-cron happily accepts -- because `template dst`
# IS legal in the schema. So a profile could carry topology and the contract
# suite stayed green. Measured before fixing: adding `dst = hdd/evil` to the
# built-in profile left the suite at 22/22.
profile_validate_templates() {   # <file> <schema dump>
    PROFILE_ERR=""
    local file="$1" dump="$2" raw field n=0 in_section=0
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile templates '$file'"; return 1; }
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        raw="${raw%$'\r'}"
        [ -z "${raw//[[:space:]]/}" ] && continue
        case "$raw" in
            '#'*) continue ;;
            '[template:'*']')
                # REV-20260809-081 F1: the name is half of the rendered section
                # identity, so its grammar is a validation concern, not only a
                # rendering one. Refusing here means a profile carrying an
                # ambiguous name never reaches a runtime at all.
                field="${raw#\[template:}"; field="${field%\]}"
                profile_component_ok template "$field" || { PROFILE_ERR="$file:$n: $PROFILE_ERR"; return 1; }
                in_section=1
                continue ;;
            '['*)
                PROFILE_ERR="$file:$n: only [template:NAME] sections belong in a profile, got '$raw'"
                return 1 ;;
        esac
        if [ "$in_section" -ne 1 ]; then
            PROFILE_ERR="$file:$n: '$raw' appears before any [template:NAME] section"
            return 1
        fi
        field=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=.*$/\1/p')
        [ -n "$field" ] || { PROFILE_ERR="$file:$n: not a 'field = value' line"; return 1; }
        profile_check_field template "$field" "$dump" "$file:$n" || return 1
    done < "$file"
    [ "$in_section" -eq 1 ] || { PROFILE_ERR="$file: no [template:NAME] section found"; return 1; }
    return 0
}

###############################################################################
# RENDERING -- turning a validated profile into effective CONFIG v4 text.
#
# Validation says a profile is well-formed. Rendering is what a production
# runtime actually consumes, and it lives here for the reason REV-076 gave: a
# second implementation of profile grammar outside this boundary is how the rule
# and the thing that applies it drift apart.
###############################################################################

# Set by profile_render_templates: the namespaced names this profile defines.
PROFILE_TEMPLATE_NAMES=""

profile_render_templates() {   # <dir> <profile> <outfile>
    PROFILE_ERR=""; PROFILE_TEMPLATE_NAMES=""
    local dir="$1" prof="$2" out="$3" file raw name ns n=0
    profile_name_ok "$prof" || { PROFILE_ERR="profile name '$prof' is not usable in a section header (letters, digits, _ and - only)"; return 1; }
    file="$dir/templates.conf"
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile templates '$file'"; return 1; }
    : > "$out" || { PROFILE_ERR="cannot write '$out'"; return 1; }
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        raw="${raw%$'\r'}"
        case "$raw" in
            '[template:'*']')
                name="${raw#\[template:}"; name="${name%\]}"
                profile_component_ok template "$name" || { PROFILE_ERR="$file:$n: $PROFILE_ERR"; return 1; }
                ns="$(profile_ns_name "$prof" "$name")"
                # A repeat inside one profile would emit a duplicate section and
                # gen-cron would refuse the composed file. Refuse HERE instead,
                # naming the profile -- a refusal from the generator names only
                # the composed temporary file, which tells the operator nothing
                # about which profile produced it.
                case " $PROFILE_TEMPLATE_NAMES " in
                    *" $ns "*) PROFILE_ERR="$file:$n: '[template:$name]' appears twice in profile '$prof' -- the composed config would carry a duplicate section"; return 1 ;;
                esac
                PROFILE_TEMPLATE_NAMES="$PROFILE_TEMPLATE_NAMES $ns"
                printf '[template:%s]\n' "$ns" >> "$out" ;;
            *)
                printf '%s\n' "$raw" >> "$out" ;;
        esac
    done < "$file"
    PROFILE_TEMPLATE_NAMES="${PROFILE_TEMPLATE_NAMES# }"
    [ -n "$PROFILE_TEMPLATE_NAMES" ] || { PROFILE_ERR="$file: no [template:NAME] section found"; return 1; }
    return 0
}

# A fragment's `use_template = a,b` must resolve INSIDE this profile, and is
# rewritten to the namespaced names.
#
# The resolution requirement is not tidiness -- it is the invariant that a
# profile must never silently bind to a host's existing hand-written template
# just because a bare name happens to match. Structurally enforced: a name this
# profile does not define cannot be referenced at all.
profile_render_fragment() {   # <file> <profile> <outfile>
    PROFILE_ERR=""
    local file="$1" prof="$2" out="$3" raw field val part ns first n=0
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile fragment '$file'"; return 1; }
    [ -n "$PROFILE_TEMPLATE_NAMES" ] || { PROFILE_ERR="profile_render_fragment called before profile_render_templates"; return 1; }
    : > "$out" || { PROFILE_ERR="cannot write '$out'"; return 1; }
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        raw="${raw%$'\r'}"
        field=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*(use_template)[[:space:]]*=.*$/\1/p')
        if [ -z "$field" ]; then
            printf '%s\n' "$raw" >> "$out"
            continue
        fi
        val="${raw#*=}"
        first=1; ns=""
        local IFS_SAVE="$IFS"; IFS=','
        for part in $val; do
            IFS="$IFS_SAVE"
            part="${part#"${part%%[![:space:]]*}"}"; part="${part%"${part##*[![:space:]]}"}"
            [ -n "$part" ] || { PROFILE_ERR="$file:$n: empty template name in 'use_template'"; return 1; }
            local cand; cand="$(profile_ns_name "$prof" "$part")"
            case " $PROFILE_TEMPLATE_NAMES " in
                *" $cand "*) ;;
                *) PROFILE_ERR="$file:$n: 'use_template' names '$part', which profile '$prof' does not define -- a profile may not bind to a template it does not own"; return 1 ;;
            esac
            if [ "$first" -eq 1 ]; then ns="$cand"; first=0; else ns="$ns,$cand"; fi
            IFS=','
        done
        IFS="$IFS_SAVE"
        printf '\tuse_template = %s\n' "$ns" >> "$out"
    done < "$file"
    return 0
}

# The whole profile directory, which is what a runtime should call.
#
# A profile IS exactly three artifacts -- templates.conf, dataset.inc,
# prune.inc. That is Slice A's definition, not an open-ended directory format,
# so completeness is part of this contract and is checked HERE.
#
# REV-20260809-077 F1: the first version wrote `[ -f "$dir/x" ] && ! validate`,
# which reads as "if it exists and fails, complain" -- so a MISSING artifact
# returned success from the production boundary. An empty directory validated
# clean. Putting the completeness check in the caller instead would have
# recreated the exact problem REV-076 removed: a second piece of profile grammar
# living outside the one boundary that owns it.
profile_validate_dir() {   # <profile dir> <gen-cron.sh path>
    PROFILE_ERR=""
    local dir="$1" gen="$2" dump f
    [ -d "$dir" ] || { PROFILE_ERR="no such profile directory: $dir"; return 1; }

    # Completeness first: a profile missing a piece is not a smaller profile,
    # it is a broken one, and the message names the path so the operator is not
    # left guessing which of the three.
    for f in templates.conf dataset.inc prune.inc; do
        if [ ! -r "$dir/$f" ]; then
            PROFILE_ERR="$dir/$f is missing or unreadable -- a profile is exactly templates.conf, dataset.inc and prune.inc"
            return 1
        fi
    done

    dump="$(mktemp)" || { PROFILE_ERR="mktemp failed"; return 1; }
    if ! profile_schema_dump "$gen" "$dump"; then rm -f "$dump"; return 1; fi

    if ! profile_validate_templates "$dir/templates.conf" "$dump"; then rm -f "$dump"; return 1; fi
    if ! profile_validate_fragment dataset "$dir/dataset.inc" "$dump"; then rm -f "$dump"; return 1; fi
    if ! profile_validate_fragment prune   "$dir/prune.inc"   "$dump"; then rm -f "$dump"; return 1; fi

    rm -f "$dump"
    return 0
}
