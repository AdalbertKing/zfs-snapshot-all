# Quiesce that fails: no snapshot, or a labelled crash-consistent one?

Owner question, 2026-08-25, during the profile stage. Recorded now, implemented
later: the engine change this needs is deliberately **not** part of the profile
work, but the profile grammar is being shaped so the patch drops in without
rewriting any profile.

## What happens today, measured

`snapsend.sh -q auto` on a guest that cannot be frozen:

```
QERR 1 guest(s) could not be quiesced -- NOT taking a snapshot,
     because it would be crash-consistent while reporting success
exit 5
```

No snapshot is taken at all. That is REV-20260730-006 §2, and the reason in the
code says exactly what the objection was:

> the loop used to discard the result, so a failed freeze printed QERR and the
> run went on to snapshot anyway and exit 0 -- an operator who asked for
> application-consistent got crash-consistent and was told it worked.

**The objection was about LYING, not about the value of the snapshot.** That
distinction is the whole design space here.

## The hole the owner named

Fail-closed costs a different amount per tier, and the original decision did not
weigh that:

| tier | what a failed freeze costs | when you find out |
|---|---|---|
| `_hourly` | 1 of 24, next one in an hour | 90 min (monitor_warn) |
| `_daily` | **1 of 7, and it is the durable artifact** | 30 h |
| `_monthly` | 1 of 6 -- a month-long hole | **never**: that monitor was removed 2026-07-22 |

For the hourly family, refusing costs almost nothing. For the daily family it
costs the thing the tier exists to produce. For monthly, nothing even reports
it.

There is a host on this estate where the asymmetry is sharper still: on `vsql2`
our quiesce aborts SQL backups on ~400 databases. There, "crash-consistent
instead of nothing" is not merely better than nothing -- it is better than the
freeze.

## The shape that answers the original objection

Not a return to fail-open. A DEGRADATION THAT CANNOT BE MISTAKEN FOR SUCCESS:

```ini
[template:daily]
	prefix  = automated_daily_
	quiesce = auto            # today: freeze failed -> no snapshot
```
```ini
[template:daily]
	prefix  = automated_daily_
	quiesce = auto,degrade    # freeze failed -> crash-consistent, and VISIBLE
```

`degrade` is only honest if all three hold at once:

1. **the snapshot is distinguishable** -- a different name (e.g.
   `automated_daily_crash_<stamp>`), so whoever restores it can see what they
   are getting, and so retention counts it for what it is;
2. **the run reports the degradation** -- an alert, not a line in a log nobody
   reads;
3. **the operator opted in beforehand**, per tier.

With those, nobody receives application consistency together with an assurance
that it worked. They receive the weaker thing, and they know it is weaker.

## Where the decision lives

| layer | holds |
|---|---|
| **tier, in the profile** | the DECISION: `quiesce = auto,degrade`. It is policy about *these data* -- the same axis the `-q` itself sits on |
| **host `.ini`** | the DEFAULT for this host when a tier says nothing |

Same layering the target already uses: `server.conf DEFAULT_TARGET` as the
default, an explicit per-relationship value as the override. It lets `vsql2`
turn degradation on once for the host while pve1 keeps fail-closed, without
touching a profile.

This is also the first concrete content anyone has found for a host-level
defaults file. Until now the argument against building one was that it would
hold nothing; that argument no longer applies to this field.

## Why it is not being implemented now

`-q` has three modes (`agent`, `sync`, `auto`) and a hard `exit 5`, and the
engines are FROZEN. A fourth mode is a contract change: an entry in
`docs/project/ENGINE-FREEZE.md`, a review **before** implementation, and
`--refreeze`. It also changes what an operator gets at restore time, which is
not something to fold into a profile commit.

## What the profile work must do now, so the patch drops in later

1. **`quiesce` stays per TIER.** Already true and measured: production pve1 runs
   `hourly` with no quiesce and `daily`/`weekly`/`monthly` with `quiesce = auto`.
   Any profile shape that collapses quiesce to one per-profile value (as the
   reviewer's `[data] quiesce = none` sketch does) makes this patch impossible
   to express and cannot describe production either.
2. **The spelling is reserved here**, so nobody invents a competing one:
   `quiesce = <mode>[,degrade]`, extending the existing field rather than adding
   a second one. A separate `quiesce_fallback` field would let the two disagree.
3. **No profile writes `degrade` yet** -- `lint_quiesce` accepts `no|agent|sync|
   auto` and would refuse it. Writing it early would produce profiles that do
   not render.

## Acceptance criteria for the future patch

- a failed freeze under `degrade` produces a snapshot whose NAME says it is
  crash-consistent, and an alert;
- a failed freeze WITHOUT `degrade` still takes no snapshot and still exits 5 --
  the discriminator for that must survive;
- retention treats the degraded snapshot as belonging to its tier (a hole in the
  ladder is what this exists to prevent);
- restore names the difference where the operator can see it before choosing.
