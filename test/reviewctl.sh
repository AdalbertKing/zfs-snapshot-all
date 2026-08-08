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

# ---- commit-bearing headers must name something the reviewer can fetch -----
#
# REV-20260807-067 F1. A header that identifies a commit is a promise that the
# reviewer can fetch, diff and pin exactly the submitted change. A SHA that
# cannot be resolved breaks the one property Protocol V2 exists to provide.
#
# The check is REACHABILITY FROM THE PUBLISHED BRANCH, not mere resolvability,
# and that distinction is the whole finding. The SHA that triggered REV-067
# (c49afd2 on REV-066) DOES resolve in the implementer's clone -- it is a real
# commit, orphaned by a rewrite, whose content was published as 39663b2. A
# `git cat-file -e` check would have passed it and the reviewer would still
# have got "No commit found" from GitHub. Only "is it on the branch the
# reviewer reads" catches that, so that is what this asks.
#
# The publication ref is origin/main when a remote-tracking branch exists, and
# HEAD otherwise (a clone with no remote can still check internal coherence).
# GITREPO is the PROJECT repository, which is not always $REPO: REVIEWCTL_REPO
# relocates the ARTIFACT tree so the suite can build throwaway layouts, but the
# SHAs in those artifacts always name commits of the project. So resolve git
# from the relocated tree when it happens to be a checkout, and from this
# script's own location otherwise.
GITREPO=""
PUBREF=""
gitrepo() {
    [ -n "$GITREPO" ] && { echo "$GITREPO"; return; }
    if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
        GITREPO="$REPO"
    else
        GITREPO="$SCRIPT_DIR"
    fi
    echo "$GITREPO"
}
pubref() {
    [ -n "$PUBREF" ] && { echo "$PUBREF"; return; }
    if git -C "$(gitrepo)" rev-parse --verify -q origin/main >/dev/null 2>&1; then
        PUBREF=origin/main
    else
        PUBREF=HEAD
    fi
    echo "$PUBREF"
}

require_commit() {   # <rev> <field> <value>
    local rev="$1" field="$2" sha="$3" ref g
    # `-` is the protocol's explicit "no such commit yet", not a broken value.
    [ -z "$sha" ] && return 0
    [ "$sha" = "-" ] && return 0
    g="$(gitrepo)"
    # No git at all means the claim cannot be checked. Unverifiable is not the
    # same as verified -- the exact confusion REV-20260806-046 removed from the
    # alert-delivery verdict -- so it fails closed and says why.
    if ! git -C "$g" rev-parse --show-toplevel >/dev/null 2>&1; then
        err "$rev: $field names $sha but there is no git repository to resolve it against; refusing to publish an unverifiable commit reference"
        return 1
    fi
    ref="$(pubref)"
    if ! git -C "$g" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        err "$rev: $field names $sha, which is not a commit in this repository"
        return 1
    fi
    if ! git -C "$g" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
        err "$rev: $field names $sha, which is a commit but is not reachable from $ref -- unpushed, or rewritten and orphaned; point at the published commit that carries the whole delivery"
        return 1
    fi
    return 0
}

# ---- deliveries: direct-main work awaiting a first look --------------------
#
# REV-20260808-070 F4. Under the owner's direct-main exception the implementer
# lands first and the reviewer reviews what landed. But state here is derived
# from REV artifacts ONLY, so a delivery with no REV is invisible: on
# 2026-08-08 OPEN-THREADS.md said "nothing to do" while Stage 3 sat on main
# unreviewed, and the same had been true of Stages 2.1 and 2.2 until the
# reviewer happened to look. "He happened to look" is not a mechanism.
#
# One line per delivery, in docs/project/DELIVERIES.md:
#
#   <!-- delivered: <sha> <what it is> -->
#
# A delivery becomes reviewer-owned work until it is cleared, and clearing is
# explicit and deterministic -- never "it aged out":
#
#   * the reviewer opens a REV whose reviewed-implementation is that sha; or
#   * the reviewer records <!-- no-review-required: <sha> --> in the same file.
#
# The sha is held to the same published-branch reachability rule as an
# implementation sha, for the same reason: a reviewer who cannot fetch it
# cannot review it.
DELIVERIES="$REPO/docs/project/DELIVERIES.md"
declare -a DELIVERED=()
declare -A DELIVERED_WHAT=()
declare -A NO_REVIEW=()

collect_deliveries() {
    [ -f "$DELIVERIES" ] || return 0
    local line sha rest
    while IFS= read -r line; do
        case "$line" in
            '<!-- delivered: '*' -->')
                rest="${line#<!-- delivered: }"; rest="${rest% -->}"
                sha="${rest%% *}"
                [ -n "$sha" ] || continue
                require_commit "delivery" "delivered" "$sha" || true
                DELIVERED+=("$sha")
                DELIVERED_WHAT[$sha]="${rest#"$sha"}" ;;
            '<!-- no-review-required: '*' -->')
                sha="${line#<!-- no-review-required: }"; sha="${sha% -->}"
                [ -n "$sha" ] && NO_REVIEW[$sha]=1 ;;
        esac
    done < "$DELIVERIES"
}

# A delivery is open until a REV names it, or the reviewer waives it.
delivery_open() {   # <sha>
    local rev
    [ -n "${NO_REVIEW[$1]:-}" ] && return 1
    for rev in "${REVS[@]}"; do
        [ "${R_REVIEWED[$rev]:-}" = "$1" ] && return 1
    done
    return 0
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
        require_commit "$rev" reviewed-implementation "${R_REVIEWED[$rev]}" || true
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
        require_commit "$rev" implementation "${P_IMPL[$rev]}" || true
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
        require_commit "$rev" closed-by "${C_BY[$rev]}" || true
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
    local rev st any=0
    while IFS= read -r rev; do
        [ -n "$rev" ] || continue
        st="${STATE[$rev]}"
        [ "$st" = CLOSED ] && continue
        any=1
        printf '| %s | %s | %s | %s |
' "$rev" "$st" "$(owner_of "$st")" "$(next_of "$st")"
    done < <([ "${#REVS[@]}" -gt 0 ] && printf '%s
' "${REVS[@]}" | sort)
    local sha
    for sha in "${DELIVERED[@]+"${DELIVERED[@]}"}"; do
        delivery_open "$sha" || continue
        any=1
        printf '| %s | DELIVERED | Reviewer | review it, or open a REV for it |
'                "${sha:0:8}${DELIVERED_WHAT[$sha]}"
    done
    [ "$any" -eq 1 ] || echo "| _(nothing open)_ | - | - | - |"
    echo
    echo "Closed reviews are in \`docs/internal/reviews/REVIEW_LEDGER.md\`."
}

MODE=""
case "${1:-}" in
    --generate|--verify|--migrate) MODE="${1#--}" ;;
    *) echo "usage: $0 --generate | --verify | --migrate" >&2; exit 1 ;;
esac

collect
collect_deliveries
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
