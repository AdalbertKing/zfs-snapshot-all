# Open threads

One table, three readers: owner, reviewer, implementer. If a thread is not
here, nobody is tracking it. Updated by whoever moves a thread.

Last update: 2026-08-06, after the reviewer's acceptance comment on issue #5.

| # | Thread | State | Whose move |
|---|---|---|---|
| 1 | REV-045 — logical pause | **CLOSED** by the reviewer 2026-08-06 for the declared scope. Endpoint-switch and in-flight live cases explicitly not required for closure. | — |
| 2 | REV-046 — alert-delivery false health | CLOSED by the reviewer | — |
| 3 | REV-047 — pair-gate audit logging | **CLOSED** (F1 and F2) by the reviewer 2026-08-06. | — |
| 4 | Hard disable — the package | **Complete**: gate, install at `--join`, orchestration, and the full live campaign on two real relationships (evidence in `HARD-DISABLE-CAMPAIGN-PLAN.md`). The campaign found and fixed two defects (state-dir ownership `8f6f8c2`, verify-endpoint blaming the address for a deliberate refusal). | reviewer: accept steps 2-4 |
| 16 | REV-049 — ownership must fail closed | Implemented in `209231c` (pairgate 45/45, negative control against `0058834`). Response written. Note: step 3 was pushed minutes before this review appeared — the pushes raced, it was not a decision to proceed. | reviewer: close or reopen |
| 17 | REV-050 — state-dir group-digit check | Implemented in `fe2209b` (gate_state_dir_ok, pairgate 57/57, negative control on `8f6f8c2`). Response written. | reviewer: close or reopen |
| 5 | ADR-0012 wording vs what was built | **Done** 2026-08-06: "security gate" is now "enforcement gate", with the self-enable consequence written into the ADR. Code and key model unchanged, as instructed. | — |
| 6 | Test policy | **Settled**: `TEST-CAMPAIGN-POLICY.md` accepted by the reviewer as the single source of truth; issue #5 is the record of the reasoning, not a parallel spec. | — |
| 7 | Issue #5 — test queueing discussion | Answered and settled in the same thread. | — |
| 8 | PR #4 — a SECOND implementation of logical pause | Closed as superseded, not merged. It was a parallel build of the same feature from another session (`--pair-label` where main uses `-L`), plus a unique LVM-thin design doc now rescued onto main (`3769525`). The branch `claude/opus-vs-fable-5-analysis-fq74yg` still exists if anything else is wanted from it. | owner: confirm the close, or say what else to salvage |
| 9 | Issue #3 — enrolment contract consensus | Open since 2026-08-03, untouched since. | owner+reviewer |
| 10 | Review numbering | **Done**: the closure review is now `REV-20260806-048-ALERT-DELIVERY-CLOSURE.md`; 047 stays with pair-gate logging, which has a response and links. | — |
| 11 | Profiles + live recursion (backlog) | Paused mid-discussion 2026-08-04. Needs a live check of ZFS descendant grants before design. | owner |
| 12 | `test/pause` section G false-fails on real hosts | Known test-isolation gap, not a product defect. | implementer, when convenient |
| 13 | pve2 has no cron config file | 14 live jobs whose source config is gone; `cron2conf.sh` exists to rebuild it. | owner: decide when |
| 14 | `docs/OPS_MONITORING.md` untracked | Sitting in the working tree, authorship unclear. | owner: keep or drop |
| 15 | Two sessions built the same feature the same day | PR #4 and main's slices 1-4 were written in parallel, hours apart, without either knowing. Cost: one complete duplicate implementation with its own tests and response file. | owner: decide how parallel sessions announce what they are taking |

| 18 | Reviewer reviewing a stale `main` | The 23:11 report on issue #5 named `6b884ba`/`8de89e1` as current while `fe2209b` (the REV-050 fix) and `b4660aa` (its response) had been public for five minutes. Asked for `git fetch` immediately before each review. | reviewer: adopt |

## How to use this

- Moving a thread means editing its row in the same commit as the work.
- A new review, discussion or decision gets a row the day it appears.
- "Whose move" is the whole point: a thread with nobody's name on it is
  either finished or forgotten.
