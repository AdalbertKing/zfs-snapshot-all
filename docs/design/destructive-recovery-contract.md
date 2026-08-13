# Destructive recovery — the contract, and the one trade-off it cannot hide

Status: design, opened 2026-08-13 by the implementer under R-016.
Scope: the execution half of Phase 7 Restore. The read-only preview is on `main`
and unchanged by this document.

## What is already settled

From `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md` and R-009/R-013/R-016:

1. default recovery point is the **latest valid backup**, default destination is
   the **original source path**;
2. preview first — naming exactly what will be lost — then **explicit destructive
   confirmation**. The operator chooses recovery intent, never transport
   mechanics;
3. **remove/roll back only the blocking divergent state**, then **incremental
   from the GUID-proven base** when one exists; full replacement only when no
   valid base exists;
4. **GUID verification after execution** — a clean exit code is not a restore.

> **Correction, R-017 (2026-08-13).** An earlier draft of this note listed
> "preserve or secure source state before destruction" as a settled requirement
> and built a mandatory operator choice on top of it. That requirement came from
> R-016's wording, not from `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`, and
> the reviewer withdrew it after re-reading the owner contract. **The default
> path is zero-choice**: keeping a second recoverable copy of divergent source
> state is not part of it. The analysis below is kept because it is what makes
> that answer correct rather than merely convenient — it shows there was no cheap
> way to have both, so the owner's simple path is not giving anything up that was
> ever available for free.

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

Shape C is the default path. B is not built. A, if it is ever wanted, belongs to
an explicit advanced/non-destructive capability next to the existing side-restore,
not to this verb (R-017).

## The pre-destruction snapshot: a measurement, not a safety net

Taking `<src>@restore-<epoch>` immediately before the rollback is worth doing, and
it is important to be exact about why, because the obvious description of it is
wrong.

It is **not preservation**. The rollback that follows destroys it along with every
other snapshot past `B`. Calling it a safety copy would be a lie of the most
dangerous kind — an operator who believed it would think a mistake was reversible.

What it actually buys: REV-118 established that `written` cannot prove a source is
idle, because it reflects the last committed txg. Snapshotting the source **forces
the divergent state into a named, measurable object** — its `used` is then the
exact byte count that is about to be destroyed, not an estimate that may be a
minute stale. So the report after the fact can say what was destroyed instead of
approximating it, and the incremental has a deterministic tip to work from.

Measurement, then. The note says so, the code comment says so, and the operator
output must never call it anything else.

## Contract

Zero-choice, per the owner's simple path:

```
zfs-backup.sh restore --replace --dataset=<source> [--config=FILE] [--yes]
```

1. resolve the relationship from the installed CONFIG; refuse anything the verb
   cannot prove it understands (unknown dataset, remote source, no backup
   snapshots, no GUID-proven base);
2. print the preview — the same strategy computation as `--plan`, which already
   names the blocking snapshots individually;
3. require **explicit destructive confirmation**; `--yes` means "I have read the
   preview";
4. snapshot the source (measurement, above);
5. roll back / discard exactly the blocking divergent state, then receive the
   incremental `B..L`;
6. verify the source's GUID at `L` equals the backup's GUID at `L`. A mismatch is
   a hard failure however clean the exit codes were;
7. report what was destroyed, by name and by size.

## Slicing

- **Slice 1** — steps 1–3 and nothing else. The verb resolves, refuses everything
  it cannot prove, previews, confirms, and then stops at a single explicit "the
  execution step does not exist yet" refusal. **Nothing is mutated, so not even
  the snapshot of step 4 is taken** — a verb that snapshots and then refuses would
  leave litter behind on every dry run.
- **Slice 2** — steps 4–7 for the incremental case, proved on a throwaway live lab.
- **Slice 3** — full replacement when no valid base exists.

Slice 1 is safe to land and review on its own: refusing is the only thing it can
do.
