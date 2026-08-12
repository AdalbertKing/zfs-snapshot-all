# Owner decision — default recovery policy

Date: 2026-08-12
Status: OWNER DECISION

## Purpose

This decision defines the zero-choice / simple recovery path. It does not replace
advanced recovery requirements already identified (historical recovery point,
partial recursive selection, arbitrary working destination, safe side restore),
but it establishes what the ordinary recovery command should optimize for.

## Default operator intent

The simple/default recovery means:

> Restore the exact LATEST valid backup recovery point back into the original
> source dataset/path.

The operator should not have to choose ZFS transport mechanics. The program
inspects source and backup history and chooses the cheapest correct strategy that
produces that exact end state.

## Strategy order

For each selected dataset in the simple recovery set:

1. Determine the latest valid recovery point on the backup side.
2. Inspect source and backup snapshot history by GUID, not by snapshot name alone.
3. If the source is non-empty and a proven common snapshot/base exists:
   - preview exactly which newer/local source snapshots and newer source state
     prevent an incremental receive;
   - require explicit confirmation because this is destructive recovery;
   - after confirmation, remove/rollback only the source-side state that blocks
     returning to the proven common base;
   - perform an INCREMENTAL `zfs send | zfs receive` from that common base to the
     backup's latest recovery point;
   - verify the resulting recovery point by GUID.
4. If no valid common base exists, the source lineage is divergent, or the source
   is empty/new, use a FULL `zfs send | zfs receive` path instead of manufacturing
   an incremental path.
5. Success means the restored source represents exactly the selected latest backup
   recovery point. A merely successful process exit is insufficient; transport
   success and GUID verification are both required.

## Important product rule

Incremental recovery is the PRIMARY target for the ordinary case when the source
still shares history with its backup. Destroying source-side snapshots/state that
block that incremental is allowed only after the destructive preview and explicit
operator confirmation.

The tool must not silently choose a full transfer merely because it is easier to
implement when a valid common base exists. Conversely, it must not destroy extra
history merely to pretend an incremental is possible when no proven common GUID
base exists; in that case it falls back to full recovery.

## Backup and sync

`backup` and `sync` use the same recovery planner and the same safety rules. The
relationship mode affects what history/common bases are likely to exist, not the
meaning of recovery. A sync relationship will often make an incremental reverse
recovery possible, but that must still be proven from GUID history.

## Advanced recovery remains orthogonal

The same architecture must later support without changing the default rule:

- restore an older, explicitly selected recovery point instead of latest;
- restore a whole recursive hierarchy, one child/subtree, or an explicit subset
  of children from one recovery point;
- restore into a user-selected working destination rather than the original path;
- safe side restore that refuses overwrite;
- full recovery when lineage/common-base proof is unavailable.

Thus the recovery model has orthogonal dimensions:

- recovery point (default: latest),
- selection set (default: configured source/recovery set),
- destination (default: original source),
- publication mode (default simple recovery is destructive-to-source after
  confirmation; explicit side/working recovery is non-destructive),
- transport strategy (internal: incremental when proven possible, otherwise full).

## Architectural consequence

Do not expose `incremental`, `full`, rollback mechanics, or `zfs receive -F` as the
ordinary user's policy choices. They are planner strategies derived from measured
ZFS state and shown in the preview. The public command expresses recovery intent;
the planner chooses the transport.

This decision supersedes any earlier design assumption that the plain/simple
recovery path must always land in a derived side namespace. A side namespace
remains an explicit safe/working recovery capability, not the default recovery
intent.
