# Hard Disable — Campaign Plan

Status: ACTIVE. Written before coding, as required by
`docs/project/TEST-CAMPAIGN-POLICY.md` §4.

Governing documents: `docs/adr/ADR-0012-pair-pause-architecture.md`,
`docs/design/pair-pause.md`, `docs/testing/pair-pause-test-plan.md`.

Scope boundary: REV-20260804-045 closed **logical pause** and is not reopened
by this package. This package builds `DISABLED` — the peer-side security
gate — as a separate functional package, per design doc §"Scope boundary".

## Owner decision recorded before coding

**Control channel while DISABLED: option A** — the narrow control verbs
(`status`, `enable`) remain reachable through the same authenticated gate
from the collector. ADR-0012 permits either this or a peer-local
administrative command; the owner chose the gate-reachable form on
2026-08-06, because both ends of every relationship in this estate belong to
the same operator and the alternative forces physical/VPN access to the peer
for every re-enable.

Consequence for the forced-command contract: the allowlist has two classes —
**data-plane** (refused while DISABLED) and **control** (permitted while
DISABLED, and never able to perform a transfer). Class membership is decided
by the gate, never by the caller's own claim.

## Checkpoint table (policy §4)

| Step | Category | Shared abstraction? | Tests after step | Full live now? |
|---|---|---|---|---|
| 0 — close test-plan A baseline gaps: A8 (marker survives restart), A11 (endpoint switch preserves pause identity) | A | no | owning suites (pairpause, zfsbackup), `impact.sh --verify` | no |
| 1 — refusal contract: `PAIR_DISABLED` reason + documented stable non-zero exit code, distinguishable from auth failure / unknown relationship / malformed command | A | no (definition, no consumers yet) | contract emitter test + distinguishability negatives | no |
| 2 — **forced-command gate** (`zfs-pair-gate`): relationship identity from the key line's own argv, DISABLED checked **before** parsing `SSH_ORIGINAL_COMMAND`, two-class allowlist, fail-closed on malformed, decision logging | **D** | yes — new security boundary | new stubbed suite + every `impact.sh` selection, **then the mandatory live security checkpoint = test plan §C (11 points) on scratch data, before any orchestration exists** | **yes — security checkpoint** |
| 3 — install the gate at enrolment + migrate existing key lines: atomic rewrite with read-back, rest of `authorized_keys` byte-identical, existing anti-smuggling refusal of packaged `command=` keys preserved | **D** (touches `authorized_keys`) | yes | join suite (line rendering, idempotence, migration), negatives; short live: an ordinary transfer still succeeds after the rewrite | mini-live |
| 4 — orchestration `disable-client` / `enable-client`: ADR ordering, retry convergence after every partial failure, `TRANSITION_INCOMPLETE` visible in status | **D** | no (consumes steps 2-3) | stubbed orchestration suite (test plan §D 1-10) + zfsbackup, **then the package's full live campaign (test plan §D and §E: two relationships, endpoint switch, restart persistence, teardown while disabled, zero residue)** | **yes — package checkpoint** |
| 5 — documentation: package response file, design-doc status, `PROJECT_STATUS.md`, full evidence record | A | no | `impact.sh` + `--verify` | no |

### Why the checkpoint sits at step 2 and not later

Policy §1D and §2 (exception) and §4 ("test that security boundary live
before adding higher-level enable/disable orchestration"): a refusal that
silently fails open is indistinguishable from a working gate once
orchestration, status output and retry logic sit on top of it. Steps 3-4
would then be debugging through three layers. The live §C checkpoint runs
against the gate alone.

### Last-touch rule (policy §2)

Steps 2, 3 and 4 each touch the gate, so no full live campaign runs between
them — only impacted suites plus the two mandated checkpoints (the §C
security checkpoint after step 2, the §D/§E package campaign after step 4).
Step 3's mini-live is not a campaign: it is the residue/regression proof that
rewriting a live `authorized_keys` did not break an ordinary transfer.

## Explicit non-solutions carried from ADR-0012

The package must not implement disable/enable by rewriting or commenting cron
lines, deleting or editing relationship keys as a daily switch, cycling
`zfs allow`/`unallow`, recreating accounts, or inferring identity from
address or `HostKeyAlias`. Cron, grants and key material stay byte-identical
across disable/enable cycles; this is asserted, not assumed.

## Reporting (policy §5)

Intermediate steps report only: commit, category, touched files/abstraction,
suites with PASS/FAIL, open risk, and whether the full campaign is deferred
and to which checkpoint. Full evidence is published at the step-2 security
checkpoint, the step-4 package campaign, and step 5.

## Known environmental constraint

One relationship per host pair (recorded live in the REV-045 response). The
live checkpoints therefore build the second relationship on a throwaway LXC
peer with its own address, the pattern used for Gate G and for the REV-045
slice-4 isolation test.
