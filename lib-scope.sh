#!/bin/bash
###############################################################################
# lib-scope.sh -- the scope file: what a relationship replicates.
#
# WHAT THIS IS
#
# REV-20260802-033 moves the choice of datasets from the collector to the
# SOURCE, where the knowledge is. The source generates one editable file, a
# human edits it, the source grants from it, and the collector generates its
# jobs from the same bytes. One file, one representation of the choice.
#
# This library owns the grammar and the reader. It does not grant, does not
# generate cron lines and does not talk to a peer.
#
# WHY THE VALIDATORS LIVE HERE TOO
#
# `pc_is_dataset` and friends used to be defined inside deploy.sh, where they
# validate the pairing package. The scope file needs exactly the same rules --
# it arrives from another host and is read as data -- and a second correct
# implementation is still a second thing to keep correct. They moved here and
# deploy.sh sources this file; the package path is unchanged.
#
# THE SECURITY RULE, UNCHANGED FROM THE PACKAGE READER
#
# This file is UNTRUSTED STRUCTURED DATA, never code. No `source`, no `eval`, no
# arithmetic on its values. Unknown syntax fails CLOSED and the caller is
# expected to hand the operator back the same file to fix, not to restart the
# enrolment.
#
# GRAMMAR
#
#   [dataset:<pool/path>]
#       include_parent   = yes | no      # send the root dataset itself?
#       include_children = yes | no      # send its descendants?
#       exclude          = <pool/path>   # this dataset only, repeatable
#       exclude_tree     = <pool/path>   # this dataset and everything under it
#
# Anything else -- another section kind, another key, a blank value, a repeated
# section, an exclusion that lies outside every included root -- is a refusal
# with a line number.
#
# Deliberately NOT in this grammar: schedule, retention, templates, target,
# keys, ports. That is collector policy (U4). Dragging it here would make the
# source's administrator choose a GFS ladder in order to hand over two
# datasets, which is the opposite of the point.
###############################################################################

# ---- the one dataset-list grammar -------------------------------------------
#
# THE COMMA IS THE PACKAGE CONVENTION, and that is measured rather than chosen:
# both engines (snapsend.sh:1905, snapget.sh:1913), the destructive one
# (delsnaps.sh:942), the monitor (check-snap-age.sh:314), the generator
# (gen-cron.sh, four sites), lib-profile.sh and cron2conf.sh all split a
# user-supplied dataset list on ','. Nothing else was ever the convention.
#
# What diverged was the RELATIONSHIP path. `deploy.sh --peer-datasets` documented
# "A B" -- space separated -- because that is how the list is STORED internally
# (PEER_SAVED_DATASETS is written with "${array[*]}" and read back with an
# unquoted `for`). An internal representation leaked into the user-facing
# grammar, so the same package took commas from one command and spaces from the
# next. The one-command remote form was worse still: it took exactly ONE
# dataset and silently had no list grammar at all.
#
# So: one splitter, here, in the library both zfs-backup.sh and deploy.sh
# already source. It accepts commas AND whitespace deliberately -- that is not
# two conventions, it is one grammar being permissive on INPUT and canonical on
# OUTPUT. Permissive because the internal space-separated form and every
# manifest already written to disk must keep parsing; canonical because comma is
# what the package documents and what callers emit.
#
# Empty items are dropped and surrounding whitespace trimmed, so "a, b" and
# "a,,b" and "a b" all mean the same two datasets.
dataset_list_split() {   # <list> -> one item per line
    # printf '%s\n', not '%s': without the trailing newline `read` discards the
    # final item, so "a,b" silently became just "a". Caught by a probe that
    # tried every input shape rather than the one I had in mind.
    printf '%s\n' "${1-}" | tr ',' '\n' | while IFS= read -r _it; do
        _it="${_it#"${_it%%[![:space:]]*}"}"     # ltrim
        _it="${_it%"${_it##*[![:space:]]}"}"     # rtrim
        [ -n "$_it" ] || continue
        # A remaining internal space means the caller passed the stored form
        # ("a b"); split it the same way rather than inventing a dataset whose
        # name contains a space -- ZFS has none, so this is never ambiguous.
        printf '%s\n' $_it
    done
}

# The canonical rendering of a list for a HUMAN or for another command's
# argument. Storage keeps using "${array[*]}" (space) because that is what the
# manifests already contain and what the unquoted `for` loops read.
dataset_list_join() {   # <items...> -> comma-separated
    local out="" i
    for i in "$@"; do [ -n "$i" ] || continue; out="${out:+$out,}$i"; done
    printf '%s' "$out"
}

# ---- identifier validators (moved verbatim from deploy.sh) ------------------

pc_is_dataset() {
    local v="$1" comp rest
    case "$v" in
        ""|/*|*/) return 1 ;;
        *[!A-Za-z0-9_.:/-]*) return 1 ;;
        *//*) return 1 ;;
        -*) return 1 ;;   # first component would be read as an option
        .*) return 1 ;;   # and a pool does not begin with a dot
    esac
    rest="$v"
    while : ; do
        comp="${rest%%/*}"
        case "$comp" in
            ""|.|..) return 1 ;;
        esac
        [ "$rest" = "$comp" ] && break
        rest="${rest#*/}"
    done
    return 0
}
pc_is_account() {
    case "$1" in
        ""|*[!a-z0-9_-]*|[!a-z_]*) return 1 ;;
    esac
    [ "${#1}" -le 32 ] || return 1
    return 0
}
pc_is_label() {
    case "$1" in
        ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ] || return 1
    return 0
}
pc_is_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ---- the reader -------------------------------------------------------------
#
# Results, all keyed by the dataset path:
#
#   SCOPE_ROOTS[]              the included roots, in file order
#   SCOPE_PARENT[ds]           yes|no
#   SCOPE_CHILDREN[ds]         yes|no
#   SCOPE_EXCLUDE[ds]          newline-separated exact datasets
#   SCOPE_EXCLUDE_TREE[ds]     newline-separated subtree roots
#
# SCOPE_ERR carries the refusal, with a line number, because the operator is
# going back into an editor and "invalid config" is not a place to put a cursor.
scope_reset() {
    SCOPE_ROOTS=()
    declare -gA SCOPE_PARENT=() SCOPE_CHILDREN=() SCOPE_EXCLUDE=() SCOPE_EXCLUDE_TREE=()
    SCOPE_ERR=""
}

# Is <a> the same as, or under, <b>? Component-wise, never a string prefix:
# "rpool/data2" starts with "rpool/data" and is not under it.
scope_under() {   # <candidate> <ancestor>
    [ "$1" = "$2" ] && return 0
    case "$1" in "$2"/*) return 0 ;; esac
    return 1
}

scope_read() {   # <file>  -> 0 ok, 1 refused (SCOPE_ERR set)
    local file="$1"
    scope_reset
    [ -r "$file" ] || { SCOPE_ERR="cannot read the scope file '$file'"; return 1; }

    local n=0 line key val cur=""
    local -a excl_ds=() excl_ln=() excl_kind=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        # A package written on a CRLF box is a format problem to report, not a
        # thing to silently strip -- the same call deploy.sh's package reader
        # makes, and for the same reason: a file that looks fine in an editor
        # and parses differently here is worse than one that is refused.
        case "$line" in
            *$'\r') SCOPE_ERR="line $n has a carriage return -- this file must be plain LF text; it was probably edited on Windows"; return 1 ;;
        esac
        # Comments and blank lines. The generated file is mostly comments: the
        # full `zfs list` inventory lives there so the operator can copy entries
        # up into the active part.
        case "$line" in
            ''|'#'*) continue ;;
            [[:space:]]*'#'*) : ;;
        esac
        line="${line#"${line%%[![:space:]]*}"}"      # ltrim
        line="${line%"${line##*[![:space:]]}"}"      # rtrim
        case "$line" in ''|'#'*) continue ;; esac

        case "$line" in
            '['*']')
                local hdr="${line#[}"; hdr="${hdr%]}"
                case "$hdr" in
                    dataset:*) ;;
                    *:*) SCOPE_ERR="line $n: unknown section '[$hdr]' -- a scope file holds only [dataset:<path>] sections. Schedule, retention and target belong to the collector, not here"; return 1 ;;
                    *)   SCOPE_ERR="line $n: malformed section header '[$hdr]' -- expected [dataset:<path>]"; return 1 ;;
                esac
                cur="${hdr#dataset:}"
                pc_is_dataset "$cur" \
                    || { SCOPE_ERR="line $n: '$cur' is not a valid dataset name"; return 1; }
                [ -n "${SCOPE_PARENT[$cur]:-}" ] \
                    && { SCOPE_ERR="line $n: [dataset:$cur] appears twice -- which one would apply is a guess, so it is refused"; return 1; }
                SCOPE_ROOTS+=("$cur")
                # Defaults are the review's defaults (F2/§7): a root is a
                # container, its children are the payload.
                SCOPE_PARENT[$cur]=no
                SCOPE_CHILDREN[$cur]=yes
                SCOPE_EXCLUDE[$cur]=""
                SCOPE_EXCLUDE_TREE[$cur]=""
                ;;
            *=*)
                [ -n "$cur" ] \
                    || { SCOPE_ERR="line $n: '$line' comes before any [dataset:] section"; return 1; }
                key="${line%%=*}"; val="${line#*=}"
                key="${key%"${key##*[![:space:]]}"}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                case "$key" in
                    include_parent|include_children)
                        case "$val" in
                            yes|no) ;;
                            '') SCOPE_ERR="line $n: '$key' is blank -- a blank field is not a default, it is a question nobody answered (say yes or no)"; return 1 ;;
                            *)  SCOPE_ERR="line $n: '$key = $val' -- expected yes or no"; return 1 ;;
                        esac
                        [ "$key" = include_parent ] && SCOPE_PARENT[$cur]="$val" || SCOPE_CHILDREN[$cur]="$val"
                        ;;
                    exclude|exclude_tree)
                        [ -n "$val" ] \
                            || { SCOPE_ERR="line $n: '$key' is blank -- remove the line, or name a dataset"; return 1; }
                        pc_is_dataset "$val" \
                            || { SCOPE_ERR="line $n: '$val' is not a valid dataset name"; return 1; }
                        excl_ds+=("$val"); excl_ln+=("$n"); excl_kind+=("$key")
                        if [ "$key" = exclude ]; then
                            SCOPE_EXCLUDE[$cur]="${SCOPE_EXCLUDE[$cur]}${SCOPE_EXCLUDE[$cur]:+$'\n'}$val"
                        else
                            SCOPE_EXCLUDE_TREE[$cur]="${SCOPE_EXCLUDE_TREE[$cur]}${SCOPE_EXCLUDE_TREE[$cur]:+$'\n'}$val"
                        fi
                        ;;
                    *)
                        SCOPE_ERR="line $n: unknown key '$key' -- a scope file knows include_parent, include_children, exclude and exclude_tree"
                        return 1
                        ;;
                esac
                ;;
            *)
                SCOPE_ERR="line $n: '$line' is neither a section header nor a key = value"
                return 1
                ;;
        esac
    done < "$file"

    [ "${#SCOPE_ROOTS[@]}" -gt 0 ] \
        || { SCOPE_ERR="the scope file selects nothing -- every [dataset:] section is commented out. Nothing would be replicated and no job would be installed"; return 1; }

    # An exclusion outside every included root is a typo, and the only moment it
    # is cheap to catch is now. Left to run, it would simply never match, and
    # the operator would find out from a backup that quietly contains more than
    # they meant.
    local i r found
    for i in "${!excl_ds[@]}"; do
        found=0
        for r in "${SCOPE_ROOTS[@]}"; do
            scope_under "${excl_ds[$i]}" "$r" && { found=1; break; }
        done
        [ "$found" -eq 1 ] || {
            SCOPE_ERR="line ${excl_ln[$i]}: ${excl_kind[$i]} = ${excl_ds[$i]} lies outside every [dataset:] section in this file, so it would never match anything"
            return 1
        }
    done
    return 0
}

# Does the scope include <dataset>? Pure decision, no ZFS: the caller supplies
# the names (from `zfs list` on the source), this answers yes or no.
#
# Order matters and is the operator's mental model: an exclusion beats an
# inclusion, and the most specific root wins.
scope_includes() {   # <dataset>  -> 0 yes, 1 no
    local ds="$1" r x best=""
    for r in "${SCOPE_ROOTS[@]}"; do
        scope_under "$ds" "$r" || continue
        [ "${#r}" -gt "${#best}" ] && best="$r"
    done
    [ -n "$best" ] || return 1

    while IFS= read -r x; do
        [ -n "$x" ] || continue
        [ "$ds" = "$x" ] && return 1
    done <<< "${SCOPE_EXCLUDE[$best]}"
    while IFS= read -r x; do
        [ -n "$x" ] || continue
        scope_under "$ds" "$x" && return 1
    done <<< "${SCOPE_EXCLUDE_TREE[$best]}"

    if [ "$ds" = "$best" ]; then
        [ "${SCOPE_PARENT[$best]}" = yes ] && return 0 || return 1
    fi
    [ "${SCOPE_CHILDREN[$best]}" = yes ] && return 0 || return 1
}
