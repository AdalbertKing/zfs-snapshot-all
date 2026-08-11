# Test cascade cost review — 2026-08-11

Status: DISCUSSION / non-blocking process optimization

## Owner concern

The suite has grown substantially and dependency-selected cascades are taking long enough to affect development cadence. Re-evaluate whether the current cascade is proportionate at this stage of the project.

## Reviewer initial assessment

The repository policy already says the right thing in principle: during implementation run the smallest fast feedback set; group related changes; run the expensive dependency-selected campaign once at the end of a package; do not repeatedly run broad campaigns merely because they exist.

`test/impact.sh` is also a planner, not a requirement to run `--all`. It resolves changed files to owning suites, manual obligations and contracts. The problem to examine is therefore not whether dependency edges should be weakened blindly, but whether:

1. some suite edges have become too coarse as large integration suites accumulated unrelated historical assertions;
2. implementer workflow is invoking the final cascade too often (for each intermediate fix rather than package checkpoint);
3. slow suites contain separable fast/slow layers with different proof value;
4. repeated identical suites across adjacent commits can be safely deferred until a meaningful boundary without losing a safety gate;
5. the graph has enough granularity to distinguish the exact runtime boundary changed.

## Current concrete example

A change confined to `zfs-backup.sh` currently selects `zfsbackup` and `localbackup` plus the manual/project-status and profile schema obligations. That is much narrower than `--all`, but `zfsbackup` has itself grown into a large lifecycle/integration suite. The correct optimization target is likely suite granularity and checkpoint cadence, not deletion of legitimate dependency edges.

By contrast, a `gen-cron.sh` change intentionally fans out to many suites (`gencron`, `scenarios`, `zfsbackup`, `migrate`, `profiles`, `reconcile`, `configexamples`, `localbackup`) because it is a shared renderer. That fan-out may be expensive but is architecturally justified unless the relevant contracts can be split into narrower, explicit interfaces.

## Proposed three-tier execution model

### Tier 1 — edit loop
Run after each small implementation iteration:
- syntax/static check;
- the new regression/negative control;
- the owning narrow suite or targeted section if independently runnable.

Target: seconds to low minutes.

### Tier 2 — package checkpoint
Run when the logical fix/package is ready for review or before building a dependent slice:
- `impact.sh` dependency-selected suites for the actual package diff;
- contract checks selected by the graph;
- required live proof if the changed boundary is environmental/destructive.

Run once per coherent package, not after every internal commit.

### Tier 3 — broad campaign
Use only for release/freeze, high-centrality shared changes, graph changes whose blast radius is broad, or when a failure/uncertainty justifies widening. `--all` is not routine evidence.

## Measurement before graph surgery

Do not optimize from impression alone. First capture wall-clock duration of every selected suite over several representative runs and identify the top contributors. Prefer a small timing wrapper/report over changing production tests.

For each slow suite ask:
- what contract does this runtime buy?
- can targeted sections be independently executed without weakening proof?
- is setup repeated unnecessarily?
- can fixtures/setup be shared safely?
- is the suite testing several architectural boundaries that should become separate suites/edges?

Do not split solely to improve elapsed time if the split would hide an important cross-boundary integration property.

## Request to Claude

Please review this from the implementer side and report, without stopping REV-102/107 work:

1. approximate wall-clock timings for the suites most frequently selected in current Phase 5 work, especially `zfsbackup`, `localbackup`, `gencron`, `profiles`, and any repeated `impact --verify` cost;
2. which cascades are currently run per edit/commit versus only at package checkpoints;
3. the three largest avoidable sources of latency;
4. whether a safe targeted-section mode or suite split can reduce edit-loop latency while preserving the existing final dependency cascade;
5. any dependency edge you believe is genuinely over-broad, with the exact contract that makes it removable or replaceable.

Reviewer bias: first optimize invocation cadence and suite granularity; do not weaken a proven dependency edge merely because its suite became slow.

This discussion is process-only and must not block functional Phase 5 work.
