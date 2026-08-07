# REV-20260807-064 — live-ledger state model conflates IMPLEMENTED with CLOSED

**Reviewed head:** `af1eba89ad43249e41482f8c494e7ab409142e5a`

**Review time:** 2026-08-07 19:00 CEST

**Newest commit event at review start:** `af1eba89ad43249e41482f8c494e7ab409142e5a`, committed **2026-08-07 18:55:32 CEST**.

**Verdict:** **REV-063 PARTIALLY SATISFIED; F1 / P2 CHANGES REQUIRED.**

Fresh `main` was read immediately before this verdict. I inspected the REV-063 implementation in `8c10e2e`, the marker advance in `af1eba8`, current `test/impact.sh`, `docs/project/OPEN-THREADS.md`, and `docs/PROJECT_STATUS.md`.

## What is accepted

The direction of REV-063 is correct and the implementation improved the project materially:

- the duplicated review-head row is gone; one machine marker is authoritative;
- the marker is checked structurally against later watched commits;
- CLOSED/DONE rows with a live `Whose move` are rejected;
- parser failure is fail-closed rather than becoming a false clean result;
- PROJECT_STATUS no longer repeats the status SHA in prose and no longer claims VM 104 is unprotected;
- threads 21c and 35 were reconciled rather than erased historically.

The controls described in `8c10e2e` also found real implementation mistakes before release (awk failure swallowed, quoting/newline damage, wrong column index). This is exactly the testing discipline the project should keep: targeted positive controls that prove the guard can fire, not a broad green campaign.

## F1 / P2 — the stated lifecycle rule is impossible, and a stale route already survives it

`OPEN-THREADS.md` now states:

> A row whose State says CLOSED/DONE/IMPLEMENTED must carry `—` in `Whose move`.

But `IMPLEMENTED` is not equivalent to `CLOSED` in this workflow. The normal review lifecycle is precisely:

`IMPLEMENTED -> reviewer: verdict -> CLOSED`

So treating every IMPLEMENTED row as non-routable would make the ledger unable to express work that is implemented and legitimately awaiting review.

The shipped code implicitly recognizes this and checks only `CLOSED|DONE`, not `IMPLEMENTED`. That avoids breaking the workflow, but it leaves the recurrence REV-063 was meant to prevent.

There is already a concrete counterexample on current `main`:

- thread **39 / REV-062** is still `IMPLEMENTED` with `reviewer: verdict`;
- REV-063 explicitly says **REV-062 APPROVED / CLOSED**.

Therefore the live ledger currently routes the reviewer to perform a verdict that has already happened, while the new `ledger_coherence()` returns clean for that row.

This is not limited to row 39. The current table contains older `IMPLEMENTED -> reviewer: verdict` rows whose corresponding reviews are already described elsewhere as closed (for example REV-056 and REV-058 in `PROJECT_STATUS.md`). The mechanism cannot distinguish a legitimate pending implementation review from a stale post-verdict implementation row because the state model does not encode that distinction.

## Required outcome

1. Correct the documented routing rule. Do **not** say that all `IMPLEMENTED` rows must have `—`.
2. Make the lifecycle machine-readable enough to distinguish at least:
   - implementation delivered, verdict pending;
   - review closed / no action pending.
   This may be done with explicit canonical State values, a separate verdict/status field, or another structural representation. Do not parse prose to infer whether a review closed.
3. Reconcile row 39 immediately: REV-062 is CLOSED by REV-063 and must not route to the reviewer.
4. Reconcile other rows where the repository already has an authoritative reviewer closure but `OPEN-THREADS` still routes `reviewer: verdict`. Preserve historical evidence in the row text if useful; only the live state/routing must change.
5. Extend `ledger_coherence()` only after the lifecycle representation is unambiguous. The check must reject a structurally CLOSED/reviewed row that still routes work, while still accepting an IMPLEMENTED-but-not-yet-reviewed row that legitimately routes to the reviewer.

## Acceptance evidence — deliberately small

No broad campaign is warranted. This is a ledger/process mechanism.

Use a targeted deterministic matrix for `ledger_coherence()`:

- `IMPLEMENTED + reviewer: verdict` where verdict is **pending** -> PASS;
- `CLOSED/reviewed + —` -> PASS;
- `CLOSED/reviewed + reviewer: verdict` -> FAIL;
- malformed/unrecognized lifecycle state that would make routing ambiguous -> fail closed or be explicitly rejected by the schema.

Add one negative control against `8c10e2e` showing the stale post-verdict case is accepted there and rejected by the fix. `./test/impact.sh --verify` on the resulting tree is sufficient unless the implementation touches runtime files outside the ledger/impact mechanism.

## Graph / dependency note

No live-host proof is required for this finding because it does not touch ZFS, crontab ownership, UID, permissions, SSH/grants, or deployment state. Requiring a host campaign here would add cost without increasing evidence. The relevant dependency is the `impact.sh` verification path and the two live-ledger files only.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-064.md`
