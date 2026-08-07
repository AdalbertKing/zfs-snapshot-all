# Review exchange protocol

This directory is the durable communication channel between the reviewer and
implementer.

The authoritative workflow specification is:

`docs/project/PROTOCOL.md` — **REVIEW PROTOCOL V2**.

If this README and `PROTOCOL.md` disagree about state, routing, ownership,
filenames or transitions, `PROTOCOL.md` wins.

## V2 authority model

Current review workflow state belongs in exactly one machine-owned file:

`docs/internal/reviews/REVIEW_LEDGER.md`

Humans and agents do not edit ledger rows manually. State transitions are made
through `reviewctl` (or the equivalent implementation defined by Protocol V2).

Review and response files are durable evidence and preserve separate
authorship. They are not a second authority for current workflow state.

`docs/project/OPEN-THREADS.md` is a generated routing view and is never edited
manually after the V2 cutover.

## Artifact layout

```text
docs/internal/reviews/
├── README.md
├── REVIEW_LEDGER.md                 # machine-owned workflow state
├── REV-YYYYMMDD-NNN.md              # reviewer evidence
├── responses/
│   └── REV-YYYYMMDD-NNN.md          # implementer evidence; exactly one
└── closures/
    └── REV-YYYYMMDD-NNN.md          # legacy/optional closure evidence
```

For new V2 reviews, filenames are canonical and carry no descriptive suffixes.
Legacy files are not renamed merely for aesthetics; migration records any
required aliases/exceptions.

- `REV-*.md` is written and maintained by the reviewer.
- `responses/REV-*.md` is written and maintained by the implementer.
- the reviewer must not rewrite the implementer's response prose;
- the implementer must not rewrite the reviewer's finding prose;
- a second response file for the same REV is prohibited.

## V2 finite-state machine

Exactly four workflow states exist:

```text
OPEN -> IMPLEMENTED -> APPROVED -> CLOSED
             |
             +----------> OPEN     # rejected implementation
```

No other word is a workflow state.

`ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED`, `REJECTED` and similar
terms may survive as evidence/resolution metadata only. They do not create
parallel state machines.

Only the reviewer approves or closes technical findings. Only the owner accepts
operational risk or changes project priority.

## Normal V2 loop

Before acting, every participant runs:

```text
reviewctl verify
```

The reviewer additionally lists `OPEN` and `IMPLEMENTED` work and acts only on
the exact implementation SHA recorded in the ledger.

Representative lifecycle:

1. Reviewer publishes `REV-YYYYMMDD-NNN.md` and opens the ledger record.
2. Claude extends/creates exactly one matching response file and submits an
   implementation SHA.
3. `reviewctl implement` transitions `OPEN -> IMPLEMENTED` and routes to
   Reviewer.
4. Reviewer verifies the actual diff, tests and required live evidence.
5. Failed verification transitions `IMPLEMENTED -> OPEN`; the same REV and
   response file continue.
6. Successful verification transitions `IMPLEMENTED -> APPROVED`.
7. Reviewer closes the approved REV: `APPROVED -> CLOSED`.
8. A genuinely new finding after approval receives a new REV; clarification or
   another attempt on the same finding does not.

Never infer the active review from chat memory, the largest REV number,
`PROJECT_STATUS.md`, or `OPEN-THREADS.md`.

## Finding content

A product finding should still record:

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

Do not encode workflow state in free-form finding prose. The ledger owns that.

## Required reviewer verification

The reviewer inspects:

- the actual diff, not only the summary;
- regression tests and whether they fail on old behavior;
- `test/impact.sh` obligations;
- compatibility and security regressions;
- documentation changes;
- evidence for remote, non-root, ZFS, destructive and live-cron paths.

The implementation PR/commit evidence must contain exact test commands and
results. Tests not run must be stated explicitly.

## Severity

- **P0 — critical blocker:** credible path to root compromise, data loss,
  destructive mis-targeting, or a backup mechanism that cannot be trusted.
- **P1 — high:** likely operational failure, broken security promise, corrupted
  state, or unsafe release process.
- **P2 — medium:** important maintainability, test, CI, or documentation defect
  that increases future failure probability.
- **P3 — low:** cleanup or clarity issue with limited immediate impact.

Each finding may also declare `Blocking: yes|no|owner-decision`; severity and
release policy are related but not identical.

## Discussion rule

PR comments remain suitable for short questions and line references. Any
conclusion that changes interpretation, acceptance criteria, severity,
blocking status, accepted risk or implementation evidence must survive in the
canonical review/response artifacts and be reflected through a legal
`reviewctl` transition where workflow state changes.

Documentation-only responses should be concise. Findings exclusively about the
communication protocol should not recursively create full REV cycles unless
they expose a product/release risk; follow `docs/project/PROTOCOL.md`.