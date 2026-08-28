# REVIEW PROTOCOL V2.2
## Claude + Reviewer + Owner workflow

Status: **ACTIVE — V2.2 agreed and in use**

Revision date: 2026-08-28
Original V2 agreement: 2026-08-07

This document consolidates:

- the Owner's REVIEW PROTOCOL V2 proposal;
- Claude's initial protocol proposal (`47a0af0`);
- Claude's amendments (`716bcd3`);
- operational lessons collected through 2026-08-12;
- the Reviewer V2.1 proposal (`de3315b`);
- Claude's V2.1 response (`71147eb`), which accepted all nine proposed deltas, five with amendments and none rejected;
- the Reviewer's independent verification of the evidence behind those amendments;
- the Reviewer V2.2 transport-profile proposal (`92af86c`);
- Claude's V2.2 response (`0b25373`), Reviewer synthesis (`8953d86`) and Claude concurrence (`b2aecee`);
- the 2026-08-27 PR-as-handoff incident and publication-completion amendment.

Where the V2.1 operational amendments or V2.2 transport/workspace rules below are more specific than earlier V2 wording, the newer rule controls. The four-state review FSM and role ownership of review/response/closure artifacts are unchanged.

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
- continued progress on dependency-independent work when one thread is blocked;
- transport-independent semantics so the same review protocol can run over GitHub, shared Git or a controlled shared workspace without redefining the lifecycle.

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

## Writing those facts — `approve` and `close`

Since 2026-08-14 the lifecycle facts have a writer, and hand-editing them is a
last resort rather than the normal path:

```text
./test/reviewctl.sh approve REV --implementation FULL_SHA  --expected-parent FULL_SHA
./test/reviewctl.sh close   REV --approval-commit FULL_SHA --expected-parent FULL_SHA
```

Two operations, never one — `approve` refuses `--approval-commit` and `close`
refuses `--implementation`, because a combined request is what published
REV-120/121 with prose saying CLOSED over headers saying CHANGES-REQUIRED.

`close` requires an approval commit that already exists on the publication ref and
that **provably carried the approval**: the review file read at that commit must
itself say `APPROVED`. A merely reachable SHA proves nothing.

`--expected-parent` must equal the publication ref's current tip. A request
computed against a state that has since moved loses rather than publishing on top
of facts it never saw.

Every write is a transaction: snapshot, mutate, regenerate both views, verify, and
restore every byte on any failure. The index is never touched, so a refusal cannot
leave a half-prepared commit.

**This does not gate canonical `main`.** Nothing stops a caller from hand-editing
and pushing. That gate is GitHub branch protection with the graph check required;
until it and its negative control are measured, the invariant is not enforced.

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

## Approval/closure publication boundary

Approval and closure are **two separate publication boundaries**. They must not be
collapsed into one "approve and close" write:

1. The approval publication updates the reviewer artifact to
   `verdict: APPROVED` and sets `reviewed-implementation` to the current full
   response SHA. It regenerates and verifies the derived views. The resulting
   reviewer approval commit must be reachable from the active published ref.
2. Only a later closure publication may create the closure artifact. Its
   `closed-by` field names the full 40-character SHA of that already-published
   approval commit. It then regenerates and verifies the derived views again.

This split is not ceremony: a closure commit cannot truthfully name its own SHA
without circularity. If the active transport cannot execute the transactional
generator or publish all facts and derived views coherently, stop at
`APPROVED | Reviewer`; do not handwrite a closure and do not claim CLOSED in
prose.

A direct-main delivery must also receive its permanent
`<!-- reviewed-by: <delivered-sha> ... -->` marker in the same publication that
first reviews it. Do not rely only on a REV's moving
`reviewed-implementation` pointer: later rounds advance that pointer and would
make the historical delivery reappear as unreviewed.

### Incident that fixed this rule

On 2026-08-14 REV-120 and REV-121 were described as approved and closed while
their reviewer headers still said `CHANGES-REQUIRED`; both closures used the
text `ChatGPT reviewer` instead of a canonical commit SHA, and delivery
`0e6511e...` resurfaced because its first-review fact had not been made
permanent. `reviewctl` correctly refused generation. Forward repair
`211d378628886c0683f817af31454f442dc3ada7` restored the four machine facts,
the delivery marker and both generated views atomically. The incident was a
publication-procedure failure, not permission for either role to edit the
other's artifacts or bypass fail-closed generation.

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

## Peer dialogue fast path

Agreed bilaterally 2026-08-12 (proposal `8983820`, Claude response `4b91504`,
Reviewer synthesis `14493a7`, Claude concurrence `866f604`, Reviewer concurrence
`b3768f1`). Consolidated here from those five artifacts; they remain the record of
how it was reached.

**Peer dialogue first; formal artifacts by exception.**

### The channel

Two files, one writer each, peer reads and never edits:

```text
docs/internal/peer-context/CLAUDE.md      Claude writes, Reviewer reads
docs/internal/peer-context/REVIEWER.md    Reviewer writes, Claude reads
```

Not a transcript and never private reasoning. Rolling and compact — entries may be
replaced or dropped. Updates are event-driven, not per commit. Entry shape:

```text
id: C-00n / R-00n
published-state: <sha>
timestamp: <Europe/Warsaw>
context: <one or two lines>
to-peer: <question / observation / suggestion>
needs-formal-answer: no
```

`published-state` is required, not decorative: an advisory entry whose position
relative to published state is unknown cannot be safely acted on, and nothing else
will catch a stale read.

### What it may and may not carry

Peer dialogue may influence implementation choices, investigation order and local
WIP, provided the acting lead owns the decision and treats neither the peer's
message nor the peer's silence as authorization, approval or proof.

A durable artifact is required when acting on the statement would (a) change formal
routing; (b) change a durable project/architecture/contract truth; (c) claim
approval or closure, or change what either lead formally reports as verified;
(d) satisfy a required evidence boundary; (e) require the peer's authorization or
assent before proceeding; or (f) escalate an unresolved disagreement to the Owner.

The mechanical test, applied at the moment of writing:

```text
Can I make this engineering decision under my existing role authority,
and would it still be valid if the peer note disappeared tomorrow?

YES -> peer dialogue is sufficient coordination.
NO  -> formal artifact required.
```

It tests durability rather than subject matter, so it cannot be argued around by
reclassifying the topic.

### Three rules that hold each other up

1. **Silence carries no meaning.** No response is not assent, not objection, not
   acknowledgement, and not evidence the entry was read. Any step whose correctness
   depends on the peer *not* objecting requires a formal artifact.
2. **Rolling deletion is safe only because rule 1 holds.** Entries may vanish; that
   is tolerable precisely because nothing may depend on one having been seen. Do not
   relax rule 1 without noticing what it is carrying.
3. **`needs-formal-answer: yes` is a pointer, never a queue.** It is valid only when
   the entry names an already-existing formal artifact that carries the answer.
   Create the artifact first, then point at it. An entry requesting a formal answer
   without naming one is not a valid entry.

### What it does not change

Peer dialogue does not change actor cadence: pickup latency remains the
infrastructure property described below. It creates no second ledger, inbox or
routing table — `REVIEW_LEDGER.md` and `OPEN-THREADS.md` stay canonical. It does not
replace the hourly heartbeat, which remains mandatory until the Owner changes that
requirement explicitly.

## Liveness and parking

A blocked thread stays honestly incomplete. Waiting on unavailable live evidence, an external dependency, the Owner or the peer lead does not block dependency-independent planned work; the current actor selects the next dependency-ready item unless there is a demonstrated project-level dependency blocker or an Owner-set priority prevents it.

Parking must state what the thread waits for. The normal reason vocabulary is `owner`, `peer-lead`, `live-evidence` or `external`. This is evidence metadata, **not a fifth FSM state** and not a second routing table. The ledger's owner remains responsible for resumption when the dependency becomes available.

A thread is never made to look complete merely because it is parked, and a blocker on one dependency chain is never bypassed on that same chain.

## Execution cadence is an infrastructure fact

Protocol routing is immediately valid and authorises the routed work, but protocol text cannot make an actor run in the background.

Current topology must therefore be described honestly: an actor that only exists during an interactive session may not pick up newly routed work until its next session. A scheduler, heartbeat or notification mechanism may reduce that latency, but absence of such infrastructure does not change ledger ownership and must not be represented as though continuous execution were occurring.

Choosing or changing the external execution/scheduling topology is an infrastructure decision; the protocol defines the semantics that any such mechanism must preserve, not a requirement for one specific scheduler.

---

# V2.2 transport/workspace profiles

V2.2 separates **protocol semantics** from the **transport/workspace profile** used by the two leads. The profile changes how an exact Git checkpoint is published and reached; it does not change roles, the REV FSM, artifact ownership, ledger semantics, evidence quality or Owner gates.

A project declares one **active profile**. Other documented profiles are capabilities, not implicit fallbacks. Profile selection is configuration, not a workflow state.

## Transport-independent publication invariants

Every profile must satisfy all of these:

1. Durable workflow evidence is Git history. Loose or uncommitted peer files are never sufficient review/submission evidence.
2. Exactly one canonical published project state/ref is named by the active profile.
3. A submitted/reviewed SHA must be exact **and reachable by the actor who must verify it** from that profile's published vantage point.
4. Single-writer role ownership remains unchanged.
5. Published routing releases work exactly as in Principle 7.
6. Transport may expose extra WIP visibility, but WIP is advisory until a canonical artifact names a reachable SHA.
7. No profile creates a second hand-maintained inbox, ledger or routing table.
8. Canonical publication is compare-and-swap against the published state the actor actually verified. If the ref moved, refresh and re-evaluate before publishing.
9. A commit containing generated output such as `REVIEW_LEDGER.md` or `OPEN-THREADS.md` is **not replayed/rebased/merged forward as derived state** after losing a publication race. Integrate the peer's new canonical facts first, regenerate derived output from those facts, then commit the regenerated result.
10. Publication is complete only after the active published ref contains the
    role-owned artifact and regenerated views, and the publisher reads that ref
    back and verifies the expected ledger state and next owner. A role branch,
    open PR, green CI, mergeable PR, or commit not yet reachable from the
    published ref is WIP, never a submission or handoff. Until read-back, the
    publisher must report `not published, no handoff yet` rather than
    `published`, `submitted`, `routed`, or `handed off`.
11. Pre-merge verification checks generated review state against the candidate
    publication ref (`HEAD` in Profile-A PR CI), so commits contained by the PR
    are valid before they reach `main`. Post-merge read-back checks canonical
    `main`. Using `main` for both boundaries makes a correct same-PR handoff
    impossible; using the candidate for both would mistake WIP for publication.

Invariant 9 follows from an observed V2 failure mode: Git can correctly replay a stale generated file even though the underlying facts changed. Generated output has no independent truth; its correct value is the value regenerated from current canonical facts.

## Profile health-check contract

The protocol core asks only:

1. can the actor read the exact canonical published state?
2. can the actor perform its authorised publication action?
3. can the actor read back/resolve the result to the expected exact SHA?

The concrete probe is profile-specific.

## Profile A — GitHub published state

**Active for the current `zfs-snapshot-all` project.**

```text
transport-profile: github-published
published-ref: GitHub main
reviewer-filesystem-access: none
```

GitHub `main` is the canonical published state and transport. Fresh GitHub read
plus the safe reviewer write/read-back probe remain Profile-A health checks. The
Owner revoked the temporary direct-main exception on 2026-08-14; short-lived
branches and Pull Requests are mandatory.

For Profile A, opening a PR starts publication but does not finish it. After
required checks and review conditions pass, the role publishing a
reviewer-owned artifact completes merge/auto-merge when authorised, then reads
fresh `main` and verifies the intended artifact plus ledger transition. If merge
cannot be completed, the PR remains WIP and the concrete blocker is reported;
the peer is not routed to that branch.

GitHub is not being removed or downgraded in this project.

### Profile A′ — optional role-branch fast lane

A′ is an optional feature of Profile A, not a separate lifecycle/profile state:

```text
refs/heads/claude/*     Claude WIP publication
refs/heads/reviewer/*   Reviewer WIP publication
main                    canonical published state
```

Role branches may be used when a long-running thread benefits from early durable peer visibility without advancing `main`. They are not mandatory.

**A role branch is never a submission.** Its existence, freshness or latest commit does not route work. A submission/review boundary exists only when the canonical role-owned artifact/ledger names the exact reachable SHA required by the protocol.

The same is true of an unmerged PR built from that branch. CI and mergeability
qualify the candidate for publication; only merge plus canonical `main`
read-back completes the boundary.

### Incident that fixed publication completion

On 2026-08-27 the Reviewer opened green, mergeable PR #167 containing
REV-20260827-122 and reported the review as published. Claude correctly read
canonical `main`, where neither the review nor `OPEN | Claude` existed, so no
handoff was visible. Merging the PR immediately made the expected ledger row
visible. The failure was permitted by stale direct-main instructions in both
agent entry files and by treating PR creation as completion despite the existing
role-branch rule. Invariant 10 now makes the completion evidence explicit and
symmetric: merge, fresh `main` read-back, expected ledger transition.

The next implementation exposed a second half of the same fault: PR #168
contained a valid response and implementation SHA, but `impact.sh --verify` no
longer invoked `reviewctl`, so CI stayed green while canonical routing remained
stale. The check had been removed during the temporary protocol retirement and
was not restored when V2 became active again. It now verifies the PR candidate
against `HEAD`; full-history CI makes the reachability proof meaningful, and
the merge/read-back rule above remains the publication boundary.

This prevents branch WIP from becoming a second informal communication channel.

## Profile B — shared Git + separate actor clones

Supported for environments where both leads can access a common Git remote/filesystem/host. **Unavailable in the current pairing while the Reviewer operates through the GitHub API without project-filesystem access.**

Preferred topology:

```text
             shared bare Git remote
             /                  \
      Claude clone          Reviewer clone
          RW own               RW own
             \                  /
              canonical published ref
                        |
                 optional GitHub mirror
```

Use **two independent clones**, not one shared working tree. Separate clones preserve independent ref/worktree boundaries and make publication an explicit Git operation.

The profile must name one canonical published ref (for example `main` or `published`). Non-forced publication protects the canonical ref from stale-parent overwrite; after a rejection the actor refreshes and re-evaluates before retrying.

GitHub may remain a synchronous or gated mirror for off-site recovery, CI, audit or release integration according to the role assigned to that mirror. Mirror policy does not change review semantics.

## Profile C — shared workspace visibility + Git checkpoints

Supported only where both leads genuinely have filesystem access. **Unavailable in the current pairing for the same reason as Profile B.**

If enabled, each actor writes only its own area and the peer may receive read-only visibility:

```text
                     Claude    Reviewer
Claude workspace       RW         R
Reviewer workspace      R        RW
```

Filesystem ACLs are defense-in-depth for the existing single-writer rule; they do not replace Git publication/ref safety.

Peer working-tree visibility is **never evidence** and should not be enabled merely because it is technically possible. Prefer a WIP commit/role branch when early visibility can be expressed durably. If a project nevertheless enables shared-workspace visibility for measured latency/inspection value, all verdicts and submissions still cross the reachable-commit boundary.

## Profile migration

Changing profile must preserve history and protocol semantics:

```text
freeze/record old published SHA
        -> establish new transport
        -> prove the same Git object graph / exact SHA is reachable there
        -> prove role publication/read boundaries
        -> declare the new active profile
        -> continue the existing ledger lifecycle
```

No REV state migration is required merely because transport changes.

Profile B/C remain documented even when unavailable to the current actors; `unavailable here` is not the same as `invalid`. The active-profile declaration prevents an unavailable profile from being assumed silently.

---

# Migration from legacy workflow

V2 cutover is complete for the active review lifecycle. Legacy artifacts remain historical and are not renamed merely for aesthetics.

The migration rules retained for historical repair are:

1. Inventory existing REV, response and closure artifacts.
2. Detect duplicate IDs and descriptive-suffix duplicates.
3. Parse legacy state only in a migration tool; production V2/V2.1/V2.2 generator never guesses legacy prose.
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
| submitted SHA is not reachable by the verifying actor under the active profile | FAIL |
| role/WIP branch is treated as submission without canonical artifact routing | PROCESS DEFECT |
| generated workflow output is replayed after peer facts changed instead of regenerated | PROCESS DEFECT |

Negative controls must include at least one real state accepted by the old
mechanism and rejected by V2/V2.1/V2.2.

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
- idle dependency-independent work while one thread is blocked;
- hard-coding GitHub-specific transport behavior into the universal review semantics.

The normal loop becomes:

```text
verify active-profile published state + ./test/impact.sh --verify
    -> read generated REVIEW_LEDGER
    -> act on work routed to your role without waiting for a new Owner message
    -> if blocked, record why and continue dependency-independent work
    -> update exactly one role-owned durable artifact
    -> regenerate REVIEW_LEDGER + OPEN-THREADS
    -> publish through the active profile and verify exact reachable SHA
```

Claude, Reviewer and Owner then cooperate from deterministic repository facts and measured evidence, not from chat memory, model claims or a transport-specific assumption.
