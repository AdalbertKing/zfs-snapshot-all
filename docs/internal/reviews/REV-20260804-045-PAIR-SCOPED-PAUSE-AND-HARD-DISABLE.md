# REV-20260804-045 — Pair-scoped pause and hard-disable contract

## Context

The completed A–J campaign established a working global host pause (`deploy.sh --pause/--resume`) and a stable cron ownership model. The next requested capability is narrower: pause exactly one collector↔peer relationship without touching the rest of the host, without regenerating cron, and without revoking ZFS delegation as a routine operational toggle.

This is a feature-design request, not a finding against the accepted A–J campaign.

## Product outcome

Add a relationship-scoped control with two clearly separated semantics:

1. **Logical pause** — managed jobs for one relationship do not start, while all other relationships on the same host continue normally.
2. **Hard disable** — the relationship’s data-plane SSH access is refused even for a manually invoked `snapget.sh`/`snapsend.sh`, while a narrow management path remains available to query and resume the relationship.

Do not call either operation `zfs allow`/`zfs unallow`. Those names already mean persistent ZFS delegation and would blur pause with enrolment/teardown. Suggested public verbs:

```text
zfs-backup.sh pause-client LABEL
zfs-backup.sh resume-client LABEL
zfs-backup.sh disable-pair LABEL
zfs-backup.sh enable-pair LABEL
zfs-backup.sh status LABEL
```

A smaller implementation may initially expose only `pause-client`/`resume-client`, but it must document that local pause alone is bypassable by an ad-hoc command that omits relationship identity. Do not claim that manual transfers are blocked unless the peer-side SSH gate is implemented and tested.

## Design boundaries

### 1. Do not edit cron for pair pause

Cron remains installed and byte-identical. The generated transfer command carries an explicit stable relationship identity, for example:

```text
--pair-label LABEL
```

or a non-conflicting equivalent accepted by both `snapget.sh` and `snapsend.sh`.

At the earliest safe point — before snapshot creation, remote probing, holds, SSH, or stream setup — the script checks the relationship state. If logically paused, it exits without side effects.

Required result shape:

```text
SKIPPED: relationship LABEL is paused
```

Exit status may be zero for cron/noise control, but the status/monitoring layer must distinguish `SKIPPED_PAUSED` from a successful backup. A paused relationship must not be reported as a fresh successful backup, and expected staleness while paused must not produce ordinary failure noise.

### 2. Stable identity, never endpoint identity

Do not infer the relationship from IP address, SSH hostname, port, account alone, or `HostKeyAlias` alone. Endpoint relocation and multi-dataset clients already prove those are not sufficient identities.

The pause key is the durable relationship/client label already recorded by enrolment. All jobs belonging to that relationship, across all datasets and endpoint candidates, observe one state.

### 3. State storage

Use a separate operational-state file, not the immutable join manifest and not the generated cron config. Suggested shape:

```text
/var/lib/zfs-snapshot-all/relationships/LABEL/paused
/var/lib/zfs-snapshot-all/relationships/LABEL/disabled
```

Exact path may follow existing repository conventions. Requirements:

- atomic creation/removal;
- strict label validation;
- root-owned, non-world-writable;
- idempotent pause/resume and disable/enable;
- status exposes the state and timestamp/reason if recorded;
- teardown removes residual state only for the exact relationship;
- re-enrolment must not silently inherit an old disabled marker unless identity continuity is deliberately proven.

### 4. In-flight behavior

Pair pause/disable prevents **new** transfers from starting. It must not kill a transfer already in progress by default. Killing an active ZFS stream is a separate product behavior and must not be smuggled into this feature.

The command should report when an in-flight hold/process exists and clarify that the current run will finish while subsequent runs are blocked.

### 5. Do not use routine `zfs unallow` as pause

Do not revoke and re-grant dataset permissions on every pause/resume. Persistent ZFS delegation remains part of enrolment and teardown. Reusing it as an operational switch would re-open UID ownership, partial-revoke, legacy-manifest, and multi-dataset transaction risks already closed by REV-039/040.

### 6. Do not rewrite `authorized_keys` on every toggle

If hard disable is implemented, the toggle should create/remove a state marker read by a stable SSH gate. It should not repeatedly remove/reinsert the key line. That would re-open atomic file-update, wrong-key deletion, rotation, and partial-commit risks.

## Manual `snapget.sh` / `snapsend.sh`: required truth table

### Local logical pause only

- Managed cron command carrying `--pair-label LABEL`: blocked before SSH.
- Manual command carrying the same label: blocked.
- Raw manual command that omits the label: **not guaranteed to be blocked**.

Therefore local pause alone is an orchestration feature, not a security boundary.

### Hard disable with peer-side SSH gate

A stable per-relationship SSH gate must identify the key/account relationship and check the peer-side disabled state before executing the requested data-plane command. When disabled:

- cron-triggered `snapget.sh`/`snapsend.sh`: refused;
- manually invoked `snapget.sh`/`snapsend.sh`: refused even if the caller omits `--pair-label`, because the accepting peer identifies the relationship from the authenticated key/account;
- raw ad-hoc SSH using the relationship key: refused for data-plane commands;
- narrow control verbs required to query or resume remain available;
- unrelated relationship keys/accounts remain unaffected.

This answers the owner’s question directly: **yes, a manual snapget/snapsend must also fail under `disable-pair`, but only if the peer-side gate is implemented. A collector-local marker by itself cannot guarantee that.**

## SSH hard-disable guidance

Inspect the current managed `authorized_keys` and account execution path before choosing the hook. Prefer, in order:

1. extend an existing forced-command/wrapper path if one already exists;
2. otherwise add one stable, repository-owned forced-command wrapper during enrolment and leave the key line stable afterward;
3. avoid changing the account shell globally if that would affect unrelated keys or administrative access.

The wrapper must:

- bind to the authenticated relationship, not trust a caller-supplied label;
- validate `SSH_ORIGINAL_COMMAND` using an allowlist or the project’s existing command restrictions;
- check the disabled marker before any data-plane command;
- allow only the minimum management operations needed while disabled (`status`, `enable/resume`, and safe teardown as justified);
- fail closed on malformed or unknown commands;
- preserve existing source/dataset scope enforcement and must not broaden it;
- log relationship label, timestamp, decision, and command class without logging secrets.

Do not make `enable-pair` impossible by blocking the only control channel. Either provide a narrowly permitted resume verb through the same authenticated gate or require an explicit local-on-peer administrative command and document that UX honestly.

## Required command semantics

### `pause-client LABEL`

- validates that LABEL resolves to one existing relationship;
- atomically sets local logical-pause state;
- does not edit cron/config/grants/keys;
- idempotent;
- reports in-flight state without killing it.

### `resume-client LABEL`

- atomically clears only local logical-pause state;
- does not imply hard-enable if the peer is still disabled;
- idempotent;
- status must show the distinction.

### `disable-pair LABEL`

- first establishes local logical pause so no new local job races the remote disable;
- then establishes the peer-side hard-disable marker through a verified control transaction;
- reads back and verifies the peer state;
- reports partial state precisely if local pause committed but remote disable did not;
- safe retry converges without changing identity or keys;
- never revokes ZFS grants as part of routine disable.

### `enable-pair LABEL`

- clears and verifies the peer-side hard-disable state first;
- only then clears local logical pause, unless the operator explicitly requests “enable but remain paused”;
- safe retry and exact mixed-state diagnostics;
- does not regenerate cron.

Suggested state presentation:

```text
RUNNING
PAUSED_LOCAL
DISABLED_REMOTE
PAUSED_LOCAL+DISABLED_REMOTE
TRANSITION_INCOMPLETE
```

## Race and failure handling

Implementation must explicitly handle:

- cron starts concurrently with `pause-client`;
- pause happens between local precheck and first SSH connection;
- endpoint changes while paused/disabled;
- peer unreachable during disable/enable;
- process killed after local marker write but before remote commit;
- repeated pause/resume/disable/enable;
- relationship removed while paused;
- stale marker from a previously removed relationship label;
- multiple datasets/jobs under one relationship;
- multiple independent relationships on one collector and on one peer.

For the unavoidable race between local precheck and connection, the peer-side gate is authoritative for hard disable. A job that passed the local check just before disable must still be refused at the peer if it has not yet begun the allowed data-plane operation. An already-running accepted stream may finish unless a separate future “abort” feature is specified.

## Suggested automated tests

### Local state and CLI

1. pause creates exactly one validated marker atomically;
2. repeated pause is a no-op success;
3. resume removes exactly that marker;
4. repeated resume is a no-op success;
5. invalid/path-traversal labels refuse without filesystem mutation;
6. one paused client does not affect a second client;
7. all datasets/jobs of one client observe the same pause;
8. endpoint change does not bypass pause;
9. teardown removes only the target relationship state;
10. re-enrolment under a reused label fails closed or proves identity before consuming stale state.

### `snapget.sh` / `snapsend.sh` preflight

11. paused labeled invocation exits before any `zfs snapshot`, `zfs hold`, SSH, `mbuffer`, compressor, or receive process;
12. output/status is `SKIPPED_PAUSED`, not success/failure ambiguity;
13. unpaused invocation is byte-for-byte behavior-compatible after the precheck;
14. manual labeled invocation is blocked;
15. manual unlabeled invocation remains possible in logical-pause-only mode and is documented as such;
16. dry-run, seed, incremental, final catch-up, resume-token path, recursive and flat-recursive modes all honor the same gate;
17. local-only transfers define and test their behavior explicitly rather than accidentally inheriting remote semantics.

### SSH hard-disable gate

18. relationship key is accepted when enabled and the existing allowed command succeeds;
19. same key is authenticated but data-plane command is refused when disabled;
20. manual `snapget.sh`/`snapsend.sh` without a pair label is still refused by the peer gate;
21. unknown/malformed `SSH_ORIGINAL_COMMAND` fails closed;
22. control `status` works while disabled;
23. control `enable/resume` works while disabled or the documented local-peer recovery path works;
24. unrelated relationship key/account remains fully operational;
25. multiple keys for different relationships cannot address each other’s marker;
26. endpoint LAN/VPN switch cannot bypass disable;
27. key rotation preserves the exact disabled state and relationship binding;
28. legacy relationships without the wrapper fail closed for `disable-pair` with migration instructions; do not claim hard disable succeeded.

### Transaction and fault injection

29. local marker write failure leaves remote untouched;
30. peer unreachable after local pause reports a retryable mixed state;
31. remote marker publication failure is detected by read-back and does not clear local pause;
32. process killed at every commit boundary converges on retry;
33. enable clears remote first; failure before local clear leaves a safe paused state;
34. no toggle changes cron checksum, generated job config, ZFS grants, manifest identity, key fingerprint, or unrelated `authorized_keys` entries;
35. in-flight transfer continues, next transfer is blocked;
36. a transfer not yet accepted by the peer is refused after hard-disable commits.

## Required live tests

Use two relationships, not one, so isolation is proven.

1. Enrol clients A and B on the same collector.
2. Activate both; record cron/config/key/grant checksums and fingerprints.
3. Pause A locally; run A’s exact cron line manually — no SSH/data mutation; run B’s exact cron line — succeeds.
4. Resume A; incremental succeeds with correct data.
5. Hard-disable A; verify peer state read-back.
6. Run A’s exact cron line and a hand-written manual `snapget.sh`/`snapsend.sh` using A’s key but omitting the label — both refused before stream mutation.
7. Run B — succeeds unchanged.
8. Switch A’s endpoint candidate and prove disable still holds.
9. Enable A; incremental succeeds without key rotation, grant rewrite, cron regeneration, or full re-seed.
10. Start a long scratch transfer, disable during flight: current stream behavior matches the documented non-abort contract; next run is blocked.
11. Teardown both relationships; prove no pause/disable markers, no orphan keys/grants/holds, and baseline cron/config restored.

## Non-goals for this stage

- automatically power off the peer;
- firewall/VPN port knocking;
- killing active ZFS streams;
- expiring leases or one-shot access windows;
- replacing ZFS delegation with temporary grants;
- changing global host pause semantics.

A later “disappearing backup server” network feature may close firewall/VPN exposure outside a lease window, but that is a separate control-plane design. This review’s hard-disable means the relationship’s authenticated data plane is unavailable, not that the host stops answering at the network layer.

## Acceptance criteria

The implementation is acceptable when:

- pair-scoped pause does not alter cron or other relationships;
- `snapget.sh` and `snapsend.sh` check before side effects;
- logical pause and hard disable are named and reported distinctly;
- hard disable blocks manually invoked remote transfers independent of caller-supplied labels;
- resume remains possible through a deliberately narrow management path;
- no routine toggle changes `zfs allow`, relationship identity, or key material;
- all automated and live isolation/fault tests above pass;
- `PROJECT_STATUS.md` and operator documentation explain the bypass boundary of local pause and the stronger guarantee of hard disable.

## Response path

Implementer response:

```text
docs/internal/reviews/responses/REV-20260804-045.md
```

Before coding, the response should state which scope is being implemented:

- logical pause only; or
- logical pause plus peer-side hard disable.

If logical pause only is chosen, explicitly retain the documented limitation that an unlabeled manual command can bypass it. Do not silently market it as `unallow` or as a security boundary.
