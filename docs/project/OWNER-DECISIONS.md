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

## Currently queued

Carried over from the pre-V2 thread table. Each is a real choice that repository
facts cannot settle.

| # | Item | Whose move |
|---|---|---|
| 8 | PR #4 — a SECOND implementation of logical pause | owner: confirm the close, or say what else to salvage |
| 9 | Issue #3 — enrolment contract consensus | owner+reviewer |
| 11 | Profiles + live recursion (backlog) | owner |
| 14 | `docs/OPS_MONITORING.md` untracked | owner: keep or drop |
| 15 | Two sessions built the same feature the same day | owner: decide how parallel sessions announce what they are taking |
| 36 | Grants on pve0 are per-dataset, not on the parent | owner: per-dataset (today) or parent grant |
| 32 | Plan: method + stages | owner+reviewer: approve or amend |
| 29 | Engine CLI / profiles / restore — design discussion | owner+reviewer: discuss |
| 30 | Atomic restore point — measured, and one gap | owner+reviewer: accept into the pre-freeze engine slice |
