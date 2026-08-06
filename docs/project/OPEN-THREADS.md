# Open threads

One table, three readers: owner, reviewer, implementer. If a thread is not
here, nobody is tracking it. Updated by whoever moves a thread.

Last update: 2026-08-06, at `e73fbac`.

| # | Thread | State | Whose move |
|---|---|---|---|
| 1 | REV-045 — logical pause | Implemented and live-verified (slices 1-4). Response written. | reviewer: close or reopen |
| 2 | REV-046 — alert-delivery false health | CLOSED by the reviewer | — |
| 3 | REV-047 — pair-gate audit logging | Both findings implemented, live re-checkpoint recorded. Response written. | reviewer: close or reopen |
| 4 | Hard disable — the package | Gate built and live-checked (step 1 of 3). Reviewer's instruction: no orchestration until this checkpoint is accepted. | reviewer: accept the checkpoint |
| 5 | ADR-0012 wording vs what was built | ADR calls DISABLED a "security gate"; the owner chose self-enable by the backup key, so it stops automation, accidents and manual runs but not a deliberate holder of the key. Implementation matches REV-045's own guidance; the ADR sentence is stronger. | reviewer: settle the wording (no code question open) |
| 6 | Test policy has three shapes | `TEST-CAMPAIGN-POLICY.md` (now simplified), the owner's chat instruction, and issue #5 all describe the same intent differently. | owner+reviewer: agree that the file is the single source |
| 7 | Issue #5 — test queueing discussion | Four questions answered in a comment on the issue (2026-08-06). If the issue and `TEST-CAMPAIGN-POLICY.md` ever diverge, the file is the source. | owner+reviewer: agree or amend |
| 8 | PR #4 — a SECOND implementation of logical pause | Closed as superseded, not merged. It was a parallel build of the same feature from another session (`--pair-label` where main uses `-L`), plus a unique LVM-thin design doc now rescued onto main (`3769525`). The branch `claude/opus-vs-fable-5-analysis-fq74yg` still exists if anything else is wanted from it. | owner: confirm the close, or say what else to salvage |
| 15 | Two sessions built the same feature the same day | PR #4 and main's slices 1-4 were written in parallel, hours apart, without either knowing. Cost: one complete duplicate implementation with its own tests and response file. | owner: decide how parallel sessions announce what they are taking |
| 9 | Issue #3 — enrolment contract consensus | Open since 2026-08-03, untouched since. | owner+reviewer |
| 10 | Two reviews numbered 047 | `REV-20260806-047-ALERT-DELIVERY-CLOSURE.md` and `REV-20260806-047.md` are different reviews sharing a number. | reviewer: renumber one |
| 11 | Profiles + live recursion (backlog) | Paused mid-discussion 2026-08-04. Needs a live check of ZFS descendant grants before design. | owner |
| 12 | `test/pause` section G false-fails on real hosts | Known test-isolation gap, not a product defect. | implementer, when convenient |
| 13 | pve2 has no cron config file | 14 live jobs whose source config is gone; `cron2conf.sh` exists to rebuild it. | owner: decide when |
| 14 | `docs/OPS_MONITORING.md` untracked | Sitting in the working tree, authorship unclear. | owner: keep or drop |

## How to use this

- Moving a thread means editing its row in the same commit as the work.
- A new review, discussion or decision gets a row the day it appears.
- "Whose move" is the whole point: a thread with nobody's name on it is
  either finished or forgotten.
