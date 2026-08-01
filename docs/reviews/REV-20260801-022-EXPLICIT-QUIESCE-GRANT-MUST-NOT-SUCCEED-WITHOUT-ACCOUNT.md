# REV-20260801-022 — explicit local quiesce grant must not succeed without an account

**Status:** CHANGES REQUIRED  
**Scope:** `deploy.sh --allow-quiesce` local-account path, commit `3831509`

## Accepted progress

1. REV-021 is addressed correctly: migration refuses a pre-existing target managed block, install paths reject deletion of existing target jobs, preview diffs the real target crontab against the exact post-install state, and only recognised host-level jobs are retained.
2. The live happy-path and injected-failure migration tests materially reduce risk; rollback now reports the state it actually restored.
3. Adding a provisioning route for the host's own delegated account is the correct ownership boundary: the privileged grant remains in `deploy.sh`, not in `migrate-to-account`.

## Finding F1 — explicit grant request exits successfully when nothing was granted

Current behaviour when no delegated account is detected:

```text
bash deploy.sh --allow-quiesce
...
WARNING: --allow-quiesce had nobody to grant to ... Nothing was installed.
exit 0
```

This is not fail-closed for an explicit privilege-provisioning operation. A human may notice the warning, but a runbook, wrapper or later high-level deploy command sees success and may continue to `migrate-to-account`, where the missing capability is discovered only in a later step.

The command already rejects `--allow-quiesce --check-only` and `--allow-quiesce --pair` with exit 2 because they cannot install a grant. The same rule should apply after runtime account discovery: if `--allow-quiesce` was explicitly requested and there is no account to receive it, terminate non-zero.

### Required behaviour

Either:

```text
FATAL: --allow-quiesce requested, but no delegated account exists.
Create/select it with --backup-user=<name> (and --datasets="...") or omit --allow-quiesce.
exit != 0
```

or make the high-level operation create/select the account unambiguously in the same invocation. A warning plus exit 0 is not sufficient.

### Regression test

Run the real argument/runtime path with no detectable delegated account and assert:

- non-zero exit;
- message names the missing account and the exact corrective command shape;
- no grant, sudoers rule or whitelist is created;
- a bare deploy without `--allow-quiesce` still skips normally and exits 0.

## Product-level note

The new flag removes a missing capability, but the simplified deployment is still a multi-command workflow: preflight names separate `deploy.sh` invocations for ZFS delegation and quiesce, then the administrator reruns `migrate-to-account`. That is acceptable as an implementation boundary, but not yet the final operator UX. The eventual high-level deploy/migration command should orchestrate these prerequisites or emit one ordered, copy-pasteable remediation block and re-check them before commit.
