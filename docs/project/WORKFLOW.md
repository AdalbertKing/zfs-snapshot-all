# Workflow V5

Status: **proposed by the Owner's instruction of 2026-11-13; active for the implementer
from the merge of this file; the Reviewer-side rules (W6) are active once the Reviewer
accepts them.** Where this file and `PROTOCOL.md`, `AI_PROJECT_RULES.md`,
`reviews/README.md` or `CLAUDE.md` disagree, this file wins. Everything it does not
mention stays as those files say.

Why: REV-197 took about 1 h of code and about 8 h of cycle, and was rejected four times
for the same class of defect. Measured on 16 sampled reviews: 0 of 39 product defects
were first found by a suite or CI; 33 were found by the Reviewer, 23 of them with a small
isolated reproduction of one path. Measured on the error log (E1-E131): the status
digest caused 14 recorded mistakes and the engine freeze 2; neither has a recorded catch
of a product defect.

## W1. Not negotiable (product safety, unchanged)

- No destruction of snapshots or data without its guards (GUID identity, ownership,
  bookmarks, Proxmox reservations). A destructive step is proved on real ZFS: it destroys
  what it should, and the old code shows the hole.
- Host-key checking, delegated-account isolation, Proxmox-reserved snapshots.
- Production: plan plus the Owner's consent. Lab: free.
- Release: only on the Owner's "publikuj", from a fresh `main`, through `publish.sh`.
  `release/review-gate.sh` and `release/coverage-gate.sh` are unchanged.
- Config, manifest, host and dataset names are data: never `eval`, never `source`.
- Backward compatibility of deployed configs and crontabs.
- No suite on the Windows box.

## W2. Two lanes

- **Lane D (data):** the change touches one of the five engines (`snapsend.sh`,
  `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh`, `lib-zfs-snap.sh`) or anything in the
  V4.1 list (identity, history and retention, selection and scheduling, permissions,
  config as the only truth, release behaviour). Full evidence, W3.
- **Lane Z (ordinary):** everything else. Regression case, green CI, merge. One response
  per batch, reviewed before the release (the coverage gate requires it).

A submission is what it was: merged to `main` on green CI, response ranges written by
`reviewctl respond`.

## W3. A lane-D round: eight steps, budget 45 minutes from verdict to merge

| min | step |
|---|---|
| 0-5 | 1. Read the verdict. Write the **path map** (W4) into the response, before code. |
| 5-25 | 2. Code plus the regression case in the suite. 3. A **reproduction script on real ZFS**, run on the rejected SHA (fails) and on the new one (passes). That is the negative control. |
| 25-35 | 4. The touched suite sections on pve9 (`only=<word>`). 5. In parallel, the **adversarial pass** (W5). |
| 35-45 | 6. The whole suite once, on the final head (second clone, alongside CI). 7. The response: a delta of at most 40 lines. 8. PR, green CI, merge; read the ledger from the CI job `ledger`. |

Once per batch, before the release, not per round: CHANGELOG, `docs/pl`, `docs/en`,
`--help`, `docs/STAN.md`.

Nothing else is owed per round. In particular there is no status digest, no engine
re-freeze, no freeze entry, and no `--bless` unless a twin's hash changed.

## W4. The path map (replaces the V4.3 six-case matrix)

Four questions, answered in at most 15 lines, before the code:

1. By which paths do data or snapshots reach the place this change reads, destroys or
   overwrites? All of them, not only the one being fixed.
2. Who else creates objects of the same kind or name: another run, another host, pvesr,
   vzdump, quiesce, a rotated disk carrying the same pool name?
3. What if the state changes between the read and the act (a concurrent run)?
4. rc != 0, an empty answer, a partial answer.

## W5. The adversarial pass (lane D, before submission)

An agent with a fresh context gets the diff and the path map and none of the author's
reasoning. Its job is to write, for every path in the map, a small reproduction (a stub
plus the real function cut out of the engine, or real ZFS on pve9), not an opinion. A
reproduction that fails sends the round back to step 2. This moves the method that found
most defects to the implementer's side of the boundary.

## W6. The class rule (needs the Reviewer's acceptance)

- A rejection names the **class** of the defect and every instance of it the Reviewer
  sees, and carries the Reviewer's reproduction (script or commands). The implementer
  uses it as the negative control.
- A second rejection in the same class stops the code. The implementer writes a design
  of at most 20 lines (the invariant plus the full path map); the Reviewer rules on the
  design; only then the third round.

## W7. Green means zero failures

A known failure is either fixed in the current batch or marked expected-fail with a
backlog number and counted apart. A run with `FAIL>0` on `main` is red and needs no
explaining. (Open: the pair "P -R -e over scaffolding" in `test/snapsend` still fails on
every run; it is the first to be fixed or marked.)

## W8. What was removed, and what holds its place

| removed | what it was for | what enforces that now |
|---|---|---|
| PROJECT_STATUS digest (`status-covers-digest`, `--refresh-status`, obligation `project-status`) | the status text follows the code | `docs/STAN.md`, at most 150 lines, refreshed once per release |
| ENGINE-FREEZE (`frozen:` markers, `--refreeze`, the `twin:` line) | no silent engine change | `release/coverage-gate.sh`: no changed shipped file is published outside a submitted, reviewed range; it has no override |
| the `file:line` in a twins `direction:` reason | a checkable reason | one sentence; the hash check and sections A-M of `test/twins` are unchanged |
| two ledger read-backs per round through pve9 | whose move | CI job `ledger` on every push and PR |
| `gate-runner` agent | explaining a gate's drift report | the gate's own output |

## W9. Documents

- This file is the rule text. `PROTOCOL.md` stays as the definition of the states, the
  headers and the release gates, and as history.
- `docs/STAN.md` is the current state. `docs/PROJECT_STATUS.md` is frozen at 2026-11-13
  and kept as history.
- `text-checker` runs on the response and on release notes.
- The error log gets an entry when a mistake produces a new rule or repeats an old one.
