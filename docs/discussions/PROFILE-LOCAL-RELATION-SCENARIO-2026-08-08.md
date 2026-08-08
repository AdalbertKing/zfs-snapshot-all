# Single-host / local cross-pool deployment — UX requirement and architecture discussion

Status: **OWNER UX REQUIREMENT — A/B IMPLEMENTATION PLACEMENT OPEN FOR CLAUDE + REVIEWER DISCUSSION**

Date: 2026-08-08

Audience: Claude + Reviewer

The Owner rejects the current manual one-host procedure as a normal deployment
path. An administrator must not have to hand-write CONFIG v4, invoke
`gen-cron.sh`, assemble `snapsend.sh` calls or edit crontab just because source
and target happen to be on the same host.

What is fixed is the **operator boundary**, not yet the internal placement of the
implementation.

The Owner's working intuition is that extending `zfs-backup.sh` is probably the
cheapest and most logical solution because that program already orchestrates
host deployment plus backup-task/config/retention lifecycle. That is a hypothesis
to test against the current code, not an architectural order. Claude and Reviewer
should resolve the cheapest clean design from repository facts and discuss any
remaining genuine trade-off before escalating it.

**Owner decision, 2026-08-08:** a third public/local wrapper is rejected. The
project must not grow a parallel local-deployment script and a second copy of
orchestration/state/status logic. The design discussion is therefore **A vs B
only**: extend `zfs-backup.sh`, or extend/reuse `deploy.sh` beneath the same
operator-facing `zfsbackup` boundary.

This is not a new REV and does not authorize changes to the frozen transfer
engines.

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

Only this host receives the package. There is no peer and no network transfer.
The desired protection is:

```text
rpool/data/...  ->  hdd/backups/...
```

with normal orchestration around it:

- dataset discovery and selection;
- snapshot creation;
- incremental/full local ZFS send/receive;
- retention / GFS;
- recursion policy (`no|flat|atomic`);
- monitoring;
- effective CONFIG v4;
- cron preview/install;
- first seed;
- reconciliation/status;
- named profile selection when Stage 5 profile runtime is active.

The data plane itself already exists: `snapsend.sh` has a native local-target
path. The problem is operator orchestration, not a missing transfer engine.

## Fixed UX requirement

The normal one-host deployment must stay at the same high-level boundary as the
remote product UX. From a clean host, target **at most two operator-facing
`zfsbackup` invocations** with all required input supplied interactively or by
arguments.

Illustrative only — exact CLI spelling is NOT decided here:

```text
zfs-backup.sh setup-server ...
zfs-backup.sh <local-relation-command> --source=rpool/data --target=hdd/backups [--profile=default] ...
```

The operator must not be told, on the normal path, to:

```text
edit CONFIG v4
run deploy.sh directly
run gen-cron.sh directly
run snapsend.sh directly
run delsnaps.sh directly
edit crontab
```

Those remain internal mechanisms / expert escape hatches.

## What remains open: cheapest internal placement

Claude + Reviewer should compare these **two** variants against the actual code
rather than decide from naming alone.

### A — extend `zfs-backup.sh` with a local-relation branch

Conceptually:

```text
zfsbackup
  ├─ host bootstrap (reuse deploy.sh as needed)
  ├─ REMOTE relation -> existing remote enrolment path
  └─ LOCAL relation  -> local discovery + source/target mapping

RELATION + PROFILE -> effective CONFIG v4 -> existing gen-cron -> existing engines
```

Why this currently looks attractive to the Owner and Reviewer:

- `zfs-backup.sh` is already the operator-facing orchestrator;
- it already owns client/relation state, config composition, activation and cron
  lifecycle;
- `deploy.sh` already states that actual snapsend/snapget/delsnaps job lines
  belong elsewhere;
- local `snapsend.sh` needs no new engine path;
- it preserves one public UX for local and remote backup.

But Claude must verify the real cost: how much of current `zfs-backup.sh` assumes
`remote client`, peer manifest, endpoint state, seed/catch-up state, etc. If
adding `local` requires invasive surgery through that state machine, the apparent
simplicity may be false.

A valid refinement of A is to extract a **small shared internal relation/composer
boundary** if that reduces branching inside `zfs-backup.sh`; that is not a new
public wrapper and does not create another operator-facing script.

### B — extend/reuse `deploy.sh` for the local branch beneath `zfsbackup`

Potential advantage: `deploy.sh` already prepares one host end-to-end and may
already contain reusable bootstrap/preflight pieces.

Potential problem: its current contract explicitly separates host bootstrap from
actual backup job lines. Making it own dataset selection, profile policy,
effective CONFIG and cron activation may mix provisioning and backup policy and
create a second orchestration owner beside `zfs-backup.sh`.

Even if B wins internally, the **operator-facing command remains `zfsbackup`**;
`deploy.sh` must stay an implementation detail on the normal path. Claude should
only prefer B if code inspection shows materially less change and a clean single
ownership boundary — not merely because the script is named `deploy.sh`.

### C — separate local deployment wrapper — REJECTED BY OWNER

Do not create `zfsbackup-local.sh`, `local-deploy.sh`, or an equivalent new public
orchestration script. That would start a script tree with duplicated discovery,
profile composition, persistent state, status, cron lifecycle and tests. This
option is no longer part of the design space.

Internal helper extraction is still allowed when it removes duplication; the
prohibition is against another public workflow/owner, not against factoring code.

## Profile ownership remains unchanged

Whichever A/B placement wins:

```text
RELATION = WHAT / WHERE
PROFILE  = HOW
```

For the example:

```text
relation:
  type        = local
  source_root = rpool/data
  target_root = hdd/backups
  selected    = operator-selected scope/root

profile:
  cadence / retention / GFS / recursion / monitoring / supported policy
```

The profile contains no concrete dataset names, target paths, endpoints, keys or
grants. A dynamic relation root plus profile recursion may cover future
descendants according to the already-agreed recursion contract; that still does
not make the profile the owner of scope.

## Required outcome of the Claude + Reviewer discussion

Before implementing the local deployment path, Claude should answer with a
code-grounded comparison of **A vs B**:

1. Which existing functions/state files in `zfs-backup.sh` can be reused for a
   local relation unchanged?
2. Which assumptions are hard-wired to peer/SSH/endpoint state and would need to
   be split?
3. If `deploy.sh` were extended/reused instead, which responsibilities would move
   or be duplicated, and what existing contract would change?
4. What is the smallest diff that gives the fixed UX without creating a second
   config renderer, cron owner, persistent-state model or public wrapper?
5. What persistent representation should identify `local` versus `remote` while
   keeping `RELATION + PROFILE -> CONFIG v4` possible?
6. Which tests and live proof are required for each option? Compare blast radius,
   not raw line count alone.
7. Recommend A or B and explicitly state why the rejected alternative costs more
   or creates worse ownership.

Reviewer should challenge that recommendation on dependency boundaries,
state-machine failure modes, idempotence and future profile integration. Resolve
technical disagreements between the two AIs in this discussion; ask the Owner
only if A and B remain materially different but technically valid product choices
after the code-grounded comparison.

## Acceptance constraints independent of implementation choice

The final one-host path must satisfy all of these:

1. At most two normal operator-facing `zfsbackup` invocations from clean host to
   active local backup relationship.
2. No manual CONFIG v4 or manual cron work on the normal path.
3. Local source discovery and target mapping are validated and previewable.
4. Effective CONFIG v4 goes through the real existing `gen-cron.sh`; do not
   create another renderer.
5. First seed uses the existing native local transfer path — no localhost SSH or
   fake peer.
6. Cron activation uses the existing transactional cron ownership mechanism.
7. Re-run is idempotent or fails closed without duplicate jobs.
8. Failure before activation cannot leave a false `active` relationship.
9. `status` can identify the local relation and its source/target.
10. Named profile runtime can plug into the same local path without redesigning
    it.
11. No new public local-deployment wrapper/script is introduced.

## Test / sequencing rule

Do not interrupt the current REV-074 correction merely because this design issue
was discovered. Resolve A vs B before freezing the Stage 5 runtime shape, then
implement at the cheapest clean boundary.

Do not open frozen engines unless code evidence proves orchestration alone cannot
solve the requirement. A targeted live one-host cross-pool proof on scratch ZFS
will be required once the chosen orchestration path exists.