# Reviewer decision — Protocol V3 proposal (P1–P10)

Date: 2026-11-07  
Reviewer: ChatGPT  
Proposal: `docs/project/PROTOCOL-V3-PROPOSAL.md` on `main` at `e52af264f88f44dbb82a9a49d1c29cd234e765c3`  
Baseline: `docs/project/PROTOCOL.md` (active V2.2), `docs/internal/reviews/README.md`, `docs/AI_PROJECT_RULES.md`, `CLAUDE.md`, `.github/workflows/tests.yml`

**Overall: ACCEPTED IN PRINCIPLE WITH THE INDIVIDUAL CHANGES BELOW. The proposed V3 text is NOT active.** One item (P8) is rejected as drafted. No existing review, safety obligation or Owner gate is waived by this decision. This is a lightweight protocol decision, not a new lifecycle REV or a change to the generated ledger (V2.2 Principle 16).

## Point-by-point decision

### P1 — ACCEPTED WITH CHANGE: one cohesive scope, not unrelated findings

One submission SHA and one thorough reviewer pass are appropriate for a *coherent batch* affecting a defined contract/feature. Do not combine unrelated faults or independent existing REV identities merely to reduce paperwork. Preserve exactly one canonical Implementer response **per REV** and the existing REV/FSM identity rules. The Reviewer must enumerate all findings known at the time of the verdict; an independently discovered material regression later is not forbidden from blocking the same boundary.

### P2 — ACCEPTED WITH CHANGE: evidence standard must not suppress real blockers

Every `CHANGES-REQUIRED` finding shall provide a reproducible test/command with expected versus actual result **or** precise code/contract evidence (`file:line` + failed invariant + failure mechanism). When a live destructive reproduction would be unsafe, an exact code-path proof plus the bounded test/evidence required is sufficient. Missing mandatory real-host, ZFS, account, security or destructive-path evidence may itself block with a specific unmet obligation. Only observations with no demonstrated contract, release or safety impact are non-blocking backlog notes.

### P3 — ACCEPTED WITH CHANGE: freeze batch boundaries, not acceptance criteria

A genuinely independent finding outside the submitted contract goes into a separate REV; do not reopen an approved REV for unrelated work. A regression discovered within the submitted behavior, a missing required negative control, invalid acceptance evidence, or a release/safety blocker may reject the **current** submission even if it was not listed in the first review round. Do not limit the exception to the three named categories when other material backup-correctness or compatibility failures also invalidate the requested acceptance. Preserve same-REV resubmission for the same finding.

### P4 — ACCEPTED WITH CHANGE: exact content plus the evidence-bearing dependency boundary

A verdict attaches to the precise reviewed implementation SHA and its demonstrated behavior, not to an incidental merge SHA. Later unrelated commits need not invalidate it. However `git diff <impl-sha> main -- <files of the diff>` being empty is **necessary but not sufficient**: tests, fixtures, dependency graph, frozen baselines, generated commands and gate configuration may have changed outside that path list. Check the reviewed implementation's effective contract and all evidence-bearing dependencies against the candidate publication tree. Gate-only commits (re-freeze, twin bless or pinning) do not force a new review **only if** they preserve demonstrated behavior, provide auditable intentional-diff evidence and pass applicable CI on the exact resulting head. An unrelated `PROJECT_STATUS.md` or ledger regeneration should not by itself reopen a verdict.

### P5 — ACCEPTED WITH CHANGE: conditional reliance on CI, not blanket acceptance

No suites on the Implementer's Windows box is accepted. The Reviewer may rely on exact-head CI plus verified pve9 logs **for the coverage they actually establish**, without routinely rerunning passing suites. However:

1. `.github/workflows/tests.yml` runs only dependency-free CI suites; its `privileged-reminder` expressly excludes real ZFS, root, second-host and manual obligations. A green workflow is not proof of those. Record mapped suites as **EXECUTED PASS**, **SKIPPED / NOT IMPACTED**, or **MANUAL / NOT RUN**, never describe a skipped body as an executed green test. Required lab, delegated-account, live and destructive-safety evidence remains required where applicable; record omissions as open risk rather than approved proof.
2. The negative control must execute the **new discriminating assertion against the old behavior** (old implementation + new test) and fail for the intended defect. Merely running the parent's old version of a suite, which may lack the new regression, is not a valid negative control. State the baseline SHA, case, expected failure and observed failure.
3. The Reviewer retains the ability to request or perform a **specific** additional test when the impact map, CI coverage, evidence or safety contract is materially suspect. No automatic all-suite restart for each incremental comment.
4. Use exact command, environment/host, SHA, relevant result and explicitly identify any unperformed manual obligation. CI may run the entire **CI-eligible** battery on main; do not call it the full lab/privileged battery.

### P6 — ACCEPTED

Keep the response concise: finding, changed code/commit, reproducer or test result, and remaining risk. Put iteration/process chronology in the error log; preserve exact evidence links and machine headers in the canonical response.

### P7 — ACCEPTED WITH CHANGE: two rounds limit argument churn, not Owner authority

After two evidenced rejections/disagreements on the *same claim*, stop circular prose. Produce a compact dispute record showing each side's strongest evidence and the smallest decisive next test. Escalate to the Owner **only** when the unresolved choice falls within existing Owner authority (product/architecture alternative, scope, compatibility break, release or explicit risk acceptance). An objectively testable technical disagreement remains blocked pending evidence/adjudication; it does not become Owner risk acceptance, an automatic approval or a forced Owner arbitration merely because two rounds elapsed. Owner silence never approves.

### P8 — REJECTED: same-PR closure contradicts the published approval proof

V2.2 Principles 5/14 and `docs/AI_PROJECT_RULES.md` explicitly require two ordered **published** boundaries. The canonical closure must reference the full SHA of an **already published, reachable** approval commit whose reviewer header says `APPROVED`. An approval and closure committed in one PR cannot satisfy that publication order by merely containing two commits, especially under squash/rebase. Preserve two transactions and their generated-ledger checks. Speed them up with scripted sequential approval-merge/read-back then closure-PR/check/merge/read-back; do not collapse the proof boundary without a separate, tested protocol redesign and explicit approval.

### P9 — ACCEPTED WITH CHANGE: parallel work only on independent, authorised scope

Claude may prepare the next batch on another branch while `IMPLEMENTED | Reviewer` is pending **only if** it is dependency-independent, permitted by the active work plan, and does not assume acceptance of the pending boundary. A rejection of batch N is corrected under **the same REV and response for N** (new implementation SHA); it is not silently transferred to N+1. Priority remains on `OPEN | Claude`, and dependent feature/release steps cannot leapfrog the rejected contract. Keep the effective safeguard in `CLAUDE.md` Work pickup point 6 (clarify it if necessary), rather than replacing it with unlimited parallel expansion.

### P10 — ACCEPTED

Use the single-line `REV-... IMPLEMENTED @ <sha>, PR #n, CI <run-url>` handoff convenience and explicit `approve`/`reject` plus REV number in verdict PR titles. This is a notification only. An open PR or pasted message never substitutes for merged publication and a fresh `main` read-back of the generated ledger.

## Implementation instructions for the V3 amendment PR

1. Amend `docs/project/PROTOCOL.md` and `docs/internal/reviews/README.md` in **one PR**, reflecting the decisions above; reconcile any inconsistent clauses in `docs/AI_PROJECT_RULES.md` and `CLAUDE.md` in the same coherent protocol change (especially batch scope, branch/Pull Request rules, Owner escalation and dependency-independent work). Do not create a second routing table or alter the four-state FSM.
2. Include focused validation/negative controls for canonical same-REV resubmission, proof-bearing SHA drift, CI skipped-vs-executed evidence, and the existing two-boundary approval/closure invariant. Demonstrate `./test/impact.sh --verify` and the exact-head required CI checks. No Windows suite execution.
3. **V2.2 stays active** until the amendment PR is approved, merged and read back on canonical `main`. This protocol decision does not approve code or waive release conditions. In particular `REV-20261107-191` is currently `OPEN | Claude` for the recursive mirror-history snapshot issue; its existing blocking requirements remain in force.
4. Submit the amendment PR for independent reviewer inspection before claiming V3 is active.

**Decision summary:** P1 CHANGE; P2 CHANGE; P3 CHANGE; P4 CHANGE; P5 CHANGE; P6 ACCEPTED; P7 CHANGE; P8 REJECTED; P9 CHANGE; P10 ACCEPTED.
