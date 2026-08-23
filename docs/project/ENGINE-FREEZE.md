# Engine freeze

<!-- frozen: snapsend.sh 100755 2920feff488c1c81f99b138e88c41ee7ee66a3dd -->
<!-- frozen: snapget.sh 100755 9b8ab52b93bb201df5177bd180b9f8630ba05fa1 -->
<!-- frozen: delsnaps.sh 100755 6e6381924dd09d347c13fc71fce71607f72c80f8 -->
<!-- frozen: check-snap-age.sh 100755 d9fa660e813a71d929a3bafbadc1a076b60eae5c -->
<!-- frozen: lib-zfs-snap.sh 100644 bdb0d002f9b71dd3a02c04577760ca6480d5ba19 -->
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

## Authorization under the post-2026-08-15 regime

The reviewer and the REV pipeline were removed by the owner on 2026-08-15
(`HANDOFF.md`), so points 1-3 below describe machinery that can no longer be
exercised as written. The freeze itself stays -- its value (no frozen engine
changes in passing) does not depend on who the authority is. The authority is
now the OWNER: a frozen file changes only on an explicit owner direction, the
change is recorded here in prose with the date and the direction it answers,
and `--refreeze` re-pins the baseline as part of the same change.

Owner-authorized refreezes:

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

There are two ways past that refusal. Only the second one is live.

### The operative route: owner direction + `--refreeze`

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

### The dormant route: an authorising review

Still implemented in `test/impact.sh`, and it cannot be exercised: it needs a
reviewer, and the owner removed that role on 2026-08-15 (`HANDOFF.md`). Kept
rather than deleted because the machinery is small, correct, and would work
again if the role came back. The refusal lifts when **all** of:

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
