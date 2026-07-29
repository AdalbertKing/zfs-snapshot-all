# Implementer instructions

Read `docs/AI_PROJECT_RULES.md`, `docs/reviews/README.md`, and the referenced review file before changing code.

## Default role

The default role for Claude in this repository is **implementer**.

For a review-driven task:

1. Create a branch named `fix/REV-YYYYMMDD-NNN-short-title` from the current reviewed base.
2. Create `docs/reviews/responses/REV-YYYYMMDD-NNN.md` before or with the first implementation commit.
3. Address one logical finding per commit whenever findings can be separated safely.
4. Add regression tests that fail on the reviewed base and pass after the fix.
5. Open a Pull Request that references the review and every finding addressed.
6. Do not merge the PR or mark findings `CLOSED`; the reviewer owns technical closure.

## Response file

Do not edit the reviewer's `docs/reviews/REV-*.md` file. Record the response separately using this structure:

```markdown
# Response to REV-YYYYMMDD-NNN

## F1 — ACCEPTED | DISPUTED | NEEDS-DISCUSSION | IMPLEMENTED

### Analysis
...

### Planned or implemented change
...

### Evidence
- commit/PR:
- commands run:
- results:

### Remaining risk
...
```

A disagreement is valid. State it precisely and provide code, ZFS/OpenSSH documentation, a reproducible test, or measured behavior. Do not change code merely to satisfy wording that is technically wrong; request review discussion instead.

## Implementation constraints

- Preserve compatibility unless the review explicitly permits a breaking change.
- Treat config, manifest, archive, hostname, dataset, and remote values as data. Do not execute them with `source`, `eval`, or equivalent mechanisms.
- Do not weaken host-key checking, delegated-account isolation, destructive-operation guards, or Proxmox-reserved-snapshot protections as a shortcut.
- Do not use `test/run.sh --bless` until the output diff has been reviewed as an intentional contract change.
- Run `./test/impact.sh` against the actual diff and report every required suite and manual obligation.
- Where the environment cannot run a required ZFS, remote-host, delegated-account, or destructive test, say so explicitly and leave the finding `IMPLEMENTED`, not `CLOSED`.

## Pull Request description

Include:

- review/finding IDs;
- root cause;
- implementation summary;
- compatibility and security impact;
- exact test commands and results;
- manual checks still required;
- documentation updated.
