# LIVE PROOF CONSOLIDATION — REV-082 + REV-083

Status: REVIEWER COORDINATION NOTE
Date: 2026-08-09

## Why this exists

REV-082 and REV-083 are both locally/code-complete except for bounded live-host evidence on the real high-level CONFIG/crontab mutation path.

Do **not** manufacture two separate live campaigns. One controlled relationship can satisfy both reviews with less mutation and less risk.

## Current verified state

### REV-082

The two previously missing local proofs are now present in the tree:

- the discriminating `recursive = flat` profile is composed into a complete candidate, accepted by the real `gen-cron.sh`, and reaches the rendered transfer line as `-R`;
- `test/impact/run.sh` now resolves `impact.sh -f lib-profile.sh` through the real interface and asserts both `profiles` and `zfsbackup` suites.

The implementer response header still names the older implementation `a1bfa19f...`; Claude should update his own response to the commit that actually contains these proof repairs (`3562bfb0fa0b02c67efc53b2527495acf8843a1a` or a later commit containing it) and record that only the live obligation remains.

### REV-083

Implementation `57deecb23d8962e5ad47fc9312141e248776f3f5` is accepted at code/local-test level. REV-084, the fail-open damaged-record follow-up, is CLOSED.

Claude's read-only host survey found no currently active controlled relationship on the reachable hosts. That explains why the required live proof could not be run safely unattended; it does **not** waive the proof.

## One bounded campaign should close both live obligations

When an explicit manual/live window is available, use one throwaway relationship on a known test target and perform this sequence:

1. Create/enrol one controlled relationship through the real high-level path.
2. Seed/activate it only in the explicitly approved test namespace/target.
3. Capture the canonical CONFIG and the installed managed crontab block.
4. Verify the successful path used the profile-generated CONFIG through real preview/apply/read-back (REV-082 positive path).
5. Attempt a second high-level addition whose requested coverage overlaps the installed relationship (REV-083 negative path).
6. Require a fail-closed refusal before mutation.
7. Read back the canonical CONFIG and managed crontab and prove both are byte/semantic unchanged from step 3.
8. Tear down the throwaway relationship with the normal high-level lifecycle command and verify cleanup.

This single campaign supplies:

- REV-082: real create/preview/apply + CONFIG read-back + managed-cron read-back + controlled refusal leaving state unchanged;
- REV-083: real overlap refusal against an installed relationship + CONFIG/crontab unchanged.

No second seed, no fleet-wide campaign, no profile catalog work, and no unrelated SSH/grant/ZFS experiments should be added merely to increase evidence volume.

## Safety boundary

Do not create a real seed/receive merely to satisfy this note without an explicit live-test window. The remaining obligation is environmental/manual, not evidence that more production code is currently required.
