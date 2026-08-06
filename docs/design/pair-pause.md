# Pair Pause — Functional Design

Status: logical pause implemented by REV-045; hard disable not yet implemented.

## User-visible states

- `ACTIVE`
- `PAUSED`
- `DISABLED`

Status output must distinguish them explicitly and must not present `PAUSED` as a failed backup.

## Logical pause CLI

```text
zfs-backup.sh pause-client LABEL
zfs-backup.sh resume-client LABEL
zfs-backup.sh status LABEL
```

Contract:
- state is durable across restart;
- cron/config are unchanged;
- managed snapget/snapsend commands include the durable relationship label;
- paused runs exit `0` with a stable `skipped_paused` result;
- the gate runs before snapshots, holds, SSH, or transfer;
- one relationship does not affect another;
- an already running transfer is not killed; the next run is skipped;
- monitoring reports an intentional pause, not staleness/failure.

A manual invocation without the relationship label can bypass logical pause. This is intentional and must be documented.

## Hard-disable CLI (future)

Proposed commands:

```text
zfs-backup.sh disable-client LABEL
zfs-backup.sh enable-client LABEL
zfs-backup.sh status LABEL
```

Contract:
- `disable-client` first establishes local pause, then activates the peer-side gate;
- success is reported only after peer-side read-back verification;
- `enable-client` verifies peer-side enablement before removing local pause;
- retries converge after partial failure;
- no cron regeneration, re-seed, key rotation, account recreation, or ZFS re-delegation is required;
- manual transfer attempts using the relationship key are refused even without local `-L`;
- other relationships remain active;
- LAN/VPN endpoint changes and key rotation cannot silently clear disabled state.

## Diagnostics

Logical pause:

```text
SKIPPED: relationship LABEL is paused
status=skipped_paused
```

Hard disable:

```text
PAIR_DISABLED: relationship LABEL is disabled by administrator
```

The hard-disable exit code must be stable and documented. Authentication failure, unknown relationship, malformed command, and disabled relationship must remain distinguishable.

## Lifecycle interactions

- `activate-client`: must not silently clear pause/disable.
- `set-endpoint`: preserves state.
- key rotation: preserves state and binds the replacement key to the same relationship.
- `remove-client`/`--leave`: teardown remains possible while paused/disabled and removes only that relationship's state.
- host-wide pause remains independent and stronger operationally; status should show both dimensions when both apply.

## Scope boundary

REV-045 closes logical pause only. Hard disable begins as a separate package after ADR review and explicit acceptance criteria.
