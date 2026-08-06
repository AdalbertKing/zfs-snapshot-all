# ADR-0012 — Pair Pause Architecture

Status: PROPOSED for hard disable; logical pause implemented by REV-045.

## Context

The project needs per-relationship control independent of host-wide pause. The accepted logical-pause scope must not rewrite cron, remove keys, or revoke ZFS delegation. A later hard-disable must also stop manual transfer attempts that omit local relationship metadata.

## Decision

Three states are defined:

- `ACTIVE`: normal operation.
- `PAUSED`: local orchestration gate. Managed snapget/snapsend invocations carrying the relationship label exit successfully as skipped before lock acquisition, snapshot creation, holds, SSH, or transfer.
- `DISABLED`: peer-side security gate. SSH may authenticate, but the relationship-bound forced command refuses before any ZFS command or other data-plane action.

`PAUSED` and `DISABLED` are distinct. Logical pause is operational control; hard disable is a security boundary.

## Identity

State is bound to the durable relationship label/manifest identity, not hostname, IP address, LAN/VPN endpoint, or transient DNS name. Endpoint changes must not bypass either state.

## Explicit non-solutions

Do not implement pause/disable by:
- rewriting or commenting cron lines;
- deleting or editing relationship keys as a daily switch;
- `zfs allow` / `zfs unallow` cycling;
- account deletion/recreation;
- inferring identity only from address or `HostKeyAlias`.

Those mechanisms belong to activation, enrolment, rotation, or teardown and create unnecessary partial-commit risk.

## Ordering

Hard disable:
1. establish local logical pause;
2. publish peer-side disabled state atomically;
3. read back and verify the exact relationship state;
4. report success.

Enable:
1. remove peer-side disabled state atomically;
2. read back and verify;
3. remove local logical pause;
4. report success.

Any partial failure remains fail-closed and retryable. A running transfer is not killed by default; new operations are refused.

## Forced-command contract

The SSH key/account must resolve to exactly one durable relationship identity. The forced command checks `DISABLED` before parsing or executing the requested ZFS operation. On refusal it logs the attempt, emits a stable machine-readable reason such as `PAIR_DISABLED`, and returns a documented non-zero code.

Other relationships on the same host must continue normally.

## Consequences

- Cron stays byte-identical across pause/disable cycles.
- Existing ZFS grants and key material remain unchanged.
- Manual snapget/snapsend without `-L` is stopped only by `DISABLED`, not by logical `PAUSED`.
- Hard disable is Category D under `docs/project/TEST-CAMPAIGN-POLICY.md` and requires an intermediate live security checkpoint before orchestration is added.
