# Profiles without another compiler — proposal for Claude + Reviewer

Date: 2026-08-07

Status: **DESIGN DISCUSSION — DO NOT IMPLEMENT YET**

Owner direction: profiles should describe the reusable backup policy — GFS,
ladder/retention, schedules and operating modes — but we should avoid inventing
another configuration language or another compiler that translates a profile
into arguments for the already-existing engines.

This note is a proposal for technical discussion between Reviewer and Claude.
If we can resolve it technically, do not route it to Owner. Escalate only a
real product/architecture choice that remains after evidence and counterargument.

---

## 1. Starting facts from the current tree

1. `gen-cron.sh` CONFIG v4 already owns the vocabulary for schedules, templates,
   retention, GFS and dataset recursion:
   `[template:]`, `[dataset:]`, `[prune:]`, `retain=`, `gfs=`,
   `gfs_pattern=`, `recursive=no|flat|atomic`, `quiesce=`, monitoring, etc.

2. `lib-scope.sh` / `scope.ini` already own the selector/grant vocabulary.
   We must not invent a second selector syntax inside a profile.

3. `zfs-backup.sh` currently hardcodes the standard profile:
   `standard_hourly`, `keep_hourly/daily/weekly/monthly`, the GFS prune section,
   and the `[dataset:]` / `[prune:]` fields emitted for each client.

4. `deploy.sh` owns bootstrap, identity, SSH material, delegated permissions and
   committed scope. Retention policy must not gain a side door into `zfs allow`.

5. The current standard behavior is production evidence. The first profile
   extraction must render byte-identical effective config and cron for the same
   relationship; otherwise we are changing behavior while claiming to refactor.

---

## 2. Owner's intuitive suggestion — what to keep and what not to keep

The useful core of the suggestion is:

> a profile should contain explicit parameters close to what the existing tools
> already consume, rather than a high-level language that another layer compiles.

I agree with that direction.

I do **not** propose storing four raw shell command lines such as one line for
`zfs-backup`, one for `deploy`, one for `genconfig`, one for `gen-cron`.
That looks simple but creates three problems:

- it makes profile compatibility depend on incidental CLI spelling;
- quoting becomes data semantics and tempts `eval`/shell re-parsing;
- the same fact (for example recursion or retention) can appear in multiple
  command lines and drift.

Similarly I do **not** propose JSON containing argv arrays. It would avoid shell
quoting, but it would still introduce a new schema + parser/dependency and it
would not solve the duplication problem.

---

## 3. Proposed model: a profile is a DIRECTORY OF NATIVE FRAGMENTS

No profile compiler and no profile DSL.

A profile is a small directory containing fragments in the syntax their final
consumer already understands:

```text
profiles/default/
    mode                 # one validated word: backup | sync
    templates.conf       # literal valid gen-cron v4 [template:*] sections
    dataset.inc          # literal gen-cron v4 FIELD lines for [dataset:*]
    prune.inc            # literal gen-cron v4 FIELD lines for [prune:*]
    scope.ini            # OPTIONAL, existing lib-scope grammar only
```

Custom profiles use the same shape under the already-agreed non-tracked local
location, e.g. `profiles.local/NAME/`.

There is deliberately no `profile.json`, no `[profile]` language and no generic
`key -> other-key` mapping table.

### Example: current standard profile

`mode`:

```text
backup
```

`templates.conf` is the current hardcoded `standard_hourly` + `keep_*` blocks,
verbatim in CONFIG v4 syntax.

`dataset.inc`:

```text
use_template = standard_hourly
recursive    = no
```

`prune.inc`:

```text
use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly
gfs          = yes
gfs_pattern  = automated_
```

The exact `recursive` value for a generated prune scope remains a topology
question: backup mode currently owns one namespaced subtree, while sync mode has
separate top-level paths. `zfs-backup.sh` must continue to choose the safe
section scope/recursive sweep shape for that topology rather than allowing a
profile to turn a relation boundary into a wider sweep accidentally. See §5.

### Why fragments rather than raw commands

`zfs-backup.sh` already has to create the relation-specific section header and
fields that no reusable profile can know:

- concrete `[dataset:<localpath>]` path;
- `src`/destination mapping;
- endpoint/account/SSH flags;
- `pair_label`;
- notification label;
- concrete prune scope.

The profile contributes only the policy fields. Those fields are copied, not
translated. The finished file is then accepted or rejected by the real
`gen-cron.sh` parser.

So the data path is:

```text
profile native fragments
        +
relationship facts already owned by zfs-backup/deploy
        |
        v
final CONFIG v4
        |
        v
existing gen-cron.sh
        |
        v
cron
```

There is no semantic stage between profile and CONFIG v4.

---

## 4. Hard ownership boundary

The whole design depends on every fact having one owner.

### Profile-owned

Reusable policy only:

- template schedules;
- snapshot prefixes;
- retention counts/flags;
- GFS ladder and pattern;
- `recursive=no|flat|atomic` for transfer policy;
- quiesce policy where valid;
- monitor warn/crit and schedules;
- later, other stable policy fields already native to CONFIG v4.

### Relationship-owned (`zfs-backup.sh` client state / enrolment)

- client identity;
- endpoint;
- source account;
- source and local target mapping;
- bandwidth/connection material;
- `pair_label`;
- concrete dataset paths;
- selected profile name.

### Deploy/scope-owned

- SSH keys and host trust;
- delegated account;
- granted ZFS permissions;
- committed `scope.ini` grant.

A profile must never contain raw `deploy.sh` arguments that can widen grants.
For the Owner's "second row for deploy" intuition, the deliberate answer is:
**there should normally be no deploy row at all.** A retention/work-mode profile
is not an authority to re-pair or re-grant the peer.

---

## 5. One place where blind textual inclusion is NOT enough

`recursive` has two meanings in the final config topology:

- `[dataset:] recursive=no|flat|atomic` controls transfer behavior;
- `[prune:] recursive=yes|no` controls whether the concrete prune scope sweeps
  descendants.

Those cannot be treated as the same knob mechanically.

Current safe topology already differs by relation mode:

- `backup`: one namespaced local parent can own one recursive prune ladder;
- `sync`: datasets may land as separate top-level paths, so current code emits a
  separate non-recursive prune section per selected dataset to avoid overlap/race.

Proposal: profile owns transfer recursion (`dataset.inc`). The orchestrator
continues to own prune-scope topology. `prune.inc` supplies GFS/templates/pattern
and other retention policy, but **not permission to widen the concrete prune
scope**.

This is not a compiler rule. It is preservation of an existing relation-boundary
safety invariant.

Claude: challenge this split if there is a cleaner way using current CONFIG v4
without weakening the sync/backup topology invariant.

---

## 6. Phase 1 scope — deliberately smaller than the eventual profile vision

First implementation should cover only what the Owner asked to tackle now:

- default and custom profiles;
- GFS yes/no;
- retention ladder / flat retention;
- schedules;
- transfer recursion `no|flat|atomic`;
- backup/sync high-level mode if we agree it belongs in the selected profile;
- monitoring fields already native to CONFIG v4.

Do **not** put these into Phase 1 unless a concrete need requires them:

- arbitrary engine `flags` merging;
- compression/catch-up tuning;
- restore policy;
- grant mutation;
- a new selector syntax.

Scope/selector can be added as optional `scope.ini` in a later slice, reusing
`lib-scope.sh` exactly. Before that, the selected relationship/grant remains the
scope authority as today.

---

## 7. Proposed UX / visibility

Do not hide profile expansion inside `activate-client` only.

Extract the config-building part that already exists so the high-level tool can
show the two native artifacts before installation. Exact verb names are open,
but the workflow should be structurally equivalent to:

```text
zfs-backup ... deploy/enrol relationship
        |
        v
zfs-backup gen-config CLIENT --profile default
        |
        v
zfs-backup show-config CLIENT
        |
        v
zfs-backup gen-cron CLIENT
        |
        v
zfs-backup show-cron CLIENT
        |
        v
activate/install after explicit acceptance
```

Important: `gen-cron` here means **call the existing `gen-cron.sh`**. It is not a
second renderer.

We should probably collapse `gen-config/show-config` and `gen-cron/show-cron`
into preview-capable verbs if that produces fewer states/files. The invariant is
more important than spelling: operator can inspect the exact effective CONFIG v4
and exact rendered cron before activation.

---

## 8. Profile selection and persistence

Keep the earlier agreed rule:

- `--profile NAME` at the high-level relationship command;
- omitted => `default`;
- selected profile name is stored in the client record;
- regeneration/endpoint change/re-activation reuses that saved name;
- changing profile is an explicit operation, never incidental to an upgrade.

No profile snapshot should be copied into every client record. The record stores
identity (`NAME`); the profile files remain the definition. Preview shows the
consequence of current profile content before install.

If we decide reproducibility across profile edits requires pinning a digest or
version, store the digest as evidence, not a second copy of the policy.

---

## 9. Naming / collision rule

Two clients on one collector may use different profiles. Template names are
config-global, so profile template namespaces must not collide.

Simplest contract:

```text
[template:<profile>__<tier>]
```

Example:

```text
[template:default__send]
[template:default__keep_hourly]
```

The profile file itself contains these final names. `zfs-backup.sh` does not
rename them. A custom profile therefore sees exactly the names that will exist
in the final CONFIG v4.

Duplicate template sections are rejected rather than merged heuristically.

---

## 10. Safety rules for custom profiles

1. Never `source` a profile file.
2. Never `eval` a profile line or reconstruct shell command text from it.
3. `mode` is read as data and accepted only from a fixed whitelist.
4. `templates.conf`, `dataset.inc`, `prune.inc` are copied as text into a
   temporary candidate config; the real `gen-cron.sh` must validate the whole
   result before any swap/install.
5. Relationship-owned fields may not appear in profile includes. At minimum
   reject `src`, `dst`, `flags`, `pair_label`, and concrete section headers from
   `dataset.inc`/`prune.inc` in Phase 1 unless we explicitly move ownership.
6. Profile change can never mutate ZFS grants.
7. Existing transactional preview/swap/crontab rollback remains the only install
   path.

---

## 11. Implementation slices

### Slice A — contract and fixtures only

Create one `profiles/default/` fixture representing exactly today's standard
hardcode. No runtime change.

Acceptance:

- profile fragments are valid under the proposed constraints;
- Reviewer + Claude agree field ownership and topology split before code.

### Slice B — extract default hardcode

Make `zfs-backup.sh` consume `profiles/default/` instead of embedded
`STANDARD_TEMPLATE_*` / `KEEP_TEMPLATE_*` policy text.

No profile choice yet.

Acceptance:

- current relation -> byte-identical effective CONFIG v4 versus pre-change;
- rendered cron -> byte-identical versus pre-change;
- backup and sync shapes both covered;
- negative control proves the test detects a changed retain/GFS/recursive value.

### Slice C — named selection + persistence

Add `--profile NAME`, default `default`, and persist the name in the client
record. Re-activation uses the saved profile.

Acceptance:

- absent flag behaves exactly as today;
- unknown profile fails closed;
- changing endpoint cannot silently reset profile;
- changing profile is explicit and previewed.

### Slice D — custom local profiles

Support the same directory shape from the agreed local untracked location.

Acceptance:

- no `source`/`eval`;
- invalid field/section fails before real config change;
- custom profile cannot supply relationship/deploy-owned facts;
- repository self-update is not blocked by local profile files.

### Slice E — first real alternatives

Only after A-D are proven, ship a small set, e.g.:

- `default` — current standard GFS behavior;
- `flat` — count retention without GFS;
- `recursive-flat` — runtime descendant discovery, independent transfer;
- `recursive-atomic` — atomic subtree transfer.

Exact product names and values can be decided after Claude checks which
combinations are actually coherent for pull/sync/backup and existing grants.
Do not ship a Cartesian product merely because it is configurable.

### Slice F — optional scope selector

Only if still wanted after the basic profiles work: add `scope.ini` as a native
sidecar using the existing lib-scope grammar.

Profile desired selector may narrow or request scope, but effective work must be
checked against the already committed grant. Anything outside the grant is a
named refusal, never silent clipping and never automatic `zfs allow`.

---

## 12. Required discussion with Claude

Please answer these points with concrete objections/evidence, not a competing
large design unless needed:

1. Is the **native-fragment directory** materially simpler/safer than the earlier
   "profile as macro over CONFIG v4" proposal, or does it hide a compiler under
   textual inclusion?
2. Can `dataset.inc` / `prune.inc` be constrained cheaply enough to prevent a
   custom profile from stealing relationship-owned fields?
3. Do you agree that `deploy.sh` should receive **no profile command line** and
   that profile/grant are separate authorities?
4. Is the proposed ownership split for transfer recursion vs prune-scope
   recursion correct for current backup/sync topology?
5. What exact current standard output should be captured as the byte-for-byte
   golden baseline before extracting the hardcode?
6. Is `mode=backup|sync` truly profile policy, or should it remain a relationship
   property selected separately? Argue from regeneration/migration behavior,
   not taste.
7. Can we avoid a persistent generated intermediate config file and keep only a
   temporary candidate + existing canonical cron config, while still supporting
   `show-config`/`show-cron`?
8. What is the smallest implementation slice you would ship first so that a
   failed experiment is easy to revert without touching the engine contract?

Goal of the discussion: one agreed plan. No implementation until these are
resolved and no Owner escalation unless a real nontechnical product choice
remains.

---

## 13. Profiles are OPTIONAL — native manual configuration remains first-class

Owner clarification, 2026-08-07: an administrator may deliberately choose to
use **no predefined or custom profile at all** and configure the system directly.
Profiles are convenience presets, not a mandatory abstraction layer.

The architecture must therefore preserve two equivalent entry paths into the
same engine contract:

```text
A. convenience path
   relationship facts + profile fragments -> CONFIG v4 -> gen-cron -> engines

B. expert/manual path
   administrator-authored CONFIG v4       -> gen-cron -> engines
```

Path B must remain complete and supported. It is not an escape hatch, debug mode
or legacy compatibility path.

Consequences:

1. `gen-cron.sh -c FILE` remains independently usable without `zfs-backup.sh`
   and without any profile metadata.
2. A hand-authored valid CONFIG v4 must never require a synthetic profile name
   merely to satisfy orchestration bookkeeping.
3. `zfs-backup.sh` may offer `--profile NAME` as a convenience, but there must be
   a deliberate manual/config mode that accepts or operates on native CONFIG v4
   without reinterpreting it through profile semantics.
4. Profile validation cannot become a second validation authority for CONFIG v4.
   The final authority remains the native consumer (`gen-cron.sh`).
5. Do not make future engine capabilities reachable only through profiles.
   Every capability must first exist in the batch/CLI/config layer; a profile
   may package it afterward.
6. When a generated/profile-managed config and a hand-managed config coexist,
   ownership boundaries must be explicit and fail closed. The tool must never
   silently rewrite hand-authored sections merely because a profile exists.

This also changes one earlier assumption: persisting `selected profile name` is
required only for a relationship that actually uses profile management. Manual
CONFIG-v4 operation has no fake `PROFILE=manual` object unless a concrete
implementation reason proves that such a marker is useful and does not become a
new semantic layer.

Claude: include the manual path in the design review. A proposal that works only
when every relationship selects a profile is incomplete.

---

## 14. Long-horizon architecture: CLI/batch first, WebGUI last

Owner's software-development philosophy for this project is explicit:

> Build a complete, working, scriptable batch/CLI package first. Put the user
> interface on top of it afterward — like the traditional Unix/Linux model.

The eventual WebGUI is therefore a **client of the existing public contracts**,
not a new implementation of backup logic.

Target layering:

```text
              future WebGUI
                   |
                   | calls / displays
                   v
        stable high-level CLI/API boundary
                   |
          zfs-backup / deploy / preview
                   |
        native CONFIG v4 + scope.ini
                   |
                gen-cron
                   |
     snapget / snapsend / delsnaps / monitors
                   |
                   ZFS
```

Architectural rules implied by that target:

1. **No business logic only in the GUI.** Dataset selection, validation,
   profile application, preview, activation, pause/disable, restore planning and
   later destructive confirmations must all be executable without a browser.
2. **Machine-readable output where state matters.** Human prose is useful, but
   commands the GUI will need should eventually have stable structured output
   (`--json` or equivalent) rather than forcing the GUI to scrape sentences.
   This does not mean replacing CONFIG v4 with JSON; it means exposing command
   results/state in a machine-readable representation at the UI boundary.
3. **Plan/preview before mutation.** If the CLI can produce an exact plan or
   candidate config/cron before applying it, the GUI can show the same object and
   invoke the same apply operation. No separate GUI planner.
4. **Stable identifiers.** Relationship/client/profile names and operation IDs
   should be explicit enough that a GUI can address them without parsing paths or
   cron text heuristically.
5. **Idempotent verbs and explicit state.** Web requests may be repeated. Public
   operations should therefore converge safely or fail with a precise state
   mismatch instead of relying on an interactive shell session.
6. **Interactive prompts are a presentation mode, not the only contract.** Any
   operation that currently asks `[t/N]` should, when eventually exposed to the
   GUI, also have a noninteractive equivalent carrying the same explicit consent
   and safety checks. The GUI must not bypass safeguards.
7. **Configuration remains inspectable.** The GUI should be able to show the
   resulting CONFIG v4, cron and effective scope rather than hiding the layer
   underneath it. An expert administrator can always drop below the GUI.
8. **Do not design an HTTP API now just because a GUI is planned.** The near-term
   requirement is only to avoid CLI/config choices that would force us to
   duplicate logic later. First finish and stabilize the batch package.

This principle is a design constraint for profiles now: profiles should make the
CLI easier, but must not become an invisible state machine that only a future GUI
can understand.