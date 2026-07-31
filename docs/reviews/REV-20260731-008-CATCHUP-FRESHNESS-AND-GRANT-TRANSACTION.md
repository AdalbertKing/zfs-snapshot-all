# REV-20260731-008 — final catch-up freshness and transactional quiesce grant

- Reviewer: ChatGPT
- Date: 2026-07-31
- Scope: `f466534`, `1d19f0b`, `bc9f2b3`, `2be1ad7`, `3cb5b74`
- Result: **QUIESCE SAFETY FIXES ACCEPTED; TWO CHANGES REQUIRED**

## 1. Accepted

I accept the closure of the three remote-quiesce blockers from REV-006/007:

- any failed preparation now blocks the snapshot;
- missing or dead `setsid`/deadman blocks before the first freeze;
- failed thaw retains the guest id for deadman retry;
- the recovery-list handoff is atomic;
- the no-freeze-without-deadman test now checks the actual call trace;
- per-account quiesce grants can be revoked without removing the shared helper;
- live verification confirmed that sudo strips the whitelist override;
- the Windows VSS freeze window is documented as a hard design constraint.

This is a meaningful safety improvement. Remote quiesce is no longer fail-open in the reviewed paths.

## 2. F1 — final catch-up record can become stale

`set-endpoint` currently accepts a prior catch-up when:

```text
FINAL_CATCHUP_ENDPOINT == ACTIVE_ENDPOINT
```

That proves only the symbolic endpoint name (`lan`/`vpn`), not that the catch-up was performed recently or against the same host and port currently being left.

Examples that currently appear able to pass the gate:

1. run `final-catchup` on Monday;
2. allow production writes for several days;
3. switch to VPN on Friday — the old Monday marker still satisfies the gate;

or:

1. run catch-up against `lan=192.168.11.11`;
2. correct the LAN endpoint to another host/port while remaining on `lan`;
3. later switch to VPN — the old `FINAL_CATCHUP_ENDPOINT=lan` still counts.

This defeats the stated purpose: the last transfer should be immediately before relocation and should prove the exact old transport still works.

### Required change

Record at least:

```text
FINAL_CATCHUP_ENDPOINT=lan
FINAL_CATCHUP_HOST=192.168.11.11
FINAL_CATCHUP_PORT=22
FINAL_CATCHUP_AT=...
```

Before an endpoint switch, require:

- endpoint name matches;
- host and port match the endpoint being left;
- catch-up age is within a short, explicit window.

Recommended default: **30 minutes**. An advanced override may exist, but it must be explicit and warn that writes since the catch-up will cross the slow link.

Any change to the active endpoint host/port should invalidate the previous catch-up marker for that endpoint.

Tests required:

- stale timestamp refuses;
- changed host refuses;
- changed port refuses;
- fresh catch-up against the exact old endpoint passes;
- explicit skip still warns and proceeds.

## 3. F2 — quiesce-grant installation is not transactional

`install_quiesce_grant()` currently installs, in this order:

1. shared helper;
2. per-account whitelist;
3. possibly the `sudo` package;
4. validates and installs the sudoers rule.

If package installation, `visudo`, `mktemp`, or sudoers installation fails, the function returns failure but may leave the helper and whitelist behind. This does not immediately grant access without the sudoers rule, but it leaves a half-installed privileged feature and makes a retry or later diagnosis ambiguous.

For an administrator using the simple path, a failed `--join --allow-quiesce` should end in one of two states only:

- fully installed and verified;
- no new per-account artifacts left behind.

### Required change

Make the per-account grant transactional:

1. resolve/install dependencies first;
2. create helper/whitelist/rule as temporary files;
3. validate the rule;
4. atomically install the complete set;
5. on any failure, remove every newly-created per-account artifact and clearly report what was rolled back.

The shared helper may remain if it existed before. If this run installed it and no account has a valid grant after rollback, either remove it or state explicitly that it remains as an inert shared binary.

Tests required with fault injection after each stage:

- dependency install failure;
- whitelist write/install failure;
- `visudo` failure;
- sudoers install failure;
- retry after each failure succeeds cleanly;
- no orphan per-account whitelist/rule remains after failure.

## 4. UX note still open

`--allow-quiesce`, `--revoke-quiesce`, and peer-side `deploy.sh --join` are still backend-oriented commands. I accept the decision not to add another parallel wrapper entry point now, but this remains part of the unresolved `enroll` workflow: the final simple deploy must expose application consistency as a product-level choice, not require knowledge of backend flags.

## 5. Decision

- Remote-quiesce fail-closed fixes: **accepted**.
- Narrow delegated helper and live trust-boundary verification: **accepted**.
- Mandatory final catch-up concept: **accepted**, implementation **changes required** for exact endpoint identity and freshness.
- Automatic sudo dependency handling: direction **accepted**, grant installation **changes required** to be transactional.
- Do not yet enable application-consistent mode by default in the standard profile until F2 is closed and the full enroll/remove lifecycle hides backend grant commands from the normal administrator path.
