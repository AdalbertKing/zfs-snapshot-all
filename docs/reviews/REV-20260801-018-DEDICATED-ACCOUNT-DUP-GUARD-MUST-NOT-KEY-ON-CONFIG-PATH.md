# REV-20260801-018 — dedicated-account migration can still duplicate root jobs

**Status:** CHANGES REQUIRED

## Finding

The new guard in `assert_no_foreign_managed_block()` refuses migration only when root's installed `# Source:` path normalizes to the exact config path selected for the dedicated account.

That condition is too narrow and conflicts with the next fix in the same workflow: a dedicated account normally cannot read `/root/...`, so the operator is instructed to place the config under `/etc/zfs-snapshot-all/`.

A realistic migration therefore becomes:

- root still runs a managed block sourced from `/root/scripts/.../jobs.pve1.v4.conf`;
- the same job definitions are copied/generated under `/etc/zfs-snapshot-all/jobs.pve1.v4.conf` for `zfsbackup`;
- `assert_no_foreign_managed_block()` sees different paths and returns success;
- activation installs the same jobs into `zfsbackup` while root's jobs remain active;
- every send/prune/monitor can run twice.

The test explicitly declares a different config path "unrelated", but path inequality does not prove unrelated job ownership.

## Required behaviour

Moving an existing collector from root to a dedicated account must be a single high-level migration, not a manual copy plus flag.

Before installing into a non-root crontab, fail closed whenever root has a `zfs-backup-managed` block that overlaps the proposed managed block, regardless of `# Source:` pathname. Prefer comparing normalized generated job lines or stable client/job identities, not config paths.

The tool should either:

1. perform an atomic/high-level ownership migration: show the exact root-block removal and target-user-block addition, obtain one confirmation, install the target block, then remove root's block with rollback on failure; or
2. refuse with a message naming the overlapping jobs and a dedicated migration verb that performs the above.

Do not tell the administrator merely to "decide what happens" and manually remove/copy internal configuration.

## Regression test

Root block source: `/root/scripts/jobs.conf`.

Dedicated-account proposal source: `/etc/zfs-snapshot-all/jobs.conf`.

Both render at least one identical send/prune/monitor job. Activation must refuse before changing either crontab, or execute the explicit transactional migration workflow. A different pathname must not make the proposal pass.

## Reviewer assessment

- argv-safe `runuser` change: accepted;
- snapget local-base correction and live end-to-end discovery: accepted, high-value regression fix;
- readable-config preflight: accepted in isolation;
- dedicated-account duplicate protection: incomplete because it keys identity on the config path;
- live dedicated-account pass should remain blocked until ownership migration cannot duplicate jobs.