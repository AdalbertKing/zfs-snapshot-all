# Claude + Reviewer brainstorm — profiles, collector scheduling, resources and restore

Date: 2026-08-07

Status: **ACTIVE AI DESIGN DISCUSSION — NO RUNTIME IMPLEMENTATION UNTIL SYNTHESIS**

Primary Owner brief:

- `OWNER-HIGH-LEVEL-BACKUP-SYSTEM-BRIEF-2026-08-07.md`

Supporting evidence/discussion:

- `PROFILES-NATIVE-FRAGMENTS-PLAN-2026-08-07.md`
- `PROFILES-TRANSFER-NETWORK-POLICY-2026-08-07.md`
- `PROFILES-TRANSFER-CLAUDE-ANSWERS-2026-08-07.md`
- `PROFILES-ADMIN-REALITY-CHECK-2026-08-07.md`
- `ENGINE-FINALIZATION-PROFILES-RESTORE-2026-08-07.md`
- `ENGINE-PROFILES-RESTORE-CLAUDE-ANSWERS-2026-08-07.md`

This is a focused design exercise. The Owner has explicitly asked Claude + Reviewer to contribute their own administrator scenarios rather than merely respond to Owner-provided ideas.

The purpose is to decide a **minimum mature product architecture**, not to implement every possible scheduler feature.

---

## 0. Ground truth already established — do not re-litigate without code evidence

1. `gen-cron.sh` CONFIG v4 remains the native authoritative renderer contract.
2. Manual/native CONFIG v4 remains first-class; profiles are optional convenience.
3. No profile DSL, no `source`, no `eval`, no arbitrary shell execution.
4. `backup|sync` is relation/topology, not reusable retention profile policy unless strong evidence later overturns that.
5. Deploy/grants/security are not profile-owned.
6. Current default profile fixture is only Slice A; runtime still does not consume profiles.
7. Current default send schedule is minute `1`; prune ladder schedule is minute `21`.
8. `-A` measures link/data characteristics and chooses compression; it does not regulate bandwidth.
9. `-b` is a per-process limiter.
10. Current transfer engine processes multiple datasets inside one invocation sequentially; current concurrency problem is overlapping jobs/relationships rather than one invocation launching every descendant in parallel.
11. Future WebGUI is a client of CLI/config/status contracts, never another implementation of the backup engine.
12. Restore remains a parallel product concern (planner -> SAFE -> destructive/replace), not a discarded backlog item.

If any item above is wrong in current HEAD, challenge it with exact file/line/test evidence.

---

## 1. Brainstorm theme A — what should a profile actually mean?

Compare three practical models rather than assuming one.

### A1. Narrow policy preset

Mostly schedules, retention/GFS and monitoring; perhaps a small number of well-established native choices.

Examples of useful named presets:

- `default`: current H24/D7/W4/M12 GFS behaviour;
- hourly+daily only;
- hourly only;
- daily archive-like policy;
- no-GFS/simple-count policy.

Questions:

- Is this enough convenience for the normal admin?
- What repeated manual decisions would still remain outside the profile?

### A2. Broad backup-policy preset

One profile packages most reusable behaviour of a relationship:

- cadence/schedule intent;
- retention/GFS;
- recursion;
- consistency/quiesce;
- autotune/catch-up;
- monitoring;
- true reusable transfer choices represented by native fields.

Questions:

- Where does this become a kitchen sink?
- Which fields are environment facts and therefore must remain outside?

### A3. Internally composable policies, one simple user-facing profile

Architecturally, schedule/retention/consistency/transfer policy may be separate native fragments, but normal users still select one named profile.

Questions:

- Does this reduce duplication or merely create a hidden precedence framework?
- Can this be done without creating a second language?

### Required outcome

Choose one model or a deliberately small hybrid. Explain why it is the best value/cost compromise **for the first mature version**, not for an imaginary enterprise product five years from now.

---

## 2. Brainstorm theme B — schedule intent versus concrete cron

Administrator scenario:

- collector initially has one client;
- later it has six or ten clients;
- all use an hourly policy;
- naïve literal schedule causes thundering herd;
- long-running jobs can still overlap even after staggering.

Questions to settle:

1. Should a reusable profile contain a literal cron expression or a cadence intent that the collector materializes to concrete CONFIG v4?
2. If native CONFIG v4 only understands literal cron today, where should the high-level cadence intent live without contaminating `gen-cron.sh`?
3. What is the smallest stable slot allocator?
4. Where is assigned slot state persisted?
5. How do we avoid reshuffling existing clients when a new one is added?
6. How do custom/manual profiles opt into exact literal time and bypass automatic spreading?
7. Should transfer and prune have independent slot allocation?
8. How should genuinely separate daily/weekly SEND tiers be staggered if future profiles introduce them?
9. How should timezone/DST behaviour be explained and tested?
10. What should `show-config` / `show-cron` show so there is no hidden schedule magic?

Strong preference from Owner: **deterministic stable assignment, not random jitter.** Randomness may be useful internally only if the final assignment is persisted and observable.

---

## 3. Brainstorm theme C — concurrency, queueing and bandwidth

Use current job topology, not an imagined parallel engine.

Questions:

1. Is a per-relationship transfer lock with SKIP-on-overlap sufficient for first mature version?
2. Should overlap SKIP be represented distinctly in monitoring/stats rather than waiting for stale-snapshot detection alone?
3. Is a collector-wide `max_active_transfers` necessary NOW, or can stable staggering + per-relation exclusion safely defer it?
4. If global concurrency is implemented, use what smallest mechanism? Avoid a daemon unless evidence forces one.
5. Queue vs skip vs bounded wait: which failure mode is easiest for an admin to reason about?
6. How should a missed/queued job behave when the next cadence arrives?
7. Is a global WAN/VPN bandwidth cap actually needed for first version, or is endpoint/relationship `-b` + staggering enough?
8. If several relations share one physical VPN bottleneck, can the product honestly state its limitation instead of building a complex shared token bucket now?
9. Should prune jobs have their own concurrency gate?
10. Does restore need a resource class so a large restore cannot silently starve scheduled backups?

Owner's desired order of defense:

```text
1. prevent avoidable overlap by schedule allocation
2. prevent same-relation overlap explicitly
3. control broader shared resources only where real deployments justify the complexity
```

Challenge this ordering if code/operations evidence says otherwise.

---

## 4. Brainstorm theme D — seed, catch-up and production priority

Scenario:

- five clients are active;
- sixth client begins a 600 GB initial seed;
- production backups must continue to meet their objectives.

Questions:

1. Can initial seed simply be manually scheduled outside production windows in v1, or must the collector actively throttle/pause it?
2. If production begins while seed runs, what smallest mechanism protects production?
3. Is final catch-up distinct enough to deserve higher priority than initial seed?
4. Does a seed use the production endpoint bandwidth cap? Current intuition says LAN seed may intentionally be unrestricted and production VPN capped.
5. How much automatic priority machinery is actually justified before it becomes scheduler over-engineering?

Working priority intuition:

```text
scheduled production > final catch-up > initial seed
```

Do not treat this as an implementation mandate until alternatives are compared.

---

## 5. Brainstorm theme E — real collector hazards we have not discussed enough

Claude + Reviewer must each add administrator failure scenarios not already supplied by Owner.

At minimum evaluate:

- target pool low on free space;
- ZFS scrub/resilver running;
- collector reboot and many missed jobs becoming eligible together;
- VPN returns after a multi-hour outage and every client wants catch-up;
- one profile's prune overlaps another profile's transfer;
- clock/timezone/DST changes;
- one client consistently takes longer than its cadence;
- one client is noisy/huge and monopolizes pool I/O;
- source disappears mid-run;
- client is paused/disabled while queued/running work exists;
- configuration/profile changes while a previous run is active;
- new recursive descendants appear after the relationship was created;
- manual technical snapshots coexist with managed snapshots;
- a common shared outage produces an alert storm;
- restore is requested while normal backup traffic continues.

For each scenario, classify:

```text
HANDLE NOW
OBSERVE + FAIL/DEGRADE CLEARLY
DEFER WITH DOCUMENTED LIMIT
```

Do not solve all of them automatically.

---

## 6. Brainstorm theme F — restore compatibility

Restore design is not being implemented in this brainstorm, but use it as an architecture test.

Questions:

1. Does the proposed profile/scheduler model preserve enough run identity to plan restore cleanly?
2. Does staggered scheduling create any ambiguity about requested point-in-time restore?
3. Does `atomic` need additional run identity/metadata before we can promise coherent subtree restore?
4. Does catch-up/skip-intermediate policy remove restore points the user may expect? How should that be surfaced?
5. Should restore default to lower priority than production backup, equal priority, or be an explicit operator override?
6. Does SAFE restore need a staging capacity check before starting?

Do not let restore force speculative metadata if today's data already suffices; verify first.

---

## 7. Brainstorm theme G — user experience and future GUI

Normal administrator should be able to answer these without knowing engine flags:

```text
Which profile is selected?
What does that profile mean?
Which datasets are in scope?
When will this client actually run?
Why was this minute assigned?
What is its bandwidth/endpoint policy?
Is a job running, queued, skipped or blocked?
Is seed competing with production?
What will be pruned?
What restore points exist?
```

Before apply/activation, target UX should expose at least:

```text
relationship facts
selected profile / manual-config mode
effective schedule allocation
effective CONFIG v4
exact generated cron
resource/limit assumptions
warnings about documented limitations
```

No GUI-specific business logic now. Design the CLI/status boundary so GUI later has something sane to call.

---

## 8. Brainstorm theme H — profiles shipped with the product

Even before deciding the full profile model, propose a **small useful built-in set**, not a catalog of twenty presets.

For each candidate profile explain:

- intended administrator use case;
- cadence;
- retention shape;
- GFS yes/no;
- recursion/consistency defaults if those belong to the chosen profile model;
- why this profile earns maintenance cost.

The Owner's original examples strongly justify considering at least:

- current `default` H24/D7/W4/M12 GFS;
- hourly+daily simpler retention;
- non-GFS/simple retention.

Do not create these files yet. First decide whether they are genuinely distinct useful policies rather than cosmetic variants.

---

## 9. Cost/value discipline

The Owner explicitly wants to avoid turning two weeks of intense work into months of architecture churn.

For every proposed feature/change, return this matrix:

| Item | Admin value | Complexity | Blast radius | Test burden | Review/token burden | Recommendation | Simpler alternative |
|---|---|---|---|---|---|---|---|
| example | HIGH | SMALL/MEDIUM/LARGE | high-level / config / engine / security | small/moderate/large/live | LOW/MEDIUM/HIGH | NOW/NEXT/DEFER | ... |

Rules:

- no wall-clock delivery promises;
- prefer relative engineering cost;
- count engine/security changes as much more expensive than high-level orchestration changes;
- do not optimize for cleverness;
- explicitly reject features whose marginal value does not justify their blast radius.

A good brainstorm result contains several **"do not build this now"** decisions.

---

## 10. Required Claude response format

Claude: respond in a companion file, not by implementing runtime.

Suggested name:

`docs/discussions/AI-BRAINSTORM-CLAUDE-RESPONSE-2026-08-07.md`

Response should be concise enough for review and contain:

1. **Executive recommendation** — proposed minimum mature architecture in <= 15 bullets.
2. **Profile model decision** — A1/A2/A3/hybrid with rationale.
3. **Scheduler/resource minimum** — exactly what is NOW versus deferred.
4. **Built-in profile shortlist** — only useful presets.
5. **Restore compatibility findings** — what must be preserved now, what can wait.
6. **New admin scenarios Claude identified independently.**
7. **Cost/value matrix** from §9.
8. **Implementation stages** — smallest reversible slices, preserving tested lower layers.
9. **Explicit rejected ideas** — what not to build and why.
10. **Open disagreements with Reviewer**, if any, framed as precise technical claims with repo evidence.

Reviewer will then challenge/merge the response and produce one Owner-readable synthesis. Ordinary technical disagreements are to be resolved AI-to-AI; do not route the Owner as a messenger.

---

## 11. Gate

Until the response and Reviewer synthesis exist:

- do not start Slice B1 runtime extraction;
- do not add speculative CONFIG v4 fields;
- do not add scheduler daemons/queues/limiters;
- do not create new built-in profile variants;
- do not change low-level engine behaviour for this brainstorm.

Documentation/code-reading/tests used as evidence are fine.

The output of this discussion should intentionally be **smaller than the space of ideas considered**.
