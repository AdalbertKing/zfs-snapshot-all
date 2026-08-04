# Proxmox deployment — a step-by-step guide

Written for an administrator who knows Linux and the basics of ZFS but is
seeing this toolkit for the first time. No knowledge of its internals is
assumed — only that you can read `zfs list` and edit a file in `vi`.

Polish version: [WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md).

---

## 1. The deployment we are building

Two Proxmox VE hosts with **no prior trust** between them — not clustered, no
exchanged SSH keys.

| Role | Example name | Address | What it does |
|---|---|---|---|
| **Collector** | `pve-backup` | `192.168.1.10` | holds the copies, manages everything, **initiates the connection** |
| **Source** | `pve-prod` | `192.168.1.20` | production, hands over data, initiates nothing |

The source holds a typical Proxmox layout:

```
rpool/data/vm-100-disk-0      <- production VM
rpool/data/vm-101-disk-0      <- production VM
rpool/data/vm-999-disk-0      <- test machine, deliberately NOT backed up
rpool/data/scratch            <- working area
rpool/data/scratch/tmp-a        (and its children)
```

On the collector, copies land under `rpool/backups`.

### Two principles worth understanding before you start

**Direction: the collector PULLS.** `pve-backup` connects to `pve-prod`, never
the other way round. The security consequence is the whole point:
**compromising production does not give access to the backups.** The
production host holds no key to the collector and has no idea how to reach it.
Ransomware that encrypts `pve-prod` has no route to `rpool/backups`.

**Split of decisions: the source decides WHAT, the collector decides HOW.** The
dataset selection is made by an administrator *on the source machine*, where
the knowledge of what is what actually lives. Schedule and retention are the
collector's business. Nobody has to guess somebody else's disk layout.

---

## 2. Before you begin

On **both** hosts:

- Proxmox VE with a ZFS pool (`rpool`),
- root SSH access (for the deployment; the jobs themselves end up running as a
  delegated account),
- network reachability from collector to source (port 22 or your own).

Required packages (`zfs`, `mbuffer`, `zstd`) **are installed by `deploy.sh`
itself** — you do not need to prepare them.

Clone the repository on both hosts, in the same place:

```bash
git clone https://github.com/AdalbertKing/zfs-snapshot-all.git /root/zfs-snapshot-all
```

> **Never copy the scripts onto a host with `scp`.** Updates arrive through an
> hourly `git pull --ff-only`. A hand-placed file makes the tree dirty and
> **permanently blocks automatic updates** on that host — silently, with no
> alert.

---

## 3. The deployment procedure

Every step states **which host** it runs on. The order is not optional.

### Step 1 — prepare the collector `pve-backup`

```bash
cd /root/zfs-snapshot-all
./zfs-backup.sh setup-server --target=rpool/backups --local-user=zfsbackup
```

This installs dependencies, creates the delegated `zfsbackup` account, creates
the `rpool/backups` dataset, writes the job config, and installs the
self-update cron entry.

`--local-user=zfsbackup` means **the backup jobs will not run as root.** Worth
doing: it bounds the damage if anything goes wrong.

Confirm a clean state:

```bash
./deploy.sh --check-only
```

### Step 2 — enrol the client (still on `pve-backup`)

```bash
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=backup
```

- `prod01` is the durable name of this relationship. It **never changes**, not
  even when the source changes its IP address. Use it in every later command.
- `--mode=backup` says: "I am not listing datasets here, the source's
  administrator will choose them." This is the path you want. (For `sync`, see
  section 6.)

The command prints the **path to a pairing package** (a `.tgz`) and the exact
command to run on the source. Note them down.

The package carries no collector secrets — a public key and the relationship's
parameters.

### Step 3 — move the package to the source

Copy the `.tgz` to `pve-prod` by any means (`scp` from your workstation, a USB
stick, whatever). This is the only manual transfer in the whole procedure.

### Step 4 — accept the pairing on the source `pve-prod`

```bash
cd /root/zfs-snapshot-all
./deploy.sh --join=/root/prod01-package.tgz
```

This creates a dedicated account for this one relationship, installs the
collector's key, and — importantly — grants it **zero ZFS permissions**.

That is a safe intermediate state, not an oversight: the collector can already
connect and run `zfs list` (`zfs allow` does not restrict listing), but cannot
read a single byte of data until you deliberately grant it in step 6.

The command prints a **LABEL**, the relationship's tag, needed in the next two
steps. For `--lan=192.168.1.20` the label is `192.168.1.20`.

### Step 5 — generate the scope file (`pve-prod`)

```bash
./deploy.sh --draft-scope=192.168.1.20
```

This writes `/etc/zfs-snapshot-all/peers/192.168.1.20.scope`, generated from
this machine's **real** ZFS inventory rather than guessed. Inside: a proposed
active section plus the complete dataset inventory as comments, to copy
entries up from.

### Step 6 — choose datasets and exclusions (`pve-prod`)

**This is the only step that requires thought.** Edit the file:

```bash
vi /etc/zfs-snapshot-all/peers/192.168.1.20.scope
```

The grammar has four fields and no magic:

| Field | Meaning |
|---|---|
| `include_parent` | take the named dataset **itself** |
| `include_children` | take **everything beneath it** |
| `exclude` | skip **exactly this one** dataset |
| `exclude_tree` | skip this dataset **and everything below it** |

#### Variant A — recursive, with exclusions (the usual case)

Take every VM disk under `rpool/data`, but not the test machine and not the
working area:

```ini
[dataset:rpool/data]
    include_parent   = no
    include_children = yes
    exclude          = rpool/data/vm-999-disk-0
    exclude_tree     = rpool/data/scratch
```

Read it as: *"`rpool/data` itself is not interesting (it is a container, not
data), everything under it is, except that one machine and except the whole
`scratch` branch."*

Result: `vm-100-disk-0` and `vm-101-disk-0` are covered. Skipped:
`vm-999-disk-0`, `scratch`, and all of `scratch`'s children.

#### Variant B — non-recursive (explicit selection)

When you want to name exactly what is copied and nothing else:

```ini
[dataset:rpool/data/vm-100-disk-0]
    include_parent   = yes
    include_children = no

[dataset:rpool/data/vm-101-disk-0]
    include_parent   = yes
    include_children = no
```

Here `include_parent = yes` means "this specific dataset" and
`include_children = no` means "and nothing under it" (VM disks rarely have
children anyway).

**Which one?** Variant A when the rule is "every machine in this pool".
Variant B when you back up selected machines and the rest is deliberately out
of scope. Note the limitation in section 7 — it may decide this for you.

The file is read as **data, never as code**. A typo, an unknown field or a
duplicated section is a refusal quoting the line number, returning you to the
editor — never a half-applied deployment.

### Step 7 — grant the permissions (`pve-prod`)

```bash
./deploy.sh --commit-scope=192.168.1.20
```

Only **now** does the collector's account receive ZFS permissions, and exactly
to what the file from step 6 selects.

This is a deliberately separate command: the scope file gets edited repeatedly
and with mistakes, while granting access should be one considered act. Before
anything happens you see the **entire plan** — what will be granted, what
revoked — rather than discovering it line by line during execution.

Re-running it after an edit **also revokes** what the new scope no longer
covers, but strictly within this relationship. A grant made by another
relationship, or by hand, is invisible to this command and stays untouched.

### Step 8 — the first copy (back on `pve-backup`)

```bash
./zfs-backup.sh seed prod01
```

A full baseline transfer. It takes as long as moving the data takes — for a
few hundred GB over gigabit, think hours. Run it under `screen`/`tmux`.

### Step 9 — verify the connection (`pve-backup`)

```bash
./zfs-backup.sh verify-endpoint prod01
```

Confirms that the address the connection actually uses works and is the one
you think it is. **No cron is installed until this passes** — a deliberate
gate, not a formality.

### Step 10 — go live (`pve-backup`)

```bash
./zfs-backup.sh activate-client prod01
```

Only now are the cron entries written. From here the backup runs itself.

### Step 11 — check

```bash
./zfs-backup.sh status
./zfs-backup.sh test prod01
zfs list -r rpool/backups
```

State `active` means done.

---

## 4. Where the data lands (`backup` mode)

The destination path is **target + relationship label + the full source path**:

```
rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0
rpool/backups/192.168.1.20/rpool/data/vm-101-disk-0
```

Verbose, but unambiguous: the label tells you at a glance which machine a copy
came from, and the original path is preserved intact. One collector can
therefore accept `rpool/data/vm-100-disk-0` from ten different hosts with no
name collision at all.

---

## 5. What happens once it is running

The default profile (the only one implemented), values taken straight from the
code:

| Item | Setting |
|---|---|
| Snapshot + transfer | hourly, at **:01** |
| Snapshot prefix | `automated_hourly_` |
| Pruning (GFS) | hourly, at **:21** |
| Retention | **24** hourly, **7** daily, **4** weekly, **12** monthly |
| Alert (warning) | no fresh copy for **90 min** |
| Alert (critical) | no fresh copy for **150 min** |

Retention is **GFS (grandfather-father-son)**: a single hourly snapshot series
is bucketed by creation time. There are no separate "daily" or "monthly"
transfers — those would be extra copies of the same data.

Alerts go out by mail. The default is one digest per host per day; while
bringing a host up, immediate alerting is worth it:

```bash
./deploy.sh --alerts=immediate
```

---

## 6. `sync` mode — a mirror rather than an archive

Instead of `--mode=backup` in step 2:

```bash
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=sync
```

One difference, but a fundamental one: **paths are reproduced one to one.**

```
source:       rpool/data/vm-100-disk-0
destination:  rpool/data/vm-100-disk-0     <- identical path, other host
```

No label prefix, and no `--target` (passing one is refused) — there is nothing
to name when the layout is meant to be identical.

**When to use it:** when you are building a standby machine ready to take over,
not an archive. After `pve-prod` fails, the guests are on `pve-backup` under
exactly the paths the Proxmox configuration expects.

**When not to:** `sync` **refuses to pair with a host in the same PVE
cluster**, and rightly so. Within one cluster the same path is physically the
same dataset, so "source" and "destination" would be one object and the sync
would overwrite the data with itself. The gate sits at enrolment, before
anything is paired.

Exclusions and recursion behave identically — it is the same scope file. Only
the path mapping changes.

---

## 7. Limitations you need to know about

Stated plainly, because each of these will surprise you later if not now.

### 7.1. A new dataset is NOT picked up automatically

This is the single most important point in this guide.

`include_children = yes` expands into a **concrete list of datasets at the
moment `--commit-scope` runs**, and that list is then frozen. If you create
`rpool/data/vm-102-disk-0` tomorrow, **it will not be backed up** — it has no
grant and it is not on the list.

This is not a bug but a consequence of the model: permissions are granted
deliberately, per dataset. It does mean that **every new machine needs two
commands on the source**:

```bash
./deploy.sh --draft-scope=192.168.1.20   # only if no scope file exists
./deploy.sh --commit-scope=192.168.1.20  # after reviewing/extending the file
```

and then, on the collector:

```bash
./zfs-backup.sh activate-client prod01   # regenerates the jobs
```

> **Put this in your VM-creation runbook.** A machine everyone believes is
> backed up and nobody ever copied is the most expensive possible way to
> discover this limitation.

Automatic coverage of new datasets is planned but requires changing the
permission model. It does not exist today.

### 7.2. Copies are crash-consistent, not application-consistent

In pull mode there is **no guest filesystem freeze** (quiesce) — the virtual
machine lives on the remote host. A snapshot represents a "power cable pulled"
state: filesystems replay their journal, but a database caught mid-transaction
may need its own recovery.

For most workloads that is enough. For databases with a hard
application-consistency requirement, an application-level backup (a dump) is
needed **alongside** this mechanism.

### 7.3. The source changes address

When `pve-prod` changes IP, **you do not re-pair.** The name `prod01` is
independent of the address:

```bash
./zfs-backup.sh set-endpoint prod01 --host=192.168.5.20
./zfs-backup.sh verify-endpoint prod01
./zfs-backup.sh activate-client prod01
```

If a VPN preserves the same `host:port`, you do not even need that —
`verify-endpoint` alone is the whole story.

---

## 8. Adding a second source

One collector serves many sources. Repeat steps 2–10 with a new name:

```bash
./zfs-backup.sh add-client prod02 --lan=192.168.1.21 --mode=backup
```

Each relationship gets **its own account on the source, its own key, and its
own grant scope**. Relationships know nothing of each other and cannot touch
each other — compromising one source opens no route to the rest.

---

## 9. Teardown

On the collector:

```bash
./zfs-backup.sh remove-client prod01
```

This removes the cron jobs, the client record and the config sections. It
**does not delete data** under `rpool/backups` — if that should go, you do it
separately and deliberately.

On the source (removes this relationship's account, key and ZFS grants):

```bash
./deploy.sh --leave=192.168.1.20
```

---

## 10. The whole procedure on one page

```bash
# --- COLLECTOR pve-backup ---
./zfs-backup.sh setup-server --target=rpool/backups --local-user=zfsbackup
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=backup
#   -> move the printed .tgz package to pve-prod

# --- SOURCE pve-prod ---
./deploy.sh --join=/root/prod01-package.tgz
./deploy.sh --draft-scope=192.168.1.20
vi /etc/zfs-snapshot-all/peers/192.168.1.20.scope      # selection + exclusions
./deploy.sh --commit-scope=192.168.1.20

# --- COLLECTOR pve-backup ---
./zfs-backup.sh seed prod01
./zfs-backup.sh verify-endpoint prod01
./zfs-backup.sh activate-client prod01
./zfs-backup.sh status
```

---

## 11. When something does not work

| Symptom | Where to look |
|---|---|
| `seed` fails on permissions | was `--commit-scope` actually run? Check `zfs allow rpool/data` on the source |
| `verify-endpoint` refuses | address/port; the message distinguishes "cannot connect" from a data problem |
| no cron entries | the client never reached `endpoint_verified` — check `status` |
| a new VM is not being copied | that is section 7.1, not a failure |
| updates stopped arriving | `git -C /root/zfs-snapshot-all status` — a dirty tree blocks `--ff-only` |

The overall state is always available from:

```bash
./zfs-backup.sh status
./deploy.sh --check-only
```
