# Changelog

Every release of this repository is one commit; its message and the `RELEASE-OF` file name the
development revision it was built from. Releases between tagged versions are listed here only
when they change how the tool is used.

## [1.0.3] — 2026-10-29

- **New-relationship wizard**: when the chosen source datasets already carry our snapshots, the
  question "chain or leftovers" comes right after the datasets, before the target, and names the
  source ("Na źródle <host> …"). It came after the target and read like a problem with the target.

## [1.0.2] — 2026-10-29

- **Faster return to the main window.** It waits only for the quick readers (status, jobs,
  progress, replicas); the monitor and run statistics follow a moment later with
  "(monitor i przebiegi: sprawdzam…)". The F4 copy tree is no longer read in the foreground after
  every window, which froze the screen for seconds. A window closed without a change, the F8 key
  window and a template or settings window re-read nothing or only what they changed.
- **One "Are you sure?" per action.** Restore asks once in its window and runs with `--yes`, so it
  no longer asks again in the terminal. Deleting a replica is one window. Deleting a relationship
  asks a second time only when its copies are deleted too. The new-relationship wizard shows one
  plan window after Create. A one-line success goes to the message line instead of a window.
- **F4 Copies in the F2 layout**: a table of copies, the snapshots in the bottom tab with the
  `zfs list` columns, F8 groups by relationship. The target browser of the wizard shows USED/AVAIL.
- **F6 Replica**: source → target in the right panel; the bottom tab lists the replica's runs,
  done and upcoming, like F2 (72 hours back).
- **F7 on a relationship** runs each dataset's lowest tier (hourly before daily before weekly …).
  A relationship without an hourly tier could run whichever line came first in cron.
- **Adding a tier** (`set-tiers --add-tier`) takes that tier's first snapshot at once, so its
  monitor does not report a missing snapshot until the first scheduled run.
- **F10 Settings**: wider gap between the columns, descriptions wrap in the third column.

## [1.0.1] — 2026-10-29

- **PVE guest guard.** Snapshots and prunes of a guest's disk run only on the node where the guest
  runs; on a pvesr replica they are skipped with an alarm (`rc=76`). Recursive trees
  (`rpool/data`, `hdd/vm-disks`) are covered too: a `-R` snapshot leaves the replica's disk out
  (`-X`) and warns, a prune does not run. Name the source node with `/etc/hosts` or `pve_node` when the
  source is given by address.
- **Host names instead of addresses** in the GUI: each side reads `host:dataset`, the direction
  `pve9 → pve10`; the ssh account and the address are in the relationship window's Config tab.
  A relationship with a second host is named after the name the host reports (the wizard asks
  only when that name is taken or invalid), and new copies land under `<target>/<host name>/…`.
- **Restore** refuses to roll the running system (`/`) or a running guest's disk back in place;
  the running system is received as a new boot environment instead (`--as-boot-env`, in the GUI
  the "new boot environment" choice). The restore wizard asks what, from when, then where.
- **F4 Copies** in two panes (the copy tree and `zfs list -t snapshot`), browsing read-only in `mc`.
- **F2 Runs**: successful prune runs of one cron line fold into one row; the cursor opens at now.
- **F3**: the relationship window has Opis/Config tabs.
- Faster GUI start: one snapshot listing per `job-stats` call; the GUI keeps it for 5 minutes
  (`--vol-cache`) unless a cron log changed since; the F4 tree is read in the background.
- Fixed: a control character in an engine's error line (ssh) no longer breaks `job-stats --json`;
  the English GUI said `lokalnie` for local copies; GFS retention refuses to prune when a
  snapshot's creation time cannot be read.
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
