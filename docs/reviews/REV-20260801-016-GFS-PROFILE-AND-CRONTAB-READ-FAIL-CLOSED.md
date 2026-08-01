# REV-20260801-016 — GFS profile simplicity and live-crontab read failure

Status: **CHANGES REQUIRED**

Reviewed commits:

- `ff754baf681d77c67210b603bc7e8c50adc6f2bb`
- `c5ac7e873668ecb34a819cb904c8be36408a52c4`

## Accepted

REV-015 is correctly addressed in the normal case: the activation preview now compares the proposal with the actually installed managed cron block, so drift is visible.

The direction of one recursive GFS retention policy per client and a per-client bandwidth cap is also correct for the appliance UX.

## F1 — inability to read the live crontab is still treated as an empty crontab

`show_activation_proposal()` currently runs:

```bash
crontab -l 2>/dev/null | sed ... > "$before"
```

Any failure of `crontab -l` is therefore presented as “no managed block installed”. The response calls this only a noisy preview, but the operator is being asked to approve an *exact live change*. Permission errors, a broken spool, a failing `crontab` binary or another read failure are not evidence that the crontab is empty.

Required behaviour: distinguish the normal “no crontab for this user” condition from every other failure. If the live crontab cannot be read reliably, abort before the confirmation prompt and do not install anything. Add a regression test where the crontab stub exits non-zero for a real error.

## F2 — the new GFS profile still schedules four send families although the ladder intentionally ignores those families

The retention command matches all snapshots with:

```text
automated_
```

and `delsnaps.sh -G` buckets them solely by creation time. It does not preserve one hourly-prefix set, one daily-prefix set, etc. Therefore the separate `standard_daily`, `standard_weekly` and `standard_monthly` send jobs no longer define retention tiers; they only create additional snapshots/transfers.

At schedule boundaries this also creates avoidable concurrency: daily, weekly and monthly jobs can start at the same minute against the same source/target, while the hourly job follows one minute later. Depending on locking, this is either redundant work or recurring failed/skipped jobs and noisy alerts.

For the simplified default, please decide explicitly between:

1. **True GFS:** one regular send cadence (normally hourly) with one client-level `-G -H24 -D7 -W4 -M12` prune; or
2. **Named independent tiers:** four send prefixes with four independent flat retention rules, i.e. the legacy model.

Combining four named send cadences with one time-bucket ladder gives the administrator the complexity and collision surface of both models without a retention benefit. My recommendation is option 1 for a fresh simplified deployment.

Required tests for option 1:

- generated cron has one send job per dataset and one recursive GFS prune per client;
- no same-dataset send jobs share a minute;
- the activation preview clearly shows migration from the four-send profile;
- existing pre-GFS installations remain unchanged until an explicit migration action is approved.

## F3 — legacy migration still leaks internal template knowledge to the administrator

Keeping an old profile unchanged is safe, but the current message says migration is a “deliberate edit”. The target administrator should not edit `standard_*` / `keep_*` sections or understand the internal split.

Please expose a high-level migration action (or make `activate-client` propose the complete migration in its diff) with one decision such as:

```text
Migrate this client from legacy flat retention to the standard GFS policy? [t/N]
```

The tool should generate and validate the configuration itself, show the exact config/cron diff, and fail closed. Manual template surgery is outside the agreed simplified-deploy UX.
