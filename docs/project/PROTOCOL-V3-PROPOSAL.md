# Protocol V3 proposal -- fast mode (for the Reviewer's acceptance)

Status: **DECIDED by the Reviewer 2026-11-07, see `PROTOCOL-V3-REVIEW-20261107.md` (accepted in principle with changes, P8 rejected); Superseded: V3 is ACTIVE since 2026-11-07 (PR #1127, merge 632af1b5); `docs/project/PROTOCOL.md` is the text in force.** Proposed 2026-11-07. Proposed by: Claude (implementer), on the Owner's instruction.
Nothing here is in force for the review workflow until the Reviewer accepts it. On acceptance,
the Implementer will amend `docs/project/PROTOCOL.md` and `docs/internal/reviews/README.md` in one PR,
and the Reviewer will check that PR against this file. Until then Protocol V2 applies unchanged.

Owner's goal, 2026-11-07: reach the goal fast. Run only the runs that are required, run no suites
on the Windows box, delegate to agents, and make review cooperation faster.

## Why (measured, not estimated)

- REV-20261104-186: the submission was rejected on the SHA (E114: gate-only commits after the
  named SHA). On 2026-11-04 the Owner stopped reviews: "Kończymy więc z recenzjami, bo się dogadać
  nie umiecie". Reviews resumed the same night for the A-TASSA repair.
- REV-20261104-186, rounds 3 and 4 (2026-11-05, `docs/project/ENGINE-FREEZE.md`): the full circle
  (pve9 suites, twins, freeze, CI, merge, ledger) was restarted after each newly found hole.
  On 2026-11-05 the Owner said: "Pełne koło po wszystkich poprawkach, a nie po każdej."
- REV-20261106-189/190: about 100 lines of code took 3 h (E123). Three late corrections each
  redid the paperwork (response, ledger, status).
- Each review round costs two merge boundaries (the response PR and the review PR) plus a third
  for closure.

## Proposed changes

Each point can be accepted, changed or rejected separately.

**P1. One REV per batch.** The Implementer delivers a batch: several fixes on one branch, one response,
one submission SHA. The Reviewer reviews the whole batch in one pass and lists **all** findings in one
verdict. Findings are not handed out one per round.

**P2. Blocking findings carry a reproduction.** A `CHANGES-REQUIRED` finding states either a command or
test with expected and actual results, or `file:line` plus the contract it breaks. Any other remark is
**non-blocking**: it goes into the verdict as a backlog note and does not reopen the REV.

**P3. Scope is fixed at publication.** A new problem outside the REV's findings gets a new REV and does
not reject the current one. The exception is data loss, a security hole, or a destructive-operation guard,
which may block.

**P4. The verdict binds content, not the merge commit.** An approval or rejection refers to the
implementation SHA. Later commits on `main` that do not touch the implementation's files do not invalidate
the verdict and do not require resubmission. Such commits are other PRs, generated views,
`PROJECT_STATUS.md` and the response itself. The Reviewer checks this with
`git diff <impl-sha> main -- <files of the diff>`, which must be empty. Gate-only commits after
the SHA, such as a freeze re-pin or a twin bless (the E114 case), are judged by their own CI run.
They do not reopen the verdict unless they change behaviour.

**P5. Evidence the Reviewer accepts without re-running anything:**
- CI on the exact head SHA. CI runs `impact.sh --verify` (the `graph` job) and the body of every
  suite that `impact.sh` maps the diff to. Unmapped suites report green without running. The full battery runs on every push to `main`.
- For each edited suite: the pve9 run, as the command, host, SHA and the `PASS=n FAIL=0` line.
- The pve9 run of the negative control on the parent SHA, showing the new test red.
- For live-host behaviour: the host, the SHA, the command, and the output tail (at most 20 lines).

The Implementer does **not** run the whole impact list on pve9. That list is what CI must show green.
No suite runs on the Implementer's Windows box. That is the Owner's rule, enforced by a hook.

**P6. Short responses.** Each finding gets: the change, the commit, the test (command → result) and the
remaining risk, in at most about one screen. Process history goes in the error log, not in the response.

**P7. Two rounds, then the Owner.** If the Reviewer and the Implementer still disagree on the same finding
after the second rejection, the Owner decides. Only the Owner accepts operational risk, so this is not a
change of authority, only a time limit.

**P8. Approve and close in one step.** When the Reviewer approves, the Reviewer may write the closure in
the same review PR. That removes one merge boundary per REV.

**P9. Work continues while the Reviewer reviews.** While a batch is at `IMPLEMENTED | Reviewer`, the
Implementer may start the next batch on a new branch. A rejection of batch N is fixed in batch N+1
unless P3's exception applies (data loss, security, destructive guard); in that case it is fixed first.
This replaces "only dependency-independent work" (CLAUDE.md, Work pickup, point 6).

**P10. Handoff ping.** The ledger on `main` stays the only authority. As a convenience, the Implementer
ends each submission with one line for the Owner to paste to the Reviewer:
`REV-... IMPLEMENTED @ <sha>, PR #n, CI <run-url>`.
The Reviewer's verdict PR title says `approve` or `reject` and the REV number.

## Already in force on the Implementer's side (Owner direction, not subject to this acceptance)

`docs/AI_PROJECT_RULES.md`, Test discipline, and CLAUDE.md, "Fast mode", as of 2026-11-07:
- no suite or `impact.sh` run on the Windows box;
- by hand on pve9 only the edited suite plus its negative control;
- the `impact.sh` list is what CI must show green;
- `--verify` runs on pve9 via `ship.sh` and in CI, once per batch.

They change what the Implementer runs, not what the Reviewer may ask for. P5 is the question
of whether that evidence is enough for the Reviewer.

## Not changed

- The ledger is generated and is the only routing authority. Response files are separate from REV files.
  Only the Reviewer approves or closes. Only the Owner accepts risk and releases (`publish.sh`).
- Negative controls, `text-checker`, and the exact-head CI read remain the Implementer's own gates.

## How to answer

Answer in a REV or a review PR. Give `ACCEPTED`, `ACCEPTED WITH CHANGE: ...` or `REJECTED: reason` for
each of P1-P10. The Owner relays the answer if needed.
