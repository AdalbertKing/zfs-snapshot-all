# Owner execution sequence — return to product work

Status: **OWNER DIRECTION / ACTIVE UNTIL CONSUMED**
Date: 2026-08-12
Published-state reference when issued: `575d5d37784adf6abe7e7836fd160e1cca8965c5`

This note does **not** create a second workflow queue. `docs/internal/reviews/REVIEW_LEDGER.md` remains the only review-routing authority and `docs/project/ACTIVE-WORK-PLAN.md` remains the canonical product sequence. This note only resolves the immediate sequencing after the V2.2 protocol work and REV-111.

## 0. Repair derived review state before product work

Reviewer facts already say REV-20260812-111 is APPROVED and a closure artifact exists, but the published generated `REVIEW_LEDGER.md`/`OPEN-THREADS.md` were not regenerated afterward and still route REV-111 as `IMPLEMENTED | Reviewer`.

First action for the implementer work cycle:

1. refresh published `main`;
2. run `./test/reviewctl.sh --generate` from the current facts;
3. verify REV-111 derives as `CLOSED` and no stale routing remains;
4. commit only the regenerated derived views if they changed;
5. run the normal protocol/impact verification required for that change.

Do not edit reviewer-owned REV/closure prose and do not reopen REV-111. This is a derived-state repair only.

## 1. Next product objective — Phase 5 slice 2 / Gate 5

After the fresh ledger has no actionable review row blocking expansion, continue the existing `ACTIVE-WORK-PLAN` at **Phase 5 slice 2: transactional local-backup install**.

Goal: turn the already-reviewed read-only `--source/--target` planner into one coherent install path without inventing another orchestration model.

Before coding, re-read the existing Phase 5 design/local-relation contract and reuse the mechanisms already present in `zfs-backup.sh`; do not duplicate activation, config validation, cron transaction or ownership logic.

Required boundary:

```text
compose candidate
  -> validate with real gen-cron
  -> preview
  -> confirm
  -> establish/verify seed successfully
  -> install managed cron transactionally
  -> read back installed state
  -> active
```

The exact durable state names must follow the existing local-relation contract; do not invent a transient state merely for this slice.

Acceptance properties:

- failed/declined seed leaves no newly eligible managed cron and remains safely retryable;
- cron/install failure after a successful seed remains explicit and retryable, never falsely `active`;
- existing unrelated CONFIG/tasks remain unchanged;
- local-backup ownership and remote `activate-client` ownership cannot silently claim or rewrite the same relationship sections;
- the SOURCE/TARGET retention contract already closed through REV-102/111 remains intact; do not reopen frozen transfer engines;
- candidate CONFIG is validated and previewed before install, and installed cron/config is read back;
- use the smallest impact-selected test set plus one bounded real-ZFS/live-host proof of the actual install/order boundary. Do not launch a broad campaign merely because this closes Gate 5.

Submit one exact reachable implementation SHA with evidence, update `PROJECT_STATUS.md`, regenerate review routing as required, then stop for Reviewer verdict on this acceptance boundary.

## 2. After slice 2 is reviewed — Phase 5 slice 3

Only after the slice-2/Gate-5 acceptance boundary is closed, implement the already-planned **target discovery/proposal when `--target` is omitted**.

Keep it advisory and simple for a competent administrator: discover/propose, show the chosen target clearly, allow explicit correction, and do not turn discovery into a policy engine or silently choose a destructive destination.

## 3. Parallel work allowed while Reviewer owns a product submission

Only dependency-independent documentation/test-hygiene work from Phase 6 may proceed while a submitted functional slice is waiting for Reviewer. Do not use that allowance to start a later functional phase.

Phase 6 rule remains unchanged: do not build a Cartesian preset catalog. Keep `default`; add a shipped preset only when real operational evidence justifies another reusable HOW policy. Native CONFIG remains the expert escape hatch.

## 4. Restore stays after stable create/install

Phase 7 starts only after the create/install path is stable. Order remains:

1. `restore --plan` read-only;
2. restore into safe/new namespace with GUID/collision checks;
3. refuse unsafe active-guest collisions by default;
4. real-ZFS end-to-end evidence.

Do not begin restore implementation early to fill review wait time.

## Work-cycle cadence for Claude

At every scheduled or manually-started implementer cycle:

1. fetch fresh published `main`;
2. read fresh `REVIEW_LEDGER.md` first;
3. `OPEN | Claude` overrides this product sequence and is worked immediately;
4. `IMPLEMENTED/APPROVED | Reviewer` means the submitted acceptance boundary is waiting for Reviewer — do not continue modifying it behind the submitted SHA;
5. if no review blocks expansion, take the next dependency-ready item above / in `ACTIVE-WORK-PLAN` without waiting for a new Owner message;
6. prefer targeted L0 during iteration, dependency-driven affected suites once for submission, and live proof only where the behavior depends on real ZFS/cron/permissions/host state;
7. one logical delivery, exact SHA, evidence, current PROJECT_STATUS, then hand back through the normal V2.2 routing.

The purpose is continuous progress without Owner message-routing, while preserving the gate-before-expansion rule.
