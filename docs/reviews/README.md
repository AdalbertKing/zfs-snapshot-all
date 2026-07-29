# Review exchange protocol

This directory is the durable communication channel between the reviewer and implementer.
GitHub Pull Requests remain the place for line-level review, but decisions must survive outside a chat session and therefore belong in these Markdown files.

## Artifact layout

```text
docs/reviews/
├── README.md
├── REV-YYYYMMDD-NNN.md
├── responses/
│   └── REV-YYYYMMDD-NNN.md
└── closures/
    └── REV-YYYYMMDD-NNN.md
```

- `REV-*.md` is written and maintained by the reviewer.
- `responses/REV-*.md` is written and maintained by the implementer.
- `closures/REV-*.md` is written by the reviewer after verification when a separate closure record is useful.

Do not turn the review file into a shared scratchpad. Separate authorship prevents one agent from silently rewriting the other agent's position.

## End-to-end path

### 1. Review publication

The reviewer:

1. reviews a specific commit or PR;
2. creates a review branch and a documentation-only PR;
3. records findings, evidence, priority, and acceptance criteria;
4. identifies which findings block deployment or release.

The review PR should be merged before the implementation PR when practical, so the reviewed requirements exist on `main`. If implementation starts earlier, it must reference the exact review branch/commit.

### 2. Implementer response

Claude creates a `fix/REV-...` branch and a response file. For every finding Claude chooses one of:

- `ACCEPTED` — agrees with the analysis and proposed acceptance criteria;
- `DISPUTED` — disagrees and provides technical evidence;
- `NEEDS-DISCUSSION` — the requirement is ambiguous or depends on an owner decision;
- `IMPLEMENTED` — a proposed fix and evidence are available in the implementation PR.

A response may be documentation-only when discussion must be resolved before code is changed.

### 3. Implementation Pull Request

The implementation PR links the review and response files. Findings that are independent should normally be implemented in separate commits or separate PRs. Security blockers take precedence over cleanup and documentation drift.

The PR must contain exact test commands and results. Tests not run must be listed explicitly.

### 4. Reviewer verification

The reviewer inspects:

- the actual diff, not only the summary;
- regression tests and whether they fail on the old behavior;
- `test/impact.sh` obligations;
- compatibility and security regressions;
- documentation changes;
- evidence for remote, non-root, ZFS, destructive, and live-cron paths.

The reviewer then approves, requests changes, or records a dispute. Only after verification may a finding be marked `CLOSED`.

### 5. Owner decision

The owner resolves:

- priority conflicts;
- accepted operational risk;
- deferred work;
- breaking compatibility;
- deployment and release timing.

An AI agent must not interpret silence as risk acceptance.

## Severity

- **P0 — critical blocker:** credible path to root compromise, data loss, destructive mis-targeting, or a backup mechanism that cannot be trusted. Stop deployment of the affected feature.
- **P1 — high:** likely operational failure, broken security promise, corrupted state, or unsafe release process. Fix before broader deployment.
- **P2 — medium:** important maintainability, test, CI, or documentation defect that increases future failure probability.
- **P3 — low:** cleanup or clarity issue with limited immediate impact.

Each finding also declares `Blocking: yes|no|owner-decision` because severity and release policy are related but not identical.

## Finding template

```markdown
## F1 — Title

- Severity: P1
- Blocking: yes
- Status: OPEN
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

## Discussion rule

PR comments are suitable for short questions and line references. Any conclusion that changes a finding's interpretation, acceptance criteria, severity, blocking status, or accepted risk must be copied into the response or closure Markdown file.
