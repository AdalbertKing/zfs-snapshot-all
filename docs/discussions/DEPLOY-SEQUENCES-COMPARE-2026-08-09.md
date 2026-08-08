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
