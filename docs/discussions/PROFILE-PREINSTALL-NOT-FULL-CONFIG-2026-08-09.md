# Profiles are preinstall presets, not a complete configuration language

Date: 2026-08-09
Status: **OWNER DIRECTION / ARCHITECTURE CONSTRAINT**

Owner clarification: profiles/templates exist to provide a good, ready-to-use starting configuration for a normal administrator. They are not intended to model every exceptional deployment or eliminate manual CONFIG v4 editing.

## 1. Product boundary

A profile is a **preinstall preset**:

```text
PROFILE + RELATION/SCOPE facts
        ↓
ready candidate CONFIG v4
        ↓
preview
        ↓
install
```

If the administrator accepts a shipped preset, the high-level tool should make deployment easy and safe.

If the administrator needs a special policy that does not fit the shipped presets, the product does **not** have to grow inheritance, overrides, exception DSLs, profile parameters, or another orchestration framework merely to express it.

The administrator may take the generated CONFIG v4 and edit it directly.

Manual CONFIG v4 remains a first-class supported path.

## 2. Profiles reduce initial work; they do not own the final configuration forever

Desired lifecycle:

```text
1. choose/discover WHAT
2. choose a sensible profile (or default)
3. generate candidate CONFIG v4
4. show config + cron
5. admin accepts as-is
   OR
   admin customizes native CONFIG v4
6. install/validate native CONFIG v4
```

Once an administrator deliberately customizes the native CONFIG beyond the preset-managed shape, the system should not pretend that it can still reconstruct every detail from a profile name.

Do not silently overwrite such manual policy with a later profile regeneration.

## 3. Kancelaria is the canonical example of why this boundary matters

Real deployment constraint: little local disk space.

The snapshot creation policy may want a longer logical history, but local retention is intentionally shorter because snapshots are synchronized/replicated to another host and are preserved there longer.

Conceptually:

```text
CREATE POLICY
  hourly snapshots
  daily snapshots

LOCAL DISK RETENTION
  deliberately aggressive / short

OTHER HOST
  synchronization/replication preserves a longer effective history
```

This can be a perfectly valid site-specific design, but it couples local capacity, cross-host synchronization and retention in a way that should **not** become another built-in profile dimension.

The correct product response is:

- provide a normal preset;
- document the native CONFIG v4 fields and examples;
- show how to customize retention after generation;
- validate the resulting native CONFIG;
- do not make the high-level profile layer model this special topology.

## 4. Reduction rule for architecture decisions

Before adding any profile mechanism ask:

> Does this help the university-level administrator get a sensible working configuration faster, or are we trying to automate an expert's bespoke config?

If the second, prefer documentation + examples + manual CONFIG.

Kill/defer by default:

- profile inheritance;
- profile composition;
- per-profile exception lists;
- arbitrary override chains;
- parameterized profile macros;
- automatic conversion of every existing bespoke host config into a built-in profile;
- high-level modeling of site-specific interactions such as storage scarcity compensated by cross-host synchronization.

## 5. Consequence for SOURCE ROOT -> PROFILE exceptions

A second source binding to another profile can still be useful when it is a simple, common operation and the relation can represent it safely.

But the existence of an imaginable exception does not justify building carve-out/precedence machinery.

If `rpool/data/vm-101 -> DB90` cannot be represented safely with the existing relation primitives at low cost, V1 may simply refuse overlapping profile-managed bindings and direct the expert administrator to native CONFIG v4.

That is not a product failure. It preserves a simple public model.

## 6. Managed versus manual ownership must be explicit

The architecture must prevent this failure:

```text
admin generates preset
→ edits native CONFIG manually
→ later high-level command silently regenerates from profile
→ expert customization disappears
```

Therefore profile-managed sections need explicit ownership, and a collision with/manual departure from the managed shape must be visible and fail closed or require an explicit re-adoption action.

A possible user-facing model:

```text
MANAGED BY PROFILE
  safe to regenerate from profile + relation

MANUAL CONFIG
  administrator-owned; high-level profile regeneration will not rewrite it
```

Do not invent more states than necessary; this is an ownership boundary, not a workflow engine.

## 7. Documentation is a feature here

The project should provide concise examples for expert customization, especially:

- independent hourly/daily retention without GFS;
- quiesce only on selected create tiers;
- intentionally shorter local retention than remote/replicated history;
- manual prune schedules/patterns;
- safe manual CONFIG validation and preview;
- how to return from manual customization to a managed preset if explicitly desired.

The purpose of the examples is to let an expert customize the native system without forcing the main CLI to absorb every special case.

## 8. Direction to Claude + Reviewer

Use profiles to simplify **installation**, not to replace CONFIG v4.

Convergence criterion:

```text
normal admin:
  minimal choices → sensible preset → working backup

expert admin:
  preset as starting point → native CONFIG edit → validation → install
```

The high-level tool should become simpler as native CONFIG remains powerful.

**Reduction over completeness.**
