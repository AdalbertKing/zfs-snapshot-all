# `--reconcile` on the four hosts — the detector is not usable yet

Measurement REV-20260808-070 asked for before `--suggest` is considered. Run
2026-08-08 at `d366483` against the live CONFIG v4 files.

**Verdict: high false-positive rate. The detector must not ship as an alert in
this state, and I am not proposing it as one.**

## Counts

| host | reported uncovered | of which genuine |
|---|---|---|
| metropolis pve1 | 16 | ~3 |
| metropolis pve2 | 23 | ~4 |
| 11.x pve0 | 43 | a handful |
| 11.x pve1 | — | config would not parse, see §3 |

## 1. The dominant false positive: receive targets

A collector's received tree is reported as "exists, and no send job backs it up".
On pve2 that is most of the list:

```
hdd/backups/pve2/rpool/data/vm-106-disk-0
hdd/backups/pve2/hdd/vm-disks/subvol-103-disk-0 (pct/103)
hdd/backups/pve2/rpool/ROOT/pve-1
```

Those are **backups**. Demanding that a backup be backed up is not a finding, it
is noise, and it is the majority of the output.

Worse, the guest attribution makes it look authoritative: `subvol-103-disk-0
(pct/103)` reads like "guest 103 is unprotected" when it is the opposite — that
is guest 103's *copy*, sitting safely on the collector.

**Cause:** the audit compares against SEND jobs only. It never asks what any job
*writes*. The config states destinations (`dst=`, and `src=` for pull), so the
received tree is derivable — I simply did not derive it.

## 2. The second false positive: scratch and test datasets

`hdd/backuptest`, `hdd/backuptest_targets`, `hdd/tests`, `rpool/zholdtest`,
`rpool/stats-test-tgt`, `hdd/ssh-push-test`, `rpool/automated_hourly_decoy` —
these are the test suites' own working datasets and deliberate decoys. Every
run of `test/remote` and `test/scenarios` creates more.

This one has no clean mechanical answer and I am not going to invent a pattern
match for `*test*`: `hdd/backups` is real on one host and scratch on another,
and a heuristic that guesses wrong in the *quiet* direction reintroduces exactly
the VM 104 blindness the tool exists to remove.

The honest options are an explicit ignore list in the config, or accepting that
a host used for testing has noisy output. That is a decision, not an
implementation detail, and it belongs to the owner and the reviewer.

## 3. Two operational findings the measurement surfaced

**a. CORRECTED 2026-08-08 13:40 — this claim was false.** The configs DO live on
the hosts, in `/etc/zfs-snapshot-all/`, on all four. I searched several other
places and never the one `docs/PROJECT_STATUS.md` names. The measurement below
was run against workstation copies for that reason. See
`RECONCILE-CONFIG-PROVENANCE-2026-08-08.md`.

~~**a. The configs do not live on the hosts.**~~ `/home/zfsbackup/zfs-snapshot-all`
contains no `jobs.*.conf` on any host; the files live only in the private
`cron-configs` repository on the workstation. Metropolis pve1 runs **8** live
`snapsend` jobs with no config file present anywhere on it.

So `--reconcile` cannot be deployed as a per-host cron job the way I described
it. For this measurement the config was piped to `/tmp` over ssh and deleted
afterwards. How the audit gets a config on a host is an unsolved part of Stage 4,
not a detail.

**b. `jobs.11.11.v4.conf` is pre-migration and no longer parses.**

```
gen-cron.sh: error: [dataset:rpool/data] tier=hourly: flag -r in 'flags' --
recursion is no longer expressed as a transfer flag.
```

The fleet-wide recursion migration reached the hosts; the stored copy for 11.x
pve1 was not updated with it, and `pve0` has a separate `-po-migracji` file while
`11.11` does not. This is the same shape as the already-known "pve2 has no cron
config": the register of what the fleet runs has drifted from what it runs.

## 4. What I am doing about it

Slice 2, before `--suggest` is discussed at all:

1. derive the **received** tree from the config's destinations and classify it
   separately — never as "uncovered";
2. report the two classes with different words, because "this has no backup" and
   "this is a backup" must not read alike;
3. re-measure on all four hosts and publish both directions again.

Only then is a false-positive rate worth quoting, and only then is an alerting
cron job worth proposing.

## 5. What the measurement does NOT say

It does not say the detector is wrong about everything. `rpool/data`,
`hdd/vm-disks/subvol-101-disk-*` and `hdd/vm-disks/vm-102-disk-0` on pve2 are
real, and on a fleet where one VM already ran unprotected for months they are
worth looking at on their own. But a signal that arrives with four times its
own volume in noise will be ignored, and an ignored alert is the failure mode
this whole package keeps rediscovering.
