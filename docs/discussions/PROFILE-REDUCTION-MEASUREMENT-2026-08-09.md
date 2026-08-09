# Profile reduction — measured on the four production configs

Answer to `PROFILE-REDUCTION-PRINCIPLE-2026-08-09.md` §10. Evidence, no new
framework. Nothing here changes code.

Source: `/etc/zfs-snapshot-all/jobs.*.conf` read from all four hosts today, not
from names or memory.

## 1. The measurement

Every `[dataset:]` and `[prune:]` section was reduced to a **HOW signature**:
the set of tiers it resolves (`send` cadence, prefix family, `prune` cadence,
retention, monitor thresholds), plus `recursive`, `quiesce`, `gfs`,
`gfs_pattern`.

Excluded as relation/site facts: dataset and target paths, host/address/port,
account, key, `pair_label`, `notify`, bandwidth, template section names, and the
**minute offset** of every cron field — a schedule is normalised to its cadence
(`H`/`D`/`W`/`M`/`Y`), so `1 * * * *` and `21 * * * *` are the same hourly
cadence.

Normalised away as incidental spelling, after checking each is genuinely the
same meaning:

| written two ways | one meaning |
|---|---|
| `keep = 24` on an hourly tier, `retain = -H24` | `keep=` auto-derives the flag from the tier letter |
| `retain = -d 7`, `retain = -D7` | same delsnaps flag, spaced and unspaced |
| `monitor_warn = 3h`, `= 180m` | same threshold |
| `quiesce` absent, `quiesce = no` | `no` is the documented default (`gen-cron.sh:81`) |

```
32 policy-bearing sections   ->   18 unique HOW signatures
```

## 2. The result that decides the shape of the answer

I then removed the retention **values** and the monitor **values** entirely,
keeping only which tiers exist:

```
still 18
```

**The numbers are not what makes these policies different. The shapes are.**

That matters because it rules out the cheapest form of reduction. If the fleet
had been eighteen tunings of one ladder, one profile plus parameters would have
collapsed it. It is not. `pve1m` runs a four-tier H/D/W/M ladder with inline
prune; `pve0` runs three tiers H/D/W; another `pve0` class creates D/W/M/Y and
prunes **nowhere**; `pve1x` creates five tiers recursively with `quiesce=agent`
and no retention at all. Those are different policies, not different constants.

## 3. Every difference, classified as §10.3 asks

| difference | class | evidence |
|---|---|---|
| which tiers exist (H/D/W vs H/D/W/M vs D/W/M/Y vs H/D/W/M/Y) | **true profile policy** | changes what snapshots exist and what is retained |
| retention depth (`-D14`/`-W8` on pve0 vs `-D7`/`-W4` on pve1m) | **true profile policy**, but see §5 | changes recovery window |
| `recursive = atomic` (pve1x) vs `no` (everywhere else) | **true profile policy** | settled as HOW by the owner |
| `quiesce = auto` / `agent` / `no` | **true profile policy** | changes consistency of the snapshot |
| retention split across `[dataset:]` inline prune vs a separate `[prune:]` scope | **incidental structure** | see §4 — the same policy counted twice |
| `keep=` vs `retain=`, `-d 7` vs `-D7`, `3h` vs `180m` | **incidental spelling** | normalised above; collapsed nothing further |
| cron minute offsets | **incidental materialisation** | normalised away |
| template section names (`vm101_hourly`, `store_lxc_daily`, `local_daily`…) | **incidental spelling** | ignored throughout |
| dataset/target paths, hosts, accounts, `pair_label`, `notify`, bandwidth | **relation/topology or account fact** | excluded by construction |
| monitor thresholds differing by small amounts for the same tier (150m vs 180m warn; 1560m vs 1800m daily) | **probably drift, not intent** | see §5 |

## 4. One inflation I can name and one I cannot remove

**Counted twice.** Some datasets carry create *and* retention in one section
(`pve1m`, `pve0`); others create in a `[dataset:]` and are retained by a separate
`[prune:]` scope covering the subtree (`pve2m`, `pve0`'s recursive ladder). A
per-section count therefore splits one policy into two signatures. Of the 18,
**7 are `[prune:]`-only signatures** that pair with a create-only `[dataset:]`
signature elsewhere on the same host. Pairing them by scope is possible but
requires deciding which prune covers which dataset — that is topology, and I am
not inferring it from paths.

So the honest range is **11–18 policies**, not a single number, and the
imprecision is structural rather than sloppy measurement.

**Cannot remove.** Nothing in the configs says whether `pve0` keeping 14 daily
and `pve1m` keeping 7 is *intended* or is drift from two people configuring two
clusters years apart. That is not derivable from the data. It is the owner's
call, and it is the single decision with the largest reduction attached to it.

## 5. What I am NOT proposing

Per §1's decision rule, applied honestly to my own instincts:

- **No new built-in profiles.** Measured earlier and re-confirmed today: **not
  one production job on any of the four hosts references a built-in template.**
  Every section uses a hand-written one. A built-in profile added now would
  eliminate zero existing definitions.
- **The justified built-in set today is exactly one — the `default` that
  already ships**, and its only job is *new* enrolments. It has never been
  applied to an existing host and §7 says it must not be.
- **No parameterised retention.** The measurement says parameters would not have
  helped: removing the values changed nothing.
- **No profile for `pve1x`'s atomic/agent policy** unless a second host wants
  it. One occurrence, one host. §8: a manual CONFIG is cheaper than a built-in
  profile used once.

## 6. The one question I want answered before anything is named

**Are the monitor threshold differences intended?**

For the same hourly tier the fleet carries warn at 90m in three places and crit
at 150m in one and 180m in another; the daily tier warns at 1560m in one place
and 1800m in three. Those gaps are too small to be policy and too specific to be
accidental — they look like thresholds tuned once, on one host, and never
propagated.

If they are drift, normalising them removes real false-alert surface and costs
nothing. If they are intentional, I want that written down before a profile
freezes one of them as "standard".

I am not changing any of them. Reporting the discrepancy is the deliverable.

## 7. §10.6 — B1 stayed narrow, confirmed

B1 step 2 added **no** profile variants. It moved the existing single policy out
of shell variables into `profiles/default/`, kept name-by-name idempotence, and
made the pre-GFS shape refuse rather than convert. The suite went 292 → 295 and
every added assertion is about refusal or namespacing, none about a new policy.

The one thing B1 did add is the namespace, and it exists to make per-source
binding *possible*, not to create profiles. It creates no choice an operator has
to understand: nobody selects a profile yet.
