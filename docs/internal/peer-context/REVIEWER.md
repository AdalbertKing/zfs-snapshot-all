# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of
a reply means nothing. Rolling and compact by design. Canonical conclusions live
in code, tests, design/review artifacts and project documents.

---

id: R-025
published-state: 2028bc62ef37de5c2d3895b34d51fe14274514a2
timestamp: 2026-08-13 21:12 Europe/Warsaw
context: Manual Check independently confirmed the remaining REV-119 residual and
  reviewed `restore-grammar-analysis.md`.
to-peer: Keep the ordinary public surface minimal: `restore SOURCE [DESTINATION]
  [--at] [--yes]` is a strong candidate, but transport/account syntax should not
  become ordinary CLI. Destination identity must resolve through existing authority
  or refuse; managed-copy source paths must resolve through CONFIG rather than adopt
  arbitrary local datasets.
needs-formal-answer: no

---

id: R-026
published-state: 7bb91f5d6cbaf75367c2c70872d77fd2208944c5
timestamp: 2026-08-13 23:00 Europe/Warsaw
context: REV-119 is APPROVED and CLOSED after independent verification of round 5.
  The dedicated boundary failure regression now reaches the post-fence branch,
  exact-head `5e27540027a7518bac6302ebef0b2474514d2851` CI is green, and the closure is
  durable at `docs/internal/reviews/closures/REV-20260813-119.md`.
to-peer: Continue the primary Phase 7 track without waiting for Owner: implement
  the next INTERNAL execution slice under the reviewed gates, still without
  attaching the public parser. Scope it to the resolved local single-dataset path,
  keep the reviewed fence and final verification properties, and preserve truthful
  cleanup/failure reporting. Add targeted tests and bounded live-ZFS proof because
  real ZFS semantics matter. Do not broaden this slice to relation-level policy or
  cross-host public CLI. Gate 7 is not yet reached.
needs-formal-answer: no

---

id: R-027
published-state: d104f556055bca590d747d252877fa8333a8f432
timestamp: 2026-08-14 00:13 Europe/Warsaw
context: Manual Check independently re-read the closed REV-119 production change
  (`77df5b4`) and round-5 evidence (`a18aa62`). Closure is valid, routing is clean
  with nothing open, exact `d104f55` CI is green, and reviewer WRITE/read-back is
  exact on that head. No newer execution implementation is present.
to-peer: Continue now with the INTERNAL Phase 7 execution slice from R-026; there is
  no review or Owner blocker. Keep the public parser unattached. For the later final
  grammar pass, carry `docs/discussions/RESTORE-CLI-LOW-PATH-OWNER-2026-08-13.md`:
  one grammar for one- and two-host layouts, relationship selector plus first-class
  direct managed-copy `POOL/PATH`, both resolving into the same planner/provenance
  model; unknown or ambiguous paths refuse. Ordinary CLI should still hide lower-
  layer transport/account mechanics.
needs-formal-answer: no
