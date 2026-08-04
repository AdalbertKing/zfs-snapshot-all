# REV-20260803-035 — cron lock path must be global per target user

**Verdict:** CHANGES REQUIRED

## What is accepted

REV-034 F1/F3/F4 are correctly addressed in the normal workflow:

- shared host-block contributors merge rather than replace one another;
- marker layout is validated globally before mutation;
- `migrate-to-account` uses the shared writer, including rollback;
- the bare-`exec` stderr redirection defect was correctly found and fixed;
- read-back verification and explicit rollback reporting are the right contract.

The direction of one writer with named ownership boundaries is accepted.

## Blocking finding — the per-user lock is not globally the same lock

`CRON_LOCK_DIR` is selected when `lib-cron.sh` is sourced:

```bash
CRON_LOCK_DIR="${CRON_LOCK_DIR:-/run}"
[ -d "$CRON_LOCK_DIR" ] && [ -w "$CRON_LOCK_DIR" ] || CRON_LOCK_DIR="${TMPDIR:-/tmp}"
```

The lock key is then:

```bash
$CRON_LOCK_DIR/lib-cron.<target-user>.lock
```

This makes the lock path depend on the **effective user of the process**, not only on the target crontab owner.

Typical production shape:

```text
root process modifying zfsbackup's crontab
    -> /run/lib-cron.zfsbackup.lock

`gen-cron.sh` running as zfsbackup modifying its own crontab
    -> /tmp/lib-cron.zfsbackup.lock
```

A delegated account normally cannot create files directly under `/run`, so its library instance falls back to `/tmp`. Root does not. The two processes therefore acquire different locks while performing read-modify-write against the same `zfsbackup` crontab.

This reopens exactly REV-034 F2:

1. root reads the account crontab under the `/run` lock;
2. the account reads it under the `/tmp` lock;
3. both render from the same old state;
4. both writes pass their own read-back;
5. the later writer silently removes the earlier writer's update.

The current contention test can pass while missing this production split if both test processes source the library under the same effective user and therefore choose the same directory.

## Required contract

For a given target user, every process on the host must resolve exactly the same lock object regardless of whether the caller is root or that delegated account.

Prefer one fixed root-owned lock directory created by deploy, for example:

```text
/run/lock/zfs-snapshot-all/
```

with permissions that let approved callers open the per-user lock without allowing arbitrary replacement or symlink tricks. Another acceptable model is a small privileged lock helper. A caller-local fallback chosen independently is not acceptable.

If the canonical lock directory is unavailable, a mutating operation should fail closed. It should not silently switch to a different namespace that another writer may not share.

## Required tests

Add a cross-identity test that models the real topology:

1. root-side writer targets account `zfsbackup`;
2. account-side writer targets its own `zfsbackup` crontab;
3. each process starts with its natural permissions and environment;
4. process A is held between read and write;
5. process B must contend on the **same inode/lock**, not enter its mutation;
6. after release, both changes survive.

Also assert directly that both identities resolve the same canonical lock path for the same target user.

## UX note

The operator must never need to configure `CRON_LOCK_DIR`. This is internal safety infrastructure and should have one package-managed location with a clear fatal diagnostic when unavailable.

## Scope-file/enrolment assessment

`lib-scope.sh` is a sensible first implementation slice: component-wise dataset matching, explicit parent/children decisions and line-numbered refusals are aligned with the simplified deploy goal. It is not yet wired to grants, job generation or pairing, so it should be described as infrastructure, not a completed enrolment workflow.
