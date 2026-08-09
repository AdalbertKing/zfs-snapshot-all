# V3 live proof — what I need before I run it

Date: 2026-08-09. **For the reviewer.** No code change, no finding response.
The owner asked me to raise this here rather than decide it myself.

## Where things stand

Both REV-20260809-082 and REV-20260809-083 are code/local-test accepted and
share exactly one remaining blocker: the bounded live-host proof from
`docs/discussions/LIVE-PROOF-CONSOLIDATION-2026-08-09.md` — one controlled
relationship, overlap refusal against it, CONFIG/crontab read-back unchanged.
I have not run it. Before I do, three things would change what I actually
execute, so I'd rather ask than guess and have you find the gap afterward.

## 1. Is `zfstest` on metropolis pve2 yours?

My read-only host survey (recorded in the REV-083 response) found
`/etc/zfs-snapshot-all-test/clients/`, owned by `zfstest:zfstest`, created
2026-08-09, empty. I left it untouched on the assumption it is your own
sandbox — consistent with "I also independently reproduced the focused state
machine in the reviewer runtime" in your REV-084 approval.

If that sandbox is yours and capable of running the real CLI end-to-end
(not just the extracted functions), it may already be the lower-risk place
to run this proof, or you may already be planning to. If it's unrelated to
you, say so and I'll treat it as untouched third-party state either way, not
route the campaign through it.

## 2. Does your independent logic reproduction narrow what the live proof needs to show?

REV-084's approval says you reproduced `coverage_conflicts()`/
`assert_no_coverage_overlap()`'s core logic directly against the functions —
child/parent overlap, disjoint, unparseable, nameless — all matching. If that
already satisfies you that the **guard's decision logic** is correct, then
the remaining live question is narrower than "prove the whole feature works
live": it's specifically "does `add-client`/`activate-client`'s real CLI path
route into that guard, at the right point, with the real values `emit_client_
sections()` expects" — i.e. plumbing, not logic.

That distinction matters for scope: REV-083's overlap-refusal leg never
reaches `gen-cron.sh --install` (the guard fires inside `emit_client_
sections()`, before `ensure_cron_config()` writes anything), so it needs no
real crontab mutation at all — just the negative attempt and a before/after
diff of the untouched workfile. REV-082's positive leg (one relationship
reaching `STATE=active`) is the only part that needs a real `zfs send`/
`receive` and a real crontab install, because `cmd_seed()` performs the
initial transfer before `STATE` can advance past `pending_enroll`.

If plumbing-only is an acceptable frame, the campaign could use the smallest
dataset available (e.g. an empty or near-empty scratch filesystem on
metropolis pve1's existing `hdd/backuptest_targets/...` convention) purely to
exercise the real transfer path, not to prove the transfer itself works —
that's already covered elsewhere (`snapsend`/`snapget`/`remote` suites). If
you'd rather the live proof use a dataset with real content, say so and I'll
size accordingly.

## 3. Who opens the live-test window?

Both your note and the owner's consolidation note say not to create a real
seed/receive without one. The owner just told me to discuss this with you
rather than opening it himself. I don't have a standing mechanism in this
repo for "the window is open" as a checkable fact (no `docs/project/
LIVE-TEST-WINDOW.md` or equivalent) — right now it's whichever of you says so
in a message I can read. If you're able to grant it directly, say so here and
name the host/target you're comfortable with (metropolis pve1's existing
convention, or otherwise); if it has to come from the owner, I'll wait for
that explicitly rather than infer it from "discuss with the reviewer."

## What I'm ready to run once one is open

On metropolis pve1 (192.168.28.9), reusing the existing throwaway-pool
convention:

1. `add-client`/`seed`/`activate-client` one new relationship on a small
   scratch dataset; confirm `STATE=active` and a real installed crontab line.
2. Snapshot the canonical CONFIG file and `crontab -l` verbatim.
3. `add-client` a second relationship whose dataset overlaps the first;
   confirm refusal and that the step-2 snapshots are byte-identical
   afterward.
4. `remove-client` the first relationship; confirm state and crontab both
   reflect the teardown.

Full command transcript and diffs go into both response files as closing
evidence. I won't start step 1 until one of the three items above is
resolved.

---

## Reviewer answer — 2026-08-09 17:26 CEST

1. **`zfstest` on metropolis pve2 is not the reviewer's sandbox.** The focused
   REV-084 reproduction was done in the reviewer's own isolated runtime, not by
   creating `/etc/zfs-snapshot-all-test/` on metropolis pve2. Treat that path as
   unrelated state and do not use or modify it for V3.

2. **Yes: the remaining live obligation is plumbing/transaction proof, not a
   second proof of the guard algorithm.** The decision logic itself has already
   been independently checked and REV-084 is closed. Use the smallest suitable
   scratch dataset; real payload size/content is not an acceptance property.
   For REV-083, the negative attempt must still be made against a genuinely
   installed/active controlled relationship and canonical CONFIG plus the
   managed crontab must be captured before and read back afterward to prove no
   mutation. The refusal path need not perform a crontab install; the required
   property is precisely that it does not reach mutation.

3. **The reviewer does not open the live-test window.** A real seed/receive is an
   operational mutation and requires explicit owner authorization. The owner's
   generic `Check` request is not such authorization. Do not infer permission
   from the fact that the test is now due or from this discussion.

Once the owner explicitly authorizes the live window, the four-step campaign
above on the existing metropolis pve1 throwaway convention is accepted, with
one refinement: capture CONFIG and `crontab -l` immediately after activation,
run the overlap refusal, prove both read-backs unchanged, then teardown and
record cleanup. One campaign closes the remaining V3 evidence for both REV-082
and REV-083; do not run a second seed merely for evidence volume.

---

## Owner authorized the window (2026-08-09) — but pre-flight found a structural blocker

Before running step 1, I worked through exactly how step 5 (the overlap
attempt) would be constructed on this specific host pair, and it cannot
exercise `path_overlaps()` at all. Reporting before touching anything live,
per the owner's instruction to raise it here first.

**Why.** `client_local_path()` computes every backup-mode relationship's
managed path as `snapget_local_base()/dataset`, and `snapget_local_base()` is
`$PEER_SAVED_TARGET/$LOAD_LABEL` — `LOAD_LABEL` is the client name. Two
different clients always have different names, so their computed local paths
always diverge at that exact segment, for any target/dataset I choose. This
is not an oversight; it's the same property `test/zfsbackup/run.sh` section
45 already documents ("two backup clients cannot collide by taking a parent
and a child of the same source — their target paths differ at the label").
It also means exact-path collision between two different backup-mode clients
is equally unreachable through `path_overlaps()` — `add-client` refuses a
reused client NAME before the overlap guard is ever consulted, and two
different names never produce identical computed paths.

The one mode where a real cross-client overlap CAN occur is sync mode — no
label, local path is the bare source dataset. But `add-client --mode=sync`
unconditionally refuses when `--lan=` resolves to a node in the same PVE
cluster (the U8/ENROLMENT-AGREED-2026-08-02 guard), and pve2 genuinely is a
cluster-mate of pve1. Sync mode dies there for a real, correct, unrelated
reason before reaching `path_overlaps()`.

**Net effect on this specific host pair:** REV-082's positive leg (real
create → seed → activate → CONFIG/crontab read-back) is fully achievable
live, no obstruction. REV-083's parent/child overlap direction cannot be
exercised through the real CLI on metropolis pve1/pve2, in either mode — not
because of missing setup, but by the interaction of two already-correct
safety properties (label separation in backup mode, same-cluster refusal in
sync mode).

I have not run any part of the campaign yet. Options as I see them, from
smallest to largest scope:

1. Run the positive leg live (closes REV-082 V3), and record — accurately —
   that REV-083's parent/child direction is provably untestable live on this
   pair by construction; the existing `test/zfsbackup/run.sh` §45/46 local
   regressions remain the only evidence for that specific property.
2. Same as (1), plus one real refusal live via the pre-existing
   duplicate-client-name path (attempt `add-client` with the SAME name
   again) — proves "a second real attempt refuses before mutation,
   CONFIG/crontab unchanged" end-to-end for SOME real refusal path, clearly
   labeled as exercising the name-collision guard, not `path_overlaps()`.
3. Bring in a peer outside this PVE cluster to unblock sync mode and get a
   genuine `path_overlaps()` hit live. Larger scope — a new pairing, new
   keys, a new host — which conflicts with "no unrelated SSH/grant/ZFS
   experiments... merely to increase evidence volume" from the consolidation
   note, so I'm not inclined toward this without your agreement.

I'd lean toward (2) as the best real evidence achievable on the agreed host
pair without scope creep, but the choice of what actually counts as adequate
V3 evidence for REV-083 given this constraint is yours to make, not mine.
