# Testing

For the programs themselves see [../docs/en/REFERENCE.md](../docs/en/REFERENCE.md). The design of
the test dependency graph, the reasoning behind it and how to lift it into an unrelated project are
written up in **[GRAPH-TESTING.md](GRAPH-TESTING.md)**.

## Start here: what does this change oblige me to run?

```bash
./test/impact.sh              # uncommitted changes
./test/impact.sh HEAD~3..HEAD # a commit range
./test/impact.sh -f a.sh -f b.sh  # specific files, no git
./test/impact.sh --all        # the full battery, ignoring any diff
```

`impact.sh` reads [`deps.conf`](deps.conf), a hand-written dependency graph, and turns a diff into
a concrete plan: which suites to run (cheap local ones first), which **contracts** to re-check,
and which paths **no suite can cover** and therefore must be exercised by hand. Run it before
deciding you are done; the suites below are what it points at. Listing the obligations is not
running them.

The graph carries three kinds of edge, and only the first is derivable from the code:

- **source edges**: `snapsend.sh` and `snapget.sh` source `lib-zfs-snap.sh`, so a change to the lib
  pulls in both consumers' obligations. `impact.sh` parses these out of the scripts itself and
  `--verify` fails if reality and the graph disagree.
- **suite edges**: which suite exercises which file. Declared, because a suite's subject is a
  variable no parser can follow.
- **contracts**: two files that must agree although neither includes the other. For example,
  `gen-cron.sh` hardcodes `check-snap-age.sh`'s exit codes in the cron lines it emits; `deploy.sh`
  must delegate exactly the ZFS verbs the engines invoke; `delsnaps.sh` duplicates the lib's hold
  tag; the non-root path defaults in the scripts must equal the paths `deploy.sh` provisions.
  Nothing in the code links those pairs, they are where the expensive mistakes live, and no tool
  can infer them, which is why the graph is written by hand and validated rather than generated.

```bash
./test/impact.sh --graph      # mermaid rendering of the whole thing
./test/impact.sh --verify     # drift check (also asserted by the impact suite)
```

`--verify` fails if a declared file is gone, a tracked `*.sh` is missing from the graph, a contract
is listed on one side only, or a derived source edge is absent. **A new script that nobody has
decided about therefore breaks the build**: an unlisted file is an untested file nobody made a
call on.

## The suites

Each suite is a `[suite:NAME]` section in [`deps.conf`](deps.conf) with its command (usually
`./test/NAME/run.sh`; the `gen-cron.sh` config-parsing suite is `./test/run.sh`) and what it
`needs`. A suite whose `needs` is `nothing` runs anywhere with plain bash and coreutils: no root,
no ZFS, no network (run them on Linux: under Git Bash on Windows some suites give false
failures). These cover decisions
(which guest owns a dataset, which cache file, whether a threshold parses, what cron line a config
yields), not mechanism, on purpose. CI runs exactly that set:

```bash
./test/ci-suites.sh          # the suites CI can run, one name per line (computed from deps.conf)
./test/ci-suites.sh --json   # the same as a JSON array
```

A suite joins CI by declaring `needs = nothing`; there is no second list to maintain. The golden
fixtures of `./test/run.sh` are regenerated with `./test/run.sh --bless`; never do that before the
diff of the output has been reviewed as an intentional contract change.

Suites that need more than that:

```bash
sudo ./test/snapsend/run.sh   # snapsend.sh / snapget.sh, LOCAL mode (root, zfs, mbuffer)
sudo ./test/delsnaps/run.sh   # delsnaps.sh, including -B bookmark pruning (root, zfs)
sudo ./test/scenarios/run.sh  # whole workflows: config -> cron line executed verbatim -> snapshot
                              # -> retention -> monitor -> alert; disaster recovery; bookmark fallback
./test/reviewctl/run.sh       # needs a git checkout with origin/main (no root, no network)
./test/remote/run.sh --peer user@other-host   # needs a SECOND host (see below)
```

The root suites run against real, throwaway ZFS pools backed by sparse files. Run them on a spare
pool or a real host, never on a non-ZFS dev machine. Each creates a PID-suffixed pool, redirects
`STATS_LOG` and `LOCKDIR` to a temp directory and cleans up via an `EXIT` trap even if a test fails
partway through. The ssh code paths are deliberately not covered by the single-host suites, since
`validate_remote_host()` refuses a loopback "replication" to the same machine by design.

### The two-host campaign

```bash
./test/remote/run.sh --peer root@other-host
```

This covers the ssh path in both directions, which no single-host suite can reach: snapsend,
snapget and delsnaps, local and remote; plain, `-r`, `-R`, `-X` and `-S`; `-z` on both sides of the
"local sends never compress" rule; `-b`; an incremental re-run that must take the already-exists
path without stranding its hold; and `-K`/`-O`/`-c` ssh option passthrough, including proof that
`-O` takes priority over `-p` (`-O "Port=1"` next to the correct `-p` must fail to connect) and that
a bad `-K` or `-c` fails authentication or negotiation cleanly instead of silently falling back to
something that happens to work. Everything it creates lives under `<parent>/xcamp<PID>`, and an
`EXIT` trap destroys both sides even when a case fails. Options: `--local-parent` and
`--peer-parent` (where to build scratch on each side), `--peer-key` and `--peer-known-hosts`.

Integrity is checked by comparing snapshot GUIDs rather than by mounting and hashing: a GUID match
proves the exact stream landed, and it is the only check that also works for an account that
cannot mount anything.

Run it as root, then again as the delegated account. That second run discharges the
`nonroot-account` obligation below:

```bash
./test/remote/run.sh --peer zfsbackup@other-host --local-parent hdd/backuptest
```

## What no suite covers

Some paths are structurally out of reach of any automated suite, and `impact.sh` names them when a
change touches them rather than letting a green summary imply otherwise. They are the
`[manual:NAME]` sections of [`deps.conf`](deps.conf), each with a `why` and a `how`. The two that
apply to the engines:

| Obligation | Why no suite can do it |
|---|---|
| `nonroot-account` | A delegated account cannot mount (no `CAP_SYS_ADMIN`, and no `zfs allow` grants it) and cannot read `/root`, so **root cannot reach these failures at all**. Run the two-host campaign as that account with no environment overrides; a multi-level target path that does not exist yet is the case that bites |
| `force-full` | `-f` and `-F` destroy and recreate the target. Root-only and destructive by nature, so done on a throwaway target only; confirm the Proxmox-reserved-snapshot refusal still triggers |

The first row is not theoretical: a single run as the delegated account once found four defects
that a fully green root suite had missed (`zfs create -p` mounting intermediates, `/root`-based
path defaults, a missing `bookmark` delegation, a hold leaked on every pre-transfer failure).

The other manual obligations cover live hardware and live hosts (`mediagate-live`, `pairgate-live`,
`monitor-live`, `quiesce-helper-live`, `deploy-check-only`, `zfsbackup-live-pair`,
`rux-live-chain`, `moveclient-live`, `crontab-diff`) and the `project-status` update. Read the
section for the one `impact.sh` names.
