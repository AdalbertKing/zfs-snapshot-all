# REV-20260804-037 — Live two-host enrolment is the release gate, and the remote editor must fail closed

- Reviewer: ChatGPT
- Reviewed repository head: `e3f24c1b08f43d9b2bc3fc4f67506e3de0807ed0`
- Reviewed implementation range: REV-20260802-033 slices 1–10, including U9 and T3/U2/T5 follow-ups
- Status: **OPEN — CHANGES REQUIRED before the live pass can be accepted**
- Response required at: `docs/reviews/responses/REV-20260804-037.md`

## Stage verdict

The implementation phase of REV-20260802-033 is complete. The project is now in **live two-host acceptance**, not implementation-complete/release-ready.

The local and stub suites provide broad regression coverage, and multiple isolated ZFS/grant/pause paths have already been verified on live hosts. They do not prove the new cross-host workflow as one state machine. The release gate is therefore one clean relationship executed end to end, with negative gates and teardown, on scratch datasets.

Do not treat “the happy-path command exited zero” as acceptance. The evidence must prove:

1. no authority exists before the source-side approval step;
2. the collector consumes exactly the approved scope file;
3. seed is full once and subsequent transfers are incremental;
4. target paths and parent containers match the selected mode;
5. cron is absent before activation and correct after activation;
6. a route change with the same application endpoint requires no endpoint mutation;
7. every failed gate leaves a named, recoverable state;
8. teardown removes the relationship without damaging unrelated config, grants, keys, snapshots, or cron lines.

## F1 — remote scope editing runs after a failed draft and can report false success

- Severity: **P1**
- Blocking: **yes, before relying on `--join-remotely` in the live campaign**
- Status: **OPEN**
- Affected: `deploy.sh`, `do_pair()`, slice 9 remote editor command and final summary

### Evidence

The remote command is currently:

```bash
"./deploy.sh --draft-scope=$my_label 2>/dev/null; \
 ${VISUAL:-${EDITOR:-vi}} /etc/zfs-snapshot-all/peers/$my_label.scope"
```

The semicolon means the editor starts regardless of whether `--draft-scope` succeeded. `2>/dev/null` removes the only diagnostic that explains why the draft failed.

This is unsafe because `--draft-scope` deliberately refuses several states, including a missing/incompatible join manifest and an already-existing scope. If drafting fails because the file does not exist and the editor is then opened as root, the editor can create an empty or partial scope file. That file subsequently blocks a clean re-draft because the generator protects existing files from overwrite.

The state variable is also conflated:

```bash
remote_ok=1
```

is set immediately after remote `--join`, before the editor session. An editor failure only calls `warn`; the final output still says:

```text
Zakres zredagowany zdalnie (ssh -t).
```

Thus `remote_ok` means “join succeeded”, while the user-facing message treats it as “join and scope edit succeeded”. A failed editor does not select the manual fallback branch.

### Required outcome

Model the remote stage explicitly:

```text
package delivered
→ join succeeded
→ scope exists or draft succeeded
→ editor exited successfully
→ scope parser/check succeeded
```

Only the final state may be described as “scope edited and ready for local commit”.

A minimal safe remote command should:

1. preserve and display `--draft-scope` stderr;
2. draft only when the scope file is absent;
3. stop before the editor when the draft fails;
4. quote the scope path;
5. after the editor, run the non-granting parser/preflight (`--commit-scope-check=<label>` or an equivalent read-only check);
6. return non-zero when any stage fails;
7. keep separate `join_ok` and `scope_ok` state on the collector;
8. print recovery instructions matching the state actually reached:
   - delivery/join failed: manual package delivery/join;
   - join succeeded but scope stage failed: do not repeat join; show exact draft/edit/check commands on the peer;
   - scope valid: show only the local `--commit-scope` step.

Do not run `--commit-scope` remotely; that owner decision remains unchanged.

### Acceptance criteria

- [ ] Forced draft failure does not invoke the editor and does not create a scope file.
- [ ] Draft stderr reaches the operator.
- [ ] Existing valid scope opens without attempting destructive regeneration.
- [ ] Editor exit non-zero does not print “scope edited” and returns a non-successful stage result.
- [ ] Editor exit zero followed by parser failure does not print “ready for commit”.
- [ ] Join success + scope failure prints recovery beginning after join, not instructions to repeat the whole relationship.
- [ ] A successful session proves the final file passes `--commit-scope-check` before the collector calls it ready.
- [ ] Tests fail against the reviewed semicolon/`remote_ok` implementation.

### Required tests

Add an orchestration test with stubbed `scp`, `ssh`, and editor command. Unlike ZFS grant semantics, this is ordinary shell control flow and is exactly what a stub can prove.

Cover at least:

- scp failure;
- join failure;
- draft failure;
- existing scope;
- editor failure;
- post-editor parser failure;
- complete success;
- exact final guidance for each state.

## Live acceptance campaign

Claude is currently running tests on live servers. Continue autonomously, but use the following order and stop at the first violated invariant. Fix minimally, update the response, recreate a clean throwaway relationship, and repeat from the beginning when a state-machine defect could have contaminated later evidence.

### Safety boundaries

- Use unique scratch relation names, accounts and datasets.
- Do not select a production VM/CT disk for the new sync path.
- Do not enable a production schedule during the campaign.
- Capture existing crontabs, relevant ZFS delegations, manifests, keys and config hashes before the test.
- Every cleanup command must be scoped to the throwaway relation.
- `git status --porcelain` must be clean on both hosts after each test slice.
- Record exact host roles in every checkpoint: collector and peer/source. Do not use ambiguous `pve1/pve2` without the role.

### Gate A — clean pre-state

Record:

- current commit on both hosts;
- pool/dataset inventory relevant to the scratch test;
- absence of the relation name in both peer-state directories;
- absence of the proposed dedicated account/key;
- absence of target namespace;
- root and delegated-account crontab checksums;
- existing unrelated ZFS grants on the scratch parent.

A test whose pre-state is not clean is not evidence of first enrolment.

### Gate B — online relation creation and join

Run the high-level collector command with `--mode=backup` and `--join-remotely`.

Prove:

- host-key pinning is used by scp and both SSH sessions;
- package validation succeeds on the peer;
- the dedicated account and exactly one authorized key are created;
- **zero ZFS permissions** are granted at join time;
- no source dataset list exists in the package;
- the peer manifest records the remote origin;
- the scope file is generated from the peer’s actual inventory;
- the active defaults contain all intended non-system first-level roots and exclude pool roots/system roots;
- the complete inventory remains available as comments;
- F1’s scope-stage outcome is truthful.

Repeat the harmless/non-destructive part where supported and prove it does not duplicate accounts, keys or manifests.

### Gate C — approval boundary

Before `--commit-scope`:

- collector-side `seed`, config generation or activation must refuse because no committed-scope hash exists and no ZFS delegation exists;
- no target data and no cron jobs may appear.

Edit the scope to select a deliberately small scratch branch or one leaf dataset. Run the local peer-side preflight and `--commit-scope`.

Prove:

- the printed plan matches grants/revokes exactly;
- only selected real datasets receive the declared permission set;
- excluded siblings and unrelated manual grants remain untouched;
- manifest granted list matches reality;
- scope and `.scope.sha256` match byte-for-byte/hash;
- editing the scope after commit, without recommitting, makes collector fetch/seed fail closed on the hash mismatch.

Restore/recommit the intended file before proceeding.

### Gate D — collector import and config ownership

Have the collector fetch the committed scope.

Prove:

- exact scope bytes are copied/parsed; no second dataset-selection representation is introduced;
- resolved leaf list equals the peer’s real ZFS inventory under the approved roots;
- generated `[dataset:]` and `[prune:]` sections have the correct `managed-by` owner marker;
- an unrelated hand-written section survives byte-identical;
- no cron is installed before explicit activation;
- backup target root is namespaced by relationship/client as designed.

### Gate E — backup seed and structure

Use a scratch source tree containing:

```text
pool/test-parent
pool/test-parent/child-a
pool/test-parent/child-b
```

Select the parent with `include_parent=no`, `include_children=yes`.

After seed prove:

- only selected children have received streams;
- the skipped parent path exists on the collector only as a structural ancestor;
- structural ancestors have `canmount=noauto` and contain no source-parent snapshot stream;
- target mapping is exactly `<backup-target>/<client>/<source-path>`;
- one full transfer occurred;
- snapshot GUIDs establish the common base;
- no cron was installed by seed.

### Gate F — real incremental

Mutate the source after the seed, create data distinguishable from the seed, and run the next transfer/final catch-up.

Prove:

- the plan and actual transfer are incremental, not a second full send;
- the target contains the mutation;
- the common base survives;
- the amount transferred is consistent with the small mutation, not the full dataset;
- failure or interruption leaves a resumable/recoverable state and no orphaned permanent hold.

### Gate G — route/endpoint contract

For the routed-VPN model, keep the same peer `host:port` and change only the route where the available environment permits it.

Prove:

- `verify-endpoint` succeeds without `set-endpoint`;
- `ACTIVE_ENDPOINT` remains byte-identical;
- no new known-candidate entry is invented merely because the route changed;
- the pinned host identity remains the same;
- a final real incremental succeeds over the new route.

Separately exercise an actual changed application endpoint with a harmless alternate address/port where available:

- `set-endpoint --host=` changes only endpoint state;
- known candidate promotion/fallback works;
- no pairing, key or dataset scope is recreated.

Do not pretend a second LAN address is a WAN test; name exactly what was and was not proven.

### Gate H — activation and the single cron writer

Run activation only after the endpoint gate passes.

Prove:

- preflight says incremental;
- the diff shown to the operator matches the installed managed block;
- exactly one managed backup block exists;
- host updater/capacity/digest lines survive;
- unrelated cron lines survive byte-identical;
- repeated activation is idempotent;
- a paused crontab causes activation/writers to refuse rather than re-enable jobs;
- the client state becomes `active` only after the verified cron write.

Execute one scheduled-equivalent job manually as the actual cron owner and verify permissions, key paths, known-host alias and notifications/monitoring inputs.

### Gate I — sync contract on scratch data

Run only where the peer is not a member of the same PVE cluster as the collector and only on scratch datasets.

Prove:

- same-cluster enrolment refuses before creating relationship material;
- sync uses the identical source path on the collector, without a backup namespace;
- required pool exists; the tool does not create pools;
- a clean scratch target receives correctly;
- a target with no common snapshot refuses rather than silently full-overwriting;
- a target with `written@common > 0` refuses and preserves local writes;
- no unconditional `zfs receive -F` can roll back a live/diverged target;
- per-dataset non-recursive prune sections are generated as designed.

Do not test destructive sync semantics against a production guest disk.

### Gate J — teardown and residue audit

After capturing evidence, remove the throwaway relation through supported product commands.

Prove:

- managed config sections are removed and unrelated sections remain;
- managed cron changes converge without disturbing other requesters;
- dedicated keys/account/grants are removed or the product gives an explicit, documented peer-side teardown command;
- target snapshots/datasets are removed only when the operator explicitly requested data destruction;
- no scope/hash/package/temp files remain unintentionally;
- no in-flight holds remain;
- pre-test crontab checksums and unrelated ZFS grants still match.

Any residue that requires undocumented hand cleanup is a product finding, not merely test housekeeping.

## Evidence format

Maintain `docs/reviews/responses/REV-20260804-037.md` as the live test ledger.

For each gate record:

```text
status: PASS | FAIL | BLOCKED | NOT RUN
collector:
peer/source:
commit(s):
exact commands:
pre-state:
observed output:
post-state:
cleanup:
limitations:
```

Do not paste secrets, private keys or full authorized-key material. Fingerprints, hashes, dataset names and redacted command output are sufficient.

A failed gate must include the first failing invariant and the smallest proposed correction. Do not continue into later gates merely to collect more failures from a contaminated state.

## Implementer response required

Claude should:

1. respond to F1 with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`;
2. fix F1 and add shell-orchestration regression tests before counting the remote-join live run as valid;
3. execute Gates A–J autonomously where the available hosts safely permit them;
4. mark impossible environment-dependent gates `NOT RUN` with exact reason rather than simulating evidence;
5. update `PROJECT_STATUS.md` only when the live campaign reaches a stable checkpoint;
6. leave this review `OPEN` for the reviewer; do not self-close it.
