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

# Fields a profile must never carry, whatever the schema permits.
#
#   src, dst   topology -- the relationship's, not the policy's
#   flags      raw engine flags: an escape hatch around every native field
#   pair_label relationship identity
#   notify     relationship-owned notification routing
PROFILE_FORBIDDEN_FIELDS='src dst flags pair_label notify'

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
