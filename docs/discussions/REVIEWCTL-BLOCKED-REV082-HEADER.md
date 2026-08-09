# Routing generation is blocked by one character in REV-082's verdict header

Date: 2026-08-09. **For the reviewer.** No code change, no finding response.

## The state

```
$ ./test/reviewctl.sh --generate
reviewctl: REV-20260809-082: verdict 'CHANGES_REQUIRED' is not APPROVED or CHANGES-REQUIRED
reviewctl: 1 problem(s) -- refusing to generate from broken facts
```

`docs/internal/reviews/REV-20260809-082.md` line 2 carries an **underscore**
where the protocol defines a hyphen:

```
<!-- verdict: CHANGES_REQUIRED -->      <- current
<!-- verdict: CHANGES-REQUIRED -->      <- what Protocol V2 accepts
```

It survived the re-push in `654577f`.

## Why I have not fixed it myself

`CLAUDE.md` is explicit that I do not edit `docs/internal/reviews/REV-*.md`. That
rule is right here even though the fix is one character: `verdict:` is the
reviewer's own machine fact, and an implementer editing a verdict header — for
any reason, however benign — makes the implementer the author of a verdict. The
protocol's whole value is that the two roles cannot forge each other's facts.

So this is a report, not a repair.

## What it currently blocks

`--generate` refuses **entirely** rather than skipping the bad artifact, which is
correct fail-closed behaviour and I am not proposing to soften it. The
consequences while it stands:

- `REVIEW_LEDGER.md` and `OPEN-THREADS.md` cannot be regenerated, so routing is
  frozen at its last good state and does not show REV-082 at all;
- `./test/impact.sh --verify` reports `GRAPH DRIFT`, so the pre-commit gate is
  red for reasons unrelated to whatever is being committed — the exact condition
  under which a real drift gets waved through;
- one delivery is waiting to be registered and cannot be: `950f67f`, the profile
  reduction measurement answering the owner's direction. I reverted the
  `DELIVERIES.md` line rather than commit a registration whose generated views
  would be stale, and I will add it as soon as generation works.

## Worth considering separately, not now

The suite pins that an unknown verdict is refused, and that is the behaviour I
want. What it does not do is distinguish "this artifact is malformed" from
"the whole run is unusable". A per-artifact error that still generates the rest,
with the bad thread routed as BLOCKED, would keep one typo from freezing the
view of every other thread.

I am not proposing it as part of any current finding — it is a change to the
protocol tool's failure granularity and belongs in its own thread if you want it.
