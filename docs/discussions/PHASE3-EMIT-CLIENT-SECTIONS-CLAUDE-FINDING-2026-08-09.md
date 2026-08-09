# Phase 3 finding — `emit_client_sections()` wipes hand customization on reactivation

Date: 2026-08-09. For the reviewer. Empirically confirmed, not yet implemented.

## Context

Gate 2 closed (REV-088); Phase 3's goal is active:

> ordinary relation/topology maintenance must not cause profile policy to be
> regenerated... a manually customized generated CONFIG must survive
> reactivation and endpoint switch unchanged in policy semantics.

Auditing `cmd_activate_client()`'s re-activation path for exactly this
property (the same audit style used for the Phase 2 property review) found
a second, larger instance of the same class of bug REV-088 already fixed
inside `ensure_cron_config()` — this time in `emit_client_sections()`.

## Empirical proof

```bash
$ source zfs-backup.sh
$ # first activation
$ PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" \
  PEER_SAVED_DATASETS="rpool/data" LOAD_LABEL="testpeer" \
  LOAD_ACCOUNT="zfsbackup" LOAD_HOST="10.0.0.5" LOAD_FLAGS="-K /dev/null" \
  PROFILE_GFS=1 emit_client_sections /tmp/t.conf testclient1
$ cat /tmp/t.conf
[dataset:tank/backups/testpeer/rpool/data]
	# managed-by: zfs-backup.sh client=testclient1
	use_template = profile__default__standard_hourly
	src          = zfsbackup@10.0.0.5:rpool/data
	flags        = -K /dev/null
	pair_label   = testclient1
	notify       = testclient1-data
...
$ # hand-add a per-client customization, exactly the kind an admin might add
$ sed -i '/notify       = testclient1-data/a\	monitor_warn = 45m' /tmp/t.conf
$ # re-activation after an endpoint switch: same call, new LOAD_HOST
$ LOAD_HOST="10.0.0.6" ... emit_client_sections /tmp/t.conf testclient1
$ cat /tmp/t.conf
[dataset:tank/backups/testpeer/rpool/data]
	# managed-by: zfs-backup.sh client=testclient1
	use_template = profile__default__standard_hourly
	src          = zfsbackup@10.0.0.6:rpool/data     <- correctly updated
	flags        = -K /dev/null
	pair_label   = testclient1
	notify       = testclient1-data
                                                       <- monitor_warn is GONE
```

`src` correctly picked up the new host — that part of the "remove-then-add
unconditionally" design (documented at `zfs-backup.sh:1170`, "that is what
makes a re-run after an endpoint switch actually pick up the new host/port/
alias") works exactly as intended. But the same unconditional
remove-then-regenerate also discards ANY other content in that client's own
managed section, hand-added or not, because the whole section is rebuilt
from `profile_emit "$PROFILE_DS_FILE"`/`"$PROFILE_PRUNE_FILE"` (the CURRENT
active profile) every single call — first activation and every later
re-activation alike, with no distinction between them.

This is the same shape REV-088 found and fixed in `ensure_cron_config()`
(profile content silently re-consulted on every activation instead of only
at CREATE time) — just at the per-relationship section level instead of the
shared-template level, and with a wider blast radius: `ensure_cron_config()`
only risked drift in the shared `[template:*]` families; this risks
silently discarding ANY hand customization of a SPECIFIC relationship's own
`[dataset:]`/`[prune:]` section, or silently re-pointing it at a different
`use_template`/`gfs_pattern` if the shared default profile's `dataset.inc`/
`prune.inc` themselves change between activations.

## Why I have not implemented a fix yet

`emit_client_sections()` is the single most reviewed function in this
codebase — REV-034 F3, REV-036, REV-045, REV-20260802-033 U7/U9/U11, and
REV-083's own overlap preflight all touch it, each for a carefully reasoned
edge case (sync mode's per-dataset prune scope, GFS ladder recursion,
ownership-marker authorship proof, endpoint-switch pickup). A change here
carries real regression risk across all of those, and I'd rather have the
mechanism agreed before touching it than redesign a function this central
unilaterally, the way REV-088's fix was contained to a function I had
written the same day.

## Proposed direction, for discussion, not yet committed to

Reuse the exact `is_new_relationship` distinction REV-088 already
established in `cmd_activate_client()` (`STATE` was `endpoint_verified` →
genuine first activation; `STATE` was `active` → re-activation), extended
to `emit_client_sections()`:

- **first activation:** current behavior, unchanged — remove-then-add from
  the profile, because there is nothing installed yet to preserve;
- **re-activation:** for each dataset path whose section already exists,
  update ONLY the topology-owned fields (`src`, `flags`) in place within
  the existing section text, leaving `use_template`, `gfs`/`gfs_pattern`,
  `recursive`, and any hand-added fields exactly as they are on disk;
  `pair_label`/`notify` are name-derived and never actually change, so
  updating or leaving them is equivalent.

Open question I do not have a confident answer to yet: mode-based clients
can have their dataset SET itself change between activations (the peer's
own committed scope file can gain/lose datasets, refreshed via
`resolve_mode_datasets()`). A dataset newly present has no existing section
to preserve (falls back to today's full-generation behavior, correctly). A
dataset that disappeared from scope currently keeps its stale section
forever regardless of my proposed change — that is pre-existing behavior
("remove-source" is explicitly deferred in `ACTIVE-WORK-PLAN.md`), not
something this fix should also try to solve.

## What I am NOT proposing

Not a merge/precedence engine, not profile versioning, not a diff-and-ask
interactive flow. Field-level replacement of exactly the two topology
fields this function already computes fresh every call, on the branch that
is a re-activation, using the existing section text as the base instead of
the profile's as the base.

## Minimal proof this would require

- re-activation preserves a hand-added field verbatim;
- re-activation still updates `src`/`flags` to the new endpoint;
- re-activation does not change `use_template`/`gfs_pattern` even if the
  shared default profile's own fragments are edited between activations;
- first activation is unaffected (still full generation);
- sync mode's per-dataset `[prune:]` shape and the backup-mode GFS ladder
  `[prune:]` shape both preserved correctly;
- negative control against the current implementation shows the
  hand-added-field case is wiped.

I have not started implementation. Requesting confirmation of the mechanism
above (or a correction to it) before writing the fix, given the function's
history.
