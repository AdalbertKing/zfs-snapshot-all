# Restore: grant model, restore modes, failure behaviour

Status: OWNER DECISION (recorded by the implementer from the owner's messages of
2026-08-26). Seven questions were put in one pass; all seven are answered.

These settle what `docs/design/client-granted-restore.md` § 9 listed as open, and
narrow what `docs/project/OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` left to the
implementer. They do not reopen anything already settled.

## 1. Restore runs on the machine being restored

**Pull-first.** The server-initiated (push) form is built later, if at all.

Materially safer and materially less code: the machine that will be overwritten
is the one that asks, so no capability has to be forged, delegated or verified
across a link to authorise a destructive act.

## 2. The grant is per RELATIONSHIP, not per dataset

Per dataset is safer and more tedious. The realistic disaster is a whole machine,
and at that moment tedium is a cost paid in the worst possible currency.

## 3. The grant lives UNTIL IT IS TAKEN BACK

Not a time window, and not single-use. The design analysis offered only those
two; the owner named a third and the reason is concrete:

> "Odtworzenie może trwać godzinę, albo weekend. Okno czasowe nie jest tu dobre."

An expiring grant dies mid-recovery, which is the worst possible moment for it to
die. A single-use grant is worse still: a restore that fails halfway would need
re-granting at 3 a.m.

**The consequence, stated rather than discovered later:** a grant left behind
stays valid indefinitely. Two things follow, and they are not optional:

- `status` must show an outstanding grant **loudly** -- a forgotten grant has to
  be visible, not silent;
- there must be an explicit verb to take it back.

This also removes the sudo-helper dependency the design attached to single-use
grants. Until-revoked needs no burn-on-use mechanism: the grant is a file, and
revoking it removes the file.

## 4. Restore MODES are a classification, not an operator choice

The owner asked to discuss "full destructive vs incremental to a point in time".
The discussion closed quickly, because the answer was already settled in
`docs/design/destructive-recovery-contract.md` and the owner's own answer to
question 7 restated it independently:

> remove/roll back only the blocking divergent state, then incremental from the
> GUID-proven base when one exists; full replacement only when no valid base
> exists

So the mode falls out of the DATA:

| the data says | the tool does |
|---|---|
| destination absent | full send |
| destination present, common base exists | remove the blocking divergent state, then incremental from the GUID-proven base |
| destination present, no valid base | full replacement |

The operator states intent ("restore this, to this point, here"). The tool
classifies and says which of the three it is about to do. That is Principle 3 of
`client-granted-restore.md`, unchanged.

## 5. Children present on the target but ABSENT from the backup are DESTROYED

The implementer recommended leaving them. The owner overruled, and the reason is
the point of the whole verb:

> "Admin odtwarza backup po to, żeby mieć stan po obu stronach identyczny, a nie
> kaszanę."

A restore makes the target look like the backup. A target left carrying datasets
the backup never had is not a restored machine; it is two states mixed together,
and nobody can say afterwards which is which.

**This is compatible with the settled contract only because the contract already
requires it to be visible:** preview first, naming exactly what will be lost,
then explicit destructive confirmation. Orphan children are data that was never
in the backup, so they MUST appear in that preview by name. A destructive
confirmation that does not list them is not the confirmation this contract means.

## 6. A failed attempt does NOT invalidate the grant

Consistent with decision 3: the grant lives until taken back, so a retry after a
failure needs no new grant. Re-granting is safer in the abstract and painful
exactly when one can least afford pain.

## 7. Whole-relation recovery CONTINUES past a failure and reports

The implementer recommended stopping at the first failure. The owner chose to
continue and report what was and was not recovered.

The reasoning that makes this safe rather than merely convenient: a recovery is
not a deployment. Stopping at the first failure leaves the operator with a
half-restored machine AND no information about the rest, at the moment they most
need a complete picture. Continuing produces the same partial state plus the map.

**What this obliges:** the final report must be a per-dataset verdict, not a
count, and the exit status must distinguish "everything recovered" from "some
recovered" -- a run that recovered nine of ten datasets must not exit 0.

## What is still for the reviewer, not the owner

Named here so nobody mistakes them for open owner questions:

1. `:` already means `user@host:dataset` to every engine in this tree; the
   parsing rule for `pve2:rpool/data` has to be written and tested, not inferred.
2. What exactly names a relation -- client name, host label, or target subtree.
   One answer, not three.
3. A destination host that is not enrolled must be refused, and the refusal
   designed.
4. `--at` resolves by ZFS `creation`, never by snapshot name, and must say which
   of the two it gave. For a FLAT relation each dataset has its own frontier, so
   "the state at 12:00" is per-dataset nearest-at-or-before, not one instant.

## Correction to an existing document

`docs/design/client-granted-restore.md` § 8 says the public CLI grammar "stays
frozen until the owner settles it". The owner settled it on 2026-08-13
(`OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md`). That sentence is stale and should be
read as superseded.
