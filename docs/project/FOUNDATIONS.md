# PRODUCT / REVIEW FOUNDATIONS

Status: **ACTIVE — OWNER DIRECTION**
Date: 2026-08-11

This file contains cross-cutting product and review invariants that apply to every
phase. It does not define work sequencing or REV state. Sequencing remains in
`ACTIVE-WORK-PLAN.md`; review routing remains generated from Review Protocol V2.

## Foundation — every managed resource has a bounded lifecycle

A successful one-shot operation is not sufficient proof of a correct system.
Anything the product creates, accumulates, schedules or leaves behind must have
an explicit lifecycle.

For every automatically managed resource, the design and review must answer:

1. **Ownership** — who creates it and which relationship/task owns it?
2. **Bounded growth** — what prevents unbounded accumulation under normal
   repeated operation? If growth is intentionally unbounded, that is an explicit
   product/risk decision, never an accidental default.
3. **Cleanup path** — who removes/compacts/expires it, from which control plane,
   and under what policy?
4. **Failure behavior** — what happens if transfer/cleanup/scheduling is broken
   for longer than the normal cadence or retention window?
5. **Scope safety** — cleanup scope must never be broader than the resource scope
   actually owned by that task/relationship.
6. **Removal behavior** — what remains after pause, disable, relationship removal,
   migration or partial failure, and who owns any residue?

The mandatory review question is:

> **What happens after 1000 successful/failed/mixed runs?**

The exact number is not a benchmark. It forces review of steady-state behavior,
resource growth and cleanup instead of validating only the first successful run.
For high-risk stateful paths, replace the thought experiment with a targeted
multi-generation/live test appropriate to the risk.

### Evidence rule

For recurring or state-creating functionality, evidence must cover the lifecycle
property, not only syntax or generated command text. Where applicable prove:

- repeated creation converges to a bounded steady state;
- cleanup preserves foreign/manual resources;
- cleanup scope equals or is narrower than ownership/backup coverage;
- outage/retry behavior does not silently destroy the only recovery/incremental
  base or grow forever;
- removal/disable does not leave a forgotten autonomous producer or cleaner;
- source-side and target-side lifecycle policies are independent when they serve
  different roles.

### Applies broadly

This rule is not snapshot-specific. It applies to, among other things:

- ZFS snapshots and bookmarks;
- staging/temporary datasets and receive state;
- logs, queues, locks and state markers;
- generated config/cron residue;
- retained technical anchors for offline/removable replicas;
- any future periodic cache, index, spool or history object.

### Origin of the rule

REV-20260811-102 exposed the missing invariant: the default backup path could
create managed hourly snapshots on a production source without a default source
cleanup owner, so the source could grow until pool exhaustion while transfer and
target-retention tests remained green. The lesson is generalized here so the
same class of defect is caught before implementation in other subsystems.

This foundation is deliberately small: **ownership + bounded growth + cleanup +
failure behavior + exact scope**. Do not create a new lifecycle framework merely
to satisfy it; use the existing CONFIG/control-plane primitives wherever they
already express the property.
