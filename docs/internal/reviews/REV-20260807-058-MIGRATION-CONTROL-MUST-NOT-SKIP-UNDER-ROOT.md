# REV-20260807-058 — recursion migration control must not disappear under root

**Reviewed head:** `b5184368a87ace8ccbea60eff6ede666c6a24b00`

**Verdict:** **CHANGES REQUIRED**

**Severity:** **P2 — safety-contract gap in a destructive/config-mutating migration path**

**Response path:** `docs/internal/reviews/responses/REV-20260807-058.md`

## Finding F1

The live REV-057 migration on `192.168.11.11` exposed a real gap in the migration guarantee. The config is `root:root 0644`, so the only principal that can commit the migration is root. But `migrate_recursion()` reads only the **current user's** `zfs-backup-managed` crontab block:

```bash
me="$(id -un)"
raw="$(cron_block_read "$me" zfs-backup-managed 2>/dev/null || true)"
...
if [ -z "$raw" ]; then
    echo "  installed crontab block: none found -- skipping that control"
fi
```

On this fleet the managed block belongs to the delegated account, not root. Therefore the strongest REV-057 control — *prove the pre-migration config still renders exactly what is installed before mutating the config* — is unavailable in the only mode that can write the production config.

This violates the REV-057 acceptance intent: if the installed control cannot be made trustworthy, the migration must fail closed rather than silently degrade to a weaker proof.

The live migration itself did **not** produce a bad outcome: the before/after renders were identical, the crontab checksum remained unchanged, an earlier rehearsal had matched the installed block, and the operator re-verified the installed block afterwards. Those facts prove this specific migration succeeded. They do not make the shipped migration command safe by construction for the next config.

## Why this is not merely a documentation issue

`--migrate-recursion` is a config-mutating command. Its design explicitly added a three-way proof because a two-way "old render == new render" comparison can preserve pre-existing drift. The current root path reduces that design back to the weaker two-way proof while still committing the file.

That matters precisely during repair/recovery, when render-environment drift is plausible. A migration utility whose strongest guard disappears because the writable file and the scheduled crontab have different owners is not fail-closed.

## Required outcome

The migration must locate the authoritative installed block for the config being migrated, independent of the UID running the command, and must not silently skip that proof when an installed block is expected.

Use the existing `# Source: <config>` provenance as the binding key. The implementation may choose the smallest mechanism consistent with existing project state, but it must satisfy all of the following:

1. Running as root against a root-owned production config can find the managed block belonging to the delegated cron user when that block's canonical `# Source:` path names the config being migrated.
2. Exactly one matching authoritative block is accepted. Multiple matching blocks are an ambiguity and must refuse.
3. If a config is known/expected to be installed but no matching block can be found, migration refuses before writing anything. Do not print "skipping that control" and continue.
4. A block belonging to another config must never be used as the control.
5. The comparison remains control-first: current legacy render vs installed block must pass before the migrated file can be committed.
6. Failure to enumerate/read a candidate crontab is not silently treated as "no block" when that prevents proving the installed state.
7. No new operator knob such as `--as-user` unless the repository genuinely lacks enough durable state to resolve the owner automatically. Prefer existing relationship/config ownership metadata and `# Source:` over new input.
8. The migration still must not install or rewrite crontab; this change only makes the read-side proof authoritative.

## Required tests

Add deterministic coverage for at least:

- root runs migration; root crontab has no managed block; delegated account has the matching `# Source:` block -> control is found and must pass;
- same topology but delegated block differs from legacy render -> migration refuses and config checksum is unchanged;
- root and delegated account each contain a matching `# Source:` block -> refuse ambiguity;
- no matching block when the config is expected to be installed -> refuse before mutation;
- another config's block exists -> it is ignored, not used as proof;
- unreadable/enumeration failure -> fail closed when it prevents proving installed state;
- ordinary non-root migration with its own matching block remains supported;
- no-crontab/uninstalled fixture path, if intentionally supported, is explicit and distinguishable from "could not find the production block" rather than inferred from absence.

Run `test/migrate` on Linux as both root and the delegated account. Include a negative control showing the reviewed head `b5184368` takes the unsafe `skipping that control` path in the root/delegated topology.

## Live verification

After the fix, do **not** re-migrate the already-converted production config merely to create evidence. Instead use a byte-for-byte rollback copy or a disposable clone of the pre-migration config on `192.168.11.11` and prove that root now discovers the delegated account's installed block and performs the control before any write. The real production config and crontab must remain unchanged during this verification.

## REV-057 status

The actual fleet migration performed at `2026-08-07 14:42 CEST` is accepted as successful evidence for that one host, and the fleet no longer carries legacy recursion. However **REV-057 cannot be closed as a safe migration facility while F1 above remains open.**

Respond in `docs/internal/reviews/responses/REV-20260807-058.md` with implementation commit(s), diff summary, root + delegated Linux test results, negative control, and the non-mutating live verification described above.
