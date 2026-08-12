# Reviewer resolution — unified remote deploy pre-code challenge

Date: 2026-08-12
Status: DESIGN CLARIFICATION — no new REV

This answers Claude peer-context `C-011` against the Owner's authoritative
`OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md` direction.

## 1. HOST is not relationship identity — accepted

Do not invent a host->relationship index, derived durable name, or second authority.
For `--source=HOST:DATASET`, the high-level planner may scan the existing client
records and resolve candidates from the already-authoritative fields.

Rules:

- zero matching existing relationships: this is a CREATE/enrol case;
- exactly one matching relationship whose requested host/source/mode/target intent
  is compatible: reuse that relationship and derive resume position from its
  existing state;
- more than one candidate: REFUSE and name the candidates; require an explicit
  advanced relationship identity rather than guessing/adopting one;
- an existing relationship that conflicts with the requested intent is not
  permission to mutate it silently.

This is a lookup over existing authority, not a new identity system.

## 2. Local and remote state authorities remain intentionally asymmetric — accepted

Do not add a local client record merely to make the unified surface look symmetric.

- LOCAL high-level deployment continues to derive installed state from CONFIG v4,
  cron and measured ZFS facts, as already agreed in Phase 5.
- REMOTE deployment continues to use the existing client record / pairing / scope
  lifecycle plus installed CONFIG/cron/ZFS facts.

One public command may therefore dispatch to two different existing state sources.
That is intentional. The UX is unified; the underlying authorities are not forced
into an artificial common record.

## 3. Existing same-PVE-cluster sync refusal remains in force

The Owner document already states that existing topology guards remain in force and
that relaxing one is a separate Owner decision. Therefore the motivating
`pve1:hdd/backup -> pve3:hdd/backup` sync example is a topology example, not an
implicit authorization to bypass the current same-cluster refusal.

Do not infer cluster membership from the host name `pve3` alone. If pve3 is an
independent backup receiver, the example proceeds normally. If pve3 is detected as
a member of the same PVE cluster as pve1, the current guard must REFUSE unless the
Owner later explicitly changes that policy.

Claude's proposed implementation detail is accepted: RUX-1 preview should evaluate
that existing guard before any enrolment/mutation so the operator sees the refusal
up front rather than halfway through `add-client`.

## Result

No change to the four-slice implementation sequence:

1. RUX-1 parser + read-only planner, including early consultation of existing
   topology guards and host->relationship candidate resolution.
2. RUX-2 existing enrol/pair/join orchestration.
3. RUX-3 existing seed -> verify -> activate orchestration with same-command retry.
4. RUX-4 bounded real proof of the backup->sync chain on a topology permitted by
   the existing guards.

The reduction remains: one operator intent surface over existing authorities and
existing lifecycle stages; no second state machine, identity store, grant path or
policy reconciliation layer.
