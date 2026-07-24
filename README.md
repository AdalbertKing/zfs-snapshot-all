# zfs-snapshot-all

A small, dependency-light toolkit for ZFS snapshot lifecycle management: create, replicate
(push or pull, local or over SSH), prune, and monitor — driven by a single INI config per host
instead of hand-written cron lines. Built as a purpose-fit alternative to syncoid/sanoid for a
small Proxmox VE fleet, with a few things tuned specifically for that environment (Proxmox
VM/CT dataset naming, qemu-guest-agent quiescing, non-root delegated operation).

No package to install beyond the scripts themselves and their runtime dependencies (`zfs`,
`mbuffer`, and optionally `zstd`/`pigz`, `ssh`, `mail`). Everything is plain bash.

## Table of contents

- [Components at a glance](#components-at-a-glance)
- [Core concepts](#core-concepts)
  - [GUID-based matching (survives renames)](#guid-based-matching-survives-renames)
  - [Bookmark-backed incremental fallback](#bookmark-backed-incremental-fallback)
  - [Resumable transfers](#resumable-transfers)
  - [Hold-based protection for in-flight snapshots](#hold-based-protection-for-in-flight-snapshots)
  - [`-i`/`--identifier`: independent jobs on the same pair](#-i--identifier-independent-jobs-on-the-same-pair)
  - [Quiescing Proxmox guests (`-q`)](#quiescing-proxmox-guests--q)
  - [Link autotuning (`-A`)](#link-autotuning--a)
  - [Compression](#compression)
  - [JSON-lines stats log](#json-lines-stats-log)
- [snapsend.sh — push replication](#snapsendsh--push-replication)
- [snapget.sh — pull replication](#snapgetsh--pull-replication)
- [delsnaps.sh — retention / pruning](#delsnapssh--retention--pruning)
- [check-snap-age.sh — staleness monitor](#check-snap-agesh--staleness-monitor)
- [gen-cron.sh — config-driven cron generator](#gen-cronsh--config-driven-cron-generator)
- [deploy_new_server.sh / deploy_backup_user.sh](#deploy_new_serversh--deploy_backup_usersh)
- [Worked scenarios](#worked-scenarios)
- [Testing](#testing)
- [Versioning](#versioning)

## Components at a glance

| Script | Role | Version |
|---|---|---|
| [`snapsend.sh`](snapsend.sh) | Create + push-replicate a dataset (source always local, target local or remote) | v2.43 |
| [`snapget.sh`](snapget.sh) | Pull-replicate a dataset (target always local, source local or remote) | v2.38 |
| [`delsnaps.sh`](delsnaps.sh) | Prune snapshots (age- or count-based) and orphaned bookmarks | v1.18 |
| [`check-snap-age.sh`](check-snap-age.sh) | Nagios-style staleness check for the newest matching snapshot | v2.0 |
| [`gen-cron.sh`](gen-cron.sh) | Generates (and optionally installs) a crontab block from one INI config | v4.11 |
| [`lib-zfs-snap.sh`](lib-zfs-snap.sh) | Shared helpers `source`d by snapsend.sh/snapget.sh (not standalone) | — |
| [`deploy_new_server.sh`](deploy_new_server.sh) | Bootstraps a brand-new host: dependencies, checkout, alerting, smoke test | — |
| [`deploy_backup_user.sh`](deploy_backup_user.sh) | Bootstraps a non-root delegated service account to run the above without root | — |

Every executable answers `-V`/`--version`. Full changelog lives in `git log`, not in this file —
this README describes current behavior, not history.

## Core concepts

These are the ideas that make the toolkit behave differently from a naive `zfs send | zfs recv`
wrapper. Skip ahead to [Worked scenarios](#worked-scenarios) for them in action.

### GUID-based matching (survives renames)

`find_common_snapshot()` first tries to match source and target snapshots **by name** (fast
path). If nothing matches — because a snapshot or the dataset itself was renamed on either side
since the last sync — it falls back to matching **by ZFS GUID**, the property that identifies a
snapshot's identity independent of its current name. `zfs receive` keys an incremental off the
stream's embedded `fromguid`, not off the name used to invoke `-i`/`-I`, so a source-side name
found via GUID is a perfectly valid incremental base.

Without this, a renamed snapshot forces a full resend (and, with `-f`, a destructive rollback of
the target). With it, replication survives an admin renaming a snapshot for clarity, or `zfs
rename`-ing the dataset itself.

### Bookmark-backed incremental fallback

A ZFS bookmark (`dataset#mark`) records a snapshot's txg + GUID at essentially zero space cost —
enough to serve as an incremental send base, but it is not a snapshot and can't be received into.
After every successful, non-recursive transfer, `record_send_bookmark()` refreshes **one**
bookmark per target on the **source** dataset, replacing the previous one. If the snapshot that
bookmark was based on later gets pruned from the source (by `delsnaps.sh`, before the target
caught up), the next run's `find_bookmark_base()` still finds a valid incremental base via the
bookmark instead of falling through to a full send.

Bookmark names are `tgt-<8 hex chars>`, an md5 hash of the target dataset path (and the `-i`
identifier, if any — see below). Nothing else on the source touches this, so it accumulates
exactly one bookmark per (target, identifier) pair forever, until a target is retired — see
[`delsnaps.sh -B`](#delsnapssh--retention--pruning) for cleaning those up.

### Resumable transfers

If a prior `zfs receive` was interrupted mid-stream, ZFS leaves a `receive_resume_token` on the
target. Both scripts detect this and resume with `zfs send -t <token>` instead of restarting from
scratch, for up to `MAX_RESUME_ATTEMPTS` (3) tries — tracked per-target under `LOCKDIR`. After
that many failed resumes, `zfs receive -A` abandons the partial state (not the target's existing
history) and the next run falls back to a normal incremental/full send.

### Hold-based protection for in-flight snapshots

The snapshot a `zfs send` is currently reading — or that a stuck resume token still depends on —
is protected with `zfs hold` (tag `zfssnapall_inflight`) for the duration. This is enforced by ZFS
itself: a `delsnaps.sh` run landing in the same cron window cannot prune a snapshot that is
mid-transfer, because a plain `zfs destroy` on a held snapshot fails outright. `delsnaps.sh`
recognizes this specific hold and reports it as "in-flight, skipped" instead of a generic
dependent-object error. The hold is released as soon as the transfer either succeeds or fails
without a resume token to protect.

### `-i`/`--identifier`: independent jobs on the same pair

Both scripts key their single-instance lock (`LOCK_KEY`) and their bookmark tag on `(source,
target)` alone by default — deliberately, so a manual run and a scheduled cron run of the *same*
job always serialize instead of racing. `-i <TAG>` folds an extra tag into both, letting a
**second, genuinely independent job** aimed at the same source/target pair get its own lock and
its own incremental-base bookmark instead of colliding with, or serializing behind, the first.
Omit it (the default) to keep today's behavior unchanged.

```bash
# Two schedules hitting the same target, deliberately kept independent:
./snapsend.sh -e -i hourly  tank/data backup/tank/data
./snapsend.sh -e -i offsite tank/data backup/tank/data
```

### Quiescing Proxmox guests (`-q`)

`snapsend.sh -q <mode>` freezes the Proxmox guest that owns a dataset immediately before
snapshotting it, so the snapshot is filesystem-consistent instead of merely crash-consistent.
Guest ownership is inferred from the Proxmox dataset-naming convention (`vm-<id>-disk-N`,
`subvol-<id>-disk-N`); anything else is snapshotted as normal, with no attempt made to quiesce it.

| mode | mechanism | applies to |
|---|---|---|
| `no` (default) | nothing | — |
| `agent` | `qemu-guest-agent` `fsfreeze` | VMs |
| `sync` | `pct exec <id> -- sync` (a flush, not a freeze — containers have no guest agent and ZFS implements no `FIFREEZE`) | containers |
| `auto` | picks per guest from its type | both |

The freeze window contains **only** `zfs snapshot` — never the transfer, since writes are blocked
guest-side while frozen. A guest owning several disks (e.g. 3) is quiesced exactly once per run,
and all of its disks are snapshotted together inside one atomic window, so a multi-disk VM never
ends up with disks pointing at different moments in time. Thaw is guaranteed by an `EXIT` trap.
Filesystem-consistent is **not** application-consistent — for a true database-consistent
snapshot, put the engine's own quiesce logic (`FLUSH TABLES WITH READ LOCK`, Postgres backup
mode, …) in the guest's own `/etc/qemu/fsfreeze-hook`, which the agent runs inside the freeze.
Ignored together with `-e` (nothing new is being created to quiesce for) and with `-n`.

### Link autotuning (`-A`)

`-A` measures a real `zfs send` sample from the dataset (needs an existing snapshot — stands down
quietly on a dataset's very first run) and the link speed to the target host, then decides
whether compressing the stream is worth it for *this* data over *this* link — nothing else.
Measurements are cached 7 days (link speed per host — one probe per host per run at most; ratio
per dataset, since compressibility is a property of the data, not the link), so the ~10s probe
runs at most about once a week; force a re-probe with `ZFS_SNAP_RETUNE=1`. An explicit `-z`/`-Z`/
`-g` always wins — `-A` only fills in a decision you didn't make, never overrides one you did.
Remote transfers only; a local target has nothing to measure.

### Compression

Two independent mechanisms:

- **Explicit stream compression** (`-z`/`-Z` for zstd, `-g` for pigz, `-l <level>` — see the
  [snapsend.sh reference](#snapsendsh--push-replication) for the full flag table and the
  benchmark behind the zstd default). Ignored (with a log line, never fatal) on a local target,
  since there is no network link to amortize the CPU cost against.
- **Compressed send** (`zfs send -c`), automatic, no flag: ships records exactly as they already
  sit on disk instead of decompressing to build the stream and recompressing on receive. Costs
  zero extra CPU — it *removes* work rather than adding it — so unlike `-z` it also helps a purely
  local transfer. Skipped automatically when the target pool lacks the required features
  (`feature@lz4_compress`, plus `feature@zstd_compress` for zstd-compressed records); force plain
  with `ZFS_SNAP_NO_COMPRESSED_SEND=1`.

### JSON-lines stats log

Every run appends one JSON object per line to `STATS_LOG` (JSON-lines: one record per line, no
top-level array), queryable with `jq` instead of parsed with regex:

```json
{"time":"2026-07-24T10:15:03Z","script":"snapsend.sh","dataset":"tank/data","target":"backup/tank/data","status":"success","duration_s":42,"resumed":false}
{"time":"2026-07-24T10:16:01Z","script":"delsnaps.sh","dataset":"tank/data","pattern":"auto_","status":"success","duration_s":1,"deleted":2,"kept":3}
```

`snapsend.sh`/`snapget.sh` records carry `target`/`resumed` (a real boolean); `delsnaps.sh`
records carry `pattern`/`deleted`/`kept` instead, since it prunes rather than transfers. Both are
best-effort: a logging failure (unwritable path) is swallowed rather than failing the underlying
backup/prune that already succeeded.

```bash
# Every failed job in the last day:
jq -c 'select(.status != "success")' "$STATS_LOG" | jq -R 'fromjson | select(.time > (now - 86400 | todate))'

# Average send duration per dataset:
jq -s 'group_by(.dataset) | map({dataset: .[0].dataset, avg_s: (map(.duration_s) | add / length)})' "$STATS_LOG"
```

## snapsend.sh — push replication

Source is always local; the target may be local or remote (`[user@]host:dataset`). Creates a new
snapshot (or reuses the latest with `-e`), finds the best incremental base (name match → GUID
match → bookmark match → full send), and transfers it.

```
Usage: snapsend.sh [options] DATASETS [REMOTE]
```

| Flag | Meaning |
|---|---|
| `-m <MESSAGE>` | Prefix for the new snapshot's name |
| `-e` | Use the existing latest snapshot instead of creating a new one |
| `-z` / `-Z` | Compress the stream with zstd (default compressor; `-Z` is an explicit synonym for `-z`) |
| `-g` | Compress with pigz instead (escape hatch when zstd is unavailable) |
| `-l <LEVEL>` | Compression level (default 3 for zstd, 6 for pigz — different scales, each tool's own default) |
| `-v <LEVEL>` | Verbosity 0 (errors only) – 4 (debug) |
| `-r` | Recursive: include child datasets (native `zfs send -R`) |
| `-n` | Dry-run: report conflicts, send nothing |
| `-I` | Full-history send if no common base exists (instead of a plain full send) |
| `-u` | Unmount the target after receive |
| `-f` | Force full send: destroy target data, reseed from scratch |
| `-w` | Raw send (`zfs send -w`) — ships an encrypted source as ciphertext with no key needed on either end; effectively a no-op on unencrypted data |
| `-p <PORT>` | SSH port (default 22) |
| `-k <FILE>` | Verify the remote host key against this known_hosts file (default: trust on first use) |
| `-A` | Autotune the link — see [Link autotuning](#link-autotuning--a) |
| `-q <MODE>` | Quiesce the owning Proxmox guest first — see [Quiescing](#quiescing-proxmox-guests--q) |
| `-i <TAG>` | Job identifier — see [`-i`/`--identifier`](#-i--identifier-independent-jobs-on-the-same-pair) |
| `-V` | Print version and exit |

```bash
snapsend.sh -v1 pool/data backuppool/data_backup
snapsend.sh -r pool/data user@backuphost:tank/backups/data
```

## snapget.sh — pull replication

The mirror image of `snapsend.sh`: the target is always local, the source may be local or remote.
Same option surface, minus `-q` (quiescing only makes sense on the side that creates the
snapshot, which for a pull is a remote host this side doesn't control) — everything else
(`-m -e -z -Z -g -l -v -r -n -I -u -f -w -p -k -A -i -V`) behaves identically, with source/target
swapped.

```bash
snapget.sh -v1 pool/data backuppool/data_backup
snapget.sh -r pool/data user@sourcehost:tank/backups/data
```

## delsnaps.sh — retention / pruning

Two mutually exclusive modes, selected by flag case:

- **Age-based** (lowercase `-y -m -w -d -h`): delete anything older than the summed threshold.
- **Count-based** (uppercase `-Y -M -W -D -H`): keep only the N most recent matching snapshots,
  summed across slots.

```
Options:
-R                 Recurse into every descendant dataset (each keeps its OWN retention)
-n                 Dry-run — print what would be deleted/kept, destroy nothing
-v, --verbose      Verbose tracing (also DEBUG=1)
-F                 Clear-cut: zfs destroy -R instead of a plain destroy — cascades to
                   same-named descendant snapshots AND dependent clones. Opt-in; dangerous.
-B                 Bookmark mode: prune orphaned snapsend/snapget bookmarks instead of
                   snapshots (age-based only)
-p <PORT>          SSH port for remote datasets
-k <FILE>          Known-hosts file for remote datasets
-V, --version      Print version and exit
```

A plain destroy refuses to remove a snapshot with dependent clones (e.g. a live Proxmox
linked-clone disk) — it is reported and skipped, not silently destroyed. `-F` opts into the old
cascading behavior when genuinely wanted. Datasets may be remote (`[user@]host:path`; remote only
when there's a `:` with no `/` before it), and local/remote entries can be mixed in one
comma-separated list.

```bash
# Age-based, recursive, two datasets:
./delsnaps.sh -R "tank/data1,tank/data2" "backup-" -y1 -m6

# Count-based, single dataset, keep the 12 most recent monthlies:
./delsnaps.sh "tank/data4" "monthly-" -M12

# Preview only:
./delsnaps.sh -n "tank/data4" "monthly-" -M12

# Remote, custom SSH port:
./delsnaps.sh -p2222 "backup@pve2:tank/data" "monthly-" -M12
```

**Bookmark pruning (`-B`)** cleans up the one-bookmark-per-target insurance policy
`snapsend.sh`/`snapget.sh` leave behind (see [Bookmark-backed incremental
fallback](#bookmark-backed-incremental-fallback)): when a target is retired, its bookmark is
never touched again and would otherwise live forever. `-B` prunes any bookmark that has not been
refreshed within the given age — pick a threshold safely longer than your longest real backup
cycle, or a paused/offline job's still-valid bookmark gets pruned too early.

```bash
# Prune snapsend/snapget bookmarks untouched for 30+ days, across a whole subtree:
./delsnaps.sh -B -R "tank/data" "tgt-" -d30
```

## check-snap-age.sh — staleness monitor

Read-only Nagios-style check: for each dataset, finds the newest snapshot whose name (after `@`)
starts with the given pattern, and compares its age to warn/crit thresholds.

```
Usage: check-snap-age.sh [-R] [-v] <comma-separated datasets> <pattern> <warn> <crit>
```

- `-R` — also check every descendant dataset, independently, against the same pattern/thresholds.
- `-v` / `--verbose` — print a status line for every dataset, not just the ones that trip.
- Thresholds are `<N><unit>` with unit `m`/`h`/`d` (e.g. `90m`, `3h`, `9d`); crit must be ≥ warn.
- **Exit codes** (the worst across all datasets checked): `0` OK, `1` WARNING, `2` CRITICAL,
  `3` UNKNOWN. A dataset with no matching snapshot at all is CRITICAL. UNKNOWN means the check
  itself couldn't answer (bad args, missing `zfs`, nonexistent dataset) — deliberately distinct
  from "the answer is bad", so a broken monitor doesn't silently read as "everything's fine".

```bash
./check-snap-age.sh "rpool/data/vm-106-disk-0" "automated_hourly" 90m 3h
./check-snap-age.sh -R "hdd/backups/pve1" "automated_daily" 30h 48h
```

## gen-cron.sh — config-driven cron generator

Reads one INI-style config file (`jobs.<hostname -s>.conf` by default) and emits the crontab block
that drives `snapsend.sh`/`delsnaps.sh`/`check-snap-age.sh` for that host — no hand-written cron
lines. Idempotent `--install`: replaces its own previously-generated block rather than appending.

```
Usage: gen-cron.sh [-c CONFIG] [--install] [-V]
```

Section types (a header is always `[type:name]`, split on the first `:`, except `[defaults]`):

| Section | Purpose |
|---|---|
| `[defaults]` | `host_label` (used in notify text) and an optional default `dst` |
| `[template:<tier>]` | One tier's full cadence + retention policy: `send_schedule`, `prefix`, `prune_schedule`, `pattern`, `keep`/`retain`, `monitor_warn`/`monitor_crit`, … |
| `[dataset:<path>]` | A dataset you own end-to-end: `use_template = <tier>[,<tier>...]`, plus per-dataset overrides (`flags`, `quiesce`, `autotune`, `dst`, …). Runs create(+send) and inline self-prune, scoped to its own path only. |
| `[prune:<scope>]` | Standalone additive prune for scopes you do **not** create locally (a backup store receiving pushes from elsewhere). `recursive=`/`clear_cut=` opt in to `-R`/`-F`. |
| `[prune-bookmarks:<scope>]` | Age-based cleanup of orphaned bookmarks — `schedule`, `age` (raw `delsnaps.sh` age flags), `pattern` (default `tgt-`), `recursive` |

There is no separate `[monitor:]` section — a staleness check is derived **automatically**
wherever a tier's `pattern` already resolves for pruning, as long as that template also sets
`monitor_warn`/`monitor_crit`. It reuses the same scope and recursion the prune operation needed;
no new syntax.

A few things the generator enforces or automates for you:

- `flags="-f"` / `flags="-n"` are **rejected** at generate time — neither makes sense as a
  standing recurring job (destroy-and-reseed every run / never actually send anything).
- `-A` is added automatically to every send whose resolved `dst` is remote (contains `:`) —
  unless `flags` already sets `-A` or names a compressor explicitly, or `autotune=no`.
- `-z`/`-Z`/`-g` on a resolved **local** `dst` produces a stderr warning (never fatal): local
  sends already drop compression on their own, so the flag is dead weight.
- Every resolved prune operation is cross-checked against every other one on the *same* literal
  scope: since `delsnaps.sh` matches by literal string prefix, one tier's pattern being a prefix
  of another's would let its snapshots leak into the wrong retention run — rejected at generate
  time.

```ini
[defaults]
host_label = pve2
dst        = hdd/backups/pve2

[template:hourly]
send_schedule    = 0 * * * *
prefix           = hourly_
pattern          = hourly_
keep             = 24
monitor_warn     = 90m
monitor_crit     = 3h

[template:daily]
send_schedule    = 30 2 * * *
prefix           = daily_
pattern          = daily_
keep             = 14
monitor_warn     = 26h
monitor_crit     = 48h

[dataset:rpool/data/vm-106-disk-0]
use_template = hourly,daily
notify       = vm106
quiesce      = agent
```

```bash
gen-cron.sh -c jobs.pve2.conf              # print the generated block for review
gen-cron.sh -c jobs.pve2.conf --install    # install it into this user's crontab
```

## deploy_new_server.sh / deploy_backup_user.sh

- **`deploy_new_server.sh`** bootstraps a fresh Proxmox/Debian host as **root**: checks/installs
  every runtime dependency (table derived from what the scripts actually invoke), clones or
  updates the repo checkout at `/root/scripts/zfs-snapshot-all`, generates `notify-fail.sh`
  (mail-on-failure) and `check-pool-capacity.sh` (mail before a pool fills up, ahead of any job
  actually breaking), smoke-tests all shipped executables plus a live compressor round-trip, and
  installs an auto-pull cron line. Idempotent — safe to re-run. It deliberately does **not**
  touch your actual `snapsend`/`snapget`/`delsnaps` job lines (those are dataset-specific per
  host); that stays a documented manual step (or use `gen-cron.sh`).

  ```bash
  bash deploy_new_server.sh                # full bootstrap
  bash deploy_new_server.sh --check-only    # audit only — installs/modifies nothing, no test mail
  ```

- **`deploy_backup_user.sh`** bootstraps a dedicated, delegated **non-root** account (default
  name `zfsbackup`) so replication doesn't need to run as root: creates the locked-password,
  SSH-key-only account, its own lock/state dir, its own checkout and auto-pull cron line, and
  `zfs allow` delegation on the dataset(s) given (default `rpool/data`, `rpool/ROOT/pve-1`).
  Delegation on a dataset (without `-d`) also covers descendants that don't exist yet — new
  VM/CT disks created later under `rpool/data` inherit it automatically.

  On Linux, a delegated `mount` permission still can't actually mount/unmount without
  `CAP_SYS_ADMIN`. Routine incremental replication is unaffected (new targets are created with
  `canmount=noauto`, so there's no mount cycle to trip on), but this account still cannot
  bootstrap a brand-new multi-level target path from scratch, run `-f`, or run `-F` against a
  currently-mounted target/clone — those remain root's job, and `-f`/`-F` now print a hint
  pointing here when they fail for that specific reason.

  ```bash
  bash deploy_backup_user.sh                              # default user + default datasets
  bash deploy_backup_user.sh zfsbackup rpool/data tank/vm  # custom user + datasets
  ```

## Worked scenarios

### 1. From zero to a running hourly/daily backup schedule

```bash
# On the new host, as root:
bash deploy_new_server.sh

# Write /root/scripts/zfs-snapshot-all/jobs.$(hostname -s).conf (see the gen-cron.sh
# example above), then:
cd /root/scripts/zfs-snapshot-all
./gen-cron.sh -c "jobs.$(hostname -s).conf"           # review the generated block
./gen-cron.sh -c "jobs.$(hostname -s).conf" --install # install it
crontab -l                                            # confirm the managed block landed
```

`gen-cron.sh` has already added `-A` to any remote send lines and rejected any `-f`/`-n` typo'd
into `flags`. The staleness checks for every tier that set `monitor_warn`/`monitor_crit` ride the
same crontab block — nothing further to wire up.

### 2. Remote push with compression, autotune, and guest quiescing

A VM disk, replicated hourly to an off-site host, guest-quiesced for a clean point-in-time image:

```bash
./snapsend.sh -q agent -A rpool/data/vm-107-disk-0 backup@offsite.example:tank/backups/pve1
```

`-A` measures the real link to `offsite.example` and this dataset's actual compressibility before
deciding whether to add compression — no need to guess a ratio by hand. `-q agent` freezes VM 107
via its qemu-guest-agent for exactly the `zfs snapshot` call, then thaws it before the transfer
starts, so the multi-second freeze never overlaps the (potentially much longer) send.

### 3. Pull replication as a non-root delegated user

On the backup target host:

```bash
bash deploy_backup_user.sh zfsbackup rpool/data
```

`deploy_backup_user.sh` deliberately does **not** exchange SSH keys with the source host — that's
host-specific and stays a manual step: copy `~zfsbackup/.ssh/id_*.pub` to the source host's
`authorized_keys` for whichever account (`root@source-host` below) will serve the send. Once
that's in place:

```bash
su - zfsbackup
./snapget.sh -v1 rpool/data/vm-106-disk-0 root@source-host:rpool/data
```

The `zfsbackup` account has `zfs allow` delegation on `rpool/data` (and everything created under
it later), so it can receive incrementals there without root — but a brand-new multi-level target
path, `-f`, or `-F` against a mounted clone still needs root, per the delegation limits above.

### 4. Surviving a rename (GUID matching)

```bash
./snapsend.sh -e tank/data backup/tank/data     # first sync: lands @a

zfs rename backup/tank/data@a backup/tank/data@archived   # admin tidies up the target
zfs snapshot tank/data@b

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

The name-based fast path finds no match (the target has no snapshot literally named `@a`
anymore), but the GUID fallback recognizes `@archived` as the same snapshot by ZFS identity, so
this stays a genuine incremental (`@archived` survives, `@b` is appended) — not a `-f`-style
rollback that would have wiped `@archived` off the target.

### 5. Recovering from a source snapshot pruned too early

```bash
./snapsend.sh -e tank/data backup/tank/data     # sync #1, bookmark refreshed for this target

zfs destroy tank/data@a                         # delsnaps.sh (or a human) prunes the source snapshot
zfs snapshot tank/data@c

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

With `@a` gone from the source, the name/GUID fast paths find nothing in common — but
`find_bookmark_base()` locates the refreshed `tank/data#tgt-<hash>` bookmark, whose GUID matches
the target's current head, and sends `-i <bookmark> @c` instead of falling back to a full resend.

### 6. Two independent schedules landing in the same target

```bash
./snapsend.sh -e -i hourly  tank/data backup/tank/data
./snapsend.sh -e -i offsite tank/data backup/tank/data
```

Without `-i` these would share one lock (so a scheduling overlap serializes rather than races —
correct on its own) and one bookmark (so whichever job ran last would silently become the only
one with a valid incremental base, breaking the other). With distinct `-i` tags each job gets its
own lock and its own `tgt-<hash>` bookmark, so both can be relied on independently.

### 7. Cleaning up bookmarks from a retired target

A VM was decommissioned three months ago; its bookmark on the source has sat untouched since. In
`jobs.<host>.conf`:

```ini
[prune-bookmarks:tank/data]
schedule  = 0 4 * * 0
age       = -d30
recursive = yes
```

`gen-cron.sh --install` turns this into a weekly `delsnaps.sh -B -R "tank/data" "tgt-" -d30` —
anything not refreshed in 30+ days (comfortably longer than any real backup cycle here) is pruned.

### 8. An interrupted transfer resumes on its own

A large initial send to a remote host drops mid-stream (network blip, host reboot):

```bash
./snapsend.sh tank/data user@host:backup/tank/data   # dies partway through
```

The target is left with a `receive_resume_token`. Nothing further to do by hand — the *next*
scheduled (or manual) run of the same command detects the token via `get_resume_token()` and
resumes with `zfs send -t <token>` instead of restarting the whole transfer. If it fails to
resume 3 times running, the next run gives up cleanly (`zfs receive -A`, discarding only the
stuck partial state) and falls back to a normal incremental or full send.

## Testing

Two different kinds of suite, deliberately kept apart:

```bash
./test/run.sh          # gen-cron.sh config-parsing: golden fixtures + negative cases
./test/quiesce/run.sh   # quiesce (-q) bookkeeping: which guest owns a dataset, dedup, etc.
./test/tune/run.sh      # -A autotune cache bookkeeping (stubbed zfs on PATH)
```

These three need **no root, no ZFS, no network** — plain bash + coreutils, so they run the same
on a Debian host and a Git-Bash dev box. They cover decisions (which guest, which cache file,
whether a threshold parses), not mechanism, on purpose.

```bash
sudo ./test/snapsend/run.sh   # snapsend.sh / snapget.sh, local-mode integration
sudo ./test/delsnaps/run.sh   # delsnaps.sh, including -B bookmark pruning
```

These two run against real, throwaway ZFS pools backed by sparse files — they need root and a
working `zfs`/`mbuffer`, so run them on a spare pool or a real host, never on a non-ZFS dev
machine. Each creates a PID-suffixed pool, redirects `STATS_LOG`/`LOCKDIR` to a temp dir, and
cleans up via an `EXIT` trap even if a test fails partway through. The remote (SSH) code paths are
deliberately **not** covered here — a real remote host is needed for that, since
`validate_remote_host()` refuses a loopback "replication" to the same machine by design.

## Versioning

No single package version — each script tracks its own (`-V`/`--version`), bumped only when that
script's own behavior changes. `git log` is the authoritative changelog; this README describes
current behavior only.
