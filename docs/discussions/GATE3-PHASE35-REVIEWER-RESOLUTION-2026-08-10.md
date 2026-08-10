# Reviewer resolution — Gate 3 closure and Phase 3.5 schema boundary

Date: 2026-08-10
Reviewed planning commit: `ea5971ad86ec3de29c5ab23f2edadc5b24a240d6`

## 1. Gate 3 — CLOSED

Gate 3 is closed.

The required Phase 3 property is:

```text
PROFILE/PRESET -> generate once -> CONFIG v4 -> runtime truth

ordinary endpoint / host / transport maintenance
        -> preserve installed CONFIG policy
        -> change only topology-owned facts
```

REV-20260809-089, REV-20260810-090 and REV-20260810-091 are all CLOSED and together cover the full property rather than only one implementation detail:

- REV-089 stopped reactivation from regenerating relationship-local section bodies from the current profile;
- REV-090 removed the remaining runtime dependency on the CREATE-time profile and stopped re-adding profile templates during ordinary reactivation;
- REV-091 stopped ordinary reactivation from repairing CONFIG-wide `[excluded:]` policy or forcing pre-GFS migration.

No remaining Phase 3 acceptance property is visible in the current code or review artifacts. REV-092 was a separate Phase 2/additive-CREATE defect and does not reopen Phase 3.

**Gate 3 acceptance property is proved. Phase 3 is CLOSED and Phase 3.5 may begin.**

## 2. Phase 3.5 — omitted versus blank

Claude's proposed resolution is ACCEPTED, with the boundary stated precisely.

For the two fields being relaxed in this phase — `prefix` and `gfs_pattern` — the generator must preserve three distinct states:

1. field resolves to a non-empty value -> use that value exactly as today;
2. field is **unresolved across its complete inheritance chain** -> deliberate no-prefix/no-pattern case, accepted;
3. field resolves because a key is present, but the resolved value is blank -> REFUSE exactly as today.

For `prefix`, "complete inheritance chain" means dataset -> template -> defaults. Omitting `prefix` at the dataset layer does NOT mean no prefix if a template/default still supplies one.

For `gfs_pattern`, the same rule applies to the section/default resolution chain used by `gen-cron.sh`.

This is the smallest rule that exposes the engine capability without reopening the historical `c90f6d1` accident class. `test/negative/blank-prefix.conf` must remain a valid negative control unchanged.

Do not implement this as a naïve `require_field -> resolve_field` replacement that accepts both absent and blank. Use the already-existing `resolve_field()` return-code distinction (or an equally small wrapper around it): unresolved is intentional absence; resolved-empty is malformed input.

The ordinary non-GFS `pattern` contract is NOT relaxed by this decision. Phase 3.5 is not permission to generalize every pattern field to empty.

## 3. Passive/existing representation

Keep passive/existing as the already-existing native CONFIG representation:

```text
flags = -e
```

Do NOT add a second persistent `snapshot_mode = create|existing` field in Phase 3.5. Two CONFIG representations for the same engine policy would create a precedence/consistency problem for no runtime benefit.

Phase 4's operator-facing preview must nevertheless present the semantic meaning clearly, e.g. "use newest existing snapshot" rather than requiring the administrator to understand `-e`. That is presentation derived from CONFIG, not a second execution-truth field.

## 4. Prefixless GFS command boundary

For `gfs=yes` with unresolved `gfs_pattern`, the generated command must pass an intentional empty positional pattern to `delsnaps.sh`, preserving argument boundaries, e.g. the semantic equivalent of:

```text
delsnaps.sh ... "" -G -H24 -D7 -W4 -M12
```

Do not silently invent a generated prefix and do not reinterpret empty-pattern GFS as "no pruning". It means all otherwise-eligible snapshot names on the declared scope, subject to the existing protected-prefix and in-flight protections.

Existing same-scope overlap/refusal logic must remain active. A broad prefixless GFS rule is allowed by design, but it must not silently coexist with another conflicting prune rule on the same scope if the existing overlap guard says they race.

## 5. Evidence boundary for Gate 3.5

Required proof:

- all four create/existing x prefix/no-prefix combinations at the generated-command boundary;
- present-but-blank `prefix` still refuses;
- present-but-blank `gfs_pattern` still refuses;
- unresolved `prefix` emits a valid transfer/create/passive command with no effective `-m` filter;
- unresolved `gfs_pattern` emits the intentional empty positional GFS pattern;
- current non-empty-prefix behavior remains byte/semantically unchanged;
- negative control against the pre-Phase-3.5 generator rejects the newly-supported unresolved cases;
- add the missing direct engine test for bare passive (`-e` with no `-m`) in the existing snapsend/snapget harness;
- dependency-selected cascade and `./test/impact.sh --verify`.

No frozen engine change is authorized by this decision. No new live host/ZFS campaign is required if implementation remains generator/config/test-only and the generated commands exercise already-existing engine semantics. Reassess only if engine logic, pruning semantics, empty-pattern quoting, or host-state mutation changes.

## 6. Next action

Claude may now:

1. record Phase 3 / Gate 3 as CLOSED in `ACTIVE-WORK-PLAN.md`;
2. implement Phase 3.5 under the rules above;
3. submit the exact implementation SHA and evidence for independent review before Phase 4 starts.

No Owner decision is required for the omitted-vs-blank question or for the passive CONFIG spelling; both are resolved here as technical representation choices under the Owner's already-recorded required outcome.
