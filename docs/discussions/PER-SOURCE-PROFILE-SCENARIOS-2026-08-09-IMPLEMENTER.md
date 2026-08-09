# Per-source profile binding — agreed, and it forces one B1 decision now

Response to `PER-SOURCE-PROFILE-SCENARIOS-2026-08-09.md`. Measured before
written; no code changed.

## The requirement is right and scenario B is the right discriminator

Persisting one profile per relationship cannot express "add `rpool/lxc` as
atomic while `rpool/data` stays flat" without either changing a live source or
inventing a second relationship to the same host. Both are wrong. `SOURCE ROOT
-> PROFILE` inside one relationship is the correct model, and it does not
violate REV-073: scope still selects the roots, the profile still carries only
reusable HOW, and the relation stores the association.

I also agree the bindings must be additive, and that day 7 seeds only the new
root.

## The thing the scenario forces, which B1 would otherwise decide by accident

Two profiles bound in one relationship compose into **one** effective CONFIG v4
file. Each profile is `templates.conf` + `dataset.inc` + `prune.inc`, and
`templates.conf` carries real `[template:NAME]` sections. Nothing in
`lib-profile.sh` requires template names to be disjoint **across** profiles — it
validates fields, not names — and the built-in names are generic
(`standard_hourly`, `keep_hourly`, `keep_daily`, `keep_weekly`, `keep_monthly`).
Any `flat` and `atomic` profile derived from the built-in one shares all five.

So I measured what the generator does with the collision rather than assuming:

```ini
[template:standard_hourly]      # from profile "flat"
	send_schedule = 1 * * * *
[template:standard_hourly]      # from profile "atomic"
	send_schedule = 5 * * * *
```

```
gen-cron.sh: error: duplicate section '[template:standard_hourly]' in <file>
rc=1
```

**It refuses.** That is the right behaviour and it is good news — the failure
mode is a hard stop, not silent cross-contamination where one profile's cadence
quietly wins over the other's. But it means per-source binding is **impossible**
until template names are made disjoint at composition, i.e. namespaced per
profile (`flat__standard_hourly`) or equivalent.

## Why the namespacing decision cannot wait for the multi-profile slice

The obvious economy is to namespace only when a second profile appears, keeping
bare names in the common single-profile case. **That breaks your own acceptance
property #1.**

Day 1 the config contains `[template:standard_hourly]` and
`use_template = standard_hourly`. Day 7 a second profile is bound; if namespacing
switches on then, the *existing* source's template section and its
`use_template` line are both rewritten — `rpool/data`'s binding changes as a
side effect of adding `rpool/lxc`. That is precisely "existing source/profile
bindings do not change silently", violated.

So namespacing has to be unconditional from the first profile emitted, or never.

## What that costs, measured rather than feared

I checked what would actually be disturbed, on all four hosts:

- **No existing config is rewritten.** Built-in templates are appended only when
  missing; nothing renames what is already there.
- **No production job in this fleet references a built-in template at all** —
  every section uses hand-written names (`hourly`, `vm101_*`, `store_*`,
  `lxc_*`, `local_*`, `flat_prune`). Measured today across all four hosts.
- **`PROFILE_GFS` detection survives**, because it greps the *existing* config
  for `[template:standard_hourly]` carrying `prune_schedule`. Renaming what is
  newly emitted does not disturb what is already on disk, so pve0 stays pre-GFS
  and metropolis pve1 stays GFS.

The cost is therefore confined to **newly enrolled clients**, whose emitted
section would read `use_template = default__standard_hourly` instead of
`standard_hourly`. There are no pending enrolments.

## Consequence for B1, stated plainly

B1's acceptance criterion as written is byte-identical effective CONFIG output.
If B1 emits bare names, it hardcodes the single-profile assumption into the
first thing that consumes `profiles/`, and the multi-profile slice then has to
change it — the retrofit this note exists to avoid.

**My recommendation: B1 emits namespaced template names from the start**, and its
acceptance criterion becomes "identical except for the template-name prefix,
which is the point", with the emitted-section test pinning the prefix. That
keeps one rule, applied once.

I am not making that call alone — it changes B1's agreed acceptance criterion,
which the owner approved as option 3 earlier today.

## Two smaller notes

**`recursive` in a profile is consistent with the boundary, and I checked.**
`lib-profile.sh` forbids `recursive` only on a *prune* section; a `[dataset:]`
`recursive` is permitted, and since REV-054 that one field drives all three
generated lines — transfer, inline prune and monitor. So `profile = flat`
supplying `recursive = flat` needs no boundary change and creates no prune-scope
race.

**The current `dataset.inc` deliberately omits `recursive`** to preserve
byte-identity with today's output. A `flat`/`atomic` profile pair necessarily
adds it, which is the same acceptance-criterion question as above, arriving from
a second direction.
