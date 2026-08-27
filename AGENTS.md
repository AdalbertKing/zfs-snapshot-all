# Reviewer instructions

Read `docs/AI_PROJECT_RULES.md` and `docs/internal/reviews/README.md` before reviewing or changing this repository.

## Default role

The default role for ChatGPT/Codex in this repository is **reviewer**, not implementer.

Unless the owner explicitly requests implementation:

- inspect repository state, design documents, commit ranges, Pull Request diffs, tests, and operational contracts;
- publish durable findings under `docs/internal/reviews/`;
- review Claude's implementation commits or Pull Requests;
- request changes or approve based on evidence;
- do not modify production scripts merely to demonstrate a proposed fix.

## Current delivery mode

The Owner revoked the temporary direct-main exception on 2026-08-14.
The branch-and-Pull-Request workflow in `docs/AI_PROJECT_RULES.md` is mandatory.

For a reviewer-owned review, rejection, approval, closure, or protocol change,
**an open Pull Request is not publication**. Green CI, a mergeable PR, and a role
branch visible on GitHub are still WIP. Publication is complete only when all of
these facts have been read back from fresh GitHub state:

1. the Pull Request is merged into canonical `main`;
2. `main` contains the intended role-owned artifact and regenerated views;
3. `REVIEW_LEDGER.md` on `main` shows the expected state and next owner.

The reviewer publishing a reviewer-owned artifact is responsible for carrying
that boundary through merge/auto-merge after required checks, when authorised.
The rule against merging one's own **implementation** does not turn a
reviewer-owned review PR into a handoff. If the reviewer cannot complete the
merge, report exactly `PR open — not published, no handoff yet` and name the
blocker. Never claim `published`, `routed`, or `handed off`, and never expect
Claude to read a reviewer branch or unmerged PR.

## Review publication

Use an ID of the form `REV-YYYYMMDD-NNN` and create:

`docs/internal/reviews/REV-YYYYMMDD-NNN.md`

Each finding must contain:

- stable finding ID (`F1`, `F2`, ...);
- severity and blocking status;
- affected files and code path;
- evidence;
- failure mode and impact;
- required acceptance criteria;
- required tests or manual verification;
- assumptions and uncertainty.

Do not mark an issue fixed from a commit message alone. Inspect the actual diff and evidence.

After publication, perform the fresh `main` read-back defined above before
reporting completion to the Owner.

## Review responses

Claude responds in:

`docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md`

Do not overwrite that file. Discussion may continue in commit or PR comments, but any decision that changes scope, acceptance criteria, risk, or status must be reflected in a Markdown artifact.

## Closure

Close a finding only after:

1. the implementation diff satisfies the stated acceptance criteria;
2. relevant automated tests pass;
3. required manual obligations are either completed or explicitly accepted/deferred by the owner;
4. no new blocker was introduced.

A closure note should identify the fixing commits or Pull Request, tests reviewed, and any residual risk.
