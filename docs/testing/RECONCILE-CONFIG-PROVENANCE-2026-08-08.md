# F3: which config is each host actually running?

> ## CORRECTION, 2026-08-08 13:40 — the first version of this document was WRONG
>
> It concluded that two of four stored configs had drifted from the installed
> cron. **They have not.** Measured against the configs that actually live on the
> hosts, in `/etc/zfs-snapshot-all/`, all four match exactly:
>
> | host | config | generated | installed | only in cron | only in config |
> |---|---|---|---|---|---|
> | metropolis pve1 | `/etc/zfs-snapshot-all/jobs.pve1.v4.conf` | 15 | 15 | 0 | 0 |
> | metropolis pve2 | `/etc/zfs-snapshot-all/jobs.pve2.v4.conf` | 11 | 11 | 0 | 0 |
> | 11.x pve0 | `/etc/zfs-snapshot-all/jobs.pve0.v4.conf` | 31 | 31 | 0 | 0 |
> | 11.x pve1 | `/etc/zfs-snapshot-all/jobs.11.11.v4.conf` | 7 | 7 | 0 | 0 |
>
> **There is no config provenance problem.** `docs/PROJECT_STATUS.md` was right
> that the configs were moved to `/etc/zfs-snapshot-all/`; my measurement was
> wrong.
>
> **How I got it wrong, since the mechanism matters more than the conclusion.**
> I searched `/opt`, `/root/scripts`, the git checkout and
> `/home/zfsbackup/cron-configs`, found nothing, and reported "the configs do not
> live on the hosts" — **without ever looking at the location the status document
> names**. Then, having decided no host-local config existed, I compared the
> WORKSTATION copies in `cron-configs/` and read their differences as fleet
> drift.
>
> Those workstation copies *are* stale — `jobs.pve0.v4-po-migracji.conf` is not
> even the file pve0 uses, which is `jobs.pve0.v4.conf` — but that is a
> housekeeping matter in a private register, not a fleet integrity problem, and I
> reported it as the latter.
>
> Consequence for REV-20260808-071: the reviewer's interim direction to
> *reconstruct the two drifted configs from installed cron* addresses a problem
> that does not exist. Nothing needs reconstructing. The `cron2conf.sh` work is
> not required.
>
> What survives from below: the 11.x pve1 workstation copy genuinely did not
> parse and was migrated (the host-local copy had already been migrated on
> 2026-08-07, `.pre-recursion.20260807-144253`); and the note that generating as
> root rather than as the crontab owner makes every line differ on the log path
> alone.
>
> The rest of this document is kept unedited below as the record of a wrong
> conclusion, not as current fact.

---

# (superseded) F3: which config is each host actually running?

REV-20260808-071 F3 requires that, before any reconciliation output is believed,
the config it was run against is proven to generate the job set the host really
executes. Measured 2026-08-08 at `8b578bd`.

**Result: only two of four stored configs are authoritative. The other two are
not, so no truth-set can honestly be built for them yet — and that is the
finding, not an excuse.**

## Method

The config was piped to the host over ssh and generated **as `zfsbackup`**, the
account whose crontab runs the jobs. Job lines were normalised by cutting the
logging/notify tail (`2>…` onwards) and compared as sets.

The first run generated as **root** and every line differed on the log path
alone (`/root/scripts/` vs `/home/zfsbackup/`) — a difference in who ran the
generator, not in the job set. Recorded because the raw diff looked like total
disagreement and was nothing of the sort.

## Per host

| host | stored config | generated | installed | only in cron | only in config | verdict |
|---|---|---|---|---|---|---|
| metropolis pve2 | `jobs.pve2.v4.conf` | 11 | 11 | 0 | 0 | **authoritative** |
| 11.x pve1 | `jobs.11.11.v4.conf` | 7 | 7 | 0 | 0 | **authoritative** (after migration, below) |
| metropolis pve1 | `jobs.pve1.v4.conf` | 15 | 15 | 4 | 4 | **NOT authoritative** |
| 11.x pve0 | `jobs.pve0.v4-po-migracji.conf` | 19 | 31 | 31 | 19 | **NOT authoritative** |

### 11.x pve1 — repaired

The stored config still expressed recursion as a transfer flag and no longer
parsed at all:

```
[dataset:rpool/data] tier=hourly: flag -r in 'flags' -- recursion is no longer
expressed as a transfer flag.
```

`gen-cron.sh --migrate-recursion` migrated it to `recursive = atomic`, and its
own before/after check reported the rendered block **identical**. So the live
crontab was never affected; only the stored copy had been left behind by the
fleet migration. After migration the generated job set matches the installed one
exactly.

### metropolis pve1 — the stored config is behind

The live crontab carries reserved-snapshot keep-counts the stored config does
not produce:

```
delsnaps.sh -P "__replicate_:2" -P "vzdump:2" -P "__migration__:2" …
```

Four prune lines differ by exactly those flags; the dataset sets, prefixes,
schedules and retention counts are identical. So somebody added `[excluded:]`
sections and installed them, and the stored config never received them.

### 11.x pve0 — the stored config describes a different host

31 installed job lines against 19 generated, with **no overlap at all**. The
live crontab operates on datasets the stored config does not mention:

```
snapsend.sh -m "automated_daily_" -u -v 3 -q auto "hdd/lxc/subvol-102-disk-0,…"
snapsend.sh -m "automated_daily_" -v 3 -q auto "hdd/data/vm-101-disk-0,hdd/data/vm-103-disk-0,hdd/data/vm-104-…"
```

Note `vm-104` — the guest that ran unprotected for months and whose coverage was
added later. That fix reached the host and never reached the stored config.

## What this means for F4

The four-host truth-set REV-071 F4 asks for can be built honestly for **pve2 and
11.x pve1** only. Building one for metropolis pve1 or pve0 would mean classifying
ZFS inventory against a config those hosts do not run — precisely what F3 exists
to prevent, and the resulting counts would look complete while describing
nothing.

So the truth-set is not being produced for those two hosts in this round. What
is needed first is a decision that is not mine to make:

1. **reconstruct** each stored config from the installed crontab (`cron2conf.sh`
   exists and round-trips), then re-verify it generates the live block; or
2. treat the installed crontab as the source of truth for reconciliation and
   read coverage from it rather than from a config file.

Option 1 keeps one representation of intent and repairs the register. Option 2
removes the register's authority entirely. I lean to option 1 — the register is
also what a human edits — but it changes what "the config" means for two hosts
and belongs to the owner and the reviewer.

## Related, already known

`docs/testing/RECONCILE-FALSE-POSITIVE-MEASUREMENT-2026-08-08.md` records that
no config file exists on any host at all. This document adds the sharper point:
for half the fleet, the copy that exists on the workstation is not what the host
runs either.

---

## F3 evidence, per REV-20260808-071 follow-up point 2

A summary table is not proof, and the preceding measurement reached the opposite
conclusion by selecting the wrong files — so the comparison is recorded with the
identity of everything that went into it.

**Command identity.** Run on each host as the account that owns the crontab:

```
su - zfsbackup -c 'cd /home/zfsbackup/zfs-snapshot-all &&
  ./gen-cron.sh -c /etc/zfs-snapshot-all/<config> |
    grep -oE "(snapsend|snapget|delsnaps|check-snap-age)\.sh[^;]*" |
    sed "s/ 2>.*//" | sort -u  > /tmp/g
  crontab -l |
    grep -oE "(snapsend|snapget|delsnaps|check-snap-age)\.sh[^;]*" |
    sed "s/ 2>.*//" | sort -u  > /tmp/l
  diff /tmp/g /tmp/l'
```

The `sed` drops the logging/notify tail, because that portion encodes **who ran
the generator** (`/root/scripts/` vs `/home/zfsbackup/`), not what the job does.
Everything else — script, flags, prefixes, dataset lists, retention — is compared
verbatim.

**Result.** Deployed repo `834b147` on every host, `whoami=zfsbackup` on every
host, and the generated and installed sets are *the same bytes*:

| host | config (`sha256`, 16) | generated | installed | set `sha256` (16) | diff |
|---|---|---|---|---|---|
| metropolis pve1 | `jobs.pve1.v4.conf` `5c30a24d81a576fe` | 15 | 15 | `bfbd69cfa236fcb1` = `bfbd69cfa236fcb1` | rc=0, 0 bytes |
| metropolis pve2 | `jobs.pve2.v4.conf` `8c4d23547b9a8fe1` | 11 | 11 | `03979d81a54ba6a8` = `03979d81a54ba6a8` | rc=0, 0 bytes |
| 11.x pve0 | `jobs.pve0.v4.conf` `f795781418cc9b53` | 31 | 31 | `72e534b60fa3544c` = `72e534b60fa3544c` | rc=0, 0 bytes |
| 11.x pve1 | `jobs.11.11.v4.conf` `4ddc96600fc6ea83` | 7 | 7 | `7bcf9b7e2daf7e74` = `7bcf9b7e2daf7e74` | rc=0, 0 bytes |

The acceptance property is the equality of the compared sets — the identical
hash and the empty diff — not the `N/N` cardinality, which is what the earlier
version of this document leaned on and which is why it was able to be wrong.
