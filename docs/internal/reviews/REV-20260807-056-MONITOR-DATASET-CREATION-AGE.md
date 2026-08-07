# REV-20260807-056 — monitor age when no matching snapshot exists

**Reviewed head:** `ba816336b9643537a9af26bf4ebfedc4227490ec`

**Scope:** `docs/design/monitor-dataset-age.md`, current `check-snap-age.sh`, and the evidence recorded for thread #23.

**Verdict:** **APPROVED / CLOSED**

**Closure reviewed through:** `b5184368a87ace8ccbea60eff6ede666c6a24b00`, 2026-08-07 14:52:23 CEST.

The defect is real and reachable. The original `check_one()` path made `has any snapshot, but none matching PATTERN` unconditionally CRITICAL, regardless of dataset age. That was observably wrong for a dataset created after the previous scheduled backup but before its first eligible backup run. The implemented rule uses the dataset's own `creation` timestamp as the effective age when no matching snapshot exists and does not require a new config field.

## Contract

1. **Uniform age rule.** When a dataset exists, has at least one snapshot, and none matches `PATTERN`, calculate age from `zfs get ... creation <dataset>` and pass that age through the same WARN/CRIT ladder used for a matching snapshot. Apply this to explicit targets and `-R` discovered descendants alike. Do not infer recursion or add config.

2. **Container-node leniency stays unchanged.** A non-explicit `-R` descendant with no snapshots at all remains `SKIP`. This review does not turn empty hierarchy nodes into monitored leaves.

3. **Message provenance is part of the operator contract.** For WARNING/CRITICAL caused by dataset creation age, the line must say that no matching snapshot exists and must identify that the displayed age is measured from dataset creation. In `-v`, the below-warning case emits an `OK` line with the same provenance. Non-verbose cron remains silent for OK.

4. **Unreadable or invalid timestamps are UNKNOWN, never fabricated age.** If `zfs get ... creation` fails, is empty, or is not a valid integer epoch, set UNKNOWN and return exit 3 according to the existing aggregate semantics.

5. **Matching-snapshot timestamp path uses the same validation.** A failed/invalid matching-snapshot `creation` read is UNKNOWN rather than an epoch-sized fabricated CRITICAL.

6. **No production/config surface expansion.** No change to `gen-cron.sh`, `cron2conf.sh`, generated crontabs or deployed configs was required for this behavior.

## Closure evidence

Implementation commit `11249330b72323d316f9aaec078518a464650427` satisfies the six conditions above. Both dataset-creation and matching-snapshot timestamps go through a validating `creation_epoch()` helper; explicit and discovered datasets share the same ladder; container-node `SKIP` remains; output states when age comes from dataset creation; and the change is confined to `check-snap-age.sh`, tests and impact/dependency metadata.

Deterministic `test/monitor` coverage reports **24/24**, with negative control against the pre-change code reporting **14 new cases failing / 10 unchanged cases passing**.

The required ZFS-backed integration surface was then executed on metropolis pve2. `sudo ./test/scenarios/run.sh` first produced **33/34**. The sole failure, S2, was independently consistent with the intended contract change: the scenario itself still asserted the removed unconditional-CRITICAL behavior against a seconds-old dataset. Commit `0534961241c60f4f87f85258c5e188e1e4410170` corrected S2 to test both sides of the new contract — an old-enough dataset with no matching backup is CRITICAL and a just-created dataset is OK — while also pinning provenance wording. The rerun completed **36/36** and scratch datasets were cleaned up.

No contradictory evidence was found in the reviewed diff. The scenario correction is a legitimate test-contract update rather than masking a regression because its previous expected value directly encoded the behavior REV-056 was created to replace, and the revised test now exercises both the newly-allowed and still-failing cases.

## Final verdict

**REV-20260807-056 is CLOSED / APPROVED.** No further implementer response is required unless a later change modifies `check-snap-age.sh` behavior covered by this contract.

## Out of scope

This review does not solve datasets that never receive any snapshot and therefore never become visible as monitored leaves. That remains the separate coverage/scope-reconciliation problem recorded as thread #22.
