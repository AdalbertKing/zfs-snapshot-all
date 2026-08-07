# AI project rules

This repository is the single source of truth for work performed by human maintainers and AI agents.
Chat transcripts, local notes, and unpushed files are not project state.

## Roles

- **Owner:** decides product direction, operational risk acceptance, delivery mode, and whether a change may be deployed.
- **Implementer (Claude by default):** analyzes accepted findings, changes code, adds tests, and supplies evidence.
- **Reviewer (ChatGPT by default):** inspects design and diffs, publishes findings, verifies evidence, and decides whether a finding is approved/closed. The reviewer does not implement production fixes unless the owner explicitly asks.

The roles may be swapped for a specific task only when the owner says so explicitly.

For detailed review ownership and transitions, `docs/project/PROTOCOL.md` (REVIEW PROTOCOL V2) is authoritative.

## Git workflow

Normal workflow:

1. Use a branch and Pull Request rather than committing directly to `main`.
2. One problem or review per branch and Pull Request.
3. One commit must contain one logical change. Do not combine an implementation, unrelated cleanup, fixture refresh, and documentation rewrite in one commit.
4. Do not merge your own implementation merely because its tests pass. The reviewer must inspect it.
5. Production should normally use a stable release tag or pinned commit. `main` is ordinarily development state, not an automatic release channel.
6. Never rewrite published history or force-push a shared branch without the owner's explicit instruction.

Recommended branch names:

- review publication: `review/REV-YYYYMMDD-NNN-short-title`
- implementation: `fix/REV-YYYYMMDD-NNN-short-title`
- maintenance not originating from a review: `maintenance/short-title`

### Temporary owner-approved direct-main mode

Active from **2026-07-29 until the owner explicitly revokes it**.

The owner has temporarily authorized Claude and ChatGPT to commit directly to `main` because:

1. four live test servers pull `main` every hour;
2. the owner operates Claude Code and ChatGPT remotely from a smartphone and cannot reliably perform the manual Git and Pull Request steps.

During this exception:

- a branch and Pull Request are preferred when practical but are not required;
- `main` is the live integration channel and the owner accepts the associated moving-main risk;
- every commit must still be one reviewable logical change;
- relevant tests must be run before push when the environment permits;
- GitHub Actions on push is post-delivery evidence, not a pre-merge gate;
- review findings and implementer responses must still be written under `docs/internal/reviews/`;
- workflow state must follow `docs/project/PROTOCOL.md` and, after V2 cutover, the machine-owned `REVIEW_LEDGER.md`;
- the implementer must not approve or close own findings; the reviewer owns technical approval/closure;
- no force-push, history rewrite, silent fixture blessing, or weakening of safety checks is permitted;
- any direct-main change that fails review must be corrected by a new forward commit, never by rewriting published history.

This exception changes delivery mechanics only. It does not waive testing, evidence, review, or safety requirements.

## Review artifacts and workflow state

Durable review communication lives under `docs/internal/reviews/`.

For V2, the authoritative specification is `docs/project/PROTOCOL.md`.

Canonical new artifacts:

- Reviewer finding: `docs/internal/reviews/REV-YYYYMMDD-NNN.md`
- Implementer response: `docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md`
- Current workflow state: `docs/internal/reviews/REVIEW_LEDGER.md` (machine-owned after V2 cutover)

The implementer must not edit the reviewer's finding prose. Disagreement is recorded in the existing response file, with technical evidence. The reviewer must not silently rewrite the implementer's response.

Exactly four V2 workflow states exist:

- `OPEN`
- `IMPLEMENTED`
- `APPROVED`
- `CLOSED`

The only rejection transition is `IMPLEMENTED -> OPEN`. A genuinely new finding after approval receives a new REV; clarification or a second implementation attempt does not.

Terms such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` and `REJECTED` may be retained as evidence or resolution metadata but are not parallel workflow states.

After cutover, agents do not manually edit `REVIEW_LEDGER.md` or `OPEN-THREADS.md`; workflow transitions go through `reviewctl`, and `OPEN-THREADS.md` is generated from the ledger.

Only the reviewer approves/closes a technical finding. Only the owner accepts operational risk or changes priority.

## Required evidence

Every implementation delivery, whether a Pull Request or direct-main commit, must state:

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

Documentation is part of the contract. Any change to flags, defaults, configuration fields, deployment behavior, delegated permissions, or operational safety must update the relevant documentation and tests in the same delivery unit.