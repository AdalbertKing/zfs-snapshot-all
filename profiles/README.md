# The shipped profiles

A profile is an admin **template** — what to keep, how often, and whether the
snapshot is coherent. It never says where from or where to; that belongs to the
relationship.

## The name tells you two things

**The letters and digits are the retention.** `d30h24` keeps thirty daily and
twenty-four hourly, and nothing else — no weekly, no monthly, because the name
does not claim any. `test/profiles` asserts this against the `delsnaps` line the
real generator renders, so a filename that lied would fail the suite rather than
mislead somebody reading `ls`.

**The case is the shape** (owner rule, 2026-08-27):

| case | shape | prunes with |
|---|---|---|
| lowercase `d30h24` | one family **per tier**, each with its own prefix and its own counter | one `delsnaps` line per tier |
| uppercase `D30H24` | **one family**, several counters over it — the GFS ladder | one `delsnaps -G` line |

**A suffix names the retention MECHANISM when it is not the catalogue default.**
The numbers say how much is kept and the case says how many families; neither
says HOW the counting is done, and there are three ways:

| mechanism | flag | what survives | suffix |
|---|---|---|---|
| flat count | `-H24` | the 24 newest | none — the catalogue default |
| GFS ladder | `-G -H24` | one per hourly bucket, for 24 hours | `-gfs` |
| age | `-h24` | everything younger than 24 hours | `-age` |

Measured on identical data (three snapshots taken inside one hour, which is
what a catch-up burst looks like): flat kept two, the ladder kept one, age kept
all three. They agree while the cadence is regular and part company at both
edges — after a burst age bounds nothing, and after downtime age keeps less
than a count would, because the survivors aged out while the job was not
running.

A bare name therefore always means the catalogue default. `y5m12d31h24` is
deliberately not shipped: we ship its `-gfs` and `-age` forms, and the bare
name stays reserved so it cannot mean two things.

**The flat count is the only mode that survives a long outage, and that is a
measurement rather than an opinion** (pve10, the real `delsnaps.sh`,
2026-09-04). A ladder rung is anchored on the WALL CLOCK -- `GFS_NOW` defaults
to `date +%s` -- and `delsnaps.sh` deletes anything older than the outermost
rung. Six snapshots, one prune run, a machine that had been off for thirty
days: flat `-H24 -D7` kept 6 of 6, `-G -H24 -D7` kept **0 of 6** (`rc=0`, no
warning, nothing in the mail), `-G -H24 -D30` kept 1. A family whose newest
member has aged past its ladder's reach is deleted entirely on the first prune
after the machine comes back. `m31w4d7h24` is the shipped answer to that:
four families, four flat counters, no `gfs` anywhere.

`Y5M12D31H24` is the first UPPERCASE profile, and it needed no new suffix: the
case rule above already said "one family, several counters over it". It was
added 2026-09-01 to close a real hole rather than a missing combination -- the
only unquiesced profile was `default`, which stops at about a month, so "five
years, and I cannot freeze anything" (guests with no agent, plain filesystems,
the LVM/ext4 adaptation) had no answer and meant hand-editing. On one family
quiesce cannot be per-tier at all: the daily snapshot IS one of the hourly ones
the ladder kept, so it is all twenty-four freezes a day or none. That is why
its "quiesced" column reads "none -- a ladder cannot" rather than "off".

**One practical constraint, stated because it is invisible until it bites.**
The case rule cannot ship BOTH cases of the same retention while the repository
is developed on a case-insensitive filesystem: this working copy has
`core.ignorecase = true`, so `Y5M12D31H24.conf` and a future bare
`y5m12d31h24.conf` could not coexist in it. That is not a problem today
precisely because the bare lowercase name is reserved and unshipped -- but it is
a second reason to keep it reserved, on top of the ambiguity reason above.

A per-tier profile may additionally put `gfs = yes` on a tier, which makes that
tier's own line carry `-G`: its family is then pruned by **time buckets** ("one
an hour for the last 24 hours") instead of by a **flat count** ("the 24
newest"). The two coincide while the cadence is regular and diverge sharply
after a catch-up burst — measured on pve9, 2026-09-01, with three snapshots
taken inside one hour: flat `-H2` kept the two newest, `-G -H2` kept one per
bucket. `y5m12d31h24` is the shipped example: four prefixes, four one-rung
ladders, and each tier's prune leaves the other three families alone.

No uppercase profile is shipped yet. The distinction exists so that when one is,
the two shapes are told apart from `ls` without opening either file.

> **The two cases of one name may never both be shipped.** On a case-insensitive
> filesystem — any Windows or macOS checkout — `D30H24.conf` and `d30h24.conf`
> are the same file: writing one overwrites the other, and deleting it deletes
> both. The Linux hosts would keep them apart, so the breakage would show up
> only on a workstation, as a profile that quietly changed shape. `test/profiles`
> refuses a catalogue containing both.

`default`, `prod` and `passive` are named in prose instead and describe
themselves in their own headers.

## Why the shape matters: coherence

A **ladder** cannot answer the coherence question. On a ladder the "daily"
snapshot *is* an hourly snapshot the counter decided to keep — one object on
disk serving several counters — so freezing the daily one means freezing all
twenty-four, which stalls every guest on the host 24 times a day.

**Per-tier** profiles can pay for the freeze once. So:

> **the coarse tiers are coherent, the hourly one never is.**

Asserted for the whole catalogue in `test/profiles`, against the rendered cron
line rather than the `quiesce` field, because the field has to survive
namespacing, template merging and the flags assembler before it becomes `-q` —
and it is the `-q` the host runs.

A failed freeze costs a name, not a snapshot: since 2026-08-27 the set is
stamped anyway as `automated_daily_crash_<timestamp>` and the run exits 8, so
cron reports it instead of filing it as clean. `,strict` is the way back for
data where a crash-consistent copy is genuinely worthless. See
`docs/design/quiesce-degrade.md`.

## The catalogue

| profile | creates | keeps | coherent tiers |
|---|---|---|---|
| `default` | one family, hourly | GFS ladder 24/7/4/12 | none — a ladder cannot |
| `prod` | four families: hourly, daily, weekly, monthly | 24 / 7 / 4 / 6 | daily, weekly, monthly |
| `d30h24` | two families: hourly, daily | 24 / 30 | daily |
| `d30h24-gfs` | the same two families | 24 / 30, each a `-G` ladder over its own prefix | daily |
| `d30h24-age` | the same two families | the same numbers BY AGE (`-h24 -d30`) | daily |
| `d7h24` | two families: hourly, daily | 24 / 7 | daily |
| `d7h24-gfs` | the same two families | 24 / 7, each a `-G` ladder over its own prefix | daily |
| `d7h24-age` | the same two families | the same numbers BY AGE (`-h24 -d7`) | daily |
| `d30` | one family, daily | 30 | daily |
| `y5m12d31h24-gfs` | four families: hourly, daily, monthly, yearly | 24 / 31 / 12 / 5, each a `-G` ladder over its own prefix | daily, monthly, yearly |
| `y5m12d31h24-age` | the same four families | the same numbers BY AGE (`-h24 -d31 -m12 -y5`) | daily, monthly, yearly |
| `m12w4d7h24-gfs` | four families: hourly, daily, weekly, monthly | 24 / 7 / 4 / 12, each a `-G` ladder over its own prefix | daily, weekly, monthly |
| `m31w4d7h24` | four families: hourly, daily, weekly, monthly | 24 / 7 / 4 / 31, each a flat COUNT over its own prefix | daily, weekly, monthly |
| `m12w4d7h24-age` | the same four families | the same numbers BY AGE (`-h24 -d7 -w4 -m12`) | daily, weekly, monthly |
| `Y5M12D31H24` | one family, hourly | GFS ladder 24/31/12/5 | none — a ladder cannot |
| `passive` | nothing — adopts a family somebody else creates | four counters over it | not applicable |

`passive` has no `prefix` at all: it consumes snapshots another tool made, so
there is no freeze of ours to take.

## What every profile shares

The `[excluded:]` floors — `__replicate_` (pvesr), `vzdump`, `__migration__` —
are config-wide, identical in every file and identical on purpose. They are not
any profile's opinion, and none of those families is ours to delete.

## A profile that only prunes — how to say "the source keeps less"

`--source-profile=NAME` gives the SOURCE side of a relationship its own
retention: a source short of disk under a collector with plenty. The flag names
a profile, and that is the trap — a profile carries a dozen fields and only the
retention was ever meant to differ. Owner, 2026-09-03: *"profil niesie w sobie
dużo więcej parametrów... takie użycie wydaje mi się karkołomne"*.

**Write a profile that creates nothing.** Drop `[dataset]`, keep `[prune]`:

```
[profile]
	description = tylko retencja -- 7 dobowych, 24 godzinowe
	version     = 1

[template:keep_hourly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	keep           = 24
	notify_word    = prune

[template:keep_daily]
	prune_schedule = 31 1 * * *
	pattern        = automated_daily
	keep           = 7
	notify_word    = prune

[prune]
	use_template = keep_hourly,keep_daily
```

This is not a new mechanism. `default.conf` already separates the two halves —
`[template:standard_hourly]` creates, `[template:keep_*]` only prunes — and a
prune-only profile is that separation with the creating half absent.

**Why it is the better shape, and not merely tidier.** A source template is
built by copying the tier it comes from and deleting the fields that make no
sense on a remote prune scope (`send_schedule`, `prefix`, `monitor_warn`,
`monitor_crit`). That deletion is a list, and a list is something to keep in
step: `quiesce` is a creating-half field too and is *not* on it, so naming a
flat profile as the source drags `quiesce` into a prune template where
`delsnaps` has no such flag. Dead weight that validates cleanly. A profile with
no creating half has nothing to leak, whatever the list says.

**The two sides must still count the same way.** They may differ in how MUCH
they keep and never in WHAT, nor in how it is counted: a source prune aimed at
a family the relationship never creates matches nothing, and `delsnaps` that
matches nothing exits 0 — the source would keep everything while its nightly
job reported success. `--source-profile` refuses on both, naming the shapes:

```
target patterns: [automated_daily(flat)]  source patterns: [automated_daily(ladder)]
```

So a `-gfs` profile pairs with a `-gfs` profile and a flat one with a flat one,
at any pair of counts.

**Naming.** The three axes above — digits for retention, case for shape, suffix
for mechanism — all describe what a profile KEEPS. "Creates nothing" is a
fourth axis and has no suffix reserved for it, so none is invented here and no
prune-only profile is shipped. Name your own as you like; if one ever joins the
catalogue it needs an owner decision on that axis first.
