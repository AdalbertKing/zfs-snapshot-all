# REVIEWER CHECKPOINT

Purpose: compact bootstrap for ChatGPT reviewer. This file is a convenience index, **not** the canonical source of volatile review state. If anything here disagrees with `main`, `docs/project/OPEN-THREADS.md`, `docs/internal/reviews/REVIEW_LEDGER.md`, exact review/response/closure artifacts, or `docs/project/ACTIVE-WORK-PLAN.md`, the fresher canonical artifact wins.

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
