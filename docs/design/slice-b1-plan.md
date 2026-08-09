# Slice B1 — plan, measured before coding

Unblocked 2026-08-09: the profile boundary is approved and closed
(REV-20260808-076, REV-20260809-077), which was the only thing holding it.

## What is hardcoded, exactly

`zfs-backup.sh` carries the policy as shell variables:

```
STANDARD_TEMPLATE_NAMES="standard_hourly"
STANDARD_TEMPLATE_standard_hourly='...'
KEEP_TEMPLATE_NAMES="keep_hourly keep_daily keep_weekly keep_monthly"
KEEP_TEMPLATE_keep_hourly='...'   (and daily / weekly / monthly)
```

emitted by a loop around lines 599-608. Five templates: one send cadence and a
four-tier retention ladder, `-H24 -D7 -W4 -M12`.

## The fixture is already byte-faithful — measured

Diffing `profiles/default/templates.conf` against the hardcoded
`[template:standard_hourly]` block shows **one** difference: the shell variable's
closing quote. The Slice A fixture is a true mirror of the policy, not an
approximation.

That matters because it makes B1's acceptance criterion cheap and exact: the
generated CONFIG v4 must be **byte-identical** before and after, and the fixture
already contains what the code contains.

## The change

Replace the variable emission with a read of `profiles/<name>/templates.conf`,
gated by `lib-profile.sh`:

```
profile_validate_dir "$dir" "$GEN"   ->  refuse before any mutation
   then emit its templates
```

That also discharges the obligation REV-076/077 left open: `profile_validate_dir`
gets its first production caller, so the boundary stops being a library nobody
invokes.

## Acceptance

1. generated CONFIG v4 **byte-identical** to today's, for every existing shape;
2. a profile failing validation refuses **before** anything is written;
3. `test/zfsbackup` (292) and `test/profiles` (39) both green;
4. dependency-selected cascade + `impact.sh --verify`;
5. negative control: the byte-identity assertion must FAIL against a
   deliberately altered profile, or it is proving nothing.

## What B1 does NOT do

No CLI change. The bare-invocation and one-versus-two-call questions are live in
`docs/discussions/DEPLOY-SEQUENCES-COMPARE-2026-08-09.md` and B1 is independent
of all of them -- it must produce byte-identical output, so by construction it
cannot alter the operator surface.

---

## STOP before coding — measured 2026-08-09, the scope is wrong as written

The check before coding found what the plan above missed. The emission has
**two branches**:

```bash
for t in $STANDARD_TEMPLATE_NAMES; do ... done
if [ "$PROFILE_GFS" -eq 1 ]; then
    for t in $KEEP_TEMPLATE_NAMES; do ... done
fi
```

`PROFILE_GFS=0` is the **pre-GFS** profile, where `standard_*` itself carries
`prune_schedule` and retention is flat per tier. `profiles/default/` represents
only the GFS shape.

Measured on the fleet:

| host | shape | `keep_*` templates |
|---|---|---|
| metropolis pve1 | GFS | 4 |
| metropolis pve2 | GFS | 0 — uses its own template names |
| **11.x pve0** | **pre-GFS** | 0 |
| 11.x pve1 | GFS | 0 |

**pve0 runs the pre-GFS profile in production.** Replacing the variables with a
read of `profiles/default/templates.conf` would drop the branch it depends on,
and the byte-identity criterion would not catch it — pve0's config already has
its templates, so nothing would be appended and the diff would be empty. The
test would pass and the capability would be gone.

pve2 shows a second thing worth knowing: it carries its own template names
(`local_daily`, `store_hourly`), so the built-in templates are only ever
appended **when missing**. Hosts with their own never receive them.

### The scope question, which is not mine

1. add a second profile directory mirroring the legacy shape;
2. extract only GFS and leave pre-GFS hardcoded — two sources again, the exact
   thing B1 exists to remove;
3. scope B1 to GFS and declare pre-GFS frozen with a written migration path for
   pve0.

I lean to **3**: option 2 defeats the slice, and option 1 makes a legacy shape
look like a supported product choice. But retiring a profile a live host runs is
an owner decision, not an implementation detail.

**Not coding until this is settled.** Discovered mid-implementation it would
have meant a rewrite; discovered by the check it costs one measurement.

---

## Owner decision 2026-08-09: option 3

Scope B1 to the GFS shape; the pre-GFS profile is **frozen**, with a written
migration path for pve0.

### What I measured before writing the path down

The question I stopped on was "how expensive is retiring a profile a live host
runs". The answer turned out to rest on a fact I had not checked: **which
templates any host actually uses.**

| host | built-in templates DEFINED | of those, USED by a section |
|---|---|---|
| metropolis pve1 | `standard_hourly`, `keep_hourly`, `keep_daily`, `keep_weekly`, `keep_monthly` | **0** |
| metropolis pve2 | none | **0** |
| 11.x pve0 | `standard_hourly`, `standard_daily`, `standard_weekly`, `standard_monthly` | **0** |
| 11.x pve1 | none | **0** |

Every section on every host uses a hand-written template — `hourly`, `daily`,
`vm101_*`, `store_*`, `lxc_*`, `local_*`, `flat_prune`. **Not one production job
in this fleet references a built-in template, in either shape.** pve0's four
`standard_*` sections are dead text: appended once by `zfs-backup.sh`, never
referenced.

So my framing was wrong in the direction that mattered. I wrote that pve0 "runs
the pre-GFS profile in production". It carries the pre-GFS *marker*; it does not
run it. Nothing on pve0 would change behaviour if those four sections vanished.

### Where the branch is genuinely live

Not in the existing configs — in **future enrolments**. `emit_client_sections`
writes `use_template = standard_hourly` under pre-GFS and
`use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly` under GFS, so
the shape decides what a client enrolled *tomorrow* gets. pve0's
`/etc/zfs-snapshot-all/clients/` is **empty** — it has never enrolled one.

And `PROFILE_GFS` is not stored anywhere. It is **detected from the config**: if
`[template:standard_hourly]` exists and carries `prune_schedule`, the host is
pre-GFS. pve0 is pre-GFS purely because of four unused sections.

### The migration path, therefore

1. **Detection stays.** Removing it would let a GFS enrolment land on a host
   whose `standard_hourly` prunes on its own schedule — the double-prune race
   `gen-cron.sh`'s own docs warn about, and the reason the branch was written.
2. **Under B1 the pre-GFS branch stops emitting and starts refusing.** A host
   detected as pre-GFS gets a named refusal at enrolment, not a silent switch to
   the GFS shape. Fail closed: the frozen profile is not quietly reinterpreted.
3. **pve0's migration is deleting four unreferenced sections** from
   `/etc/zfs-snapshot-all/jobs.pve0.v4.conf`, after which detection reports GFS.
   Zero jobs reference them, zero clients are enrolled, so it changes no
   behaviour — but it is an owner-run edit on a live config, not something B1
   does behind anyone's back, exactly as the existing comment insists.

### What the acceptance criterion must now include

Byte-identity of regenerated configs is **not sufficient** and this is why: on
pve0 nothing is appended, so the diff is empty whether the branch works or not.
B1 must additionally pin, on a fixture:

- a pre-GFS config **refuses** enrolment with the reason named;
- a GFS config emits `keep_*` from `profiles/default/`;
- a host with its own template names (the pve2 case) still receives nothing.

That third one is the quiet requirement: built-ins are appended **only when
missing**, and two of four hosts never receive them at all.

---

## Corrections after REV-20260809-079 — both findings accepted

### F1 — I proposed a hand edit while a transactional migration verb already exists

`zfs-backup.sh migrate-profile` has existed since REV-20260801-016 F3. Verified
in the tree, not taken from the review: `cmd_migrate_profile()` at
`zfs-backup.sh:2311` refuses a config that is already GFS, works on a `mktemp`
working copy beside the real file, removes the four legacy `standard_*` sections
through `remove_template_section()`, calls `ensure_cron_config()` to build the
GFS shape, rebuilds every **active** client through the same
`emit_client_sections()` activation uses, logs `no active clients -- migrating
the templates only` for exactly pve0's case, validates the working copy through
the real `gen-cron.sh`, shows the config and cron preview, asks once, then runs
the config-source / foreign-block / clobber / readability guards and installs
through `atomic_replace_and_install()`.

So my "delete four unreferenced sections" was not a lighter path. It was the
same migration with every guard removed.

**This is my recurring failure mode, and naming it is the point:** I proposed a
mechanism without searching for the existing one. The same mistake produced my
claim that host configs "do not live on the hosts" while `/etc/zfs-snapshot-all/`
held all four of them.

The review's time-of-check objection is also right and is the part I would have
got wrong even with the correct verb. "Zero clients, zero references" are
**mutable live-host facts measured on 2026-08-09**. A migration must prove the
state at execution time. `migrate-profile` does precisely that — it re-reads the
config, rebuilds from current client records and previews the real cron delta —
whereas my plan would have carried a day-old inventory as a precondition.

**Corrected path for pve0:** run `zfs-backup.sh migrate-profile`, read the
preview, confirm. The 2026-08-09 inventory is evidence that the migration should
be uneventful, not a licence to skip the preview.

### The interaction B1 must not break, named as F1.2 requires

After B1 the loader changes what `ensure_cron_config()` emits, and
`migrate-profile` calls it. Two things must stay true:

1. **The removal list stays a LEGACY-name list.** `migrate-profile` removes the
   bare `standard_hourly|daily|weekly|monthly`. Those are the names the pre-GFS
   *hardcode* wrote. They must not be re-derived from the loaded profile, which
   after namespacing emits different names — a migration that removed the names
   it is about to write, and left the legacy ones behind, would be a no-op that
   reports success.
2. **`emit_client_sections()` and `ensure_cron_config()` must resolve the same
   names.** They already share this by construction (`:885` says they are
   extracted so activation and migration cannot drift). B1 must keep that single
   source, not give the loader its own naming.

If either cannot hold, F1.2 applies: fix that path inside B1 rather than
migrating pve0 by hand.

### F2 — my suppression rule does not exist in the code

I wrote that built-ins are appended "only when missing", so "hosts with their own
never receive them", and turned it into a B1 acceptance criterion.

The first clause is true **name by name**; the conclusion is false. The loop at
`zfs-backup.sh:599` is:

```bash
for t in $STANDARD_TEMPLATE_NAMES; do
    grep -q "^\[template:$t\]" "$file" 2>/dev/null && continue
    ...append...
```

It asks whether *that name* is present, never whether the config has some other
templates. A config carrying only `local_daily`/`store_hourly` does **not**
suppress anything; if `ensure_cron_config()` runs on it, the missing built-in
names are appended.

So pve2's state proves only where pve2 is, not which rule produced it. Had that
criterion gone into B1, a test would have blessed a semantic rule the code does
not have — under the banner of extraction equivalence, which is the one thing
extraction must not do.

**Corrected acceptance criterion:** name-by-name idempotence.

- a built-in section already present is not duplicated;
- a missing one is emitted per the applicable GFS/pre-GFS rule, **regardless of
  unrelated custom template names**;
- a pre-GFS config refuses ordinary enrolment rather than converting silently;
- "custom templates ⇒ never append" stays out of B1 entirely; if the product
  wants it, it is its own decision with its own tests.

### Acceptance criterion, superseded by the reviewer's namespace resolution

The byte-identity criterion this document opened with is replaced by
behaviour-equivalence, per `PER-SOURCE-PROFILE-SCENARIOS-2026-08-09-REVIEWER.md`:
profile-owned template names are namespaced deterministically from the first
emission, `use_template` references are rewritten during composition, the profile
files themselves are never mutated, hand-written sections are never renamed as
collateral, and a post-normalisation collision is a hard refusal before mutation.

What must stay byte-identical is the **rendered job semantics** — schedule,
prefix, retention/GFS, recursion, monitoring, source/target mapping, flags — not
the config text.
