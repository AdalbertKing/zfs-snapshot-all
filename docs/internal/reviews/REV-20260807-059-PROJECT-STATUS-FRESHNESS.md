# REV-20260807-059 — REV-058 closure and PROJECT_STATUS freshness

**Reviewed head:** `47d0fa2fd93c25a008173927d74c937e66049958`

**Review time:** 2026-08-07 16:00 CEST

**Verdict:** **CHANGES REQUIRED**

## REV-058 verdict: APPROVED / CLOSED

The implementation in `ebe951c6a8f5bd8d632d28c48934014d3038c11c` satisfies REV-058.

The reviewed code no longer reads only the invoking user's crontab. `migrate_find_control_block()` binds the control to the managed block whose durable `# Source:` resolves to the config being migrated, searches all passwd users when root, and refuses uncertainty before mutation. In particular:

- unreadable passwd enumeration under root refuses;
- an unreadable candidate crontab refuses rather than becoming “empty”;
- two matching blocks refuse as ambiguous;
- a different config's block is not accepted as proof;
- a proven absence of an installed block remains distinguishable from inability to prove installed state;
- no new operator knob was introduced;
- the crontab remains read-only in this workflow.

The regression evidence is proportionate to the defect. `test/migrate` expanded from 34 to 52 tests; Linux runs are reported as root 52/52 and delegated account 54/54. The negative control against `b518436` is especially useful: G2 returns rc=0 on the old code and commits while the delegated installed block disagrees, which directly reproduces the unsafe path. The live proof uses a throwaway account and real `crontab(1)` to show root locating another user's authoritative block and refusing drift, while production config/crontab checksums remain unchanged.

**REV-058 is CLOSED.** No further implementation response is required for it.

## F1 / P2 — `docs/PROJECT_STATUS.md` violates its own freshness contract

`docs/PROJECT_STATUS.md` currently begins by declaring that it is a live document which must be refreshed after every behavior-changing stage, and explicitly says that if its date/state is older than the latest behavior-changing commit, that is a defect rather than a minor documentation issue.

The file is now materially stale:

- it still names `121892f` / `gen-cron.sh v4.27` as the current recursion state;
- it still says the fleet migration **is not performed**;
- it still describes `192.168.11.11` as carrying an unmigrated config that deployed v4.27 refuses;
- the actual tree has `gen-cron.sh v4.29` from `ebe951c`;
- the production migration was completed at 2026-08-07 14:42 CEST and `OPEN-THREADS.md` records that no fleet config carries legacy recursion anymore;
- REV-056 is already closed by the reviewer;
- REV-058 is implemented and is closed by this review.

This is not cosmetic drift. `PROJECT_STATUS.md` is explicitly used as operational source-of-truth between owner, implementer and reviewer. In its current form an operator reading only that file would take the wrong action: they would believe a production migration remains pending and that the deployed generator is v4.27 when both claims are obsolete.

### Required outcome

Refresh `docs/PROJECT_STATUS.md` in one documentation-only commit so that its leading/current-state section accurately reflects the state at the commit carrying the refresh. At minimum it must state:

1. current generator version/state (`v4.29` at the reviewed head unless superseded before the refresh);
2. fleet recursion migration completed at 2026-08-07 14:42 CEST, with no remaining legacy `-r/-R` recursion in managed config `flags`;
3. REV-056 CLOSED;
4. REV-058 CLOSED, with the root/delegated installed-block control fixed in `ebe951c`;
5. current outstanding work separated from already-completed migration work;
6. the new engine/profile/restore document is a **discussion**, not implemented state.

Do not rewrite history away. The older v4.27/migration-pending paragraph may remain as a dated previous-state entry if useful, but it must no longer be presented as the current state.

### Acceptance criteria

- `PROJECT_STATUS.md`'s first/current-state block agrees with the actual head that carries the correction.
- No sentence in the current-state block says the fleet recursion migration is pending.
- No sentence in the current-state block identifies v4.27 as the deployed/current generator if v4.29 or newer is current.
- Closed reviews are not presented as pending.
- Discussion-only profile/restore/CLI plans are not presented as implemented.
- No production code, config, cron, grants, or host state changes are needed for this finding.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-059.md`

The response should name the documentation commit and identify the specific stale claims corrected. No runtime test campaign is required for a documentation-only correction; a fresh-head consistency check is required before declaring it done.
