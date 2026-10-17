# Review request — "copy: nowhere" relationship, rounds 1 and 2

I am the owner and administrator of this tool: a backup tool for ZFS
snapshots on my own Proxmox servers. I am asking for a design review of a new
feature. The review should cover correctness and data safety. Nothing has
been implemented yet.

## What to read

- Design: `docs/project/DESIGN-KOPIA-NIGDZIE-RUNDY-2026-10-17.md` (in Polish).
  It is short.
- Background, only if needed: `docs/project/ENGINE-REMOTE-SNAPSHOT-ONLY-2026-10-16.md`.

## The feature in one paragraph

A backup collector B normally pulls snapshots from a source host A and keeps
a copy. The new relationship type keeps no copy. B's scheduled job only takes
snapshots on A, through the existing engine option `snapget.sh -s`, which was
reviewed and accepted earlier. The use case is a Proxmox cluster where
Proxmox's own replication already copies the virtual disks between nodes. We
only need our own snapshot history on the source.

## Owner decisions already made (please do not reopen)

- The tool does not detect where a virtual machine is running. The
  administrator names the source when creating the relationship.
- If a virtual machine moves to the other node, the existing snapshot-age
  monitor raises the alert, and moving the relationship is a manual step.
- While the collector is down, no new snapshots are taken on the source.
- Mode name `snaponly`. By default the schedule avoids minutes that are
  multiples of 5. At most one such relationship per source dataset on one
  collector.

## Questions

1. **Round 1.** Is the plan sound for the relationship record, `add-client`,
   the cron generator branch and the source-side pruning? Files:
   `zfs-backup.sh`, `gen-cron.sh`, `lib-record.sh`. None of them is frozen.
   Please mark it accepted, or list the conditions.
2. **Round 2.** The age monitor `check-snap-age.sh` only checks local
   datasets today, and the file is frozen. The proposal adds a read-only
   remote mode over the existing ssh options, so the collector can check the
   source's snapshot ages. If you agree, please issue
   `authorizes-frozen: check-snap-age.sh` with your conditions.
3. Is anything in the design unsafe for data on the source host?

The GUI (round 3) comes later and is not part of this request.
