# REV-20260804-041 — Last-client removal must not continue after config commit failure

- Reviewer: ChatGPT
- Reviewed repository head: `fef231454a452ac543e22fce2ae075016175f6e7`
- Reviewed production commit: `2780b8c61ca21eab7729104419dfd5ce47b5c78e`
- Status: **OPEN — CHANGES REQUIRED**
- Response required at: `docs/reviews/responses/REV-20260804-041.md`
- Scope: REV-20260804-039 F2, the new last-client branch in `zfs-backup.sh cmd_remove_client()`.

## Summary

The new branch correctly recognizes that `gen-cron.sh` must continue refusing an empty job set and that removing the last client therefore needs a direct `cron_block_remove` transaction. The chosen order — remove the live managed cron block before publishing a zero-job config — is defensible because it fails toward jobs being stopped rather than stale jobs continuing.

The implementation then breaks its own failure contract: if publishing the zero-job config fails after the cron block was removed, it only warns and continues into `deploy.sh --unpair`, marks the client `STATE=removed`, and prints success. The collector is left with no managed cron block, an old config that still describes the removed client, and a client record that now claims removal is complete. The warning says to repair the config before the next activation, but the function immediately destroys the local relationship state needed to perform a normal retry.

This is not a cosmetic reporting issue. It converts a recoverable partial commit into a falsely completed teardown.

## F1 — config publication failure is treated as success and teardown continues

- Severity: **P1**
- Blocking: **yes, for REV-039 F2 and Gate J**
- Status: **OPEN**

### Evidence

The last-client path performs:

```bash
cron_block_remove "$(cron_target_user)" zfs-backup-managed
...
if ! mv -f "$workfile" "$CRON_CONFIG"; then
    rm -f "$workfile"
    warn "the zfs-backup-managed cron block was removed, but $CRON_CONFIG could not be updated..."
fi
```

After that branch, execution continues unconditionally:

```bash
bash "$DEPLOY" --unpair --peer="$PEER_HOST" || die ...
...
echo "STATE=removed"
...
log "client '$name' removed locally"
```

Therefore a failed config commit produces all of these at once:

1. `zfs-backup-managed` is already absent from the crontab;
2. `$CRON_CONFIG` still contains the removed client's sections;
3. peer unpair instructions/state mutation proceed;
4. the client record is marked removed;
5. the command reports local removal as complete.

The operator cannot simply re-run `remove-client`, because the record now says `STATE=removed`. The implementation's own promise — "re-running remove-client is safe once this is resolved" — applies only to the earlier cron-removal failure, not to this later and equally real failure.

### Required outcome

The last-client transition needs one explicit partial-commit protocol. At minimum:

- A failed zero-job config publication must return non-zero immediately.
- It must not call `deploy.sh --unpair`.
- It must not mark the client removed.
- The client record must remain retryable and must record, or the diagnostic must precisely state, that the managed cron block is already absent and the config publication is pending.
- A retry must converge safely without requiring hand reconstruction of the removed cron body.

A stronger implementation may render and durably stage the zero-job config before removing cron, then atomically publish it after the cron commit. If final publication still fails, either restore the prior cron block from a verified pre-image or leave an explicit machine-readable partial state that a retry understands. Merely warning and continuing is not acceptable.

### Acceptance criteria

- [ ] Force the final config rename/publication to fail after a successful `cron_block_remove`.
- [ ] Command exits non-zero.
- [ ] `deploy.sh --unpair` is not called.
- [ ] Client record is not marked `STATE=removed`.
- [ ] The diagnostic names the exact mixed state: managed cron block absent, old config still present.
- [ ] Re-running after the publication problem is fixed completes successfully without manual cron reconstruction.
- [ ] A successful last-client removal still removes only `zfs-backup-managed`, preserves `zfs-backup-host` and foreign lines, publishes a config with zero managed sections, and then marks the client removed.
- [ ] Regression test fails against commit `2780b8c`.

## Required implementer response

Respond with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`, and include:

1. the exact transaction/recovery protocol for the cron-removed/config-not-published state;
2. the regression test that forces the final publication failure;
3. proof that unpair and `STATE=removed` are unreachable on that failure;
4. a live Gate J retry from a single-client collector, including crontab/config/client-record checks before and after.

Until this is resolved, REV-039 F2 remains **OPEN** and Gate J remains **FAILED/PARTIAL**, regardless of the happy-path implementation.