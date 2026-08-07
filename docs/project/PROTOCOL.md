# REVIEW PROTOCOL V2
## Claude + Reviewer + Owner workflow

Status: **AGREED DESIGN — implementation/cutover pending**

Date: 2026-08-07

This document consolidates:

- the Owner's REVIEW PROTOCOL V2 proposal;
- Claude's initial protocol proposal (`47a0af0`);
- Claude's amendments (`716bcd3`).

## Resolution of Claude's amendments

All three amendments are resolved.

**A — ACCEPTED.** `REVIEW_LEDGER.md` is generated, never typed. It remains the
single authoritative **current-state view**, while review/response/closure
artifacts contain the machine facts from which that state is deterministically
derived. Those artifacts are authoritative evidence/authorship records, not a
second current-state table.

**B — OPTION 2 SELECTED.** V2 keeps the Owner's four states:
`OPEN -> IMPLEMENTED -> APPROVED -> CLOSED`. `CLOSED` differs from `APPROVED`
by a real repository fact: a canonical closure artifact under `closures/`.
There is therefore no manually invented transition.

**C — ACCEPTED.** New V2 review and response filenames are fixed; duplicate REV
identities or descriptive-suffix duplicates are hard errors.

Also accepted:

- documentation-only findings normally receive a one-paragraph response;
- protocol verification is folded into `./test/impact.sh --verify`, so the
  normal pre-stage gate is one command, not two.

---

# Motivation

Current review quality is high, but the review process is inefficient.

Observed symptoms:

- duplicated reviews and follow-ups;
- two files for the same REV identity;
- uncertainty about the active REV;
- stale `PROJECT_STATUS.md` / `OPEN-THREADS.md`;
- contradictory routing and state prose;
- duplicated synchronization work;
- unnecessary token consumption.

The problem is not review quality. The problem is communication state being
represented in manually maintained prose and tables.

---

# Goals

The protocol shall guarantee:

- one authoritative current-state view;
- deterministic state derivation;
- no duplicated reviews;
- no duplicated responses;
- deterministic next-action ownership;
- machine-verifiable consistency;
- separate reviewer/implementer authorship;
- minimal process overhead.

---

# Principle 1 — Single Source Of Truth

Exactly one file is authoritative when a human or agent asks:

- What state is this REV in?
- Whose move is it?
- Which implementation commit is waiting for review?
- Which implementation commit did the reviewer actually verify?
- What is the next action?

That file is:

`docs/internal/reviews/REVIEW_LEDGER.md`

Nothing else is a current-state workflow table.

However, the ledger is **generated**. Nobody edits it manually.

The generation chain is:

```text
review / response / closure machine facts
                  |
                  v
        REVIEW_LEDGER.md
                  |
                  v
        OPEN-THREADS.md
```

This resolves the apparent tension between "one source of truth" and Claude's
correct observation that another hand-maintained ledger would only rename the
failure mode seen on 2026-08-07.

Review/response/closure files are evidence and authorship records. They contain
small machine fields so the state can be derived without reading prose.
They are not alternative current-state summaries.

`PROJECT_STATUS.md` is not workflow.

`OPEN-THREADS.md` is not workflow authority.

---

# Principle 2 — Review is a finite-state machine

Exactly four workflow states exist:

```text
OPEN
  |
  v
IMPLEMENTED
  |
  v
APPROVED
  |
  v
CLOSED
```

The only backward transition is:

```text
IMPLEMENTED -> OPEN
```

when the reviewer rejects the submitted implementation.

No hidden workflow states exist.

Words such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` or
`REJECTED` may exist as evidence/resolution metadata, but never as additional
FSM states.

---

# Principle 3 — Roles

## Claude — Implementer

Responsibilities:

- implement;
- provide exact evidence;
- maintain exactly one response file per REV;
- submit the exact implementation commit.

Never:

- approve own implementation;
- close a review;
- edit reviewer prose;
- edit generated ledger/routing files manually.

## Reviewer

Responsibilities:

- inspect the actual implementation diff;
- verify tests and live evidence;
- approve or reject;
- create a new REV only for a genuinely new finding;
- close an approved review;
- maintain reviewer-authored review metadata/prose.

Never:

- implement production code unless the Owner explicitly changes roles;
- rewrite Claude's response prose;
- guess the active REV from memory or the largest number;
- manually edit generated workflow views.

## Owner

Responsibilities:

- priorities;
- architecture/product decisions;
- accepted operational risk;
- deferred work;
- release/deployment decisions;
- decisions explicitly routed to Owner.

Owner silence is never approval or risk acceptance.

---

# Principle 4 — Canonical artifacts and filenames

New V2 files use fixed names only:

```text
docs/internal/reviews/REV-YYYYMMDD-NNN.md
docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md
docs/internal/reviews/closures/REV-YYYYMMDD-NNN.md
```

No descriptive suffixes.

The descriptive title belongs in H1 inside the file, not in the filename.

A duplicate `rev:` identity is a hard error even if filenames differ.

Exactly one response file exists per REV. Subsequent Claude updates extend that
same file.

Closure artifact is tiny machine/audit evidence, not another narrative response.

---

# Principle 5 — Machine facts, not prose parsing

The generator never decides workflow state from Polish or English sentences.
It consumes canonical fields.

## Reviewer file

Minimum machine header:

```text
<!-- rev: REV-20260807-064 -->
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: - -->
<!-- supersedes: - -->
```

Allowed reviewer verdicts are evidence values:

- `CHANGES-REQUIRED`
- `APPROVED`

`reviewed-implementation` names the exact implementation SHA for which that
verdict was issued.

## Implementer response

Minimum current machine header:

```text
<!-- rev: REV-20260807-064 -->
<!-- response-status: IMPLEMENTED -->
<!-- implementation: abcd1234 -->
```

Evidence-only response status may also express routing facts such as
`DISPUTED` or `NEEDS-OWNER`; these are not FSM states.

The implementation SHA, not prose saying "done", is the submission fact.

## Closure artifact

Minimum:

```text
<!-- rev: REV-20260807-064 -->
<!-- closed-by: <reviewer-commit-sha> -->
```

`CLOSED` therefore differs from `APPROVED` by an objective file fact, as Claude
required.

---

# Principle 6 — Deterministic state derivation

The generator derives state in this order.

## CLOSED

A valid canonical closure artifact exists for the REV and references reviewer
approval evidence.

## APPROVED

No closure artifact exists, and:

- reviewer verdict is `APPROVED`;
- `reviewed-implementation` equals the current response `implementation` SHA.

## IMPLEMENTED

No closure artifact exists, and a current implementation SHA exists that has
not yet received a reviewer verdict for that same SHA.

Concrete rule:

```text
response.implementation != review.reviewed-implementation
```

## OPEN

All other valid nonclosed cases, including:

- new review with no implementation yet;
- reviewer rejected the current implementation;
- dispute/clarification awaiting Reviewer or Owner.

This model makes rejection deterministic without editing Claude's response:

```text
Claude submits sha1
  response implementation = sha1
  reviewer reviewed-implementation = -
  => IMPLEMENTED

Reviewer rejects sha1
  verdict = CHANGES-REQUIRED
  reviewed-implementation = sha1
  => OPEN

Claude submits sha2 in the SAME response file
  response implementation = sha2
  reviewed-implementation = sha1
  => IMPLEMENTED

Reviewer approves sha2
  verdict = APPROVED
  reviewed-implementation = sha2
  => APPROVED

Reviewer creates closure artifact
  => CLOSED
```

No manually assigned state token is needed in the source artifacts.

---

# Principle 7 — Deterministic next owner

The ledger also derives exactly one next owner.

Default mapping:

```text
OPEN, no special routing       -> Claude
IMPLEMENTED                    -> Reviewer
APPROVED                       -> Reviewer   # closure action
CLOSED                         -> -
```

An explicit machine routing fact may override `OPEN` only for legitimate
nonimplementation work:

- dispute needing reviewer resolution -> `Reviewer`;
- architecture/risk decision -> `Owner`.

There is never more than one next owner.

Generated rows with missing or duplicated ownership are invalid.

---

# Principle 8 — Never guess active review

Normal reviewer procedure begins with one external gate:

```text
./test/impact.sh --verify
```

That gate includes protocol verification.

Then inspect the generated ledger:

```text
reviewctl list --state OPEN
reviewctl list --state IMPLEMENTED
```

(or equivalent read-only commands).

Review exactly the implementation SHA named by the generated state.

Never infer active work from:

- chat memory;
- the highest REV number;
- latest `main`;
- `PROJECT_STATUS.md`;
- `OPEN-THREADS.md`.

---

# Principle 9 — One response and one follow-up rule

A new REV is created only when a **new finding** appears.

Never create a new REV because:

- wording changed;
- evidence was added;
- documentation was clarified;
- the same acceptance criterion remains unmet;
- implementation needs another attempt.

Those remain in the existing REV and the same response file.

Rejected implementation is:

```text
IMPLEMENTED -> OPEN
```

and the same REV continues.

A genuinely new finding after approval creates a new REV. The old approved REV
is not mutated back to `IMPLEMENTED`.

---

# Principle 10 — PROJECT_STATUS

`PROJECT_STATUS.md` describes project/product/operational state only.

It never defines:

- current review state;
- next review owner;
- active REV routing;
- reviewer approval.

It may reference reviews as evidence/history.

Existing project-status freshness logic remains an independent production/project
consistency check inside `impact.sh --verify`.

---

# Principle 11 — OPEN-THREADS is generated

`docs/project/OPEN-THREADS.md` is generated from `REVIEW_LEDGER.md`.

Nobody edits it manually after V2 cutover.

If regenerated output differs from the committed file, verification fails.

No prose inference is allowed.

---

# Principle 12 — Verification is one external gate

The normal mandatory command before a stage is:

```text
./test/impact.sh --verify
```

It invokes protocol generation/verification internally.

`reviewctl verify` may exist as a focused developer/test command, but agents are
not required to remember two independent pre-stage gates.

The protocol verifier performs this conceptually as one operation:

1. parse canonical machine facts fail-closed;
2. reject duplicate/orphan/noncanonical artifacts;
3. generate the expected ledger deterministically;
4. compare it byte-for-byte with committed `REVIEW_LEDGER.md`;
5. generate expected routing and compare with committed `OPEN-THREADS.md`.

The following conditions therefore fail as part of generation or comparison,
not as a growing pile of prose-specific checkers:

- duplicate REV;
- duplicate response;
- noncanonical new filename;
- orphan response/closure;
- malformed machine fields;
- missing/invalid implementation SHA where required;
- approval for a different implementation SHA;
- closure without approval evidence;
- impossible derived ownership;
- stale ledger;
- stale routing.

Parser errors, missing dependencies and malformed rows fail closed. They never
produce a silent PASS.

---

# Principle 13 — Legal lifecycle facts

The derived lifecycle permits only:

```text
OPEN -> IMPLEMENTED
IMPLEMENTED -> OPEN
IMPLEMENTED -> APPROVED
APPROVED -> CLOSED
```

A source-artifact edit that would derive an impossible lifecycle is rejected.

No:

```text
APPROVED -> IMPLEMENTED
CLOSED -> OPEN
CLOSED -> IMPLEMENTED
OPEN -> CLOSED
```

Historical repair requires an explicit migration/repair mechanism and an
auditable forward commit.

---

# Principle 14 — reviewctl manages artifacts transactionally

Representative commands:

```text
reviewctl open REV-20260807-065 --review docs/internal/reviews/REV-20260807-065.md
reviewctl implement REV-20260807-065 --response docs/internal/reviews/responses/REV-20260807-065.md --sha <implementation-sha>
reviewctl reject REV-20260807-065 --sha <implementation-sha>
reviewctl approve REV-20260807-065 --sha <implementation-sha>
reviewctl close REV-20260807-065
reviewctl show REV-20260807-065
reviewctl list --state IMPLEMENTED
```

Exact CLI spelling may change.

The invariant does not: a command modifies only the calling role's canonical
artifact(s), regenerates derived views, and verifies before completion.

`reviewctl close` creates the canonical closure fact. It does not merely type
`CLOSED` into a table.

---

# Principle 15 — Evidence requirements remain unchanged

V2 changes coordination, not review quality.

Still required where applicable:

- contract + required tests before implementation;
- actual diff inspection;
- negative controls with both changed and unchanged case counts;
- `test/impact.sh` obligations;
- real-host proof;
- delegated-account proof for account/permission/crontab paths;
- exact test commands/results;
- explicit tests not run;
- no silent fixture blessing or weakened safety checks.

---

# Principle 16 — Lightweight documentation/process findings

Documentation-only findings normally receive a concise one-paragraph response,
not another design document.

A finding exclusively about the review protocol does not recursively create a
full REV cycle unless it exposes product/release risk. Record it as a compact
protocol note/decision and amend this document explicitly.

This adopts Claude's token-cost observation and prevents reviews about reviews
from becoming the dominant workload.

---

# Principle 17 — Runtime isolation

Protocol tooling manages communication artifacts only.

It must not:

- modify production configuration;
- alter cron blocks;
- change ZFS state;
- deploy code;
- weaken safety policy;
- treat workflow consistency as proof that production behavior is correct.

Protocol correctness and product correctness are separate gates.

---

# Migration from legacy workflow

Cut over deliberately; do not mix models indefinitely.

1. Inventory existing REV, response and closure artifacts.
2. Detect duplicate IDs and descriptive-suffix duplicates.
3. Parse legacy state only in a migration tool; production V2 generator never
   guesses legacy prose.
4. Resolve ambiguous legacy mappings explicitly.
5. Generate the initial `REVIEW_LEDGER.md` from canonicalized facts.
6. Freeze legacy filenames; do not rename history merely for aesthetics.
7. Require canonical fixed names for every new V2 REV.
8. Generate `OPEN-THREADS.md` from the ledger.
9. Remove obsolete `ledger_coherence`, review-head and other checkers whose
   only job was policing manually maintained review prose/tables.
10. Keep independent `impact.sh` project/production checks.
11. Make `impact.sh --verify` invoke V2 protocol verification.
12. Update any remaining documentation that says `OPEN-THREADS.md` is manually
   edited or defines a competing state list.
13. Run positive and negative controls against real legacy drift cases.

Legacy state mapping for migration only:

```text
OPEN / ACCEPTED / DISPUTED / NEEDS-DISCUSSION -> OPEN + explicit route
IMPLEMENTED                                   -> IMPLEMENTED
reviewer-verified, not archived               -> APPROVED
CLOSED / DONE                                 -> CLOSED
DEFERRED / withdrawn / accepted-risk          -> CLOSED + resolution metadata
```

---

# Minimum acceptance matrix

| Case | Expected |
|---|---|
| canonical new review, no response | OPEN |
| response submits sha1, reviewer has not reviewed sha1 | IMPLEMENTED |
| reviewer rejects sha1 | OPEN |
| same response advances to sha2 | IMPLEMENTED |
| reviewer approves sha2 | APPROVED |
| valid closure artifact after approval | CLOSED |
| closure without matching approval | FAIL |
| approval for sha1 while response current sha is sha2 | FAIL / not APPROVED |
| duplicate review ID | FAIL |
| duplicate response ID | FAIL |
| descriptive-suffix duplicate for new V2 REV | FAIL |
| orphan response | FAIL |
| orphan closure | FAIL |
| malformed machine header | FAIL closed |
| regenerated ledger differs from committed ledger | FAIL |
| regenerated OPEN-THREADS differs from committed file | FAIL |

Negative controls must include at least one real state accepted by the old
mechanism and rejected by V2.

---

# Expected result

The protocol eliminates:

- duplicated reviews;
- duplicated responses/follow-ups;
- uncertainty about ownership;
- stale workflow documents;
- contradictory state models;
- repeated synchronization;
- unnecessary token consumption.

The normal loop becomes:

```text
./test/impact.sh --verify
    -> read generated REVIEW_LEDGER
    -> act only on work routed to your role
    -> update exactly one role-owned durable artifact
    -> regenerate REVIEW_LEDGER + OPEN-THREADS
    -> ./test/impact.sh --verify
```

Claude, Reviewer and Owner then cooperate from deterministic repository facts,
not from chat memory.