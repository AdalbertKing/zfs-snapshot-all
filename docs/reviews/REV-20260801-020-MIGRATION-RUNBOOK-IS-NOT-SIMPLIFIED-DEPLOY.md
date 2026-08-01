# REV-20260801-020 — Root → account: runbook is useful evidence, not the simplified deployment

**Status:** CHANGES REQUIRED  
**Scope:** `4f4271e`, `9b25842`, follow-up to REV-20260801-019

## Accepted

1. `9b25842` correctly adds `$HOME/cron.log` to the dedicated account's logrotate stanza and bumps the marker, so existing deployments can receive the correction. The regression test covers both account/root path parity and the marker update.
2. `docs/MIGRATION-ROOT-TO-ACCOUNT.md` is valuable as an engineering record. The three-way render A/B/C and the five measured capability gaps explain why changing only the crontab owner is unsafe.
3. Holding the live migration while REV-019 is open is the correct fail-closed decision.

## Finding 1 — this is still an expert-only manual migration

The documented procedure requires the administrator to understand and manually coordinate:

- extraction and normalisation of a managed cron block;
- the difference between root and account checkouts;
- placement and mode of the jobs config;
- `zfs allow` on every relevant parent dataset;
- `pair`/`join` and per-guest quiesce grants;
- the special digest line that is intentionally absent from the account render;
- removal and installation of two crontabs in the correct order;
- rollback of several independent resources.

That is a good diagnostic/runbook for the implementer, but it does not satisfy the product target. A competent general Linux/ZFS administrator should not need to know the internal flags, pair/join order, repository layout, normalisation rules or which lines belong outside the managed block.

**Required:** keep this document as design evidence, but do not present it as the operational answer. Implement one high-level command, e.g.:

```text
zfs-backup migrate-account --config <file> --to <user>
```

It should discover the current owner and live block, render A/B/C internally, provision/check all required capabilities, show one combined proposal, and perform one transactional identity switch. On any failed gate it must make no cron change.

## Finding 2 — the digest becomes an unmanaged orphan

The procedure says to remove the managed root block and re-add `alert-digest.sh` as an ordinary unmanaged root line because the account render intentionally omits it.

That splits one logical deployment across:

- an account-owned managed block; and
- a manually maintained root line outside the tool's ownership.

Consequences:

- `remove-client` or a later reverse migration cannot reliably know whether that line belongs to this deployment;
- repeated migrations can duplicate it;
- preview/rollback cannot truthfully show the whole change unless it also models the unmanaged root line;
- the administrator must remember a hidden exception indefinitely.

**Required:** make host-level jobs first-class managed state. Either maintain a separate tool-owned host block in root's crontab, or move the digest to a system service/timer owned independently of the client block. Migration must create/preserve/remove it idempotently and include it in the combined preview and rollback.

## Finding 3 — capability preparation and identity switch need separate guarantees

The ordering principle in the document is sound: provision capabilities while root still runs the jobs, then make the identity flip small. However, the current steps still rely on manual verification between independent commands.

The high-level command should have explicit phases:

1. **preflight/read-only:** A/B/C equivalence, config durability/readability, target checkout, ZFS delegation, quiesce grants, logging and host-level jobs;
2. **prepare:** create only missing target capabilities, without touching either production cron;
3. **preview:** show the combined removal from root and installation for the account, including host-level lines;
4. **commit:** switch ownership with no interval in which both job sets are active;
5. **verify/rollback:** verify the installed blocks as their actual users; on failure restore the exact prior crontabs and leave a loud failure.

Preparation may be resumable, but the identity switch must be atomic from the operator's perspective and fail closed.

## Decision

- `9b25842` logrotate correction: **ACCEPTED**.
- Migration preflight findings and HOLD: **ACCEPTED**.
- `docs/MIGRATION-ROOT-TO-ACCOUNT.md` as engineering/runbook documentation: **ACCEPTED**.
- Root → dedicated-account migration as a deploy workflow: **CHANGES REQUIRED**.
- REV-019 remains open; documentation alone does not close the path-keyed duplicate guard or provide the required transactional migration.
