# Profiles are preinstall presets, not a complete configuration language

Date: 2026-08-09
Status: **OWNER DECISION — BINDING / CLAUDE RESPONSE REQUESTED**

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

The minimal acceptable property is therefore:

```text
PROFILE/PRESET
  may generate a candidate

INSTALLED CONFIG v4
  is the executable truth

MANUAL EDIT
  must not be silently replaced by preset regeneration
```

Do not build a workflow engine merely to encode this. A small ownership/provenance marker or explicit refusal is preferable to additional lifecycle states.

## 7. Documentation is a feature here

The project should provide concise examples for expert customization, especially:

- independent hourly/daily retention without GFS;
- quiesce only on selected create tiers;
- intentionally shorter local retention than remote/replicated history;
- manual prune schedules/patterns;
- safe manual CONFIG validation and preview;
- how to deliberately regenerate/re-adopt a preset if the administrator explicitly wants to discard manual customization.

The purpose of the examples is to let an expert customize the native system without forcing the main CLI to absorb every special case.

## 8. One-way handoff: preset -> CONFIG

This owner decision intentionally weakens an earlier assumption that a persisted `SOURCE ROOT -> PROFILE` binding must remain the authoritative long-lived source of production policy.

The preferred mental model is now:

```text
SOURCE/RELATION FACTS + PROFILE
             ↓
        GENERATE ONCE
             ↓
          CONFIG v4
             ↓
     production execution
```

The profile may remain recorded as provenance or as a convenience for a future explicit regeneration, but **CONFIG v4 is not continuously reconstructed from the profile**.

Consequences:

1. Updating `profiles/default` during a software upgrade must not mutate an already-installed CONFIG.
2. Endpoint changes must not require policy regeneration from the profile merely to preserve the existing policy.
3. A profile digest may be useful as provenance/evidence, but it must not create a profile-drift workflow unless a concrete safety need requires it.
4. Re-applying a preset over an existing/manual CONFIG must be an explicit operation with preview; never an incidental side effect of another command.
5. If storing a selected profile name serves no runtime purpose after installation, do not persist it merely because an earlier Stage 5 plan assumed persistence.

## 9. Re-evaluate Stage 5 C/D under this simpler owner contract

Earlier planning proposed named profile selection + persistence and later custom profile management. Claude + Reviewer must now challenge how much of that remains necessary.

The desired public product is closer to:

```text
normal path:
  choose preset -> generate -> preview -> install

expert path:
  choose preset -> generate -> edit CONFIG v4 -> validate -> install
```

not:

```text
profile manager continuously owns every installed policy forever
```

The profile subsystem therefore needs only enough persistence to support a real operator action. Do not preserve bookkeeping with no product value.

## 10. Kancelaria example as an explicit non-goal for high-level automation

A site may intentionally create snapshots on one cadence but prune them locally faster than the logical protection policy would suggest, because cross-host synchronization preserves the longer history elsewhere.

That scenario is valid, but it is **expert native CONFIG territory**.

The software should help through:

- a generated baseline;
- documented examples;
- validation;
- preview;
- clear warnings where configuration is inconsistent.

It should not grow new high-level profile dimensions to encode that site-specific interaction.

## 11. Questions to Claude — reduce the plan, do not add framework

Please respond narrowly with current-code/plan consequences:

1. Which parts of the earlier Stage 5 C/D plan can now be deleted because profiles are preinstall presets rather than permanent runtime managers?
2. Does any current production path truly require persisting `profile_name` after CONFIG installation? If yes, name the exact operation and why the installed CONFIG alone is insufficient.
3. Can endpoint mutation, re-activation and additive source enrollment preserve the existing installed CONFIG without reconstructing policy from a profile?
4. What is the **smallest** mechanism that prevents accidental overwriting of a manually edited generated CONFIG: existing config ownership markers, a digest, an explicit command boundary, or something else already present?
5. Can we kill profile-drift adoption/version workflow entirely and retain only optional provenance such as `generated-from=<name,digest>`?
6. For a new source added later, is it simpler to ask/select a preset for that source at that time, rather than maintain a persistent global profile manager?
7. Identify any architecture item from `PROFILE-RUNTIME-ARCHITECTURE-CHALLENGE-2026-08-09.md` that becomes unnecessary under this owner decision.
8. Do not solve the Kancelaria pattern in high-level CLI. Confirm which CONFIG v4 examples/documentation are sufficient instead.

## 12. Direction to Claude + Reviewer

Use profiles to simplify **installation**, not to replace CONFIG v4.

Convergence criterion:

```text
normal admin:
  minimal choices -> sensible preset -> working backup

expert admin:
  preset as starting point -> native CONFIG edit -> validation -> install
```

The high-level tool should become simpler as native CONFIG remains powerful.

**Reduction over completeness.**

## 13. Owner follow-up: preset is CREATE-only; existing CONFIG may receive a new independent task

The existence of a CONFIG file is **not** itself a reason to refuse use of a preset. A preset may append a new, non-overlapping task/source package to an existing CONFIG.

The public rule is:

```text
PROFILE/PRESET = CREATE NEW CONFIG FRAGMENT ONLY
CONFIG v4      = SOURCE OF TRUTH FOR EDITS
```

Examples:

```text
existing CONFIG:
  rpool/data -> bespoke/manual policy

later:
  add rpool/lxc using preset X

result:
  rpool/data unchanged
  new rpool/lxc package appended transactionally after full validation/preview
```

A preset must refuse if the requested source/task already exists or overlaps existing coverage. It must not update, merge, re-adopt, or reconstruct existing policy.

## 14. Deletion belongs to relationship lifecycle, never to presets

Do not define "remove profile output" and do not reverse-match installed CONFIG to a template in order to delete it.

Deleting a relationship/task is a separate package operation and belongs at the `zfs-backup.sh` orchestration layer, because that layer owns stable relationship identity and knows which concrete sections/state belong to the relationship.

Current code already has the right architectural shape via:

```text
zfs-backup.sh remove-client NAME
```

It uses `CLIENT_NAME`, recorded `MANAGED_DATASETS`/`MANAGED_PRUNE_SCOPE`, and the section marker:

```text
# managed-by: zfs-backup.sh client=<name>
```

to identify exactly this relationship's `[dataset:]` / `[prune:]` sections. It refuses a collision that looks hand-written rather than silently deleting it.

The teardown sequence is relationship-level:

```text
identify relationship
  -> remove only its owned dataset/prune sections from working CONFIG
  -> validate remaining CONFIG
  -> regenerate/update cron, or remove the managed cron block if no jobs remain
  -> atomically install remaining CONFIG
  -> deploy.sh --unpair
  -> mark client STATE=removed
  -> clear relationship operational state
```

Lower layers keep narrow responsibilities:

```text
gen-cron/lib-cron -> render/write cron

deploy.sh         -> pairing/grant/key teardown

zfs-backup.sh     -> decides WHAT constitutes the relationship being removed
```

The shared CONFIG file itself is not necessarily deleted, because other relationships, templates, defaults, or manual sections may remain. "Remove the pair" means remove that pair's owned task sections and relationship state, not delete unrelated shared configuration.

The ownership test must be relationship identity/marker based, never "this still looks like preset X".

This yields the reduced contract:

```text
PRESET        creates a new starting task
CONFIG v4     is the execution truth
zfs-backup.sh owns explicit relationship lifecycle, including remove
lower layers  execute narrow primitives
```

No profile history, reverse template matching, delete-by-profile semantics, or profile manager is required.

## 15. Claude response already supports the reduction

Claude's current-tree analysis at commit `66d3b1cbd8602a9e96f306973dfa2f4120375804` concludes that the one-way preset model lets the project delete/defer persistent SOURCE ROOT -> PROFILE management, profile drift/version adoption, per-source carve-out precedence, and custom-profile CLI complexity. `PROFILE_ACTIVE` is process-local today and no runtime operation currently requires persisted profile identity.

Claude also points out that the existing `managed-by` marker is already the right ownership primitive: it records **who owns the CONFIG section**, not which profile it resembles. That distinction is exactly what relationship removal needs.
