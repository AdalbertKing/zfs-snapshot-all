# Handoff — Stage 3 landed, and one gap in the protocol itself

Implementer → reviewer, 2026-08-08. Short by design.

## 1. Where we are

Five REVs closed (065–069), **zero open threads**. Stage 2 is complete and its
integrated live campaign ran: **619 assertions, 0 failures** on metropolis pve1
at `4b30447`, results in `docs/testing/POST-STAGE2-CAMPAIGN-RESULTS-2026-08-08.md`.

Stage 3 — the engine freeze — landed as `75ab39d`. **Nothing routes it to you**,
which is §3 below.

## 2. What I would like a verdict on: `75ab39d`

Not a submission under a REV, because there is no REV. Four design decisions in
it are worth challenging, and I would rather you challenge them now than after
they harden:

**a. Scope.** Frozen: `snapsend.sh`, `snapget.sh`, `lib-zfs-snap.sh`. Not frozen:
`gen-cron.sh`, `deploy.sh`, `delsnaps.sh`, `check-snap-age.sh`, the test tree —
because that is where profiles, scope reconciliation and restore still have to
work. My reasoning: freezing those would freeze the roadmap, not the risk. If you
think `lib-cron.sh` or `zfs-pair-gate.sh` belong in scope, say so.

**b. "A closed review cannot authorise new work."** The refusal lifts only when
`unfreeze:` names a review that exists and is **not** CLOSED. I believe that is
right — a closed review was answered and the answer accepted — but it means an
authorised change must land *before* its review closes, which is a sequencing
constraint I am imposing on you as much as on me.

**c. It is not tamper-proof, and the document says so.** Anyone can run
`--refreeze`. What is removed is the *silent* case. If you want something
stronger, the honest options are a pre-commit hook (bypassable with `--no-verify`)
or CI — both outside what this package has ever carried.

**d. The negative control is weak and I am not dressing it up.** Six assertions
fail against `107a5be`, but the whole mechanism is new, so that shows the feature
did not exist — not that a specific rule changed. Weight sits on the positive
cases: an OPEN review authorises, a CLOSED one does not, an unfrozen file is
untouched.

## 3. A gap in Protocol V2 — delivered work with no REV is invisible

Under the owner's direct-main exception I implement first and you review what
lands. But the ledger and `OPEN-THREADS.md` are derived **from REV artifacts
only**. So right now the routing view says "nothing to do" while `75ab39d` sits
on `main` unreviewed. The same was true of Stages 2.1 and 2.2 until you happened
to look.

That is the failure class the owner objected to: coordination state that does not
describe reality.

**Proposal, deliberately small — no new tool, no new state machine.** A file
`docs/project/UNREVIEWED.md` with one machine header per delivery:

```
<!-- delivered: <sha> <one-line description> -->
```

`reviewctl` renders those as rows in `OPEN-THREADS.md` owned by the reviewer with
next action "review or open a REV", and the same commit-reachability rule already
applies to the SHA. You clear a row by opening a REV for it or by deleting the
line when it needs none. I write the line at delivery time; `impact.sh --verify`
can require that a commit touching a frozen or `project-status`-watched file
either names a REV or adds a delivered line.

If you would rather solve it differently — e.g. you simply open a REV per
delivery, including approvals — that is fine too and needs no code. What I want
to avoid is leaving it informal, because "he happened to look" has been the
mechanism twice.

## 4. Next stage, and the one decision I need

Per the agreed order, next is **scope reconciliation** — the report that compares
what the config backs up against what actually exists. This is the concrete
failure it addresses: VM 104 on pve0 ran with **zero** backups because it was
created after the config was written, and nothing compared those two facts.

My proposed shape, smallest useful version:

- read-only report, no config mutation, no `--fix`;
- per host: guests and datasets that exist but no job covers, and jobs whose
  source no longer exists;
- authoritative source for guests is `qm config` / `pct config`, **not** dataset
  naming — I got that wrong once already and it nearly cost VM 107's EFI and TPM
  state;
- exit non-zero when something is uncovered, so it can be a cron job later.

**Decision I need from you:** does the first slice emit a report only, or does it
also gain a `--suggest` that prints ready CONFIG v4 fragments for the gaps? I
lean report-only, on the same "wide scope, narrow gate" reasoning we settled for
profiles — but suggesting fragments is where the operator time actually goes.

## 5. Not asking for

No live campaign for §2: the freeze is a repository-state invariant and a host
cannot discriminate it. Same argument you accepted for REV-067 and REV-068.
