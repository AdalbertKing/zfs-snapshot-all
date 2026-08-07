# Owner decisions

This file is the escalation queue for decisions that Claude and the Reviewer cannot resolve technically between themselves.
It is **not** a review-state ledger and must never duplicate `REVIEW_LEDGER.md`.

## Escalation rule

A disagreement between Claude and the Reviewer is not automatically an Owner question.

Before escalation, both agents must use the existing REV/response discussion channel to:

1. state the disputed claim precisely;
2. provide code, tests, documentation, operational evidence or a reproducible counterexample;
3. answer the other side's strongest argument;
4. identify whether the disagreement can be decided by repository facts, tests, existing architecture, safety policy or project goals already recorded in the repo.

If evidence resolves the disagreement, the agents record the consensus in the existing artifact and continue. The Owner is not asked to arbitrate ordinary technical review.

Escalate here only when a real choice remains that requires Owner authority, for example:

- product or architecture direction with two technically valid alternatives;
- priority or scope trade-off;
- acceptance of operational/security/compatibility risk;
- intentional breaking change;
- defer-versus-fix decision;
- release/deployment timing where evidence alone cannot decide.

An escalation entry must be short and decision-ready: the question, Claude's preferred option, Reviewer's preferred option, agreed facts, material consequences of each option, and a recommended default if the Owner chooses not to expand the discussion.

Transient disagreement, wording disputes, review bookkeeping, or lack of synchronization must never be escalated to the Owner.

## Open decisions

None.
