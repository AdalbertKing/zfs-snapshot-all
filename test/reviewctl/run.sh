#!/bin/bash
# Tests for reviewctl.sh -- the REVIEW PROTOCOL V2 state machine.
#
# Every case builds a throwaway repo of artifacts and asks reviewctl what state
# it derives. No git, no network, no real reviews touched.
#
# This is the minimum acceptance matrix from docs/project/PROTOCOL.md. It is
# written out case by case rather than looped, because the whole point of V2 is
# that state is DERIVED -- and a derivation nobody pins is just another opinion.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Negative control: CTL must point at a copy living INSIDE this repository,
# e.g. test/.oldctl.sh. reviewctl resolves the git repo from its own
# SCRIPT_DIR when REVIEWCTL_REPO points at a non-git artifact tree, so a copy
# in /tmp cannot resolve any commit and EVERY case fails -- 15 of them, most
# unrelated to whatever is being controlled for. That looks like a devastating
# regression and means nothing.
#
#   git show <base>:test/reviewctl.sh > test/.oldctl.sh && chmod +x test/.oldctl.sh
#   CTL="$PWD/test/.oldctl.sh" ./test/reviewctl/run.sh ; rm -f test/.oldctl.sh
CTL="${CTL:-$REPO/test/reviewctl.sh}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# world <name> -> fresh artifact tree, exported as W
world() {
    W="$TMPD/$1"; rm -rf "$W"
    mkdir -p "$W/docs/internal/reviews/responses" "$W/docs/internal/reviews/closures" "$W/docs/project"
}
review()  { printf '<!-- rev: %s -->\n<!-- verdict: %s -->\n<!-- reviewed-implementation: %s -->\n\n# t\n' "$1" "$2" "$3" > "$W/docs/internal/reviews/$1.md"; }
respond() { printf '<!-- rev: %s -->\n<!-- response-status: %s -->\n<!-- implementation: %s -->\n\n# t\n' "$1" "$2" "$3" > "$W/docs/internal/reviews/responses/$1.md"; }
closure() { printf '<!-- rev: %s -->\n<!-- closed-by: %s -->\n' "$1" "$2" > "$W/docs/internal/reviews/closures/$1.md"; }

# state <rev> -> the state reviewctl derives, or FAILED if it refused
state() {
    REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1 || { echo FAILED; return; }
    awk -F'|' -v r=" $1 " '$2==r {gsub(/^ +| +$/,"",$3); print $3}' "$W/docs/internal/reviews/REVIEW_LEDGER.md"
}
expect() { local got; got="$(state "$2")"; [ "$got" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$got"; }

R=REV-20260808-001

# The state machine only ever compares these for EQUALITY, so what they are
# does not matter to the transitions -- but since REV-20260807-067 reviewctl
# also demands that a commit-bearing header names a commit REACHABLE FROM THE
# PUBLISHED BRANCH, so they have to be real. Three published commits, resolved
# once. Structural cases keep testing structure; the commit check gets its own
# cases below.
sha1="$(git -C "$REPO" rev-parse origin/main~2)"
sha2="$(git -C "$REPO" rev-parse origin/main~1)"
sha3="$(git -C "$REPO" rev-parse origin/main~3)"
deadbeef="$(git -C "$REPO" rev-parse origin/main)"
[ -n "$sha1" ] && [ -n "$sha2" ] && [ -n "$deadbeef" ] || { echo "cannot resolve published commits"; exit 1; }

# ---- the happy path, one transition at a time ------------------------------
world a; review $R CHANGES-REQUIRED -
expect "canonical review, no response -> OPEN" $R OPEN

world b; review $R CHANGES-REQUIRED -;            respond $R IMPLEMENTED $sha1
expect "response submits sha1, unreviewed -> IMPLEMENTED" $R IMPLEMENTED

# The label on this case was right and its expectation was wrong: it pinned the
# bug instead of the contract, and the reviewer caught it, not me
# (REV-20260807-065). Rejection of the SUBMITTED sha is the one backward
# transition the protocol has.
world c; review $R CHANGES-REQUIRED $sha1;         respond $R IMPLEMENTED $sha1
expect "reviewer rejects the submitted sha -> OPEN" $R OPEN
# State alone is not the contract -- routing is. A rejected submission whose
# owner still reads Reviewer sends the reviewer back to the sha they rejected.
row="$(awk -F'|' -v r=" $R " '$2==r {print}' "$W/docs/internal/reviews/REVIEW_LEDGER.md")"
case "$row" in *"| Claude |"*) ok "rejection routes back to Claude" ;;
  *) bad "rejection routes back to Claude" "$row" ;; esac
case "$row" in *"implement and respond"*) ok "rejection asks for an implementation, not a review" ;;
  *) bad "rejection asks for an implementation, not a review" "$row" ;; esac

world c2; review $R CHANGES-REQUIRED $sha1;        respond $R IMPLEMENTED $sha2
expect "after rejection, advancing to sha2 -> IMPLEMENTED again" $R IMPLEMENTED

world d; review $R CHANGES-REQUIRED $sha1;         respond $R IMPLEMENTED $sha2
expect "response advances to sha2 -> IMPLEMENTED" $R IMPLEMENTED

world e; review $R APPROVED $sha2;                 respond $R IMPLEMENTED $sha2
expect "reviewer approves the submitted sha -> APPROVED" $R APPROVED

world f; review $R APPROVED $sha2; respond $R IMPLEMENTED $sha2; closure $R $deadbeef
expect "closure on top of a matching approval -> CLOSED" $R CLOSED

# ---- the cases that must NOT be accepted -----------------------------------
# Approval that names a different commit than the one on the table is not
# approval of what is on the table. This is the one that would otherwise let a
# stale verdict close current work.
world g; review $R APPROVED $sha1;                 respond $R IMPLEMENTED $sha2
expect "approval for sha1 while sha2 is submitted -> not APPROVED" $R IMPLEMENTED

world h; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED $sha1; closure $R $deadbeef
expect "closure without an approval -> refused" $R FAILED

world i; review $R CHANGES-REQUIRED -
cp "$W/docs/internal/reviews/$R.md" "$W/docs/internal/reviews/$R-EXTRA.md"
expect "two files claiming one REV identity -> refused" $R FAILED

world j; respond $R IMPLEMENTED $sha1
expect "orphan response with no review -> refused" $R FAILED

world k; review $R CHANGES-REQUIRED -; closure $R $deadbeef
out="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "orphan-ish closure without approval refuses" || bad "orphan-ish closure without approval refuses" "$out"

world l; printf '<!-- rev: %s -->\n<!-- verdict: MAYBE -->\n' "$R" > "$W/docs/internal/reviews/$R.md"
expect "malformed verdict -> refused, not guessed" $R FAILED

world m; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED $sha1; closure $R ""
out="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "closure with no closed-by refuses" || bad "closure with no closed-by refuses" "$out"

# ---- generated views must match the facts ----------------------------------
world n; review $R APPROVED $sha2; respond $R IMPLEMENTED $sha2
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1
REVIEWCTL_REPO="$W" "$CTL" --verify >/dev/null 2>&1
[ $? -eq 0 ] && ok "freshly generated ledger verifies" || bad "freshly generated ledger verifies"

echo 'tampered' >> "$W/docs/internal/reviews/REVIEW_LEDGER.md"
REVIEWCTL_REPO="$W" "$CTL" --verify >/dev/null 2>&1
[ $? -ne 0 ] && ok "hand-edited ledger is refused" || bad "hand-edited ledger is refused"

REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1
echo 'tampered' >> "$W/docs/project/OPEN-THREADS.md"
REVIEWCTL_REPO="$W" "$CTL" --verify >/dev/null 2>&1
[ $? -ne 0 ] && ok "hand-edited routing view is refused" || bad "hand-edited routing view is refused"

# ---- legacy files are frozen, not broken -----------------------------------
# A pre-V2 review has no machine header. It must be skipped in silence: it is
# reviewer-authored, and the implementer retrofitting headers into it would be
# editing reviewer artifacts (Principle 3).
world o; review $R CHANGES-REQUIRED -
printf '# an old review with no machine header\n' > "$W/docs/internal/reviews/REV-20260101-999-DESCRIPTIVE-NAME.md"
expect "a pre-V2 file without headers is ignored, not an error" $R OPEN

# ---- commit-bearing headers must name a fetchable commit (REV-067 F1) ------
#
# The protocol's core promise is that the reviewer can fetch, diff and pin
# exactly the submitted change. REV-066 was routed to the reviewer carrying
# `implementation: c49afd2...`, and GitHub answered "No commit found".
#
# The diagnosis matters more than the symptom: that SHA was NOT fabricated and
# NOT a typo. It is a real commit in the implementer's clone, orphaned by a
# rewrite, whose content was published as a DIFFERENT SHA. So resolvability is
# not the property -- a `git cat-file -e` check passes it and the reviewer
# still cannot fetch it. Reachability from the published branch is the
# property, and it is what these cases pin.
ORPHAN="$(git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse origin/main^{tree})" -p "$(git -C "$REPO" rev-parse origin/main)" -m 'orphan for test' 2>/dev/null)"
NOSUCH=0123456789abcdef0123456789abcdef01234567

world p1; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED $sha1
expect "a published commit is accepted" $R IMPLEMENTED

world p2; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED $NOSUCH
expect "a well-formed but nonexistent SHA is refused" $R FAILED

world p3; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED not-a-sha-at-all
expect "a non-commit value is refused" $R FAILED

if [ -n "$ORPHAN" ]; then
    world p4; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED "$ORPHAN"
    expect "a REAL commit that is not on the published branch is refused" $R FAILED
    # The message has to name the REV, the field and the SHA, or the reviewer
    # cannot act on it (REV-067 required outcome 4).
    msg="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"
    case "$msg" in
      *"$R"*implementation*"$ORPHAN"*) ok "the refusal names the REV, the field and the SHA" ;;
      *) bad "the refusal names the REV, the field and the SHA" "$msg" ;;
    esac

    # The same commit is valid while checking a PR candidate that contains it.
    # Without this prospective boundary, the implementation PR cannot carry
    # its generated ledger update: origin/main rejects the SHA until after the
    # merge, guaranteeing a stale handoff or a second repair PR.
    REVIEWCTL_REPO="$W" REVIEWCTL_PUBREF="$ORPHAN" "$CTL" --generate >/dev/null 2>&1
    candidate_state="$(awk -F'|' -v r=" $R " '$2==r {gsub(/^ +| +$/,"",$3); print $3}' "$W/docs/internal/reviews/REVIEW_LEDGER.md")"
    [ "$candidate_state" = IMPLEMENTED ] \
        && ok "the same commit is accepted from a candidate ref that contains it" \
        || bad "the same commit is accepted from a candidate ref that contains it" "got=$candidate_state"
else
    bad "a REAL commit that is not on the published branch is refused" "could not build an orphan commit"
fi

world p4b; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED "$sha1"
msg="$(REVIEWCTL_REPO="$W" REVIEWCTL_PUBREF=not-a-real-ref "$CTL" --generate 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && case "$msg" in *"not-a-real-ref"*) true;; *) false;; esac; then
    ok "an invalid candidate publication ref fails closed and is named"
else
    bad "an invalid candidate publication ref fails closed and is named" "$msg"
fi

# The reviewer's own header is held to the same standard -- a review that pins
# a head nobody can fetch is the same failure pointing the other way.
world p5; review $R CHANGES-REQUIRED $NOSUCH; respond $R IMPLEMENTED $sha1
expect "an unfetchable reviewed-implementation is refused too" $R FAILED

# And the closure artifact, which is the one that declares a thread finished.
world p6; review $R APPROVED $sha2; respond $R IMPLEMENTED $sha2; closure $R $NOSUCH
expect "an unfetchable closed-by is refused" $R FAILED

# `-` is the protocol's explicit "no commit yet". It must stay legal, or the
# very first review of any thread becomes unrepresentable.
world p7; review $R CHANGES-REQUIRED -
expect "the literal - is not treated as a broken SHA" $R OPEN


# ---- deliveries: direct-main work awaiting a first look (REV-070 F4) --------
#
# The failure is demonstrated, not hypothetical: OPEN-THREADS.md said "nothing
# to do" while Stage 3 sat on main unreviewed, because routing derives from REV
# artifacts only. A delivery with no REV had no way to exist.
deliver() { printf '<!-- delivered: %s %s -->
' "$1" "${2:-a delivery}" >> "$W/docs/project/DELIVERIES.md"; }
threads_rows() { REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1; grep -c '^| ' "$W/docs/project/OPEN-THREADS.md"; }
threads_txt()  { REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1; cat "$W/docs/project/OPEN-THREADS.md"; }

world d1; deliver "$sha1" "stage three"
case "$(threads_txt)" in
    *"${sha1:0:8}"*DELIVERED*Reviewer*) ok "a delivery with no REV becomes reviewer-owned work" ;;
    *) bad "a delivery with no REV becomes reviewer-owned work" "$(threads_txt)" ;;
esac

# Cleared by the reviewer opening a REV for exactly that sha -- and cleared
# WITHOUT leaving the same work listed twice.
world d2; deliver "$sha1" "stage three"; review $R CHANGES-REQUIRED $sha1
txt="$(threads_txt)"
case "$txt" in *DELIVERED*) bad "opening a REV for the delivery clears the delivery row" "$txt" ;;
  *) ok "opening a REV for the delivery clears the delivery row" ;; esac
case "$txt" in *"$R"*) ok "...and the REV row replaces it, so the work is listed once" ;;
  *) bad "...and the REV row replaces it, so the work is listed once" "$txt" ;; esac

# ...or by the reviewer explicitly waiving it. Deterministic, never "it aged out".
world d3; deliver "$sha1" "a docs-only change"
printf '<!-- no-review-required: %s -->
' "$sha1" >> "$W/docs/project/DELIVERIES.md"
case "$(threads_txt)" in *DELIVERED*) bad "an explicit waiver clears the delivery" "$(threads_txt)" ;;
  *) ok "an explicit waiver clears the delivery" ;; esac

# A REV for a DIFFERENT sha does not clear this delivery.
world d4; deliver "$sha1" "stage three"; review $R CHANGES-REQUIRED $sha2
case "$(threads_txt)" in *DELIVERED*) ok "a REV for another sha leaves the delivery open" ;;
  *) bad "a REV for another sha leaves the delivery open" "$(threads_txt)" ;; esac

# Same reachability rule as an implementation sha: a reviewer who cannot fetch
# it cannot review it.
world d5; deliver "$NOSUCH" "unfetchable"
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1
[ $? -ne 0 ] && ok "an unreachable delivery sha is refused" || bad "an unreachable delivery sha is refused"


# The moving-pointer flaw, found by USING the mechanism (2026-08-08).
# reviewed-implementation is advanced by the reviewer to each new submission, so
# a delivery cleared by "some REV currently names this sha" reappears the moment
# that thread progresses -- and would do so forever. "It was reviewed" is a fact
# about the past and must be recorded as one.
world d6; deliver "$sha1" "stage three"; review $R CHANGES-REQUIRED $sha2
printf '<!-- reviewed-by: %s %s -->
' "$sha1" "$R" >> "$W/docs/project/DELIVERIES.md"
case "$(threads_txt)" in *DELIVERED*) bad "reviewed-by clears a delivery whose REV has moved on" "$(threads_txt)" ;;
  *) ok "reviewed-by clears a delivery whose REV has moved on" ;; esac

# Without the marker the same world still shows the row: the flaw is real, and
# this pins that the marker is what closes it rather than something incidental.
world d7; deliver "$sha1" "stage three"; review $R CHANGES-REQUIRED $sha2
case "$(threads_txt)" in *DELIVERED*) ok "...and without it the delivery is still open" ;;
  *) bad "...and without it the delivery is still open" "$(threads_txt)" ;; esac

# REV-20260811-099 / REV-20260811-100 F1: the full resurface lifecycle, walked
# STATE BY STATE rather than asserted only in its final shape. The historical
# failure is temporal, so a fixture that starts already-retired stays green even
# if the transition or its bookkeeping breaks. Each step generates and asserts
# before the next.
world d8; deliver "$sha1" "phase slice"
# 1. a direct-main delivery starts as reviewer-owned DELIVERED work.
case "$(threads_txt)" in *"${sha1:0:8}"*DELIVERED*) ok "099L step1: a fresh direct-main delivery starts open/DELIVERED" ;;
  *) bad "099L step1: a fresh direct-main delivery starts open/DELIVERED" "$(threads_txt)" ;; esac
# 2. a REV opened AT the delivery sha replaces the DELIVERED row with the REV row.
review $R CHANGES-REQUIRED $sha1
txt="$(threads_txt)"
case "$txt" in *DELIVERED*) bad "099L step2: opening the REV at the delivery sha clears the DELIVERED row" "$txt" ;;
  *) ok "099L step2: opening the REV at the delivery sha clears the DELIVERED row" ;; esac
case "$txt" in *"$R"*) ok "099L step2: ...and the REV row stands in its place" ;;
  *) bad "099L step2: ...and the REV row stands in its place" "$txt" ;; esac
# 3. a follow-up ADVANCES the SAME review's pointer to a later cumulative sha.
#    Without a durable fact the original delivery resurfaces HERE -- the exact
#    historical failure this mechanism exists to remove.
review $R APPROVED $sha2; respond $R IMPLEMENTED $sha2
case "$(threads_txt)" in *"${sha1:0:8}"*DELIVERED*) ok "099L step3: advancing the pointer resurfaces the original delivery until it is retired" ;;
  *) bad "099L step3: advancing the pointer resurfaces the original delivery until it is retired" "$(threads_txt)" ;; esac
# 4. record the durable reviewed-by fact for the ORIGINAL delivery sha.
printf '<!-- reviewed-by: %s %s -->\n' "$sha1" "$R" >> "$W/docs/project/DELIVERIES.md"
# 5. close at the cumulative sha; the original delivery AND the closed REV are gone.
closure $R $sha2
txt="$(threads_txt)"
case "$txt" in *"${sha1:0:8}"*) bad "099L step5: after the advance + closure the retired delivery stays absent" "$txt" ;;
  *) ok "099L step5: after the advance + closure the retired delivery stays absent" ;; esac
case "$txt" in *"$R"*) bad "099L step5: the closed REV is not open either" "$txt" ;;
  *) ok "099L step5: the closed REV is not open either" ;; esac

# Negative control: in that same closed world, a GENUINELY unreviewed delivery
# (a third sha no REV or reviewed-by names) must still show as open -- so the
# retirement is the reviewed-by fact, not "closing a REV silences all deliveries".
deliver "$sha3" "an actually unreviewed delivery"
case "$(threads_txt)" in *"${sha3:0:8}"*DELIVERED*) ok "099L control: a genuinely unreviewed delivery still shows as open" ;;
  *) bad "099L control: a genuinely unreviewed delivery still shows as open" "$(threads_txt)" ;; esac

# ---- commit ids must be CANONICAL, not merely resolvable (REV-080 F1) -------
#
# Resolvability and canonical form are different properties, and the gap
# between them cost a real thread. REV-078's response carried
# `implementation: dc1c038` while the approval carried the full 40-char SHA of
# THE SAME COMMIT. require_commit passed it -- git resolves an unambiguous
# abbreviation -- and then state_of_raw() compared the two header STRINGS,
# found them unequal, and derived IMPLEMENTED from an approval already granted.
# rc=0 throughout, so routing sent the thread back to the reviewer who had
# already done the work.
#
# The discriminating case is therefore NOT "a bad sha is refused". It is "a
# sha that IS the same commit, written short, does not silently mean a
# different one". Everything else here is the same class in the other
# commit-bearing fields, which requirement 4 says must not be left behind.
short1="${sha1:0:7}"
# Prove the premise rather than assume it: if this abbreviation did not resolve
# to sha1, the case below would pass for the wrong reason -- refused as
# unresolvable rather than as non-canonical.
[ "$(git -C "$REPO" rev-parse "$short1" 2>/dev/null)" = "$sha1" ] \
    && ok "premise: the abbreviation resolves to the same commit" \
    || bad "premise: the abbreviation resolves to the same commit" "short=$short1"

world q1; review $R APPROVED $sha1; respond $R IMPLEMENTED $sha1
expect "canonical full SHAs on both sides still reach APPROVED" $R APPROVED

world q2; review $R APPROVED $sha1; respond $R IMPLEMENTED "$short1"
expect "an abbreviated implementation of the SAME commit is refused, not silently IMPLEMENTED" $R FAILED

msg="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"
case "$msg" in
  *"$R"*implementation*"$short1"*) ok "the refusal names the REV, the field and the abbreviated value" ;;
  *) bad "the refusal names the REV, the field and the abbreviated value" "$msg" ;;
esac

world q3; review $R APPROVED "$short1"; respond $R IMPLEMENTED $sha1
expect "an abbreviated reviewed-implementation is refused too" $R FAILED

world q4; review $R APPROVED $sha1; respond $R IMPLEMENTED $sha1; closure $R "$short1"
expect "an abbreviated closed-by is refused" $R FAILED

# Not just length: a 40-character value that is not lowercase hex is not an
# object id either, and uppercase would compare unequal to git's own output.
world q5; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED "$(printf '%s' "$sha1" | tr 'a-f' 'A-F')"
expect "an uppercase 40-char value is refused" $R FAILED

# `-` keeps working in the field the protocol defines it for. Without this the
# canonical-form rule would make the first submission of any thread illegal.
world q6; review $R CHANGES-REQUIRED -; respond $R ACCEPTED -
expect "the literal - stays legal in implementation" $R OPEN

# Requirement 4: the same rule in delivery bookkeeping. These two markers CLEAR
# a delivery by matching its sha as a key, so an abbreviated one clears nothing
# and the delivery stays open forever -- and before this change they were not
# even reachability-checked.
world q7; deliver "$short1" "abbreviated delivery"
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1 \
    && bad "an abbreviated delivered sha is refused" \
    || ok "an abbreviated delivered sha is refused"

world q8; deliver "$sha1" "stage three"
printf '<!-- no-review-required: %s -->\n' "$short1" >> "$W/docs/project/DELIVERIES.md"
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1 \
    && bad "an abbreviated no-review-required is refused rather than silently clearing nothing" \
    || ok "an abbreviated no-review-required is refused rather than silently clearing nothing"

world q9; deliver "$sha1" "stage three"
printf '<!-- reviewed-by: %s %s -->\n' "$short1" "$R" >> "$W/docs/project/DELIVERIES.md"
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1 \
    && bad "an abbreviated reviewed-by is refused" \
    || ok "an abbreviated reviewed-by is refused"


# ==============================================================================
# TRANSACTIONAL WRITERS -- `approve` and `close` (consensus of 2026-08-14).
#
# Every case here is a shape that actually happened, or one the reviewer named as
# a required negative control. The REV-120/121 publication put prose saying
# APPROVED/CLOSED on canonical main while the headers said CHANGES-REQUIRED
# against a superseded implementation, and wrote a person's name where a commit id
# belongs. The writer has to make each of those unspellable.
# ==============================================================================

TIP="$(git -C "$REPO" rev-parse origin/main)"
OLD="$(git -C "$REPO" rev-parse origin/main~3)"

# a world holding one submitted-but-unreviewed REV
txworld() {   # <name>
    world "$1"
    # Use exactly the minimum reviewer header promised by PROTOCOL.md. The
    # transactional writer must derive the canonical response path from REV;
    # an optional legacy `response:` pointer cannot be a hidden precondition.
    printf '<!-- rev: %s -->\n<!-- verdict: CHANGES-REQUIRED -->\n<!-- reviewed-implementation: %s -->\n\n# t\n' \
        "$R" "$OLD" > "$W/docs/internal/reviews/$R.md"
    respond "$R" IMPLEMENTED "$sha1"
}
tx()      { REVIEWCTL_REPO="$W" "$CTL" "$@" >"$TMPD/out" 2>&1; }
revfile() { cat "$W/docs/internal/reviews/$R.md"; }

# A refusal is asserted by its REASON, never by a non-zero exit alone. Without
# this every case below also passes against a build that has no writer at all --
# it refuses the unknown subcommand and looks like a working guard. The negative
# control across an older reviewctl is what exposed that, so the fix is here
# rather than a note admitting it.
refuses() {   # <name> <expected phrase> <args...>
    local name="$1" phrase="$2"; shift 2
    if tx "$@"; then
        bad "$name" "it succeeded"
    elif grep -qF -- "$phrase" "$TMPD/out"; then
        ok "$name"
    else
        bad "$name" "refused for the wrong reason: $(head -1 "$TMPD/out")"
    fi
}

# T1. The happy path has to exist, or every refusal below proves nothing.
txworld t1
if tx approve "$R" --implementation="$sha1" --expected-parent="$TIP" \
   && grep -q '^<!-- verdict: APPROVED -->$' "$W/docs/internal/reviews/$R.md" \
   && grep -q "^<!-- reviewed-implementation: $sha1 -->$" "$W/docs/internal/reviews/$R.md"; then
    ok "approve sets the verdict and the reviewed implementation together"
else
    bad "approve sets the verdict and the reviewed implementation together" "$(cat "$TMPD/out")"
fi

# T2. Replay is idempotent: the same approval twice is a no-op success.
if tx approve "$R" --implementation="$sha1" --expected-parent="$TIP" && grep -q 'already APPROVED' "$TMPD/out"; then
    ok "replaying the same approval is an idempotent no-op"
else
    bad "replaying the same approval is an idempotent no-op" "$(cat "$TMPD/out")"
fi

# T3. THE REV-120/121 SHAPE: approval must name what the response actually submits.
txworld t3
before="$(revfile)"
if tx approve "$R" --implementation="$OLD" --expected-parent="$TIP"; then
    bad "approving a superseded implementation refuses" "it succeeded"
elif [ "$(revfile)" = "$before" ] && grep -q "but the response currently submits" "$TMPD/out"; then
    ok "approving a superseded implementation refuses, and the artifact is byte-identical"
else
    bad "approving a superseded implementation refuses" "the artifact was modified"
fi

# T4. A combined approve+close request has no spelling at all.
txworld t4
refuses "approve refuses --approval-commit, so the two cannot be one request" \
        "approve does not take --approval-commit" \
        approve "$R" --approval-commit="$sha1" --expected-parent="$TIP"
refuses "close refuses --implementation, so the two cannot be one request" \
        "close does not take --implementation" \
        close "$R" --implementation="$sha1" --expected-parent="$TIP"

# T5. closed-by naming a person cannot be produced: the writer only ever writes a
#     validated SHA, and a name is refused at the boundary.
txworld t5
if tx close "$R" --approval-commit="ChatGPT reviewer" --expected-parent="$TIP"; then
    bad "a human name as the approval commit refuses" ""
else
    grep -q 'not a lowercase 40-character commit id' "$TMPD/out" \
        && ok "a human name as the approval commit refuses, by the canonical-SHA rule" \
        || bad "a human name as the approval commit refuses, by the canonical-SHA rule" "$(cat "$TMPD/out")"
fi

# T6. Abbreviated, uppercase and non-existent commit ids all refuse.
refuses "an abbreviated approval commit refuses" "abbreviated commit id" \
        close "$R" --approval-commit="$short1" --expected-parent="$TIP"
refuses "an uppercase approval commit refuses" "not a lowercase 40-character commit id" \
        close "$R" --approval-commit="$(printf '%s' "$sha1" | tr 'a-f' 'A-F')" --expected-parent="$TIP"
refuses "an approval commit that is not a commit refuses" "is not a commit in this repository" \
        close "$R" --approval-commit="0123456789012345678901234567890123456789" --expected-parent="$TIP"

# T7. Closure requires an approval that PROVABLY happened: the named commit must
#     itself carry the APPROVED verdict for this review. A merely reachable commit
#     proves nothing, and that is what left the REV-120 closure underivable.
txworld t7
tx approve "$R" --implementation="$sha1" --expected-parent="$TIP"
if tx close "$R" --approval-commit="$TIP" --expected-parent="$TIP"; then
    bad "closure refuses a commit that did not carry the approval" "it succeeded"
else
    grep -q 'does not carry an APPROVED verdict' "$TMPD/out" \
        && ok "closure refuses a commit that did not carry the approval" \
        || bad "closure refuses a commit that did not carry the approval" "$(cat "$TMPD/out")"
fi
[ -f "$W/docs/internal/reviews/closures/$R.md" ] \
    && bad "that refusal leaves no closure artifact behind" "" \
    || ok "that refusal leaves no closure artifact behind"

# T8. Closing an unapproved review refuses.
txworld t8
refuses "closing a review whose verdict is not APPROVED refuses" "not APPROVED" \
        close "$R" --approval-commit="$sha1" --expected-parent="$TIP"

# T9. THE COMPARE-AND-SWAP: a stale expected parent loses and changes nothing.
txworld t9
before="$(revfile)"
if tx approve "$R" --implementation="$sha1" --expected-parent="$OLD"; then
    bad "a stale expected parent loses the CAS" "it succeeded"
elif [ "$(revfile)" = "$before" ] && grep -q "the published state moved" "$TMPD/out"; then
    ok "a stale expected parent loses the CAS and leaves the artifact untouched"
else
    bad "a stale expected parent loses the CAS" "the artifact was modified"
fi

# T10. Malformed canonical facts -- the response the review names is not there.
txworld t10
rm -f "$W/docs/internal/reviews/responses/$R.md"
before="$(revfile)"
if tx approve "$R" --implementation="$sha1" --expected-parent="$TIP"; then
    bad "an approval with no response artifact refuses" "it succeeded"
elif [ "$(revfile)" = "$before" ] && grep -q "there is nothing to approve" "$TMPD/out"; then
    ok "an approval with no response artifact refuses and mutates nothing"
else
    bad "an approval with no response artifact refuses" "the artifact was modified"
fi

# T11. First review makes the delivery acknowledgement PERMANENT, and advancing
#      reviewed-implementation later does not resurrect it. That header is a
#      moving pointer, so a delivery cleared only by it reappears as unreviewed
#      the moment the thread moves on.
txworld t11
deliver "$sha1" "the submitted delivery"
tx approve "$R" --implementation="$sha1" --expected-parent="$TIP"
grep -q "^<!-- reviewed-by: $sha1" "$W/docs/project/DELIVERIES.md" \
    && ok "first approval writes a permanent reviewed-by for the delivery" \
    || bad "first approval writes a permanent reviewed-by for the delivery" "$(cat "$W/docs/project/DELIVERIES.md")"
respond "$R" IMPLEMENTED "$TIP"
tx approve "$R" --implementation="$TIP" --expected-parent="$TIP"
REVIEWCTL_REPO="$W" "$CTL" --generate >/dev/null 2>&1
grep -q "$sha1" "$W/docs/project/OPEN-THREADS.md" \
    && bad "advancing the thread does not resurrect the earlier delivery" "it is open again" \
    || ok "advancing the thread does not resurrect the earlier delivery"

# T12. Nothing is ever staged. A refusal cannot leave a half-prepared commit
#      because the writer never touches the index -- asserted against the REAL
#      repository index, which is the one a caller would be about to commit.
idx_before="$(git -C "$REPO" diff --cached --name-only | sort)"
txworld t12
tx approve "$R" --implementation="$OLD" --expected-parent="$TIP"
idx_after="$(git -C "$REPO" diff --cached --name-only | sort)"
[ "$idx_before" = "$idx_after" ] \
    && ok "a refused write leaves the git index exactly as it found it" \
    || bad "a refused write leaves the git index exactly as it found it" "the index changed"


# ---- REV-122 F2 and F4 -------------------------------------------------------

# T13. F2: an APPROVED verdict at the named commit is not enough -- it must have
#      approved the implementation the response submits NOW. Otherwise the closure
#      cements approval of something since superseded, which is REV-120's defect
#      wearing a closure's clothes.
#
#      Uses a REAL approval from this repository's history: 211d378 carries
#      `verdict: APPROVED` for REV-20260814-120 against implementation 46c13a6.
#      The world's response is then pointed at a DIFFERENT implementation, so the
#      only thing under test is the implementation comparison.
R120=REV-20260814-120
APPROVAL=211d378628886c0683f817af31454f442dc3ada7
APPROVED_IMPL=46c13a6c132f8ff7428876e6806ee2fd5709a583
world t13
# Deliberately use the protocol's minimum reviewer header. Closure must derive
# the canonical response path exactly as approval and the state generator do.
printf '<!-- rev: %s -->\n<!-- verdict: APPROVED -->\n<!-- reviewed-implementation: %s -->\n\n# t\n' \
    "$R120" "$APPROVED_IMPL" > "$W/docs/internal/reviews/$R120.md"
respond "$R120" IMPLEMENTED "$TIP"
if tx close "$R120" --approval-commit="$APPROVAL" --expected-parent="$TIP"; then
    bad "closure refuses when the approval covered a superseded implementation" "it succeeded"
else
    grep -q 'no longer on the table' "$TMPD/out" \
        && ok "closure refuses when the approval covered a superseded implementation" \
        || bad "closure refuses when the approval covered a superseded implementation" "$(head -1 "$TMPD/out")"
fi

# T13b. CONTROL: the same approval closes cleanly when the response still submits
#       exactly what was approved. Without this, a close that refused everything
#       would pass T13.
respond "$R120" IMPLEMENTED "$APPROVED_IMPL"
tx close "$R120" --approval-commit="$APPROVAL" --expected-parent="$TIP" \
    && ok "the same approval closes cleanly when the implementation still matches (control)" \
    || bad "the same approval closes cleanly when the implementation still matches (control)" "$(cat "$TMPD/out")"

# T14. F4: replaying an approval must still VERIFY, not return early. The first cut
#      answered "nothing to do" over a tree whose derived views had been damaged.
txworld t14
tx approve "$R" --implementation="$sha1" --expected-parent="$TIP"
echo 'tampered' >> "$W/docs/project/OPEN-THREADS.md"
if tx approve "$R" --implementation="$sha1" --expected-parent="$TIP"; then
    grep -q 'derived views verified' "$TMPD/out" \
        && ok "an idempotent replay repairs and verifies rather than returning early" \
        || bad "an idempotent replay repairs and verifies rather than returning early" "$(cat "$TMPD/out")"
else
    bad "an idempotent replay repairs and verifies rather than returning early" "$(cat "$TMPD/out")"
fi
REVIEWCTL_REPO="$W" "$CTL" --verify >/dev/null 2>&1 \
    && ok "...and the tampered view is no longer accepted afterwards" \
    || bad "...and the tampered view is no longer accepted afterwards" ""
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
