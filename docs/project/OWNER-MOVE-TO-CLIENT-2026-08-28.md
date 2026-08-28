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
   relationship, cron is regenerated, and the old relationship is PAUSED (see
   the decision below: paused, not retired).

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
- the old relationship, PAUSED -- its record and its peer manifest stay exactly
  where they are.

`zfs-backup.sh:8991` refuses a section at a path another client manages unless
that path was previously recorded as managed by that name. That guard is
correct and is exactly why this has to be a deliberate handover verb rather than
a config edit: the re-recording is the operation.

If the operator later decides to retire the old relationship, `remove-client
<old>` finds nothing of its own left to remove, because the sections moved --
so it takes out the record and stops there. That is a separate decision, taken
later, by a person. The move does not take it for them.

## Stopping the old relationship: a PAUSE, and nothing heavier

Owner decision, 2026-08-28: **pause is enough.**

> "Pauza wystarczy, bo co jesli padnie w trakcie."

That is the reasoning, and it settles the question on its own. A pause is
reversible; retiring a record is not. A move that dies halfway has to leave a
state the operator can walk back out of, and "the old relationship is paused"
is exactly that state -- resume it and the old machine is protected again while
you work out what went wrong.

Retiring the record is a separate decision the operator can take later, once the
move is known to have worked. The verb does not take it for them.

## After pausing, the verb SAYS what it did. It does not decide anything else

Owner decision, 2026-08-28, and it is a principle rather than a detail of this
verb:

> "Wystarczy po zapauzowaniu powiedziec co zrobil. Admin ma narzedzie, a nie
> nadinteligentnego samograja wyprzedzajacego jego mysli, co nigdy dobrze nie
> zadziala."

So: the old machine may still be alive after the move, and it stops being backed
up. The verb states that plainly and does not require the operator to declare a
retirement, prove the machine is dead, or answer a question the tool invented.
It reports; the admin decides.

This is the same line the estate already draws elsewhere (the tool does not
restrict destructive operations an administrator is entitled to perform) and it
applies to prompts and preconditions as much as to guards.

## Open — under discussion

**Does `move-to-client` run the recovery itself, or refuse until the data is
there?** Not decided.

The implementer's recommendation is SEPARATE, for a reason that is not
aesthetic: recovery and hand-over are two different failure domains. A recovery
takes hours and may need several attempts (mount, grant, replace), each its own
conversation; the hand-over is seconds, local, and transactional. Composed, they
produce a verb that can be half-done in two incompatible ways, and an operator
mid-incident has to work out which half stopped.

The GUID proof is the natural seam -- it is precisely the question "is the data
there yet". A verb that both produces that condition and checks it is checking
its own work.

This project has already settled the same tension once: `activate` is an
idempotent composite over `set-endpoint` / `verify-endpoint` / `final-catchup` /
`activate-client`, and its own usage text says to invoke the steps directly only
to recover a stuck activation. Separate, resumable steps; a composite on top if
one is wanted.

Following the principle recorded above, a composite should NOT be built ahead of
use. Walk the path by hand first; a composite designed before anyone has run the
steps is exactly the automaton the owner rejected.

**What the open question forces either way:** `move-to-client` must be
IDEMPOTENT. Run against sections that have already moved it says so and exits
zero -- not an error, not a second move. That is also the answer to "what if it
dies halfway": if it stops between re-recording the sections and installing the
crontab, the config says new and the crontab says old, and a re-run resolves it.
Without idempotence that state has no exit but a hand edit.

## Not decided by this document

Whether the cross-host restore grammar (`restore A:ds B:ds`, reserved since
2026-08-13 and still refused by the parser) opens at the same time. It is the
addressing this scenario needs, and its destination is a relation label rather
than a hostname, which is what makes it consistent with R-025.
