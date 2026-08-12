# REV-102's closure cannot be generated: the REV file's machine headers still say CHANGES-REQUIRED

**Author:** implementer (Claude). **For:** the reviewer. **Nothing reviewer-owned
was edited** — `docs/internal/reviews/REV-20260811-102.md` and the closure file
are yours, so this is a report, not a fix.

## Symptom

`./test/reviewctl.sh --generate` refuses, and therefore **no** routing can be
regenerated for **any** review, including the newly opened REV-111:

```
reviewctl: REV-20260811-102: closure artifact without a matching APPROVED verdict for the submitted implementation
reviewctl: 1 problem(s) -- refusing to generate from broken facts
```

`REVIEW_LEDGER.md` and `OPEN-THREADS.md` are consequently frozen at the
pre-closure state: they still show `REV-20260811-102 | IMPLEMENTED | Reviewer`
and do not show REV-20260812-111 at all.

## Cause

`e31c0fc` added `docs/internal/reviews/closures/REV-20260811-102.md` with

```
<!-- closed-by: b9fcd402594ed2e989b773f437b513c4e759d8e2 -->
```

but `docs/internal/reviews/REV-20260811-102.md` still carries the headers from
the previous round:

```
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: d747b35c65efd7caa4cb611f3d6101728a53472f -->
```

`state_of_raw()` in `test/reviewctl.sh` accepts a closure only when
`verdict = APPROVED` **and** `reviewed-implementation` equals the response's
`implementation` — here `b9fcd402594ed2e989b773f437b513c4e759d8e2`. Neither holds,
so the closure reads as an attempt to declare victory and the generator stops,
by design.

The closure prose itself is unambiguous approval; only the two machine headers
lag. This is the same failure class as the REV-082 verdict-header incident: one
header line freezes all routing.

## Fix (reviewer's move, two lines)

In `docs/internal/reviews/REV-20260811-102.md`:

```
<!-- verdict: APPROVED -->
<!-- reviewed-implementation: b9fcd402594ed2e989b773f437b513c4e759d8e2 -->
```

then `./test/reviewctl.sh --generate`. REV-102 becomes `CLOSED` and REV-111
appears as `OPEN | Claude`.

## What I am doing meanwhile

Treating REV-20260812-111 as genuinely routed to me on the strength of its own
headers (`verdict: CHANGES-REQUIRED`, `reviewed-implementation: b9fcd40`,
"**CHANGES REQUIRED — OPEN → Claude**") rather than waiting for the ledger to
say so, since the ledger cannot be regenerated until the headers above are
corrected. I am not editing the ledger by hand to work around it.
