# REV-20260731-007 — helper quiesce is a good privilege boundary, but REV-006 safety blockers remain

- Reviewer: ChatGPT
- Date: 2026-07-31
- Scope: `1ed60d7`, `a59c4cc`, current `lib-zfs-snap.sh`
- Result: **PRIVILEGE DESIGN ACCEPTED; REMOTE QUIESCE STILL CHANGES REQUIRED**

## 1. What is good and accepted

The new `zfs-quiesce-helper` is the right direction for delegated pull accounts:

- it avoids granting `sudo qm`/`sudo pct` or root SSH;
- the helper exposes only `status`, `freeze`, `thaw`, and `writers`;
- scope is derived from the delegated dataset whitelist rather than a static guest-id list;
- `--allow-quiesce` is a local source-host decision and is off by default;
- sudo is invoked with `-n`, so missing privilege fails immediately;
- the deadman now uses the same helper path as the freeze path;
- malformed IDs, unsupported verbs, out-of-scope guests, missing whitelist, and command failures have dedicated refusal tests.

This materially improves least privilege and operator safety.

## 2. REV-006 blockers are still present in current code

The two new commits route operations through the helper, but they do not close the three safety findings already recorded in `REV-20260730-006-REMOTE-QUIESCE-SAFETY.md`.

### F1 — freeze failure still does not abort the snapshot

`freeze_one()` prints `QERR` and returns success when:

- a VM was already frozen;
- `fsfreeze-freeze` fails;
- container `sync` fails;
- mode and guest kind are incompatible.

The caller then continues to `zfs snapshot`.

Therefore a run requested with `-q` can still produce a crash-consistent snapshot and exit successfully after a failed quiesce. That violates the explicit fail-closed contract.

Required behavior:

- any requested guest that is running and cannot be quiesced must set a failure flag or return non-zero;
- no snapshot may start if any required freeze/flush failed;
- already-frozen must be a blocking condition, unless there is an explicit, separately designed ownership/recovery procedure;
- the final process exit must clearly distinguish quiesce failure from snapshot failure.

A minimal pattern is:

```bash
freeze_failed=0
for ds in "${scopes[@]}"; do
    freeze_one "$ds" || freeze_failed=1
done
[ "$freeze_failed" -eq 0 ] || exit 5
```

The exact code is not prescribed, but the gate is mandatory.

### F2 — missing `setsid` still degrades to an unsafe warning

Current behavior remains:

```text
QLOG setsid unavailable -- running without the deadman safety net
```

The deadman is not an optional enhancement. It is the only protection against a frozen production guest after loss of the controlling SSH/session/process.

Required behavior:

- test for `setsid` before any freeze;
- if unavailable, exit non-zero and freeze nothing;
- add a regression test proving no `freeze` helper call occurs when `setsid` is absent.

### F3 — failed thaw still clears the recovery list

`thaw_all()` still truncates `frozen_file` unconditionally after attempting thaw. If one thaw fails:

1. the guest can remain frozen;
2. its ID is removed from the file;
3. the detached deadman later sees no IDs and cannot retry.

This disables the second safety mechanism exactly when it is needed most.

Required behavior:

- remove an ID only after confirmed successful thaw;
- retain failed IDs atomically in `frozen_file` for the deadman;
- return non-zero if any thaw fails;
- the EXIT trap must not delete the state file while failed IDs remain;
- deadman logging must distinguish successful thaw from failed thaw attempts; it must not always claim `thawed guest(s)`.

Suggested data flow:

```text
frozen_file -> thaw attempts -> retry_file with only failed IDs
success for all: remove state file and stop deadman
any failure: atomically replace frozen_file with retry_file and leave deadman armed
```

## 3. New helper-specific verification still required

Before enabling `-q` in `zfs-backup.sh`'s standard profile, complete the existing live obligation on a real source host using a delegated account:

1. verify `sudo -n` strips `ZFS_QUIESCE_ALLOW_DIR` and other test overrides;
2. verify the installed sudoers rule reaches only `/usr/local/sbin/zfs-quiesce-helper`;
3. verify an out-of-scope real guest is refused;
4. verify a real freeze and normal thaw through the helper;
5. kill the controlling run and verify deadman thaw through the helper;
6. force the first thaw attempt to fail and prove the deadman still retains the guest ID and retries;
7. remove or revoke the pairing and verify helper, whitelist, and sudoers artifacts are cleaned up or explicitly documented as retained shared state.

The final point is important operationally: an admin should not have to know that a removed backup relationship may leave privileged artifacts behind.

## 4. UX assessment

The helper itself is appropriately hidden backend machinery. However, the current remediation text still tells the source-side operator to run backend syntax:

```text
deploy.sh --join <package> --allow-quiesce
```

For the simple deploy path, expose this through the planned peer-side `zfs-backup enroll` command or equivalent. The administrator should choose a clear policy such as `--application-consistent`, while the wrapper handles `--allow-quiesce`, helper installation, and validation internally.

## 5. Decision

- Narrow delegated privilege helper: **accepted**.
- Helper routing in `snapget`: **accepted as plumbing**.
- Remote quiesce safety as a whole: **not accepted**.
- Do not add `-q` to the production `standard` profile until F1, F2, F3 and the delegated live tests are closed.
