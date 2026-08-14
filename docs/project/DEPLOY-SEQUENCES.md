# Deployment command sequences

Owner asked for the complete set, 2026-08-09. Taken from the tools' own help and
code, not from memory. **Marked throughout: what runs today, what is proposed.**

## A) Two hosts — normal path

Collector `pve1`, target `hdd/backups`; source `pve2`, `rpool/data`.

```bash
# --- on pve1 (collector) ---
./zfs-backup.sh add-client pve2 --host=192.168.28.8:22 --target=hdd/backups

# --- on pve2 (source), from its console ---
./deploy.sh --join=/path/to/package.tgz     # account/key + guided scope + grant

# --- back on pve1 ---
./zfs-backup.sh seed pve2
./zfs-backup.sh activate pve2               # verify + preview + cron install
```

State: `pending_enroll -> seeding -> seed_complete -> endpoint_verified ->
active`. **Cron exists only from `endpoint_verified`** — the same invariant
REV-20260808-075 made me carry into the single-host path.

Seeding over LAN and running over VPN changes only the final command:

```bash
./zfs-backup.sh activate pve2 --host=<vpn-host:port>
```

It owns the final catch-up, endpoint switch, verification and activation.
`--draft-scope`, `--commit-scope`, `final-catchup`, `set-endpoint`,
`verify-endpoint` and `activate-client` remain expert/resume primitives; they
are not required on the normal path.

## B) One host — TODAY

**There is no sequence.** This is the gap the owner's directive names. Today:

```bash
./deploy.sh                                              # bootstrap
zfs create -p hdd/backups
vi /etc/zfs-snapshot-all/jobs.pve1.conf                  # CONFIG v4 BY HAND
./gen-cron.sh -c /etc/zfs-snapshot-all/jobs.pve1.conf            # render/validate only
./snapsend.sh -m automated_ rpool/data hdd/backups               # seed, FOREGROUND
./gen-cron.sh -c /etc/zfs-snapshot-all/jobs.pve1.conf --install  # ONLY after the seed succeeded
./gen-cron.sh -c /etc/zfs-snapshot-all/jobs.pve1.conf --reconcile # read back
```

**CORRECTED after the reviewer's comparison (2026-08-09).** The first version of
this row put `--install` *before* the manual seed — the exact ordering REV-075
had just made me fix in the single-host contract. Labelling a sequence TODAY does
not make it safe to publish in the wrong order: a runbook teaches whatever order
it prints, and this one would have taught scheduled jobs firing on a
relationship whose first seed had never run.

This is an expert escape path, not product UX. Keeping it fail-closed in the
same direction as the future orchestrator is the least it must do.

Six steps, including writing a config from memory and a hand-run seed with no
gate between it and the installed cron.

## A) Two hosts — profiles

The default profile is implicit in the normal four-command path above. A named
profile is still one optional argument on `add-client`; it does not create a
second procedure.

## B) One host — AFTER PROFILES (proposed)

```bash
./zfs-backup.sh --target=hdd/backups
./zfs-backup.sh --source=rpool/data --profile=default
```

`--profile` optional (default is `default`), `--source` optional (absent =
propose from the whole host), `--target` remembered after the first call.

## The number worth looking at

Two-host setup is four public commands, with the source-side choice contained
inside the guided `--join`. The expert verbs remain available without being
part of the ordinary procedure.

## Execution account is independent from the profile — owner-requested UX note

Added 2026-08-09 after the owner asked whether the high-level workflow forces a
dedicated `zfsbackup` account. It must not.

The execution account and the backup profile are two independent choices:

```
PROFILE = HOW the backup runs (cadence, retention/GFS, recursion, monitoring)
ACCOUNT = WHICH local Unix account owns/runs the production jobs
```

The built-in `default` profile must therefore never imply or require the
`zfsbackup` account.

### Root remains the default

This is already how the shipped collector behaves: if `LOCAL_USER` is empty,
`zfs-backup.sh` targets `root`'s crontab. `setup-server --local-user=root` is
explicitly equivalent to omitting `--local-user`. The delegated account is an
opt-in.

For the future one-host high-level orchestration, the shortest root-owned form
should therefore remain the ordinary path:

```bash
./zfs-backup.sh --source=rpool/data --target=hdd/backups
```

Conceptually:

```
operator/orchestrator = root
cron owner             = root
production jobs         = root
source                  = rpool/data
target                  = hdd/backups
profile                 = default (implicit)
```

### Dedicated `zfsbackup` account — same workflow, one explicit parameter

The delegated variant should not become a second deployment procedure. The
normal operator still runs the high-level orchestrator as `root`, because host
bootstrap, account creation and ZFS delegation require privilege. The explicit
account choice only changes who owns and executes the production jobs.

Proposed finished one-host command:

```bash
./zfs-backup.sh --source=rpool/data --target=hdd/backups --local-user=zfsbackup
```

`--profile=default` remains optional because `default` is the default profile.

The high-level command should internally perform, in order:

```
root starts zfs-backup.sh
  -> bootstrap host if needed
  -> deploy.sh --backup-user=zfsbackup
  -> create/maintain account zfsbackup
  -> ensure /home/zfsbackup/zfs-snapshot-all checkout
  -> grant only the ZFS permissions required by the selected local relation
  -> load + validate profile default
  -> compose effective CONFIG v4
  -> ensure CONFIG is readable by zfsbackup
  -> show CONFIG + cron proposal
  -> explicit confirmation
  -> persist configured
  -> run the first foreground seed as the selected job owner
  -> persist seeded only after seed success
  -> install zfsbackup's crontab through the shared cron writer
  -> read back / verify
  -> persist active
```

After activation, a direct ownership check is:

```bash
crontab -u zfsbackup -l
```

The intended role split is therefore:

```
root
  = orchestration, bootstrap, account creation, permission/delegation changes

zfsbackup
  = production backup jobs, retention, monitoring and its own managed crontab
```

This is consistent with the shipped implementation: `deploy.sh --backup-user=X`
creates the delegated account only when explicitly requested; `zfs-backup.sh`
uses `${LOCAL_USER:-root}` as the cron target; and a delegated account gets its
own checkout because `/root/scripts/...` is not readable through `/root` on a
normal Proxmox host.

### Migration remains an expert/transition path

An existing root-owned installation does not need to be rebuilt just to adopt a
dedicated account. The existing `migrate-to-account ACCOUNT` verb remains the
explicit migration path. That is separate from the clean-install happy path
above.

### UX invariant to preserve while local orchestration is implemented

Changing the execution account must change **one parameter, not the workflow**:

```bash
# root-owned jobs (default)
./zfs-backup.sh --source=rpool/data --target=hdd/backups

# delegated jobs
./zfs-backup.sh --source=rpool/data --target=hdd/backups --local-user=zfsbackup
```

If implementing this requires the operator to learn a second sequence of
`deploy.sh`, `gen-cron.sh`, manual grants, manual CONFIG edits or direct crontab
commands, the high-level abstraction has leaked and the design should be
revisited.
