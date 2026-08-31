# Owner decision — one spelling for scope, and how a recovery lands somewhere else

Date: 2026-08-30. Status: OWNER DECISION, recorded by the implementer.

This closes the last open half of `OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` —
the public cross-host CLI — and finishes what
`OWNER-RESTORE-SCOPE-2026-08-26.md` started. It supersedes the `label:dataset`
addressing form **everywhere**, not only where that file already replaced it.

## What was actually wrong

The 2026-08-26 decision replaced `pve2:rpool/data` with `--source` / `--target`
because `:` is legal inside a ZFS dataset name and the two readings had to be
disambiguated at runtime. That is not a theoretical objection: it produced a live
defect (#132) in which a legal copy location `.../pool/data:archive` was split at
the first colon and refused while sitting in CONFIG.

But the replacement only reached the single-machine case. Measured on the tree of
2026-08-30, both spellings were live:

```bash
zfs-restore.sh lab1 --target rpool/data/x    # the 2026-08-26 form
zfs-restore.sh lab1:rpool/data/x             # the 2026-08-13 form
```

and with a destination the flags were **refused**, with the refusal pointing at
the colon:

```
restore: --source/--target select datasets WITHIN one relationship, and a second
address names a different one. Say it the way the grammar does:
restore <from>[:<dataset>] <onto>[:<dataset>].
```

So the only way to write "one disk of this VM, onto a different machine" was the
spelling the owner had already replaced, for a reason that applies with more
force here — a recovery aimed by an ambiguous address is aimed at the wrong
machine, and this is the verb that destroys what it lands on.

## The shape

```bash
# the whole relationship, back onto its own machine and paths
zfs-restore.sh lab1

# some of its datasets, back onto their own paths
zfs-restore.sh lab1 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1

# the whole relationship, onto a different machine, same paths
zfs-restore.sh lab1 lab2

# some of its datasets, onto a different machine, same paths
zfs-restore.sh lab1 lab2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1

# onto a different machine AND different paths — positional pairs
zfs-restore.sh lab1 lab2 --target rpool/data/x,rpool/data/y --onto hdd/data/x,hdd/data/y

# the whole relationship, rebased onto one path
zfs-restore.sh lab1 lab2 --onto hdd/data
```

One spelling for scope, in every form: the relationship name stands alone and the
datasets arrive through flags. The colon is gone.

## `--onto` — what it is and what it is not

`--onto` names **where the recovery lands on the destination machine**. It is a
different axis from `--source`/`--target`, which say *in which namespace the
operator is naming the datasets* — the copy's or the machine's. Both can appear.

The rules, and each one exists because its absence has a failure mode:

1. **`--onto` requires a destination relationship.** Without a second address
   there is nothing to land on; the source paths are the destination by
   definition. Refusal, not a no-op.
2. **With a selection list, the lists are the same length and read as positional
   pairs.** Different lengths refuse. Never zip-to-shortest, never repeat the
   last element — both would silently recover fewer datasets than were named, or
   land two on one.
3. **Positional, not set-wise.** Writing the disks in a different order on the
   two sides says something the operator did not mean; sorting it out for them
   would hide exactly the mistake this form exists to let them state precisely.
   This is the rule already settled for both-sides `--source`/`--target` on
   2026-08-26, applied unchanged.
4. **Each member is an exact dataset path.** No globs, no prefixes, no workload
   semantics — the same limit `--source`/`--target` already carry.
5. **Children follow relatively.** A selected dataset that covers a subtree lands
   with each child at the same relative position under its paired `--onto` path.
6. **Two members may not lead to the same destination.** A duplicate is a refusal
   before the preview, not a race between two receives.

### The whole-relationship form

`--onto` with exactly **one** path and **no** selection list means: the whole
relationship, rebased there. Every dataset lands under it at its position
relative to the relationship's own root.

This exists because the disaster it serves is the ordinary one — a replacement
machine whose pool is not called `rpool` — and requiring the operator to
enumerate four disks by hand at that moment is the thing the comma was introduced
to prevent.

**The base is derived from the relationship's RECORDED roots, and it is shown.**
A first version of this rule said the root must be read and never inferred. That
was written without looking at a real relationship: a VM with four disks is four
recorded sections and therefore four roots, so "read the root" would have refused
the exact disaster the form exists for.

The base is the longest prefix common to the recorded source roots, taken at
dataset-name boundaries — never mid-name, so `rpool/data/vm-101` and
`rpool/data/vm-1010` share `rpool/data`, not `rpool/data/vm-101`. Roots with no
common prefix have no single meaning for "rebased here", so the command
**refuses and names them**.

It is an inference, so it is not allowed to be silent: the preview states the
base and the destination it is rebasing onto, on their own line, above the
per-dataset pairs. An inference the operator confirms is not a guess; an
inference nobody sees is.

## Retiring the colon

`label:dataset` is still accepted for one release and **warns loudly**, naming
the flag form that replaces it. It is then removed.

Not removed outright, because it is a public spelling that appears in this
project's own documents and in the 2026-08-28 two-host campaign transcript. Not
kept silently, because two ways to say one thing is how they come to disagree —
which is the argument the code itself makes three lines above the refusal quoted
at the top of this file, while doing the opposite.

## What this does NOT change

- **The destination is a relationship label, never a hostname.** R-025 stands: a
  machine this collector has already paired with, pinned a key for, and can ask
  for a grant. `--onto` names a *path* on that machine; it never names a machine.
- **The grant is per relationship** and `REPLACE` is granted explicitly
  (`OWNER-RESTORE-GRANT-AND-MODES-2026-08-26.md`). `--onto` selects where within
  a granted relationship, never widens the grant.
- **One preview, one confirmation**, listing every `SOURCE@snapshot -> DEST`
  pair with its classified action, before anything is destroyed.
- **`--at` stays per dataset**, resolved by ZFS `creation`, under the explicit
  PER-DATASET FRONTIER heading.
- **Partial failure stays D+B** (2026-08-30): pre-flight the whole scope and
  refuse before touching anything if any member cannot be restored; then execute
  without stopping at a failure, and report a per-dataset verdict whose exit
  status distinguishes "everything" from "some".

## The copy-location address — CLOSED 2026-08-31

The 2026-08-13 file required that an operator naming a copy location and an
absolute destination can run the same recovery without going through a
relationship name. This is that, and the shape of it fell out of one constraint.

```bash
zfs-restore.sh --from-copy hdd/backups/pve1/hdd/labsrc --onto hdd/recovered
```

**A flag, not an inferred shape.** Accepting a path in the first positional and
inferring it is not a label would mean deciding what `hdd` is -- an equally good
pool name and relationship name. This project has already paid once for
disambiguating by shape; `--from-copy` cannot be misread.

**`--onto` is mandatory here**, unlike the relationship form. There, omitting the
destination means "back where it came from" because the record says where that
was. A copy location carries no such record, so a default would be invented
rather than recalled.

**It never destroys.** Destruction requires a grant, a grant requires a
relationship, and a raw copy location has none: nobody to publish consent, and no
schedule to stand down either. The only remaining justification would be "the
operator is at the keyboard", which is the argument that dismantles a consent
model. Overwriting means naming a relationship and going the ordinary way. So it
lands in free space through the same engine the relationship-addressed safe
restore has used since it was proven live on 2026-08-15 -- a new ADDRESS for a
proven engine, not a second engine.

Everything resolves before anything is created: one unusable pair refuses the
whole list and names every bad one, the same discipline as the relation-level
pre-flight.

## Still open

Nothing from the 2026-08-13 grammar. Its two halves -- the addressing form and
absolute paths without a relationship name -- are both answered above.
