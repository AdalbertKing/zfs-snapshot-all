# Stage 5 profile architecture — single-host / local cross-pool scenario

Status: **OWNER SCENARIO / ARCHITECTURE INPUT — NOT AN IMPLEMENTATION ORDER**

Date: 2026-08-08

Audience: Claude + Reviewer

This note records a concrete deployment shape that the Stage 5 profile architecture
must not accidentally make impossible. It does **not** interrupt the current work,
does not authorize engine changes, and is not a new REV.

## Concrete scenario

One Proxmox host, `pve0`, has two independent ZFS pools:

```text
pve0

SOURCE / production:
  rpool/data
    ├── vm-100-disk-0
    ├── vm-101-disk-0
    └── ...

TARGET / backup:
  hdd/backups
```

The administrator wants to install the package **only on this host**.

There is no second backup host and no network transfer. The wanted protection is:

```text
rpool/data/...  ->  hdd/backups/...
```

with the full normal orchestration around it:

- snapshot creation;
- incremental/full ZFS send/receive as appropriate;
- retention / GFS;
- recursion policy (`no|flat|atomic`);
- monitoring;
- cron generation;
- reconciliation/status;
- profile selection.

The administrator should be able to choose a profile for this relationship just as
for a remote relationship. Example profile names discussed by the Owner include
`default`, `GFS_7_30_FLAT`, `7_30`, `GFS_0_7_ATOMIC`; their exact semantics are
**not defined by this note**.

## Architectural consequence

A profile belongs to the **`zfsbackup` orchestration layer**, not to `deploy.sh`.

`deploy.sh` is one provisioning mechanism used when the relationship crosses a
host boundary. It is responsible for remote-relationship concerns such as
pair/join, SSH identity/trust, grants, endpoint facts and related enrolment state.
It is not the owner of backup policy.

The intended abstraction is therefore:

```text
                         zfsbackup
                            |
                   construct RELATION
                            |
               +------------+------------+
               |                         |
             LOCAL                     REMOTE
               |                         |
      local discovery/preflight       deploy.sh
      source/target mapping           pair/join
      local scope selection           grants / SSH
                                      endpoint facts
               |                         |
               +------------+------------+
                            |
                     RELATION READY
                            |
                         PROFILE
                            |
             relation facts + HOW policy
                            |
                  effective CONFIG v4
                            |
                       gen-cron.sh
                            |
                           cron
```

For the local case, **do not invent a fake peer** and do not route through
`localhost` SSH merely to reuse the remote deployment path. There is no reason for
pair/join, remote keys, endpoint verification, remote grants, LAN seed or endpoint
switching when source and target are on the same host.

The existing engine already has a native local-target path: `snapsend.sh` accepts a
local target without a REMOTE argument and does not need SSH for that shape. The
orchestration should eventually expose that capability rather than emulate a remote
relationship to self.

## Ownership stays the same as REV-073

This scenario does **not** move dataset selection into the profile.

```text
LOCAL RELATION                          PROFILE
  discovers local datasets               defines HOW to back up
  selects WHAT is protected              cadence / schedule
  owns source -> target mapping           retention / GFS
  owns local topology facts               recursion / monitoring
                                          quiesce / autotune where supported
                \                        /
                 +----------+-----------+
                            |
                  effective CONFIG v4
```

For example:

```text
relation:
  type        = local
  source_root = rpool/data
  target_root = hdd/backups
  selected    = <operator/deploy selection>

profile:
  name        = GFS_7_30_FLAT
  policy      = HOW only
```

The profile must still contain **no concrete dataset names, source/target mapping,
endpoint data, keys or grants**.

If a selected root is intentionally dynamic and the chosen profile uses `flat` or
`atomic` recursion, newly created descendants may enter the effective job according
to the already-agreed recursion semantics. That does not make the profile the owner
of scope: the relation chose the root; the profile chose how recursion behaves.

## Stage 5 design constraint

Do **not** implement the profile runtime as:

```text
REMOTE CLIENT RECORD + PROFILE -> CONFIG
```

if that makes a profile structurally dependent on remote-client/enrolment state.
The durable model should be:

```text
RELATION + PROFILE -> effective CONFIG v4
```

where `RELATION` can eventually be at least:

```text
local
remote
```

This note does **not** require the whole local-relation UX to be implemented in the
current Stage 5 slice. It requires only that Stage 5 not freeze an architecture
that would force a later profile redesign to support it.

## Why this is not hypothetical

The fleet already contains the physical pattern behind this scenario: local
cross-pool copies `rpool/data/* -> hdd/backups/*` exist on pve0/pve2. The Owner has
explicitly confirmed that a copy to a second independent pool on the same host is a
valid protection layer; off-host replication is a separate layer and must not be
assumed to be the definition of backup at this level.

## Question for Claude

When Stage 5 reaches runtime design, please answer explicitly:

1. Where is profile selection accepted and persisted?
2. Can the profile resolver/composer operate on a relation that has **no peer,
   no SSH endpoint and no deploy manifest**?
3. What is the smallest boundary between `zfsbackup`, `deploy.sh`, profile
   resolution and CONFIG v4 composition that keeps local and remote relations on
   one policy path?
4. Does any proposed Stage 5 data structure accidentally equate `relationship`
   with `remote client`? If yes, correct that before freezing the runtime contract.

Cost rule: preserve the current work sequence. Do not open frozen engines or build
local deployment now merely because this scenario has been recorded.
