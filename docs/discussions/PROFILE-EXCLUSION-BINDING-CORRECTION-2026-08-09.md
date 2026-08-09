# Profile exclusion correction — exclusion belongs to the binding, not the profile

Date: 2026-08-09
Status: OWNER CORRECTION / REVIEWER -> CLAUDE

Owner caught an important timing/ownership error in the harder adversary from `PROFILE-TWO-TIER-FLAT-CHALLENGE-2026-08-09.md`.

## 1. Correction

A reusable profile exists before any source host has been discovered. Therefore it cannot contain, own, or anticipate:

```text
exclude = rpool/data/vm-101-disk-0
```

or any equivalent concrete dataset exception.

The profile remains pure HOW:

```text
BASE
  hourly H24 no-freeze
  daily D30 freeze
  recursive=flat

DB90
  hourly H24 no-freeze
  daily D90 freeze
```

No dataset names appear in either profile.

## 2. When an exclusion can exist

Only after source discovery and relation composition:

```text
profiles already exist
        ↓
discover source datasets
        ↓
operator selects/binds source roots
        ↓
relation stores SOURCE ROOT -> PROFILE
        ↓
if a more-specific source is assigned another profile,
relation composition must prevent overlap
```

Example:

```text
Day 1 after discovery:

rpool/data -> BASE
  parent=no
  descendants=yes

Day 20 operator decides vm-101 needs D90:

rpool/data/vm-101-disk-0 -> DB90
```

At that moment, and only at that moment, the relation needs a non-overlap result equivalent to:

```text
rpool/data descendants under BASE
EXCEPT rpool/data/vm-101-disk-0

rpool/data/vm-101-disk-0 under DB90
```

## 3. Preferred reduction rule

Do NOT ask the operator to separately invent and maintain an `EXCLUDE vm-101` rule if the intent is already fully expressed by assigning the child another profile.

Preferred high-level action:

```text
assign rpool/data/vm-101-disk-0 -> DB90
```

The composer should then either:

A. transactionally materialize an explicit carve-out in relation state, or
B. refuse if the current relation/scope representation cannot express non-overlap safely.

The user-visible concept remains only:

```text
SOURCE ROOT -> PROFILE
```

not:

```text
SOURCE ROOT -> PROFILE + EXCLUDE DSL + precedence rules
```

## 4. Prefer explicit persisted carve-out over hidden precedence

A generic rule such as `most specific binding wins` is compact but creates an implicit precedence language and can become difficult to audit.

Reviewer preference, if native relation state can support it cheaply:

```text
user intent:
  rpool/data -> BASE
  rpool/data/vm-101-disk-0 -> DB90

persisted effective relation state:
  binding rpool/data -> BASE
    generated carve-out: rpool/data/vm-101-disk-0

  binding rpool/data/vm-101-disk-0 -> DB90
```

The carve-out is derived transactionally from the two bindings and shown in preview/read-back. The operator does not manually maintain it.

If the child binding is removed later, the generated carve-out must also be removed transactionally so the child automatically returns to the ancestor's dynamic BASE coverage.

## 5. Dynamic descendants remain simple

With:

```text
rpool/data -> BASE
rpool/data/vm-101-disk-0 -> DB90
```

future siblings still inherit the ancestor binding:

```text
vm-100 -> BASE
vm-101 -> DB90
vm-102 -> BASE
future vm-103 -> BASE
```

No profile mutation or regeneration is required merely because vm-103 appears.

## 6. Security/authorization remains separate

The concrete child path is relation/scope state and may also require grants/capability updates. That does not move dataset identity into the profile.

The order is therefore:

```text
PROFILE definitions (host-independent HOW)
        ↓
DISCOVERY
        ↓
RELATION/SCOPE selection (WHAT)
        ↓
SOURCE ROOT -> PROFILE binding
        ↓
non-overlap/carve-out validation
        ↓
grants/capabilities as required
        ↓
effective CONFIG v4
```

## 7. Claude challenge

Please answer narrowly:

1. Can the current relation/scope representation materialize this derived child carve-out without a new selector language?
2. If yes, what is the smallest explicit persisted representation and how is it reversed when the child binding is removed?
3. If no, should v1 simply refuse overlapping source-profile bindings rather than build precedence/exclusion machinery?
4. Do not put concrete `exclude=` values into profile files under any design.
5. Keep the owner rule: reduction, not complication. The operator should express the intent once (`child -> different profile`), not again as a separate exclusion rule.
