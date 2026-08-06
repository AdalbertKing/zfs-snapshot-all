# Pair Pause Test Plan

Status: active for logical pause closure; mandatory baseline for future hard disable.

Follow `docs/project/TEST-CAMPAIGN-POLICY.md`.

## A. Logical pause automated tests

1. Create pause marker atomically; repeated pause is idempotent.
2. Resume removes only the named relationship marker; repeated resume is idempotent.
3. Invalid/traversal labels refuse before mutation.
4. Paused snapget with `-L LABEL` exits `0`, records `skipped_paused`, and performs no lock, dependency probe, snapshot, hold, SSH, send, or receive.
5. Same for snapsend.
6. Active relationship follows the unchanged path.
7. Relationship A paused while B remains active.
8. Marker survives process/host restart simulation.
9. Cron and generated config remain byte-identical across pause/resume.
10. Monitoring reports intentional pause without stale/failure alert.
11. Endpoint switch preserves pause identity.
12. Teardown while paused removes only the correct state.
13. Manual invocation with `-L` is blocked; without `-L` is explicitly demonstrated as outside logical-pause enforcement.

Required suites include direct owners plus all `impact.sh` selections, twin CLI coverage, cron/config generation, monitoring, status, and orchestration.

## B. Logical pause live campaign

Use two independent relationships A and B on scratch datasets.

- Record pre-campaign cron/config/state checksums.
- Activate both.
- Pause A.
- Execute the exact generated commands: A skips before source snapshot/SSH; B transfers normally.
- Confirm no source snapshot, hold, session, or target mutation for A.
- Confirm B data integrity.
- Confirm monitoring/status for both.
- Resume A and prove incremental catch-up.
- Confirm cron/config checksums unchanged.
- Restart the relevant service/host or otherwise prove marker persistence.
- Teardown and verify zero relationship-specific residue.

## C. Hard-disable security checkpoint

Treat as Category D. Before adding orchestration, prove the forced-command boundary itself.

1. Active relationship command succeeds.
2. Disabled relationship authenticates but is refused before any ZFS command.
3. Refusal is stable, logged, machine-readable, and non-zero.
4. Manual snapget/snapsend without local label is refused by the peer.
5. Direct/manual use of the same key cannot bypass the gate.
6. Different relationship on the same host remains operational.
7. Unknown/mismatched identity refuses closed.
8. Endpoint change does not bypass disabled state.
9. Key rotation preserves disabled state and does not leave an old bypass key.
10. Malformed/unparseable forced command refuses closed.
11. No cron, `authorized_keys`, account, or ZFS grant mutation occurs during disable/enable.

Run this live on scratch data before implementing higher-level enable/disable workflow.

## D. Hard-disable orchestration tests

1. Disable ordering: local pause -> remote atomic publish -> read-back verification.
2. Enable ordering: remote removal -> read-back verification -> local resume.
3. Failure before remote publish leaves local pause.
4. Publish succeeds but acknowledgment fails: retry converges without duplicate state.
5. Enable remote succeeds but local resume fails: retry converges safely.
6. Concurrent pause/disable/enable operations serialize correctly.
7. Running transfer is not killed by default; next operation is refused.
8. Teardown works while disabled and removes only this relationship's marker/key binding.
9. Host-wide pause and pair state compose predictably.
10. Restart persistence and recovery are verified.

## E. Evidence requirements

For every checkpoint record:
- exact commit;
- hosts and scratch datasets;
- before/after state and checksums;
- exact commands and exit codes;
- proof of absence of forbidden side effects;
- all suite counts, skips, and failures;
- negative-control evidence that the new tests fail against the pre-fix implementation where feasible;
- teardown residue check.
