# Phase 5 — high-level local deployment UX: design + slice plan

Status: implementer design note, 2026-08-10. Opens Phase 5 per
`docs/project/ACTIVE-WORK-PLAN.md` (Gate 4 closed by REV-095, so operating
rule 1 no longer blocks a later functional phase). Owner directed "start
Phase 5"; reviewer directed starting without asking.

## Goal (from the plan)

One coherent operator workflow for a basic **local** backup:

```bash
./zfs-backup.sh local-backup --source=rpool/data --target=hdd/backups
```

discover/propose scope, choose/default a preset, show CONFIG + cron, then seed
and activate transactionally. This is the LOCAL push/snapshot path — distinct
from `add-client`/`activate-client`, which pair two hosts for a remote PULL.

## What already exists and is reused, not rebuilt

- **profile rendering** — `lib-profile.sh` `profile_render_templates` produces
  the namespaced `[template:profile__<name>__*]` sections (the GFS ladder).
- **config generation truth** — `gen-cron.sh -c` validates and renders the
  candidate CONFIG; `show_activation_proposal` + `atomic_replace_and_install`
  already do "preview then atomic install with read-back", used by
  `activate-client`. Phase 5 composes these; it does not add a second renderer
  or a second installer.
- **host setup** — `setup-server` already resolves `DEFAULT_TARGET`/`CRON_CONFIG`
  and writes `SERVER_CONF`. `local-backup` writes into that same `CRON_CONFIG`.

A local candidate CONFIG was proven to render through the real `gen-cron.sh`
(send line + one GFS prune ladder + monitor):

```
[defaults] host_label = <host>
<profile__default__* templates>
[dataset:<source>]  use_template = profile__default__standard_hourly
                    dst = <target>
[prune:<target>]    use_template = profile__default__keep_hourly,keep_daily,keep_weekly,keep_monthly
                    gfs = yes   gfs_pattern = automated_   recursive = yes
```

The push engine reads locally and writes to `dst` when `dst` has no `:` — the
same "local-to-local" branch `snapsend.sh` already documents.

## Decisions

1. **Command surface**: a new `local-backup` subcommand, not a bare top-level
   `--source/--target`, so it sits beside the other verbs and keeps dispatch
   uniform. `--source=`, `--target=`, optional `--profile=` (default `default`),
   optional `--config=` (defaults to the resolved `CRON_CONFIG`).
2. **Source is WHAT, recursion is HOW/preset** (plan rule). `--source` names one
   dataset; whether the job is recursive comes from the profile/preset, never
   from a separate `--recursive` flag on this command.
3. **Overlap is refused, both directions.** `--target` nested inside `--source`,
   `--source` nested inside `--target`, or the two equal, all refuse — a backup
   whose destination overlaps its own source is a self-reference. Implemented as
   a pure string check with trailing-slash boundaries (so `rpool/data` does not
   spuriously match `rpool/database`). No ZFS needed to decide it.
4. **Same pool is allowed with one factual note, not a policy judgement** (plan
   rule). `--source=rpool/x --target=rpool/y` proceeds; the preview states
   plainly that source and target share pool `rpool`, so a pool-level failure
   takes both. It does not refuse and does not moralise.
5. **Target mapping**: `dst = <target>` verbatim — the on-disk child the push
   engine creates under it is the engine's business, exactly as in the existing
   local `[dataset:] dst=` shape. The overlap check reasons about the stated
   `--target`, which is the operator's declared destination.
6. **Read-only planning first** (mirrors Phase 7 `restore --plan`). Slice 1
   discovers scope, validates, renders the candidate CONFIG and its cron, and
   STOPS. Install is a separate slice, so the first reviewable unit cannot touch
   a crontab.
7. **Transactional install** (slice 2) reuses `activate-client`'s existing
   sequence: build a workfile, `gen-cron.sh -c` validate, preview, confirm,
   `atomic_replace_and_install` with read-back. Decline/failure leaves the real
   `CRON_CONFIG` and crontab untouched — the "retryable state, no production
   cron" the plan requires falls out of never touching the real file until the
   atomic swap.

## Slice plan

- **Slice 1 (this delivery) — planning/preview, read-only.** `cmd_local_backup`
  with argument parsing, the pure overlap/same-pool validation, default-profile
  selection with `profile_validate_dir`, candidate-CONFIG generation, and
  config+cron preview via `gen-cron.sh`. It refuses to install (surface reserved,
  message points at the coming slice). Test suite `test/localbackup` pins the
  overlap refusals (both directions + equal), the same-pool note, unknown-profile
  refusal, and that the candidate renders through the real `gen-cron.sh` with the
  default profile's semantics — all pure/text, no ZFS.
- **Slice 2 — transactional install.** Wire the workfile/validate/preview/confirm/
  `atomic_replace_and_install` path; add ownership markers so `local-backup` and
  `activate-client` never fight over the same CONFIG; live-verify on a real host.
- **Slice 3 — scope discovery / same-pool ergonomics.** Optional: propose a
  target when omitted (like `setup-server` does), children handling.

## Gate 5

Basic local backup deployment is one coherent operator workflow. Reached when
slice 2 lands and is live-verified; slice 1 is the read-only planning half.
