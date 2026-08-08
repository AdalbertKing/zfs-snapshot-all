# Transfer progress inspired by syncoid — Reviewer/Claude design discussion

Date: 2026-08-08
Status: **ACTIVE DESIGN DISCUSSION — DO NOT IMPLEMENT UNTIL CONVERGENCE AND, IF FROZEN FILES ARE NEEDED, EXPLICIT REVIEW AUTHORISATION**

Owner question:

> Syncoid shows transfer progress and ETA. Evaluate whether `snapget.sh` / `snapsend.sh` can gain an equivalent mechanism cheaply, and decide **when** to implement it so we do not destabilise the frozen engine.

Current main when this discussion was opened: `1592aa45e443229eb5b9fd53058c2704d9d09c49`.

---

## 1. Relevant current-engine facts

1. `snapsend.sh` and `snapget.sh` are both frozen by `docs/project/ENGINE-FREEZE.md`; so is `lib-zfs-snap.sh`.
2. Both engines already finish constructing the exact `zfs send ...` operation before `transfer_data()` runs.
3. Current transport uses `mbuffer -q`; it intentionally suppresses transfer display and has no known total-size input in the current pipeline.
4. The engines have multiple send shapes that any estimator must match exactly: full, incremental `-I`, skip-intermediate `-i`, recursive, raw/compressed send, bookmark incremental and resume-token send.
5. External compression changes the number of bytes on the wire, so a ZFS-stream size estimate and network-byte count are different quantities.
6. `snapget.sh` often generates the ZFS stream on the remote source and decompresses locally before `zfs recv`; `snapsend.sh` generates the stream locally.
7. Resume is first-class in both engines (`zfs send -t <token>`), so a progress feature that lies or disappears on resume needs to be justified explicitly.

---

## 2. Mechanism worth evaluating

The syncoid pattern is conceptually simple:

```text
same planned zfs-send stream
        |
        +--> zfs send -n -v/-P ... -> estimated stream size
        |
        +--> real zfs send ... -> byte counter with TOTAL -> percent/rate/ETA
```

The attractive property is that **remaining bytes are not inferred from target state**. Total size is obtained before transfer from ZFS for the same stream, and runtime progress is just bytes already passed through a counter.

For our design, do not assume exact option spelling or output parsing from memory. Verify the actual OpenZFS versions on the fleet, including resume-token dry-run behaviour, before implementation.

---

## 3. Reviewer preliminary ranking of implementation strategies

### A. Estimate/progress outside the engine — attractive but probably wrong if it duplicates planning

A high-level wrapper could in theory ask ZFS for a size before invoking the engine. But if `zfsbackup` has to reconstruct whether the engine will choose full / `-I` / `-i` / bookmark / recursive / resume, it becomes a second planner and can drift from the real transfer decision.

**Preliminary verdict: reject unless the engine exposes the exact already-resolved send plan without duplicating semantics.** Cheap code that gives the wrong denominator is not cheap.

### B. Minimal optional instrumentation inside the existing transfer path — preferred candidate

The lowest-risk shape appears to be:

1. Keep all existing transfer decisions untouched.
2. After the real send command has been resolved, derive/execute a dry-run estimate for that exact stream.
3. Only in an interactive progress mode, insert a byte counter whose total is the ZFS estimate.
4. If progress support is unavailable or estimation fails, **fall back to today's exact transfer path**. Telemetry must never turn a valid backup into a failed backup.
5. Do not add progress output to normal cron by default.

A particularly low-cost v1 would make progress conditional on an interactive terminal and availability of `pv`:

```text
interactive + pv + valid estimate -> progress
otherwise                         -> current pipeline unchanged
```

`pv` normally suppresses its display when stderr is not a terminal, but the engine should not rely on undocumented accidental behaviour: decide and test the policy explicitly.

This avoids making `pv` a hard dependency for production cron and avoids a new daemon/state service.

### C. Mandatory progress/state infrastructure now — likely too expensive

Persisted progress for `zfsbackup status`, WebGUI polling, cross-process ETA and historical throughput is useful later, but it introduces state ownership, lifecycle/cleanup, crash semantics and concurrency questions.

**Preliminary verdict: defer.** First prove a thin CLI progress layer. Persisted status can consume a stable progress contract later if the product needs it.

---

## 4. Where the byte counter must sit

The denominator from ZFS is the logical ZFS send stream. If external compression is enabled, the counter must observe the corresponding uncompressed logical stream, not compressed WAN bytes.

Candidate placements:

### `snapsend.sh`

```text
zfs send -> progress counter -> optional compressor -> ssh/mbuffer -> decompressor -> zfs recv
```

The source is local, so this can be done without requiring a progress tool on the remote target.

### `snapget.sh`

To avoid a new dependency on the remote source:

```text
remote zfs send -> optional remote compressor -> ssh -> mbuffer -> local decompressor -> progress counter -> zfs recv
```

That measures logical stream progress after decompression. It may lag slightly behind bytes already buffered on the wire, but its denominator remains semantically correct.

If Claude sees a cheaper placement that preserves the same denominator, argue it with the current pipeline.

Network-byte telemetry, if ever wanted, is a **different metric** and should not be confused with ZFS-stream completion.

---

## 5. Resume

Two acceptable first-version choices exist:

1. Support resume immediately if the fleet's OpenZFS can reliably estimate `zfs send -t <token>` with the dry-run interface.
2. If that needs disproportionate special casing, explicitly show progress only for normal full/incremental sends in v1 and log that resumed transfer size/ETA is unavailable.

What is not acceptable is silently reusing the original full-stream denominator after a resume and presenting a false percentage.

Claude: please verify current OpenZFS behaviour on the actual hosts rather than assuming it.

---

## 6. Timing — preliminary recommendation

**Do not implement this now while Stage 5 contracts/profile runtime are still moving.** The engines are frozen for a reason.

If the technical discussion concludes that strategy B is genuinely small and non-semantic, the cheapest integration window is probably:

```text
Stage 5 runtime functionally complete
        ↓
additional owner-selected profiles prepared
        ↓
explicit small engine-unfreeze review for progress
        ↓
focused progress regression/live proof
        ↓
ONE final Stage-5 live campaign covers profiles + final production path
        ↓
Stage 6 restore
```

Reason: if we add progress **after** the expensive final Stage-5 live campaign, we immediately owe another production-path proof for a frozen-engine change. If we add it too early, profile work and engine work become entangled.

Fallback if the implementation is not clearly tiny by that checkpoint: **defer it rather than delaying Stage 5**. Restore does not require a progress bar to be correct.

---

## 7. Minimum proof if implemented

Do not rerun 619 assertions mechanically just because a frozen file changed. Use the dependency graph, but the progress feature itself must prove at least:

- estimator and actual send are derived from the same resolved transfer decision;
- full send progress;
- ordinary incremental progress;
- `-i`/`-I` distinction preserved;
- recursive stream denominator is sane;
- external compression counter is placed on logical-stream side, not compressed-wire side;
- no `pv` / no TTY / estimator failure -> transfer still follows today's path and succeeds;
- progress output cannot corrupt machine-readable stdout contracts;
- cron/noninteractive execution does not produce uncontrolled progress spam;
- resume behaviour is either correctly supported and tested or explicitly unavailable without lying;
- one real ZFS local proof and one real remote push/pull proof on the appropriate identities;
- a negative/mutation control that proves the test would catch a denominator/pipeline-placement defect;
- `impact --verify` and dependency-selected cascade clean.

If the change touches shared helpers or alters command construction rather than adding an observational branch, widen the proof accordingly.

---

## 8. Questions for Claude

Please respond with code-specific evidence, preferably in:

`docs/discussions/TRANSFER-PROGRESS-CLAUDE-RESPONSE-2026-08-08.md`

Answer these points:

1. Can the dry-run estimator be built from the **already-resolved** send operation without creating a second planner or unsafe string surgery?
2. What is the smallest diff: duplicated tiny helper in the twin engines, shared helper in `lib-zfs-snap.sh`, or another existing seam?
3. Is optional interactive `pv` the cheapest robust v1, or does existing `mbuffer` provide enough total-aware progress to avoid another tool? Verify, do not assume.
4. For compressed `snapget`, is local post-decompression counting the cleanest way to avoid a remote `pv` dependency?
5. Does the installed OpenZFS support useful dry-run size estimation for resume tokens on all relevant hosts?
6. Which existing suites/graph edges must fire for this exact diff, and what smallest live proof closes the environment-sensitive part?
7. Do you agree that, if implemented, the cheapest timing is **late Stage 5 immediately before the already-planned final live campaign**, not now and not after that campaign?
8. If you disagree, identify the concrete cost/risk that dominates and propose the cheaper checkpoint.

Goal: converge on **implement late-Stage-5 / defer / reject**, with an exact minimal mechanism and proof boundary. No production change from this discussion alone.
