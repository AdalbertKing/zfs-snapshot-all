# REV-20260804-043 — Endpoint-switch carve-out must not hide same-client job deletion

**Verdict:** CHANGES REQUIRED

**Severity:** P1 — safety guard regression

**Response path:** `docs/reviews/responses/REV-20260804-043.md`

## Finding F1

Commit `2e02a7d` fixes the live Gate G failure by treating any removed cron line as an in-place endpoint update when its `HostKeyAlias=zfs-client-<name>` appears anywhere in the newly rendered block.

That identity is too coarse. A single client may own multiple managed jobs/datasets, and all of those pull lines use the same stable HostKeyAlias. Therefore this implementation can suppress a genuine deletion of one job whenever at least one other job for the same client remains in the proposed render.

Current logic, simplified:

```bash
alias=$(...lost line...)
if proposed_aliases contains "$alias"; then
    continue   # deletion ignored
fi
```

Counterexample:

```text
installed:
  client=alpha dataset=tank/a endpoint=old
  client=alpha dataset=tank/b endpoint=old

proposed:
  client=alpha dataset=tank/a endpoint=new
```

Both installed lines carry `HostKeyAlias=zfs-client-alpha`. The `tank/b` job is genuinely deleted, but the new carve-out ignores it because the proposed `tank/a` line still carries the same alias.

The new regression test in `test/zfsbackup` proves only:

1. one old line replaced by one new line with the same alias is accepted;
2. a line with a completely different alias is still rejected.

It does not cover multiple jobs belonging to one client, which is the case where the safety guard becomes ineffective.

## Evidence

In `assert_target_block_not_clobbered()` the complete identity comparison is reduced to the alias extracted by:

```bash
grep -oE 'HostKeyAlias=[^ ]+'
```

Any lost line is discarded from the `lost` set solely because that alias occurs in any proposed line. No dataset/source/target/job identity is compared.

This affects the exact guard whose purpose is to prevent silent deletion of managed jobs during config regeneration.

## Required outcome

The endpoint portion of a job may vary, but the remaining job identity must still match uniquely. Use a normalized representation that removes or canonicalizes only the mutable endpoint while retaining at least the stable relationship and job-specific source/target identity.

For example, parse generated pull commands into a tuple such as:

```text
HostKeyAlias + source dataset path + destination dataset path + schedule/job type
```

and compare installed versus proposed tuples after replacing only the host:port field with a placeholder.

Do not rely on HostKeyAlias alone.

## Acceptance criteria

1. A one-job endpoint change for the same relationship passes.
2. Two jobs for the same client, with only one retained under the new endpoint, refuse because the other job would be deleted.
3. Two jobs for the same client, both retained with only endpoint changes, pass.
4. A source dataset, destination dataset, schedule, command type, or other job-defining field changing/disappearing is not silently classified as an endpoint-only update.
5. A different client's removed job continues to refuse.
6. The matching is fail-closed when a managed line cannot be parsed into the expected generated command shape.
7. Add regression tests covering the multi-job same-alias counterexample above and rerun the impacted suites.
8. Re-run Gate G after the corrected guard, including the real incremental over the switched route.

## Gate effect

Gate G returns to **BLOCKED** pending this correction and a clean live rerun. Gate I remains **IN PROGRESS**: commit `d58e847` fixes the first live sync-mode pairing defect, but the evidence currently proves only that pairing completes, not the full Gate I sync lifecycle.
