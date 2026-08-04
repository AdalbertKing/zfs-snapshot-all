# REV-20260801-019 — dedicated-account migration guard still keys on config path

Status: **CHANGES REQUIRED**

The new live pass found and fixed several real defects in the delegated-account path (account checkout, preview/install parity, config modes, pinned known_hosts ownership, and remove-client loading server state). Those fixes are valuable and the fail-closed guards prevented production damage.

However, REV-018 is not closed.

`assert_no_foreign_managed_block()` still decides whether root and the dedicated account represent the same workload by comparing only the normalized `# Source:` config path:

```bash
[ "$(normalize_cron_source "$raw")" = "$(normalize_cron_source "$file")" ] || return 0
```

The normal migration shape explicitly changes that path because the delegated account cannot read a config under `/root`:

```text
root:      /root/scripts/jobs.pve1.v4.conf
zfsbackup: /etc/zfs-snapshot-all/jobs.pve1.v4.conf
```

If the second file is a copy or generated replacement describing the same datasets/jobs, the guard returns success and permits installing a duplicate managed block while root's block remains active. The test currently asserts that a different path is unrelated, which encodes the unsafe assumption rather than testing workload identity.

## Required direction

Prefer one high-level transactional verb for `root -> dedicated account` migration. Before changing either crontab it should:

1. render the current root managed block and the proposed account block;
2. identify overlap by stable client/job identity or normalized generated commands, not config pathname;
3. show one combined preview: remove root block + install account block;
4. commit both sides with rollback, leaving either the old root block or the new account block active, never both;
5. fail closed if either crontab cannot be read or if workload identity is ambiguous.

At minimum, add a regression test where root's source is `/root/a.conf`, the target source is `/etc/zfs-snapshot-all/b.conf`, and both generate the same dataset send/prune jobs. Installation must be refused unless performed through the explicit migration operation.

## Additional review note

The two consecutive commits needed to place `read_server_conf` in the intended function show that text-pattern patching can silently modify the wrong occurrence. Add a focused test proving `remove-client` targets the configured dedicated user's crontab and that `final-catchup` behavior is unchanged.

No production change requested.