# zfsbackup 1.0

The first public release. ZFS snapshots, copies, retention and monitoring for small Proxmox VE
fleets, driven from one collector host through a text GUI in the server console and run by cron.
Plain bash and Python 3 for the GUI; no daemon, no database.

## What it does

- **Relations** between two hosts, created in a wizard (F3, Ins): **backup** (the collector pulls
  copies and keeps its own history), **mirror** (the same datasets under the same path),
  **local copy**, **local snapshots** and **remote snapshots**.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source,
  counted flat, by age or as a GFS ladder; five shipped templates and a tier table for your own.
- **Chains and Proxmox replication.** When a source already carries our snapshot family, the wizard
  asks who makes them: a chain (another collector, an old cron, a pvesr replica) is adopted
  passively and nothing is created or deleted there; leftovers of an old relation make the new
  one take over with its own snapshots.
- **Replicas** to USB disks or a second pool, once a night, optionally encrypted.
- **Monitoring and a daily mail digest** when a copy stops arriving; **restore** and read-only
  browsing of a snapshot from the GUI.
- **Delegated accounts**: jobs can run as a non-root account with exactly the ZFS rights they need;
  guest quiescing through a sudo helper.
- **Self-update** from this repository once an hour, with a hold and a rollback.

## Getting started

See the README and `docs/en/ESSENTIALS.md` (Polish: `docs/pl/ESENCJA.md`). The GUI starts in
English; `zfs-backup gui --lang=pl` switches it to Polish.

## Upgrading an existing installation

Hosts installed from the development repository keep updating from it until they are switched to
this one. Configurations written by hand (CONFIG v4) keep working; taking them over into relations
is a documented, step-by-step operation (`zfs-backup edit-config`, then the wizard).

## Known limitations

- Target-side GFS retention is rendered as a flat count per tier; while the cadence is regular
  the two keep the same snapshots, after a burst of catch-up runs they differ.
- An automatic guard for datasets that become Proxmox replication targets while snapshotted is
  planned for 1.1; until then the wizard asks and the admin decides.
