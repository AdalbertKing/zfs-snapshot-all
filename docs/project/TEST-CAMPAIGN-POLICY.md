# TEST CAMPAIGN POLICY

Status: ACTIVE

This document is the project-wide policy for deciding when to run narrow tests, impacted suites, subsystem campaigns, and full live campaigns. Its goal is to minimise total cost: implementation time, environment time, token use, later diagnosis cost, and production-data risk.

## 1. Classify every change before coding

### A — isolated/local
Examples: wording, one validator, one marker read/write, one pure helper, documentation.

Required after the step:
- `bash -n` for touched shell files;
- the direct owning suite;
- `test/impact.sh --verify`;
- a focused negative test when fixing a defect.

A full campaign waits until the functional package closes.

### B — one-subsystem functional change
Examples: `pause-client`, one CLI flag in snapget/snapsend, one class of generated cron lines, status/monitoring for one feature.

Required after each logical step:
- owning suite;
- all suites selected by `impact.sh`;
- positive, negative, idempotence, and two-relationship isolation tests where applicable.

Do not run a costly full live campaign after every slice if the next planned slice will modify the same workflow again. Run the full subsystem campaign after the last planned touch of that workflow.

### C — shared abstraction
Examples: `lib-cron.sh`, manifest/config format, shared parser/helper, lock model, relationship identity, endpoint identity, atomic state writer, forced-command framework.

Required before other work builds on it:
- all impacted suites and all direct consumers;
- old behaviour and new behaviour;
- failure, retry, idempotence, backward-compatibility tests;
- a short live checkpoint when cron, SSH, ZFS, UID, locks, or transfer behaviour is involved.

Do not defer validation of a shared abstraction until several dependent features have accumulated.

### D — data or security boundary
Examples: send/receive, rollback/destroy, resume tokens, grants/revokes, UID binding, `authorized_keys`, teardown, cron activation, hard-disable SSH, clobber protection, partial commits.

Required after each completed safety checkpoint:
- all impacted suites;
- positive and negative tests;
- forced-failure and retry-after-partial-failure tests;
- residue checks;
- two independent relationships/principals;
- live scratch-data test.

Do not batch several unverified Category D changes.

## 2. Last-touch rule

Before a costly campaign ask:

> Will the next planned step modify the same code block, shared abstraction, or lifecycle again?

- YES: run narrow/impacted regression now and defer the full live campaign to the final planned touch.
- NO: run the full subsystem campaign now.
- Exception: Categories C and D require an earlier checkpoint before dependent work continues.

## 3. Diagnosis-cost rule

Run a broad checkpoint early when:
- many consumers depend on the change;
- a failure can masquerade as another layer;
- the next slice relies on a new contract;
- only live infrastructure can prove the behaviour;
- partial failure can leave persistent state;
- data, permissions, cron, SSH identity, or teardown are affected.

Defer the broad checkpoint when the change is local, strongly unit-tested, easy to attribute to one commit, and the next slice will replace the same implementation area.

## 4. Package checkpoints

A functional package must define its stable checkpoints before coding. For each step record:

| Step | Category | Shared abstraction? | Tests after step | Full live now? |
|---|---|---:|---|---:|

Update this table when the real scope expands.

For logical pair pause, the full live campaign belongs after the complete chain is present: state marker, CLI, `-L` propagation, config, cron generation, monitoring, status, pause/resume. Shared-lock or shared-parser changes still require their own intermediate checkpoint.

For hard disable, treat forced-command identity and refusal-before-ZFS as Category D. Test that security boundary live before adding higher-level enable/disable orchestration.

## 5. Reporting and token economy

For intermediate slices report only:
- commit;
- category;
- touched files/abstraction;
- suites and PASS/FAIL;
- open risk;
- whether the full campaign is deferred and to which checkpoint.

Publish full evidence only after a package checkpoint, live test, regression, shared-abstraction change, or final verdict. Refer to prior commits/documents instead of repeating history.

## 6. Non-negotiable rule

The cheapest process is not the one with the fewest test runs. It is the one that places full campaigns exactly at stable boundaries while testing shared abstractions and safety boundaries before dependent code obscures failures.
