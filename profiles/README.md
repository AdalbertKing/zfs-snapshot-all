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
| `m12w4d7h24-age` | the same four families | the same numbers BY AGE (`-h24 -d7 -w4 -m12`) | daily, weekly, monthly |
| `passive` | nothing — adopts a family somebody else creates | four counters over it | not applicable |

`passive` has no `prefix` at all: it consumes snapshots another tool made, so
there is no freeze of ours to take.

## What every profile shares

The `[excluded:]` floors — `__replicate_` (pvesr), `vzdump`, `__migration__` —
are config-wide, identical in every file and identical on purpose. They are not
any profile's opinion, and none of those families is ours to delete.
