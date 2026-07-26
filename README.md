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
  - [Bandwidth limiting (`-b`)](#bandwidth-limiting--b)
  - [Mounting the target (`-u`/`-U`)](#mounting-the-target--u--u)
  - [JSON-lines stats log](#json-lines-stats-log)
- [snapsend.sh — push replication](#snapsendsh--push-replication)
- [snapget.sh — pull replication](#snapgetsh--pull-replication)
- [delsnaps.sh — retention / pruning](#delsnapssh--retention--pruning)
- [check-snap-age.sh — staleness monitor](#check-snap-agesh--staleness-monitor)
- [gen-cron.sh — config-driven cron generator](#gen-cronsh--config-driven-cron-generator)
- [Alerting](#alerting)
- [deploy.sh — one-script host bootstrap](#deploysh--one-script-host-bootstrap)
- [Worked scenarios](#worked-scenarios)
- [Testing](#testing)
- [Versioning](#versioning)

## Components at a glance

| Script | Role | Version |
|---|---|---|
| [`snapsend.sh`](snapsend.sh) | Create + push-replicate a dataset (source always local, target local or remote) | v2.63 |
| [`snapget.sh`](snapget.sh) | Pull-replicate a dataset (target always local, source local or remote) | v2.57 |
| [`delsnaps.sh`](delsnaps.sh) | Prune snapshots (age- or count-based) and orphaned bookmarks | v1.23 |
| [`check-snap-age.sh`](check-snap-age.sh) | Nagios-style staleness check for the newest matching snapshot | v2.0 |
| [`gen-cron.sh`](gen-cron.sh) | Generates (and optionally installs) a crontab block from one INI config | v4.18 |
| [`lib-zfs-snap.sh`](lib-zfs-snap.sh) | Shared helpers `source`d by snapsend.sh/snapget.sh (not standalone) | — |
| [`deploy.sh`](deploy.sh) | Bootstraps a host end to end: dependencies, checkout, alerting, log rotation, smoke test, and optionally the delegated non-root account | — |

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

The hold is taken right after the snapshot, i.e. *before* the target is created, so everything in
between — ancestor creation, target creation, a refused force-full-send, listing target snapshots —
runs while holding it. Every one of those failure paths releases it on the way out (v2.58): none of
them has anything to come back for, and a stranded hold makes the source snapshot un-prunable
forever while `zfs destroy` reports only a misleading `dataset is busy`. The transfer-failure path
is the deliberate exception — with a resume token, a later run needs that exact snapshot.

**Exception — datasets replicated by Proxmox VE are never held.** If a dataset carries any
`@__replicate_` snapshot, the hold is skipped and the reason logged. `pvesr` moves data with
`zfs send -Rpv | zfs recv -F`, and a forced receive of a *replication* stream destroys every
destination snapshot the sending side no longer has — which, given the source runs its own
retention, is most syncs. A held snapshot cannot be destroyed, so the receive aborts, and
replication does not merely skip a cycle: it stays broken until someone releases the hold by
hand. Watch for snapshots named `recv-<pid>-1` — that is what a forced receive does with a
destination snapshot it could not delete, and it is the fingerprint of this having happened.

Nothing is lost by skipping. The hold exists to stop `delsnaps.sh` pruning mid-send, but on a
`pvesr`-managed dataset the snapshot set is not yours to defend — `pvesr` rewrites it to mirror
the source on every sync, so a hold cannot win that race, only break the sync. The check cannot
distinguish a replication source from a target and does not try: erring toward "skip" trades a
little pruning protection for never wedging replication.

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

**Datasets spanning several pools are fine.** `zfs snapshot` accepts multiple names only within
one pool, so the window issues one atomic call **per pool** rather than one call for everything.
This costs nothing in coherence: every guest stays frozen until the last call returns, so no
write can slip between them and all disks still land on the same instant. (Before v2.55 a single
call was used for the whole list, and any job mixing e.g. `rpool/data/vm-1` with
`hdd/vm-disks/subvol-2` failed outright, creating nothing. ZFS reports this as
`cannot create snapshots : multiple snapshots of same fs not allowed`, which names the wrong
constraint — it is one-pool-per-call, not a duplicate filesystem.)
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

### Bandwidth limiting (`-b`)

`-b <RATE>` caps the transfer. RATE is an mbuffer rate spec — a plain number of **bytes** per
second, or one with a `b`/`k`/`M`/`G` suffix (1024-based). Bytes, not bits: a 20 Mbps link is
`-b 2M`. Default is no limit.

It is applied as `mbuffer -r` to the mbuffer **already** in every pipeline, so it costs no extra
process and no extra memory. That mbuffer sits on the receiving side, right after the wire and
*before* any decompression — which is exactly where the bytes being counted are the bytes actually
crossing the link, compressed or not. (syncoid's `--source-bwlimit` puts a limiter on the sending
side, where it would have to sit after the compressor to mean the same thing.)

The mechanism is backpressure: mbuffer drains the stream at RATE, stops reading the socket, TCP
closes its window, the sender blocks. Buffers ahead of it — mbuffer's own 16 MB, the TCP window,
ssh's — mean the opening moments of a transfer can outrun the limit before it settles; tens of MB,
irrelevant on anything worth throttling.

Measured on a 200 MB incompressible stream, metropolis pve2 → pve1:

| | unthrottled | `-b 20M` | `-b 5M` |
|---|---|---|---|
| push (`snapsend.sh`) | 6.7 s | 14.1 s | 44.9 s |

Both throttled figures are the transfer time the limit implies plus ~4 s of fixed overhead.

On a **local** transfer there is no link, but the limit still applies and is still useful: it
throttles pool-to-pool I/O so a large backup doesn't starve the guests.

`-b` also feeds [`-A`](#link-autotuning--a): a limit makes the link slower than the probe measured,
and compress-or-not turns on link speed, so `-A` decides against `min(measured, -b)` rather than
against the raw probe. The cap is applied on the way into the decision, not stored in the cache —
the measurement stays valid for its week, the cap belongs to one invocation.

### Mounting the target (`-u`/`-U`)

**A replication target is not mounted.** That is the default since snapsend v2.54 / snapget v2.49;
`-u` is still accepted (and now does nothing) so existing cron lines keep parsing, and `-U` opts
back into mounting for a target that is genuinely meant to be browsed.

The reason is not tidiness. A plain `zfs send` carries no properties, so a received dataset
inherits `mountpoint` from its new parent and lands harmlessly under the target — but `-r` and
`-I` both send a **replication stream** (`zfs send -R`), which *does* carry properties, and a
source whose mountpoint is set locally brings that path along. Demonstrated live, 2026-07-25:

```
# source: rpool/mptest, mountpoint=/mnt/mptest_live (local)
# received with mounting enabled, then:
$ findmnt -n /mnt/mptest_live
/mnt/mptest_live rpool/mptest              zfs rw,relatime,xattr,noacl
/mnt/mptest_live rpool/mpoutU/rpool/mptest zfs rw,relatime,xattr,noacl   <- the BACKUP, on top
```

The backup copy mounted **over** the live dataset and shadowed it: anything reading that path now
reads the backup. `rpool/ROOT/pve-1` has `mountpoint=/` set locally on every Proxmox host, so the
same mechanism applied to a recursive backup of it points at `/`.

Two smaller reasons: a mounted copy of every container rootfs gets walked by anything that scans
the filesystem, for nothing; and a non-root receiver cannot mount at all (`mount(2)` needs
`CAP_SYS_ADMIN` regardless of `zfs allow`), so the delegated `zfsbackup` deployments need this.

What actually changes, precisely:

| situation | before | now |
|---|---|---|
| target created by these scripts | already `canmount=noauto`, never mounted | unchanged |
| incremental receive into a mounted target | stays mounted | unchanged — `-u` governs the moment of receipt, and an incremental doesn't remount |
| full/initial receive into an existing mounted target | remounted afterwards | left unmounted |
| `-w`/`-f`, where `recv` builds the leaf from the stream | mounted per the stream's own `mountpoint` | left unmounted |

`canmount` on a pre-existing target is never rewritten, so `zfs mount <dataset>` brings any of
them back by hand. `-U` sets `canmount=on` for targets it creates, since `canmount=noauto` would
otherwise outrank the recv flag and make the opt-out silently powerless.

**Under `-r` the default used to stop at the leaf** (fixed in snapsend v2.60 / snapget v2.54).
`canmount=noauto` is set on what these scripts *create* — the leaf and the ancestor path — but a
recursive stream's descendants are created by `zfs recv` itself and arrive carrying the **source's**
`canmount`. Measured on metropolis: a source child with `canmount=on`, replicated with `-r`,
produced a mountable child on the backup host, while the same source under `-R` came out `noauto`
because `-R` pre-creates every target itself. Since ordinary datasets are `canmount=on`, that was
the shadow-mount hazard above, reachable through the recursion flag most jobs use. Both scripts now
close the received subtree after a successful recursive transfer (filesystems only; skipped under
`-U`). The source's own `canmount` is never touched.

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
| `-m <MESSAGE>` | Prefix for the new snapshot's name. Omitting it is legal but warned about (v2.63/v2.57) — see below |
| `-e` | Use the existing latest snapshot instead of creating a new one |
| `-z` / `-Z` | Compress the stream with zstd (default compressor; `-Z` is an explicit synonym for `-z`) |
| `-g` | Compress with pigz instead (escape hatch when zstd is unavailable) |
| `-l <LEVEL>` | Compression level (default 3 for zstd, 6 for pigz — different scales, each tool's own default) |
| `-v <LEVEL>` | Verbosity 0 (errors only) – 4 (debug) |
| `-r` | Recursive: include child datasets, one atomic `zfs send -R` stream for the whole subtree |
| `-R` | Flat-recursive, syncoid/sanoid-compatible: expand into every descendant first (`zfs list -r`, unlimited depth, same call syncoid's `getchilddatasets` makes), then send each one as its own independent job. A failing child doesn't abort its siblings; a GUID collision on one child only forces a full resend of that child, not the whole tree (`-F` is a no-op here — see [Recursion: `-r` vs `-R`](#recursion--r-vs--r)). Mutually exclusive with `-r` |
| `-X <REGEX>` | **`-R` only.** Drop every expanded dataset whose full name matches REGEX (extended regex, unanchored). Repeatable — a dataset goes if any pattern hits. syncoid's `--exclude`. See [Filtering the expansion](#filtering-the-expansion--x--s) |
| `-S` | **`-R` only.** Skip-parent: send the descendants but not the listed dataset itself. syncoid's `--skip-parent` |
| `-n` | Dry-run: report conflicts, send nothing |
| `-I` | Full-history send if no common base exists (instead of a plain full send) |
| `-u` | Accepted and ignored — not mounting is the default since v2.54. Kept so existing cron lines keep parsing |
| `-U` | Mount the target after receive — the opt-out, see [Mounting the target](#mounting-the-target--u--u) |
| `-f` | Force full send: destroy target data, reseed from scratch |
| `-w` | Raw send (`zfs send -w`) — ships an encrypted source as ciphertext with no key needed on either end; effectively a no-op on unencrypted data |
| `-p <PORT>` | SSH port (default 22) |
| `-c <CIPHER_SPEC>` | SSH cipher(s) to request (`ssh -c`), e.g. `-c aes128-gcm@openssh.com` for a faster/weaker cipher on a CPU-bound link. Default: let ssh/sshd negotiate. No-op on a local run |
| `-k <FILE>` | Verify the remote host key against this known_hosts file (default: trust on first use) |
| `-K <FILE>` | SSH private key to authenticate with (`ssh -i`, plus `-o IdentitiesOnly=yes` so an agent holding other keys can't get the account locked out by a max-auth-tries limit). Not `-i` — that already means `--identifier` here |
| `-O <SSH_OPTION>` | Extra `ssh -o NAME=VALUE`, verbatim, e.g. `-O "ProxyJump=bastion"`. Repeatable. Syncoid's `--sshoption`. Placed **first** on the ssh command line — OpenSSH keeps the first value it sees for a given key, so an explicit `-O` can override `-p`/`-k`/`-c`/`-K` or even disable multiplexing with `-O ControlMaster=no` (verified live: `-o Port=2222 -p 22` connects on 2222, not 22) |
| `-b <RATE>` | Cap the transfer rate — see [Bandwidth limiting](#bandwidth-limiting--b) |
| `-A` | Autotune the link — see [Link autotuning](#link-autotuning--a) |
| `-q <MODE>` | Quiesce the owning Proxmox guest first — see [Quiescing](#quiescing-proxmox-guests--q) |
| `-i <TAG>` | Job identifier — see [`-i`/`--identifier`](#-i--identifier-independent-jobs-on-the-same-pair) |
| `-o "<FLAGS>"` | Raw flags appended verbatim to `zfs send` (e.g. `-o "-L -e"`). No validation — same trust level as any other flag. Skipped on the resume path (the resume token already fixes the stream format) |
| `-x <PROPERTY>` | Exclude PROPERTY on receive (`zfs recv -x`). Repeatable. Applied on both the normal and the resumed receive |
| `-F` | Reconcile before sending (recursively under `-r`; a no-op under `-R`, see [Recursion: `-r` vs `-R`](#recursion--r-vs--r)): if a **child** dataset has a snapshot named like the incremental base under a *different GUID* (real collision, not just older orphaned history), upgrade this run to a full resend of the whole subtree, same as `-f`. Narrower than `-n`'s report on purpose — a target-only snapshot that isn't a name collision (e.g. an archive keeping longer history than source) is normal and left alone, or every run against such a target would force an expensive full resend |
| `-V` | Print version and exit |

**Running without `-m` at all is legal, but warned about (verbosity 0, survives a default cron
run).** `create_snapshot()` builds the name as `${MESSAGE}$(date ...)`, so an empty `MESSAGE`
produces a bare timestamp — `2026-07-26_22-51-22` instead of `automated_hourly_2026-07-26_22-51-22`
— and `delsnaps.sh` matches by literal string **prefix**, so no real retention pattern will ever
match it. Confirmed live: such a snapshot survived a real `delsnaps.sh -n ... "automated_hourly_"`
untouched. It is not deleted by anything, ever, unless a rule specifically targets it. Every
`gen-cron.sh`-generated line is safe from this — `prefix` is a required field there — so it only
ever fires on a manual/interactive invocation.

**The warning does NOT fire under `-e`.** With `-e`, nothing new is created at all — the newest
existing snapshot on the dataset is picked up as-is, even one this tool never made: a manual
`zfs snapshot`, a snapshot from another tool entirely. That is deliberate flexibility (letting a
push/pull pick up whatever the newest snapshot happens to be, regardless of who made it), not an
oversight, so it earns no warning.

```bash
snapsend.sh -v1 pool/data backuppool/data_backup
snapsend.sh -r pool/data user@backuphost:tank/backups/data
```

## snapget.sh — pull replication

The mirror image of `snapsend.sh`: the target is always local, the source may be local or remote.
Same option surface, minus `-q` (quiescing only makes sense on the side that creates the
snapshot, which for a pull is a remote host this side doesn't control) — everything else
(`-m -e -z -Z -g -l -v -r -R -X -S -n -I -u -f -w -p -c -k -K -O -b -A -i -o -x -U -F -V`) behaves identically, with
source/target swapped (`-o` still applies to the remote `zfs send`, `-x` to the local receive,
`-F` always destroys locally since the target is always local here). `-R`'s descendant listing
runs over ssh when the source is remote, since unlike `snapsend.sh` the source here isn't always
local.

```bash
snapget.sh -v1 pool/data backuppool/data_backup
snapget.sh -r pool/data user@sourcehost:tank/backups/data
```

### Recursion: `-r` vs `-R`

Both walk the full dataset tree with no depth limit — `zfs list -r`/`zfs send -R` have no `-d`
cap, so a child-of-child-of-child-of-child nests exactly as deep as `-r` reaches. The difference
is the unit of work, not the depth:

- **`-r`**: one atomic `zfs send -R` stream carries the whole subtree; one `zfs recv` lands it
  all at once. All-or-nothing, but a single GUID collision anywhere in the tree (see `-F`) forces
  a full resend of everything, because `zfs send -R -I` decides full-vs-incremental per child from
  the *source's* history, not from what survives on the target.
- **`-R`**: syncoid/sanoid-compatible — expands the tree into a flat list first (`zfs list -r`,
  same call syncoid's `getchilddatasets` makes), then runs each dataset through the normal
  single-dataset send/recv path independently. A failing or colliding child only affects itself;
  everything else still lands, same as `snapsend.sh`/`snapget.sh` already do today for
  comma-separated top-level `DATASETS`.

Use `-r` for a single guest's own disks where all-or-nothing is exactly what you want (see
[Quiescing](#quiescing-proxmox-guests--q)). Use `-R` for a whole subtree of independent
datasets (e.g. `hdd/backups/pve2` holding `rpool/data/vm1`, `rpool/data/vm2`, ...) where one
dataset's problem shouldn't block the rest.

**Forgetting both is caught.** Naming a dataset that only holds children — `rpool/data` on a
Proxmox host, say — without `-r` or `-R` sends the parent and nothing else, and *reports success*:
the parent is a real dataset, so the transfer genuinely succeeds, the stats log records success,
and `check-snap-age.sh` sees a fresh snapshot. Nothing downstream is in a position to notice the
data never left. Both scripts therefore check for immediate children whenever neither recursion
flag is set and warn at verbosity 0 (i.e. even in a default cron run):

```
WARNING: rpool/data has 1 child dataset(s) but neither -r nor -R was given -- only rpool/data
itself is being sent, its children are NOT. Add -R (independent per-dataset jobs) or -r (one
atomic recursive stream) if you meant to include them.
```

It is a warning, not an error — replicating a parent alone is legitimate, and a job may
deliberately split parent and children across schedules. It also fires under `-n`, since a preview
is the best moment to learn the job is aimed at an empty container.

### Filtering the expansion — `-X`, `-S`

`-R` makes filtering possible in the first place. Under `-r` the subtree is one atomic
`zfs send -R` stream with nowhere to filter, so both flags are **rejected without `-R`** rather
than ignored — a filter that silently does nothing is worse than one that refuses.

```bash
# Everything under rpool/data except the swap volumes:
snapsend.sh -R -X 'swap' -m daily_ rpool/data user@backup:hdd/backups/pve1

# Only the children — rpool/data itself is an empty container:
snapsend.sh -R -S -m daily_ rpool/data user@backup:hdd/backups/pve1
```

- **`-X <REGEX>`** — syncoid's `--exclude`. An extended regex (`grep -E`), matched **unanchored**
  against the dataset's full name. Repeatable; a dataset is dropped if any pattern matches. In
  `snapget.sh` the name tested is the full **source-side** path (`SOURCE_BASE` included), so one
  regex reads the same whichever direction the data moves.
- **`-S`** — syncoid's `--skip-parent`. Send the descendants of each listed dataset, never the
  dataset itself.

**Anchoring matters more than it looks.** A child's full name contains its parent's, so an
unanchored pattern that matches a parent also matches everything beneath it:

| Pattern | `rpool/swap` | `rpool/swap/inner` |
|---|---|---|
| `-X swap` | excluded | **also excluded** |
| `-X 'swap$'` | excluded | still sent |

Both are legitimate — decide which you meant. Excluding a dataset does *not* by itself exclude its
descendants: each expanded name is tested on its own, and `zfs create -p` still creates the
skipped level on the target as an empty dataset so a surviving child has somewhere to land.

**Filtering everything out is an error, not a quiet success** (exit 1, nothing snapshotted). A
typo in a regex, or `-S` on a dataset that turns out to have no children, would otherwise exit 0
having sent nothing — indistinguishable from a healthy run in cron, and invisible until a restore
needs the data. Same reasoning as the container-parent warning above.

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
-c <CIPHER_SPEC>   SSH cipher(s) to request — same as snapsend.sh/snapget.sh -c
-K <FILE>          SSH private key (ssh -i + IdentitiesOnly=yes) — same as -K there
-O <SSH_OPTION>    Extra "ssh -o NAME=VALUE", repeatable, placed first — same as -O there
-V, --version      Print version and exit
```

A plain destroy refuses to remove a snapshot with dependent clones (e.g. a live Proxmox
linked-clone disk) — it is reported and skipped, not silently destroyed. `-F` opts into the old
cascading behavior when genuinely wanted. Datasets may be remote (`[user@]host:path`; remote only
when there's a `:` with no `/` before it), and local/remote entries can be mixed in one
comma-separated list.

**An empty pattern, or no age/count flags at all, is deliberately unrestricted — by design, not
oversight.** Matching is by literal string prefix (`[[ "$snapname" == "${pat}"* ]]`), so an empty
pattern matches *every* snapshot on the scope, not just ones without one. And with no age/count
flag given at all, the script silently defaults to age-mode with threshold = right now, which
deletes everything already there. Both are confirmed live behavior, and **neither is going to be
validated away**: this is an admin tool, not a consumer one, and the same philosophy that doesn't
put a confirmation prompt on `rm -rf *` doesn't put one here either — an operator who explicitly
asks to prune every snapshot on a scope, regardless of who created it, gets exactly that. The two
things that still survive *any* invocation of this kind: `is_protected_snapshot()` (Proxmox's own
`__replicate_`/`__migration__`/`vzdump` snapshots, never touched by any pattern or threshold) and a
`zfssnapall_inflight` hold (a snapshot mid-transfer cannot be destroyed regardless of what matched
it — `zfs destroy` refuses and it is reported, not silently skipped). Combine an empty pattern with
`-F` and both the match scope and the destroy method are at their most permissive at once — worth
knowing before reaching for both together. What *is* guarded is the config generator producing this
by accident rather than by request — see `gen-cron.sh`'s blank-vs-missing field handling below.

**A failed remote listing is a failure, not an empty result** (since v1.23). Before that fix, any
ssh/zfs error while listing a remote dataset's snapshots or bookmarks — a wrong port after a
firewall change, a revoked key, a bogus `-c` cipher, the host simply down — produced empty output
indistinguishable from "this dataset genuinely has nothing matching the pattern", so the run logged
"No snapshots found ... " and exited 0. A retention job on a remote target could therefore fail
silently forever: no alert, snapshots piling up unpruned, and every run reporting success. Found
live while proving `-c` actually reaches ssh (a bogus cipher name made ssh refuse the connection,
and this is what was hiding the refusal) — now such a listing failure exits 1 and alerts like any
other broken job.

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
| `[prune:<scope>]` | Standalone additive prune for scopes you do **not** create locally (a backup store receiving pushes from elsewhere). `recursive=`/`clear_cut=` opt in to `-R`/`-F`; `prune = no` makes the section a monitor carrier only; `ssh_flags` for a remote (`host:path`) scope. |
| `[prune-bookmarks:<scope>]` | Age-based cleanup of orphaned bookmarks — `schedule`, `age` (raw `delsnaps.sh` age flags), `pattern` (default `tgt-`), `recursive`, `ssh_flags` for a remote scope |

There is no separate `[monitor:]` section — a staleness check is derived **automatically**
wherever a tier's `pattern` already resolves for pruning, as long as that template also sets
`monitor_warn`/`monitor_crit`. It reuses the same scope and recursion the prune operation needed;
no new syntax. **Rejected on a remote `[prune:]` scope** — `check-snap-age.sh` is local-only by
design (see its own header), so a monitor riding a `host:path` scope would run `zfs list` locally
against that literal string and report a permanent false `UNKNOWN`. Run `check-snap-age.sh` in its
own cron line on the host that actually owns the dataset instead.

**`ssh_flags = <-p/-k/-c/-K/-O only>`** reaches a `[prune:]`/`[prune-bookmarks:]` section's remote
scope with `delsnaps.sh`'s SSH options — port, known_hosts, cipher, private key, extra `-o`. Kept
deliberately narrow: `-R`/`-F`/`-B`/`-n` are rejected here because they already have their own
field (`recursive=`/`clear_cut=`) or their own section type (`-B` is what `[prune-bookmarks:]`
*is*), so a second way to say the same thing would just be a second way to disagree with it. Set
on a scope with no `:` it is a **warning**, not a rejection (delsnaps.sh only opens ssh for entries
that look remote, so it is a harmless no-op there — but almost certainly means the scope itself is
missing a host prefix). The real use case for `[prune-bookmarks:]`: a `snapget.sh` **pull**'s
bookmarks accumulate on the **remote** source, so cleaning up an old one needs to reach that host.
Two remote scopes sharing schedule/pattern/age/recursive but needing *different* `ssh_flags` (e.g.
different ports) do **not** merge into one line — that key is part of the grouping, precisely so
one line's flags can't silently apply to another host's entries.

```ini
[prune:root@192.168.28.9:hdd/pulled]
use_template = hourly
ssh_flags    = -p 2222 -k /etc/zfs-known-hosts -K /etc/zfs-backup-id_ed25519
notify       = pulled
```

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
- **A key present but blank is treated exactly like the key being absent**, for `prefix`, `pattern`
  and `retain`/`keep` (v4.18). `ini_has()` only tests whether a key exists in the config, not
  whether its value is non-empty, so `pattern = ` with nothing after the `=` used to read as
  "resolved" with an empty string and sail straight past the "required field" check. The
  consequence is real, not cosmetic: an empty `pattern` makes `delsnaps.sh` match *every* snapshot
  on the scope (it matches by prefix, and everything starts with `""`), and an empty `retain`
  produces a `delsnaps.sh` line with no threshold flag at all, which silently defaults to age-mode
  with threshold=now — deleting virtually everything the dataset already has. Neither ever showed
  up as an error; it just quietly generated the single most destructive line the config could
  produce. `[prune-bookmarks:]`'s `pattern` is the one exception: that field already has a sensible
  default (`tgt-`) when omitted, so a blank value now falls back to the same default instead of
  being rejected — matching its own designed behavior rather than being promoted to an error.
  `dst` keeps its own legitimate blank meaning (no target, snapshot only) untouched; this only
  applies to fields with no sane empty meaning at all.

**`prune = no`: a monitor without a second prune.** A recursive `[prune:hdd/backups]` already
covers every leaf underneath it, but monitor thresholds are per tier, and a leaf that matters more
than its siblings wants its own. Adding `[prune:hdd/backups/pve2/nextcloud]` just to hang
`monitor_warn`/`monitor_crit` on it looks like a harmless duplicate — the same pattern, the same
retention, "a no-op on the same snapshots". It is not. The two `delsnaps.sh` lines fire in the same
minute and **race**: whichever loses finds the snapshot already gone and exits non-zero with
`could not find any snapshots to destroy` plus a misleading hint about dependent clones. On pve2
that fired 63 times in one day. `delsnaps`' own `flock` does not catch it either — the lock key is
`md5(dataset_list + pattern)`, and the two lines legitimately hash differently because one passes
`-R parent` and the other an explicit leaf.

Setting `prune = no` on such a section emits **no** `delsnaps` line and keeps the monitor. It is
rejected at generate time if the section then has no `monitor_warn`/`monitor_crit`, since it would
emit nothing at all. Note the cross-check above only compares patterns on the *same literal
scope* — containment across scopes stays your discipline; v4.15 gives you the way to express the
fix, it does not try to detect every overlap. If a `delsnaps` job ever reports "could not find any
snapshots to destroy" on a schedule, look for a second prune line whose scope contains that
dataset at the same minute before chasing clones or holds.

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

## Alerting

**Configurable per host, defaulting to one mail per day.** Every finding is recorded to a queue
and `alert-digest.sh` mails a single grouped summary once a day — or, if you ask for it, each
finding mails the moment it happens.

### Choosing the cadence — `/etc/zfs-alert.conf`

One file, sourced by all three scripts. **`ZFS_ALERT_MODE` is the variable to change.**

| Variable | Default | Meaning |
|---|---|---|
| `ZFS_ALERT_MODE` | `daily` | `daily` = queue every ALERT, one summary mail per host per day. **`immediate` = mail each ALERT as it happens.** |
| `ZFS_WARN_MODE` | `daily` | Same choice for WARNING-tier findings, set separately. |
| `ZFS_ALERT_EMAIL` | deploy-time value | Where alerts go — changes all three scripts at once. |
| `ZFS_ALERT_COOLDOWN` | `14400` (4h) | `immediate` only: seconds before the *same* message may mail again. Ignored in `daily` (the digest de-duplicates by counting). |
| `ZFS_ALERT_STATE_DIR` | `/var/lib/zfs-snapshot-all/notify-state` | `immediate` only: where those cooldown timestamps live. |
| `ZFS_ALERT_QUEUE` | `/var/lib/zfs-snapshot-all/alert-queue.log` | `daily` only: the queue the digest consumes. |

The config lives at **`/etc/zfs-alert.conf`** and the queue under
**`/var/lib/zfs-snapshot-all/`** (`2775 root:zfsalert`, setgid) rather than in `/root/scripts`,
because `/root` is `0700`: a delegated non-root account (phase 8) cannot read
or write anything under it. Opening `/root/scripts` to a group instead would be a privilege
escalation — root executes those scripts from cron, so an account able to write there could
replace them. The shared directory therefore holds **only data**; the scripts stay private to
each account, and phase 8 gives the service account its own copies of
`notify-fail.sh`/`notify-warn.sh` pointed at the same queue. `alert-digest.sh` is not duplicated
— it runs as root over the shared queue, so the host still sends one mail a day covering both
accounts. Hosts set up before this split are migrated automatically, queued findings included.

A finding travels exactly one of the two paths, so it is never reported twice. The digest's
*schedule* is not here — it is a cron line, emitted by `gen-cron.sh` (`DIGEST_SCHEDULE`, default
`0 7 * * *`).

**The environment beats the file.** Setting any of these variables before invoking a script wins
over what the config says, which is what makes `ZFS_ALERT_QUEUE=/tmp/q ./alert-digest.sh` a safe
way to try things. It was the other way round until v9/v7/v7 — the config was sourced after the
environment was read, so a test aimed at a scratch queue silently summarised, mailed and then
**deleted the production queue** instead. Found exactly that way.

```bash
sed -i 's/^ZFS_ALERT_MODE=.*/ZFS_ALERT_MODE=immediate/' /etc/zfs-alert.conf
```

**Set `immediate` while bringing a host up.** A job you misconfigured today is a five-minute fix
if you hear about it within the hour, and a lost night of backups if you read about it in
tomorrow's digest. Provision it that way from the start with
`bash deploy.sh --alerts=immediate`, then switch to `daily` once the host has run
clean for a few days. `deploy.sh` creates this file once and **never overwrites it**,
so the mode survives every re-run and upgrade.

| Mechanism | Records | How |
|---|---|---|
| `notify-fail.sh` | Any job returning non-zero (`snapsend`/`snapget`/`delsnaps` failure), `check-snap-age.sh` CRITICAL/UNKNOWN, or a DEGRADED/FAULTED pool (see below) | `daily`: appends `epoch\tALERT\tmessage` to the queue, sends no mail. `immediate`: mails at once, rate-limited per message. |
| `notify-warn.sh` | `check-snap-age.sh` WARNING (getting stale, not yet CRITICAL) | Same queue, `epoch\tWARN\tmessage`, per `ZFS_WARN_MODE`. |
| `alert-digest.sh` | — | The only backup mail this host sends. Once a day (default `0 7 * * *`) it collapses the queue to one row per (severity, message) — count plus first/last-seen — ALERTs first, then WARNINGs, and mails **one** message. Subject carries the counts: `[ZFS] <host> <date> -- N alert / M warn`. Each row is followed by **what the finding actually said**, indented. |
| `check-pool-capacity.sh` | A pool/dataset approaching its quota, ahead of any job actually failing from it | See `deploy.sh` |

**What a finding carries.** A label alone (`pve0 hourly getting stale (vm-archive)`) is a string
from your config — it identifies the job and nothing else. So since notify-fail v8 / notify-warn v6
the finding travels with the text the job or the monitor actually produced, and `gen-cron.sh`
v4.16 captures it: monitors keep `check-snap-age.sh`'s verdict in a variable, jobs write stderr to
a temp file (still appended to `cron.log`, unchanged) and pass its last 8 lines on failure.

```
ALERT -- zadanie padlo, backup przeterminowany albo pula nie jest ONLINE:

  x1    pve2 hourly prune (test)                                (16:36)
        No snapshots found for dataset hdd/nie-ma matching pattern x_

WARNING -- starzeje sie, jeszcze nie critical:

  x1    pve2 daily getting stale (root)                         (16:36)
        CRITICAL dataset=rpool/ROOT/pve-1 pattern=automated_daily
        newest=automated_daily_2026-07-26_00-21-01 age=16h (warn=1m crit=2m)
```

The detail shown is from the **last** occurrence: for something firing every fifteen minutes, the
most recent reading is the one that describes the state now. Queue entries written before v8/v6
have three columns instead of four and simply show without detail, so nothing already queued is
lost across the upgrade. A side effect of the capture worth knowing: a job's output reaches
`cron.log` as one contiguous block when it finishes rather than streaming while it runs — which
also stops two overlapping jobs interleaving their lines there.

**Why `daily` is the default.** Up to v3 there was no choice: `notify-fail.sh` always mailed on
the spot, rate-limited per unique message text. The cooldown was keyed on the *message*, so every distinct finding kept its
own independent counter and two jobs failing in the same cron tick sent two separate mails in the
same second. Volume therefore scaled with the number of distinct findings rather than with the
number of hosts — across a fleet that is a stream an operator starts filtering away, which is
strictly worse than one daily summary that actually gets read.

**What this costs.** An urgent finding waits until the digest runs. That is deliberate. Note it
does *not* apply to hardware: Proxmox's own ZED pool-health mail is a separate mechanism this
project does not touch, so a disk genuinely dropping out still pages immediately through that
path. A silent day means "nothing was queued" — it is not proof of health, since a dead cron is
also silent; a daily "all OK" per host was rejected because at fleet scale that is exactly the
noise this replaced.

**Log rotation** ships with the deploy scripts: `/etc/logrotate.d/zfs-snapshot-all` (root's logs)
and `/etc/logrotate.d/zfs-snapshot-all-<user>` (the service account's), both monthly, keep 24,
compressed. Two stanzas rather than one because of `create`: rotating the service account's logs
into a root-owned file would leave that account unable to append, and its cron would stop logging
silently. Neither stanza uses a `*.log` glob — the alert queue sits in the same directory and is
state, not a log. Retention is long on purpose: diagnosing a backup problem means comparing runs
weeks apart, and the volume is ~0.1 MB/day (a few MB on disk after ZFS compression).

If `mail` fails, the digest puts the findings back on the queue and exits non-zero rather than
dropping them — with one delivery a day, a lost run is a lost day of alerting.

The cron lines are unchanged by all of this: `gen-cron.sh` still emits the same
`notify-warn.sh` / `notify-fail.sh` calls, and both scripts keep the same one-argument interface.
Only what they do with the finding changed.

`gen-cron.sh` wires the first two straight into every generated monitor line (`[ $rc -eq 1 ] &&
notify-warn.sh ...; [ $rc -eq 2 ] && notify-fail.sh ...; [ $rc -ge 3 ] && notify-fail.sh ...`) —
see [gen-cron.sh](#gen-cronsh--config-driven-cron-generator).

**Every command in a generated line redirects its own stderr to the cron log, the notify calls
included.** cron mails whatever a job writes to stdout *or* stderr, and the notify scripts are
not silent — `notify-fail.sh` announces its own cooldown suppression there. Redirecting only the
monitored command (the behaviour before v4.13) meant a monitor sitting at CRITICAL sent a raw
cron mail on *every tick* — 96/day per monitor at `*/15` — which is exactly the flood the
rate-limiting exists to prevent. Note the redirect binds to one command, not to the whole line,
so anything added to these lines needs its own. Setting `MAILTO=""` hides this symptom but also
silences every other cron job on the host; fix the stream instead.

`notify-fail.sh`, `notify-warn.sh`,
and `alert-digest.sh` are not tracked as standalone files in this repo — `deploy.sh`
creates/upgrades them on each host from a heredoc (see its `*_MARKER` comments for the
version-detection that makes re-running it idempotent), so every host runs an identical, known
copy without a file to hand-copy or drift.

### Pool health (DEGRADED/FAULTED)

`snapsend.sh`/`snapget.sh` check the ZFS pool backing every dataset they touch — via
`check_pool_health()` in `lib-zfs-snap.sh` — the always-local side unconditionally, and the
remote side too whenever the transfer actually is remote, reusing the same SSH connection the
transfer already opens. A pool that isn't `ONLINE` mails through `notify-fail.sh` directly (same
rate-limited path as above), deliberately independent of the transfer's own exit code: a
`DEGRADED` pool with a surviving mirror leg still sends fine, so tying the alert to transfer
success would either mask a real disk failure behind a "job succeeded" exit code, or falsely
report a working transfer as failed. Because the check always runs from whichever side already
opens the connection, one execution reports **both** ends of a push/pull — the other side never
needs a separate pool-health cron of its own for the same relationship.

## deploy.sh — one-script host bootstrap

One script per host, run as root, idempotent, safe to re-run. It replaced an earlier
`deploy_new_server.sh` + `deploy_backup_user.sh` pair: that split was historical rather than
conceptual, and it forced an ordering ("run the other one first") that lived in the operator's
head instead of in the code, duplicated the helpers and the checkout logic, and produced two
separate `--check-only` verdicts for one machine.

```bash
bash deploy.sh                          # host setup; maintains an existing account if found
bash deploy.sh --check-only             # audit the WHOLE host, change nothing
bash deploy.sh --alerts=immediate       # mail every finding — use while bringing a host up
bash deploy.sh --backup-user=zfsbackup  # also CREATE the delegated non-root account
```

Defaults live in a config block at the top of the script (`NOTIFY_EMAIL`, `ALERT_MODE`,
`BACKUP_USER`, `BACKUP_USER_DATASETS`); edit them to make a choice permanent for a host, or pass
a flag for a single run.

**`BACKUP_USER` is about creation, not maintenance.** Leave it empty and an existing delegated
account is still auto-detected and kept up to date (its notify scripts, log rotation, group
membership); only *creating* one has to be asked for. So a bare `bash deploy.sh` is the right
command on every host in the fleet, whether or not that host has an account — nobody has to
remember which is which.

- **Phases 1–7 (always)** bootstrap a fresh Proxmox/Debian host as **root**: checks/installs
  every runtime dependency (table derived from what the scripts actually invoke), clones or
  updates the repo checkout at `/root/scripts/zfs-snapshot-all`, generates `notify-fail.sh`
  (mail-on-failure, rate-limited), `notify-warn.sh` + `alert-digest.sh` (daily WARNING digest),
  and `check-pool-capacity.sh` (mail before a pool fills up, ahead of any job actually breaking)
  — see [Alerting](#alerting) — smoke-tests all shipped executables plus a live compressor
  round-trip, and installs an auto-pull cron line. Idempotent — safe to re-run. It deliberately
  does **not** touch your actual `snapsend`/`snapget`/`delsnaps` job lines (those are
  dataset-specific per host); that stays a documented manual step (or use `gen-cron.sh`).

- **Phase 8 (optional)** bootstraps a dedicated, delegated **non-root** account (default
  name `zfsbackup`) so replication doesn't need to run as root: creates the locked-password,
  SSH-key-only account, its own lock/state dir, its own checkout and auto-pull cron line, and
  `zfs allow` delegation on the dataset(s) given (default `rpool/data`, `rpool/ROOT/pve-1`).
  Delegation on a dataset (without `-d`) also covers descendants that don't exist yet — new
  VM/CT disks created later under `rpool/data` inherit it automatically.

  On Linux, a delegated `mount` permission still can't actually mount/unmount without
  `CAP_SYS_ADMIN`. Routine incremental replication is unaffected, and since v2.57 **every** level
  of a target path — not just the leaf — is created `canmount=noauto`, so a delegated account can
  now bootstrap a brand-new multi-level target from scratch. (`zfs create -p` applies its `-o` to
  the final dataset only; the levels it invents got `canmount=on`, ZFS tried to mount them, and the
  receive died with `Insufficient privileges`. Root never saw it.) What still needs root: `-f`, and
  `-F` against a currently-mounted target/clone — both print a hint pointing here when they fail
  for that reason.

  **Paths follow the account.** Run as non-root, `STATS_LOG`, `NOTIFY_SCRIPT` and `LOCKDIR` default
  to `$HOME/zfs-snapshot-stats.log`, `$HOME/notify-fail.sh` and `$HOME/run` instead of their
  counterparts under `/root` — which is `0700` and therefore unreadable to that account. The old
  defaults produced one `Permission denied` per dataset, silently lost pool-health alerts, and a
  hard error on the lock directory. An explicit environment variable still wins.

  ```bash
  bash deploy.sh --backup-user=zfsbackup                        # default datasets
  bash deploy.sh --backup-user=zfsbackup --datasets="rpool/data tank/vm"
  ```

## Worked scenarios

### 1. From zero to a running hourly/daily backup schedule

```bash
# On the new host, as root:
bash deploy.sh

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
bash deploy.sh --backup-user=zfsbackup --datasets="rpool/data"
```

Phase 8 deliberately does **not** exchange SSH keys with the source host — that's
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

### Start here: what does *this* change oblige me to run?

```bash
./test/impact.sh              # uncommitted changes
./test/impact.sh HEAD~3..HEAD # a commit range
```

`impact.sh` reads [`test/deps.conf`](test/deps.conf) — a hand-written dependency graph — and turns
a diff into a concrete plan: which suites to run (cheap local ones first), which **contracts** to
re-check, and which paths **no suite can cover** and therefore must be exercised by hand. Run it
before deciding you are done; the suites below are what it points at.

The graph carries three kinds of edge, and only the first is derivable from the code:

- **source edges** — `snapsend.sh`/`snapget.sh` source `lib-zfs-snap.sh`, so a change to the lib
  pulls in both consumers' obligations. `impact.sh` parses these out of the scripts itself and
  `--verify` fails if reality and the graph disagree.
- **suite edges** — which suite exercises which file. Declared, because a suite's subject is a
  variable no parser can follow.
- **contracts** — two files that must agree although neither includes the other: `gen-cron.sh`
  hardcodes `check-snap-age.sh`'s exit codes in the cron lines it emits; `deploy.sh` must delegate
  exactly the ZFS verbs the scripts invoke; `delsnaps.sh` duplicates the lib's hold tag; the
  non-root path defaults in the scripts must equal the paths `deploy.sh` provisions. Nothing in the
  code links any of those pairs, they are where the expensive mistakes live, and no tool can infer
  them — which is why the graph is written by hand and validated rather than generated.

```bash
./test/impact.sh --graph      # mermaid rendering of the whole thing
./test/impact.sh --verify     # drift check (also asserted by the impact suite)
```

`--verify` fails if a declared file is gone, a tracked `*.sh` is missing from the graph, a contract
is listed on one side only, or a derived source edge is absent. **A new script that nobody has
decided about therefore breaks the build** — that is the point: an unlisted file is an untested
file nobody made a call on.

### The suites

```bash
./test/run.sh          # gen-cron.sh config-parsing: golden fixtures + negative cases
./test/quiesce/run.sh   # quiesce (-q) bookkeeping: which guest owns a dataset, dedup, etc.
./test/tune/run.sh      # -A autotune cache bookkeeping (stubbed zfs on PATH)
./test/impact/run.sh    # impact.sh itself, plus a live --verify of the real graph
```

These four need **no root, no ZFS, no network** — plain bash + coreutils, so they run the same
on a Debian host and a Git-Bash dev box. They cover decisions (which guest, which cache file,
whether a threshold parses), not mechanism, on purpose.

```bash
sudo ./test/snapsend/run.sh   # snapsend.sh / snapget.sh, local-mode integration
sudo ./test/delsnaps/run.sh   # delsnaps.sh, including -B bookmark pruning
```

```bash
./test/remote/run.sh --peer root@<other-host>
```

The two-host campaign: the ssh path in both directions, which no single-host suite can reach
(`validate_remote_host()` refuses a loopback replication by design). 90 checks covering snapsend,
snapget and delsnaps, local and remote, plain / `-r` / `-R` / `-X` / `-S`, `-z` on both sides of the
"local sends never compress" rule, `-b`, an incremental re-run that must take the already-exists
path without stranding its hold, and `-K`/`-O`/`-c` SSH option passthrough — including proving `-O`
actually takes priority over `-p` (`-O "Port=1"` alongside the correct `-p` must fail to connect)
and that a bad `-K`/bad `-c` fails authentication/negotiation cleanly rather than silently falling
back to something that happens to work. Everything it creates lives under `<parent>/xcamp<PID>`
and an `EXIT` trap destroys both sides even when a case fails. Run it as root, then again as the
delegated account — that second run is the `nonroot-account` obligation:

```bash
./test/remote/run.sh --peer zfsbackup@<other-host> --local-parent hdd/backuptest
```

Integrity is checked by comparing snapshot GUIDs rather than by mounting and hashing: a GUID match
proves the exact stream landed, and it is the only check that also works for an account that
cannot mount anything.

These two run against real, throwaway ZFS pools backed by sparse files — they need root and a
working `zfs`/`mbuffer`, so run them on a spare pool or a real host, never on a non-ZFS dev
machine. Each creates a PID-suffixed pool, redirects `STATS_LOG`/`LOCKDIR` to a temp dir, and
cleans up via an `EXIT` trap even if a test fails partway through. The remote (SSH) code paths are
deliberately **not** covered here — a real remote host is needed for that, since
`validate_remote_host()` refuses a loopback "replication" to the same machine by design.

### What no suite covers

Three areas are structurally out of reach, and `impact.sh` names them when a change touches them
rather than letting a green summary imply otherwise:

| Obligation | Why no suite can do it |
|---|---|
| `remote-ssh` | `validate_remote_host()` refuses loopback by design, so ssh needs a second real host |
| `nonroot-account` | a delegated account cannot mount (no `CAP_SYS_ADMIN`, and no `zfs allow` grants it) and cannot read `/root` — **root cannot reach these failures at all** |
| `force-full` | `-f`/`-F` destroy and recreate the target; root-only and destructive by nature |

That middle row is not theoretical. On 2026-07-25 the suite was green at 161/161 and one run as the
delegated account found four defects: `zfs create -p` mounting intermediates, `/root`-based path
defaults, a missing `bookmark` delegation, and a hold leaked on every pre-transfer failure.

## Versioning

No single package version — each script tracks its own (`-V`/`--version`), bumped only when that
script's own behavior changes. `git log` is the authoritative changelog; this README describes
current behavior only.
