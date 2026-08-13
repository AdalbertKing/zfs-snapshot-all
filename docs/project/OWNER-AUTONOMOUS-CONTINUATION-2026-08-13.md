# OWNER DECISION — autonomous continuation without Owner relay

Date: 2026-08-13
Status: ACTIVE

## Problem observed

The review protocol can determine `whose move` correctly while the project still
stalls because the next actor is not actively picked up. A passive hourly watcher
or a heartbeat proves observation, but it does not itself continue the work.
The Owner explicitly requires work to continue without his intervention whenever
the next action is already determined by the accepted project contracts.

## Required operating rule

The scheduled Reviewer cycle is an **active reviewer/orchestrator loop**, not a
passive monitor.

On every cycle it must:

1. freshly read current `main`;
2. perform the safe GitHub WRITE/read-back probe on `reviewer-write-probe`;
3. read generated routing, CI and both peer-context channels;
4. if the move is Reviewer's, perform the actual review/approval/rejection/closure
   work immediately, without waiting for an Owner message;
5. if the move is Claude's and no fresh Claude activity follows the last handoff,
   publish one concise Reviewer peer handoff naming the exact published SHA and the
   next dependency-ready action from canonical project state;
6. after closing a review, explicitly release the next already-scoped step to
   Claude rather than ending at `CLOSED` / `whose move`;
7. escalate to Owner only for a new product/architecture choice, accepted-risk
   decision, scope/priority change, or production-data safety decision.

Do not create a formal REV merely to wake or remind the other lead. Do not repeat
an identical peer handoff every cycle.

## Heartbeat change

The old requirement for an hourly repository heartbeat is superseded by this
Owner decision.

A scheduled cycle must **not create a main commit solely to prove that it ran**.
Liveness/audit evidence is instead:

- the safe `reviewer-write-probe` READ/WRITE/read-back result; and
- real review, closure, routing or peer-handoff artifacts when actual work requires
  them.

This reduces artificial commits and prevents the monitoring mechanism from
becoming project work of its own.

## Current execution priority

Until Gate 7 closes:

- Phase 7 Restore is PRIMARY;
- read-only RUX-1 may be used only in a genuine window where Restore is blocked
  waiting for Reviewer work;
- after Gate 7, continue directly with RUX-1 -> RUX-2 -> RUX-3 -> RUX-4 without
  another Owner confirmation.

## Transport limitation and correctness rule

Peer-context/GitHub can release work but cannot guarantee that an externally idle
Claude process/session is physically awakened. Direct model-to-model triggering is
a transport/orchestration improvement, not a correctness dependency of the review
protocol.

Until a direct bridge exists, the active Reviewer loop must remove all avoidable
Reviewer-side stalls and leave an exact durable handoff whenever Claude is the next
actor. Failure of any future bridge must never stop the GitHub/shared-git protocol
from operating correctly.
