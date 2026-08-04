# REV-20260801-025 — quiesce boundary must cover every pool and the remote path

## Verdict

**CHANGES REQUIRED**

REV-024 is correctly fixed for the first local `zfs snapshot` boundary: slow container flushes run before VM freeze, the VMs are re-checked, and the measured window is fail-closed. The live 1 s result is good evidence.

Two correctness gaps remain.

## F1 — one check precedes several per-pool snapshot commands

The code builds `QUIESCE_SNAPS_BY_POOL`, calls `quiesce_still_frozen` once, and then executes one `zfs snapshot` command per pool in a loop.

For a job spanning more than one pool, only the first pool is covered by the checked boundary. A slow first snapshot can consume the remaining freeze budget or allow VSS to auto-thaw before the second pool is snapshotted. The second snapshot can then be crash-consistent while the job still reports quiesce success.

The log wording `taking N atomic snapshot(s), one per pool` is individually true per command but must not imply cross-pool atomicity or one common verified boundary.

### Required

Before **each** per-pool `zfs snapshot` command:

1. re-check every VM still owned by this run;
2. re-check the elapsed window;
3. refuse before that pool's snapshot if either check fails.

After each snapshot, either continue only while the same deadline remains valid or thaw and use a separately defined transaction. Do not claim cross-pool coherence that ZFS cannot provide across separate commands/pools.

Add a regression test with two pools where the first snapshot is delayed past the budget and assert that the second snapshot is never issued.

## F2 — remote quiesce still lacks the same snapshot-boundary proof

`PROJECT_STATUS` records the remote path's missing boundary re-check as open. This is the same correctness contract, not a later enhancement. `snapget-first` and the LAN→VPN workflow rely on the remote/client-side snapshot path; leaving it weaker means the simplified deploy can produce different consistency guarantees depending on which direction/path is used.

### Required

Apply the same binary `-q` contract to the remote path:

- slow preparation before freeze;
- freeze immediately before snapshot;
- status re-check at the actual snapshot boundary;
- explicit deadline;
- guaranteed thaw;
- non-zero result and no snapshot on uncertainty.

The operator-facing workflow must not require knowing whether the implementation selected a local or remote quiesce path to understand the consistency guarantee.

## Product-level note

This should remain internal machinery. The eventual deploy command should report one clear result such as:

- `application-consistent snapshot confirmed`, or
- `snapshot refused: VM 106 was no longer frozen`.

It must not ask the general administrator to tune `QUIESCE_MAX_WINDOW` as a normal deployment step. A non-default override should be an expert escape hatch backed by measured host evidence, not part of the standard onboarding path.
