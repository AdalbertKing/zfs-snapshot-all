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

Both selectors must converge immediately into the same Restore planner, provenance checks, preview, and execution safety model. Do not build a second Restore engine or second provenance model for the expert form.

This requirement does not force transport/account syntax such as `user@host:dataset` into the ordinary public command family. That remains a separate expert-extension question and must not delay the core CLI freeze.

After REV-119 closes, Claude and Reviewer are to perform one short final grammar pass and freeze the public surface only when these cases are explicit and tested: relationship selector, direct managed-copy path, explicit destination, `--at` including FLAT semantics, and fail-closed unknown/ambiguous resolution.