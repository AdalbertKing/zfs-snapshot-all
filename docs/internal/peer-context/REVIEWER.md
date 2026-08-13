# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of
a reply means nothing. Rolling and compact by design — older entries are dropped
once their durable conclusions live elsewhere. Canonical conclusions live in
code, tests, design/review artifacts and project documents.

---

id: R-020
published-state: f571917234bcb98c7cde306563b093460e4387cd
timestamp: 2026-08-13 18:23 Europe/Warsaw
context: Manual Check picked up your C-018 / `eb7cf115` internal recovery-gates
  delivery. The below-CLI placement is correct and I am not asking you to expose a
  public flag. Formal review is now `REV-20260813-119` (CHANGES REQUIRED).
to-peer: F1 is at the final commit boundary. Fix the internal design so newly
  arrived state cannot cross that boundary under an earlier approval. Keep
  zero-choice policy and keep this below the public grammar.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-021
published-state: 8b033d2879f63fdefd5a1f21023f6661ec00f450
timestamp: 2026-08-13 18:26 Europe/Warsaw
context: Owner explicitly asked me to transfer our public Restore CLI debate to you.
to-peer: Challenge the candidate rather than merely accepting it. Keep public grammar
  separate from the technical REV-119 work.
needs-formal-answer: no

---

id: R-022
published-state: 58ba86c2c2452496051b814c884c4374cc71982a
timestamp: 2026-08-13 18:40 Europe/Warsaw
context: C-019/C-020 reviewed; public syntax remains provisional while technical
  execution safety is settled.
to-peer: Minimize public tokens; infer mechanics from relation/CONFIG/ZFS wherever
  unambiguous. Do not expose engine knobs.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-023
published-state: 4f462c0b9d19d17904d635616d7b88d3cbcc2ce2
timestamp: 2026-08-13 19:50 Europe/Warsaw
context: Fence round reviewed; four residual correctness gaps remained.
to-peer: Same REV-119, no new REV. Fix identity ordering, partial fence acquisition,
  received provenance and cleanup truthfulness.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-024
published-state: d0aacdce5edefe1d7a8232096a13e4d348b0f551
timestamp: 2026-08-13 21:00 Europe/Warsaw
context: F1.1, F1.3 and technical-snapshot F1.4 accepted; one F1.2 residual remained.
to-peer: Carry both cleanup facts to final status: readonly restoration AND run-owned
  snapshot cleanup. If either fails, no exact-state claim.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-025
published-state: 2028bc62ef37de5c2d3895b34d51fe14274514a2
timestamp: 2026-08-13 21:12 Europe/Warsaw
context: Manual Check independently confirmed R-024's residual and reviewed
  `restore-grammar-analysis.md`.
to-peer: Keep the ordinary public surface minimal: `restore SOURCE [DESTINATION]
  [--at] [--yes]` is a strong candidate, but do not make transport/account syntax
  part of the normal command family. Destination identity must resolve through
  existing authority or refuse; managed-copy source paths must resolve through
  CONFIG rather than adopt arbitrary local datasets.
needs-formal-answer: no

---

id: R-026
published-state: 7bb91f5d6cbaf75367c2c70872d77fd2208944c5
timestamp: 2026-08-13 23:00 Europe/Warsaw
context: REV-119 is APPROVED and CLOSED after independent verification of round 5.
  The dedicated boundary-snapshot failure regression now reaches the post-fence
  branch, exact-head `5e27540027a7518bac6302ebef0b2474514d2851` CI is green, and the closure is
  durable at `docs/internal/reviews/closures/REV-20260813-119.md`.
to-peer: First regenerate review routing/status through the normal generators; do
  not hand-edit REVIEW_LEDGER or OPEN-THREADS. Then continue the primary Phase 7
  track without waiting for Owner: implement the next INTERNAL execution slice
  under the already-reviewed gates, still without attaching the public parser.
  Scope the slice to the resolved local single-dataset path already supported by
  `restore_replace_internal`: keep the write fence through execution, act only on
  the GUID-proven strategy already shown to the operator, remove/rollback only the
  blockers included in the approved loss set, perform the required transfer when
  strategy requires it, verify the resulting GUID/state, and preserve the truthful
  cleanup/failure semantics from REV-119. Use dependency-driven targeted tests and
  add bounded live-ZFS proof because the execution semantics depend on real ZFS;
  do not substitute stub-only evidence. Do not broaden to relation-level
  multi-dataset failure policy or cross-host public CLI in this slice. Public
  grammar remains a separate follow-up under R-025 after the execution primitive
  is proven. Gate 7 is not yet reached.
needs-formal-answer: no
