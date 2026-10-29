# zfsbackup 1.0

The first public release. ZFS snapshots, copies, retention and monitoring for small Proxmox VE
fleets, driven from one collector host through a text GUI in the server console and run by cron.
Plain bash and Python 3 for the GUI; no daemon, no database.

## What it does

- **Relations**, created in a wizard (F3, Ins): **backup** (the collector pulls copies from another
  host and keeps its own history), **mirror** (the same datasets under the same path),
  **remote snapshots**, and on the collector itself **local copy** and **local snapshots**.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source,
  counted flat, by age or as a GFS ladder; five shipped templates and a tier table for your own.
- **Chains and Proxmox replication.** When a source already carries our snapshot family, the wizard
  asks who makes them. A chain (another collector, an old cron, a pvesr replica) is adopted
  passively (`--passive`): nothing is created or deleted there. Leftovers of an old relation make
  the new one take over with its own snapshots (`--own-snapshots`). A **local copy** can be
  passive too, e.g. a copy of a pvesr replica whose snapshots another node makes.
- **Replicas** to USB disks or a second pool, once a night, optionally encrypted.
- **Monitoring and a daily mail digest** when a copy stops arriving; **restore** and read-only
  browsing of a snapshot from the GUI.
- **Delegated accounts**: jobs can run as a non-root account with exactly the ZFS rights they need;
  guest quiescing through a sudo helper.
- **Self-update** from this repository once an hour, with a hold and a rollback.
- **English by default**: the GUI and command output (the setting descriptions that `settings`
  prints are the GUI's Polish catalogue keys); the GUI also has a Polish version. The top bar names the author when the terminal is wide enough.

## Fixed before release

- The install guard no longer accepts a weakened or foreign `-P` protection on the source-prune
  line when it comes together with the passive-mirror (`prune_foreign`) rewrite: every protection
  of the installed line must stay as it is.
- `add-source` on a relation that was moved to another address connects through the relation's
  active endpoint (host and port together), not the original pairing host.

## Getting started

See the README and `docs/en/ESSENTIALS.md` (Polish: `docs/pl/ESENCJA.md`). The GUI starts in
English; `zfs-backup gui --lang=pl` (or `[gui] language = pl` in F10 Settings) switches it to
Polish. Command output is English in both cases.

## Upgrading an existing installation

Hosts installed from the development repository keep updating from it until they are switched to
this one. Configurations written manually (CONFIG v4) keep working; taking them over into relations
is a documented, step-by-step operation (`zfs-backup edit-config`, then the wizard).

## Known limitations

- Target-side GFS retention is rendered as a flat count per tier; while the cadence is regular
  the two keep the same snapshots, after a burst of catch-up runs they differ.
- An automatic guard for datasets that become Proxmox replication targets while snapshotted was
  not part of 1.0 (the wizard asked and the admin decided). *It shipped in 1.0.1: the PVE guest
  guard, for single guest disks and for recursive trees (see CHANGELOG).*
