# Proxmox deployment — a step-by-step guide

Written for an administrator who knows Linux and the basics of ZFS but is
seeing this package for the first time. No knowledge of its internal
architecture is assumed — only that you can read `zfs list` and edit a file in `vi`.

Polish version: [WDROZENIE-PROXMOX.md](../pl/WDROZENIE-PROXMOX.md).

---

## 1. The model we are deploying

Two Proxmox VE hosts with **no prior trust** between them (they are not in one
cluster and have not exchanged SSH keys).

| Role | Name in the example | Address | What it does |
|---|---|---|---|
| **Collector** | `pve-backup` | `192.168.1.10` | holds the copies, manages everything, **initiates the connection** |
| **Source** | `pve-prod` | `192.168.1.20` | production, hands over data, initiates nothing |

The source has these typical Proxmox datasets:

```
rpool/data/vm-100-disk-0      <- production VM
rpool/data/vm-101-disk-0      <- production VM
rpool/data/vm-999-disk-0      <- test machine, we do NOT want it in the copy
rpool/data/scratch            <- working directory
rpool/data/scratch/tmp-a        (and its children)
```

On the collector the copies are to land under `rpool/backups`.

### Two fundamental principles worth understanding right away

**Direction: the collector PULLS.** It is `pve-backup` that connects to
`pve-prod`, not the other way round. The security consequence is fundamental:
**a break-in on production gives no access to the copies.** The production
server has no key to the collector and does not even know how to get there.
Ransomware that encrypts `pve-prod` has no path to `rpool/backups`.

**Split of decisions: the source decides WHAT, the collector decides HOW.** The
administrator picks the list of datasets *on the source machine* — where it is
known what is what. The schedule and retention are set by the collector. This
way nobody has to guess someone else's disk layout.

---

## 2. Before you start

On **both** hosts:

- Proxmox VE with a ZFS pool (`rpool`),
- root access over SSH (for the duration of the deployment; in the end the jobs
  run from a delegated account),
- network connectivity collector → source (port 22 or your own).

The required packages (`zfs`, `mbuffer`, `zstd`) are **installed by `deploy.sh`
itself** — you do not have to do it manually.

Clone the repository onto both hosts, to the same location:

```bash
git clone https://github.com/AdalbertKing/zfsbackup.git /root/zfs-snapshot-all
```

> **Never copy scripts to the hosts with `scp`/`pscp`.** Updates arrive through
> `git pull --ff-only` every hour. A file replaced manually will dirty the tree
> and **permanently block automatic updates** on that host — silently, with no
> alert.

---

## 3. The deployment procedure

Each step states clearly **on which host** it is performed. The order is
mandatory.

### Step 1 — prepare the collector `pve-backup`

```bash
cd /root/zfs-snapshot-all
./deploy.sh --backup-user=zfsbackup
```

What happens: dependencies are installed, the delegated account `zfsbackup` is
created, and a cron entry with automatic updating is added. You pick the
dataset for the copies (e.g. `rpool/backups`) when you create a relation (wizard: the Cel (target) field, CLI: `--target=`).

`--backup-user=zfsbackup` means: **backup jobs will not run as root.** Worth
it — it limits the damage if anything goes wrong.

Check that everything is clean:

```bash
./deploy.sh --check-only
```

### Step 2 — register the client (still `pve-backup`)

```bash
./zfs-backup.sh add-client prod01 --host=192.168.1.20 --mode=backup
```

- `prod01` — the permanent name of this relation. It **will never change**, even
  when the source changes its IP address. Use it in all later commands.
- `--mode=backup` — says: "I do not list the datasets here, the administrator
  of the source will choose them". This is the path you want. (For the `sync`
  variant, see chapter 6.)

The command prints the **path to the pairing package** (a `.tgz` file) and the
exact command to run on the source. Write them down.

The package contains no collector secrets — it contains a public key and the
relation parameters.

### Step 3 — move the package to the source

Copy the `.tgz` file to `pve-prod` any way you like (`scp` from your
workstation, a USB stick, anything). This is the only moment when you move
something manually.

### Step 4 — accept the pairing on the source `pve-prod`

```bash
cd /root/zfs-snapshot-all
./deploy.sh --join=/root/prod01-package.tgz
```

A dedicated account is created for this one relation, with the collector's key
installed and — this is important — **with zero ZFS permissions.**

This is a safe intermediate state, not an unfinished job: the collector can
already connect and run `zfs list` (listing is not restricted by `zfs allow`),
but it cannot read a single byte of data until you deliberately grant that in
step 7.

The command prints the **LABEL** — the label of this pairing, needed in the
following steps on the source. The label is the short host name of the
collector (`hostname -s`), not the address of the source. In this guide the
collector is called `pve-backup`, so the label is `pve-backup`. This is a different thing from the relation name (`prod01`), which goes into cron as `-L`.

### Step 5 — generate the scope file (`pve-prod`)

```bash
./deploy.sh --draft-scope=pve-backup
```

This creates `/etc/zfs-snapshot-all/peers/pve-backup.scope` — generated from
the **real** ZFS inventory of this machine, not guessed. Inside: a proposal of
active sections plus the full list of datasets as a comment, from which you can
add more.

### Step 6 — choose datasets and exclusions (`pve-prod`)

**This is the only step that requires thinking.** You edit the file:

```bash
vi /etc/zfs-snapshot-all/peers/pve-backup.scope
```

The grammar has four fields and no magic:

| Field | Meaning |
|---|---|
| `include_parent` | whether to take the named dataset **itself** |
| `include_children` | whether to take **everything under it** |
| `exclude` | skip **exactly this one** dataset |
| `exclude_tree` | skip this dataset **and everything below it** |

#### Variant A — with recursion and exclusions (typical)

We take all VM disks from under `rpool/data`, but without the test machine and
without the whole working directory:

```ini
[dataset:rpool/data]
    include_parent   = no
    include_children = yes
    exclude          = rpool/data/vm-999-disk-0
    exclude_tree     = rpool/data/scratch
```

Read it like this: *"`rpool/data` itself does not interest me (it is a
container, not data), everything under it does, except this one machine and
except the whole `scratch` branch."*

Result — the copy will cover `vm-100-disk-0` and `vm-101-disk-0`. Left out:
`vm-999-disk-0`, `scratch` and all its children.

#### Variant B — without recursion (manual selection)

When you want to name exactly what is to be copied, and nothing more:

```ini
[dataset:rpool/data/vm-100-disk-0]
    include_parent   = yes
    include_children = no

[dataset:rpool/data/vm-101-disk-0]
    include_parent   = yes
    include_children = no
```

Here `include_parent = yes` means "this specific dataset", and
`include_children = no` means "and nothing under it" (VM disks usually have no
children anyway).

**Which to choose?** Variant A if the rule is "all machines from this pool".
Variant B if you back up selected machines and the rest are deliberately left
out. Note the limitation described in chapter 7 — it may tip the choice.

The file is read as **data, never as code**. A typo, an unknown field or a
duplicated section = a refusal with the line number and a return to editing,
not a half-finished deployment.

### Step 7 — grant the permissions (`pve-prod`)

```bash
./deploy.sh --commit-scope=pve-backup
```

Only **now** does the collector's account get its ZFS permissions — and exactly
for what the file from step 6 selected.

This is deliberately a separate, conscious command: the scope file is edited
often and with mistakes, while granting permissions is meant to be one
considered act. Before it runs you see the **whole plan** (what will be
granted, what revoked), not a discovery along the way.

Running it again after editing the file **also revokes** whatever the new scope
no longer covers — but only within the bounds of this relation. A grant made by
someone else, or manually, is invisible to this command and stays untouched.

### Step 8 — the first copy (back on `pve-backup`)

```bash
./zfs-backup.sh seed prod01
```

A full base transfer. It takes as long as it takes to send the data — for a few
hundred GB over gigabit, count in hours. You can safely run it in `screen`/`tmux`.

### Step 9 — verify the connection (`pve-backup`)

```bash
./zfs-backup.sh verify-endpoint prod01
```

Confirms that the address the connection actually uses works and is the one you
think it is. **Cron will not be installed until this step passes** — this is a
deliberate gate, not a formality.

### Step 10 — start (`pve-backup`)

```bash
./zfs-backup.sh activate-client prod01
```

Only now are the cron entries created. From this moment the backup runs by itself.

### Step 11 — check

```bash
./zfs-backup.sh status
./zfs-backup.sh test prod01
zfs list -r rpool/backups
```

State `active` = ready.

---

## 4. Where the data will land (the `backup` variant)

The target path consists of: **target + source address + full source path**:

```
rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0
rpool/backups/192.168.1.20/rpool/data/vm-101-disk-0
```

It looks verbose, but it is unambiguous: the address tells you at once which
machine a copy comes from, and the original path is preserved in full. Thanks
to this, one collector can accept `rpool/data/vm-100-disk-0` from ten different
hosts with no name collisions.

---

## 4a. How to read a generated cron line

Nobody writes these lines manually — `gen-cron.sh` generates them from the
configuration file. But you usually open them once every half year, during an
outage, so here is a breakdown of one example (shortened; the minute in the
first field is **only an example** here — every relation gets its own, see
chapter 5):

```text
17 * * * * … snapget.sh -m "automated_hourly_" -i -K /root/.ssh/pairing/192.168.1.20_ed25519     -A -L prod01 "zfsbackup-pve-backup@192.168.1.20:rpool/data/vm-100-disk-0"     "rpool/backups/192.168.1.20" …
```

| fragment | what it means | where it comes from |
|---|---|---|
| `17 * * * *` | every hour, at the minute chosen for this relation (here :17) | `send_schedule` — the cadence from the profile, minute chosen on the collector |
| `-m "automated_hourly_"` | name the snapshots it creates with this prefix; retention and monitoring recognise them by it | `prefix` |
| `-i` | when catching up on a backlog, **jump straight to the newest state** instead of going through all the snapshots on the way. Faster and less data, but the copy will have no intermediate states | your `flags` |
| `-K …/192.168.1.20_ed25519` | log in to the source **with this specific key** (the one from the pairing). Does what `ssh -i` does, but the letter `i` was already taken — see above | your `flags` |
| `-A` | **measure the link and decide by itself** whether compression pays off. The result is remembered for a week: link speed per host, data compressibility per dataset | added by the generator, by default |
| `-L prod01` | this transfer belongs to **relation `prod01`**. Thanks to this, `pause-client` and `disable-client` can stop it before it does anything (see [PAUSE-AND-DISABLE.md](PAUSE-AND-DISABLE.md)) | `pair_label` |
| `"zfsbackup-…@192.168.1.20:rpool/data/vm-100-disk-0"` | **where we take it from**: the account on the source, its address and the dataset. A literal path — exactly what `zfs list` shows there | `src` |
| `"rpool/backups/192.168.1.20"` | **the base directory, not the destination** | the target from `--target` + the source address |

The last row is the most common misunderstanding. The data will **not** land in
`rpool/backups/192.168.1.20`, but a few levels deeper — the script appends the
whole original path from the source underneath:

```text
rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0
```

which is exactly what chapter 4 describes. If you typed the full target path
here manually, the copy would land one level too deep, and every run would do a
full transfer from scratch.

The monitor line for the same dataset looks like this:

```text
*/15 * * * * … check-snap-age.sh -L prod01 "rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0"     "automated_hourly" 90m 150m …
```

— that is, it checks the **target**, not the source, and knows the same
relation label, so during a pause it answers "this is normal, this relation is
standing still" instead of waking you every 15 minutes.

---

## 5. What happens after the deployment

Retention and schedule are chosen by a **profile** (in the GUI when creating a
relation: `default`, `full`, `d7h24`, `d30h24`, `m12w4d7h24-gfs`; files in
`profiles/`, description in `profiles/README.md`). A relation that nobody has
assigned another profile gets `default`, with the values from
`profiles/default.conf`:

| Tier | Snapshot prefix | Kept | Alert: warning / critical |
|---|---|---|---|
| hourly | `automated_hourly_` | **24** | 90 min / 150 min |
| daily | `automated_daily_` | **7** | 30 h / 48 h |
| weekly (Sunday) | `automated_weekly_` | **4** | 8 days / 10 days |
| monthly | `automated_monthly_` | **3** | 35 days / 40 days |

This is **flat** retention, not GFS: each tier is a **separate family of
snapshots**, made by its own job (its own `send_schedule`) and pruned by its
own job (its own `prune_schedule`), and the counter simply keeps the N newest
items of that family, regardless of their age. Thanks to this, a long gap in
new copies arriving (e.g. a source switched off for a month) pushes nothing out
of the copy. A longer history is given by other profiles (e.g. `full` keeps 12
monthly ones).

**Minutes.** Values such as "hourly at :01, prune at :21" are only the
template's starting values. The collector picks **its own free minute for each
relation** (computed from its name, skipping minutes already taken on that
host): the push runs in that minute, the prune of the copy on the target
**20 minutes later**, the prune of the snapshots on the source (over SSH)
**40 minutes later**. A profile with several tiers keeps the gaps between them —
each tier is shifted by the relation's minute. Thanks to this, relations do not
start in the same minute on the same link and disks. You will see the actual
times in the generated cron lines.

Alerts go by mail. By default there is one summary report per day per host;
during the deployment it is worth switching to immediate ones:

```bash
./deploy.sh --alerts=immediate
```

### Mail on plain Debian (non-Proxmox)

On Proxmox this works by itself, because the PVE installer configures postfix.
**On plain Debian there is usually no MTA at all** — and then the backup runs
correctly, and every failure is silent.

`deploy.sh` installs the `mailutils` package, but that gives only the `mail`
*command*. Delivery needs an MTA, which is a separate package. That is why the
script **issues a separate verdict** on alerting — in every mode, including
`--check-only`:

```
alert delivery: postfix present, no queued mail -- prerequisites OK; actual delivery UNVERIFIED in this run (--test-mail probes it)
ALERTING IS NOT WIRED UP: 'mail' exists but no MTA provides sendmail(8)
mail transport present (postfix) but 3 message(s) are STUCK IN THE QUEUE
```

If you see either of the last two — alerts from this host do not work. The
minimal fix:

```bash
apt-get install postfix
```

At the installer prompt choose **"Local only"** if alerts are to go to the
local root (this package's default address), or **"Internet Site"** /
**"Satellite system"** if they are to go to an external address.

> **`deploy.sh` deliberately does NOT configure postfix.** It is a host-wide
> change: when the host already has working mail (exim4, a configured relay,
> msmtp), overwriting `main.cf` would break someone else's configuration. The
> choice of smarthost and SMTP credentials is also a per-installation decision,
> and the password would have to live somewhere. The same principle keeps
> `--commit-scope` away from other people's ZFS grants.

**Checking after the fact** — the simplest proof that mail really leaves:

```bash
./deploy.sh --check-only
mailq
```

An empty queue after sending means the MTA accepted the message and sent it
on. Messages lingering in `mailq` mean alerts are being produced and not
arriving — a state to fix, not a cosmetic issue.

---

## 6. The `sync` variant — a mirror instead of an archive

Instead of `--mode=backup` in step 2:

```bash
./zfs-backup.sh add-client prod01 --host=192.168.1.20 --mode=sync
```

There is one difference, but a fundamental one: **paths are reproduced one to
one.**

The same goes for **snapshots**: a `sync` relation is a mirror. Every pull
carries `snapget.sh -M`, so whatever the source removes from its retention
disappears here on the next run, and the target has no retention of its own. A
history longer than the source's retention is the job of a `backup` relation,
not `sync`.

A `backup` relation, in turn, prunes **foreign** snapshots on its target the
same way as its own. Every pull carries `-I`, so everything the source keeps
between two of our snapshots — a manual one, a family of another tool — lands
on the copy and would otherwise stay there for good. That is why the target's
`[dataset:]` (and its `[prune:]` ladder) has `prune_foreign = yes`; gen-cron
then renders the prune of the finest tier without a name pattern and with
`-P "<family>:all"` for every other family pruned at that place. A foreign
snapshot is thus counted together with the hourly ones and disappears when an
hourly one would. Replica families keep the two newest.

```
source:  rpool/data/vm-100-disk-0
target:  rpool/data/vm-100-disk-0     <- identical path, the other host
```

There is no label prefix and no `--target` (giving it will be rejected) —
there is nothing to name, since the layout is to be identical.

**When to use it:** when you are building a standby machine ready to take over
the role, not an archive. After a failure of `pve-prod` the machines stand on
`pve-backup` under the same paths that the Proxmox configuration looks for.

**When NOT to:** `sync` **refuses to pair with a host from the same PVE
cluster** — and rightly so. In one cluster the same path is physically the same
dataset, so "source" and "target" would be one object, and the synchronisation
would overwrite the data with itself. The gate stands at client registration,
before anything is paired.

Exclusions and recursion work exactly the same — the scope file is the same.
Only the path mapping changes.

---

## 7. Limitations you must know about

We name them plainly, because each of them will surprise you later if not now.

### 7.1. A new dataset will NOT be covered automatically

This is the most important point of this guide.

`include_children = yes` expands into a **concrete list of datasets at the
moment `--commit-scope` is run**, and that list stays frozen. If you create
`rpool/data/vm-102-disk-0` tomorrow, **it will not get into the copy** — it has
no permissions and is not on the list.

This is not a bug, but a consequence of the model: permissions are granted
consciously, per dataset. But it means that **every new machine needs two
commands on the source**:

```bash
./deploy.sh --draft-scope=pve-backup   # only when the scope file does not exist
./deploy.sh --commit-scope=pve-backup  # after checking/completing the file
```

and then on the collector:

```bash
./zfs-backup.sh activate-client prod01   # regenerates the jobs
```

> **Put this in your VM creation procedure.** A machine whose backup everybody
> is sure of, and which nobody ever copied, is the most expensive possible way
> to discover this limitation.

Automatic coverage of new datasets is planned, but it requires a change to the
permission model — it does not exist today.

### 7.2. Copies are crash-consistent, not application-consistent

In pull mode there is **no guest filesystem quiesce by default** — the virtual
machine lives on a remote host, and the collector's account has no right to
freeze it. Quiesce is an option to enable deliberately: on the source,
`deploy.sh --join=… --allow-quiesce` gives the account of the paired relation
the right to quiesce guests whose disks lie under the granted datasets (the
decision belongs to the source — the pairing package does not ask for it).
Without it a snapshot corresponds to a state as if the plug had been pulled:
filesystems recover from the journal, but a database in the middle of a
transaction may need its own recovery.

For most uses this is enough. For databases with a hard requirement of
application consistency you need an application-side backup (a dump)
**alongside** this mechanism.

### 7.3. Changing the source's address

When `pve-prod` changes its IP, you **do not pair again.** The name `prod01` is
independent of the address:

```bash
./zfs-backup.sh set-endpoint prod01 --host=192.168.5.20
./zfs-backup.sh verify-endpoint prod01
./zfs-backup.sh activate-client prod01
```

If a VPN keeps the same `host:port` — you do not even do that, `verify-endpoint`
is enough.

---

## 8. Connecting a second source

The same collector serves many sources. You repeat steps 2–10 with a new name:

```bash
./zfs-backup.sh add-client prod02 --host=192.168.1.21 --mode=backup
```

Every relation gets **its own account on the source, its own key and its own
scope of permissions**. Relations know nothing about each other and cannot touch
each other — compromising one source does not open the way to the others.

### Changing a relation that already works

To change retention or schedule, do not delete and recreate the relation:

```bash
./zfs-backup.sh edit-relation prod01 --profile=full --plan
./zfs-backup.sh edit-relation prod01 --profile=full --yes
```

The relation's sections are generated anew from the profile, as when creating
it, and installed the same way: with a preview and with the same gates. No data
is sent again. Without `--profile` the profile stored with the relation is
used, which gives an older relation today's spread of minutes. The snapshot
family must stay the same: a profile with no common family is a new relation
(`delete-relation`, then create anew), not an edit. Only an installed (active)
relation can be edited. In the GUI: in F3 Relacje (relations), Enter on the relation, then `e`.

---

## 9. Teardown

On the collector:

```bash
./zfs-backup.sh remove-client prod01
```

Removes the jobs from cron, the client entry and the configuration sections. It
**does not delete the data** in `rpool/backups` — if it is to go, you do that
separately and deliberately.

On the source (cleans up the account, key and ZFS permissions of this relation):

```bash
./deploy.sh --leave=pve-backup
```

---

## 10. Cheat sheet — the whole procedure

```bash
# --- COLLECTOR pve-backup ---
./deploy.sh --backup-user=zfsbackup
./zfs-backup.sh add-client prod01 --host=192.168.1.20 --mode=backup
#   -> move the printed .tgz package to pve-prod

# --- SOURCE pve-prod ---
./deploy.sh --join=/root/prod01-package.tgz
./deploy.sh --draft-scope=pve-backup
vi /etc/zfs-snapshot-all/peers/pve-backup.scope      # selection + exclusions
./deploy.sh --commit-scope=pve-backup

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
| `seed` ends with a permission error | was `--commit-scope` really run? `zfs allow rpool/data` on the source |
| `verify-endpoint` refuses | address/port; the message distinguishes "cannot connect" from a data problem |
| no cron entries | the client did not reach `endpoint_verified` — check `status` |
| a new VM is not being copied | that is point 7.1, not a failure |
| updates stopped arriving | `git -C /root/zfs-snapshot-all status` — a dirty tree blocks `--ff-only` |
| backup works, but there are no alerts | `./deploy.sh --check-only` gives a verdict on mail; then `mailq`. On non-Proxmox there is usually no MTA (chapter 5) |
| `mailq` shows `alias database unavailable` | `/etc/aliases.db` is missing — `newaliases` rebuilds it |

The state of the whole is always shown by:

```bash
./zfs-backup.sh status
./deploy.sh --check-only
```
