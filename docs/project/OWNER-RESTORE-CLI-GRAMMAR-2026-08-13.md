# Owner decision — the public restore grammar

Date: 2026-08-13
Status: OWNER DECISION (recorded by the implementer from the owner's message of
2026-08-13; the owner's wording is preserved in the forms below). This is the
decision R-018/R-019 were waiting on, so the public CLI surface is no longer
frozen.

Details are to be worked through with the reviewer in a separate thread. The open
questions at the end of this file are the implementer's, raised so they are
settled deliberately rather than by whatever the first implementation happens to
do.

## The shape

Recovery is addressed by **relation name**, with an optional dataset after a
colon, and an optional destination as a second argument.

| form | meaning |
|---|---|
| `zfs-backup.sh restore pve2` | the whole relation `pve2`, latest recovery point, back to its own source paths |
| `zfs-backup.sh restore pve2:rpool/data` | one dataset out of that relation |
| `zfs-backup.sh restore pve2:rpool/data pve3:rpool/data` | that dataset, recovered onto a different machine and path |
| `zfs-backup.sh restore pve2:rpool/data/v1 pve3:rpool/data/v1` | a single child, onto a different machine |
| `zfs-backup.sh restore pve2:rpool/data pve3:rpool/data --at="2026-08-10 12:00"` | a historical recovery point, onto a different machine |
| `zfs-backup.sh restore pve2 pve3` | every dataset of relation `pve2`, onto `pve3`, keeping the source paths |

**Absolute paths must work too.** An operator who names
`hdd/backups/pve1` (a copy location on the backup server) as the source, and an
absolute destination path as the target, must be able to run the same recovery
without going through a relation name.

## What this settles

- the first argument is the **source of the data** (the backup), the second is
  the **destination**. Omitting the destination means "back where it came from",
  which is the default policy of
  `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`;
- one command covers dataset, child and whole-relation recovery — the scope comes
  from what is named, not from a separate flag;
- recovering somewhere else is not a different verb; it is the same verb with a
  destination;
- a historical point is `--at`, not a snapshot name. The operator thinks in
  wall-clock time.

## Open questions the implementer needs settled with the reviewer

1. **`:` is already taken.** Every engine in this tree reads `user@host:dataset`
   as a remote spec, and `pve2:rpool/data` uses the same separator for a relation
   name. A parsing rule has to be written down and tested, not inferred — the
   failure mode is a recovery aimed at the wrong machine.
2. **What names a relation.** `pve2` has to resolve to a set of datasets and
   their copy locations. Whether that is the client name, the host label, or the
   target subtree needs to be one answer, not three.
3. **A third machine may not be enrolled.** `pve3:rpool/data` as a destination
   means the backup server pushes to a host that may have no delegated account,
   no trust, and no relationship. Refusing clearly beats half-working, but the
   refusal has to be designed.
4. **`--at` on a whole relation is not a point in time.** For a FLAT relation each
   dataset has its own frontier, so "the state at 12:00" is per-dataset nearest
   at-or-before, not one instant across the subtree — the distinction R-013 made
   the planner spell out. `--at` must resolve by ZFS `creation`, never by the
   snapshot name, and must say which of the two it is giving.
5. **Whole-relation recovery is many destructive operations.** Partial failure
   needs a defined outcome: stop at the first failure, or continue and report
   what was and was not recovered.
6. **Destination-exists is a different risk than destination-absent.** Recovering
   onto a fresh path on `pve3` destroys nothing; recovering onto an existing one
   destroys whatever is there. The same command covers both, so the confirmation
   cannot be the same.
