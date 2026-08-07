# REV-20260807-063 — close REV-062; live ledgers must agree with current state

**Reviewed head:** `fb09d58b5ed68fda8af55ce3fdbb95a58e253587`

**Review time:** 2026-08-07 18:33 CEST

**Newest commit event at review start:** `fb09d58b5ed68fda8af55ce3fdbb95a58e253587`, committed **2026-08-07 18:20:13 CEST**.

**Verdict:** **REV-062 APPROVED / CLOSED. New F1: CHANGES REQUIRED (P2, documentation/process only).**

Fresh `main` was read immediately before this verdict. I independently inspected the REV-062 response, commit `9f14daa`, the L6/L7 test diff, `PROJECT_STATUS.md`, and `docs/project/OPEN-THREADS.md`.

## REV-062 closure

REV-062 is satisfied.

`cron_lock_files_audit()` now validates both halves of the supported shared-lock invariant: expected group ownership (`stat -c %G`) and group-write permission. The production call passes `ALERT_GROUP`; repair remains root-side. The diagnostic distinguishes wrong-group from missing group-write.

The targeted tests are discriminating in the required direction: L6 exercises a `0664` file whose group differs from the expected group and the old `2f69c2d` audit accepts it; L7 proves the already-correct repair path moves the file to the expected group and the new audit then passes. The reported Linux delegated-account run is 94/94. No wider campaign was required by REV-062.

Finding REV-062 F1 is therefore **CLOSED**.

## F1 / P2 — the two live project ledgers disagree with facts they already contain

The new machine marker prevents `PROJECT_STATUS.md` from silently lagging a watched behavior-changing commit, but the current documents show that moving the marker is not sufficient to keep the *live state* internally coherent.

### `docs/PROJECT_STATUS.md`

At the top it correctly records Stage 0 as completed and explicitly says VM 104 is now backed up. The same current-state block later still says, in its "Otwarte" summary, that VM 104 on pve0 is without backup and awaits an owner decision. Those statements cannot both describe current state.

The metadata line also says the refresh is at `2026-08-07 17:2x`, commit `332aa25`, while the machine marker is already `9f14daa` and the body describes the REV-062 fix. The marker is current, the human-facing refresh identity is not.

### `docs/project/OPEN-THREADS.md`

The table's current rows still include stale routing information after the changes already present on the same `main`:

- row `R` says "GOTOWE DO RECENZJI na a2777af" although the reviewed/fixed head is now `fb09d58` and REV-062 has an implementation response;
- thread 35 still describes the delegated `gen-cron.sh --install` lock defect as open for reviewer decision even though `f26a205` + W1-W5 + four-host live proof are already recorded in thread 37;
- the file header still says its last update was after REV-054, despite many later state transitions.

This is not asking for historical rows to be deleted. Historical evidence may remain, but the state/owner columns of a live ledger must not route work to an already-completed action.

### Why this matters

These files are explicitly used as operational coordination state between owner, reviewer and implementer. A stale row here can cause duplicate work, a false owner decision, or a reviewer to assess an obsolete head. The project already suffered that class of failure; a machine freshness marker that can coexist with contradictory current-state prose does not fully solve it.

## Required outcome

1. Make the current-state section of `PROJECT_STATUS.md` internally consistent with Stage 0 and the current reviewed head. In particular remove/relocate the obsolete "VM 104 without backup" owner item and make the human-readable refresh metadata agree with what the machine marker/body actually cover.
2. Reconcile `OPEN-THREADS.md` routing rows with the current state: update/remove the stale `R` announcement and close/supersede thread 35 in favor of the implemented/verified lock state. Refresh the header metadata.
3. Preserve historical facts; do not rewrite history as if the old defect never existed.
4. No production code change and no broad test campaign is requested.
5. Because this is the second recurrence of a live-ledger drift on the same day, Stage 1's hygiene mechanism should explicitly cover **semantic current-state/routing coherence**, not only "a marker exists after the latest watched commit". A lightweight deterministic check is sufficient if one can be defined without parsing prose; otherwise make the authoritative live fields machine-readable and derive the prose from them. Do not add a brittle grep over Polish sentences.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-063.md`
