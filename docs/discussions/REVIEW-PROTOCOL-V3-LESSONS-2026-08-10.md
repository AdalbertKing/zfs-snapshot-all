# REVIEW PROTOCOL V3 — lessons and proposed amendments

Status: PROPOSAL FOR CLAUDE + REVIEWER DISCUSSION
Date: 2026-08-10
Owner direction: capture lessons from this project so the protocol can be reused in other projects; reviewer and implementer should resolve details between themselves and escalate only unresolved policy choices to Owner.

## Problem observed

Review quality remained high, but workflow repeatedly stalled on protocol mechanics and on evidence that could not be produced in the current execution context. Examples included reviewer/response header spelling, generated routing metadata, and an evidence-only live-ZFS obligation being treated too much like a blocker for subsequent development.

The protocol should preserve strict evidence standards without turning every outstanding proof obligation into a global development stop.

## Proposed amendments

### 1. Separate CODE verdict from EVIDENCE state

A review should distinguish at least:

- CODE-ACCEPTED / CODE-CHANGES-REQUIRED
- EVIDENCE-COMPLETE / EVIDENCE-PENDING

A change may therefore be `CODE-ACCEPTED + EVIDENCE-PENDING`.

This means: no known production-code defect remains, but production approval of the affected environmental contract still waits for live proof.

### 2. Evidence debt does not automatically block subsequent development

An evidence-only obligation blocks only the release/production gate whose property it proves, unless the reviewer explicitly demonstrates a dependency from the next development slice to that unproved property.

Default rule:

`manual/live evidence pending != stop all development`

This operationalizes the existing Owner rule that manual reviews/proofs do not suspend or shift the schedule.

### 3. Every blocker must name its blocking scope

Avoid ambiguous labels such as simply `P1 blocker`.

Use a scope, for example:

- `release blocker`
- `production-activation blocker`
- `next-slice blocker`
- `migration blocker`
- `evidence debt / non-scheduling blocker`

A next-slice blocker requires a stated dependency edge explaining why work cannot safely continue.

### 4. Execution-context capability is part of evidence planning

Before demanding live proof, reviewer should establish whether the current actor/session can legally and safely perform it.

If proof requires attended destructive/mutating operations and the current session is unattended, the review should immediately record a reproducible proof recipe and classify the obligation as attended evidence debt rather than bounce it repeatedly between Reviewer and Implementer.

### 5. Protocol metadata failures are hygiene, not product findings

Malformed review headers, routing regeneration, ledger drift caused solely by review metadata, etc. should be repaired by the owner of that metadata and should not open a production REV unless they compromise a real product/test dependency.

Reviewer owns reviewer-file corrections. Implementer owns response-file corrections. Generated views are regenerated, never hand-edited.

### 6. Machine-validated review templates

Create/use one canonical helper/template for new REV artifacts so tokens such as `CHANGES-REQUIRED` cannot be mistyped and required headers cannot be omitted.

Prefer generation/validation at creation time over discovering formatting errors one hourly cycle later.

### 7. No ping-pong for already-understood obligations

Once both sides agree that:

- code has no known defect,
- only a specific external proof is missing,
- current execution context cannot produce it,
- exact reproduction steps are recorded,

then repeated implementer responses and reviewer re-reviews add no evidence. The thread should park in an explicit `EVIDENCE-PENDING` state until an eligible session supplies new evidence.

### 8. Review cadence remains independent

Manual reviews, attended proofs, or parked evidence debts do not suspend scheduled implementation/review activity. New deliveries continue to be reviewed normally. A parked thread wakes only when new relevant evidence/code appears.

### 9. Minimum sufficient evidence remains the rule

This amendment does NOT weaken evidence requirements. Continue to prefer:

`targeted regression + dependency-driven cascade + appropriate live proof + meaningful negative control`

over broad PASS-count campaigns.

Live-host proof remains mandatory where correctness depends on ZFS, crontab, UID/account identity, permissions, SSH/grants, deploy, or host state. The change is only that the protocol distinguishes production approval from scheduling the next independent development slice.

## Proposed state example

For REV-093 after code review:

- code: ACCEPTED
- evidence: PENDING (attended live ZFS)
- production approval for Phase 3.5: PENDING
- next independent development phase: NOT BLOCKED
- next action on REV-093: attended proof only; no further implementer/reviewer ping-pong until new evidence exists

## Questions for Claude

1. Does the CODE/EVIDENCE split fit `reviewctl` cleanly, or is a smaller representation preferable?
2. What is the smallest schema change that can express `EVIDENCE-PENDING` without destabilizing existing ledger/history?
3. Should blocker scope be a machine header, ledger field, or normative prose with only evidence state machine-readable?
4. Can REV creation be wrapped in a helper that emits canonical headers and validates tokens before commit?
5. Propose exact backward-compatible changes to PROTOCOL.md/reviewctl/OPEN-THREADS routing. Do not implement protocol machinery yet; respond with design tradeoffs first.

## Reviewer position

Prefer the smallest backward-compatible extension. Do not redesign a working review system merely to add vocabulary. The essential behavioral fix is: accepted code with unavailable attended proof must be parkable without falsely approving production behavior and without blocking unrelated subsequent work.
