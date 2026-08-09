# ACTIVE WORK PLAN

Status: **ACTIVE — OWNER APPROVED**
Date: 2026-08-09
Owner direction: combine importance with implementation cost; do the highest-value low/medium-cost work first, keep the architecture reduction-oriented, and do not grow a profile-management framework.

This file is the canonical **work sequence** from now on. It supersedes the sequencing in `PLAN-2026-08-07.md` where the two disagree. The older plan remains historical evidence for how the project reached the current state.

This file does **not** duplicate review state. Current REV ownership/status remains canonical in `docs/internal/reviews/REVIEW_LEDGER.md` and `docs/project/OPEN-THREADS.md`.

## Operating rules

1. **Gate before expansion.** Do not start a later functional phase while an earlier safety gate is open, except independent documentation/test-hygiene work.
2. **Reduction over completeness.** Prefer refusal + native CONFIG v4 over inheritance, precedence, carve-outs, drift managers or other framework machinery.
3. **Preset is CREATE-only.** A preset creates a new starting task/package. It never updates, merges, reconciles, deletes or silently re-applies existing policy.
4. **CONFIG v4 is execution truth after install.** Endpoint/topology operations must preserve installed policy rather than reconstruct it from a profile.
5. **Live evidence follows risk.** Do not add hosts, SSH/grant work, ZFS campaigns or payload volume merely to increase evidence count when the required property is already provable at a narrower boundary.

---

## Phase 1 — close the current live gate (ACTIVE NOW)

Goal: close the only remaining evidence boundary for REV-082/REV-083 before adding more Stage 5 behavior.

Use the already-authorized bounded metropolis pve1/pve2 throwaway window and the smallest suitable scratch dataset.

Executed campaign on this specific pair (2026-08-09, see REV-20260809-086 response for the full transcript):

1. Real `add-client -> seed -> activate-client` for one throwaway relationship (`v3proofA`).
2. Confirmed `STATE=active`; captured canonical CONFIG and the managed `crontab -l` block verbatim.
3. A second, differently-named relationship (`v3proofB`) — a hand-written client record reusing `v3proofA`'s already-established peer manifest, never going through its own `add-client` — attempted `seed` and was refused by `assert_no_coverage_overlap()` naming `v3proofA`, before any transfer. Proved canonical CONFIG, managed crontab, and the entire destination subtree unchanged afterward.
4. Removed the throwaway relationship through the normal lifecycle; verified state and cron cleanup.
5. Command transcript and before/after evidence are in the REV-082/083/085/086 responses.

### REV-083 overlap-specific acceptance boundary on this pair — CORRECTED (REV-086)

The premise this section previously stated — "distinct relationship names produce distinct `LABEL` namespaces, so cross-client overlap is structurally unreachable" — was **false** and is corrected here per REV-20260809-086. `load_client_and_connection()` derives `LOAD_LABEL` from `peer_label(PEER_HOST)`, not from the relationship's own name: two differently-named relationships sharing a peer share the same `target/label` namespace, and (before REV-085's fix) `cmd_seed()` could perform a real receive into that shared coverage before any guard ran.

A genuine cross-client overlap **is** reachable on this pair, and was reached live: see the campaign above and the REV-086 response for the exact-path overlap that `v3proofB` hit via `cmd_seed()`, refused before transfer.

Sync mode remains correctly refused when the peer is a member of the same PVE cluster; that part of the original note was accurate and is unaffected by this correction.

### Gate 1

REV-082, REV-083, REV-085 and REV-086 are implementer-complete with live evidence submitted; reviewer approval/closure pending. No new Stage 5 feature starts before this gate.

---

## Phase 2 — finish the CREATE-only additive model

Goal: a preset may safely create **one new, independent, non-overlapping task package** inside an existing CONFIG without touching old policy.

Required properties:

- existing unrelated CONFIG/task remains byte/semantic unchanged;
- new disjoint source/task can be appended transactionally;
- existing source refuses;
- parent/child overlap refuses;
- identical semantic template may be reused;
- template identity with different semantic content refuses;
- whole candidate CONFIG is validated and previewed before install;
- resulting managed cron is previewed and installed atomically with rollback/read-back.

No merge engine, no precedence/carve-out machinery, no profile update semantics.

### Gate 2

Preset can **add new** but cannot mutate old.

---

## Phase 3 — decouple endpoint/reactivation from policy regeneration

Goal: ordinary relation/topology maintenance must not cause profile policy to be regenerated.

Required property:

```text
endpoint / host / transport change
        -> preserve existing CONFIG policy
        -> change only relationship/topology facts that actually changed
```

A manually customized generated CONFIG must survive reactivation and endpoint switch unchanged in policy semantics.

### Gate 3

One-way handoff is true in production behavior:

```text
PROFILE/PRESET -> generate once -> CONFIG v4 -> runtime truth
```

---

## Phase 4 — expose presets as a small user feature

Goal: turn the existing profile boundary/renderer into a useful operator-facing CREATE choice without creating a profile manager.

Implement the smallest public surface:

- `--profile=NAME` only where a new task/package is being created;
- default preset remains the zero-choice normal path;
- show candidate CONFIG and resulting cron before install;
- no persistent profile authority after install;
- optional provenance only if it enables a concrete operator action; otherwise do not store it.

### Gate 4

A normal administrator can select/accept a sensible preset and obtain a valid native CONFIG without learning internal profile machinery.

---

## Phase 5 — high-level local deployment UX

Goal: converge toward the simple local workflow:

```bash
./zfs-backup.sh --source=rpool/data --target=hdd/backups
```

The high-level path should discover/propose scope, choose/default a preset, show CONFIG + cron, seed, and activate with transactional state handling. Avoid exposing internal command-tree complexity when one logical workflow can own it.

Keep the already-agreed rules:

- source selection is WHAT, recursion is HOW/preset;
- nested target inside source refuses;
- same-pool target may be allowed with one factual preview note, not policy judgement;
- decline/failed seed leaves retryable state and no production cron.

### Gate 5

Basic local backup deployment is one coherent operator workflow.

---

## Phase 6 — minimal preset set + expert documentation

Documentation work may proceed in parallel when it does not cross an earlier gate.

### Presets

Do not build a Cartesian catalog. Keep `default`; add another shipped preset only when production evidence shows a common HOW policy with enough value to justify it.

### Native CONFIG examples

Document concise expert examples for:

- independent hourly/daily retention without forcing GFS;
- quiesce only on selected create tiers;
- intentionally shorter local retention than remote/replicated history (Kancelaria pattern);
- manual prune schedules/patterns;
- safe CONFIG validation and preview;
- deliberate manual customization after preset generation.

Documentation is the intended escape hatch for bespoke policy; the CLI must not absorb every expert exception.

---

## Phase 7 — Restore

Start after the create/install path is stable.

Order:

1. `restore --plan` — read-only planning first.
2. Restore into a safe/new namespace with GUID verification and collision checks.
3. Refuse unsafe active-guest collisions by default.
4. Real ZFS end-to-end evidence.
5. Destructive replacement as a **separate verb**, with explicit confirmation and mandatory pre-restore snapshot.

### Gate 7

The product can both create a backup and restore it through a deliberately safe workflow.

---

## Deferred until a concrete need exists

These do not block the core product:

- `remove-source CLIENT DATASET`;
- multiple different presets per source inside one relationship, unless it stays cheap and overlap-free;
- optional `generated-from=<profile,digest>` provenance;
- broader preset catalog.

## Explicit non-goals unless the Owner reopens them

Do not build:

- profile inheritance;
- profile composition DSL;
- arbitrary override chains;
- per-profile exception/carve-out precedence;
- profile drift/version/adoption manager;
- automatic profile re-apply to installed policy;
- custom-profile lifecycle manager merely to represent bespoke native CONFIG;
- high-level modeling of site-specific interactions such as storage scarcity compensated by replication.

## Active sequence in one line

```text
V3 live gate
 -> CREATE-only additive
 -> endpoint/reactivation preserves policy
 -> --profile at CREATE + preview
 -> simple --source/--target workflow
 -> minimal presets + expert docs
 -> RESTORE
 -> only then optional conveniences backed by real need
```
