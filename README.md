# zfs-snapshot-all

ZFS snapshots, replication, retention and monitoring for small Proxmox VE fleets — run from one
**collector** host, configured through a text GUI in the server console, executed by cron.
Plain bash; no daemon, no database.

- **Backup** — the collector pulls copies from a source and keeps its own history;
  **mirror**, **local copy**, **local / remote snapshots** for the other cases.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source.
- **Replicas** to USB or a second pool, once a night, optionally encrypted (`prepare-media --encrypt`).
- **Monitor and mail digest** when a copy stops arriving; **restore** from the GUI.
- Proxmox-aware: VM/CT dataset naming, guest quiescing, delegated non-root accounts.

## Quick start

On the collector, as root:

```bash
git clone https://github.com/AdalbertKing/zfs-snapshot-all.git /root/scripts/zfs-snapshot-all
cd /root/scripts/zfs-snapshot-all
./deploy.sh --backup-user=zfsbackup
zfs-backup gui          # F3 Relacje (relations), Ins: the wizard creates the first relation
```

For the setup the collector needs root SSH access to the source host; the wizard installs the package
there itself; the jobs can run as a delegated account (`--backup-user`) instead of root. `deploy.sh`
checks the dependencies: ZFS, `cron`, `flock`, `mbuffer`, `ssh`, `awk`, `zstd` (the default compressor; `pigz` as an
alternative), `python3` for the GUI and a mail transport for alerts. The GUI is in Polish; an English
translation is in preparation.

## Documentation

| | English | Polski |
|---|---|---|
| essentials (one page) | *in preparation* | [docs/pl/ESENCJA.md](docs/pl/ESENCJA.md) |
| deployment on Proxmox | [docs/en/DEPLOYMENT-PROXMOX.md](docs/en/DEPLOYMENT-PROXMOX.md) | [docs/pl/WDROZENIE-PROXMOX.md](docs/pl/WDROZENIE-PROXMOX.md) |
| collector, two sources, replica | *in preparation* | [docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md) |
| how it works | *in preparation* | [docs/pl/JAK-TO-DZIALA.md](docs/pl/JAK-TO-DZIALA.md) |
| command cheat sheet | *in preparation* | [docs/pl/KOMENDY.md](docs/pl/KOMENDY.md) |
| restore from a replica | *in preparation* | [docs/pl/ODZYSK-Z-REPLIKI.md](docs/pl/ODZYSK-Z-REPLIKI.md) |
| pause and hard disable | *in preparation* | [docs/pl/PAUZA-I-BLOKADA.md](docs/pl/PAUZA-I-BLOKADA.md) |
| technical reference (all engine options, config, alerting) | [docs/en/REFERENCE.md](docs/en/REFERENCE.md) | *w przygotowaniu* |
| config examples | [docs/en/CONFIG-EXAMPLES.md](docs/en/CONFIG-EXAMPLES.md) | *w przygotowaniu* |
| shipped retention templates | [profiles/README.md](profiles/README.md) | |
| tests | [test/README.md](test/README.md) | |

## License

MIT — see [LICENSE](LICENSE).
