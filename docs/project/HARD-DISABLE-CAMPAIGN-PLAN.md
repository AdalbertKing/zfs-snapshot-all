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

### Follow-up decision forced by the live checkpoint (2026-08-06)

The checkpoint surfaced what "control through the same gate" actually costs.
The control verbs run **as the delegated account**, so `enable` can only work
if that account may remove its own marker — which means the relationship's
own key can lift its own block. Three ways out were put to the owner: a
separate admin key (gate-reachable control, backup key never able to
self-enable), self-enable by the backup key, or root-on-peer only.

**Owner chose self-enable by the backup key**, for the simpler operation.
Recorded consequence, which must not be quietly upgraded later:

> `DISABLED` stops every scheduled job, every manual command including one
> that omits `-L` entirely, and every accidental or automated re-run — and
> logs each lift to syslog. It is **not** a boundary against someone who
> holds the relationship key and deliberately lifts it. Making it that
> boundary needs the separate admin key, considered and declined here.

**Open point for the reviewer:** `ADR-0012` calls `DISABLED` a "peer-side
security gate", and REV-045's guidance sanctions "a narrowly permitted resume
verb through the same authenticated gate" — the shape built here. Those two
statements sit at different strengths, and the implementation matches the
second. If the ADR's wording is meant literally, the admin-key variant is the
change that satisfies it, and nothing else in the design moves.

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

## Step 1 evidence — the gate and its live security checkpoint (2026-08-06)

Commits `d4b0932` (gate + suite), `6914c11` (stderr fix), and this one.
Stubbed: **pairgate 25/25** (one SKIP on this dev box: a filesystem that
ignores 0555 for the owner), impact 21/21, graph `--verify` clean. The graph
selects only those two suites — nothing sources the gate yet, so the blast
radius really is that small; no campaign was run for that reason.

Live checkpoint on metropolis (test plan §C), run WITHOUT the enrolment
machinery on purpose: two throwaway accounts on pve2 with hand-written
`command="/usr/local/sbin/zfs-pair-gate <label>",restrict` key lines, a
scratch dataset with its own grants, and real pulls from pve1. That isolates
what the checkpoint is for — does sshd truly route a real key through the
gate — from enrolment code that does not exist yet.

| § | Observation |
|---|---|
| C1 | ACTIVE: `snapget` over the gated key completed, snapshot landed on the target, rc 0 |
| C2 | DISABLED: the same `snapget` refused, `PAIR_DISABLED`, and **the source snapshot count did not move (1 → 1)** — refused before any zfs command, not after |
| C4/C5 | a hand-written `snapget` with no `-L` at all, and a raw `ssh … zfs send`, both refused (rc 93) — the caller's own claims never entered the decision |
| C6 | relationship B on the same host transferred normally throughout |
| C7d | an interactive session on the relationship key refused (rc 91) |
| control | `PAIR-CONTROL status` answered while disabled, carrying the recorded reason |
| C11 | `authorized_keys` md5 and `zfs allow` output byte-identical before and after the whole cycle; 63 decisions in syslog with label, decision and a sanitised command class |
| resume | after enable, the next pull completed incrementally — no re-seed |
| teardown | accounts, keys, datasets, state dirs and the gate removed; zero residue; `audit clean` on both hosts |

Two real defects found by this checkpoint, both fixed forward with
regressions: the stderr leak (`6914c11` — it would have put "Permission
denied" into the alert mail of every transfer) and the enable path, which
failed against a root-owned state directory and produced the design question
answered above rather than a silent false "enabled".

## Constraints carried from ADR-0012

No cron rewriting, no key deletion as a switch, no `zfs allow`/`unallow`
cycling, no account recreation, no identity inferred from address or
`HostKeyAlias`. Cron, grants and key material stay byte-identical across
disable/enable — asserted, not assumed.

## Environmental note

One relationship per host pair (recorded live in the REV-045 response), so
the live checkpoints build relationship B on a throwaway LXC peer with its
own address — the Gate G / REV-045 slice-4 pattern.
