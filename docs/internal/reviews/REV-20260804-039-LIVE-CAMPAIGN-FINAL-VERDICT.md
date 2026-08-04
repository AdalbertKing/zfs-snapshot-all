# REV-20260804-039 — Live campaign final verdict: CHANGES REQUIRED

- Reviewer: ChatGPT
- Reviewed repository head: `d06f82fb250c645ea04857309a1ceea5d8614268`
- Reviewed campaign: `REV-20260804-037`, Gates A–J
- Status: **CHANGES REQUIRED**
- Response required at: `docs/internal/reviews/responses/REV-20260804-039.md`

## Verdict

The live two-host campaign was high-value and found eight real defects that the local suites had missed, including two fleet-wide incremental blockers in `snapget.sh`. The fixes for REV-037 F1 and REV-038 are credible and the manual backup flow reached seed, incremental, endpoint verification, activation and teardown.

The release gate is **not accepted yet**. The campaign itself records three unresolved lifecycle defects and four required acceptance scenarios that were not run. A campaign cannot be declared complete while its own required gates remain `PARTIAL` or `NOT RUN`.

## Closed from prior reviews

### REV-037 F1 — CLOSED

The remote scope stage now fails closed, preserves diagnostics, distinguishes draft/editor/check failures and only reports readiness after `--commit-scope-check`. The subsequent live failures in repository path handling were also fixed. The implementation and live evidence are sufficient to close F1.

### REV-038 — CLOSED

`do_join()` now commits its manifest through a temp file in the destination directory, validates the rendered fields, applies mode, atomically renames and verifies the final path. The campaign restarted Gate B after this fix and confirmed a complete manifest with no grants at join time.

## F1 — interrupted `--join-remotely` strands an asymmetric relationship

- Severity: **P1**
- Blocking: **yes, for the advertised online enrolment path**
- Status: **OPEN**

The campaign records that interrupting the interactive editor after remote `--join` leaves the peer with:

- the account;
- the authorized key;
- the committed peer manifest;

while the collector has no client record because `add-client` treats the terminated `deploy.sh --pair` as total failure.

This is not merely an editor-environment inconvenience. Process interruption, terminal loss and SSH disconnect are normal failure modes of an interactive online enrolment flow. The relationship must have a deterministic recovery path that does not require the operator to infer which half committed.

### Required outcome

Choose and implement one explicit state model:

1. write a collector-side pending relationship record before the remote mutation and advance it after each remote milestone; or
2. provide an idempotent `resume-enrolment NAME`/equivalent path that discovers the peer-side committed state, verifies fingerprint/account/manifest identity, and completes the missing collector record without rotation or duplicate keys.

A blind second `add-client` that happens to fall into rotation logic is not an acceptable recovery contract.

### Acceptance criteria

- [ ] Kill the process after remote join but before editor completion.
- [ ] Peer state remains valid and explicitly marked as pending/remote-joined.
- [ ] One documented recovery command completes the same relationship without adding a second key or rotating identity.
- [ ] Re-running the recovery is idempotent.
- [ ] A mismatched peer manifest/fingerprint refuses closed.

## F2 — removing the last client cannot commit an intentionally empty managed cron state

- Severity: **P1**
- Blocking: **yes, for lifecycle completeness**
- Status: **OPEN**

Gate J found that `remove-client` removes the last generated config section, then calls the normal generator. `gen-cron.sh` refuses a config with zero send/prune/monitor rules, so the live crontab remains unchanged and the command cannot complete teardown. The campaign had to restore the old crontab manually.

A collector with one client is a normal deployment, not an edge case. Removing that client must remove the project's managed job block while preserving host-level and foreign cron content.

### Required outcome

Add an explicit empty-managed-state transaction. Do not weaken `gen-cron.sh` globally into accepting accidental empty configs. `remove-client` should detect that no managed jobs remain and ask the shared cron writer to remove only `zfs-backup-managed`, with diff/read-back/rollback semantics.

### Acceptance criteria

- [ ] Removing the only client removes exactly the `zfs-backup-managed` block.
- [ ] `zfs-backup-host` and all foreign lines remain byte-identical.
- [ ] Client state/config removal occurs only after the cron transaction succeeds.
- [ ] A failed cron write restores the prior state and leaves the client record intact.
- [ ] Removing one of several clients still regenerates the remaining jobs normally.

## F3 — peer teardown can leave orphaned numeric-UID ZFS grants

- Severity: **P1**
- Blocking: **yes, for secure teardown**
- Status: **OPEN**

Gate J confirmed that deleting `zfsbackup-pve1` did not remove its `zfs allow` grants. The grant survived as `user (unknown: 1001)` until manually revoked by numeric UID.

This is a durable authorization residue. A later account reusing the UID may inherit access unexpectedly. Printing instructions that delete the account without first revoking the exact manifest-bounded grants is unsafe.

### Required outcome

Peer-side teardown must use the join manifest's `PEER_JOIN_GRANTED_DATASETS` as the bounded revoke set and revoke by the account's numeric UID before `userdel`. It must not enumerate or remove unrelated/manual grants outside that manifest.

### Acceptance criteria

- [ ] Capture account UID before deletion.
- [ ] Revoke the project's exact permission set from every manifest-recorded dataset using a form that still works if the account name disappears.
- [ ] Verify no grant for that UID remains on those datasets before `userdel`/manifest deletion.
- [ ] Preserve unrelated grants to other users and grants outside the manifest set.
- [ ] A held/in-flight dataset refuses teardown or reports a precise partial state; it is never silently skipped.
- [ ] Re-running teardown after partial completion is idempotent.

## F4 — required acceptance matrix is incomplete

- Severity: **P1 release gate**
- Blocking: **yes**
- Status: **OPEN**

The ledger marks the following required scenarios as not run:

- Gate B: complete `--join-remotely` path ended `PARTIAL`;
- Gate E: `include_parent=no` + `include_children=yes` with structural parent creation;
- Gate G: real route change preserving the same application endpoint;
- Gate H: live idempotent re-activation and paused-writer refusal;
- Gate I: sync contract on a non-clustered scratch pair.

These are not optional embellishments. They correspond directly to the owner decisions that motivated REV-033.

### Required outcome

Run the missing cases on scratch datasets and suitable hosts. If no physical second route/non-clustered pair is available, create an isolated network namespace/VM test fixture that preserves the real SSH/ZFS behavior. Do not substitute source-grep or stub evidence for these final live gates.

### Acceptance criteria

- [ ] Gate B fully passes without killing or manual fallback.
- [ ] Gate E proves excluded parent data is not transferred while children are, and destination structural parents have the intended properties.
- [ ] Gate G changes only routing while `host:port` remains unchanged; no endpoint mutation occurs and incremental still succeeds.
- [ ] Gate H re-activation is byte-idempotent; pause blocks activation through the shared writer.
- [ ] Gate I runs backup-safe sync only on scratch datasets between non-cluster peers, proving same-path mapping and refusal on a deliberately live/modified target.

## Additional review note — new `snapget.sh` fixes

The three live fixes around first seed, `written@` parsing and GUID/name mismatch are directionally correct and fixed real blockers. They changed a critical receive-safety boundary late in the campaign. Before release, run the complete root+real-ZFS suites named by the dependency graph, including at minimum `snapsend`, `remote`, `scenarios`, resume-token paths, GUID-renamed bases, zero and non-zero `written@`, first seed into a pre-created empty target, and an explicit divergence refusal. Record exact counts and host revision in the response.

## Gate status at this verdict

| Gate | Reviewer status |
|---|---|
| A | PASS |
| B | **PARTIAL / BLOCKED by F1** |
| C | PASS |
| D | PASS after live fix |
| E | **PARTIAL / required parent-child case not run** |
| F | PASS after critical live fixes |
| G | **PARTIAL / route-change case not run** |
| H | **PARTIAL / idempotence and pause case not run live** |
| I | **NOT RUN** |
| J | **FAILED as product flow; manual teardown used (F2/F3)** |

## Implementer response

Respond finding by finding with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`. For every accepted finding include:

1. implementation commit(s);
2. regression test that fails against `d06f82f`;
3. exact live rerun evidence;
4. updated A–J ledger;
5. cleanup proof.

Do not mark the campaign accepted yourself. The next reviewer pass will issue the release verdict.