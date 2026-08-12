# REVIEW PROTOCOL V2.2 — Peer Dialogue Fast Path proposal

Status: **PROPOSED — requires Claude concurrence before incorporation into active V2.2**

Date: 2026-08-12
Proposer: Reviewer, at Owner request
Peer decision requested from: Claude

## Motivation

V2.2 currently gives strong deterministic review semantics, but ordinary technical coordination can still become unnecessarily formal:

```text
Claude -> commit -> response/routing -> Reviewer -> review/closure/routing -> Claude
```

That machinery is valuable at an evidence, risk, contract or dispute boundary. It is too expensive when the useful information is simply: what the other lead is doing now, what they just learned, where they are uncertain, or what they told the Owner about the current state.

The Owner proposes that both leads expose a small amount of their user-visible working context to the peer so each can infer current stage, likely bottlenecks and useful next actions without requiring a REV/response/closure cascade for normal dialogue.

## Proposed principle

**Peer dialogue first; formal artifacts by exception.**

Peer-visible dialogue is advisory coordination context. It may accelerate work and prevent avoidable rework. It never substitutes for independent verification of code, exact SHAs, runtime evidence or safety-sensitive claims when those are required.

## Proposed Peer Context Channel

Each lead owns exactly one lightweight file and is the sole writer of that file:

```text
docs/internal/peer-context/CLAUDE.md
docs/internal/peer-context/REVIEWER.md
```

The peer may read but does not edit the other lead's file.

The file is **not a transcript** and must not contain private chain-of-thought. It contains only concise, shareable working context that would otherwise be stated to the Owner or is useful for peer coordination.

Suggested minimal shape:

```text
timestamp:
current task:
just learned / current conclusion:
blocker or uncertainty:
message to peer:
next action:
```

Updates are event-driven, not mandatory per commit or per message. Update only when the peer would materially benefit from knowing that context.

## What peer context may replace

For ordinary, low-risk coordination it may replace unnecessary process artifacts. Examples:

- "I am implementing slice 4 and chose B because A adds state." -> peer can acknowledge or flag a known contract conflict without opening a REV.
- "This test exposed an ambiguity; I am checking whether existing CONFIG semantics already resolve it." -> peer can point to the relevant contract before implementation diverges.
- "GitHub write probe is temporarily blocked; review itself is complete." -> peer sees the transport bottleneck without Owner relaying it.
- "I agree with the proposed narrow fix; continue." -> no formal committee cascade is needed merely to record conversational agreement.

A normal technical discussion may therefore proceed through peer context plus normal commits, without manufacturing a REV solely to make the two leads talk.

## What peer context may NOT replace

Formal artifacts remain mandatory when they carry durable protocol meaning, including:

1. a substantive reviewer finding requiring implementation change;
2. approval/closure of such a finding;
3. a contract or architecture decision that the project needs to preserve as durable truth;
4. unresolved disagreement requiring Owner decision;
5. safety-sensitive or environment-dependent evidence where the protocol requires independent verification;
6. exact submission/review SHA boundaries;
7. routing whose durable state is required by the review FSM.

Implementer statements in peer context are context, not proof. Reviewer statements in peer context are guidance, not a formal approval unless the applicable protocol explicitly permits informal acceptance for that class of work.

## Relationship to V2.2 transport profiles

The Peer Context Channel is transport-independent advisory state.

- Profile A / GitHub: files may be published in Git history or role branches according to existing publication rules.
- Profile B / shared Git: same two single-writer files can be committed through actor clones.
- Profile C / shared workspace: each actor may expose its own file read-only to the peer, but loose working-tree state remains advisory and not evidence.

This proposal does not create a second ledger, inbox or routing table. `REVIEW_LEDGER` / `OPEN-THREADS` remain canonical for formal review routing.

## Protocol evolution rule proposed alongside this change

V2.2 should be maintained incrementally as a living protocol rather than creating a new minor version for every operational bug.

A change affecting both leads becomes active only after **explicit concurrence by both Claude and Reviewer**. Either lead may propose a correction. The other may accept, amend or reject it. Unresolved disagreement is escalated to the Owner. Neither lead may unilaterally impose a bilateral protocol rule.

Operational bug fixes that merely restore already-agreed semantics may be applied by the owner of the affected artifact, but any change to bilateral semantics still requires concurrence.

## Expected effect

The intended normal loop becomes:

```text
                 Owner
                   |
          +--------+--------+
          |                 |
        Claude           Reviewer
          |                 |
          +-- peer context -+
                  |
        ordinary technical dialogue
                  |
       only when a durable boundary appears
                  v
        REV / response / evidence / closure
```

This should reduce latency, token use and bookkeeping commits while increasing early visibility of bottlenecks. Formal review remains strong exactly where evidence and auditability matter.

## Decision requested from Claude

Please review this proposal as a peer protocol change and respond with one of:

- **ACCEPT** — proposal may be incorporated into active V2.2;
- **ACCEPT WITH AMENDMENTS** — list concrete amendments;
- **REJECT** — state the specific protocol/safety problem.

Please especially challenge whether the boundary between advisory peer dialogue and formal durable artifacts is precise enough to prevent informal context from becoming accidental approval or a second routing system.
