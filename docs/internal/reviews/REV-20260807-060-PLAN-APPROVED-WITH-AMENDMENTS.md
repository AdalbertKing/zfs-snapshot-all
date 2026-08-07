# REV-20260807-060 — plan approved with amendments

**Reviewed head:** `4e1b554a9a8f73a706a4e1310d3484229cba19b8`

**Review time:** 2026-08-07 16:39 CEST

**Verdict:** **APPROVED WITH AMENDMENTS**

The direction in `docs/project/PLAN-2026-08-07.md` is accepted. In particular, Stage 0 before further feature work, real-host/delegated-account evidence for ZFS/crontab/permission changes, contract+tests before implementation, scope reconciliation before profiles, and restore split into planner / SAFE / replace are all the right direction.

The plan needs the amendments below before Stage 2 implementation starts.

## A1 — Stage 0: uncovered guests are opt-out, not opt-in

The current production gap outranks feature work. Stage 0 may proceed immediately.

Default rule: every dataset belonging to an existing guest discovered on pve0 is brought under backup. Leaving any discovered guest out must be an explicit, durable exclusion with a reason. The operator must not have to remember later whether an omission was intentional or accidental.

This does not require a new general profile mechanism in Stage 0; the immediate repair may remain a config correction followed by render/diff/install/live proof.

## A2 — Stage 1: freshness must use machine-readable state

The principle "enforce, don't remind" is approved, but `impact.sh` should not key correctness off parsing prose such as the Polish `Data odświeżenia` line.

Use one explicit machine-readable marker for the behavior head covered by `PROJECT_STATUS.md` (name/format is implementer choice), with the human-readable date remaining documentation. The verification mechanism should compare that marker with behavior-changing commits and fail when status is stale.

Acceptance requirement: changing wording or formatting of the introductory prose must not silently disable freshness verification.

## A3 — Stage 2: one pre-freeze tranche, separate contracts/commits

It is reasonable to run one final regression cascade for the three pre-freeze engine/CLI changes:

1. one snapshot suffix per run for non-quiesced `flat`,
2. refusal of conflicting recursion declarations,
3. long recursion options.

However these should remain separately reviewable changes/contracts rather than one inseparable patch. One final campaign is efficient; coupling unrelated parser and snapshot-correlation code into one implementation unit is not.

## A4 — recursion CLI invariant: exactly one semantic declaration

The proposed translation

`--recursive=no -> (nothing)`

is unsafe if implemented as simple argv erasure. For example, `--recursive=no -r` could collapse to `-r` and silently choose a mode even though the caller supplied two contradictory declarations.

The parser contract must be semantic, independent of spelling:

- accepted declarations are `-r`, `-R`, `--recursive=atomic`, `--recursive=flat`, `--recursive=no`;
- an invocation may contain **at most one recursion-mode declaration**;
- any second declaration is an error, even when it repeats the same mode or mixes short and long forms;
- `--recursive=no` is therefore a real declaration, not merely absence of a flag;
- parsing stops interpreting long options after `--`;
- invalid long-option values fail closed.

This contract and its tests must be approved before implementation, per the plan's own §1.3 rule.

## A5 — Stage 4 reconciliation: map actual guest storage, not only guest IDs

Moving reconciliation before profiles is strongly approved. It fixes the underlying class of failure exposed by VM 104 rather than merely packaging the stale scope more nicely.

`qm list` / `pct list` alone are not sufficient evidence of dataset ownership. Reconciliation must inspect the actual guest configuration (`qm config <vmid>` / `pct config <vmid>` or an equivalent authoritative source) and map configured storage to ZFS datasets/zvols.

At minimum the report should distinguish:

- guest storage missing from backup scope;
- explicitly/durably excluded storage;
- configured backup scope that no longer maps to an active guest;
- ambiguous/unmappable storage.

The first version remains report-only. Ambiguity must never become automatic inclusion.

## A6 — profiles: accepted architecture

The profile model is accepted:

`selector -> candidates`, checked against the relationship grant, then expanded into the existing v4 config and rendered only by `gen-cron.sh`.

A selector that reaches outside the grant must fail with the concrete dataset names. Silent intersection/truncation would recreate false health and is rejected.

## A7 — restore: run correlation is not point-in-time equivalence

The planner / SAFE namespace / destructive replace split is accepted.

Hoisting the snapshot suffix once per run is an appropriate prerequisite because it makes a `flat` run correlatable. The restore planner must nevertheless preserve the distinction between:

- `atomic` — one recursive ZFS snapshot operation;
- `flat -q` — one correlated quiesced set;
- plain `flat` — correlated run, but sequential snapshots and therefore not one whole-tree point in time.

A common suffix identifies a run; it does not by itself prove application-consistent point-in-time state.

Before execution, the planner must also verify completeness of the expected effective scope, not merely find snapshots sharing a suffix.

## REV-059

The response to REV-059 is accepted. `PROJECT_STATUS.md` now presents v4.29/current migration state as current and retains v4.27 only as explicitly historical state. No further runtime work is required for REV-059.

**REV-059 is CLOSED.**

## Stage gates

- **Stage 0:** approved to execute now.
- **Stage 1:** approved with A2.
- **Stage 2:** **do not implement yet**. First present the parser/snapshot contracts and tests, including A4.
- **Stage 3+:** ordering accepted subject to the amendments above.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-060.md`

The response should either accept these amendments or identify a concrete technical conflict. If accepted, Stage 0 may proceed without another design round; Stage 2 still requires the promised pre-implementation contract+tests review.
