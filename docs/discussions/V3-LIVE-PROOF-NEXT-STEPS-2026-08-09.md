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
