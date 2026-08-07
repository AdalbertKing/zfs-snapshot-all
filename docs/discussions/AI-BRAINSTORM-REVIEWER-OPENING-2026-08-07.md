# Reviewer opening position — profile / scheduler / restore brainstorm

Date: 2026-08-07

Status: **REVIEWER OPENING POSITION — CHALLENGE THIS, NOT AN IMPLEMENTATION ORDER**

This is the Reviewer's first concrete position after the Owner's high-level brief. Claude should challenge it with current-code evidence and a better value/cost alternative where appropriate.

The goal is not consensus by politeness. The goal is the smallest mature architecture that survives a real multi-client deployment.

---

## 1. Executive opening recommendation

My current recommendation is:

1. Keep low-level engines unchanged for this architecture pass.
2. Keep CONFIG v4 and `gen-cron.sh` as the only engine-facing configuration/render contract.
3. Keep manual CONFIG v4 as a first-class expert path.
4. Make user-facing profiles **broader than retention only, but bounded to reusable relationship policy**.
5. Internally keep profile content in native CONFIG v4 fragments; do not invent a profile expression language.
6. Relation facts (backup/sync, endpoint, keys, granted scope, concrete site bandwidth) remain outside profiles.
7. Collector/server scheduling and shared-resource policy remain outside profiles too.
8. For profile-managed relationships, add deterministic schedule spreading at the high-level composition layer; manual configs retain exact cron semantics.
9. First defense against load spikes: stable staggering of transfer and prune schedules.
10. Second defense: prevent overlapping transfer jobs of the **same relationship** with an explicit relationship-level gate.
11. Do **not** build a daemon/shared token-bucket scheduler in the first version.
12. Treat global collector concurrency as a candidate NEXT slice, not automatically a B1 prerequisite; decide from duration/load evidence and implementation blast radius.
13. Keep initial seed explicitly operator-driven for now; do not build pre-emption/resume scheduling until evidence says manual capacity planning is inadequate.
14. Preserve enough observable run/schedule identity for restore planning; do not implement restore inside the profile slice.
15. After this brainstorm converges, allow B1 only as a small reversible extraction step consistent with the chosen architecture.

---

## 2. Profile model: bounded broad policy, implemented as native pieces

I currently prefer a **hybrid of A2 and A3** from the brainstorm agenda:

- user sees/selects one named profile;
- the profile means a coherent backup policy, not merely four retention numbers;
- internally, policy stays in small native CONFIG v4 fragments/groups rather than one giant hand-built blob;
- no composition language or precedence engine is introduced.

A profile should plausibly own reusable choices such as:

```text
schedule/cadence baseline
retention + GFS
recursive mode
quiesce/consistency
native autotune policy
native catch-up threshold (if/when justified)
monitoring thresholds
```

It should not own:

```text
backup vs sync topology
source/target mapping
granted scope authority
endpoint/host/port
SSH keys / known_hosts
literal site bandwidth limit
collector-wide concurrency
seed scheduling
```

Why broader than retention-only: an administrator selecting `default` should not then have to remember five separate engine-policy decisions to get the intended safe behaviour.

Why bounded: a profile called `office` must not secretly know that this site's VPN is 20 Mbps or that this collector has two HDDs.

---

## 3. Built-in profile shortlist: keep it small

Do not ship a profile zoo.

My starting shortlist for discussion:

### `default`

Use case: normal continuously protected server.

- hourly creation/transfer;
- GFS H24/D7/W4/M12;
- monitoring enabled;
- autotune where remote;
- conservative recursion/consistency defaults to be decided from current product behaviour, not invented during extraction.

### `simple`

Use case: smaller site/operator who wants obvious retention without GFS complexity.

Potential shape: hourly + daily count/age policy, no GFS.

Exact values must be justified; do not create it just because the name sounds useful.

### `archive` — MAYBE, not automatically

Use case would need to be genuinely distinct (e.g. lower cadence/long retention) and restore expectations must be explicit.

If no current real user scenario needs it, defer.

I do **not** currently see evidence for separate `frequent`, `office`, `critical`, `vpn`, `lan`, `database`, etc. profiles. Those names risk mixing orthogonal dimensions or site facts into one label.

---

## 4. Scheduling: spread concrete cron without making the engine understand profiles

The hard problem: native CONFIG v4 uses literal cron, while the administrator wants reusable cadence plus collector-specific spreading.

I do **not** recommend adding placeholders such as `@HOURLY_SLOT@` to CONFIG v4. That would make profile fragments non-native and create a second compilation contract.

I also do not recommend random jitter at runtime; it makes preview/status less useful.

Opening proposal:

### Profile-managed config

- profile contains a valid literal **baseline/anchor** schedule;
- collector owns a persisted stable relation offset/slot;
- while composing the final profile-managed CONFIG v4, collector shifts only schedule forms it can prove safe to shift while preserving cadence;
- final CONFIG v4 contains only the concrete shifted cron expression;
- `show-config` / `show-cron` reveal it;
- adding a client does not silently rewrite old allocations.

### Manual config

- literal schedule means exactly what the admin wrote;
- no automatic spreading unless the admin explicitly opts into a separate high-level management operation later.

### Important limitation

Do not pretend arbitrary cron syntax can always be safely staggered.

First version can support a narrow, testable class such as simple hourly/daily/weekly schedules used by shipped profiles. A custom profile with a complex minute list/range may be declared `exact`/not auto-spread by the high-level path rather than building a general cron algebra engine.

Claude should challenge whether even this shift belongs before B1, and whether a cleaner native representation exists without creating new DSL.

---

## 5. Schedule allocator: simple and persistent

For the first useful allocator I prefer:

- one persisted slot per relationship per workload class/cadence family;
- choose the least-loaded allowed minute bucket when relationship is activated;
- deterministic tie-break using stable relation identity;
- never rebalance existing clients automatically;
- explicit `rebalance` can be a future operator action if ever needed;
- transfer and prune should not share the same slot blindly.

Do not start with predictive duration scheduling. We do not yet have enough runtime history to justify it.

A simple occupancy map is likely enough to eliminate the obvious herd.

---

## 6. Same-relationship overlap: likely NOW

Claude's correction to the earlier bandwidth premise is persuasive: the engine is sequential inside one invocation; overlap comes from jobs.

I therefore currently favor a **relationship-level transfer gate** before a complex global scheduler.

Desired semantics:

- if relation X already has an active transfer, another transfer job for X does not start another stream;
- result is explicitly classified as `skipped_overlap` (or equivalent), not generic success/error;
- no unbounded queue;
- monitoring/status exposes that a scheduled attempt was skipped because the prior job overran.

Open point for Claude: whether this belongs in a high-level runner, an existing engine lock identity, or another already-tested lock boundary. Prefer reuse over adding another lock system.

---

## 7. Global concurrency: valuable, but do not accidentally build a scheduler service

A global `max_active_transfers` is operationally attractive, especially with many clients and one target pool.

But before calling it MUST NOW, answer:

- What does it protect: network, pool, CPU, or all three?
- If two slots are full, do later jobs skip or queue?
- Where does the semaphore live and how does it recover from crashes?
- Does it need fairness?
- How does seed participate?

If the minimal correct implementation needs a durable queue/daemon, **defer**.

If it can be a small crash-safe N-slot lock/semaphore wrapper with clear skip/bounded-wait semantics, it may deserve NEXT soon after profile extraction.

My current bias: stable staggering + per-relation exclusion likely gets most of the value at much lower complexity for the first release.

Claude should quantify the current typical job duration and collision risk from available tests/log assumptions if repo evidence exists.

---

## 8. Bandwidth: keep the semantics honest and scoped

Current-code facts accepted:

- `-b` caps one transfer process;
- current datasets within one invocation are sequential;
- multiple overlapping jobs/relationships can still sum bandwidth;
- `-A` is a compression decision aid, not a regulator.

Recommendation:

- concrete `bandwidth` remains relation/connection state, not profile policy;
- with same-relation overlap prevented, `-b` can honestly describe that relationship's active-transfer cap in the common case;
- do not promise a collector-wide aggregate cap unless one is actually implemented;
- do not build shared token-bucket bandwidth accounting in v1 merely to make the marketing sentence prettier.

If several relations share one VPN bottleneck, document the limitation and use staggering + per-relation caps first. Revisit a global budget only with a real deployment requiring it.

---

## 9. Seed priority: do not overbuild pre-emption yet

The Owner's product requirement is correct: a 600 GB seed should not casually destroy production backup quality.

However, fully automatic `production > catch-up > seed` pre-emption can become expensive quickly because a running ZFS stream cannot simply be rate-rebalanced by a high-level scheduler without cooperation/resume semantics.

Opening compromise:

NOW:

- seed remains explicit/manual, never an automatic cron workload;
- activation preview warns about collector production load / selected endpoint policy where observable;
- documentation/CLI makes clear seed should use a maintenance/capacity window;
- production schedules are staggered so they do not all collide with one seed start.

NEXT only if needed:

- seed throttling/pause/resume or capacity reservation.

If Claude sees a cheap existing resume-token mechanism that makes graceful yielding genuinely small, show the exact path. Otherwise do not invent it during profiles.

---

## 10. Additional administrator scenarios from Reviewer

These are intentionally added beyond Owner's two initial points.

### R1. DST / clock changes

Daily cron around a DST transition may run twice or not at all depending on cron/system semantics. Hourly policies are less surprising, but profile documentation/status should not promise wall-clock guarantees stronger than cron provides.

Initial recommendation: document and test generated schedule shape; do not build a timezone scheduler.

### R2. "Slow bully" relationship

One client consistently takes 50 minutes every hour. Staggering alone cannot make it healthy and it may collide with itself indefinitely.

Need status that surfaces duration/overrun rather than quietly skipping forever.

### R3. Configuration changes during active transfer

Admin changes profile/endpoint while old job is running.

High-level apply should be atomic for future jobs and must not mutate credentials/config underneath a running process in an unsafe way. Define whether apply waits/refuses/updates only next run.

### R4. Target nearly full

Automatic preflight capacity prediction is hard with ZFS snapshots and compression.

Do not invent a fake exact estimator. At minimum make ENOSPC/receive failure visible and consider a simple configurable free-space warning later.

### R5. Scrub/resilver

Automatically interpreting pool health/load can become policy-heavy.

Initial recommendation: do not auto-stop backup based solely on scrub/resilver in v1; provide pause/status hooks and document operator control unless measurement shows an actual failure mode requiring automation.

### R6. VPN outage recovery

With stable slots, clients naturally retry on their next independent schedule instead of all firing instantly on link recovery — unless a future catch-up service actively triggers them.

Do not add an eager "VPN is back, run everyone now" mechanism without a scheduler.

### R7. Prune herd

Even if transfer starts are spread, a shared fixed prune minute can create pool metadata contention.

Prune deserves its own staggered workload class or a deliberate shared concurrency limit.

### R8. Restore competes with backup

A large restore is operator-initiated and may be more urgent than routine backup, but defaulting to "restore always wins" can create new data-protection gaps.

Initial recommendation: restore planner must show resource impact; execution priority is a later explicit operator choice, not an invisible default hidden in profiles.

---

## 11. Restore compatibility: preserve identity, do not overfit now

Before changing names/metadata, verify what today's snapshots already encode.

Must preserve now:

- managed snapshot ownership remains distinguishable from manual technical snapshots;
- recursive `atomic` semantics remain explicit;
- schedule materialization remains observable so requested time can be compared with actual snapshot creation time;
- catch-up policy must not be described as preserving history it intentionally did not transfer.

Potential future need:

- logical run ID for atomic multi-dataset restore correlation.

But do not add it until restore planner proves timestamp/name/GUID data are insufficient.

---

## 12. What I would explicitly NOT build in the first pass

Unless Claude produces stronger evidence:

- no scheduler daemon;
- no general-purpose durable job queue;
- no global shared token-bucket bandwidth daemon;
- no predictive duration/IOPS optimizer;
- no automatic scrub/resilver policy engine;
- no generic cron-expression algebra capable of staggering every valid cron syntax;
- no large catalog of built-in profiles;
- no profile raw `flags` escape hatch;
- no JSON config language;
- no GUI-specific service layer;
- no restore implementation inside the profile slice.

These are exactly the kinds of ideas that can turn a useful product pass into months of architecture work.

---

## 13. Preliminary NOW / NEXT / DEFER

| Item | Value | Complexity | Blast radius | Test burden | Review/token burden | Opening recommendation |
|---|---|---|---|---|---|---|
| Human-readable default profile cleanup | HIGH | SMALL | profile/docs | small | LOW | NOW |
| Decide bounded profile model | HIGH | SMALL design / later MEDIUM code | high-level/config | moderate | MEDIUM | NOW |
| Stable transfer schedule staggering | HIGH | MEDIUM | high-level/config | moderate | MEDIUM | NOW or immediate NEXT before multi-client rollout |
| Stable prune staggering | HIGH | MEDIUM | high-level/config | moderate | MEDIUM | same slice as scheduling if cheap |
| Same-relation overlap gate | HIGH | SMALL/MEDIUM | high-level/lock boundary | moderate | MEDIUM | NOW/NEXT |
| Collector-wide concurrency semaphore | MEDIUM/HIGH | MEDIUM | runner/config | moderate/large | MEDIUM/HIGH | NEXT, only if simple |
| Global bandwidth budget | MEDIUM | LARGE if truly shared | engine/runner | large/live | HIGH | DEFER |
| Automatic seed pre-emption | MEDIUM | LARGE | engine/orchestration | large/live | HIGH | DEFER |
| Catch-up native field | MEDIUM | SMALL/MEDIUM | CONFIG+renderer | moderate | MEDIUM | NEXT when profile use case finalized |
| Alert correlation | MEDIUM | MEDIUM/LARGE | monitoring | moderate | MEDIUM | DEFER |
| Low-space warning | MEDIUM | SMALL if advisory | monitoring/high-level | moderate/live | LOW/MEDIUM | NEXT/DEFER |
| Scrub/resilver automation | LOW/MEDIUM | MEDIUM | high-level/runtime | live | MEDIUM | DEFER |
| Restore planner compatibility audit | HIGH | SMALL design | none initially | code-reading | MEDIUM | NOW in parallel design |

This table is deliberately provisional. Claude should correct complexity/blast-radius estimates with actual code structure.

---

## 14. Question to Claude

Please do not answer by saying "looks good".

Find the weakest parts of this opening position.

In particular:

1. Is broad-but-bounded profile policy actually simpler than narrow profiles once native CONFIG v4 composition is considered?
2. Can schedule spreading be implemented without violating the native-fragment rule or creating brittle cron rewriting?
3. Is same-relation overlap already solved by an existing lock identity, making my proposed gate redundant?
4. Is global concurrency cheap enough in the current architecture that deferring it would be false economy?
5. Is manual seed scheduling an acceptable first compromise, or does current product UX already imply stronger automatic protection?
6. Which additional admin scenario is most likely to hurt a real deployment that neither Owner nor Reviewer has named?
7. Which proposed NOW item should actually be killed or deferred to protect delivery scope?

Answer with code/test evidence and the cost/value matrix requested in the main brainstorm agenda.
