# Review exchange protocol

This directory is the durable communication channel between the reviewer and
implementer.

The authoritative workflow specification is:

`docs/project/PROTOCOL.md` — **REVIEW PROTOCOL V2**.

If this README and `PROTOCOL.md` disagree about state, routing, ownership,
filenames or transitions, `PROTOCOL.md` wins.

## V2 authority model

Current review workflow state is read from exactly one generated view:

`docs/internal/reviews/REVIEW_LEDGER.md`

Nobody edits ledger rows manually.

The ledger is generated deterministically from small machine facts in the
role-owned review, response and closure artifacts. Those files preserve
evidence and authorship; they are not competing current-state tables.

`docs/project/OPEN-THREADS.md` is generated from the ledger and is never edited
manually after V2 cutover.

## Work pickup / handoff

Handoff has two symmetric halves: the publisher must complete canonical
publication, and the recipient must refresh and read it.

For the publisher, a role branch or Pull Request is not a handoff — including a
green and mergeable PR. Publication is complete only after the PR is merged and
a fresh read of `main` shows both the intended artifact and the expected ledger
row/state/next owner. If that read-back has not succeeded, report `PR open — not
published, no handoff yet`; never report `published`, `submitted`, `routed`, or
`handed off`.

For the recipient, routing is only useful if the next agent actually refreshes
and reads it. Therefore **before either agent says it has no work / nothing from
the other agent**, it must refresh the published `main` and inspect the generated
`REVIEW_LEDGER.md`.

For Claude specifically:

- any fresh ledger row `OPEN | Claude` is an actionable reviewer handoff;
- Claude opens the matching reviewer-owned `REV-YYYYMMDD-NNN.md` and continues
  that same REV;
- a reviewer rejection normally leaves Claude's existing response header and
  prose untouched, so an old response that still says `IMPLEMENTED` or asks for
  reviewer input is not evidence that Claude should wait;
- `IMPLEMENTED | Reviewer` means Claude has submitted and should wait for
  review; `APPROVED | Reviewer` means closure is the reviewer's move;
- Claude must not report "nothing from Reviewer" while a fresh ledger row is
  `OPEN | Claude`.

For the Reviewer, the symmetric rule applies: fresh `IMPLEMENTED | Reviewer`
means there is an exact submitted SHA to review.

This is a **pickup rule**, not a second inbox or state model. Do not create a
parallel handoff table. `OPEN-THREADS.md` remains convenience-only and
`PROJECT_STATUS.md` remains product/operational state, never workflow routing.

## Artifact layout

```text
docs/internal/reviews/
├── README.md
├── REVIEW_LEDGER.md                 # generated current-state view
├── REV-YYYYMMDD-NNN.md              # reviewer evidence + machine facts
├── responses/
│   └── REV-YYYYMMDD-NNN.md          # implementer evidence; exactly one
└── closures/
    └── REV-YYYYMMDD-NNN.md          # tiny reviewer closure fact
```

For new V2 reviews, filenames are canonical and carry no descriptive suffixes.
A duplicate `rev:` identity is a hard error even if two filenames differ.
Legacy files are not renamed merely for aesthetics; migration records required
exceptions.

- Reviewer maintains reviewer files.
- Claude maintains implementer response files.
- Reviewer must not rewrite implementer response prose.
- Implementer must not rewrite reviewer finding prose.
- Subsequent implementation attempts extend the same response file.

## V2 finite-state machine

Exactly four workflow states exist:

```text
OPEN -> IMPLEMENTED -> APPROVED -> CLOSED
             |
             +----------> OPEN     # reviewer rejected submitted SHA
```

Each state is derived from repository facts; nobody types the state into a
manual routing table.

In outline:

- new review/no unreviewed implementation -> `OPEN`;
- response implementation SHA differs from reviewer's
  `reviewed-implementation` -> `IMPLEMENTED`;
- reviewer verdict `APPROVED` applies to the current response SHA -> `APPROVED`;
- valid canonical closure artifact exists for that approval -> `CLOSED`.

Terms such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` and
`REJECTED` may exist as evidence/resolution metadata only.

## Normal V2 loop

The single normal pre-stage gate is:

```text
./test/impact.sh --verify
```

Protocol verification is invoked from that gate. A focused `reviewctl verify`
may exist for development/testing, but normal operation must not depend on
remembering two independent verification commands.

Representative lifecycle:

1. Reviewer merges the canonical `REV-YYYYMMDD-NNN.md` publication and reads
   back `OPEN | Claude` from the ledger on `main`; only then is it handed off.
2. Claude creates/extends exactly one matching response and submits an exact
   implementation SHA.
3. Generated ledger shows `IMPLEMENTED`, owner `Reviewer`.
4. Reviewer verifies the actual SHA, tests and required live evidence.
5. Rejection records `CHANGES-REQUIRED` for that SHA; generated state becomes
   `OPEN` and the same REV continues.
6. Claude picks up that `OPEN | Claude` row from a fresh ledger read, opens the
   current reviewer file, and continues the same response with the next SHA.
7. A new implementation SHA in the same response makes state `IMPLEMENTED`
   again.
8. Reviewer approval for the current SHA makes state `APPROVED`.
9. Reviewer creates the canonical closure fact; state becomes `CLOSED`.
10. A genuinely new finding after approval receives a new REV; clarification or
    another attempt on the same finding does not.

Never infer the active review from chat memory, the largest REV number,
`PROJECT_STATUS.md`, or `OPEN-THREADS.md`.

## Finding content

A product finding should record:

```markdown
## F1 — Title

- Severity: P1
- Blocking: yes
- Affected: `file.sh`, function or line range

### Evidence
...

### Failure mode
...

### Required outcome
...

### Acceptance criteria
- [ ] ...

### Required verification
- automated:
- manual:

### Notes and uncertainty
...
```

Do not encode current workflow state in free-form finding prose.

## Required reviewer verification

The reviewer inspects:

- the actual diff, not only the summary;
- regression tests and whether they fail on old behavior;
- `test/impact.sh` obligations;
- compatibility and security regressions;
- documentation changes;
- evidence for remote, non-root, ZFS, destructive and live-cron paths.

Implementation evidence must contain exact test commands and results. Tests not
run must be stated explicitly.

## Severity

- **P0 — critical blocker:** credible path to root compromise, data loss,
  destructive mis-targeting, or an untrustworthy backup mechanism.
- **P1 — high:** likely operational failure, broken security promise, corrupted
  state, or unsafe release process.
- **P2 — medium:** important maintainability, test, CI, or documentation defect
  that increases future failure probability.
- **P3 — low:** cleanup or clarity issue with limited immediate impact.

A finding may also declare `Blocking: yes|no|owner-decision`; severity and
release policy are related but not identical.

## Discussion rule

PR comments remain suitable for short questions and line references. Any
conclusion that changes interpretation, acceptance criteria, severity,
blocking status, accepted risk, reviewer verdict or implementation evidence
must survive in the appropriate role-owned artifact.

Documentation-only responses should normally be one concise paragraph.
Protocol-only process notes should not recursively create full REV cycles unless
they expose product/release risk; follow `docs/project/PROTOCOL.md`.
