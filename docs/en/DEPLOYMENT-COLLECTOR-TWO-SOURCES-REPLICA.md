# Deployment: collector, two sources, replica on removable media; passive chain

Polish version: [WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](../pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md).

Two scenarios on one installation flow:

- **A. A collector with two sources and a replica on removable media** (sections 3–8).
- **B. A passive chain: three hosts** — source → server 1 (backup) → server 2
  (a double of server 1) (section 9).

Shared by both: prerequisites (1), the job account (2), the installation flow (3),
teardown (10), pitfalls (11) and the final check (12).

## 1. Prerequisites

**Packages and time.** Every host with a collector needs ZFS, cron and git. The
dependency check at install time reports a missing `crontab`. Align the time zone
with the rest of the fleet, otherwise snapshot names carry a different time than
`creation` (activation warns about the mismatch):

```bash
timedatectl set-timezone Europe/Warsaw
```

**The operator's root-ssh channel** is needed only when the collector is to set up
the source side itself (`--join-remotely`, `--grant-remotely`): the collector must
be able to run `ssh root@source` in BatchMode, with the source's pin in
`/root/.ssh/known_hosts`. Without this channel use `--manual-join` (section 3).

**On production source hosts, create separate test datasets** if this is your first
deployment. You do not touch production, and the grant covers only what you point
it at.

## 2. The account the jobs run from

The account is a decision of **this relation**, given when it is created:

- `--local-user=NAME` — jobs run from the account `NAME`. The account is created if
  it does not exist, gets a delegation on the sources and on the target, and the job
  block goes into its crontab;
- no `--local-user` — jobs run as **root**.

There is no host-wide setting and no guessing: the account name is stored together
with the relation, so `activate` and `remove-client` read it back. The account on
the SOURCE side (`zfsbackup-<collector label>`) is created by `--join` and neither
of these flags concerns it. The replica always runs as root (it needs `zpool
import/export`).

## 3. Source installation flow

One command on the collector, repeated identically after every interruption — it
resumes from where it stopped. There are two variants of the source side.

**Manual variant (`--manual-join`) — three steps, not one.** The first step builds
the payload and **refuses to go on**. This is not an error:

```bash
# on the collector
./zfs-backup.sh --source=10.0.0.9:hdd/dane \
                --target=hdd/backups \
                --local-user=zfsbackup \
                --name=src-a \
                --install --yes --manual-join
```

```
>>> created target dataset hdd/backups/10.0.0.9
>>> Wsad gotowy: /root/scripts/pairing/kolektor-to-10.0.0.9.tgz
FATAL: cannot reach zfsbackup-kolektor@10.0.0.9 to find out whether it has
signed a scope ... Refusing; nothing was changed.
```

The collector has no right to **guess** what the source has granted it. Until the
source signs the scope, replicating "what I remember" would be a silent drift of
permissions from reality.

Step two — **on the source**, from its own console:

```bash
scp <collector>:/root/scripts/pairing/kolektor-to-10.0.0.9.tgz /root/
./deploy.sh --join=/root/kolektor-to-10.0.0.9.tgz
```

It asks for the **number of datasets**, not for "y/n". This is deliberate: you have
to read the number, you cannot accept it by reflex.

```
>>> Kolektor prosil o: hdd/dane
>>> Przyjecie nada kontu zfsbackup-kolektor prawa
>>>   snapshot,destroy,mount,send,hold,release,bookmark
>>> na 3 dataset(ach), w tym 2 wolumen(ach) maszyn, lacznie 40.5 MiB.
Wpisz liczbe datasetow (3) aby ZAAKCEPTOWAC, [e]dytuj, [n]przerwij:
```

Step three — **the same command as in step one**. It finishes the seeding, verifies
the endpoint and installs cron:

```
>>> client 'src-a' is active; endpoint and installed cron both use '10.0.0.9:22'.
```

**Remote variant (`--join-remotely`, the default).** When you have a root-ssh
channel (section 1), the whole thing is one command on the collector:

```bash
./zfs-backup.sh --source=10.0.0.9:hdd/dane --target=hdd/backups \
                --local-user=zfsbackup --name=src-a \
                --grant-remotely --yes --install
```

What it does:

1. creates the delegated account, key and gate on the source over the root-ssh
   channel;
2. with **`--grant-remotely`** it writes a scope EQUAL TO THE REQUEST on the source
   and runs `deploy.sh --commit-scope` there (the `GRANTED_REMOTELY_BY` trace in
   the source's manifest). Without this flag the flow is two-touch: the command
   stops with instructions on what to run on the source, and running it again
   resumes;
3. seeds (the first full transfer) and verifies the grants and the endpoint;
4. shows a preview of the crontab changes and installs the managed block into the
   crontab of the account from section 2. If that account's crontab already holds a
   managed block, the tool takes the config named in its `# Source:` line and
   appends the new relation's sections to that file; sections that already exist
   keep their values.

## 4. Scenario A: topology

```
10.0.0.9  (zrodlo-a)                       10.0.0.99 (kolektor)
hdd/dane              ──backup──►          hdd/backups/10.0.0.9/…
  ├ vm-900-disk-0                            
  └ vm-900-disk-1                                 │
                                                  │ replica
10.0.0.8  (zrodlo-b)                              ▼
hdd/dane              ──backup──►          pool `repl` on a USB disk
  ├ vm-900-disk-0                          (two disks, the same pool name,
  └ vm-900-disk-1                           different GUIDs = rotation)
```

**The collector pulls** (`pull`) from both sources with the delegated account, and
the replica is a copy of what the collector already has, onto a medium that gets
unplugged.

**The second source — identical** to the first:

```bash
./zfs-backup.sh --source=10.0.0.8:hdd/dane --target=hdd/backups \
                --local-user=zfsbackup --name=src-b --install --yes --manual-join
# … carry the payload over, deploy.sh --join on zrodlo-b, the same command again
```

**There is no "add a second source" step here.** Every relation is separate and
gets its own set of sections and its own minutes.

**You prepare the medium once, with the `prepare-media` verb.** The base dataset on
the disk tells the gate that the **right** disk is connected, and the same command
creates it. The list of free disks:

```bash
./zfs-backup.sh prepare-media --list
```

Without `--yes` the command only shows the plan (what will be erased). With `--yes`
it **erases the whole disk**, creates the pool (`failmode=continue`, `zstd`
compression, no mountpoint), creates the base dataset (`replica` by default; change
it with `--base=`) and exports the pool, so the disk can be unplugged right away:

```bash
./zfs-backup.sh prepare-media repl /dev/disk/by-id/<disk> --yes
```

Such a pool fits `--dst=repl/replica` from the next section.

Two rotating disks get **the same pool name** and different GUIDs. The gate
recognises the medium by GUID, not by name, so rotation works, and two disks
connected at once are **refused**, naming both.

## 5. Scenario A: replica on removable media

One command, any number of sources — `--source` can be repeated:

```bash
./zfs-backup.sh add-replica weekly \
    --source=hdd/backups/10.0.0.9 \
    --source=hdd/backups/10.0.0.8 \
    --dst=repl/replica \
    --install --yes
```

`add-replica` is an **upsert**: the same command with a different list of sources
changes the existing job. The default schedule (without `--schedule` or with
`--schedule=auto`) is a free night hour on that host — 22, 23, then 0–5, with a free
minute — once a day, so two replicas do not start together; an existing replica
keeps its schedule. The replica is **not an online mirror**: the medium is at risk
only while its pool is imported, so the number of runs **is** the exposure.

Running outside the schedule:

```bash
./zfs-backup.sh run-replicas          # safe at any time
./zfs-backup.sh list-replicas         # inventory + live medium state
```

Optionally, **not by default**, a trigger when a disk is connected:

```bash
./zfs-backup.sh install-media-trigger --install
```

## 6. Scenario A: what lands in the config

The tool writes the relation — you do not write it by hand. One `[relation:NAME]`
block carries the whole policy of the relation (tiers, retention and the minutes of
each side), and the relation's sections only point to it through
`relation = NAME` and say which side they are on (`side`). This is what a relation
with one dataset on the collector looks like (an abridged real config):

```ini
[relation:src-a]
	tiers = hourly, daily
	hourly.target_send_schedule = 1 * * * *     # values from the template; minutes
	hourly.prune_schedule = 21 * * * *          # of each dataset below
	…                                           # (.retain, .prefix, .monitor …)

[dataset:hdd/backups/10.0.0.9/hdd/dane]         # the copy at the collector
	relation     = src-a
	side         = target
	send_schedule_hourly = 13 * * * *           # this dataset's own minute
	send_schedule_daily = 23 1 * * *
	prune_schedule_hourly = 33 * * * *          # prune of the COPY: +20
	prune_schedule_daily = 43 1 * * *
	…                                           # src, pair_label, flags -- the tool

[prune:zfsbackup-kolektor@10.0.0.9:hdd/dane]    # prune of the SOURCE, over SSH
	relation     = src-a
	side         = source
	prune_schedule_hourly = 53 * * * *          # prune of the SOURCE: +40
	prune_schedule_daily = 3 2 * * *
```

The second section is the one that is easiest to forget: **the backup also creates
snapshots on the source**, and without its limit the source pool grows without end.

A hand-written config may use templates instead of the block (`[template:]` +
`use_template`), but inside a `[relation:]` block templates must not be mixed in.
Relations created by the GUI (F3 Relacje (relations)) and by the CLI are always
written as a block.

The replica has its own config, because it runs as **root**, while the backups run
as the delegated account:

```ini
[replica:weekly]
	source    = hdd/backups/10.0.0.9,hdd/backups/10.0.0.8
	dst       = repl/replica
	schedule  = 12 23 * * *              # a free night hour, chosen automatically
	prefix    = replica_
	media     = removable
	recursive = yes
```

## 7. Scenario A: what lands in the schedule

Seven jobs, **seven different minutes** — three slots per relation (the table shows
the hourly tier), plus the replica once a day at night:

| minute | job | touches |
|---|---|---|
| `:13` | backup src-a | SSH to zrodlo-a |
| `:07` | backup src-b | SSH to zrodlo-b |
| `:33` | prune of the copy of src-a | local disk only |
| `:27` | prune of the copy of src-b | local disk only |
| `:53` | prune of the **source** of src-a | **SSH to zrodlo-a** |
| `:47` | prune of the **source** of src-b | **SSH to zrodlo-b** |
| a free minute, a night hour | replica (root) | pool import/export |

The base minute is chosen **once, when the relation is created**: it starts from the
checksum of the relation name, then takes the first minute the host does not use
yet. The result goes into the section. The next slots are `+20` (prune of the copy)
and `+40` (prune of the source). Sections that already exist keep their minutes, so
adding a third relation does not touch existing lines.

A job line looks like this:

```
13 * * * * /root/scripts/zfs-snapshot-all/zfs-job.sh "kolektor … backup (src-a-dane)" \
           --log=/root/scripts/cron.log --notify=/root/scripts/notify-fail.sh \
           --detail=8 -- /home/zfsbackup/zfs-snapshot-all/snapget.sh -m … 
```

The envelope (`ZFS-JOB BEGIN/END`, stderr capture, notification) lives in
`zfs-job.sh`, and **the engine command stays visible** after `--`. You can copy the
line and run it by hand — it behaves exactly as it does under cron. The reason is
hard: cron accepts a command of up to **1000 bytes**.

## 8. Scenario A: medium rotation, timings and statistics

```bash
# disk A connected, a night run or run-replicas — after the run the pool is
# exported and the disk can be pulled out
./zfs-backup.sh list-replicas     # 'available' = connected, not imported
```

After disk B is connected (a different GUID, the same pool name), the first run
**pulls it in**, because the gate compares the GUID with the record and finds it is
a different medium. The record keeps one line per source:

```
guid=3717319648122292429
snap:hdd/backups/10.0.0.9=replica_<date>_<time>
snap:hdd/backups/10.0.0.8=replica_<date>_<time>
```

Skipping a run requires **all** conditions at once: this GUID, every source quiet,
every source proven on this disk. When any condition is not met, the run imports the
pool as usual.

**Two disks at once are refused**, with `rc=2` and both named:

```
REFUSING: 2 pools named 'repl' are available to import. Rotated media often
share a name, so this is two disks in at once. Unplug one, or import the one
you mean by its id and re-run -- this will not choose for you.
```

**A medium with a foreign line is refused too.** If the disk carries a replica of a
relation that no longer exists, and the collector has a new family of snapshots with
no common ancestor, the gate names both families and presents the choice (a
different `--dst`, or `zfs destroy -r` on the target), instead of throwing a ZFS
error every night.

Timings and statistics — two levels, both already recorded:

```bash
# job level: the full history, a pair of markers per run
grep "ZFS-JOB" /home/zfsbackup/cron.log

# dataset level: mode, time, volume, throughput
./zfs-backup.sh progress --json
```

Example fields (illustrative numbers):

```
total_bytes = 1000000000   done_bytes = 400000000
wire_bytes  =  250000000   rate_bps   =  50000000
```

`done_bytes` is what the engine pushed into the pipe, `wire_bytes` is what went out
over the link — with compression the link carries less than `done_bytes`, and the
difference is the compression. `-1` means "not measurable here" (with `push`,
mbuffer sits on the remote side), **never 0**, so that a missing measurement is not
read as an idle link. The observer samples **every 2 seconds**, so a transfer
shorter than a tick leaves zeros. Records are pruned on every engine run — after 7
days, skipping those in the `running` state.

## 9. Scenario B: passive chain, three hosts

```
source               server 1 (backup)             server 2 (double)
hdd/dane   ────────► hdd/kopie/<source>/… ───────► hdd/kopie/<source>/…
      link A: backup                link B: sync (passive)
```

Both links are collectors: server 1 pulls from the source, server 2 pulls from
server 1. You choose the job account separately on each collector (section 2), with
the `--local-user` flag when creating the given link.

**Requirements of server 2.** The pool must have **the same name** as on server 1
(sync recreates the same paths). The kernel and headers must match each other,
because the ZFS module is built for a specific kernel. A root-ssh channel from
server 2 to server 1 is needed only for the remote variant (section 1).

**Link A — backup, one command on server 1:**

```bash
# on server 1:
./zfs-backup.sh \
    --source=<source>:hdd/dane \
    --target=hdd/kopie \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

Verifying link A: compare the checksum of a file on the source and in the copy, and
the `guid` of the same snapshot on both sides — it must be identical:

```bash
# on server 1:
zfs list -H -t snapshot -o name -r hdd/kopie/<source>/hdd/dane
zfs get -H -o value guid "hdd/kopie/<source>/hdd/dane@<snapshot>"
# on the source, the same snapshot:
zfs get -H -o value guid "hdd/dane@<snapshot>"
```

**Link B — the double, one command on server 2:**

```bash
# on server 2:
./zfs-backup.sh \
    --source=<server1>:hdd/kopie/<source>/hdd/dane \
    --mode=sync \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

`--mode=sync` is an identity mapping (the same path on the double — hence the
requirement of the same pool name). You get a refusal if server 1 looks like a
member of the same PVE cluster as server 2: inside a cluster `pvesr` already
replicates, so use `--mode=backup` there.

Because the source of link B **already carries the `automated_*` family** (link A
produces it), the relation is detected as **PASSIVE**: `snapget -e` consumes the
newest existing snapshot, creates nothing on the source and prunes nothing — the
retention of the family stays with server 1. The passive schedule is `:31` (half an
hour behind the producer), the monitor thresholds are 3h/5h (the chain's cadence).
The activation preview states the passivity outright.

Verifying the end of the chain:

```bash
# on server 2:
zfs mount hdd/kopie/<source>/hdd/dane        # the copies are noauto
```

Proof of an increment: add a file on the source, wait for a run of link A and a run
of link B; the checksum of the new file must be identical on all three hosts. The
runs are visible in the log by their markers:

```bash
grep ZFS-JOB /home/zfsbackup/cron.log | tail    # BEGIN/END rc=… per run
```

## 10. Teardown — exactly in reverse

One order for both scenarios: first whatever pulls furthest from the source (the
replica, then link B of the chain), and the link next to the source last.

On the collector (for scenario A):

```bash
./zfs-backup.sh remove-replica weekly --install --yes
./zfs-backup.sh remove-client src-a
./zfs-backup.sh remove-client src-b
./clean-relationships.sh --purge-orphans --yes
zfs destroy -r hdd/backups          # a human deletes the DATA, not the tool
```

Scenario B: first `remove-client` on server 2 (the double stops pulling before its
source disappears) and `deploy.sh --leave` on server 1; then `remove-client` on
server 1 and `deploy.sh --leave` on the source.

On every host that is a source of a relation, from its own console (label = the
collector's short hostname):

```bash
./deploy.sh --leave=kolektor
./clean-relationships.sh            # must end with "nothing orphaned"
```

`remove-client` removes the sections from the crontab and the collector's pairing
record. `--leave` on the source removes the delegated account, the `zfs allow`
grants, the join manifest and the scope files. If `--leave` refuses because of an
unclosed `zfs unallow` (an old manual grant), run the `zfs unallow -u <uid>
<dataset>` named in the message and repeat the same command.

`remove-replica` on the **last** job in the config removes the whole managed block
and says so outright. None of these verbs deletes datasets or the copies on the
medium: "unpairing ends the relationship, not the backup".

**The package does not delete the copies on the medium** — there is no separate verb
for that. The disk is cleaned by formatting: in the GUI, change the replica ->
"Dodaj dysk" (add disk).

## 11. Pitfalls

| pitfall | what to do |
|---|---|
| a collector without a root-ssh channel to production | use `--manual-join` (section 3); do not assume permanent root→production trust |
| no `crontab` on a fresh host | install cron; the dependency check will catch it |
| a host time zone different from the rest of the fleet | set it (section 1); activation warns about the mismatch |
| two links of a chain creating one family of snapshots | link B on an existing family is PASSIVE and creates or prunes nothing; do not bypass this with a hand-written config |
| a delegated account gets a **freed UID** after a previous one | `--leave` takes away the gate directory; the audit must end with "nothing orphaned" |
| the same relation name reused | the old record lands as `*.conf.removed-<ts>`; the audit **lists** them, it does not delete |
| a cron line close to 1000 bytes | the envelope is in `zfs-job.sh`; if `crontab` refuses, the message names every command over the limit with its length |
| schedule after a reinstall | always compare before installing: regeneration from the config vs the live `crontab -l` |
| `--leave` refuses with an unclosed `zfs unallow` | run the `zfs unallow` named in the message and repeat the same command |

Three guards act on their own, by design: the refusal of a full resend without `-f`,
the refusal of an install that deletes jobs, and the fail-closed `--leave` on an
unclosed `unallow`.

## 12. Final check

```bash
./zfs-backup.sh status              # every relation: state=active
./zfs-backup.sh list-replicas       # medium: here / available / away / wrong_medium
./clean-relationships.sh            # "nothing orphaned" on EVERY host
zfs list -r hdd/backups             # the data at the collector
```
