# Client-granted restore — architecture

Status: design, opened 2026-08-17 by the implementer at the owner's direction.
Supersedes nothing. `docs/design/destructive-recovery-contract.md` (the execution
mechanics) and `docs/design/restore-grammar-analysis.md` (the CLI surface) stay
valid; this document sits *above* both and changes who is allowed to start them.

Owner's requirement, verbatim in substance: *restore must not be possible from
the server alone. An admin can make a mistake and flatten a production machine.
The client has to grant it first.*

---

## 1. Why the grant belongs here and not in the server

Backup and restore are not symmetric, and the asymmetry is the whole argument.

| | who acts | who is at risk | authority |
|---|---|---|---|
| **backup** | source pushes (or collector pulls) | the *copy* — worthless if wrong | source owns its own data |
| **restore** | collector writes onto production | **the production machine** | today: the collector, alone |

Every other destructive capability in this tree is exercised *by the machine that
owns the data*: `delsnaps` prunes its own snapshots, the pause/disable gates are
enforced **peer-side** precisely so the other end cannot override them. Restore is
the one operation that would let one host destroy another host's live data on its
own say-so.

So the grant is not a belt-and-braces extra. It restores the invariant the rest of
the design already keeps: **destructive authority lives with the data owner.**

### The failure this prevents

Not primarily malice. The realistic sequence is: an operator on the collector is
recovering client A, mistypes a relation name, and the tool resolves it to
client B — which is healthy and in production. Every safeguard built so far
(preview, `--yes`, GUID proof) is *inside* that one command, on that one machine.
None of them involves the machine about to be destroyed.

A grant is the only safeguard that requires **a second machine, a second human
action, and a second point in time.**

---

## 2. Principle 1 — prefer the pull

**The command that destroys should run on the machine being destroyed.**

If restore is initiated *on the client*, the grant problem largely dissolves:
whoever runs it already has root on the machine at risk. There is no privilege to
delegate and nothing to forge. The collector's role reduces to serving a stream,
which is read-only on its side.

This is not a new mechanism. `snapget.sh` already implements the pull direction
and is tested; restore-as-pull reuses a direction the tree already has, rather
than inventing a push-to-production path that does not exist today.

**Recommendation: the pull form is the default and the first slice.** It is
strictly safer, and it is less code.

The push form (drive many clients from one console) is a real operational want,
and section 3 exists for it — but it should be built *second*, and it must not
weaken the pull form.

---

## 3. Principle 2 — if the server initiates, it needs a capability it cannot forge

For the server-driven form, the client publishes a **grant**: a fact on the client
that the collector can read but never create.

### Shape

```
/var/lib/zfs-snapshot-all/relationships/<label>/restore-grant
```

Fields:

| field | why |
|---|---|
| `label` | which relationship this grant is for |
| `dataset` | exact dataset, or a subtree root with an explicit recursive flag |
| `mode` | `create` \| `rewind` \| `replace` — see §4; a grant for `rewind` must never authorise `replace` |
| `point` | optional pinned recovery point (GUID, not name) |
| `expires` | absolute wall-clock time |
| `nonce` | single-use token |

### Enforcement, and the one thing that must not be got wrong

The peer gate (`zfs-pair-gate.sh`, already wired as a forced command in
`authorized_keys`) is the enforcement point. It already intercepts every command
the relationship key can run.

**The delegated account must not be able to create, edit or extend a grant.**
Otherwise the protection is theatre: the collector's key would be granting itself
permission. Concretely:

- the grant directory is **root-owned**, the account has read-only access;
- the grant is created only by a **local, interactive, root** action on the
  client (`zfs-backup.sh allow-restore …` run *on the client*);
- burning the nonce needs a write, which the account cannot do — so consumption
  goes through a narrow **root helper over sudo**, exactly the pattern
  `zfs-quiesce-helper` already established for "the account must trigger a
  privileged action with no discretion".

There is a known precedent to *not* repeat: the hard-disable gate deliberately
allows the relationship key to lift its own block (owner's decision, recorded in
ADR-0012). **The restore grant must not be self-liftable.** If it were, the entire
mechanism would reduce to a speed bump.

### Time-boxing is the robust part; single-use is the nice-to-have

If the sudo helper is not built in the first pass, the grant degrades to
*time-boxed only* — replayable within its window. That is an acceptable interim
(the window is the operator's own maintenance window) but it must be **stated in
the code and in the operator output**, not quietly assumed. Naming a hole is not
fixing it; the honest interim is a short default expiry (≤ 60 min) and a loud
message saying the grant is time-boxed, not single-use.

---

## 4. Principle 3 — the tool classifies, the operator states intent

The owner's split was "target empty / target not empty". The load-bearing axis is
slightly different, and sharper:

| case | condition | what is destroyed | consent |
|---|---|---|---|
| **CREATE** | target dataset absent | nothing | grant + confirmation |
| **REWIND** | target present **and** a GUID-proven common base exists | only state newer than the base | grant + preview naming every object + confirmation |
| **REPLACE** | target present, **no** common base | everything at the target | grant scoped explicitly to `replace` + confirmation quoting the dataset name back |

Three consequences worth stating:

1. **"Empty" is not the question — "is there a common base" is.** A target that
   exists but shares a base is the *cheap* case (incremental), not the dangerous
   one. A target that exists without a base is the dangerous one, and it can look
   identical from the operator's side.
2. **REWIND is the ransomware case** the owner named: roll production back to the
   last known-good common point and re-apply the delta from the copy. It is also
   the case the current internal engine already implements and has under test.
3. **The operator never selects the mechanism.** They say *what state they want
   back*; the tool classifies and shows which of the three it is before asking.
   A `--force` that promotes REWIND into REPLACE is exactly the shape this design
   refuses.

`restore_replace_internal` today implements REWIND and refuses REPLACE by name
("nie będzie udawane przyrostem"). That refusal is correct and should survive: it
becomes "REPLACE needs its own grant mode", not "REPLACE is impossible".

---

## 5. Principle 4 — children are a first-class part of the plan, never a side effect

This is the trap the owner sensed twice, and it deserves being spelled out,
because it is where a restore silently produces a machine that boots but is wrong.

### The mechanics

- A **non-recursive** `zfs recv -F` on a parent **does not touch its children.**
  Restore `rpool/data` and the children `rpool/data/vm-100-disk-0` … are left at
  whatever state they are in. The result is a machine mixing restored and
  un-restored datasets — internally inconsistent, and nothing in ZFS complains.
- A **recursive** stream (`send -R`) plus `recv -F` does the opposite: it
  **destroys** target children that are not in the stream. That widens the
  destructive set beyond what a per-dataset preview showed.

Neither default is safe. Therefore:

**The plan must enumerate every child and assign it an explicit disposition** —
`restore` / `leave` / `destroy` — and the operator confirms the *set*, not the
parent. A child that exists on the target but not in the backup is the sharp case:
it can only be *left* (result is a mix) or *destroyed* (data loss outside the
backup's knowledge). It must never be decided implicitly.

### The relation's consistency kind decides what a subtree restore even means

The tree already distinguishes these and the distinction is load-bearing here:

- **ATOMIC** (`recursive = atomic`) — the subtree shares one snapshot instant.
  The unit of restore is the whole subtree at that instant. Restoring one child
  alone breaks the property the relation exists for, and is refused. (The current
  engine already refuses exactly this.)
- **FLAT** (per-dataset recursion) — each dataset has its own frontier. "The
  subtree at 12:00" is **per-dataset nearest-at-or-before**, not one instant. The
  planner already prints this distinction; the restore must repeat it per dataset
  and must never present the result as a consistent point in time.

---

## 6. Point-in-time selection

- Default: latest valid recovery point.
- `--at="YYYY-MM-DD HH:MM"`: nearest at-or-before, resolved by ZFS **`creation`**,
  never by the snapshot name — the two diverge after a rename, a hand-made
  snapshot imitating the convention, or a bad clock, and this has been measured on
  this estate.
- A tie on `creation` **refuses** and names the tied candidates (already
  implemented for the internal path).
- On a FLAT subtree the chosen point is reported **per dataset**.

---

## 7. Space — the gap found 2026-08-17

The existing safe (side) restore does a **full** `zfs send | zfs recv` into
`<pool>/restore/<src>` — same pool as the copy — with **no free-space check
anywhere**, and `--plan` does not report sizes.

An incremental is *not* available for a side restore, and this was measured, not
assumed: an incremental stream needs a receiver that already holds the base, and a
fresh dataset does not; naming a clone's snapshot `@B` gives it a new GUID, not
`B`'s (see `destructive-recovery-contract.md`).

A `zfs clone` would be near-free but **pins the origin snapshot**, so a forgotten
restore clone silently freezes retention on the backup copy — the tree already
made plain `zfs destroy` refuse rather than cascade into clones.

Therefore, independent of everything above and safe to do now:

1. pre-flight check using `zfs send -nP` (dry run, prints `size`) against the
   destination pool's `available`, refusing with the actual numbers. It is an
   **estimate** — on-disk compression differs from stream size — so it is a guard
   with margin, never a promise;
2. `--plan` reports the size of each recovery point, so cost is visible *before*
   choosing.

`--into=POOL/PATH` (restore into a pool that has room) is desirable but touches
the CLI grammar, so it waits with §8.

---

## 8. Slicing

Deliberately not one pass. Each slice is independently useful and independently
provable on a throwaway lab.

| slice | content | destructive? | depends on |
|---|---|---|---|
| **S0** | space pre-flight + sizes in `--plan` | no | nothing |
| **S1** | grant: `allow-restore` on the client, grant file, `--plan` shows grant state | no | nothing |
| **S2** | **CREATE**, pull-initiated, single dataset | no (target absent) | S1 |
| **S3** | **REWIND**, pull-initiated, single dataset — the ransomware case | yes, bounded | S1, S2 |
| **S4** | child disposition + ATOMIC subtree unit | yes | S3 |
| **S5** | **REPLACE** (no common base) | yes, total | S4 |
| **S6** | `--at` time selection | — | S3 |
| **S7** | server-initiated (push) form + gate enforcement + sudo nonce burn | yes | S3, and the CLI grammar decision |

S0 and S1 can start immediately: neither destroys anything, and neither depends on
the CLI grammar question the owner has not settled.

The public CLI grammar stays frozen until the owner settles it. Every slice above
is reachable through the existing `--flag=value` surface in the meantime, exactly
as the current engine is.

---

## 9. Open questions for the owner

1. **Pull-first?** Do you accept "restore runs on the machine being restored" as
   the default, with the server-driven form built later? It is materially safer
   and materially less code.
2. **Grant granularity** — per dataset, or per relationship? Per dataset is safer
   and more tedious; per relationship is one action for a whole-machine recovery,
   which is the realistic disaster case.
3. **Grant lifetime** — a fixed short window, or until consumed? (Until-consumed
   needs the sudo helper; a window does not.)
4. **Orphan children** (present on target, absent from backup) — is the default
   `leave` (mixed result, nothing lost) or `destroy` (clean result, data outside
   the backup lost)? I would default to `leave` and make `destroy` an explicit
   per-child decision, but this is a policy call.
5. **Does a grant survive a failed attempt?** If a restore fails halfway, is the
   grant still valid for the retry, or must the client re-grant? Re-granting is
   safer; it is also painful at 3 a.m. during a real recovery.
