# REV-20260802-029 — quiesce must be revalidated before every pool snapshot

**Status: CHANGES REQUIRED**

Commit `7564f8e` correctly brings the remote path up to the local path for ordering, initial boundary re-check and deadline enforcement. It does **not** close the multi-pool part of REV-025.

The remote script currently does this:

1. freeze all VMs;
2. check every VM and the deadline once;
3. run one `zfs snapshot` command per pool.

The comment says every guest remains frozen until the last group is done, but this is not proven. A slow or blocked snapshot of pool A can consume the remaining window or allow VSS to thaw before pool B. Pool B is then snapshotted without another status/deadline check.

The same issue appears to remain in the local path. Therefore "same contract" currently means both paths share the same incomplete boundary.

## Required behaviour

Immediately before **each** pool's `zfs snapshot` command:

- verify every VM owned by this run still reports `frozen=yes`;
- recompute elapsed time from the first successful freeze;
- refuse before touching that pool when either check fails;
- preserve guaranteed thaw on every refusal path.

Add a regression test with at least two pools where the first pool's snapshot consumes/exceeds the budget. Assert that the second pool's `zfs snapshot` is never invoked. Cover both local and remote paths, or factor one shared invariant and prove both callers use it.

## UX implication

This must remain an internal safety invariant. Do not expose per-pool timing or ordering as another deployment choice for the administrator. A requested quiesced job either proves the boundary for every snapshot it creates or fails closed.

## Separate small documentation defect

The remediation text introduced with `--add-quiesce` still says the whitelist is "PRZEPISYWANA" from the printed list. In additive mode that is no longer true and can mislead an operator about whether unrelated grants survive. Update the printed explanation to say that the command merges the required datasets and preserves existing entries.
