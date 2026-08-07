# Profiles — transfer/network policy reopened before Slice B1

Date: 2026-08-07

Status: **OWNER CLARIFICATION / AI DESIGN REQUIRED — BLOCKS Slice B1**

This note reopens one part of the otherwise agreed profile design before runtime extraction starts. It does not change production code.

## 1. Owner clarification

Before Claude starts Slice B1, Owner requires the profile UX to account for the wider transfer policy, not only schedule/retention/GFS. In particular:

- checking/measuring available link bandwidth;
- bandwidth behaviour on VPN/slow links;
- sharing one relationship's bandwidth between concurrent transfers;
- compression/autotune policy;
- catch-up/skip-intermediate policy;
- other reusable transfer behaviour that belongs in a complete backup profile.

A profile should remain understandable to an administrator opening it in an editor, and the future WebGUI must be able to expose the same concepts without implementing separate backup logic.

## 2. Existing native mechanisms we must reuse

The engine already has useful primitives:

- `snapsend.sh` / `snapget.sh -A`: measures the real link and per-dataset compression ratio, caches link measurement for 7 days, and decides whether compression is worthwhile. `gen-cron.sh` already exposes this natively as `autotune = yes|no` and auto-adds `-A` on remote transfers unless an explicit compression choice overrides it.
- `snapsend.sh` / `snapget.sh -b RATE`: caps one transfer using the existing receive-side `mbuffer -r`.
- `-T N`: catch-up threshold / skip-intermediates decision based on the dataset's measured own snapshot interval.
- compression choices already exist in the engine (`-z/-Z/-g/-N`) and remote compression defaults on.
- `recursive` and `quiesce` already have dedicated CONFIG v4 fields.

Do not invent a profile DSL for any of these. If a reusable policy cannot be expressed cleanly in native CONFIG v4, extend the native config/engine contract first, then let profiles package it.

## 3. Current bandwidth semantics are insufficient

Today `zfs-backup.sh add-client --bandwidth=RATE` stores one `BANDWIDTH` value in the client record. When the client is loaded, the same `-b RATE` is appended to every transfer line.

That is a **per-process** ceiling, not an aggregate relationship ceiling.

Example:

```text
relationship cap configured: 2M
four dataset transfers run concurrently
current possible aggregate: ~8M
expected relationship ceiling: <= 2M
```

Therefore the current comment describing this as a slow-VPN peer "ceiling" is stronger than the mechanism actually guarantees.

Static division by the number of datasets at config-generation time is not acceptable as the general fix: recursive/flat policy discovers descendants at runtime, a new dataset may appear after configuration, and not every job is active for the same duration.

The implementation must choose a real aggregate mechanism (shared limiter/budget, deliberate serialization, or another tested design) if `BANDWIDTH` is to mean a relationship-wide cap.

## 4. LAN seed versus VPN production

The relationship may intentionally use different network conditions over its lifecycle:

```text
initial seed / catch-up: fast LAN
production schedule:    VPN / WAN
```

One unconditional client-level rate value is not enough to model "LAN unrestricted, VPN capped" or different endpoint capacities.

The current endpoint model should not be rolled back to magic `lan`/`vpn` slots merely to solve this. Endpoint identity remains literal host:port. If rate/capacity is endpoint-specific, model it as endpoint/relation connection data, not as a profile pretending to know a site's Mbps.

## 5. Ownership split proposed for Claude + Reviewer reconciliation

### Relationship / endpoint facts

These are concrete facts, not reusable backup policy:

- endpoint/address/port;
- SSH key/known-host material;
- actual configured total bandwidth ceiling for this relation/endpoint, if any;
- any measured link-capacity state/cache;
- mapping of which endpoint is currently active.

A profile must not contain a literal site-specific value such as `vpn_host=...` or assume that `20M` is correct for every client using that profile.

### Profile-owned reusable transfer policy

A profile may package reusable choices **only through native CONFIG v4 fields**, for example:

- `autotune = yes|no`;
- `recursive = no|flat|atomic`;
- `quiesce = no|agent|sync|auto`;
- schedule/retention/GFS/monitoring;
- compression policy once represented cleanly as native config rather than forcing a profile to own connection flags;
- catch-up threshold once represented cleanly as native config;
- any future parallelism/bandwidth-sharing policy once the underlying engine/config contract actually supports it.

### Product invariant, not a profile choice

If the high-level product calls a relationship value `bandwidth` or `bandwidth limit`, it should mean the **aggregate ceiling for that relationship**, independent of how many dataset jobs happen to be active. Correct accounting should not require a special profile.

A profile may choose a reusable strategy such as auto-tuning or concurrency policy, but it must not change the basic meaning of a configured relationship cap.

## 6. `flags` ownership needs to be revisited

The currently agreed fragment validator subtracts `flags` as relationship-owned because that field mixes connection material (`-K`, `-k`, `-p`, SSH `-O`, current `-b`) with transfer behaviour.

That blacklist is safe for Slice A, but it also prevents profiles from expressing reusable transfer choices if those choices exist only as raw engine flags.

Do **not** solve this by allowing arbitrary `flags` in a profile. That would let a profile override keys, ports, connection options and site-specific rate limits.

Preferred direction:

1. keep connection material relation-owned;
2. promote important reusable transfer decisions from raw flags to dedicated native CONFIG v4 fields where needed;
3. profiles then use those native fields;
4. `gen-cron.sh` remains the only renderer to engine argv.

This preserves the no-new-DSL rule and keeps profile files understandable.

## 7. What the final human-readable profile should expose

The shipped `default` profile should eventually let an administrator understand at least these policy groups without reading engine flags:

```text
SCHEDULE / SNAPSHOTS
RECURSION / SCOPE BEHAVIOUR
CONSISTENCY / QUIESCE
TRANSFER / AUTOTUNE / COMPRESSION / CATCH-UP
RETENTION / GFS
MONITORING
```

Concrete endpoint, credentials and actual site bandwidth remain outside the reusable profile.

## 8. Gate before Slice B1

Claude and Reviewer must reconcile this note against current code and the existing agreed profile design before runtime extraction starts.

Required answers:

1. Confirm exactly what `-A` measures and what it does **not** control.
2. Confirm current `-b` is per transfer and therefore cannot guarantee aggregate relation bandwidth with concurrent jobs.
3. Decide the smallest correct aggregate-bandwidth design, including dynamic recursive descendants.
4. Decide how LAN seed vs VPN/WAN production limits are represented without restoring magic endpoint slots.
5. Decide which reusable transfer choices deserve dedicated CONFIG v4 fields before profiles package them (compression, `-T`, concurrency/bandwidth policy, etc.).
6. Update the final `default` profile UX/comments so it represents the complete intended policy, not only today's hardcoded retention.

No Slice B1 runtime change should land until this design point has an AI consensus recorded in the repository.
