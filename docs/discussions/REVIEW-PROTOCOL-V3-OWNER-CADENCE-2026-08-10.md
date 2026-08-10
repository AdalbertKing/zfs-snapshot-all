# REVIEW PROTOCOL V3 — Owner cadence requirement

Status: OWNER REQUIREMENT / input to Claude + Reviewer V3 agreement
Date: 2026-08-10

## Owner-observed failure

When a review thread reaches a state where no actor can add new evidence in the current execution context, project work can stop until the Owner manually tells the agents to continue. This is especially harmful in unattended/night work: a parked live-host proof or review ping-pong can consume the remaining cadence and leave the planned next independent work slice untouched.

The Owner explicitly requires the protocol to prevent this. Forward progress after a parked thread must be automatic under the agreed project plan; it must not require a fresh Owner prompt.

## Required invariant

**A review/evidence thread may block only work that has a demonstrated dependency on that thread. It must not consume or suspend the project cadence for independent planned work.**

Once a thread has no immediately executable next action for the current actor/context, the actor must:

1. record the exact outstanding obligation and who/what context can satisfy it;
2. classify its blocking scope;
3. park that thread without repeated no-new-information responses;
4. immediately select the next planned work item whose dependency prerequisites are satisfied;
5. continue work in the same scheduled/unattended run without waiting for Owner intervention.

This is a liveness requirement, not merely documentation guidance.

## Default scheduling rule

`EVIDENCE-PENDING` defaults to **non-blocking for subsequent independent development**.

It may block release/production activation of the affected behavior. It becomes a `next-slice blocker` only when a concrete dependency edge is stated: the next slice relies on the unproved property strongly enough that continuing would create invalid work or unsafe assumptions.

An OPEN/APPROVED review thread similarly does not globally stop development unless its scope explicitly blocks the next planned item.

## No-work-left behavior

If the current planned item is parked and there is no immediately executable child task, the actor must consult the project plan/status/backlog and take the next dependency-ready item. `Nothing actionable on the current REV` is not equivalent to `nothing actionable in the project`.

Only stop the unattended cadence when one of these is true:

- every dependency-ready planned item genuinely requires Owner input;
- every dependency-ready planned item requires an unavailable execution context (for example attended destructive host access);
- continuing would violate an explicit freeze/gate with a demonstrated dependency;
- the plan/backlog contains no dependency-ready work.

When stopping for one of those reasons, record the exact reason and the smallest Owner action needed. Do not merely wait on an evidence-only thread.

## Implication for reviewctl / routing

The proposed `evidence: PENDING` state must not route to `Claude / implement and respond` when code is already accepted. More importantly, review routing and project-work routing are separate concerns:

- reviewctl answers who owns the review thread and what closes it;
- project status/plan answers what dependency-ready implementation work proceeds next.

Protocol V3 should explicitly require the scheduled actor to perform both decisions. An unresolved review row must not be interpreted as a global scheduler lock unless its blocking scope reaches the next planned item.

## Concrete REV-093 example

Desired state:

- code: ACCEPTED
- evidence: PENDING (attended live ZFS)
- Phase 3.5 production approval: pending
- REV-093: parked until eligible live evidence appears
- Phase 4 or other independent next planned slice: starts automatically in the next available implementation cadence, without Owner saying "go on"

## Request to Claude

Please incorporate this as a first-class V3 liveness/cadence invariant when proposing the final backward-compatible protocol amendment. In particular, propose the smallest mechanism that makes unattended continuation explicit and testable rather than relying on an agent remembering an informal convention.

Reviewer position: this requirement is stronger than the earlier statement that manual reviews do not shift the schedule. V3 should define the positive action after parking: **select and execute the next dependency-ready planned work item**.
