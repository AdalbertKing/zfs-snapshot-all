# REVIEWER CHECKPOINT

Purpose: compact bootstrap for ChatGPT reviewer. This file is a convenience index, **not** the canonical source of volatile review state. If anything here disagrees with `main`, `docs/project/OPEN-THREADS.md`, `docs/internal/reviews/REVIEW_LEDGER.md`, exact review/response/closure artifacts, or `docs/project/ACTIVE-WORK-PLAN.md`, the fresher canonical artifact wins.

## Latest final-audit batch — 2026-10-25 (PR #849 / REV-174 verification)

**REV-20261024-174 remains CHANGES-REQUIRED.** Submitted PR #849 head
`096c9433e07dbf4f74e54b7947b844571c62fcdb` (implementation
`084aabef741e6865aa8a24ab9d87ca80011e153c`) fixes weakened and removed
existing `-P` floors, but does not meet acceptance criterion 1. The new guard
accepts any new token shaped `:all` or `:2`; it cannot tell whether that token
was actually generated. Thus a kept `vzdump:2` plus an unrelated new
`manual:all` is still excused with the empty-pattern rewrite. This can suppress
intended pruning and create capacity pressure.

The exact static trace and required negative controls are recorded in the same
REV artifact. PR #849 remains open on old base
`99ea75ddf86e09cdca5c21a42bdff84fc1ab90a3`, and GitHub reports no workflow run
for its exact head. No implementation was merged and no live host was touched.

**Next reviewer action:** wait for Claude to narrow the exception to the exact
generated protection set, add arbitrary-new-`:all`/`:2` negative controls,
rebase, and provide exact-head CI. PR #469 remains queued after this response.

## Latest final-audit batch — 2026-10-24 (PR #845 local passive copy)

**No new finding was confirmed.** The exact implementation range is
`d16c1ea5a2acde06ef2a5b60e22a6229f703bfd8..994b404bdc9e2c538aee6cca0697a4dc903ec0af`,
merged as `bb00fca9c1a85373f45c3251ef2f8a3cf51c290d`. It adds local
`local-backup --passive` pickup for an existing snapshot family, the recursive
source-overlap refusal, and the non-interactive `edit-config` stop after a
rejected candidate.

The passive candidate writes `passive = yes` on every source section, renders
`snapget -e`, omits source `delsnaps` while retaining landing retention and
monitoring, seeds against the whole family root, and refuses the meaningless
no-copy combination. A recursive source now conflicts with an already-installed
child section; the same flat source remains the negative control. The installer
continues to reject source/target nesting before composition. No cron, ZFS or
live host was changed by the review.

Exact-head evidence: cron 235/235, deadcode 7/7, and every new passive/overlap
assertion in localbackup and TUI passed. The whole localbackup run was 154 pass /
17 fail and TUI 403 pass / 8 fail: the former failures are the pre-existing
container fixture pinning `[defaults] repo_dir` to a non-runnable root path; the
TUI failures are unrelated command-line/terminal fixture cases. The passive seed
trace still proved `snapget -m automated_ ... -e`; only the subsequent record
assertion was blocked by that same install-fixture refusal. Exact-head CI run
40131058505 and `impact --verify` pass.

**Next reviewer action:** pick up any `IMPLEMENTED | Reviewer` response to
REV-20261024-174 first. Otherwise continue with PR #469, source-side prune
schedule spreading. Do not repeat PR #845 without new code or evidence.

## Latest final-audit batch — 2026-10-24 (PR #465 / REV-174)

**A new P1 finding was opened in the destructive `prune_foreign` installer
boundary.** PR #465 is the exact range
`533b41a34a3da8656a29adfcfb5f9d8d6a0f7096..cacf61c230b1df84734f0a5d672820b3ec7b14ea`,
merged as `288ab86a51713747574b6eb7e4406c851e611a51`.

The generator itself still constructs the intended empty-pattern carrier,
protects every other managed family with `:all`, keeps two replica snapshots,
and refuses remote scope. The defect is the seventh install-guard exception:
`foreign_normalized_identity()` removes every `-P` token while comparing the
installed and proposed lines. An independent floor such as `vzdump:2` can
therefore change to `vzdump:0` in the same proposal and be accepted as if only
the permitted U4 rewrite occurred. The next empty-pattern retention run can
then delete old snapshots from that newly unprotected family.

Deterministic production-function evidence: a plain protection change is
refused (rc 1), the intended U4-only transition is accepted (rc 0), and the
combined U4 plus `vzdump:2 -> vzdump:0` transition is incorrectly accepted
(rc 0). Exact-head suites pass 165/165 cron, 35/35 cron2conf, 12/12 passivepick
and 8/8 mirrorguard; exact-base production files add 7, 4, 1 and 1 failures.
Current main passes generator 123/123, cron 230/230, passivepick 15/15 and
mirrorguard 8/8, demonstrating the missing cross-condition assertion rather
than a broad regression. No cron or ZFS action was performed.

**Next reviewer action:** pick up any `IMPLEMENTED | Reviewer` response to
REV-20261024-174 first. Otherwise continue with PR #469, source-side prune
schedule spreading. Do not repeat the remainder of PR #465 without new code or
evidence.

## Latest final-audit batch — 2026-10-24 (PRs #453/#455 engine control and observability)

**The terminal progress-record rewrite and lock-skip rc 75 contract remain
correct; no new REV was opened.** The exact deliveries are:

- PR #453: base `45d0dc0c54d8f24df776743dbdcafd9ddde8c840`,
  production commit `e03c2df2372e54191cec9c389b3dfe83dfa0e871`, final head
  `27072f9bedf39cf9fdb2fffea651eb9ec6f66935`, merge
  `9de180bf0213e3b3c3ee14eee64181d9f2d5e09e`;
- PR #455: base `2a5c8201afc67628fa6b79c067984e2c304d8277`,
  production commit `b11cd9e1420edf62ff52a95f873c79ee1a9080a0`, final head
  `2d433ca7955f97c2f944c4c77d3a67093ea6eaa0`, merge
  `2daddf61d3171a2613906df75c70c964da4a4e84`.

`progress_done` now replaces either the running terminal or an already
finished terminal from the previous transfer and heals an old glued record by
cutting at the first real top-level `,"state":` field. It writes through a
temporary file, leaves unknown shapes untouched and remains telemetry-only: no
transfer decision reads this record. Escaped dataset text cannot impersonate
the delimiter. For the lock gate, both engine twins still emit the same
`skipped_lock` statistic and diagnostic, but return EX_TEMPFAIL 75 rather than
false success. `zfs-job` records the real rc and routes 75 only to the warning
script; ordinary nonzero status still uses the failure notifier. The repository
contains no other producer of rc 75, and later run-now handling explicitly
classifies 75 as busy rather than success or failure.

Independent evidence on current `main`
`16c9fd9d73b7780d2b1f193a2a2de1a02f8512d4`:

- current `test/twins` is **94/94**, `test/pairpause` is **22/22** and
  `test/cron` is **232/232**;
- at exact PR #453 head, the historical twins suite is now **82 PASS / 1
  unrelated FAIL** because its `process_dataset` porting deadline expired on
  2026-10-19. Replacing only `lib-zfs-snap.sh` with the exact base adds the
  intended `progress_done` failure (**81 PASS / 2 FAIL**). Exact-head CI run
  `37450082594` succeeded before that dated deadline expired;
- exact PR #455 head is **22/22** in `pairpause` and **146/146** in `cron`.
  Replacing only both engines and `zfs-job.sh` with the exact base yields
  **20 PASS / 2 FAIL** (both engines return the old rc) and **145 PASS / 1
  FAIL** (75 goes to the failure notifier). Exact-head CI run `37452537070`
  succeeded;
- both exact-range `diff --check` checks pass. The recorded live evidence on
  pve10 invoked the same cron line twice for root and the delegated account:
  the second run returned 75 and queued one WARN rather than an ALERT. The
  reviewer did not repeat live-host concurrency or ZFS work.

**Next reviewer scope:** PR #465, the destructive `prune_foreign = yes`
delivery. Verify exact family/protection construction, refusal of remote scope,
installer-guard exceptions and a negative control proving unrelated protected
families survive.

## Previous final-audit batch — 2026-10-24 (PR #463 removable replica -> snapget -M)

**No new confirmed defect and no new REV** in the exact PR #463 transition
`9fb9a7afd2904c8ac58d1a7e989b1ed19e49e428..91954aafa0ca1305d86669ab5c4159ec768f9674`,
merged as `76ee2e94f7da0eedcee593bd8c5f11293cfab75f`.
Current published tree reviewed: `7ff2b0bd1d11ab865a03100023b0606c2a3fbc0e`.

- **Engine/target:** `gen-cron.sh::replica_engine_cmd` switched the local
  `snapsend.sh -m P` call to `snapget.sh -m P -M`. The mirror uses the shared
  transfer library, then reconciles the target's extra snapshots; it does not
  enable a new unconditional `receive -F` or independently authorize deleting
  source datasets. The destructive mirror/P-0 boundary is already documented
  separately and is not silently reapproved by this batch.
- **Bookmark identity:** both `snapsend.sh` and `snapget.sh` source the same
  `lib-zfs-snap.sh`; both call `record_send_bookmark` with the same destination
  name and `IDENTIFIER`. `bookmark_target_tag` hashes
  `printf '%s\0%s' target identifier` and takes 8 hexadecimal characters.
  The PR #463 generator's ordinary replica does not introduce a `-j`
  identifier. The old and new transport therefore retain the same per-target
  anchor calculation, not merely the same comment.
- **Medium identity:** PR #463 itself did not implement GUID registration;
  subsequent owner-directed changes did. On current `main`,
  `zfs-media-gate.sh` checks explicit allowed pool GUIDs before importing,
  handles multiple same-name candidates, and distinguishes its own import
  from a pool left imported by another actor. Its detach path refuses a
  nonmatching ownership marker rather than exporting a different disk.
  Later PRs #741 and #742 additionally record success on media already
  imported and decouple the copy-current marker from the all-or-nothing
  skip record. Those follow-ups matter to present-day correctness and are
  not mistaken for evidence on the original PR head.
- **Error reporting:** the PR #463 `snapget.sh::mirror_target` change raises
  the summary to log level 0 when at least one snapshot was removed or
  could not be removed; a no-change run remains level 1. Current
  `test/twins` exercises these three outcomes. A stuck removal still
  yields a failed mirror result rather than a silent success.
- **Compatibility boundary:** at the original PR head `cron2conf.sh`
  accepted both old installed `snapsend` and new `snapget -M` replica
  envelopes and kept flags. Later X27 S4 intentionally removed
  `cron2conf.sh` and its own suite; it would be misleading to claim
  those old legacy round-trip tests still run on current main. The
  current cron generator instead has direct tests for ordinary/passive
  replicas, `-M`, GUID gating, own `keep=N` pruning without `-M`,
  and long-command dispatch.

**Evidence measured from repository and actual CI logs:**

- Exact PR #463 head Actions run `37495811929` completed SUCCESS. A reviewer
  worktree at that exact head reran the now-deleted `test/cron2conf` suite:
  **31 PASS / 0 FAIL**. The same head suite with the exact base parser fails
  the three new replica-shape fixtures (`replica-fixed`,
  `replica-multisource`, `replica-removable`), so the parser update is
  discriminating. The PR report's older count of four base failures is not
  reproduced and is not repeated as evidence. Exact-head `test/twins` now
  reports **93 PASS / 1 FAIL** solely because its dated `process_dataset`
  porting deadline expired on 2026-10-19; that unrelated port is complete on
  current main, where twins is 94/94.
- Current `main` push Actions run `40112247542` completed SUCCESS,
  51/51 jobs successful. Logs examined: `mediagate` **160 PASS / 0 FAIL**,
  including L8r (foreign/same-name GUID), L8s (two disks), L8f (pre-imported
  medium), AG1–AG8; `twins` **94 PASS / 0 FAIL** including mirror log
  levels; `cron` **232 PASS / 0 FAIL**; `gencron` **123 PASS / 0 FAIL**.
  Syntax and dependency graph jobs also succeeded.
- The original PR describes a live pve9/USB replication followed by removal
  of a source snapshot and target reconciliation. This is implementer
  operational evidence only: reviewer has not repeated USB, pool import,
  destruction, bookmark continuity or hardware checks on a live host.
  Successful CI is not a claim of a second independent live test.

**Outcome:** no distinct newly confirmed PR #463 regression against current
published implementation; no review state transition needed. Keep closed REV
findings closed. No production script or host was changed by this audit.

**Next reviewer scope:** PRs **#453 and #455** as one small engine-control
batch: terminal progress accounting and lock-skip rc 75/reporting across both
engine twins. PRs #480/#482 are already covered by REV-151 and its accepted
continuation; do not repeat that destructive-landing campaign without new code
or evidence.

## Previous final-audit batch — 2026-10-24 (PR #510 / W19 and W14 engine reconciliation)

**PR #510's encrypted-parent receive and replica-only log classification remain
correct on the current tree; no new REV was opened.** The exact PR range is
`71b51681f7d576db47fad7b70598f35efea034a4..bb509c2ebacf2db2bdc93f8f6855d5a311f5d8de`,
with production commit `ed97b9bdc83fa4cf284e68fb6685de20f98c3b84`
and merge commit `bfbc3b5d20c937b60c9532469e237f194603e9aa`.

W19 leaves an absent target leaf to `zfs receive` when its nearest existing
parent is encrypted, matching the raw-send path. Ancestors are created with
`canmount=noauto`, target reachability is checked, and the saved `canmount`
value is restored after transfer. Failure to read the parent's encryption
state preserves the previous pre-create behaviour; it neither grants deletion
authority nor reports a failed transfer as successful. W14 does not change the
existing `receive -F` decision: it lowers log severity only when
`written@base` is zero, there is at least one newer snapshot, and every such
snapshot is named `replica_*`; all other divergence remains loud.

Independent evidence on current `main`
`ba2b561dd04f47c914c08d2e64385b07dae1b880`:

- the helper blob is byte-identical to the PR head and both reviewed branches
  remain present;
- focused W14 controls pass 4/4, and fake-ZFS W19 encrypted/unencrypted-parent
  controls both pass;
- the exact base has neither helper (negative control), while shell syntax and
  exact-range `diff --check` pass;
- twins pass 94/94, eval-free passes 16/16, and `impact --verify` passes;
- exact PR-head CI run `38242689996` completed successfully. The recorded
  manual evidence used disposable file-backed `pve9b` pools for first and
  incremental push plus first pull; the reviewer did not repeat live-host work.

The former U49 handoff was stale: U49 was already audited in the historical
note of REV-152 and its separate bare-`user@host` routing defect REV-154 is
closed. U35, browse/mount, U42-U47, and GFS/configuration round-trip scopes are
also published; do not repeat them without new code or evidence.

**Next reviewer scope:** PR #463, concentrating on the removable-replica move
onto `snapget -M`: media identity gating, bookmark continuity, and failure
reporting. Treat the mirror-deletion boundary already reviewed in PR #460 /
REV-150 as prior evidence rather than reopening it without a new delta.

## Previous final-audit batch — 2026-10-24 (source-side GFS and relation export/import reconciliation)

**The scope named after the X27 batch was already independently reviewed, but
that completion was buried in REV-152's historical audit note and the later
REV-168 lifecycle.  Fresh current-tree checks found no new contradicting code
or evidence, so neither closed REV is reopened.**

The source-side GFS delivery is PR #610: base
`3a99ff48ceeb71e8f9b2b66ad107343b183272aa`, first implementation
`6a1344d4477fb388519a9adf60eb521c17780769`, final head
`b97e0be8e665be18e94ff5dfa6e58a7dddecb321`, merge
`03888a6ce0bcd00f2750ec4e5b03e99f9813f17f`.  The adjacent relation
export/import delivery is PR #629: base
`998d1b2b2879dc635a35cb3ebcb701c87a249035`, head
`8c9e435fe3fbed05d0451ab16c6b35b47e7580db`, merge
`6799af50ed5e845616b2a97e7259aa6e1ea755dd`.  Its escape-handling defect was
published as REV-20261022-168 and fixed by
`6413f161b9fd3f1f3830664a94275c2253e14418`; the canonical approval and
closure remain consistent.

Independent evidence on current `main`
`5b502ed2a3a74470e7265c1c6eeed7453a831bef`:

- the exact pre-PR #610 base renders the source hourly tier as a flat
  `delsnaps` count (no `-G`), reproducing the historical defect.  Current
  `[relation:]` expansion with `gfs = yes` renders two source-side `-G` lines
  and zero target-landing `-G` lines; target retention remains flat as required
  by the post-downtime safety decision;
- `bash test/run.sh` is **123/123**, including the `prune-tier-gfs` golden,
  old/new relation equivalence and fail-closed relation-shape controls;
- `bash test/zfsbackup/run.sh --section exportrel` is **79/79**.  It executes
  real relation export and block restore, proves unchanged/changed `--check`,
  preserves a literal quote and backslash byte-for-byte, and refuses an
  unsupported escape or non-string value without installing anything;
- the published REV-168 reproducer is **4/4** on current main; the recorded
  pre-fix result remains **2 PASS / 2 FAIL** on the same equality and restored
  value criteria;
- `bash -n gen-cron.sh zfs-backup.sh`, both exact-range `git diff --check`
  checks and `./test/impact.sh --verify` pass.  PR-head CI runs recorded by the
  original audit/closure are 39162123391 (#610), 39313874955 (#629) and
  39847065498 (REV-168 implementation), all successful.

No new REV was opened.  This batch makes the already-published result visible
in the continuation artifact and removes the stale instruction to repeat the
same campaign.  No live host, crontab, account or ZFS dataset was touched.

This batch's former U49 handoff is superseded by the latest reconciliation
above; U49 was already completed and must not be repeated without new evidence.

## Previous final-audit batch — 2026-10-24 (X27 pre-block compatibility reconciliation)

**The backlog warning mixed two different compatibility contracts.  Current
`gen-cron.sh` still renders production-shaped pre-X27 config made only from
`[template:]` plus `use_template`, while commands which edit a named
relationship deliberately require its `[relation:NAME]` block.  The latter is
an explicit Owner decision, not an unreviewed migration defect.**

The reviewed delivery is the exact sequence:

- PR #531: `1ff3809c4b4192296568f4f0f8af401e6274743f..e2cf0356513cd41e26c08320f2ccfc34ccddcf88`,
  merge `a326a0bd099aad2cedf639258abfa8ab11be038a`;
- PR #533: `a326a0bd099aad2cedf639258abfa8ab11be038a..37c94ddaef74819389794c45c926219716c1cb84`,
  merge `ba4b80494c9ad2cf36964c70b02295c2518ced49`;
- PR #534: `ba4b80494c9ad2cf36964c70b02295c2518ced49..cf210ace0e6d06ea30497c4bd882b15a87f8a4f5`,
  merge `59dd621385ebe83db6b34134212dd2c0edfe35ee`;
- PR #535: `59dd621385ebe83db6b34134212dd2c0edfe35ee..014066dfd3e9f7ed23e97a9cfd3322c080c53581`,
  merge `f47c7a79b39c6667e6add93004021d4d5eba936d`;
- PR #536: `f47c7a79b39c6667e6add93004021d4d5eba936d..133fc90af4b5869fe0063d451956de6a90e286e0`,
  merge `e3e03763002068ddf15b00731f76b040a7df0c1c`.

Independent evidence on current `main`
`c8d27f2b4ea372aed7d8d402d9302aa44af227ae`:

- the production-shaped old remote fixture, containing no `[relation:]` block,
  renders successfully (rc 0), and its generated cron is byte-equivalent to the
  corresponding X27 block fixture after the documented source-line
  normalization.  The local pair is equivalent as well;
- `test/run.sh` is **123/123**, including both equivalence pairs and the
  fail-closed controls for a missing block, missing/invalid `side`, a mixed
  `relation` + `use_template`, foreign label, orphan block, tier mismatch and
  unknown relation field;
- the relevant `localbackup` X27 assertions pass: `set-tiers` round-trips the
  block, the old named-relationship shape is refused with the reconstruction
  command and no write, `edit-relation --profile` replaces one block only, and
  snapshots-only/local source-side forms remain valid.  The full suite is
  **148/164** in this root/container checkout: all 16 failures are the known
  install-fixture cascade where the generated root block points outside the
  fixture (`[defaults] repo_dir`) and no `crontab-writes` file is created; none
  is in the reviewed X27 compatibility assertions;
- `bash -n gen-cron.sh zfs-backup.sh` passes.  The historical combined range's
  `git diff --check` reports one trailing blank line in `test/deps.conf`; this
  is historical whitespace, not a current-tree or reviewer-patch failure;
- exact-head CI passed for every delivery: runs 38596804612 (#531),
  38602104934 (#533), 38615070362 (#534), 38634304966 (#535) and 38639067192
  (#536).

The controlling Owner decision is recorded in
`docs/project/X27-CONFIG-JEDYNYM-ZRODLEM.md` and current project status:
automatic backward migration was removed because the package was still in the
lab; lab relationships were converted host by host, while existing production
managed cron blocks keep running until an explicit rebuild.  A manually written
config without relationship records remains a supported generator input.  A
named relationship in the old shape is not silently guessed or rewritten:
mutating/read-model commands refuse and tell the operator to recreate it from a
profile.  Restoring `migrate-config` or `cron2conf` would contradict that Owner
boundary and expand version 1.0 scope.

No new REV was opened.  This batch reconciles the stale backlog warning with
the actual split contract and the Owner's recorded cut-over decision.  No live
host, crontab or dataset was touched.

This batch's former next-scope pointer was completed by the reconciliation
above; do not repeat the GFS/export-import campaign without new code or evidence.

## Previous final-audit batch — 2026-10-24 (PR #553 / REV-170 reconciliation)

**The widened `<pool>/restore` delegation was unsafe in PR #553, but that
exact defect and its continuation are already covered by CLOSED REV-170; the
current capability lifecycle satisfies the published acceptance boundary.**
The exact PR #553 range is
`b3660d3fc593e8824214174d2930d77c085565d0..30710f595b475a68c383a552d27c3e03b9a38641`
and its merge is `23dd574486db30f94849504e92bd0339ac72898f`.
The final approved implementation is
`e6b0be67f7060b7d427c952c047929bcaf37a0bc`; approval commit
`1a4911261f4d5bec9604830947e498e8bb766985` and the canonical closure agree.

Independent evidence on current `main`
`77c8a3b89d2806f2273e63f21e345cd947dfb128`:

- the published shared-namespace reproducer against exact PR #553 head is
  **5/5 PASS**: withdrawing the first of two same-account grants removes their
  one shared namespace capability while the second grant remains active;
- the same reproducer on current main is **4 PASS / 1 expected FAIL** because
  the capability correctly remains effective for the second owner;
- the account-drift control against exact PR #553 head is **3 PASS / 3 FAIL**:
  no grant-time account is recorded, withdrawal revokes the rejoined account,
  leaves the original tuple delegated and removes the other active account's
  tuple. Current main is **6/6 PASS** and its trace names only the grant-time
  account;
- the current `restoregrant` suite's REV-170 sequential-owner, pending retry,
  cross-account/pool, concurrent withdrawal, killed lock-holder, ambiguous
  legacy record and account-drift controls all pass. The full run is 207/210
  in this root-only reviewer container; all three failures are the known tests
  that deliberately require a non-root caller. The supported CI evidence in
  the approval records 210/210;
- `test/restore/run.sh` is 335/335 and `test/deadcode/run.sh` is 7/7;
  `bash -n`, exact-range `git diff --check`, `test/impact.sh` selection and
  `./test/impact.sh --verify` pass;
- exact PR #553 head CI run 38787893215 and final REV-170 implementation run
  39939015319 passed:
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/38787893215 and
  https://github.com/AdalbertKing/zfs-snapshot-all/actions/runs/39939015319.

The current namespace capability is limited to the restore verbs
`receive,rollback,create,canmount,mountpoint,mount`; it does not add snapshot,
destroy,hold or delegation-management rights. A global grant transaction lock
serializes all labels sharing the namespace. Active and pending owners keep the
tuple; the last owner removes it before resuming its writers; failed or
ambiguous revocation remains durable and fail-closed. The namespace and
recovered contents are never destroyed by grant withdrawal. No live host or
dataset was touched in this reviewer batch.

No new REV was opened and REV-170 remains CLOSED. This batch reconciles the
stale #553 backlog warning with the already-published finding, two rejected
implementations, approval and closure; it does not rewrite that history.

**Next reviewer scope:** reconcile the X27 backward-compatibility warning for
pre-X27 fleet configs against the actual migration/reader code, published
reviews and a production-shaped old-config render negative control.

## Previous final-audit batch — 2026-10-24 (local restore / PRs #539 and #541)

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
