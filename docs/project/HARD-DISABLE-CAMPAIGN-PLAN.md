# Hard Disable — Plan

Governing design: `docs/adr/ADR-0012-pair-pause-architecture.md`,
`docs/design/pair-pause.md`, `docs/testing/pair-pause-test-plan.md`.
Test scope is chosen by risk, per `docs/project/TEST-CAMPAIGN-POLICY.md`;
each choice is justified in one line rather than derived from a checklist.

Scope: REV-20260804-045 closed **logical pause** and is not reopened. This
package builds `DISABLED` — the peer-side gate that refuses a transfer even
when the caller omits every local hint.

## Owner decision recorded before coding

**Control channel while DISABLED: reachable through the same gate** (owner,
2026-08-06). ADR-0012 allows either this or a peer-local admin command; both
ends of every relationship here belong to one operator, and the alternative
forces VPN/physical access to the peer for every re-enable.

Consequence: the gate sorts commands into **data-plane** (refused while
disabled) and **control** (`status`, `enable`; permitted while disabled and
structurally unable to move data). The gate decides the class. The caller
never declares it.

## Steps and the test scope each one earns

**1. The gate itself** (`zfs-pair-gate`): identity from the key line's own
argv, disabled-check before `SSH_ORIGINAL_COMMAND` is parsed, two-class
allowlist, fail-closed on anything unrecognised, decision logging. The
refusal contract (`PAIR_DISABLED` + a stable exit code) lands in the same
commit — it has no consumers of its own, so a separate cycle for it would
buy nothing.

*Tests:* new stubbed suite + whatever `impact.sh` selects, then **a live run
of test-plan §C on scratch data**. This is the one early live checkpoint the
package needs: a gate that fails open looks exactly like a gate that works,
and once orchestration and status sit on top, that failure becomes a
three-layer debugging problem instead of a one-line one.

**2. Installing the gate** (enrolment + rewriting existing key lines).
Touches `authorized_keys` on a live peer, so the risk is residue and
lockout, not logic: atomic rewrite, read-back, everything outside the
managed line byte-identical, and the existing refusal of packaged
`command=` keys preserved.

*Tests:* join suite plus negatives, and one live proof that an ordinary
transfer still succeeds after the rewrite. Not a campaign — a residue check.

**3. Orchestration** (`disable-client` / `enable-client`): ADR ordering,
retry convergence after any partial failure, `TRANSITION_INCOMPLETE` visible
in status.

*Tests:* stubbed suite for the ordering and failure-injection cases, then
**the package's full live campaign** (test-plan §D and §E). This is where a
full campaign is worth its cost: it is the last planned touch of the
workflow, and everything below it is already proven.

**4. Docs and evidence.** Response file, design-doc status, PROJECT_STATUS.

Between steps 1-3 no full campaign runs: each step touches the same gate, so
a campaign in the middle would be re-run and re-paid for at the end.

## Constraints carried from ADR-0012

No cron rewriting, no key deletion as a switch, no `zfs allow`/`unallow`
cycling, no account recreation, no identity inferred from address or
`HostKeyAlias`. Cron, grants and key material stay byte-identical across
disable/enable — asserted, not assumed.

## Environmental note

One relationship per host pair (recorded live in the REV-045 response), so
the live checkpoints build relationship B on a throwaway LXC peer with its
own address — the Gate G / REV-045 slice-4 pattern.
