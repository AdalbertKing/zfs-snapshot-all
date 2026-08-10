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

## Phase 1 — close the current live gate — CLOSED

Goal: close the current safety/evidence boundary before adding more Stage 5 behavior.

The bounded metropolis pve1/pve2 campaign was executed on 2026-08-09. See REV-20260809-086 response for the full transcript.

1. Real `add-client -> seed -> activate-client` for one throwaway relationship (`v3proofA`).
2. Confirmed `STATE=active`; captured canonical CONFIG and the managed `crontab -l` block verbatim.
3. A second, differently-named relationship (`v3proofB`) — a hand-written client record reusing `v3proofA`'s already-established peer manifest, never going through its own `add-client` — attempted `seed` and was refused by `assert_no_coverage_overlap()` naming `v3proofA`, before any transfer. Canonical CONFIG, managed crontab, and the entire destination subtree were unchanged afterward.
4. Removed the throwaway relationship through the normal lifecycle and verified cleanup.
5. The campaign exposed the independent `CRON_CONFIG` clobber defect, fixed in `67415a5795ad3d1cb659e3017c1485bc99b59a61` and formally closed as REV-087.

### Corrected overlap model

The earlier premise that distinct relationship names imply distinct backup `LABEL` namespaces was false. `LOAD_LABEL` is derived from `peer_label(PEER_HOST)`, so differently named relationships sharing a peer share the same `target/label` namespace. REV-085 added the canonical overlap guard before real seed transfer; the live campaign then exercised that exact boundary.

Sync mode remains correctly refused when the peer is a member of the same PVE cluster.

### Gate 1 — CLOSED

REV-082, REV-083, REV-084, REV-085, REV-086 and REV-087 are all **CLOSED**. There are no open review threads. Phase 2 may proceed.

---

## Phase 2 — finish the CREATE-only additive model — CLOSED

Goal: a preset may safely create **one new, independent, non-overlapping task package** inside an existing CONFIG without touching old policy.

Audited 2026-08-09 against the existing `add-client`/`activate-client` create-only path (built through REV-082–087) before writing anything new, per operating rule 2 (reduction over completeness — do not rebuild what already satisfies the property):

- existing unrelated CONFIG/task remains byte/semantic unchanged — **already implemented**: `ensure_cron_config()` only appends missing content, `emit_client_sections()` touches only the calling client's own sections; `test/zfsbackup/run.sh` pins this with md5-checked re-runs;
- new disjoint source/task can be appended transactionally — **already implemented**: `activate-client`'s workfile/validate/dry-run/preview/`atomic_replace_and_install` sequence;
- existing source refuses; parent/child overlap refuses — **already implemented**: `coverage_conflicts()`/`assert_no_coverage_overlap()`/`path_overlaps()` (REV-083/084/085), now proven live (REV-086) at both `cmd_seed()` and `emit_client_sections()`;
- identical semantic template may be reused — **already implemented**: `ensure_cron_config()`'s per-name append loop is a no-op when the namespaced name is already present and a re-render of the same unmodified profile is always byte-identical;
- **template identity with different semantic content refuses — was a genuine gap; fixed, then corrected again per REV-20260809-088.** The append loop's presence check was name-only, so a template already on disk under a namespaced name kept serving stale content forever if the active profile's own template content later changed, with no diff, warning, or refusal. First fix (real GitHub SHA `5f2201c55c46b1867349d909b830facb5a93a23a` — an earlier reference to a since-superseded local/rebased SHA was corrected here) put the comparison inside `ensure_cron_config()` unconditionally, which turned a CREATE-time collision rule into a standing profile-drift gate hit on every re-activation, and compared raw text instead of semantics — both caught by REV-088 (F1, F2). Corrected in `20f333d9d96de3b2e814d6cd87a86cfe515d3568`: the check now runs only when `cmd_activate_client()` explicitly says a relationship is being activated for the first time, and compares semantics (normalized, sorted) rather than raw text. `test/zfsbackup/run.sh` section 4: 322/322, negative control against `5f2201c...` shows 3 of 4 new assertions fail for the predicted reasons;
- whole candidate CONFIG validated and previewed before install; resulting managed cron previewed and installed atomically with rollback/read-back — **already implemented**: `gen-cron.sh -c`, `show_activation_proposal`, `atomic_replace_and_install`, `assert_cron_config_matches_installed`.

No merge engine, no precedence/carve-out machinery, no profile update semantics were added.

Registered as an unreviewed direct-main delivery in `docs/project/DELIVERIES.md` pending a REV.

### Gate 2

Preset can **add new** but cannot mutate old. All required properties have implementer evidence above; gate closure is the reviewer's call.

**REOPENED and re-answered — REV-20260810-092 (P1).** Found by the reviewer while
verifying REV-091, and it is a genuine Gate 2 residual rather than a Phase 3 one:
`ensure_cron_config()` appended any missing reserved-prefix `[excluded:]` section
whenever `needs_profile=1`, including an additive CREATE into an
already-populated CONFIG. `[excluded:]` is **not relationship-local** —
`gen-cron.sh` resolves every one of them into a single `PROTECT_FLAGS` fragment
and pastes it onto *every* generated prune line in the file — so adding one
rewrites the effective prune command of relationships that were installed first.
That is the invariant this gate exists for: *add one new independent relationship
-> old relationships unchanged.*

My REV-091 positive guard could not have caught it: it ran against a fixture
holding only `[defaults]`, where "installs the floors" and "mutates shared
policy" are indistinguishable because there was no established task to disturb.

Implemented to the review's four bullets exactly:

- a genuinely new CONFIG (no `[dataset:]`/`[prune:]` section at all) still gets
  the CONFIG-wide safety defaults;
- explicit migration may still lay them down — `migrate-profile` passes the new
  `global_policy_mode=always`, being a previewed, confirmed transaction and the
  one command that *installs* the broad GFS ladder these floors fence;
- an additive CREATE into a populated CONFIG inherits the installed `[excluded:]`
  state exactly and repairs nothing;
- the "refuse rather than mutate" escape hatch is unreachable here and
  deliberately not built: `[excluded:]` is uniform global policy, so a new
  relationship under a missing floor is in exactly the state every existing
  relationship is already in. The review's own proof step 6 requires B to be
  created successfully in that state.

One addition beyond the required minimum, flagged in the response for rejection:
the declined-repair path *warns*, naming the absent floors. Inheriting installed
policy is correct; doing it silently is not.

Evidence: section 52, six assertions asserting on the **rendered `delsnaps.sh`
command** rather than on config text (`PROTECT_FLAGS` is a generator-side
concatenation, so section-level equality would not test what the gate promises)
— **352/352**. Response:
`docs/internal/reviews/responses/REV-20260810-092.md`.

**Gate 2 CLOSED by the reviewer, 2026-08-10** (`57e7914e…` approval,
`5cb6a84` closure): *"Gate 2 acceptance property is now proved: preset/additive
CREATE may add B but may not mutate A. Phase 2 may close."* The extra warning on
the declined-repair path — offered for rejection — was explicitly accepted, on
the grounds that it changes no policy and makes inherited global policy visible.

---

## Phase 3 — decouple endpoint/reactivation from policy regeneration — CLOSED

Goal: ordinary relation/topology maintenance must not cause profile policy to be regenerated.

Required property:

```text
endpoint / host / transport change
        -> preserve existing CONFIG policy
        -> change only relationship/topology facts that actually changed
```

A manually customized generated CONFIG must survive reactivation and endpoint switch unchanged in policy semantics.

### Status — implemented, awaiting reviewer

The defect blocking this property was found by auditing the reactivation path
against the property itself, written up in
`docs/discussions/PHASE3-EMIT-CLIENT-SECTIONS-CLAUDE-FINDING-2026-08-09.md`, and
confirmed independently as **REV-20260809-089** (P1). `emit_client_sections()`
removed and regenerated every relationship-owned section from the *current*
active profile on every call — correct exactly once, at CREATE, and a silent
policy clobber on every later reactivation.

Implemented per the review's required correction:

- **first activation** — unchanged, full generation from the selected profile;
- **reactivation** — the installed section is the base; only the two
  topology-owned fields (`src`, transport `flags`) are refreshed in place, with
  the field set justified from the runtime contracts rather than guessed;
- `pair_label`/`notify` are deliberately **not** rewritten — both are pure
  functions of the relationship name and the dataset path, neither of which can
  change for a dataset that is already in scope;
- `[prune:]` sections carry no topology-owned field at all, so an owned one is
  left entirely untouched, in both the backup-mode GFS ladder shape and the
  sync-mode per-dataset shape;
- ownership-marker checks and fail-closed refusal preserved unchanged; a
  section this client does not own is still refused, never adopted by header
  alone;
- `migrate-profile` passes the first-activation flag explicitly, because
  re-deriving policy from the profile is that command's entire purpose.

Evidence: `test/zfsbackup/run.sh` section 49, **333/333**; negative control
against the reviewed base `8d0dc243…` → **328/333**, the five failures being
exactly the new discriminating assertions. Response:
`docs/internal/reviews/responses/REV-20260809-089.md`.

**That was necessary but not sufficient — REV-20260810-090 (two further P1s).**
REV-089 stopped the relationship-local section *body* from being regenerated,
but `cmd_activate_client()` still reached `ensure_cron_config()`, which still
called `load_active_profile` unconditionally (F1) and still appended any profile
template the installed CONFIG did not carry (F2). So the handoff still had an
availability dependency and an additive mutation path. My REV-089 evidence could
not have caught either: section 49 drove `emit_client_sections()` directly and
kept the profile present and valid throughout — the residual dependency sat in
the caller I never crossed.

Fixed by making the profile a **lazy** dependency gated at the additive boundary
the review named, not by removing it:

- `detect_profile_gfs()` extracted — the pre-GFS check always read the installed
  file, never a profile, so it can be answered first;
- `client_section_plan()` extracted — the preserve/regenerate split, now the
  single implementation shared by `cmd_activate_client()` and
  `emit_client_sections()`, reporting `PLAN_NEEDS_PROFILE`;
- `ensure_cron_config()` takes `needs_profile` (default 1); `load_active_profile`
  and the template-append loop both move inside it;
- a reactivation that generates nothing never touches the profile; one that must
  generate a section still loads it and still fails loudly there.

Evidence: section 50, six assertions, all crossing the real
`cmd_activate_client()` boundary — **339/339**; negative control against
`c5f04ab0…` → **335/339**, the four failures being exactly the new assertions.
Response: `docs/internal/reviews/responses/REV-20260810-090.md`.

**And a third round — REV-20260810-091 (two more P1s), same function again.**
REV-090 gated the two operations it named, but `ensure_cron_config()` still did
two more things unconditionally: it re-added the CONFIG-wide `[excluded:]`
retention floors (F1) and it refused a pre-GFS installed CONFIG outright (F2).
So `needs_profile=0` still did not actually mean topology-only. Both are now
behind the same gate. The pre-GFS *detection* still runs unconditionally —
`PROFILE_GFS` is read downstream by the prune shape and the activation summary —
only the *refusal* is conditional, and it still fires wherever policy is
genuinely being generated onto a legacy host.

Evidence: section 51, seven assertions — **346/346**; negative control against
`e26adc57…` → **343/346**, the three failures being exactly the new
discriminating assertions. Response:
`docs/internal/reviews/responses/REV-20260810-091.md`.

The operative rule for this phase, in the reviewer's words: *pure topology
reactivation does not create, repair, normalize or migrate policy.*

Deferred and explicitly out of scope per all three reviews: source-removal /
dataset-set reconciliation.

### Gate 3

One-way handoff is true in production behavior:

```text
PROFILE/PRESET -> generate once -> CONFIG v4 -> runtime truth
```

**Status: CLOSED by the reviewer, 2026-08-10.** Three reviews took this from
"the section body is not regenerated" to the full property, each finding a
residual the previous round's evidence could not have caught:

| REV | residual | state |
|---|---|---|
| REV-20260809-089 | reactivation regenerated the relationship-local section body from the current profile | CLOSED |
| REV-20260810-090 | reactivation still *loaded* the profile and appended its templates | CLOSED |
| REV-20260810-091 | reactivation still re-added `[excluded:]` floors and still refused a pre-GFS config | CLOSED |

`docs/internal/reviews/closures/REV-20260810-091.md` records *"Both residual
Phase 3 paths are resolved"*, but no explicit Gate 3 closure statement had been
written the way Gate 1 and Gate 2 have one until
`docs/discussions/GATE3-PHASE35-REVIEWER-RESOLUTION-2026-08-10.md`: *"REV-089,
REV-090 and REV-091 are all CLOSED and together cover the full property rather
than only one implementation detail... No remaining Phase 3 acceptance
property is visible in the current code or review artifacts... Gate 3
acceptance property is proved. Phase 3 is CLOSED and Phase 3.5 may begin."*

---

## Phase 3.5 — expose prefixless create / passive (`-e`) / single-series GFS — CLOSED

`docs/internal/reviews/closures/REV-20260810-093.md` (2026-08-10): APPROVED /
CLOSED. The attended live-ZFS proof (`docs/internal/reviews/responses/
REV-20260810-093.md`, commit `0356545`) supplied the targeted real-ZFS
evidence the reviewer required for the three newly-exposed cells; no
production-code defect was found at any point. "Phase 3.5 production approval
is therefore granted. No engine thaw or production-code follow-up is
required by REV-093."

**Owner direction: MUST DO** —
`docs/discussions/PREFIXLESS-PASSIVE-GFS-OWNER-DIRECTION-2026-08-09.md`.
Recorded here because the plan is the sequencing document
and this phase existed only in discussion notes until now, which is exactly how
an agreed requirement gets quietly dropped.

Goal: the engines already support all four cells of create/existing ×
prefix/no-prefix, and `delsnaps.sh -G` already supports an empty pattern.
`gen-cron.sh` artificially narrows that with `require_field prefix` and
`require_field gfs_pattern`, making the prefixless variants unreachable from
native CONFIG or from any preset.

Sequencing agreed by owner, reviewer and implementer: **after Phase 3, before
Phase 4** — it defines what a native CONFIG/preset is *allowed to express*, so
it must land before Phase 4 makes presets a public contract.

Scope (from the assessment in
`docs/discussions/PREFIXLESS-PASSIVE-GFS-CLAUDE-ASSESSMENT-2026-08-09.md`):

- `gen-cron.sh`: two field-requirement relaxations, `test/gencron` goldens and
  negative controls;
- one small addition to `test/snapsend`/`test/snapget` for the bare-passive
  (`-e`, no `-m`) cell, the only one of the four with no direct test evidence;
- keep expressing passive as `flags = -e`; revisit a first-class field only when
  Phase 4's preview UX actually needs it.

**Design question resolved by the reviewer** —
`docs/discussions/GATE3-PHASE35-REVIEWER-RESOLUTION-2026-08-10.md` §2: the
`resolve_field()` not-found-anywhere (rc 1) vs. found-but-blank (rc 0, empty)
distinction is exactly right; `test/negative/blank-prefix.conf` must keep
pinning blank as a refusal unchanged.

### Status — implemented, awaiting reviewer

`gen-cron.sh` gained `resolve_field_or_omit()`, a small wrapper around
`resolve_field()` used only for `prefix` and `gfs_pattern`: unresolved
anywhere in the ds/tmpl/defaults (or section/defaults) chain now resolves to
`""` — the deliberate no-prefix / prefixless-GFS case — while a key that is
present but blank still refuses exactly as `require_field()` always has.
`pattern` was deliberately left on `require_field()` — it has no accepted
omitted meaning, per the reviewer's resolution.

- `snapsend.sh -m ""` / `snapget.sh -m ""` for the two no-prefix create/
  existing cells — identical to `-m` never given at all, already the engines'
  existing behavior;
- `delsnaps.sh -G ... "" -H24 ...` for the prefixless GFS ladder — an
  intentional empty positional PATTERN, already accepted by the engine,
  matching every otherwise-eligible snapshot on the scope subject to the
  existing protected-prefix/overlap guards;
- the same-scope pattern-overlap guard (`validate_retain_patterns`) already
  treats an empty pattern as a prefix of everything, so a prefixless GFS
  ladder colliding with another prune rule on the same scope still refuses;
- passive representation stays `flags = -e`, per the reviewer's §3 — no
  second `snapshot_mode` field added.

Evidence: `test/run.sh` (the gencron suite) **67/67**; new golden
`fixtures/prefixless-matrix.conf` pins all four create/existing ×
prefix/no-prefix cells at the generated-command boundary; `fixtures/
gfs-no-pattern.conf` (promoted from a negative fixture — the omitted case is
no longer refused) pins the empty positional GFS pattern; new negative
`negative/blank-gfs-pattern.conf` pins present-but-blank still refusing;
`negative/blank-prefix.conf` passes unchanged (message text updated only).
Negative control against the pre-Phase-3.5 generator (`8693b4e3…`, `GEN=`
override): the two new goldens fail (old generator refuses what the new one
now accepts) — confirms the change, not a coincidence. Dependency-selected
cascade (`test/impact.sh`): `test/migrate/run.sh` 52/52, `test/profiles/
run.sh` 55/55, `test/reconcile/run.sh` 47/47, `test/zfsbackup/run.sh`, plus
`test/cron2conf/run.sh` 11/11 for the cron-line-shape contract. Full details
and exact commands: `docs/discussions/PHASE35-IMPLEMENTATION-CLAUDE-2026-08-10.md`.
Registered as an unreviewed direct-main delivery in `docs/project/DELIVERIES.md`
pending a REV, same as Phase 2's property 6.

The bare-passive (`-e`, no `-m`) direct engine test the scope note above
asked for turned out to already exist — `test/snapsend/run.sh` "-e with no
-m" (send side) and its snapget mirror "snapget -e with no -m" (pull side)
both assert the pre-existing snapshot is the one actually transferred, not
just that no warning fires. Needs real ZFS to execute; not run in this
environment (see the response file for what live verification remains).

`sudo ./test/scenarios/run.sh` (needs root, zfs, mbuffer) was not executed in
this environment — flagged as a manual obligation, not skipped silently.

### Gate 3.5

All four create/existing × prefix/no-prefix combinations are expressible in
native CONFIG and provable at the generated-command boundary; prefixed behaviour
is preserved byte/semantically; negative controls show the old generator
rejected what the new one accepts.

**Status: CLOSED** (`REV-20260810-093.md`, 2026-08-10).

---

## Phase 4 — expose presets as a small user feature — SLICE 1 IMPLEMENTER-COMPLETE

Goal: turn the existing profile boundary/renderer into a useful operator-facing CREATE choice without creating a profile manager.

Implement the smallest public surface:

- `--profile=NAME` only where a new task/package is being created;
- default preset remains the zero-choice normal path;
- show candidate CONFIG and resulting cron before install;
- no persistent profile authority after install;
- optional provenance only if it enables a concrete operator action; otherwise do not store it.

### Status — first slice implemented, awaiting reviewer

Was not blocked by REV-093's live-ZFS evidence while it was still pending
(that evidence gap sat on Phase 3.5's runtime behavior, not on Phase 4's
stated dependency, which is Phase 3.5's generator-side CODE contract); as of
2026-08-10 REV-093 is CLOSED (see the Phase 3.5 section above), so the point
is moot regardless. See
`docs/discussions/REVIEW-PROTOCOL-V3-OWNER-CADENCE-IMPLEMENTER-2026-08-10.md`
for the worked dependency analysis.

Commit `9074fe5`: `add-client --profile=NAME` validates the profile directory
(`profile_validate_dir`) before any pairing, stores the choice on the client
record, defaults to `default` when omitted (zero-choice path unchanged).
`activate-client`'s first-activation branch reads it via a new
`apply_client_profile_choice()` helper; re-activation never consults it, same
one-way handoff boundary Phase 3 (REV-089) already draws for the profile in
general, so a pre-existing client record with no `PROFILE` field is a no-op.
`show_activation_proposal`/`atomic_replace_and_install` already satisfy "show
candidate CONFIG and resulting cron before install" — reused as-is, no new
preview mechanism built. Only one profile (`profiles/default`) currently
exists; this slice is the selection mechanism, not a second named profile —
defining further profiles is a separate product decision.

`test/zfsbackup/run.sh` section 53: 358/358 (whole suite). `test/impact.sh`:
only `test/zfsbackup/run.sh` required, run clean. Manual obligation not
covered by any suite: `zfsbackup-live-pair` (needs two live hosts + root —
the real `deploy.sh --pair`/`snapget.sh -n`/`gen-cron.sh --install` path
`add-client`/`activate-client` actually exercise).

### Gate 4

A normal administrator can select/accept a sensible preset and obtain a valid native CONFIG without learning internal profile machinery.

**Status: first slice (the CLI flag + CREATE-time storage + first-activation wiring) implementer-complete, closure is the reviewer's call.**

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

### Native CONFIG examples — DELIVERED (docs), awaiting reviewer

`docs/CONFIG-EXAMPLES.md` + four runnable configs under `docs/examples/`
document all six required expert examples:

- independent hourly/daily retention without forcing GFS — `examples/independent-tiers.conf`;
- quiesce only on selected datasets — `examples/selective-quiesce.conf`;
- intentionally shorter local retention than store/replicated history (Kancelaria pattern) — `examples/short-local-long-store.conf`;
- manual prune schedules/patterns (incl. monitor-only carrier + bookmark prune) — `examples/manual-prune.conf`;
- safe CONFIG validation and preview — the `gen-cron.sh -c` → diff → `--install` workflow;
- deliberate manual customization after preset generation — grounded in the Phase 3 reactivation-preserves-policy guarantee.

Each of the four `.conf` files was rendered through `./gen-cron.sh -c` and
produces the intended send/prune/monitor lines; the doc gives the reader the
exact command to re-validate. Gate-safe under operating rule 1 (documentation,
crosses no earlier gate). Linked from `README.md`. Registered as an unreviewed
direct-main delivery in `docs/project/DELIVERIES.md`.

**Known test-hygiene gap:** the four example configs are not yet pinned by a
suite, so generator changes could let them rot. Deferred as a follow-up (a small
`test/` golden that renders each `docs/examples/*.conf`) rather than expanding
this documentation slice.

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
CREATE-only additive
 -> endpoint/reactivation preserves policy
 -> --profile at CREATE + preview
 -> simple --source/--target workflow
 -> minimal presets + expert docs
 -> RESTORE
 -> only then optional conveniences backed by real need
```
