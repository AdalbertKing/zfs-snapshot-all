# Owner decision, 2026-08-28 — recovery onto a different machine is a MOVE

## The decision

A relationship whose machine is being replaced does not get cloned. **It moves.**

> "Bliźniak przejmuje kopię oryginału. Te operacje dla logicznej spójności
> należy nazwać nie `clone-client`, a **`move-to-client`**. [...] Bez sensu by
> było kopiowanie w te i we wte. Należy przełączyć drogowskazy do backupu na
> nową relację, a starą zatrzymać."

The copy on the collector stays exactly where it is. What changes is which
machine the relationship points at.

## What that rules out, and why it matters

The obvious shape — pair the new machine, let it build its own copy, recover
into it — costs a **full re-seed**. The new relationship's copy would be a fresh
dataset with no common snapshot against the old one, so after recovering 10 TB
onto the new machine the next backup sends the same 10 TB back to the collector.

Moving the copy avoids that entirely. The datasets the recovery writes onto the
new machine carry the SAME GUIDs as the copy they came from, so the first backup
after the move finds its common snapshot immediately and sends an increment. The
copy's history is one continuous lineage across the machine swap, which is also
the honest description of what happened: the data did not change custodian, the
machine under it did.

## The order, and it is not arrangeable

1. **Pair the new machine** as its own relationship, with the same profile.
   Paused from the start — nothing of its own may run yet.
2. **Recover onto it**, reading the OLD relationship's copy. The new
   relationship contributes the address, the key, the account, the grant and the
   pause; its copy is not involved and is not written to. On a fresh machine the
   datasets are absent, so the mode is `create` and the destructive `replace`
   gate stays closed.
3. **`move-to-client`** — the copy's sections are re-recorded against the new
   relationship, cron is regenerated, and the old relationship is stopped.

Moving BEFORE recovering points the schedule at an empty machine. The next pull
would find no common snapshot and either refuse or full-send, which is the
10 TB this decision exists to avoid, in the other direction.

## The precondition that makes the move safe

**Before switching a single signpost, prove the new machine actually holds the
copy — by GUID, per dataset.**

That check is the whole safety of the operation and it is cheap: the copy's
newest snapshot must exist on the new machine under the same GUID. Without it,
`move-to-client` is a config edit that silently repoints a backup at a machine
which does not have the data, and nothing discovers that until the next pull.

The estate has already paid for the general form of this mistake all through the
2026-08-27 restore lab: a step that reports success without measuring its own
result. This verb must measure.

## What the move actually touches

- the `[dataset:]` and `[prune:]` sections carrying `client=<old>` — re-recorded
  as `client=<new>`, with `src`, `flags` and `pair_label` switched to the new
  peer, and **the copy path unchanged**;
- the source-side prune, which addresses the peer and must follow it;
- the monitor;
- the crontab, regenerated from the changed config;
- the old relationship's record, stopped.

`zfs-backup.sh:8991` refuses a section at a path another client manages unless
that path was previously recorded as managed by that name. That guard is
correct and is exactly why this has to be a deliberate handover verb rather than
a config edit: the re-recording is the operation.

`remove-client <old>` afterwards finds nothing of its own left to remove,
because the sections moved. It retires the record, which is what it should do.

## Open — owner's call, not decided here

1. **Does `move-to-client` run the recovery itself, or refuse until the data is
   there?** The argument for refusing: composing a destructive recovery into a
   config operation makes one verb that can fail halfway in two different
   domains. Two verbs, each separately verifiable, is the shape the rest of this
   tool takes.
2. **What "stopped" means for the old relationship** — paused indefinitely,
   disabled at the peer, or the record retired outright. The sections are gone
   from it either way.
3. **The old machine may still be alive.** After the move it stops being backed
   up. That is correct when it is being replaced and dangerous when it is not.
   Should the verb require the retirement to be stated, or is saying loudly what
   it did enough?

## Not decided by this document

Whether the cross-host restore grammar (`restore A:ds B:ds`, reserved since
2026-08-13 and still refused by the parser) opens at the same time. It is the
addressing this scenario needs, and its destination is a relation label rather
than a hostname, which is what makes it consistent with R-025.
