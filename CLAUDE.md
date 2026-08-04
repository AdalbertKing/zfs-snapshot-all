# Implementer instructions

Read `docs/AI_PROJECT_RULES.md`, `docs/internal/reviews/README.md`, and the referenced review file before changing code.

## Default role

The default role for Claude in this repository is **implementer**.

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

`docs/PROJECT_STATUS.md` is the shared current-state document. The owner and the
reviewer both read it, and the reviewer works from GitHub rather than from this
session — so it is the only place either of them can find out what the tree does
*today*.

Refresh it at the end of **every** stage, before reporting the stage as done:

- the `Stan na` commit and date;
- the host, version and deployment tables;
- the suite counts;
- the open-items split: awaiting reviewer / awaiting owner / known gaps.

Where a change replaces a design the document describes, **rewrite that section**
rather than appending to it. Historical accuracy belongs in
`docs/internal/reviews/responses/`; current truth belongs in `PROJECT_STATUS.md`. A
document that lags behind `main` is not untidy, it is a reviewer reading a design
that no longer exists.

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