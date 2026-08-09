# `reviewctl --generate` is blocked by REV-088's verdict header

Date: 2026-08-10. For the reviewer. Reviewer-owned metadata; not corrected here.

## What is blocking

```text
reviewctl: REV-20260809-088: closure artifact without a matching APPROVED verdict
           for the submitted implementation
reviewctl: 1 problem(s) -- refusing to generate from broken facts
```

`./test/impact.sh --verify` fails the same gate, and with the generator
refusing, `REVIEW_LEDGER.md`/`OPEN-THREADS.md` cannot be regenerated to add
REV-089 at all.

## Why

`docs/internal/reviews/closures/REV-20260809-088.md` is well-formed and closes
the review properly:

```text
<!-- rev: REV-20260809-088 -->
<!-- closed-by: 510d58709537f4928d5c9bf86b8b808b949108ef -->
```

But `docs/internal/reviews/REV-20260809-088.md` still carries the two headers it
opened with:

```text
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: 5f2201c55c46b1867349d909b830facb5a93a23a -->
```

`state_of_raw()` accepts a closure only when **both** hold: the verdict is
`APPROVED`, **and** `reviewed-implementation` equals the response's
`implementation`. Here the verdict is still the opening one, and
`reviewed-implementation` still names the pre-fix base `5f2201c5…` rather than
the delivered `20f333d9…` that the closure itself quotes. So the closure sits on
top of an approval of a *different* commit, which is precisely the "a closure
artifact would be a way to declare victory" case the check exists to catch.

Measured, not assumed: advancing the verdict alone does **not** unblock the
generator — I tried that first in an unstaged working copy and it still refused,
which is what led to reading `state_of_raw()` rather than guessing. Advancing
**both** headers produces a clean run (`wrote … (25 reviews)`) with exactly the
expected delta and nothing else:

```text
- REV-20260809-088 | IMPLEMENTED | Reviewer | … | 5f2201c5… | verify the submitted implementation
+ REV-20260809-088 | CLOSED      | -        | … | 20f333d9… | -
+ REV-20260809-089 | OPEN        | Claude   | - | 8d0dc243… | implement and respond
```

Both temporary edits were reverted; `git status` shows the review file
unmodified.

The closure text is unambiguous about the intent ("REV-088 is closed after
independent verification…", "Gate 2 may close; Phase 3 may proceed"), so this
reads as the review's own headers not having been advanced when the closure was
written in a separate pass — the same class as REV-087's `closed-by: Reviewer`
that this reviewer already repaired during the REV-088 pass.

## Why I did not fix it

`CLAUDE.md` rule 7: the reviewer owns technical closure, and the verdict header
is the reviewer's own record of a decision only the reviewer can make. Editing
it here would be Claude writing the reviewer's approval, which is exactly the
thing the header exists to prevent — even when the intent is obvious from the
closure prose sitting next to it.

## Effect on the REV-089 delivery

The REV-089 implementation, tests and response are complete and committed. The
two generated views (`REVIEW_LEDGER.md`, `OPEN-THREADS.md`) do NOT yet list
REV-089, because the generator refuses to run at all while the above disagreement
stands — a deliberate all-or-nothing property of the tool, not a partial failure.

Once REV-088's two headers are advanced, `bash test/reviewctl.sh --generate`
produces both views cleanly (proven above); I will regenerate and commit them in
a follow-up commit.

## Suggestion, not a request

The generator has now been blocked by reviewer-owned header bookkeeping twice in
two days (REV-087's `closed-by`, REV-088's verdict + `reviewed-implementation`),
and both times the intent was unambiguous from the artifact text sitting next to
the header. The current design requires the same fact to be stated in three
places that must agree.

I would not weaken the check itself — it is the only thing standing between a
closure artifact and "declaring victory", which is exactly why it caught this.
The cheaper fix is a **refusal that says what to write**: today's message names
the symptom ("closure artifact without a matching APPROVED verdict for the
submitted implementation") but not which of the two conditions failed, nor the
two values that disagree. Naming them ("verdict is CHANGES-REQUIRED, expected
APPROVED" / "reviewed-implementation 5f2201c5… != implementation 20f333d9…")
would have turned this note into a thirty-second edit by the reviewer.

That is a change to `test/reviewctl.sh`, which I own and could implement — but
it changes how a protocol gate reports, so I am proposing rather than doing it.
Say the word and it lands as its own commit with its own negative control.
