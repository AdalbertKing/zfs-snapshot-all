# Restore CLI — Owner requirement for the expert low path

Date: 2026-08-13
Status: OWNER DIRECTION

The final public Restore CLI must keep both levels of addressing:

1. a short high-level relationship selector for the normal workflow;
2. a first-class expert selector that points directly at the exact managed ZFS backup copy on the collector.

The high-level grammar remains centered on:

`zfs-backup.sh restore SOURCE [DESTINATION] [--at=TIME] [--yes]`

`SOURCE` must therefore be able to mean either a known relationship/scope or an exact managed backup-copy `POOL/PATH`.

Examples of required intent:

- `zfs-backup.sh restore branch-01`
- `zfs-backup.sh restore hdd/backups/branch-01/rpool/data`
- `zfs-backup.sh restore hdd/backups/branch-01/rpool/data rpool/recovered/data`

The direct path is a normal expert capability, not a debug workaround. An experienced administrator who already sees the correct backup dataset must not be forced to translate it back into a relationship name first.

At the same time, a physical path is accepted only when the existing project authorities can map it unambiguously to a managed backup copy. Unknown, ambiguous, or unrelated local ZFS paths refuse; Restore must not guess provenance or adopt arbitrary datasets.

## One-host and two-host layouts are one product

The Restore CLI must remain coherent when backup source and restore destination are on one physical server as well as when they span two servers. Do not create a separate `local-restore` command family or a second grammar for the one-server topology.

For a one-server backup created by the high-level local workflow, an experienced operator must be able to point directly at the local managed backup dataset and recover it to a local destination with the same command shape:

- `zfs-backup.sh restore hdd/backups/rpool/data`
- `zfs-backup.sh restore hdd/backups/rpool/data rpool/data`
- `zfs-backup.sh restore hdd/backups/rpool/data rpool/recovered/data`

For a two-server relationship, the relationship selector is a convenience resolver over the same underlying concept: a known managed copy plus an inferred or explicit destination.

The invariant is:

`user intent -> resolve managed copy + destination -> one Restore planner -> one safety/provenance model`

Topology changes resolution facts only. It must not change the meaning of Restore, its safety gates, its historical `--at` semantics, or its preview/confirmation model.

Both selectors must converge immediately into the same Restore planner, provenance checks, preview, and execution safety model. Do not build a second Restore engine or second provenance model for the expert form or for the one-host form.

This requirement does not force transport/account syntax such as `user@host:dataset` into the ordinary public command family. That remains a separate expert-extension question and must not delay the core CLI freeze.

After REV-119 closes, Claude and Reviewer are to perform one short final grammar pass and freeze the public surface only when these cases are explicit and tested: relationship selector, direct managed-copy path, one-host managed-copy restore, two-host restore, explicit destination, `--at` including FLAT semantics, and fail-closed unknown/ambiguous resolution.