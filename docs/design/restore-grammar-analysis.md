# The public restore grammar — where it is ambiguous, and the smallest fix

Date: 2026-08-13
Status: implementer analysis, for the reviewer debate (R-020). Not a decision.

Input: the owner's forms in
`docs/project/OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md`. R-020 asks that the
candidate be challenged against ambiguous relation names, remote specs, absolute
copy paths, whole-relation cross-host recovery and destination identity, and that
the smallest grammar that survives be proposed.

## The test each token has to pass

R-020's three questions, applied to every token anyone proposes:

1. can the relation, the CONFIG or ZFS already know it?
2. is there one safe, obvious default for the common case?
3. does it describe the operator's **intent**, or the **mechanics** underneath?

If the answer points inward, the token does not belong on the surface. This is why
there is no `--recursive` below (the relation knows), no transport flags (mechanics),
and no snapshot selector (policy says latest, `--at` covers history).

## Where the candidate is ambiguous

### 1. `:` already means something else

Every engine in this tree reads `user@host:dataset`. The candidate reuses `:` for
`relation:dataset`. Both are `word:path`. This is the dangerous one, because the
failure mode is not an error message — it is a recovery aimed at the wrong machine.

### 2. A bare word is not one kind of thing

`restore pve2 pve3` reads `pve2` as a **relation** and `pve3` as a **machine**.
Same shape, different namespace, and only the position says which.

### 3. A relation name can collide with a pool name

Nothing stops a relation being called `rpool`. Then `restore rpool` is either the
relation or the pool, and the two answers destroy different data.

### 4. A destination host may not be enrolled

`pve3:rpool/data` names a machine that may have no account, no trust and no
relationship here. The tool has nowhere to get credentials, and "try SSH and see"
is not an acceptable first move for a destructive verb.

### 5. Keeping source paths across hosts can collide

`restore pve2 pve3` recreates each dataset at its own source path on `pve3`. Some
of those paths may already exist there, with data. One command, two very different
risks.

### 6. `--at` over a whole relation is not a point in time

For a FLAT relation every dataset has its own frontier, so "the state at 12:00" is
per-dataset nearest-at-or-before, not one instant across the subtree — the
distinction R-013 already made the planner print. Selling it as a consistent
point would be selling a recovery point that never existed.

## The smallest grammar that stays unambiguous

```
zfs-backup.sh restore <source> [<destination>] [--at="YYYY-MM-DD HH:MM"] [--yes]
```

Two positions, one optional time, one confirmation skip. Everything else is
derived.

**Source** — one of:

| form | means | recognised by |
|---|---|---|
| `NAME` | the whole relation | no `/`, no `:` |
| `NAME:DATASET` | one dataset of that relation | `:` present, no `@` before it |
| `POOL/PATH` | an absolute copy path on this host | `/` present, no `:` |

**Destination** — one of:

| form | means | recognised by |
|---|---|---|
| *(omitted)* | each dataset back to its own original source path | — |
| `HOST` | the same paths, on that host | no `/`, no `:` |
| `HOST:DATASET` | an explicit path on that host | `:` present |
| `user@HOST:DATASET` | the same, with an explicit account | `@` before `:` |
| `POOL/PATH` | an absolute path on this host | `/` present, no `:` |

### The disambiguation rule, in order

1. `@` before the first `:` → a remote spec. Always. This keeps the engines'
   existing meaning intact and untouched.
2. `:` present → split at the **first** `:`. The left side is a **name**: in
   source position it must resolve to a known relation, in destination position to
   a known host.
3. `/` present → an absolute dataset path on this host.
4. otherwise → a bare name: a relation in source position, a host in destination
   position.

### The one property that makes this safe

**A name that does not resolve is an error, never a guess.** No falling back from
"unknown relation" to "maybe it is a hostname", no DNS lookup, no SSH probe. That
single rule is what removes ambiguity 1 and 2 from the dangerous class: the worst
case becomes a refusal naming what it looked for and where it looked, instead of a
destructive operation pointed somewhere nobody intended.

Ambiguity 3 follows from rule 4: a bare word is a relation, so a *pool* can never
be addressed as a bare word — write `rpool/something`. The cost is that a
single-word pool cannot be a bare source; that is acceptable, and the real fix is
at enrolment, where a relation name should be refused if it contains `/`, `:` or
`@`, and flagged if it equals an existing pool name.

### What the remaining ambiguities become

- **4, unenrolled destination**: refuse, and say what is missing. If the operator
  genuinely wants a host this installation has no record of, they write
  `user@HOST:DATASET` and supply the identity themselves. Bare `HOST` means "you
  already know this one".
- **5, colliding paths across hosts**: the preview lists each dataset with what is
  already at its destination, and the confirmation says how many destinations are
  occupied. Same verb, but the operator sees which half of the risk they are in.
- **6, `--at` over a relation**: the output states, per dataset, which recovery
  point was chosen and that a FLAT relation gives nearest-at-or-before rather than
  an instant. `--at` resolves by ZFS `creation`, never by the snapshot name.

## What is deliberately absent

No `--force`, no `--recursive`, no transport or compression flags, no snapshot
name selector, no preserve/discard choice (R-017 settled that the default path is
zero-choice). Each of them fails at least one of the three questions above.

`restore --plan` stays as the read-only view. It is not a mode of this command;
it answers a different question.

## What I am not proposing to settle here

Whether a relation-level restore should stop at the first failed dataset or
continue and report. It is a real decision with no obvious default, it is
independent of the grammar, and it belongs with the execution work.
