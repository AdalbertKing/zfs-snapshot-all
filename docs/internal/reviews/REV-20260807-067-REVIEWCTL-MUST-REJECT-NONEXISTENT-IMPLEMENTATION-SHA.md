<!-- rev: REV-20260807-067 -->
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: 8980e2653cfff76aec0dd3b1a30700d9f704a555 -->
<!-- supersedes: - -->

# REV-20260807-067 — reviewctl must reject a nonexistent implementation SHA

**Review time:** 2026-08-07 22:01 CEST

**Reviewed head:** `8980e2653cfff76aec0dd3b1a30700d9f704a555`.

## Verdict

**CHANGES REQUIRED.** REV-066's substantive response is acceptable: the revised verification plan is now risk-shaped and follows the dependency graph. However Protocol V2 currently routes REV-066 to the reviewer using an implementation SHA that does not exist in the repository. That defeats the protocol's core property: the reviewer must be able to verify exactly the submitted implementation.

## F1 / P1 — REVIEW_LEDGER accepts an implementation ref that Git cannot resolve

Current `docs/internal/reviews/responses/REV-20260807-066.md` declares:

`<!-- implementation: c49afd2afbb3a40643e34303bf2a7b6d7aaaa948 -->`

and generated `REVIEW_LEDGER.md` therefore records REV-066 as:

`IMPLEMENTED | Reviewer | c49afd2afbb3a40643e34303bf2a7b6d7aaaa948`.

A fresh GitHub commit lookup for that SHA returns **No commit found**. The actual delivery is visible as real commits `af696e47` (risk-shaped verification contract), `39663b2b` (remove contradictory leftovers), followed by response commit `bd517f0d`.

This is not cosmetic metadata. A typo or fabricated SHA can currently move the FSM into `IMPLEMENTED -> Reviewer`, while the reviewer cannot fetch, diff, or pin the thing supposedly submitted. That recreates the stale/wrong-head failure Protocol V2 was introduced to prevent.

### Required outcome

1. `reviewctl` must fail closed when any machine header that is supposed to identify a commit (`implementation`, `reviewed-implementation`, and equivalent commit-bearing fields) is not resolvable as a commit in the repository.
2. REV-066's response must be corrected to a real commit that contains the complete submitted change. If the delivery spans sequential commits, point at the tip commit containing the whole delivery rather than inventing a synthetic identifier.
3. Ledger/open-thread generation must refuse to publish `IMPLEMENTED -> Reviewer` for an unresolved implementation SHA.
4. Error output must name the REV, field, and offending SHA.

### Minimal acceptance evidence

No live-host run is useful here; this is pure repository/FSM metadata.

- targeted `test/reviewctl` case: valid commit SHA accepted;
- targeted case: syntactically valid 40-hex but nonexistent SHA rejected;
- targeted case: malformed/non-commit object rejected if the parser permits it;
- negative control against the pre-fix implementation showing the nonexistent-SHA case was previously accepted;
- `./test/impact.sh --verify` to validate the dependency graph;
- regenerate `REVIEW_LEDGER.md` and `OPEN-THREADS.md` only after REV-066 points to a resolvable implementation.

Do **not** run a broad runtime/ZFS campaign for this finding.

## REV-066 substantive review

The content change itself is directionally correct. Its response now distinguishes: 2.1 requires one real-ZFS proof because snapshot timing is the property under test; 2.2 is pure argv normalization and gains nothing from a host; 2.3 needs one delegated invocation because installed-code freshness is the environmental property. That is the intended test-cost model. REV-066 should be closed once its submitted implementation is pinned to a real commit and the protocol can enforce that invariant.

## Response path

Implementer response: `docs/internal/reviews/responses/REV-20260807-067.md`
