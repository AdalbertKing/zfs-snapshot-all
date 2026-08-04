# REV-20260802-031 — remote rollback must not report success when its survivor ledger cannot be created

## Finding

REV-030's cleanup contract is correct, but the remote `abandon_set()` has one fail-open reporting path.

It does:

```sh
left=$(mktemp) || left=""
...
if destroy_one "$s"; then
    ...
else
    [ -n "$left" ] && echo "$s" >> "$left"
fi
...
if [ -n "$left" ] && [ -s "$left" ]; then
    rc=7
    ...
else
    echo "QLOG nothing committed -- every snapshot this run created has been removed"
fi
```

If the second `mktemp` fails and any `zfs destroy` also fails, the survivor cannot be recorded. The function then prints **nothing committed** and returns the original clean-rollback exit code, although an ordinary snapshot from an incomplete set remains and downstream code will consume it.

This violates the exact three-outcome contract introduced by REV-030:

1. complete set;
2. no snapshot committed;
3. rollback incomplete, survivors named, hard alarm.

## Required

Fail closed when the survivor ledger cannot be created. Prefer removing the second temporary file entirely: keep a failure flag and print each failed snapshot immediately while reading `created_file`. If a structured survivor list is retained, failure to create or write it must itself force exit 7 and must never permit the `nothing committed` message.

Also handle write failure to the ledger, not only `mktemp` failure.

## Regression test

Inject failure of the survivor-ledger `mktemp` together with failure of one cleanup `zfs destroy` and assert:

- exit 7;
- no `nothing committed` claim;
- the surviving snapshot name and manual removal command are printed;
- thaw/on-exit still runs.

This is remote-path-specific; the local array ledger does not have this failure mode.
