# REV-20260804-042 — Final verdict on Gates A–J, second round

**Verdict: CHANGES REQUIRED**

This is an independent final review of the implementation and evidence added after REV-20260804-039, including responses to REV-039, REV-040 and REV-041 and commits through `cf1f5e75b4e591f76a902a6d702b050da0d40a18`.

No new production-code defect was found in the reviewed REV-041 change. The fail-closed correction is structurally correct: a failed publication of the last-client config now terminates before `--unpair` and before `STATE=removed`; the added test forces the exact `mv` failure, proves that the deploy path is not invoked, proves the client record and old config remain unchanged, and proves a retry converges.

REV-040 is also closed. The relationship now carries a durable `PEER_JOIN_ACCOUNT_UID`; teardown uses only that bound UID, refuses on drift or unprovable legacy state, and the required live multi-principal tests demonstrate that a foreign live grant and a foreign orphaned UID are not revoked.

REV-039 F1 is accepted as closed by evidence. The existing retry path was exercised twice after deliberate SIGTERM during remote scope editing. It reused the same unconsumed key, reconfirmed the same fingerprint, left exactly one authorized key and completed the collector record on retry. The missing operator contract was corrected by documenting that exact-command retry is safe.

## Gate status

| Gate | Final reviewer status | Evidence / open point |
|---|---|---|
| A | PASS | Clean baseline and restoration checks recorded. |
| B | PASS | Interrupted remote enrolment and idempotent retry verified live twice; identity and key count remained stable. |
| C | PASS | Scope commit and mismatch behavior previously verified. |
| D | PASS | Scope/config import previously verified after collector-label correction. |
| E | PASS | Live parent-structural-only case: `include_parent=no`, children transferred, parent had no own snapshots. |
| F | PASS | Live seed and incremental completed after the three `snapget.sh` safety corrections; `test/snapsend` 202/202. |
| G | **NOT RUN** | No second route exists on the available host pair. Unit/local U9 coverage is not a substitute for the required live route change. |
| H | PASS | Live idempotent re-activation, pause refusal and exact resume restoration recorded. |
| I | **NOT RUN** | No mutually reachable non-clustered host pair was available. The attempted pair failed before state creation, which is useful fail-closed evidence but does not exercise sync. |
| J | PASS | Last-client removal, exact managed-cron removal, UID-bound grant revoke and clean teardown verified; REV-041 failure/retry path covered by a precise fault-injection test. |

## Blocking findings

### F1 — Gate G remains unverified

The campaign's acceptance matrix explicitly requires a real endpoint/routing relocation while preserving the configured endpoint contract. The available environment has only one route, so this behavior has not been demonstrated live.

**Acceptance criteria**

1. Provide two independently selectable network paths between the same test peer and collector, or an isolated network namespace/lab equivalent that exercises the real SSH/ZFS command path rather than stubbing the routing decision.
2. Complete enrolment and a successful transfer on path 1.
3. Move traffic to path 2 while preserving the endpoint identity required by the gate.
4. Prove the next incremental succeeds, no new relationship/key is created, and no stale route-specific state remains.
5. Record commands, timestamps, endpoint state before/after and transfer evidence in the live ledger.

### F2 — Gate I remains unverified

The required sync workflow on scratch datasets across a non-clustered pair was not run. The failed `ssh-keyscan` attempt proves clean refusal on an unreachable host, not the sync behavior itself.

**Acceptance criteria**

1. Use a mutually reachable pair that is demonstrably outside the same Proxmox cluster, or an isolated equivalent with real ZFS datasets on both sides.
2. Create disposable scratch datasets and record their initial GUID/snapshot state.
3. Complete sync enrolment and the intended initial synchronization.
4. Make controlled changes and complete a real subsequent synchronization.
5. Verify data, snapshot lineage, directionality safeguards, cluster guard behavior and clean teardown with no accounts, keys, grants, holds, cron entries or manifests remaining.

## Required next step

Do not change production code merely to satisfy this review. Provision or connect an appropriate test topology, execute Gates G and I, and append the raw evidence to the living ledger.

Respond in:

`docs/internal/reviews/responses/REV-20260804-042.md`

Once both gates pass, publish an updated final campaign statement. If either gate exposes a defect, fix it under a new focused response and re-run the affected gate plus its regression surface.
