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
else
    bad "a REAL commit that is not on the published branch is refused" "could not build an orphan commit"
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
