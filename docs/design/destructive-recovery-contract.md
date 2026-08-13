# Destructive recovery — the contract, and the one trade-off it cannot hide

Status: design, opened 2026-08-13 by the implementer under R-016.
Scope: the execution half of Phase 7 Restore. The read-only preview is on `main`
and unchanged by this document.

## What is already settled

From `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md` and R-009/R-013/R-016:

1. default recovery point is the **latest valid backup**, default destination is
   the **original source path**;
2. preview first, then **explicit confirmation** — the operator chooses recovery
   intent, never transport mechanics;
3. **preserve or secure source state before destroying it**;
4. **incremental from the GUID-proven base when one exists**; full replacement
   only when no valid base exists;
5. **GUID verification after execution** — a clean exit code is not a restore.

Points 3 and 4 are the ones that collide, and the collision is not a coding
detail. It has to be decided by whoever owns the data, so the tool must not
resolve it quietly.

## The collision

Call the GUID-proven common base `B`, the backup's latest point `L`, and whatever
the source holds beyond `B` its **divergent state** — snapshots newer than `B`,
plus live data written after the newest snapshot.

An incremental receive of `B..L` onto the source is cheap: it moves only the delta.
But it can only land if the source is rolled back to `B`, and that rollback
destroys the divergent state. `zfs recv -F` does exactly this, silently.

Preserving the divergent state has exactly three shapes, and each pays somewhere:

| shape | preserves | transfer cost | space cost | breaks |
|---|---|---|---|---|
| **A. rename aside** — `zfs rename src src-preserved-<ts>`, then FULL receive into the freed path | everything: all snapshots, all live data | full send of the dataset | two full copies until the operator removes the preserved one | mountpoints, and any VM/CT config naming the dataset, until the operator cleans up |
| **B. copy the delta out** — full send of `src@safety` to a holding dataset, then incremental | everything | full send of the dataset | two full copies | nothing structural |
| **C. discard with consent** — snapshot the source, then `recv -F`, accepting that the rollback destroys it | nothing beyond `B` | delta only | none | nothing |

Shape B cannot be made cheap by sending only the delta: an incremental stream
`B..safety` needs a receiver that already holds `B`, and no holding dataset does.
A clone of the backup's `B` does not qualify either. Measured on pve1
(`zfs-2.1.9-pve1`, throwaway datasets, destroyed afterwards) rather than reasoned:

```
hdd/rvsrc@B          10373290730650909394
hdd/rvsrc@safety     14480132571279717671
hdd/rvstore/copy@B   10373290730650909394     <- same GUID, so B really is common

$ zfs clone hdd/rvstore/copy@B hdd/rvstore/holding
$ zfs send -i hdd/rvsrc@B hdd/rvsrc@safety | zfs recv hdd/rvstore/holding
cannot receive incremental stream: most recent snapshot of hdd/rvstore/holding does
not match incremental source                                              rc=1

$ zfs snapshot hdd/rvstore/holding@B         # try to give it the anchor by hand
hdd/rvstore/holding@B  3324144800071787979   <- a NEW guid, not B's
$ zfs send -i hdd/rvsrc@B hdd/rvsrc@safety | zfs recv hdd/rvstore/holding
cannot receive incremental stream: most recent snapshot of hdd/rvstore/holding does
not match incremental source                                              rc=1
```

The second half is the part worth having measured: naming a snapshot `@B` does not
make it `B`. The clone inherits the origin's *data*, not its snapshot identity, so
the cheap-preservation idea fails on ZFS's own terms and not on a naming detail.

Shape C's "snapshot the source first" is worth keeping even though the rollback
then destroys that snapshot: it is what makes the txg-visibility gap irrelevant.
`written` cannot prove a source is idle (REV-118), but a snapshot taken before the
destructive step captures whatever was there, proven or not — so the preview's
`STAN ZRODLA NIEDOWIEDZIONY` stops being a reason to refuse. It converts an
unprovable question into a captured fact, and only then throws it away on the
operator's explicit instruction.

## Proposed contract

**The tool refuses to choose.** A destructive recovery whose source has divergent
state requires the operator to name what happens to it:

```
zfs-backup.sh restore --replace --dataset=<source> --preserve-source=rename
zfs-backup.sh restore --replace --dataset=<source> --discard-source-changes
```

- neither flag given, and divergent state exists → **refuse**, print the preview,
  name both options and their costs. This is the default and it does nothing;
- no divergent state at all → still requires confirmation, but neither flag,
  because there is nothing to decide about;
- `--yes` skips the interactive confirmation. It does **not** substitute for the
  divergence decision: `--yes` means "I have read the preview", not "pick for me".

Sequence, once the decision exists:

1. compute the strategy read-only (existing code) and print it;
2. confirm — interactively, or `--yes`;
3. secure the source: `zfs snapshot <src>@restore-safety-<epoch>`, always, both
   shapes. Named outside every managed prefix so retention never touches it;
4. execute the chosen shape;
5. verify: the source's snapshot GUID at `L` must equal the backup's GUID at `L`.
   Mismatch is a hard failure, loudly, whatever the exit codes said;
6. report what still exists and what was destroyed, by name.

## Slicing

- **Slice 1** — everything above except the transfer shapes: verb, refusals,
  preview, confirmation, safety snapshot, GUID verification, and the divergence
  decision gate. No destruction yet; the execution point is a single refusal.
- **Slice 2** — shape C (discard), the cheap path, on a throwaway live lab.
- **Slice 3** — shape A (rename aside), which needs the mountpoint consequence
  handled rather than mentioned.

Slice 1 is safe to land and review on its own: it can refuse, and that is all it
can do.

## Open question for the reviewer

Is shape B worth building at all? It costs a full copy like A, preserves the same
data, and unlike A leaves the original path untouched — but it needs somewhere to
put a second full copy, which on these hosts is the same pool that already holds
the backup. My inclination is to skip it and offer A and C only. That is a
judgement about operator ergonomics, not a technical constraint, so it should not
be mine alone.
