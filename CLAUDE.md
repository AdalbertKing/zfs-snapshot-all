# Implementer instructions

Read `docs/AI_PROJECT_RULES.md`, `docs/internal/reviews/README.md`, and the active reviewer file before changing code.

**Before every work round, read section 1 of `docs/internal/IMPLEMENTER-ERROR-LOG.md`.**
Owner instruction, 2026-08-27. That section is the distilled rules, deliberately
short; the entries under it are evidence, not a reading list. Every mistake goes
in with its genesis, its cause and the rule it produces. A repeated mistake under
an existing rule is a stronger signal than a new category -- it means the rule is
not being applied -- so add it to that rule's evidence rather than inventing a
new one.

## Default role

The default role for Claude in this repository is **implementer**.

## Work pickup — mandatory

`docs/internal/reviews/REVIEW_LEDGER.md` on the freshly published `main` is the only authoritative answer to **current review ownership and routing**. Product sequencing when no review blocks expansion comes from `docs/project/ACTIVE-WORK-PLAN.md` plus any current explicit Owner direction that narrows its immediate next step.

At the start of every scheduled or manually-started work cycle, and **before saying that there is nothing from the Reviewer / nothing to do**:

1. Refresh the published repository state (`git fetch origin main` or an equivalent fresh read of GitHub `main`). Do not decide from a stale local checkout.
2. Read `docs/internal/reviews/REVIEW_LEDGER.md` from that fresh published state.
3. Every row whose derived state is `OPEN` and owner is `Claude` is an actionable reviewer handoff. Open the matching `docs/internal/reviews/REV-YYYYMMDD-NNN.md` and continue that REV from the reviewer's current requirements.
4. `IMPLEMENTED -> Reviewer` means the submitted SHA is waiting for review. `APPROVED -> Reviewer` means closure is the reviewer's move. Do not continue modifying that submitted acceptance boundary behind its SHA merely because the implementer cycle is still running. `CLOSED` needs no implementer action.
5. If there is no `OPEN | Claude` work and no earlier gate/submission whose current Reviewer ownership blocks functional expansion, read `docs/project/ACTIVE-WORK-PLAN.md` and any current explicit Owner sequencing note, then start the next dependency-ready planned item without waiting for a new Owner message.
6. While Reviewer owns a submitted functional boundary, only dependency-independent work explicitly permitted by the active plan may proceed; do not jump to a later functional phase to fill the wait.
7. Never claim "no reviewer work" while the fresh ledger contains an `OPEN | Claude` row, and never claim "nothing to do" without also checking the active product sequence when review routing is clear.

A rejection/follow-up normally does **not** edit Claude's response file: the Reviewer advances the reviewer-owned `reviewed-implementation`/verdict fact, which deterministically changes the ledger from `IMPLEMENTED -> Reviewer` to `OPEN -> Claude`. Therefore an older response may still say `response-status: IMPLEMENTED`, may describe previous remaining work, or may contain an earlier request for reviewer input. **The fresh ledger plus the current reviewer file wins for pickup.** Claude updates the same response file only after producing the next implementation/evidence SHA.

`docs/project/OPEN-THREADS.md` is only a generated convenience view. `docs/PROJECT_STATUS.md` describes product/operational state. Neither may be used instead of `REVIEW_LEDGER.md` for workflow ownership. `ACTIVE-WORK-PLAN.md` is product sequencing, not a second review-routing table.

## Current delivery mode

`docs/AI_PROJECT_RULES.md` records an active, temporary owner-approved direct-main exception.
While it remains active:

1. A branch and Pull Request are preferred when practical but are not required.
2. Claude may commit a reviewed logical change directly to `main`.
3. Create or update `docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md` with the implementation evidence.
4. Address one logical finding per commit whenever findings can be separated safely.
5. Add regression tests that fail on the reviewed base and pass after the fix.
6. Before push: run `./test/impact.sh --verify` and, of the suites it lists, only
   those the change directly exercises -- the ones you edited, or whose subject
   you changed. Push and let CI run the rest. See "Which executor" below.
7. Do not mark findings `CLOSED`; the reviewer owns technical closure.
8. Never force-push or rewrite a published direct-main commit. Correct defects with a new forward commit.

When the owner revokes the exception, return to the normal branch and Pull Request workflow described in `docs/AI_PROJECT_RULES.md`.

## Response file

Do not edit the reviewer's `docs/internal/reviews/REV-*.md` file. Record the response separately using this structure:

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
- Run `./test/impact.sh` against the actual diff to LIST every required suite and
  manual obligation, and report that list. Listing is not running.
- Where the environment cannot run a required ZFS, remote-host, delegated-account, or destructive test, say so explicitly and leave the finding `IMPLEMENTED`, not `CLOSED`.

## Which executor

Owner direction, 2026-08-26: **stop stalling the project on test machinery.**
Three executors, and the choice is not a matter of taste.

| executor | for | cost here |
|---|---|---|
| **targeted local check** | pure-text logic; the discriminator for the thing being debugged | seconds |
| **a live host** (pve9 and the other lab machines) | anything bash-real or ZFS-real | seconds -- native bash, real `flock`/`logger`/`zfs` |
| **CI** | the whole battery | ~1-2 min, in parallel, for free |

**This Windows box is not on that list for full suites.** One suite costs 13-25
minutes here against seconds on a runner (`test/ci-suites.sh` says so in its own
header), and it also LIES: `localbackup` gave 56/1 on Git Bash while CI was fully
green on the same SHA. A serial local battery buys nothing and blocks the session
for the duration.

So:

- run locally only a suite you **edited**, or whose subject you changed -- not
  running a test you just wrote is its own defect;
- everything else: push, and read CI once. `./test/gh-api.sh GET
  "actions/runs?per_page=6"`, compare `head_sha`, move on;
- **never block on the queue.** If GitHub has not scheduled the run, say so and
  keep working. A red check is information; a queued check is not;
- `./test/impact.sh --verify` / `--refreeze` / `--refresh-status` are NOT suite
  runs. They take seconds and they are the freeze and status-digest gates. Keep
  them;
- when a negative control needs the same suite three times, that is a signal the
  suite needs a section selector, not a signal to run it three times.

Reporting rule: report on completion, not per iteration. One message with the
result, not a running commentary on which suite is at which line.

## Project status document

`docs/PROJECT_STATUS.md` is the shared **product/operational** current-state document. It describes what the tree and deployed estate do today, but it is **not review workflow state and must not be used to decide whose move it is**. Workflow ownership comes only from the generated `docs/internal/reviews/REVIEW_LEDGER.md` as required by Protocol V2.

Refresh `PROJECT_STATUS.md` at the end of **every** stage, before reporting the stage as done:

- the `Stan na` commit and date;
- the host, version and deployment tables;
- the suite counts;
- product/operational open items and known gaps.

Where a change replaces a design the document describes, **rewrite that section** rather than appending to it. Historical accuracy belongs in `docs/internal/reviews/responses/`; current product truth belongs in `PROJECT_STATUS.md`.

`./test/impact.sh` raises this as the manual obligation `project-status`.

## Delivery evidence

For a Pull Request or direct-main delivery, record:

- review/finding IDs;
- root cause;
- implementation summary;
- compatibility and security impact;
- exact test commands and results;
- manual checks still required;
- documentation updated;
- exact commit SHA or PR number.