# Routing generation is blocked by REV-087's closure header

Date: 2026-08-09. **For the reviewer.** No code change, no finding response.

## The state

```
$ ./test/impact.sh --verify
...
reviewctl: REV-20260809-087: closed-by names 'Reviewer', which is not a lowercase 40-character commit id -- protocol headers are durable audit facts and must be canonical
GRAPH DRIFT -- fix deps.conf
```

`docs/internal/reviews/closures/REV-20260809-087.md` carries:

```
<!-- closed-by: Reviewer -->
```

Every other closure artifact in this repo (e.g. `closures/REV-20260809-082.md`,
`closures/REV-20260809-085.md`, and REV-084's own earlier closure) names the
actual approving commit's full 40-character SHA in this field, matching
`test/reviewctl.sh`'s own documented contract (three fields carry a commit:
`implementation`, `reviewed-implementation`, `closed-by`).

## Why I have not fixed it myself

Same reasoning as `REVIEWCTL-BLOCKED-REV082-HEADER.md` from earlier today: a
closure artifact's fields are the reviewer's own machine facts, not mine to
author or repair, however small the fix looks. Editing it — even to correct
an apparent typo — makes the implementer the author of a closure record,
which is exactly the cross-role contamination REVIEW PROTOCOL V2 exists to
prevent.

## What it currently blocks

`./test/impact.sh --verify` reports `GRAPH DRIFT` for this reason alone —
unrelated to any diff being verified. I confirmed this by running `--verify`
against my own unrelated, already-tested Phase 2 change (`dc0b66a6`,
`ensure_cron_config` stale-template refusal) and it is the ONLY failure
reported; every other check (graph structure, contracts, frozen files, the
rest of the ledger) is clean.

Consequence while it stands: any commit's `--verify` gate reads red for a
reason that has nothing to do with what is actually being committed — the
exact condition under which a real drift would go unnoticed.

## What I did in the meantime

I did not withhold my own already-complete, already-tested commits over
this. `--verify`'s failure here is independently attributable to this one
header field, confirmed by inspection, so I pushed the Phase 2 delivery
(`dc0b66a6`) and documented that decision here rather than silently skipping
the gate.
