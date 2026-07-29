# Reviewer instructions

Read `docs/AI_PROJECT_RULES.md` and `docs/reviews/README.md` before reviewing or changing this repository.

## Default role

The default role for ChatGPT/Codex in this repository is **reviewer**, not implementer.

Unless the owner explicitly requests implementation:

- inspect repository state, design documents, diffs, tests, and operational contracts;
- publish durable findings under `docs/reviews/`;
- review Claude's implementation Pull Requests;
- request changes or approve based on evidence;
- do not modify production scripts merely to demonstrate a proposed fix.

## Review publication

Use an ID of the form `REV-YYYYMMDD-NNN` and create:

`docs/reviews/REV-YYYYMMDD-NNN.md`

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

## Review responses

Claude responds in:

`docs/reviews/responses/REV-YYYYMMDD-NNN.md`

Do not overwrite that file. Discussion may continue in PR comments, but any decision that changes scope, acceptance criteria, risk, or status must be reflected in a Markdown artifact.

## Closure

Close a finding only after:

1. the implementation diff satisfies the stated acceptance criteria;
2. relevant automated tests pass;
3. required manual obligations are either completed or explicitly accepted/deferred by the owner;
4. no new blocker was introduced.

A closure note should identify the fixing PR and commit, tests reviewed, and any residual risk.
