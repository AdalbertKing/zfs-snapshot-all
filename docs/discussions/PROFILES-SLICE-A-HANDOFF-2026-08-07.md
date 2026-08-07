# Profiles Slice A — fixture landed, test+graph must land atomically

Date: 2026-08-07
Status: **IMPLEMENTATION HANDOFF — fixtures on main, runtime unchanged**

Owner asked to proceed with the agreed optional native-fragment profile design.
Reviewer implemented the fixture half of Slice A directly on `main` under the
active owner-approved direct-main exception.

## Landed fixtures

Current built-in default fixture:

- `profiles/default/templates.conf`
- `profiles/default/dataset.inc`
- `profiles/default/prune.inc`

They intentionally mirror the current `zfs-backup.sh` hardcode and are NOT read
by runtime yet.

Important boundaries already encoded in the files:

- `dataset.inc` contains `use_template = standard_hourly`; it deliberately does
  NOT add explicit `recursive = no`, because today's generated CONFIG omits it
  and Slice B requires byte-identical CONFIG before/after extraction.
- `prune.inc` contains the retention/GFS policy but deliberately does NOT contain
  `recursive = yes|no`; concrete prune topology belongs to orchestration because
  backup and sync have different safe shapes.
- no relationship-owned `src`, `dst`, `flags`, `pair_label`, `notify`, endpoint,
  account, target or grant facts are present.

## Prepared contract test

Commit `73045e73fdf7417ec8e803e7bf3157029d82bfa3` contained a first
`test/profiles/run.sh`. Its tracked executable bit was corrected in follow-up
`72896f27c8aa4a11985f7cd8ae96a4e582fd959e`.

The test was then removed from `main` in `565c7e9b1f9730eabfa75c80e71450053567cb5a`
ON PURPOSE: `test/impact.sh --verify` requires every tracked shell test to be
registered in `test/deps.conf`. Leaving the test committed first and the graph
fix for later would deliberately make the repository's mandatory gate red.

Reintroduce the test and its graph entries in ONE logical delivery.

The prepared test does these things:

1. calls the real `gen-cron.sh --dump-fields` — verified present on current main;
2. validates `.inc` fields from that derived schema rather than duplicating the
   generator's allow-list;
3. subtracts only relationship-owned fields (`src`, `dst`, `flags`,
   `pair_label`, `notify`) and prune-topology `recursive`;
4. refuses section headers inside `.inc` fragments;
5. composes the default fragments into a complete temporary CONFIG v4 and asks
   the real `gen-cron.sh` to accept it;
6. pins the current default H24/D7/W4/M12, schedules, prefix and monitor values;
7. has negative controls for relationship-owned `src`, prune `recursive`, an
   unknown field and a section header.

Claude may reuse that exact file from commit `73045e73...` or improve it, but do
not weaken those properties.

## Required `test/deps.conf` integration

At minimum add:

```ini
[file:profiles/]
suites    = profiles
contracts = profile-config-schema
note      = built-in native CONFIG v4 profile fragments; runtime consumes none
            of them in Slice A.

[file:test/profiles/run.sh]
suites = profiles

[suite:profiles]
cmd   = ./test/profiles/run.sh
needs = nothing
covers = native profile fragments are derived from gen-cron's real field schema,
         relationship/topology-owned fields are refused, the default fragments
         compose into a valid CONFIG v4, and negative controls discriminate the
         forbidden shapes.
```

Also:

- add `profiles` to `[file:gen-cron.sh] suites`, because `--dump-fields` / CONFIG
  schema changes must exercise the native-fragment contract;
- add `profiles/` to `[contract:profile-config-schema] members` and keep
  membership symmetric;
- keep the existing `zfsbackup` profile-schema checks: Slice A supplements them,
  it does not replace them.

Directory sections ending in `/` are supported by `impact.sh`; contract
membership can name the declared `profiles/` file-section directly.

## Required proof before Slice B1

Run and record:

```bash
./test/profiles/run.sh
./test/impact.sh --verify
```

Then run the plan selected by `./test/impact.sh <base..HEAD>`; do not broaden to
a full ZFS campaign because Slice A changes no runtime behavior.

Before B1, capture the pre-change generated artifacts for the **backup** shape
(control first): effective CONFIG v4 and rendered cron. B2 will repeat the same
proof independently for **sync**.

No production runtime file should consume `profiles/default/*` until Slice A's
contract test and graph are green.
