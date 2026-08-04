# REV-20260804-044 — Final A–J verdict

**Verdict: ACCEPTED**

## Scope reviewed

Independent review of the current `main` through commit `5d92677f09df203dd5d84e643453507de0e205e2`, including:

- `docs/reviews/responses/REV-20260804-037.md` and the live Gates A–J ledger;
- responses to REV-039, REV-040, REV-041, REV-042 and REV-043;
- production changes through `3a89892`;
- test changes and the reported live evidence for Gates G and I;
- teardown and residue evidence.

Implementer statements were checked against the committed diffs, regression tests and the internally consistent live evidence. No new production defect was found in the final delta.

## REV-037 F1

**CLOSED.** The remote draft/editor/check boundary remains fail-closed. No later change reintroduced the false-success path.

## Gates A–J

| Gate | Reviewer status |
|---|---|
| A — clean baseline | PASS |
| B — enrolment / retry | PASS |
| C — committed scope / hash | PASS |
| D — scope import / generated config | PASS |
| E — structural parent with enabled children | PASS |
| F — seed and real incremental | PASS |
| G — real route relocation | PASS |
| H — activation idempotence and pause refusal | PASS |
| I — sync on a genuinely independent, non-clustered host | PASS |
| J — secure teardown and residue check | PASS |

## Closure of REV-043

The first Gate G fix used `HostKeyAlias` as a client-wide identity and could hide deletion of one of several jobs belonging to the same client. Commit `3a89892` correctly narrows the exception to endpoint-only changes by normalizing only the mutable host inside the pull job's `-A "account@host:path"` argument while preserving the rest of the cron line as strict job identity.

The regression coverage directly exercises the review counterexample:

- one job, endpoint-only change: allowed;
- two jobs for one client, one disappears: refused;
- two jobs, both retained through endpoint change: allowed;
- source dataset changes with endpoint: refused;
- another client's job disappears: refused;
- unrecognized/local lines remain fail-closed.

`test/zfsbackup` is reported at **263/263**, including a negative control against the earlier defective implementation. Gate G was then re-run live under the corrected guard and completed with a real incremental over the new route.

**REV-043: CLOSED.**

## Gate I evidence

The initial privileged-LXC attempt was correctly rejected as insufficient because source and destination shared the same kernel and ZFS namespace. The replacement test used a real KVM guest with its own kernel and independent `testsync` pool, paired against a separately created same-named pool on the collector with a different pool GUID. Seed, activation, subsequent data change and transfer were exercised, followed by full teardown.

The live campaign also exposed and fixed the sync-mode pairing defect where an empty `PEER_TARGET` produced an invalid `/<label>` pre-create path (`d58e847`).

**Gate I: PASS.**

## Teardown and residual risk

The committed evidence records:

- peer-side `--leave` using the durably bound UID;
- collector-side `remove-client` completion;
- scratch datasets, temporary pools, VM/LXC lab guests and ephemeral networking removed;
- crontabs restored byte-for-byte to their pre-campaign checksums;
- no residual peer manifests;
- delegated production datasets unchanged;
- audit clean after teardown.

The temporary UID collision encountered in the first privileged-LXC attempt is disclosed as a test-environment incident, was removed immediately, and did not leave persistent authorization changes. It does not create an open production-code finding, but privileged-LXC ZFS tests should continue to reserve a non-overlapping UID range before account creation.

## Final decision

All findings from REV-037 through REV-043 are closed. Gates A–J have complete acceptance evidence. There are no remaining release-blocking technical findings in this review campaign.

**ACCEPTED.**

No implementer response is required unless later commits change the reviewed behavior or invalidate the recorded evidence.
