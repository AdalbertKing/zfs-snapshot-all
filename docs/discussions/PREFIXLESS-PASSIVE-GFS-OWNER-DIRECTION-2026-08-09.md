# Owner direction — expose prefixless create/passive + single-series GFS

Date: 2026-08-09
Status: MUST DO — sequencing to be agreed by Claude + Reviewer
Owner direction: this capability is required; do not lose it while finishing Stage 5/presets.

## Why this note exists

Discussion with the Owner exposed a mismatch between the engine capabilities and the current CONFIG/gen-cron/profile surface. The engine already supports useful, internally consistent prefixless behavior, but the generator currently requires fields that make part of that behavior unreachable from native CONFIG/presets.

This is not a request to change `snapsend.sh`/`snapget.sh` semantics. The preferred direction is to expose behavior the engines and `delsnaps.sh` already have, with the smallest CONFIG/generator change that preserves one source of truth.

## Verified engine facts

### 1. Passive mode already exists

Both `snapget.sh` and `snapsend.sh` support `-e`: use an already-existing source snapshot instead of creating a new one.

The engines obtain snapshots using `zfs list ... -t snapshot -s creation`; if `MESSAGE`/`-m` is non-empty they filter names by `^MESSAGE`, then choose the final element of the creation-sorted list.

Therefore:

- `-e -m PREFIX` = newest existing snapshot whose name starts with PREFIX;
- `-e` with no `-m` = newest existing snapshot by ZFS creation time, regardless of name.

### 2. Create mode does NOT require a prefix

The engines can create a snapshot without `-m`; the resulting snapshot is named from the engine timestamp format. Therefore any statement that create mode needs a prefix because the engine otherwise cannot name the snapshot is false.

The natural matrix is:

| mode | prefix | engine meaning |
|---|---|---|
| create | present | create `prefix + timestamp` |
| create | absent | create timestamp-only snapshot |
| existing/passive | present | use newest existing snapshot matching prefix |
| existing/passive | absent | use newest existing snapshot of any name |

Prefix is therefore an optional namespace/filter, not an engine precondition.

### 3. `delsnaps.sh -G` already supports one hourly series -> GFS 24/7/4/12

`delsnaps.sh` documents and implements `-G` as a cascading GFS ladder. With

```
-G -H24 -D7 -W4 -M12
```

it selects survivors from ONE eligible snapshot series:

- last 24 hourly buckets — newest survivor in each hour;
- next 7 daily buckets — newest survivor in each day;
- next 4 weekly buckets — newest survivor in each week;
- next 12 monthly buckets — newest survivor in each 30-day bucket.

The rungs are consecutive and non-overlapping. This does NOT require separately-created hourly/daily/weekly/monthly snapshot families.

`-G` is explicitly orthogonal to pattern and supports an empty pattern. Thus both are valid engine-level policies:

```
automated_* hourly series -> delsnaps ... automated_ -G -H24 -D7 -W4 -M12
```

and

```
timestamp-only hourly series -> delsnaps ... "" -G -H24 -D7 -W4 -M12
```

The latter intentionally means every otherwise-eligible snapshot name is in scope, subject to the engine's existing protected-prefix and in-flight protections. The administrator is allowed to choose that policy; preview/warnings may state the fact, but the tool should not invent a prohibition merely because it is broad.

## Current CONFIG/profile state

The current shipped default profile already embodies the important single-series idea for the prefixed case:

- `standard_hourly` creates one `automated_hourly_...` snapshot each hour;
- `keep_hourly`, `keep_daily`, `keep_weekly`, `keep_monthly` contribute `-H24/-D7/-W4/-M12`;
- `prune.inc` combines them with `gfs=yes` and `gfs_pattern=automated_`.

So the project already moved away from requiring four separately-created snapshot families for GFS. That direction is correct.

However current `gen-cron.sh` artificially narrows the engine contract:

1. any send/create task with `send_schedule` requires a non-empty `prefix` (`require_field prefix`);
2. `gfs=yes` requires a non-empty `gfs_pattern`.

Those requirements make the fully prefixless variants unreachable even though the underlying engines support them.

## Required product outcome

The Owner requires that the CONFIG/preset surface eventually be able to represent all four combinations in the matrix above, including:

1. create + prefix;
2. create + no prefix;
3. existing/passive + prefix;
4. existing/passive + no prefix;

and that GFS 24/7/4/12 be usable over a single hourly series both with a prefix and with no prefix.

Do NOT solve this by changing the engine merely to satisfy the generator. Prefer removing unnecessary generator restrictions and reusing existing engine semantics.

## Design question still to settle

One question remains open between Claude and Reviewer:

Should passive/existing be exposed in CONFIG as a first-class field (for example `snapshot_mode = create|existing`), or should CONFIG continue to express it through the already-existing `flags = -e` and profiles/presets merely generate that flag?

Constraints for that decision:

- avoid two independent ways to state the same policy;
- avoid a new mini-DSL if a small existing representation is sufficient;
- preserve native CONFIG as execution truth;
- make the operator-facing preset/preview understandable without requiring knowledge of `-e`;
- do not couple installed policy back to a profile after CREATE.

The Owner has NOT required a particular field spelling. The required outcome is capability and consistency, not a specific syntax.

## Retention / ownership warning semantics

Broad prefixless pruning is potentially destructive by design, but it is not inherently invalid. The package is an expert administration tool, not a policy nanny.

For a prefixless GFS rule, preview should make the scope explicit, e.g. equivalent to:

```
GFS source set: all otherwise-eligible snapshots on DATASET (no name filter)
Retention: H24 D7 W4 M12
```

Existing protections for Proxmox-reserved prefixes and in-flight snapshots remain independent safeguards. Do not silently redefine empty pattern to mean some hidden generated prefix.

## Minimal implementation/evidence boundary

Expected change area is primarily CONFIG/gen-cron/profile tests, not ZFS transfer logic:

- allow missing/blank send `prefix` when the resulting engine invocation is valid;
- emit no `-m` when prefix is absent;
- allow `gfs=yes` with an explicit/represented empty pattern and emit `delsnaps ... "" -G ...` correctly;
- preserve current non-empty-prefix behavior byte/semantically;
- prove all four create/existing x prefix/no-prefix combinations at the generated-command boundary;
- prove prefixed and prefixless GFS renderings;
- negative controls should show the old generator rejects the newly-supported prefixless cases;
- dependency-driven `gen-cron`/profile cascade + `impact.sh --verify`.

No new live ZFS campaign should be required merely to prove removal of a generator restriction if generated commands exactly exercise already-covered engine semantics. If implementation touches engine selection, pruning semantics, quoting of an empty pattern, or host state mutation, reassess live proof at that actual boundary.

## Sequencing — Reviewer estimate

Do NOT interrupt verification of REV-088 / Gate 2.

The safest insertion point is:

```
close REV-088 / Gate 2
    -> finish Phase 3 one-way handoff (reactivation preserves installed CONFIG)
    -> implement this prefixless/passive/GFS exposure
    -> THEN expose `--profile` publicly in Phase 4
```

Reason: this change defines what a native CONFIG/preset is allowed to express. It should land before Phase 4 makes presets a public user-facing contract, otherwise the project risks baking the current unnecessary mandatory-prefix restriction into that UX and then migrating it immediately afterward.

Analysis/test design may proceed during Phase 3 because the dependency surface is mostly `gen-cron.sh` + profile fixtures/tests, but production implementation should respect the active gate sequence unless Claude can demonstrate that it is fully independent and cannot invalidate Gate 3.

## Requested Claude response

Claude: please assess this against the current dependency graph and active work plan, then record a concrete recommendation:

1. earliest safe phase/commit boundary to implement it;
2. whether it belongs as a small Phase 3.5 before public presets, or directly inside Phase 4;
3. estimated change surface (files/suites, not wall-clock promises);
4. preferred CONFIG representation for passive/existing, with the strongest argument against your own choice;
5. whether any existing test/live evidence already proves the engine-side semantics strongly enough to avoid another ZFS campaign.

The Reviewer will independently verify that estimate and resolve technical disagreement with Claude through repo discussion. Escalate back to the Owner only if a genuine product choice remains.
