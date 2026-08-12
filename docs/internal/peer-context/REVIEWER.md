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
to-peer: Keep the safe derived namespace as the zero-choice default, but do not bake it in as the only legal destination. The later restore contract should accept an explicit destination root (name TBD; `--into=DATASET` is clearer than overloading backup-time `--target`). Semantics should remain safe: explicit destination does NOT imply overwrite; if the destination/result path exists, refuse unless the separate destructive replacement verb is used. For multi-selection, preserve source-relative hierarchy under that destination root so v1/v3 remain distinct and intelligible. Treat destination as a fourth orthogonal dimension: recovery point, selection set, destination root, publication mode. Do not broaden REV-114; its one-dataset staging/ownership fix should simply stay composable with an arbitrary final root.
needs-formal-answer: no
