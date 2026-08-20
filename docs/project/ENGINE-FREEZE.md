# Engine freeze

<!-- frozen: snapsend.sh 100755 274baf7ec76e59cee3bfea961486c11aa485517f -->
<!-- frozen: snapget.sh 100755 675f46d1664351f9219ed3012ad2b2d52573982c -->
<!-- frozen: delsnaps.sh 100755 b792c0c1d160b44c404d444d43dcbae392554219 -->
<!-- frozen: check-snap-age.sh 100755 d9fa660e813a71d929a3bafbadc1a076b60eae5c -->
<!-- frozen: lib-zfs-snap.sh 100644 902b307cbcac9fbedf7c3f076334a801884f3666 -->
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
