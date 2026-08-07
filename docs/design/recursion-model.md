# Recursion — one decision per dataset, not three

Status: **proposal**, no code written. Raised by the owner 2026-08-07 after
finding the generated jobs "illogical, confusing and inconsistent". The live
survey below says the owner is right, and says so more sharply than the
original complaint did.

Audience: someone who administers ZFS and reads `zfs(8)`, but has not read this
repository's 20k lines. Every claim here is either a file:line reference or a
command run against a real host on 2026-08-07.

---

## 1. The complaint

> I expected `[dataset:rpool/data]` to mean "this subtree, recursively", so that
> a new VM disk `rpool/data/vm-903-disk-0` is backed up tonight without me
> regenerating anything. Instead the tooling wants one section per disk, and a
> new guest is silently missed until I remember to edit the config. That is not
> acceptable.

Two separate questions hide in there, and they have different answers:

- **Does the engine expand recursion at run time, or freeze it at generate
  time?** It expands at run time. The engine is fine.
- **Does one config section produce a *consistent* set of jobs?** No. And that
  is the actual defect.

---

## 2. What the four engines do today

All four expand recursion **when the cron job runs**, never when the config is
generated. A dataset created at 15:00 is visible to the 02:00 job.

| Command | Who expands | Unit of work | Same instant for the whole subtree? |
|---|---|---|---|
| `snapsend/snapget -r` | ZFS itself | subtree = one stream | **yes** — `zfs snapshot -r` + `zfs send -R` |
| `snapsend/snapget -R` | the script, via `zfs list -r` ([snapsend.sh:1744](../../snapsend.sh)) | one dataset = one job | no, unless `-q` (see §2.1) |
| `delsnaps -R` | the script ([delsnaps.sh:893](../../delsnaps.sh)) | one dataset = own retention | n/a |
| `check-snap-age -R` | the script | one dataset = own age check | n/a |

`deploy.sh` and `zfs-backup.sh` **have no `-r`/`-R` options at all.** `deploy.sh
--draft-config` prints a *comment* suggesting you add `-R` yourself
([deploy.sh:5543](../../deploy.sh)); `zfs-backup.sh` only sniffs `-r`/`-R` out of
already-rendered cron lines to compute quiesce coverage
([zfs-backup.sh:2657](../../zfs-backup.sh)).

### 2.1 Why `-q` appears in that table

Without `-q`, flat mode calls `zfs snapshot` once **per dataset**, each at its
own moment. Ten datasets spread over 40 seconds are ten different points in
time — fine for independent disks, wrong for a guest whose data and log live on
two datasets.

With `-q`, the freeze happens first, then **one** `zfs snapshot` call carries
every name at once ([snapsend.sh:1977](../../snapsend.sh)), then the sends run
against snapshots that already exist. Atomic **per pool** — ZFS cannot span
pools, so a two-pool job is two atomic groups, and the freeze is re-checked
before each ([snapsend.sh:1970](../../snapsend.sh)). If that snapshot fails, the
run fails; it never falls back to unquiesced per-dataset snapshots
([snapsend.sh:1998](../../snapsend.sh)).

### 2.2 The letters are inverted relative to `zfs(8)`

`snapsend -r` runs `zfs send -R`. `snapsend -R` never runs `zfs send -R`. An
administrator who knows the real flags gets the opposite of their reflex. The
letters cannot be changed — every deployed crontab uses them — but §4 makes them
something the operator rarely types.

---

## 3. Where recursion is declared — and why that is the defect

A `[dataset:]` section generates up to three cron lines: **send**, **inline
prune**, **monitor**. Recursion is declared differently for each:

| Line | How you ask for recursion | Kind of thing |
|---|---|---|
| send | `flags = -R` (a substring) | free text |
| inline prune | **you cannot** — see below | — |
| monitor | rides the prune section | — |

Inline prune is hard-coded non-recursive:

> "listing every member dataset BY FULL PATH, non-recursively. **No `-R`, ever.**"
> — [gen-cron.sh:1486](../../gen-cron.sh)

So `flags = -R` on `[dataset:rpool/data]` produces:

```
snapsend.sh ... -R "rpool/data" ...          <- recursive: picks up a new child
delsnaps.sh  "rpool/data" "daily-" -H24      <- rpool/data only: child ignored
```

A new child is replicated and then **never pruned, and never monitored**. It
looks like a healthy run forever. Nothing warns: `lint_flags()` inspects `flags`
for `-f`, `-n`, `-q`, `-z` ([gen-cron.sh:511](../../gen-cron.sh)) and says nothing
about `-R`.

Meanwhile `[prune:]` *does* have a proper field, and gen-cron actively refuses
the flag form there:

> `ssh_flags has -R -- use this section's own 'recursive = yes' instead`
> — [gen-cron.sh:555](../../gen-cron.sh)

The same decision is a validated field in one section and unvalidated free text
in another.

---

## 4. Live survey, 2026-08-07 — four production hosts

Method: `crontab -l -u zfsbackup` on each host, `/etc/zfs-snapshot-all/jobs.*.v4.conf`,
`zfs list` cross-referenced with `qm list` / `pct list`.

### 4.1 The predicted trap is latent, not live

No `[dataset:]` section on **any** managed host carries `-R` in `flags`. The
recursive-send-with-flat-prune combination does not currently exist in
production. Stated plainly so the reviewer can weight the priority: **this is a
trap waiting, not an outage running.**

### 4.2 The owner already had to work around it — by hand

`pve1` (192.168.11.11) is the one host that replicates a whole subtree. Its
config does **not** express that as one decision. It expresses it as two
sections plus a deliberately split template family:

```ini
[dataset:rpool/data]
	use_template = hourly,daily,weekly,monthly,annual   # send only, NO retention
	flags        = -r -v 3

[template:flat_prune]
	prune_schedule = 58 * * * *
	pattern        = automated_
	retain         = -h 12

[prune:rpool/data]
	use_template = flat_prune
	recursive    = yes
```

Why the templates are split: if the five send templates also carried
`prune_schedule`, the `[dataset:]` section would emit its own non-recursive
inline prune **in addition to** the recursive `[prune:]` one. The two are
additive with no cross-check ("B semantics", [gen-cron.sh:281](../../gen-cron.sh)),
they would race on the same pattern and schedule, and the loser reports "could
not find any snapshots to destroy" and alerts.

So the only correct recursive deployment in the fleet was reached by keeping
retention out of the send templates on purpose. That works, and it is
documented in the config's own comments — but it is a workaround for the tool,
not a use of it.

### 4.3 The real damage is elsewhere, and it is live

Because everything else enumerates datasets one per section, a guest created
after the config was written is invisible. On **pve0** (192.168.11.10):

| Guest | State | Dataset | `automated_*` snapshots |
|---|---|---|---|
| VM 104 `debian` | **running** | `hdd/data/vm-104-disk-1` | **0** |
| VM 103 `vdc` | stopped | `hdd/data/vm-103-disk-0` | 0 |
| VM 107 `vwin3` | stopped | `hdd/data/vm-107-disk-1` | 0 |
| CT 105 `usql` | stopped | `hdd/lxc/subvol-105-disk-0` | 0 |

A running VM with zero backups. This is the same failure that was found once
before (VM 101, which had zero backups until it was noticed by hand) — the
config enumerates, reality grows, and nothing reconciles the two.

`pve0`'s config has no recursive `[dataset:]` section, so nothing in the tool is
"broken" by its own contract. That is precisely the problem: **the contract
permits a config that is silently incomplete, and offers no ergonomic way to
write one that is not.**

---

## 5. Proposal

Make recursion a **first-class field on `[dataset:]`**, driving all three
generated lines from one declaration.

```ini
[dataset:rpool/data]
	recursive    = atomic          # or: flat, or: no (default)
	use_template = hourly,daily
```

| Value | send | inline prune | monitor | when to use |
|---|---|---|---|---|
| `no` (default) | this dataset | this dataset | this dataset | a single disk |
| `flat` | `snapsend -R` | `delsnaps -R` | `check-snap-age -R` | many independent datasets; one child failing must not stop its siblings; you want `-X`/`-S` filters |
| `atomic` | `snapsend -r` | `delsnaps -R` | `check-snap-age -R` | one guest across several datasets; you need a single point in time |

`delsnaps` and `check-snap-age` have no atomic mode and need none — retention
and age are per-dataset questions. `-R` is correct for both under either value.

Consequences:

1. **`-r`/`-R` in `flags` becomes an error**, with the message gen-cron already
   uses for `ssh_flags`: *use this section's own `recursive =` instead*. No more
   unvalidated free text.
2. **The `[prune:]` workaround becomes unnecessary** for the common case. §4.2's
   config collapses to one section with normal templates.
3. **`--draft-config` emits the field instead of prose.** Today it prints
   "$ds has N descendants — one `-R` in flags covers the subtree" and leaves the
   operator to act on it. It should emit `recursive = flat` (commented, like
   every other line it drafts) so the decision is visible in the shape of the
   file.
4. **The inverted letters stop mattering** to the operator, who writes `atomic`
   or `flat`. The letters remain the generator's business, so deployed crontabs
   keep working untouched.

### 5.1 What this does **not** change

- No engine change. `snapsend`, `snapget`, `delsnaps`, `check-snap-age` are
  untouched. This is generator and validator work.
- `-r` and `-R` are **not** merged. They are different guarantees: `-r` gives one
  atomic point in time and fails as a unit; `-R` isolates per-child failures,
  supports `-X`/`-S`, and records per-dataset bookmarks (under `-r` no bookmark
  is recorded at all, [snapsend.sh:1440](../../snapsend.sh)). Removing either
  loses something the other cannot supply.
- Existing crontabs are byte-identical after migration for any config that does
  not use the new field.

### 5.2 Compatibility and migration

Live configs carrying `-r`/`-R` in `flags`: **one** — `pve1` (192.168.11.11),
`[dataset:rpool/data] flags = -r -v 3`. `pve0`, metropolis `pve1` and metropolis
`pve2` carry none.

That makes a hard cut-over cheap. The open question for the reviewer is whether
it should still be staged:

- **(a) Hard reject.** `-r`/`-R` in `flags` dies at generate time. One config to
  edit, fleet-wide. Regeneration refuses until it is edited — loud, and the
  operator is the person who wrote it.
- **(b) Deprecate first.** Accept the flag with a warning for one release, then
  reject. Safer for configs outside this fleet, if any exist.

The project's own precedent points at (a): blank config fields are rejected
rather than defaulted, on the stated grounds that a silent default is "a
question nobody answered".

### 5.3 Test obligations

- `test/cron`: one case per `recursive` value asserting all three generated
  lines, plus a negative control that the old `flags = -R` config is refused.
- `test/negative`: `-r`/`-R` in `flags` produces the new refusal.
- `test/fixtures`: the §4.2 pve1 config, migrated, must generate a crontab
  byte-identical to what that host runs today. This is the strongest available
  proof that the change is behaviour-preserving, and it is cheap — the host's
  current crontab is the expected output.
- `cron2conf.sh` must read `-r`/`-R` back into the field, or round-tripping a
  live crontab silently drops recursion.
- No live-host obligation: generator-only change, and the fixture above covers
  the one real recursive deployment.

---

## 6. What this proposal deliberately leaves open

The pve0 finding in §4.3 is **not fixed by this change.** A `recursive` field
makes a complete config easy to write; it does not notice that `hdd/data` has
four guests and the config names one. That is a different feature — reconciling
declared scope against what the hypervisor actually runs — and it should be
argued on its own merits, not smuggled in here.

It is, however, the reason this proposal matters. The tool currently makes the
safe shape (one recursive declaration) harder to write than the unsafe one (a
list that goes stale). That is backwards.
