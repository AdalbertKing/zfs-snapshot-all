# Changelog

Every release of this repository is one commit; its message and the `RELEASE-OF` file name the
development revision it was built from. Releases between tagged versions are listed here only
when they change how the tool is used.

## [Unreleased]

- Community files for the public release: a Polish README (`README.pl.md`), `SECURITY.md`,
  `CONTRIBUTING.md`, this changelog, issue and pull request templates, and the interactive
  tutorial (`docs/tutorial/index.html`) shipped with the package.

## [1.0] — 2026-10-25

The first public release (tag `v1.0`).

- **Relations**, created in a wizard (F3, Ins): backup, mirror, remote snapshots, and on the
  collector itself local copy and local snapshots.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source,
  counted flat, by age or as a GFS ladder; shipped templates and a tier table for your own.
- **Chains and Proxmox replication**: snapshots someone else makes are adopted passively
  (`--passive`); leftovers of an old relation are taken over with own snapshots (`--own-snapshots`).
- **Replicas** to USB disks or a second pool, once a night, optionally encrypted.
- **Monitoring and a daily mail digest** when a copy stops arriving; **restore** and read-only
  browsing of a snapshot from the GUI.
- **Delegated accounts** with exactly the ZFS rights the jobs need; guest quiescing through a sudo
  helper.
- **Self-update** from this repository once an hour, with a hold and a rollback.
- GUI in English by default, Polish with `--lang=pl`; command output in English.

Known limitations of 1.0: target-side GFS retention is rendered as a flat count per tier; an
automatic guard for datasets that become Proxmox replication targets while snapshotted is planned
for 1.1.
