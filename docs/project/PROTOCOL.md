# REVIEW PROTOCOL V2
## Claude + Reviewer + Owner workflow

Status: **CONSOLIDATED PROPOSAL — implementation pending**

Date: 2026-08-07

This document consolidates the Owner proposal with the implementer proposal in
commit `47a0af0`.

The design choice is explicit:

- the Owner requirement is preserved: **exactly one authoritative store of
  current review workflow state**;
- Claude's root-cause analysis is preserved: **that state must not be
  hand-maintained prose**.

Therefore `REVIEW_LEDGER.md` is authoritative for current state and routing,
but humans do not edit it directly. `reviewctl` is the only writer.
Review/response files are durable evidence and authorship records; they do not
constitute a second workflow-state authority.

---

# Motivation

Current review quality is high, but the review process is still inefficient.

Symptoms observed on 2026-08-07 include:

- duplicated reviews;
- duplicated follow-ups;
- two files for the same REV identity;
- uncertainty which REV is currently active;
- stale `PROJECT_STATUS.md` / `OPEN-THREADS.md`;
- contradictory routing and state prose;
- reviewers spending time synchronizing instead of reviewing;
- unnecessary token consumption.

The problem is not review quality. The problem is the communication protocol
and manual maintenance of derived coordination state.

---

# Goals

The protocol shall guarantee:

- one source of truth for current review state;
- deterministic workflow;
- no duplicated reviews;
- no duplicated responses;
- deterministic ownership of the next action;
- machine-verifiable consistency;
- preserved authorship boundaries between implementer and reviewer;
- minimal process overhead for documentation-only and process-only findings.

---

# Principle 1 — Single Source Of Truth

Exactly one file defines **current review workflow state**:

`docs/internal/reviews/REVIEW_LEDGER.md`

Nothing else is authoritative for the questions:

- What state is this REV in?
- Whose move is it?
- Which implementation commit is under review?
- Which reviewer commit/verdict applies?
- What is the next action?

`PROJECT_STATUS.md` is not workflow state.

`OPEN-THREADS.md` is not workflow state.

Review files and response files are evidence and durable communication. They
may contain machine identity/evidence fields, but their prose must never be
parsed to infer current workflow state.

## Important implementation rule

`REVIEW_LEDGER.md` is **machine-owned**.

Humans and agents do not edit ledger rows manually. All state changes are made
through `reviewctl` (or an equivalent transactional tool). This adopts Claude's
central observation: a hand-maintained derived table with checkers bolted onto
it will drift again.

---

# Principle 2 — Review is a finite-state machine

Exactly these workflow states exist:

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

No hidden workflow states exist.

Terms such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` or
`REJECTED` may appear as evidence/resolution metadata, but they are **not FSM
states** in V2.

Examples:

- implementer disputes a finding -> state remains `OPEN`, next owner is
  `Reviewer` or `Owner` as explicitly routed;
- owner defers accepted work -> review is eventually `CLOSED` with resolution
  metadata `deferred`, not a fifth FSM state;
- reviewer rejects an implementation -> legal transition `IMPLEMENTED -> OPEN`.

---

# Principle 3 — Roles

## Claude — Implementer

Responsibilities:

- implement accepted work;
- provide exact evidence;
- maintain exactly one response file per REV;
- announce the exact implementation commit through `reviewctl implement`.

Never:

- approve own implementation;
- close a review;
- edit the reviewer's finding text;
- manually edit `REVIEW_LEDGER.md` or generated routing views.

## Reviewer

Responsibilities:

- inspect the actual diff and evidence;
- approve or reject the implementation;
- create a new REV only for a genuinely new finding;
- close an approved review;
- maintain reviewer-authored review text.

Never:

- implement production code unless the Owner explicitly changes roles for the
  task;
- edit Claude's response prose;
- infer active work from memory or from the highest REV number;
- manually edit generated routing views.

## Owner

Responsibilities:

- priorities;
- architecture and product direction;
- accepted operational risk;
- deferred work;
- deployment/release decisions;
- resolving items explicitly routed to `Owner`.

Owner silence is never interpreted as approval or risk acceptance.

---

# Principle 4 — REVIEW_LEDGER schema

Each REV has exactly one ledger record containing at least:

```text
REV
state
owner
review_path
response_path
implementation_commit
review_commit
supersedes
next_action
resolution
```

Example:

```text
REV: REV-20260807-064
state: IMPLEMENTED
owner: Reviewer
review_path: docs/internal/reviews/REV-20260807-064.md
response_path: docs/internal/reviews/responses/REV-20260807-064.md
implementation_commit: abcd1234
review_commit: -
supersedes: -
next_action: Reviewer verification
resolution: -
```

Canonical state and owner tokens are parsed as tokens, never inferred from
Polish or English prose.

Allowed owners are:

- `Claude`
- `Reviewer`
- `Owner`
- `-` only when no next action exists.

Minimum invariants:

- `OPEN` must name a next owner;
- `IMPLEMENTED` must have `owner=Reviewer`, a response path and an
  implementation commit;
- `APPROVED` must have a reviewer verdict/review commit;
- `CLOSED` must have `owner=-` and no next action;
- one REV identity may occur only once in the ledger.

---

# Principle 5 — Never guess active review

Every review stage starts with:

```text
reviewctl verify
reviewctl list --state OPEN
reviewctl list --state IMPLEMENTED
```

The reviewer then verifies only the implementation commit named in the ledger.

Never:

- infer the active review from chat memory;
- assume the latest REV number is active;
- assume `main` is the implementation that was submitted;
- use `PROJECT_STATUS.md` or `OPEN-THREADS.md` to decide whose move it is.

---

# Principle 6 — One review file and one response file

Canonical filenames are fixed:

```text
docs/internal/reviews/REV-YYYYMMDD-NNN.md
docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md
```

No descriptive suffixes are allowed in V2.

Do not create:

```text
REV-...-response2.md
REV-...-final.md
REV-...-followup.md
REV-...-fixed.md
```

Subsequent implementer updates extend the same response file.

A duplicate REV identity or noncanonical filename is a hard verification error.
This directly addresses the duplicate-REV failure seen on 2026-08-07.

## Machine identity/evidence fields

Review and response files carry small machine headers so `reviewctl verify` can
check identity and evidence without interpreting prose.

Reviewer file, minimum:

```text
<!-- rev: REV-20260807-064 -->
<!-- verdict: CHANGES-REQUIRED -->
<!-- supersedes: - -->
```

Implementer response, minimum:

```text
<!-- rev: REV-20260807-064 -->
<!-- implementation: abcd1234 -->
```

On approval the reviewer records an explicit approval/review commit through
`reviewctl approve`. The ledger remains the authority for current state.

---

# Principle 7 — One follow-up rule

A new REV is created only when a **new finding** appears.

Do not create a new REV because:

- wording changed;
- documentation was clarified;
- evidence was added;
- the same acceptance criterion is still unmet;
- the same implementation needs a second attempt.

Those remain in the existing REV and existing response file.

If an implementation fails verification:

```text
IMPLEMENTED -> OPEN
```

The same REV continues.

If a genuinely new finding appears after approval, create a new REV and link
it through `supersedes` or an explicit reference. Do not mutate the approved
REV back to `IMPLEMENTED`.

---

# Principle 8 — PROJECT_STATUS

`PROJECT_STATUS.md` describes **project/product/operational state**.

It must not define:

- current review state;
- next review owner;
- active REV routing;
- whether a reviewer has approved an implementation.

It may reference reviews as historical evidence.

Existing freshness checks for project status remain useful. `reviewctl verify`
may invoke or aggregate the existing `impact.sh --verify` freshness check, but
must not duplicate its logic in prose.

---

# Principle 9 — OPEN-THREADS is generated

`docs/project/OPEN-THREADS.md` is a generated human routing view of
`REVIEW_LEDGER.md`.

Nobody edits it manually.

Generation is deterministic. If the committed file differs from the generated
form, verification fails.

The generator must never infer status from prose. It reads canonical ledger
fields only.

Owner-only routing may be presented as a filtered generated view, but must not
create a second manually maintained review-state store.

---

# Principle 10 — Mandatory verification

Every stage starts with:

```text
reviewctl verify
```

Verification fails closed on at least:

- orphan REV file;
- orphan response file;
- duplicate REV identity;
- duplicate/noncanonical filename;
- missing response for `IMPLEMENTED`;
- missing implementation commit;
- implementation commit that does not exist;
- missing reviewer commit/verdict for `APPROVED`;
- impossible state transition;
- illegal/missing next owner;
- stale generated `OPEN-THREADS.md`;
- ledger/artifact identity mismatch;
- stale project-status obligation reported by the existing freshness mechanism;
- ambiguous legacy state during migration.

A parser error, missing dependency or malformed row is a verification failure,
never a silent PASS.

The transition checker compares the proposed state with the state committed in
the parent revision so illegal transitions cannot be hidden by editing the
current table.

---

# Principle 11 — Legal state transitions

Only these transitions are legal:

```text
OPEN -> IMPLEMENTED
IMPLEMENTED -> APPROVED
APPROVED -> CLOSED
IMPLEMENTED -> OPEN       # reviewer rejected implementation
```

Creation starts at `OPEN`.

A new finding after approval creates a **NEW REV**.

Not legal:

```text
APPROVED -> IMPLEMENTED
CLOSED -> OPEN
CLOSED -> IMPLEMENTED
OPEN -> CLOSED
```

Any historical correction requires an explicit migration/repair command and an
auditable commit; never a silent ledger edit.

---

# Principle 12 — reviewctl owns transitions

Representative commands:

```text
reviewctl open REV-20260807-065 --review docs/internal/reviews/REV-20260807-065.md
reviewctl implement REV-20260807-065 --response docs/internal/reviews/responses/REV-20260807-065.md --sha <implementation-sha>
reviewctl reject REV-20260807-065 --review-sha <review-sha>
reviewctl approve REV-20260807-065 --review-sha <review-sha>
reviewctl close REV-20260807-065
reviewctl verify
reviewctl show REV-20260807-065
reviewctl list --state IMPLEMENTED
```

Exact CLI spelling may change during implementation. The invariants may not.

`reviewctl` performs a transition transactionally: validate -> update ledger ->
regenerate derived views -> verify. A failed step leaves no partially updated
workflow state.

---

# Principle 13 — Evidence requirements remain unchanged

This protocol changes communication/state management, not production review
quality.

The existing requirements remain:

- contract and required tests before implementation where the project plan
  requires it;
- actual diff inspection;
- negative controls with both changed and unchanged case counts;
- `test/impact.sh` obligations;
- live proof on the relevant real environment;
- delegated-account proof for account/permission/crontab paths;
- explicit reporting of tests not run;
- no silent fixture blessing or weakening of safety checks.

---

# Principle 14 — Lightweight documentation/process findings

Claude's process-cost observation is adopted.

A documentation-only finding that does not alter product behavior still uses
the existing REV when one already exists, but the implementer response should
normally be one concise paragraph rather than a second design document.

A finding exclusively about this communication protocol does **not** create a
full recursive REV cycle unless it exposes a production/release risk. Record it
compactly in `PROTOCOL-NOTES` (or the future equivalent) and amend this protocol
through an explicit owner/reviewer decision.

This prevents reviews about reviews from consuming the same process as product
findings.

---

# Principle 15 — Runtime isolation

The review protocol must never modify production behavior.

`reviewctl` may manage only review communication/state artifacts and generated
routing views. It must not:

- edit production configuration;
- modify cron blocks;
- change ZFS state;
- deploy code;
- alter safety policy;
- mark implementation evidence as valid merely because workflow files are
  consistent.

Workflow consistency and product correctness remain separate gates.

---

# Migration from the legacy protocol

V2 must be introduced as a deliberate cutover, not by gradually mixing state
models.

1. Inventory all existing `REV-*`, response and closure artifacts.
2. Detect duplicate REV identities and noncanonical filenames.
3. Build the initial `REVIEW_LEDGER.md` once from the current known state, with
   every ambiguous mapping reported for explicit reviewer/owner resolution.
4. Map legacy states deterministically:
   - legacy `OPEN`, `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION` -> V2 `OPEN`
     with explicit next owner;
   - legacy `IMPLEMENTED` -> V2 `IMPLEMENTED`;
   - reviewer-verified but not archived -> V2 `APPROVED`;
   - legacy `CLOSED`/`DONE` -> V2 `CLOSED`;
   - `DEFERRED`, withdrawn findings and accepted-risk cases -> `CLOSED` with
     resolution metadata preserving the reason.
5. Freeze legacy artifact names. Do not rename historical files merely for
   aesthetics; record aliases/migration exceptions where necessary.
6. From the cutover commit onward, require canonical V2 filenames for new REVs.
7. Generate `OPEN-THREADS.md` from the ledger.
8. Replace old prose/ledger routing checkers with `reviewctl verify`; retain only
   independent production checks such as `impact.sh`.
9. Update `docs/internal/reviews/README.md` and `docs/AI_PROJECT_RULES.md` so
   they point to V2 and do not define competing state lists.
10. Run positive and negative controls proving that legacy drift accepted by the
    old mechanism is rejected by V2.

---

# Acceptance matrix for reviewctl

At minimum the automated tests must prove:

| Case | Expected |
|---|---|
| `OPEN` + valid next owner | PASS |
| `OPEN` + owner `-` | FAIL |
| `IMPLEMENTED` + response + real implementation SHA + Reviewer owner | PASS |
| `IMPLEMENTED` + missing response | FAIL |
| `IMPLEMENTED` + missing/invalid SHA | FAIL |
| `APPROVED` + reviewer commit | PASS |
| `APPROVED` without reviewer evidence | FAIL |
| `CLOSED` + owner `-` | PASS |
| `CLOSED` + routed owner | FAIL |
| duplicate REV identity | FAIL |
| second response filename for same REV | FAIL |
| noncanonical new V2 filename | FAIL |
| `IMPLEMENTED -> OPEN` | PASS |
| `APPROVED -> IMPLEMENTED` | FAIL |
| generated OPEN-THREADS differs from committed copy | FAIL |
| malformed parser input | FAIL closed |

Negative controls must demonstrate that at least one real legacy-bug state is
accepted by the old mechanism and rejected by V2.

---

# Expected result

This protocol should eliminate:

- duplicated reviews;
- duplicated follow-ups;
- uncertainty about ownership;
- stale workflow documents;
- contradictory state models;
- unnecessary synchronization;
- unnecessary token consumption.

The intended working loop becomes:

```text
reviewctl verify
    -> read ledger
    -> act only on rows owned by your role
    -> write/extend exactly one durable artifact
    -> perform one legal reviewctl transition
    -> regenerate routing
    -> reviewctl verify
```

Claude, Reviewer and Owner can then cooperate deterministically without using
chat memory as project state.