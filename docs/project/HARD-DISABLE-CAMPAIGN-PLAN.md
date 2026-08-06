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

## Step 2 evidence — installing the gate (2026-08-06)

Commits `656eae0` (install + gated key line + 9 tests) and `0058834` (the
ownership fix the live check forced). Reviewer's instruction for this step
was join/negative tests plus a live residue/lockout check, no full campaign.

Stubbed: **pairgate 40/40**. Graph-selected suites for the deploy.sh change,
all green: alertmail 18, draftscope 26, join 82, joinmanifest 10, joinremote
8, pause 74, quiescehelper 119, selfupdate 28 (7 standing SKIPs). Contracts
flagged by the graph (account-paths, delegation-verbs, notify-markers,
ssh-flag-parity): none touched — no path, zfs verb, heredoc marker or ssh
flag changed.

**Live residue/lockout check** on metropolis pve2, on a throwaway account
whose `authorized_keys` started in the pre-gate shape: an operator key plus a
BARE relationship key, both working. Production pairing was deliberately not
involved.

| Check | Result |
|---|---|
| migration | the bare relationship line became the gated line; the operator's line survived byte for byte; no `.new` residue |
| **lockout (first run)** | **both keys refused** — the atomic replace had left the file root:root and sshd's StrictModes refuses that. Cause confirmed in `auth.log` and by restoring ownership, not guessed |
| lockout (after `0058834`) | ownership preserved (`gatetest-c:gatetest-c`, 0600); operator key logs in; relationship key runs through the gate |
| disable after migration | `zfs list` over the relationship key refused with `PAIR_DISABLED` |
| blast radius of a disable | the operator's key on the SAME account still logs in — a disable stops a relationship, not an account |
| teardown | account, keys, state dir and the installed gate removed; `audit clean` on both hosts |

The lockout was real and would have hit production: `do_join` repairs it a few
lines later with its own `chown -R`, so the join path was never broken, but
any other caller — starting with migrating relationships enrolled before the
gate existed — would have locked accounts out one at a time.

**No separate migration command was built, deliberately.** Every client record
on the only collector is `state=removed`, so there is nothing enrolled to
migrate; re-joining an old relationship migrates its key line in place, which
is exactly what the live check exercised. A `--migrate-gate` verb would be
speculative code with its own live-test cost and no current subject.

## Step 3 + full campaign — live evidence (2026-08-06, metropolis)

Two REAL relationships, both enrolled through the ordinary CLI, both gated
automatically by `--join`: **ca** ← pve2 (`hdd/campsrc`) and **cb** ← a
throwaway LXC peer with its own address (`hdd/campsrcb`) — one relationship
per host pair, so the second peer has to be its own machine.

| Test-plan item | Result |
|---|---|
| gate installed by enrolment | `--join` installed `/usr/local/sbin/zfs-pair-gate`, wrote `command="… pve1",restrict …` into the account's `authorized_keys`, and created the relationship's state dir — on both peers, with no manual step |
| disable ordering | local pause first, then the peer, then a read-back — observed in that order |
| **the point of the whole package** | with A disabled, a **hand-written `snapget` carrying no `-L` at all** was refused by the peer: `PAIR_DISABLED`. This is exactly what logical pause cannot do |
| A's own cron line | skipped at the collector (`SKIPPED: relationship ca is paused`) — the local half stops it before it ever reaches the link |
| A's monitor line | `OK -- relationship ca is paused … staleness is expected` — no page for a backup stopped on purpose |
| B throughout | pulled normally, `"status":"success"`, unaffected by A's state |
| endpoint change | an ephemeral second address on the peer (`192.168.28.208`, never written to any config) still answered `PAIR_DISABLED` — identity is the key, not the address |
| persistence | marker survived an `sshd` restart |
| peer unreachable mid-operation | happened for real (a DNS name resolving to a public address): `enable` reported `STATE unchanged: still disabled on the peer and paused locally. Safe to retry`, and the retry converged |
| enable + return | after enable, the exact cron line transferred again, `"status":"success"` |
| **no side effects** | config md5, account crontab md5 and the pairing key fingerprint **byte-identical from before the disable to after the enable** |
| teardown while disabled | `remove-client` worked with the relationship disabled, cleared its own marker, left no cron line |
| residue | both peers `--leave`d, LXC destroyed, ephemeral address removed, scratch datasets gone, `audit clean` on both hosts |

### Two defects the campaign found

1. **The state directory's ownership did not take on the first join** of a
   freshly created account, and `install_pair_gate` only warned — so
   enrolment finished looking complete while `enable` through the gate could
   never work. Surfaced as a `disable-client` that failed halfway, and the
   orchestration reported that correctly (`PAUSED_LOCAL, peer NOT disabled`,
   safe retry named). Fixed in `8f6f8c2`: the result is verified, and the
   warning now says precisely what is lost and how to fix it. Deliberately
   not fatal — the account and key already exist by then, and the security
   property still holds.

2. **`verify-endpoint` read a deliberate refusal as a dead address.** Its
   probe is a data-plane command, so a disabled relationship refuses it, and
   the tool then blamed the endpoint — sending the operator to hunt a network
   fault that does not exist. Same rule as the ssh-exit-255 discrimination
   elsewhere in this estate: never blame the link for an answer the far end
   gave on purpose. Fixed with a distinct message naming `enable-client` as
   the remedy, pinned by a source test.

### Process note

The campaign's first attempt failed on a stale manifest from the REV-045
lab: `remove-client` prints the peer-side commands and does not run them, and
I had not run them. The collision guard refused the new join, correctly. The
lesson is about teardown discipline, not the tool — but it is worth knowing
that a collector-side removal leaves the peer holding state until someone
runs `--leave` there.

## Constraints carried from ADR-0012

No cron rewriting, no key deletion as a switch, no `zfs allow`/`unallow`
cycling, no account recreation, no identity inferred from address or
`HostKeyAlias`. Cron, grants and key material stay byte-identical across
disable/enable — asserted, not assumed.

## Environmental note

One relationship per host pair (recorded live in the REV-045 response), so
the live checkpoints build relationship B on a throwaway LXC peer with its
own address — the Gate G / REV-045 slice-4 pattern.
