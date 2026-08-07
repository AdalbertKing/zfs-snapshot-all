# AI brainstorm — synthesis after Owner admin-reality review

Date: 2026-08-07

Status: **AI CONSENSUS — DESIGN PHASE CLOSED FOR THIS PASS**

This is the compact synthesis requested by Owner after the profile / scheduler /
bandwidth / restore brainstorm. It supersedes disagreements inside the earlier
brainstorm notes, but does not erase their evidence.

The purpose is explicitly to stop design churn and return to small delivery
slices.

---

## 1. Final architecture boundary

Four layers remain distinct:

1. **Engine** — `snapsend.sh`, `snapget.sh`, `delsnaps.sh`, monitoring and shared
   libraries. Execute operations; know nothing about user profiles or WebGUI.
2. **CONFIG v4 / profile policy** — native engine-facing policy. Manual CONFIG v4
   remains first-class and profiles remain optional.
3. **Relationship / endpoint** — concrete deployment facts: source/target,
   backup/sync, granted scope, host/port/keys, literal site bandwidth and stable
   assigned schedule state.
4. **Collector/orchestrator** — cross-relationship concerns: spreading work in
   time, preventing avoidable overlap, future shared-resource controls and
   operator-visible status/plan.

`gen-cron.sh` remains the single CONFIG v4 -> cron renderer.

Future WebGUI is a client of the high-level CLI/state; it does not reimplement
backup logic.

Restore remains a parallel product pillar, not an afterthought.

---

## 2. Profile model — consensus

Use a **bounded broad profile** with one rule:

> **Wide scope, narrow gate.** A reusable intent may enter a profile only after
> it exists as a native CONFIG v4 field with a real use case.

Therefore profile policy may include native reusable intent such as:

- schedule/cadence baseline;
- retention / GFS;
- recursion;
- monitoring;
- `quiesce = auto` or another deliberate native consistency policy;
- `autotune = yes|no`.

Why `quiesce=auto` and `autotune=yes` are portable policy rather than site facts:
the *intent* travels; runtime measures/resolves the environment locally.

A profile does **not** own:

- `backup|sync` topology;
- source/target mapping;
- grant authority;
- endpoint/port/key material;
- literal bandwidth such as `2M`;
- collector-wide concurrency;
- seed scheduling.

Do not add raw `flags` to profiles.

Do not create CONFIG fields merely because profiles might use them later.
`-T` catch-up policy is a candidate only after a concrete use case justifies a
native field.

No profile composition language / precedence framework is introduced.
Internally the profile may stay split into native CONFIG v4 fragments for
ownership clarity, but this is storage/implementation structure, not a new DSL.

---

## 3. Built-in profiles — keep the catalogue small

Owner's original requirement stands: provide several useful presets, not only
one GFS default.

The exact names and numeric values beyond `default` do **not** block B1.
The catalogue should stay deliberately small and be justified by deployment
patterns, for example:

- `default` — today's H24 / D7 / W4 / M12 GFS policy;
- one simple/hourly-focused preset;
- one simpler non-GFS or hourly+daily preset;
- an archive-style preset only if a real restore/retention use case justifies it.

Do not generate a Cartesian product of cadence x recursion x retention x
consistency.

Recursive mode remains a policy field, not a profile-name dimension.

Custom profiles use the same native representation as built-ins.

---

## 4. Multi-client scheduling — stable staggering is required

Owner supplied the concrete deployment case: six clients selecting the same
profile must not all inherit the same `:01` transfer and `:21` prune start.
That is sufficient product evidence; no further proof of need is required.

For **profile-managed relationships**, collector/orchestrator must eventually
materialize stable concrete offsets while preserving cadence.

Required semantics:

- deterministic/stable assignment;
- persisted per relationship;
- adding a new client does not reshuffle existing clients;
- transfer and prune are separate workload classes;
- final effective CONFIG v4 contains only ordinary literal cron expressions;
- `show-config` / `show-cron` expose the actual result;
- manual CONFIG v4 keeps exact cron semantics and is not silently shifted.

Do **not** implement random runtime jitter.
Do **not** build general cron algebra for arbitrary expressions in v1.
Shipped/simple schedules may be the first supported auto-spread class.

This is a high-level composition concern, not a reason to make `gen-cron.sh`
profile-aware.

---

## 5. Same-relationship overlap — reuse the existing engine lock

Code inspection resolved the earlier design question.

`snapsend.sh` already has a skip-on-collision lock keyed by job identity. Today
it prevents the same hourly job overlapping itself, but a different tier/job of
the same relationship can use a different key.

Consensus proposal:

- when `-L <relationship-label>` is present, key the existing transfer lock on
  that stable relationship identity;
- loser **skips and logs**, never waits indefinitely;
- without `-L`, retain today's per-job lock semantics and document the limit.

This reuses an existing tested mechanism: no daemon, queue, new lock directory or
new scheduling service.

Cost: **SMALL**.
Blast radius: engine lock identity, therefore this belongs **before engine
freeze** and needs focused tests.

---

## 6. Bandwidth — corrected model and v1 compromise

Earlier discussion incorrectly used parallel datasets inside one transfer as the
main multiplier. Code evidence corrected that premise: datasets inside the
current invocation are processed sequentially and same-schedule datasets are
normally grouped.

Real concurrency is overlapping jobs and different relationships.

Consensus:

- `-A` measures link/data to choose compression; it is not a bandwidth
  regulator;
- literal `bandwidth` remains relationship/connection state, not profile policy;
- same-relationship overlap exclusion makes one relationship much easier to
  reason about;
- do not promise a collector-wide aggregate bandwidth ceiling unless one is
  actually implemented;
- **do not build a shared token-bucket/bandwidth daemon in v1**.

Several relationships sharing one VPN can still sum their individual caps. V1
mitigation is stable staggering plus honest per-relationship limits and status.
A collector-wide bandwidth pool is DEFER unless a real deployment proves it is
worth the cost.

---

## 7. Global concurrency and server resource scheduler

The administrator problem is real, but a general scheduler service is not
justified for this pass.

V1 strategy:

1. spread predictable starts;
2. prevent same-relationship overlap;
3. expose overruns / skipped-overlap in status/monitoring;
4. keep seed operator-driven;
5. gather real duration/load evidence.

Then evaluate whether a small crash-safe collector-wide N-slot semaphore gives
enough value.

A global concurrency cap is **NEXT candidate**, not a prerequisite to extracting
the current default profile.

Explicitly not building now:

- scheduler daemon;
- durable general-purpose queue;
- fairness framework;
- predictive duration/IOPS optimizer;
- automatic scrub/resilver resource policy;
- shared global token-bucket bandwidth daemon.

---

## 8. Seed / final catch-up / production

Product requirement remains: bulk seed must not casually destroy production
backup quality.

V1 compromise:

- seed is explicit/operator-driven, not another recurring scheduler class;
- use the appropriate endpoint/capacity window;
- do not invent automatic pre-emption/resume during profile work;
- production schedules are independently staggered;
- capacity/pre-emption automation is NEXT/DEFER only with evidence.

Conceptual priority remains useful for future design:

`production > final catch-up > initial seed`, but v1 does not require a daemon to
enforce it dynamically.

---

## 9. Scope/reality reconciliation

Live administration exposed a higher-value issue: configuration can enumerate a
world that later changes. A new VM/dataset may exist with no effective backup or
may fall outside the granted scope.

Profiles must not hide this.

Before calling the profile UX mature, high-level tooling should report at least:

- desired/profile-selected scope;
- currently discovered datasets;
- granted scope;
- missing/out-of-grant datasets;
- resulting effective scope.

Never silently expand grants.

A reporting/reconciliation slice is **HIGH value / MEDIUM cost** and belongs
around the high-level profile rollout. Automatic grant mutation is not implied.

---

## 10. Restore compatibility and ordering

Restore remains separate from profile implementation, but one engine-level
identity issue must be settled before freeze.

Current conclusion from live tests/design:

- atomic recursive and quiesced flat runs already have useful correlation;
- flat non-quiesced work needs a run-level suffix/identity calculated once per
  logical run if whole-subtree restore is to identify one run reliably;
- shared snapshot name proves a shared **run**, not necessarily identical
  point-in-time semantics across every mode.

Therefore:

1. engine run-identity/suffix change required by the already agreed Stage 2 goes
   **before freeze**;
2. restore planner follows at high level;
3. SAFE restore follows planner;
4. destructive/replace restore is later and has its own safety contract.

Do not implement restore inside profile B1.

---

## 11. Operational scenarios explicitly retained

Architecture must remain compatible with these administrator cases even when no
new automation is built now:

- six clients selecting the same default profile;
- one slow relationship whose run approaches/exceeds cadence;
- prune herd after transfer starts have been spread;
- VPN outage and recovery without an eager "run everyone now" storm;
- new VM/dataset appearing after initial configuration;
- target near full;
- scrub/resilver during backup;
- config/profile/endpoint changed while an older job is running;
- manual snapshots beside managed snapshots;
- restore competing with scheduled backup;
- installed scripts lagging behind repository state.

Where v1 does not automate a case, behaviour/limitation must be observable and
honestly documented.

---

## 12. NOW / NEXT / DEFER

### NOW / before engine freeze

- finish already-agreed Stage 2 engine work, including restore-run identity;
- relationship-keyed reuse of the existing overlap lock, with focused tests;
- correct any misleading bandwidth wording;
- keep impact/test effort risk-shaped rather than broad by habit.

### NEXT / high-level delivery

- B1: extract today's default policy with byte-identical effective CONFIG v4;
- human-readable profile comments/summary;
- stable profile-managed transfer/prune schedule staggering;
- scope/reality reconciliation report;
- restore planner;
- SAFE restore;
- small built-in profile catalogue and custom-profile selection after the native
  base proves sound.

The precise order among the high-level NEXT slices should follow dependency and
cost, not ideology. B1 itself is reversible and may proceed once the NOW engine
freeze prerequisites are satisfied; it does not have to implement every NEXT
feature.

### DEFER / do not build in this pass

- global bandwidth sharing daemon;
- scheduler daemon / durable queue;
- automatic seed pre-emption;
- predictive resource optimizer;
- automatic scrub/resilver policy engine;
- generic cron-expression staggering algebra;
- large profile zoo;
- raw profile flags;
- JSON config language;
- WebGUI-specific duplicate service logic;
- destructive restore until planner+SAFE are proven.

---

## 13. Cost discipline

Owner explicitly requires avoiding a multi-month architecture detour after two
weeks of intensive work.

For every new proposal, ask:

1. Does it prevent incorrect/unsafe operation, or only improve convenience?
2. Can a smaller mechanism deliver most of the value?
3. Does it touch stable engine code?
4. What is the test and review/token cost?
5. Can it be added later without breaking native CONFIG v4?

A good design review must produce several explicit **do not build** decisions.
This one does.

---

## 14. Decision state

There are **no unresolved Claude ↔ Reviewer technical disagreements** from this
brainstorm.

No Owner decision is required to choose between competing AI proposals at this
point.

The design pass is closed. Resume delivery in small slices under the ordering
above, and reopen architecture only when implementation evidence exposes a real
conflict or materially changes the cost/value calculation.
