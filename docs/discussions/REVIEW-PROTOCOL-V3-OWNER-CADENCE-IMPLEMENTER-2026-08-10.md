# Implementer response — REVIEW PROTOCOL V3 owner cadence requirement

Date: 2026-08-10. Response to `docs/discussions/REVIEW-PROTOCOL-V3-OWNER-CADENCE-2026-08-10.md`,
building on `docs/discussions/REVIEW-PROTOCOL-V3-LESSONS-IMPLEMENTER-2026-08-10.md`
(the `evidence: PENDING` header proposal). No protocol machinery changed here.

## Agreement

The liveness invariant is correct and stronger than what I answered in the
earlier response. My answer to LESSONS question 2 fixed *how a parked REV
renders* (`APPROVED` + `evidence: PENDING`, routed to the reviewer for a
closure artifact, not back to Claude). It did not address *what the acting
session does next* — this document is the missing half.

## The requested mechanism has to answer one concrete question, testably

"Is the next planned item blocked by this parked thread?" `reviewctl` cannot
answer this — confirmed by re-reading it just now: `state_of_raw()`
(`test/reviewctl.sh:299-323`) and `owner_of()`/`next_of()` (`:325-346`) derive
review-thread ownership from headers alone and have no notion of
`ACTIVE-WORK-PLAN.md` phases at all. Per my own answer to LESSONS question 3,
that's correct — `reviewctl` should not start enforcing scheduling. But the
owner is right that leaving the answer to agent memory of an "informal
convention" is exactly what produced tonight's stall: nothing forced anyone
to check `ACTIVE-WORK-PLAN.md` before treating REV-093 as a global stop.

Proposed minimal, testable mechanism, consistent with the LESSONS-3 answer
(prose, not a `reviewctl`-enforced header):

1. Extend the existing `Blocking:` field (`docs/internal/reviews/README.md:164-165`)
   from `yes|no|owner-decision` to allow a fourth shape: `next-slice (Phase N)`
   — naming the exact phase it blocks, not just "yes". `Blocking:` is already
   free text the reviewer writes per finding; this only constrains its
   vocabulary, adds nothing to `reviewctl`.
2. **The check is grep, not code**: before parking a thread, or before
   skipping the next `ACTIVE-WORK-PLAN.md` phase as "blocked", the acting
   session runs `grep -n "Blocking:" docs/internal/reviews/REV-<id>.md`. If
   the value doesn't name the phase currently under consideration, that phase
   is not blocked by it — full stop, no further deliberation needed. Absence
   of a `Blocking:` field at all means the same thing (`no` is already the
   template default). This is "testable" in the sense the owner asked for: a
   fixed, one-line command any session can run, not a memory of a discussion.
3. This doesn't need a new file or ledger column. It needs the convention
   applied going forward and, ideally, one retrofit: `REV-20260810-093.md`
   currently has no `Blocking:` field at all. I can't add it — reviewer-owned
   file, same boundary as the header-typo findings earlier tonight — but I
   can point at it here for the reviewer to add on next touch.

## Worked example: is REV-093 actually a next-slice blocker for Phase 4?

I re-read `docs/project/ACTIVE-WORK-PLAN.md` rather than assume. Phase 3.5's
stated dependency edge to Phase 4 is explicit (`ACTIVE-WORK-PLAN.md:253-255`):

> "after Phase 3, before Phase 4 — it defines what a native CONFIG/preset is
> *allowed to express*, so it must land before Phase 4 makes presets a public
> contract."

That dependency is about the **generator-side CODE contract** (can a preset
express prefixless/passive/prefixless-GFS at all) — not about whether the
*already-existing engine behavior* those generated commands invoke has been
freshly proven live. REV-093's own independent-review section agrees: "I do
not currently find a production-code defect in `3495ec4d`." The three
outstanding cells (`snapsend.sh -m ""`, bare `-e`, `delsnaps.sh -G ... ""`)
are not new engine code Phase 3.5 introduced — `snapsend.sh -m ""` was already
identical to no `-m` (existing default), and `delsnaps.sh -G` already accepted
an empty positional pattern before this delivery (see
`docs/discussions/PHASE35-IMPLEMENTATION-CLAUDE-2026-08-10.md`, "no engine
change needed at all"). REV-093 asks for live proof of *engine behavior that
predates Phase 3.5*, exposed through a *new generator path*.

Applying the mechanism above: `REV-20260810-093.md` has no `Blocking:` field.
Under the proposed convention, that reads as **not a next-slice blocker**.
Independently checking the actual dependency text confirms the same answer by
substance, not just by absent-field default: Phase 4's stated prerequisite is
Gate 3.5's CODE (implementer-complete, no known defect), not its live-ZFS
evidence.

**Conclusion, applying the owner's cadence rule directly: Phase 4 is the next
dependency-ready planned item.** REV-093 stays parked exactly as the LESSONS
response described (`APPROVED` + `evidence: PENDING` once the reviewer adopts
that header; today, simply: no further implementer/reviewer ping-pong on it
until an attended session can run the recorded reproduction recipe). Gate 3.5
formal closure and Phase 3.5's *production activation* remain pending on that
evidence — this does not retroactively approve Phase 3.5 for production use,
only unblocks *starting* Phase 4's design/implementation work.

## Answering the owner's request directly

> propose the smallest mechanism that makes unattended continuation explicit
> and testable rather than relying on an agent remembering an informal
> convention

Smallest version: one vocabulary extension to an already-existing free-text
field (`Blocking: next-slice (Phase N)`), one fixed grep command as the
required check before parking or before deferring the next plan phase, and
one worked precedent (this document) an unattended session can point to
instead of re-deriving the reasoning from scratch. No `reviewctl` schema
change, no new ledger column, no new file type. If the reviewer wants this
enforced rather than advisory, the smallest enforceable version would be a
`test/impact.sh` check that fails when a `Blocking: next-slice (Phase N)`
value names a phase whose section in `ACTIVE-WORK-PLAN.md` no longer exists or
has already closed — catching the field going stale, not computing the
dependency itself. Not proposing that now; flagging it as the next increment
if advisory-only proves insufficient in practice.

## Next action taken in this session

Per the conclusion above and the standing instruction not to wait for a fresh
prompt: proceeding to scope Phase 4 next, in the same session. REV-093 stays
open, parked, with its reproduction recipe on file
(`docs/internal/reviews/responses/REV-20260810-093.md`) for the next attended
session with real ZFS access.
