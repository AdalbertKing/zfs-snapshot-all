# REV-20260807-057 — recursion migration must not leave a live config unusable

**Review forced:** 2026-08-07 13:09 CEST

**Fresh head fetched immediately before review:** `b16676fd6f43e5175217c3946ccaed02957b8cde` (`2026-08-07 13:06:24 CEST`)

**Verdict:** **CHANGES REQUIRED**

**Severity:** **P2 — operational migration / upgrade-safety blocker**

**Response path:** `docs/internal/reviews/responses/REV-20260807-057.md`

## Finding F1 — the deployed generator already refuses a production host's own live config

The recursion redesign in v4.27 deliberately hard-rejects legacy `-r` / `-R` inside `[dataset:] flags`, replacing that free-text declaration with `recursive = no | flat | atomic`. The hard rejection is correct and REV-054 approved it.

The rollout order is not yet operationally complete, however. `PROJECT_STATUS.md` now records all of the following as current facts:

1. v4.27 has already reached the fleet via the hourly update path;
2. `192.168.11.11` still has the pre-migration production config containing `flags = -r ...`;
3. the deployed v4.27 `gen-cron.sh` on that host refuses that config;
4. the installed crontab keeps running only because nothing regenerates it automatically;
5. the correct migration has been proven on a throwaway copy to preserve the installed managed block byte-for-byte, but the live config itself was intentionally not changed.

This is not a current backup outage, but it is an upgrade-safety defect in the package state: the installed toolchain cannot successfully consume one of the configurations it is responsible for maintaining. The next legitimate human action that needs a regenerate/install path can therefore fail at exactly the point where the administrator is trying to repair or change something.

A hard cut-over is acceptable only when the package also provides a bounded, obvious path from the old accepted representation to the new accepted representation. "Edit `flags = -r -v 3` by hand into `recursive = atomic` + `flags = -v 3`" is evidence for the implementation, not the intended operator UX.

## Required outcome

Do not weaken the v4.27 hard rejection and do not silently mutate production configs during hourly self-update. Close the migration gap explicitly.

The smallest acceptable design is a **one-command, fail-closed migration path** owned by the package. It may live in `zfs-backup.sh`, `gen-cron.sh`, or an existing migration surface if there is already one that naturally owns config-schema migrations. Do not create a parallel framework just for this field.

### Contract

1. **Discovery uses the same parsing semantics as the generator.** Find legacy recursion only where `-r` / `-R` is actually an option in `[dataset:] flags`; do not use a naive substring/grep rule that mistakes option arguments such as `-m R-daily_` for recursion.

2. **Mapping is deterministic and narrow.**
   - legacy `-r` -> `recursive = atomic`;
   - legacy `-R` -> `recursive = flat`;
   - remove only the recursion option from `flags` and preserve every other option and argument;
   - refuse ambiguous/unrepresentable input rather than guessing.

3. **No semantic drift is allowed.** Before replacing a live config, render the proposed migrated config in the same effective environment used for the installed managed block and prove that the managed cron block is byte-identical to the currently installed one. The direct equivalence technique already proven on `192.168.11.11` after REV-055 is the reference. If the control cannot be made trustworthy, abort; do not call a noisy comparison success.

4. **Config commit is transactional.** Keep the original file until validation and equivalence checks pass; write through temp + atomic rename; preserve owner/mode; retain a named rollback copy or another package-standard recovery point. A failure before commit leaves the original config untouched.

5. **Do not reinstall cron merely to migrate syntax.** If the migrated config reproduces the installed managed block byte-for-byte, commit the config and leave the running crontab untouched. This is a schema migration, not a schedule change.

6. **Idempotent.** Running the migration again on an already migrated config is a no-op with rc=0 and no file-content change.

7. **Operator-facing output names exactly what happened.** Report the file, each migrated dataset section, `atomic` vs `flat`, whether the installed block comparison passed, and whether the live file was changed. On refusal, say exactly which section/flag prevented safe migration.

8. **Fleet preflight.** Before calling the recursion package operationally complete, inspect all active configs on all four reachable hosts with the same detector. Record which require migration. Do not assume only `192.168.11.11` because it was the one already found.

## Required tests

At minimum:

- plain `-r` migrates to `recursive = atomic`;
- plain `-R` migrates to `recursive = flat`;
- bundled forms such as `-Rv 3` and `-rZ` are interpreted consistently with v4.27's getopts-equivalent parser and preserve non-recursion flags correctly;
- an argument containing `R`/`r` is not migrated as recursion;
- already-migrated config is byte-identical after a second run;
- forced render failure leaves the source config byte-identical;
- forced config-publish failure leaves the source config byte-identical and reports a retryable failure;
- installed-block mismatch refuses the migration;
- negative control proves the pre-migration config is rejected by current v4.27 and the migrated config is accepted;
- live proof on `192.168.11.11`: config before/after checksums recorded, migrated config accepted by deployed v4.27, proposed managed block byte-identical to installed block, installed crontab checksum unchanged.

Use the existing impacted suites and update `test/deps.conf` / impact metadata if the new migration entry point creates a real dependency edge.

## Interaction with REV-056

REV-056 (`b16676f`) is **APPROVED FOR IMPLEMENTATION WITH CONDITIONS** and may proceed independently. This review does not reopen its monitor-age contract.

However, the recursion package must not be described as fully deployed on the fleet until F1 above is closed. The current state is accurately described as: **runtime behavior still running, new generator deployed, one or more live configs potentially awaiting schema migration**.

## Response required

Respond in `docs/internal/reviews/responses/REV-20260807-057.md` with:

- ACCEPTED / DISPUTED / NEEDS-DISCUSSION;
- chosen existing command surface for migration and why it is the smallest one;
- implementation commit(s);
- deterministic test results and negative controls;
- four-host config inventory;
- live `192.168.11.11` migration/equivalence evidence or an explicit technical blocker.

No owner decision is required for the migration mechanism itself; this is package upgrade hygiene. Do not modify unrelated production behavior while closing it.
