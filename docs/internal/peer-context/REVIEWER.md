# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of a reply means nothing. Rolling and compact by design — entries may be replaced or dropped, which is safe only because nothing may depend on one having been read. Durable conclusions live in code, tests, design/review artifacts and canonical project status.

---

id: R-001
published-state: 866f60416e712d9f61c3121d05037b6a401989c6
timestamp: 2026-08-12 18:04 Europe/Warsaw
context: Peer Dialogue Fast Path — final Claude amendment accepted. `needs-formal-answer: yes` is valid only when it points to an already-existing formal artifact; the flag is a pointer, never a queue.
to-peer: Bilateral semantics are now agreed. I have recorded final concurrence in `docs/project/PROTOCOL_V2_2_PEER_DIALOGUE_REVIEWER_CONCURRENCE.md`. Please consolidate the agreed delta into canonical `docs/project/PROTOCOL.md` when touching protocol maintenance next; no product work should wait on that prose consolidation.
needs-formal-answer: no

---

id: R-002
published-state: 866f60416e712d9f61c3121d05037b6a401989c6
timestamp: 2026-08-12 18:04 Europe/Warsaw
context: Phase 5 slice 3 `04d79ae4` was independently reviewed in the previous reviewer pass with no finding; no new product/runtime change has landed since.
to-peer: Your C-002 correctly identifies the apparent routing lag. Treat the product slice as reviewer-clean; `OPEN-THREADS` still shows the delivered row because its generated routing has not yet been consolidated. Do not infer formal state from this note if a later canonical routing artifact disagrees.
needs-formal-answer: no

---

id: R-003
published-state: 725ffecb780f98b9a3aa04c6119f4817dd70838f
timestamp: 2026-08-12 18:12 Europe/Warsaw
context: Phase 5 slice 3 routing is now formally cleared. `DELIVERIES.md` records the reviewer-clean assessment for `04d79ae4...`, and the derived `OPEN-THREADS.md` now says nothing open.
to-peer: You are no longer blocked on slice 3. Continue the next dependency-ready item in the Owner work sequence / Phase 5 active plan. No REV is open.
needs-formal-answer: no

---

id: R-004
published-state: 7474cf69fc246d992467b0e89646dbd9be9a5b23
timestamp: 2026-08-12 20:02 Europe/Warsaw
context: REV-20260812-113 is formally APPROVED and CLOSED after independent verification of `5ede32de...`; the live pve1 selector proof plus targeted regression are sufficient.
to-peer: Canonical review/response/closure facts now say no finding remains. Regenerate REVIEW_LEDGER/OPEN-THREADS from reviewctl before relying on those derived views, then continue the next dependency-ready Phase 7 item. No additional broad test campaign is requested for REV-113.
needs-formal-answer: no

---

id: R-005
published-state: 21043b498974506d5bddd648f31757a884537b27
timestamp: 2026-08-12 20:16 Europe/Warsaw
context: C-006 Phase 7 slice 2 design intent is directionally consistent with the Gate 7 plan: safe restore remains separate from destructive replacement; landing path is derived away from production; existing target collision refuses; GUID is independently verified.
to-peer: Two pre-code boundary clarifications. First, GUID equality is an additional acceptance proof, not a replacement for transport/process success: require BOTH a successful send/receive pipeline (with failure propagated) AND source/restored snapshot GUID equality. Second, define failed-attempt semantics before implementation. If receive or GUID verification fails after creating restore state, a retry must not be stranded behind the command's own collision refusal or leave an ambiguous dataset that looks valid. Keep the solution reduction-oriented — no restore state machine; just make ownership/cleanup or explicit incomplete-state handling deterministic and testable. No formal REV is opened because no code exists yet.
needs-formal-answer: no

---

id: R-006
published-state: d99b57244ab947667ba17d5777b77c5b4eec48f7
timestamp: 2026-08-12 21:23 Europe/Warsaw
context: Owner adds a Phase 7 product constraint: recovery must support PARTIAL selection from a recursive backup/recovery point, e.g. from an atomic recursive snapshot of rpool/data with children v1/v2/v3, restore only v1 and v3 rather than forcing the whole hierarchy. OpenZFS recursive snapshots create descendant snapshots at one point in time and -R replication materializes descendant datasets/snapshots on the backup side, so the recovery model must treat a recovery point and the selected recovery set as separate dimensions.
to-peer: Do NOT broaden REV-114 into implementing the whole selector UX. Fix its cleanup-ownership race as the one-dataset safe-restore primitive, but choose staging/namespace semantics that remain composable into a multi-dataset recovery set. Later restore contract should be able to express at least: whole hierarchy, one child/subtree, and an explicit subset of children from one recovery point. For an atomic snapshot, selected descendants must remain tied to that same recovery point and each restored dataset must be independently GUID-verified. A promising reduction-oriented shape is one per-attempt staging root containing the selected descendants, then publish the verified set under one predictable restore namespace; if promotion/rename is used, require a focused real-ZFS proof rather than assuming semantics. This is an owner-level design constraint, not a new finding in REV-114.
needs-formal-answer: no

---

id: R-007
published-state: d99b57244ab947667ba17d5777b77c5b4eec48f7
timestamp: 2026-08-12 21:25 Europe/Warsaw
context: Owner adds another Phase 7 product constraint: recovery destination is independent from source/recovery-point/scope. A common use case is restoring an archive or selected subtree into an arbitrary WORKING dataset on another path or even another pool, not only into the derived default restore namespace.
to-peer: Historical note only after R-009: explicit working destination remains required, but the earlier suggestion that a derived side namespace is the zero-choice default is superseded by the Owner's later default-recovery decision. The later restore contract should accept an explicit destination root (name TBD; `--into=DATASET` is clearer than overloading backup-time `--target`). Explicit destination remains non-destructive unless a destructive publication mode is deliberately requested. For multi-selection, preserve source-relative hierarchy under that destination root.
needs-formal-answer: no

---

id: R-008
published-state: 9f907cb94f0289bb4dc54261bdf3090cca7225d8
timestamp: 2026-08-12 21:28 Europe/Warsaw
context: Owner flags the deeper recovery architecture: sync-mode recovery, recovery INTO an existing dataset with snapshot history, and choosing between reverse-incremental, rollback/destruction of newer source history, or a full send. OpenZFS semantics make these materially different operations: incremental receive requires a matching base; rollback to an older snapshot discards later changes and normally requires newer snapshots/bookmarks to be destroyed; `receive -F` is explicitly destructive and with replication streams can also destroy snapshots/filesystems absent on the sender.
to-peer: Historical architectural exploration, partially superseded by R-009. The parts that remain: use one recovery planner for backup and sync; identify common bases by GUID; keep partial atomic recovery scoped so broad `-R -F` cannot touch unselected descendants; fence normal relationship activity during destructive recovery; protect the chosen backup recovery point from pruning. The earlier preference to preserve newer source history by falling back to a full staged receive is superseded for SIMPLE recovery: when a valid common GUID base exists, the Owner wants destructive cleanup/rollback of source-side state that blocks incremental, after preview+confirmation, and then incremental transfer as the primary path.
needs-formal-answer: no

---

id: R-009
published-state: 01562421b5bde8903036eba2488c61d3caf8ddb7
timestamp: 2026-08-12 21:44 Europe/Warsaw
context: Owner has now fixed the DEFAULT recovery policy durably in `docs/project/OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`. Simple recovery means restore the exact LATEST valid backup recovery point back into the ORIGINAL source path. This supersedes the earlier working assumption that plain/simple restore defaults to a derived side namespace.
to-peer: Treat the Owner decision as authoritative. Default/simple recovery planner: (1) latest backup recovery point is selected automatically; (2) inspect backup+source history by GUID; (3) if source is non-empty and a proven common base exists, preview exactly what source-side newer snapshots/state blocks the receive, require explicit destructive confirmation, remove/rollback only that blocking state, then perform reverse INCREMENTAL send|receive to latest and GUID-verify; incremental is the primary goal, not an optional optimization; (4) if source is empty/new, lineage is divergent, or no proven common GUID base exists, use FULL send|receive rather than manufacturing a base; (5) user selects recovery intent, not `incremental/full` mechanics. Advanced modes remain orthogonal: historical point, partial recursive set, explicit `--into` working destination, and side/non-destructive recovery. Do NOT fold this scope expansion into REV-114; fix that race narrowly, then redesign the later recovery planner/CLI against this Owner contract.
needs-formal-answer: no

---

id: R-010
published-state: 34b8e97b25d224fa0b2f46ae5fcba406d0a72e2e
timestamp: 2026-08-12 21:50 Europe/Warsaw
context: Owner opens the next recovery-design question before more code: how restore should interpret recursive/flat histories when descendants do not share the same snapshot set, including the real shape `hdd/backups/pve2/rpool/data` with no parent snapshots while `.../v1`, `.../v2`, `.../v3` have differing histories. This must be resolved now because R-009's word LATEST is ambiguous across atomic vs flat relationships.
to-peer: Proposed semantic split for discussion, not yet a new Owner decision. (A) Model an ATOMIC recovery as a Recovery Point: for the selected dataset set, `latest` means the newest COMPLETE common atomic snapshot family across all selected members. OpenZFS recursive `snapshot -r` creates descendants at one instant; do not silently degrade an atomic whole-tree restore into per-child latest if the retained histories have diverged. If a selected member (including the parent when atomic/include-parent semantics require it) lacks that family, that atomic point is incomplete; choose an older complete common point or refuse if none exists. Partial selection may still use a common atomic point across only the selected descendants. (B) Model FLAT recovery as a Recovery Set/Frontier: each selected dataset is independent, so `latest` means each member's own newest valid snapshot; creation times/names may differ and the preview must show that mixed-time mapping rather than pretending it is one recovery point. A parent with no snapshot is valid as namespace-only when the installed CONFIG excluded the parent; create/preserve only the structural parent needed for children. If CONFIG says the parent itself was protected but backup has no parent snapshot, default whole-source recovery is incomplete and must not silently claim success; explicit partial-child recovery can still proceed. (C) Recovery should be capable of a deliberately FLATTENED selection even from an atomic history (e.g. recover v1/v3 independently), but that is an advanced semantic relaxation, not the default for an atomic relationship, and public CLI spelling is intentionally not chosen yet. Do not add a manifest/state machine unless actual ZFS+CONFIG facts prove insufficient; first make the planner produce a per-dataset map `{dataset -> snapshot, guid, creation, consistency=atomic|independent}`. R-009 should later be refined so `latest` means latest complete common point for atomic and latest per-member frontier for flat.
needs-formal-answer: no

---

id: R-011
published-state: 911e9a2d27d55a17ca4a13b76b5488d395d36860
timestamp: 2026-08-12 21:58 Europe/Warsaw
context: Owner agrees FLAT latest is trivially per-member latest, and asks for historical FLAT semantics when an explicit wall-clock point T is requested: should each member select `<= T`?
to-peer: Proposed rule: yes. For an explicitly selected FLAT dataset set, historical recovery at wall-clock T maps each member independently to the newest valid snapshot whose measured ZFS creation time is <= T: `snap_i(T)=argmax creation(snapshot)<=T`. The preview must show the resulting mixed-time frontier and actual per-member creation timestamps. If an explicitly selected member has no qualifying snapshot <=T, default recovery of that requested set is incomplete and should refuse as a set; an explicit partial selection may omit that member. However, WHOLE-FLAT-as-of-T has a separate topology problem: with dynamic descendants, present-day snapshot history alone may not prove whether a child with no qualifying snapshot did not yet exist at T, existed but had not yet been backed up, or had older snapshots pruned. Do not silently guess topology-at-T. First see whether existing CONFIG + backup dataset facts can distinguish those cases; if not, historical whole-tree FLAT restore may require a minimal durable inventory/catalog recorded at backup time (dataset membership + snapshot GUID/creation), not a state machine. Keep `latest` free of this complication: current latest frontier remains derivable directly from retained snapshots.
needs-formal-answer: no
