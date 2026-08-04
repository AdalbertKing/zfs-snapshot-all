# REV-20260731-009 — catch-up freshness accepted; quiesce grant update rollback incomplete

- Reviewer: ChatGPT
- Date: 2026-07-31
- Scope: `54c1ead`, `763767b`, response `docs/internal/reviews/responses/REV-20260731-008.md`
- Result: **CATCH-UP FIX ACCEPTED; GRANT TRANSACTION STILL CHANGES REQUIRED**

## 1. Accepted

I accept the final-catchup changes:

- endpoint name, host, port and epoch are recorded;
- stale or identity-mismatched records fail closed;
- missing legacy epoch is refused rather than grandfathered;
- moving an endpoint invalidates the prior proof;
- the 30-minute default is explicit and `--allow-stale-catchup` overrides age only, with a warning.

This closes REV-008 F1 and is appropriate for the LAN→VPN relocation workflow.

I also accept `54c1ead`: the live-host discovery that a bare `return` inside the EXIT-trap path could convert a failed thaw into success was critical. Explicitly returning the helper status and pinning the embedded script against bare `return` closes the observed PVE 7/Bash 5.1 failure mode. The fact that the local Bash 5.3 behavioural test could not reproduce it is documented honestly.

## 2. Remaining defect: rollback protects creation, not update

`install_quiesce_grant()` now rolls back files that **did not exist before the run**, using `created_helper`, `created_allow` and `created_rule`.

It does not restore existing artifacts that the run overwrites.

Example:

1. account already has a valid whitelist and sudoers rule;
2. `--join --allow-quiesce` is rerun with a changed dataset list or newer helper;
3. the helper and whitelist are overwritten successfully;
4. installation of the sudoers rule then fails;
5. `_grant_rollback()` sees `created_helper=0`, `created_allow=0`, `created_rule=0` and restores nothing.

The host is left with a mixture of old and new grant state. This contradicts the stated two-end-state guarantee: "fully installed, or nothing new".

The same issue applies to an existing shared helper: it is overwritten before the transaction commits, but no previous copy is retained for rollback.

## 3. Required correction

Before the install phase, preserve every existing destination that may be replaced:

- `/usr/local/sbin/zfs-quiesce-helper`;
- `/etc/zfs-quiesce-allow/$account`;
- `/etc/sudoers.d/zfs-quiesce-$account`.

On any failure after the first replacement:

- restore pre-existing files byte-for-byte with their owner/mode;
- remove only destinations that were absent before the run;
- validate the restored sudoers state;
- report whether the operation restored an old grant or removed a newly created one.

An alternative, cleaner implementation is to stage all three files beside their final destinations and commit them with an ordered rename plus rollback copies. The shared helper still needs version/update handling independent of the per-account grant.

## 4. Tests required

Add fault-injection cases for an **existing valid grant**, not only a clean host:

1. existing helper + whitelist + rule; fail installing the new whitelist — all three old files unchanged;
2. fail installing the new rule after helper and whitelist replacement — all old files restored;
3. successful update changes exactly the intended files;
4. rerun with identical content is an idempotent no-op or produces an explicitly bounded replacement;
5. after rollback, `visudo -cf` succeeds for the restored rule.

Hashing the three files before and after each injected failure is sufficient evidence.

## 5. UX note

Installing the `sudo` package is a host-level side effect that is not rolled back when later grant setup fails. I do not require package removal — automatic package rollback is riskier than leaving a standard dependency installed — but the failure message should say clearly:

> Grant was not created. The `sudo` package was installed and left in place.

That keeps the outcome understandable for an administrator who did not inspect the implementation.

## Decision

- REV-008 F1 catch-up freshness: **closed**.
- Bash 5.1 trap/thaw regression: **closed, with valuable live evidence**.
- REV-008 F2 transactional grant installation: **not yet closed for update/re-enroll paths**.
- Do not enable application-consistent mode as a default until update rollback is proven on an existing grant.
