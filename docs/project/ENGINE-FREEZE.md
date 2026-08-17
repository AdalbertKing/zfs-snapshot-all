# Engine freeze

<!-- frozen: snapsend.sh 100755 aff7b28d5ce0b8d0332ad74793c07538920c5870 -->
<!-- frozen: snapget.sh 100755 898fe0ebd903ca5322201d139928f5448836483d -->
<!-- frozen: delsnaps.sh 100755 b792c0c1d160b44c404d444d43dcbae392554219 -->
<!-- frozen: check-snap-age.sh 100755 59dda7e685f8f2d39dea638b95ee9341313fbfb1 -->
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

## How it is enforced

`./test/impact.sh --verify` compares each frozen file's **index entry** — mode
and object id, the same primitive REV-20260807-068 arrived at — against the
baseline recorded above. A difference is refused, naming the file.

The refusal lifts only when **all** of these hold:

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

The sequence for an authorised engine change:

```text
# 1. the reviewer opens REV-YYYYMMDD-NNN asking for the change
# 2. record the authorisation
#    edit the unfreeze: marker to name that REV
# 3. implement, stage, verify, commit as usual
# 4. after the review closes, re-take the baseline:
./test/impact.sh --refreeze
#    which also resets unfreeze: back to -
```

## What this does not do

It is **not** tamper-proof, and pretending otherwise would be the same error as
a verdict that claims more than it measured. Anyone can run `--refreeze` and
commit. What it removes is the *silent* case: an engine edit can no longer land
without either a named authorising review or a visible baseline reset sitting in
the diff, where a reviewer reads it.

It also cannot judge whether the change is a good one. It answers "was this
authorised", not "was this wise". That is review, not tooling.
