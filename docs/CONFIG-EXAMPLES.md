# Expert native CONFIG examples

`gen-cron.sh` reads one INI config per host (CONFIG format v4) and generates the
managed crontab block from it. A preset (`add-client --profile=NAME`) is just a
way to *generate* such a config for a new relationship; after install the config
is the execution truth, and hand-writing or hand-editing one is a supported,
first-class path — the documentation, not the CLI, is the escape hatch for
bespoke policy.

This file collects worked expert examples that the CLI deliberately does not try
to absorb. Every `.conf` here is a real file under [`examples/`](examples/) and
generates cleanly; the full field reference lives in the header of
[`gen-cron.sh`](../gen-cron.sh).

**Validate/preview any config without touching a crontab** — this renders the
managed block to stdout and exits non-zero on any error:

```bash
./gen-cron.sh -c docs/examples/independent-tiers.conf
```

Re-run any example below with its own path to see exactly what it generates.

---

## 1. Independent hourly + daily retention, without forcing GFS

[`examples/independent-tiers.conf`](examples/independent-tiers.conf)

Two tiers on one dataset, each with its own cadence and its own **count-based**
retention (`keep = N` → `-<TIER_LETTER><N>`). The counts are independent — 24
hourly and 14 daily — not a cascading grandfather-father-son ladder. GFS is a
separate, opt-in choice (`gfs = yes` on a `[prune:]` section, example 4's
neighbour `gfs-ladder.conf` in the test fixtures); you never pay for a ladder
just to keep two retention counts.

Generates one send line and one prune line per tier:

```
5 * * * *  ... snapsend.sh -m "automated_hourly_" -e "tank/vm-100-disk-0" ...
35 * * * * ... delsnaps.sh "tank/vm-100-disk-0" "automated_hourly" -H24 ...
40 0 * * * ... delsnaps.sh "tank/vm-100-disk-0" "automated_daily"  -D14 ...
```

## 2. Quiesce only where a guest can tolerate a freeze

[`examples/selective-quiesce.conf`](examples/selective-quiesce.conf)

`quiesce` is per-dataset and, unlike link auto-tuning (`-A`), is **never
inferred** — whether a guest can be briefly frozen, and what the write stall
costs, is invisible from a dataset name. Set it only on the datasets whose
guests can take it:

- `agent` — qemu-guest-agent `fsfreeze` (a VM running the agent);
- `sync` — container-level quiesce (an LXC);
- `auto` — let `snapsend.sh` choose per guest type;
- absent / `no` — crash-consistent snapshot, command unchanged.

Because the three datasets resolve different `-q`, they stay three separate send
lines rather than merging. Do **not** quiesce a network gateway or anything
whose brief stall would cut your own path to the host.

## 3. Shorter local retention than the store keeps (the "Kancelaria" pattern)

[`examples/short-local-long-store.conf`](examples/short-local-long-store.conf)

The working pool holds only a short local safety window (48 hourly = two days);
long history lives in the store, which keeps `-D90`. Every snapshot is still
sent — only the *local* copies are pruned aggressively. Shown on one host for
clarity; the common production shape is the same two rules split across two
hosts (source self-prunes short, store prunes long). Retention is per-dataset,
so each side owns its own policy and neither infers the other's.

## 4. Hand-authored prune schedules and patterns

[`examples/manual-prune.conf`](examples/manual-prune.conf)

A pure backup store — it receives pushes and creates nothing, so there is no
`[dataset:]` section at all. Retention is written directly with standalone
`[prune:]` sections. Three patterns worth copying:

- **two independent prune rules on one subtree**, each on its own cron and its
  own snapshot-name pattern;
- **a monitor-only carrier** — `[prune:backup/store/hot]` sets `prune = no`, so
  it emits no `delsnaps` line (the recursive parent already prunes that subtree)
  but still emits a staleness check. Repeating the prune rule here instead would
  race the parent on the same snapshots and alert — the loser reports "could not
  find any snapshots to destroy";
- **`[prune-bookmarks:]`** cleaning orphaned send bookmarks on an age threshold,
  unrelated to any snapshot tier. Pick an `age` well past your longest real
  backup gap, or a paused job's still-live bookmark gets pruned too early.

## 5. Safe validation and preview before install

`gen-cron.sh` never writes a crontab as a side effect of reading a config. The
two-step discipline is:

```bash
# 1. Render to stdout and eyeball it. Non-zero exit = the config is rejected.
./gen-cron.sh -c jobs.$(hostname -s).conf

# 2. Diff the proposed managed block against what is installed, THEN install.
#    --install replaces only the managed block atomically, reads it back, and
#    refuses if the staged config no longer matches what it validated.
./gen-cron.sh -c jobs.$(hostname -s).conf --install
```

Always look at the diff before `--install`, especially on a host with live
jobs — a config typo that changes a schedule or a path is caught here, not at
03:00. Unknown field names, blank-but-present fields, `-r`/`-R` smuggled into
`flags`, and same-scope pattern overlaps are all hard errors at generate time,
so a config that renders is a config whose shape has already been checked.

## 6. Deliberate manual customization after preset generation

A preset is CREATE-only: it generates a starting config and then has no further
authority. After that the config is yours to edit, and ordinary lifecycle
operations preserve your edits:

- **reactivation / endpoint or transport change** refreshes only the two
  topology-owned fields (`src`, transport `flags`) in place; it does not
  regenerate policy from the profile. A hand-tuned `keep`, an added tier, a
  custom `prune_schedule` survives an endpoint switch unchanged.
- **an additive CREATE** of a second, non-overlapping relationship appends its
  own sections and leaves every existing section byte-for-byte, refusing if the
  new scope would overlap one already present.
- re-deriving policy from a profile happens only where you explicitly ask for
  it (`migrate-profile`), which previews and confirms before it writes.

So the intended workflow for bespoke policy is: let a preset (or a hand-written
skeleton) generate a valid config once, then edit the config directly and keep
it under version control. Validate with step 5 after every edit.

---

For the exhaustive field-by-field reference (every section type, every field,
merge rules, the recursion model, the reserved-prefix guard) read the header
comment block at the top of [`gen-cron.sh`](../gen-cron.sh).
