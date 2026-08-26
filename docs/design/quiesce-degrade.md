# Quiesce that fails: no snapshot, or a labelled crash-consistent one?

Owner question, 2026-08-25, during the profile stage. **BUILT 2026-08-26**,
after a pre-review of the frozen engines authorised it (PR #165, marker
`authorizes-frozen: lib-zfs-snap.sh snapsend.sh snapget.sh`). The sections below
are kept in the order they were written -- the measurement, the hole, the shape
-- and the last section says what was actually built and what it cost.

## What happens today, measured

`snapsend.sh -q auto` on a guest that cannot be frozen:

```
QERR 1 guest(s) could not be quiesced -- NOT taking a snapshot,
     because it would be crash-consistent while reporting success
exit 5
```

No snapshot is taken at all. That is REV-20260730-006 §2, and the reason in the
code says exactly what the objection was:

> the loop used to discard the result, so a failed freeze printed QERR and the
> run went on to snapshot anyway and exit 0 -- an operator who asked for
> application-consistent got crash-consistent and was told it worked.

**The objection was about LYING, not about the value of the snapshot.** That
distinction is the whole design space here.

## The hole the owner named

Fail-closed costs a different amount per tier, and the original decision did not
weigh that:

| tier | what a failed freeze costs | when you find out |
|---|---|---|
| `_hourly` | 1 of 24, next one in an hour | 90 min (monitor_warn) |
| `_daily` | **1 of 7, and it is the durable artifact** | 30 h |
| `_monthly` | 1 of 6 -- a month-long hole | **never**: that monitor was removed 2026-07-22 |

For the hourly family, refusing costs almost nothing. For the daily family it
costs the thing the tier exists to produce. For monthly, nothing even reports
it.

There is a host on this estate where the asymmetry is sharper still: on `vsql2`
our quiesce aborts SQL backups on ~400 databases. There, "crash-consistent
instead of nothing" is not merely better than nothing -- it is better than the
freeze.

## The shape that answers the original objection

Not a return to fail-open. A DEGRADATION THAT CANNOT BE MISTAKEN FOR SUCCESS:

```ini
[template:daily]
	prefix  = automated_daily_
	quiesce = auto            # today: freeze failed -> no snapshot
```
```ini
[template:daily]
	prefix  = automated_daily_
	quiesce = auto,degrade    # freeze failed -> crash-consistent, and VISIBLE
```

`degrade` is only honest if all three hold at once:

1. **the snapshot is distinguishable** -- a different name (e.g.
   `automated_daily_crash_<stamp>`), so whoever restores it can see what they
   are getting, and so retention counts it for what it is;
2. **the run reports the degradation** -- an alert, not a line in a log nobody
   reads;
3. **the operator opted in beforehand**, per tier.

With those, nobody receives application consistency together with an assurance
that it worked. They receive the weaker thing, and they know it is weaker.

## Where the decision lives

| layer | holds |
|---|---|
| **tier, in the profile** | the DECISION: `quiesce = auto,degrade`. It is policy about *these data* -- the same axis the `-q` itself sits on |
| **host `.ini`** | the DEFAULT for this host when a tier says nothing |

Same layering the target already uses: `server.conf DEFAULT_TARGET` as the
default, an explicit per-relationship value as the override. It lets `vsql2`
turn degradation on once for the host while pve1 keeps fail-closed, without
touching a profile.

This is also the first concrete content anyone has found for a host-level
defaults file. Until now the argument against building one was that it would
hold nothing; that argument no longer applies to this field.

## As built

### The grammar

`quiesce = <mode>[,degrade]`, exactly the spelling reserved above. One parser,
`quiesce_parse_mode` in `lib-zfs-snap.sh`, used by both engines -- so `-q` cannot
come to mean two things depending on which direction a relationship runs. It
refuses `no,degrade` (a policy about a freeze that never happens), a misspelled
qualifier and a repeated one. `gen-cron.sh`'s `lint_quiesce` splits the same
grammar at config time, so a config that renders cleanly cannot fail at run time
on this field, and `sync,degrade` on a pull is still refused for the reason bare
`sync` is.

### The name

`automated_daily_crash_2026-08-26_20-50-40`. Fixed, not configurable, built by
one helper (`quiesce_crash_message`) for both directions. The marker sits between
the family and the timestamp, and both halves of that sentence are load-bearing.
Checked in the frozen scripts rather than assumed:

| property | why it holds |
|---|---|
| retention still prunes it with its tier | `delsnaps.sh` matches a family by PREFIX, and `automated_daily_crash_...` still starts with `automated_daily` |
| "keep the newest N" is not reordered | `delsnaps.sh` orders candidates with `zfs list -s creation`, by time and not lexically |
| the age monitor stays green | `check-snap-age.sh` uses the same prefix match |

The third row looks like a hole and is a deliberate division of labour. The age
monitor answers "is there a recent snapshot for this family" -- there is, and the
green is correct. That it is crash-consistent is reported by the run's own exit
status and mail. A monitor that flagged it would re-report the same degradation
every 15 minutes for the snapshot's whole life, which is the alert flood this
estate already measured once and removed.

Fixed rather than configurable because these snapshots travel between hosts
(pvesr, and the collector pulling from its sources), so a per-host name would
mean different things depending on where you were standing. The only reader is a
human.

### What degrading does NOT excuse

Three refusals stay fatal with the qualifier exactly as without it, and each is
enforced rather than documented:

- **a thaw that did not take** -- a guest left frozen is an outage, and an outage
  is not improved by taking a snapshot afterwards;
- **a foreign freeze found already in place** -- somebody else's window is not
  ours to end, and we cannot say what application state it holds;
- **a rollback that could not remove this run's own snapshots** -- a
  crash-consistent set on top of a half-finished quiesced one leaves two
  overlapping answers to "what is the current tier snapshot", which is
  REV-20260802-030 again.

Two further refusals stay fatal for a different reason: a mode that can never fit
the guest (`agent` on a container, `sync` on a VM) is a config error that will
never fix itself, and degrading it would tell the operator their guests are
quiesced for as long as the config survives. `,degrade` answers "the freeze did
not happen THIS TIME".

### One coherent set

`quiesce_degrade_gate` rolls back everything this run created inside the window
and thaws everything it froze BEFORE it agrees to anything. Only then does the
ordinary, unquiesced path take the whole set again under the marked name. No run
ever mixes plain and `_crash_` names; that is why the gate returns a decision
rather than the engines patching a name onto a partial set.

### The remote half

`snapget.sh` freezes on the SOURCE, and the code that does it is shipped over ssh
and run by `bash -s` -- so no function in `lib-zfs-snap.sh` exists on the far
side, and nothing can be called across the boundary. The only thing that crosses
is an exit code.

That turned out to be enough, because the remote script's existing contract
already distinguishes the states that matter, and does so structurally:

| remote rc | means | degradable |
|---|---|---|
| 3 | refused before freezing anything (no privilege, no `setsid`, deadman not armed) | **yes** |
| 5 | quiesce failed, rollback and thaw both clean -- a failure in either turns this into 7 or 6 instead | **yes** |
| 4 | `zfs snapshot` itself failed | no: the crash snapshot uses the same command |
| 6 | a guest is still frozen | no: an outage |
| 7 | the rollback left snapshots behind | no |
| other | ssh or the far side broke | no: a link failure is not a quiesce policy decision |

rc 3 is the case that was measured on pve9/pve1/pve2, 2026-08-25.

**No line of the shipped remote script changed.** The first attempt at this patch
did edit it -- a `quiesce_degrade_gate` call was placed at what looked like a
local failure site and was in fact inside the heredoc -- which would have called
an undefined function on the far host and broken remote quiesce outright. Written
down because the file gives no visual warning at that boundary.

### The status

A successful degradation exits **8**, decided last and only on the otherwise
clean path: a real transfer error outranks it. Returning non-zero BEFORE the
transfer would keep the snapshot on the source and lose the very thing
`,degrade` exists to preserve -- the durable copy on the far side.

### Where the decision lives, as built

`prod.conf` carries `quiesce = auto,degrade` on daily, weekly and monthly;
hourly still has no quiesce at all, because an hourly freeze would stall every
guest 24 times a day and losing one interval of twenty-four is not what this is
for.

The host `settings.ini` supplies `quiesce` ONLY when the tier named none. It
cannot widen an explicit value: a tier that says `auto` keeps meaning
fail-closed `auto`, and no host default turns it into `auto,degrade`.
`settings_get` moved from `zfs-backup.sh` to `lib-cron.sh` for this -- the one
file both `zfs-backup.sh` and `gen-cron.sh` already source, so the two cannot
disagree about what a host said.

## Acceptance criteria, answered

- **a failed freeze under `degrade` produces a snapshot whose NAME says it is
  crash-consistent, and an alert** -- met. The name is built by
  `quiesce_crash_message`; the alert is the existing cron notifier, fired by the
  distinct exit status 8.
- **a failed freeze WITHOUT `degrade` still takes no snapshot and still exits
  non-zero -- the discriminator must survive** -- met, and it is the assertion
  the suite spends the most lines on. `test/quiesce` runs the SAME failure with
  and without the qualifier at every site, local and remote, and a mutation that
  removes the opt-in check fails ten pre-existing fail-closed assertions.
- **retention treats the degraded snapshot as belonging to its tier** -- met by
  the prefix property above, and asserted as a property rather than as a string.
- **restore names the difference where the operator can see it before choosing**
  -- NOT met here, and deliberately: restore is not built yet. The literal
  `*_crash_*` name is what the restore view will show, which is why the marker is
  in the name rather than in a sidecar record.

## What is proven, and how

| claim | evidence |
|---|---|
| the grammar accepts and refuses the right values | `test/quiesce`, both halves of the table, including the bare modes -- the first version of the parser rejected `auto` because `local raw="$1" mode="$raw"` leaves `mode` empty, and only the positive control caught it |
| the gate refuses without the opt-in | `test/quiesce`, with a mutation control |
| a failed thaw and a failed rollback stay fatal WITH the opt-in | `test/quiesce`, each with a mutation control |
| the remote mapping degrades 3 and 5 and nothing else | `test/quiesce`, all seven codes in both directions |
| push and pull produce the SAME degraded name | `test/runsuffix`, driving both engines' own `create_snapshot`, with an unmarked negative control |
| a degraded run transfers, lands and exits 8 | **LIVE ONLY.** No suite on this box has ZFS. See the run recorded in `docs/PROJECT_STATUS.md`. |
