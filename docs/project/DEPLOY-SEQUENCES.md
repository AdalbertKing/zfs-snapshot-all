# Deployment command sequences — today vs after profiles

Owner asked for the complete set, 2026-08-09. Taken from the tools' own help and
code, not from memory. **Marked throughout: what runs today, what is proposed.**

## A) Two hosts — TODAY (shipped)

Collector `pve1`, target `hdd/backups`; source `pve2`, `rpool/data`.

```bash
# --- on pve1 (collector) ---
./zfs-backup.sh setup-server --target=hdd/backups
./zfs-backup.sh add-client pve2 --lan=192.168.28.8:22 --mode=backup

# --- on pve2 (source), from its console ---
./deploy.sh --join=/path/to/package.tgz     # account + key, ZERO zfs permissions
./deploy.sh --draft-scope=pve1              # proposal from real ZFS
#   ... edit the scope file ...
./deploy.sh --commit-scope=pve1             # only now are zfs grants issued

# --- back on pve1 ---
./zfs-backup.sh seed pve2
./zfs-backup.sh verify-endpoint pve2
./zfs-backup.sh activate-client pve2        # cron is installed only here
```

State: `pending_enroll -> seeding -> seed_complete -> endpoint_verified ->
active`. **Cron exists only from `endpoint_verified`** — the same invariant
REV-20260808-075 made me carry into the single-host path.

Seeding over LAN and running over VPN adds `set-endpoint pve2 --host=<vpn>` and
`final-catchup` between the seed and activation.

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

## A) Two hosts — AFTER PROFILES (proposed)

```bash
./zfs-backup.sh add-client pve2 --lan=192.168.28.8:22 --mode=backup --profile=default
```

One flag. **Everything else is unchanged** — the profile replaces the hardcoded
schedule/retention policy, not the enrolment flow.

## B) One host — AFTER PROFILES (proposed)

```bash
./zfs-backup.sh --target=hdd/backups
./zfs-backup.sh --source=rpool/data --profile=default
```

`--profile` optional (default is `default`), `--source` optional (absent =
propose from the whole host), `--target` remembered after the first call.

## The number worth looking at

Two-host changes by **one flag** after profiles, because the orchestration
already exists. Single-host changes from **six manual steps to two**, because
there is no orchestration there at all.

That is the measure of what is left to build: not the profiles — the single-host
layer.
