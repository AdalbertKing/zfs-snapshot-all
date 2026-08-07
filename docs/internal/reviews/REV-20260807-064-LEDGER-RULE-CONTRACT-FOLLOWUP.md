# REV-20260807-064 — live-ledger rule text must match the enforced state machine

**Reviewed head:** `af1eba89ad43249e41482f8c494e7ab409142e5a`

**Review time:** 2026-08-07 18:56 CEST

**Newest commit event at review start:** `af1eba89ad43249e41482f8c494e7ab409142e5a`, committed **2026-08-07 18:55:32 CEST**.

**Verdict:** **REV-063 substantially implemented but not yet closed. New F1: CHANGES REQUIRED (P2, documentation/process contract).**

Fresh `main` was read immediately before this review. I inspected the two commits after REV-063 (`8c10e2e`, `af1eba8`), the resulting `test/impact.sh`, `PROJECT_STATUS.md`, `docs/project/OPEN-THREADS.md`, and the required response path.

## REV-063 implementation assessment

The substantive REV-063 repair is directionally correct:

- `PROJECT_STATUS.md` no longer contradicts itself about Stage 0 / VM 104;
- stale review-announcement prose was removed in favor of one `review-head` machine marker;
- obsolete routing rows were reconciled (including the old delegated-install-lock row);
- `ledger_coherence()` fails closed on awk parse failure and checks finished rows structurally rather than grepping prose;
- the review-head marker is checked against later watched behavior-changing commits;
- both status/review markers were advanced to `8c10e2e` in `af1eba8`.

That is the right architecture for the recurrence REV-063 described.

However, one contract mismatch remains in the live ledger itself, and the required REV-063 response file is absent.

## F1 / P2 — `OPEN-THREADS.md` documents a stronger rule than `ledger_coherence()` actually enforces

The new header says:

> a row whose State says `CLOSED/DONE/IMPLEMENTED` must carry `—` in `Whose move`.

But the actual checker intentionally treats only `CLOSED|DONE` as terminal:

```awk
if (st ~ /CLOSED|DONE/ && mv != "-" && mv != DASH && mv != "")
    print ...
```

The code's rule is the correct one for the current review protocol: `IMPLEMENTED` is not terminal. It can legitimately mean "implementation exists, reviewer verdict still required". The same file currently demonstrates that exact valid state in thread 39 (`REV-062` implementation awaiting reviewer verdict before this review closed it).

Therefore the new machine-backed ledger immediately contains two competing state-machine definitions:

- prose: `IMPLEMENTED` is terminal and must route to nobody;
- checker + actual workflow: `IMPLEMENTED` may route to reviewer.

This is precisely the kind of semantic drift the new mechanism is intended to eliminate.

### Required outcome

1. Make the authoritative state rule explicit and consistent everywhere. Recommended contract:
   - `CLOSED` / `DONE` are terminal and must have `Whose move = —`;
   - `IMPLEMENTED` is non-terminal and may route to the reviewer (or another actor) until a verdict closes it.
2. Align `OPEN-THREADS.md` header text with `ledger_coherence()` rather than widening the checker to reject legitimate `IMPLEMENTED -> reviewer` rows.
3. Add a small deterministic control proving an `IMPLEMENTED | reviewer: verdict` row is accepted while `CLOSED | reviewer: verdict` is rejected. This pins the state-machine boundary rather than just the current text.
4. No production runtime change and no broad test campaign.

## REV-063 response-path omission

The review explicitly named:

`docs/internal/reviews/responses/REV-20260807-063.md`

That file is absent on the reviewed head. The implementation commits are useful evidence, but the repository review protocol requires a durable implementer response. Add the response, referencing the exact commits/tests and explicitly acknowledging the terminal-vs-nonterminal ledger states above.

## Closure state

REV-063 is **not yet CLOSED** solely because the durable response is missing and the new ledger rule text contradicts the checker/workflow. The substantive reconciliation and machine checks are otherwise acceptable.

## Response path

Implementer response for this follow-up:

`docs/internal/reviews/responses/REV-20260807-064.md`
