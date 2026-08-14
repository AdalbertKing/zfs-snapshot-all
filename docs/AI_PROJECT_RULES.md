# AI project rules

This repository is the single source of truth for work performed by human maintainers and AI agents.
Chat transcripts, local notes, and unpushed files are not project state.

## Roles

- **Owner:** decides product direction, operational risk acceptance, delivery mode, and whether a change may be deployed.
- **Implementer (Claude by default):** analyzes accepted findings, changes code, adds tests, and supplies evidence.
- **Reviewer (ChatGPT by default):** inspects design and diffs, publishes findings, verifies evidence, and decides whether a finding is approved/closed. The reviewer does not implement production fixes unless the owner explicitly asks.

The roles may be swapped for a specific task only when the owner says so explicitly.

For detailed review ownership, state derivation and transitions, `docs/project/PROTOCOL.md` (REVIEW PROTOCOL V2) is authoritative.

## AI-to-AI disagreement and Owner escalation

Claude and the Reviewer are expected to resolve ordinary technical disagreements directly through the durable review artifacts before involving the Owner.

A temporary disagreement is not an Owner decision and must not be surfaced to the Owner merely because the agents initially reached different conclusions.

Before escalation, both sides must:

1. state the disputed claim precisely;
2. provide repository evidence, tests, code, documentation, live/operational evidence or a reproducible counterexample where applicable;
3. answer the other side's strongest technical argument;
4. attempt to derive the answer from existing architecture, safety rules, accepted project goals and observable behavior.

If evidence resolves the dispute, record the consensus in the existing REV/response/closure path and continue. Do not create a new REV solely because a discussion occurred.

Escalation to the Owner is allowed only for a genuinely irreducible Owner choice such as product/architecture direction between technically valid alternatives, priority/scope, accepted risk, intentional compatibility break, defer-versus-fix, or release/deployment timing.

Unresolved Owner choices are recorded concisely in `docs/project/OWNER-DECISIONS.md`. That file is an escalation queue, not review workflow state and never competes with `REVIEW_LEDGER.md`.

Do not escalate synchronization failures, wording disagreements, bookkeeping errors, or questions that can be decided by code/tests/evidence.

## Minimal-change / higher-layer-first rule

Implementation speed is valuable, but changes must preserve already-stabilized lower layers whenever the requested behavior can be implemented safely above them.

Before modifying a stable or frozen component, the implementer must briefly identify:

1. the contract that actually needs to change;
2. the higher layers that depend on that contract;
3. whether the requested behavior can be implemented at a higher layer without changing lower-layer semantics;
4. the smallest boundary that must be opened if a lower-layer change is genuinely necessary.

Prefer the highest layer that can correctly own the behavior. A lower-layer change is justified when the behavior originates there or cannot be exposed safely from above, but the change should remain as narrow as possible.

Do not combine a required change with opportunistic refactoring, cleanup, API redesign, renaming, or adjacent modernization. Such work requires a separate justification and reviewable delivery unless it is demonstrably necessary for the requested change.

When a frozen component must be reopened, preserve its existing behavioral contracts unless the Owner explicitly accepts a contract change. Tests must cover the changed boundary and dependency-driven consequences rather than merely proving the local implementation.

Observability features such as progress, status, metrics, or diagnostics should preferentially expose information from the existing execution path without changing the semantics of that path. In particular, adding transfer progress must not become an implicit redesign of snapshot selection, send/receive behavior, retention, SSH, or error handling.

This rule is not a presumption against implementation initiative. Its purpose is to keep implementation fast while making architectural blast radius explicit before code is changed.

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

### Owner-approved branch-protected mode

Active from **2026-08-14**. The Owner explicitly revoked the temporary direct-main
exception and approved both the transactional review publication core and GitHub
branch protection for `main`.

The normal workflow above is mandatory:

- every implementation, review publication and protocol change uses a short-lived
  branch and Pull Request;
- `main` advances only after the required graph/protocol verification succeeds;
- approval and closure remain two separate publication boundaries;
- ordinary work must not use administrator bypass, force-push or direct-main;
- auto-merge may be used after required checks and review conditions pass;
- phone operation is supported by automation around branches/PRs, not by weakening
  the canonical-state gate.

The GitHub branch-protection setting may lag this rule briefly while a signed-in
settings session is arranged. That is a deployment gap, not an extension of the
old exception: agents must follow branch/PR publication immediately.

Historical note: direct-main was temporarily authorised from 2026-07-29 through
2026-08-14 because four live test servers pulled `main` hourly and the Owner
operated the agents remotely from a smartphone. It was revoked after REV-120/121
proved that post-push CI can diagnose an inconsistent review transition but cannot
prevent its publication. The transition decision is recorded in
`docs/project/OWNER-DECISIONS.md`.

## Review artifacts and workflow state

Durable review communication lives under `docs/internal/reviews/`.

For V2, the authoritative specification is `docs/project/PROTOCOL.md`.

Canonical new artifacts:

- Reviewer finding/evidence: `docs/internal/reviews/REV-YYYYMMDD-NNN.md`
- Implementer response/evidence: `docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md`
- Reviewer closure fact: `docs/internal/reviews/closures/REV-YYYYMMDD-NNN.md`
- Current workflow state view: `docs/internal/reviews/REVIEW_LEDGER.md` (generated after V2 cutover)

New V2 artifact filenames carry no descriptive suffixes. A duplicate REV identity is a hard error even if filenames differ.

The implementer must not edit the reviewer's finding prose. Disagreement is recorded in the existing response file, with technical evidence. The reviewer must not silently rewrite the implementer's response.

Exactly four V2 workflow states exist:

- `OPEN`
- `IMPLEMENTED`
- `APPROVED`
- `CLOSED`

They are derived from canonical machine facts in the role-owned artifacts. Nobody manually assigns state in the generated ledger.

The only rejection transition is `IMPLEMENTED -> OPEN`. A genuinely new finding after approval receives a new REV; clarification or a second implementation attempt does not.

Terms such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` and `REJECTED` may be retained as evidence or resolution metadata but are not parallel workflow states.

After cutover, agents do not manually edit `REVIEW_LEDGER.md` or `OPEN-THREADS.md`; the latter is generated from the ledger.

Only the reviewer approves/closes a technical finding. Only the owner accepts operational risk or changes priority.

The normal mandatory pre-stage verification command is:

`./test/impact.sh --verify`

Protocol verification is included in that gate; normal operation must not depend on remembering a separate second verification command.

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
4. Run `./test/impact.sh --verify` for the final pre-stage consistency gate.
5. Record any unperformed manual obligation explicitly; never imply that a green local suite covers remote SSH, delegated accounts, destructive force-full paths, or live cron installation.
6. Do not use `--bless` merely to make golden tests pass. A fixture change must be reviewed as an intentional behavior change.

## Safety boundaries

- Treat pairing packages, INI files, manifests, dataset names, hostnames, and remote output as untrusted data unless the code proves otherwise.
- Data files must be parsed as data, not executed with `source`, `eval`, or an equivalent mechanism.
- Destructive ZFS operations require explicit scope, dry-run evidence where available, and a throwaway target for tests.
- Security checks must fail closed with a clear diagnostic. Do not silently fall back to a less secure behavior.
- Do not remove compatibility or safety guards as incidental cleanup.

## Documentation

Documentation is part of the contract. Any change to flags, defaults, configuration fields, deployment behavior, delegated permissions, or operational safety must update the relevant documentation and tests in the same delivery unit.