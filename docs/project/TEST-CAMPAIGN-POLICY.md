# Test campaign policy

Status: ACTIVE. Simplified 2026-08-06 by owner direction; supersedes the
earlier A/B/C/D category version, which described the same intent as a
checklist. Same goal, less ceremony: quality without paying for the same
campaign twice.

Cross-cutting lifecycle invariants are defined in
`docs/project/FOUNDATIONS.md` and apply to every campaign.

## The rule

1. Match the test scope to the real risk of the change.
2. Group related changes into one package; run the expensive campaign once,
   at the end of it.
3. While implementing, run only what gives fast local feedback: syntax check,
   the new or changed function's own test, the owning suite, a reproduction
   of the specific defect.
4. Do not re-run a full campaign just because you can, and never for a
   documentation-only change.
5. Do not defer a checkpoint when the change touches something shared or
   dangerous (see below).
6. Justify each scope decision in one line. The reviewer judges the result
   and the reasoning, not checklist compliance.
7. For any recurring path that creates or accumulates state, prove the
   **lifecycle**, not only the first run: ownership, bounded growth, cleanup
   path, cleanup scope and failure behavior. Ask explicitly: **what happens
   after 1000 successful/failed/mixed runs?** Use a thought experiment for
   low-risk logic and a targeted multi-generation/live test where the state is
   destructive, persistent or operationally dangerous.

## Do not wait — checkpoint now

Run a checkpoint before continuing when the change touches:

- untrusted input parsing, permissions, SSH, `zfs allow`, archive
  extraction, or anything running as root;
- a shared library, the crontab writer, the cron generator, or a contract
  several suites depend on;
- an operation that is destructive or leaves persistent state;
- a periodic/automatic writer, cleaner or accumulator whose steady-state
  resource growth has not yet been proved bounded;
- an assumption the next step will build on;
- anything where a targeted test already failed — do not stack new work on
  an unsettled base.

In this repo that means, concretely: `lib-cron.sh`, `lib-zfs-snap.sh` and the
`twin-functions` contract, `deploy.sh`'s pair/join paths, `zfs-pair-gate.sh`,
and the contracts nothing in the code enforces (`delegation-verbs`,
`account-paths`, `ssh-flag-parity`, `monitor-exit-codes`, `gen-cron-flags`).
It also means snapshot/bookmark retention, queues/logs/locks, temporary or
staging datasets, generated state residue and future offline-replica anchors:
these are not complete until their repeated-run cleanup/failure lifecycle is
proved.

## Reporting

Report results for the FINAL commit of a package, not copied from earlier
ones. Per intermediate step, one short block is enough: commit, what it
touched, suites with counts, open risk, and what was deferred to which
checkpoint. Full logs only when something failed.

For recurring/state-creating functionality, the report must name the lifecycle
property proved (or explicitly deferred): steady-state bound, cleanup owner,
cleanup scope and long-outage/failure behavior. A green one-shot command is not
sufficient evidence for that class of change.

`./test/impact.sh` selects the suites for an actual diff and `--verify`
catches graph drift; use them instead of guessing the blast radius.
