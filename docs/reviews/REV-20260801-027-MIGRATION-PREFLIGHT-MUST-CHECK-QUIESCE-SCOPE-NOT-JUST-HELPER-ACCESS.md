# REV-20260801-027 — migration preflight must verify quiesce scope, not just helper access

**Status:** CHANGES REQUIRED

## Finding

REV-026 correctly derives ZFS capabilities from the rendered jobs and prints an exact corrective dataset list. The quiesce preflight still uses a weaker, host-wide test:

```bash
if grep -qE '^[0-9*].* -q ' "$rootcron"; then
    if target_can_quiesce "$acct"; then
        _have "konto moze quiesce przez helpera"
    else
        _gap "... deploy.sh --backup-user=$acct --datasets=\"...\" --allow-quiesce"
    fi
fi
```

`target_can_quiesce` proves only that the account can invoke the helper. It does not prove that the helper whitelist covers every guest/dataset that the rendered `-q` jobs will touch.

A partial grant therefore passes preflight. The first uncovered VM is discovered only by cron, after migration, when `status <id>` or `freeze <id>` is refused. This is the same class of defect REV-026 fixed for ZFS delegation: the account has the mechanism, but not the capabilities required by the actual jobs.

The current corrective message also retains `--datasets="..."`, forcing the operator to reconstruct information the preflight already has.

## Required behavior

1. Derive the quiesce scope from the **rendered block**, not merely from the presence of any `-q` line.
2. For each local source dataset whose generated job requests quiesce, resolve the guest ID/type using the same mapping the runtime uses.
3. Verify that the delegated account can query and, where applicable, freeze/flush every resolved guest through the helper whitelist.
4. Distinguish cleanly:
   - no guest / stopped guest — acceptable;
   - local running guest covered by the grant — acceptable;
   - guest outside whitelist, unreadable status, missing helper/sudo — blocking gap;
   - remote quiesce — validate on the remote side or state explicitly which higher-level enrolment proof covers it.
5. Print one exact corrective command with the derived dataset list, for example:

```text
deploy.sh --backup-user=zfsbackup --datasets="rpool/data/vm-106-disk-0 hdd/vm-disks/vm-101-disk-0" --allow-quiesce
```

No placeholder should remain in a standard migration path.

## Regression test

Create a rendered block with two `-q auto` sources where the helper whitelist covers only one. `migrate-to-account --preflight` must fail and name only the uncovered dataset/guest. A grant covering both must pass. The test must exercise the real scope parser/helper query boundary rather than stub `target_can_quiesce` to a single success value.

## Product impact

This is blocking for the simplified deploy contract. An administrator must not need to know that "helper installed" and "all jobs covered by its whitelist" are different internal states. The high-level operation must prove the latter before moving the cron block.
