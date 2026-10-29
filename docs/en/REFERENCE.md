# zfs-snapshot-all: technical reference

Polish version: [REFERENCJA.md](../pl/REFERENCJA.md).

This is the reference for the individual programs, flags and config sections.
For the procedure of setting up two hosts, read
[DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md) first; for ready-made expert configs,
[CONFIG-EXAMPLES.md](CONFIG-EXAMPLES.md). The complete list of `zfs-backup.sh` verbs is in
[COMMANDS.md](COMMANDS.md), and how the pieces fit together is in
[HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## Contents

- [Components at a glance](#components-at-a-glance)
- [The front door and the GUI](#the-front-door-and-the-gui)
  - [Relation kinds](#relation-kinds)
  - [Commands by purpose](#commands-by-purpose)
  - [The GUI](#the-gui)
- [Core concepts](#core-concepts)
  - [GUID-based matching](#guid-based-matching)
  - [Bookmark-backed incremental fallback](#bookmark-backed-incremental-fallback)
  - [Resumable transfers](#resumable-transfers)
  - [Hold-based protection for in-flight snapshots](#hold-based-protection-for-in-flight-snapshots)
  - [Job identifiers](#job-identifiers)
  - [Skipping intermediate snapshots](#skipping-intermediate-snapshots)
    - [Automatic catch-up threshold](#automatic-catch-up-threshold)
  - [Quiescing Proxmox guests](#quiescing-proxmox-guests)
  - [Link autotuning](#link-autotuning)
  - [Compression](#compression)
  - [Bandwidth limiting](#bandwidth-limiting)
  - [Mounting the target](#mounting-the-target)
  - [JSON-lines stats log](#json-lines-stats-log)
- [snapsend.sh (push replication)](#snapsendsh-push-replication)
- [snapget.sh (pull replication)](#snapgetsh-pull-replication)
  - [Recursion modes](#recursion-modes)
  - [Filtering the expansion](#filtering-the-expansion)
- [delsnaps.sh (retention and pruning)](#delsnapssh-retention-and-pruning)
  - [Reserved-prefix protection](#reserved-prefix-protection)
  - [Bookmark pruning](#bookmark-pruning)
  - [GFS cascading ladder](#gfs-cascading-ladder)
- [check-snap-age.sh (staleness monitor)](#check-snap-agesh-staleness-monitor)
- [gen-cron.sh (config-driven cron generator)](#gen-cronsh-config-driven-cron-generator)
  - [Options](#options)
  - [Relation blocks: what the tool writes](#relation-blocks-what-the-tool-writes)
  - [Section types](#section-types)
  - [Hand-written configs with templates](#hand-written-configs-with-templates)
  - [What the generator enforces](#what-the-generator-enforces)
  - [Monitor-only prune sections](#monitor-only-prune-sections)
  - [GFS ladder in a prune section](#gfs-ladder-in-a-prune-section)
- [Alerting](#alerting)
  - [Choosing the cadence](#choosing-the-cadence)
  - [Queue, digest and notify scripts](#queue-digest-and-notify-scripts)
  - [Pool health](#pool-health)
  - [Log rotation](#log-rotation)
- [deploy.sh (host bootstrap)](#deploysh-host-bootstrap)
- [Worked scenarios](#worked-scenarios)

Testing is described in [../../test/README.md](../../test/README.md).

## Components at a glance

| Program | Role |
|---|---|
| [`zfs-backup.sh`](../../zfs-backup.sh) | The front door. Creates, activates, pauses, edits and removes relations; runs replicas; starts the GUI (`zfs-backup gui`). It orchestrates the programs below and never writes onto a client's production data (that is `zfs-restore.sh`'s job) |
| [`zfs-restore.sh`](../../zfs-restore.sh) | The restore surface (planner, safe restore into a side namespace, destructive replace behind an explicit grant). `zfs-backup.sh restore` forwards to it |
| [`snapsend.sh`](../../snapsend.sh) | Create and push-replicate a dataset (source always local, target local or remote) |
| [`snapget.sh`](../../snapget.sh) | Pull-replicate a dataset (target always local, source local or remote); also mirror mode and snapshot-only mode |
| [`delsnaps.sh`](../../delsnaps.sh) | Prune snapshots (age-, count- or GFS-ladder-based) and orphaned bookmarks |
| [`check-snap-age.sh`](../../check-snap-age.sh) | Nagios-style staleness check for the newest matching snapshot, local or over ssh |
| [`gen-cron.sh`](../../gen-cron.sh) | Generates (and optionally installs) a crontab block from one INI config |
| [`zfs-job.sh`](../../zfs-job.sh) | The envelope around every generated cron job (logging, begin/end markers, failure notification). The engine command stays readable in the crontab line |
| [`deploy.sh`](../../deploy.sh) | Bootstraps a host (dependencies, checkout, alerting, log rotation, smoke test, optional delegated account) and handles pairing (`--pair`, `--join`, `--leave`) |
| [`clean-relationships.sh`](../../clean-relationships.sh) | Audits one host for relation traces (records, accounts, keys, grants, holds) and removes the dead ones when told to |
| [`update-control.sh`](../../update-control.sh) | Self-update, rollback and update hold, deployed outside the checkout it manages |
| [`zfs-pair-gate.sh`](../../zfs-pair-gate.sh) | Peer-side gate that refuses the data-plane commands of a disabled relation |
| [`zfs-media-gate.sh`](../../zfs-media-gate.sh) | `zpool import`, sync, `zpool export` bracket around a replica onto removable media |
| [`zfs-quiesce-helper.sh`](../../zfs-quiesce-helper.sh) | The only privileged action a delegated account may perform on a guest (freeze/thaw), behind a sudo rule |
| [`tui/`](../../tui) | The text GUI (`zfs-tui.py` plus the whiptail windows it starts) |
| [`hostscripts/`](../../hostscripts) | The scripts a host runs from cron or for alerting, installed by copying: `notify-fail.sh`, `notify-warn.sh`, `alert-digest.sh`, `alert-env.sh`, `check-pool-capacity.sh`, `capacity-guard.sh`, `growth-guard.sh` |
| `lib-*.sh` | Shared code, sourced and never run: [`lib-zfs-snap.sh`](../../lib-zfs-snap.sh) (send/receive/quiesce engine for snapsend and snapget), `lib-cron.sh` (the one crontab writer), `lib-backup-common.sh`, `lib-pairing.sh`, `lib-scope.sh`, `lib-profile.sh`, `lib-record.sh`, `lib-rekey.sh` |
| [`profiles/`](../../profiles) | Retention templates; see [profiles/README.md](../../profiles/README.md) |

Versions are not listed here, because a number kept manually in two places goes stale. Ask the
program: `snapsend.sh`, `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh` and `gen-cron.sh` answer
`-V`; `deploy.sh` and `zfs-backup.sh` answer `--version` (the checkout's revision). The changelog is
`git log`; this document describes current behavior only.

## The front door and the GUI

Normally you do not call the engines yourself. `zfs-backup.sh` creates a relation, writes
the config, installs the cron block and keeps the pieces consistent. Run it without arguments to
print the full usage. A relation is created in four commands (collector, source, collector,
collector) as shown in [DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md); each command can be re-run
after an interruption and resumes from the durable state.

### Relation kinds

These are the names the GUI uses.

| Kind | What it does | Engine |
|---|---|---|
| backup | The collector pulls datasets of a source into its own target and keeps a tiered history on both sides | `snapget.sh`, `delsnaps.sh` |
| mirror (lustro) | Sync mode: the collector holds the source's datasets at the same paths and, after each pull, destroys the target snapshots the source no longer has (`snapget.sh -M`) | `snapget.sh -M` |
| local copy (kopia lokalna) | A copy of local datasets onto another local pool, run by root or a named account | `snapget.sh` with a local source |
| local snapshots (migawki lokalne) | Snapshots on the source, pruned in place, nothing copied (`--target=''`) | `snapsend.sh`, `delsnaps.sh` |
| remote snapshots (migawki zdalne) | The collector takes snapshots on a remote source and copies nothing (`[snaponly:]` section, `snapget.sh -s`) | `snapget.sh -s`, `delsnaps.sh` |

Remote push (the source pushes to the collector) is a CLI mode for existing fleets; the GUI has no
window for it. See [snapsend.sh](#snapsendsh-push-replication).

### Commands by purpose

| Purpose | Verbs |
|---|---|
| Create | `--source=HOST:DATASET --target=DATASET [--install]` (remote backup; without `--install` it only plans), `--mode=sync` (mirror), `--source=DATASET --target=DATASET` (local copy), `--target=''` (local snapshots), `new-relation` (wizard), `add-client`, `seed`, `activate` |
| Change | `edit-relation`, `set-tiers`, `show-tiers`, `set-transfer`, `set-bandwidth`, `add-source`, `remove-source`, `save-profile`, `list-profiles`, `delete-profile`, `edit-config` |
| State | `pause-client` / `resume-client` (logical pause, `-L` on the job lines), `disable-client` / `enable-client` (the peer refuses the relation), `move-to-client`, `set-endpoint`, `verify-endpoint`, `final-catchup` |
| Remove | `remove-client`, `delete-relation` (the whole removal as one command) |
| Inspect | `status`, `monitor`, `list-jobs`, `job-stats`, `show-config`, `show-scope`, `pair-snapshots`, `export-relation` / `import-relation`, `list-datasets`, `check-source`, `source-pruners`, `prepare-source`, `test` |
| Replicas (extra copies onto disks that get unplugged) | `add-replica`, `list-replicas`, `run-replicas`, `run-relation`, `prepare-media`, `install-media-trigger`, `remove-media-trigger`, `replica-restart`, `remove-replica` |
| Restore | `restore --plan`, `restore --dataset=D --snapshot=S` (safe side restore), `browse NAME --ask` (read-only mount of a snapshot, copy files out) |

Verbs that end in `-client` act on the relation record; bare verbs act on the link or the data.
Many verbs only plan until you pass `--yes` (or `--install`), and the readers have a `--json`
form, which is the GUI's data layer.

### The GUI

`zfs-backup gui` (equivalently `./zfs-backup.sh gui`) opens a full-screen text interface for an ssh
session. It is a thin layer over the verbs above: it reads their `--json` output and runs the same
commands, so everything it does can be done on the command line. The GUI starts in English; for
Polish: F10 Settings, item `language` (writes `[gui] language = pl` to `settings.ini`); for one
run: `ZFS_TUI_LANG=pl zfs-backup gui` or `--lang=pl`.

| Key | Window or action |
|---|---|
| F1 | Help (Pomoc) |
| F2 | Runs (Przebiegi): past and upcoming |
| F3 | Relations (Relacje): Ins = new, Del = delete, Enter = open, `e` = edit inside a relation window |
| F4 | Copies (Kopie): Enter browses, F9 restores |
| F5 | Templates (Szablony) |
| F6 | Replica (Replika) |
| F7 | Run now (F2, F3, F6), Browse (F4) |
| F8 | Show/hide past runs (F2), pause/resume a relation (F3), group by relation (F4), Key (F6) |
| F9 | Group by relation (F2), File export/import (F3), Restore (F4) |
| F10 | Settings (Ustawienia): host settings (`settings.ini`, see [Alerting](#alerting)) |
| F12 | Quit (Wyjście) |

Restore from a disk (the former F11 Restore window) has been inside F4 Copies since 2026-10-27: the disk's row, F9. F11 is free.

## Core concepts

These are the ideas that make the toolkit behave differently from a naive `zfs send | zfs recv`
wrapper. Skip to [Worked scenarios](#worked-scenarios) to see them in action.

### GUID-based matching

`find_common_snapshot()` first tries to match source and target snapshots **by name** (fast
path). If nothing matches, because a snapshot or the dataset itself was renamed on either side
since the last sync, it falls back to matching **by ZFS GUID**, the property that identifies a
snapshot independent of its current name. `zfs receive` keys an incremental off the stream's
embedded `fromguid`, not off the name given to `-i`/`-I`, so a source-side name found via GUID is
a valid incremental base.

Without this, a renamed snapshot forces a full resend (and, with `-f`, a destructive rollback of
the target). With it, replication survives an admin renaming a snapshot for clarity, or `zfs
rename`-ing the dataset itself.

### Bookmark-backed incremental fallback

A ZFS bookmark (`dataset#mark`) records a snapshot's txg and GUID at essentially zero space cost.
That is enough to serve as an incremental send base, but it is not a snapshot and cannot be
received into. After every successful, non-recursive transfer, `record_send_bookmark()` refreshes
**one** bookmark per target on the **source** dataset, replacing the previous one. If the snapshot
that bookmark was based on is later pruned from the source (by `delsnaps.sh`, before the target
caught up), the next run's `find_bookmark_base()` still finds a valid incremental base via the
bookmark instead of falling through to a full send.

Bookmark names are `tgt-<8 hex chars>`, a hash of the target dataset path (and of the `-j`
identifier, if any). Nothing else on the source touches them, so exactly one bookmark per
(target, identifier) pair accumulates until the target is retired; see
[Bookmark pruning](#bookmark-pruning) for cleaning those up. Under `-r` (one atomic stream) the
engines keep no bookmark.

### Resumable transfers

If a `zfs receive` is interrupted mid-stream, ZFS leaves a `receive_resume_token` on the target.
Both engines detect it and resume with `zfs send -t <token>` instead of restarting, for up to
`MAX_RESUME_ATTEMPTS` (3) tries, counted per target under `LOCKDIR`. After that many failed
resumes, `zfs receive -A` abandons the partial state (not the target's existing history) and the
next run falls back to a normal incremental or full send.

### Hold-based protection for in-flight snapshots

The snapshot a `zfs send` is reading, or that a stuck resume token still depends on, is protected
with `zfs hold` (tag `zfssnapall_inflight`). ZFS itself enforces it: a `delsnaps.sh` run in the
same cron window cannot prune a snapshot that is mid-transfer, because `zfs destroy` on a held
snapshot fails. `delsnaps.sh` recognizes this hold and reports "in-flight, skipped" instead of a
generic dependent-object error. The hold is released as soon as the transfer succeeds, or fails
without a resume token to protect.

The hold is taken right after the snapshot, before the target is created, so ancestor creation,
target creation, a refused force-full-send and listing the target's snapshots all run while
holding it. Every one of those failure paths releases the hold on the way out: a stranded hold
would make the source snapshot un-prunable while `zfs destroy` reports only a misleading
`dataset is busy`. The transfer-failure path is the deliberate exception, because with a resume
token a later run needs that exact snapshot.

**Exception: datasets replicated by Proxmox VE are never held.** If a dataset carries any
`@__replicate_` snapshot, the hold is skipped and the reason logged. `pvesr` moves data with
`zfs send -Rpv | zfs recv -F`, and a forced receive of a replication stream destroys every
destination snapshot the sending side no longer has. A held snapshot cannot be destroyed, so the
receive would abort and replication would stay broken until someone releases the hold manually.
Watch for snapshots named `recv-<pid>-1`: that is what a forced receive does with a destination
snapshot it could not delete.

Nothing is lost by skipping. The hold exists to stop `delsnaps.sh` pruning mid-send, but on a
`pvesr`-managed dataset the snapshot set is not yours to defend, because `pvesr` rewrites it to
mirror the source on every sync. The check cannot tell a replication source from a target and does
not try; erring toward "skip" trades a little pruning protection for never wedging replication.

### Job identifiers

Both engines key their single-instance lock and their bookmark tag on `(source, target)` alone by
default, so a manual run and a scheduled run of the same job always serialize instead of racing.
`-j <TAG>` folds an extra tag into both, letting a **second, independent job** aimed at the same
source/target pair have its own lock and its own incremental-base bookmark. Omit it to keep the
default.

```bash
# Two schedules hitting the same target, deliberately kept independent:
./snapsend.sh -e -j hourly  tank/data backup/tank/data
./snapsend.sh -e -j offsite tank/data backup/tank/data
```

### Skipping intermediate snapshots

When a common base is found, an incremental normally runs `zfs send -I <base> <newest>`, which
carries **every** snapshot in between as its own snapshot on the target. This is what lets a
lower-frequency tier (daily, weekly, ...) ride an hourly job's incremental to the archive. `-i`
switches that one send to `zfs send -i <base> <newest>`: only the diff to the newest snapshot,
none of those in between.

It is meant for a target that has been offline a long time: with the default, every
hourly/daily/etc. snapshot taken while it was gone lands on the target and streams in full; `-i`
carries only the final state, in one step. The trade-off is that the target gains none of the
intermediate snapshots' own history.

It combines with `-r`: `zfs send -R -i` is valid and recursive, so base and newest land on every
dataset in the subtree and the intermediates on none. Under `-R` (independent per-dataset jobs)
each expanded dataset gets its own common-base lookup, so `-i` simply flips that per-dataset
choice. It is a no-op (logged, not rejected) when there is no common snapshot to begin with: the
bookmark-fallback path already sends a single diff.

```bash
# Target has been offline for a week; catch it up in one step instead of
# replaying every hourly/daily snapshot taken in the meantime:
./snapsend.sh -i tank/data backup/tank/data
```

#### Automatic catch-up threshold

`-T <N>` decides `-i` automatically, per dataset, from how long the target has been behind,
expressed **relative to that dataset's own snapshot cadence** rather than as an absolute time or
count. An absolute threshold creates an arbitrary cliff (23 h offline keeps every intermediate,
26 h keeps none) and is wrong across tiers (an hourly job piles up about 24 snapshots a day, a
daily job about one). With `-T`, the threshold is "more than N of THIS dataset's own intervals",
where the interval is *measured* (the gap between the two newest snapshots on the source that
match this run's `-m` prefix, never assumed).

| dataset's own cadence | own interval (measured) | `-T 24` cliff at |
|---|---|---|
| hourly | ~1 h | ~24 h offline |
| daily | ~24 h | ~24 days offline |

So a daily-tier dataset offline for 5 days stays under an `N=24` threshold and keeps sending every
daily snapshot, while an hourly-tier dataset offline for 26 hours crosses it and catches up in a
single diff.

```bash
./snapsend.sh -T 24 tank/data backup/tank/data
```

Unmeasurable cases (fewer than two matching snapshots on the source, a zero or negative
interval, a common snapshot whose creation time cannot be read) always resolve to "no": the
default `-I` stays untouched, and `-T` never fails a run. An explicit `-i` wins outright and skips
the check.

**Known limitation:** a job whose `-m` prefix matches several tiers at once (for example
`-e -m automated_` matching hourly, daily, weekly, monthly and annual snapshots) measures its
interval from the most frequent tier among the matches, which understates the interval for the
coarser tiers riding along. Use a single-tier `-m` prefix per job to avoid it.

### Quiescing Proxmox guests

`-q <mode>` freezes the Proxmox guest that owns a dataset immediately before snapshotting it, so
the snapshot is filesystem-consistent instead of merely crash-consistent. Guest ownership is
inferred from the Proxmox dataset naming (`vm-<id>-disk-N`, `subvol-<id>-disk-N`); anything else is
snapshotted as normal, with no attempt to quiesce.

| mode | mechanism | applies to |
|---|---|---|
| `no` (default) | nothing | none |
| `agent` | `qemu-guest-agent` `fsfreeze` | VMs |
| `sync` | `pct exec <id> -- sync` (a flush, not a freeze: containers have no guest agent and ZFS implements no `FIFREEZE`) | containers |
| `auto` | picks per guest from its type | both |

The freeze window contains **only** `zfs snapshot`, never the transfer. A guest owning several
disks is quiesced once per run and all its disks are snapshotted together in one atomic window.
`zfs snapshot` accepts several names only within one pool, so datasets spanning several pools get
one atomic call per pool; every guest stays frozen until the last call returns, so all disks still
land on the same instant. Thaw is guaranteed by an `EXIT` trap. Quiescing is ignored together with
`-e` (nothing new is created) and with `-n`.

**Window budget.** VSS limits a Windows freeze to about 10 seconds and releases it on its own, so a
successful `fsfreeze-freeze` proves nothing by the time `zfs snapshot` runs. The engine freezes VMs
only immediately before the snapshot (slow, non-freezing work such as flushing containers happens
first), asks every VM again whether it is still frozen right before `zfs snapshot`, and measures the
elapsed time from the first freeze. A guest that is no longer frozen, or a window longer than the
budget (`QUIESCE_MAX_WINDOW`, default 5 seconds), refuses the snapshot rather than snapshotting on
a freeze that may already be gone. Raise the budget only if you know the guests involved can hold
the freeze.

**Failure policy.** A failed freeze still takes the snapshot, crash-consistent, unless the tier says
`,strict`:

- the snapshot name carries `_crash_` between the family and the timestamp
  (`automated_daily_crash_2026-08-26_20-50-40`), so it still belongs to the same family for
  retention and monitoring;
- the run exits **8**, so cron's notifier reports it;
- the log says which quiesce failed and why.

Append `,strict` (`-q auto,strict`) to take no snapshot and fail the run instead; use it for
datasets where a crash-consistent copy is useless, for example a database whose restore procedure
begins by discarding one. `,degrade` is still accepted and asks for what is now the default. Some
failures are fatal in either case: a thaw that did not take, a foreign freeze already in place, and
a rollback that could not remove this run's own snapshots. The qualifier parser is shared by both
engines; `no,<qualifier>` is rejected.

**Pull.** `snapget.sh -q` accepts the same modes and qualifiers, and the whole freeze, atomic
snapshot, thaw sequence runs in one remote invocation with its own `EXIT` trap and a detached
deadman timer (`-Q <SECONDS>`, default 120, minimum 10), so a dropped connection or a killed local
job cannot leave a guest frozen. It needs privilege on the source: pair with `--as=root`, or keep
the delegated account and run `deploy.sh --join <package> --allow-quiesce` on the source, which
installs `zfs-quiesce-helper.sh` and a sudo rule for that one script. With neither, the default
degrade policy applies: a `_crash_` snapshot and exit 8 (see above); with `,strict` the job fails
without a snapshot. A local source freezes the guests
on this host.

Filesystem-consistent is not application-consistent. For a database-consistent snapshot, put the
engine's own quiesce logic (`FLUSH TABLES WITH READ LOCK`, Postgres backup mode, ...) in the
guest's `/etc/qemu/fsfreeze-hook`, which the agent runs inside the freeze.

### Link autotuning

`-A` measures a real `zfs send` sample from the dataset (it needs an existing snapshot and stands
down quietly on a dataset's very first run) and the link speed to the target host, then decides
whether compressing the stream is worth it for *this* data over *this* link. Measurements are
cached 7 days (link speed per host; ratio per dataset, since compressibility belongs to the data),
so the probe of about 10 seconds runs at most about once a week; force a re-probe with
`ZFS_SNAP_RETUNE=1`. An explicit `-z`/`-Z`/`-g`/`-N` always wins: `-A` only fills in a decision you
did not make. Remote transfers only; a local target has nothing to measure. In a pull the
compressor runs on the remote source, so the ratio is measured there.

### Compression

Two independent mechanisms:

- **Explicit stream compression**: `-z`/`-Z` (zstd), `-g` (pigz), `-l <level>`. Against a remote
  target or source compression is on by default (zstd level 3) unless `-N` is given. It is
  ignored, with a log line and never fatal, on a local transfer, since there is no network link to
  amortize the CPU cost against. zstd is the default because it measured strictly better than pigz
  on the reference hardware (about 2.3x ratio at roughly 450 MB/s for zstd -3, against about 2.2x at
  roughly 140 MB/s for pigz -6).
- **Compressed send** (`zfs send -c`), automatic and without a flag: ships records as they already
  sit on disk instead of decompressing to build the stream and recompressing on receive. It costs no
  extra CPU (it removes work), so unlike `-z` it also helps a purely local transfer. It is skipped
  automatically when the target pool lacks the required features (`feature@lz4_compress`, plus
  `feature@zstd_compress` for zstd-compressed records); force plain sends with
  `ZFS_SNAP_NO_COMPRESSED_SEND=1`.

### Bandwidth limiting

`-b <RATE>` caps the transfer. RATE is an mbuffer rate spec: a plain number of **bytes** per
second, or a number with a `b`/`k`/`M`/`G` suffix (1024-based). Bytes, not bits: a 20 Mbps link is
`-b 2M`. The default is no limit.

It is applied as `mbuffer -r` to the mbuffer already in every pipeline, so it costs no extra
process or memory. That mbuffer sits on the receiving side, right after the wire and *before* any
decompression, which is exactly where the bytes counted are the bytes crossing the link,
compressed or not. The mechanism is backpressure: mbuffer drains the stream at RATE, stops reading
the socket, TCP closes its window and the sender blocks. Buffers ahead of it (mbuffer's own 16 MB,
the TCP window, ssh's) let the opening moments of a transfer outrun the limit by tens of MB, which
is irrelevant on anything worth throttling.

Measured on a 200 MB incompressible stream between two hosts:

| | unthrottled | `-b 20M` | `-b 5M` |
|---|---|---|---|
| push (`snapsend.sh`) | 6.7 s | 14.1 s | 44.9 s |

Both throttled figures are the transfer time the limit implies plus about 4 s of fixed overhead.

On a **local** transfer there is no link, but the limit still applies and throttles pool-to-pool
I/O so a large backup does not starve the guests. `-b` also feeds [`-A`](#link-autotuning): the
decision is made against `min(measured, -b)`; the cap is applied on the way into the decision and
is not stored in the cache.

When a pairing is created with `--bandwidth=RATE` the cap belongs to the link (every relation
with that peer); `zfs-backup.sh set-bandwidth` changes it.

### Mounting the target

**A replication target is not mounted.** This is the default; `-u` is still accepted and does
nothing, so existing cron lines keep parsing, and `-U` opts back into mounting for a target that
is meant to be browsed.

The reason is not tidiness. A plain `zfs send` carries no properties, so a received dataset
inherits `mountpoint` from its new parent and lands harmlessly under the target. But `-r` and `-H`
both send a **replication stream** (`zfs send -R`), which *does* carry properties, and a source
whose mountpoint is set locally brings that path along:

```
# source: tank/mptest, mountpoint=/mnt/mptest_live (local)
# received with mounting enabled, then:
$ findmnt -n /mnt/mptest_live
/mnt/mptest_live tank/mptest                zfs rw,relatime,xattr,noacl
/mnt/mptest_live backup/dst/tank/mptest     zfs rw,relatime,xattr,noacl   <- the BACKUP, on top
```

The backup copy mounts **over** the live dataset and shadows it: anything reading that path now
reads the backup. `rpool/ROOT/pve-1` has `mountpoint=/` set locally on every Proxmox host, so the
same mechanism on a recursive backup of it points at `/`. Two smaller reasons: a mounted copy of
every container rootfs gets walked by anything that scans the filesystem, and a non-root receiver
cannot mount at all (`mount(2)` needs `CAP_SYS_ADMIN` regardless of `zfs allow`).

| situation | result |
|---|---|
| target created by these programs | `canmount=noauto`, never mounted (every level of the target path, not only the leaf) |
| incremental receive into a mounted target | stays mounted; `-u` governs the moment of receipt and an incremental does not remount |
| full/initial receive into an existing mounted target | left unmounted |
| `-w`/`-f`, where `recv` builds the leaf from the stream | left unmounted |
| descendants received under `-r` | closed (`canmount=noauto`) after a successful recursive transfer; filesystems only; skipped under `-U` |

`canmount` on a pre-existing target is never rewritten, so `zfs mount <dataset>` brings any of
them back manually. `-U` sets `canmount=on` for targets it creates, since `canmount=noauto` would
otherwise outrank the recv flag and make the opt-out powerless. The source's own `canmount` is
never touched. The descendants of a recursive stream are created by `zfs recv` itself and arrive
carrying the source's `canmount`; the engines close the received subtree afterwards so the
shadow-mount hazard cannot reach them either.

### JSON-lines stats log

Every run appends one JSON object per line to `STATS_LOG` (JSON-lines: one record per line, no
top-level array), so you can query it with `jq` instead of parsing it with regex. The default path
is `/root/scripts/zfs-snapshot-stats.log` for root and `$HOME/zfs-snapshot-stats.log` for a
non-root account.

```json
{"time":"2026-07-24T10:15:03Z","script":"snapsend.sh","label":"src-a","dataset":"tank/data","target":"backup/tank/data","status":"success","duration_s":42,"resumed":false}
{"time":"2026-07-24T10:16:01Z","script":"delsnaps.sh","dataset":"tank/data","pattern":"auto_","status":"success","duration_s":1,"deleted":2,"kept":3}
```

`snapsend.sh`/`snapget.sh` records carry `label` (the relation, from `-L`; empty when the job
has none), `target` and `resumed` (a real boolean). `delsnaps.sh` records carry
`pattern`/`deleted`/`kept` instead, since it prunes rather than transfers. `status` is `success`,
a failure, or a distinct non-success such as `skipped_paused` (the relation is paused),
`skipped_lock` or `snapshot_only`, so a skipped run can never be read back as a fresh backup.
Logging is best-effort: an unwritable path is swallowed rather than failing a backup that already
succeeded.

```bash
# Every non-success record since yesterday:
jq -c --arg since "$(date -u -d '1 day ago' +%FT%TZ)" 'select(.status != "success" and .time > $since)' "$STATS_LOG"

# Average send duration per dataset:
jq -s 'group_by(.dataset) | map({dataset: .[0].dataset, avg_s: (map(.duration_s) | add / length)})' "$STATS_LOG"
```

## snapsend.sh (push replication)

Source is always local; the target may be local or remote (`[user@]host:dataset`). It creates a
new snapshot (or reuses the latest with `-e`), finds the best incremental base (name match, then
GUID match, then bookmark match, then a full send) and transfers it. It is also the engine of
restore-to-place and of local snapshot-only jobs.

**Remote push is a CLI mode for existing fleets.** The GUI creates pull, mirror, local-copy and
snapshot-only relations and has no window for push. To set one up manually: run
`deploy.sh --pair --role=push --peer=COLLECTOR` on the source and `deploy.sh --join=…` on the
collector, then add a `[dataset:]` section with `dst = account@COLLECTOR:target` and
`flags = -K <pairing key> -k <pinned known_hosts>` to the source's config and install it with
`gen-cron.sh --install`. To move such a relation to a new collector address, edit `dst` and add
`-O HostKeyAlias=<old address>` to `flags`, then install again: the host key was pinned under the
old address, and without the alias ssh refuses the new one. To tear down, run `deploy.sh --unpair`
on the source and then the three commands it prints on the collector (`zfs unallow`, `userdel -r`,
`rm` of the manifest).

```
Usage: snapsend.sh [options] DATASETS [REMOTE]
```

| Flag | Meaning |
|---|---|
| `-m <MESSAGE>` | Prefix for the new snapshot's name. Omitting it is legal but warned about, see below |
| `-e` | Use the existing latest snapshot instead of creating a new one |
| `-E <PREFIX>` | Used with `-e`: never adopt a snapshot whose name starts with PREFIX as the newest/base, even when it is newer (the newest non-excluded snapshot wins). Repeatable. For passive pickups of a foreign system's snapshots |
| `-t` | The second argument is the EXACT dataset to write, not a base to append the source name under. Used by restore, where the copy has to land back at its original path. Refused with several datasets, without a base, and with `-R` |
| `-z` / `-Z` | Compress the stream with zstd (`-Z` is a synonym for `-z`). On by default against a remote target |
| `-g` | Compress with pigz instead (escape hatch when zstd is unavailable) |
| `-N` | No compression: opts out of the remote default. Contradicts `-z`/`-Z`/`-g` |
| `-l <LEVEL>` | Compression level (default 3 for zstd, 6 for pigz; the scales differ) |
| `-v <LEVEL>` | Verbosity 0 (errors only, the default) to 4 (debug) |
| `-r` | Recursive: include child datasets in one atomic `zfs send -R` stream for the whole subtree |
| `-R` | Flat-recursive, syncoid/sanoid-compatible: expand into every descendant first (`zfs list -r`, unlimited depth), then send each one as its own independent job. Mutually exclusive with `-r`; see [Recursion modes](#recursion-modes) |
| `-X <REGEX>` | **`-R` only.** Drop every expanded dataset whose full name matches REGEX (extended regex, unanchored). Repeatable. See [Filtering the expansion](#filtering-the-expansion) |
| `-S` | **`-R` only.** Skip-parent: send the descendants but not the listed dataset itself |
| `-n` | Dry-run: report conflicts, send nothing |
| `-H` | Full-history send if no common base exists (instead of a plain full send) |
| `-u` | Accepted and ignored: not mounting is the default |
| `-U` | Mount the target after receive; see [Mounting the target](#mounting-the-target) |
| `-f` | Force full send: destroy target data, reseed from scratch |
| `-w` | Raw send (`zfs send -w`): ships an encrypted source as ciphertext, no key needed on either end; effectively a no-op on unencrypted data |
| `-p <PORT>` | SSH port (default 22) |
| `-c <CIPHER_SPEC>` | SSH cipher(s) to request (`ssh -c`), e.g. `aes128-gcm@openssh.com` for a CPU-bound link. Default: let ssh/sshd negotiate. No-op on a local run |
| `-k <FILE>` | Verify the remote host key against this known_hosts file (default: trust on first use, then refuse if the key changes) |
| `-K <FILE>` | SSH private key (`ssh -i`, plus `-o IdentitiesOnly=yes` so an agent holding other keys cannot get the account locked out by a max-auth-tries limit). Not `-i`, which means skip-intermediates here |
| `-O <SSH_OPTION>` | Extra `ssh -o NAME=VALUE`, verbatim, e.g. `-O "ProxyJump=bastion"`. Repeatable. Placed **first** on the ssh command line; OpenSSH keeps the first value it sees for a key, so an explicit `-O` can override `-p`/`-k`/`-c`/`-K` or disable multiplexing with `-O ControlMaster=no` |
| `-b <RATE>` | Cap the transfer rate; see [Bandwidth limiting](#bandwidth-limiting) |
| `-A` | Autotune the link; see [Link autotuning](#link-autotuning) |
| `-q <MODE>` | Quiesce the owning Proxmox guest first; see [Quiescing](#quiescing-proxmox-guests) |
| `-j <TAG>` | Job identifier; see [Job identifiers](#job-identifiers) |
| `-i` | Skip intermediate snapshots on an incremental (`zfs send -i` instead of `-I`); see [Skipping intermediate snapshots](#skipping-intermediate-snapshots) |
| `-T <N>` | Auto-switch to `-i` once more than N of a dataset's own snapshot intervals have elapsed since the common base; see [Automatic catch-up threshold](#automatic-catch-up-threshold) |
| `-o "<FLAGS>"` | Raw flags appended verbatim to `zfs send` (e.g. `-o "-L -e"`). No validation. Skipped on the resume path, where the token already fixes the stream format |
| `-x <PROPERTY>` | Exclude PROPERTY on receive (`zfs recv -x`). Repeatable; applied on the normal and the resumed receive |
| `-F` | Reconcile before sending (recursively under `-r`; a no-op under `-R`): if a **child** dataset has a snapshot named like the incremental base under a *different GUID* (a real collision, not just older orphaned history), upgrade this run to a full resend of the whole subtree, as `-f` does. Narrower than `-n`'s report on purpose: a target-only snapshot that is not a name collision (an archive keeping longer history than the source) is normal and left alone |
| `-L <LABEL>` | The relation (`zfs-backup.sh` client) this run belongs to. If it is paused (`pause-client`), the run exits 0 with "SKIPPED: relationship LABEL is paused" before any lock, snapshot or ssh work and logs `skipped_paused`. Written into generated lines by `pair_label`. A run without `-L` is not gated: pause is orchestration, not a security boundary |
| `-V` | Print version and exit |

**Running without `-m` is legal but warned about** (verbosity 0, so it shows up in a default cron
run). The snapshot name is `${MESSAGE}$(date ...)`, so an empty `MESSAGE` produces a bare
timestamp (`2026-07-26_22-51-22` instead of `automated_hourly_2026-07-26_22-51-22`), and
`delsnaps.sh` matches by literal string **prefix**, so no real retention pattern will ever match
it. Nothing deletes such a snapshot unless a rule specifically targets it (see the `-G` ladder).
Every `gen-cron.sh`-generated line is safe from this because `prefix` is a required field there,
so it only fires on a manual invocation. The warning does **not** fire under `-e`: nothing new is
created and the newest existing snapshot, even one this tool never made, is picked up as-is. That
is deliberate flexibility.

```bash
snapsend.sh -v1 pool/data backuppool/data_backup
snapsend.sh -r pool/data user@backuphost:tank/backups/data
```

## snapget.sh (pull replication)

The mirror image of `snapsend.sh`: the target is always local, the source may be local or remote.
It accepts every `snapsend.sh` flag (`-m -e -E -t -z -Z -g -N -l -v -r -R -X -S -n -H -i -T -u -U -f
-w -p -c -k -K -O -b -A -j -o -x -F -L -q -V`) with source and target swapped: `-o` applies to the
remote `zfs send`, `-x` to the local receive, `-F` always destroys locally since the target is
always local, and `-R`'s descendant listing runs over ssh when the source is remote. `-q` works as
described under [Quiescing](#quiescing-proxmox-guests): the guest lives on the source, so the
freeze runs there. Three flags exist only here:

| Flag | Meaning |
|---|---|
| `-M` | Mirror (sync relations): after a successful pull, destroy on the target every snapshot the source no longer has that is OLDER than the common base, so the target holds what the source holds. Never the base or anything newer, never a Proxmox-reserved family, and nothing at all when the source list cannot be read or comes back empty. Decided per dataset, so with `-R` every expanded child mirrors its own source. Not with `-r` |
| `-s` | Snapshot-only, no transfer: takes the source snapshot(s) where the source lives (over ssh for `[user@]host:dataset`, locally for a bare dataset) and stops: nothing is sent, received, held, bookmarked, mirrored or created here. For datasets that another mechanism already copies (`pvesr` in a Proxmox cluster) and that only need this relation's own snapshot family. Takes exactly one positional argument (the source list); a target argument and every flag that only shapes a transfer are refused before any ssh or snapshot (`-e -t -M -f -F`, and `-z -Z -g -N -l -A -b -H -i -T -w -o -x -u -U -E`). `-m -j -v -n -r -R -X -S -q -Q -L -p -k -K -O -c` stay. Needs neither mbuffer nor a compressor. `-n` prints one `PLAN=SNAPSHOT-ONLY src=<dataset>` line per selected dataset. Stats status is `snapshot_only` or `snapshot_only_failed`, never `success` |
| `-Q <SECONDS>` | How long the remote deadman waits before thawing unconditionally (default 120, minimum 10). Only meaningful with `-q` |

```bash
snapget.sh -v1 pool/data backuppool/data_backup
snapget.sh -r user@sourcehost:pool/data tank/backups
```

For a pull the remote side is READ and is given literally; the local side gets an optional base.

### Recursion modes

Both walk the full dataset tree with no depth limit. The difference is the unit of work, not the
depth:

- **`-r`**: one atomic `zfs send -R` stream carries the whole subtree and one `zfs recv` lands it
  all at once. All-or-nothing, and a single GUID collision anywhere in the tree (see `-F`) forces
  a full resend of everything, because `zfs send -R -I` decides full-versus-incremental per child
  from the *source's* history, not from what survives on the target. The engines keep no bookmark
  under `-r`, so a source prune that ages out the last common snapshot ends the relation until
  a destructive re-seed.
- **`-R`**: syncoid/sanoid-compatible. It expands the tree into a flat list first, then runs each
  dataset through the normal single-dataset path independently. A failing or colliding child only
  affects itself, and each keeps its own bookmark.

Use `-r` for a single guest's own disks where all-or-nothing is what you want (see
[Quiescing](#quiescing-proxmox-guests)). Use `-R` for a whole subtree of independent datasets
where one dataset's problem should not block the rest. In configs this is the `recursive =` field
(`no`, `flat` = `-R`, `atomic` = `-r`); `-r`/`-R` inside free-form `flags` is a hard error.

**Forgetting both is caught.** Naming a dataset that only holds children (`rpool/data` on a
Proxmox host, say) without `-r` or `-R` sends the parent and nothing else, and *reports success*:
the parent is a real dataset, so the transfer succeeds, the stats log records success and
`check-snap-age.sh` sees a fresh snapshot. Both engines therefore check for immediate children
whenever neither recursion flag is set and warn at verbosity 0 (so also in a default cron run):

```
WARNING: rpool/data has 1 child dataset(s) but neither -r nor -R was given -- only rpool/data
itself is being sent, its children are NOT. Add -R (independent per-dataset jobs) or -r (one
atomic recursive stream) if you meant to include them.
```

It is a warning, not an error, because replicating a parent alone is legitimate. It also fires
under `-n`, since a preview is the best moment to learn the job is aimed at an empty container.

### Filtering the expansion

Under `-r` the subtree is one atomic stream with nowhere to filter, so `-X` and `-S` are
**rejected without `-R`** rather than ignored.

```bash
# Everything under rpool/data except the swap volumes:
snapsend.sh -R -X 'swap' -m daily_ rpool/data user@backup:hdd/backups/src-a

# Only the children; rpool/data itself is an empty container:
snapsend.sh -R -S -m daily_ rpool/data user@backup:hdd/backups/src-a
```

- **`-X <REGEX>`** (syncoid's `--exclude`): an extended regex (`grep -E`), matched **unanchored**
  against the dataset's full name. Repeatable; a dataset is dropped if any pattern matches. In
  `snapget.sh` the name tested is the full **source-side** path, so one regex reads the same in
  either direction. A malformed regex fails before any snapshot is taken.
- **`-S`** (syncoid's `--skip-parent`): send the descendants of each listed dataset, never the
  dataset itself.

**Anchoring matters.** A child's full name contains its parent's, so an unanchored pattern that
matches a parent also matches everything beneath it:

| Pattern | `rpool/swap` | `rpool/swap/inner` |
|---|---|---|
| `-X swap` | excluded | **also excluded** |
| `-X 'swap$'` | excluded | still sent |

Both are legitimate; decide which you meant. Excluding a dataset does not by itself exclude its
descendants, and `zfs create -p` still creates the skipped level on the target as an empty dataset
so a surviving child has somewhere to land.

**Filtering everything out is an error** (exit 1, nothing snapshotted). A typo in a regex, or
`-S` on a dataset with no children, would otherwise exit 0 having sent nothing, which is
indistinguishable from a healthy run in cron.

## delsnaps.sh (retention and pruning)

Two mutually exclusive modes, selected by flag case:

- **Age-based** (lowercase `-y -m -w -d -h`): delete anything older than the summed threshold.
- **Count-based** (uppercase `-Y -M -W -D -H`): keep only the N most recent matching snapshots,
  summed across slots.

```
delsnaps.sh [options] <comma-separated datasets> <pattern> <age or count flags>

Options:
-R                 Recurse into every descendant dataset (each keeps its OWN retention)
-n                 Dry-run: print what would be deleted/kept, destroy nothing
-v, --verbose      Verbose tracing (also DEBUG=1)
-F                 Clear-cut: zfs destroy -R instead of a plain destroy. Cascades to
                   same-named descendant snapshots AND dependent clones. Opt-in; dangerous.
-B                 Bookmark mode: prune orphaned snapsend/snapget bookmarks instead of
                   snapshots (age-based only)
-G                 GFS cascading ladder instead of a flat count sum (count-based
                   -H/-D/-W/-M/-Y only)
-p <PORT>          SSH port for remote datasets
-k <FILE>          Known-hosts file for remote datasets
-c <CIPHER_SPEC>   SSH cipher(s) to request; same as snapsend.sh/snapget.sh -c
-K <FILE>          SSH private key (ssh -i + IdentitiesOnly=yes); same as -K there
-O <SSH_OPTION>    Extra "ssh -o NAME=VALUE", repeatable, placed first; same as -O there
-P <prefix>:<keep> How many of the NEWEST reserved snapshots to protect, per dataset
                   (default: __replicate_/__migration__/vzdump all protected)
-L <LABEL>         The relationship this run belongs to. While it is paused the run
                   exits 0 without destroying anything ("SKIPPED: relationship ... is paused")
-V, --version      Print version and exit
```

A plain destroy refuses to remove a snapshot with dependent clones (a live Proxmox linked-clone
disk, for instance); it is reported and skipped, not silently destroyed. `-F` opts into cascading
when genuinely wanted. Datasets may be remote (`[user@]host:path`; remote only when there is a `:`
with no `/` before it), and local and remote entries can be mixed in one comma-separated list.

**A failed remote listing is a failure, not an empty result.** Any ssh or zfs error while listing
a remote dataset's snapshots or bookmarks (a wrong port, a revoked key, a bogus `-c` cipher, the
host down) exits 1 and alerts like any other broken job, instead of logging "No snapshots found"
and exiting 0, which would let a remote retention job fail silently forever.

```bash
# Age-based, recursive, two datasets:
./delsnaps.sh -R "tank/data1,tank/data2" "backup-" -y1 -m6

# Count-based, single dataset, keep the 12 most recent monthlies:
./delsnaps.sh "tank/data4" "monthly-" -M12

# Preview only:
./delsnaps.sh -n "tank/data4" "monthly-" -M12

# Remote, custom SSH port:
./delsnaps.sh -p2222 "backup@src-a:tank/data" "monthly-" -M12
```

**An empty pattern, or no age/count flags at all, is deliberately unrestricted.** Matching is by
literal string prefix, so an empty pattern matches *every* snapshot on the scope. With no age or
count flag at all, the script defaults to age-mode with threshold = now, which deletes everything
already there. Neither is going to be validated away: this is an admin tool, and an operator who
explicitly asks to prune every snapshot on a scope gets exactly that. Two things survive any
invocation of this kind: `is_protected_snapshot()` (Proxmox's own `__replicate_`, `__migration__`
and `vzdump` snapshots, unless relaxed with `-P`) and a `zfssnapall_inflight` hold (`zfs destroy`
refuses and the snapshot is reported, not silently skipped). Combining an empty pattern with `-F`
makes both the match scope and the destroy method as permissive as they get. What *is* guarded is
the config generator producing this by accident rather than by request; see
[What the generator enforces](#what-the-generator-enforces).

### Reserved-prefix protection

Snapshots named `__replicate_*`, `__migration__*` and `vzdump*` belong to Proxmox itself, and
pruning one out from under `pvesr` breaks the replication chain irreparably, so by default *all* of
them are protected. But absolute protection makes them **immortal**, which is wrong in one place: a
**backup target** that received a replication stream. `-r`/`-H` carry every snapshot on the source,
not just the ones this tool made, so those reserved snapshots land on the target where nothing ever
prunes them, while only the newest has any value for a future incremental. `-P <prefix>:<keep>` (or
`[excluded:<prefix>]` in the config) sets how many of the **newest** to keep, *per dataset*:

```bash
./delsnaps.sh -P "__replicate_:1" tank/backups "__replicate_" -H0   # keep the newest, prune the rest
```

It is **per prefix** (relaxing `__replicate_` leaves `__migration__` and `vzdump` absolutely
protected), **per dataset** (each carries its own replication chain), and it only **relaxes a
guard, never widens a match**: an older reserved snapshot still has to match the run's pattern to
be deleted, so a routine `"automated_hourly_"` job cannot touch one even with protection fully
disabled (`:0`).

### Bookmark pruning

`-B` cleans up the one-bookmark-per-target insurance policy `snapsend.sh`/`snapget.sh` leave behind
(see [Bookmark-backed incremental fallback](#bookmark-backed-incremental-fallback)): when a target
is retired, its bookmark is never touched again and would live forever. `-B` prunes any bookmark
that has not been refreshed within the given age. Pick a threshold safely longer than your longest
real backup cycle, or a paused or offline job's still-valid bookmark gets pruned too early.

```bash
# Prune snapsend/snapget bookmarks untouched for 30+ days, across a whole subtree:
./delsnaps.sh -B -R "tank/data" "tgt-" -d30
```

### GFS cascading ladder

`-G` is for a scope with no naming convention to prune by: snapshots taken with no `-m` (bare
timestamps, see the [`-m` note](#snapsendsh-push-replication)), or any scope where every snapshot
looks alike to prefix matching. The plain count flags **sum**: `-H24 -D7` keeps the 31 newest
snapshots regardless of how they are spread in time. `-G` gives the same five letters a GFS
(Grandfather-Father-Son) meaning: each becomes its own non-overlapping tier of a cascading tower,
walked in a fixed order, each tier's coverage starting where the previous one's ends:

| Flag | Tier | Bucket width | Survivor kept |
|---|---|---|---|
| `-H<N>` | Hourly | 1 hour | newest snapshot in that hour |
| `-D<N>` | Daily | 1 day, right after the hourly tier's coverage ends | newest snapshot in that day |
| `-W<N>` | Weekly | 1 week, right after the daily tier ends | newest snapshot in that week |
| `-M<N>` | Monthly | 30 days, right after the weekly tier ends | newest snapshot in that month |
| `-Y<N>` | Yearly | 365 days, right after the monthly tier ends | newest snapshot in that year |

A letter left out simply has no rung (`-H24 -D7` alone is a valid two-tier ladder). An empty bucket
(a gap in the source's own cadence) has no survivor and nothing is invented to fill it. Anything
older than the outermost requested tier, and anything inside a tier that is not that bucket's
survivor, is deleted, subject to the same reserved-prefix and in-flight-hold protections as every
other mode. Under `-R` every descendant gets its own ladder, but all share one "now", computed once
at the start of the run.

```bash
# Thousands of unpruned, unpatterned hourly snapshots. Preview first, always,
# the first time -G touches a real dataset:
./delsnaps.sh -n -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3

# Output looks right? Drop -n and it actually prunes:
./delsnaps.sh -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3
```

`-G` also works with a real pattern: the ladder buckets whatever matches the pattern first. It is
rejected when mixed with age-based lowercase flags, with `-B`, or when given with no
`-H`/`-D`/`-W`/`-M`/`-Y` at all.

## check-snap-age.sh (staleness monitor)

Read-only Nagios-style check: for each dataset, find the newest snapshot whose name (after `@`)
starts with the given pattern and compare its age with warn and crit thresholds. It creates,
sends and destroys nothing.

```
Usage: check-snap-age.sh [-R] [-v] [-L LABEL] [-x PREFIX]... [-p PORT] [-k KNOWN_HOSTS] [-c CIPHER]
                         [-K KEY] [-O OPTION]... <comma-separated datasets> <pattern> <warn> <crit>
```

| Flag | Meaning |
|---|---|
| `-R`, `--recursive` | Also check every descendant dataset, independently, against the same pattern and thresholds |
| `-v`, `--verbose` | Print a status line for every dataset, not only the ones that trip |
| `-L <LABEL>` | The relation the datasets belong to. While it is paused the check exits OK with wording naming the pause: staleness is the expected state of a deliberately stopped backup |
| `-x <PREFIX>` | Repeatable. Snapshots whose name starts with PREFIX are invisible to the monitor: they neither satisfy freshness nor raise it. For passive relations that watch "whatever the foreign system stamps" |
| `-p -k -c -K -O` | ssh port, pinned known_hosts file (strict host-key checking; without `-k`, accept-new), cipher, identity file and extra `-o` options. The same five as `delsnaps.sh`, used for remote entries |
| `-V`, `--version` | Print version and exit |

A dataset entry may be `[user@]host:dataset` and is then read over ssh on that host (read-only:
`zfs list` and `zfs get` only; the ssh is non-interactive and time-bounded). The monitor runs on
the host that owns the *schedule*: for a remote-snapshots relation that is the collector,
whose cron takes the snapshots on the source, so the source is where the snapshots are and the
collector is where they are checked. Thresholds are `<N><unit>` with unit `m`/`h`/`d` (for example
`90m`, `3h`, `9d`); crit must be at least warn.

**Exit codes** (the worst across all datasets checked): `0` OK, `1` WARNING, `2` CRITICAL,
`3` UNKNOWN. UNKNOWN means the check itself could not answer (bad arguments, missing `zfs`,
nonexistent dataset, a failed ssh or listing) and is deliberately distinct from "the answer is
bad", so a broken monitor does not read as "everything is fine". Every read is checked: a failed
snapshot list or a failed `-R` walk is UNKNOWN, never an empty success. CRITICAL outranks UNKNOWN
in the final exit code, and every finding is also written to stderr. A dataset with **no** matching
snapshot is judged by the age of the *dataset itself* through the same warn/crit ladder, so a guest
created after the last scheduled run is not reported as a stale backup of something that never had
the chance to have one; a dataset whose creation time cannot be read is UNKNOWN.

```bash
./check-snap-age.sh "rpool/data/vm-106-disk-0" "automated_hourly" 90m 3h
./check-snap-age.sh -R "hdd/backups/src-a" "automated_daily" 30h 48h
./check-snap-age.sh -p 2222 -K /etc/zfs-backup-id_ed25519 "backup@src-a:tank/data" "automated_hourly" 90m 3h
```

## gen-cron.sh (config-driven cron generator)

Reads one INI-style config file and emits the crontab block that drives
`snapsend.sh`/`snapget.sh`/`delsnaps.sh`/`check-snap-age.sh` for that host, with no hand-written cron
lines. `--install` is idempotent: it replaces its own previously generated block rather than
appending. On a managed host `zfs-backup.sh` writes the config and calls the generator for you
(`zfs-backup.sh show-config NAME` prints the config that holds a relation and
`zfs-backup.sh edit-config` edits it with validation); calling `gen-cron.sh` directly is the way for
a hand-written config. For ready-to-run expert configs see
[CONFIG-EXAMPLES.md](CONFIG-EXAMPLES.md).

### Options

```
Usage: gen-cron.sh [-c CONFIG] [--install] [--uninstall] [--reconcile] [--migrate-recursion] [-V] [-h]
```

| Option | Meaning |
|---|---|
| `-c <FILE>` | Config file (default `jobs.<hostname -s>.conf` next to the script) |
| `--install` | Install or replace the managed block in this user's crontab. Without it the block is printed to stdout for review |
| `--uninstall` | Remove the managed block and stop. Needs no `-c`: the usual reason is that the config is gone or wrong. Removes the schedule only, never the config or the datasets |
| `--reconcile` | Read-only: compare what the config backs up against what exists on this host and exit non-zero if a dataset has no SEND job. A dataset with only a prune rule is being trimmed, not backed up. Answers the failure where a guest created after the config was written ran with zero snapshots because nothing compared the two. Needs `zfs` on this host |
| `--migrate-recursion` | Rewrite a config that spelled recursion as `-r`/`-R` inside a free-form `flags` into the section's own `recursive =`, and show the before and after crontab so the result can be diffed before it is installed. A one-off migration |
| `-V`, `--version` | Print version and exit |
| `-h` | Print help |

Every schedule field (`send_schedule`, `prune_schedule`, `monitor_schedule`, and the
`schedule` of `[prune-bookmarks:]`) must be exactly five crontab fields, each in range; the
`@daily`-style shorthands are not accepted. **Unknown field names are rejected** in every section
type, so a typo cannot generate cleanly and do nothing.

### Relation blocks: what the tool writes

A relation is one `[relation:NAME]` block that carries its whole policy: the tiers, their
retention and the schedules of each side. The relation's `[dataset:]` and `[prune:]`
sections point at it with `relation = NAME` and say which side they are on with `side`. This is
what `zfs-backup.sh` and the GUI write; you normally read these blocks, not write them. A
collector config for one source with one dataset (example):

```ini
[relation:src-a]
	tiers = hourly, daily
	hourly.target_send_schedule = 1 * * * *     # values from the template;
	hourly.prune_schedule = 21 * * * *          # the minutes of each dataset below
	hourly.target_prefix = automated_hourly_    # are spread from these
	hourly.pattern = automated_hourly
	hourly.retain = -H24
	hourly.monitor = 90m 150m
	daily.target_send_schedule = 11 1 * * *
	daily.target_prefix = automated_daily_
	daily.target_retain = -D30
	daily.source_retain = -D5

[dataset:hdd/backups/src-a/hdd/data]           # the copy, on the collector
	relation     = src-a
	side         = target
	send_schedule_hourly = 13 * * * *           # this dataset's own minute
	send_schedule_daily = 23 1 * * *
	prune_schedule_hourly = 33 * * * *          # pruning of the COPY: send minute + 20
	prune_schedule_daily = 43 1 * * *
	# src, pair_label and flags are written by the tool

[prune:zfsbackup-collector@10.0.0.9:hdd/data]  # pruning of the SOURCE, over ssh
	relation     = src-a
	side         = source
	prune_schedule_hourly = 53 * * * *          # pruning of the SOURCE: send minute + 40
	prune_schedule_daily = 3 2 * * *
```

The second and third sections matter: a backup also creates snapshots on the source, and without
the `side = source` prune the source pool grows without bound.

The rules:

- Block keys are `tiers` (comma list, finest first), `gfs` (optional, every tier feeds one GFS
  ladder), the engine settings `history compression cipher autotune raw` (they live in the block
  only; setting one in a section as well is refused), and the per-tier keys `<tier>.<field>`.
- `<field>` is any template field (`send_schedule prune_schedule prefix pattern keep retain
  quiesce notify_word tier_label monitor_warn monitor_crit monitor_schedule gfs ...`) plus
  `monitor` (= `monitor_warn monitor_crit`, two durations: warn then crit). `<tier>.target_<field>`
  applies to the target side only and `<tier>.source_<field>` to the source side only; a
  side-specific spelling wins over the plain one. `<tier>.target = no` or `<tier>.source = no`
  switches the tier off on that side.
- `side` is always stated, never guessed: `side = target` for the copies, `side = source` for the
  originals. (A local relation's source retention is a `[prune:<source path>]` with no `@`, and
  it is still the source.)
- A section takes its tiers from one place: `relation` and `use_template` in the same section is
  refused, a block that no section points at is refused, and a section whose `pair_label` names a
  different relation is refused. A tier defined in a block cannot also exist as a
  `[template:]` section.
- Each dataset and each relation gets its own free minute on the collector (picked once, at
  creation, from a hash of the name and then the first minute the host does not use yet); target
  prunes run send minute + 20 and source prunes send minute + 40. Per-section
  `send_schedule_<tier>` and `prune_schedule_<tier>` override the block's values.
- `zfs-backup.sh show-tiers NAME`, `set-tiers` and `edit-relation` read and change these blocks.

### Section types

A header is always `[type:name]`, split on the first `:`, except `[defaults]`.

| Section | Purpose |
|---|---|
| `[defaults]` | `host_label` (used in notify text), an optional default `dst`, the five paths that end up in every generated line (`repo_dir`, `notify_script`, `warn_script`, `digest_script` (`none` emits no digest line), `cron_log`; all absolute, each overridden by the upper-case environment variable of the same name; set them when the jobs do not run as root), and defaults for the tier fields `send_schedule prune_schedule prefix pattern dst src autotune quiesce monitor_schedule gfs_pattern`. Retention, thresholds and notify wording are per tier and are refused here |
| `[relation:<name>]` | One relation's whole policy; see above |
| `[template:<tier>]` | One tier's full cadence and retention policy: `send_schedule`, `prefix`, `prune_schedule`, `pattern`, `keep` or `retain`, `monitor_warn`/`monitor_crit`, `monitor_schedule`, `notify_word`, `tier_label`, `notify_raw`, ... Hand-written configs and profiles use these |
| `[dataset:<path>]` | A dataset you own end to end. `use_template` or `relation`, plus per-dataset fields. Runs create(+send/pull) and an inline self-prune scoped to its own path (or its subtree with `recursive`). `dst` makes it a push (the section path is the local source), `src = [user@]host:path` makes it a pull (the section path is the local destination and must end with `path` verbatim); both on one section is rejected. Also: `flags` (identity only: `-K -k -O -p`), `flags_<tier>`, `send_schedule_<tier>`, `prune_schedule_<tier>`, `quiesce`, `autotune`, `pair_label`, and the link and scope fields `bandwidth`, `compression`, `cipher`, `history`, `raw`, `passive` (adopt the newest existing snapshot, `-e`), `exclude_family` (`-E`), `exclude_child_<n>` (`-X`, numbered from 1), `media`, `prune_foreign` |
| `[prune:<scope>]` | Standalone additive prune for scopes you do **not** create locally (a backup store, the source of a pull). `recursive=`/`clear_cut=` opt in to `-R`/`-F`; `prune = no` makes the section a monitor carrier only; `ssh_flags` for a remote (`host:path`) scope; `gfs = yes` plus `gfs_pattern` combine all tiers into one `-G` ladder. A `[prune:]` never sends, so transfer fields are refused |
| `[snaponly:<[user@]host:dataset>]` | Snapshots on a remote source, taken by `snapget.sh -s`, nothing copied. The section name is the source. Tiers come from `use_template`; `pair_label` is required; also `recursive`, `notify`, `notify_raw`, `ssh_flags`. A target, engine flags or target-side prune fields are refused. The source's retention is a `[prune:<scope>]` with `side = source` |
| `[replica:<name>]` | Another copy of a dataset this host already holds, usually onto a removable disk. `source` (local datasets, comma list), `dst` (a base dataset on the medium, never a pool root and never remote), `schedule`, `prefix` or `passive = yes`, `media = removable`, `media_guids`, `on_insert`, `recursive`, `keep`, `history`, `raw`, `flags`, `notify`, and `monitor`/`monitor_warn`/`monitor_crit`. The name only labels the medium; a source may have several replicas |
| `[excluded:<prefix>]` | How many of the **newest** snapshots carrying a Proxmox-reserved prefix to protect, per dataset: `keep = <N>` or `keep = all`. Emits `-P` onto every snapshot-prune line |
| `[prune-bookmarks:<scope>]` | Age-based cleanup of orphaned bookmarks: `schedule`, `age` (raw `delsnaps.sh` age flags, required), `pattern` (default `tgt-`), `recursive`, `ssh_flags` for a remote scope, `notify` |

There is no separate `[monitor:]` section. A staleness check is derived automatically wherever a
tier's `pattern` already resolves for pruning, as long as that tier also sets
`monitor_warn`/`monitor_crit` (both or neither, and `pattern` is required). It reuses the same
scope and recursion the prune needed. On a remote `[prune:]` scope the check runs over ssh with
that section's `ssh_flags` (see `check-snap-age.sh`); a read that fails is the monitor's UNKNOWN
("monitor BROKEN"), never a quiet OK. Where the same tier also sends, `monitor_warn` must be longer
than that tier's longest gap between runs (the generator walks a real calendar over
`send_schedule`: weekly is 7 days, monthly 31, Monday to Friday 72 hours); a threshold at or below
it alarms on a healthy job every cycle and is refused.

**`ssh_flags = <-p/-k/-c/-K/-O only>`** gives a `[prune:]` or `[prune-bookmarks:]` section's remote
scope `delsnaps.sh`'s ssh options (port, known_hosts, cipher, private key, extra `-o`). It is
deliberately narrow: `-R`/`-F`/`-B`/`-n` are rejected because they have their own field
(`recursive=`/`clear_cut=`) or section type (`-B` is what `[prune-bookmarks:]` is). On a scope with
no `:` it is a warning, not a rejection. The use for `[prune-bookmarks:]`: a `snapget.sh` pull's
bookmarks accumulate on the *remote* source, so cleaning one up needs to reach that host. Two
remote scopes that share schedule, pattern, age and recursion but have different `ssh_flags` do
**not** merge into one line.

### Hand-written configs with templates

`[template:]` sections with `use_template` remain valid in hand-written configs (they cannot be
mixed with `relation` in one section). Profiles under `profiles/` use them too. This example pushes
two tiers from one host:

```ini
[defaults]
host_label = src-a
dst        = hdd/backups/src-a

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
gen-cron.sh -c jobs.src-a.conf              # print the generated block for review
gen-cron.sh -c jobs.src-a.conf --install    # install it into this user's crontab
```

A remote prune section in the same style:

```ini
[prune:root@10.0.0.9:hdd/pulled]
use_template = hourly
ssh_flags    = -p 2222 -k /etc/zfs-known-hosts -K /etc/zfs-backup-id_ed25519
notify       = pulled
```

### What the generator enforces

- `flags="-f"` and `flags="-n"` are **rejected**: neither makes sense as a standing recurring job
  (destroy-and-reseed every run, or never send anything). `-r`/`-R` inside `flags` is also an
  error; use `recursive =`.
- `-A` is added automatically to every send whose resolved `dst` is remote (contains `:`), unless
  `flags` already sets `-A` or names a compressor explicitly, or `autotune = no`.
- `-z`/`-Z`/`-g` on a resolved **local** `dst` produces a stderr warning (never fatal), since local
  sends already drop compression.
- Every resolved prune operation is cross-checked against every other one on the *same* literal
  scope: since `delsnaps.sh` matches by literal prefix, one tier's pattern being a prefix of
  another's would let its snapshots leak into the wrong retention run, so it is rejected.
- **A key present but blank is treated exactly like an absent key** for `prefix`, `pattern` and
  `retain`/`keep`. An empty `pattern` would make `delsnaps.sh` match every snapshot on the scope,
  and an empty `retain` would produce a line with no threshold flag, which defaults to age-mode with
  threshold = now and deletes nearly everything. `[prune-bookmarks:]`'s `pattern` is the one
  exception: a blank value falls back to its default `tgt-`. `dst` keeps its legitimate blank
  meaning (no target, snapshot only).
- The yes/no fields (`recursive`, `clear_cut`, `gfs`, `prune`, `passive`, ...) accept only `yes` or
  `no`, in any case; anything else is an error rather than a silent "no".
- Datasets that share a resolved `(send_schedule, dst, prefix, flags)` merge into one send line,
  and datasets that share a resolved `(prune_schedule, pattern, keep/retain, recursive)` merge into
  one prune line that lists them by full path. Recursion is never inferred from a shared parent,
  and pull datasets never merge. Disks of two different guarded PVE guests never share a line (the guest
  guard below).
- **PVE guest guard (`pve_guest_guard`, `pve_node`).** A line that creates or prunes snapshots on
  a guest's disk (`vm-N-disk-M`, `subvol-N-disk-M`) at its source (a push without `-e`, a pull, a
  `[snaponly:]` and the prune of those same datasets) carries `--pve-guests=<host>:<id>`. Before
  the engine runs, `zfs-job.sh` looks up `/etc/pve/nodes/<node>/{qemu-server,lxc}/<id>.conf` to see
  where the guest runs. On another node of this cluster: the command does NOT run, END `rc=76`,
  alarm (the disk here is a pvesr replication target). Not a PVE cluster member, or the guest is
  defined nowhere: runs as before. A source host given by an address that cannot be mapped to a
  node (a delegated account cannot read `corosync.conf`): runs, and WARNs when the guest is in
  this cluster; `pve_node = <node>` in
  the `[snaponly:]`/`[dataset:]` (pull) section settles it. On by itself; `pve_guest_guard = no`
  in `[defaults]`, `[dataset:]` or `[snaponly:]` turns it off. Passive copies (`-e`) and backup
  targets are not checked.
  **Trees** (1.0.1): a recursive line over a parent that is no guest disk (`rpool/data`,
  `hdd/vm-disks`) carries `--pve-guests=<host>:tree`, and the config keeps its one entry. At run
  time `zfs-job.sh` lists the SOURCE tree (`zfs list -r`; a remote tree over the line's own ssh
  options), reads the guest id from each disk name (`vm-`/`subvol-`/`base-N-disk-M`) and where
  that guest runs. A disk whose guest runs on another node is a pvesr replica: a `-R` snapshot
  (one snapshot per dataset) runs with `-X` on exactly that disk and WARNs; a prune or an atomic
  `-r` cannot leave a child out and is NOT RUN (`rc=76`, alarm). A remote tree that cannot be
  listed runs as before and WARNs. The target of a copy is never read.
- `recursive` drives all three generated lines from one declaration: `no` = this dataset,
  `flat` = `-R` on the transfer, `delsnaps -R`, `check-snap-age -R`; `atomic` = `-r` on the
  transfer with the same `-R` prune and monitor.
- Every command in a generated line redirects its own stderr to the cron log, the notify calls
  included, because cron mails whatever a job writes to stdout or stderr. Anything you add to such
  a line needs its own redirect.

### Monitor-only prune sections

`prune = no` gives a monitor without a second prune. A recursive `[prune:hdd/backups]` already
covers every leaf underneath it, but monitor thresholds are per tier and a leaf that matters more
than its siblings wants its own. Adding `[prune:hdd/backups/src-a/nextcloud]` just to hang
`monitor_warn`/`monitor_crit` on it looks like a harmless duplicate, but the two `delsnaps.sh`
lines fire in the same minute and **race**: the loser finds the snapshot already gone and exits
non-zero with `could not find any snapshots to destroy` plus a misleading hint about dependent
clones. `delsnaps.sh`'s own `flock` does not catch it, because the lock key hashes the dataset
list and pattern, and the two lines legitimately differ (`-R parent` versus an explicit leaf).

`prune = no` emits no `delsnaps` line and keeps the monitor. It is rejected if the section then has
no `monitor_warn`/`monitor_crit`, since it would emit nothing. The cross-check above only compares
patterns on the *same literal scope*; containment across scopes stays your discipline. If a
`delsnaps` job reports "could not find any snapshots to destroy" on a schedule, look for a second
prune line whose scope contains that dataset at the same minute before chasing clones or holds.

### GFS ladder in a prune section

A `[prune:]` scope backing a dataset with no naming convention of its own (see
[GFS cascading ladder](#gfs-cascading-ladder)) would otherwise need one tier per rung, each emitting
its own flat `delsnaps.sh` line. `gfs = yes` combines every tier in `use_template` into one
`delsnaps.sh -G` line:

```ini
[template:store_hourly]
prune_schedule = 51 * * * *
pattern        = automated_hourly
retain         = -H24
monitor_warn   = 90m
monitor_crit   = 3h

[template:store_daily]
prune_schedule = 53 0 * * *
pattern        = automated_daily
retain         = -D7

[template:store_weekly]
prune_schedule = 55 0 * * 0
pattern        = automated_weekly
retain         = -W4

[prune:backup/store]
use_template = store_hourly,store_daily,store_weekly
recursive    = yes
gfs          = yes
gfs_pattern  = automated_
notify       = store
```

This generates one prune line, on the first-listed tier's own schedule, instead of three:

```
51 * * * * ... delsnaps.sh -G -R "backup/store" "automated_" -H24 -D7 -W4 ...
```

Each tier's own `retain` must resolve to exactly one count flag (`-H`/`-D`/`-W`/`-M`/`-Y` followed
by a number); an age-based `retain=` or a multi-flag string is rejected under `gfs = yes`.
`gfs_pattern` is a *separate* field from each tier's `pattern`: the per-tier `pattern` keeps
driving that tier's own monitor, while `gfs_pattern` is the wider net the combined ladder needs to
see every contributing tier's snapshots. Every tier's `pattern` must start with `gfs_pattern`;
omitting the field gives the prefixless ladder. A tier with `prune = no` is skipped from the
combined ladder but keeps its monitor.

## Alerting

**Configurable per host, defaulting to one mail per day.** Every finding is recorded to a queue and
`alert-digest.sh` mails a single grouped summary once a day; if you ask for it, each finding mails
the moment it happens instead. A finding travels exactly one of the two paths, so it is never
reported twice. The mail text is in Polish.

### Choosing the cadence

One file, `/etc/zfs-alert.conf`, sourced by the alert scripts as plain shell (the old location
`/root/scripts/zfs-alert.conf` is still read as a fallback). **`ZFS_ALERT_MODE` is the variable to
change.**

| Variable | Default | Meaning |
|---|---|---|
| `ZFS_ALERT_MODE` | `daily` | `daily` = queue every ALERT, one summary mail per host per day. **`immediate` = mail each ALERT as it happens** |
| `ZFS_WARN_MODE` | `daily` | The same choice for WARNING-tier findings, set separately |
| `ZFS_ALERT_EMAIL` | set at deploy time | Where alerts go; changes all the scripts at once |
| `ZFS_ALERT_COOLDOWN` | `14400` (4 h) | `immediate` only: seconds before the *same* message may mail again. Ignored in `daily` (the digest de-duplicates by counting) |
| `ZFS_ALERT_STATE_DIR` | `/var/lib/zfs-snapshot-all/notify-state` | `immediate` only: where the cooldown timestamps live |
| `ZFS_ALERT_QUEUE` | `/var/lib/zfs-snapshot-all/alert-queue.log` | `daily` only: the queue the digest consumes |
| `ZFS_DIGEST_DAYS` | `7` | How many days of runs the digest's table covers. Independent of how often the mail is sent |
| `ZFS_DIGEST_QUIET` | `mon` | When a host with NOTHING to report still mails its full periodic report: `mon`..`sun`, `monthly` (the 1st), `1`..`28` (that day of the month), `daily`, or `off`. A day with findings always sends. `off` costs the guarantee that silence means a dead channel |

**Precedence**, highest first: the environment, then `settings.ini`, then `zfs-alert.conf`, then
the defaults above. The environment beating the file is what makes
`ZFS_ALERT_QUEUE=/tmp/q ./alert-digest.sh` a safe way to try things. `settings.ini`
(`/etc/zfs-snapshot-all/settings.ini`, edited with F10 in the GUI) maps onto these variables:

| `settings.ini` | Variable |
|---|---|
| `[alerts] email` | `ZFS_ALERT_EMAIL` |
| `[alerts] errors` | `ZFS_ALERT_MODE` |
| `[alerts] warnings` | `ZFS_WARN_MODE` |
| `[alerts] all_ok_mail` | `ZFS_DIGEST_QUIET` |
| `[alerts] stats_days` | `ZFS_DIGEST_DAYS` |
| `[alerts] repeat_after` | `ZFS_ALERT_COOLDOWN` (a number of seconds, or `30m`, `4h`) |
| `[capacity] threshold` | `ZFS_CAPACITY_THRESHOLD` |
| `[capacity] guard`, `guard_at`, `guard_target`, `guard_min_keep` | `ZFS_GUARD*` (capacity guard) |
| `[growth] alert`, `factor`, `min_mib`, `max_ratio_pct`, `days` | `ZFS_GROWTH_*` (growth guard) |

`deploy.sh` writes `/etc/zfs-alert.conf` once with every key documented and never overwrites it,
so a hand-edited mode survives every re-run and upgrade; a host provisioned before a key existed
still accepts it, only the comment is missing.

```bash
sed -i 's/^ZFS_ALERT_MODE=.*/ZFS_ALERT_MODE=immediate/' /etc/zfs-alert.conf
```

**Set `immediate` while bringing a host up.** A job you misconfigured today is a five-minute fix
if you hear about it within the hour, and a lost night of backups if you read about it in
tomorrow's digest. Provision it that way with `bash deploy.sh --alerts=immediate`, then switch to
`daily` once the host has run clean for a few days.

The config lives in `/etc` and the queue under `/var/lib/zfs-snapshot-all/` (`2775 root:zfsalert`,
setgid) rather than in `/root/scripts`, because `/root` is `0700`: a delegated non-root account
cannot read or write anything under it. Opening `/root/scripts` to a group instead would be a
privilege escalation, since root executes those scripts from cron. The shared directory therefore
holds only data; the scripts stay private to each account, and deploy gives the service account
its own copies of `notify-fail.sh` and `notify-warn.sh` pointed at the same queue.
`alert-digest.sh` is not duplicated: it runs as root over the shared queue, so the host still
sends one mail a day covering both accounts. The digest's *schedule* is a cron line emitted by
`gen-cron.sh` (`DIGEST_SCHEDULE`, default `0 7 * * *`).

**Why `daily` is the default.** With immediate mail, the cooldown is keyed on the *message*, so
every distinct finding keeps its own counter, and two jobs failing in the same cron tick send two
mails in the same second. Volume scales with the number of distinct findings rather than with the
number of hosts, and across a fleet that is a stream an operator starts filtering away, which is
worse than one daily summary that gets read. The cost is that an urgent finding waits until the
digest runs. That does not apply to hardware: Proxmox's own ZED pool-health mail is a separate
mechanism this project does not touch, so a disk dropping out still pages immediately. A silent
day means "nothing was queued", not "healthy", since a dead cron is also silent; a periodic "all
OK" mail (`ZFS_DIGEST_QUIET`) exists for that reason.

### Queue, digest and notify scripts

These scripts live in [`hostscripts/`](../../hostscripts) and `deploy.sh` installs them by copying,
so "current" means byte-identical to the checkout. `gen-cron.sh` wires the first two straight into
every generated monitor line (`[ $rc -eq 1 ] && notify-warn.sh ...; [ $rc -eq 2 ] &&
notify-fail.sh ...; [ $rc -ge 3 ] && notify-fail.sh ...`).

| Script | Records | How |
|---|---|---|
| `notify-fail.sh` | Any job returning non-zero (`snapsend`/`snapget`/`delsnaps` failure), `check-snap-age.sh` CRITICAL/UNKNOWN, or a pool that is not ONLINE | `daily`: appends `epoch<TAB>ALERT<TAB>label<TAB>detail` to the queue and sends no mail. `immediate`: mails at once, rate-limited per message |
| `notify-warn.sh` | `check-snap-age.sh` WARNING (getting stale, not yet CRITICAL) | The same queue with severity `WARN`, per `ZFS_WARN_MODE` |
| `alert-digest.sh` | | The only backup mail a host sends in `daily` mode. Once a day it mails one message whose subject is `[ZFS] <host> <date> STAN: OK\|UWAGA -- N alert / M warn`. The first block is the state *now* (pools, and a table of the jobs over the `ZFS_DIGEST_DAYS` window); the second is what *happened*: ALERT findings first, then WARNING findings, each followed by what the finding actually said. A quiet day uses a different subject (`... cisza, kanal sprawny (raport okresowy)`) so it cannot be mistaken for a findings mail. If `mail` fails, the findings are put back on the queue and it exits non-zero |
| `check-pool-capacity.sh` | A pool, or a dataset with a refquota, approaching full, ahead of any job failing from it. Reports through `notify-fail.sh` and so arrives in the same digest | Cron, default threshold 90% (`ZFS_CAPACITY_THRESHOLD`) |
| `capacity-guard.sh` | Optional (default `off`): when a pool crosses `ZFS_GUARD_AT` (default 89%), deletes only snapshots that are safe to delete: ones this host's own local `delsnaps` lines own, never held, never the newest snapshot of a dataset. Any uncertainty means deleting nothing | `[capacity]` in `settings.ini` |
| `growth-guard.sh` | Optional (default `off`), alert only: flags an increment that is a multiple (`ZFS_GROWTH_FACTOR`, default 5) of the dataset's recent norm while being poorly compressible, the signature of mass file encryption. Deletes and pauses nothing | `[growth]` in `settings.ini` |

**What a finding carries.** A label alone (`src-a hourly getting stale (vm-archive)`) is a string
from your config: it identifies the job and nothing else. So the finding travels with the text the
job or the monitor actually produced: monitors pass `check-snap-age.sh`'s verdict line (dataset,
pattern, newest snapshot, age, thresholds) and failed jobs pass the last 8 lines of their stderr
(still appended to `cron.log`). The queue has four tab-separated columns (epoch, severity, label,
detail); older three-column lines show without detail. A finding stays one line so concurrent
appends stay atomic: tabs in the detail become spaces and newlines become `\001`, which the digest
turns back into newlines. The detail shown is from the **last** occurrence, because for something
firing every fifteen minutes the most recent reading describes the state now. As a side effect, a
job's output reaches `cron.log` as one contiguous block when it finishes, which also stops two
overlapping jobs interleaving their lines.

`notify-fail.sh`, `notify-warn.sh` and `alert-digest.sh` read the shared preamble
`hostscripts/alert-env.sh`, which `deploy.sh` installs beside them.

### Pool health

`snapsend.sh`/`snapget.sh` check the ZFS pool backing every dataset they touch via
`check_pool_health()` in `lib-zfs-snap.sh`: the always-local side unconditionally, and the remote
side too whenever the transfer is remote, over the connection the transfer already opens. A pool
that is not `ONLINE` is reported through `notify-fail.sh` (so, in `daily` mode, it is queued for
the digest like any other ALERT, and in `immediate` mode it mails under the usual cooldown), with
the first lines of `zpool status` as the detail. The check is deliberately independent of the
transfer's exit code: a `DEGRADED` pool with a surviving mirror leg still sends fine, so tying the
alert to transfer success would either hide a real disk failure behind a "job succeeded" exit code
or report a working transfer as failed. Because the check runs from whichever side opens the
connection, one execution reports both ends of a push or pull; the other side needs no pool-health
cron of its own. A peer whose pair gate refuses the relation (`disable-client`) is logged as
"could not be checked" and raises no pool alert: an administrative block is not a storage fault.

### Log rotation

`/etc/logrotate.d/zfs-snapshot-all` (root's logs) and `/etc/logrotate.d/zfs-snapshot-all-<user>`
(the service account's) ship with the deploy script: monthly, keep 24, compressed. There are two
stanzas because of `create`: rotating the service account's logs into a root-owned file would leave
that account unable to append. Neither uses a `*.log` glob, because the alert queue sits in the
same directory and is state, not a log. Retention is long on purpose, since diagnosing a backup
problem means comparing runs weeks apart, and the volume is about 0.1 MB a day.

## deploy.sh (host bootstrap)

One script per host, run as root, idempotent, safe to re-run. It also drives the peer pairing
(`--pair`, `--join`, `--leave`, `--unpair`, `--draft-scope`, `--commit-scope`, and the maintenance
verbs `--pause`/`--resume` and `--self-update`/`--rollback`/`--resume-updates`); those are
normally called for you by `zfs-backup.sh` and are documented in
[DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md) and in `deploy.sh --help`.

```bash
bash deploy.sh                          # host setup; maintains an existing account if found
bash deploy.sh --check-only             # audit the WHOLE host, change nothing
bash deploy.sh --alerts=immediate       # mail every finding; use while bringing a host up
bash deploy.sh --backup-user=zfsbackup  # also CREATE the delegated non-root account
```

Defaults live in a config block at the top of the script (`NOTIFY_EMAIL`, `ALERT_MODE`,
`BACKUP_USER`, `BACKUP_USER_DATASETS`); edit them to make a choice permanent for a host, or pass a
flag for a single run. `--email=ADDR` sets the alert address, and `--test-mail` sends a delivery
smoke test (automatic on first setup only).

**`BACKUP_USER` is about creation, not maintenance.** Left empty, an existing delegated account is
still auto-detected and kept up to date (its notify scripts, log rotation, group membership); only
*creating* one has to be asked for. A bare `bash deploy.sh` is therefore the right command on
every host in the fleet, whether or not it has an account.

- **Steps 1 to 7 (always)** bootstrap a Proxmox/Debian host as **root**: (1) check or install every
  runtime dependency, (2) clone or update the checkout at `/root/scripts/zfs-snapshot-all`,
  (3) the shared alert state, (4) the notify scripts and the digest, (5) capacity alerting,
  (6) a smoke test of the shipped executables plus a live compressor round-trip, and (7) the
  auto-pull cron line. It deliberately does **not** touch your actual `snapsend`/`snapget`/`delsnaps`
  job lines: those are per host and belong to `zfs-backup.sh` or `gen-cron.sh`.
- **Step 8 (optional)** bootstraps a dedicated, delegated **non-root** account (suggested name
  `zfsbackup`) so replication does not need to run as root: a locked-password, SSH-key-only
  account, its own lock and state directory, its own checkout and auto-pull cron line, and `zfs
  allow` delegation on the datasets given with `--grant-datasets` (alias `--datasets`; default
  `rpool/data rpool/ROOT/pve-1`, the stock Proxmox layout; override it on any host that departs
  from it). Delegation on a dataset (a plain `zfs allow`, not `zfs allow -d`) also covers descendants that
  do not exist yet,
  so new VM/CT disks created later under `rpool/data` inherit it. `--allow-quiesce` additionally
  lets that account freeze the guests whose disks live under those datasets; `--revoke-quiesce`
  removes it.

  On Linux, a delegated `mount` permission still cannot mount or unmount without
  `CAP_SYS_ADMIN`. Routine incremental replication is unaffected, and since every level of a target
  path (not only the leaf) is created `canmount=noauto`, the account can bootstrap a brand-new
  multi-level target from scratch. What still needs root: `-f`, and `-F` against a currently
  mounted target or clone; both print a hint pointing here when they fail for that reason.

  **Paths follow the account.** Run as non-root, `STATS_LOG`, `NOTIFY_SCRIPT` and `LOCKDIR` default
  to `$HOME/zfs-snapshot-stats.log`, `$HOME/notify-fail.sh` and `$HOME/run` instead of their
  counterparts under `/root`, which is `0700`. An explicit environment variable still wins. In a
  `gen-cron.sh` config, set `repo_dir`, `notify_script`, `warn_script`, `digest_script` and
  `cron_log` in `[defaults]` for the same reason.

  ```bash
  bash deploy.sh --backup-user=zfsbackup                        # default datasets
  bash deploy.sh --backup-user=zfsbackup --datasets="rpool/data tank/vm"
  ```

## Worked scenarios

### 1. From zero to a running hourly/daily schedule with a hand-written config

This is the manual route; the normal route is `zfs-backup.sh` (see
[DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md)).

```bash
# On the new host, as root:
bash deploy.sh

# Write /root/scripts/zfs-snapshot-all/jobs.$(hostname -s).conf (see the template
# example under gen-cron.sh), then:
cd /root/scripts/zfs-snapshot-all
./gen-cron.sh -c "jobs.$(hostname -s).conf"           # review the generated block
./gen-cron.sh -c "jobs.$(hostname -s).conf" --install # install it
crontab -l                                            # confirm the managed block landed
./gen-cron.sh -c "jobs.$(hostname -s).conf" --reconcile  # does every dataset have a send job?
```

`gen-cron.sh` has already added `-A` to remote send lines and rejected any `-f`/`-n` typed into
`flags`. The staleness checks for every tier that set `monitor_warn`/`monitor_crit` ride the same
crontab block.

### 2. Remote push with compression, autotune and guest quiescing

A VM disk, replicated to an off-site host, guest-quiesced for a clean point-in-time image:

```bash
./snapsend.sh -q agent -A rpool/data/vm-107-disk-0 backup@offsite.example:tank/backups/src-a
```

`-A` measures the real link to `offsite.example` and this dataset's compressibility before
deciding whether to compress. `-q agent` freezes VM 107 through its qemu-guest-agent for exactly
the `zfs snapshot` call and thaws it before the transfer starts, so the freeze never overlaps the
(potentially much longer) send. If the freeze fails, the snapshot is still taken, named
`..._crash_...`, and the run exits 8; add `,strict` (`-q agent,strict`) to refuse instead.

### 3. Pull replication as a non-root delegated user

On the collector, one command creates the delegated account, delegates the target to it, pairs
with the source and installs the jobs into that account's crontab:

```bash
./zfs-backup.sh --source=src-a:rpool/data --target=hdd/backups --local-user=zfsbackup --install
```

Keys and the pinned host key are exchanged by the pairing, not manually. The account has `zfs allow`
delegation on the target (and everything created under it later), so it receives incrementals
without root, including a brand-new multi-level target path; `-f`, or `-F` against a mounted
clone, still needs root. To run a job manually as that account, copy the engine command from
`crontab -l -u zfsbackup`: the line carries the `-K` and `-k` it needs, and runs exactly as cron
runs it.

### 4. Surviving a rename (GUID matching)

```bash
./snapsend.sh -e tank/data backup/tank/data     # first sync: lands @a

zfs rename backup/tank/data@a backup/tank/data@archived   # admin tidies up the target
zfs snapshot tank/data@b

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

The name-based fast path finds no match (the target has no snapshot literally named `@a`), but the
GUID fallback recognizes `@archived` as the same snapshot by ZFS identity, so this stays a genuine
incremental (`@archived` survives, `@b` is appended) and not a `-f`-style rollback that would wipe
`@archived` off the target.

### 5. Recovering from a source snapshot pruned too early

```bash
./snapsend.sh -e tank/data backup/tank/data     # sync #1, bookmark refreshed for this target

zfs destroy tank/data@a                         # delsnaps.sh (or a human) prunes the source snapshot
zfs snapshot tank/data@c

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

With `@a` gone from the source, the name and GUID fast paths find nothing in common, but
`find_bookmark_base()` locates the refreshed `tank/data#tgt-<hash>` bookmark, whose GUID matches
the target's current head, and sends `-i <bookmark> @c` instead of falling back to a full resend.

### 6. Two independent schedules landing in the same target

```bash
./snapsend.sh -e -j hourly  tank/data backup/tank/data
./snapsend.sh -e -j offsite tank/data backup/tank/data
```

Without `-j` these would share one lock (so an overlap serializes rather than races, which is
correct on its own) and one bookmark (so whichever job ran last would silently become the only one
with a valid incremental base). With distinct tags each job has its own lock and its own
`tgt-<hash>` bookmark, so both can be relied on independently.

### 7. Cleaning up bookmarks from a retired target

A VM was decommissioned three months ago; its bookmark on the source has sat untouched since. In
the config:

```ini
[prune-bookmarks:tank/data]
schedule  = 0 4 * * 0
age       = -d30
recursive = yes
```

`gen-cron.sh --install` turns this into a weekly `delsnaps.sh -B -R "tank/data" "tgt-" -d30`:
anything not refreshed in 30 or more days (comfortably longer than any real backup cycle) is
pruned.

### 8. An interrupted transfer resumes on its own

A large initial send to a remote host drops mid-stream (network blip, host reboot):

```bash
./snapsend.sh tank/data user@host:backup/tank/data   # dies partway through
```

The target is left with a `receive_resume_token`. Nothing is needed manually: the *next* scheduled
(or manual) run of the same command detects the token via `get_resume_token()` and resumes with
`zfs send -t <token>`. If it fails to resume 3 times running, the next run gives up cleanly
(`zfs receive -A`, discarding only the stuck partial state) and falls back to a normal incremental
or full send.

### 9. Thinning years of unpatterned snapshots into a GFS tower

A dataset has been snapshotted hourly for months with no `-m` prefix, so `delsnaps.sh`'s
pattern-based pruning has nothing to key off. A flat count-based prune would need one job per
tier; `-G` collapses it into one:

```bash
# Preview first: how many would actually go, and does the shape look right?
./delsnaps.sh -n -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3

# Looks right, run it for real:
./delsnaps.sh -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3
```

The empty pattern (`""`) matches every snapshot on the scope; `-G` only changes what happens to
that matched set. Instead of one flat "keep the 50 newest", the tower keeps 24 one-per-hour, then 7
one-per-day right after that, then 4 one-per-week, 12 one-per-month and 3 one-per-year, each tier
starting where the previous one's coverage ends. A dataset that has really been snapshotting hourly
the whole time ends up close to the flat-count total either way; one with an irregular history (a
burst of extra snapshots on one day, then a week of silence) gets exactly one survivor per bucket
the data actually reached, which is where the two schemes diverge, sometimes sharply. Before
switching a live retention job from flat counts to `-G`, dry-run **both** and diff their "would
delete" sets: on irregular data the tower can claim snapshots a flat count never would have.
