# Stage 5 profile architecture — single-host / local cross-pool deployment

Status: **OWNER DIRECTIVE — IMPLEMENT AS FIRST-CLASS `zfsbackup` UX**

Date: 2026-08-08

Audience: Claude + Reviewer

This note was originally recorded only as a future architecture constraint. The
Owner has now explicitly rejected that deferral after walking the current manual
procedure. A normal one-host deployment must **not** require an administrator to
hand-write CONFIG v4, invoke `gen-cron.sh`, or manually stitch engine commands.
That is precisely the implementation detail the `zfsbackup` orchestration layer
exists to hide.

This is an implementation requirement for the Stage 5 path, not a new review
finding and not authorization to redesign the frozen engines.

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

The package is installed only on this host. There is no peer and no network
transfer. The wanted protection is:

```text
rpool/data/...  ->  hdd/backups/...
```

with the same orchestration quality as a remote deployment:

- local dataset discovery and scope selection;
- snapshot creation;
- incremental/full ZFS send/receive as appropriate;
- retention / GFS;
- recursion policy (`no|flat|atomic`);
- monitoring;
- effective CONFIG v4 generation;
- cron preview/generation/installation;
- first seed;
- reconciliation/status;
- profile selection as soon as the Stage 5 profile runtime is wired.

The existing engine already supports the data plane natively: `snapsend.sh`
accepts a local target without a REMOTE host. Do not emulate a remote relation to
self.

## Required operator boundary

From a clean host, the normal deployment must require **at most two high-level
`zfsbackup` invocations**. The exact subcommand spelling may follow the existing
CLI conventions, but the ownership boundary is fixed.

Intended shape (illustrative spelling):

```text
1. zfs-backup.sh setup-server [...host-level options...]

2. zfs-backup.sh add-local NAME \
       --source=rpool/data \
       --target=hdd/backups \
       [--profile=default] \
       [--yes]
```

The second command owns the whole local-relation transaction. It must not print
instructions telling the operator to edit CONFIG v4 or run lower-level scripts.
Internally it may call the already-owned mechanisms (`deploy.sh` host bootstrap,
`gen-cron.sh`, `snapsend.sh`, retention/monitor helpers), but those are
implementation details.

Interactive mode may show the discovered scope, effective config and rendered
cron before confirmation. A noninteractive/`--yes` form may consume all required
input on the command line. Either way, the operator stays at the `zfsbackup`
layer.

## What `deploy.sh` is for

`deploy.sh` remains useful, but it is **not the operator-facing second half of a
local deployment**.

It has two roles beneath `zfsbackup`:

1. host bootstrap/maintenance: dependencies, checkout, alerting, smoke checks,
   host-level jobs;
2. remote-relation provisioning where needed: pair/join, SSH trust/identity,
   grants, endpoint facts and enrolment state.

For a local relation there is no peer, no SSH, no pair/join, no remote grant, no
endpoint verification, no LAN seed and no endpoint switch. Do not invent any of
those merely to reuse remote code.

## Durable abstraction

The runtime model must be:

```text
                         zfsbackup
                            |
                   construct RELATION
                            |
               +------------+------------+
               |                         |
             LOCAL                     REMOTE
               |                         |
      local discovery/preflight       deploy.sh remote provisioning
      source/target mapping           pair/join / grants / SSH
      local scope selection           endpoint facts
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
                  seed / install cron
```

Do **not** implement:

```text
REMOTE CLIENT RECORD + PROFILE -> CONFIG
```

The durable contract is:

```text
RELATION + PROFILE -> effective CONFIG v4
```

where a relation can be at least `local` or `remote`.

## Ownership remains REV-073

This directive does not move dataset selection into the profile.

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

A profile still contains no concrete dataset names, source/target mapping,
endpoint data, keys or grants. The relation chooses the source/root/scope. The
profile chooses HOW that scope is protected.

If the relation chooses a dynamic root such as `rpool/data` and the profile uses
`flat` or `atomic`, newly created descendants can enter according to the already
agreed recursion semantics. The relation still owns the root; the profile owns
recursion behaviour.

## Profile timing

Do not block this local orchestration boundary on inventing the Owner's additional
profile names now. The local relation path must be built so profile selection is a
normal input to it. As soon as named profile runtime is wired, the same local
command must accept e.g. `--profile=default` and later the additional Owner-defined
profiles without a local-mode redesign.

Until named profiles are active, using the current standard/default policy
internally is acceptable only as a transitional implementation detail; it must not
be exposed as hand-written CONFIG work for the administrator.

## Acceptance criteria

The one-host feature is not complete until all of the following are true:

1. A fresh supported host can be prepared and a local cross-pool relationship
   activated with at most two operator-facing `zfsbackup` invocations.
2. No normal-path step asks the operator to edit CONFIG v4 manually.
3. No normal-path step asks the operator to invoke `deploy.sh`, `gen-cron.sh`,
   `snapsend.sh`, `delsnaps.sh` or `crontab` directly.
4. Local discovery proves the selected source datasets/root actually exist.
5. Target mapping is previewed and validated before activation.
6. Effective CONFIG v4 is generated by orchestration and validated by the real
   `gen-cron.sh`; do not create a second cron renderer.
7. First local seed uses the existing native local `snapsend.sh` path, with no
   localhost SSH/fake peer.
8. Activation installs the managed cron transactionally through the existing
   cron ownership mechanism.
9. Re-running the command is idempotent or fails closed with a clear existing-
   relation explanation; it must not duplicate cron/jobs.
10. Failure before activation leaves no false `active` state. If seed/config/cron
    installation fails, the relationship remains visibly incomplete/retryable.
11. `zfsbackup status` can identify the local relationship and its source/target.
12. Profile runtime, once enabled, uses this same path: `LOCAL RELATION + PROFILE
    -> effective CONFIG v4`.

## Test boundary

Do not open frozen engines merely to implement orchestration; the local data-plane
capability already exists. Test the smallest affected graph:

- `zfsbackup` local relation parsing/state/composition;
- real `gen-cron.sh` validation/rendering;
- idempotence and failure/rollback controls;
- targeted live one-host cross-pool proof on scratch datasets;
- once profiles are active, include local+default and the Owner's later profile
  matrix in the final Stage 5 live campaign.

The manual CONFIG-v4 procedure may remain documented as an expert/debug escape
hatch. It is **not** an acceptable normal deployment UX.