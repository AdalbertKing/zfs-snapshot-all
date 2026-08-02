# REV-20260802-032 — ledger write failure must roll back or name the whole partial set

## Finding

`3d4c13f` correctly removes the second survivor tempfile and makes `abandon_set()` fail closed. The new ledger-write failure path is still incomplete:

```sh
zfs snapshot "${group[@]}"
for s in "${group[@]}"; do
    if ! echo "$s" >> "$created_file"; then
        echo "... $s ... remove by hand ..."
        exit 7
    fi
done
```

At the point an append fails, the **entire pool group has already been created**, and snapshots from earlier pools may also exist. Immediate `exit 7`:

1. does not call `abandon_set()`;
2. does not attempt to destroy any snapshot created earlier in this run;
3. names only the one snapshot whose append failed;
4. can leave earlier members of the same atomic pool snapshot, plus earlier pools, as ordinary-looking survivors not listed in the alarm.

Example: group contains `tank/a@t tank/b@t`; append of `tank/a@t` succeeds, append of `tank/b@t` fails. Both snapshots exist. The message names only `tank/b@t`; `tank/a@t` remains ledgered but cleanup is never invoked. If an earlier pool was already completed, its snapshots remain too.

This violates the REV-030 contract: complete set, clean rollback, or **a complete and exact list of every survivor**.

## Required correction

On any ledger append failure, do not exit directly. The path must account for the complete set created by this invocation.

Preferred simple contract:

- keep the current pool's confirmed `group` in memory;
- attempt rollback of all current-group snapshots plus every snapshot already recorded in `created_file`;
- exit with the original ledger error only if rollback is complete;
- otherwise exit 7 and name every survivor with an exact removal command.

An equivalent design is acceptable if it cannot under-report survivors. A pre-created in-memory/temporary manifest written **before** the ZFS operation is not sufficient evidence that the snapshots exist; cleanup must still distinguish confirmed creations from planned names.

## Regression test

Use one pool group containing at least two snapshots and make the second ledger append fail after `zfs snapshot` succeeds. Assert:

1. both snapshots were created by the stub;
2. both are then destroyed when cleanup succeeds;
3. an earlier-pool snapshot is also destroyed;
4. clean rollback does not leave any ordinary snapshot;
5. when destroy of one or more snapshots is injected to fail, exit is 7 and **every** survivor is named — including snapshots whose ledger append previously succeeded and snapshots from earlier pools;
6. thaw still runs.

The current test with one snapshot proves only that the directly failing name is reported; it cannot expose under-reporting of the rest of the set.

## Reviewer verdict

- Removal of the second survivor tempfile: accepted.
- Immediate survivor reporting in `abandon_set()`: accepted.
- Ledger-write failure handling: **changes required** — fail-closed exit code is correct, but the survivor inventory and rollback are incomplete.
