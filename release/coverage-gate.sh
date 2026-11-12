#!/bin/bash
# release/coverage-gate.sh -- every behaviour change in a release has a review (REV-20261112-195 F4).
#
#   coverage-gate.sh <dev-repo> <previous-release-rev> <rev> <paths-file> < REVIEW_LEDGER.md (of <rev>)
#
# review-gate.sh judges the rows the ledger HAS. A change nobody submitted has no row, so it
# passed by absence: 1.0.19 published the bookmark-wins engine change that way (2026-11-12).
# This gate asks the other question: is every commit since the previous release that touches a
# shipped run-time file covered by some review? Covered = an ancestor of (or equal to) a SHA the
# ledger names, as a response's implementation or as the revision a Reviewer reviewed. Merges,
# and commits that touch only docs, tests or release scaffolding, are not behaviour.
# <paths-file>: the shipped run-time paths, one per line (publish.sh writes it from the MANIFEST).
# Exit 0 = covered; 1 = refused, with every uncovered commit named; 2 = could not run.
set -u

dev="$1" prev="$2" rev="$3" paths_file="$4"
ledger=$(cat)
printf '%s\n' "$ledger" | grep -q '^| REV' || { echo "coverage-gate: the input is not a REVIEW_LEDGER.md (no REV rows)" >&2; exit 2; }
git -C "$dev" cat-file -e "$prev^{commit}" 2>/dev/null || { echo "coverage-gate: the previous release's revision '$prev' is not a commit of $dev" >&2; exit 2; }
git -C "$dev" cat-file -e "$rev^{commit}" 2>/dev/null || { echo "coverage-gate: '$rev' is not a commit of $dev" >&2; exit 2; }
mapfile -t paths < <(grep -v '^[[:space:]]*$' "$paths_file")
[ "${#paths[@]}" -gt 0 ] || { echo "coverage-gate: no run-time paths given" >&2; exit 2; }

# Every SHA the ledger names (implementation, reviewed); one the repo does not have covers nothing.
nots=()
while IFS='|' read -r _ r _ _ impl reviewed _; do
    r=${r// /}; case "$r" in REV-*) ;; *) continue ;; esac
    for s in ${impl// /} ${reviewed// /}; do
        case "$s" in *[!0-9a-f]*|'') continue ;; esac
        git -C "$dev" cat-file -e "$s^{commit}" 2>/dev/null && nots+=("^$s")
    done
done <<< "$ledger"

uncovered=$(git -C "$dev" rev-list --no-merges "$rev" "^$prev" "${nots[@]}" -- "${paths[@]}") \
    || { echo "coverage-gate: git rev-list failed" >&2; exit 2; }
if [ -n "$uncovered" ]; then
    echo "coverage-gate: these commits since the previous release ($(git -C "$dev" rev-parse --short "$prev")) change shipped run-time files and no review covers them -- refusing to publish. Submit them (PROTOCOL V3.14 batch, or the response of the REV they answer), then publish again:" >&2
    while IFS= read -r c; do
        git -C "$dev" log -1 --format='  %h %s' "$c" >&2
    done <<< "$uncovered"
    exit 1
fi
exit 0
