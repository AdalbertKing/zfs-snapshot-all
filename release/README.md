# zfsbackup

**English** · [Polski](README.pl.md)

ZFS snapshots, replication, retention and monitoring for small Proxmox VE fleets — run from one
**collector** host, configured through a text GUI in the server console, executed by cron.
Plain bash and Python 3 for the GUI; no daemon, no database, no agent on the sources beyond the
same scripts.

**Who it is for:** administrators of one to a few dozen Proxmox VE hosts on ZFS who want
off-host copies with history, retention per tier, alerts when a copy stops arriving, and a
restore path they can walk in a console — without running a backup server.

- **Backup** — the collector pulls copies from a source and keeps its own history;
  **mirror**, **local copy**, **local / remote snapshots** for the other cases.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source.
- **Replicas** to USB or a second pool, once a night, optionally encrypted (`prepare-media --encrypt`).
- **Monitor and mail digest** when a copy stops arriving; **restore** from the GUI.
- Proxmox-aware: VM/CT dataset naming, guest quiescing, delegated non-root accounts, local copies
  of pvesr replicas (`--passive`).
- Existing snapshots on a source are never guessed at: the wizard asks whether someone else makes
  them (adopt them, `--passive`) or they are leftovers (`--own-snapshots`).

```text
 zfs-snapshot-all            nas01 198.51.100.97 | account root, zfsbackup            read 22:04:55
╔═ Relations on collector nas01 (3) ═══════════════════════╗┌─ ab -- relation ─────────────────────┐
║ Relation  Type    Direction          State    Copies     ║│ ── Now                               │
║ ──────────────────────────────────────────────────────── ║│ Copies       up to date   critical   │
║ ab        backup  nas01<192.0.2.2    running  up to date ║│              after 150m              │
║ cb        mirror  nas01<>198.51.10…  running  up to date ║│ Last run     OK   2026-10-27         │
║ srvb      backup  nas01<198.51.100…  running  up to date ║│              21:16:06                │
║                                                          ║│ Next         2026-10-27 22:15:00     │
║                                                          ║│ ── Runs (7 days)                     │
║                                                          ║│ Calls        282, errors 0           │
║                                                          ║│ Time         last 13s / avg 9s /     │
║                                                          ║│              max 28s                 │
║                                                          ║│ Data         0B                      │
║                                                          ║│ ── Settings                          │
║                                                          ║│ Other host   192.0.2.2:22            │
║                                                          ║│ Account      root                    │
║                                                          ║│ Template     d30h24                  │
╚═ Enter details   Ins new   Del delete   Tab to datasets ═╝└──────────────────────────────────────┘
╔═ ab: [Datasets]  Jobs ═══════════════════════════════════════════════════════════════════════════╗
║ Source → target                                                   Copies      Tiers  Data 7 days ║
║ ──────────────────────────────────────────────────────────────────────────────────────────────── ║
║ zfsbackup-nas01@192.0.2.2:hdd/data → hdd/backups/198.51.100.98/…  up to date  2      0B          ║
║ zfsbackup-nas01@192.0.2.2:hdd/vms → hdd/backups/198.51.100.98/h…  up to date  2      0B          ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```

*The GUI (F3 Relations) on a lab collector; host names and addresses replaced.*

## Requirements

- Proxmox VE (or Debian with OpenZFS) on every host that takes part: the collector and each source.
- Root on the collector for the installation; root SSH access from the collector to a source for
  its one-time setup. The jobs themselves can run as a delegated account (`--backup-user`).
- `zfs`, `cron`, `flock`, `mbuffer`, `ssh`, `awk`, `zstd` (the default compressor; `pigz` as an
  alternative), `python3` for the GUI, and a mail transport (`sendmail`-compatible) for alerts.
  `deploy.sh` checks the engines' dependencies and says what is missing; `ssh` only where a
  relation reaches another host.

## Quick start

On the collector, as root:

```bash
git clone https://github.com/AdalbertKing/zfsbackup.git /root/scripts/zfs-snapshot-all
cd /root/scripts/zfs-snapshot-all
./deploy.sh --backup-user=zfsbackup
zfs-backup gui          # F3 Relations, Ins: the wizard creates the first relation
```

For the setup the collector needs root SSH access to the source host; the wizard installs the package
there itself. The GUI starts in English; `zfs-backup gui --lang=pl` (or `[gui] language = pl` in
F10 Settings) switches it to Polish. Command output is always English.

Installed hosts update themselves from this repository once an hour (`update-control.sh`); `zfs-backup
--version` shows the release and the development revision it was built from (`RELEASE-OF`).

## Before you rely on it

This is an administrator's tool. It runs as root, creates and **destroys** ZFS snapshots on the
collector and on the sources according to the retention you set, and its restore can overwrite a
dataset in place.

- Test a restore on your own data before you need one: a copy you have never restored is not yet a
  backup. The [tutorial](docs/tutorial/index.html) walks through it.
- Retention deletes. Check the template of a new relation (F5) before the first run, and leave
  snapshots that another tool makes (pvesr, another collector) to `--passive`.
- Keep a second copy outside the collector (a replica to USB or a second pool, F6) — one collector
  is one point of failure.
- There is no warranty (see [LICENSE](LICENSE)); read [the essentials](docs/en/ESSENTIALS.md) first.

## Documentation

Each topic exists in both languages: a one-page essentials file to start with, then the full guides and the
technical reference. An **interactive tutorial**: build your variant from blocks (one host, two hosts, a Proxmox
cluster with pvesr, A > B <> C) and follow it in real GUI screens or CLI commands, in English and Polish:
[https://adalbertking.github.io/zfsbackup/tutorial/](https://adalbertking.github.io/zfsbackup/tutorial/). The same page is in [docs/tutorial/index.html](docs/tutorial/index.html) and also works
downloaded, offline.

| | English | Polski |
|---|---|---|
| **essentials (one page)** | [docs/en/ESSENTIALS.md](docs/en/ESSENTIALS.md) | [docs/pl/ESENCJA.md](docs/pl/ESENCJA.md) |
| how it works | [docs/en/HOW-IT-WORKS.md](docs/en/HOW-IT-WORKS.md) | [docs/pl/JAK-TO-DZIALA.md](docs/pl/JAK-TO-DZIALA.md) |
| deployment on Proxmox | [docs/en/DEPLOYMENT-PROXMOX.md](docs/en/DEPLOYMENT-PROXMOX.md) | [docs/pl/WDROZENIE-PROXMOX.md](docs/pl/WDROZENIE-PROXMOX.md) |
| collector, two sources, replica | [docs/en/DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](docs/en/DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md) | [docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md) |
| command cheat sheet | [docs/en/COMMANDS.md](docs/en/COMMANDS.md) | [docs/pl/KOMENDY.md](docs/pl/KOMENDY.md) |
| restore from a replica | [docs/en/RESTORE-FROM-REPLICA.md](docs/en/RESTORE-FROM-REPLICA.md) | [docs/pl/ODZYSK-Z-REPLIKI.md](docs/pl/ODZYSK-Z-REPLIKI.md) |
| pause and hard disable | [docs/en/PAUSE-AND-DISABLE.md](docs/en/PAUSE-AND-DISABLE.md) | [docs/pl/PAUZA-I-BLOKADA.md](docs/pl/PAUZA-I-BLOKADA.md) |
| technical reference (engine options, config, alerting) | [docs/en/REFERENCE.md](docs/en/REFERENCE.md) | [docs/pl/REFERENCJA.md](docs/pl/REFERENCJA.md) |
| config examples | [docs/en/CONFIG-EXAMPLES.md](docs/en/CONFIG-EXAMPLES.md) | [docs/pl/PRZYKLADY-CONFIGU.md](docs/pl/PRZYKLADY-CONFIGU.md) |
| shipped retention templates | [profiles/README.md](profiles/README.md) | |

What changed between releases: [CHANGELOG.md](CHANGELOG.md).

## Contributing and security

Bug reports and ideas: GitHub issues. How changes get in (this repository is generated from a
development repository): [CONTRIBUTING.md](CONTRIBUTING.md). A vulnerability — do not open a public
issue; see [SECURITY.md](SECURITY.md).

## Support the author

zfsbackup is free and stays free. If it saves you time or a bad night, you can support further
work — a star on GitHub and a good bug report help too.

[☕ Buy me a coffee](https://buymeacoffee.com/tel4891350z)

## Author and license

Wojciech Król (Adalbert King). MIT — see [LICENSE](LICENSE).
