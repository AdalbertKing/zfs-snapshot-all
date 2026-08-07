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

# ---- the happy path, one transition at a time ------------------------------
world a; review $R CHANGES-REQUIRED -
expect "canonical review, no response -> OPEN" $R OPEN

world b; review $R CHANGES-REQUIRED -;            respond $R IMPLEMENTED sha1
expect "response submits sha1, unreviewed -> IMPLEMENTED" $R IMPLEMENTED

# The label on this case was right and its expectation was wrong: it pinned the
# bug instead of the contract, and the reviewer caught it, not me
# (REV-20260807-065). Rejection of the SUBMITTED sha is the one backward
# transition the protocol has.
world c; review $R CHANGES-REQUIRED sha1;         respond $R IMPLEMENTED sha1
expect "reviewer rejects the submitted sha -> OPEN" $R OPEN
# State alone is not the contract -- routing is. A rejected submission whose
# owner still reads Reviewer sends the reviewer back to the sha they rejected.
row="$(awk -F'|' -v r=" $R " '$2==r {print}' "$W/docs/internal/reviews/REVIEW_LEDGER.md")"
case "$row" in *"| Claude |"*) ok "rejection routes back to Claude" ;;
  *) bad "rejection routes back to Claude" "$row" ;; esac
case "$row" in *"implement and respond"*) ok "rejection asks for an implementation, not a review" ;;
  *) bad "rejection asks for an implementation, not a review" "$row" ;; esac

world c2; review $R CHANGES-REQUIRED sha1;        respond $R IMPLEMENTED sha2
expect "after rejection, advancing to sha2 -> IMPLEMENTED again" $R IMPLEMENTED

world d; review $R CHANGES-REQUIRED sha1;         respond $R IMPLEMENTED sha2
expect "response advances to sha2 -> IMPLEMENTED" $R IMPLEMENTED

world e; review $R APPROVED sha2;                 respond $R IMPLEMENTED sha2
expect "reviewer approves the submitted sha -> APPROVED" $R APPROVED

world f; review $R APPROVED sha2; respond $R IMPLEMENTED sha2; closure $R deadbeef
expect "closure on top of a matching approval -> CLOSED" $R CLOSED

# ---- the cases that must NOT be accepted -----------------------------------
# Approval that names a different commit than the one on the table is not
# approval of what is on the table. This is the one that would otherwise let a
# stale verdict close current work.
world g; review $R APPROVED sha1;                 respond $R IMPLEMENTED sha2
expect "approval for sha1 while sha2 is submitted -> not APPROVED" $R IMPLEMENTED

world h; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED sha1; closure $R deadbeef
expect "closure without an approval -> refused" $R FAILED

world i; review $R CHANGES-REQUIRED -
cp "$W/docs/internal/reviews/$R.md" "$W/docs/internal/reviews/$R-EXTRA.md"
expect "two files claiming one REV identity -> refused" $R FAILED

world j; respond $R IMPLEMENTED sha1
expect "orphan response with no review -> refused" $R FAILED

world k; review $R CHANGES-REQUIRED -; closure $R deadbeef
out="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "orphan-ish closure without approval refuses" || bad "orphan-ish closure without approval refuses" "$out"

world l; printf '<!-- rev: %s -->\n<!-- verdict: MAYBE -->\n' "$R" > "$W/docs/internal/reviews/$R.md"
expect "malformed verdict -> refused, not guessed" $R FAILED

world m; review $R CHANGES-REQUIRED -; respond $R IMPLEMENTED sha1; closure $R ""
out="$(REVIEWCTL_REPO="$W" "$CTL" --generate 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "closure with no closed-by refuses" || bad "closure with no closed-by refuses" "$out"

# ---- generated views must match the facts ----------------------------------
world n; review $R APPROVED sha2; respond $R IMPLEMENTED sha2
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
