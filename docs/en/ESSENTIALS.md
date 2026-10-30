# zfs-snapshot-all — essentials

Polish version: [ESENCJA.md](../pl/ESENCJA.md).

The package takes ZFS snapshots, copies them to a second host (or to a disk), prunes them according to retention, and
checks that the copies are fresh. One host — the **collector** — manages everything: it creates relations, holds the
copies, sends the mails. Everything is bash, the jobs run from cron, and for daily work there is a text GUI on the
server console.

## Concepts

| concept | meaning |
|---|---|
| **relation** | a pair: the collector + a source host (or the collector alone), chosen datasets and a schedule; it has a name |
| kinds of relation | **backup** (the collector pulls copies and keeps its own history), **mirror** (the same as on the source), **local copy** (on the same host), **local / remote snapshots** (snapshots only, no copies) |
| **template** | how many snapshots to keep at each tier (hourly, daily, weekly…); the GUI offers `default`, `full`, `d7h24`, `d30h24`, `m12w4d7h24-gfs` |
| **replica** | a copy of the copy on a separate medium (USB or a second pool), once a day at night |
| **monitor** | checks the age of the newest snapshot and raises an alarm when copies stop arriving |

## First run

1. On the collector, as root: fetch the package and prepare the host.

   ```bash
   git clone https://github.com/AdalbertKing/zfsbackup.git /root/scripts/zfs-snapshot-all
   cd /root/scripts/zfs-snapshot-all
   ./deploy.sh --backup-user=zfsbackup
   ```

2. Start the GUI and create the first relation: **F3 Relations**, key **Ins**. The wizard asks for the kind
   of relation, the source host, the datasets, the target, the template, how many snapshots stay on the source
   and the name, shows a summary and the plan, and changes anything only after **EXECUTE**. Step by step, for
   every variant: [docs/tutorial/index.html](../tutorial/index.html).

   ```bash
   zfs-backup gui
   ```

   The collector needs SSH access to the source host as root; the wizard installs the package on the source by itself.

3. Check after an hour: **F2 Przebiegi (runs)** (what ran and what runs next, with errors).

## Day to day

| I want to… | where |
|---|---|
| see whether the copies are up to date | F3 Relacje (relations) — the "Kopie" (copies) column |
| change datasets, schedule, retention | F3, Enter on the relation, `e` |
| pause a relation (e.g. server maintenance) | F3, Enter, F8 Pauza (pause) |
| restore data | F4 Kopie (copies), F9 Przywróć (restore) |
| browse files in a snapshot | F4 Kopie, Enter (or F4 on a run in F2) |
| add a replica on a disk | F6 Replika (replica), Ins |
| do the same from the command line | [COMMANDS.md](COMMANDS.md) |

## Where next

- [HOW-IT-WORKS.md](HOW-IT-WORKS.md) — how it works inside, in plain language;
- [DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md) — step-by-step deployment on two Proxmox hosts;
- [DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md) — a collector with two
  sources and a replica on USB, a chain of three hosts;
- [RESTORE-FROM-REPLICA.md](RESTORE-FROM-REPLICA.md) — restore from the replica disk;
- [PAUSE-AND-DISABLE.md](PAUSE-AND-DISABLE.md) — pausing and hard-disabling a relation;
- [COMMANDS.md](COMMANDS.md) — command cheat sheet;
- technical manual (all engine options, config, alerts): [REFERENCE.md](REFERENCE.md).
