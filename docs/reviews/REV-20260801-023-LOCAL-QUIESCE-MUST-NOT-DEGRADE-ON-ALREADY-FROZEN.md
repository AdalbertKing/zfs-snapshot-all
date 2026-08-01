# REV-20260801-023 — local quiesce still degrades on an already-frozen guest

## Verdict

**CHANGES REQUIRED** for the local `-q` path. The new direct/helper routing and the distinction between `not running` and `could not determine` are accepted. The live discovery on pve1 was important and the fix closes that specific silent-degradation path.

## Remaining fail-closed regression

In `quiesce_freeze()`, a running QEMU guest reported as already frozen still does this:

```bash
[ "$frozen" = yes ] && {
    log 0 "... ALREADY frozen before this run -- leaving it alone ..."
    return 0
}
```

The caller then continues to create the snapshot and can complete the backup successfully.

That contradicts the safety rule already established for remote quiesce: when `-q` is requested, an already-frozen guest is not a successful quiesce of this run. The process does not own that freeze, cannot prove its application boundary, and deliberately will not thaw it. Treating it as success can again produce a backup whose consistency is weaker or simply unknown while the job exits 0.

## Required behaviour

For a running QEMU guest and requested quiesce:

- `frozen=no` → freeze, snapshot, thaw;
- `frozen=unknown` → fail before snapshot;
- `frozen=yes` before this run → fail before snapshot with a clear recovery instruction;
- freeze failure → fail before snapshot;
- thaw failure → fail and preserve/retry recovery state.

Do not silently reinterpret `-q` as “best effort”. If a best-effort policy is wanted later, it must be a separately named profile/mode and must not claim application consistency.

## Regression test

Add a local delegated-account test where helper `status` returns:

```text
id=106 kind=qemu running=yes frozen=yes
```

Assert all of the following:

1. no ZFS snapshot command is executed;
2. no send starts;
3. exit status is non-zero;
4. the message says the guest was already frozen before this run and that the backup was refused;
5. no thaw is attempted because this run did not acquire the freeze.

Please also reconcile the nearby comment saying that an “unreachable agent” is a reason to take an ordinary snapshot. For a running QEMU guest under explicit `-q`, agent unavailability must be a refusal, not a downgrade. If that comment is stale, remove it; if the code still follows it in any branch, fix that branch and test it.

## Product implication

This matters especially after `migrate-to-account`: the administrator accepted a configuration containing quiesce and should never need to inspect logs to discover that the job quietly changed consistency class. The status/alert contract must be binary and machine-readable: quiesce succeeded for this run, or the backup failed.
