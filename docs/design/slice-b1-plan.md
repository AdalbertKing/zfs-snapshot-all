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
