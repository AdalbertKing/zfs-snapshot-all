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
# THE RENDERER'S OWN VERSION, and it is part of what a relationship was
# generated FROM.
#
# REV F2b. profile_digest first covered profile.conf and gen-cron's tier-letter
# table -- the operator's file and the table that turns `keep = 24` into -H24.
# That still misses this file: change how a fragment is rendered, how a template
# is namespaced, or how a keep is translated, and the installed CONFIG changes
# while profile.conf and the table do not. The digest would call that unchanged
# and migrate-profile would answer "nothing to migrate".
#
# BUMP THIS whenever a change here alters what the same profile.conf renders to.
# Not a hash of the file: a hash would move on a comment edit and force a
# pointless migration across the fleet. A number a human sets is the honest
# instrument, because only a human knows whether the OUTPUT changed.
PROFILE_RENDER_SCHEMA=1

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
#
# and the SCOPE fields split out of 'flags' on 2026-08-31 (gen-cron.sh,
# add_scope_flags):
#
#   passive            what this relationship TAKES from its source: whether it
#   exclude_family     authors snapshots or adopts a family somebody else
#   exclude_child_<n>  stamps, which families it refuses, which children it
#                      leaves behind. Naming them is what empties the identity
#                      sack; it must not, in the same change, hand them to a
#                      layer that has no way to be overridden per relationship.
#                      PROFILE-VARIABLE-INVENTORY.md argues these are the
#                      natural home for a profile DEFAULT, and that is a later
#                      change with its own prerequisites -- a template layer to
#                      inherit from, and a CLI that can distinguish "the
#                      operator said no" from "the operator said nothing".
#                      Forbidding is the reversible direction.
PROFILE_FORBIDDEN_FIELDS='src dst flags pair_label notify bandwidth compression cipher passive exclude_family'

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
    # exclude_child_<n> is numbered, so it cannot be a word in the list above. Without
    # this arm it would still be refused -- gen-cron's --dump-fields enumerates
    # static names only, so the schema check upstream reports it as "not a
    # dataset field in CONFIG v4" -- but that message sends the reader looking
    # for a typo in a field they spelled correctly.
    case "$f" in
        exclude_child_*) case "${f#exclude_child_}" in ""|*[!0-9]*) ;; *) return 0 ;; esac ;;
    esac
    return 1
}

# One line of a profile-owned stanza, in a known section kind.
profile_check_field() {   # <kind> <field> <schema dump> <where>
    local kind="$1" field="$2" dump="$3" where="$4"
    # OWNERSHIP BEFORE SPELLING. Both checks can fire on one field, and when
    # they do the ownership answer is the useful one: it tells the operator the
    # field is not theirs to write here, instead of sending them to look for a
    # typo in a name they spelled correctly. exclude_child_<n> is the case that made
    # the order matter -- it is numbered, so --dump-fields (which enumerates
    # static names) does not list it, and the schema check reported a correctly
    # spelled field as unknown.
    if profile_field_forbidden "$field"; then
        PROFILE_ERR="$where: '$field' is relationship-owned and must not appear in a profile (REV-20260808-073)"
        return 1
    fi
    if ! grep -qxF "$kind $field" "$dump"; then
        PROFILE_ERR="$where: '$field' is not a $kind field in CONFIG v4"
        return 1
    fi
    # Recursion is TOPOLOGY -- which datasets a relationship covers and whether
    # its subtree is re-expanded at every run. That is the deployment's answer,
    # recorded at enrolment (RECURSION, PEER_SAVED_RECURSIVE_ROOTS); a profile
    # cannot know whether the source it is about to be applied to is a subtree
    # root at all.
    #
    # The [prune:] half of this rule has been here since REV-20260808-073. The
    # [dataset:] half was missing, and its absence was read (in
    # docs/project/PROFILE-VARIABLE-INVENTORY.md, 2026-08-24) as a ready place
    # for a profile default -- "the archival profile is flat". Measured
    # 2026-08-31, it was a landmine instead:
    #
    #   1. a profile carrying `recursive` in its [dataset] block VALIDATES;
    #   2. emit_client_sections pastes the profile fragment into the section and
    #      then writes its own `recursive` line for a recursive root, so the
    #      section carries the field TWICE;
    #   3. gen-cron refuses a duplicate field outright, naming the duplicate and
    #      not the profile that caused it.
    #
    # So the profile was not defaulting anything: it was bricking every
    # recursive relationship created from it. Refusing it at validation is the
    # answer the [prune:] half already gives, and it names the real cause.
    if [ "$field" = recursive ]; then
        PROFILE_ERR="$where: a profile may not set 'recursive' on a $kind section -- recursion is the relationship's topology, chosen at enrolment, and a profile does not know whether its source is a subtree root"
        return 1
    fi
    # POLICY GOES IN A [template:], NOT IN A FRAGMENT -- the general form of the
    # rule above, and the reason `recursive` needs its own line (it has no
    # template layer, so it falls outside this one).
    #
    # A profile's [dataset]/[prune] block is pasted verbatim into every section
    # the profile creates. Any field with a template layer put there is wrong
    # twice over, and both were measured on 2026-08-31 with the real
    # emit_client_sections:
    #
    #   * it COLLIDES. `send_schedule = 7 * * * *` in a [dataset] fragment
    #     produced a section carrying both it and the staggered minute the
    #     relationship writes -- `send_schedule = 7 * * * *` and
    #     `send_schedule = 2 * * * *`, one after the other -- and gen-cron
    #     refuses a duplicate field. Unlike the `recursive` case this hits EVERY
    #     relationship, because the stagger always writes a minute;
    #
    #   * and it FLATTENS. A section-level value overrides every tier the
    #     section names, so a profile with four cadences would collapse to one.
    #     That is the same boundary the schedule stagger hit
    #     (PROFILE-VARIABLE-INVENTORY.md section 4).
    #
    # The check is derived from gen-cron's own allow-lists rather than from a
    # list kept here: if the field exists at the template layer, that is where
    # it belongs. Nothing to keep in step, and a new policy field is covered the
    # day gen-cron declares it.
    if [ "$kind" = dataset ] || [ "$kind" = prune ]; then
        if grep -qxF "template $field" "$dump"; then
            PROFILE_ERR="$where: '$field' is policy and belongs in one of this profile's [template:] sections, not in its [$kind] block -- a value here is pasted into every section the profile creates, where it overrides every tier that section names and collides with the line the relationship writes for itself"
            return 1
        fi
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
    local file="$1" dump="$2" raw field n=0 in_section=0 seen_excluded=""
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
            '[excluded:'*']')
                # The reserved-family floors. They were a hardcoded list in
                # zfs-backup.sh -- "__replicate_", "vzdump", "__migration__",
                # keep=2 -- which meant the one thing every deployment on this
                # estate carries was the one thing no profile could describe,
                # and "what does a default deployment actually do" could not be
                # answered by reading the profile.
                #
                # A prefix is NOT namespaced the way a template name is. These
                # sections are config-wide policy shared by every relationship
                # in the file, and two profiles naming the same family mean the
                # same family -- rewriting the name would produce two floors
                # for one thing. So the check is on what a section header can
                # carry, not profile_component_ok.
                field="${raw#\[excluded:}"; field="${field%\]}"
                case "$field" in
                    '')          PROFILE_ERR="$file:$n: [excluded:] with no prefix"; return 1 ;;
                    *'['*|*']'*) PROFILE_ERR="$file:$n: '$field' is not usable in a section header"; return 1 ;;
                esac
                # One profile cannot fence one family twice. The runtime refuses
                # two PROFILES that disagree about a family; a profile
                # disagreeing with ITSELF is the same fault caught earlier and
                # more cheaply, and it names the file instead of the composed
                # temporary the generator would complain about.
                case " $seen_excluded " in
                    *" $field "*) PROFILE_ERR="$file:$n: '[excluded:$field]' appears twice in this profile -- one config cannot fence a family two ways"; return 1 ;;
                esac
                seen_excluded="$seen_excluded $field"
                in_section=2
                continue ;;
            '['*)
                PROFILE_ERR="$file:$n: only [template:NAME] and [excluded:PREFIX] sections belong in a profile, got '$raw'"
                return 1 ;;
        esac
        if [ "$in_section" -eq 0 ]; then
            PROFILE_ERR="$file:$n: '$raw' appears before any [template:NAME] or [excluded:PREFIX] section"
            return 1
        fi
        field=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=.*$/\1/p')
        [ -n "$field" ] || { PROFILE_ERR="$file:$n: not a 'field = value' line"; return 1; }
        # Each kind against its own schema: [excluded:] takes `keep` and nothing
        # else, and checking it against the template field list would accept
        # every policy field there is.
        if [ "$in_section" -eq 2 ]; then
            profile_check_field excluded "$field" "$dump" "$file:$n" || return 1
        else
            profile_check_field template "$field" "$dump" "$file:$n" || return 1
        fi
    done < "$file"
    [ "$in_section" -ne 0 ] || { PROFILE_ERR="$file: no [template:NAME] section found"; return 1; }
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

# TWO KINDS OF SECTION COMPOSE IN TWO DIFFERENT WAYS, and putting them in one
# output file broke the scheme the moment profiles gained [excluded:].
#
#   [template:NAME]     NAMESPACED. Two profiles may define the same name and
#                       both survive, so rendered files CONCATENATE -- that is
#                       the property the whole namespace exists for.
#   [excluded:PREFIX]   SHARED. Config-wide policy, deliberately not renamed,
#                       because two profiles naming __replicate_ mean the same
#                       __replicate_. Concatenating two renders would emit the
#                       section twice, and gen-cron refuses duplicates.
#
# So they go to different outputs. The excluded file is consumed by the floor
# installer, which appends only what the config lacks; the templates file stays
# concatenation-safe, exactly as it was before this field existed.
profile_render_templates() {   # <templates file> <profile> <outfile> [excluded outfile] [tier letters]
    PROFILE_ERR=""; PROFILE_TEMPLATE_NAMES=""
    local file="$1" prof="$2" out="$3" excl_out="${4:-}" letters="${5:-}" raw name ns n=0 in_excl=0 canon=""
    profile_name_ok "$prof" || { PROFILE_ERR="profile name '$prof' is not usable in a section header (letters, digits, _ and - only)"; return 1; }
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile templates '$file'"; return 1; }
    : > "$out" || { PROFILE_ERR="cannot write '$out'"; return 1; }
    if [ -n "$excl_out" ]; then
        : > "$excl_out" || { PROFILE_ERR="cannot write '$excl_out'"; return 1; }
    fi
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        raw="${raw%$'\r'}"
        case "$raw" in
            '[excluded:'*']')
                # Shared, not namespaced -- so it must not reach the file that
                # gets concatenated with another profile's.
                in_excl=1
                [ -n "$excl_out" ] && printf '%s\n' "$raw" >> "$excl_out"
                continue ;;
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
                in_excl=0
                canon="$name"
                printf '[template:%s]\n' "$ns" >> "$out" ;;
            *)
                if [ "$in_excl" -eq 1 ]; then
                    [ -n "$excl_out" ] && printf '%s\n' "$raw" >> "$excl_out"
                else
                    # `keep = N` inside a TEMPLATE is the ergonomic spelling and
                    # is translated here, while the canonical (pre-namespace)
                    # name is still known. Inside [excluded:] `keep` means
                    # something else entirely -- a floor count, no cadence, no
                    # letter -- which is why this branch is the template one.
                    local _k _kv
                    _k="$(printf '%s' "$raw" | sed -n -E 's/^[[:space:]]*keep[[:space:]]*=[[:space:]]*(.*)$/\1/p')"
                    if [ -n "$_k" ] && [ -n "$letters" ] && [ -n "$canon" ]; then
                        _kv="$(profile_keep_to_retain "$canon" "${_k%%[[:space:]]*}" "$letters")" || return 1
                        printf '\tretain         = %s\n' "$_kv" >> "$out"
                    else
                        printf '%s\n' "$raw" >> "$out"
                    fi
                fi ;;
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
###############################################################################
# ONE FILE, NATIVE NAMES -- profiles/<name>/profile.conf
#
# Owner decision 2026-08-25: one operator-facing file, and no new vocabulary.
# The three internal artifacts (templates / dataset fragment / prune fragment)
# remain, but as a COMPILATION TARGET rather than as the thing an operator
# writes. Nobody should have to know that a profile is three files to change a
# retention.
#
# WHY THE NAMES STAY NATIVE. The alternative on the table was a dedicated
# dialect (`[tier:hourly]`, `create_schedule`, `[protect:]`). It reads well and
# it was rejected for two measured reasons:
#
#   * a second vocabulary is a second field list to keep in step with
#     `gen-cron.sh --dump-fields`, and drift of exactly that kind is what
#     REV-054 and the REV-074 follow-up already cost this tree;
#   * `[tier:]` FUSES creation with retention, and the built-in `default`
#     cannot be written that way at all: it creates ONE family
#     (`automated_hourly_`) and prunes it with FOUR counters (-H24 -D7 -W4
#     -M12) in a single GFS ladder call. A shape where a tier owns its own
#     prefix and its own retention can describe production, and cannot
#     describe `default`.
#
# WHAT WAS TAKEN FROM THE DIALECT PROPOSAL: the single file, an explicit
# `[profile]` header with a version, and the ergonomic `keep = 24` -- which is
# translated here rather than pushed into the generator, see
# profile_keep_to_retain.
#
# SECTION KINDS AND HOW EACH COMPOSES:
#
#   [profile]            metadata. Never emitted into a config.
#   [template:NAME]      native template. NAMESPACED -> rendered files may be
#                        concatenated with another profile's.
#   [dataset]            defaults copied into every [dataset:] this profile
#   [prune]              creates; likewise for [prune:]. Pathless on purpose:
#                        the path belongs to the relationship, never here.
#   [excluded:PREFIX]    config-wide floor. SHARED, never namespaced -> two
#                        profiles naming __replicate_ mean the same family, so
#                        these compose by AGREEMENT, not by concatenation.
#
# Splits one profile.conf into the four artifacts the runtime already consumes.
# Validation is unchanged in kind: every field is still checked against
# gen-cron's own schema for its section kind, and the forbidden list still
# refuses identity, topology and link values.
profile_split_one_file() {   # <profile.conf> <tpl out> <ds out> <prune out> <excl out>
    PROFILE_ERR=""
    local file="$1" tpl="$2" dso="$3" pro="$4" exo="$5" raw kind="" n=0 seen_tpl=0
    [ -r "$file" ] || { PROFILE_ERR="cannot read profile '$file'"; return 1; }
    : > "$tpl"; : > "$dso"; : > "$pro"; : > "$exo"
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        raw="${raw%$'\r'}"
        case "$raw" in
            '#'*) continue ;;
        esac
        [ -z "${raw//[[:space:]]/}" ] && continue
        case "$raw" in
            '[profile]')        kind=meta;     continue ;;
            '[dataset]')        kind=dataset;  continue ;;
            '[prune]')          kind=prune;    continue ;;
            '[template:'*']')   kind=template; seen_tpl=1; printf '%s\n' "$raw" >> "$tpl"; continue ;;
            '[excluded:'*']')   kind=excluded;                printf '%s\n' "$raw" >> "$exo"; continue ;;
            '['*)
                PROFILE_ERR="$file:$n: '$raw' is not a section a profile may carry ([profile], [template:NAME], [dataset], [prune], [excluded:PREFIX])"
                return 1 ;;
        esac
        case "$kind" in
            "")       PROFILE_ERR="$file:$n: '$raw' appears before any section"; return 1 ;;
            meta)     continue ;;
            template) printf '%s\n' "$raw" >> "$tpl" ;;
            # The two FRAGMENTS are bare stanza lines, never sections, and the
            # emitter indents them when it pastes them into a real section. The
            # indentation this file carries for readability is stripped here --
            # left in, it would arrive doubled.
            dataset)  printf '%s\n' "${raw#"${raw%%[![:space:]]*}"}" >> "$dso" ;;
            prune)    printf '%s\n' "${raw#"${raw%%[![:space:]]*}"}" >> "$pro" ;;
            excluded) printf '%s\n' "$raw" >> "$exo" ;;
        esac
    done < "$file"
    [ "$seen_tpl" -eq 1 ] || { PROFILE_ERR="$file: no [template:NAME] section found"; return 1; }
    return 0
}

# `keep = 24` on a profile template -> `retain = -H24`.
#
# The ergonomics are the reviewer's and they are right: `keep = 24` is what the
# production config already says, and it reads better than a flag letter. The
# reason the generator cannot do it for a profile is mechanical -- it derives
# the letter from the tier NAME, and a profile's names are namespaced
# (`profile__default__keep_hourly`) long before they get there.
#
# So it is derived HERE, from the canonical name, using gen-cron's own table
# (`--dump-tier-letters`) rather than a copy of it. The cadence is the LAST
# underscore-separated component, which is true of every built-in name
# (`keep_hourly`, `standard_hourly`, `hourly`).
#
# Fail closed: a name whose last component is not a known cadence is REFUSED,
# naming the alternative. Guessing a letter would silently apply the wrong
# counter to a retention ladder, which is the kind of mistake that is invisible
# until a restore needs the snapshot that was never kept.
profile_keep_to_retain() {   # <canonical template name> <keep value> <letters file> -> retain
    PROFILE_ERR=""
    local name="$1" keep="$2" letters="$3" cadence letter
    case "$keep" in
        ''|*[!0-9]*) PROFILE_ERR="keep='$keep' on '[template:$name]' is not a count"; return 1 ;;
    esac
    cadence="${name##*_}"
    letter="$(awk -v c="$cadence" '$1==c {print $2; exit}' "$letters")"
    if [ -z "$letter" ]; then
        PROFILE_ERR="'[template:$name]' uses 'keep = $keep', and the retention letter is derived from the tier cadence -- '$cadence' is not one gen-cron knows ($(awk '{printf "%s ", $1}' "$letters")). Name the tier for its cadence, or write 'retain = -<LETTER>$keep' explicitly"
        return 1
    fi
    printf -- '-%s%s' "$letter" "$keep"
    return 0
}

# A PROFILE IS A FILE. Not a directory holding one file -- that shape was left
# over from when a profile really was three (templates.conf, dataset.inc,
# prune.inc). They collapsed into one on 2026-08-25 and the directory stayed on
# out of habit, which is a wrapper around nothing.
profile_validate_file() {   # <profile file> <gen-cron.sh path>
    PROFILE_ERR=""
    local file="$1" gen="$2" dump f
    # -f, NOT just -r. A DIRECTORY is readable, so an -r test waved one straight
    # through and the failure surfaced further in as `read: Is a directory` from
    # the splitter -- a crash where a sentence belonged. It is not a hypothetical
    # input either: it is exactly what the previous layout put on disk, and
    # anyone with a host still carrying profiles/<name>/ will type it.
    if [ -d "$file" ]; then
        PROFILE_ERR="$file is a directory -- a profile is a single file. The old layout kept it as <name>/profile.conf; point at that file, or at <name>.conf"
        return 1
    fi
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        PROFILE_ERR="$file is missing or unreadable -- a profile is exactly that one file"
        return 1
    fi

    dump="$(mktemp)" || { PROFILE_ERR="mktemp failed"; return 1; }
    if ! profile_schema_dump "$gen" "$dump"; then rm -f "$dump"; return 1; fi

    # Guarded, one by one. The first cut allocated these four with no check, so
    # a failing mktemp handed the splitter empty paths and validation carried on
    # against files that were never created -- a profile would have "validated"
    # because nothing could be read. Caught by the allocation-failure control in
    # test/zfsbackup, which injects exactly that.
    local vt vd vp ve
    vt="$(mktemp)" || { PROFILE_ERR="mktemp failed"; rm -f "$dump"; return 1; }
    vd="$(mktemp)" || { PROFILE_ERR="mktemp failed"; rm -f "$dump" "$vt"; return 1; }
    vp="$(mktemp)" || { PROFILE_ERR="mktemp failed"; rm -f "$dump" "$vt" "$vd"; return 1; }
    ve="$(mktemp)" || { PROFILE_ERR="mktemp failed"; rm -f "$dump" "$vt" "$vd" "$vp"; return 1; }
    if ! profile_split_one_file "$file" "$vt" "$vd" "$vp" "$ve"; then
        rm -f "$dump" "$vt" "$vd" "$vp" "$ve"; return 1
    fi
    # The excluded sections are validated together with the templates: they are
    # both "sections a profile may own", and profile_validate_templates already
    # knows the difference between the two kinds.
    cat "$ve" >> "$vt"
    if ! profile_validate_templates "$vt" "$dump"; then rm -f "$dump" "$vt" "$vd" "$vp" "$ve"; return 1; fi
    if ! profile_validate_fragment dataset "$vd" "$dump"; then rm -f "$dump" "$vt" "$vd" "$vp" "$ve"; return 1; fi
    if ! profile_validate_fragment prune   "$vp" "$dump"; then rm -f "$dump" "$vt" "$vd" "$vp" "$ve"; return 1; fi

    rm -f "$dump" "$vt" "$vd" "$vp" "$ve"
    return 0
}
