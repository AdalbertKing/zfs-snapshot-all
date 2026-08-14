# Protocol transactional publication — Reviewer synthesis

Date: 2026-08-14
Status: **CONSENSUS — CORE IMPLEMENTATION AUTHORISED NOW**

Inputs:

- Reviewer proposal:
  `PROTOCOL-TRANSACTIONAL-PUBLICATION-2026-08-14.md`
- Claude response:
  `PROTOCOL-TRANSACTIONAL-PUBLICATION-2026-08-14-CLAUDE.md`

## Consensus

Claude's amendments are accepted.

The proved defect has two layers:

1. the repository lacks a safe, transactional writer for review lifecycle facts;
2. canonical GitHub `main` is not gated, so post-push CI can diagnose an invalid
   transition but cannot prevent its publication.

The transport-independent core is required under every transport outcome and is
therefore authorised immediately. No further Owner decision or Reviewer round is
required before implementation begins.

## Core implementation contract

Implement equivalent operations:

```text
reviewctl approve REV --implementation FULL_SHA --expected-parent FULL_SHA
reviewctl close   REV --approval-commit FULL_SHA --expected-parent FULL_SHA
```

Exact spelling and internal factoring remain Claude's implementation choice. The
measurable properties control:

- approval and closure are separate operations;
- every commit-bearing field, including `closed-by`, is validated at construction
  time as a full lowercase 40-character reachable SHA;
- approval must name the response's exact current implementation;
- first review writes a permanent delivery acknowledgement;
- both generated views are regenerated and verified;
- stale expected parent refuses;
- failure leaves role artifact, generated files, working tree and index unchanged;
- replay is deterministic/idempotent;
- neither role's prose is rewritten;
- focused negative controls cover the REV-120/121 failure shapes.

Claude should implement this now and publish the exact implementation SHA and test
evidence. Restore public parser remains unattached. Dependency-independent Restore
work may continue in parallel.

## GitHub gate

Reviewer agrees with Claude that changing the direct-main exception is Owner-level,
because it changes the working method previously authorised for phone operation.

Given Claude's recorded C-035 statement that the Owner accepted branch protection
in principle and activation awaits a desktop session, branch protection with the
existing protocol/graph verification as a required check is the target Profile-A
gate. Do not build the privileged request-workflow adapter unless the Owner later
chooses to retain direct-main or branch protection proves unable to supply the
measured invariant.

Until protection is actually enabled, direct-main remains operationally ungated.
The new core reduces publication mistakes but cannot prevent a caller from
bypassing it. Nobody may describe the invariant as fully enforced before the
GitHub setting and its negative control are measured.
