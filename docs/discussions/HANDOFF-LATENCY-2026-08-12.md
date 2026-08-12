# The 2026-08-12 "communication failure" was latency, not blindness

**Author:** implementer (Claude). **Status:** disagreement stated with evidence,
for the reviewer and the owner to settle. Nothing here changes code or protocol
on its own.

## The claim

The handoff that reached me on 2026-08-12 states:

> There has been a communication failure: you reported that you could not see any
> new work from Reviewer even though the repository routed work back to you.

and, on that basis, `386520b` and `f4efe0f` added a mandatory "pick up from
REVIEW_LEDGER before declaring yourself idle" rule to `CLAUDE.md` and
`docs/internal/reviews/README.md`.

I have no objection to that rule and I will follow it. But the premise is not
what the repository records, and fixing the wrong cause leaves the real one live.

## What the repository records

Two identities appear in the log: commits authored `Adalbert` are reviewer-side,
commits authored `AdalbertKing` are mine.

| time (CEST) | commit | author | `REV-20260811-102` row in the ledger |
|---|---|---|---|
| 08-11 22:29 | `5eca02d` | Claude | `IMPLEMENTED \| Reviewer` |
| 08-12 01:09 | `c5e36d0` | **Claude** | `IMPLEMENTED \| Reviewer` — my last activity |
| 08-12 01:58-06:03 | 5 heartbeats | reviewer | unchanged; nothing routed to Claude |
| 08-12 **08:05** | `7c4be78` | reviewer | **`OPEN \| Claude`** — the handoff |
| 08-12 08:19-08:35 | `386520b` `f4efe0f` `bb8449c` | reviewer | protocol change + "IMMEDIATE NEXT ACTION" |
| 08-12 ~11:20 | — | — | first Claude session after the handoff |

`git show c5e36d0:docs/internal/reviews/REVIEW_LEDGER.md` confirms the row read
`IMPLEMENTED | Reviewer` at 01:09.

So until 08:05 the ledger said the move was the reviewer's. Any report of mine
before 08:05 that there was no work routed to Claude was **correct**, and a
mandatory ledger pickup would have produced exactly the same answer. The gap is
that the handoff landed at 08:05 and the first implementer session after it
started around 11:20.

## The actual cause

The two sides are not scheduled the same way.

- The reviewer has an hourly heartbeat that commits on its own.
- I have no scheduler. I exist only inside a session the owner opens. Between
  01:09 and 11:20 no implementer process was running, so nothing on my side could
  read the ledger, mandatory rule or not.

That is a three-hour queueing delay in a channel where one end polls and the
other does not. It is not a case of an implementer looking at stale chat memory
instead of the generated ledger — which is the failure the new rule prevents, and
a real failure worth preventing, just not this one.

## What would actually close it

Options, in increasing cost, for the owner to pick:

1. **Owner-triggered pickup.** After the reviewer routes a REV to Claude, the
   owner opens a session. Zero machinery; the delay stays bounded by the owner's
   attention rather than by anything automatic.
2. **Implementer heartbeat.** A recurring implementer session that fetches
   published `main`, reads the ledger, and either picks up an `OPEN | Claude` row
   or records a no-op. Symmetric with the reviewer's heartbeat; costs a run per
   interval whether or not there is work.
3. **Reviewer-side ping.** The routing commit also emits something the owner
   actually sees, so step 1 does not depend on the owner watching the repository.

My recommendation is 1 plus 3: the polling asymmetry is cheap to live with as
long as routing is visible to a human, and an idle implementer heartbeat spends a
run per interval to discover nothing most of the time.

## Not in dispute

- `REV-20260811-102 OPEN -> Claude` was a genuine handoff and I have executed it.
- The ledger, not chat memory and not `PROJECT_STATUS.md`, is the authority on
  whose move it is.
- Refreshing published `main` before deciding anything is right, and my local
  `main` was eight commits stale when this session started — which would have
  mattered if a session had been running.
