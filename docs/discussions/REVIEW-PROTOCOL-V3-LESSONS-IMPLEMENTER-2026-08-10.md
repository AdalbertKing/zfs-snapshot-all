# Implementer response — REVIEW PROTOCOL V3 lessons

Date: 2026-08-10. Response to `docs/discussions/REVIEW-PROTOCOL-V3-LESSONS-2026-08-10.md`.

Read `test/reviewctl.sh` and `docs/project/PROTOCOL.md` before answering — the
questions below are grounded in what `state_of_raw()` actually does today, not
a guess at it. No protocol machinery changed in this response, per instruction 5.

## The motivating problem is reproducible right now

`REVIEW_LEDGER.md`'s current last row is exactly the friction the proposal
describes:

```
| REV-20260810-093 | OPEN | Claude | - | 3495ec4d... | - | implement and respond |
```

REV-093's own text says "I do not currently find a production-code defect in
`3495ec4d`" and asks only for live-ZFS proof, yet its verdict header is
`CHANGES-REQUIRED` — the only value other than `APPROVED` the schema allows
(`test/reviewctl.sh:247-250`). `state_of_raw()` (`:300-326`) has no branch for
"code accepted, only evidence outstanding": a `CHANGES-REQUIRED` verdict on the
current implementation SHA always derives `OPEN`, and `owner_of(OPEN)` /
`next_of(OPEN)` (`:328-346`) always route to Claude with "implement and
respond" — even when, as here, the implementer's own response already argued
there is nothing left to implement. That is not a hypothetical gap; it is the
literal state of this repository at the moment this file was written.

## 1. Does the CODE/EVIDENCE split fit `reviewctl` cleanly?

Not as a second parallel state machine — as a single additional, optional
axis on the *existing* one. The four-state FSM (`OPEN -> IMPLEMENTED ->
APPROVED -> CLOSED`) already answers a narrower question than "is this
production-ready": it answers "has the reviewer looked at the current SHA and
said yes." That question doesn't need to change. What's missing is a way for
the reviewer to say yes to it while still holding back the closure fact until
proof lands. Grafting evidence state onto `APPROVED`/`CLOSED` — the two states
that already mean "reviewer is satisfied" — is a smaller change than adding
parallel `CODE-*`/`EVIDENCE-*` enums that the render/routing logic would need
to cross-product against the existing four states.

## 2. Smallest schema change

One new **optional** reviewer-file header, read the same way `verdict` and
`reviewed-implementation` already are:

```
<!-- evidence: PENDING -->
```

- Absent header (every one of the 92 existing REV files) means `COMPLETE` —
  zero retroactive edits, zero migration.
- Legal values `PENDING` / `COMPLETE`, validated the same fail-closed way
  `verdict` is validated at `:247-250` (unknown value is an error, not a
  silent pass).
- Touches exactly one place in the derivation: the `CLOSED` branch at
  `state_of_raw():302-309` gains one more condition — closure additionally
  requires `evidence` to be `COMPLETE` or absent. `APPROVED`, `IMPLEMENTED`
  and `OPEN` derivation are untouched.
- Effect on REV-093's own shape: reviewer would record `verdict: APPROVED`
  (code has no defect) + `evidence: PENDING` (live proof outstanding). State
  derives to `APPROVED`, owner `Reviewer`, and `next_of(APPROVED)` already
  reads "write the closure artifact" (`:342`) — which the reviewer correctly
  won't do until evidence lands. Ownership stops bouncing to Claude for work
  that doesn't exist. `next_of` for this case should say something like
  "await live evidence, then write the closure artifact" — a string change,
  not a state change.
- Ledger render (`render_ledger():348-368`) gets one additive column at the
  end. `render_threads()` needs no change: it already filters on `st =
  CLOSED` (`:383`), so an `APPROVED`/evidence-pending REV keeps surfacing on
  `OPEN-THREADS.md` for free, satisfying amendment 8 (cadence stays
  independent) without new logic.

## 3. Where does blocker scope belong?

Prose, not a new machine header — for a narrower reason than "keep it
simple": `reviewctl` today enforces nothing about development scheduling at
all. It derives review-thread state, full stop. `release blocker` /
`next-slice blocker` / etc. describe a relationship between a REV and *other
work*, which is out-of-band information the ledger has no representation
for and, per amendment 2, is explicitly not supposed to gate. Making it a
machine header would imply `reviewctl` enforces it, which invites exactly the
kind of drift-between-claim-and-code that Protocol V2 was built to eliminate
(see the `test/reviewctl.sh:14-19` header comment on why V2 exists at all).
The README already has a machine-adjacent field for this — `Blocking:
yes|no|owner-decision` in the finding-content template (`README.md:107-136`,
`:164-165`). Extending that enum's *values* (e.g. `owner-decision` ->
`release`/`next-slice`/`migration`/`evidence-debt`) is consistent with the
existing pattern and needs no new header or ledger column. Only the
PENDING/COMPLETE evidence axis needs to be machine-readable, because it's the
only part of this proposal that actually changes what `CLOSED` means.

## 4. A helper for canonical REV creation

Reasonable, but scoped carefully against the standing ownership rule: "Reviewer
maintains reviewer files... Implementer must not rewrite reviewer finding
prose" (`README.md:46-49`). `test/reviewctl.sh` is already shared
implementer-maintained infra that both roles run (`--generate`/`--verify`), so
adding a third mode — e.g. `--new-review <REV-id>` emitting the canonical
three-line header block (`rev:`/`verdict:`/`reviewed-implementation:`, plus
now optionally `evidence:`) to stdout or a new file — fits the tool's existing
role without the implementer touching reviewer prose: it scaffolds structure,
the reviewer still writes every word of the finding. This directly
answers amendment 6 (REV-093 shipping with no machine header at all, caught
only a review cycle later per `docs/internal/reviews/responses/REV-20260810-093.md`,
is the exact failure a creation-time template would have made
structurally impossible). Not implementing this now, per instruction 5 — it's
listed here as a design tradeoff to accept or reject.

## 5. Concrete backward-compatible change set

If the reviewer agrees with the shape above, here is the full diff surface,
proposed but **not implemented in this response**:

- **`docs/project/PROTOCOL.md`**: add an "Evidence state" section defining the
  optional `evidence:` header, its two legal values, its default when absent,
  and the amended sentence for what `CLOSED` requires (currently
  `:273`/`:287-297` describe `CLOSED` purely in terms of verdict + SHA
  match; add "+ evidence not PENDING").
- **`test/reviewctl.sh`**:
  - `collect()` (`:229-277`): read `evidence:` from `$f` alongside `verdict`
    and `reviewed-implementation`; validate against `{PENDING,COMPLETE,""}`
    the same way `:247-250` validates verdict, erroring closed on anything
    else.
  - `state_of_raw()` (`:300-326`): add the evidence condition to the existing
    `CLOSED` branch only.
  - `next_of()` (`:338-346`): branch the `APPROVED` case on evidence state for
    the text only; no new return state.
  - `render_ledger()` (`:348-368`): one additive trailing column.
- **`docs/internal/reviews/README.md`**: document the header in the artifact
  layout section (`:28-51`) and note it's reviewer-owned like `verdict`.
- **`OPEN-THREADS.md`**: no code change — the existing `!= CLOSED` filter
  already does the right thing once `APPROVED` can mean "accepted, evidence
  pending."
- **Migration**: none. All 92 `CLOSED` rows in the current ledger have no
  `evidence:` header in their source files and would continue deriving
  `CLOSED` exactly as they do today under "absent means `COMPLETE`."
- **Test impact**: `test/impact.sh` should be run against this diff before
  landing it — `reviewctl.sh` almost certainly has its own test coverage
  pinning ledger column shape and state transitions (the file's own comments
  reference REV-065/067/078/080/082 as bugs its current logic exists to
  prevent), and a new column or branch is exactly the kind of change that
  coverage is there to catch.

## Where I'd push back

Amendment 7 ("no ping-pong for already-understood obligations... park in an
explicit `EVIDENCE-PENDING` state") is right in spirit but the proposed name
collides with the state-machine vocabulary in `README.md:52-75`, which
reserves `OPEN/IMPLEMENTED/APPROVED/CLOSED` as "exactly four workflow
states." Calling the parked condition `EVIDENCE-PENDING` reads like a fifth
FSM state even though nothing above proposes one. Recommend the discussion
and any eventual `PROTOCOL.md` text call it "`APPROVED` with `evidence:
PENDING`" rather than a bare `EVIDENCE-PENDING` label, so nobody later
implements a fifth `state_of_raw()` branch to match a name that was only ever
meant to describe an `APPROVED` row's evidence column.

## Answer to the open questions, summarized

1. Fits as one optional axis grafted onto `APPROVED`/`CLOSED`, not a parallel
   state machine.
2. One optional header (`evidence: PENDING|COMPLETE`, absent = `COMPLETE`),
   one added condition in the existing `CLOSED` branch, one additive ledger
   column.
3. Normative prose (extend the existing `Blocking:` enum in the finding
   template) — `reviewctl` doesn't gate scheduling today and shouldn't start
   via a header nobody enforces.
4. Yes — a `reviewctl --new-review` scaffold mode, implementer-maintained tool
   emitting structure only, reviewer still writes all finding prose.
5. Diff surface listed above; smallest version touches one header, one `if`,
   one column, zero migration.
