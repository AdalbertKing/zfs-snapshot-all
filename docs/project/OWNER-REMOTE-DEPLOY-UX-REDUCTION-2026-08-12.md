# Owner decision — unified high-level remote deployment UX

Date: 2026-08-12
Status: OWNER DECISION / MUST DO

## Purpose

The existing multi-host deployment path is technically mature but exposes too much
of its internal lifecycle to the ordinary administrator:

`add-client -> join -> seed -> verify-endpoint -> activate-client`.

That lifecycle remains useful and must remain available for diagnostics, recovery
and expert operation. It must no longer be the ordinary public deployment workflow.

The Owner requires the remote deployment UX to converge on the same mental model
already used by the high-level local workflow: the operator states SOURCE, TARGET
or MODE, and INSTALL intent; the program orchestrates the existing proven stages.

This is a UX reduction, not a redesign of the transfer engines or relationship
state machine.

## Canonical operator model

The command is run on the machine that will RECEIVE/manage the copy.

A source without a host prefix is local:

```bash
bash /root/zfs-snapshot-all/zfs-backup.sh \
  --source=rpool/data \
  --target=hdd/backup \
  --install
```

A source with a host prefix is remote and is pulled by the current host:

```bash
bash /root/zfs-snapshot-all/zfs-backup.sh \
  --source=pve2:rpool/data \
  --target=hdd/backup \
  --install
```

Sync preserves the source dataset name/path on the receiving host, so the common
sync form needs no separate target:

```bash
bash /root/zfs-snapshot-all/zfs-backup.sh \
  --source=pve1:hdd/backup \
  --mode=sync \
  --install
```

The public meaning is deliberately compositional:

- `--source=DATASET` = local source;
- `--source=HOST:DATASET` = remote source to pull from HOST;
- `--target=DATASET` = local destination root for backup mode;
- `--mode=sync` = identity-preserving sync mapping; do not invent a second target
  path for the ordinary case;
- `--install` = execute the reviewed plan after confirmation;
- without `--install` = preview only, no durable change on either host;
- `--yes` may skip the ordinary confirmation only where existing safety rules
  already allow unattended installation. It does not bypass scope, collision,
  endpoint, grant or topology checks.

Exact final spelling may be refined only if implementation facts require it; the
simple forms above are the product target and should not be expanded casually.

## Concrete topology that motivated this decision

The product must make this ordinary to deploy:

```text
pve2:rpool/data
      |
      | BACKUP
      v
pve1:hdd/backup
      |
      | SYNC
      v
pve3:hdd/backup
```

Today the second relationship requires the administrator to drive the state machine
manually on pve3. After this reduction the complete relationship-level work should
look like:

```bash
# on pve1
bash /root/zfs-snapshot-all/zfs-backup.sh \
  --source=pve2:rpool/data \
  --target=hdd/backup \
  --install

# on pve3
bash /root/zfs-snapshot-all/zfs-backup.sh \
  --source=pve1:hdd/backup \
  --mode=sync \
  --install
```

The pve3 relationship copies the backup estate already present on pve1. It does not
create a second independent backup relationship directly to pve2.

Existing topology guards remain in force. This decision does not silently relax any
same-cluster sync refusal or other safety boundary; if a concrete deployment needs
such a policy changed, that is a separate Owner decision.

## Internal lifecycle stays

Do NOT replace the proven lifecycle. The high-level remote command orchestrates it:

```text
preflight / identify relationship
        -> enrol / pair / join if absent
        -> establish/confirm source scope
        -> seed if required
        -> verify endpoint
        -> activate
        -> read back installed CONFIG/cron state
```

The existing expert verbs remain available:

- `add-client`
- `seed`
- `final-catchup`
- `set-endpoint`
- `verify-endpoint`
- `activate-client`
- `status`
- `test`
- `remove-client`

They become implementation/debugging controls, not required knowledge for the
ordinary install path.

## Critical retry/idempotence contract

The reduced command must be safe to run again after interruption at ANY stage.
This is the load-bearing property of the reduction.

Do not add a second high-level deployment state machine. Derive progress from the
state already owned by the existing system: client record, pairing/join manifest,
committed scope, installed CONFIG v4, cron state and measured ZFS facts.

On re-run:

- no relationship -> create/enrol it;
- pending enrolment / join incomplete -> resume or give the one exact manual join
  action still required;
- joined but not seeded -> seed;
- interrupted/retryable seed -> reuse the existing seed retry semantics;
- seed complete -> verify endpoint;
- endpoint verified -> activate;
- active and matching requested intent -> report success/no-op;
- active or partial relationship whose host/source/target/mode conflicts with the
  new command -> REFUSE rather than silently mutate/adopt it.

Re-running the same high-level command after terminal loss must be the normal retry
procedure. The operator should not have to remember which internal verb comes next.

## Join behavior

For a new remote relationship the high-level path should attempt the already
existing remote-join mechanism when it is safely possible.

If unattended/remote join cannot be completed, do not expose the whole internal
workflow. Stop with one precise source-host action, for example the generated
`deploy.sh --join=...` command/package, and then tell the operator to re-run the
SAME original high-level command on the receiving host.

After that re-run the orchestrator detects that join is complete and continues at
seed/verify/activate.

## Scope and explicit source

`--source=HOST:DATASET` is authoritative operator intent about WHAT is requested,
but it must not bypass the remote enrolment/scope/grant safety contract.

The high-level path may translate the requested root into the existing pairing and
scope machinery; the source side still has to validate/confirm/grant the exact
scope before a seed is allowed. Do not create a second grant mechanism.

If the requested source cannot be represented safely by the existing scope model,
refuse with the exact reason rather than silently discovering a different source.

## Relationship identity

The common one-relationship-per-peer case must require no extra naming argument.
Use the existing stable relationship identity model rather than making address the
runtime identity again.

Implementation may derive/select the obvious relationship identity for the simple
case (normally the peer label/name) and may provide an explicit advanced identity
escape hatch only when multiple distinct relationships to the same peer make the
simple inference ambiguous.

If more than one existing relationship could match, REFUSE and ask for the explicit
identity; do not guess.

## Config/profile boundary

This feature must preserve all existing CREATE-only/profile rules:

- first creation may use the selected/default preset to produce candidate CONFIG;
- after install, CONFIG v4 is runtime truth;
- retry/reactivation must not reload a profile merely to reconstruct policy;
- the high-level wrapper must not repair, normalize, migrate or re-add policy in an
  already installed relationship;
- an input mismatch is not permission to mutate an existing relationship.

The wrapper composes existing lifecycle operations; it is not a reconciliation
engine.

## Preview contract

Without `--install`, no durable change is allowed on either host. Show what can be
known locally and what installation would need to establish remotely.

With `--install` and without `--yes`, show one consolidated plan before the first
mutating action, including at least:

- receiving host;
- remote/local source;
- requested source dataset/scope;
- mode (`backup` or `sync`);
- local target mapping (or identity mapping for sync);
- selected/default preset at CREATE, if applicable;
- current lifecycle position if a partial relationship already exists;
- stages that will be executed or skipped as already complete;
- whether remote join can be attempted automatically;
- final CONFIG/cron effect before activation where existing machinery already
  provides that preview.

The operator confirms the intent once. Internal stages should not each ask the same
question again unless an existing stage has a materially different destructive or
security confirmation that cannot safely be inherited.

## Implementation plan

This is a MUST-DO convenience backed by a concrete Owner need. Per the current
ACTIVE-WORK-PLAN, do not derail the active Restore gate to build it. Prepare the
contract now; implement it immediately after Gate 7 unless the Owner explicitly
reprioritizes.

### Slice RUX-1 — parser + read-only planner

Add recognition of local versus `HOST:DATASET` source and `--mode=sync` to the
high-level entry point. Produce a consolidated read-only plan. No enrolment, SSH
writes, seed, CONFIG write or cron write.

Acceptance:

- existing local high-level command unchanged;
- remote backup form parses to the correct host/source/target intent;
- remote sync form parses to identity mapping;
- ambiguous/invalid source syntax refuses;
- no `--install` leaves both hosts unchanged;
- no duplicate relation/state representation introduced.

### Slice RUX-2 — new remote relationship orchestration through join

Reuse `add-client`/pair/join implementation rather than copying it. The high-level
command creates or resumes a new relationship and either completes remote join or
stops with one exact manual join action and SAME-command retry instruction.

Acceptance:

- fresh remote relationship can progress to joined/pending-seed state;
- lost terminal after join -> same command resumes, no duplicate key/account/scope;
- existing matching relationship is recognized;
- conflicting relationship facts refuse;
- explicit source still goes through source-side scope/grant validation.

### Slice RUX-3 — seed -> verify -> activate orchestration

Drive the existing state machine to ACTIVE, using existing helpers/verbs and their
safety checks. Do not duplicate seed, endpoint or activation logic.

Acceptance:

- fresh remote BACKUP reaches active from one high-level invocation when no manual
  join interruption is required;
- fresh remote SYNC reaches active the same way;
- interruption after seed -> same command resumes at verify/activate;
- interruption after verify -> same command resumes at activate;
- re-run of an already active matching relationship is a clean no-op/success;
- cron cannot become active before successful seed + endpoint verification;
- installed policy survives retries/reactivation unchanged.

### Slice RUX-4 — real chained topology proof

Use a bounded real-host proof of the motivating architecture, not a broad campaign:

```text
pve2 --backup--> pve1 --sync--> pve3
```

Prove at minimum:

- pve1 relationship pulls the requested source into its backup target;
- pve3 syncs the chosen pve1 backup dataset with identity-preserving mapping;
- subsequent runs are incremental where the existing engine contract says they
  should be;
- same-command retries after one deliberately interrupted boundary resume rather
  than recreate the relationship;
- CONFIG and cron on each receiving host represent only that host's relationships;
- no source/target policy from the first leg is silently regenerated on the second.

Use the smallest safe datasets/payload necessary. Do not turn this proof into a new
fleet-wide campaign.

## Gate RUX

The feature is complete when a general administrator can create both legs of the
motivating topology by expressing only source, destination/mode and install intent,
and can recover from an interrupted setup by re-running the same command.

The product-level target is therefore:

```text
LOCAL:
  --source=rpool/data --target=hdd/backup --install

REMOTE BACKUP:
  --source=pve2:rpool/data --target=hdd/backup --install

REMOTE SYNC:
  --source=pve1:hdd/backup --mode=sync --install
```

Everything below that line is implementation detail unless troubleshooting is
needed.

## Explicit non-goals

Do not use this feature as an excuse to add:

- a second lifecycle/state database;
- profile drift/reconciliation;
- automatic policy migration during retry;
- another pairing/grant protocol;
- a generic distributed workflow framework;
- automatic topology discovery across arbitrary hosts;
- implicit adoption of an existing conflicting relationship;
- new transfer-engine semantics where orchestration of the existing engines is
  sufficient.

The design principle is the same as the rest of the project: reduction of operator
steps without multiplying internal authorities.