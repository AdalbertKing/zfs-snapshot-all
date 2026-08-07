# REV-20260807-055 — recursion implementation closure

**Reviewed head:** `ba24c8bd56d5acf71b69fa795fdcb69baa8e66ae`  
**Scope:** implementation of the contract approved in `REV-20260807-054`, including `gen-cron.sh`, `cron2conf.sh`, fixtures/tests, migration evidence, and the draft-config UX obligation.  
**Verdict:** **CHANGES REQUIRED**

The core generator work is directionally correct: `recursive = no|flat|atomic` is section-scoped, drives transfer/prune/monitor together, and legacy recursion in ordinary/bundled flag spellings is rejected. The round-trip work also correctly removes the recovered recursion flag from reconstructed free-form `flags` and refuses inconsistent tiers.

Two acceptance conditions from REV-054 are still not satisfied on this head.

## F1 — `deploy.sh --draft-config` was not migrated to the typed field

REV-054 acceptance condition 5 was explicit: `deploy.sh --draft-config` must emit/comment the typed `recursive =` field instead of prose telling the operator to put `-R` in `flags`.

The implementation commit changes `gen-cron.sh`, `cron2conf.sh`, their tests/fixtures, and project docs, but does not change `deploy.sh` at all. The design document still records the existing draft behaviour at `deploy.sh:5543`: the draft prints prose saying a descendant set can be covered by one `-R` in `flags`.

That is now actively stale guidance: on the same head, `gen-cron.sh v4.27` hard-rejects `-r/-R` in `[dataset:] flags`. A newly generated draft can therefore tell the operator to write a configuration that the generator refuses.

### Required correction

- Update the draft-config output to show/comment `recursive = flat` (or the appropriate typed-choice wording) rather than instructing the operator to add `-R` to `flags`.
- Add a focused regression test that fails against the pre-fix draft output and pins the absence of the legacy `-R in flags` instruction.
- Keep the choice explicit; do not silently make every dataset recursive.

No live campaign is required for this correction.

## F2 — the required real pve1 migration fixture/equivalence proof is missing

REV-054's migration decision required the one known live legacy-recursive configuration — pve1 `[dataset:rpool/data] flags = -r -v 3` — to be migrated to the typed field and proven to reproduce the currently installed managed crontab under the repository's existing comparison rules.

The implementation adds a synthetic `test/fixtures/recursive.conf` / `.expected` matrix and a `cron2conf` recursive fixture. Those are useful semantic tests, but they are not the required pve1 migration fixture and they do not prove byte/set equivalence to the currently installed managed block that motivated the hard cut-over.

This matters because hard reject intentionally makes the existing pve1 source config non-regenerable until it is migrated. The migration proof was the acceptance condition that made that operational cut-over safe.

### Required correction

- Add the migrated pve1 fixture (or an equivalent captured fixture tied to the current managed block) using `recursive = atomic` and removing legacy `-r` from `flags` while preserving the other flags (e.g. `-v 3`).
- Assert that generation reproduces the installed managed block according to the same byte/set-equivalence rule used elsewhere in this repository.
- Record the exact comparison result in the response to REV-054/055.

No engine or two-host campaign is required unless this exercise uncovers a runtime change.

## What is accepted already

Subject to F1/F2 above, the following parts of `ba24c8b` satisfy REV-054:

- one typed dataset representation: `no|flat|atomic`;
- both push and pull mapping covered by the new golden fixture;
- transfer, inline prune and monitor all carry the same recursion scope;
- bundled `-R` / `-r` spellings are rejected by targeted negative tests;
- `cron2conf.sh` extracts recursion into the typed field and removes it from reconstructed free-form flags;
- inconsistent recursion across tiers is refused rather than guessed.

## Acceptance for closure

Fix F1 and F2, run the targeted generator/draft/cron2conf tests plus `impact.sh --verify`, and respond with exact counts and the pve1 equivalence result. A new full ZFS/remote campaign is not requested.
