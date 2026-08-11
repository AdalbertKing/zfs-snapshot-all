# Phase 5 source retention (REV-20260811-102) — design + window decision

Status: implementer design note, 2026-08-11. Owner directed "design/decide the
window first" before code. REV-102 stays OPEN (not implemented) until the window
and approach are settled here.

## The defect (agreed)

The built-in `default` profile bounds only the TARGET:

- `standard_hourly` = send + `prefix=automated_hourly_`, **no prune** → creates
  `automated_hourly_*` on the source every hour, forever;
- `keep_hourly/daily/weekly/monthly` = the GFS ladder `-H24 -D7 -W4 -M12`, emitted
  only as `[prune:<target>]`.

So a default job accumulates managed snapshots on the source with no cleanup —
the backup product can fill the source pool it is meant to protect. Source and
target retention must stay **independent** (short source window ≠ target GFS); the
fix only adds the missing source side, it does not couple them.

## Owner direction (recorded)

The **collector** owns source retention too: collector cron + one canonical
CONFIG → remote source prune over the relationship's existing SSH/grant boundary.
No second autonomous scheduler on the source. For local source→target it is
trivial (one host, one CONFIG generates both prunes).

## Proposed design (reduction-oriented, low blast radius)

**Do not touch `standard_hourly`/`keep_*`.** Changing `standard_hourly` to
self-prune would (a) only work for the local path — in remote PULL the `[dataset:]`
is the *local target* (`src=host:source`), so self-pruning it prunes the target,
not the source — and (b) have a huge blast radius (every emit/migrate/gencron/
configexamples golden). Instead add ONE new template the orchestration uses:

1. **New profile template `source_hourly`** (in `templates.conf`) + a
   `source-prune.inc` fragment:
   ```
   [template:source_hourly]
       prune_schedule = <cron>
       pattern        = automated_hourly
       retain         = -H<N>          # the short source window, see decision
   ```
   No `monitor_warn/crit` (a remote `[prune:host:...]` scope rejects monitors —
   check-snap-age is local-only). `source-prune.inc` → `use_template = source_hourly`.

2. **Local path (`cmd_local_backup`)**: for each root emit, alongside the existing
   `[prune:<target>]` GFS, a `[prune:<root>]` using `source-prune.inc` (short
   window, `pattern=automated_hourly`). Both local, independent.

3. **Remote PULL (`emit_client_sections`)**: alongside the existing
   `[prune:<local-target>]` GFS ladder, emit a `[prune:<account>@<host>:<source>]`
   carrying `ssh_flags` derived from the relationship's `LOAD_FLAGS` (-K/-p/-c/-O),
   using `source-prune.inc`. gen-cron already renders that into
   `delsnaps.sh -c/-K/-O ... <host:source> automated_hourly -H<N>` over SSH — the
   collector-scheduled remote prune the owner direction asks for. No source-side
   cron; pause/disable/remove of the relationship removes it with everything else.

Only the tool-owned `automated_hourly_` pattern is matched, so manual/foreign
snapshots on the source survive. Target-only old snapshots are untouched by the
source prune (different scope). The window is visible in the generated CONFIG and
the preview.

## The one hard dependency to flag (remote grant gap)

Remote source pruning is a **destructive** op on the source. Today the pairing
grants the collector account only what a pull needs on the source (send + hold);
it does **not** grant `destroy`. So `[prune:host:source]` would fail closed on the
source until the pairing also delegates `zfs allow destroy` (and mount/snapshot as
delsnaps needs) on the source datasets to the collector identity. This is the
narrow implementation gap the review anticipated: the *grammar* expresses it, the
*grant* is missing. Options:

- extend `deploy.sh --join` to also delegate the destroy grant when a relationship
  opts into collector-owned source pruning; **fail closed** if the grant is absent
  (never silently skip the source prune);
- until that grant work lands, the remote source prune is generated but the
  activation must verify the grant and refuse activation rather than install a job
  that will fail every hour.

The local path has no such gap (same host, same account).

## Decision needed: the default source window

Product-policy choice, kept explicit. The source window is a short operational
buffer (enough for the next incremental + a safety margin), deliberately shorter
than the target GFS history.

| Option | Source window | Rationale |
|---|---|---|
| **-H48 (recommended)** | 48 hourly = **2 days** | matches the documented `short-local-long-store.conf` (`keep=48`); one full day of margin past the daily incremental cadence; small footprint |
| -H24 | 1 day | tightest; risk: a missed daily incremental leaves no common snapshot for the next send |
| -H72 | 3 days | more slack on the source; larger source footprint |

Recommendation: **-H48**, as a flat count (`delsnaps -H48`), not a GFS ladder —
the source only needs a recent window; the deep history lives on the target.

## Blast radius / evidence plan (once the window is chosen)

- profile: add `source_hourly` + `source-prune.inc`; `test/profiles` gains
  assertions for the new template (existing `standard_hourly`/`keep_*` pins
  unchanged);
- `cmd_local_backup` + `emit_client_sections`: new `[prune:source]` emission;
  `test/localbackup` + `test/zfsbackup` generation cases proving the candidate
  carries BOTH a bounded source prune AND the independent target GFS, that manual
  snapshots are not matched, and (negative control vs `5423518…`) that the base
  leaves source retention absent;
- **real-ZFS end-to-end** (short-source/long-target + a follow-up incremental
  after a source prune) and **remote-identity** proof (the collector's cleanup
  hits the remote source, not the local target) are live-host obligations this
  environment cannot run → the REV stays **IMPLEMENTED, not CLOSED** until they
  are executed on a real host;
- the remote grant dependency above is resolved or explicitly exposed as a gap.
