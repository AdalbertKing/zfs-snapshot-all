# Changelog

Every release of this repository is one commit; its message and the `RELEASE-OF` file name the
development revision it was built from. Releases between tagged versions are listed here only
when they change how the tool is used.

## [1.0.5] — 2026-10-30

- **Security: the GUI's run-statistics cache** (`job-stats --vol-cache`, run as root) is kept only
  in the user's own runtime directory (`$XDG_RUNTIME_DIR` or `/run/user/<uid>`), and only when that
  is a real directory owned by the user and not writable by group or others. Without one there is
  no cache. It used to fall back to `/tmp` with a predictable name, so a planted symlink let root
  write the snapshot listing into another file.
- **Export and import of an encrypted (raw) relationship**: the export now carries `--raw`, so the
  import sends raw and the encrypted target accepts it. An older export file is imported with
  `--raw` when its dataset sections are raw.
- **PVE guest guard on whole trees**: a recursive snapshot or prune finds its source tree in
  every spelling: `pool/path`, `host:pool/path` and `user@host:pool/path`. A generated prune took
  its `-P __replicate_:2` value for the dataset, and `host:pool/path` (no account) was skipped. In
  both cases the tree was not checked and the prune could run over a pvesr replica disk.
- **New-relationship wizard**: with two or more datasets, the "leftovers" answer keeps
  `--own-snapshots` in the command (the summary showed it, the command lost it); a local copy
  answered "chain" keeps `--passive`.
- **Replica wizard**: "format a new medium" no longer offers another replica's disk; an own cron
  schedule is checked field by field (minute 0-59, hour 0-23, …), and a wrong one asks again
  instead of falling back to "auto".
- **One date format in the GUI**: `YYYY.MM.DD HH:MM`, with seconds where they were shown before.
  The short forms ("today" as a bare time, "tomorrow", a weekday, `DD.MM`) are gone. Snapshot
  names, `--at=` values and F4's CREATION column (`zfs list` format) are unchanged.
- **F6 Replica**: "Rekurencyjnie" (recursive) instead of "Z dziećmi"; "Na dysku" says how many
  newest `replica_` snapshots the disk keeps and about how far back, with a separate
  "Ile migawek" row; the runs tab estimates each run's data from the `written` of its `replica_`
  snapshots ("-" when there is none).
- **F4 groups** show the relationship type in the group header instead of a Rodzaj column, so
  the longer dates no longer cut copy names.
- **Fewer windows**: the "running" window is drawn once with a seconds counter in the last row
  (it flashed every 2 seconds); a successful save, wizard or identical import ends with one
  sentence on the message line instead of an Ok window; Enter in a confirmation no longer cancels
  it; the output window follows its tail until you scroll up.

## [1.0.4] — 2026-10-29

- **Browsing a copy with mc**: mc runs in its own small root. `/kopia` is the snapshot
  (read-only), `/odzysk` is the only place it can write, and the rest is the read-only system mc
  needs. Neither panel can reach the host's pools, `/root` or other copies any more.
- **Faster GUI start**: the screen comes after the quick readers (about a second on the lab host);
  the monitor and run statistics follow, and until they answer the screen says "sprawdzam…"
  (checking…) instead of "bez monitora" / "brak w dziennikach".
- **F2 cursor** stays on the same run when the run statistics arrive (at start and after every
  window); it used to jump to an older run.
- **Re-adding a source tier** of a local relationship (`set-tiers --add-src-tier`) runs that tier's
  first snapshot, as for other relationships.
- **Source-retention table**: a long note wraps inside the window instead of being cut.

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
