<!-- rev: REV-20260807-067 -->
<!-- verdict: APPROVED -->
<!-- reviewed-implementation: d4a1e7dae3ec085db8728d1c01c5a92b25e2a034 -->
<!-- supersedes: - -->

# REV-20260807-067 — reviewctl must reject an unverifiable implementation SHA

**Original review time:** 2026-08-07 22:01 CEST

**Original reviewed head:** `8980e2653cfff76aec0dd3b1a30700d9f704a555`.

## Original finding

Protocol V2 could route a review to Reviewer using an implementation SHA that the reviewer could not fetch from the published branch. The triggering SHA was later shown to be a real local commit orphaned by a rewrite, which sharpens the invariant: mere object resolvability is insufficient; the commit-bearing header must point at a commit reachable from the published review branch.

## Approval — 2026-08-07 22:58 CEST

**APPROVED implementation:** `d4a1e7dae3ec085db8728d1c01c5a92b25e2a034`.

The implementation correctly enforces the stronger property. `reviewctl` validates `implementation`, `reviewed-implementation`, and `closed-by`; distinguishes a non-commit from a commit that exists locally but is not reachable from `origin/main`; names the REV/field/SHA in the refusal; and fails closed when commit verification is unavailable. The explicit `-` sentinel remains legal for the protocol state where no commit exists yet.

The response also corrects REV-066 to published commit `39663b2b754f2194b0342f068a93fe3b22aaeadc` rather than the orphaned pre-rewrite SHA.

The evidence is appropriately minimal and discriminating: `test/reviewctl` reports 28/28; the negative control against pre-fix `2620824` has six new assertions fail while 22 structural cases still pass; and the orphan case creates its own dangling commit with `git commit-tree`, so the test does not depend on accidental local history. No live-host/ZFS proof would add evidence to this repository-metadata invariant.

One limitation remains documented rather than hidden: reachability proves that the reviewer can fetch the named commit, not that the commit contains the complete intended delivery. Content completeness remains a review responsibility.

## Response path

`docs/internal/reviews/responses/REV-20260807-067.md`
