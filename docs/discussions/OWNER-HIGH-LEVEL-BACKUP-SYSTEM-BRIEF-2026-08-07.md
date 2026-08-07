# Owner high-level backup-system brief — before further profile runtime work

Date: 2026-08-07

Status: **OWNER DIRECTION / ARCHITECTURE BOUNDARY — DISCUSS FIRST, DO NOT IMPLEMENT FROM THIS FILE ALONE**

This document captures the Owner's later voice discussion with the Reviewer after the earlier profile/network notes. It supersedes any earlier implication that Slice B1 should start immediately merely because Slice A is green.

The Owner's instruction is: **pause profile runtime extraction long enough for Claude + Reviewer to do a real administrator-focused architecture brainstorm, reach a practical compromise, and return a concise recommendation.** Do not turn this into a months-long redesign. The goal is a mature product with a controlled scope, not theoretical completeness.

---

## 1. Product philosophy

The project should continue to follow a Unix/Linux-style layering model:

```text
complete, scriptable batch/CLI package first
                 ↓
stable native config + orchestration contracts
                 ↓
future WebGUI as a client of those contracts
```

The WebGUI must not become a second backup engine or a second implementation of retention, recursion, grants, scheduling or restore logic.

A competent administrator must always be able to run the product without profiles and without a GUI by writing/using native CONFIG v4 directly.

Profiles are a convenience layer, not a mandatory ontology.

---

## 2. Four layers we must keep conceptually separate

### Layer 1 — engines / low-level mechanisms

Examples: `snapsend.sh`, `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh`, ZFS/SSH primitives.

Principle: **keep this layer stable, deterministic and heavily tested.** Do not move high-level product intelligence down into it unless a missing primitive genuinely cannot be expressed above.

### Layer 2 — native CONFIG v4 + profile convenience

`gen-cron.sh` remains the authoritative renderer of CONFIG v4.

A profile may package reusable policy, but the final artifact must remain ordinary CONFIG v4. Manual CONFIG v4 remains first-class.

### Layer 3 — relationship + collector/orchestrator

This is where the product knows that many individually valid relationships share one physical backup server.

This layer owns or may need to own:

- concrete source/target/endpoint identity;
- assigned schedule slots;
- server-wide concurrency/resource policy;
- seed versus production priority;
- relationship/endpoint bandwidth facts;
- aggregate view of many clients;
- operational state and status/preview.

### Layer 4 — restore

Restore remains an independent major product layer and must not be forgotten while profiles are designed.

It does **not** block the present brainstorm, but every important backup/profile/data-model decision should be checked against future restore:

- can we identify the right restore point?
- can the user preview what will be restored?
- can safe restore work without touching production data?
- can atomic recursive backup later yield a coherent atomic restore point?

Restore work already discussed (planner -> SAFE -> destructive/replace) remains alive and must resume after the current architecture pass; it is not cancelled by profiles.

---

## 3. Why the Owner reopened the profile discussion

The original idea was intentionally modest: ship several useful ready-made policies instead of forcing an administrator to hand-write every retention ladder.

Examples of the original intent:

- current `default`: hourly snapshots with GFS retention `H24 / D7 / W4 / M12`;
- a simpler hourly+daily profile;
- a profile without GFS;
- other pre-defined schedules/retention shapes;
- custom administrator profiles using the same native format.

That is still valid.

However, after looking at a real multi-client deployment, the Owner wants Claude + Reviewer to determine whether a profile should remain mostly a retention/schedule preset or evolve into a broader reusable backup-policy preset (recursion, consistency, autotune, catch-up, monitoring, etc.).

**No decision has been made yet.** Do not silently promote the profile into a giant monolith, and do not silently freeze it as "retention only". Compare the models and recommend the smallest one that gives real operational value.

---

## 4. Administrator reality check: think about the seventh client, not the first

Design as if an administrator installs one collector and gradually attaches six, ten or twenty endpoints.

The question is not only "does each generated cron line parse?". The question is:

> Does the whole backup server remain predictable when many correct relationships operate at once?

The existing detailed thought experiment is in:

- `PROFILES-ADMIN-REALITY-CHECK-2026-08-07.md`
- `PROFILES-TRANSFER-NETWORK-POLICY-2026-08-07.md`
- Claude's first response: `PROFILES-TRANSFER-CLAUDE-ANSWERS-2026-08-07.md`

Those documents are inputs to this brief, not the end of the discussion.

---

## 5. Scheduling and bandwidth are one operational problem with two defenses

The Owner explicitly connected these two topics.

### Defense A — avoid unnecessary overlap first

If six clients use an hourly policy, do not blindly materialize all six at the same literal minute.

The collector should be able to spread equivalent cadence across stable slots, for example:

```text
client-1 :02
client-2 :12
client-3 :22
client-4 :32
client-5 :42
client-6 :52
```

The numbers are illustrative, not a contract.

Required properties:

- cadence is preserved;
- allocation is deterministic/stable;
- adding a new client does not reshuffle old clients unexpectedly;
- the exact effective CONFIG v4 and cron are visible before activation;
- an expert/manual config can choose an exact schedule and opt out of automatic spreading.

This should apply to other synchronized workload classes too (especially prune), not only transfers.

### Defense B — control shared resources when overlap is unavoidable

Staggering does not guarantee non-overlap because jobs may run longer than their slot gap.

If jobs still overlap, the system needs explicit resource semantics rather than hoping TCP/ZFS will self-balance.

Claude correctly established an important current-code fact after the earlier note:

- datasets inside one current `snapsend`/`snapget` command are processed sequentially;
- the dangerous concurrency is overlapping **jobs/relationships**, not arbitrary parallel descendants inside one command;
- `-b` is per process;
- `-A` measures link/data and decides compression only; it is not a bandwidth regulator.

Therefore do not design a runtime descendant-count divisor. Design around the real job topology.

Open questions include:

- per-relationship overlap lock/skip semantics;
- collector-wide concurrency limit;
- optional aggregate WAN/VPN budget;
- how bandwidth ceilings are scoped (endpoint, relation, collector);
- whether production can pre-empt/throttle seed;
- whether a bounded queue is worthwhile or whether skip+monitoring is safer/simpler.

The Owner's desired invariant is simple even if implementation is not:

> First avoid collisions by scheduling. If collisions still happen, control the shared resource explicitly.

---

## 6. Server-wide resource policy exists above profiles

A key conclusion from the administrator thought experiment is that profile and relationship are not enough. There is a third scope: **collector/server policy**.

Possible server-level concerns:

- maximum concurrent transfer jobs;
- maximum concurrent prune jobs;
- seed versus production priority;
- global WAN/VPN ceiling if one bottleneck is shared;
- target-pool pressure;
- CPU/RAM pressure from compression, SSH and buffers;
- low free-space safety;
- scrub/resilver/maintenance periods;
- restart/recovery stampedes after a missed window;
- alert correlation when one shared outage makes many clients stale.

Do not automatically implement all of these. First classify them:

- MUST HAVE for the first usable multi-client product;
- SHOULD HAVE soon;
- NICE TO HAVE / defer.

A mature design may deliberately state an observable limitation instead of implementing an expensive scheduler. Silent overload is the unacceptable option.

---

## 7. Seed is not equal to production

A new multi-hour initial seed must not make established production clients miss their normal backup objectives.

The working priority intuition is:

```text
production scheduled backup
        >
final catch-up needed for activation
        >
initial bulk seed
```

The exact mechanism is open. Possible implementations range from simple scheduling/locks to explicit capacity reservation. Choose the smallest mechanism that actually protects production.

Do not add a daemon merely because a theoretically perfect resource allocator can be imagined.

---

## 8. Profile content remains an open design decision

Claude + Reviewer must compare at least these models.

### Model A — narrow preset

Profile mostly packages native schedule + retention/GFS + monitoring, with only a few established policy fields.

Pros: small, understandable, low blast radius.

Risk: administrator still assembles several important reusable choices elsewhere.

### Model B — broad policy profile

Profile packages most reusable behaviour of one relationship: schedule intent, retention, recursion, consistency, autotune/catch-up, monitoring and other true policy choices.

Pros: one meaningful high-level choice for normal users.

Risk: profile becomes a kitchen sink and starts absorbing environment-specific facts.

### Model C — internally composable policy pieces with one user-facing profile

Implementation/design may think in separate policy groups, while the administrator still selects one named profile.

Pros: avoids monolith internally while keeping UX simple.

Risk: can accidentally create a new meta-language or precedence system.

The Owner has **not selected a model**. Claude + Reviewer should recommend one after applying the constraints below.

Hard constraints whatever model wins:

1. no second config DSL merely for profiles;
2. no arbitrary raw `flags` as the profile's escape hatch;
3. CONFIG v4 stays canonical for the engine;
4. manual CONFIG v4 stays first-class;
5. relation/security/endpoint facts remain outside reusable profile policy;
6. profile selection can never expand ZFS grants silently;
7. future WebGUI must expose the same concepts rather than recreate logic.

---

## 9. Native fields should be earned, not invented speculatively

If a useful reusable policy exists only as an engine flag, do not automatically expose arbitrary `flags` in profiles.

Preferred sequence:

```text
real administrator use case
        ↓
prove it deserves a stable semantic field
        ↓
add native CONFIG v4 support (if needed)
        ↓
profile may package that native field
```

This keeps the profile understandable and the engine contract stable.

`autotune` and `recursive` are examples of concepts already represented natively. Catch-up threshold may deserve a field; connection credentials/port/key and concrete bandwidth facts do not become profile policy merely because they are flags today.

---

## 10. Future WebGUI consequence

The high-level CLI/orchestrator should eventually provide stable operations such as:

- plan/preview effective relationship;
- show effective config;
- show exact cron;
- status including assigned schedule/resource state;
- idempotent apply/update operations;
- later, machine-readable output where a real GUI consumer needs it.

Do not add JSON just to look API-ready. Add a machine contract when there is a consumer, while preserving CONFIG v4 as the configuration truth.

A GUI button must not contain business logic that the CLI cannot perform.

---

## 11. Restore compatibility check

While evaluating profile/scheduling choices, explicitly verify they do not make restore harder.

Questions to keep visible:

- Do snapshot names/metadata provide enough identity for requested point-in-time restore?
- If scheduling is staggered, does the user still understand the actual snapshot time?
- If `atomic` means one coherent run, can restore identify that run as a unit?
- Do catch-up/skip-intermediate choices affect which historical restore points physically exist on the target?
- Can a restore job coexist with collector resource controls without starving scheduled backups?

Restore is not an excuse to block every profile decision, but it must not be rediscovered after the data model is frozen.

---

## 12. Delivery discipline: do not turn this into a multi-month architecture project

The Owner has already invested heavily in this project and explicitly does **not** want a theoretically perfect design that expands into months of work.

Every proposal from Claude + Reviewer must therefore include:

- user/admin value: HIGH / MEDIUM / LOW;
- implementation complexity: SMALL / MEDIUM / LARGE;
- blast radius: high-level only / CONFIG+renderer / engine / security;
- test burden: small / moderate / large / live-host required;
- expected review/token burden: LOW / MEDIUM / HIGH (rough category is enough);
- recommendation: NOW / NEXT / DEFER;
- the simplest acceptable alternative.

Do not estimate wall-clock delivery dates. We care about relative engineering cost and risk, not promises.

Decision heuristic:

> Prefer the smallest design that solves a real deployment failure mode, preserves the tested engine contracts, and does not paint restore/WebGUI into a corner.

---

## 13. Immediate instruction to Claude + Reviewer

1. **Do not start Slice B1 runtime extraction yet.** The earlier Claude response predates this Owner direction.
2. Read this brief together with the three profile/admin/network discussion files named above.
3. Brainstorm proactively. Do not wait for Owner to invent points 3, 4, 5 and 6.
4. Think like the administrator operating the collector after a week, a month and after adding the tenth client.
5. Identify likely failure modes and operational annoyances.
6. Separate MUST / SHOULD / DEFER and explicitly kill over-engineered ideas.
7. Reconcile disagreements AI-to-AI using current code/tests as evidence. Owner is not a relay.
8. Produce a compact, Owner-readable synthesis with a recommended minimum viable architecture and staged implementation order.
9. Only after that consensus should implementation resume.

The expected outcome is not a giant specification. It is a **practical architecture boundary and a short staged plan** that makes the system noticeably more mature without destabilizing the low-level engines.
