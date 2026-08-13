# Restore public CLI — Owner + Reviewer discussion handoff to Claude

Status: **DISCUSSION ONLY — NOT A DECISION, NOT A PUBLIC CONTRACT**
Date: 2026-08-13
Participants so far: Owner + Reviewer
Requested next participant: Claude / implementer

This document transfers the current Restore CLI discussion so Claude can challenge it before any public grammar is frozen. The Owner's explicit goal is reduction: do not manufacture prefixes/flags where the parser already has enough information to understand the operator's intent.

## 1. Physical fact that triggered the discussion

For a remote relationship whose source is `pve2:rpool/data`, the actual backup on the collector may be physically represented as something like:

```text
hdd/backups/pve2/rpool/data
```

The operator can therefore naturally think about recovery in two different namespaces:

```text
SOURCE / relation namespace:  pve2:rpool/data
BACKUP-storage namespace:      hdd/backups/pve2/rpool/data
```

That distinction is the central unresolved issue.

## 2. Baseline semantic default

The simple/default operation remains unchanged at the product level:

> Restore the latest valid backup state to its original source location.

The CLI should express operator intent, not transport mechanics. `incremental`, `full`, rollback details, GUID-base selection, receive flags, etc. should remain internal.

## 3. Candidate A — physical backup dataset as the selector

Example:

```bash
zfs-backup.sh restore hdd/backups/pve2/rpool/data
```

Interpretation:

> Take this backup object and restore it to the original source that the installed relationship says it came from.

Advantages discussed:

- very concrete and ZFS-native: the operator points at the thing that physically exists;
- useful to an administrator inspecting the collector directly;
- naturally supports selecting a child by using its physical backup dataset path.

Concern:

- it makes the public workflow depend on the collector's physical backup layout;
- layout may change while logical relationship identity should remain stable;
- the operator must think in the backup-storage namespace even when the recovery target is elsewhere.

Potential expert/fallback role: this form may still be valuable as an advanced resolver, especially during disaster recovery, but we have not decided whether it should be canonical or merely accepted as an alias.

## 4. Candidate B — relationship identity as the primary selector

If the relationship is named `pve2` (example only; relationship identity must not be conflated with hostname), the shortest form would be:

```bash
zfs-backup.sh restore pve2
```

Meaning:

> Restore the default/latest recoverable state of the whole relationship to its original destination(s).

Selective hybrid proposed by the Owner:

```bash
zfs-backup.sh restore pve2:rpool/data
zfs-backup.sh restore pve2:rpool/data/v1
```

Conceptual grammar:

```text
RELATION[:SOURCE_PATH]
```

Meaning:

- `pve2` → whole relationship;
- `pve2:rpool/data` → only that source dataset from the relationship;
- `pve2:rpool/data/v1` → a narrower member/subtree.

This avoids `--relation=`, `--dataset=`, `--source-host=` and similar prefixes when the positional form is unambiguous.

Important caveat for Claude to challenge: in the current product model a relationship/client name is a stable identity and **host is not the key**. `pve2` is therefore only a convenient example relationship name, not permission to derive identity from endpoint/hostname.

## 5. The logical dissonance we explicitly noticed

If both forms are accepted equally:

```bash
restore pve2:rpool/data
restore hdd/backups/pve2/rpool/data
```

they may resolve to the same recovery object, but the path component means different things:

```text
pve2:rpool/data
     ^ source-side namespace

hdd/backups/pve2/rpool/data
^ collector backup-storage namespace
```

So the same positional slot changes coordinate systems depending on its shape.

This may be a reasonable convenience resolver, or it may be bad CLI design. We have **not decided**. Claude should argue both sides and propose a cleaner alternative if one exists.

## 6. Historical point selection

Two ideas were discussed.

Exact known ZFS snapshot, preferably using native ZFS notation:

```bash
zfs-backup.sh restore pve2:rpool/data@automated_hourly_2026-08-10_12-00-01
```

rather than necessarily requiring:

```bash
--snapshot=automated_hourly_2026-08-10_12-00-01
```

For an operator who knows a time but not a snapshot name:

```bash
zfs-backup.sh restore pve2:rpool/data --at="2026-08-10 12:00"
```

Proposed meaning of `--at=T`:

- FLAT: newest retained snapshot `<= T` independently per selected dataset;
- ATOMIC: newest complete common atomic point `<= T` or refuse.

This must stay aligned with the already-settled R-013 / Owner FLAT-ATOMIC semantics.

Question for Claude: is `@SNAPSHOT` plus `--at=T` the smallest coherent public surface, or does it create parser/identity ambiguity we are missing?

## 7. Partial / multi-selection

For one child, the Owner prefers expressing the scope in the main selector rather than paying for `--select`:

```bash
restore pve2:rpool/data/v1
```

For multiple disjoint members, a selector may still earn its existence:

```bash
restore pve2:rpool/data --select=v1,v3
```

We discussed preferring one compact list over repeated `--select` tokens unless repetition is materially safer/easier to parse.

Question for Claude: can multiple disjoint selections be expressed more cleanly without making the positional grammar ambiguous?

## 8. Restore to another place / another host

The cross-host case exposed a second independent dimension: the backup's identity and the restore destination are not the same thing.

Example intent:

```text
backup identity:  pve2:rpool/data
restore target:   pve3:rpool/data
```

A very small candidate grammar is:

```bash
zfs-backup.sh restore pve2:rpool/data pve3:rpool/data
```

General form:

```text
restore SOURCE [DESTINATION]
```

where omission of `DESTINATION` means the original location.

This also suggests local side recovery without `--into`:

```bash
zfs-backup.sh restore pve2:rpool/data tank/recovery/data
```

if a destination without a relationship/host qualifier means a local dataset on the machine running the command.

This raised the question whether `--into` is redundant. We have not decided.

## 9. Whole-relationship disaster recovery to another host

Possible shorthand:

```bash
zfs-backup.sh restore pve2 pve3
```

Potential meaning:

> Take every selected/member dataset belonging to backup relationship `pve2` and restore it on destination host/relationship `pve3`, preserving source-relative dataset paths.

Example mapping:

```text
pve2:rpool/data       -> pve3:rpool/data
pve2:tank/documents   -> pve3:tank/documents
pve2:rpool/ROOT/x     -> pve3:rpool/ROOT/x
```

This is attractive for disaster recovery but could hide substantial assumptions about destination identity, enrolment, grants, topology and pool availability. Claude should identify which of those assumptions make this shorthand unsafe or ambiguous.

## 10. Candidate minimal vocabulary so far

A deliberately small candidate, **not approved**:

```text
restore SELECTOR [DESTINATION]

SELECTOR:
  RELATION
  RELATION:SOURCE_PATH
  RELATION:SOURCE_PATH@SNAPSHOT
  possibly BACKUP_DATASET as an expert/physical alias

optional only when intent truly differs:
  --at=T
  --select=a,b     # only for disjoint multi-selection if needed
  --yes            # ordinary confirmation semantics only
```

Potentially no `--into` if positional `DESTINATION` proves clearer.

Explicitly unwanted unless a real use case forces them:

```text
--relation=
--dataset=
--backup-dataset=
--source-host=
--destination-host=
--replace
--incremental
--full
--rollback
--discard-source-changes
--preserve-source
```

## 11. Questions we want Claude to debate, not merely accept

1. What should be the **one canonical namespace** of the first positional selector: relationship/source identity, physical backup dataset, or a resolver that accepts both?
2. If both logical and physical selectors are accepted, is the namespace switch intuitive enough, or will it create operator mistakes?
3. Does `RELATION:SOURCE_PATH` create confusion with existing `user@host:dataset` remote syntax? If yes, propose a better compact separator/grammar without bringing back redundant flags.
4. Should the physical backup path remain an expert/fallback form for disaster recovery when relationship metadata is damaged? If metadata is missing, what can and cannot be inferred safely?
5. Is `restore SOURCE [DESTINATION]` better than `--into=DESTINATION`, especially for cross-host restore?
6. Can `restore RELATION DESTINATION_RELATION_OR_HOST` safely mean whole-relationship disaster recovery while preserving relative paths, or does it hide too much topology?
7. Should exact snapshot selection use native `@SNAPSHOT` notation? What edge cases would make that unsafe?
8. Can `--select` be eliminated or narrowed further for single/subtree selection while retaining clean support for disjoint members?
9. Which parts of this grammar can be resolved from existing CONFIG/client authorities without inventing a second index or state store?
10. Show the Owner 3–5 concrete command families for the common cases and compare them on ambiguity, recoverability when metadata is damaged, parser complexity, and number of concepts the operator must remember.

## 12. Working rule while this discussion is open

Do **not** implement or freeze new public Restore positional/flag grammar. Internal Restore mechanics may continue subject to formal review (currently REV-20260813-119). Claude should answer this discussion first with critique and a recommended grammar, including counterexamples that break any proposal above.
