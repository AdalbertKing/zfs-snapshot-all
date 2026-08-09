# Profile reduction principle — owner direction + reviewer challenge

Date: 2026-08-09
Status: **OWNER DIRECTION / REVIEWER -> CLAUDE RESPONSE REQUESTED**

Owner direction: **reduction, not complication**.

This note constrains the ongoing profile-runtime architecture discussion. The goal is not to enumerate every capability CONFIG v4 can express. The goal is to reduce the policies that actually exist or are clearly required into the smallest coherent set of reusable profiles, while preserving exact behavior and safety.

## 1. Reduction is the default decision rule

For every proposed profile, field, variant, capability layer or special case ask:

1. What real current or near-term deployment requires it?
2. How many existing manual policy definitions does it eliminate?
3. Does it remove operator choices, or add another choice the operator must understand?
4. Can the same result be obtained by an existing native CONFIG v4 field without another abstraction?
5. If two policies differ only in incidental names/hosts/targets/schedule offsets, are they actually the same HOW policy after normalization?

If a mechanism does not reduce the number of independent facts or decisions, do not add it merely because it is architecturally possible.

## 2. Do not design built-in profiles from a Cartesian product

Do NOT generate variants by multiplying dimensions such as:

```text
cadence × retention × recursion × quiesce × local/remote × account
```

That produces a profile zoo and hides the same complexity behind names.

Instead:

```text
CURRENT PRODUCTION CONFIGS
        ↓
extract HOW only
        ↓
normalize away relation/site facts and template spelling
        ↓
semantic policy fingerprint
        ↓
cluster identical policies
        ↓
smallest useful set of profiles
```

A difference creates a distinct profile only when it changes actual policy semantics and that distinct policy is genuinely used/wanted.

## 3. Required measurement before naming the built-in set

Claude: measure the current four production configs that were already inspected during B1. Do not infer from template names.

For every active source/job, derive a normalized HOW signature containing only policy-owned semantics, for example where applicable:

- create schedules/cadence;
- snapshot prefix family as semantics, ignoring arbitrary local template names;
- retention/GFS ladder;
- recursive mode;
- quiesce/consistency behavior;
- monitoring thresholds/schedule;
- native autotune or other genuinely active policy fields.

Explicitly exclude relation/site facts:

- source/target dataset names;
- host/address/port;
- account/key/pair label;
- bandwidth/site transport facts;
- arbitrary template section names;
- collector-assigned schedule offsets if those merely materialize the same cadence.

Then report:

```text
N active policy-bearing jobs/source roots
→ M unique normalized HOW signatures
→ frequency of each signature
→ exact semantic delta between signatures
```

The objective is to learn whether today's apparent many hand-written templates reduce to e.g. 2-4 real policies.

## 4. Names come last

Do not invent names such as `archive`, `critical`, `GFS_7_30_FLAT`, `standard-flat`, etc. until the semantic clusters are known.

First write the policy in plain terms. Then decide whether it deserves a reusable profile. Only then give it a name.

A name is a stable product contract; it must describe an already-understood policy, not drive the design.

## 5. Preserve the settled ownership split, but do not over-layer it

The architectural boundaries remain useful:

```text
RELATION/SCOPE = WHAT/WHERE
PROFILE        = HOW
ACCOUNT        = execution identity
GRANTS         = authorization boundary
```

However, compatibility/capability checks should be implemented only where they prevent a real false-green or unsafe mutation. Do not turn them into separate user-visible concepts, daemons, files or DSLs unless required.

Example: if a profile requires quiesce and the delegated account lacks permission, the high-level apply path must detect/remediate/refuse. That does NOT imply the administrator needs to learn a new `capability plan` object.

The internal architecture may have a check; the external product should become simpler.

## 6. Recursion: avoid both explosion and ownership drift

Owner has already settled that recursion is HOW, not WHAT. Do not move `flat/atomic/no` back into relation scope merely to reduce profile count.

At the same time, do not pre-create every recursion variant for every retention policy. Create only combinations evidenced by real deployment scenarios.

If two otherwise identical real policies differ only in recursion, they are semantically distinct HOW policies and may require two profiles. That is acceptable if both are actually needed. It is still reduction compared with arbitrary hand-written configs.

## 7. Migration principle for today's hosts

Do NOT migrate existing hosts by assigning `default` indiscriminately.

Correct migration is:

```text
current active CONFIG
→ normalize HOW
→ map to an existing identical profile if one exists
→ otherwise keep manual CONFIG first-class or create one justified profile
→ render candidate
→ compare effective CONFIG + cron semantics
→ zero unintended behavior change
```

Manual CONFIG v4 remains a supported endpoint. A one-off policy used once does not automatically deserve a built-in profile.

## 8. What to kill early

Prefer NOT to build:

- profile inheritance;
- profile composition language;
- parameterized profile templates/macros;
- per-host profile copies differing only in topology;
- automatic Cartesian profile generation;
- another schema mirroring CONFIG v4;
- user-visible capability/grant state machines;
- aliases whose only purpose is spelling convenience.

A second profile is cheaper than a framework if there are genuinely two policies. A manual CONFIG is cheaper than a built-in profile used once.

## 9. Concrete reduction test for the current architecture challenge

The hypothetical `daily-consistent-flat` scenario is useful as a *test case*, not automatically as a product profile.

Before adding native support or a built-in profile for it, answer:

- Does a current/committed use case actually require separate hourly crash-consistent + daily quiesced creation?
- If yes, what is the smallest native CONFIG representation that keeps their retention/monitoring classes distinct?
- Can the existing schema express it without another abstraction?
- If not, what single native extension buys the capability with the least long-term complexity?

The same rule applies to policy digest/pinning, capability checks, provenance and scheduler changes: implement the minimum contract that prevents a demonstrated unsafe or surprising behavior.

## 10. Claude response requested

Please respond with evidence, not a new framework:

1. Measure and cluster the current four host configs by normalized HOW semantics.
2. State the minimum number of distinct real policies you find.
3. For each difference, say whether it is:
   - true profile policy;
   - relation/topology fact;
   - account/grant fact;
   - incidental spelling/schedule materialization.
4. Propose the smallest initial built-in profile set justified by that evidence.
5. Identify any proposed architecture item from the current challenge that can be deleted/deferred without creating a concrete false-green or unsafe transition.
6. Keep narrow B1 extraction separate from this product-set decision; B1 should remain behavior-preserving and must not grow new profile variants as a side effect.

Reviewer criterion for convergence: **fewer concepts, fewer independent knobs, fewer profiles, with the same or stronger safety.**
