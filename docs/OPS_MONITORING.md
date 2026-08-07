# Daily automated infrastructure monitoring

Scope, auto-fix whitelist, and escalation rules for the unattended daily check
across the four live hosts. This document is the standing authorization for
what the daily routine may do without asking the owner first; anything not
listed here is a report, never an action.

## Hosts checked

- `pve0` — 192.168.11.10 ([[infra-pve-cluster]] equivalent: `docs` has no local mirror of memory, see repo history for context)
- `pve1` — 192.168.11.11 (11.x cluster)
- `pve1` — 192.168.28.9 (metropolis cluster)
- `pve2` — 192.168.28.8 (metropolis cluster)

Reachable via `plink.exe` through Pageant (key already loaded in the
owner's Windows session); no per-run passphrase needed.

## What is checked, per host

- `crontab -l` against the expected `gen-cron.sh`-managed block (where managed)
- `cron.log` tail (last 24h) for failed sends/prunes
- `check-pool-capacity.sh` output / recent alert mail (host-local, not
  git-tracked, deployed on metropolis pve1/pve2)
- `zpool status` (DEGRADED/FAULTED/UNAVAIL members, scrub errors)
- `pvesr status` / `/etc/pve/replication.cfg` (FailCount, LastSync lag vs
  configured cadence)
- local mail queue (`mailq`) for stuck alert delivery
- ZED events from the last 24h
- stuck `receive_resume_token` / in-progress resumable receives

## Auto-fix whitelist — no confirmation needed

Only these actions, and nothing else, may be performed automatically:

1. Hung/stale monitoring script process — kill and rerun. The check itself
   is read-only, so rerunning it changes nothing but staleness.
2. Stuck local mail queue — flush (`postfix flush`). Never edit or drop a
   queued message's content.
3. A failed *non-destructive* check script, where the failure looks like a
   transient SSH/network blip — rerun the same check once. No state change.
4. A stale `/var/run/*.lock` file confirmed to have no live owning process
   (same pattern as the documented 2026-07-10 incident cleanup) — remove it
   so the next cron fire isn't skipped.

Everything else is a report, never an automatic fix — including but not
limited to: pool capacity above the 90% threshold, pool DEGRADED/FAULTED,
`pvesr` FailCount > 0 or sync lag beyond the job's cadence, an unreachable
host, any stuck resume/receive token, any `zfs destroy`/hold/prune decision,
and any crontab content drift from the expected managed block.

## Software bug found in zfs-snapshot-all itself

1. Open a GitHub issue on `AdalbertKing/zfs-snapshot-all` describing the
   failure: root cause, evidence, affected host/job.
2. If the fix is unambiguous and can ship with a new regression test that
   fails on the current `main` and passes after the fix: implement it, run
   `./test/impact.sh` plus every required suite, update
   `docs/PROJECT_STATUS.md`, and commit directly to `main` under the active
   direct-main exception (`docs/AI_PROJECT_RULES.md`), referencing the issue
   number in the commit message. Record the delivery evidence in
   `docs/reviews/responses/OPS-YYYYMMDD-NNN.md`, following the same
   required-evidence shape as a reviewer-originated response (this one
   originates from monitoring instead of a reviewer finding, hence the
   `OPS-` prefix rather than `REV-`).
3. If the fix is ambiguous, needs an operational risk decision, or a
   required suite can't run in this environment — do not commit. Report to
   the owner instead, with the same root-cause writeup.
4. Never mark anything `CLOSED`; that stays the reviewer's call, same as
   every other delivery in this repo.

## Daily report

One summary email every run, regardless of findings: what's healthy, what
was auto-fixed (from the whitelist above), what's waiting on an owner
decision, and any GitHub issue or commit created.
