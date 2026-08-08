# Post-Stage-2 integrated live campaign — results

Answers `POST-STAGE2-INTEGRATED-LIVE-CAMPAIGN-2026-08-07.md`.

**Host:** metropolis pve1 (`192.168.28.9`), peer pve2 (`192.168.28.8`).
**Date:** 2026-08-08, 04:05–04:40 CEST.
**Candidate SHA:** `4b30447` — the tip carrying all Stage-2 code. Everything
after it in this document is documentation only and changes no behaviour.

Counts are from that SHA on that host. None are copied from a laptop run or
from an earlier commit.

---

## 1. Automated gate

| suite | result | notes |
|---|---|---|
| `./test/impact.sh --verify` | **consistent** | run on the host, not only locally |
| `recursion` | **64/64** | Stage 2.2 + 2.3 |
| `runsuffix` | **6/6** | Stage 2.1 |
| `twins` | **24/24** | |
| `monitor` | **24/24** | |
| `impact` | **35/35** | |
| `pairpause` | **18/18** | after the fix in §3 |
| `snapsend` | **202/202** | root, ZFS, mbuffer |
| `delsnaps` | **65/65** | root, ZFS |
| `scenarios` | **36/36** | root, ZFS, mbuffer |
| `remote` | **145/145** | as `zfsbackup`, peer pve2 — discharges the mandatory `nonroot-account` obligation |

**Total: 619 assertions, 0 failures.**

## 2. Stage 2.1 — run correlation, the obligation the contract left open

`test/scenarios` does **not** cover suffix correlation; checked rather than
assumed (zero matches for suffix/correlation in the suite). The debt was real.

Scratch subtree `hdd/rs-src` with three 300 MB children, so the run takes
seconds and genuinely crosses second boundaries.

```
./snapsend.sh --recursive=flat -m runcorr_ hdd/rs-src hdd/rs-dst    04:23:04 -> 04:23:30, rc=0
hdd/rs-src@runcorr_2026-08-08_04-23-04
hdd/rs-src/a@runcorr_2026-08-08_04-23-04
hdd/rs-src/b@runcorr_2026-08-08_04-23-04
hdd/rs-src/c@runcorr_2026-08-08_04-23-04
```

26 seconds, **one suffix across all four datasets**.

Negative control on the same subtree with the pre-2.1 engine from `643238a`,
checked out through `git worktree`:

```
./snapsend.sh -R -m oldcorr_ hdd/rs-src hdd/rs-dst2                 04:23:50 -> 04:24:18, rc=0
hdd/rs-src@oldcorr_2026-08-08_04-23-50
hdd/rs-src/a@oldcorr_2026-08-08_04-23-54
hdd/rs-src/b@oldcorr_2026-08-08_04-24-03
hdd/rs-src/c@oldcorr_2026-08-08_04-24-11
```

**Four suffixes spread over 21 seconds.** That is the uncorrelatable run Stage
2.1 exists to remove, observed rather than argued.

The run was invoked as `--recursive=flat`, so it also exercises Stage 2.3 on a
real transfer rather than only at the argv boundary.

Scratch datasets destroyed, worktree removed.

## 3. Finding: `test/pairpause` false-failed on every host

Six cases failed on the host and passed on a laptop. The assertion required
`rc != 0` **and** no `SKIPPED` message, but only the second half is the
contract. An ungated run fails later on a bogus dataset **only where zfs is
missing**; on a real host `zpool list` reports the unknown pool and the run
ends `rc=0`.

Diagnosed rather than assumed: the same suite at `643238a`, before Stage 2
touched anything, gives an identical **12/6** on the same host. So the
assertion was wrong, not the code, and no Stage-2 change caused it.

Fixed in `4b30447`; the suite is 18/18 on the host and on the laptop.

This is the first time `pairpause` had ever run on a host, which is the whole
argument for this campaign existing.

## 4. Stage 2.3 — the installed copy, on every host

The contract asked for **one** delegated-account invocation. Run on all four
hosts, because deployment is an hourly `git pull` and "one host has it" is not
"the fleet has it". As `zfsbackup`, against a nonexistent pool, so both probes
end during argument parsing and touch nothing:

| host | commit | probe A `--recursive=ture` | probe B `-em --recursive=ture` |
|---|---|---|---|
| metropolis pve1 | `3d44488` | refused by value, rc=1 | 0 validations — data |
| metropolis pve2 | `3d44488` | refused by value, rc=1 | 0 validations — data |
| 11.x pve0 | `3d44488` | refused by value, rc=1 | 0 validations — data |
| 11.x pve1 | `3d44488` | refused by value, rc=1 | 0 validations — data |

Probe B is the one that matters: it proves the REV-069 cluster fix is
**deployed**, not merely committed.

An invalid mode is the only discriminating observation available here. A valid
mode is silent whether the token is data or an option — the reason two earlier
probes for this property were blind.

## 5. Not run, and why

- **Root-run of `test/remote`.** The delegated account is the mandatory
  obligation and the harder case (no mount, no `/root`). A root pass would not
  discriminate anything the account pass did not already cover.
- **`force-full` (`-f`/`-F`).** Destructive by nature and unrelated to every
  Stage-2 change; the graph raises it because `snapsend.sh` changed at all.
- **Fleet-wide suite runs.** The campaign document explicitly does not ask for
  them, and pause/hard-disable already have their own live evidence.
