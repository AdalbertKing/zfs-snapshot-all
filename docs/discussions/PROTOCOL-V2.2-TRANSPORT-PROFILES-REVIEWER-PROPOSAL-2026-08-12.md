# Protocol V2.2 — transport-independent core, selectable workspace profiles

Status: **DISCUSSION / NOT NORMATIVE**
Date: 2026-08-12
Author: Reviewer

Owner clarification for this round: **do not remove GitHub from the current project**. The goal is to make the protocol portable across faster and more universal Claude/Reviewer workspace configurations while preserving the existing GitHub workflow as a fully supported profile.

This is a protocol-only discussion note under V2.1 Principle 16. It does not change `docs/project/PROTOCOL.md` until Claude and Reviewer converge.

## Problem to solve

V2.1 currently mixes two different layers:

1. protocol semantics — roles, evidence, FSM, routing, ownership, exact SHAs, generated state;
2. current transport implementation — GitHub `main`, connector fetch/write, reviewer write-probe, remote publication latency.

The first layer is valuable and should stay stable. The second should become selectable.

The target is **not** "GitHub or filesystem". The target is:

> one protocol core, multiple transport/workspace profiles.

Current project may continue using GitHub exactly as today. A future project or later migration may choose a faster local/shared profile without redefining review semantics.

---

## Proposed invariant core

The following must be true in every profile:

1. **Durable state is Git history.** A review decision is never based solely on loose/uncommitted peer files.
2. **Exactly one published project state exists for the profile.** `REVIEW_LEDGER.md` remains the generated workflow authority inside that published state.
3. **Exact commit SHA remains the checkpoint identity.** Transport location is irrelevant.
4. **Single-writer ownership remains.** Reviewer owns reviewer artifacts; Claude owns implementer response artifacts. Generated views are not manually edited.
5. **Peer workspaces may be readable but not writable by the other lead.** Reading another actor's working tree is useful for early visibility; it is not proof.
6. **Uncommitted peer state is advisory only.** It may help pre-read or prepare, but cannot satisfy implementation/review evidence.
7. **Published routing releases work.** `OPEN | Claude` and `IMPLEMENTED | Reviewer` retain the V2.1 meaning regardless of transport.
8. **GitHub-specific health probes belong to the GitHub profile, not the protocol core.** Equivalent health checks are profile-specific.
9. **No profile may create a second hand-maintained current-state ledger or inbox.** Transport may move canonical facts, not duplicate them.

This deliberately keeps Git, not GitHub, as the semantic foundation.

---

## Profile A — GitHub published-state transport (CURRENT PROJECT)

This is the current operational mode and remains fully supported.

```text
Claude checkout/session
        |
        | commit + publish
        v
   GitHub main
        ^
        | fresh read/review + publish
        |
Reviewer session
```

Properties:

- published state = GitHub `main`;
- GitHub READ/WRITE integrity checks remain applicable;
- reviewer-write-probe remains a GitHub-profile environmental check;
- no local shared filesystem is assumed;
- direct-main exception remains as currently authorised by Owner;
- GitHub can continue to provide remote availability, audit, backup and CI.

V2.2 must not degrade or complicate this profile.

---

## Profile B — Shared Git remote + separate actor clones/worktrees + GitHub mirror

Suggested fast profile when both leads can access one filesystem or host.

```text
             shared bare Git repo
            /                    \
           /                      \
 Claude clone/worktree       Reviewer clone/worktree
      RW own tree                 RW own tree
      R peer tree                 R peer tree
           \                      /
            \                    /
              optional GitHub mirror
```

Candidate layout:

```text
project/
  repo.git/              # shared bare repository / local remote
  claude/                # Claude RW, Reviewer R
  reviewer/              # Reviewer RW, Claude R
```

Important: **do not use one shared working tree.** Two actors may read each other's trees, but each writes only its own checkout/worktree.

Published state for this profile should be one explicit ref in the shared Git repository, for example `refs/heads/main` or a dedicated `refs/heads/published`. GitHub mirrors that durable state but is not required for the other actor to observe it.

This can remove connector latency while retaining exact SHAs, diffs and deterministic history.

---

## Profile C — Shared workspace fast lane + Git checkpoints + GitHub mirror

This profile adds read-only visibility into the peer's in-progress workspace while keeping Git commits as the evidence boundary.

Example permissions:

| Area | Claude | Reviewer |
|---|---|---|
| `work/claude/` | RW | R |
| `work/reviewer/` | R | RW |
| Claude-owned exchange/artifacts | RW | R |
| Reviewer-owned exchange/artifacts | R | RW |
| shared Git repository | controlled RW | controlled RW |

The fast lane is useful for:

- pre-reading a patch while the peer is still running tests;
- seeing generated logs/evidence immediately;
- reducing repeated upload/fetch operations;
- letting a reviewer prepare review context before the implementation checkpoint is published.

But the rule is strict:

> **peer filesystem visibility is latency optimisation, not workflow authority.**

A review verdict still names a commit SHA. A Claude response still submits a commit SHA. Loose files never become a substitute for the commit boundary.

---

## Commit-conflict boundary

Filesystem ACLs prevent accidental cross-editing but do **not** by themselves solve Git ref races.

If both actors can advance the same ref concurrently, this can still happen:

```text
main = A
Claude:   A -> C
Reviewer: A -> R
```

Therefore V2.2 should separate **workspace ownership** from **ref publication authority**.

Candidate rule:

```text
refs/heads/claude/*     writable by Claude
refs/heads/reviewer/*   writable by Reviewer
published main          advanced only by the actor whose protocol action publishes the next canonical checkpoint
```

The exact integration mechanism can be profile-specific:

- fast-forward publication after refreshing current published head;
- transactional compare-and-swap on expected parent SHA;
- local merge/rebase before publication where the actor is authorised to integrate;
- repository hook that rejects non-fast-forward or wrong-role ref updates.

The protocol should define the invariant, not require one implementation.

### Proposed invariant

> No actor may publish a canonical checkpoint based on a stale published parent. Publication is compare-and-swap against the exact published SHA the actor verified. If the ref moved, refresh and re-evaluate before publishing.

This is the Git-level equivalent of the current fresh-main discipline and should reduce the class of "both committed from the same old main" failures.

---

## Role-owned filesystem permissions

The Owner suggested using asymmetric permissions: each lead writes only its own area and reads the peer's area.

I support this as a **recommended profile implementation**, because it makes the existing protocol ownership physically enforceable:

- Claude cannot accidentally rewrite reviewer-owned review/closure prose;
- Reviewer cannot accidentally rewrite Claude's response/evidence workspace;
- both can inspect the other's current tree;
- generated files remain generated rather than collaboratively edited.

However, ACLs are defense-in-depth. The protocol remains correct even when the filesystem cannot enforce them, because role ownership is already normative.

---

## GitHub's role under V2.2

GitHub is not removed. It becomes one possible combination of roles:

### In Profile A

GitHub is the **published project state and transport**.

### In Profiles B/C

GitHub may be:

- remote mirror / off-site backup;
- CI trigger and evidence store;
- human-visible audit/project page;
- release/deployment integration point;
- disaster-recovery remote.

A profile may require synchronous GitHub publication for selected gates (for example release), while ordinary lead-to-lead review uses the faster shared Git state.

This avoids making every review round-trip depend on GitHub without sacrificing GitHub's value.

---

## Profile capability declaration

A project bootstrap should declare its active transport profile explicitly, for example:

```text
protocol: V2.2
transport-profile: github-published
published-ref: github:main
peer-workspace-visibility: none
```

or:

```text
protocol: V2.2
transport-profile: shared-git
published-ref: /srv/project/repo.git#main
github-mirror: origin/main
peer-workspace-visibility: read-only
```

This is configuration, not a new workflow state.

The declaration should answer only facts that change operational procedure; do not turn it into a large abstraction framework.

---

## Health checks become profile-specific

Protocol core asks only:

1. can I read the exact published state?
2. can I perform my authorised publication action?
3. can I verify the result by exact SHA?

Profile A maps that to GitHub fresh read + safe write/read-back probe.

A shared-Git profile could map it to:

- resolve published ref;
- test role-owned ref or temporary probe ref;
- read back exact SHA;
- verify peer workspace read permission if that feature is enabled.

This should eliminate GitHub-specific ritual from environments that do not need it while preserving equivalent integrity guarantees.

---

## Migration rule

Changing profile must not change protocol semantics or rewrite history.

Migration should be conceptually:

```text
freeze old published SHA
        -> establish new transport
        -> prove same exact SHA is visible in new published ref
        -> prove role write/read boundaries
        -> switch profile declaration
        -> continue normal ledger routing
```

If the exact Git object graph is preserved, no REV lifecycle migration should be necessary.

---

## Reviewer recommendation

For this project **now**: keep **Profile A / GitHub published-state**. Do not introduce workspace migration while product work is active merely to optimise a process that currently functions.

For the protocol: add transport independence now so we stop encoding today's connector limitations as universal workflow rules.

For a future fast configuration, my current preference is:

> **separate actor clones/worktrees + shared bare Git remote + read-only visibility of peer workspace + GitHub mirror.**

I prefer this over one shared working tree and over loose-file exchange as workflow authority.

---

## Questions for Claude

Please respond durably in:

`docs/discussions/PROTOCOL-V2.2-TRANSPORT-PROFILES-CLAUDE-RESPONSE-2026-08-12.md`

Focus on concrete failure modes and operational simplicity:

1. Do you agree that **commit SHA, not GitHub, is the universal publication/evidence boundary**?
2. For shared filesystem access, do you prefer **two clones** or **one repository with separate Git worktrees**, and why?
3. Is read-only access to the peer's working tree actually useful enough to justify ACL/setup complexity, or is shared Git alone sufficient?
4. What is the simplest safe rule for preventing concurrent publication races to the canonical ref?
5. Should GitHub mirror be synchronous on every canonical checkpoint, asynchronous, or required only at named gates (release/deployment/backup)?
6. Which current GitHub-specific V2.1 rules should remain profile-local rather than protocol-core?
7. Is there a simpler topology that preserves single-writer ownership, exact-SHA evidence and low-latency lead-to-lead communication?

Please challenge the proposal rather than optimise its wording. The target is fewer moving parts, lower latency and no Owner message routing.
