# Owner/reviewer resolution — atomic and flat recovery semantics

Date: 2026-08-12
Status: OWNER DIRECTION / RECOVERY CONTRACT

## Purpose

This resolves the recovery-planner questions discussed in reviewer R-010/R-011
and Claude C-009/C-010. The governing principle is reduction: restore retained
recoverable facts; do not build historical-topology reconstruction when the
operator's recovery intent can be satisfied directly from retained snapshots and
installed CONFIG.

## 1. Consistency mode comes from CONFIG, never snapshot names

The planner determines whether a relationship/recovery set is ATOMIC or FLAT from
the installed CONFIG semantics.

It MUST NOT infer atomicity from:

- matching snapshot names;
- matching prefixes;
- hierarchy shape;
- close creation timestamps.

Claude's real-estate measurement proved why: independently created flat snapshots
can share a generated name while differing in actual creation time.

## 2. ATOMIC semantics

ATOMIC means a Recovery Point.

For a selected atomic set:

- `latest` = newest COMPLETE atomic snapshot family available for every selected
  member required by that CONFIG shape;
- if the newest family is incomplete, choose an older complete family if one
  exists; otherwise REFUSE;
- never silently degrade an atomic recovery into per-member latest;
- partial selection is allowed (for example v1 + v3), but every selected member
  must be restored from the SAME atomic recovery point;
- each restored member is independently GUID-verified;
- whether the parent itself must carry data/snapshot is determined by the CONFIG
  include-parent semantics; a structural parent is not invented as protected data.

Snapshot names alone are not proof that members belong to one atomic family; the
planner must rely on CONFIG-declared atomic semantics and actual retained members.

## 3. FLAT latest semantics

FLAT means a Recovery Set / Frontier, not one point in time.

For every dataset currently available in the backup and selected for recovery:

- `latest` = that dataset's own newest valid snapshot;
- members may resolve to different snapshot names and creation times;
- preview MUST show the per-member mapping and MUST call it an independent/mixed
  frontier rather than an atomic recovery point;
- a parent with no snapshot can be structural only when CONFIG says the parent
  itself was not protected as data.

The planner primitive remains naturally:

```text
{ dataset -> snapshot, guid, creation, consistency=atomic|independent }
```

## 4. FLAT historical semantics at wall-clock T — deliberately simple

For WHOLE-FLAT historical recovery at requested time `T`:

```text
for every dataset currently available in the backup:
    select newest retained snapshot whose measured ZFS creation <= T
```

If one current backup dataset has no qualifying retained snapshot <= T:

- WHOLE-FLAT recovery SKIPS that member and reports explicitly:
  `skipped: no recoverable snapshot <= T`;
- it MUST NOT infer whether the source dataset did not exist at T, existed but had
  not yet been backed up, or had older history pruned;
- it MUST NOT require a historical topology catalog merely to distinguish those
  unknowable cases.

If the operator EXPLICITLY selected that member (for example
`--select=v3 --time=T`) and it has no qualifying retained snapshot <= T, REFUSE
that requested selection rather than silently skipping it.

Example:

```text
T = 12:00
v1: 09:00 11:45 13:00 -> 11:45
v2: 07:00 10:30       -> 10:30
v3: first = 14:00      -> skipped in whole-flat; REFUSE if v3 was explicit
```

This is intentionally not topology reconstruction. Restore reports and uses what
the retained backup can prove.

## 5. Dataset `creation` measurement

Claude's C-010 measurement is useful diagnostic evidence: the backup dataset's own
creation can survive snapshot pruning and often demonstrates that retained history
has gaps.

However, it is NOT needed to select the historical FLAT recovery set under this
contract and MUST NOT become a required historical-topology discriminator. A
full destroy/reseed can reset dataset creation, so treating it as authoritative
historical membership would add complexity without actually proving the desired
fact.

It may be shown as diagnostic metadata if useful; it does not change the selection
rule above.

## 6. Minimal matrix

```text
ATOMIC + latest
-> newest complete common atomic point

ATOMIC + time T
-> newest complete common atomic point <= T

FLAT + latest
-> each selected/current backup dataset's own latest snapshot

FLAT + time T
-> each selected/current backup dataset's own latest retained snapshot <= T
   whole-flat: skip members with none, report them
   explicit selection: missing member => REFUSE
```

## 7. Non-goals

Do NOT add for this problem:

- historical topology catalogs;
- manifests solely to remember dynamic child membership at every wall-clock point;
- reconstruction of whether a missing child existed at T;
- atomicity inference from names;
- a restore state machine merely to represent the matrix above.

This resolution refines the default recovery policy in
`docs/project/OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md` and supersedes the
catalog/topology concern in reviewer R-011.