# Public Restore grammar — implementer proposal

Opens the thread `OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` says is owed: "Details
are to be worked through with the reviewer in a separate thread."

Date: 2026-08-14
Status: **AWAITING REVIEWER CHALLENGE**
Attaches nothing. No parser is written, no flag exists, `restore_replace_internal`
stays unreachable from the CLI. Both REV-120/121 closures state that no public
Restore parser surface is authorised, and this document does not change that — it
proposes what to build so the authorisation can be about something concrete.

## What is already settled and not reopened here

The Owner fixed the shape: first argument is the source of the data, second is the
destination, omitting the destination means "back where it came from", scope comes
from what is named rather than from a flag, and a historical point is `--at` in
wall-clock time. I am not relitigating any of that.

The internal primitive underneath is closed: GUID-proven common base, loss set by
`createtxg` covering snapshots and bookmarks, informed confirmation, write fence,
commit boundary, explicit destroys plus a non-recursive rollback, identity-anchored
final state, and a recovery point that refuses when the maximum capture time is
shared (REV-119/120/121).

## Q1 — `:` is ambiguous, so nothing may be inferred from it

Every engine here reads `user@host:dataset`. The Owner's grammar uses `:` again in
`pve2:rpool/data`. A parsing rule that guesses which one it is chooses the machine
a destructive recovery aims at, so it must not guess.

**Proposal: resolve, never infer.** The first token is classified by *lookup*, not
by shape:

1. contains `@` → remote spec. This verb does not do remote recovery today
   (`restore_replace_internal` refuses it by name), so it is a refusal with a
   reason, not a parse.
2. otherwise, split on the FIRST `:`; the left side must **resolve against the
   installed CONFIG's relation set**. If it resolves, this is the relation form
   and everything right of the first `:` is a dataset path within it.
3. otherwise, if the whole token names an existing local dataset, it is the
   absolute form the Owner requires ("an operator who names `hdd/backups/pve1` …
   must be able to run the same recovery").
4. otherwise refuse, printing the relation names that do exist and the absolute
   form. Never a fallback, never a nearest match.

Relation names are then constrained at the source: a name containing `/`, `@`, `:`
or whitespace cannot be accepted as a relation name anywhere it is created. That
makes step 2 decidable rather than heuristic, and it is a validation, not a parse.

**Discrimination the tests must carry:** a relation named `pve2` and a *dataset*
literally named `pve2` in some pool must produce different, deliberate outcomes,
and a token that could be read either way must refuse rather than pick.

## Q2 — what names a relation: one answer, and `--plan` prints it

Today there is no relation-level name at all. `restore_relations()` derives
per-dataset tuples from the installed CONFIG, and PROJECT_STATUS records that a
local relation deliberately has **no persistent record** — the installed CONFIG
plus the cron block is the state.

So a relation name must be *derived*, deterministically, from the CONFIG. I
propose, in strict order, with no fallback chain beyond it:

- `pair_label` where the section carries one (remote pairs already have it);
- otherwise the **target subtree** (`dst=`) for local push relations;
- and if that derivation produces the same name twice, every affected relation is
  **unnamed** and reachable only by the absolute form. Not disambiguated by
  suffix, not picked by order.

The load-bearing half is the discovery surface: **`restore --plan` must print the
exact tokens this grammar accepts**, so an operator never composes a name from
memory. A name the plan does not print is a name the parser refuses. That single
rule keeps Q1 and Q2 from drifting apart as the CONFIG grows.

## Q3 — a third machine that is not enrolled

`pve3:rpool/data` as a destination means pushing to a host that may have no
delegated account, no trust and no relationship.

**Proposal: prove enrolment before anything destructive, and refuse with the
missing piece named.** The check is positive and specific — reachability, the
delegated account, the required ZFS delegations on the destination path — and each
failure says which one failed and the exact command that would establish it. Not
"cannot connect".

Two properties I would ask the reviewer to hold me to: the check happens **before
the loss set is measured**, so an unenrolled destination costs nothing and mutates
nothing; and a partially-enrolled destination (reachable, wrong delegations) is a
refusal, never a degraded recovery. This project has measured the failure mode
where a missing grant produced `rc=0` and a silently absent safety net.

## Q4 — `--at` on a relation is a frontier, not an instant

For a FLAT relation each dataset has its own frontier, so "the state at 12:00" is
per-dataset nearest at-or-before. The planner already says this for the map output
(R-013) and the wording exists.

**Proposal:**

- resolution is by ZFS `creation`, never by the snapshot name — the project has
  measured names that lie;
- per dataset, the chosen point is the newest snapshot whose `creation` is at or
  before the requested time;
- the output states, per dataset, which snapshot was chosen and its real creation
  time, and labels the whole result a **frontier** unless the relation is declared
  `atomic`, in which case it is one point and says so;
- a dataset with no snapshot at or before the time is **not** silently skipped and
  **not** given the oldest available one; it is named as having no point, and the
  run refuses before touching anything;
- REV-121 applies unchanged: if two candidates tie at the chosen second, that
  dataset is ambiguous and the run refuses rather than picking.

## Q5 — partial failure across a whole relation

Each dataset recovery is destructive and independent.

**Proposal: stop at the first failure.** Continuing after an unexplained
destructive failure risks compounding damage on a machine an operator is already
recovering, and the second failure would be diagnosed on top of the first.

The report is three distinct lists, never a ratio: recovered and verified; failed
with the exact failure classification the primitive already produces (nothing
destroyed / partially changed); and **not attempted**. The third list is the one a
single "3/7 succeeded" line destroys, and it is the one an operator needs to plan
the next command.

I can be argued out of stop-first for the *non-destructive* case (every
destination absent, so nothing is being overwritten), but not for the destructive
one.

## Q6 — destination-exists and destination-absent are different risks

The same command covers both, so the confirmation cannot be the same.

**Proposal:**

- **absent destination** — nothing is destroyed. The preview states what will be
  created and where, and the confirmation is ordinary. `--yes` covers it.
- **existing destination** — the whole REV-119/120 machinery applies as it does
  today: measured loss set including bookmarks, write fence, commit boundary,
  exact-set revalidation, identity-anchored final state. The confirmation text
  states the measured bytes and names what disappears.
- `--yes` covers the destructive case too — automation needs it — **but never
  covers a value this run guessed**. That rule already exists in this tree: slice
  3 refuses `--yes` for a heuristically proposed target while accepting it for a
  target the operator configured. A recovery point chosen by `--at`, a relation
  name resolved from an abbreviation, or a destination proposed rather than named
  must fall on the same side.

## What I would build first, once there is consensus

Not the parser. First the **resolver** — the function that turns one token into
either a resolved relation, a resolved absolute path, or a refusal that names the
alternatives — with its own tests, reachable from `--plan` only. It answers Q1 and
Q2, it is read-only, and every later slice depends on it. The destructive verb
stays unreachable until the resolver is reviewed.

## Where I expect to be wrong

Q2 is the weakest part. Deriving a name from `dst=` is convenient and it is not
obviously the operator's mental model — the Owner wrote `pve2`, which reads like a
machine, not a target subtree. If the answer is that relations should carry an
explicit name written into the CONFIG at creation time, that is a bigger change
than this document proposes and it belongs to you and the Owner rather than to me.
