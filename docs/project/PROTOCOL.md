# REVIEW PROTOCOL V2.1
## Claude + Reviewer + Owner workflow

Status: **ACTIVE — V2.1 agreed and in use**

Revision date: 2026-08-12
Original V2 agreement: 2026-08-07

This document consolidates:

- the Owner's REVIEW PROTOCOL V2 proposal;
- Claude's initial protocol proposal (`47a0af0`);
- Claude's amendments (`716bcd3`);
- operational lessons collected through 2026-08-12;
- the Reviewer V2.1 proposal (`de3315b`);
- Claude's V2.1 response (`71147eb`), which accepted all nine proposed deltas, five with amendments and none rejected;
- the Reviewer's independent verification of the evidence behind those amendments.

Where the V2.1 operational amendments below are more specific than earlier V2 wording, V2.1 controls. The four-state review FSM and role ownership of review/response/closure artifacts are unchanged.

## Resolution of Claude's original V2 amendments

All three amendments are resolved.

**A — ACCEPTED.** `REVIEW_LEDGER.md` is generated, never typed. It remains the
single authoritative **current-state view**, while review/response/closure
artifacts contain the machine facts from which that state is deterministically
derived. Those artifacts are authoritative evidence/authorship records, not a
second current-state table.

**B — OPTION 2 SELECTED.** V2 keeps the Owner's four states:
`OPEN -> IMPLEMENTED -> APPROVED -> CLOSED`. `CLOSED` differs from `APPROVED`
by a real repository fact: a canonical closure artifact under `closures/`.
There is therefore no manually invented transition.

**C — ACCEPTED.** New V2 review and response filenames are fixed; duplicate REV
identities or descriptive-suffix duplicates are hard errors.

Also accepted:

- documentation-only findings normally receive a one-paragraph response;
- protocol verification is folded into `./test/impact.sh --verify`, so the
  normal pre-stage gate is one command, not two.

---

# Motivation

Current review quality is high, but the review process is inefficient.

Observed symptoms:

- duplicated reviews and follow-ups;
- two files for the same REV identity;
- uncertainty about the active REV;
- stale `PROJECT_STATUS.md` / `OPEN-THREADS.md`;
- contradictory routing and state prose;
- duplicated synchronization work;
- unnecessary token consumption.

The problem is not review quality. The problem is communication state being
represented in manually maintained prose and tables.

---

# Goals

The protocol shall guarantee:

- one authoritative current-state view;
- deterministic state derivation;
- no duplicated reviews;
- no duplicated responses;
- deterministic next-action ownership;
- machine-verifiable consistency;
- separate reviewer/implementer authorship;
- minimal process overhead;
- work release without requiring the Owner to relay messages between leads;
- impact-driven evidence rather than ritual full-suite execution;
- continued progress on dependency-independent work when one thread is blocked.

---

# Principle 1 — Single Source Of Truth

Exactly one file is authoritative when a human or agent asks:

- What state is this REV in?
- Whose move is it?
- Which implementation commit is waiting for review?
- Which implementation commit did the reviewer actually verify?
- What is the next action?

That file is:

`docs/internal/reviews/REVIEW_LEDGER.md`

Nothing else is a current-state workflow table.

However, the ledger is **generated**. Nobody edits it manually.

The generation chain is:

```text
review / response / closure machine facts
                  |
                  v
        REVIEW_LEDGER.md
                  |
                  v
        OPEN-THREADS.md
```

This resolves the apparent tension between "one source of truth" and Claude's
correct observation that another hand-maintained ledger would only rename the
failure mode seen on 2026-08-07.

Review/response/closure files are evidence and authorship records. They contain
small machine fields so the state can be derived without reading prose.
They are not alternative current-state summaries.

`PROJECT_STATUS.md` is not workflow.

`OPEN-THREADS.md` is not workflow authority.

---

# Principle 2 — Review is a finite-state machine

Exactly four workflow states exist:

```text
OPEN
  |
  v
IMPLEMENTED
  |
  v
APPROVED
  |
  v
CLOSED
```

The only backward transition is:

```text
IMPLEMENTED -> OPEN
```

when the reviewer rejects the submitted implementation.

No hidden workflow states exist.

Words such as `ACCEPTED`, `DISPUTED`, `NEEDS-DISCUSSION`, `DEFERRED` or
`REJECTED` may exist as evidence/resolution metadata, but never as additional
FSM states.

---

# Principle 3 — Roles

## Claude — Implementer

Responsibilities:

- implement;
- provide exact evidence;
- maintain exactly one response file per REV;
- submit the exact implementation commit.

Never:

- approve own implementation;
- close a review;
- edit reviewer prose;
- edit generated ledger/routing files manually.

## Reviewer

Responsibilities:

- inspect the actual implementation diff;
- verify tests and live evidence;
- approve or reject;
- create a new REV only for a genuinely new finding;
- close an approved review;
- maintain reviewer-authored review metadata/prose.

Never:

- implement production code unless the Owner explicitly changes roles;
- rewrite Claude's response prose;
- guess the active REV from memory or the largest number;
- manually edit generated workflow views.

## Owner

Responsibilities:

- priorities and changes to already-set scope/priority;
- architecture/product decisions between technically valid alternatives;
- accepted operational risk or explicit defer-versus-fix decisions;
- intentional compatibility breaks;
- production deployment/rollout decisions;
- decisions explicitly routed to Owner.

Owner silence is never approval or risk acceptance. It is also not required to start ordinary already-routed work that stays inside accepted scope and the safety boundary below.

---

# Principle 4 — Canonical artifacts and filenames

New V2 files use fixed names only:

```text
docs/internal/reviews/REV-YYYYMMDD-NNN.md
docs/internal/reviews/responses/REV-YYYYMMDD-NNN.md
docs/internal/reviews/closures/REV-YYYYMMDD-NNN.md
```

No descriptive suffixes.

The descriptive title belongs in H1 inside the file, not in the filename.

A duplicate `rev:` identity is a hard error even if filenames differ.

Exactly one response file exists per REV. Subsequent Claude updates extend that
same file.

Closure artifact is tiny machine/audit evidence, not another narrative response.

---

# Principle 5 — Machine facts, not prose parsing

The generator never decides workflow state from Polish or English sentences.
It consumes canonical fields.

## Reviewer file

Minimum machine header:

```text
<!-- rev: REV-20260807-064 -->
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: - -->
<!-- supersedes: - -->
```

Allowed reviewer verdicts are evidence values:

- `CHANGES-REQUIRED`
- `APPROVED`

`reviewed-implementation` names the exact implementation SHA for which that
verdict was issued.

## Implementer response

Minimum current machine header:

```text
<!-- rev: REV-20260807-064 -->
<!-- response-status: IMPLEMENTED -->
<!-- implementation: abcd1234 -->
```

Evidence-only response status may also express routing facts such as
`DISPUTED` or `NEEDS-OWNER`; these are not FSM states.

The implementation SHA, not prose saying "done", is the submission fact.

## Closure artifact

Minimum:

```text
<!-- rev: REV-20260807-064 -->
<!-- closed-by: <reviewer-commit-sha> -->
```

`CLOSED` therefore differs from `APPROVED` by an objective file fact, as Claude
required.

---

# Principle 6 — Deterministic state derivation

The generator derives state in this order.

## CLOSED

A valid canonical closure artifact exists for the REV and references reviewer
approval evidence.

## APPROVED

No closure artifact exists, and:

- reviewer verdict is `APPROVED`;
- `reviewed-implementation` equals the current response `implementation` SHA.

## IMPLEMENTED

No closure artifact exists, and a current implementation SHA exists that has
not yet received a reviewer verdict for that same SHA.

Concrete rule:

```text
response.implementation != review.reviewed-implementation
```

## OPEN

All other valid nonclosed cases, including:

- new review with no implementation yet;
- reviewer rejected the current implementation;
- dispute/clarification awaiting Reviewer or Owner.

This model makes rejection deterministic without editing Claude's response:

```text
Claude submits sha1
  response implementation = sha1
  reviewer reviewed-implementation = -
  => IMPLEMENTED

Reviewer rejects sha1
  verdict = CHANGES-REQUIRED
  reviewed-implementation = sha1
  => OPEN

Claude submits sha2 in the SAME response file
  response implementation = sha2
  reviewed-implementation = sha1
  => IMPLEMENTED

Reviewer approves sha2
  verdict = APPROVED
  reviewed-implementation = sha2
  => APPROVED

Reviewer creates closure artifact
  => CLOSED
```

No manually assigned state token is needed in the source artifacts.

---

# Principle 7 — Deterministic next owner and work release

The ledger derives exactly one next owner.

Default mapping:

```text
OPEN, no special routing       -> Claude
IMPLEMENTED                    -> Reviewer
APPROVED                       -> Reviewer   # closure action
CLOSED                         -> -
```

An explicit machine routing fact may override `OPEN` only for legitimate
nonimplementation work:

- dispute needing reviewer resolution -> `Reviewer`;
- architecture/risk decision -> `Owner`.

There is never more than one next owner.

Generated rows with missing or duplicated ownership are invalid.

A fresh row routed to a lead is **standing authorisation to begin that already-scoped work**. `OPEN | Claude` does not require a new Owner message before implementation/evidence begins; `IMPLEMENTED | Reviewer` and `APPROVED | Reviewer` do not require a new Owner message before review/closure begins.

Routing authorises work; it does not imply that an actor is continuously running or that an external dependency is currently available. The lead remains responsible for the routed thread and may continue dependency-independent work under the liveness rule below.

---

# Principle 8 — Never guess active review

Normal reviewer procedure begins with one external gate:

```text
./test/impact.sh --verify
```

That gate includes protocol verification.

Then inspect the generated ledger:

```text
reviewctl list --state OPEN
reviewctl list --state IMPLEMENTED
```

(or equivalent read-only commands).

Review exactly the implementation SHA named by the generated state.

Never infer active work from:

- chat memory;
- the highest REV number;
- latest `main`;
- `PROJECT_STATUS.md`;
- `OPEN-THREADS.md`.

The same rule applies symmetrically to process claims: claims about whether the other lead had work, refreshed state, ran a test or observed a failure are checked against repository or measured evidence before becoming a process conclusion.

---

# Principle 9 — One response and one follow-up rule

A new REV is created only when a **new finding** appears.

Never create a new REV because:

- wording changed;
- evidence was added;
- documentation was clarified;
- the same acceptance criterion remains unmet;
- implementation needs another attempt.

Those remain in the existing REV and the same response file.

Rejected implementation is:

```text
IMPLEMENTED -> OPEN
```

and the same REV continues.

A genuinely new finding after approval creates a new REV. The old approved REV
is not mutated back to `IMPLEMENTED`.

---

# Principle 10 — PROJECT_STATUS

`PROJECT_STATUS.md` describes project/product/operational state only.

It never defines:

- current review state;
- next review owner;
- active REV routing;
- reviewer approval.

It may reference reviews as evidence/history.

Existing project-status freshness logic remains an independent production/project
consistency check inside `impact.sh --verify`.

---

# Principle 11 — OPEN-THREADS is generated

`docs/project/OPEN-THREADS.md` is generated from `REVIEW_LEDGER.md`.

Nobody edits it manually after V2 cutover.

If regenerated output differs from the committed file, verification fails.

No prose inference is allowed.

---

# Principle 12 — Verification is one external gate

The normal mandatory command before a stage is:

```text
./test/impact.sh --verify
```

It invokes protocol generation/verification internally.

`reviewctl verify` may exist as a focused developer/test command, but agents are
not required to remember two independent pre-stage gates.

The protocol verifier performs this conceptually as one operation:

1. parse canonical machine facts fail-closed;
2. reject duplicate/orphan/noncanonical artifacts;
3. generate the expected ledger deterministically;
4. compare it byte-for-byte with committed `REVIEW_LEDGER.md`;
5. generate expected routing and compare with committed `OPEN-THREADS.md`.

The following conditions therefore fail as part of generation or comparison,
not as a growing pile of prose-specific checkers:

- duplicate REV;
- duplicate response;
- noncanonical new filename;
- orphan response/closure;
- malformed machine fields;
- missing/invalid implementation SHA where required;
- approval for a different implementation SHA;
- closure without approval evidence;
- impossible derived ownership;
- stale ledger;
- stale routing.

Parser errors, missing dependencies and malformed rows fail closed. They never
produce a silent PASS.

Before either lead publishes a review, response or closure artifact, `./test/reviewctl.sh --generate` (or the current equivalent transactional generator) must succeed on the resulting facts. This requirement exists because a malformed role-owned header can otherwise freeze routing for unrelated reviews. It is an invariant, not a requirement for a particular Git hook implementation.

---

# Principle 13 — Legal lifecycle facts

The derived lifecycle permits only:

```text
OPEN -> IMPLEMENTED
IMPLEMENTED -> OPEN
IMPLEMENTED -> APPROVED
APPROVED -> CLOSED
```

A source-artifact edit that would derive an impossible lifecycle is rejected.

No:

```text
APPROVED -> IMPLEMENTED
CLOSED -> OPEN
CLOSED -> IMPLEMENTED
OPEN -> CLOSED
```

Historical repair requires an explicit migration/repair mechanism and an
auditable forward commit.

---

# Principle 14 — reviewctl manages artifacts transactionally

Representative commands:

```text
reviewctl open REV-20260807-065 --review docs/internal/reviews/REV-20260807-065.md
reviewctl implement REV-20260807-065 --response docs/internal/reviews/responses/REV-20260807-065.md --sha <implementation-sha>
reviewctl reject REV-20260807-065 --sha <implementation-sha>
reviewctl approve REV-20260807-065 --sha <implementation-sha>
reviewctl close REV-20260807-065
reviewctl show REV-20260807-065
reviewctl list --state IMPLEMENTED
```

Exact CLI spelling may change.

The invariant does not: a command modifies only the calling role's canonical
artifact(s), regenerates derived views, and verifies before completion.

`reviewctl close` creates the canonical closure fact. It does not merely type
`CLOSED` into a table.

---

# Principle 15 — Evidence and impact-driven test discipline

Review quality is evidence-driven, not suite-count-driven.

`./test/impact.sh` remains the source of required automated and manual obligations for the actual diff. The default is to run the suites selected by dependency/impact analysis plus explicit live/manual obligations. The entire repository suite is not mandatory merely because a review exists.

Escalate beyond the impact-selected set when:

- the changed contract has uncertain blast radius;
- dependency mapping is incomplete or suspect;
- a release/migration gate explicitly requires a broader campaign;
- an observed regression suggests coupling missing from the graph;
- the reviewer names a concrete additional risk and the additional test addresses that risk.

`Nothing in the graph is affected` is a valid result when the diff genuinely lies outside mapped product dependencies; it does not waive explicit protocol, live, manual, security or environment-specific obligations.

If a relevant suite reveals a regression that impact analysis should have selected but did not, treat that as a dependency-graph defect. Repair the graph in the same logical delivery when the mapping defect is local and clear; otherwise track the graph repair explicitly before relying on that mapping to close the affected risk.

Still required where applicable:

- contract + required tests before implementation;
- actual diff inspection;
- negative controls with both changed and unchanged case counts;
- real-host proof;
- delegated-account proof for account/permission/crontab paths;
- exact test commands/results;
- explicit tests not run;
- no silent fixture blessing or weakened safety checks.

Green tests prove only the exercised contract. They never substitute for required remote, delegated-account, destructive, real-ZFS or live-cron evidence.

---

# Principle 16 — Lightweight documentation/process findings and process economy

Documentation-only findings normally receive a concise one-paragraph response,
not another design document.

A finding exclusively about the review protocol does not recursively create a
full REV cycle unless it exposes product/release risk. Record it as a compact
protocol note/decision and amend this document explicitly.

Protocol machinery must remove repeated work rather than become a second product. Before adding a checker, ledger field, status file, handoff document or workflow state, prefer eliminating the manually maintained derived state that caused the inconsistency. When two artifacts express the same current fact, one must be derived from the other or removed.

A proposed process mechanism should be able to answer: **what repeated human/model work does this remove?** The routing-generator pre-publication invariant in Principle 12 passes this test because repeated stale-header incidents froze unrelated routing.

---

# Principle 17 — Runtime isolation

Protocol tooling manages communication artifacts only.

It must not:

- modify production configuration;
- alter cron blocks;
- change ZFS state;
- deploy code;
- weaken safety policy;
- treat workflow consistency as proof that production behavior is correct.

Protocol correctness and product correctness are separate gates.

---

# V2.1 operational amendments

These rules capture the agreed lessons from live use of V2 without adding workflow states.

## Simplicity / reuse existing semantics

Before adding a profile, state, marker, config concept, workflow artifact or special mode, first test whether the required behavior is already expressed safely and unambiguously by the existing contract.

Prefer omission, composition or an existing engine semantic when equivalent and safe. A new distinction is warranted when materially different operator intents would otherwise be indistinguishable in configuration or observable behavior and that distinction matters to operation, validation, safety or recovery. It is not warranted merely to label a state already unambiguous from existing semantics, such as the absence of an optional section.

## Owner gate — closed list

Inside already-accepted scope, ordinary implementation, review, read-only inspection, tests, evidence campaigns, documentation and isolated throwaway-lab work do not require a new Owner message.

Owner decision is required for:

1. destructive/state-changing action against existing production datasets, production configuration, cron or other non-throwaway live state;
2. intentional compatibility break;
3. deployment/rollout of a change to live production use;
4. changing Owner-set scope, priority or sequencing when the change is material — ordinary selection of the next dependency-ready item inside an accepted phase is not an escalation;
5. accepting/defering a known risk instead of fixing or proving it.

Isolated disposable test artifacts on real hosts are not automatically production state merely because the host is live; they remain bounded by the project's explicit test safety rules and namespaces.

## Evidence hierarchy

Neither lead accepts the other lead's statement that work is done, tests pass, a branch is current, behavior is safe, or a process failure occurred without checking the relevant facts.

For review/process decisions, evidence priority is:

1. fresh published repository state and exact SHA;
2. exact diff and contract;
3. reproducible automated or live measurement;
4. durable role-owned artifacts;
5. model prose, delegated-worker self-report, commit-message summary or chat memory.

A delegated worker's report about its own work is model prose until the accountable lead verifies it against repository or measured facts.

The safe GitHub read/write-probe checks tool/channel integrity where write capability matters. It does not substitute for inspecting implementation evidence.

## Minimal-change / higher-layer-first

Before reopening a stable lower layer, identify:

1. the contract that actually needs to change;
2. higher-layer dependencies;
3. whether the behavior can be implemented safely above the stable layer;
4. the smallest boundary that must be reopened if not.

Do not combine the required change with opportunistic refactoring, renaming, cleanup or redesign. Observability/progress/status features should first expose information from the existing execution path rather than redesigning execution semantics.

## Delegation

Lead models may delegate bounded mechanical work to subagents, cheaper models or deterministic tooling: searches, inventories, test execution, fixture comparison, log extraction, dependency extraction and candidate-test generation are normal examples.

Delegate execution, not responsibility. The Implementer Lead remains accountable for code/evidence produced by delegated workers. The Reviewer Lead remains accountable for review conclusions and personally verifies load-bearing evidence. High-reasoning lead judgment remains required for architecture, contract changes, ambiguous failures, review verdicts, security/destructive risk and Owner escalation.

Prefer deterministic tooling when the task can be proved mechanically.

## Measurement before opinion

If a safe, available runtime measurement can decide a technical question, run the measurement instead of parking the question on the other lead's opinion. Escalation is appropriate when measurement is unavailable, materially disproportionate, requires Owner-gated production-destructive action, or the result still leaves an irreducible product/risk choice.

## Liveness and parking

A blocked thread stays honestly incomplete. Waiting on unavailable live evidence, an external dependency, the Owner or the peer lead does not block dependency-independent planned work; the current actor selects the next dependency-ready item unless there is a demonstrated project-level dependency blocker or an Owner-set priority prevents it.

Parking must state what the thread waits for. The normal reason vocabulary is `owner`, `peer-lead`, `live-evidence` or `external`. This is evidence metadata, **not a fifth FSM state** and not a second routing table. The ledger's owner remains responsible for resumption when the dependency becomes available.

A thread is never made to look complete merely because it is parked, and a blocker on one dependency chain is never bypassed on that same chain.

## Execution cadence is an infrastructure fact

Protocol routing is immediately valid and authorises the routed work, but protocol text cannot make an actor run in the background.

Current topology must therefore be described honestly: an actor that only exists during an interactive session may not pick up newly routed work until its next session. A scheduler, heartbeat or notification mechanism may reduce that latency, but absence of such infrastructure does not change ledger ownership and must not be represented as though continuous execution were occurring.

Choosing or changing the external execution/scheduling topology is an infrastructure decision; the protocol defines the semantics that any such mechanism must preserve, not a requirement for one specific scheduler.

---

# Migration from legacy workflow

V2 cutover is complete for the active review lifecycle. Legacy artifacts remain historical and are not renamed merely for aesthetics.

The migration rules retained for historical repair are:

1. Inventory existing REV, response and closure artifacts.
2. Detect duplicate IDs and descriptive-suffix duplicates.
3. Parse legacy state only in a migration tool; production V2/V2.1 generator never guesses legacy prose.
4. Resolve ambiguous legacy mappings explicitly.
5. Generate state from canonicalized facts.
6. Freeze legacy filenames.
7. Require canonical fixed names for every new REV.
8. Generate `OPEN-THREADS.md` from the ledger.
9. Keep independent `impact.sh` project/production checks.
10. Require `impact.sh --verify` to invoke protocol verification.

Legacy state mapping for migration only:

```text
OPEN / ACCEPTED / DISPUTED / NEEDS-DISCUSSION -> OPEN + explicit route
IMPLEMENTED                                   -> IMPLEMENTED
reviewer-verified, not archived               -> APPROVED
CLOSED / DONE                                 -> CLOSED
DEFERRED / withdrawn / accepted-risk          -> CLOSED + resolution metadata
```

---

# Minimum acceptance matrix

| Case | Expected |
|---|---|
| canonical new review, no response | OPEN |
| response submits sha1, reviewer has not reviewed sha1 | IMPLEMENTED |
| reviewer rejects sha1 | OPEN |
| same response advances to sha2 | IMPLEMENTED |
| reviewer approves sha2 | APPROVED |
| valid closure artifact after approval | CLOSED |
| closure without matching approval | FAIL |
| approval for sha1 while response current sha is sha2 | FAIL / not APPROVED |
| duplicate review ID | FAIL |
| duplicate response ID | FAIL |
| descriptive-suffix duplicate for new V2 REV | FAIL |
| orphan response | FAIL |
| orphan closure | FAIL |
| malformed machine header | FAIL closed |
| regenerated ledger differs from committed ledger | FAIL |
| regenerated OPEN-THREADS differs from committed file | FAIL |
| routed in-scope work waits only for a new Owner message | PROCESS DEFECT |
| unrelated dependency-ready work freezes because one thread is parked | PROCESS DEFECT |
| relevant unselected regression exposes missing dependency mapping | GRAPH DEFECT |

Negative controls must include at least one real state accepted by the old
mechanism and rejected by V2/V2.1.

---

# Expected result

The protocol eliminates or bounds:

- duplicated reviews;
- duplicated responses/follow-ups;
- uncertainty about ownership;
- stale workflow documents;
- contradictory state models;
- repeated synchronization;
- unnecessary token consumption;
- Owner-as-message-router latency;
- ritual full-suite execution for narrow changes;
- idle dependency-independent work while one thread is blocked.

The normal loop becomes:

```text
./test/impact.sh --verify
    -> read generated REVIEW_LEDGER
    -> act on work routed to your role without waiting for a new Owner message
    -> if blocked, record why and continue dependency-independent work
    -> update exactly one role-owned durable artifact
    -> regenerate REVIEW_LEDGER + OPEN-THREADS
    -> ./test/impact.sh --verify
```

Claude, Reviewer and Owner then cooperate from deterministic repository facts and measured evidence, not from chat memory or model claims.