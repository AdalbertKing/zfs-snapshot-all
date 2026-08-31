# Engine freeze

<!-- frozen: snapsend.sh 100755 d8c8c4743f0374c829e7661493b99f95faaa7c1c -->
<!-- frozen: snapget.sh 100755 2b61ddb2d40f9ca7b454d877591447bc097a4c28 -->
<!-- frozen: delsnaps.sh 100755 834b449905a0eb3f14ce1301c4323980f9ed2bc3 -->
<!-- frozen: check-snap-age.sh 100755 34faf6d1665c24bdc9d33f539e59f47d218d7816 -->
<!-- frozen: lib-zfs-snap.sh 100644 e668fa7ee19fba21ea50f6ad1208ffcb30daaa0c -->
<!-- unfreeze: - -->

**Machine markers above. Written by `./test/impact.sh --refreeze`, checked by
`--verify`. Do not edit them by hand** — a hand-typed baseline is a baseline
nobody measured.

## What is frozen

The two transfer engines and the library they both run on:

The set approved in the Stage-3 plan, in full:

| file | why it is in scope |
|---|---|
| `snapsend.sh` | the push engine |
| `snapget.sh` | the pull engine |
| `delsnaps.sh` | the destructive one — it deletes snapshots |
| `check-snap-age.sh` | the monitor whose silence is indistinguishable from health |
| `lib-zfs-snap.sh` | the code the engines execute |

The first version of this document dropped `delsnaps.sh` and `check-snap-age.sh`
on the grounds that later work might need them. REV-20260808-070 F1 rejected
that, correctly: it changed an approved contract instead of implementing it, and
if future work genuinely needs one of those files, **requiring a review first is
exactly what the freeze is for**.

**Not frozen:** `gen-cron.sh`, `deploy.sh`, `zfs-backup.sh`, the pair-gate and
the test tree. Not added speculatively either — `lib-cron.sh` and
`zfs-pair-gate.sh` stay out until a dependency argument requires them.

## What the freeze means

A change to a frozen file requires a review **before** the implementation, not
after it. That is the whole point: the engines are the code every relationship
in the fleet executes nightly, they now have 619 assertions of live evidence
behind them, and the cheapest way to lose that is a small edit that seemed
obvious.

## Authorization

The owner removed the REV pipeline on 2026-08-15 (`HANDOFF.md`), and for a while
that left only one live route. It no longer does. **Corrected 2026-08-26 at the
reviewer's request**, because this section described a division of labour the
project had already stopped using:

| who | does what |
|---|---|
| **Owner** | directs the scope. A frozen file changes only on an explicit owner direction -- that has not changed and is not negotiable |
| **Claude** | implements, and records the change here in prose with the date and the direction it answers |
| **Reviewer** | performs the pre-review, and issues the `authorizes-frozen` marker when it authorises one |

So BOTH routes below are live. They are not alternatives to each other in
practice: the owner's direction is what makes a change legitimate, and the
pre-review is what makes it safe. The 2026-08-26 quiesce-degrade entry went
through both -- owner direction ("chcę dokończyć Quiesce"), then a pre-review
that returned APPROVED WITH GUARDS and nine contract conditions, then the
implementation, then `--refreeze`.

The freeze itself is unchanged, and its value (no frozen engine changes in
passing) never depended on who the authority is.

Owner-authorized refreezes:

- 2026-08-29 (snapsend.sh, snapget.sh): **the log announced a creation that did
  not happen.** Owner direction: "Tak" -- to the implementer's report from the
  removable-media lab.

  LOG TRUTH ONLY. No behaviour changes: the same guard decides whether the
  dataset is created, the same failure aborts the same way, and the remote path
  still costs exactly ONE ssh round trip.

  Both engines logged, unconditionally, before doing anything:

      log 2 "Creating target dataset: $tgt_dataset"

  and it was wrong three ways at once.

  1. The creation below it is guarded by `zfs list ... || zfs create ...`, so on
     every incremental run -- which is every run after the first -- it announced
     a creation that did not occur. Observed on pve9 during the media lab: the
     line appeared while the copy was demonstrably NOT recreated, because the
     target's older snapshots survived the transfer.
  2. With `-w` the dataset actually created is `$create_target`, the PARENT of
     `$tgt_dataset`. The line named the wrong path.
  3. It ran BEFORE `$create_target` was computed, so it could not have named the
     right one even in principle.

  Now each branch says what it did: `Created target dataset: $create_target` or
  `Target dataset already exists: $create_target`. On the remote side the
  existing single `ssh` reports which branch it took rather than being asked a
  second time -- the round-trip count is part of this package's contract and was
  not going to be spent on a log line.

  Why it was worth unfreezing for a message. An operator watching a nightly job
  saw "Creating target dataset" every night and had no way to tell a first seed
  from an increment -- the one thing that line could usefully have told them. A
  log that says the same thing whatever happened is not information, and this
  project has spent the day removing exactly that shape from `detach`, from
  `pause-client`, and from a test that recorded a PASS unconditionally.


- 2026-08-28 (snapget.sh): **the remedy this file prints destroys bookmarks, and
  did not say so.** Owner direction: "Tak" -- to the implementer's proposal after
  the measurement below.

  DIAGNOSIS ONLY. Same refusal, same status, same way out; one sentence added to
  each of the two branches that name `zfs rollback -r`.

  Measured on the lab, 2026-08-28, on real ZFS:

      recv -F, target NOT diverged      bookmark survives
      recv -F, target diverged (rolled  bookmark SURVIVES -- recv destroys
        back, snapshot destroyed)         snapshots, not bookmarks
      zfs rollback -r to an earlier     bookmark DESTROYED
        point

  So the automatic path is safe and the MANUAL remedy is the one that kills
  them -- and this file is where an operator is told to run it.

  It matters because of what a bookmark on a copy is for. `record_send_bookmark`
  leaves one per target, and for a replica onto removable media that bookmark is
  the anchor the disk returns to: it lets a month-old disk take an increment
  instead of a full re-seed, and it works even though the snapshot it points at
  was pruned long ago. Measured the same afternoon: with the anchor gone and no
  common snapshot left, the engine fails with "destination has snapshots (eg.
  ...) must destroy them to overwrite it" -- loud and safe, and the only way
  forward is -f, which re-seeds the whole disk.

  The sentence names the command to look first (zfs list -t bookmark -d 1), so
  the loss is a decision rather than a surprise.

- 2026-08-27 (delsnaps.sh): **`-L` -- the pause reaches the engine that
  destroys.** Owner direction, verbatim: "Jesli nalezy uzupelnic silnik, czyli
  delsnaps o te funkcje i go odmrozic. Zrob to. pausa ma wstrzymac wszelkie
  operacje cronowe naszego pakietu z prunem wlacznie."

  This is a BEHAVIOUR change, not a diagnostic one, and it is the first on this
  file since the freeze.

  snapsend.sh, snapget.sh and check-snap-age.sh have honoured the logical pause
  marker since REV-20260804-045. delsnaps.sh did not, and gen-cron emitted no
  `-L` on any prune line -- by an explicit decision recorded in gen-cron.sh:
  "retention of what already landed stays correct while a relationship is
  paused; only new transfers and the alarms about their absence stop."

  That reasoning was right about the case it considered and wrong about the one
  it did not. Measured on the lab, 2026-08-27: during a restore campaign the
  source-side prune fired at :21, applied its GFS ladder to a source the restore
  had just rolled back, and destroyed the recovery point itself. The
  relationship was left with no common snapshot at all. "Retention stays
  correct" assumes the data underneath it is not moving; a restore is precisely
  when it is.

  Scope: one flag taking an argument, free in delsnaps' own parser, in both the
  split and attached spellings its neighbours already accept. The gate is the
  same contract as the other three engines, to the letter -- same marker path,
  same charset rule, exit 0 so cron stays quiet, and its own `skipped_paused`
  stats status so a skipped prune can never be read back as a prune that ran. A
  run that omits `-L` is not gated: logical pause is an orchestration switch,
  not a security boundary, and this file does not pretend otherwise either.

  Placed after the arguments are named and before any ssh, any listing and any
  destroy: a paused prune must not even ask the far side what it holds.

  Considered and rejected: stopping cron. The host's crontab carries jobs that
  are not ours, and stopping the daemon to pause one relationship stops those
  too -- the owner named that trap before I could walk into it.

- 2026-08-27 (snapget.sh): **the refusal named a remedy the account cannot run,
  and the remedy that fits said nothing when it failed.** Same owner direction
  as the entry below it ("az do braku zaciecia i koniecznych poprawek w kodzie").

  DIAGNOSIS ONLY again. No input changes verdict, status or effect.

  Measured on the lab, immediately after the entry below was proven. The
  refusal ended "Force explicitly with -f". Run as the account that owns the
  relationship, `-f` gives:

      cannot create '...': dataset already exists
      Hint: -f [...] requires root.

  `-f` is the wrong size of hammer as well as unusable: it destroys the whole
  copy and re-sends every byte, when what the situation needs is to drop the
  handful of snapshots the source no longer has. Those are already NAMED in the
  refusal, and the account that owns the relationship can destroy them --
  measured, rc=0, no root and nothing re-sent.

  **And destroying them is not enough either -- corrected again, same evening.**
  Following that advice on the lab cleared the snapshot refusal and produced the
  other one: "has 15872 written since the common snapshot". Destroying a
  snapshot does not move the live filesystem, so the copy stayed where those
  snapshots had left it, one refusal ahead. `zfs rollback -r <copy>@<common>`
  does both halves in one command -- drops the snapshots and returns the
  filesystem to the point -- and the relationship account can run it. Proven by
  the pull then going through unaided: "All datasets processed successfully".

  Both branches of the guard now name that command, including the
  something-wrote-here branch, where it is the way out once the divergence is
  known to be expected.

  **`-F` is not it, and the first version of this entry said it was.** I ran
  `-F`, watched the refusal not fire, and concluded reconcile had dropped the
  snapshots. It had not: `-F` acts only on a name collision under a DIFFERENT
  GUID, and what it actually did was escalate the run to a full re-pull -- same
  cost as `-f`, reached by another road. The next `-F`, against a state with no
  such collision, refused like any other run and exposed the mistake. One
  observation, one inference, shipped: the cost of reading an outcome instead of
  reading the flag.

  `-F` also failed at the time, with no hint at all:

      cannot unmount '/hdd/labcoll/.../vm-900-disk-0': permission denied
      Transfer failed

  ...while the SIBLING dataset, identical but not mounted, succeeded in the same
  run. The hint that would have explained it was gated on `FORCE_FULL_SEND`, and
  the cause is not `-f`: it is `recv -F`, which rolls back, which unmounts, which
  a delegated account cannot do on Linux. The gate is now the actual cause
  (`recv_force_flag` non-empty), and when the target is mounted and the caller is
  not root the message says so and gives the one-off root command.

  Proven by the same account finishing the pull unaided once the copy was
  unmounted: "All datasets processed successfully".

- 2026-08-27 (snapget.sh): **the copy being AHEAD is not the same event as
  something writing to it, and the refusal now says which one happened.**
  Owner direction, verbatim: "Testuj dalej. Rob nowy lab. [...] portem je
  odzyskuj az do braku zaciecia i koniecznych poprawek w kodzie."

  DIAGNOSIS ONLY. No behaviour changes: the same input is refused, at the same
  place, with the same exit status, and `-f` remains the same way out. What
  changes is the sentence the operator reads.

  Found on the lab, 2026-08-27, in the state a restore leaves behind. A restore
  had rolled the SOURCE back an hour. The copy still held the snapshot of the
  period that had been rolled away, so `written@<common>` on the copy was 14.5K
  and the pull refused with "something wrote to this target [...] if this is a
  live guest disk [...] investigate."

  Nothing had written to it. The copy's own `written` was **0** -- its
  filesystem was byte-identical to its newest snapshot. The 14.5K was a
  SNAPSHOT, and `written@` cannot tell the two apart because it counts
  everything after the point, whatever made it.

  The two causes are opposites. A rogue writer means the copy is contaminated
  and `-f` restores its integrity. A copy that is ahead means the copy is the
  only surviving record of a period the source destroyed, and `-f` is the one
  command that ends it. Sending the operator to look for a live guest that is
  not there is the least of it.

  Discriminated from data the function already holds: if the common point is
  not the target's LAST snapshot, the excess is snapshots. They are then named,
  because they are exactly what `-f` would destroy.

- 2026-08-27 (snapsend.sh AND snapget.sh, one commit): **`-t` -- the second
  argument is the EXACT dataset, not a base to append the source name under.**
  Owner direction, verbatim: "A. zmiany maja byc jednoczenie w snapsend i snapget
  przeprowdzone."

  Both engines composed the target as `BASE/<source name>`, or identity when the
  base was omitted. Both preserve the source's name, which is right for a backup
  -- a collector holding twenty sources needs them to stay apart. A RESTORE is
  the one operation where it is wrong: the copy lives at
  `hdd/backups/<peer>/hdd/data` and has to land back as `hdd/data`, and neither
  mapping can say that.

  FOUND ON THE LAB, not by reading. pve9 -> pve1, 2026-08-27: the grant was read
  and enforced, the mode classified remotely as `rewind`, the recovery point
  chosen -- and the engine then tried to create
  `hdd/labsrc/hdd/labcoll/192.168.28.9/hdd/labsrc`. Every unit test passed
  throughout, because none of them composed a real target path.

  Both engines in ONE commit at the owner's instruction. They are twins, and
  `test/twins` exists because a capability added to one direction and not the
  other is how they drift. This is that rule applied before the drift instead of
  after it.

  Scope: one BOOLEAN flag, free in both optstrings, taking no argument -- so
  gen-cron.sh's FLAGS_ARG_LETTERS contract is untouched. The composition gains a
  new FIRST branch; the two existing branches are byte-identical, so every run
  that does not pass `-t` behaves exactly as before. `-t` refuses what it cannot
  mean: no base, more than one dataset, or `-R`.


- 2026-08-27 (lib-zfs-snap.sh, snapsend.sh, snapget.sh): **the default answer to
  a failed freeze is inverted.** Owner direction, verbatim: "Przemyslalem i chce,
  zeby snapshots sie tworzyly domyslnie pomimo porazki flush buffers." A failed
  freeze now takes a crash-consistent snapshot -- `_crash_` in the name, exit 8
  -- without anybody having written a qualifier, and `,strict` is the per-tier
  way back to the previous refusal.

  Scope, so the entry is not larger than the change: `QUIESCE_DEGRADE` defaults
  to `1` instead of `0`; `quiesce_parse_mode` gains `,strict` and reads *what was
  written* rather than the resulting flag when rejecting a qualifier on `no`; the
  two engines' `-q` help and three run-time log lines stop saying the operator
  asked for something they now get by default. No gate, no rc mapping, no remote
  script and no name builder was touched -- the sentence "what degrading does not
  excuse" is true in exactly the words it already had.

  The one line that would have broken the fleet, recorded because it was not
  obvious until the parser was written out: `no` is both engines' built-in `-q`
  value, so with the default at `1` a bare `no` is indistinguishable from
  `no,degrade` unless the check reads the written qualifier. Reading the flag
  there would have made every run in the estate refuse at startup on the next
  hourly `git pull`. Caught by the suite's `bare no still parses` assertion,
  which existed for the previous flip in the other direction.

  This entry has the owner's direction and not a pre-review. The direction is
  what makes it legitimate; the pre-review is what makes it safe, and it is
  absent, so the risk is stated rather than covered: this changes what every
  quiesced job in the fleet does on failure, on the next hourly pull, and the
  `,degrade` already written into `prod.conf` and every generated crontab means
  no line in production changes meaning today -- only tiers that carry a bare
  `-q` mode do, and those degrade instead of refusing.

- 2026-08-26 (lib-zfs-snap.sh): the PULL half of `,degrade` classified by CAUSE,
  not only by cleanliness. Same authorization as the entry below it -- this is
  that change corrected, not a new one. Found in review, and the reasoning error
  is the part worth keeping: the entry below claimed the remote script's exit
  codes already discriminated everything that mattered. They discriminate
  CLEANLINESS -- 3 and 5 both mean "the source host is as we found it" -- and say
  nothing about CAUSE. A foreign freeze and an impossible mode/guest pair are
  clean too, `prep_one` returned 1 for every failure, the aggregator turned any
  of them into `exit 5`, and the local side degraded every 5. So the same
  configuration refused a foreign freeze on PUSH and degraded it on PULL.
  `prep_one` now returns 2 for the never-degradable causes, the aggregator counts
  the two classes separately, fatal outranks degradable, and the result is
  `exit 9` -- which the local mapping will not degrade.
  Carried in the same reading: `info=$(gq_status "$id")` discarded the command's
  status, so an unreadable status gave an empty `kind`, fell into the "no guest
  here -- skipping" arm and returned SUCCESS. A helper that could not answer
  looked exactly like a host with nothing to freeze. Now an explicit failure, and
  a degradable one -- the same answer its local twin gives.
  The tests that missed this stubbed a ready-made rc, proving only that 5 becomes
  8 and never asking what becomes a five. The new discriminators RUN the remote
  classifier and carry its actual code through the local mapping; two existing
  assertions moved from 5 to 9, deliberately, because that is the contract change.

- 2026-08-26 (lib-zfs-snap.sh, snapsend.sh, snapget.sh): `quiesce = <mode>,degrade`.
  Owner direction: "nie. Chcę dokończyć Quiesce". **The first change on this list
  that was PRE-REVIEWED**: submitted as a design before an engine line was
  written, returned APPROVED WITH GUARDS with nine contract conditions and an
  `authorizes-frozen` marker naming these three files and no others.
  WHAT IT ANSWERS, measured rather than argued: on pve9/pve1/pve2 (2026-08-25)
  the `prod` profile produced NOTHING for three of its four tiers, because a
  delegated account could not reach the guests and every tier that asks for `-q`
  refuses rather than snapshot. For an hourly tier that is one interval of
  twenty-four. For daily, weekly and monthly it is the durable artifact.
  WHAT CHANGED: `-q` accepts an optional `,degrade` qualifier, per tier, opted in
  beforehand. Without it, EVERY existing refusal behaves exactly as before -- the
  suite runs the same failure with and without the qualifier at every site, and a
  mutation that removes the opt-in check fails ten pre-existing fail-closed
  assertions. With it, a quiesce failure rolls back and thaws first, and only from
  a proven-clean state takes the whole set again as `*_crash_*`, transfers it
  normally, and exits 8 so cron reports it. A thaw that did not take, a foreign
  freeze already in place, and a rollback that left snapshots behind all stay
  fatal with the qualifier exactly as without it.
  THE PART THAT NEEDED CARE: `snapget.sh`'s quiesce runs on the SOURCE, in a
  script shipped over ssh and executed by `bash -s`, where no library function
  exists. The first attempt placed a gate call inside that heredoc -- it reads
  like local code and is not -- which would have broken remote quiesce outright.
  Reverted before it shipped. The remote half needs no edit at all: the shipped
  script's exit codes ALREADY distinguish "refused before freezing anything" (3)
  and "rolled back and thawed cleanly" (5) from "still frozen" (6) and "rollback
  incomplete" (7), structurally, because a failure in either cleanup turns 5 into
  6 or 7. So the whole remote decision is an rc mapping on the local side, and
  not one line of the shipped script changed.
  No transfer semantics changed: every edit is a parse, a name, a decision about
  whether to refuse, or a final status.
  Regression tests: `test/quiesce` gains 53 assertions (the grammar table with
  both halves, the gate with three mutation controls, and all seven remote codes
  in both directions); `test/runsuffix` gains the push/pull name-parity control
  with an unmarked negative control. The end-to-end -- a degraded run that
  transfers, lands and exits 8 -- has no local coverage and is a LIVE obligation.

- 2026-08-24 (snapget.sh, snapsend.sh): HOTFIX to the subtree verification
  landed hours earlier the same day. Independent review found it fail-open in
  two ways, both reproduced with executable discriminators:
  (1) an inventory error was accepted as success -- `src_have=$(... ) ||
  return 0` meant an ssh/zfs failure SKIPPED the check and let the run keep
  its success, i.e. the verification disappeared exactly when the link broke;
  (2) membership was a SUBSTRING test, so `pool/t/a@s3-extra` was accepted as
  proof that `pool/t/a@s3` exists.
  Both inventory calls now fail closed with a named diagnostic, and membership
  is an exact whole-line match (grep -Fxq). New suite test/subtree/run.sh pins
  all four cases plus the original skipped-descendant case in BOTH engines;
  the four review cases fail against the pre-fix engines (negative control
  run).

- 2026-08-24 (snapget.sh, snapsend.sh): under `-r` the verification now proves EVERY
  descendant landed, not just the root. The boundary the code stated --
  "the descendants rode the same stream and cannot have arrived separately"
  -- was measured FALSE in the pve1>pve9 campaign: `zfs recv` of a -R stream
  SKIPS a descendant whose local state cannot accept the increment, lands
  the rest, and exits 0. Reproduced deterministically on a purpose-built
  tree (a child carrying a manual snapshot the rest of the tree never had,
  plus the base deleted on the source): parent and sibling received the new
  snapshot, that child did not, and the run reported success. New
  validate_subtree costs two `zfs list` calls (one per side) and requires
  only the datasets that really carry the snapshot on the source; -X
  exclusions are skipped because they never entered the stream. Mirrored into
  snapsend.sh in the same change: the receive side behaves identically
  whoever pushed the stream, so the push engine carried the same hole (the
  twins suite refused the one-sided edit and named it). Owner direction:
  "Opisz po polsku znaleziska i naprawiamy".

- 2026-08-23 (lib-zfs-snap.sh): the ControlMaster socket is per RUN ($$ in
  the path), not per host+port. The shared master plus tune_ssh_close's
  '-O exit' meant the first concurrent run to finish killed every sibling's
  in-flight transfer (silent ssh 255, 'cannot receive: failed to read from
  stream', random victim). Measured live in the passive lab on same-minute
  relationships; diagnosed by PIPESTATUS probes (255 0 1) and ssh -v
  ('auto-mux: Trying existing master'). The within-run handshake saving
  that motivated the multiplexer is unchanged.

- 2026-08-23 (lib-zfs-snap.sh, two changes, one stage -- the seed-family /
  closing campaigns, owner-directed 'Rob'):
  (1) the progress watcher subshell now closes the inherited engine flock
  (exec 200>&-) -- it outlives the engine by design, and holding fd 200 kept
  the single-instance lock alive for seconds after every run, so the
  one-command flow's verify probe (firing right after its own seed) died with
  'Another instance ... is already running' on every FIRST enrolment while
  every manual retry passed.
  (2) progress_done/progress_mark_verified moved 2>/dev/null BEFORE the
  output redirect: bash opens redirects left to right, so a failing open of
  the record file was reported to the still-original stderr -- one
  'Permission denied' line per dataset in a delegated account's cron.log.
  Both measured live on pve9 before the fix; no transfer semantics touched.

- 2026-08-23 (snapget.sh, snapsend.sh, check-snap-age.sh): the DECLARED-PASSIVE
  stage, owner-directed ('Rob etap pasywny') from the LAB-E campaign findings.
  snapget/snapsend gain -E PREFIX (repeatable): in -e adoption, snapshots whose
  name starts with an excluded prefix can never be adopted as the base -- the
  newest NON-excluded snapshot wins even when an excluded one is newer. Proven
  live with the discriminating pair on pve9<->pve2: -E smiec_ adopted the older
  dobry_1; the control without -E adopted smiec_nowszy.
  check-snap-age.sh gains the explicit any-mode (pattern '-') and -x PREFIX
  exclusions: a passive relation watches 'the newest snapshot of anything,
  minus the excluded families'. The empty-pattern refusal stays untouched --
  silence is not a declaration. Age is printed in minutes under two hours,
  because 'age=0h' next to CRITICAL at a 20m threshold read as a contradiction.
  The owner's model, verbatim: passive takes the newest snapshot WHATEVER it is
  called; there are no recognisable prefixes in foreign names. Prefix-sniffing
  remains only where it was truthful all along -- the sync-chain guard, which
  detects OUR OWN family stamped by another instance.

- 2026-08-23 (snapget.sh, snapsend.sh, lib-zfs-snap.sh): live transfer
  progress. Owner-authorized as a STAGE ("obecnie szerzej -- chce widziec ile
  zostalo np z 4TB w trakcie transferu, a nie po"), which cannot be built
  without the engines: they are the only place that knows a transfer is
  happening.
  `zfs send` gains `-v -P`. That is the whole source of the numbers -- ZFS
  itself, no new dependency. Measured on zfs-2.1.11: a `size<TAB><bytes>`
  header immediately, then one `HH:MM:SS<TAB><cumulative><TAB><snapshot>` line
  per second, and in the PULL direction those come back over ssh's stderr
  intact.
  THE PART THAT NEEDED CARE, and the reason this is an engine change rather
  than a wrapper: the send's stderr is also where its ERRORS arrive, and the
  alerting path takes `tail -n 8` of that stream when a job fails. Progress
  lines left in it would replace the failure reason with a byte counter. So
  the stderr is captured to a file, a watcher reads it alongside, and
  progress_strip removes the progress lines before the file is replayed to
  stderr. Verified live: zero progress lines in the script's own log during a
  real transfer.
  ssh is untouched in the PUSH direction -- there it RECEIVES the stream on
  stdin, so the capture goes on the send, never on the ssh, and never `-n`.
  BOUNDARY, recorded rather than hidden: `-v` counts bytes the send PUSHED
  INTO the pipe, not bytes landed on the target. With compression and an
  mbuffer in between the difference is the buffer depth -- irrelevant on a 4 TB
  seed, but on a small dataset "100%" appears shortly before the receive
  finishes. Measuring the landed side would cost a second stream; not done.
  Best-effort throughout: an unwritable directory, a killed watcher or a
  malformed line must never affect the transfer. A record that stops being
  refreshed is reported as suspect by the reader, never deleted -- deleting it
  would destroy the only evidence that something died.

- 2026-08-23 (snapget.sh, snapsend.sh, delsnaps.sh, lib-zfs-snap.sh): `-n` on
  every READ-ONLY ssh invocation. Owner-authorized in chat after the exact
  scope was stated, because this is the kind of change the seal exists to make
  visible: it touches four frozen files and the transfer pipeline runs through
  two of them.
  ssh without -n reads its stdin to EOF and hands it to the remote command.
  None of these calls want that; all of them were taking it. The visible
  consequence is that any confirmation prompt printed AFTER engine work cannot
  be answered from a pipe -- `seed` and `activate` refused "not confirmed" no
  matter what was fed in, because the engine had already drained the answer.
  On a terminal it works (stdin is the tty), so it never appeared in hand
  testing; it appeared the moment anything was scripted. Found running issue
  #9's four-command trial. Measured on pve9, engine driven directly:
      printf 'ZOSTALO' | { ./snapget.sh -n ... >/dev/null; read -r x; ... }
        -> [PUSTO]
  38 invocations changed. FOUR were deliberately left alone, and they are the
  reason this needed authorization rather than a sweep -- each one carries the
  PAYLOAD on stdin, and -n there would break the transfer outright:
      snapsend.sh:1011,1015   zfs send | [compress |] ssh "mbuffer | zfs recv"
      lib-zfs-snap.sh:980     throughput probe piping into ssh "cat > /dev/null"
      lib-zfs-snap.sh:2504    the quiesce script fed to ssh "bash -s"
  A first, cruder attempt at this landed in zfs-backup.sh alone (#127) and was
  necessary but NOT sufficient: `activate` still refused, because the catch-up
  it runs on the way calls the engine. That is recorded here rather than
  quietly superseded -- the earlier claim was too strong.

- 2026-08-23 (snapsend.sh + snapget.sh): the landing check moved BEFORE the
  durable yes. Same authorization as the entry below it -- this is that change
  finished, not a new one. Caught in review: the first cut ran the verification
  AFTER release_snapshot, clear_inflight_snap and record_send_bookmark, so a
  failed verification returned 1 while the hold protecting the snapshot was
  already gone, the in-flight marker was already cleared, and the bookmark
  already pointed at a target nobody had confirmed. Durable state said "done"
  about a transfer the same function was in the middle of calling failed, and
  the retry would have found its base unprotected and prunable. A proof that
  runs after the thing it is meant to gate is decoration.
  Proven live with the discriminating test the review asked for:
      comparator = false -> EXIT=1, bookmarks created 0, hold still held 1
      normal run         -> EXIT=0, bookmarks created 1, hold released 0
  No transfer semantics changed: the same check, earlier in the same function.

- 2026-08-22 (snapsend.sh + snapget.sh): a transfer must PROVE it landed.
  Owner-directed in those words -- "Bierz i idz po kolei" against a list whose
  first item was exactly this, after I argued it was the only item on that list
  where the product can currently report success about a backup that is not
  there. Until now the sole evidence was the pipeline exiting 0, which says the
  processes did not crash. Every live campaign in this project has been verified
  by a human comparing GUIDs by hand afterwards -- I did it on every hop of
  every pass today -- precisely because the tool could not say it.
  NOT new machinery: validate_snapshot already compares ZFS's own identity for
  a snapshot on both sides, and both engines already trusted it to decide
  whether an existing target snapshot is the same one. It is now also called
  after a successful transfer, so "success" means the snapshot is on the target
  carrying the source's GUID. A second comparator was deliberately not written:
  two definitions of "the same snapshot" would drift, and this project spent
  today paying for exactly that kind of duplication (the fourth copy of the
  family probe).
  BOUNDARY, recorded rather than hidden: under -r the subtree travels as ONE
  stream, so this proves the ROOT landed; descendants rode the same stream and
  cannot have arrived separately, but are not individually checked. Under -R
  every dataset is its own job and every one is proven.
  Proven live with both controls:
      normal transfer     -> "Verified: hdd/vtgt/hdd/vsrc@vtest2_... carries
                              the source's GUID", run succeeds
      comparator says no  -> "VERIFY FAILED: ... the transfer reported success
                              but the snapshot cannot be confirmed", EXIT=1
  The negative control was produced by forcing a false verdict from the
  comparator on a scratch copy of the engine -- it proves the WIRING (a failed
  verification becomes a failed dataset and a non-zero run, so cron alerts),
  not the comparator, which this file already relied on for the same question.

- 2026-08-22 (snapsend.sh + snapget.sh): a long transfer can be WATCHED from a
  terminal. Authorized in those words -- "zrob progres transferu, masz zgode" --
  after the owner rejected the ordering I proposed, and he was right to. I wanted
  to mine the duration history first; production says there is nothing there to
  mine. Measured the same day: hdd/vm-disks/subvol-101-disk-1, 4.39 TB
  referenced, ships **624 bytes** in an hourly incremental, and 532 runs average
  0.3 s. The history is a flat line. The case that actually needs an eye is the
  SEED -- "wyobraz sobie task inicjalny 4TB, puszczamy i nic nie widzimy" -- and
  it is the one case no history can serve, because a first run has nothing to
  compare against.
  Not new machinery: mbuffer has counted bytes and rate all along and every
  pipeline in both engines ran it with `-q`. The mute is now lifted ONLY when
  stderr is a tty. From cron nobody is watching and mbuffer's status would land
  in the stderr cron appends to cron.log, turning the one file an operator greps
  into a rate meter -- so there the behaviour is byte-for-byte what it was.
  No percentage, deliberately: mbuffer cannot be told a total, and `pv` (which
  can, and which syncoid uses for exactly this) is installed on none of these
  hosts. Instead the total is ANNOUNCED once from a `zfs send -nP` dry run that
  splices -nP into the REAL send command, so it can never describe a different
  stream than the one that follows. Fail-soft by construction: a size that could
  not be measured is a line that is not printed, never a transfer that does not
  run.
  Proven live the same day, both paths and both silences:
      local push  : "about to move 400.7 MiB" then "summary: 401 MiByte in 0.6sec"
      remote pull : the same announcement, then mbuffer's running total every
                    second -- 50.5, 98.8, 147, 198, 244, 289, 335, 382 MiB --
                    and "summary: 401 MiByte in 4.4sec - average of 91.4 MiB/s"
      no tty      : zero lines. Not fewer -- zero.
  No transfer semantics changed: every edit is a message, a `[ -t 2 ]` test, or
  a dry run that moves nothing.

- 2026-08-21 (snapget.sh v2.69 -> v2.70): under -e, an -R-EXPANDED child with
  no matching family is scaffolding and is skipped with a log line instead of
  failing the run; a REQUESTED root with nothing to adopt stays the hard error
  it always was. Authorized live during LAB6 pass 5: the chain middle's empty
  path containers (created by recv -p, never snapshotted by anything) failed
  every passive seed and would have failed every passive cron tick, while the
  leaves transferred correctly (guid-verified). The upper layer cannot fix
  this honestly -- enumerating leaves at activation freezes membership, which
  the owner rejected; under -e the family IS the membership, so the engine has
  to be the one that says "no family here means not a member".
  Refined in the same authorization after pass 6 measured the first cut: the
  REQUESTED root under -R is a subtree designator and may itself be
  scaffolding (the chain root's family lives only in its descendants), so
  under -R -e ANY member with no family is skipped, and a new aggregate guard
  fails the run only when NOTHING in the whole expansion had a family --
  "success" must never report an adoption that never happened. The first cut
  also planted its membership flag in the quiesce loop instead of the
  transfer loop (same iterator spelling, two screens apart) -- caught by the
  live campaign, not by any suite, and worth recording for the next surgeon.

- **2026-08-17** -- `delsnaps.sh`: failure-cause-specific destroy hints
  (lab3 campaign, owner direction "napraw błędy"). The unconditional
  "dependent clones" hint sent a live investigation the wrong way while the
  real error was a missing `mount` ability in the delegation; the hint is now
  chosen from zfs's actual stderr. No retention semantics changed.
- **2026-08-20** -- `check-snap-age.sh`: an empty pattern is refused (PR #61).
  A CONTRACT NARROWING, and recorded as one. The match is a literal prefix, so
  an empty pattern matched every snapshot on the dataset -- measured live on
  pve2 at one instant: `automated_hourly` gave age 3h, empty gave
  `__replicate_107-0_...` age 2h. A monitor scoped that wide reports the
  freshness of whatever else touches the pool and can never go red for this
  project's own family.
  **NOT pre-authorised.** It came out of a cleanup sweep on my own initiative;
  the owner was told in the message that shipped it, not before. Written down
  that way because this list is worth nothing if it records only the
  comfortable cases -- and because this file is the one that gained
  `check-snap-age.sh` in the first place for narrowing an approved contract
  (REV-20260808-070 F1).
- **2026-08-20** -- `snapsend.sh` + `snapget.sh`: a `THE TWIN` header pointing
  at the 2026-08-04 decision NOT to merge the engines (PR #66). COMMENTS ONLY:
  44 lines added, count of changed non-comment lines zero, and the twins
  baseline confirmed the pinned function hashes did not move. Also not
  pre-authorised, same batch of work.
- **2026-08-20** -- `lib-zfs-snap.sh`: a peer whose pair gate is DISABLED is
  named as such instead of guessed at (O12). **PRE-AUTHORISED** by the owner,
  in those words: *"Odblokuj silnik i napraw O12"* — the first entry on this
  list that was directed beforehand rather than reported afterwards.
  Measured on metropolis the same day: the gate answered
  `PAIR_DISABLED: relationship pve1 is disabled by administrator`, and the
  library reported *"exit 93 -- e.g. no 'zfs' in this account's PATH"*. It had
  the answer in hand and guessed a different one — the same family as the
  exit-255 confusion that block already exists to end.
  Three call sites, and the third matters most: `pool_health` discarded the
  exit status, so the refusal fell through to `UNKNOWN`, and
  `check_pool_health` MAILS on anything that is not ONLINE. An administrative
  block was raising a **storage alarm** about a perfectly healthy pool. It now
  reports `PAIR-DISABLED`, says why, and raises no alert — the instrument for
  "this relationship stopped copying" is `check-snap-age`, in its own terms.
  **No transfer semantics changed:** every edit is a diagnosis, a return value
  already reserved for "unknown", or the suppression of a false alert.
  Carried along, because unit-testing `pool_health` directly for the first time
  exposed it: both cache-keyed helpers built their key inside the same `local`
  that declared its inputs. Bash expands those words before the builtin runs,
  so the key came from the OUTER scope — unbound under `set -u`, and silently
  the WRONG VALUE when an outer `pool` existed. It worked only because
  `check_pool_health` happens to declare its own `local pool` immediately
  before calling. Fixed in `pool_health` and its twin `csend_pool_has`; the
  stake is a cache key, so a wrong one crosses pools.
  Regression tests: `test/quiesce` gains 11, verified to fail on the frozen
  baseline and pass after — including controls that the new recogniser does
  NOT relabel an ordinary remote failure as an administrative block.

## How it is enforced

`./test/impact.sh --verify` compares each frozen file's **index entry** — mode
and object id, the same primitive REV-20260807-068 arrived at — against the
baseline recorded above. A difference is refused, naming the file.

There are two ways past that refusal, and both are live -- see the table above
for who owns which. This sentence used to say "only the second one is live" while
labelling the first one "operative" and the second one "dormant", which was
wrong in both directions.

### The routine route: owner direction + `--refreeze`

```text
# 1. the owner directs the change (or is told, in the same breath, that it
#    happened -- see the honest entries in the list above)
# 2. implement, stage, verify
# 3. re-take the baseline, which also resets unfreeze: back to -
./test/impact.sh --refreeze
# 4. ADD AN ENTRY TO THE LIST ABOVE: date, files, what changed, and whether it
#    was directed beforehand. This step is the whole mechanism.
```

Step 4 is not paperwork. `--refreeze` is one command and anyone can run it, so
the baseline reset is not what makes the change visible -- the ENTRY is. A
refreeze with no entry is exactly the silent engine edit this document exists to
prevent, performed by the person the document was written for.

### The reviewed route: an authorising pre-review

Implemented in `test/impact.sh`, and exercised for the first time on 2026-08-26:
the quiesce-degrade change was submitted for pre-review BEFORE any engine line
was written, and the reviewer returned an `authorizes-frozen` marker naming
exactly the three files the change was allowed to touch -- and excluding
`delsnaps.sh` and `check-snap-age.sh`, which the change had argued it did not
need. The refusal lifts when **all** of:

1. `unfreeze:` names a review that exists;
2. that review is not CLOSED — a closed review was answered and the answer was
   accepted, so it cannot authorise new work;
3. that review carries a **reviewer-owned** `<!-- authorizes-frozen: <paths> -->`
   marker, and **every** changed frozen path appears in it.

Point 3 is REV-20260808-070 F2. Without it the gate only asked "is some review
open", so any unrelated open thread could be named to wave an arbitrary engine
edit through — weaker than what this document claimed. The marker is written by
the reviewer, in the review artifact, because authorisation is theirs to give.
Never inferred from prose.

## What this does not do

It is **not** tamper-proof, and pretending otherwise would be the same error as
a verdict that claims more than it measured. Anyone can run `--refreeze` and
commit. What it removes is the *silent* case: an engine edit can no longer land
without a visible baseline reset sitting in the diff.

Owner decision, 2026-08-20: **that is what it is for, and the document now says
so instead of describing a lock.** It is a seal, not a bolt -- the scissors are
tied to it on a string. It does not stop the box being opened; it makes an
opened box impossible to mistake for a closed one. The alternative considered
and declined was a gate the implementer genuinely cannot open (a reset only the
owner may commit), on the grounds that the visibility is what has actually been
paying: both engine changes on 2026-08-20 were stated as engine changes in their
pull requests, in the words "contract narrowing on a frozen file", precisely
because this gate made them say it.

The failure mode to watch is therefore not someone forcing the seal. It is a
refreeze whose entry never gets written -- at which point the diff shows a
baseline moving for no stated reason, and nobody knows whether that was a
comment or a change of behaviour.

It also cannot judge whether the change is a good one. It answers "was this
authorised", not "was this wise". That is review, not tooling.
