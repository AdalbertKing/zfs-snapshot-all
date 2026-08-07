# REV-20260807-062 — lock-file audit must verify group ownership

**Reviewed head:** `a2777af5baf28c65d72f673973c8e535236dc731`

**Review time:** 2026-08-07 18:01 CEST

**Newest commit event at review start:** `a2777af5baf28c65d72f673973c8e535236dc731`, committed **2026-08-07 17:54:07 CEST**.

**Verdict:** **CHANGES REQUIRED**

This review started from a fresh read of `main`, then inspected the REV-061 response, `PROJECT_STATUS.md`, `OPEN-THREADS.md`, the new lock-file repair/audit implementation in `2f69c2d`, the test-harness correction in `d675178`, and the dependency graph in `test/deps.conf`.

## REV-061 status

The repository-side implementation of REV-061 F1/F2 is substantially aligned with the requested design:

- `gen-cron.sh` now uses the shared lock directory rather than `/var/run`, distinguishes open/create failure from real contention, keeps fail-closed contention and retains the override;
- `test/cron` has targeted W1-W5 coverage and a meaningful old-tree negative control after fixing the previously ineffective `GEN=` control;
- the status freshness check is keyed off the explicit machine marker and the marker has already caught a later stale status on its first real opportunity.

That is the right test shape: targeted regression + discriminating control + live-host evidence for the delegated-identity path, not a broad campaign.

However, the new follow-on repair for thread #38 has one independently verifiable hole, so I am not closing the whole lock/deployment thread yet.

## F1 / P1 — `cron_lock_files_audit()` checks mode but not the required group

### Evidence

`deploy.sh` now repairs each existing `*.lock` with:

```bash
chgrp "$grp" "$lk"
chmod 0664 "$lk"
```

but `cron_lock_files_audit()` verifies only the group-write mode bit:

```bash
m="$(stat -c '%a' "$lk" 2>/dev/null)"
g="${m%?}"; g="${g: -1}"
case "$g" in
    2|3|6|7) ;;
    *) bad="$bad $(basename "$lk")($m)" ;;
esac
```

The audit never verifies the file's group ownership against `zfsalert` (or against the group passed to the repair path).

Therefore a file such as:

```text
-rw-rw-r-- root root .../lib-cron.zfsbackup.lock
```

passes `cron_lock_files_audit()` because its group digit is writable, even though the supported delegated account is not made able to open it merely by the `0664` mode. The exact production invariant is **shared group + group-write**, not group-write alone.

The current L tests mirror the same blind spot. They vary modes, and L2 calls repair with `$(id -gn)`, but there is no case proving that a `0664` lock owned by the wrong group is rejected by audit and repaired to the required shared group. This is a graph/test conclusion, not a request for a broad campaign: the suite is attached to `deploy.sh` correctly in `deps.conf`; the missing edge is inside the behavioral contract covered by that suite.

### Required outcome

1. `cron_lock_files_audit()` must validate both properties required for delegated access:
   - the lock file belongs to the expected shared group (`zfsalert` / supplied group), and
   - that group has write permission.
2. The diagnostic must name the offending file and distinguish wrong group from missing group-write when useful to the operator.
3. `cron_lock_files_repair()` remains the root-side repair authority; do not move foreign-file `chgrp/chmod` into unprivileged `lib-cron.sh`.
4. Do not expand this into a fleet-wide campaign. The minimum proof is sufficient.

### Minimal acceptance evidence

- one deterministic test with a lock that is `0664` but intentionally in the wrong group, proving audit refuses it;
- one deterministic repair test proving the same file becomes expected-group + group-writable and audit then passes;
- negative control against `2f69c2d` showing the wrong-group case is incorrectly accepted there;
- one Linux/root-capable targeted check if the local test environment cannot change group ownership. No full suite campaign is required beyond the dependency-driven suites selected for `deploy.sh` plus `impact --verify`.

## Test-harness observation

`d675178` is a good correction: four L assertions used a nonexistent `check()` helper and therefore did not assert what their labels claimed. Defining `check()` as an explicit harness failure is a useful fail-loud guard against recurrence. This reinforces the current review policy: counts and negative controls matter more than the word `PASS`.

## Documentation hygiene

`a2777af` demonstrates that the new status marker is functioning as intended: the prior behavior-changing commit made `--verify` report STALE, and the marker was then advanced. That mechanism is accepted as evidence that REV-061 F2's recurrence prevention is working.

`OPEN-THREADS.md` row 38 should also be cleaned when this finding is addressed: the current row contains the new CLOSED fields followed by the old prose/owner-decision fields on the same Markdown row. This is documentation cleanup, not a separate blocking finding.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-062.md`

Keep the response focused on the invariant and the minimal discriminating tests. Do not spend tokens on an unrelated full campaign.