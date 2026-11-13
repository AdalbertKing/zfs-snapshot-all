# Changelog

Every release of this repository is one commit; its message and the `RELEASE-OF` file name the
development revision it was built from. Releases between tagged versions are listed here only
when they change how the tool is used.

## [1.0.21] — 2026-11-13

- **Under `-R`, a quiesced dataset whose window snapshot is missing fails** (REV-20261112-197
  round 5, both engines). Before, a member left empty, fully `-E`-excluded or without the `-m`
  family was skipped as scaffolding and the run reported success without copying it. Also under
  quiesce: a snapshot that disappears after selection fails the dataset; a resumed interrupted
  transfer no longer ends the dataset before the window's snapshot is copied; `-s` checks that the
  window's snapshot exists; `snapget.sh`'s local snapshot-only mode no longer takes a second,
  unfrozen snapshot. Passive runs (no window) are unchanged.
- **A quiesced run copies the snapshot its own window made** (REV-20261112-197 round 4, both
  `snapsend.sh` and `snapget.sh`). Before, it took the newest snapshot of the `-m` family, which
  could be another job's snapshot made between the window and the copy. Such a copy made the
  target depend on a point the other job owns and, with `--source-keep`, later prunes. If the
  window's snapshot is gone before the copy, the run now refuses.

- **An active replica with `keep` keeps only its newest own snapshot on the source** (W5-1; one per medium when it has several). New
  `snapget.sh --source-keep=N`: after a successful pull of the snapshot the run made with `-m`
  (not under `-r`; under `-R` each dataset is pruned on its own), the job's own older snapshots
  (exact `-m` prefix plus the engine's timestamp, or its quiesce crash form) beyond the N newest
  are destroyed on the source, and only those a run of this same target made (the run stamps its snapshot on the source with
  the user property `zfsbackup:srckeep-owner`, naming the target and its pool GUID, so two
  rotating disks of one pool name are two owners; a successful quiesce window's snapshot is
  stamped too) and the target holds (by GUID); a snapshot without
  that stamp (older history, an `-H` seed, one made by hand) is never pruned: with two media
  of one replica, each medium's head stays on the source until that medium's own next run, so
  one medium never takes another's base, even when a bookmark could not be made
  (REV-20261112-197). Other families and other jobs' snapshots are never touched; a
  failed listing or destroy is a warning, not a failed run; `-n` destroys nothing. Refused with
  `-e`, with `-s`, without `-m`, or without `-i`; `snapsend.sh` refuses it (pull-only).
  `gen-cron.sh` passes `--source-keep=1` only to an active replica with `keep = N` that runs
  with `-i` (an explicit `history = all` or `auto:N` gets none); the mirror variant (`-m P -M`)
  does not get it, because under `-M` the medium follows the source, so the pruning would delete
  the medium's copies too.
- **A passive copy never adopts a Proxmox-reserved snapshot** (W5-2). Under `-e` both engines skip
  `__replicate_`, `vzdump` and `__migration__` as the newest/base, with or without `-E`. An `-m`
  that names one of those families (for example `-e -m __replicate_`) opts that family out. A
  dataset with only reserved snapshots now refuses under `-e` ("Every source snapshot on
  '<dataset>' matches an -E exclusion"); under `-R` it is skipped as scaffolding. Reserved
  snapshots already on a medium stay (the mirror never removes a reserved family); remove them by
  hand once.

## [1.0.20] — 2026-11-12

- **A mirror keeps a snapshot that was renamed on the source** (REV-20261112-196). `-M` (sync
  relations, removable replicas) now decides "gone from the source" by GUID. A snapshot renamed
  on either side stays. A snapshot that only shares a name with a source snapshot, with another
  GUID, is not on the source. When either side's GUID list cannot be read, or does not name
  exactly the snapshots of its name list (empty, partial, or changed while read), nothing is
  deleted.
- **The bookmark path keeps the safety checks** (REV-20261112-195):
  - A push onto a sync or exact (`-t`) path whose copy was written to after its newest snapshot
    is refused there too. Before, a bookmark-backed increment skipped that check and `zfs recv -F`
    rolled the write back.
  - When the snapshots between a bookmark and the newest one cannot be listed in full, the run refuses
    and the next run tries again. Before, it sent a single diff and those snapshots never arrived.
  - `-T` applies to an increment from a bookmark too, measured from the bookmark's creation.
- **A release refuses a change no review covers** (`release/coverage-gate.sh`). The gate compares
  the run-time package of the published release (read from the release repo's `origin/main`) with
  the candidate. Every shipped file that changed, was newly shipped or stopped being shipped must
  be reached through submitted review ranges: each response names `implementation:` and
  `<!-- base: <sha> -->`. That includes edits made inside a merge. A file's state is its mode
  and its bytes after the release scrub, so a chmod or a scrub change that rewrites a shipped
  file needs a review as well. A resubmission of the same review keeps its earlier ranges as
  `<!-- submitted: <base> <sha> -->` lines, so narrowing `base:` does not drop earlier work.
- **Attaching a removable replica medium** (REV-20261112-194):
  - A replica source whose name holds `:` (`tank/data:part`) is copied as a local dataset.
    Before, the engine read the part before the `:` as an ssh host, while the media gate
    checked the name as given.
  - A medium is refused as "a different lineage" only when no target snapshot shares a GUID
    with a source snapshot or bookmark. A snapshot renamed on either side counts. Unreadable
    evidence no longer leads to a refusal or to `zfs destroy` advice.
  - A medium imported before the run (by an interrupted run of ours or by an operator) gets
    the same lineage and free-space checks. On refusal an operator's import stays imported.
  - A source tree that cannot be listed in full no longer counts as "no new data", so the copy
    is not skipped on that basis.

## [1.0.19] — 2026-11-12

- **A copy no longer loses snapshots the source pruned while the collector was away.** When the
  target's newest snapshot was gone from the source but an older one was common to both, the
  older one became the base and `zfs recv -F` discarded the newer snapshots on the target, even
  though the source's `tgt-` bookmark still marked them. For a single dataset (not `-r`) the bookmark
  is now the base; the
  increment goes `-i` bookmark → the oldest snapshot after it not excluded by `-E`, then `-I` to
  the newest, so the snapshots made in between arrive too (with `-i`: the single diff only). Proxmox `__replicate_` snapshots are
  never the first step. A dry run (`-n`) plans the same base. The same loss was measured on a
  replica disk that keeps N versions; the same code path serves it.

## [1.0.18] — 2026-11-11

- **A replica disk that comes back after retention gets an increment again** (REV-20261111-B01):
  once the collector's retention had pruned the snapshot the disk holds, the media gate refused
  the disk as "a DIFFERENT lineage", though the source bookmark still anchors the increment.
  The gate now counts a source bookmark with the disk snapshot's GUID as the shared point.
- **A copy killed as a whole leaves no false orphan alarm** (REV-20261111-B01): on
  TERM/INT/HUP the engine closes its own progress records as interrupted (F4: PRZERWANY).
  Before, they stayed "running", and 30 minutes later the pool-capacity check reported an
  orphan.

- **Mail subjects say what kind of mail it is** (U184): `[ZFS][REPORT]` the daily summary,
  `[ZFS][WARNING]` a warning, pool capacity or data growth (formerly `[ZFS CAPACITY]`,
  `[ZFS GROWTH]`), `[ZFS][ALERT]` a failed run. Mail rules matching `[ZFS]` keep working;
  rules matching `[ZFS CAPACITY]` or `[ZFS GROWTH]` need the new subject.
- **GUI, from the lab walk:** F2 opens on the newest finished run once the run history arrives
  (it stayed on the last upcoming run); F4 shows a replica's medium in F6's words -- "WRONG
  DISK" or "CONNECTED" (pool not imported) instead of "medium not connected"; F2 shows a
  source-retention tier as "hourly", not "src_hourly".
- **A quiesced tier of a dataset that is not a guest disk no longer fails every night** (U188):
  the remote quiesce run used to check the account's privileges before looking for a guest,
  so a delegated account without `--allow-quiesce` turned every such snapshot into a `_crash_`
  set with exit 8. With no `vm-N-disk-M`/`subvol-N-disk-M` in scope it now takes a plain
  snapshot and exits 0; a scope with a guest disk is checked as before.
- **The growth guard also watches sources of "snapshots on the source only" relations**
  (U172): on the collector, `growth-guard.sh` reads the remote entries of its retention lines
  and measures the source's increments over ssh with that line's own options (key, known
  hosts, port), under the collector's `[growth]` thresholds; the alarm subject names the source,
  the dataset and the relation. A host with no config of its own has nothing to watch: exit 0,
  no mail (U173; it used to mail "the guard is not working" every hour).
- **A passive local copy fed by pvesr runs after the replica brings the snapshot** (U181):
  `local-backup --passive` moves each tier's copy time to 10 minutes after the pvesr run that
  brings that tier's snapshot (a daily copy at 01:11 behind a `*/2:00` replica runs at 02:10),
  and its monitor thresholds add the replica interval to the template's (daily 32h/50h instead
  of 30h/48h).
- **A freshly formatted replica disk is checked before it is called ready** (U185):
  `prepare-media` waits until a plain `zpool import` lists the new pool, and refuses otherwise.
  The GUI no longer drops a refresh asked for while another one is running.
- **A passive replica no longer reports "could not record what ... now holds"** after every
  good run (U187). It never skips by design, so the record was never needed.
- **A connected replica disk shows how full it is** (U186): F6 has a `Used` column and the
  medium line says `used N% (X of Y)`; `list-replicas --json` carries `medium_size` and
  `medium_alloc` in bytes while the disk's pool is imported (empty otherwise).
- **The replica wizard shows each dataset's snapshots** (U175): the dataset tree has the count
  (`list-datasets --own-snapshots` gives `snapshots`, every family) and, at zero, the note that
  a passive replica will not copy it.
- **F2 reads newest first and folds one relation's datasets** (U166, U171): upcoming runs (the
  next 6 h only) are on top, past runs below the `now` line, and the cursor starts on the latest
  finished run. Cron lines of one relation, task and tier that start at most 5 minutes apart (one
  line per dataset, spread over free minutes to spare the link; U189) are one row `N datasets` with the worst result (`FAILED 1/3`) and the longest time;
  Enter expands it to one row per dataset with its full path. Cron is unchanged.
- **F4 shows a replica copy in progress** (U170): a replica dataset with no snapshot yet says
  `copy running` while the copy runs, and `interrupted, will resume` when a cut-off receive left
  a resume token (`zfs-tree --json` carries `resume`); the pair panel shows the state and how
  full the medium is. The `other disk` row has its own name.
- **F2/F3 show every run of every job** (U176): a row finds its runs by the label of its own
  cron line. A snapshot-only relation's snapshot rows, the daily/weekly/monthly rows, and a local
  prune row made of several datasets took another line's label and showed no runs (or another
  line's runs).
- **F6 shows a running copy and the current medium state** (U174, U180): `list-replicas --json`
  has `running_since` (the gate's run record, live pid); the row and the medium line say
  `kopia trwa od ...` (`copy running since ...`) instead of the last finished run. F6 reads the
  replica list again on entry and every 15 s while it is open. A disk just inserted, its copy
  waiting (`replica.insert_wait`), reads `disk connected, copy in ~N s` instead of `disconnected`:
  `run-replicas --on-insert` records the wait per device and `list-replicas` gives `insert_in`.
- **A stopped run is shown as interrupted, not running for ever** (U167): `job-stats --runs`
  gives rc `-2` to a run with no END whose `zfs-job.sh` process is gone; F2 says `PRZERWANY`
  (`INTERRUPTED`). Where other users' processes cannot be read (hidepid), it stays running.
- **Removing a replica removes its state files** (U169, U178): `remove-replica --install`
  has the gate (new verb `forget`) delete the replica's files in `/var/lib/zfs-snapshot-all/media/`;
  a copy running at that moment is named in the plan and in the Del window (new gate verb
  `running`) and is not stopped.
- **A replica copy stopped by SIGTERM still exports its disk** (U182): the cron line runs the
  gate's `detach` even when the whole job's process group is killed.
- **A first copy that cannot fit on the disk is refused** (U183): before writing, the gate adds
  up the sources that have no copy on the medium yet, compares that with the free space, and
  exports the disk when it is short. The `add-replica` plan (and the replica wizard before
  EXECUTE) says how big the first copy is and, with the medium's pool imported, how much is
  free, with `!!!` when it cannot fit.

- **A ZFS disk whose pool name and GUID cannot be read starts no replica on insertion**
  (REV-20261109-193). In 1.0.17 such a disk ran every on-insert replica; now the insertion is
  logged and nothing runs. Runs by schedule or by hand are unchanged.

## [1.0.17] — 2026-11-09

- **The GUI title bar shows the package version** (`zfs-snapshot-all 1.0.17`), read from the first
  version heading of this file shipped next to the program; no doubt about which release is running.
- **The replica wizard recognises the broken udev rule as installed on hosts.** 1.0.16 looked for
  a backslash at the end of a line; on pve1 the rule written up to 1.0.15 was one line with the
  backslash in the middle (`... zfs_member", \  RUN+=...`). Any backslash outside a comment now marks
  the rule as old, and the plan renews it.
- **Connecting a disk starts only the replicas whose medium it is.** The on-insert run reads the
  disk's pool (name and GUID, from `blkid`) and runs a replica only when the GUID is one of its
  disks, or, for a replica without a GUID list, when the pool name matches. A disk whose name and GUID `blkid` cannot read runs every
  on-insert replica, as before. Before, any ZFS disk
  ran every on-insert replica. Measured on pve1, 2026-11-09: a benchmark disk produced a replica
  run that skipped and showed as "Last run OK"; a disk just formatted by the wizard, whose GUID
  is saved only at EXECUTE, was refused with rc 2 and an alert. A run by schedule or by hand is
  unchanged: the gate still refuses a wrong disk loudly.
- **A failed on-insert run no longer blocks the next connection.** The udev rule now calls
  `systemd-run --collect`. Without it the failed transient unit stayed loaded, and systemd-run
  refused every later connection of a disk with the same kernel name ("Unit ... already
  exists") until a reboot or `systemctl reset-failed`. Re-run `install-media-trigger --install`,
  or let the replica wizard renew the rule: it treats a rule without `--collect` as old.

## [1.0.16] — 2026-11-09

- **The udev rule from `install-media-trigger` is now valid.** It was written as two physical
  lines joined by a trailing backslash; systemd-udevd 247 (pve1, PVE 7.4) read it as one line with the
  backslash inside, logged `Invalid key/value pair, ignoring`, and dropped the rule, so
  plugging in a disk never started `run-replicas --on-insert`. The rule is one line now.
  **Re-run `install-media-trigger --install` on every host that installed the trigger:** it
  rewrites the rule file unconditionally. The replica wizard (GUI) treats such a two-line rule
  as old and renews it in its plan, as it does a rule without `--on-insert`.
- **USB disks get a deep queue at every attach.** A disk behind `usb-storage` comes up with
  `nr_requests=2`, and `zfs recv` onto it wrote 10 MB/s; with 128 it wrote 65 MB/s (WD My
  Passport 2 TB, OpenZFS 2.1.11). The setting is lost at every unplug, so the media gate raises
  `nr_requests` to 128 on every USB whole disk below that, just before `zpool import`
  (never lowered, non-USB disks untouched, silent when sysfs is read-only). `prepare-media`
  does the same before `zpool create`. One shared function in `lib-backup-common.sh`; the gate now
  sources that library from its own directory (it is deployed beside it) and exits 2 if it is missing.
- **`prepare-media` warns when a USB bridge hides the sector size.** If the kernel's
  `physical_block_size` is smaller than what `smartctl -i` (or `-d sat`) reports, the plan says so.
  The pool is created `ashift=12` regardless, as before.

## [1.0.15] — 2026-11-07

- **A passive source with no snapshot at all is no longer a failed run.** Under `-e -R` (a
  passive replica with `recursive = yes`, a passive copy with `recursive = flat`), a subtree with no snapshot anywhere has
  nothing to copy. The run now says so on stderr, which the job log keeps ("nothing to copy") and ends rc 0. Before, it
  ended rc 1, so one empty source, such as a pool's `data` dataset holding only a container
  without snapshots, failed the whole replica. A subtree whose snapshots exist but none can be
  adopted (another family, or all excluded by `-E`) still fails, as before, and so does an empty subtree under atomic `-r`. Both engines.

## [1.0.14] — 2026-11-07

- **Excluded families stay excluded under `-r` and `-H`.** 1.0.13 kept `-E` families out of an
  incremental on a single dataset. Three cases still let them through:
  - An atomic recursive job (`-e -r -E`) checked only the root's own snapshots. An excluded
    snapshot that only a child has (pvesr's `__replicate_` on a guest disk) still went in the
    single `-R -I` stream.
  - The first copy under `-r` or `-H` is one `zfs send -R` stream. It carries every snapshot before
    the one it names, children included.
  - After such a first copy under plain `-H`, the following steps went without `-R`. The children
    then stayed at the starting snapshot, and the run still reported success.

  Now, for a stream that carries children (`-r`, or the first copy under `-H`), the engines plan the interval
  over the whole subtree, by creation order. The first stream
  starts at the newest root snapshot with no excluded snapshot at or before it, and every later
  step carries `-R` when that first stream did. When no such starting snapshot exists, the run
  sends nothing and says why. The engines' `-R` option (one job per dataset) is unchanged.
- **An active replica after pvesr.** For a replica job without `-r`, on a disk that Proxmox VE
  replicates to this node, pvesr's
  receive destroys the replica's own snapshot but leaves its bookmark. The next copy continues
  from that bookmark, as one increment. This was measured with real pvesr on 2026-11-07. A test now
  reproduces the effect (the snapshot destroyed, the bookmark kept); the engine did not change.
- **Passive means the newest existing snapshot, not the current state.** The relation and replica
  wizards say so in the passive choice window and in the plan; ESENCJA/ESSENTIALS and
  JAK-TO-DZIALA/HOW-IT-WORKS say it too. A passive
  copy or replica takes no snapshot itself. The target holds the state of the source's newest
  snapshot, which may be old, and a dataset without snapshots is not copied. Only the mode with its
  own snapshots copies the current state.

## [1.0.13] — 2026-11-07

- **Which installation a mail is about.** A new setting, `alerts.site` (F10, or `zfs-backup.sh settings set
  alerts.site=Site-A --yes`), names the installation. The subject of the daily summary and of an
  alert mail (immediate mode) then reads `[ZFS] Site-A pve2 ...`; with a sendmail, the sender reads
  `zfs-backup Site-A pve2`.
  Without it the subject carries the host's full name (`pve2.example.net`) rather than the bare `pve2`,
  which several firms can have.
- **The first copy of a replica carries the history.** A new mirror replica (`snapget.sh -e -M`)
  used to start from the newest snapshot only, so the older ones never reached it. Its first copy
  now sends the oldest eligible snapshot in full and then every later one up to the newest. A
  replica made before this change keeps what it has; only "Start over on this disk" (F6, Enter, `e`) fills it in. `-i` and `-H` keep their
  own rules.
- **Excluded families stay excluded inside an incremental.** `zfs send -I` carries every snapshot
  between its two ends. With `-E` (for example a replica that excludes `__replicate_`), an
  excluded snapshot between the last common one and the newest still reached the target. This
  applied to the first copy and to every later run, in `snapget.sh` and `snapsend.sh`. When an
  excluded snapshot lies in that interval, the engines now send the same data as a chain of `-i`
  steps through the snapshots that are not excluded. Snapshots copied earlier are not removed.
- **A family name in `flags` is checked as written.** `-E a*b` in a hand-edited `flags` used to
  pass the check whenever a file matching `a*b` existed in the directory `gen-cron.sh` ran from.
- **Runs and job statistics with overlapping runs.** A second start of the same line while the
  first one still runs ends at once with rc 75; its end took the start time of the real run, so
  that run showed no duration and the skip counted as a failure. Ends now pair with the newest
  open start, and rc 75 is not a failure (job table, Runs, the digest).
- **Last run of a replica.** When a skip (rc 75) and the real run ended in the same minute, the
  skip could be shown as the last run (0 s, and "ERROR (rc=75)" in the details). The last run is
  now the one that ended later to the second; a skip does not count in the average or maximum
  time; the details say "skipped" like the list.

## [1.0.12] — 2026-11-05

- **apt 404 on a dependency** (first install on a Debian 11 source host): the 404 fallback of
  1.0.11 pinned only the package it installed, so `git` from the main archive still pulled
  `git-man` from the security archive and the wizard's source preparation failed. Every apt
  install the tool does (`deploy.sh`'s dependencies, git and sudo on the source) now also pins
  each package named in apt's 404 lines to its newest version outside the security archive, up
  to three tries.
- **Deployment guide:** the first `git` on Debian 11, before the package exists, names the same
  pinning by hand (`git` and `git-man`).
- **One replica, one run at a time.** A copy still running when the next trigger comes (schedule
  or a re-plug) is not started a second time: the new run ends with rc 75 and says since when the
  copy runs; its detach no longer exports the disk under the running copy. The age monitor reports
  a running copy as OK (WARNING past the critical age).
- **New replica on a disk already attached:** the wizard asks whether to start the first copy now
  (in the background, as F7).
- **`prepare-media` creates the pool with `ashift=12`.** USB bridges report 512-byte sectors on
  4 KiB disks; ZFS then chose `ashift=9` and every write became a read-modify-write.
- **F2 Przebiegi:** finished runs of the last 72 h (was 12 h); a running run is always listed, also
  after F8 and when it started before the window. The idle screen is redrawn whole once a minute,
  so a console broadcast no longer leaves garbage on it (Ctrl-R does the same at once).
- **F4 Kopie** of a snapshot-only relation lists the guest disks replicated by `pvesr`.
- **gen-cron:** two datasets with the same basename in one relation get distinct notify labels;
  the relation install (`zfs-backup.sh`) no longer refuses a block where only such a label changed. Commented-out
  `snapsend`/`delsnaps` lines in root's crontab no longer block the install.
- **delete-relation** also removes the relation's progress records; the capacity monitor reports a
  record whose process is gone as orphaned (and marks it dead) instead of a hung copy.
- **`deploy.sh`** ends with the next step (`zfs-backup gui`) instead of hand-written cron recipes.
- **Replica wizard:** the cron field names its five fields, minute first, with examples.
- **A long copy from a Proxmox VE replicated disk is no longer reported as failed.** Proxmox VE
  replaces its `__replicate_` snapshot every few hours and a dataset carrying them is not held, so a copy
  running longer than that found the sent snapshot gone and said `VERIFY FAILED`. The snapshot's
  GUID is recorded when it is sent and proves the copy when the source no longer has it.
- **First copy:** a target dataset that does not exist yet is no longer logged as "Could not list
  the snapshots ... failure".
- **A passive replica skips snapshot families like a relationship does.** `add-replica
  --exclude-family=A,B` (with `--passive`) gives the copy the same `-E` exclusions a relationship
  has; the replica wizard sets `__replicate_,vzdump,__migration__` for a passive replica that has none, so the
  copy stands on the tool's own snapshots instead of the ones Proxmox VE replication renames and
  replaces every few hours. `list-replicas --json` shows the list as `exclude_family`.
- **A replica run that cannot record itself does not start.** If the gate cannot create or open its
  lock, or write and read back its run record (state directory not writable, a directory where the record
  belongs), attach stops with rc 2 before any import. A detach that finds a record it cannot read
  does not export the pool (it says DO NOT UNPLUG if the pool is imported).
- **Snapshot family names are checked.** `--exclude-family` (add-replica, add-client, rux,
  local-backup), `exclude_family` and `-E` in `flags` accept letters, digits and `_ . : -` only;
  gen-cron refuses `flags` that contain `;`, `&`, `|`, `<`, `>`, a backtick, `$(` or a newline,
  because the value is copied into root's crontab line unchanged.

## [1.0.11] — 2026-11-05

- **No false "monitor BROKEN" and no failed bookmark prune from a pipe** (U149, U165). Under
  `pipefail` a reader that stops early (`grep -q`, `grep -m1`) made the writer die of SIGPIPE, and
  a root the list did contain read as missing: `check-snap-age.sh -R` paged "descendant list does
  not contain the root itself", `delsnaps.sh -R` failed the bookmark prune. The monitor and the prune
  use here-strings; 57 `| grep -q` readers in the other `pipefail` files became `grep_q` (reads to the
  end); the rest are counted with a reason by a ratchet in `test/evalfree`. `cron_block_source` reads
  the block with `awk`, so `list-jobs --json` no longer carries a `sed: ... Broken pipe` line.
- **gen-cron** warns when two tiers of one dataset share a minute and their hours meet (the shape
  that lost the lock with rc=75).
- **Quiesce whitelist preflight:** installing a `-q` line warns about a guest outside
  `/etc/zfs-quiesce-allow/<account>`; a `zfs list` that fails during that check says UNKNOWN with
  the dataset and the reason instead of reporting no gap.
- **New relation with an excluded child** (e.g. `photos` under `[-] hdd/data`): the first copy no
  longer fails with "-X needs -R" -- `-X` is written only to a section that rides `-R`.
  Pairing creates the pull root as `<target>/<landing>` (`deploy.sh --pair --landing=`), no extra
  empty `<target>/<peer address>`.
- **`deploy.sh --uninstall [--yes]`**: the inverse of a plain deploy -- the tool's cron blocks,
  accounts it created (with their delegations and quiesce grants), links, host scripts, its
  directories and the `zfsalert` group; datasets, snapshots, packages, logs and the checkout stay.
  It refuses while the host still takes part in a relationship and names the verb for each.
- **apt 404 on Debian 11:** one more try with the newest version outside the security archive, said
  in the log; `check_dep` keeps apt's last `E:` line; `--join` installs sudo before its first
  change (`--check-only` then reports `[missing] sudo` on a host without it).
- **Pairing:** `delete-relation` on one side of a two-way pair named after the hosts no longer
  removes `relationships/<name>` while the pair gate still uses it (the reverse relation stopped
  with PAIR_UNKNOWN).
- **First install** (from-zero tests on the lab): `check-source` takes a directory as the package
  only with `.git`; the first `git` in an old directory fetches before moving anything aside; the
  failure window starts with the FATAL line; `--unpair` on a join manifest points to `--leave`;
  zero delegation names the pools and `--grant-datasets=`; `delete-relation` without a peer prints
  no empty name; the deployment guide clones into `/root/scripts/zfs-snapshot-all`.
- **GUI language:** ESSENTIALS/ESENCJA say how to switch the GUI, which starts in English
  (`gui.language` = en): F10 `language` or `settings set gui.language=pl --yes`. `list-replicas` without a root config is an empty
  list, so a host whose only relation runs on a delegated account shows no "no answer" header.
- **GUI:** a failure or a rejected plan returns to the wizard summary with the answers kept; Esc in
  the name window is Back; remote-snapshot texts do not speak of copying; a dataset added to a
  remote-snapshot relation without snapshots waits for its first run instead of showing "up to
  date", and does not hold the whole tier waiting while the others have snapshots; the edit plan says the
  first snapshot/copy comes "at the next cron run"; the "already on the source" list skips excluded
  datasets; the Datasets row of a change shows the new list; a tier repeated by two monitor groups
  names its group on F3; two Polish words in the English GUI (the plan's `(^name$ ...)` hint, the
  frame's "Enter window") are translated.

## [1.0.10] — 2026-11-04

- **The daily mail is a table of relations.** Subject (Polish, like the mail): "OK, N relacji" or
  "K z N relacji wymaga uwagi", plus any pool that is not ONLINE or is at least 80% full. Body:
  every relation with its newest run and its state in the GUI's words; DO ZROBIENIA only when
  something needs action -- failed jobs with the datasets they act on and the cause, read from the
  run's own lines in cron.log (for exit 8, the first "Quiesce:" line); runs without quiescing;
  stale or unanswering monitors; pools. All pools of the host in the header; one line for the week. Removed relations are not shown. The full statistics come as an HTML attachment,
  one section per relation. Sent with `sendmail -t` as "zfs-backup <host>"; without sendmail an
  ASCII body by `mail -s`; without python3, or with `ZFS_DIGEST_LAYOUT=jobs`, the job-table mail.
- **Alerts in plain words** (immediate mode): subject "[ZFS] host: relation -- what happened (when)",
  a sentence on what it means and what to do; a monitor that measures from the dataset's creation
  (no relation start) says so. Exit 8 -- snapshots taken without quiescing the guest -- goes to the
  warning script, not the alert one; the daily mail still lists it under DO ZROBIENIA.
- **Wizard, "Where to":** opens the dataset tree directly. From 110 terminal columns every dataset
  tree window has the F2 layout (table with Used/Avail/Snapshots/Notes, a facts panel, a bottom tab).
  The facts say where the copies will land and which relation copies there; for a local copy also
  what is already there and whether the first copy is incremental (common snapshot) or full (and
  how big). On first entry the cursor starts on a target that already holds a copy of this data
  with a common snapshot, if there is one. Ins creates a new dataset under the highlighted one.
- **Passive local copy:** monitor thresholds follow the pvesr replica that feeds it (at least 2x/3x
  its interval). **Monitor** (`check-snap-age.sh` v2.9): an `-R` root holding only snapshots of
  another family, above children that hold the family, is a container, not "waiting".
- `delete-relation` refuses `--yes` while a run of the relation is in progress; the plan of
  `edit-relation` for a local relation says `--yes`; "Short source retention" replaces "Fastprune" in the GUI.
- Engines (REV-20261104-186): the protected-snapshot check before a forced full copy and the `-F`
  collision scan fail closed; remote snapshot lists run no awk on the far side; `-m` is a literal
  prefix; `delsnaps` keeps what it cannot read and lists an `-R` tree before pruning it.

## [1.0.9] — 2026-11-04

- **A local copy into an archive that keeps longer than its source installs.** The rehearsal before
  `--install` read the engine's dry-run exit code 1 as a failure, but the dry-run lists every
  snapshot the target has and the source no longer has -- an archive's older daily and weekly
  history. Such snapshots older than the common base are now history, as in activate-client; a
  target snapshot newer than the base still refuses the install.

## [1.0.8] — 2026-11-04

- **Fastprune for remote snapshots** (wizard: Advanced -> Fastprune; edit window: Fastprune row). One
  number of hours N for every tier of the chosen template: `retain = -h<N>`, pruned every hour;
  monitor thresholds stay only on tiers more frequent than N. Meant for a source with no room, whose
  history lives in a passive copy on the collector; the plan names that copy or warns there is none.
- **Update hold covers the delegated accounts.** `update-control.sh --hold-updates` (and
  `deploy.sh --hold-updates`) hold automatic updates; `--resume-updates` releases them. The hold is
  mirrored to `/etc/zfs-snapshot-all/update-hold`, and the account's hourly `git pull` line skips the
  pull while it exists. Takes effect on a host once it runs this release.
- Wizard: backup and mirror can be passive when the source has no snapshots of the family yet
  (Advanced -> Passive); the `passive-flat` template is listed for them; remote snapshots no longer
  offer GFS-ladder templates; the "another creator" answer is shown in the summary; a passive plan no
  longer says "freezes".
- GUI: a relation with one tier up to date and the rest waiting for their first run is "up to date";
  a tier without monitor thresholds no longer turns its dataset into "no monitor"; the relation panel
  counts a flat tier's own prune jobs; plan texts read as paragraphs; an edit that only adds jobs
  says so.

## [1.0.7] — 2026-11-03

- **A new copy relationship no longer mails "monitor BROKEN" before its first run.** Since 1.0.6 a
  copy relationship takes no first copy, so its target does not exist until its first cron run (a
  passive copy: until the family appears on the source). The monitor read that as UNKNOWN and its
  cron line mailed every 15 minutes. `check-snap-age.sh` v2.8: with the relationship's start (`-S`)
  a dataset that does not exist yet is WAITING, and WARNING/CRITICAL past the thresholds; without
  `-S` a missing dataset is still UNKNOWN.

## [1.0.6] — 2026-11-03

- **A new or changed relationship takes no snapshot and no first copy.** Every tier starts at its
  own cron time; a yearly tier can be months away. Until 1.0.5 activation snapshotted every tier
  at once, guest freeze included, and a change of a remote-snapshots relationship did it again.
- **The monitor counts from the relationship's start.** The config keeps `<tier>.monitor_since`
  (written once, never moved), and the age alarm is measured from the later of the newest
  snapshot and that start. Before its first run a tier is WAITING ("czeka na pierwszy termin" in
  the GUI), not stale; past its thresholds it alarms as before. With the start set, a recursive
  tree with no snapshot at all is checked too, so a relationship whose cron never runs does alarm.
  `check-snap-age.sh` v2.7: `-S EPOCH`, `-W`.
- **Remote snapshots keep the plain `automated_*` family.** The collector-stamped family
  (`<collector>_automated_*`) is now only made on request (`--stamp-family`, in the GUI: "another
  collector or a cron makes them"). When the source already has snapshots of the family, the
  relationship asks who makes them (`--own-snapshots`: leftovers, taken into its retention); the
  answer can be given on a re-run after that question, once, before activation.
- **New-relationship wizard**: the account is a step of the walk, not hidden in "Advanced". A
  local copy can be made passive before the source has snapshots of the family (Advanced →
  Passive): it only takes snapshots someone else makes (a remote-snapshots relationship plus a
  pvesr replica), including datasets created under the source later.
- **GUI**: local snapshot-only relationships say "only snapshot" in F2 (not "transfer
  lsrc_hourly") and show the minute cron really runs; the relationship panel has one line per
  tier (current / waiting with its first run / stale, with its alarm threshold).
- **Install guard**: jobs installed before the PVE guest guard (no `--pve-guests`, several guests
  on one line) no longer block adding a relationship to the same account, where the re-rendered
  lines still cover every dataset; any other difference is still refused.

## [1.0.5] — 2026-10-30

- **Security: the GUI's run-statistics cache** (`job-stats --vol-cache`, run as root) is kept only
  in the user's own runtime directory (`$XDG_RUNTIME_DIR` or `/run/user/<uid>`), and only when that
  is a real directory owned by the user and not writable by group or others. Without one there is
  no cache. It used to fall back to `/tmp` with a predictable name, so a planted symlink let root
  write the snapshot listing into another file.
- **Export and import of an encrypted (raw) relationship**: the export now carries `--raw`, so the
  import sends raw and the encrypted target accepts it. An older export file is imported with
  `--raw` when its dataset sections are raw.
- **PVE guest guard on whole trees**: a recursive snapshot or prune finds its source tree in
  every spelling: `pool/path`, `host:pool/path` and `user@host:pool/path`. A generated prune took
  its `-P __replicate_:2` value for the dataset, and `host:pool/path` (no account) was skipped. In
  both cases the tree was not checked and the prune could run over a pvesr replica disk.
- **New-relationship wizard**: with two or more datasets, the "leftovers" answer keeps
  `--own-snapshots` in the command (the summary showed it, the command lost it); a local copy
  answered "chain" keeps `--passive`.
- **Replica wizard**: "format a new medium" no longer offers another replica's disk; an own cron
  schedule is checked field by field (minute 0-59, hour 0-23, …), and a wrong one asks again
  instead of falling back to "auto".
- **One date format in the GUI**: `YYYY.MM.DD HH:MM`, with seconds where they were shown before.
  The short forms ("today" as a bare time, "tomorrow", a weekday, `DD.MM`) are gone. Snapshot
  names, `--at=` values and F4's CREATION column (`zfs list` format) are unchanged.
- **F6 Replica**: "Rekurencyjnie" (recursive) instead of "Z dziećmi"; "Na dysku" says how many
  newest `replica_` snapshots the disk keeps and about how far back, with a separate
  "Ile migawek" row; the runs tab estimates each run's data from the `written` of its `replica_`
  snapshots ("-" when there is none).
- **F4 groups** show the relationship type in the group header instead of a Rodzaj column, so
  the longer dates no longer cut copy names.
- **Fewer windows**: the "running" window is drawn once with a seconds counter in the last row
  (it flashed every 2 seconds); a successful save, wizard or identical import ends with one
  sentence on the message line instead of an Ok window; Enter in a confirmation no longer cancels
  it; the output window follows its tail until you scroll up.

## [1.0.4] — 2026-10-29

- **Browsing a copy with mc**: mc runs in its own small root. `/kopia` is the snapshot
  (read-only), `/odzysk` is the only place it can write, and the rest is the read-only system mc
  needs. Neither panel can reach the host's pools, `/root` or other copies any more.
- **Faster GUI start**: the screen comes after the quick readers (about a second on the lab host);
  the monitor and run statistics follow, and until they answer the screen says "sprawdzam…"
  (checking…) instead of "bez monitora" / "brak w dziennikach".
- **F2 cursor** stays on the same run when the run statistics arrive (at start and after every
  window); it used to jump to an older run.
- **Re-adding a source tier** of a local relationship (`set-tiers --add-src-tier`) runs that tier's
  first snapshot, as for other relationships.
- **Source-retention table**: a long note wraps inside the window instead of being cut.

## [1.0.3] — 2026-10-29

- **New-relationship wizard**: when the chosen source datasets already carry our snapshots, the
  question "chain or leftovers" comes right after the datasets, before the target, and names the
  source ("Na źródle <host> …"). It came after the target and read like a problem with the target.

## [1.0.2] — 2026-10-29

- **Faster return to the main window.** It waits only for the quick readers (status, jobs,
  progress, replicas); the monitor and run statistics follow a moment later with
  "(monitor i przebiegi: sprawdzam…)". The F4 copy tree is no longer read in the foreground after
  every window, which froze the screen for seconds. A window closed without a change, the F8 key
  window and a template or settings window re-read nothing or only what they changed.
- **One "Are you sure?" per action.** Restore asks once in its window and runs with `--yes`, so it
  no longer asks again in the terminal. Deleting a replica is one window. Deleting a relationship
  asks a second time only when its copies are deleted too. The new-relationship wizard shows one
  plan window after Create. A one-line success goes to the message line instead of a window.
- **F4 Copies in the F2 layout**: a table of copies, the snapshots in the bottom tab with the
  `zfs list` columns, F8 groups by relationship. The target browser of the wizard shows USED/AVAIL.
- **F6 Replica**: source → target in the right panel; the bottom tab lists the replica's runs,
  done and upcoming, like F2 (72 hours back).
- **F7 on a relationship** runs each dataset's lowest tier (hourly before daily before weekly …).
  A relationship without an hourly tier could run whichever line came first in cron.
- **Adding a tier** (`set-tiers --add-tier`) takes that tier's first snapshot at once, so its
  monitor does not report a missing snapshot until the first scheduled run.
- **F10 Settings**: wider gap between the columns, descriptions wrap in the third column.

## [1.0.1] — 2026-10-29

- **PVE guest guard.** Snapshots and prunes of a guest's disk run only on the node where the guest
  runs; on a pvesr replica they are skipped with an alarm (`rc=76`). Recursive trees
  (`rpool/data`, `hdd/vm-disks`) are covered too: a `-R` snapshot leaves the replica's disk out
  (`-X`) and warns, a prune does not run. Name the source node with `/etc/hosts` or `pve_node` when the
  source is given by address.
- **Host names instead of addresses** in the GUI: each side reads `host:dataset`, the direction
  `pve9 → pve10`; the ssh account and the address are in the relationship window's Config tab.
  A relationship with a second host is named after the name the host reports (the wizard asks
  only when that name is taken or invalid), and new copies land under `<target>/<host name>/…`.
- **Restore** refuses to roll the running system (`/`) or a running guest's disk back in place;
  the running system is received as a new boot environment instead (`--as-boot-env`, in the GUI
  the "new boot environment" choice). The restore wizard asks what, from when, then where.
- **F4 Copies** in two panes (the copy tree and `zfs list -t snapshot`), browsing read-only in `mc`.
- **F2 Runs**: successful prune runs of one cron line fold into one row; the cursor opens at now.
- **F3**: the relationship window has Opis/Config tabs.
- Faster GUI start: one snapshot listing per `job-stats` call; the GUI keeps it for 5 minutes
  (`--vol-cache`) unless a cron log changed since; the F4 tree is read in the background.
- Fixed: a control character in an engine's error line (ssh) no longer breaks `job-stats --json`;
  the English GUI said `lokalnie` for local copies; GFS retention refuses to prune when a
  snapshot's creation time cannot be read.
- Community files for the public release: a Polish README (`README.pl.md`), `SECURITY.md`,
  `CONTRIBUTING.md`, this changelog, issue and pull request templates, and the interactive
  tutorial (`docs/tutorial/index.html`) shipped with the package.

## [1.0] — 2026-10-25

The first public release (tag `v1.0`).

- **Relations**, created in a wizard (F3, Ins): backup, mirror, remote snapshots, and on the
  collector itself local copy and local snapshots.
- **Retention per tier** (hourly, daily, weekly, monthly, yearly), on the copy and on the source,
  counted flat, by age or as a GFS ladder; shipped templates and a tier table for your own.
- **Chains and Proxmox replication**: snapshots someone else makes are adopted passively
  (`--passive`); leftovers of an old relation are taken over with own snapshots (`--own-snapshots`).
- **Replicas** to USB disks or a second pool, once a night, optionally encrypted.
- **Monitoring and a daily mail digest** when a copy stops arriving; **restore** and read-only
  browsing of a snapshot from the GUI.
- **Delegated accounts** with exactly the ZFS rights the jobs need; guest quiescing through a sudo
  helper.
- **Self-update** from this repository once an hour, with a hold and a rollback.
- GUI in English by default, Polish with `--lang=pl`; command output in English.

Known limitations of 1.0: target-side GFS retention is rendered as a flat count per tier; an
automatic guard for datasets that become Proxmox replication targets while snapshotted is planned
for 1.1.
