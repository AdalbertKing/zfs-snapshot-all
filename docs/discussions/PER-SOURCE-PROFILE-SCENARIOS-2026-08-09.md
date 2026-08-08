# Scenario test — additive sources with per-source profile binding

Date: 2026-08-09
Status: OWNER SCENARIO / Stage 5 architecture requirement, not yet implemented

## Why this scenario matters

The owner asked for the same evolution in local and two-host deployments:

- day 1: protect `rpool/data` as **flat**, without sending the parent dataset;
- day 7: add `rpool/lxc`;
- scenario A: `rpool/lxc` is also **flat**;
- scenario B: `rpool/lxc` is **atomic** while the existing `rpool/data` must remain flat.

Scenario B is the discriminating case. It proves that storing one profile only at whole-relationship level is insufficient: adding an atomic source must not silently change an already-active flat source.

The existing ownership rule remains unchanged:

```text
RELATION / SCOPE = WHAT / WHERE
PROFILE          = HOW
```

Concrete dataset names still do not belong inside reusable profile definitions. The relation binds a selected source/root to the profile that supplies its HOW policy.

## Meaning of "flat without the parent"

For `rpool/data`:

```ini
[dataset:rpool/data]
include_parent   = no
include_children = yes
```

This is WHAT/scope: do not protect the container dataset itself, but include its descendants.

The selected profile supplies HOW:

```ini
recursive = flat
```

Therefore descendants such as `rpool/data/vm-100-disk-0`, `rpool/data/vm-101-disk-0`, etc. are independent backup streams. `rpool/data` itself is not one of those streams.

---

# Scenario A — both source roots use flat

## A1. One host

Topology:

```text
source:  rpool/data
later:   rpool/lxc
target:  hdd/backups
```

Day 1, target CLI:

```bash
./zfs-backup.sh --target=hdd/backups --source=rpool/data --profile=flat
```

The proposal must show the selected scope before adoption:

```ini
[dataset:rpool/data]
include_parent   = no
include_children = yes
```

with `profile=flat` / `recursive=flat` resolved into the effective CONFIG.

Expected result:

```text
rpool/data                  NOT sent as a stream
rpool/data/<child-1>        -> hdd/backups/...
rpool/data/<child-2>        -> hdd/backups/...
...
```

Six days later:

```bash
./zfs-backup.sh --source=rpool/lxc --profile=flat
```

This is additive. The proposal should clearly distinguish existing and new state:

```text
EXISTING:
  rpool/data    profile=flat    parent=no children=yes

ADD:
  rpool/lxc     profile=flat    parent=no children=yes

TARGET:
  hdd/backups
```

On acceptance the system seeds only the newly-added `rpool/lxc` scope, regenerates/validates the effective CONFIG and managed cron block, and leaves the already-proven `rpool/data` stream set unchanged. It must not reseed or redefine `rpool/data` merely because another source root was added.

## A2. Two hosts

Example:

```text
pve1 = collector, target hdd/backups
pve2 = source, rpool/data + rpool/lxc
```

Day 1, pve1:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=flat
```

On pve2:

```bash
./zfs-backup.sh --join=/root/wsad.tgz
```

The source-side scope proposal is edited/adopted as:

```ini
[dataset:rpool/data]
include_parent   = no
include_children = yes
```

Then the same high-level join command is run again to validate the edited scope, show the grant/revoke delta, obtain explicit confirmation, and commit the grants:

```bash
./zfs-backup.sh --join=/root/wsad.tgz
```

Back on pve1, rerun the original high-level relationship command:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=flat
```

It resumes the persisted relationship, fetches/binds the committed scope, composes the effective CONFIG with the flat profile, seeds, verifies, installs/read-backs cron, and reaches ACTIVE.

Six days later the source-side scope is extended with:

```ini
[dataset:rpool/lxc]
include_parent   = no
include_children = yes
```

using the same two-step `--join` high-level boundary (proposal/edit, then explicit grant commit). The collector then reruns:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=flat
```

Expected delta:

```text
rpool/data    already active, unchanged
rpool/lxc     new, seed required
```

Only the new source root is seeded; the existing one is not recreated.

---

# Scenario B — existing flat source, later atomic source

## B1. One host

Day 1 is identical:

```bash
./zfs-backup.sh --target=hdd/backups --source=rpool/data --profile=flat
```

Persisted intent after activation:

```text
rpool/data
  scope:   parent=no, children=yes
  profile: flat
```

Six days later the owner wants `rpool/lxc` protected atomically:

```bash
./zfs-backup.sh --source=rpool/lxc --profile=atomic
```

The command must mean:

```text
EXISTING:
  rpool/data    profile=flat      UNCHANGED

ADD:
  rpool/lxc     profile=atomic
```

It must NOT reinterpret this as "change the whole relationship to atomic".

For this worked example, atomic means the recursive root participates in the atomic tree, so the scope is conceptually:

```ini
[dataset:rpool/lxc]
include_parent   = yes
include_children = yes
```

and the profile supplies:

```ini
recursive = atomic
```

The required persistent model is therefore equivalent to:

```text
LOCAL RELATION
  target = hdd/backups

  source rpool/data
    scope   = parent:no, children:yes
    profile = flat

  source rpool/lxc
    scope   = parent:yes, children:yes
    profile = atomic
```

The exact on-disk representation is an implementation decision; the semantic binding is the requirement.

## B2. Two hosts

Day 1:

```bash
# pve1
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=flat

# pve2
./zfs-backup.sh --join=/root/wsad.tgz
# adopt scope: rpool/data, parent=no, children=yes
./zfs-backup.sh --join=/root/wsad.tgz

# pve1
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=flat
```

Persisted result:

```text
relationship pve2
  rpool/data -> profile flat
```

Six days later, source-side WHAT is extended on pve2 with `rpool/lxc` and its required grant is explicitly committed through the same join/scope boundary.

The collector must then be able to express that the newly-added source uses atomic while the old source keeps flat. A whole-relationship-only spelling such as:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8 --profile=atomic
```

is insufficient/ambiguous unless the CLI makes clear which source binding is being changed. It cannot silently mean "replace the relationship profile".

Required persisted semantics:

```text
REMOTE RELATION pve2
  host   = current transport address
  target = hdd/backups

  source rpool/data
    profile = flat

  source rpool/lxc
    profile = atomic
```

Again, the profile definitions themselves contain no concrete dataset names; this is relation state binding selected WHAT to reusable HOW.

---

# Stage 5 requirement exposed by the scenario

A design that persists only:

```text
RELATION pve2
  profile = flat
```

cannot satisfy scenario B without either:

1. unintentionally changing `rpool/data` when `rpool/lxc` is added as atomic, or
2. inventing a second artificial relationship to the same host solely to obtain another profile.

Both are wrong abstractions.

Stage 5/local orchestration must therefore support the semantic mapping:

```text
SOURCE ROOT -> PROFILE
```

inside one local or remote relationship, for example:

```text
rpool/data -> flat
rpool/lxc  -> atomic
```

This does not violate REV-073. Scope/deploy still owns which concrete source roots are selected; profiles still own only reusable HOW policy. The relation stores the association between them.

## Acceptance properties for the eventual implementation

- Adding a new source is additive by default; existing source/profile bindings do not change silently.
- A profile change must name/show the source binding(s) it will affect before mutation.
- Scenario A seeds only the new source root on day 7.
- Scenario B leaves `rpool/data=flat` while adding `rpool/lxc=atomic`.
- Local and remote relationships use the same semantic model.
- No profile file gains concrete dataset names.
- Source-side grants remain based on scope/WHAT, not on profile/HOW.
- Effective CONFIG v4 remains the single composition output consumed by `gen-cron.sh`.
- No frozen transfer-engine change is implied by this requirement.
