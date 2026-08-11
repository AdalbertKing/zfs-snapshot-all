# Passive-source profile — snapget `-e` without source retention

Status: owner/reviewer discussion input for further Claude design work

Date: 2026-08-11

## Observation

The package uses `snapget.sh` for remote PULL. Its `-e` mode means: use the latest existing snapshot on the remote source instead of creating a new snapshot there.

This creates a legitimate passive-source relationship:

- snapshots on SOURCE are created by an external/local mechanism (for example Proxmox/pvesr/admin policy);
- `zfs-snapshot-all` pulls an existing snapshot with `snapget -e`;
- `zfs-snapshot-all` should not take ownership of SOURCE snapshot lifecycle;
- TARGET retention remains managed normally on the collector.

## Native CONFIG representation

Do not invent `retention = none` or another special runtime token merely to mean "do nothing".

For a passive source, the native CONFIG should express the absence of source-retention ownership by simply omitting the source `[prune:<source>]` section.

Conceptually:

```ini
[dataset:<local-target>]
    src = <account>@<host>:<source>
    # rendered transfer flags include -e

# NO [prune:<remote-source>] section

[prune:<local-target>]
    # normal managed target retention
```

Absence of the SOURCE prune section means the package does not manage source retention. This is intentionally different from a zero-valued retention, which could be misread as "delete everything".

## Product/profile consequence

The current profile set has no profile that deliberately produces this shape. A future passive-source profile/preset should couple two decisions at CREATE time:

1. remote PULL uses `snapget -e` (existing snapshots, no source snapshot creation by the package);
2. no source `[prune:]` is proposed/generated;
3. target `[prune:]` remains generated from the selected target-retention policy.

The administrator should not need to know the hidden rule "if you selected -e, manually delete the proposed source retention". The profile/preset should generate the correct ownership model directly.

Preview/show-config should make the omission explicit in human terms, e.g.:

```text
SOURCE snapshots: external / existing (-e)
SOURCE retention: not managed by zfs-snapshot-all
TARGET retention: managed, <resolved ladder>
```

but CONFIG v4 itself needs no new retention representation for the source: omission of `[prune:<source>]` is sufficient.

## Interaction with REV-102

REV-102 should not establish an unconditional invariant that every remote PULL relationship receives collector-owned source prune.

The narrower ownership invariant is:

- if the package creates/manages SOURCE snapshots, the high-level CREATE path must also propose bounded SOURCE retention;
- if the relationship is passive (`snapget -e`) and consumes externally-owned snapshots, the package must not silently take over SOURCE retention.

Therefore remote-PULL source-prune work under REV-102 should preserve a clean path for a passive-source profile that emits no remote source `[prune:]` and consequently does not require `destroy` merely for retention management.

## Points for Claude to work through

- smallest profile/preset shape that expresses passive source without adding another runtime configuration language;
- where `-e` is carried in profile composition today and how to ensure preview exposes it;
- whether any existing validation incorrectly assumes every managed PULL has source prune;
- exact minimal source grant for passive mode after reading the real snapget command path (do not assume `destroy`/`snapshot` are needed if the relationship neither creates nor prunes source snapshots);
- snapshot selection semantics under `-e`: confirm whether "latest existing" is constrained by prefix/pattern or truly any latest snapshot, and surface any operator risk before making passive a shipped preset;
- targeted generation tests: passive profile => `-e`, no source prune, target prune present; managed/default profile => source prune still present;
- one negative control showing that adding source prune to passive mode would violate the intended ownership boundary.

This is design input, not a new formal finding and does not itself pause REV-102 work.
