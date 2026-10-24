# REVIEWER CHECKPOINT

Purpose: compact bootstrap for ChatGPT reviewer. This file is a convenience index, **not** the canonical source of volatile review state. If anything here disagrees with `main`, `docs/project/OPEN-THREADS.md`, `docs/internal/reviews/REVIEW_LEDGER.md`, exact review/response/closure artifacts, or `docs/project/ACTIVE-WORK-PLAN.md`, the fresher canonical artifact wins.

## Latest final-audit batch — 2026-10-24 (local restore / PRs #539 and #541)

**Both local-restore backlog defects reproduce on their exact bases and are
corrected in the current tree; no current defect was found.** PR #539 spans
`ebb1fcf42eb88a8bda5c210e8210fb612db330e4..c809809040ffff0a9d1cc5ea529b925104d2266a`;
its corrective dispatcher commits culminate in
`99330357e4599ef4df661a0be352454ae6e9d83b` and
`c12b9c0a4ed233736c4aa36e1c128033227db45d`, and its merge is
`61af6f8977821db6ba766a6d725780f1d45b189b`. PR #541 spans
`616b6716ca90a918fc64850b11bc9e58152f844b..5c9286d6a3f092954add9321a8844c13ace8c5a8`;
the production correction is consolidated in
`db3a9f5aca7a2f801600029d372974fb520bc83d` and the merge is
`291b6307dc46053a53b51a738663a4b2b450d276`.

Independent evidence on current `main`
`eac8eee9b918a858cbeb2024ded46a76995ce1aa`:

- a public-entry negative control on PR #539's exact base returned rc 1 and
  **zero bytes** for a local relationship's read-only plan; the same invocation
  on current main returned rc 0 and the complete `Plan odtworzenia` without
  changing anything. The current focused dispatcher assertion passes;
- running PR #541's corrected `restoregrant` instrument against its exact base
  reproduced all five local failures: no rollback before the engine, false rc 0
  while a newer snapshot remains, a success verdict instead of `NOT at`, and no
  refusal/engine suppression when no base is pinned. The corresponding current
  assertions pass;
- current `test/restore/run.sh` is 335/335 and `test/deadcode/run.sh` is 7/7.
  `test/restoregrant/run.sh` is 207/210 in this root-only reviewer container;
  its three known failures are non-root precondition/message checks, outside the
  reviewed local-rollback path. The relevant `localbackup` assertion passes;
  its full suite is not valid in this root/container fixture and finished
  147/164 with unrelated install/seed fixture failures;
- `bash -n`, both exact-range `git diff --check` runs, both `test/impact.sh`
  selections and `./test/impact.sh --verify` pass;
- exact-head CI runs 38701660631 (#539) and 38710218351 (#541) passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38701660631 and
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38710218351;
- the repository's bounded manual evidence records the original silent exit,
  the original false-success local rewind, a successful destructive lab rewind
  with snapshot identity and `referenced` equality, and the next relationship
  run discarding the copy's now-newer snapshots. No live host or dataset was
  touched by this reviewer batch.

PR #539 now bypasses peer loading for `RUX_MODE=local` and confines a failed
remote load before handing diagnosis to `zfs-restore.sh`. PR #541 now requires
a uniquely pinned common base, rolls back only the exact engine depth and only
datasets with a copy counterpart, stops after a rollback refusal, and verifies
GUID, newest snapshot and live `referenced` state after an engine rc 0. No REV
was opened: these are historical defects with current corrective code and
discriminating regression evidence, not open acceptance properties.

**Next reviewer scope:** audit PR #553's widened restore delegation on its exact
range: creation and ownership of `<pool>/restore`, least-privilege capability
set, failure/retry cleanup, and revoke symmetry with concurrent grants.

## Previous final-audit batch — 2026-10-24 (F23 / PR #547 reconciliation)

**The original F23 guard was not fail-closed for a multi-dataset scope; PR
#547 corrected both halves and the current destructive boundary is reachable.**
F23 entered in
`08ab57cdd25f257d28f369eaf9f4399358872b3f` without a separate REV,
approval or closure artifact. Its prose said an absent/unparseable scope made
the root refusal inert and called that safe; no test changed in that commit.
The later live incident showed the composition was unsafe: the gate's
`:-\ ` bracket expression emptied every space-separated scope while the
collector treated an empty scope as permission to skip the root check.

The exact PR #547 range is
`f7478b700fa294c63fd17dbf31b8bc56ff054ff8..41ea9ae9fad01266e1c6ba2384ca4f75ab4166d8`;
the corrective commit is
`77e755e966b2796e2e50bd14385f5b47f3c5a547` and the merge is
`3070e49c064d0ce4190d6f3d9964b177679fae70`. The patch moved `-` to the end
of the gate whitelist and made a remote destructive `replace` refuse an empty
reported scope before the engine. PR #548 later refined a root to a scope
member whose parent is not in the same scope; PR #550's already-published audit
proves the package refresh carries the corrected gate to an existing install.

Independent evidence on current `main`
`6146dbab2d34296d1b195ec233ac56c6753225e6`:

- running PR #547's corrected test instrument against its exact base reproduced
  both failures: the multi-dataset gate assertion failed, and an empty-scope
  `replace` invoked the recorder engine; the same focused assertions on current
  main all pass, including both engine-not-invoked controls;
- current `test/pairgate/run.sh` is 92/92 and `test/restore/run.sh` is 335/335;
  the relevant five `test/restoregrant` assertions pass. Its full run is 207/210
  in this root-only reviewer container; the three failures are its known
  non-root precondition/message checks and do not traverse the reviewed scope
  guard;
- `test/deadcode/run.sh` is 7/7; `bash -n`, `git diff --check`, the exact-range
  `test/impact.sh` selection and `./test/impact.sh --verify` pass;
- exact-head CI run 38726889526 passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38726889526;
- the repository's bounded live evidence records root refusal before mutation,
  successful child recovery, intact delegation and subsequent successful chain
  runs. No live host or dataset was touched by this reviewer batch.

No new REV was opened. This is a historical proof gap plus later corrective
code, not a current defect. There is no F23 review to reopen; the current ledger
and open-thread view remain empty.

**Next reviewer scope:** reconcile the remaining paired local-restore backlog
items PR #539 and #541 against their exact fixes: public dispatcher diagnostics
for a local relation and a production-path off-point recovery control that
proves the local dataset is actually changed rather than merely reported.

## Previous final-audit batch — 2026-10-24 (REV-084 / PR #551 reconciliation)

**PR #551 restored the reachable fail-closed diagnostic; REV-20260809-084
remains CLOSED.** The exact PR range is
`b9b1e5c58f2f6e854f10e18abe6b99399f676b18..75709842186c3fb73319587bbdfcb14d487e7a9f`,
the corrective commit is
`bb2ec7dc02e954e3122117f8a3738a2a3ed7dd72`, and the merge is
`8f0746a427e89e752afc8ba7360afb15b5e76687`.

The old backlog warning was accurate. REV-084's original implementation made
`coverage_conflicts()` propagate unreadable/unparseable records, but the later
`die_arm_fatal` change meant that `record_load` could terminate the parent from
inside the per-record subshell before that status was translated into the
named refusal. PR #551 added `die_confine_to_subshell` at that exact boundary.

Independent evidence on current `main`
`6fe95b0be79bc4d532ead887ac8d97e73fa3a31d`:

- direct negative control on PR #551's base
  `b9b1e5c58f2f6e854f10e18abe6b99399f676b18`: a record with a disallowed field
  returned rc 1 with empty output; the higher-level refusal was not reached;
- the same probe on current `main`: rc 1 with the fail-closed
  `could not check ... refusing rather than guessing` diagnostic and the exact
  bad record path;
- the current restore-grant suite's two relevant assertions pass: the grant is
  not written when a relationship record cannot be read, and the reason is
  named. The full suite in this root-only reviewer container was 207/210; its
  three failures are the known non-root precondition/derived ordering checks,
  not the reviewed refusal path;
- `./test/impact.sh
  b9b1e5c58f2f6e854f10e18abe6b99399f676b18..75709842186c3fb73319587bbdfcb14d487e7a9f`
  selects the expected deploy/record/restore-grant/zfsbackup coverage;
  `./test/impact.sh --verify` passes;
- exact-head CI run 38759223428 passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38759223428.

No new REV was opened. The original REV-084 acceptance property is currently
implemented and now demonstrably reachable; PR #551 is later corrective code,
not grounds to rewrite the historical closure.

**Next reviewer scope:** reconcile PR #547 / the old F23 lab finding (multi-
dataset scope rejected by the pair gate, disabling the collector-side replace
guard) against the exact shipped fix, current gate parser, destructive-path
negative control and published review/closure history.

## Previous final-audit batch — 2026-10-24 (REV-129 reconciliation)

**PR #557 / REV-20260831-129 — historical evidence gap reconciled; REV remains
CLOSED.** The reviewed integrated range is
`b6e6adb68085abbb3cff3fe87f66a92a988c65c3..f31ac727acbab9595e5aaf9c0184793b9b92dad8`;
the P8 correction is `5b9ae11777c980e74a269b91fc99cc793208d4e7`
and the merge is `83bc122c2852cef8d4590cfc086ebb5889619bf2`.

The old backlog warning was valid about the proof, but not evidence of a
current open defect. REV-129's approval and closure were intentional and
formally connected: approval commit
`2d379051308f946fe618637830ea5e9b37923638` reviewed implementation
`8c5204919f366371810535417b18f3592e6bbfd9`, and the closure names the same
approval. The approval was nevertheless evidentially unsound. Its focused
test called `restore_remote_off_point` with a hand-built per-dataset map and
therefore never traversed `restore_one`'s production map builder. At the exact
approved SHA the focused test passed 9/9 while the production awk program
failed with `runaway string constant` (rc 2) because its `printf` contained a
literal newline. The map was empty and post-restore verification fell back to
snapshot names.

PR #557 fixed that production path by extracting `restore_guid_map`, corrected
the awk format string, and added both map-output and production-wiring tests.
Independent current-tree evidence at
`0b6737e6ecbc2e984d61960a15e6dff5e416ec09`:

- historical focused suite at the approved SHA: 9/9 despite the production
  awk negative control failing with rc 2 (this demonstrates the old test gap);
- current focused off-point suite: 9/9;
- current full restore suite: 335/335, including the two P8 production-path
  assertions;
- `./test/impact.sh b6e6adb68085abbb3cff3fe87f66a92a988c65c3..f31ac727acbab9595e5aaf9c0184793b9b92dad8`
  selected restore, restore-grant, TUI and dead-code coverage;
  `./test/impact.sh --verify` passed;
- upstream exact-head CI run 38810678111 passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38810678111.

No new REV was opened: the currently shipped production builder is corrected,
the regression now traverses the previously missed boundary, and no fresh
failure contradicts it. The stale `CHANGES REQUIRED` prose in the original
review remains historical finding text; the machine header, approval commit,
closure, response and ledger agree on the closed state.

**Next reviewer scope:** reconcile the next old-backlog empty-proof report,
PR #551 / REV-20260809-084 (`coverage_conflicts` and `die_arm_fatal`), against
the exact published approval/closure and current reachable refusal path; do
not reopen it without a current defect or new contradicting evidence.

## Previous final-audit batch — 2026-10-24

**GUI reader timeout, PR #813 — reviewed, no new finding.** The exact integrated
range was `7c4a57581ad9b50ed1ab9f0c50e3f0fb764181f6..66e702aade8cb96a0e3af8cb45079adc13d47b02`;
the implementation commit was `749b41b43c5264a1d51475298ee8594da76820c5`,
the status update was `839de264e9dd7f3a86c8bfbca8d45161113829a6`, and
the merge commit was `66e702aade8cb96a0e3af8cb45079adc13d47b02`.

The change is confined to read-only GUI verbs. A hanging reader and its child
process are killed as one process group after the configured deadline; the
error reaches the existing stale-data gates, while normal JSON remains
unchanged. Independent evidence:

- focused timeout/child/normal-reader checks: 3/3;
- stale-row action gates: 13/13;
- negative control: the base waited 2.00 s and had no timeout diagnostic; the
  reviewed head returned after 1.00 s with the expected timeout diagnostic;
- full TUI suite in its expected checkout/whiptail environment: 405/405;
- `./test/impact.sh 7c4a57581ad9b50ed1ab9f0c50e3f0fb764181f6..66e702aade8cb96a0e3af8cb45079adc13d47b02`
  selected `test/tui/run.sh`; `./test/impact.sh --verify` passed;
- upstream CI run 40029976213 passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/40029976213.

No REV was opened. The current ledger and open-thread view contained no live
review. Source-retention equality and config export/import round-trip were not
reopened: their acceptance properties are already covered by closed REV-171
and REV-168 respectively, with no new contradicting code or evidence in this
batch.

That batch routed the next review to the old
`REVIEW-BACKLOG-2026-10-16.md` warning for PR #557 / REV-129; the latest batch
above records its completed reconciliation.

## Mandatory start of every Check / reviewer write

1. fresh READ of `main`;
2. move `reviewer-write-probe` to that exact SHA;
3. read the probe back and verify exact SHA;
4. only then review or write;
5. never probe writes on production code/main itself.

Roles: Claude = implementer, ChatGPT = independent reviewer/architect, Owner = user. GitHub is the protocol between Claude and reviewer. Never accept implementer claims without exact diff/artifact/evidence inspection.

Review protocol:
- reviewer: `docs/internal/reviews/REV-YYYYMMDD-NNN.md`
- implementer response: `docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md`
- closure: `docs/internal/reviews/closures/REV-YYYYMMDD-NNN.md`
- generated routing: `docs/internal/reviews/REVIEW_LEDGER.md`, `docs/project/OPEN-THREADS.md`
- gate: `./test/impact.sh --verify`

State model: `OPEN -> IMPLEMENTED -> APPROVED -> CLOSED`; same acceptance property stays the same REV, independent defect gets a new REV.

## Durable owner contracts

**Reduction, not complication.** Prefer the smallest safe rule, refusal on ambiguity, and native CONFIG v4 over inheritance, merge/precedence engines, drift managers, Cartesian preset catalogs, or lifecycle frameworks.

**Preset/profile is CREATE-only.** `PROFILE/PRESET -> generate candidate CONFIG -> preview -> install`; after install **CONFIG v4 is runtime truth**. Ordinary reactivation/topology maintenance must not reconstruct, repair, normalize, migrate, or silently reapply policy from the profile.

**Additive CREATE:** a new disjoint task/package may be added, but old task semantics must remain unchanged. Exact/parent/child overlap refuses. Semantic template reuse is allowed; same identity with different semantics refuses. Whole candidate CONFIG + resulting cron are validated/previewed before atomic install/read-back.

**Explicit source:**
- local explicit `--source` is authoritative WHAT and must validate;
- no explicit source -> discovery may propose;
- any invalid explicit source -> hard REFUSE of the whole requested set, no fallback and no partial success;
- on initial remote connection, collector must not treat `--source` as established truth before source-side discovery/scope/grant; accepted remote scope becomes authoritative only after that boundary.

**Recursion:** CONFIG HOW field `recursive = no|flat|atomic`; legacy hidden `-r/-R` in flags refuses. Recursion is policy/HOW, not relation topology.

**Frozen engines:** `snapsend.sh`, `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh`, `lib-zfs-snap.sh`; thaw/change only with explicit reviewer justification and appropriate evidence.

Canonical architecture references:
- `docs/discussions/PROFILE-REDUCTION-PRINCIPLE-2026-08-09.md`
- `docs/discussions/PROFILE-PREINSTALL-NOT-FULL-CONFIG-2026-08-09.md`
- `docs/discussions/EXPLICIT-SOURCE-BEATS-DISCOVERY-2026-08-09.md`
- `docs/project/ACTIVE-WORK-PLAN.md`

## Current compact state — refreshed 2026-08-10 22:33 CEST

Always refresh `main` before relying on any SHA below.

Closed gates/phases already established in repo:
- Phase 1 — live safety gate: CLOSED.
- Phase 2 — additive CREATE cannot mutate old policy: CLOSED; REV-092 resolved the CONFIG-global `[excluded:]` residual.
- Phase 3 — endpoint/reactivation preserves installed policy: CLOSED; REV-089/090/091 closed.
- Phase 3.5 — prefixless create / passive `-e` / prefixless GFS expressibility: CLOSED; REV-093 closed with live-ZFS evidence.
- Phase 4 / Gate 4 — public CREATE-time profile selection proof: CLOSED by REV-095.
- Phase 6 runnable-example hygiene through the current four examples: REV-094 and REV-096 CLOSED.

Current review routing after REV-096 closure:

**No open reviews.** `docs/project/OPEN-THREADS.md` is canonical and must still be read fresh before acting.

Latest reviewer-reviewed test-hygiene implementation:
- REV-096 — total semantic-coverage registry for runnable `docs/examples/*.conf` — implementation `ac6fe3119412a684edf483caa0895fd2bb1e5883` — APPROVED/CLOSED.
- The registry now fails both for an unregistered runnable example (`uncovered`) and for a stale semantic-coverage registration whose file disappeared (`stale`).
- This was test-only; no live ZFS/SSH/crontab/grant/account proof was required.

## Work sequence / current next move

Canonical sequence remains:

`CREATE-only additive -> endpoint/reactivation preserves policy -> public --profile at CREATE + preview -> simple local --source/--target workflow -> minimal presets + expert docs -> RESTORE -> optional conveniences only on proven need`

**Next functional work per the owner-approved plan: Phase 5 — high-level local deployment UX — ACTIVE NOW.**

Target operator shape:

`./zfs-backup.sh --source=rpool/data --target=hdd/backups`

Phase 5 must preserve the explicit-source contract above: omitted source may trigger discovery/proposal; any explicit invalid source hard-refuses the whole requested set; no fallback or partial success. Recursion remains HOW/preset, not WHAT. Nested target inside source refuses. Decline/failed seed must remain retryable with no production cron.

Phase 6 documentation work may proceed independently where it does not cross Phase 5's gate, but must not stall or replace the next functional Phase 5 work.

## Reporting format for Owner

For every `Check`, report short descriptions, not bare IDs:

`Phase N — short goal — STATE`

then e.g.

`REV-096 — semantic coverage registry for runnable CONFIG examples — CLOSED`

Manual `Check` means an immediate fresh independent review, not a repetition of hourly automation state.
