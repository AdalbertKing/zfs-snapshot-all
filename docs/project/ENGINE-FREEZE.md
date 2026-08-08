# Engine freeze

<!-- frozen: snapsend.sh 100755 aff7b28d5ce0b8d0332ad74793c07538920c5870 -->
<!-- frozen: snapget.sh 100755 898fe0ebd903ca5322201d139928f5448836483d -->
<!-- frozen: lib-zfs-snap.sh 100644 902b307cbcac9fbedf7c3f076334a801884f3666 -->
<!-- unfreeze: - -->

**Machine markers above. Written by `./test/impact.sh --refreeze`, checked by
`--verify`. Do not edit them by hand** — a hand-typed baseline is a baseline
nobody measured.

## What is frozen

The two transfer engines and the library they both run on:

| file | why it is in scope |
|---|---|
| `snapsend.sh` | the push engine |
| `snapget.sh` | the pull engine |
| `lib-zfs-snap.sh` | the code both of them execute |

**Not frozen, deliberately:** `gen-cron.sh`, `deploy.sh`, `delsnaps.sh`,
`check-snap-age.sh`, `zfs-backup.sh`, the pair-gate and the test tree. Those are
where the remaining planned work lives — profiles, scope reconciliation,
restore. Freezing them would freeze the roadmap, not the risk.

## What the freeze means

A change to a frozen file requires a review **before** the implementation, not
after it. That is the whole point: the engines are the code every relationship
in the fleet executes nightly, they now have 619 assertions of live evidence
behind them, and the cheapest way to lose that is a small edit that seemed
obvious.

## How it is enforced

`./test/impact.sh --verify` compares each frozen file's **index entry** — mode
and object id, the same primitive REV-20260807-068 arrived at — against the
baseline recorded above. A difference is refused, naming the file.

The refusal lifts only when `unfreeze:` names a review that exists and is not
yet CLOSED. A closed review cannot authorise new work: it was answered, and its
answer was accepted.

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
