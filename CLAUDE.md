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

The ledger derived from the freshly published `main` (`./test/reviewctl.sh --derive origin/main`) is the only authoritative answer to **current review ownership and routing**. Product sequencing when no review blocks expansion comes from `docs/project/ACTIVE-WORK-PLAN.md` plus any current explicit Owner direction that narrows its immediate next step.

At the start of every scheduled or manually-started work cycle, and **before saying that there is nothing from the Reviewer / nothing to do**:

1. Refresh the published repository state (`git fetch origin main` or an equivalent fresh read of GitHub `main`). Do not decide from a stale local checkout.
2. Derive the state from that fresh published `main`: `git fetch origin main`, then `./test/reviewctl.sh --derive origin/main` (add `--threads` for the routing view). On this Windows box run it on the pve9 clone instead: `./test/remote-suite.sh derive origin/main` (`... threads`), about 30 s; here it takes minutes (E130).
3. Every row whose derived state is `OPEN` and owner is `Claude` is an actionable reviewer handoff. Open the matching `docs/internal/reviews/REV-YYYYMMDD-NNN.md` and continue that REV from the reviewer's current requirements.
4. `IMPLEMENTED -> Reviewer` means the submitted SHA is waiting for review. `APPROVED -> Reviewer` means closure is the reviewer's move. Do not continue modifying that submitted acceptance boundary behind its SHA merely because the implementer cycle is still running. `CLOSED` needs no implementer action.
5. If there is no `OPEN | Claude` work and no earlier gate/submission whose current Reviewer ownership blocks functional expansion, read `docs/project/ACTIVE-WORK-PLAN.md` and any current explicit Owner sequencing note, then start the next dependency-ready planned item without waiting for a new Owner message.
6. While Reviewer owns a submitted functional boundary, only dependency-independent work explicitly permitted by the active plan may proceed, and it may not assume that the pending boundary will be accepted (PROTOCOL V3.9). That includes preparing the next batch on another branch. A rejection of that boundary is fixed under the same REV and response, not moved to the next batch. Do not jump to a later functional phase to fill the wait.
7. Never claim "no reviewer work" while the fresh ledger contains an `OPEN | Claude` row, and never claim "nothing to do" without also checking the active product sequence when review routing is clear.

A rejection/follow-up normally does **not** edit Claude's response file: the Reviewer advances the reviewer-owned `reviewed-implementation`/verdict fact, which deterministically changes the ledger from `IMPLEMENTED -> Reviewer` to `OPEN -> Claude`. Therefore an older response may still say `response-status: IMPLEMENTED`, may describe previous remaining work, or may contain an earlier request for reviewer input. **The fresh ledger plus the current reviewer file wins for pickup.** Claude updates the same response file only after producing the next implementation/evidence SHA.

The `--threads` view (`OPEN-THREADS.md`) is only a derived convenience view, and neither it nor any local `--generate` copy is committed. `docs/PROJECT_STATUS.md` describes product/operational state. Neither may be used instead of the derived ledger for workflow ownership. `ACTIVE-WORK-PLAN.md` is product sequencing, not a second review-routing table.

## Current delivery mode

The Owner revoked the temporary direct-main exception on 2026-08-14. The normal
branch-and-Pull-Request workflow in `docs/AI_PROJECT_RULES.md` is mandatory.

Create or update the matching response artifact, use logical commits, add the
discriminating regression, run the targeted checks plus `./test/impact.sh
--verify`, and let CI run the broader battery as described below. Do not mark a
finding `CLOSED`; the Reviewer owns technical closure. Never force-push or
rewrite published history.

**An open Pull Request is not a submission.** Green CI, a mergeable PR, and a
Claude role branch visible on GitHub are still WIP. A response/implementation is
submitted to the Reviewer only after the authorised merge boundary has completed
and a fresh read of canonical `main` proves all of these facts:

1. the exact implementation SHA named by the response is reachable from `main`;
2. `main` contains the response;
3. `./test/reviewctl.sh --derive origin/main` shows `IMPLEMENTED | Reviewer` for that REV.

If the implementation PR is waiting for Reviewer inspection, branch protection,
checks, or merge authority, report that exact state. Do not claim `submitted`,
`published`, or `handed to Reviewer` until the `main` read-back above succeeds.

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

**Owner, 2026-11-03 ("1-4 od razu", answering why a round now takes a day):**

1. **No suite runs on this Windows box at all** -- not even an edited one. Here:
   `bash -n`, and the new test cases cut out and run on their own (seconds, as for
   the guest-split guard, 2026-11-03). The edited suite runs on the pve9 clone or
   in CI. Measured that day: test/monitor 3m54s here; `impact.sh --verify` did not
   finish in 5 minutes here -- run it on pve9 too.
2. **Batches, not rounds.** Several fixes ride one branch; PROJECT_STATUS, the
   text-checker pass, ENGINE-FREEZE/refreeze and the digest are done ONCE per batch,
   just before its PR.
3. **Lab before code.** Walk the whole GUI scenario on the lab first and write every
   defect down; fix them as one batch afterwards. Not one fix cycle per defect.

Point 4 of the same answer is a change, not a rule: the cron install guard is to compare
job IDENTITY (relation, tier, kind, datasets) instead of line text -- after 1.0.6.

So:

- run an edited suite (or one whose subject you changed) on pve9/CI -- not
  running a test you just wrote is its own defect;
- everything else: push, and read CI once. `./test/gh-api.sh GET
  "actions/runs?per_page=6"`, compare `head_sha`, move on;
- **never block on the queue.** If GitHub has not scheduled the run, say so and
  keep working. A red check is information; a queued check is not;
- `./test/impact.sh --refreeze` / `--refresh-status` take seconds and write the
  index: they run here. `./test/impact.sh` (the suite list) and `--verify` run on
  the pve9 clone or in CI -- `--verify` did not finish in 5 minutes here. Owner,
  2026-11-07, after this line had said "keep them" and it cost five minutes:
  `.claude/hooks/suites-on-pve9.sh` (PreToolUse on Bash) now refuses a local
  suite or `impact.sh` call on Windows;
- when a negative control needs the same suite three times, that is a signal the
  suite needs a section selector, not a signal to run it three times.

**Owner, 2026-11-13 (the REV-197 night: about 1 h of code; snapsend started 9 times at 25-40 min each):**

- **A slow suite is a defect. Measure it before you wait on it.** Snapsend took 25-40
  minutes because the suites left 2999 progress records on pve9, and every transfer
  read all of them (9.7 s instead of 0.4 s per `snapget` call). If a suite runs longer than its checks
  explain, time one engine call before running anything else.
- **During a round, run only the sections the change touches:**
  `./test/remote-suite.sh snapsend origin/<branch> only=<word>`. The whole suite runs
  once, on the final head, before the PR.
- **A commit that touches no engine or test file** (docs, response, status) never
  restarts a suite. Do not kill a running suite because the head moved.
- **Negative control:** a script that reproduces the defect on real ZFS (minutes), run
  on the rejected SHA. Not a second whole-suite run on an old commit.
- **Before writing destructive code** (anything that destroys snapshots or data), list
  in the response every path by which data reaches the medium, before the code. The
  paths missed in REV-197 cost two extra review rounds.
- **Two suites at once:** give them separate clones, `REMOTE_SUITE_CLONE=/tmp/tt2/...`.

Reporting rule: report on completion, not per iteration. One message with the
result, not a running commentary on which suite is at which line.

### Fast mode -- one batch, start to finish (Owner, 2026-11-07)

"Priorytet to szybkie dotarcie do celu": run only the required runs, no suites on Windows,
delegate, cooperate with the reviewer faster. This is the default way of working, not an
exception for one night. One batch:

1. **Collect first.** Gather every defect from the deployment, the copy/replica runs, or the
   lab scenario into one list in the session notes. Work around each one on the host by hand if
   needed and keep going. Do not start a fix cycle per defect.
2. **One branch per batch.** For each fix: Edit, `bash -n`, and the cut-out case here (seconds).
   After the collected fixes (not after each one), push the branch and run **only the edited
   suite** on pve9:
   `./test/remote-suite.sh <suite> origin/<branch>`. Without a ref it tests `origin/main`, not your
   edit. Then the negative control, which is **the new test against the old code**. Running the
   parent's suite does not count, because the parent does not have the new test (Reviewer,
   PROTOCOL-V3-REVIEW-20261107 P5.2). Make a throwaway branch `<branch>-negctl` that reverts only
   the code fix and keeps the test. Push it and run `./test/remote-suite.sh <suite> origin/<branch>-negctl`.
   The new case must fail for the intended defect. Record the baseline SHA, the case, the expected
   failure and the observed failure, then delete the branch. The top-level
   suite `test/run.sh` is not a `test/<suite>/` directory, so it goes to CI. Nothing else runs
   by hand. The `impact.sh` list is what CI must show green.
3. **Delegate while you work.** Reading goes to haiku (`repo-greper` / `Explore`). Typing
   ≥150 lines goes to `simple-coder`. Prose gets `text-checker` before its commit. In a batch that is once, on the batch's final prose,
   not after each fix.
4. **Close once.** Write the response and PROJECT_STATUS, do the text-checker pass, commit,
   then run `./test/ship.sh` (push, digest, `--verify` on pve9; it refuses a dirty tree). Open the PR, read exact-head CI once,
   and merge on green. A material defect or evidence gap found in this batch's scope is fixed
   under the same REV, and the batch is finalised once. There is no suite rerun per edit, only
   one targeted validation after the collected fixes. Only unrelated, non-blocking observations
   go to the next batch, as backlog notes (PROTOCOL V3.2). An independent finding gets a new
   REV (V3.3).
5. **One release per deployment**, on the Owner's "publikuj". Never one version per finding.
   `publish.sh --push` refuses while any REV is `OPEN` or `IMPLEMENTED` (PROTOCOL V3.13). Pass
   `--accept-open-review=REV-...` only when the Owner names those REVs.
6. **Reviewer: Protocol V3** (`docs/project/PROTOCOL.md`, section "V3 amendments"). ACTIVE since
   2026-11-07: PR #1127, merge 632af1b5, read back on `main`. In practice:
   - one pass per batch;
   - each suite in the evidence marked with one of three statuses: `EXECUTED PASS`;
     `SKIPPED / NOT IMPACTED`; `MANUAL / NOT RUN`;
   - a rejection is fixed under the same REV;
   - approval and closure stay two published boundaries;
   - each submission ends with the handoff line `REV-... IMPLEMENTED @ <sha>, PR #n, CI <run-url>`
     and the delegation split line (V3.10, V3.11).

   Protocol changes are made during the work, as V3.n amendments (V3.12).

## Which model -- delegation

**HARD GATE -- every session, every thread (Owner, 2026-10-20: cheaper plan, "konieczność
optymalnej pracy pod kątem zużywania tokenów").** Before the call, not after:

1. **Reading code**: more than ~150 lines, or more than two files, or "where is X / who
   calls it" -> `repo-greper` or `Explore` (haiku). The session reads only the excerpt it
   is about to edit (`Read` with offset/limit), never a whole large file "to get oriented".
2. **Typing a fully specified change** of ~150 lines or more (test answer sequences,
   fixtures, docs from notes) -> `simple-coder`, with files, functions, inputs and the
   expected result in the brief.
3. **A red CI check** -> `ci-reader`. **Prose before commit** -> `text-checker`.
4. **Suites** run on the pve9 clone or in CI, with output trimmed (`> file; grep FAIL;
   tail -1`), never streamed into the session.
5. The session keeps: design, diagnosis, guards, engines, git, hosts, merge.

Skipping the gate is an error-log entry like any other defect. The end-of-round split
line (below) shows that the gate was applied.

Owner direction, 2026-09-23, re-cut 2026-10-07: **the session model
orchestrates; simple work goes to cheaper subagents.** Token cost is a routing
parameter, not an afterthought. The session decides, briefs, reviews and
integrates; it does not type what a cheaper model can type.

**Models are named by ALIAS, never by ID.** The agent files say `haiku` /
`sonnet`; the harness maps each alias to the newest model of that line.
Measured 2026-10-07: a `haiku` agent reports itself as Haiku 5.5 (the Owner's
model picker lists Opus 5.5, Fable 5.1, Sonnet 5.5, Haiku 5.5). A newer
model arrives in every agent by itself, with no edit here. Ask an agent which
model it is (one line, no tools) rather than trusting a list in a prompt -- the
session's own environment note still named Haiku 4.5 that day.

**It has to pay, in tokens.** Price per million tokens, 2026-10-07 (input /
output): Opus 5.5 $4 / $20, Sonnet 5.5 $2 / $10, Haiku 5.5 $0.10 / $0.50. Two
facts decide the routing:

- **The session's context is the hidden cost.** Everything the session reads
  stays in the conversation and is re-read, from cache, on every later turn. A
  20k-token CI log read by the session costs ~$0.08 once and ~$0.20 more over the
  ~50 turns it then rides along; the same log read by `ci-reader` cost ~30k Haiku
  tokens, about $0.005. Reading goes to Haiku: an order of magnitude, and the
  session's context stays lean.
- **Starting an agent has a fixed price**: ~60k Haiku tokens for a one-line,
  zero-tool call (its system prompt), ~$0.006. Cheap in money, so the test is
  whether the work needs doing at all, not whether Haiku can afford it.

Typing through `simple-coder` is roughly break-even with the session typing it:
a ~200-line dialog is ~$0.15-0.20 of Sonnet (start, reading the files, output)
plus the session's brief and review, against ~$0.08 of Opus output plus carrying
the text in context. So it pays only for a large self-contained piece (~150
lines and up) or for parallel work -- below that the session types, and a
delegation for its own sake is waste.

| role | agent (`.claude/agents/`) | model | use it for | may not |
|---|---|---|---|---|
| CI diagnosis | `ci-reader` | haiku | a RED check: which test failed, the log excerpt, does `main` pass it | re-run, merge, guess a queued result |
| inventory | `repo-greper` | haiku | "where is X / who calls it / which suites cover it" across more than two files | say anything runs on a host |
| prose vs tree | `text-checker` | haiku | **every** PROJECT_STATUS / error-log / response / PR text before its commit | edit, confirm live claims |
| gate explanation | `gate-runner` | haiku | only when a gate's drift report must be read and explained | write forms, suites |
| typing a decided change | `simple-coder` | sonnet | test sections from a spec, a whiptail dialog over a fixed verb contract, docs from bullet notes | Bash, git, hosts, frozen engines, design |
| everything else | session | -- | decide, diagnose, guards, engines, live hosts, git, PR, merge | -- |

**No model at all** when a plain command does the job: waiting for green CI and
merging is a polling script in the session's scratchpad (`wait-merge.sh`, not
in the repo; zero tokens); `impact.sh --verify` /
`--refresh-status` run inline with their output trimmed (`> file; tail -1`). A
subagent for a shell call costs more than the call -- measured 2026-09-23, one
`gate-runner` run of `impact --verify` was ~30k haiku tokens for a one-line answer.

Routing, in the order the session asks it:

1. **Is it a decision?** Diagnosis, design, choosing between readings of a
   review, a guard, an engine, anything destructive, anything on a live host,
   git history, PR and merge: the session. Never delegated.
2. **Is it a plain command?** Run it, no agent.
3. **Is it reading?** Inventory, a red CI log, a text against the tree: a haiku
   reader, in the background, while the session works on. The report is a lead,
   not evidence: re-check any claim before repeating it to the Owner.
4. **Is it typing a change already fully specified** -- files, functions,
   expected behaviour, the discriminating input for each test, what the negative
   control must show? `simple-coder`, when the piece is ~150 lines or more, or
   runs in parallel with other work. Below that the session types (see the
   arithmetic above).
5. **Independent pieces run in parallel** (several agents in one message). Two
   `simple-coder`s never edit the same file at once; use `isolation:
   "worktree"` when their files could overlap.

The session's duties after a delegated edit do not shrink: read the diff like
an enemy, run `bash -n` / the targeted check / the edited suite, build the
negative control against `main`. A subagent's "done" is not a check.

**Every report at the end of a round names the split in one line:** what went
to which agent, and what the session kept and why. Rounds #470 (edit-relation)
and #471 (replica GUI) went out with nothing delegated and no `text-checker` pass
on their status entries (E74). The line is how the Owner sees the rule being applied.

## Project status document

`docs/PROJECT_STATUS.md` is the shared **product/operational** current-state document. It describes what the tree and deployed estate do today, but it is **not review workflow state and must not be used to decide whose move it is**. Workflow ownership comes only from the ledger derived with `./test/reviewctl.sh --derive origin/main` as required by Protocol V2.

Refresh `PROJECT_STATUS.md` at the end of **every** stage, before reporting the stage as done:

- the `Stan na` commit and date;
- the host, version and deployment tables;
- the suite counts;
- product/operational open items and known gaps.

Where a change replaces a design the document describes, **rewrite that section** rather than appending to it. Historical accuracy belongs in `docs/internal/reviews/responses/`; current product truth belongs in `PROJECT_STATUS.md`.

`./test/impact.sh` raises this as the manual obligation `project-status`.

## Delivery evidence

For every Pull Request delivery, record:

- review/finding IDs;
- root cause;
- implementation summary;
- compatibility and security impact;
- exact test commands and results;
- manual checks still required;
- documentation updated;
- exact commit SHA or PR number.
