#!/bin/bash
# reviewctl.sh -- REVIEW PROTOCOL V2: derive review state from machine facts.
#
# docs/project/PROTOCOL.md is the agreed design. The short version:
#
#   review / response / closure machine headers
#                 |
#                 v
#         REVIEW_LEDGER.md          <- generated, never typed
#                 |
#                 v
#         OPEN-THREADS.md           <- generated, never typed
#
# Why this exists at all: on 2026-08-07 four reviews were spent on our own
# bookkeeping (stale status, self-contradicting ledger, rule text disagreeing
# with its own checker, two files for one REV). The cause was coordination
# state kept as hand-maintained prose with checkers bolted on to police it.
# Nothing here polices prose. State is derived; a derived table cannot drift
# from the facts it is derived from.
#
#   ./test/reviewctl.sh --generate   write the ledger and routing view
#   ./test/reviewctl.sh --verify     regenerate and refuse any difference
#   ./test/reviewctl.sh --migrate    one-shot: canonicalise legacy artifacts
#
# Principle 17: this manages communication only. It never touches runtime code.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REVIEWCTL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RDIR="$REPO/docs/internal/reviews"
LEDGER="$RDIR/REVIEW_LEDGER.md"
THREADS="$REPO/docs/project/OPEN-THREADS.md"

ERRORS=0
err() { echo "reviewctl: $*" >&2; ERRORS=$((ERRORS+1)); }

# ---- machine-header reader --------------------------------------------------
# Deliberately anchored and whole-line: a header is a fact, not a phrase that
# happens to appear. Anything malformed is left EMPTY so the caller fails
# closed rather than inheriting a half-parsed value.
hdr() {   # <file> <field>
    sed -n "s|^<!-- $2: *\\([^ ][^>]*[^ ]\\) *-->$|\\1|p" "$1" 2>/dev/null | head -1
}

declare -A R_VERDICT R_REVIEWED R_FILE
declare -A P_STATUS P_IMPL P_FILE
declare -A C_BY C_FILE
declare -a REVS=()

seen_rev() { local r; for r in "${REVS[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }

collect() {
    local f rev
    for f in "$RDIR"/REV-*.md; do
        [ -f "$f" ] || continue
        # No header at all = pre-V2. Frozen by design, not broken: retrofitting
        # headers into reviewer-authored files would be the implementer editing
        # reviewer artifacts (Principle 3). Legacy history stays readable where
        # it is; the ledger describes V2 only.
        rev="$(hdr "$f" rev)"
        [ -z "$rev" ] && continue
        if [ -n "${R_FILE[$rev]:-}" ]; then
            err "duplicate review identity $rev: ${R_FILE[$rev]#$REPO/} and ${f#$REPO/}"
            continue
        fi
        R_FILE[$rev]="$f"
        R_VERDICT[$rev]="$(hdr "$f" verdict)"
        R_REVIEWED[$rev]="$(hdr "$f" reviewed-implementation)"
        case "${R_VERDICT[$rev]}" in
            APPROVED|CHANGES-REQUIRED) ;;
            *) err "$rev: verdict '${R_VERDICT[$rev]}' is not APPROVED or CHANGES-REQUIRED" ;;
        esac
        seen_rev "$rev" || REVS+=("$rev")
    done
    for f in "$RDIR"/responses/REV-*.md; do
        [ -f "$f" ] || continue
        rev="$(hdr "$f" rev)"
        [ -z "$rev" ] && continue          # pre-V2, see the note above
        [ -n "${P_FILE[$rev]:-}" ] && { err "duplicate response for $rev"; continue; }
        [ -n "${R_FILE[$rev]:-}" ] || err "orphan response: ${f#$REPO/} has no review"
        P_FILE[$rev]="$f"
        P_STATUS[$rev]="$(hdr "$f" response-status)"
        P_IMPL[$rev]="$(hdr "$f" implementation)"
        seen_rev "$rev" || REVS+=("$rev")
    done
    for f in "$RDIR"/closures/REV-*.md; do
        [ -f "$f" ] || continue
        rev="$(hdr "$f" rev)"
        [ -z "$rev" ] && continue          # pre-V2, see the note above
        [ -n "${C_FILE[$rev]:-}" ] && { err "duplicate closure for $rev"; continue; }
        [ -n "${R_FILE[$rev]:-}" ] || err "orphan closure: ${f#$REPO/} has no review"
        C_FILE[$rev]="$f"
        C_BY[$rev]="$(hdr "$f" closed-by)"
        [ -n "${C_BY[$rev]}" ] || err "$rev: closure artifact has no 'closed-by:'"
        seen_rev "$rev" || REVS+=("$rev")
    done
}

# States are computed ONCE, in the current shell, before anything renders.
#
# The first version called state_of() from inside the render loop, i.e. inside
# a command substitution -- so every err() it raised incremented a counter in a
# subshell that then exited, and an invalid closure produced a ledger with
# rc=0. A generator that fails open is worse than no generator, and this one
# was written to remove exactly that class of bug.
declare -A STATE=()
derive_all() {
    local rev
    for rev in "${REVS[@]}"; do STATE[$rev]="$(state_of_raw "$rev")"; done
    # state_of_raw cannot report errors upward from a subshell, so the invalid
    # combinations are re-checked here, in this shell, where err() sticks.
    for rev in "${REVS[@]}"; do
        if [ "${STATE[$rev]}" = INVALID ]; then
            err "$rev: closure artifact without a matching APPROVED verdict for the submitted implementation"
        fi
    done
}

# ---- Principle 6: deterministic derivation, in this order -------------------
state_of_raw() {   # <rev>  -> echoes STATE
    local rev="$1" v="${R_VERDICT[$1]:-}" ri="${R_REVIEWED[$1]:-}" im="${P_IMPL[$1]:-}"
    if [ -n "${C_FILE[$rev]:-}" ]; then
        # A closure is only valid on top of an approval of the submitted SHA.
        # Without this a closure artifact would be a way to declare victory.
        if [ "$v" = APPROVED ] && [ -n "$im" ] && [ "$ri" = "$im" ]; then
            echo CLOSED; return
        fi
        echo INVALID; return
    fi
    if [ "$v" = APPROVED ]; then
        if [ -n "$im" ] && [ "$ri" = "$im" ]; then echo APPROVED; return; fi
        # Approval that names a different SHA than the one currently submitted
        # is not approval of what is on the table.
        echo IMPLEMENTED; return
    fi
    # The one backward transition the protocol allows: the reviewer looked at
    # exactly this submission and rejected it, so the next move is Claude's.
    # Without this the generated routing would send the reviewer back to the
    # SHA they already rejected, and never route the correction to anyone
    # (REV-20260807-065 F1).
    if [ -n "$im" ] && [ "$ri" = "$im" ]; then echo OPEN; return; fi
    # A rejection of an OLDER sha does not reopen a newer submission: Claude has
    # already advanced, and that newer sha is genuinely awaiting review.
    [ -n "$im" ] && { echo IMPLEMENTED; return; }
    echo OPEN
}

owner_of() {   # <state>
    case "$1" in
        OPEN)        echo "Claude" ;;
        IMPLEMENTED) echo "Reviewer" ;;
        APPROVED)    echo "Reviewer" ;;
        CLOSED)      echo "-" ;;
        *)           echo "-" ;;
    esac
}

next_of() {
    case "$1" in
        OPEN)        echo "implement and respond" ;;
        IMPLEMENTED) echo "verify the submitted implementation" ;;
        APPROVED)    echo "write the closure artifact" ;;
        CLOSED)      echo "-" ;;
        *)           echo "INVALID -- see errors above" ;;
    esac
}

render_ledger() {
    echo "# REVIEW_LEDGER"
    echo
    echo "**GENERATED by \`./test/reviewctl.sh --generate\`. Do not edit.**"
    echo "State is derived from the machine headers in the review, response and"
    echo "closure artifacts; editing this file by hand only makes it disagree"
    echo "with them, which is the failure REVIEW PROTOCOL V2 exists to remove."
    echo
    echo "| REV | State | Owner | Implementation | Reviewed | Response | Next |"
    echo "|---|---|---|---|---|---|---|"
    [ "${#REVS[@]}" -eq 0 ] && { echo "| _(no V2 reviews yet)_ | - | - | - | - | - | - |"; return; }
    local rev st
    while IFS= read -r rev; do
        st="${STATE[$rev]}"
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
            "$rev" "$st" "$(owner_of "$st")" \
            "${P_IMPL[$rev]:--}" "${R_REVIEWED[$rev]:--}" \
            "$([ -n "${P_FILE[$rev]:-}" ] && echo "responses/$(basename "${P_FILE[$rev]}")" || echo "-")" \
            "$(next_of "$st")"
    done < <(printf '%s\n' "${REVS[@]}" | sort)
}

render_threads() {
    echo "# Open threads"
    echo
    echo "**GENERATED by \`./test/reviewctl.sh --generate\` from REVIEW_LEDGER.**"
    echo "Do not edit. Owner decisions that are not reviews live in"
    echo "\`docs/project/OWNER-DECISIONS.md\`."
    echo
    echo "| REV | State | Whose move | Next action |"
    echo "|---|---|---|---|"
    [ "${#REVS[@]}" -eq 0 ] && { echo "| _(no V2 reviews yet)_ | - | - | - |"; echo; echo "Closed reviews are in \`docs/internal/reviews/REVIEW_LEDGER.md\`."; return; }
    local rev st
    while IFS= read -r rev; do
        st="${STATE[$rev]}"
        [ "$st" = CLOSED ] && continue
        printf '| %s | %s | %s | %s |\n' "$rev" "$st" "$(owner_of "$st")" "$(next_of "$st")"
    done < <(printf '%s\n' "${REVS[@]}" | sort)
    echo
    echo "Closed reviews are in \`docs/internal/reviews/REVIEW_LEDGER.md\`."
}

MODE=""
case "${1:-}" in
    --generate|--verify|--migrate) MODE="${1#--}" ;;
    *) echo "usage: $0 --generate | --verify | --migrate" >&2; exit 1 ;;
esac

collect
derive_all
# An empty ledger is a legal starting state: V2 begins at the first REV that
# carries machine headers.
set +u

case "$MODE" in
    generate)
        [ "$ERRORS" -eq 0 ] || { echo "reviewctl: $ERRORS problem(s) -- refusing to generate from broken facts" >&2; exit 1; }
        render_ledger > "$LEDGER"
        render_threads > "$THREADS"
        echo "reviewctl: wrote ${LEDGER#$REPO/} and ${THREADS#$REPO/} (${#REVS[@]} reviews)"
        ;;
    verify)
        local_rc=0
        [ "$ERRORS" -eq 0 ] || local_rc=1
        t1="$(mktemp)"; t2="$(mktemp)"
        render_ledger > "$t1"; render_threads > "$t2"
        if ! diff -q "$t1" "$LEDGER" >/dev/null 2>&1; then
            echo "reviewctl: REVIEW_LEDGER.md differs from the facts:" >&2
            diff "$LEDGER" "$t1" 2>/dev/null | head -20 >&2
            local_rc=1
        fi
        if ! diff -q "$t2" "$THREADS" >/dev/null 2>&1; then
            echo "reviewctl: OPEN-THREADS.md differs from the ledger:" >&2
            diff "$THREADS" "$t2" 2>/dev/null | head -20 >&2
            local_rc=1
        fi
        rm -f "$t1" "$t2"
        [ "$local_rc" -eq 0 ] && echo "reviewctl: ledger and routing agree with the artifacts (${#REVS[@]} reviews)"
        exit "$local_rc"
        ;;
    migrate)
        echo "reviewctl: --migrate is a one-shot tool; see docs/project/PROTOCOL.md" >&2
        exit 1
        ;;
esac
