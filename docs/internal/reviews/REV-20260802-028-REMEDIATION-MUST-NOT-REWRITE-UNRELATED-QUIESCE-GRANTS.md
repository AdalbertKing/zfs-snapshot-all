# REV-20260802-028 — remediation must not rewrite unrelated quiesce grants

Status: **CHANGES REQUIRED**

## Finding

Commit `0d48103` correctly changed the remediation command from the missing quiesce datasets to the full dataset set derived from the block being migrated. That prevents revoking grants already needed by the same block.

It still does not prove that the printed command preserves the host's complete existing whitelist.

`deploy.sh --backup-user=NAME --datasets="..." --allow-quiesce` rewrites `/etc/zfs-quiesce-allow/NAME` wholesale. `CAP_ALL` is derived only from the proposed managed block. Therefore a host can have:

- quiesce grants used by another config, manual job, recovery job, or older deployment;
- none of those datasets present in the block being migrated;
- a single missing dataset in the proposed block.

Following the printed remediation command removes every unrelated existing grant while appearing to be the safe, generated fix.

Changing `GAPS` to `FULL SET OF THIS BLOCK` fixes the observed case, but not the destructive update primitive.

## Required direction

Before printing a command that rewrites the whitelist, either:

1. read the current whitelist and print the union of **existing entries + all required entries**, with preview; or preferably
2. add an explicit additive operation, e.g. `--add-quiesce-datasets`, whose contract is merge-only and idempotent.

Fail closed if the existing whitelist cannot be read or parsed. Do not infer that entries absent from the current rendered block are obsolete.

Add a regression test:

```text
existing whitelist: tank/vm-900-disk-0
proposed block:     tank/vm-100-disk-0, tank/vm-102-disk-0
missing grant:      tank/vm-102-disk-0
```

After applying the generated remediation, all three entries must remain. The test should exercise the actual deploy/update path, not only inspect printed text.

## UX assessment

The single ordered remediation block and the second capability check are good transitional safeguards. Keeping privileged grant changes separate is acceptable for now. However the generated command must be safe to paste without requiring the administrator to understand that `--allow-quiesce` is replacement rather than additive.
