# A dataset cannot be late before it exists

Status: **proposal**, no code written. Found while analysing the operational
consequences of `recursive` (REV-054/055) for a newly created guest. Owner has
decided the shape; this note asks the reviewer to settle the contract details.

## The defect

`check-snap-age.sh` has two answers for "no snapshot matches the pattern":

- no snapshots **at all**, on a `-R` discovered descendant → `SKIP`, silent.
  This is the container-node leniency and it is correct.
- **any** snapshot, none matching → `CRITICAL`, unconditionally
  ([check-snap-age.sh:193](../../check-snap-age.sh)).

The second branch never asks how long the dataset has existed. So a guest
created at 15:00 that acquires *any* non-matching snapshot before its first
scheduled backup is reported as a stale backup — of a dataset that has not yet
had the chance to have one.

### It is reachable in production, not theoretical

On `192.168.11.11`, whose monitor is `check-snap-age.sh -R "rpool/data"
"automated_"`, the children already carry pvesr snapshots:

```
rpool/data/vm-100-disk-0@__replicate_100-0_1786096803__
rpool/data/vm-106-disk-0@__replicate_106-0_1786096828__
rpool/data/vm-106-disk-1@__replicate_106-0_1786096828__
```

A new guest on that host gets a `__replicate_` (or `vzdump`) snapshot from
Proxmox itself, and the hourly `automated_` job runs at :01. Between those two
moments the dataset has snapshots, none matching, and the monitor calls it
CRITICAL.

Reproduced directly on scratch datasets (metropolis pve2, 2026-08-07):

```
SKIP     dataset=.../fresh-novm    -- no snapshots at all
CRITICAL dataset=.../fresh-manual  -- no snapshot found matching this pattern
rc=2
```

`fresh-manual`'s only snapshot was one an admin had just taken.

### Severity, stated accurately

All four hosts run `ZFS_ALERT_MODE` at its default `daily`, so this is **one
false line in the daily digest**, not a mail every 15 minutes. An earlier
version of this analysis said the latter; that was wrong and is corrected here.

The cost is not volume, it is trust: a digest that routinely carries false
"backup stale" lines is a digest that gets skimmed, and skimming is how a real
stale backup gets missed.

## Proposed rule — remove the special case, do not add a knob

When no snapshot matches the pattern, **use the dataset's own creation time as
the effective age** and run it through the existing severity ladder, instead of
jumping to CRITICAL.

```
age = NOW - creation(dataset)      # instead of "no match -> CRITICAL"
```

| situation | today | proposed |
|---|---|---|
| created 10 min ago, no backup yet | CRITICAL | **OK** |
| created 3h ago, warn=90m crit=3h | CRITICAL | **CRITICAL** (unchanged) |
| created 2h ago, warn=90m crit=3h | CRITICAL | **WARNING** (new, and correct) |
| created 3 days ago, never backed up | CRITICAL | CRITICAL (unchanged) |

The alarm now fires when the promise is actually broken rather than before it
falls due. It also gains a WARNING band this case never had.

Owner's decision, recorded: apply it **uniformly**, to explicitly named
datasets as well as `-R` discovered ones — it is the same arithmetic, and two
different answers to one question is how a dependency tree and a technical-debt
generator get built. No new config field, so no change to `gen-cron.sh`,
`cron2conf.sh`, generated crontabs, or any deployed config.

Unchanged: the "no snapshots at all on a discovered descendant" leniency stays
exactly as it is. Without it every intermediate container node would start
alerting.

### Verified as feasible

- `zfs get -Hp -o value creation <dataset>` is readable by the **delegated
  account** with the existing grant — no new `zfs allow` (measured on pve2).
- A **received** dataset's `creation` is the time of receipt, not the source's
  (`1786100206` vs `1786100201` on a 5-second-old send). So the rule behaves
  the same on a backup target, where monitors also run — a freshly received
  dataset is correctly "new" there too.

### Rejected alternatives

- **`monitor_grace = <duration>` config field.** Same effect, but a new field
  through the generator, `cron2conf`, fixtures and every config. More surface
  for no additional expressive power.
- **Ignore non-matching snapshots on discovered descendants.** This deletes the
  finding worth keeping — "has vzdump snapshots for weeks, has no backup". A
  silent hole.
- **An exclusion list in the monitor, like `delsnaps -P`.** Handles the pvesr
  case, does nothing for an admin's manual snapshot, and creates a second
  exclusion list to keep in agreement with the first.

## What the reviewer is asked to settle

1. **Message wording at CRITICAL.** The line must still say no matching
   snapshot was found, but the age now comes from the dataset rather than from
   a snapshot, and an operator reading `age=72h` should not have to guess which.
   Proposed: keep the existing sentence and append the provenance, e.g.
   `-- no snapshot found matching this pattern (age measured from dataset
   creation)`. Wording is a contract here: `test/alertmail` already pins quoted
   strings elsewhere, and the digest carries this text to a human at 07:00.

2. **Unreadable `creation` must be UNKNOWN, not a fake age.** The existing
   snapshot path has a latent bug worth not copying: `newest_epoch` is used
   unquoted in `$((NOW - newest_epoch))`, and bash reads an empty value as 0, so
   a failed `zfs get` yields an age of the whole Unix epoch and a CRITICAL with
   a nonsense number. Fail-closed, but it reports a fabricated measurement.
   Proposal: the new path returns UNKNOWN (exit 3) when `creation` cannot be
   read. Open question: fix the existing snapshot path in the same change, or
   keep them separate?

3. **`-v` output for the "too new" case.** Silence is right for cron; but a
   human running `-v` to ask why a dataset is not alerting deserves a line.
   Proposed: an `OK` line stating the age came from creation.

4. **Test obligations.** `test/monitor` (or wherever check-snap-age's cases
   live) with: a dataset newer than warn, one between warn and crit, one older
   than crit, each with a non-matching snapshot present; plus the container-node
   leniency unchanged; plus a negative control proving the new cases fail
   against the current code. No ZFS-free path exists for `creation`, so this
   likely needs the root/ZFS suite rather than the local one — confirm whether
   that is acceptable or whether a stub is wanted.

## Out of scope

This does not address a dataset that never gets *any* snapshot and is therefore
invisible to the monitor by design — the silence-is-not-coverage problem, which
is thread #22 (pve0's unbacked guests) and needs scope reconciliation, not a
monitor change.
