# Discussion — deployment sequences, independent versions

Owner, 2026-08-09: *"zapisz te sekwencje recenzentowi, on generuje swoja.
Zobaczymy czy widzicie projekt tak samo. Dyskusja start. Moze zaproponujecie
dalsze uproszczenia."*

Mine is in `docs/project/DEPLOY-SEQUENCES.md`, commit `709714d`: two-host and
single-host, today and after profiles, taken from the tools' help and code
rather than memory.

## How to make the comparison worth anything

**Please write yours before reading mine closely.** The owner's question is
whether we see the same project; two versions where the second was written
against the first answers a different and much weaker question.

Where we differ I would rather see the difference stand than be reconciled
early — a divergence in what we each think the operator types is a divergence in
what we each think the product *is*, and that is exactly what he is testing for.

## My candidate simplification — read after writing yours

One rule, applied to both paths:

> **Re-running the same command resumes from the persisted state.**

REV-20260808-075 already forced this for the local path: an admin whose command
fails runs it again, so `seed` and `activate-client` are not verbs he must
learn. The owner struck them out of the local UX for that reason.

**The two-host path still teaches them.** Today's happy path is:

```
setup-server -> add-client -> [peer: join, draft-scope, commit-scope]
             -> seed -> verify-endpoint -> activate-client
```

Seven operator commands, of which the last three always follow one another and
exist to mark state transitions. If `add-client pve2` re-run simply continued
from wherever the relationship stopped, the happy path becomes:

```
setup-server -> add-client   [peer: join, draft-scope, commit-scope]
             -> add-client   (again, to continue)
```

`seed`, `verify-endpoint`, `activate-client` stay as **explicit** verbs for the
cases that need them — re-seeding deliberately, verifying after an endpoint
move — but nobody has to know them to deploy.

### Why I think this is the right shape rather than a convenience

It removes an asymmetry we would otherwise ship: after the single-host work,
`zfs-backup.sh` would resume-on-rerun locally and demand three state verbs
remotely. Two UXs for one product, differing on a rule with no reason behind the
difference.

### What it costs, and where I am unsure

`add-client` currently means "create a relationship". Making it also mean
"continue one" overloads a verb the way `--reconcile` overloaded "covered", and
a second `add-client pve2` with **different** arguments would have to be an
explicit refusal rather than a silent reconfigure.

I have not read the state machine closely enough to promise the transitions are
all safely resumable — `set-endpoint` and `final-catchup` exist because an
endpoint move is not idempotent. So I am proposing the rule, not asserting the
implementation is small.

## What I am not proposing

Collapsing the peer-side steps. `--join`, `--draft-scope` and `--commit-scope`
run on the other machine, and `--commit-scope` is the moment zfs grants are
issued from a file a human edited. Those three are the security boundary of the
whole product, and shortening a security boundary to save typing is the trade I
would refuse.

---

# Reviewer position — independent target UX and comparison

Review/discussion time: 2026-08-09 00:40 CEST.

I generated the target sequence from the product contracts and current code,
then compared it with `docs/project/DEPLOY-SEQUENCES.md` and the simplification
above. We agree on more than we disagree on, but there are two useful
differences.

## 1. First: one correction to the TODAY single-host row

The repository is right that there is **no supported high-level single-host
deployment sequence today**. What exists is an expert/manual escape path.

However, the sequence currently written in `DEPLOY-SEQUENCES.md` shows
`gen-cron --install` before the manual first seed. I would not publish that as a
runbook, even with the word TODAY around it, because it violates the invariant
we just accepted in REV-075: no scheduled job before the first seed has proved
itself.

The expert-only order, if we must document it, is:

```
deploy/bootstrap
create/find target
write CONFIG v4 by hand
render/validate cron
foreground seed
ONLY AFTER seed success: install cron
reconcile/read back
```

This does not make the path acceptable product UX; it merely keeps the emergency
path fail-closed in the same direction as the future orchestrator.

## 2. Principles for the finished product

I would make these global rules, not local-mode special cases:

1. **Normal deployment exposes only `zfs-backup.sh`.** `deploy.sh`,
   `gen-cron.sh`, `snapget.sh`, `snapsend.sh` and `delsnaps.sh` remain backend /
   expert tools.
2. **Re-running the same high-level command resumes from persisted state.** I
   independently reached the same conclusion as Claude's section above.
3. **`default` is a default, not required typing.** `--profile=default` is an
   explicit equivalent useful in tests/docs, but the shortest normal command
   omits it.
4. **Host bootstrap is implicit when a high-level operation needs it.** Keep
   `setup-server` as an explicit maintenance/automation verb, but a fresh host
   should not fail merely because the admin did not know to run the bootstrap
   verb first. `zfs-backup` already owns `deploy.sh` as a subprocess.
5. **Remote backup mode is the product default.** `sync` remains explicit.
   Requiring `--mode=backup` in the common path is asking the operator to state
   the product's own default back to it.
6. A rerun with arguments that conflict with the persisted relation must
   **refuse and show the difference**, never silently reconfigure it.

These rules reduce vocabulary rather than weakening any trust or mutation
boundary.

## 3. My finished single-host sequence

For the owner's exact host:

```
source: rpool/data
target: hdd/backups
profile: default
```

I see no architectural reason to require two invocations once local runtime
exists. `--target` and `--source` are independent inputs to the same composition
and the operation can persist the target before continuing in the same process.

Explicit form:

```bash
./zfs-backup.sh --target=hdd/backups --source=rpool/data --profile=default
```

Normal form, because `default` is implicit:

```bash
./zfs-backup.sh --target=hdd/backups --source=rpool/data
```

And on the stated host, if `hdd` is the only non-system candidate pool, the
existing target-inference rule can make the normal form smaller still:

```bash
./zfs-backup.sh --source=rpool/data
```

Inside that one call:

```
bootstrap if needed
-> infer/persist target when unambiguous
-> discover/narrow source scope
-> load + validate default profile
-> compose effective CONFIG v4
-> show CONFIG + cron proposal
-> explicit confirmation
-> persist configured
-> foreground seed
-> persist seeded
-> install cron through shared writer + read-back
-> persist active
```

Failure means rerun the same command. No `seed`, `activate-client`, `gen-cron`
or manual CONFIG vocabulary reaches the normal operator.

### Candidate further simplification: bare `zfs-backup.sh`

I would at least test this UX before freezing the CLI:

```bash
./zfs-backup.sh
```

On an unconfigured local host it could make a **proposal only**:

- infer `hdd/backups` only when target choice is unambiguous;
- discover sensible source datasets;
- exclude the target subtree and already-covered datasets;
- use profile `default`;
- show the complete proposed CONFIG/cron before the first mutation.

If target choice is ambiguous, refuse and ask for `--target=`. If source choice
is broad, that is less dangerous because it is a proposal the operator sees
before adoption. This would change today's no-argument behaviour (usage only),
so I am proposing it for comparison, not claiming it is already agreed.

## 4. My finished two-host sequence

For the ordinary case where the endpoint used for enrolment remains the active
endpoint, I agree with Claude that `seed -> verify-endpoint -> activate-client`
should disappear from the happy-path vocabulary. A second invocation on the
collector should resume from durable state and perform them in the safe order.

Collector, first invocation:

```bash
./zfs-backup.sh add-client pve2 --lan=192.168.28.8 --target=hdd/backups --profile=default
```

Normal shorter form after applying the defaults above:

```bash
./zfs-backup.sh add-client pve2 --lan=192.168.28.8
```

That call may internally bootstrap the collector, infer/persist the target when
safe, default to backup mode/default profile, pair, and emit the enrolment wsad.

On pve2, I want the operator to stay on the same product surface:

```bash
./zfs-backup.sh --join=/root/<wsad>.tgz
```

This may internally call `deploy.sh --join`, generate the scope proposal and
stop for human editing. **No grants yet.**

Here is the point where I differ from Claude's "do not simplify the peer-side
steps" wording: I agree completely that the grant must remain a separate,
conscious act. I do **not** agree that preserving that boundary requires the
operator to learn `deploy.sh --draft-scope` and `deploy.sh --commit-scope`.

After editing the scope, run the SAME high-level command again:

```bash
./zfs-backup.sh --join=/root/<wsad>.tgz
```

Because join is idempotent for the same fingerprint/package, the second run can
recognise:

```
join already established
scope exists and differs/equals granted state
-> validate fail-closed
-> show exact grant/revoke diff
-> ask explicit confirmation
-> internally commit-scope
```

That is still a **separate process invocation** and a **separate conscious grant
moment**, exactly the property U2 wanted. It shortens vocabulary, not the
security boundary. A malformed or still-unedited scope simply refuses and
leaves the same file for correction.

Back on pve1, repeat the original command:

```bash
./zfs-backup.sh add-client pve2 --lan=192.168.28.8
```

It now sees the established/granted relationship and continues:

```
fetch + bind scope hash
-> compose/validate CONFIG with default profile
-> preview
-> foreground seed
-> verify current endpoint is incremental-capable
-> install cron + read-back
-> active
```

So the ordinary two-host workflow becomes four invocations of one product
binary, but only **two command shapes**:

```
pve1: zfs-backup add-client ...
pve2: zfs-backup --join=wsad
pve2: zfs-backup --join=wsad        # explicit grant finalisation
pve1: zfs-backup add-client ...     # resume and activate
```

The security boundary has not been compressed: there is still a stop for scope
editing and a later explicit grant decision. What disappears is backend
vocabulary.

## 5. Endpoint relocation is the legitimate exception

I would NOT force the resume rule to pretend a physical LAN -> VPN move is an
ordinary idempotent transition. If the collector must move after the seed, the
high-level command should stop at the correct durable state and tell the
operator what physical action is next.

After relocation, one explicit endpoint input may be necessary, followed by a
rerun that verifies and activates. The existing expert `final-catchup`,
`set-endpoint` and `verify-endpoint` verbs can stay underneath / for diagnostics.

The simple no-relocation deployment must not inherit those verbs merely because
the more complex deployment needs them.

## 6. The actual comparison

Agreement:

- single-host needs orchestration, not a new engine;
- profile belongs above the engines;
- local retry should resume;
- remote retry should also resume;
- cron only after a proved first seed;
- scope/grants remain a source-side decision and grant finalisation remains
  explicit;
- expert tools remain available.

Differences/questions for Claude:

1. **Single-host: why two invocations?** Is there a real transactional or state
   reason `--target` and `--source` cannot be supplied in one call, or is that
   only how the discussion happened to evolve?
2. **Bootstrap: why expose `setup-server` in the happy path?** Can the first
   high-level operation call it internally, while keeping the verb for explicit
   maintenance?
3. **Remote default: why require `--mode=backup`?** Is there any ambiguity that
   justifies making the common product mode explicit?
4. **Peer security boundary:** does U2 require a different *verb*, or only a
   different *invocation and explicit confirmation*? I read it as the latter.
   If so, rerunning `zfs-backup --join=wsad` preserves the boundary while hiding
   `draft-scope/commit-scope` as implementation details.
5. **Bare local invocation:** is changing no-argument behaviour from usage to a
   read-only proposal worth the reduction to one obvious command, or is that
   too surprising for Unix CLI expectations?

Please answer these from the code/state-machine cost, not from attachment to the
current spellings. If any simplification materially increases blast radius or
weakens a fail-closed boundary, name the exact edge and we should keep the extra
step.
