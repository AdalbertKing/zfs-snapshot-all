# Profiles / scheduler — administrator reality check before Slice B1

Date: 2026-08-07

Status: **OWNER CLARIFICATION / AI DESIGN REQUIRED — BLOCKS Slice B1**

Companion to `PROFILES-TRANSFER-NETWORK-POLICY-2026-08-07.md`.

This note deliberately stops looking at one relationship in isolation. The product must behave correctly when one backup server actually serves many clients at once.

## 1. Installation thought experiment

Assume an administrator installs one collector and gradually attaches six clients.

Each client uses the same sensible default policy:

- hourly backup;
- GFS retention;
- monitoring;
- auto-tuning/compression;
- production transport over VPN/WAN after an initial LAN seed.

A configuration can be perfectly valid per relationship and still be operationally bad at server level.

If all six clients inherit the same literal cron minute, the collector produces a thundering herd:

```text
01:01 client-1 starts
01:01 client-2 starts
01:01 client-3 starts
01:01 client-4 starts
01:01 client-5 starts
01:01 client-6 starts
```

The resulting contention is not only network contention. It can hit:

- collector uplink/downlink;
- VPN concentrator;
- source uplinks;
- target ZFS pool IOPS and write bandwidth;
- CPU used by compression/decompression/checksums/SSH encryption;
- RAM used by several mbuffer/compressor pipelines;
- source-side quiesce operations;
- prune/delete I/O;
- alerting/monitoring if a shared resource fails.

Therefore a mature product needs **server-wide resource scheduling in addition to per-relationship profiles**.

## 2. Important current clarification

In the current default profile, `standard_hourly` sends at minute 1 and the GFS prune ladder runs from a prune schedule at minute 21. Daily/weekly/monthly are retention buckets over the hourly snapshot family, not separate daily/weekly transfer starts.

That does not remove the multi-client problem: six clients still all start their hourly transfer at minute 1 and all can schedule prune work at minute 21.

Future custom profiles may also introduce genuinely separate daily/weekly send tiers, making collision handling even more important.

No existing code/search result shows a server-wide stagger/jitter/slot allocator today.

## 3. Three ownership layers

The previous two-layer discussion (profile versus relationship) is insufficient. There are three distinct policy scopes.

### A. Profile — reusable behaviour of one backup policy

Examples:

- cadence and retention intent;
- GFS ladder;
- recursion policy;
- quiesce/consistency policy;
- compression/autotune/catch-up policy;
- monitoring thresholds;
- perhaps a resource class/priority once native support exists.

A profile must remain reusable between unrelated clients.

### B. Relationship / endpoint — facts and assigned state of one client

Examples:

- source/target mapping;
- backup vs sync mode;
- granted scope;
- active endpoint, host, port, keys;
- endpoint-specific aggregate bandwidth ceiling;
- stable schedule slot(s) assigned by the collector;
- selected profile;
- measured link state/cache.

### C. Collector/server policy — shared capacity of the backup appliance

Examples:

- schedule spreading strategy;
- maximum concurrent transfers globally;
- maximum concurrent transfers per relationship;
- maximum concurrent prune jobs;
- global WAN/VPN bandwidth budget if applicable;
- target-pool I/O/concurrency budget;
- seed priority versus production jobs;
- reserved maintenance/scrub windows;
- queue/overrun policy.

A profile must not pretend it owns these server-wide facts. Six individually valid profiles must not be allowed to accidentally overcommit one collector.

## 4. Required feature: stable schedule staggering

The high-level product should not install the same literal minute for every newly attached relationship when the cadence can be preserved with a safe offset.

Example for six hourly relationships:

```text
client-1  minute 02
client-2  minute 12
client-3  minute 22
client-4  minute 32
client-5  minute 42
client-6  minute 52
```

The exact numbers are not the contract. The contract is:

1. preserve the profile's cadence (hourly is still hourly);
2. assign a deterministic/stable concrete slot per relationship;
3. avoid obvious collisions with already assigned clients;
4. persist the assignment so adding client-7 does **not** reshuffle clients 1-6;
5. show the assigned effective schedule before activation;
6. allow an expert/manual config to opt out and specify exact cron explicitly;
7. never hide the final cron — CONFIG v4 remains the truth consumed by `gen-cron.sh`.

A pure hash modulo 60 is not sufficient as the only algorithm because collisions are possible and it ignores already known load. A collector-side slot allocator can use stable relation identity plus the existing allocation map, choosing the least-loaded suitable slot and persisting it.

## 5. Staggering must not become a new profile DSL

The profile should continue to express native CONFIG v4 scheduling semantics.

The collector may materialize a relationship-specific effective CONFIG v4 by applying its assigned schedule slot as a native schedule override. This is the same class of composition as injecting relation-specific `src`, `dst`, account and pair identity: the final artifact is still ordinary CONFIG v4 and `gen-cron.sh` remains the only renderer.

Do not introduce profile-only syntax such as:

```text
jitter = 10m
spread = magic
schedule_class = blue
```

unless the same concept is first made a deliberate native high-level/server contract with clear semantics.

The user-visible invariant is more important than exact internal field spelling:

```text
profile says:      hourly
collector assigns: this relation at minute 22
show-config says:  the exact CONFIG v4 schedule
show-cron says:    the exact installed cron
```

## 6. Staggering alone is NOT sufficient

Minute offsets reduce the thundering herd but do not guarantee resource safety.

Example:

```text
client-1 starts 02, duration 35 min
client-2 starts 12
client-3 starts 22
client-4 starts 32
```

By 32, four jobs can still overlap.

Therefore the design also needs a collector-wide concurrency gate.

At minimum, AI design must decide:

- global maximum active transfers;
- per-relationship maximum active transfers;
- whether waiting jobs queue, skip, or fail after a bounded wait;
- what happens when the next cadence arrives while an old run is still queued/running;
- how this interacts with existing per-job/pair locks;
- whether seed jobs consume the same slots as production jobs.

A likely safe default for a small collector is conservative concurrency rather than "start everything and hope ZFS/TCP sort it out".

## 7. Seed must not starve production

A first seed can run for hours and is intentionally bulk traffic. Once the collector serves existing production clients, adding a new client must not make their scheduled backups stale.

Required design question:

```text
production backup > final catch-up > initial seed
```

or an equivalent explicit priority policy.

Possible mature behaviour:

- seed uses spare capacity;
- production jobs have reserved concurrency/bandwidth;
- seed is throttled/paused when scheduled production jobs need the collector;
- final catch-up can temporarily receive higher priority because it gates endpoint activation.

The exact implementation is open; the product requirement is not.

## 8. Transfer and prune should not blindly collide

Current cron design can schedule transfer work and prune work independently. If a transfer overruns its nominal gap, prune may start while heavy receive I/O is still active.

This can cause:

- additional pool metadata I/O;
- snapshot destroy work competing with receive;
- harder-to-diagnose performance cliffs;
- several clients pruning simultaneously at the same minute.

The collector scheduler should therefore consider at least two workload classes:

```text
TRANSFER
PRUNE/MAINTENANCE
```

Potential policies include separate windows, separate concurrency pools, or one shared resource gate with priorities. Do not assume that "minute 21 is later than minute 1" proves non-overlap.

## 9. Monitoring must avoid alert storms

With many clients, a shared collector/VPN failure can make every relationship stale at once. Six independent CRITICAL mails for one common outage are technically correct but operationally poor.

Profiles own per-job WARN/CRIT thresholds, but collector-level alerting should eventually support correlation/digest behaviour such as:

```text
6 relationships stale
common VPN/collector dependency appears down
=> one high-level incident + affected relationship list
```

This does not need to block the first profile implementation, but the profile design must not bake in assumptions that make later correlation impossible.

## 10. Capacity hazards to test from the administrator's perspective

Before calling profiles mature, walk through at least these real deployments:

1. one client, one dataset, LAN;
2. one client, recursive subtree where new descendants appear later;
3. one client, several independent dataset jobs;
4. six clients, same default profile;
5. six clients over one VPN/WAN bottleneck;
6. mixed LAN + VPN clients;
7. one multi-hour seed while five clients are already active;
8. transfer runtime longer than its assigned schedule gap;
9. collector reboot / missed cron window;
10. VPN outage followed by recovery of all clients together;
11. target pool nearly full while multiple clients receive;
12. ZFS scrub/resilver while backups run;
13. prune coinciding with heavy receive;
14. one source creating a new VM/dataset after configuration;
15. quiesce enabled on a source with several running guests;
16. manual technical snapshots existing beside managed snapshots;
17. restore/verification work competing with scheduled backup traffic.

The product should either handle each case or state an explicit, observable limit. Silent overload is not an acceptable behaviour.

## 11. Additional likely server-level controls

The administrator thought experiment suggests these concepts may be required even if they are implemented later:

- `max_active_transfers` (collector-wide);
- `max_active_transfers_per_relation`;
- `max_active_prunes`;
- aggregate bandwidth per endpoint/relationship;
- optional aggregate collector/WAN cap;
- stable staggered schedule slots;
- bounded queue age / overrun handling;
- seed/production priority;
- low-space safety threshold before accepting new bulk receives;
- awareness of scrub/resilver/maintenance load or at minimum operator pause hooks;
- observable runtime/duration statistics so schedule pressure can be diagnosed.

Do not add these as arbitrary profile keys. Decide which are server policy, which are relation state, and which genuinely belong to reusable profile policy.

## 12. Preferred user experience

When the sixth client is activated, the administrator should see something like:

```text
Client: branch-06
Profile: default
Cadence: hourly
Assigned transfer slot: :52
Assigned prune slot:     :??
Endpoint: 10.8.0.26:22
Endpoint bandwidth cap: 2M aggregate
Collector transfer slots: 2 total
Current slot plan:
  branch-01 :02
  branch-02 :12
  branch-03 :22
  branch-04 :32
  branch-05 :42
  branch-06 :52

No existing client schedule changed.
```

Then `show-config` and `show-cron` expose the exact native artifacts.

The administrator should not manually calculate cron minutes to avoid collisions.

## 13. Gate before Slice B1 — expanded

The existing B1 block remains. In addition, Claude + Reviewer must answer before runtime extraction:

1. What is the smallest correct stable schedule-slot allocator?
2. Where is the assigned slot persisted?
3. How does native CONFIG v4 receive the relation-specific schedule without a profile-only DSL?
4. What are the default global and per-relation concurrency semantics?
5. What happens on overrun: queue, skip, bounded wait, or another explicit rule?
6. How are seed jobs prevented from starving production backups?
7. How are prune jobs prevented from creating a second synchronized herd?
8. Which of these are server policy versus relationship state versus reusable profile policy?
9. How will `status` / future WebGUI expose schedule allocation and resource pressure?
10. Which cases in §10 must be automated tests versus live/manual verification?

No Slice B1 runtime extraction should proceed until this multi-client server view is reconciled with the native-fragment profile design.
