# Live proof: structural containers, `-S` and `-X` on real ZFS

REV-20260808-074 F1. The 41/41 suite proves the comparison logic against a
stub; it does not prove the ZFS assumptions the stub stands in for. This does.

**Host:** metropolis pve1 (`192.168.28.9`), `zfs-2.1.9-pve1`.
**Identity:** `--reconcile` run as `zfsbackup`; scratch datasets created and
destroyed as root.
**Reviewed implementation:** `99dd958`.
**Scratch:** `hdd/cont-test` with children `a` and `b` (20 MB each).
Destroyed afterwards; `hdd/cont-*` count back to 0, `/tmp/ct` removed.

## The five cases

Classification was read from the heading each dataset appears under, not
inferred from counts.

| # | situation | `hdd/cont-test` lands under |
|---|---|---|
| 1 | parent empty, **both** children covered | **CONTAINER** (suppressed) |
| 2 | 50 MB written **directly into the parent** | **UNCOVERED** |
| 3 | one child left uncovered | **UNCOVERED** |
| 4d | `recursive = flat`, `flags = -S`, data in parent | **UNCOVERED** |
| 4e | `recursive = flat`, no `-S`, data in parent | covered (absent from all findings) |
| 5a | `recursive = flat`, `flags = -X cont-test/b$` → child `b` | **UNCOVERED** |
| 5b | same run → child `a` | covered |

## Why 4d and 4e are stated as a pair

Case 4b — `-S` with an **empty** parent — put the parent under CONTAINER. That
is the right answer, but it is **ambiguous as proof**: the parent could be
unsuppressed-and-covered, or skipped-and-then-suppressed, and the output looks
the same either way.

Putting real data in the parent separates them. With data, the container guard
cannot fire, so the only thing that can keep the parent out of `covered` is `-S`
itself:

- **with `-S`** → `UNCOVERED`
- **without `-S`** → covered, absent from every findings list

The difference is the flag. That pair is the actual `-S` proof; 4b alone was
not.

## The ZFS property the guard depends on

Measured rather than assumed:

| state | `usedbydataset` |
|---|---|
| empty structural parent | **106 496** (~104 KiB) |
| after writing 50 MB into it | **52 584 448** |
| after deleting that file | 106 496 |

So the 1 MiB threshold sits an order of magnitude above an empty filesystem's
own metadata and two orders below real content. It is validated against reality,
not chosen from memory.

## One finding this produced: the property lags the write

Immediately after `dd` + `sync`, `usedbydataset` still read **106 496** while
`ls` showed a 50 MB file and `df` showed 51 MB used. Twelve seconds later it
read 52 584 448.

ZFS space accounting settles on transaction-group commit, so `sync` alone does
not make it current. Consequences, stated plainly:

- **for this proof:** my first run of case 4d reported CONTAINER and looked like
  a failure of the `-S` fix. It was not — it was the measurement racing the txg.
  I caught it because the number disagreed with `ls` and `df`, not because the
  test told me;
- **for the mechanism:** a `--reconcile` run within a few seconds of data being
  written into a parent can still classify it as a container. For auditing
  established datasets, which is the use, this does not matter. It would matter
  if the audit ever ran as a post-write hook, and it should not.

## Dependency cascade

The reviewed change `99dd958` touched `gen-cron.sh`. The graph selected and I
ran: `reconcile` 41/41, `test/run.sh` 65/65, `migrate` 52/52, `profiles` 22/22,
`zfsbackup` 292/292, plus `impact` 56/56 and `impact.sh --verify` clean.

That edge set covers the changed runtime path because `gen-cron.sh` is the only
file touched and every suite that owns generator behaviour is in it. This
document adds no code, so it selects nothing further.

No transfer-engine campaign: the frozen engines were not changed. No crontab
write: `--reconcile` is read-only, and nothing in this proof installed anything.
