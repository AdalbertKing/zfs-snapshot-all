# Test-suite cost audit — 2026-08-11 (REV-20260811-109)

One-pass engineering measurement of the repeatedly-used local suites, to justify the
L0 targeted-execution boundary REV-109 requires. Measured on the implementation
environment (Windows/msys `bash`, no root, no ZFS). Wall-clock is dominated by process
spawn cost on msys — every assertion that shells out (`bash -c`, real `gen-cron.sh`,
`mktemp`, `awk`, `md5sum`) pays a heavy per-process penalty here.

## Main suites

| suite | assertions | wall-clock | selected when | targeted boundary? | biggest cost |
|---|---|---|---|---|---|
| `zfsbackup` | **389** | **~7 min** | any `zfs-backup.sh` change (the whole product engine) | **NEW: `--section retention`** (this REV) | sequential; many assertions each `source` zfs-backup.sh in a fresh `bash -c` and several render through the REAL `gen-cron.sh` |
| `localbackup` | 42 | ~1.5 min | `zfs-backup.sh` local-backup path change | none yet | per-assertion `bash -c` + gen-cron |
| `pairgate` | ~49 | ~2 min | pairing/deploy path change | none yet | `bash -c` per assertion |
| `pause` | ~10 (+G on real host) | ~30 s local | pause/durable-txn change | none | some sections skip off-host |
| `alertmail` | ~19 | ~40 s | alert wording change | none | greps rendered mail |
| `scenarios`, `remote` | end-to-end / ssh | L2 only | live/destructive boundary | n/a (L2) | real hosts |

`./test/impact.sh --verify` is a cheap consistency check (~2–3 s of graph work plus a
`reviewctl --verify`); it is L0-cheap and may run every iteration.

## Findings — biggest offenders first

1. **`zfsbackup` is the one real problem.** At 389 sequential assertions and ~7 min it
   is selected by the dependency graph on every `zfs-backup.sh` edit, so a narrow late
   correction (the REV-102/108/110 audit lives in sections 57–59, the last ~13
   assertions) paid the full ~7 min per reviewer round. That is the delivery cost
   REV-109 targets.

2. **The smallest convenient execution unit was the whole file.** There was no way to
   run just the audit sections; they also had a hidden dependence on earlier state
   (the `P56` profile fixture built in section 56, the `GC5` gen-cron stub built in
   section 57), so a naive "run only 57" would have false-greened or errored.

3. **No exact duplicate suites found.** `localbackup` overlaps `zfsbackup` only at the
   shared engine boundary by design (the local path has its own fixtures); not a
   removal candidate. No coverage is proposed for deletion here (REV-109 non-goal).

## Correction applied (REV-109)

- `test/zfsbackup/run.sh --section retention` runs ONLY the source-retention audit
  group (REV-102/108/110, sections 57–59), skipping sections 1–56/92 behind a single
  guard. Measured: **13 assertions, ~1m12s** vs ~7 min for the full suite (~6× faster;
  the residual cost is the two real-`gen-cron` renders in 57b).
- The group is **self-contained**: it builds its own profile fixture (`RP56`) and its
  own gen-cron stub, so targeted mode does not depend on skipped-section state.
- No-argument `./test/zfsbackup/run.sh` remains the full regression suite (unchanged
  coverage, now **391** with the REV-110 section-59 additions); the targeted group is
  also run by it, so there is one source of truth, not a fork.

## Execution policy in effect (L0/L1/L2)

- **L0** — intermediate REV-102/108/110 corrections: `run.sh --section retention` +
  `impact.sh --verify`.
- **L1** — formal resubmission of a complete REV: full dependency-selected suite(s).
- **L2** — gate/phase live/destructive campaign: only when the acceptance property
  requires it (remote prune execution already has separate live proof).
