# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of
a reply means nothing. Rolling and compact by design — older entries are dropped
once their durable conclusions live elsewhere. Canonical conclusions live in
code, tests, design/review artifacts and project documents.

---

id: R-017
published-state: 2787bdb6df73394bb88632ec0655b4a3aae9558c
timestamp: 2026-08-13 11:39 Europe/Warsaw
context: C-017 correctly exposed a conflict, but the conflict was introduced by my
  R-016 wording, not by the authoritative Owner recovery contract. I re-read
  `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`: for a proven common base it
  explicitly requires preview of the source-side state that blocks recovery,
  explicit destructive confirmation, removal/rollback of only that blocking state,
  then INCREMENTAL B..L. Preservation of a second recoverable copy of divergent
  source state is NOT a requirement of the simple/default path.
to-peer: Correct R-016 as follows and do not escalate to Owner. The ordinary
  recovery path MUST stay zero-choice with respect to transport/preservation:
  preview exactly what will be lost, require explicit destructive confirmation,
  then discard/rollback the blocking divergent state and use the GUID-proven
  incremental when possible. Do NOT add a mandatory
  `--preserve-source` vs `--discard-source-changes` policy choice to default
  recovery; that would contradict the Owner's zero-choice simple path. Shape B is
  therefore not needed for Gate 7, and shape A/rename-aside belongs, if ever useful,
  to an explicit advanced/non-destructive recovery capability alongside side/into
  restore, not to the default contract. A pre-destruction snapshot may still be
  used as an execution safety/measurement step after confirmation if it closes the
  REV-118 open-TXG uncertainty, but if the subsequent rollback destroys that
  snapshot it MUST NOT be described as preservation or as recoverable safety state.
  Update the design note so point 3 is no longer claimed as settled Owner policy,
  then continue the smallest destructive-execution slice under R-009/R-013 without
  waiting for Owner or Reviewer.
needs-formal-answer: no

---

id: R-018
published-state: 27efcc6f62ab4ae014a86216f5e80e65f6f7ad9d
timestamp: 2026-08-13 13:02 Europe/Warsaw
context: Fresh orchestration pass: main is unchanged since R-017, REVIEW_LEDGER is
  fully CLOSED, OPEN-THREADS is empty, PROJECT_STATUS correctly says destructive
  replacement is not implemented, and exact-head CI is green. One canonical-doc
  drift matters before coding: `ACTIVE-WORK-PLAN.md` Phase 7 still carries the
  older bullets "destructive replacement as a separate verb" and "mandatory
  pre-restore snapshot". The later Owner recovery contract of 2026-08-12 expressly
  supersedes the old safe-side default and makes ordinary/latest->original recovery
  destructive after preview+confirmation; R-017 already resolves preservation.
  Separately, Owner is actively deciding the PUBLIC restore selector/destination
  grammar, so that surface must not be frozen by an implementation slice yet.
to-peer: Treat the Phase 7 bullets in ACTIVE-WORK-PLAN as historical where they
  conflict with `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`, R-009/R-013/R-017;
  do not resurrect a separate destructive verb or a mandatory preserved-copy
  policy from the older plan. You MAY continue Phase 7 below the public CLI
  boundary: correct `docs/design/destructive-recovery-contract.md` per R-017 and
  build/refine the smallest internal execution helper + targeted tests for
  preview->confirmation->rollback/blocker removal->GUID-proven incremental/full
  fallback->GUID verify, provided it adds no new public restore grammar. Do NOT
  commit new public flags/positional syntax (`--replace`, preserve/discard choices,
  selector/destination grammar) until the Owner's current CLI decision is made
  durable. No formal REV is open and no Owner escalation is needed for the
  technical execution path.
needs-formal-answer: no

---

id: R-019
published-state: 2bdf0286a29863fb3b89b08acd3650290438629c
timestamp: 2026-08-13 16:52 Europe/Warsaw
context: Manual Check finds no implementer commit or C-018 after R-018, while the
  repository remains healthy: all formal REVs are CLOSED, OPEN-THREADS is empty,
  PROJECT_STATUS still correctly says destructive execution is absent, and exact
  `2bdf0286...` CI is green. The Owner's restore CLI discussion is intentionally
  still open; that blocks only the PUBLIC selector/destination grammar, not the
  internal execution path.
to-peer: Continue Phase 7 NOW below the public CLI boundary. First correct
  `docs/design/destructive-recovery-contract.md` so it no longer treats preservation
  as default policy. Then implement the smallest internal, non-public execution
  helper and targeted tests for the already-settled chain:
  preview facts -> explicit confirmation boundary -> remove/rollback only blockers
  -> GUID-proven incremental when a common base exists -> full fallback only when
  no valid base exists -> verify resulting recovery point by GUID. Do not add or
  freeze any public positional/flag grammar while Owner is still deciding it.
  Publish C-018 with the exact implementation SHA when that dependency-ready slice
  lands; do not wait for another Owner or Reviewer message.
needs-formal-answer: no
