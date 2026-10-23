# Commands: the full list

Polish version: [KOMENDY.md](../pl/KOMENDY.md).

This document is an **inventory of what the package can do**, arranged the way you
use it, not alphabetically. The full set of flags of each program is given by its
own `-h`; here you will find **why** a command exists and **when** to use it.

---

## 1. Seven programs and the division of work

| program | role |
|---|---|
| `zfs-backup.sh` | **operator verbs**: relation lifecycle, control, restore. This is what a human touches |
| `deploy.sh` | **the machinery**: dependencies, delegated account, pairing, consents. Run on the host it concerns |
| `snapsend.sh` / `snapget.sh` | **transfer engines**: push and pull. Called by cron (snapsend also by restore in place), not by hand. A push relation in 1.0 is a CLI mode for an existing fleet (the GUI does not create it) -- recipe in the README, snapsend.sh section |
| `delsnaps.sh` | **retention engine**: the only one that prunes snapshots according to retention. Data can still be overwritten by `-f` in the transfer engines and by `restore --overwrite` (restore onto an existing dataset, `zfs-restore.sh`) |
| `check-snap-age.sh` | **monitor**: whether the backup has gone stale |
| `gen-cron.sh` | turns a config into a block in the crontab |

The engines are **frozen** (`docs/project/ENGINE-FREEZE.md`): they change only
on an explicit order from the owner, with an entry in that file.

---

## 2. Relation lifecycle: the normal path, in order

A relation is: **collector + protected machine + a set of datasets + schedule**.
It has a name (it goes into the cron line as `-L` and into the config as `pair_label`), a record on the collector and a delegated account on the
protected machine.

```bash
# 1. one command, from scratch to a working schedule
zfs-backup.sh --source=HOST:DATASET --target=COPY --name=NAME --install --yes
```

This composite does the three steps below for you. It is **idempotent and resumable**
-- after an interruption you run exactly the same command again.

The steps separately -- call them directly **only to unblock a stuck
activation**:

```bash
zfs-backup.sh add-client NAME --host=HOST[:PORT] [--target=X] [--profile=NAME]
zfs-backup.sh seed NAME [--yes]              # first transfer, cron NOT installed
zfs-backup.sh set-endpoint NAME --host=HOST[:PORT]
zfs-backup.sh verify-endpoint NAME
zfs-backup.sh final-catchup NAME [--yes]
zfs-backup.sh activate-client NAME [--yes]   # only this installs cron
```

**Pairing has two sides.** `add-client` produces a bundle; on the protected
machine you have to accept it:

```bash
# on the protected machine, from the console:
deploy.sh --join=/root/<bundle>.tgz
```

`--join` is **interactive by design**: to accept the scope you have to
type **the number of datasets**. A consent that a reflex cannot give.

---

## 3. Controlling a relation

```bash
zfs-backup.sh status [NAME]                  # what exists, in what state
zfs-backup.sh pause-client NAME [--reason=TEXT]
zfs-backup.sh resume-client NAME
zfs-backup.sh disable-client NAME [--reason=TEXT]
zfs-backup.sh enable-client NAME
zfs-backup.sh remove-client NAME
```

**Pause versus disable: they are not the same, and the difference matters:**

- **`pause-client`**: a *logical* pause. The jobs of this relation skip themselves.
  An orchestration switch, not a security boundary: a manual invocation of an engine
  **without `-L NAME`** is not stopped.
- **`disable-client`**: the **peer refuses** this relation's commands, including those without `-L`.
  Enforced on the other side.

**What the pause covers:** pull, prune **and** monitor. It works only where the job
lines carry `-L NAME`, and that comes from `pair_label` in the config, so a config
without `pair_label` (old, hand-written) cannot be paused.

---

## 4. Restore

### Preview: nothing is touched

```bash
zfs-backup.sh restore --plan
zfs-backup.sh restore --plan --dataset=DATASET
```

Shows what can be restored, from where, and **when each snapshot was really
made**: by the ZFS `creation` property, never by name. The name and `creation`
can differ by a time zone between hosts.

### Restore onto your own machine

```bash
zfs-backup.sh restore RELATION --yes                      # the whole relation, the latest point
zfs-backup.sh restore RELATION:DATASET --yes              # one dataset
zfs-backup.sh restore RELATION --target ds1,ds2 --yes     # selected ones
zfs-backup.sh restore RELATION --at="2026-08-10 12:00" --yes
```

`--at` is **wall-clock time**, resolved per dataset by `creation`.

### Restore onto a **different** machine

```bash
zfs-backup.sh restore FROM TO --yes                   # the same paths
zfs-backup.sh restore FROM:ds TO:ds2 --yes            # a different path
```

`TO` is a **pairing label** (the name under which the collector knows a paired machine), never an arbitrary host. That is, a machine the
collector is already paired with, has a pinned key for, and can ask for consent. You
cannot point at a machine this host has never met. The target must be
**paired**, not activated.

### Handing the copy over to a new machine

```bash
zfs-backup.sh move-to-client FROM TO [--yes]
```

For when the relation's machine has been **replaced**. The copy **does not move off the disk**:
what changes is which machine it is backed up from, so there is **no new
seed**. It refuses until the data is already on the new machine, and it **proves this
by GUID, per dataset**. It **pauses** the old relation, it does not delete it.

**The order is enforced:** pair, restore onto it, hand over. In the reverse order
the schedule aims at an empty machine.

### Three conditions that must be met

1. **Consent**: the protected machine must publish it (section 5).
2. **Pause**: restore itself suspends the relation's schedule for the duration of the restore
   and resumes it afterwards (a pause set earlier by a human
   is left untouched). If the pause cannot be set, restore **refuses**.
3. **Target unmounted** in `replace` mode: the delegated account will not unmount
   under Linux.

---

## 5. Consents: on the protected machine

Run **as root on the machine that is to be written to**. The collector cannot
grant itself anything; that is the whole value of this mechanism.

```bash
deploy.sh --allow-restore=LABEL [--replace]
deploy.sh --deny-restore=LABEL
deploy.sh --show-restore=LABEL
```

`--replace` is separate and never follows from an ordinary consent: it allows
**destroying** what the machine has now and putting an older copy in its place. Without it
the collector can write where there is free space.

The consent **does not expire**. It grants exactly `receive,rollback,create,canmount,mountpoint`
and on withdrawal takes away **exactly those**; the backup permissions stay.

---

## 6. Deploying a machine

```bash
deploy.sh                              # prepare the host
deploy.sh --check-only                 # audit, changes nothing
deploy.sh --backup-user=zfsbackup      # create the delegated account
deploy.sh --self-update                # update the package
deploy.sh --rollback                   # undo the update
```

Pairing and scope:

```bash
deploy.sh --pair ...                   # initiating side (collector)
deploy.sh --join=PACKAGE                  # accepting side
deploy.sh --draft-scope=LABEL       # print a proposed scope
deploy.sh --commit-scope=LABEL      # grant the scope
deploy.sh --leave=LABEL             # dismantle the relation on the peer side
deploy.sh --unpair                     # end the relation on this side
```

---

## 7. Engines: called by cron

They are not run by hand in normal work. Full flag lists: `-h`.

```bash
snapsend.sh [opcje] DATASETS [BAZA_CELU]      # push
snapget.sh  [opcje] ZDALNE_DATASETY [BAZA]    # pull
delsnaps.sh [opcje] DATASETS PATTERN RETENTION # deletion
check-snap-age.sh [-R] [-L LABEL] DATASETS PATTERN WARN CRIT
```

Flag families worth knowing:

| flag | meaning |
|---|---|
| `-m PREFIX` | snapshot name prefix; with `-e` it selects an **existing** one |
| `-r` / `-R` | recursion: one atomic stream / a separate job per dataset |
| `-L LABEL` | the relation the invocation belongs to: **this is what the pause reads** |
| `-K` / `-k` / `-O` | key, pinned known_hosts, ssh options |
| `-b BYTES` | bandwidth limit (**bytes**, not bits) |
| `-z` / `-Z` / `-A` | compression / autotune |
| `-q MODE` | guest quiesce before the snapshot |
| `-f` | full send: **destroys and recreates the target**, requires root |
| `-F` | *snapget*: reconciliation on a name collision under a different GUID |
| `-t` | the target is an **exact path**, not a base (the restore path) |

**`-H`/`-D`/`-W`/`-M`/`-Y`** in `delsnaps.sh` mean *how many to keep*; the lowercase
`-h`/`-d`/`-w`/`-m`/`-y` set an age threshold: snapshots older than the
given number of hours/days/weeks/months/years are deleted. `-G` turns on the GFS ladder.

---

## 8. Schedule

```bash
gen-cron.sh -c CONFIG              # print the block, install nothing
gen-cron.sh -c CONFIG --install    # install/replace the managed block
gen-cron.sh --uninstall            # remove the block (the config stays)
```

Run **as the relation's account**, not as root: `REPO_DIR` comes from
where the script lies, so root will generate root's paths.

**Always take a backup copy and a diff before installing.** The hourly self-update
`git pull` line sits **outside** the managed block and must survive.

---

## 9. Diagnostics

```bash
zfs-backup.sh status                 # state of all relations
zfs-backup.sh progress               # progress of running transfers
zfs-backup.sh test NAME             # trial pull (dry-run) of every dataset of the relation
zfs-backup.sh --version
deploy.sh --check-only               # host audit
deploy.sh --test-mail                # whether alerts get out
```

---

## 10. Where things live

| path | what |
|---|---|
| `/etc/zfs-snapshot-all/jobs.<host>[.<account>].conf` | job config |
| `/etc/zfs-snapshot-all/clients/<name>.conf` | relation record (collector) |
| `/etc/zfs-snapshot-all/peers/<label>.conf` | pairing manifest |
| `/etc/zfs-snapshot-all/settings.ini` | host settings |
| `/var/lib/zfs-snapshot-all/relationships/<label>/paused` | pause marker |
| `/var/lib/zfs-snapshot-all/restore-grants/<label>` | restore consent |
| `/usr/local/sbin/zfs-pair-gate` | gate of the forced ssh command |
| `/root/scripts/cron.log`, `/root/scripts/zfs-snapshot-stats.log` | root's job logs |
| `~/cron.log`, `~/zfs-snapshot-stats.log` | delegated account's job logs (`~` = its home directory) |

---

## 11. The remaining `zfs-backup.sh` verbs, by topic

Full flags: `zfs-backup.sh --help`. Verbs without `--yes` only plan.

### Relations

| verb | what for | example |
|---|---|---|
| `edit-relation` | change an installed relation in place (sections regenerated from the profile); no pairing and no data movement | `zfs-backup.sh edit-relation NAME --profile=P --plan` |
| `delete-relation` | remove a relation entirely: the jobs here, the account on the source (`deploy.sh --leave`, skipped when another relation uses this host) and the record, which frees the name; copies on disk stay unless `--destroy-copies`; without `--yes` only a plan | `zfs-backup.sh delete-relation NAME --yes` |
| `add-source` | add one dataset to an installed relation, on both sides | `zfs-backup.sh add-source NAME hdd/db --yes` |
| `remove-source` | take one dataset out of a relation, on both sides; copies already taken stay | `zfs-backup.sh remove-source NAME hdd/db --yes` |
| `export-relation` | write the relation's declarations out as a document (with `--json`) | `zfs-backup.sh export-relation NAME --json` |
| `import-relation` | recreate a relation from such a file; without `--yes` it only prints the commands | `zfs-backup.sh import-relation plik.json --name=NOWA --yes` |
| `test NAME` | trial pull (dry-run) of every dataset of the relation | `zfs-backup.sh test NAME` |

### Replicas (copies on removable disks)

| verb | what for | example |
|---|---|---|
| `add-replica` | add or change a replica (upsert); without `--install` only a plan; `--ask` = GUI windows | `zfs-backup.sh add-replica usb1 --source=hdd/dane --dst=usbrep1/replica --install` |
| `list-replicas` | list of replicas and medium state: here, available, away, wrong_medium | `zfs-backup.sh list-replicas` |
| `run-replicas` | run all replicas now; a missing medium is a silent skip | `zfs-backup.sh run-replicas --name=usb1` |
| `prepare-media` | prepare a disk as a replica medium (**erases it**); `--list` shows free disks | `zfs-backup.sh prepare-media usbrep1 /dev/sdX --yes` |

### Retention

| verb | what for | example |
|---|---|---|
| `show-tiers` | the retention tiers of one relation, from its block in the config | `zfs-backup.sh show-tiers NAME` |
| `set-tiers` | change the tiers in the config in one atomic swap | `zfs-backup.sh set-tiers NAME --tier=TIER --keep=N --plan` |
| `audit-source-retention` | audit: which pull sources have no bounded retention; `--apply` adds the missing ones | `zfs-backup.sh audit-source-retention` |

### Restore

| verb | what for | example |
|---|---|---|
| `restore --plan` | what can be restored and from where (read only) | `zfs-backup.sh restore --plan` |
| `restore RELATION` | restore a relation from its copy (see section 4) | `zfs-backup.sh restore NAME --yes` |
| `restore --from-copy` | restore from a copy on this pool when the relation records are gone; described in [RESTORE-FROM-REPLICA.md](RESTORE-FROM-REPLICA.md) | `zfs-backup.sh restore --from-copy COPY --onto DATASET` |

### GUI

| verb | what for | example |
|---|---|---|
| `gui` | the control screen (requires `python3`; F3 Relacje (relations), F6 Replika (replica)) | `zfs-backup.sh gui` |

---

## 12. Good to know in advance

**After a restore with a rollback, the next backup will refuse.** That is correct: the copy holds
snapshots that the source no longer has, and they are the only trace of that period.
The refusal names them and gives the way out: `zfs rollback -r <copy>@<point>`
does both at once, without root and without sending again.
