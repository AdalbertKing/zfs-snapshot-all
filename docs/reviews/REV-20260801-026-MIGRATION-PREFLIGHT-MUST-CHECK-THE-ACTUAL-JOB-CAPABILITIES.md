# REV-20260801-026 — migration preflight must check the actual job capabilities

**Status:** CHANGES REQUIRED

The comma-list fix in `7983147` is correct, and the corrected local-quiesce advice is necessary. The same live pve2 preflight exposes a broader fail-open problem: `config_datasets()` and `target_can_zfs()` do not model what the generated jobs actually do.

## F1 — pull/receive jobs can pass preflight without receive/create/rollback/bookmark

`target_can_zfs()` currently requires only:

```
snapshot destroy hold release mount
```

But `deploy.sh` documents the delegated account contract as:

```
snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark
```

A `[dataset:]` section can generate `snapget.sh` pull jobs writing locally. An existing account with only the five probed permissions passes `migrate-to-account --preflight`, then the moved cron can fail on receive/create/rollback or lose bookmark-backed continuation.

The preflight must derive required capabilities from the rendered job/config, not check one fixed subset. At minimum:

- local snapshot/send: snapshot, send, hold, release, bookmark as applicable;
- local receive target: receive, create, rollback, mount/canmount as applicable;
- snapshot prune: destroy;
- bookmark prune: bookmark and destroy as required by the actual command.

A migration must refuse before touching either crontab when any capability used by any resulting line is absent.

## F2 — `[prune-bookmarks:]` is explicitly excluded from delegation checks

The new test pins this exclusion as intentional:

> prune-bookmarks is deliberately NOT a source of delegation checks today

That is unsafe for account migration. If the scope is local, the resulting bookmark-prune cron line moves from root to the delegated account but its dataset and required permissions are never checked. The first evidence may be a failed scheduled prune after migration.

Remote bookmark scopes may need SSH capability rather than local ZFS delegation; that distinction should be derived from the scope. Excluding the whole section type is not fail-closed.

## F3 — operator advice still requires manual reconstruction

The preflight now prints:

```
deploy.sh --backup-user=<acct> --datasets="..."
```

The tool has already parsed the exact dataset set. Printing `"..."` forces the general administrator to copy, deduplicate and understand internal section semantics—the task the preflight just performed.

Print the exact safe command, or preferably let the high-level migration prepare the missing delegation after one explicit confirmation. The standard workflow must not require rebuilding `--datasets` by hand.

## Acceptance

1. A config with a local pull target fails preflight when `receive` or `create` is absent.
2. A config using bookmark-backed transfer fails when `bookmark` is absent.
3. A local `[prune-bookmarks:]` section is included in capability checks and fails when its required permission is absent.
4. A remote `[prune-bookmarks:]` scope is not incorrectly treated as a local dataset.
5. The corrective command contains the exact derived dataset list—no placeholder.
6. Tests prove each refusal against the pre-fix tree and prove that no crontab/config is changed.

The product-level rule remains: the administrator selects the relationship and account; the package determines the permissions and datasets required by the accepted config.