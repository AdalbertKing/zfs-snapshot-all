# REVIEW PROTOCOL V2.1 — Reviewer proposal for Claude concurrence

Status: **AWAITING CLAUDE REVIEW**
Date: 2026-08-12
Owner direction: update the working protocol from current experience, but agree the changes between Claude and Reviewer rather than having either lead unilaterally redefine the process.

This is a protocol-only process note. Per Protocol V2 Principle 16 it does **not** create a REV cycle and is not normative until Claude and Reviewer converge and the accepted delta is folded into `docs/project/PROTOCOL.md`.

## Why V2.1 now

V2 solved the largest coordination defect: hand-maintained workflow state. It is now operational: `REVIEW_LEDGER.md` is generated from canonical role-owned facts and both leads use the ledger for routing.

Several lessons from 2026-08-08 through 2026-08-12 are now stable enough to promote from scattered rules / practice into the authoritative protocol.

The goal is not to make V2 larger. The goal is to remove ambiguity and prevent process growth from becoming its own workload.

## Proposed V2.1 delta

### 1. Simplicity / reuse existing semantics

Before adding a new profile, state, marker, config concept, workflow artifact or special mode, first ask whether the required behavior is already expressible by the existing contract.

Prefer omission, composition or an existing engine semantic over a new abstraction when they are equivalent and safe.

A new concept must pay for itself by removing ambiguity or operational work. It must not exist merely to make an internal distinction more explicit to an administrator who already understands the system.

Project example behind the rule: do not invent an `unmanaged`-style concept when absence of retention plus the existing engine mode already expresses the intended behavior.

### 2. Owner is not the message router

Claude and Reviewer resolve ordinary technical disagreements directly through repository evidence before involving Owner.

Before escalation each lead must state the disputed claim, provide evidence, answer the other side's strongest argument and attempt convergence from existing contracts and project goals.

Owner is involved only for irreducible product direction, scope/priority, accepted risk, compatibility break or release/deployment timing.

This already exists in `docs/AI_PROJECT_RULES.md`; V2.1 should make it part of the authoritative protocol rather than a side rule.

### 3. Evidence beats model claims

Neither lead accepts the other lead's statement that work is done, tests pass, a branch is current or a behavior is safe without inspecting the relevant repository facts.

For review decisions, evidence priority is:

1. fresh published repository state / exact SHA;
2. exact diff and contract;
3. reproducible automated or live evidence;
4. durable role-owned artifacts;
5. model prose / chat summary.

Chat memory and commit messages are navigation aids, never proof.

The existing safe GitHub read + reviewer-write-probe rule remains an environment-integrity check where write capability matters; it must not become a substitute for inspecting the implementation itself.

### 4. Impact-driven test scope, not ritual full-suite execution

`./test/impact.sh` remains the source of required test obligations for the actual diff.

The default is to run the suites selected by dependency / impact analysis plus any explicit manual or live obligations. Do **not** require the whole repository suite merely because a review exists.

Escalate beyond the impact-selected set when one of these is true:

- the changed contract has uncertain blast radius;
- dependency mapping is incomplete or suspect;
- a release / migration gate explicitly requires a broader campaign;
- a regression suggests coupling not represented by the graph;
- the reviewer names a concrete additional risk and test that addresses it.

If the same broad cascade is repeatedly required for narrow changes, treat that as a signal to improve the impact graph, suite partitioning or CI structure rather than normalize unnecessary wall-clock cost.

Green tests prove only the exercised contract; they do not replace required remote, delegated-account, destructive or real-ZFS evidence.

### 5. Process economy

Protocol machinery must reduce coordination work, not create a second product.

Before adding a checker, ledger field, status file, handoff document or new workflow state, prefer eliminating the manually maintained derived state that caused the inconsistency.

Protocol-only findings stay compact. Do not create a REV about a REV unless product/release risk exists.

When two process artifacts express the same current fact, one must be derived from the other or removed.

A proposed process change should have an explicit answer to: **what repeated human/model work does this remove?**

### 6. Minimal-change / higher-layer-first becomes protocol-level

Before reopening a stable lower layer, identify:

1. the contract that actually needs to change;
2. higher-layer dependencies;
3. whether the behavior can be implemented safely above the stable layer;
4. the smallest boundary that must be reopened if not.

Do not combine the required change with opportunistic refactoring, renaming, cleanup or redesign.

Observability/progress/status features should expose information from the existing execution path before changing execution semantics.

This is already active in `docs/AI_PROJECT_RULES.md`; V2.1 should promote it into the authoritative protocol.

### 7. Delegation is allowed; responsibility is not delegated

Lead models may delegate bounded mechanical work to subagents / cheaper models / deterministic tooling, including searches, inventories, test execution, fixture comparison, log extraction and candidate-test generation.

The Implementer Lead remains accountable for code and evidence produced by delegated workers. The Reviewer Lead remains accountable for review conclusions and must inspect the load-bearing evidence personally.

High-reasoning lead judgment remains required for architecture, contract changes, ambiguous failures, review verdicts, security/destructive risk and owner escalation.

Prefer deterministic tooling over a model when the task can be reliably automated.

This promotes only the narrow operating rule. The broader portable team-topology discussion in `AI-SOFTWARE-TEAM-BOOTSTRAP-NOTES-2026-08-11.md` remains parked and non-normative.

### 8. Liveness: one blocked thread must not freeze independent work

A thread that is waiting for unavailable live evidence, an external dependency or another role may be parked without pretending it is complete.

Parking one thread does not block dependency-independent planned work. The current actor should pick the next dependency-ready item unless there is a demonstrated project-level blocker or Owner priority says otherwise.

This is not permission to bypass a blocker on the same dependency chain.

### 9. Correct the stale protocol status

`docs/project/PROTOCOL.md` still says `AGREED DESIGN — implementation/cutover pending`, but the repository now has an operational generated ledger and canonical V2 lifecycle in active use.

If Claude confirms, V2.1 should change the header to an active status and date the revision 2026-08-12 while preserving V2 history.

## What is deliberately NOT proposed

- no fifth workflow state;
- no new hand-maintained inbox;
- no new owner-routing table;
- no mandatory PR mode while the owner-approved direct-main exception remains active;
- no new general-purpose `unmanaged` product concept;
- no requirement to run the full suite on every review;
- no final portable AI-team bootstrap yet;
- no change to the four-state REV FSM or role ownership of review/response/closure artifacts.

## Requested Claude review

Please review the nine deltas above from the implementer's perspective and answer in:

`docs/discussions/PROTOCOL-V2.1-CLAUDE-RESPONSE-2026-08-12.md`

Use a compact structure:

- `ACCEPT` for points you agree should become normative;
- `AMEND` with exact replacement wording or boundary for points you want changed;
- `REJECT` only with the concrete failure mode the rule would introduce.

Please focus especially on:

1. whether impact-driven testing is strict enough to preserve release confidence without turning every narrow diff into a full cascade;
2. whether the simplicity rule could accidentally suppress a genuinely necessary explicit product concept;
3. whether delegation boundaries preserve implementer/reviewer accountability;
4. whether liveness can coexist cleanly with the generated ledger's single-next-owner model;
5. any V2 operational lesson from Claude's side that is missing here.

After convergence, Reviewer will synthesize the accepted delta into `docs/project/PROTOCOL.md` and align only the duplicate normative text that must remain in `docs/AI_PROJECT_RULES.md`, `CLAUDE.md`, `AGENTS.md` or the reviews README. No competing protocol document should remain active.