# Transfer progress inspired by syncoid — Reviewer/Claude design discussion

Date: 2026-08-08
Status: **TODO / DESIGN BACKLOG — DO NOT DISTURB CURRENT STAGE 5 PATH; NO IMPLEMENTATION UNTIL EXPLICITLY REACTIVATED AND, IF FROZEN FILES ARE NEEDED, EXPLICIT REVIEW AUTHORISATION**

Owner question:

> Syncoid shows transfer progress and ETA. Evaluate whether `snapget.sh` / `snapsend.sh` can gain an equivalent mechanism cheaply, and decide **when** to implement it so we do not destabilise the frozen engine.

Owner follow-up, 2026-08-08:

> Treat this as a TODO idea that must not disturb the current work path. The interesting value is broader than an interactive progress bar: cron telemetry, status, reports/mail and future tuning may all consume the same measurements.

Current main when this discussion was opened: `1592aa45e443229eb5b9fd53058c2704d9d09c49`.

---

## 0. Scheduling boundary — this is NOT current-path work

This discussion records a potentially valuable future feature. It is **not** a Stage 5 blocker, not a reason to unfreeze the engine now, and not permission to expand the current delivery scope.

Current work continues unchanged.

Only revisit implementation at a natural checkpoint where the cost can be compared against the already-planned test campaign. If the smallest safe implementation is not clearly cheap at that point, leave it in TODO.

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

## 3. The useful abstraction is telemetry, not a progress bar

Do not optimise only for an interactive terminal. The smallest future contract should, if practical, expose measurements that several consumers can reuse without turning the engine into a monitoring platform.

Candidate primitives:

```text
planned_bytes          # when an estimate was requested/available
actual_logical_bytes   # bytes of the logical ZFS stream actually observed
wire_bytes             # optional/later; distinct from logical bytes
started_at / duration_seconds
average_rate
mode=full|incremental|resume
result=ok|failed|skipped
```

The exact schema/storage is deliberately NOT decided here.

The important separation is:

```text
transfer
   |
   +--> interactive CLI: percent / rate / ETA
   +--> cron: quiet execution + one final measurement record
   +--> future `zfsbackup status`: current job state/progress
   +--> future reports/mail: aggregate successes, resumes, anomalies
   +--> future tuning: real duration/throughput/change-volume history
```

### Interactive execution

A human-run command may show live progress on stderr:

```text
38.7 GiB estimated
21.4 / 38.7 GiB   55%   43.8 MiB/s   ETA 00:06:44
```

Machine-readable stdout contracts must remain untouched.

### Cron execution

Do **not** emit a moving progress bar into cron logs. For non-interactive jobs the useful output is a compact final fact, for example conceptually:

```text
RESULT=OK mode=incremental logical_bytes=41553824768 duration=824 avg_rate=...
```

Do not assume cron needs a pre-transfer `zfs send -nP` merely to collect history. If actual bytes and duration can be measured cheaply during the real transfer, history/tuning may not need a planned total at all. Estimate is necessary for `%`/ETA, not necessarily for post-run telemetry.

### Reports / mail

Avoid success mail on every hourly job. More useful future consumers are:

- immediate failure/warning mail;
- anomaly notification (e.g. throughput collapse or unusually large incremental);
- daily/periodic aggregate: success ratio, transferred volume, average/p95 duration, resumes, notable deviations.

No mail implementation is part of this TODO.

### Future tuning value

Historical measurements could later support decisions with evidence rather than guesses:

- stable schedule staggering based on real job durations;
- identifying a relation whose runtime approaches/exceeds cadence;
- detecting throughput degradation while backups still technically succeed;
- spotting unexpectedly large change volume;
- comparing logical-stream bytes with wire bytes to assess compression value;
- feeding future autotune/resource decisions;
- trend input for capacity warnings, with explicit acknowledgement that send-stream volume is not equal to snapshot space usage.

Do **not** build predictive scheduling, a database, a daemon, or analytics now merely because these future consumers exist.

---

## 4. Reviewer preliminary ranking of implementation strategies

### A. Estimate/progress outside the engine — attractive but probably wrong if it duplicates planning

A high-level wrapper could in theory ask ZFS for a size before invoking the engine. But if `zfsbackup` has to reconstruct whether the engine will choose full / `-I` / `-i` / bookmark / recursive / resume, it becomes a second planner and can drift from the real transfer decision.

**Preliminary verdict: reject unless the engine exposes the exact already-resolved send plan without duplicating semantics.** Cheap code that gives the wrong denominator is not cheap.

### B. Minimal optional instrumentation inside the existing transfer path — preferred candidate

The lowest-risk shape appears to be:

1. Keep all existing transfer decisions untouched.
2. After the real send command has been resolved, derive/execute a dry-run estimate for that exact stream only when a consumer needs a total/ETA.
3. In interactive progress mode, insert a byte counter whose total is the ZFS estimate.
4. If progress support is unavailable or estimation fails, **fall back to today's exact transfer path**. Telemetry must never turn a valid backup into a failed backup.
5. For cron, prefer cheap measurement of the real transfer and one final record; no moving progress output.

A particularly low-cost interactive v1 would make progress conditional on an interactive terminal and availability of `pv`:

```text
interactive + pv + valid estimate -> progress
otherwise                         -> current pipeline unchanged
```

This avoids making `pv` a hard dependency for production cron and avoids a new daemon/state service.

### C. Mandatory progress/state infrastructure now — too expensive for this TODO

Persisted progress for `zfsbackup status`, WebGUI polling, cross-process ETA and historical throughput may be useful later, but it introduces state ownership, lifecycle/cleanup, crash semantics and concurrency questions.

**Verdict for current path: defer.** First prove, if/when reactivated, the smallest telemetry/progress seam. Persistence and consumers can be layered later only when justified.

---

## 5. Where the byte counter must sit

The denominator from ZFS is the logical ZFS send stream. If external compression is enabled, the counter must observe the corresponding uncompressed logical stream, not compressed WAN bytes.

Candidate placements:

### `snapsend.sh`

```text
zfs send -> progress/logical-byte counter -> optional compressor -> ssh/mbuffer -> decompressor -> zfs recv
```

The source is local, so this can be done without requiring a progress tool on the remote target.

### `snapget.sh`

To avoid a new dependency on the remote source:

```text
remote zfs send -> optional remote compressor -> ssh -> mbuffer -> local decompressor -> progress/logical-byte counter -> zfs recv
```

That measures logical stream progress after decompression. It may lag slightly behind bytes already buffered on the wire, but its denominator remains semantically correct.

If Claude sees a cheaper placement that preserves the same denominator, argue it with the current pipeline when this TODO is reactivated.

Network-byte telemetry, if ever wanted, is a **different metric** and should not be confused with ZFS-stream completion.

---

## 6. Resume

Two acceptable first-version choices exist:

1. Support resume immediately if the fleet's OpenZFS can reliably estimate `zfs send -t <token>` with the dry-run interface.
2. If that needs disproportionate special casing, explicitly show progress only for normal full/incremental sends in v1 and log that resumed transfer size/ETA is unavailable.

What is not acceptable is silently reusing the original full-stream denominator after a resume and presenting a false percentage.

Claude: when this TODO is reactivated, verify current OpenZFS behaviour on the actual hosts rather than assuming it.

---

## 7. Timing — TODO checkpoint only

**Do not implement this now while Stage 5 contracts/profile runtime are moving.** The engines are frozen for a reason and the Owner explicitly says this idea must not disturb the current work path.

Potential cheapest future integration window, only if strategy B is proven genuinely small and non-semantic:

```text
Stage 5 runtime functionally complete
        ↓
additional owner-selected profiles prepared
        ↓
RE-EVALUATE THIS TODO
        ↓
if cheap: explicit small engine-unfreeze review for progress/telemetry
        ↓
focused regression/live proof
        ↓
ONE final Stage-5 live campaign covers profiles + final production path
        ↓
Stage 6 restore
```

If it is not clearly cheap at that checkpoint: **leave it TODO and continue to Stage 6**. No current milestone is blocked by this feature.

---

## 8. Minimum proof if ever implemented

Do not rerun 619 assertions mechanically just because a frozen file changed. Use the dependency graph, but the progress/telemetry feature itself must prove at least:

- instrumentation does not alter transfer planning;
- estimator, when used, and actual send derive from the same resolved transfer decision;
- full send progress/measurement;
- ordinary incremental progress/measurement;
- `-i`/`-I` distinction preserved;
- recursive stream denominator is sane;
- external compression counter is placed on logical-stream side, not compressed-wire side;
- no `pv` / no TTY / estimator failure -> transfer still follows today's path and succeeds;
- progress output cannot corrupt machine-readable stdout contracts;
- cron/noninteractive execution has no uncontrolled progress spam and can still produce a compact final measurement if that feature is enabled;
- resume behaviour is either correctly supported and tested or explicitly unavailable without lying;
- one real ZFS local proof and one real remote push/pull proof on the appropriate identities;
- a negative/mutation control that proves the test would catch a denominator/pipeline-placement defect;
- `impact --verify` and dependency-selected cascade clean.

If the change touches shared helpers or alters command construction rather than adding an observational branch, widen the proof accordingly.

---

## 9. Questions for Claude — answer only when useful; do not interrupt current work

A Claude response is welcome when there is a natural pause, but this discussion must not preempt current Stage 5 work.

Preferred response path if/when taken up:

`docs/discussions/TRANSFER-PROGRESS-CLAUDE-RESPONSE-2026-08-08.md`

Questions:

1. Can the dry-run estimator be built from the **already-resolved** send operation without creating a second planner or unsafe string surgery?
2. What is the smallest diff: duplicated tiny helper in the twin engines, shared helper in `lib-zfs-snap.sh`, or another existing seam?
3. Is optional interactive `pv` the cheapest robust v1, or does existing `mbuffer` provide enough total-aware progress to avoid another tool? Verify, do not assume.
4. Can cron cheaply collect actual logical bytes + duration without paying for a dry-run estimate when no `%`/ETA consumer exists?
5. For compressed `snapget`, is local post-decompression counting the cleanest way to avoid a remote `pv` dependency?
6. Does the installed OpenZFS support useful dry-run size estimation for resume tokens on all relevant hosts?
7. What minimal stable telemetry primitives are worth exposing now so future status/mail/tuning can reuse them without requiring a database or daemon?
8. Which existing suites/graph edges must fire for this exact diff, and what smallest live proof closes the environment-sensitive part?
9. At the late-Stage-5 checkpoint, would implementing this still be cheaper than deferring it beyond Stage 6? Re-evaluate from the then-current diff/risk, not today's enthusiasm.

Goal: preserve the idea and its potential value while keeping today's delivery path untouched. No production change from this discussion alone.
