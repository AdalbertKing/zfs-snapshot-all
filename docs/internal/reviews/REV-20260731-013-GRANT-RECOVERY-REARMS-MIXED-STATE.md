# REV-20260731-013 — recovery must not re-arm a mixed grant

**Status:** CHANGES REQUIRED  
**Reviewed commit:** `cda91de39c05494df2cb3159c41fc6d4030cf6cd`

## Accepted

REV-012's normal commit order is now correct:

1. disable the existing sudoers rule;
2. replace whitelist;
3. replace helper;
4. install the new rule last.

The live happy-path test is useful and confirms that the generated rule, permissions, delegation boundary, update and revoke work on a real host.

## Blocking problem: `_grant_sweep` re-enables the old rule over new artifacts

The crash-recovery path undoes the fail-closed property.

Consider an update that widens the whitelist:

```text
old: rpool/data/vm-106
new: rpool/data/vm-106 + rpool/data/vm-107
```

Crash after steps 1–2, before step 3 leaves:

```text
whitelist = new
helper    = new
rule      = absent
rule.zqg-bak = old active rule content
```

On the next run `_grant_sweep report` iterates the rule, sees `rule.zqg-bak` with no final `rule`, and immediately renames it back to the active dotless sudoers path.

At that instant the **old rule is active against the already committed new whitelist/helper**. The grant is widened before the new transaction has validated, staged or suspended anything. If that rerun then fails before reaching commit step 0, the widened mixed state remains active indefinitely.

This recreates the exact privilege-widening class that REV-012 was intended to close; it only moves it from the first run's commit path into the next run's recovery path.

## Required behaviour

An interrupted update whose sudoers rule is parked as `.zqg-bak` must remain **disabled** until a coherent state is chosen.

Prefer one of these simple fail-closed models:

1. **Rollback first, while still disabled:** restore old helper and old whitelist from their backups, then restore the old rule last; or
2. **Finish the new transaction while disabled:** leave the rule parked, validate/stage the requested state, and install a rule only after helper and whitelist are coherent.

Do not restore the rule independently merely because its destination is absent.

If automatic recovery cannot prove which helper/whitelist pair is coherent, stop with a clear message and leave the grant disabled. That is safer and simpler for the administrator than silently activating a mixed state.

## Required tests

Add a test that kills the update after each of these points:

- new whitelist committed;
- new whitelist and helper committed;
- immediately before new rule rename.

For each state, start a second enrolment and force it to fail **before commit step 0** (for example during staging or validation). Assert throughout that no active dotless sudoers rule can coexist with the widened whitelist until the second run completes successfully.

Also test interrupt → plain audit/status invocation, if either path calls the sweep. Read-only commands must not reactivate a parked grant.

## Reviewer decision

- REV-012 normal commit order: **accepted**.
- Live happy-path grant test: **accepted as useful evidence**.
- Crash recovery / next-run sweep: **CHANGES REQUIRED**.
- Remote quiesce should not become the default production profile until this is closed.
