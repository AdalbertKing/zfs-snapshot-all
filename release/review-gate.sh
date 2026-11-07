#!/bin/bash
# release/review-gate.sh -- the Reviewer's gate in front of a release (PROTOCOL V3.13).
#
#   review-gate.sh [ACCEPTED-REV,...] < REVIEW_LEDGER.md
#
# Owner decision 2026-11-07 (answering the Reviewer's F1 on PR #1127): implementation is merged
# into dev `main` on green CI -- that merge is the V2 submission -- and the Reviewer's verdict is
# required before the PUBLICATION instead. Hosts only ever receive the release repository, so
# this is where an unreviewed change would reach production.
#
# Reads the generated ledger of the revision being released. Every row in state OPEN or
# IMPLEMENTED is a review without a verdict for its current SHA; APPROVED and CLOSED pass.
# The Owner may accept the risk of a named open review explicitly (Owner authority, V3.7):
# such a REV is listed in the first argument. Exit 0 = may publish; prints one line per
# accepted REV ("accepted: REV-..."), for the release commit message. Exit 1 = refused, and
# the refusal names every blocking REV with its state.
set -u

accept=",${1:-},"
ledger=$(cat)
printf '%s\n' "$ledger" | grep -q '^| REV' || { echo "review-gate: the input is not a REVIEW_LEDGER.md (no REV rows)" >&2; exit 1; }

blocked=""
while IFS='|' read -r _ rev state owner _; do
    rev=${rev// /}; state=${state// /}; owner=${owner// /}
    case "$rev" in REV-*) ;; *) continue ;; esac
    case "$state" in
        APPROVED|CLOSED) continue ;;
    esac
    if [ "${accept#*,"$rev",}" != "$accept" ]; then
        echo "accepted: $rev ($state | $owner) -- Owner risk acceptance"
    else
        blocked="$blocked $rev($state|$owner)"
    fi
done <<< "$ledger"

if [ -n "$blocked" ]; then
    echo "review-gate: no Reviewer verdict for:$blocked -- refusing to publish (PROTOCOL V3.13). Wait for the verdict, or the Owner names each REV in --accept-open-review=REV-...,REV-..." >&2
    exit 1
fi
exit 0
