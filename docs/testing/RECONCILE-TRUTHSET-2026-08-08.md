# F4 truth-set: every emitted line, classified, on all four hosts

REV-20260808-071 F4. Run 2026-08-08 at `5853d32`, against the **host-local**
CONFIG v4 files whose equivalence to the installed cron is proved in
`RECONCILE-CONFIG-PROVENANCE-2026-08-08.md` (identical set hashes, empty diff).

Exact counts. No estimates.

## 1. False negatives: none

The property that matters most, checked mechanically rather than by reading.
Every guest volume from `qm config` / `pct config`, mapped to its dataset through
`/etc/pve/storage.cfg`, was tested for **exists in ZFS** and **appears in
UNCOVERED**:

| host | guest volumes | exist | reported uncovered |
|---|---|---|---|
| metropolis pve1 | 6 | 6 | **0** |
| metropolis pve2 | 1 | 1 | **0** |
| 11.x pve0 | 9 | 9 | **0** |
| 11.x pve1 | 3 | 3 | **0** |

All 19 are covered. That includes `hdd/data/vm-104-disk-1` — the guest that once
ran unprotected — and `hdd/data/vm-107-disk-0` / `-disk-2`, VM 107's **efidisk
and tpmstate**, the two I once nearly proposed destroying by reading disk names
instead of guest configs.

**No guest volume disappeared from both classes.**

## 2. Every uncovered line, classified

| host | uncovered | received | system | of the uncovered: containers | scratch/test | genuine |
|---|---|---|---|---|---|---|
| metropolis pve1 | 16 | 0 | 1 | 2 | 13 | **1** |
| metropolis pve2 | 12 | 11 | 1 | 2 | 7 | **3** |
| 11.x pve0 | 28 | 7 | 2 | 2 | 19 | **7** |
| 11.x pve1 | 16 | 0 | 2 | 2 | 14 | **0** |

Received went from 0 to 18 across the fleet — that is the F1 fix. Uncovered fell
from 16/23/43 to 16/12/28.

### Class: container datasets (8 fleet-wide, 2 per host)

`hdd/vm-disks` and `rpool/data` on the metropolis hosts, `hdd/lxc` / `rpool/lxc`
and equivalents elsewhere. These are the Proxmox storage parents whose
**children are all covered**; the parent holds no data of its own.

I am not calling these true findings, and I am not silently suppressing them
either. It is a real class the detector does not model: *a dataset with no data,
all of whose children are covered*. Suppressing it needs a rule, and the rule is
a decision — the same one already open for scratch datasets.

### Class: scratch and test (53 fleet-wide)

`hdd/backuptest`, `hdd/backuptest_targets`, `hdd/tests`, `hdd/kopie*`,
`rpool/zholdtest*`, `rpool/zr2*`, `rpool/pulltest`, `rpool/pushtest`,
`rpool/flag-test*`, `hdd/ssh-push-test*`, `rpool/stats-test*`,
`rpool/automated_hourly_decoy`, `hdd/rpool/testpull`, `rpool/backups/pve0test*`.

Created by `test/remote` and `test/scenarios`, including deliberate decoys. Every
suite run adds more. Classified manually here, as the review permits; **no
`*test*` heuristic added**.

### Class: genuine findings (11 fleet-wide)

These deserve a human look and are the reason the tool exists.

**11.x pve0 — 7.** `hdd/mssql`, `hdd/samba`, `hdd/isos`, `hdd/data/vmfiles`,
`hdd/vztmp`, `hdd/lxc64`, `hdd/kopie2`. Names suggesting real content — a SQL
store, a Samba share, VM files — with no send job. I am not asserting they
*should* be backed up; I am asserting nothing backs them up and nobody has said
that is intended.

**metropolis pve2 — 3.** `hdd/vm-disks/subvol-101-disk-0`,
`subvol-101-disk-1`, `vm-102-disk-0`. Guests 101 and 102 do **not** run on pve2
(`pct list`/`qm list` show only 103), so these are either pvesr replication
targets or leftovers from a migration. Either way pve2 holds guest data that no
job on pve2 protects.

**metropolis pve1 — 1.** `hdd/backups`. Written by the *peer's* config, not
pve1's — the documented limit: an inbound push is declared in the sending host's
config, which this host does not have.

**11.x pve1 — 0.**

## 3. What the detector still gets wrong

Nothing in the false-negative direction, on this evidence.

In the false-positive direction, of 72 uncovered lines fleet-wide, **11 are
genuine**, 53 are scratch and 8 are containers. So roughly **15% signal**, up
from about 8% before the F1/F2 fixes, and still not good enough to alert on.

The two remaining classes both need a decision rather than code:

1. **containers** — suppress a dataset whose children are all covered and which
   holds no data of its own? It is mechanical and safe-looking, but "holds no
   data" needs defining (`used` minus `usedbychildren`? `written`?), and getting
   it wrong hides a real dataset.
2. **scratch** — an explicit owner-managed ignore list in the config, as the
   review suggests, considered only after the detector is correct.

Neither is mine to choose.

## 4. Evidence identity

Every figure above comes from `gen-cron.sh --reconcile` run as `zfsbackup` on
the host, against `/etc/zfs-snapshot-all/<config>`, with the deployed repo at the
commit recorded in the provenance document. The guest inventory comes from
`qm config`/`pct config` and `/etc/pve/storage.cfg` on the same host in the same
session, never from dataset names.

---

## 6. After the owner's container decision — measured, not predicted

Re-run on all four hosts once the suppression landed.

| host | uncovered before | after | suppressed as containers |
|---|---|---|---|
| metropolis pve1 | 16 | 15 | `rpool/data` |
| metropolis pve2 | 12 | 11 | `rpool/data` |
| 11.x pve0 | 28 | 26 | `hdd/lxc`, `rpool/data` |
| 11.x pve1 | 16 | 16 | — none |

**Four suppressed, not the eight I predicted, and the shortfall is the guard
working rather than the rule failing.**

`hdd/vm-disks` stayed a finding on both metropolis hosts because it has children
that are **not** covered — `subvol-101-disk-0`, `subvol-101-disk-1` and
`vm-102-disk-0` on pve2. Suppressing it would have hidden exactly the three
genuine findings section 2 identified. Guard 1 ("every child must be covered")
is what stopped that.

On 11.x pve1 nothing was suppressed at all: `rpool/lxc` and `rpool/lxc64` have
no covered children, so they are not solved containers, they are simply
unprotected.

I predicted 8 by counting "two parents per host" from the shape of the output.
That was pattern-matching on names, and the measurement disagrees — the same
mistake in miniature as reading disk names to decide what an orphan was.

Signal is now roughly **11 of 68**, up from 11 of 72. The container class was
never the bulk of the noise; **scratch and test datasets are**, at 53 lines, and
that decision is still open.
