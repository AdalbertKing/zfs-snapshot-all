# REV-20260807-061 — Stage 0 follow-up: delegated install lock and status recurrence

**Reviewed head:** `123fca80c452aa6fa47fdcfe0f4a971680004d33`

**Review time:** 2026-08-07 17:00 CEST

**Verdict:** **CHANGES REQUIRED**

This review was started from a fresh read of `main`. The newest commit event at review start was `123fca80c452aa6fa47fdcfe0f4a971680004d33`, committed **2026-08-07 16:58:58 CEST**.

REV-060's seven plan amendments are accepted by the implementer and Stage 0 has been executed on pve0. I do not treat the commit message's live-host assertions as independent proof by themselves; the next fleet/live campaign must still be able to reproduce the claimed grants, installed block and monitor state. Two issues are independently verifiable in the repository now.

## F1 / P1 — `gen-cron.sh --install` defaults to a lock path the delegated owner cannot create

### Evidence

`gen-cron.sh` currently defines:

```bash
LOCKFILE="${GEN_CRON_LOCKFILE:-/var/run/gen-cron.install.lock}"
```

and `install_crontab()` immediately does:

```bash
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    die "another gen-cron.sh --install is already running (lock: $LOCKFILE) -- retry once it finishes"
fi
```

The product deliberately supports managed crontabs owned by a delegated account. On the real Stage 0 run, that account could not create/open `/var/run/gen-cron.install.lock`; the run succeeded only after overriding `GEN_CRON_LOCKFILE` to the project's already-managed writable lock directory under `/var/lib/zfs-snapshot-all/locks`.

This is therefore not an operator-environment oddity. The default CLI path is incompatible with a supported deployment identity. The error path also conflates two different failures: inability to open/create the lock and an actually-contended lock.

### Required outcome

1. The default install lock must live in a location deliberately provisioned for the invoking identity used by supported deployments, or be selected by an identity-aware helper with the same property.
2. A failure to open/create the lock must be reported as that failure, including the path and the underlying reason; it must not claim another install is running.
3. Real lock contention must remain fail-closed and continue to refuse concurrent writers.
4. `GEN_CRON_LOCKFILE` may remain as a test/operator override, but normal delegated operation must not depend on knowing or setting it.

### Acceptance evidence

- deterministic tests for: delegated/default path writable; open/create failure; real contention; override still works;
- negative control against the current implementation showing at least the delegated/default-path case fails there;
- one live `gen-cron.sh --install` as the delegated account **without** `GEN_CRON_LOCKFILE`, on a non-destructive/controlled block or with byte-identical render/install proof.

Do not solve this by making the delegated account broadly writable to `/var/run`.

## F2 / P2 — `PROJECT_STATUS.md` became stale again immediately after REV-059

REV-059 was closed because `PROJECT_STATUS.md` had been refreshed and its leading current-state block was again truthful. At current `main`, that block still says:

- `Data odświeżenia: 2026-08-07 16:10`, commit `3e911ee`;
- VM 104 on pve0 without a copy is still an open owner item.

But Stage 0 is now recorded as completed: `123fca8` says VM 104 and the other uncovered guest storage are under backup, grants were issued, the managed block was installed and monitors return rc=0. The same commit updates `OPEN-THREADS.md` to mark Stage 0 done.

So the live status document again contradicts the repository's newer declared production state less than an hour after REV-059 closure.

### Required outcome

1. Refresh the leading current-state section to the post-Stage-0 state and remove VM 104 from the open-gap summary.
2. Do not merely patch prose. Stage 1's already-approved machine-readable freshness mechanism (REV-060 A2) is now elevated from planned hygiene to the required prevention for recurrence. Implement it before another behavior/deployment stage is declared complete.
3. The freshness check must fail on this exact class: a later stage/production-state commit with an unchanged behavior/status marker.

### Acceptance evidence

- updated truthful `PROJECT_STATUS.md`;
- machine-readable marker and test proving prose changes cannot disable the check;
- negative control demonstrating the pre-fix tree accepts a stale status that the new check rejects.

## Stage 0 storage discovery correction

The correction in `123fca8` is important and accepted as a design input: `vm-107-disk-0` and `vm-107-disk-2` are not orphans but `efidisk0` and `tpmstate0`. Stage 4 reconciliation and restore completeness must therefore enumerate **all storage-bearing guest configuration keys**, not only `scsi|virtio|sata|ide`. No destructive action against those datasets is approved by this review.

## REV-060 state

The implementer's response accepts A1–A7 without technical conflict. That is sufficient to close the plan-response loop; **REV-060 is CLOSED as a design review**. Its Stage 2 gate remains unchanged: parser/snapshot contracts and tests must be presented before Stage 2 implementation.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-061.md`

Production code may be changed only to address F1/F2 through the normal reviewed implementation flow. This review itself changes documentation only.
