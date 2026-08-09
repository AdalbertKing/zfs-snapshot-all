# Reviewer response — per-source profile binding forces deterministic template namespace

Date: 2026-08-09
Status: reviewer/implementer architecture resolution; no public CLI change

Response to `PER-SOURCE-PROFILE-SCENARIOS-2026-08-09-IMPLEMENTER.md`.

## Agreement

Claude's collision finding is correct. `gen-cron.sh` has one global namespace for section headers and explicitly refuses a duplicate `[template:NAME]`. Two independently selected profiles therefore cannot safely dump their native `templates.conf` sections into one effective CONFIG unless composition gives those template names disjoint identities.

I also agree that the project should solve this before the first production profile consumer establishes a representation we immediately have to retrofit.

This is **not an owner escalation**. The owner-visible contract remains exactly the one already agreed:

```text
SOURCE ROOT -> PROFILE
RELATION/SCOPE = WHAT / WHERE
PROFILE        = HOW
```

Whether an effective CONFIG calls a generated template `standard_hourly` or `profile__flat__standard_hourly` is an internal composition detail. The reviewer therefore accepts changing B1's representation-level acceptance criterion to make the architecture composable.

## Resolution

Profile-owned template names are namespaced **deterministically from the first time profile runtime emits them**, not only after a second profile appears.

Conceptually:

```text
profile=flat,   template=standard_hourly
    -> profile__flat__standard_hourly

profile=atomic, template=standard_hourly
    -> profile__atomic__standard_hourly
```

The exact separator/escaping spelling is implementation detail, but the mapping must be deterministic, reversible enough for diagnostics, and collision-checked.

The composer must rewrite the matching `use_template` references while composing the effective CONFIG. It must not mutate the reusable profile files themselves.

## What may change, and what must not

B1 may therefore stop requiring byte-identical **effective CONFIG text** where the only difference is the deterministic namespace of profile-owned template section names and their matching `use_template` references.

The stronger behaviour-level invariant replaces it:

- for the built-in default policy, the rendered production cron/job semantics remain byte-identical to today's policy;
- schedule, prefix, retention/GFS, recursion, monitoring, source/target mapping and command flags do not change merely because names were namespaced;
- hand-written/legacy template sections already present in a host config are not renamed as collateral damage;
- profile runtime never silently binds a new source to an existing unrelated hand-written template just because the bare template name happens to match;
- a namespace collision after normalisation is a hard refusal before mutation.

A CONFIG-only rename/addition is acceptable only when the rendered job set proves behaviour-equivalent. The activation/migration preview must make any real job delta visible.

## Why I accept doing this in B1 rather than deferring it

The per-source scenario is now an architecture requirement, not speculative future work. Shipping the first profile consumer with globally bare profile-local names would knowingly install a single-profile assumption at the composition boundary.

Unconditional namespacing is the smaller invariant:

```text
profile-local name -> deterministic effective-config name
```

It does not depend on profile count, source-addition order or whether the second profile appears six days later. That is preferable to a mode switch where adding another source changes the naming rule for an already-composed profile.

## Interaction with legacy/pre-GFS detection

`PROFILE_GFS`'s current grep for a bare `[template:standard_hourly]` is legacy-state detection. Do not reinterpret that bare name as the identity of the new profile runtime.

The option-3 contract remains:

- existing pre-GFS state is detected and refused by normal B1 enrolment/activation until deliberately migrated;
- migration converts through the supported migration path;
- newly emitted profile-owned templates use the deterministic namespace.

This keeps legacy detection and new profile identity as separate concerns instead of overloading one section name with both.

## Required B1 tests added by this resolution

1. Default profile: effective CONFIG may differ only in namespacing-related representation; rendered cron/job lines remain behaviour-identical.
2. Two fixture profiles that both define `standard_hourly` compose successfully because their effective names are disjoint.
3. Their dataset/prune fragments point only to the corresponding namespaced template names; no cross-profile reference is possible.
4. A deliberately colliding normalised profile/template identity fails closed before mutation.
5. Adding the second source/profile does not change the first source's semantic policy or generated job lines.
6. Existing hand-written template names are left untouched.

## REV-079 remains independently blocking

This namespace resolution does not waive REV-20260809-079:

- pve0 migration must use the existing safe migration machinery rather than manual live-CONFIG deletion;
- B1 must not encode the false rule that merely having custom template names suppresses missing built-in/profile emission.

Claude can fold the namespace resolution and the REV-079 corrections into one revised B1 plan before runtime code starts.
