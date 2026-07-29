# AI project rules

This repository is the single source of truth for work performed by human maintainers and AI agents.
Chat transcripts, local notes, and unpushed files are not project state.

## Roles

- **Owner:** decides product direction, operational risk acceptance, and whether a change may be deployed.
- **Implementer (Claude by default):** analyzes accepted findings, changes code, adds tests, and supplies evidence.
- **Reviewer (ChatGPT by default):** inspects design and diffs, publishes findings, verifies evidence, and decides whether a finding is closed. The reviewer does not implement fixes unless the owner explicitly asks.

The roles may be swapped for a specific task only when the owner says so explicitly.

## Git workflow

1. Do not commit directly to `main`.
2. One problem or review per branch and Pull Request.
3. One commit must contain one logical change. Do not combine an implementation, unrelated cleanup, fixture refresh, and documentation rewrite in one commit.
4. Do not merge your own implementation merely because its tests pass. The reviewer must inspect it.
5. Use a stable release tag or pinned commit for production deployment. `main` is development state, not an automatic release channel.
6. Never rewrite published history or force-push a shared branch without the owner's explicit instruction.

Recommended branch names:

- review publication: `review/REV-YYYYMMDD-NNN-short-title`
- implementation: `fix/REV-YYYYMMDD-NNN-short-title`
- maintenance not originating from a review: `maintenance/short-title`

## Review artifacts

Durable review communication lives under `docs/reviews/`.

- Reviewer finding: `docs/reviews/REV-YYYYMMDD-NNN.md`
- Implementer response: `docs/reviews/responses/REV-YYYYMMDD-NNN.md`
- Optional closure record: `docs/reviews/closures/REV-YYYYMMDD-NNN.md`

The implementer must not edit the reviewer's finding file. Disagreement is recorded in the response file, with technical evidence. The reviewer must not silently rewrite the implementer's response.

Review states:

- `OPEN` — published and awaiting response or implementation.
- `ACCEPTED` — implementer agrees with the finding; not yet proven fixed.
- `DISPUTED` — implementer disagrees and provides evidence.
- `IMPLEMENTED` — code and tests are present in a PR; not yet accepted by reviewer.
- `CLOSED` — reviewer verified the acceptance criteria.
- `DEFERRED` — owner explicitly accepted postponement and recorded the reason.
- `REJECTED` — reviewer withdrew the finding or owner accepted the documented risk.

Only the reviewer marks a technical finding `CLOSED`. Only the owner accepts operational risk or changes priority.

## Required evidence

Every implementation PR must state:

- review and finding IDs addressed;
- root cause;
- files changed;
- tests added or changed;
- exact commands run and their results;
- manual obligations reported by `test/impact.sh`;
- known limitations and remaining risks.

A statement such as "tests pass" without commands and results is insufficient.

## Test discipline

Before declaring work complete:

1. Run `./test/impact.sh <range>` or `./test/impact.sh` for the actual diff.
2. Run every listed dependency-free suite.
3. Run root/ZFS/remote suites when the impact graph requires them and the environment is available.
4. Record any unperformed manual obligation explicitly; never imply that a green local suite covers remote SSH, delegated accounts, destructive force-full paths, or live cron installation.
5. Do not use `--bless` merely to make golden tests pass. A fixture change must be reviewed as an intentional behavior change.

## Safety boundaries

- Treat pairing packages, INI files, manifests, dataset names, hostnames, and remote output as untrusted data unless the code proves otherwise.
- Data files must be parsed as data, not executed with `source`, `eval`, or an equivalent mechanism.
- Destructive ZFS operations require explicit scope, dry-run evidence where available, and a throwaway target for tests.
- Security checks must fail closed with a clear diagnostic. Do not silently fall back to a less secure behavior.
- Do not remove compatibility or safety guards as incidental cleanup.

## Documentation

Documentation is part of the contract. Any change to flags, defaults, configuration fields, deployment behavior, delegated permissions, or operational safety must update the relevant documentation and tests in the same PR.
