# Owner decision — how a restore names WHAT to restore

Date: 2026-08-26. Status: OWNER DECISION, recorded by the implementer.

This supersedes the addressing half of
`OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md`. That file's `pve2:rpool/data` form is
**stale** and should be read as replaced by what is below; everything else in it
(the destination as a second argument, `--at` as wall-clock time, one verb for
every scope) stands.

## The shape

```bash
# the whole relationship
zfs-backup.sh restore pve2

# one dataset, named on the machine being restored
zfs-backup.sh restore pve2 --target rpool/data/x

# one dataset, named where the copy lives
zfs-backup.sh restore pve2 --source backup/pve2/rpool/data/x

# several datasets, comma-separated
zfs-backup.sh restore pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1
```

The relationship name stands ALONE and the dataset arrives through a flag.

**That is not a cosmetic change.** It dissolves the ambiguity the 2026-08-13 file
raised as its first open question and which cost the most discussion: `:` is
legal inside a ZFS dataset name, so `pve2:rpool/data` had two readings and the
resolver had to refuse when both resolved. With the flag form the relationship
name is never adjacent to a path and there is nothing to disambiguate.

## Why commas, and why they are safe

The owner's case, in his words: a VM with four virtual disks is four datasets,
and recovering it must be **one** command.

Four commands would mean four previews, four destructive confirmations, and a
window in which the machine is half restored — for something that is one object
to the person doing the recovery. This overrules the reviewer's suggestion that
several partial datasets be restored with separate commands and that "no complex
selector language is required": a comma-separated list is not a selector
language, and the case it serves is the ordinary one, not an exotic one.

**The separator is safe by measurement, not by convention.** ZFS refuses a comma
in a dataset name outright (pve9, 2026-08-26):

```
$ zfs create -o mountpoint=none hdd/przecinek,test
cannot create 'hdd/przecinek,test': invalid character ',' in name
```

So a comma can never occur inside a member of the list, and splitting on it
cannot destroy a legal name. This is exactly the property `:` lacks, which is
why the colon form produced an ambiguity and this one cannot.

## What the list does NOT change

- **`--source` and `--target` stay exact ZFS dataset paths.** No globs, no
  prefixes, no subtree expansion, no workload semantics. A comma list is N exact
  names, nothing more. If a member does not resolve, the command refuses; it
  never restores the members it understood and skips the rest silently.
- **One preview, one confirmation, covering every member.** The point of the
  single command is a single decision, so the preview lists every
  `SOURCE@snapshot -> TARGET` pair and its classified action
  (`CREATE`/`REWIND`/`REPLACE`) before anything is destroyed. A confirmation that
  does not name all four disks is not the confirmation this contract means.
- **Partial failure behaves as the owner already decided for whole-relation
  recovery** (`OWNER-RESTORE-GRANT-AND-MODES-2026-08-26.md` §7): continue past a
  failure, report a per-dataset verdict, and exit non-zero if any member failed.
  Nine of ten recovered must not exit 0.
- **`--at` remains per-dataset** (reviewer rule 4): each member gets the snapshot
  with the greatest `creation` at or before the requested time, and the report
  says so under an explicit PER-DATASET FRONTIER heading. A comma list is not an
  atomic point in time, and four disks of one VM are exactly the case where
  someone would assume it is.
- **The grant stays per relationship.** The list chooses scope within a
  relationship the operator already has a grant for; it never widens it.

## One namespace per invocation — settled

Reviewer, 2026-08-26, answering the question this section used to leave open:

- `--source LIST` and `--target LIST` are **mutually exclusive**;
- every member of one invocation is named in ONE namespace — the collector's or
  the restored host's;
- a mixed spelling is not needed: once one side is chosen, the recorded mapping
  computes the other;
- the resolver must resolve the **whole** list before the preview. A missing
  member, an ambiguous one, a duplicate input, or two members leading to the same
  target is a refusal **with no mutation whatsoever**;
- only a complete, unambiguous plan reaches one preview and one confirmation.

The mistake this removes is concrete: an operator naming two of a VM's disks as
they exist on the collector and two as they exist on the host, and getting a plan
that looks complete.

## As built

`zfs-restore.sh` implements the resolution half. The plan is read-only, so this
is scope selection only — no destructive door is opened by it.

The `--target`/`--source` split is enforced in the matching core rather than
above it: `restore_resolve_try` gained a namespace argument, and the existing
positional form still passes an empty one, which keeps its "either side" reading.
Saying which side you mean is the whole point of naming the flag, so the flags do
not fall back to "either".

Both spellings work (`--target x` and `--target=x`) because both recorded
contracts write the first one, and an option whose value is missing — or is
itself the next flag — is refused rather than swallowed.
