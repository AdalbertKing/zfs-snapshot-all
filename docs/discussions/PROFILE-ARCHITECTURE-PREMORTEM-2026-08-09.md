# Profile architecture pre-mortem — scope, consistency and lifecycle traps

Date: 2026-08-09
Status: REVIEWER/ARCHITECT DESIGN FINDINGS — not a runtime REV by itself

Purpose: find failure modes BEFORE Stage 5 profile runtime is wired. These are not all defects in shipped code. Some are compatibility rules or missing product contracts that become dangerous only once a named profile can mutate production CONFIG/cron.

## First correction: quiesce is already tier-resolvable in CONFIG v4

`gen-cron.sh` resolves policy fields as dataset -> template -> defaults inside the tier loop. `quiesce` and `autotune` are POLICY_FIELDS, so CONFIG v4 already permits e.g.:

```ini
[template:hourly]
send_schedule = 1 * * * *
quiesce = no

[template:daily]
send_schedule = 15 0 * * *
quiesce = auto
```

The current built-in `default` does NOT have a daily send tier. It has one send tier (`standard_hourly`) plus retention-only keep_hourly/daily/weekly/monthly. Therefore today's `daily` means a retained point selected from hourly-created snapshots, not a separately-created daily snapshot.

This distinction must be explicit in profile summaries: CREATE tiers and RETENTION tiers are not the same thing.

---

# Findings

## A1 — BLOCKER before broad profile authoring: the profile boundary permits silent cross-tier overrides

Native CONFIG v4 deliberately permits a `[dataset:]` to override template policy. `resolve_field()` precedence is:

```text
dataset -> template -> defaults
```

The profile boundary currently validates `dataset.inc` as a normal dataset fragment and forbids only relationship-owned fields (`src dst flags pair_label notify`, plus prune recursion). Therefore `dataset.inc` may legally contain tier policy fields such as:

```text
send_schedule
prune_schedule
prefix
pattern
keep/retain
monitor_*
quiesce
autotune
```

That is dangerous inside a reusable profile. Example:

```ini
# templates.conf
[template:hourly]
quiesce = no

[template:daily]
quiesce = auto

# dataset.inc
quiesce = auto
```

The dataset fragment silently wins for BOTH tiers, so the hourly run freezes too. The same class is worse with `send_schedule` or `prefix`: one line in dataset.inc can collapse several tiers onto one schedule or snapshot namespace.

### Recommendation

Make the PROFILE boundary stricter than general CONFIG v4:

- `templates.conf` owns tier-scoped policy: schedule, prefix/pattern, retention, monitoring, quiesce, autotune, tier labels/notification wording;
- `dataset.inc` owns only source-section composition fields that are genuinely source-wide, initially `use_template` and `recursive`;
- `prune.inc` owns only retention composition fields, initially `use_template`, `gfs`, `gfs_pattern` and any explicitly justified prune-scope field;
- do not let dataset.inc/prune.inc override arbitrary tier policy merely because native CONFIG v4 allows expert hand-written overrides.

This needs no gen-cron schema change; it belongs in `lib-profile.sh`, exactly like the existing profile-only topology restrictions.

## A2 — BLOCKER before `daily freeze`: GFS can mix different consistency classes

A useful policy is:

```text
hourly: no freeze
 daily: quiesced
```

If those create snapshots with prefixes such as:

```text
automated_hourly_...
automated_daily_...
```

and one combined GFS ladder uses:

```ini
gfs_pattern = automated_
```

then `delsnaps.sh -G` sees ALL matching snapshots and selects the newest snapshot in each age bucket. GFS does not know which tier created a snapshot or whether it was quiesced.

Therefore a snapshot retained as the "daily/weekly/monthly" representative can be an hourly crash-consistent snapshot. That silently destroys the meaning of "daily is the consistent restore point".

### Recommendation

Never combine different consistency classes in one GFS eligibility pattern.

For the concrete policy above, one safe conceptual shape is:

```text
hourly unquiesced -> its own retention set
quiesced daily snapshots -> D/W/M ladder built ONLY from daily-quiesced prefix
```

However current CONFIG/profile composition must be checked for whether it can express both retention groups cleanly on the same destination scope. If it cannot, that is a CONFIG v4/profile-shape requirement, not something to fake with a broader `gfs_pattern`.

## A3 — CONFIG/profile expressiveness gap: one prune scope cannot obviously carry two independent retention groups when one is GFS

A `[prune:<scope>]` can use multiple templates. With `gfs=no`, gen-cron emits independent prune rules per tier. With `gfs=yes`, it emits ONE combined ladder using ONE `gfs_pattern` for all tiers in that section.

That works for today's homogeneous hourly-created snapshot class. It is insufficient for the common policy:

```text
hourly unquiesced: retain H24
quiesced daily: retain D7/W4/M12 as a GFS ladder
```

without either mixing consistency classes or inventing another representation of a second prune policy on the same destination scope.

### Required design decision

Before shipping a built-in "freeze daily only" profile, prove one of:

1. existing CONFIG v4 can represent two retention groups on the same target without semantic abuse; or
2. add the smallest native representation that can, then let profiles use it.

Do not encode this as profile-only magic that gen-cron cannot represent natively.

## A4 — compatibility rule required: scope parent exclusion can contradict atomic recursion

Scope/relationship owns WHAT. Profile owns HOW. Those layers are not mathematically independent.

Example:

```text
scope: rpool/lxc parent=no, children=yes
profile: recursive=atomic
```

An atomic recursive ZFS stream rooted at `rpool/lxc` inherently includes the root. The composition cannot both exclude the parent and send one atomic subtree rooted there.

### Recommendation

Introduce an explicit scope/profile compatibility validator before mutation. At minimum:

```text
recursive=no      -> validate selected concrete dataset representation
recursive=flat    -> parent may be included or excluded; descendants are independent
recursive=atomic  -> selected root must participate; child-only scope is incompatible
```

The same validator should compute required grant/capability scope. Never resolve a contradiction by silently widening WHAT.

## A5 — likely capability gap: recursion is source-wide, not tier-wide

`recursive` is deliberately section-scope in CONFIG v4. All send/prune/monitor tiers for one `[dataset:]` share the same `no|flat|atomic` value.

Therefore this cannot currently be expressed for one source binding:

```text
hourly -> flat
 daily -> atomic
```

This may be acceptable product scope, but it must be a deliberate limit, not discovered after profile names imply it is possible.

Important nuance: a quiesced flat run can already create a useful coherent snapshot set, so "daily atomic" is not automatically required merely to obtain VM consistency. The product question is whether atomic transfer/tree semantics themselves must vary by tier.

### Recommendation

Do NOT widen CONFIG immediately. First define one concrete administrator case where tier-specific recursion adds material value beyond quiesced flat. If accepted, solve it natively in CONFIG v4 before profile catalogue growth. Otherwise document one recursion mode per source binding.

## A6 — SECURITY/CAPABILITY dependency: profile HOW can require deployment changes

`quiesce=auto` is policy, but delivering it as a delegated account requires privileged support:

```text
/usr/local/sbin/zfs-quiesce-helper
/etc/zfs-quiesce-allow/<account>
/etc/sudoers.d/zfs-quiesce-<account>
```

The source host deliberately authorizes this locally. Without the capability, the engine fails closed rather than taking an unquiesced snapshot.

Therefore changing a binding from a no-quiesce profile to a quiesce profile is NOT only CONFIG/cron regeneration. It may require a source-side privilege/capability transaction first.

### Recommendation

Every profile exposes a machine-readable **required capabilities** summary derived from its native fields, e.g.:

```text
requires.quiesce = yes
```

Composition must check deployed capabilities before activation. If missing:

- local/root path may provision through the normal privileged orchestrator;
- remote delegated path must route through the existing source-side authorization boundary;
- cron must not be installed until capability read-back succeeds.

Profiles still do not OWN grants. They declare what behaviour requires; deployment proves it is authorized.

## A7 — UX/semantic hole: `quiesce=auto` is not one uniform consistency class

Engine behaviour is intentionally different by object type:

- running QEMU VM -> guest-agent filesystem freeze; hard fail if agent/freeze unavailable;
- LXC -> `pct exec ... sync`; a flush, NOT a freeze;
- stopped guest -> nothing needed;
- dataset not matching Proxmox guest-disk naming -> nothing to quiesce, success.

So a profile summary that says merely:

```text
consistency = quiesced
```

would overpromise.

### Recommendation

Preview/status should resolve consistency against discovered scope and show facts, for example:

```text
VM 100 disks: agent freeze
CT 101 disks: sync flush only
custom dataset tank/db: no recognised guest quiesce
```

A built-in profile may still say `quiesce=auto`, but the UI must not translate that to a stronger guarantee than the engine provides.

## A8 — SCHEDULER trap: multiple tiers in one relationship can collide with each other

Stable staggering has mainly been discussed as "six clients all start at :01". A multi-tier profile adds another collision domain inside ONE relationship.

Example:

```text
hourly send  = 00:01
 daily send  = 00:01
```

With relationship-wide overlap exclusion, one job can systematically skip the other. A consistent daily tier could then never run even though every component is individually valid.

### Recommendation

The future slot allocator must consider:

1. cross-relationship start spreading; AND
2. intra-relationship tier separation.

Transfer and prune remain separate workload classes, but all send tiers sharing one relationship lock must be conflict-checked before concrete cron is accepted.

## A9 — LIFECYCLE trap: profile NAME is not enough durable intent

A relation that stores only:

```text
profile = default
```

is vulnerable to silent semantic drift when a software update changes `profiles/default/` or an administrator edits a custom profile under the same name.

The next regeneration could change schedule, retention, quiesce or recursion without the relation itself changing.

### Recommendation

Persist at least:

```text
profile_name
profile_content_digest/version
last accepted effective policy digest
```

On mismatch, show the policy delta and require explicit adoption before mutation. Existing relations must not silently track moving profile content.

For built-ins, `default` should mean "the preset selected by the admin", not "whatever today's package happens to call default".

## A10 — migration classification: not every profile change is a hot edit

Changing a profile can alter very different invariants:

- schedule only -> usually hot-edit;
- monitor thresholds -> hot-edit;
- quiesce -> capability check required;
- prefix/pattern/GFS -> retention namespace migration; old snapshots may become orphaned or newly eligible for deletion;
- recursion flat <-> atomic -> transfer topology/base semantics may require explicit compatibility proof or reseed;
- source/profile binding change -> only named source may change; additive sources must not reinterpret existing ones.

### Recommendation

Before `--profile NAME` can update an active binding, classify the delta:

```text
SAFE_REGENERATE
CAPABILITY_CHANGE
RETENTION_MIGRATION
TRANSFER_TOPOLOGY_CHANGE
REFUSE/RESEED_REQUIRED
```

Do not reduce all profile changes to "render new CONFIG and install cron".

## A11 — MONITORING trap: a healthy hourly tier can mask a dead daily-consistent tier unless monitoring is tier-specific

If hourly unquiesced snapshots continue but the daily quiesced job stops, a monitor using a broad/shared pattern can stay green forever.

CONFIG v4 already supports monitor thresholds per template/tier. The architecture should preserve that property in profiles and summaries.

### Recommendation

Every built-in SEND tier should either:

- have explicit tier-specific monitoring; or
- be visibly marked `monitoring = none` in profile preview.

For a profile advertised as providing a daily consistent restore point, monitoring that daily tier is part of the promise, not an optional cosmetic.

## A12 — MULTI-RELATION snapshot namespace needs an explicit contract

`pair_label` distinguishes relationship state/locking, but snapshot `prefix` comes from policy templates. Two zfs-snapshot-all relationships protecting the same source dataset with the same profile can therefore share the same managed snapshot-name namespace.

Possible consequences to measure before declaring this supported:

- both jobs may consume snapshots created by the other as matching candidates/common bases;
- retention/monitoring by prefix may observe the other relation's snapshots;
- different consistency policies using the same prefix can contaminate restore semantics;
- near-simultaneous creation can collide on names depending on suffix timing.

### Recommendation

Make one product contract explicit:

1. either one zfs-snapshot-all relationship owns a source root at a time; OR
2. managed snapshot identity is relationship-aware in a way shared consumers understand.

Do not leave multi-target protection as an accidental behaviour of identical prefixes.

## A13 — exception model: one source-root profile may be too coarse for one special child

Dynamic flat scope is intentionally useful:

```text
rpool/data -> default-flat
```

A later need may be:

```text
all rpool/data descendants -> default-flat
VM 120 database disk        -> stronger consistency/archive policy
```

Adding an overlapping child binding without a precedence/exclusion rule risks double coverage. Rejecting it makes one exceptional VM force enumeration of the whole parent.

### Recommendation

Not a B1 blocker. Before claiming mature per-source profiles, choose and document either:

- no overlapping source bindings (simple, explicit limit); or
- carve-out semantics: more-specific child binding excludes that child from parent binding, with preview of the resulting effective scope.

Never let both bindings silently run against the same child.

## A14 — RESTORE provenance: snapshot name alone does not prove profile/consistency history

Stage 6 will eventually answer questions like "give me the latest daily quiesced restore point". Snapshot names currently encode prefix/time, not a durable profile digest or quiesce outcome.

If profile contents can change over time, current profile state cannot prove what policy produced an old snapshot. Stats logs are best-effort operational history, not durable restore metadata.

### Recommendation

Before SAFE restore promises consistency classes, define how the planner proves provenance. Prefer the cheapest durable model that does not require speculative engine churn:

- immutable/pinned profile history plus unambiguous tier prefixes may be sufficient if measured and preserved;
- otherwise add explicit managed provenance metadata in a separately reviewed restore prerequisite.

Do not label a restore point "quiesced daily" merely because its name looks like a daily prefix.

---

# Priority / what blocks what

## Before B1 runtime wiring

Must resolve or explicitly constrain:

1. A1 profile-boundary cross-tier override rules.
2. A4 scope/profile compatibility validation.
3. A6 capability planning before activation.
4. A9 profile version/digest persistence contract (at least decide where it lands; B1 extraction itself may remain default-only if it cannot yet select/change profiles).

B1 may still extract today's default in a deliberately narrow default-only step if none of these new behaviours are exposed yet. Do not accidentally claim broad profile runtime while these are unresolved.

## Before shipping `hourly no-freeze + daily freeze`

Must resolve:

- A2 GFS consistency-class mixing;
- A3 multiple retention-group expressiveness;
- A8 intra-relationship schedule collision;
- A11 tier-specific monitoring.

## Before advertising arbitrary profile changes on active relations

Must resolve A10 and A9.

## Before Stage 6 restore claims consistency semantics

Must resolve A14, using the existing run-identity work as evidence rather than inventing metadata blindly.

## Deliberately NOT blockers yet

- A5 tier-specific recursion: real limitation, but require a concrete use case before schema work.
- A12 multi-relation same-source support: either explicitly forbid for v1 or measure/namespace it before supporting.
- A13 overlapping child override: useful future capability, but simple v1 can reject overlap loudly.

---

# Architectural summary

The useful mental model is no longer only:

```text
RELATION = WHAT/WHERE
PROFILE  = HOW
```

It needs one more composition layer:

```text
RELATION / SCOPE
      +
PROFILE (tier policy)
      +
HOST CAPABILITIES / AUTHORIZATION
      +
PROFILE VERSION
      |
      v
COMPATIBILITY + CAPABILITY PLAN
      |
      v
EFFECTIVE CONFIG v4
      |
      v
gen-cron
```

The profile itself should stay reusable and topology-free. The missing intelligence belongs in composition: verify that WHAT and HOW can coexist, that the host is authorized/capable of delivering HOW, and that a change from the previously accepted policy is safe before writing CONFIG/cron.
