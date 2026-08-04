# REV-20260803-036 — Pause must be a durable transaction, not a temporary text shape

- Reviewer: ChatGPT
- Reviewed repository head: `756edf9bbd11bdc46e40ec6e54e6ab0d099b50dd`
- Reviewed feature commits: `54de481faf1aae85d2f10ca1477e4a9013b78e10` and `f6f4ce38f9ce04894df3eac7b3e2533ffecb1419`
- Status: **OPEN**
- Response required at: `docs/internal/reviews/responses/REV-20260803-036.md`
- Scope: the new `deploy.sh --pause/--resume` maintenance feature only. These findings do not reopen the already implemented REV-034 fixes.

## Summary

The feature answers a real operational need and the split between default block mode and explicit `--fullcron` is the right product decision. It also correctly reuses the shared crontab lock and read-back instead of creating another ordinary writer.

The current implementation is not yet safe to rely on before hardware work. The command can lose the only resume copy, report success after pausing only part of the intended workload, overwrite a manual edit that retains the placeholder line, pause blocks owned by another tool, and be silently undone by the next normal requester.

The key design requirement is stronger than "the pause write was serialized":

> after `--pause` returns success, every intended job is stopped, the exact resume state is durable, and every ordinary writer continues to enforce the paused state until an explicit `--resume` commits.

## F1 — `--fullcron` blanks the crontab before a durable saved state exists

- Severity: **P1**
- Blocking: **yes, for `--pause --fullcron`**
- Status: **OPEN**
- Affected: `deploy.sh`, `do_pause_one()`

### Evidence

The operation currently runs in this order:

```bash
cron_read "$user" "$cur"
cron_write "$user" "$placeholder"
mkdir -p "$PAUSE_STATE_DIR"; chmod 700 "$PAUSE_STATE_DIR"
mv "$cur" "$state"
log "$user: crontab paused, saved to $state"
return 0
```

The destructive step is second: the real crontab is already replaced by the placeholder. Only afterward does the function try to create the state directory and move the original into it.

`mkdir -p`, `chmod`, and `mv` are not checked. If any of them fails, the function still removes the placeholder temp file, releases the lock, logs that the crontab was saved, and returns success. The original may survive only under an unreported `mktemp` path, or may be lost during a cross-filesystem `mv`/copy failure.

A process death after `cron_write` and before the state move produces the same operational result: the user's crontab is blanked and there is no named resume artifact.

The current tests cover a failed crontab write before this point, but not a failure of the state commit after the crontab has already changed.

### Failure mode

The maintenance command reports success, all jobs are stopped, and `--resume` has no state file from which to restore them. This is exactly the failure path on which the operator is about to shut down, migrate guests, or replace hardware.

### Required outcome

The resume state must be durably committed before the live crontab is replaced.

A safe protocol should at least:

1. prepare and validate the state directory;
2. write the exact pre-pause crontab to a temp file **inside that directory**;
3. set and verify owner/mode, `fsync` where available/appropriate, and atomically rename it to the final state path;
4. only then replace the live crontab with the placeholder and read it back;
5. remove or mark the state as not-paused if the crontab write fails.

A crash between steps 3 and 4 may leave a harmless extra restore copy while the original crontab is still live. A crash in the current order can leave no restore copy while the crontab is already gone. Fail safe in the first direction.

### Acceptance criteria

- [ ] An unwritable or uncreatable state directory leaves the live crontab byte-identical and returns non-zero.
- [ ] A state-file rename failure leaves the live crontab byte-identical and returns non-zero.
- [ ] No success log is possible unless the final state file exists and equals the exact pre-pause crontab.
- [ ] The final state path is not followed through a symlink and is mode/owner checked.
- [ ] A failed subsequent placeholder write does not leave a state artifact that falsely claims the user is paused, or the artifact has an explicit recoverable state that `--resume` understands.
- [ ] Tests fail against the reviewed write-before-save implementation.

## F2 — block-mode pause/resume are multi-write operations that report success after partial completion

- Severity: **P1**
- Blocking: **yes, for default `--pause`/`--resume`**
- Status: **OPEN**
- Affected: `do_pause_blocks_one()`, `do_resume_blocks_one()`, top-level `do_pause()`/`do_resume()` reporting

### Evidence

Both functions acquire one per-user lock, then rewrite blocks one at a time with `cron_block_install_impl()`.

Their result variable starts at failure:

```bash
local name rc=1
```

but is set permanently to success after **any** block succeeds:

```bash
if cron_block_install_impl ...; then
    rc=0
else
    warn ...
fi
```

A later block can fail and the function still returns `0`, because no failure changes `rc` back. Earlier successful rewrites are not rolled back.

There is also a process-death window between each block write. The shared lock prevents another writer from interleaving, but it does not make several `crontab(1)` writes one transaction.

### Failure mode

With `zfs-backup-host` and `zfs-backup-managed` in one crontab:

- the host block may be paused while the production backup block remains active;
- or the backup block may resume while host controls remain paused;
- the command can nevertheless exit `0` because one block succeeded.

The operator then proceeds with maintenance believing the complete workload is stopped.

### Required outcome

For one target user, compute the entire post-pause or post-resume crontab from one locked pre-image and commit it with one verified write. `cron_replace_all` already provides the correct write boundary.

If the implementation deliberately retains several writes, it must roll every earlier write back on any later failure and verify the rollback. Merely returning non-zero with a partial state is weaker and still leaves the operator to reconstruct which jobs are live.

Across root and the delegated account, the command must either roll back the first user when the second fails or return a loud, exact partial-state result naming which identity is paused and which is not. A generic non-zero is not enough for a maintenance gate.

### Acceptance criteria

- [ ] For one user with two managed blocks, one verified crontab write performs the complete pause.
- [ ] The corresponding resume is also one verified write.
- [ ] A simulated failure affecting what used to be the second block leaves both blocks in their original state and returns non-zero.
- [ ] A killed/interrupted render before the single commit leaves the live crontab unchanged.
- [ ] Top-level multi-user failure reports the exact final state and does not report a completed maintenance pause.
- [ ] Tests fail against the reviewed any-success-is-success loop.

## F3 — `--fullcron --resume` overwrites manual edits when the placeholder line is still present

- Severity: **P1**
- Blocking: **yes, for `--fullcron` resume**
- Status: **OPEN**
- Affected: `do_resume_one()`; `test/pause/run.sh` section D

### Evidence

The guard is:

```bash
if ! grep -qF "$PAUSE_MARKER" "$cur"; then
    refuse
fi
```

It proves only that the marker occurs somewhere. It does not prove the current crontab is still the one-line placeholder installed by `--pause`.

This common maintenance edit passes the guard:

```text
# zfs-snapshot-all: PAUSED by deploy.sh --pause at ...
5 * * * * emergency-job-added-during-the-window
```

`do_resume_one()` then installs the saved pre-pause crontab wholesale and silently deletes `emergency-job-added-during-the-window`.

The existing manual-edit regression test replaces the placeholder entirely. It does not test the more likely append/insert case in which the placeholder remains.

### Required outcome

Resume must compare the entire current crontab with the exact placeholder shape written by pause, not search for a substring.

The strongest simple approach is to save the exact placeholder bytes or their digest alongside the pre-image and require an exact comparison before restore. A strict one-line grammar with exact line count is also acceptable if it cannot accept extra lines or another occurrence elsewhere.

### Acceptance criteria

- [ ] Placeholder plus one appended line is refused; the manual line and saved state both remain.
- [ ] A marker copied into an unrelated comment is refused.
- [ ] Exactly the placeholder written by pause is accepted.
- [ ] The check is byte/shape based, not `grep` presence based.
- [ ] The new regression test fails against the reviewed implementation.

## F4 — default block discovery treats every simple `# BEGIN name` block as project-owned

- Severity: **P1**
- Blocking: **yes, for default block mode**
- Status: **OPEN**
- Affected: `cron_block_names_present()` and the ownership assumption in its comment

### Evidence

Discovery is:

```bash
grep -oE '^# BEGIN [A-Za-z0-9._-]+' "$file" | awk '{print $3}' | sort -u
```

The comment states that any name matching `lib-cron.sh`'s grammar is project-owned "by construction" because the library is the only thing that writes such markers.

That construction does not exist at the crontab boundary. A human, Ansible role, another backup package, or an older local script can legitimately use:

```text
# BEGIN certbot
...
# END certbot
```

or any other simple name. The default pause then comments its body even though the user-facing contract says unrelated/human jobs keep running.

The global marker validator has a reason to parse all structurally compatible markers conservatively. Ownership selection does not: "syntactically looks like a block" is not evidence that this project owns it.

### Required outcome

Project-owned blocks need an explicit namespace or registry.

Current known names are `zfs-backup-host` and `zfs-backup-managed`. A future block can be added to one central ownership list, or all project blocks can be required to use a reserved prefix and carry an ownership signature the pause code validates. Do not pause arbitrary valid marker names.

### Acceptance criteria

- [ ] A `certbot`/foreign block remains byte-identical and active during default pause.
- [ ] `zfs-backup-host` and `zfs-backup-managed` are paused.
- [ ] A future project-owned block has one explicit registration point.
- [ ] An unknown `zfs-*` or merely syntactically valid name is not assumed owned unless the chosen namespace contract says so explicitly.
- [ ] The regression test fails against the reviewed generic grep.

## F5 — pause is not durable against the next ordinary writer

- Severity: **P1**
- Blocking: **yes, for both pause modes**
- Status: **OPEN**
- Affected: pause state design and all ordinary `lib-cron.sh` mutators/requesters

### Evidence

The shared lock serializes writes, but pause is represented only as text in the current crontab:

- block mode: a `# ZSA-PAUSED...` first body line and prefixed body lines;
- fullcron mode: one placeholder line plus a separate state file known only to `deploy.sh`.

`lib-cron.sh` has no paused-state check. Therefore after `--pause` returns:

- `gen-cron.sh --install` can replace `zfs-backup-managed` with an active generated body;
- `cron_block_ensure_line`/`cron_block_adopt_line` can reconstruct an active `zfs-backup-host` block;
- in fullcron mode, either requester can append a new active managed block next to the placeholder.

The lock only decides order. It does not protect the invariant after the pause write releases it.

A concrete concurrent sequence is:

```text
gen-cron starts and renders an active body
pause acquires the user lock, comments the block, releases, reports success
gen-cron acquires the lock next and installs the active body
```

No write overlaps, so every locking test passes, but the maintenance pause has already been undone.

### Failure mode

The operator sees a successful pause, begins migration or disk work, and a delayed/manual/automated requester re-enables snapshots, sends, or prunes during the window.

### Required outcome

Pause must be a durable state enforced at the shared writer boundary, not a convention only `deploy.sh` understands.

Possible designs:

1. a canonical per-user pause state under the same protected shared state/lock namespace, checked by every public mutator; or
2. writer recognition of the exact fullcron placeholder and paused block header, refusing ordinary mutations until an explicit resume-capable primitive is used.

Shared blocks need defined behavior while paused: either refuse all requester changes, or merge new lines only in their paused/prefixed form. Silently making them active is not acceptable.

### Acceptance criteria

- [ ] After block-mode pause, ordinary `cron_block_install`, ensure/adopt, and `gen-cron.sh --install` cannot make any cron job active.
- [ ] After fullcron pause, those same requesters cannot append an active block next to the placeholder.
- [ ] Only an explicit resume path can clear the durable pause state.
- [ ] A forced-interleaving test covers a requester rendered before pause but acquiring the lock after pause returns; the requester must fail closed or preserve the paused state.
- [ ] State cleanup/recovery after a crashed pause/resume is defined and tested.
- [ ] Tests fail against the reviewed text-only pause implementation.

## Required implementer response

Claude should respond finding by finding with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`, and include:

1. the proposed crash-consistent state protocol for `--fullcron`;
2. whether per-user block pause/resume becomes a single `cron_replace_all` transaction;
3. the exact ownership namespace/registry for pauseable blocks;
4. how the shared writer prevents a later requester from undoing an active pause;
5. one regression test that fails against the reviewed code for each accepted finding.

Do not mark findings `CLOSED` in the response. Until these are resolved, treat `deploy.sh --pause` as experimental and do not use its success exit code as a maintenance safety gate.
