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
