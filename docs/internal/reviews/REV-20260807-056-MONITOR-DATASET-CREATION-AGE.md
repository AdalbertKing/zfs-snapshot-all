# REV-20260807-056 — monitor age when no matching snapshot exists

**Reviewed head:** `ba816336b9643537a9af26bf4ebfedc4227490ec`

**Scope:** `docs/design/monitor-dataset-age.md`, current `check-snap-age.sh`, and the evidence recorded for thread #23.

**Verdict:** **APPROVED FOR IMPLEMENTATION WITH CONDITIONS**

The defect is real and reachable. The current `check_one()` path makes `has any snapshot, but none matching PATTERN` unconditionally CRITICAL, regardless of dataset age. That is observably wrong for a dataset created after the previous scheduled backup but before its first eligible backup run. The proposal to use the dataset's own `creation` timestamp as the effective age when no matching snapshot exists is the right model and does not require a new config field.

The implementation may proceed, subject to the contract below.

## Contract

1. **Uniform age rule.** When a dataset exists, has at least one snapshot, and none matches `PATTERN`, calculate age from `zfs get ... creation <dataset>` and pass that age through the same WARN/CRIT ladder used for a matching snapshot. Apply this to explicit targets and `-R` discovered descendants alike. Do not infer recursion or add config.

2. **Container-node leniency stays unchanged.** A non-explicit `-R` descendant with no snapshots at all remains `SKIP`. This review does not turn empty hierarchy nodes into monitored leaves.

3. **Message provenance is part of the operator contract.** For WARNING/CRITICAL caused by dataset creation age, the line must say that no matching snapshot exists and must identify that the displayed age is measured from dataset creation. The operator must not be left to infer whether `age=` is snapshot age or dataset age. In `-v`, the below-warning case should emit an `OK` line with the same provenance. Non-verbose cron remains silent for OK.

4. **Unreadable or invalid timestamps are UNKNOWN, never fabricated age.** If `zfs get ... creation` fails, is empty, or is not a valid integer epoch, set UNKNOWN and return exit 3 according to the existing aggregate semantics. Do not feed an empty/non-numeric value to shell arithmetic.

5. **Fix the existing matching-snapshot timestamp path in the same change.** The current code also does `newest_epoch=$(zfs get ...)` followed directly by `$((NOW - newest_epoch))`; an empty result becomes 0 in shell arithmetic and produces a fabricated epoch-sized CRITICAL. Once the new path introduces correct timestamp validation, leaving the old path knowingly inconsistent would create two reliability contracts in one function. Both dataset-creation and matching-snapshot timestamp reads must use the same validated helper/semantics and return UNKNOWN on unreadable or invalid creation time.

6. **No production/config surface expansion.** No changes are expected in `gen-cron.sh`, `cron2conf.sh`, generated crontabs, or deployed configs. If implementation needs such changes, stop and return for review because that would widen the approved scope.

## Required tests

A deterministic regression suite is required. Prefer a ZFS-free harness by stubbing `zfs` via `PATH` (or an equivalent command seam) so timestamp/read failures are testable without root and without relying on wall-clock races. Live scratch-ZFS evidence may supplement this but must not be the only proof.

At minimum prove:

- non-matching snapshot + dataset age below WARN -> rc 0; silent normally; `OK` with creation provenance under `-v`;
- non-matching snapshot + age between WARN/CRIT -> WARNING / rc 1 with creation provenance;
- non-matching snapshot + age >= CRIT -> CRITICAL / rc 2 with creation provenance;
- explicit and recursive-discovered datasets use the same ladder;
- recursive descendant with no snapshots at all remains SKIP;
- unreadable dataset `creation` -> UNKNOWN / rc 3, no fabricated age;
- matching snapshot whose `creation` read fails or is empty/non-numeric -> UNKNOWN / rc 3, proving the pre-existing arithmetic bug is closed too;
- aggregate semantics remain correct when OK/WARN/CRIT/UNKNOWN datasets are mixed;
- negative control against the reviewed pre-change `check-snap-age.sh` demonstrates that the new fresh-dataset cases fail there.

If the existing test graph has a canonical home for `check-snap-age.sh`, use it and update `test/deps.conf` / impact metadata as required. If not, a focused `test/monitor` suite is appropriate.

## Evidence already accepted

The proposal records a live reachable shape on `192.168.11.11` (children carrying `__replicate_` snapshots) and a scratch reproduction on pve2 where a fresh dataset with a manual non-matching snapshot is CRITICAL while a fresh dataset with no snapshots is SKIP. It also records that the delegated account can read dataset `creation` and that received datasets use receipt-time creation. These establish feasibility and production relevance; they do not substitute for the deterministic regression suite above.

## Out of scope

This review does not solve datasets that never receive any snapshot and therefore never become visible as monitored leaves. That remains the separate coverage/scope-reconciliation problem recorded as thread #22.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-056.md`

The response must name the implementation commit(s), show the relevant diff, report the deterministic suite and negative control, and explicitly state whether any runtime/deployed file outside `check-snap-age.sh` and its tests changed.
