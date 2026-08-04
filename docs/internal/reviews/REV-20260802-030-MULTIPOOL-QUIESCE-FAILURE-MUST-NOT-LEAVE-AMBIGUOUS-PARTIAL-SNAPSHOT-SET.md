# REV-20260802-030 — multi-pool quiesce failure must not leave an ambiguous partial snapshot set

## Status

**QUESTION / CHANGES REQUIRED unless the existing downstream contract proves this harmless.**

REV-029 correctly revalidates the freeze immediately before every pool snapshot and refuses before touching the next pool. The remaining failure shape is now explicit:

1. pool A is snapshotted while the freeze is valid;
2. pool A's snapshot consumes the remaining freeze window;
3. validation before pool B fails;
4. pool B is not snapshotted;
5. pool A's newly-created snapshot is deliberately kept.

The code and response say this is safe because the snapshot of pool A was valid when taken. That proves the consistency of **that snapshot**, but not the safety of leaving an incomplete logical snapshot set in the namespace used by later send, prune, monitoring and retry logic.

## Questions to answer

1. Can a later scheduled `snapsend`/`snapget`, prune, bookmark or base-selection path consume the surviving pool-A snapshot as if the whole job completed?
2. Do monitors distinguish `one pool succeeded, job failed before the remaining pools` from a complete coherent run?
3. On retry, can the partial timestamp collide with, outrank or otherwise affect selection of the new complete set?
4. Is there a persistent transaction marker proving that this timestamp is incomplete until every pool has succeeded?

Please answer against the actual selection/prune code and add a regression test that exercises the next run, not only the immediate refusal.

## Preferred contract

For the default administrator-facing workflow, the least surprising behaviour is:

- record exactly which snapshots this invocation created;
- if any later pool is refused or its snapshot command fails, destroy only those newly-created snapshots before thaw/exit;
- if cleanup cannot complete, exit with a distinct hard failure and print the exact surviving snapshots requiring attention;
- never delete a pre-existing snapshot and never silently claim rollback succeeded.

An alternative is acceptable only if incomplete sets are explicitly marked, ignored by every send/base/prune path, surfaced by monitoring, and cleared or completed deterministically on retry. That is substantially more machinery and therefore harder to justify for the simple deploy goal.

## Required tests

At minimum:

1. two pools; pool A snapshot succeeds; deadline fails before pool B;
2. verify pool B was never touched;
3. verify the pool-A snapshot created by this invocation is removed, or is persistently marked and ignored by all downstream selection paths;
4. injected cleanup failure reports the exact survivor and exits non-zero;
5. a following normal run produces and uses a complete set without being influenced by the failed run.

## UX criterion

A competent general administrator should see one clear outcome:

- **complete quiesced snapshot set created**, or
- **nothing committed; rollback complete**, or
- **rollback incomplete: these exact snapshots remain and require action**.

"Some valid snapshots remain, but the logical job failed" is an internal implementation detail that must not leak into ordinary operation without a defined recovery contract.
