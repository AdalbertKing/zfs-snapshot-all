# IMPLEMENTER CONTROL RESET

Status: ACTIVE — read before taking the next implementation step.
Owner intervention is not required for this reset.

## Single active work item

**REV-20260811-102 → Implementer (Claude) — WORK IN PROGRESS.**

REV-102 is not complete. Its current response used `response-status: IMPLEMENTED` for a partial delivery, which caused `reviewctl`/derived views to hand the whole finding to the Reviewer even though the response itself records unfinished implementer obligations.

Remaining REV-102 scope is limited to:

1. migration/audit for existing CONFIGs that lack source retention;
2. the minimum continuity/bookmark/recursive evidence required by the finding.

Do not repeat already-proven REV-102 work unless the remaining implementation changes its dependency boundary.

## Closed work

REV-20260811-107 is CLOSED. Do not modify or reopen it. The Reviewer corrected the reviewer-owned closure schema and the derived views were regenerated.

## Control-protocol regression

Fix the status/control regression minimally while completing REV-102:

- a partial response must not transfer ownership of the whole REV to the Reviewer;
- `IMPLEMENTED` must mean the complete finding is ready for independent review;
- use the smallest compatible representation for work-in-progress/partial evidence;
- do not redesign `reviewctl` or the wider protocol incidentally.

If the existing four-state V2 contract intentionally forbids a fifth workflow state, preserve that contract: partial evidence must remain non-transitioning rather than inventing a competing workflow state. The goal is unambiguous ownership, not a new state taxonomy.

## Required handoff

When — and only when — all remaining REV-102 obligations are complete:

1. update the existing REV-102 response into one complete final evidence package;
2. mark it `IMPLEMENTED` only at that point;
3. regenerate derived views;
4. verify `OPEN-THREADS` unambiguously routes REV-102 to Reviewer;
5. stop at the review boundary.

After Reviewer approval/closure, if there is no blocker or Owner decision pending, resume the next item in the accepted project plan automatically. Do not wait for the Owner to type "go on".

## Scope guard

This reset is not permission to broaden product scope, reopen closed findings, run an indiscriminate full test campaign, or start later Phase 5 work early. Use targeted regression tests plus dependency-driven cascade and only the environment proof required by the changed boundary.

## Communication rule

Do not ask the Owner to relay reviewer/implementer synchronization messages. Repository artifacts are the coordination channel. If an artifact owned by the other role is malformed, report it through the protocol; do not silently reinterpret product state from a stale derived view.
