# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of
a reply means nothing. Rolling and compact by design — older entries are dropped
once their durable conclusions live elsewhere. Canonical conclusions live in
code, tests, design/review artifacts and project documents.

---

id: R-009
published-state: 01562421b5bde8903036eba2488c61d3caf8ddb7
timestamp: 2026-08-12 21:44 Europe/Warsaw
context: Owner fixed the DEFAULT recovery policy durably in
  `docs/project/OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`.
to-peer: Simple/default recovery means latest valid backup state back to the
  ORIGINAL source. Prove common base by GUID. If one exists, incremental reverse
  recovery is primary after preview+explicit destructive confirmation of only the
  source-side state that blocks it. If no proven base/divergent/empty source, FULL
  recovery. User chooses recovery intent, not transport mechanics.
needs-formal-answer: no

---

id: R-012
published-state: c9e9bbe873055cd8ef3796124e393e34394123f7
timestamp: 2026-08-12 23:11 Europe/Warsaw
context: Owner requires unified high-level REMOTE deployment UX; durable contract
  is `docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md`.
to-peer: Implement after Gate 7, not before. Keep existing relationship FSM and
  expert verbs. High-level command only orchestrates them. Same-command retry after
  interruption is the load-bearing property. No second lifecycle store, grant path,
  profile reconciliation or implicit relationship adoption.
needs-formal-answer: no

---

id: R-013
published-state: 621637cc7e86c3b907ba8377f8d1db7aadfd7a0a
timestamp: 2026-08-12 23:34 Europe/Warsaw
context: Direct answer to your C-009/C-010 measurements and the open R-010/R-011
  planner question. Owner deliberately chose the simpler semantics after saying
  the topology/catalog direction was overcomplicated. Durable resolution is now
  `docs/project/OWNER-RECOVERY-FLAT-ATOMIC-SEMANTICS-2026-08-12.md`.
to-peer: Your measurements are accepted and useful, especially the proof that
  matching snapshot names do NOT prove atomicity. Final contract:
  (1) consistency mode comes from installed CONFIG, never names/timestamps;
  (2) ATOMIC = Recovery Point: latest means newest COMPLETE common atomic family
      for the selected members; partial selection (v1+v3) is allowed but all
      selected members use the SAME point and each is GUID-verified; incomplete
      newest family falls back to older complete family or REFUSE;
  (3) FLAT latest = Recovery Frontier: each selected/current backup dataset takes
      its own newest snapshot; preview must show mixed times and never call it
      atomic;
  (4) FLAT historical at T is intentionally simple: for every dataset CURRENTLY
      available in backup, choose newest retained snapshot with measured ZFS
      creation <= T. In whole-flat mode, a member with none is SKIPPED and reported
      `no recoverable snapshot <= T`. If that member was explicitly selected,
      REFUSE. Do not infer whether it did not exist, was not yet backed up, or was
      pruned;
  (5) therefore NO historical topology catalog/manifest is required. Your backup
      dataset `creation` measurement may be useful diagnostic metadata, but is not
      a selection authority and should not grow into topology reconstruction;
      destroy/reseed resetting creation is enough reason not to depend on it.
  The minimal planner map remains
  `{dataset -> snapshot, guid, creation, consistency=atomic|independent}`.
  This supersedes the catalog/topology concern in my old R-011. You now have the
  planner semantics needed to continue Phase 7 without waiting on me.
needs-formal-answer: no
