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
# REVIEWCTL_PUBREF may name a prospective publication ref, notably HEAD in PR
# CI. That lets one PR carry both a response and the derived routing views even
# though its implementation commit is, correctly, not reachable from main yet.
# The override changes only the reachability vantage point; canonical
# publication still requires a post-merge read-back from main.
# GITREPO is the PROJECT repository, which is not always $REPO: REVIEWCTL_REPO
# relocates the ARTIFACT tree so the suite can build throwaway layouts, but the
# SHAs in those artifacts always name commits of the project. So resolve git
# from the relocated tree when it happens to be a checkout, and from this
# script's own location otherwise.
GITREPO=""
PUBREF="${REVIEWCTL_PUBREF:-}"
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
    local ref="$PUBREF" g
    g="$(gitrepo)"
    if [ -z "$ref" ]; then
        if git -C "$g" rev-parse --verify -q origin/main >/dev/null 2>&1; then
            ref=origin/main
        else
            ref=HEAD
        fi
    fi
    git -C "$g" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 \
        || { echo "reviewctl: publication ref '$ref' does not resolve to a commit" >&2; return 1; }
    echo "$ref"
}

# REV-20260809-080 F1. A commit-bearing header must be CANONICAL before any
# equality decision is made about it, and that is a separate property from
# "does git resolve it".
#
# The failure was real, not synthetic. REV-078's response carried
# `implementation: dc1c038` while the approval carried the full 40-char SHA of
# the SAME commit. require_commit passed it -- git resolves an unambiguous
# abbreviation -- and then state_of_raw() compared the two header STRINGS,
# found them different, and derived IMPLEMENTED from an approval that had
# already been granted. rc=0 throughout. OPEN-THREADS routed the thread back to
# the reviewer, who had already done the work.
#
# Rejection rather than canonicalisation, per the review's stated preference:
# these files are long-lived audit facts, not interactive git input, and an
# abbreviation that is unambiguous today can become ambiguous as the repository
# grows. Canonicalising would also silently rewrite what an artifact says.
canonical_sha() {   # <rev> <field> <value> -> 0 canonical
    local rev="$1" field="$2" sha="$3"
    case "$sha" in
        *[!0-9a-f]*)
            err "$rev: $field names '$sha', which is not a lowercase 40-character commit id -- protocol headers are durable audit facts and must be canonical"
            return 1 ;;
    esac
    if [ "${#sha}" -ne 40 ]; then
        err "$rev: $field names '$sha', an abbreviated commit id (${#sha} chars) -- write the full 40-character SHA, or state equality cannot be decided (REV-20260809-080)"
        return 1
    fi
    return 0
}

require_commit() {   # <rev> <field> <value>
    local rev="$1" field="$2" sha="$3" ref g
    # `-` is the protocol's explicit "no such commit yet", not a broken value.
    [ -z "$sha" ] && return 0
    [ "$sha" = "-" ] && return 0
    canonical_sha "$rev" "$field" "$sha" || return 1
    g="$(gitrepo)"
    # No git at all means the claim cannot be checked. Unverifiable is not the
    # same as verified -- the exact confusion REV-20260806-046 removed from the
    # alert-delivery verdict -- so it fails closed and says why.
    if ! git -C "$g" rev-parse --show-toplevel >/dev/null 2>&1; then
        err "$rev: $field names $sha but there is no git repository to resolve it against; refusing to publish an unverifiable commit reference"
        return 1
    fi
    if ! ref="$(pubref)"; then
        err "$rev: cannot validate $field against the publication ref"
        return 1
    fi
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
                # REV-20260809-080 F1, requirement 4: these two markers CLEAR a
                # delivery by matching its sha as an array key, so an
                # abbreviated one silently clears nothing and the delivery
                # stays open forever with no error. Same class as the
                # implementation/reviewed-implementation comparison, and it was
                # not even reachability-checked before.
                [ -n "$sha" ] || continue
                require_commit "delivery" "no-review-required" "$sha" || true
                NO_REVIEW[$sha]=1 ;;
            '<!-- reviewed-by: '*' -->')
                # A delivery that WAS reviewed, recorded explicitly.
                #
                # Found by using the mechanism: clearing originally depended on
                # some REV currently naming the sha in reviewed-implementation.
                # That header is a MOVING POINTER -- the reviewer advances it to
                # each new submission -- so once a thread progressed past the
                # delivered commit, the delivery reappeared as unreviewed and
                # would have done so forever. "It was reviewed" is a fact about
                # the past and has to be recorded as one.
                rest="${line#<!-- reviewed-by: }"; rest="${rest% -->}"
                sha="${rest%% *}"
                [ -n "$sha" ] || continue
                require_commit "delivery" "reviewed-by" "$sha" || true
                NO_REVIEW[$sha]=1 ;;
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

# =============================================================================
# TRANSACTIONAL LIFECYCLE WRITERS (consensus of 2026-08-14)
#
# REV-120/121 ended with prose on canonical main saying APPROVED and CLOSED while
# the machine headers said CHANGES-REQUIRED against a superseded implementation,
# and with `closed-by` naming a person. The parser refused to derive from that --
# correctly, and far too late, because the contradiction was already published.
#
# --generate cannot prevent it: by the time it runs, someone has already
# hand-edited the facts. So the facts get a writer, and the writer is the only
# thing that has to be right.
#
# The shape is deliberately narrow:
#
#   approve REV --implementation SHA  --expected-parent SHA
#   close   REV --approval-commit SHA --expected-parent SHA
#
# Two operations, never one. A single approve+close call is what produced the
# REV-120/121 state, so the tool cannot express it: `close` requires an approval
# commit that ALREADY exists on the published branch and that provably carried the
# approval, which a combined operation could not have.
#
# Every write is a transaction. Files are snapshotted, mutated, the derived views
# are regenerated and verified by re-invoking this script's own tested paths, and
# any failure restores every byte. The index is never touched at all -- this
# stages nothing, so a refusal cannot leave a half-prepared commit either.
#
# What this does NOT do, and must not be described as doing: it does not gate
# canonical main. Nothing stops a caller from hand-editing and pushing exactly as
# before. That gate is the GitHub branch protection the Owner has yet to enable,
# and until it is measured nobody may call the invariant enforced.
# =============================================================================

TXDIR=""
tx_cleanup() { [ -n "$TXDIR" ] && rm -rf "$TXDIR"; TXDIR=""; }
tx_die() {   # <message...>
    tx_restore
    echo "reviewctl: $*" >&2
    tx_cleanup
    exit 1
}

# Snapshot before touching. A file that does not exist yet is recorded as absent,
# so restoring means deleting it -- a refusal must not leave a closure artifact
# lying around any more than it may leave a half-written one.
declare -a TX_FILES=()
tx_guard() {   # <file...>
    local f
    for f in "$@"; do
        TX_FILES+=("$f")
        if [ -f "$f" ]; then
            mkdir -p "$TXDIR/present/$(dirname "${f#$REPO/}")"
            cp -p "$f" "$TXDIR/present/${f#$REPO/}"
        else
            mkdir -p "$TXDIR/absent"
            printf '%s\n' "$f" >> "$TXDIR/absent/list"
        fi
    done
}
tx_restore() {
    [ -n "$TXDIR" ] || return 0
    local f
    for f in "${TX_FILES[@]:-}"; do
        [ -n "$f" ] || continue
        if [ -f "$TXDIR/present/${f#$REPO/}" ]; then
            cp -p "$TXDIR/present/${f#$REPO/}" "$f"
        elif [ -f "$TXDIR/absent/list" ] && grep -qxF "$f" "$TXDIR/absent/list"; then
            rm -f "$f"
        fi
    done
}

tx_sha_ok() {   # <label> <value> -- canonical AND reachable, or refuse
    local label="$1" sha="$2" g ref
    case "$sha" in
        '') tx_die "$label is required and must be a full 40-character commit id" ;;
        *[!0-9a-f]*) tx_die "$label names '$sha', which is not a lowercase 40-character commit id -- protocol headers are durable audit facts and must be canonical" ;;
    esac
    [ "${#sha}" -eq 40 ] || tx_die "$label names '$sha', an abbreviated commit id (${#sha} chars) -- write the full 40-character SHA, or state equality cannot be decided"
    g="$(gitrepo)"
    git -C "$g" rev-parse --show-toplevel >/dev/null 2>&1 \
        || tx_die "$label names $sha but there is no git repository to resolve it against; refusing to write an unverifiable commit reference"
    git -C "$g" cat-file -e "${sha}^{commit}" 2>/dev/null \
        || tx_die "$label names $sha, which is not a commit in this repository"
    ref="$(pubref)" || tx_die "cannot validate $label against the publication ref"
    git -C "$g" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null \
        || tx_die "$label names $sha, which is a commit but is not reachable from $ref -- unpushed, or rewritten and orphaned"
}

# The compare-and-swap half. `--expected-parent` is the caller's statement of the
# published state it computed its request against; if the branch has moved, the
# request was computed against facts that no longer hold and it loses.
tx_expect_parent() {   # <sha>
    local sha="$1" g ref tip
    tx_sha_ok "--expected-parent" "$sha"
    g="$(gitrepo)"; ref="$(pubref)"
    tip="$(git -C "$g" rev-parse "$ref" 2>/dev/null)"
    [ "$tip" = "$sha" ] || tx_die "--expected-parent names $sha but $ref is at ${tip:-<unknown>} -- the published state moved after this request was computed; recompute it against the current head rather than publishing against a stale one"
}

tx_rev_id() {   # <rev>
    case "$1" in
        REV-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9]) ;;
        *) tx_die "'$1' is not a REV id (expected REV-YYYYMMDD-NNN)" ;;
    esac
}

# Replace exactly one machine header in place, or refuse. Never touches prose:
# the sed is anchored to the whole header line, so nothing else in the file can
# match, and a missing header is a refusal rather than an append.
tx_set_header() {   # <file> <field> <value>
    local f="$1" field="$2" val="$3" tmp
    grep -q "^<!-- $field: .* -->$" "$f" \
        || tx_die "$f has no '$field' machine header to set -- refusing to invent one in a role artifact"
    tmp="$TXDIR/h.$$"
    sed "s|^<!-- $field: .* -->$|<!-- $field: $val -->|" "$f" > "$tmp" || tx_die "could not rewrite $field in $f"
    cat "$tmp" > "$f"
}

# Regenerate and verify through this script's own tested paths, in a child
# process so nothing here inherits half-collected state.
tx_regenerate_and_verify() {
    local out
    if ! out="$("$0" --generate 2>&1)"; then
        tx_die "the transition does not derive cleanly, so it is not published: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    fi
    "$0" --verify >/dev/null 2>&1 \
        || tx_die "generated views do not agree with the artifacts after the write -- refusing to leave a state that --verify would reject"
}

# REV-122 F3, accepted and answered honestly rather than papered over.
#
# --expected-parent was a preflight observation: checked once at the start, so the
# branch could move while the tool worked and the result would be published on top
# of facts it never saw. Re-checking at the end closes most of that window -- but
# NOT all of it, and the remainder cannot be closed here at all.
#
# This tool writes files. It does not publish. The real compare-and-swap is the
# push: `git push` without --force is refused when the remote ref has moved, which
# is an atomic test-and-set performed by the server. So the honest design is that
# this narrows the window and the push holds the property, and the tool says so
# instead of claiming a CAS it cannot perform.
tx_reconfirm_parent() {   # <sha>
    local sha="$1" g ref tip
    g="$(gitrepo)"; ref="$(pubref)"
    tip="$(git -C "$g" rev-parse "$ref" 2>/dev/null)"
    [ "$tip" = "$sha" ] || tx_die "$ref moved from $sha to ${tip:-<unknown>} while this transition was being written -- nothing is published, and the write has been rolled back; recompute against the new head"
}

tx_begin() {
    TXDIR="$(mktemp -d)" || { echo "reviewctl: mktemp failed" >&2; exit 1; }
    TX_FILES=()
}

tx_approve() {   # <rev> <impl-sha> <expected-parent>
    local rev="$1" impl="$2" parent="$3"
    tx_rev_id "$rev"
    local rfile="$RDIR/$rev.md"
    [ -f "$rfile" ] || tx_die "$rev: no review artifact at ${rfile#$REPO/}"
    tx_sha_ok "--implementation" "$impl"
    tx_expect_parent "$parent"

    # Approval names the response's CURRENT implementation, never an older one.
    # This is the REV-120 failure in one line: the closure prose approved 46c13a6
    # while the header still pointed at the round-1 SHA.
    local pfile pimpl
    # Response filenames are canonical by Principle 4. Do not require the
    # optional legacy `response:` pointer: it is absent from the protocol's
    # minimum reviewer header, and the generator already discovers the same
    # canonical file by REV identity. Requiring it only in the writer made a
    # state that generated as IMPLEMENTED impossible to approve.
    pfile="$RDIR/responses/$rev.md"
    [ -f "$pfile" ] || tx_die "$rev: canonical response ${pfile#$REPO/} does not exist -- there is nothing to approve"
    pimpl="$(hdr "$pfile" implementation)"
    [ -n "$pimpl" ] || tx_die "$rev: the response carries no implementation header -- nothing has been submitted to approve"
    [ "$pimpl" = "$impl" ] || tx_die "$rev: --implementation is $impl but the response currently submits $pimpl -- approve what was submitted, or ask for a resubmission"

    # Idempotent replay: the same approval twice is a no-op WRITE -- but never a
    # no-op check.
    #
    # REV-122 F4: the first cut returned success here before regenerating or
    # verifying anything, so a replay over a tree whose derived views had since
    # been damaged reported "nothing to do" and left the damage in place. Replay
    # must be idempotent in its effect, not blind to the state it is replaying
    # onto. So the write is skipped and the verification is not.
    if [ "$(hdr "$rfile" verdict)" = "APPROVED" ] && [ "$(hdr "$rfile" reviewed-implementation)" = "$impl" ]; then
        tx_guard "$LEDGER" "$THREADS"
        tx_regenerate_and_verify
        echo "reviewctl: $rev is already APPROVED at $impl -- no write needed; derived views verified"
        return 0
    fi

    tx_guard "$rfile" "$DELIVERIES" "$LEDGER" "$THREADS"
    tx_set_header "$rfile" verdict APPROVED
    tx_set_header "$rfile" reviewed-implementation "$impl"

    # First review makes the delivery acknowledgement PERMANENT. reviewed-implementation
    # is a moving pointer, so a delivery cleared only by it reappears as unreviewed
    # the moment the thread advances -- the defect REV-20260809-080 already fixed
    # for the reader. The writer must not recreate it.
    if [ -f "$DELIVERIES" ] && grep -q "^<!-- delivered: $impl " "$DELIVERIES" \
       && ! grep -q "^<!-- reviewed-by: $impl" "$DELIVERIES"; then
        printf '<!-- reviewed-by: %s reviewed under %s -->\n' "$impl" "$rev" >> "$DELIVERIES"
    fi

    tx_regenerate_and_verify
    tx_reconfirm_parent "$parent"
    echo "reviewctl: $rev APPROVED at $impl (parent $parent)"
    echo "reviewctl: nothing is published yet -- the compare-and-swap is the push, which the server refuses if $(pubref) has moved."
    echo 'reviewctl: commit the result -- "close" will require that commit id.'
}

tx_close() {   # <rev> <approval-commit> <expected-parent>
    local rev="$1" acommit="$2" parent="$3"
    tx_rev_id "$rev"
    local rfile="$RDIR/$rev.md"
    [ -f "$rfile" ] || tx_die "$rev: no review artifact at ${rfile#$REPO/}"
    tx_sha_ok "--approval-commit" "$acommit"
    tx_expect_parent "$parent"

    [ "$(hdr "$rfile" verdict)" = "APPROVED" ] \
        || tx_die "$rev: verdict is '$(hdr "$rfile" verdict)', not APPROVED -- a closure without an approval is exactly the state that made REV-120/121 underivable"

    # The named commit must PROVABLY be the approval: at that commit the review
    # already said APPROVED for the implementation it still names. A closure that
    # merely points at some reachable commit proves nothing.
    local g shown approved_impl
    g="$(gitrepo)"
    shown="$(git -C "$g" show "$acommit:docs/internal/reviews/$rev.md" 2>/dev/null \
             | sed -n 's|^<!-- verdict: *\([^ ][^>]*[^ ]\) *-->$|\1|p' | head -1)"
    [ "$shown" = "APPROVED" ] \
        || tx_die "$rev: --approval-commit $acommit does not carry an APPROVED verdict for this review (it says '${shown:-<no header>}') -- name the commit that published the approval"

    # REV-122 F2: an APPROVED verdict at that commit is not enough. It must have
    # approved THE SAME implementation the response submits now, or the closure
    # cements an approval of something else -- which is REV-120's defect wearing a
    # closure's clothes. The response is re-read here rather than trusted from the
    # review file, because reviewed-implementation is a moving pointer and the
    # question is what is on the table now.
    approved_impl="$(git -C "$g" show "$acommit:docs/internal/reviews/$rev.md" 2>/dev/null \
                     | sed -n 's|^<!-- reviewed-implementation: *\([^ ][^>]*[^ ]\) *-->$|\1|p' | head -1)"
    local rpath rimpl
    # Same canonical-path rule as approval: `response:` is not part of the
    # minimum reviewer header and cannot be a hidden prerequisite for closing
    # a state the generator and approval writer both accept.
    rpath="docs/internal/reviews/responses/$rev.md"
    rimpl="$(hdr "$REPO/$rpath" implementation)"
    [ -n "$rimpl" ] || tx_die "$rev: the response carries no implementation header, so there is nothing a closure can be checked against"
    [ "$approved_impl" = "$rimpl" ] \
        || tx_die "$rev: --approval-commit $acommit approved implementation '${approved_impl:-<none>}', but the response submits '$rimpl' -- closing here would record approval of something that is no longer on the table; approve the current implementation first"

    local cdir="$RDIR/closures" cfile="$RDIR/closures/$rev.md"
    if [ -f "$cfile" ] && [ "$(hdr "$cfile" closed-by)" = "$acommit" ]; then
        echo "reviewctl: $rev is already closed by $acommit -- nothing to do"
        return 0
    fi
    [ -f "$cfile" ] && tx_die "$rev: a closure already exists naming $(hdr "$cfile" closed-by) -- refusing to overwrite a published closure with a different one"

    tx_guard "$cfile" "$LEDGER" "$THREADS"
    mkdir -p "$cdir"
    {
        printf '<!-- rev: %s -->\n' "$rev"
        printf '<!-- closed-by: %s -->\n' "$acommit"
        printf '\n# Closure — %s\n\n' "$rev"
        printf 'APPROVED and CLOSED. The approval is commit `%s`; the implementation it\n' "$acommit"
        printf 'approved is `%s`.\n\n' "$(hdr "$rfile" reviewed-implementation)"
        printf 'Written by `reviewctl close`. Reviewer prose may be added below this line;\n'
        printf 'the machine headers above are the durable facts.\n'
    } > "$cfile"

    tx_regenerate_and_verify
    tx_reconfirm_parent "$parent"
    echo "reviewctl: $rev CLOSED by $acommit (parent $parent)"
    echo "reviewctl: nothing is published yet -- the compare-and-swap is the push, which the server refuses if $(pubref) has moved."
}

# ---- argument parsing for the writers ---------------------------------------
# Foreign flags are refused rather than ignored, and the two operations cannot be
# combined: `approve` does not accept --approval-commit and `close` does not
# accept --implementation, so the request that produced REV-120/121 has no
# spelling here.
if [ "${1:-}" = "approve" ] || [ "${1:-}" = "close" ]; then
    tx_op="$1"; shift
    tx_rev="${1:-}"; shift || true
    [ -n "$tx_rev" ] || { echo "usage: $0 $tx_op REV --implementation|--approval-commit SHA --expected-parent SHA" >&2; exit 1; }
    tx_impl=""; tx_acommit=""; tx_parent=""
    tx_begin
    for a in "$@"; do
        case "$a" in
            --implementation=*)   [ "$tx_op" = approve ] || tx_die "close does not take --implementation; closure names the approval commit, not the implementation"
                                  tx_impl="${a#*=}" ;;
            --approval-commit=*)  [ "$tx_op" = close ]   || tx_die "approve does not take --approval-commit; approval and closure are separate publications"
                                  tx_acommit="${a#*=}" ;;
            --expected-parent=*)  tx_parent="${a#*=}" ;;
            *) tx_die "unknown option '$a'" ;;
        esac
    done
    if [ "$tx_op" = approve ]; then tx_approve "$tx_rev" "$tx_impl" "$tx_parent"
    else                            tx_close   "$tx_rev" "$tx_acommit" "$tx_parent"; fi
    tx_cleanup
    exit 0
fi

MODE=""
case "${1:-}" in
    --generate|--verify|--migrate) MODE="${1#--}" ;;
    *) echo "usage: $0 --generate | --verify | --migrate | approve REV ... | close REV ..." >&2; exit 1 ;;
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
