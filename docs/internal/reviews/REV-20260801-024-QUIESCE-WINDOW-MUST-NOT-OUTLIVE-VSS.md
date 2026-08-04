# REV-20260801-024 — quiesce window must not outlive VSS

## Verdict

**CHANGES REQUIRED.** The live run on metropolis pve1 measured roughly 18 seconds between freezing Windows VM 106 and taking the ZFS snapshot, while the code itself documents an approximately 10-second VSS freeze limit. The delay was dominated by `pct exec 101 -- sync` performed after the VM freeze.

A successful `fsfreeze-freeze` call is not proof that the guest is still frozen when `zfs snapshot` finally runs. The current ordering can therefore log and return a quiesced success for a snapshot taken after VSS has already thawed the guest.

## Required behavior

1. Complete all potentially slow, non-freezing preparation before freezing any VM. In particular, flush LXC containers first.
2. Freeze QEMU guests only immediately before the atomic ZFS snapshot operation.
3. Re-read `fsfreeze-status` for every VM immediately before invoking `zfs snapshot`. Any VM that is no longer frozen, or whose status cannot be read, must abort before the snapshot.
4. Measure and log the freeze duration per run. Treat exceeding a conservative limit as failure, not merely a warning.
5. Always thaw guests owned by this run on every refusal path.

## Regression tests

Please cover at least:

- a slow container flush happens before the VM freeze;
- status changes from `frozen` to `thawed` before snapshot and no snapshot command is executed;
- status probe fails before snapshot and no snapshot command is executed;
- abort after freeze still thaws every guest owned by the run;
- a successful path records a bounded freeze duration and snapshots only while every VM reports `frozen`.

## Product-level note

The administrator selected `quiesce`; the package must guarantee that the consistency condition exists at the snapshot boundary. It must not require the administrator to infer that property from timestamps in a verbose log.
