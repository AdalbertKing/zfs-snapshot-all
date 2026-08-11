# AI software team bootstrap — parked notes for final protocol discussion

Status: PARKED / NOT YET NORMATIVE
Date: 2026-08-11

These notes collect side-discussion ideas that should be revisited only when the current project is mature enough for a final Claude + Reviewer retrospective. They are not active protocol requirements yet.

## Goal

Extract from this project a portable, self-contained Markdown bootstrap for a new software project using:

- Owner
- Implementer Lead AI
- Reviewer / Architect Lead AI
- optional subagents / cheaper models
- shared project state
- durable history and evidence

The final artifact should be usable in a completely new repository and new chats, with copy/paste startup prompts for both lead models.

## Final discussion topics to include

### 1. Roles, strengths and characteristic failure modes

The bootstrap should define not only authority, but working style and compensating controls.

Implementer Lead: fast codebase navigation and implementation, with a risk of local optimization / expanding blast radius unless contracts and higher-layer consequences are named first.

Reviewer Lead: independent contract/dependency analysis and adversarial verification, with a risk of review becoming an optimization target of its own, excessive follow-up/ping-pong, or stalling delivery after the load-bearing risk is already understood.

Owner: product direction, priority, risk acceptance and irreducible choices; not a message router between the AIs.

### 2. Workspace / transport topology must be configurable

Do not assume the current GitHub-centric topology is optimal. Compare at least:

- GitHub-centric asynchronous workflow;
- shared workspace + GitHub as durable checkpoint/history;
- cloud development workspace accessible to both leads;
- separate worktrees/branches + GitHub;
- reviewer with read/write access only to review artifacts versus own isolated worktree.

The final protocol should define an abstract `SHARED PROJECT STATE` and `DURABLE HISTORY`, then provide selectable deployment profiles rather than hard-coding GitHub as the only communication medium.

Key retrospective question for Claude and Reviewer independently:

> If we started this project today knowing all the synchronization, moving-SHA, write-probe, generated-view and local-vs-main issues we encountered, which topology would we choose and why?

### 3. Delegation to subagents and cheaper/lower models

The two strongest models should not mechanically perform every repository task.

Candidate delegation classes:

- repository-wide searches and inventories;
- mechanical diff classification;
- running test matrices;
- fixture comparison;
- extracting call/dependency graphs;
- log collection and summarization;
- repetitive documentation consistency checks;
- generating candidate test cases for lead review.

Core rule to consider:

> Delegate execution, not responsibility.

The Implementer Lead remains accountable for code produced by subagents. The Reviewer Lead remains accountable for review conclusions even when a cheaper model or agent gathered evidence.

The final protocol should specify when delegation is appropriate, what evidence a lead must inspect before accepting delegated output, and when a high-reasoning model is required.

### 4. Skills, Codex/workspace tools, CI and artifacts

The final retrospective should explicitly examine capabilities not substantially used in this project:

- reusable skills for repeatable procedures;
- coding/workspace agents such as Codex-style terminal access;
- CI as independent evidence and regression routing;
- generated artifacts such as diagrams, release reports and evidence bundles.

Do not adopt tools for novelty. Evaluate whether each reduces Owner effort, removes synchronization friction, lowers model cost, or improves evidence quality.

Artifacts must not become a second source of truth outside the repository/project state unless explicitly designed that way.

### 5. Cost-aware model routing

The final bootstrap should include a simple decision rule for task/model matching, for example:

- high-reasoning lead: architecture, contract changes, ambiguous failures, review verdicts, risk decisions;
- coding-capable mid model/agent: bounded implementation under an explicit contract;
- cheap/simple model: search, classification, mechanical transformation, report preparation;
- deterministic tools/scripts: anything reliably automatable without model judgment.

Avoid spending the strongest model on work that can be proved mechanically.

### 6. Liveness / unattended work

A parked review or unavailable live proof must not halt independent planned work. The final bootstrap must make continued work a positive action, not merely say that reviews "do not block".

After parking a non-executable thread, the current actor selects and executes the next dependency-ready planned item in the same cadence unless there is a demonstrated dependency blocker.

This matters especially for overnight/autonomous work.

### 7. Minimal-change / higher-layer-first

Carry forward the rule already added to `docs/AI_PROJECT_RULES.md`: before reopening a stable lower layer, identify the contract, higher-layer dependencies, whether the behavior can live above it, and the smallest necessary boundary.

Observability/progress work should first try to expose information from the existing execution path without redesigning its semantics.

### 8. Final portable artifact shape

Potential final filename:

`AI-SOFTWARE-TEAM-BOOTSTRAP.md`

Expected contents:

- project-state and source-of-truth model;
- Owner / Implementer Lead / Reviewer Lead roles;
- characteristic strengths and failure modes;
- startup prompts for both lead AIs;
- workspace/topology selection guide;
- review/evidence workflow;
- dependency/impact discipline;
- live-host/environment evidence rules;
- blocker scope and liveness rules;
- delegation and model-routing rules;
- skills/tools/CI/artifact guidance;
- escalation rules;
- project bootstrap checklist;
- compact examples of normal review, evidence debt and parked-thread continuation.

## Timing

Do not finalize this document now. Continue collecting lessons while the current project is active. Before producing the portable V1, Claude and Reviewer should each perform an independent retrospective, critique the current protocol/topology, discuss disagreements through repository artifacts, and only then synthesize the final bootstrap. Escalate to Owner only genuinely irreducible product/process choices.
