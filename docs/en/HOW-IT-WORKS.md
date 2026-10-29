# How it works

Polish version: [JAK-TO-DZIALA.md](../pl/JAK-TO-DZIALA.md).

One page. No history, no rationale, no review numbers — those live in
`docs/` and are not needed to understand what happens on the host.

## What it does

It takes ZFS snapshots, copies them to a second disk or a second host, deletes
the old ones, and shouts if the newest one has become too old.

Everything else is detail of these four actions.

## Engines: four scripts that touch snapshots

| script | action | in one direction |
|---|---|---|
| `snapsend.sh` | **push** | takes a snapshot HERE and pushes it THERE |
| `snapget.sh` | **pull** | takes a snapshot THERE and pulls it HERE |
| `delsnaps.sh` | **prune** | deletes old snapshots according to a rule |
| `check-snap-age.sh` | **check** | how old the newest snapshot is (warning and critical thresholds, e.g. 90m / 3h) |

`snapsend` and `snapget` are the same program in two directions — that is why they
are so alike and why they were deliberately not merged (the direction is the thing
that can be mixed up).

None of the engines knows anything about the crontab, the config or other hosts. They get
arguments and do one thing.

## The rest of the package: who calls and sets up these engines

| script | role |
|---|---|
| `zfs-backup.sh` | **the main entry point for the admin**: creating and changing relations between hosts (`add-client`, `activate-client`, `pause-client`, `status` …) and `zfs-backup.sh gui` |
| `gen-cron.sh` | turns a config into a crontab block; it **does not make backups** itself |
| `deploy.sh` | setting up a host from scratch: account, ZFS permissions, alerts, logrotate |
| `zfs-restore.sh` | restoring data from a snapshot |
| `zfs-job.sh` | a wrapper around every cron line: records the start and the end in `cron.log`, calls `notify-fail.sh` on error |
| `lib-*.sh` | shared code; `lib-zfs-snap.sh` is the heart of both transfer engines |
| `update-control.sh` | updating and rolling back an update |
| `zfs-pair-gate.sh`, `zfs-quiesce-helper.sh` | narrow permissions for the account on the other host |

## GUI

`zfs-backup gui` opens a screen in the terminal (whiptail), driven by function
keys: F2 Runs, F3 Relations (Ins new, Enter window, `e` edit), F4 Copies (F7 or Enter on a snapshot
browses files, F9 restores, also from a disk), F6 Replica, F10 Settings. These are the same operations as in the `zfs-backup.sh` CLI, only in windows —
the GUI calls the same verbs, so the config and the crontab come out identical.

## The script that writes the crontab

`gen-cron.sh` reads the configuration file and turns it into crontab lines
that call the engines.

```
config  ──gen-cron.sh──>  block in the crontab  ──cron──>  zfs-job.sh ──> snapsend/delsnaps/check-snap-age
```

Without `--install` it only prints the block to the screen. With `--install` it replaces it
in the crontab. It always replaces the **whole block** between the markers
`# BEGIN zfs-backup-managed` and `# END zfs-backup-managed`, never a single line.

This is where all the "wisdom" sits: checking that the config makes sense,
choosing flags, refusals. The engines are dumb, the generator is careful.

## What happens on a host over a day

Example (the hours depend on the config):

```
MANAGED BLOCK (written by gen-cron.sh)
  every hour         snapsend / snapget   snapshot and copy
  every hour         delsnaps             pruning the copy with the GFS ladder
  */15               check-snap-age       freshness monitors
  once a day         snapsend / snapget   daily tier
  once a week        snapsend / snapget   weekly tier
  after the push     delsnaps             pruning the given tier

OUTSIDE THE BLOCK (gen-cron.sh does not touch them)
  :15  every hour    git pull       the host fetches the new version of the scripts
  7:00 every day     alert-digest   one mail summarising the day
```

Every line records its start and end in `cron.log` (`ZFS-JOB BEGIN` / `END`)
and calls `notify-fail.sh` if anything returned an error.

**Deployment is a `git pull` at :15.** The package gets onto a host through `git clone`; when the host
cannot reach the repository, `prepare-source` sends a bundle over `scp`
from the current checkout and unpacks it on the host.

## Config: a relation as one block

The file `jobs.<host>.conf`, sections in square brackets. A relation created from the GUI
or from `zfs-backup.sh` is written by the tool itself:

- the `[relation:NAME]` block carries the policy: tiers, minutes, retention and monitor thresholds;
- `[dataset:…]` points to the dataset and the relation (`relation`, `side`); `[prune:…]` prunes on the other side;
- `prefix` is what we create, `pattern` is what we delete — they must match each other;
- a monitor has no section of its own, it arises where a tier has a `pattern` and thresholds;
- a full example with explanation: [DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md), section 6.

## Where the state lives

```
/etc/zfs-snapshot-all/jobs.<host>.conf     config (the only source of truth)
/etc/zfs-snapshot-all/clients/             relations with other hosts
account crontab (zfs-backup-managed block) the generated block
cron.log                                   what happened (next to the scripts)
```

## The account the jobs run on

When you do not give `--local-user` while creating a relation, the jobs run as
**root**. When you do (e.g. `--local-user=zfsbackup`), they run as that
delegated account with narrow ZFS permissions, and its crontab gets the block.
The delegated account must be able to read the config and the scripts — that is why the config lives
in `/etc/zfs-snapshot-all`, not under `/root`.

## If something does not work — the order of looking

1. `grep ZFS-JOB cron.log | tail` — did the job start at all
   (`BEGIN` without `END` = it died midway).
2. `gen-cron.sh -c <config>` without `--install` — does the config generate at all.
3. Compare the result with the live crontab before you install anything.
4. `zfs list -t snapshot <dataset>` — do the snapshots really exist.

**Before every crontab installation: a backup and a diff.** The risk lies in editing the
config or the crontab manually, outside the tool. Installation through `zfs-backup.sh`
refuses when the config would generate a block that deletes running jobs.
