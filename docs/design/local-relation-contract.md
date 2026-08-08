# Single-host deployment — contract before code

Answers the owner directive in
`docs/discussions/PROFILE-LOCAL-RELATION-SCENARIO-2026-08-08.md`.

**Zero code.** This project has twice today paid less for agreeing a contract
first (REV-060 gated Stage 2; REV-073 corrected profile ownership *before* a
runtime existed and said so explicitly). This is the same move.

---

## 1. What already exists, measured not assumed

| need | exists today | where |
|---|---|---|
| local dataset discovery | **yes** | `deploy.sh --draft-scope` — depth-1 under each pool, minus `ROOT`/`swap`, full inventory as comments |
| scope file grammar + reader | **yes** | `lib-scope.sh` (`scope_read`, `scope_includes`, validators) |
| CONFIG v4 → cron | **yes** | `gen-cron.sh`, sole renderer |
| single crontab writer | **yes** | `lib-cron.sh` |
| local send/receive | **yes** | `snapsend.sh` with a local `dst`, no host prefix |
| scope reconciliation | **yes** | `gen-cron.sh --reconcile` |

So the data plane and every mechanism are present. **What is missing is
orchestration**, exactly as the directive says.

## 2. The decisive design question

`zfs-backup.sh` is built around a **relationship with a peer**: a client state
machine `pending_enroll -> seeding -> seed_complete -> endpoint_verified ->
active`, a join package, an ssh identity, an endpoint that can move.

A local relation has **no peer, no endpoint, no key, no network**. Three of the
five states are about reaching another machine.

The directive is explicit: *do not emulate a remote relation to self.* So the
question is not "how do I fake a client" but:

> Does a local relation get its own, shorter lifecycle, or does it reuse the
> existing one with the peer-dependent states declared not-applicable?

**My proposal: its own lifecycle, deliberately short.**

```text
LOCAL RELATION            REMOTE CLIENT (unchanged)
  configured                pending_enroll
  seeded                    seeding
  active                    seed_complete
                            endpoint_verified
                            active
```

Reasons, in order of weight:

1. `endpoint_verified` is the gate that stops cron being installed before the
   peer is reachable. With no peer there is nothing to verify, and a state that
   is always trivially true is a state that teaches an operator to ignore it.
2. Reusing the remote lifecycle means every future change to it must ask "and
   what does this mean with no peer?" — a permanent tax for a one-time saving.
3. The pause/disable split has the same shape: **logical pause applies**
   (it is an orchestration switch), **hard disable does not** — it is enforced
   by the peer's forced-command gate, and there is no peer. That asymmetry must
   be stated, not discovered.

## 3. The two invocations

```text
zfs-backup.sh setup-server  --target=hdd/backups          # exists today
zfs-backup.sh add-local NAME --source=rpool/data --target=hdd/backups \
                             [--recursive=flat] [--profile=default] [--yes]
```

`add-local` performs, in one run. **The order is the contract**, corrected by
REV-20260808-075 F1:

1. **discover** the local datasets under `--source` (reusing the `--draft-scope`
   census and its `ROOT`/`swap` rule);
2. **select** — interactively, or non-interactively from `--datasets`/the scope
   file. Per REV-073 the *deployment* owns this, never the profile;
3. **compose and validate** effective CONFIG v4 — including the nested-target
   refusal and the same-pool notice;
4. **preview** the rendered cron block; confirmation required unless `--yes`;
5. **persist** the relation as `configured`;
6. **seed** — the first send, foreground, result reported;
7. **persist** `seeded`, only after that seed succeeds;
8. **install** the managed cron block through `lib-cron.sh`, transactionally;
9. **persist** `active`, only after the installed block reads back correctly.

### Why this order, and what I had wrong

My first draft installed cron at step 5 and seeded afterwards. That contradicted
the lifecycle **two sections above it**: `configured -> seeded -> active`, with
cron belonging to `active`. Scheduled jobs would have been eligible to fire on a
relationship that never finished bootstrapping — precisely the state the
lifecycle exists to make impossible — and a schedule firing during a long
initial full send would have raced it. The engine's lock might serialise the
work, but leaning on that repairs nothing in the control plane.

The remote path has had this invariant all along: cron is installed only from
`endpoint_verified`. I moved the feature to a single host and dropped the rule.

### Failure behaviour, stated as the contract

| what fails | resulting state | what exists on disk |
|---|---|---|
| seed | stays `configured` | **no managed cron** |
| cron install or read-back | stays `seeded` | seed is done, retryable |
| nothing | `active` | cron installed and read back |

Re-running from `configured` retries the seed without duplicating state or jobs.
Re-running from `seeded` retries activation and does **not** repeat a proven
seed unless the operator asks for it explicitly.

No transient `seeding` state: `configured` is durable until the foreground
command returns, so a state that only counts progress would earn nothing.

## 4. Boundaries I am asking to have confirmed

- **No transfer-engine change.** `snapsend.sh` already takes a local `dst`. The
  engines are frozen and this needs nothing from them.
- **No new renderer.** `gen-cron.sh` stays the only thing that turns CONFIG v4
  into cron. `add-local` writes config and calls it.
- **Same-pool targets — SETTLED 2026-08-08, owner chose option B.**
  `rpool/data -> hdd/backups` is cross-pool and is the point. `hdd/x ->
  hdd/backups` is legal and weaker. `add-local` will **not** refuse it, and will
  state the topology **once, at preview, without a verdict**:

  ```
  Uwaga: cel hdd/backups jest w tej samej puli co zrodlo hdd/vm-disks.
  ```

  No "are you sure", no flag to bypass, no explanation of what it does or does
  not protect against. The deciding argument: **the preview is not the audit.**
  `--reconcile` is a machine that runs nightly and must not editorialise -- the
  owner's ruling applies there in full and nothing is added to it. The preview is
  a one-time screen shown to a human at the moment they choose a design. A fact
  that would be noise in a nightly alert is exactly right once, there.

  Cost of being wrong: one line to delete. A refusal with `--allow-same-pool`
  would have stayed in the interface forever.

- **Nested targets are REFUSED.** A target inside the source is a correctness
  defect, not a policy question, and nothing guards it today -- the existing
  self-sync guard covers only bare `user@host` resolving to this host.

  Measured on metropolis pve1 rather than argued, because my first description
  of the failure was wrong. `snapsend.sh -R hdd/nest-src hdd/nest-src/backup`:

  | run | result |
  |---|---|
  | 1 | `rc=0`, "All datasets processed successfully" -- `-R` expands descendants BEFORE the run and the target did not exist yet |
  | 2 | reports **`Transfer failed`** and still creates a second nesting level |

  Dataset count went 6 -> 10, depth reached
  `hdd/nest-src/backup/hdd/nest-src/backup/hdd/nest-src/child`. So it is not an
  infinite loop inside one run: **each run copies the previous backup into the
  new one**, growing without bound while reporting a transfer error. That shape
  is worse than a loop, because it reads as an ordinary transfer failure.

  `add-local` refuses a target at or beneath the source, before writing
  anything. Scratch datasets destroyed after the measurement.
- **Profiles.** `--profile` is accepted only once the Stage 5 runtime exists.
  Until then `add-local` takes cadence/retention from a built-in default and
  says which one it used.

## 5. What I will NOT build

- a fake client pointing at `localhost`, or any ssh-to-self;
- a second config renderer, scope grammar, or crontab writer;
- a state file format of its own if the existing client state store can carry a
  `kind = local` field — to be decided by reading that code, not guessed here;
- `--profile` behaviour that would make the profile own dataset selection
  (REV-073).

## 6. Test plan

- unit: `add-local` argument validation, refusal of a source that does not
  exist, refusal of a target inside the source;
- **ordering (REV-075 F1)**: the cron writer is **not called** when the seed
  fails; `active` is **not** persisted before cron read-back; a failed seed
  leaves the relation visibly non-active and retryable; retry from `configured`
  and from `seeded` are both idempotent;
- rendering: the generated CONFIG v4 for a known selection is **byte-stable**,
  and `gen-cron.sh` accepts it;
- crontab: install goes through `lib-cron.sh` and touches only the managed
  block — asserted by a real side effect, not by the command's own report;
- reconciliation: after `add-local`, `--reconcile` reports the selected datasets
  as covered and the target tree as received;
- one live run on a real host with a scratch cross-pool relation: induce a seed
  failure and prove **no managed cron was installed**, then a successful seed and
  activation with the actual crontab and relation state read back; destroyed
  afterwards;
- negative control against today's tree, where `add-local` does not exist.

## 7. What I need before coding

1. **owner:** confirm the two-invocation shape and the `add-local` spelling (or
   name it);
2. ~~lifecycle~~ — **settled by the reviewer (REV-075): own short lifecycle**,
   not peer states declared N/A;
3. ~~same-pool warning~~ — **settled by the owner: option B**, see §4.

I am not starting implementation until §7.2 is settled, because getting the
lifecycle wrong is the expensive mistake and the one hardest to undo after
operators have relationships on disk.

---

## 8. The operator sequence — position for the reviewer to confirm

Owner asked to see the command sequence. Principle: **one new verb**, everything
else reuses an existing command that means the same thing for a local relation.

### Normal path — two invocations

```bash
./zfs-backup.sh setup-server --target=hdd/backups
./zfs-backup.sh add-local prod --source=rpool/data --target=hdd/backups
```

`setup-server` exists today and is not peer-specific. `add-local` is the only
new command.

### Inside the second, in the order REV-075 fixed

```
1  discover datasets under rpool/data
2  select (interactive, or --datasets="...")
3  compose + validate CONFIG v4     <- nested-target refusal here
4  preview config and cron block    <- same-pool notice here
5  persist configured
6  SEED, foreground
7  persist seeded                   <- only after the seed succeeds
8  install cron via lib-cron.sh
9  persist active                   <- only after read-back succeeds
```

### Resuming after a failure

| what failed | state | on disk | resume with |
|---|---|---|---|
| seed | `configured` | **no cron** | `zfs-backup.sh seed prod` |
| cron install / read-back | `seeded` | seed proven | `zfs-backup.sh activate-client prod` |

Both verbs already exist for remote clients and mean the same thing here.
Resuming from `seeded` does **not** repeat a proven seed unless asked.

### Day two — all existing commands

```bash
zfs-backup.sh status prod
gen-cron.sh -c /etc/zfs-snapshot-all/jobs.pve0.conf --reconcile
zfs-backup.sh pause-client prod --reason="..."
zfs-backup.sh resume-client prod
zfs-backup.sh remove-client prod
```

### Deliberately NOT available locally

| command | why |
|---|---|
| `disable-client` / `enable-client` | enforced by the **peer's** forced-command gate; there is no peer |
| `set-endpoint` / `verify-endpoint` | there is no endpoint to move |
| `final-catchup` | closes an endpoint move that cannot happen |

Calling one of these on a local relation must **refuse with the reason**, not
succeed silently having done nothing. A no-op that reports success is how an
operator learns to trust a control that does not exist.

### What I am asking the reviewer to confirm

1. one new verb (`add-local`) with `seed` / `activate-client` reused for the two
   resume paths — or a local-specific spelling for those;
2. that the three unavailable commands **refuse loudly** rather than being
   hidden from `--help` for a local relation;
3. nothing here contradicts REV-075's ordering, which it should not, since the
   sequence is derived from it.

---

## 9. The "transactionally" claim, established rather than assumed

I wrote step 7 as "install the managed cron block transactionally" and then said
I had not read `lib-cron.sh` closely enough to promise it. Read now, so the
contract rests on the code rather than on a hope.

**What `cron_block_install` actually provides:**

| property | how |
|---|---|
| mutual exclusion | `flock -w $CRON_LOCK_TIMEOUT` on a per-user lock file, refusing a symlinked lock path and an unwritable lock dir |
| read-modify-write inside the lock | reads the current crontab, renders, compares |
| no-op detection | identical content returns success with `CRON_CHANGED=0`, so a rerun writes nothing |
| **write verified by read-back** | `cron_write` re-reads after `crontab(1)` and refuses to report success if the content differs |
| failure classification | `cron_restore_after_failure` checks whether the crontab actually changed before shouting; a crontab that never changed is not a false emergency |
| unverifiable restore | distinct **exit 2**, prior content deliberately left on disk |

So **step 9's read-back already exists in the library** — `add-local` inherits
it rather than needing to add it, which also means there is no second place for
it to drift.

**The boundary, stated because it is real:** the `flock` serialises writers that
go *through this library*. It does not serialise a human running `crontab -e`,
and `crontab(1)` offers no compare-and-swap. A concurrent hand-edit landing
between the read and the write would be silently overwritten — except that the
read-back then compares against what *we* wrote, so the loss would be real and
unreported.

That is a pre-existing property of the whole package, not something the local
path introduces, and every existing caller already lives with it. I am recording
it rather than fixing it here: widening the lock to cover interactive edits is
its own change, with its own blast radius, and it does not belong inside a
single-host deployment feature.

---

## 10. REVISED CLI — owner, 2026-08-08 evening

Sections 3 and 8 proposed `add-local` with an interactive checkbox selection.
The owner rejected the shape on grounds worth writing down, because they are a
design philosophy and not a preference:

> Jak najmniej zbednych nielogicznych aliasow. Jak najwiecej domyslnych
> ustawien. Logika i intuicja — musisz wcielac sie w "admina po Uniwerku".

### What that struck out

| I proposed | why it was wrong |
|---|---|
| `setup-host` alias | translating our vocabulary into more of our vocabulary |
| `add-local` verb | the ABSENCE of a subcommand already means local; `local` in the verb repeats it |
| `seed` / `activate-client` to resume | forces the admin to learn our state machine to retry something that failed |

An admin whose command fails **runs it again**. State is persisted, so the same
command must resume from where it stopped. Those two verbs stay for remote
relations, where they carry history; nobody needs them locally.

### The shape

```bash
zfs-backup.sh --target=hdd/backups          # a property of the HOST, set once
zfs-backup.sh --source=rpool/data,rpool/lxc # what to protect; called again as the host grows
zfs-backup.sh --source=rpool/newpool        # later, additively
```

Dispatch rule, one sentence: **first argument starts with `-` and is not
`-h`/`--help` -> no subcommand -> local mode.** Verified free: today that path
hits `unknown command`, and a bare `zfs-backup.sh` still prints usage, so help
does not turn into an action.

`--target` persists as `DEFAULT_TARGET` in `server.conf` — the mechanism
`setup-server` already writes. `--source` grows over time, which matches how a
host actually evolves: this is the VM 104 lifecycle, where a guest created after
the config was written had zero backups.

**Cost, stated once:** this spends the "options with no subcommand" slot
permanently. A future global option before a verb (`--verbose status prod`)
becomes impossible. There are none today; every option belongs to its
subcommand.

### Selection is a DRAFT CONFIG, not a menu

Owner: the same process as joining a client to a server — a proposal built from
the datasets that exist, presented **as a config**.

The precedent is real and already shipped: `deploy.sh --draft-config` lists the
peer's datasets and writes a reviewed-by-hand `.suggested` file, and **never
installs anything**. The local path reuses that idea rather than inventing an
interactive selector.

Why it is better than my checkbox menu: the artifact **is** a CONFIG v4 file,
which is what the operator maintains anyway; it is editable in a real editor;
and proposal is separated from action by construction.

Flow: `--source=...` writes the draft, shows it, asks to adopt. Decline and the
`.suggested` file stays on disk to edit; re-run adopts it. The happy path stays
one command, and editing is the natural second call rather than a third verb.

### Recursion belongs to the PROFILE, not the flag

I asked whether `--source=rpool/data` should mean "these children" or
"recursively". **Wrong question** — owner: that is what the profile specifies.

`recursive = no|flat|atomic` is a profile field (REV-054), and per REV-073 the
profile owns *how*. `--source` says only *what to consider*. Today's
container-like behaviour comes from a **hardcoded default**, which is exactly
the hardcode Stage 5 slice B1 exists to lift out into the profile.

So the CLI decides nothing here, the draft shows what the current profile
resolved, and a human can change it in the file before adopting.

### Defaults, and where they stop

Everything the admin does not need to start is defaulted: schedule, retention,
prefix, monitoring, recursion (from the profile). Two things stay on the command
line: **what to protect**, and **where it lands when that is ambiguous**.

`--target` may be inferred when the host has exactly one candidate pool, as
`setup-server` already does. It is **refused when ambiguous** — pve2 has three
pools, and quietly choosing where backups land is not convenience, it is a
surprise.
