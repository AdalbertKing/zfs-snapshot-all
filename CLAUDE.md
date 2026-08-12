# Implementer instructions

Read `docs/AI_PROJECT_RULES.md`, `docs/internal/reviews/README.md`, and the active reviewer file before changing code.

## Default role

The default role for Claude in this repository is **implementer**.

## Work pickup — mandatory

`docs/internal/reviews/REVIEW_LEDGER.md` on the freshly published `main` is the only authoritative answer to **what Claude should do next**.

At the start of a work cycle, after the Owner asks whether there is work, and **before saying that there is nothing from the Reviewer / nothing to do**:

1. Refresh the published repository state (`git fetch origin main` or an equivalent fresh read of GitHub `main`). Do not decide from a stale local checkout.
2. Read `docs/internal/reviews/REVIEW_LEDGER.md` from that fresh published state.
3. Every row whose derived state is `OPEN` and owner is `Claude` is an actionable reviewer handoff. Open the matching `docs/internal/reviews/REV-YYYYMMDD-NNN.md` and continue that REV from the reviewer's current requirements.
4. `IMPLEMENTED -> Reviewer` means the submitted SHA is waiting for review. `APPROVED -> Reviewer` means closure is the reviewer's move. `CLOSED` needs no implementer action.
5. Never claim "no reviewer work" while the fresh ledger contains an `OPEN | Claude` row.

A rejection/follow-up normally does **not** edit Claude's response file: the Reviewer advances the reviewer-owned `reviewed-implementation`/verdict fact, which deterministically changes the ledger from `IMPLEMENTED -> Reviewer` to `OPEN -> Claude`. Therefore an older response may still say `response-status: IMPLEMENTED`, may describe previous remaining work, or may contain an earlier request for reviewer input. **The fresh ledger plus the current reviewer file wins for pickup.** Claude updates the same response file only after producing the next implementation/evidence SHA.

`docs/project/OPEN-THREADS.md` is only a generated convenience view. `docs/PROJECT_STATUS.md` describes product/operational state. Neither may be used instead of `REVIEW_LEDGER.md` for workflow ownership.

## Current delivery mode

`docs/AI_PROJECT_RULES.md` records an active, temporary owner-approved direct-main exception.
While it remains active:

1. A branch and Pull Request are preferred when practical but are not required.
2. Claude may commit a reviewed logical change directly to `main`.
3. Create or update `docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md` with the implementation evidence.
4. Address one logical finding per commit whenever findings can be separated safely.
5. Add regression tests that fail on the reviewed base and pass after the fix.
6. Run the impact graph and all available required suites before push.
7. Do not mark findings `CLOSED`; the reviewer owns technical closure.
8. Never force-push or rewrite a published direct-main commit. Correct defects with a new forward commit.

When the owner revokes the exception, return to the normal branch and Pull Request workflow described in `docs/AI_PROJECT_RULES.md`.

## Response file

Do not edit the reviewer's `docs/internal/reviews/REV-*.md` file. Record the response separately using this structure:

```markdown
# Response to REV-YYYYMMDD-NNN

## F1 — ACCEPTED | DISPUTED | NEEDS-DISCUSSION | IMPLEMENTED

### Analysis
...

### Planned or implemented change
...

### Evidence
- commit/PR:
- commands run:
- results:

### Remaining risk
...
```

A disagreement is valid. State it precisely and provide code, ZFS/OpenSSH documentation, a reproducible test, or measured behavior. Do not change code merely to satisfy wording that is technically wrong; request review discussion instead.

## Implementation constraints

- Preserve compatibility unless the review explicitly permits a breaking change.
- Treat config, manifest, archive, hostname, dataset, and remote values as data. Do not execute them with `source`, `eval`, or equivalent mechanisms.
- Do not weaken host-key checking, delegated-account isolation, destructive-operation guards, or Proxmox-reserved-snapshot protections as a shortcut.
- Do not use `test/run.sh --bless` until the output diff has been reviewed as an intentional contract change.
- Run `./test/impact.sh` against the actual diff and report every required suite and manual obligation.
- Where the environment cannot run a required ZFS, remote-host, delegated-account, or destructive test, say so explicitly and leave the finding `IMPLEMENTED`, not `CLOSED`.

## Project status document

`docs/PROJECT_STATUS.md` is the shared **product/operational** current-state document. It describes what the tree and deployed estate do today, but it is **not review workflow state and must not be used to decide whose move it is**. Workflow ownership comes only from the generated `docs/internal/reviews/REVIEW_LEDGER.md` as required by Protocol V2.

Refresh `PROJECT_STATUS.md` at the end of **every** stage, before reporting the stage as done:

- the `Stan na` commit and date;
- the host, version and deployment tables;
- the suite counts;
- product/operational open items and known gaps.

Where a change replaces a design the document describes, **rewrite that section** rather than appending to it. Historical accuracy belongs in `docs/internal/reviews/responses/`; current product truth belongs in `PROJECT_STATUS.md`.

`./test/impact.sh` raises this as the manual obligation `project-status`.

## Delivery evidence

For a Pull Request or direct-main delivery, record:

- review/finding IDs;
- root cause;
- implementation summary;
- compatibility and security impact;
- exact test commands and results;
- manual checks still required;
- documentation updated;
- exact commit SHA or PR number.