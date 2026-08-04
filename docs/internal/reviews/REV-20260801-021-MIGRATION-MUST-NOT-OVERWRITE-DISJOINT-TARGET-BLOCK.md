# REV-20260801-021 — `migrate-to-account` must not overwrite a disjoint target block

**Status:** CHANGES REQUIRED

## Finding

The new workload-overlap guard deliberately allows an existing managed block in the target account when its jobs are disjoint from the root block.

That is not safe with the current commit path. `gen-cron.sh --install` owns and replaces the account's single `# BEGIN zfs-backup-managed` block. The proposed `newblock` is rendered only from the root collector config being migrated. Therefore an already-installed, disjoint managed block in the target account is not merged into the proposal; it is overwritten.

The current preview also hides this: it prints the target account's current job count, but diffs `/dev/null` against `newblock`, not the actual target crontab against the exact post-install crontab.

## Reproduction shape

- root managed block: jobs for `tank/a`
- `zfsbackup` managed block: disjoint jobs for `tank/b`
- overlap guard: passes by design
- migration commit: `gen-cron.sh -c <root-config> --install` as `zfsbackup`
- result: the `tank/b` managed jobs disappear

This is a silent backup regression.

## Required behavior

Choose one unambiguous fail-closed rule:

1. **Simplest and preferred:** `migrate-to-account` refuses whenever the target account already contains any managed block, unless it is byte-/identity-equivalent to the exact proposal and the operation is an idempotent retry.

or

2. Explicitly merge both authoritative configs into one proposal, validate it, and show the exact combined diff. This is materially more complex and should not be the default path.

Also:

- preview the exact target crontab after replacement, preserving unmanaged lines and showing removal of any existing managed lines;
- add a regression test with disjoint `tank/a` and `tank/b` blocks proving that migration cannot silently delete `tank/b`;
- remove or narrow the test asserting that disjoint managed blocks are generally safe to allow.

## Separate observation

The `dropped -> host-level` classification is also too broad: every root job omitted by the account render is retained as a host-level job. Only explicitly recognized host-level job types (currently the digest) should be retained. Any other dropped send/prune/monitor line should stop migration and name the line, rather than split ownership silently.
