# Gate 3 closure call, and the one question blocking Phase 3.5

Date: 2026-08-10. For the reviewer, with one item for the owner.
Zero open threads as of `3888da8`; this note exists so that state does not get
mistaken for "nothing left to decide".

## 1. Gate 3 — asking for the call, not assuming it

Phase 3's three reviews are all APPROVED and CLOSED:

| REV | residual it removed |
|---|---|
| REV-20260809-089 | reactivation regenerated the relationship-local section body from the current profile |
| REV-20260810-090 | reactivation still *loaded* the profile and appended its templates |
| REV-20260810-091 | reactivation still re-added `[excluded:]` floors and still refused a pre-GFS config |

`closures/REV-20260810-091.md` says *"Both residual Phase 3 paths are
resolved"*, which reads as the property being satisfied — but Gate 1 and Gate 2
each got an explicit closure sentence ("Gate 2 acceptance property is now
proved... Phase 2 may close") and Gate 3 has not. I have marked Phase 3
**implementer-complete, Gate 3 awaiting reviewer** in `ACTIVE-WORK-PLAN.md`
rather than closing it myself, because gate closure is not mine to write.

If the three closures are considered to constitute Gate 3, say so and I will
record it. If something is still outstanding, it is not visible to me from the
artifacts.

Worth noting for the record: each of those three rounds found a residual that the
*previous* round's evidence structurally could not have caught — the profile was
never removed (089→090), the whole function was never audited against the stated
rule (090→091), and the guard fixture had nothing installed to disturb
(091→092). That pattern is why I am not asserting the property is now complete
merely because the last review closed.

## 2. Phase 3.5 is now in the plan, because it was not

`ACTIVE-WORK-PLAN.md` did not contain the prefixless/passive/GFS phase at all.
The owner marked it **MUST DO** on 2026-08-09
(`PREFIXLESS-PASSIVE-GFS-OWNER-DIRECTION-2026-08-09.md`), and the sequencing —
after Phase 3, before Phase 4 — was agreed between the reviewer's estimate and
my assessment. It existed only in two discussion notes, which is precisely how an
agreed requirement quietly stops happening. It now has a numbered phase and a
Gate 3.5.

## 3. The question that blocks implementation (not analysis)

From the addendum to my assessment, and still unanswered. It is a real fork, not
a formality:

`test/negative/blank-prefix.conf` exists and pins the CURRENT refusal as
**correct**. Its history (`c90f6d1`, "Treat a blank config value the same as a
missing one") is not arbitrary: `gen-cron.sh`'s `ini_has()` tests whether a key
was *written*, not whether it has a value, so a typo like `prefix = ` with
nothing after the `=` used to resolve as "present" and sail through the old
required-field check. That was measured live at the time to produce exactly the
bare-timestamp / empty-pattern accidents the owner's direction note now wants to
make reachable **on purpose**.

So relaxing `require_field prefix` naively reopens a defect this project already
paid to close. Nothing in the config text distinguishes "deliberately no prefix"
from "meant to type one" — both are `prefix = `.

**Proposed resolution**, using a distinction already present and unused:
`resolve_field()` already returns *not found anywhere in the
dataset/template/defaults chain* (rc 1) separately from *found but blank*
(rc 0, empty value). `require_field` collapses both into one refusal.

- field **entirely omitted** → the new deliberate "no prefix" / "no pattern"
  case, now accepted (a profile simply does not emit the line — a natural fit
  for how profiles already compose fragments);
- field **present but blank** → **stays a refusal**, unchanged.

This reaches every cell of the owner's matrix while leaving
`test/negative/blank-prefix.conf` passing untouched, and adds no new parser.

**What I need:** confirmation of that rule, or a correction. I would rather ask
once than implement a schema relaxation, have it reviewed, and discover the
project wanted blank-means-blank after all — a schema decision is much more
expensive to reverse than a function boundary, because configs get written
against it.

Absent a correction I will proceed on the omitted-vs-blank rule above, but not
before Gate 3 is called, per operating rule 1.

## 4. What I am doing meanwhile

Analysis and test design only, which both the owner note and the reviewer's
sequencing estimate explicitly permit during Phase 3. Concretely: the
bare-passive (`-e` with no `-m`) cell is the one of four with no direct test
evidence today, and closing that gap in `test/snapsend`/`test/snapget` is
independent of the question above — it tests engine behaviour that already
exists and is already reachable by hand, just not through `gen-cron.sh`.
