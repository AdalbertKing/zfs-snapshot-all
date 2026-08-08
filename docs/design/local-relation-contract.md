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

`add-local` performs, in one run:

1. **discover** the local datasets under `--source` (reusing the `--draft-scope`
   census and its `ROOT`/`swap` rule);
2. **select** — interactively, or non-interactively from `--datasets`/the scope
   file. Per REV-073 the *deployment* owns this, never the profile;
3. **render** effective CONFIG v4 into `/etc/zfs-snapshot-all/`;
4. **preview** the cron block and require confirmation unless `--yes`;
5. **install** the cron block through `lib-cron.sh`, the single writer;
6. **seed** — the first send, foreground, with its result reported.

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
- rendering: the generated CONFIG v4 for a known selection is **byte-stable**,
  and `gen-cron.sh` accepts it;
- crontab: install goes through `lib-cron.sh` and touches only the managed
  block — asserted by a real side effect, not by the command's own report;
- reconciliation: after `add-local`, `--reconcile` reports the selected datasets
  as covered and the target tree as received;
- one live run on a real host with a scratch pool pair, destroyed afterwards;
- negative control against today's tree, where `add-local` does not exist.

## 7. What I need before coding

1. **owner:** confirm the two-invocation shape and the `add-local` spelling (or
   name it);
2. **reviewer:** the lifecycle decision in §2 — own short lifecycle, or reuse
   with peer states declared N/A;
3. ~~same-pool warning~~ — **settled by the owner: option B**, see §4.

I am not starting implementation until §7.2 is settled, because getting the
lifecycle wrong is the expensive mistake and the one hardest to undo after
operators have relationships on disk.
