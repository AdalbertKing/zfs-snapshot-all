# Open threads

One table, three readers: owner, reviewer, implementer. If a thread is not
here, nobody is tracking it. Updated by whoever moves a thread.

Last update: 2026-08-06, after the reviewer's acceptance comment on issue #5.

| # | Thread | State | Whose move |
|---|---|---|---|
| 1 | REV-045 — logical pause | **CLOSED** by the reviewer 2026-08-06 for the declared scope. Endpoint-switch and in-flight live cases explicitly not required for closure. | — |
| 2 | REV-046 — alert-delivery false health | CLOSED by the reviewer | — |
| 3 | REV-047 — pair-gate audit logging | **CLOSED** (F1 and F2) by the reviewer 2026-08-06. | — |
| 4 | Hard disable — the package | **CLOSED** by the reviewer 2026-08-07 (`REV-20260807-052`, APPROVED). No code or test finding open. Approval is for the documented enforcement-gate model, with the self-enable limitation stated. | — |
| 16 | REV-049 — ownership must fail closed | **CLOSED** by the reviewer 2026-08-06. | — |
| 17 | REV-050 — state-dir group digit | **CLOSED** by the reviewer 2026-08-06. | — |
| 5 | ADR-0012 wording vs what was built | **Done** 2026-08-06: "security gate" is now "enforcement gate", with the self-enable consequence written into the ADR. Code and key model unchanged, as instructed. | — |
| 6 | Test policy | **Settled**: `TEST-CAMPAIGN-POLICY.md` accepted by the reviewer as the single source of truth; issue #5 is the record of the reasoning, not a parallel spec. | — |
| 7 | Issue #5 — test queueing discussion | Answered and settled in the same thread. | — |
| 8 | PR #4 — a SECOND implementation of logical pause | Closed as superseded, not merged. It was a parallel build of the same feature from another session (`--pair-label` where main uses `-L`), plus a unique LVM-thin design doc now rescued onto main (`3769525`). The branch `claude/opus-vs-fable-5-analysis-fq74yg` still exists if anything else is wanted from it. | owner: confirm the close, or say what else to salvage |
| 9 | Issue #3 — enrolment contract consensus | Open since 2026-08-03, untouched since. | owner+reviewer |
| 10 | Review numbering | **Done**: the closure review is now `REV-20260806-048-ALERT-DELIVERY-CLOSURE.md`; 047 stays with pair-gate logging, which has a response and links. | — |
| 11 | Profiles + live recursion (backlog) | Paused mid-discussion 2026-08-04. Needs a live check of ZFS descendant grants before design. | owner |
| 12 | `test/pause` section G false-fails on real hosts | **Not reproducible — the thread was stale.** Fixed 2026-08-03 in `3776a9a` (the account scan glob became overridable and points at a path that cannot match). Re-verified 2026-08-06 by running the suite on BOTH production hosts: 74/74, G1 passing on each. | — |
| 13 | pve2 has no cron config file | 14 live jobs whose source config is gone; `cron2conf.sh` exists to rebuild it. | owner: decide when |
| 14 | `docs/OPS_MONITORING.md` untracked | Sitting in the working tree, authorship unclear. | owner: keep or drop |
| 15 | Two sessions built the same feature the same day | PR #4 and main's slices 1-4 were written in parallel, hours apart, without either knowing. Cost: one complete duplicate implementation with its own tests and response file. | owner: decide how parallel sessions announce what they are taking |

| 18 | Reviewer reviewing a stale `main` | The 23:11 report on issue #5 named `6b884ba`/`8de89e1` as current while `fe2209b` (the REV-050 fix) and `b4660aa` (its response) had been public for five minutes. Asked for `git fetch` immediately before each review. | reviewer: adopt |
| 19 | REV-051 — dot-segment gate labels | **CLOSED** 2026-08-07 with the negative control accepted. | — |

## How to use this

- Moving a thread means editing its row in the same commit as the work.
- A new review, discussion or decision gets a row the day it appears.
- "Whose move" is the whole point: a thread with nobody's name on it is
  either finished or forgotten.
