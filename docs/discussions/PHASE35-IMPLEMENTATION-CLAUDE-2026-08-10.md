# Phase 3.5 implementation — prefixless create / passive (`-e`) / single-series GFS

Date: 2026-08-10. Implements
`docs/discussions/GATE3-PHASE35-REVIEWER-RESOLUTION-2026-08-10.md` on top of
base commit `8693b4e3543f166e44a402ac71dd1c7f7d0de1b8` (the reviewed Gate 3 /
Phase 3.5 planning delivery, docs-only).

## What changed

`gen-cron.sh` gained one new function, `resolve_field_or_omit()`, placed
right after `require_field()`:

```bash
resolve_field_or_omit() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4" val
    if val="$(resolve_field "$field" "$ds" "$tmpl" "$defaults")"; then
        [ -n "$val" ] || return 1
        printf '%s' "$val"
    fi
    return 0
}
```

It reuses `resolve_field()`'s existing return-code distinction (not-found-
anywhere = rc 1, found-but-blank = rc 0 with an empty string) exactly as the
reviewer's resolution specified — no new state was invented:

- unresolved anywhere across the ds/tmpl/defaults (or section/defaults)
  chain → prints `""`, returns 0 (the new, deliberate no-prefix /
  prefixless-GFS case);
- resolved but blank → returns 1, so the caller's `|| die "..."` still fires,
  unchanged from `c90f6d1`.

Two call sites switched from `require_field` to this:

- `prefix` (send/create, `gen-cron.sh` build_dataset tier loop) — was: `||
  die "...did not resolve (missing, or set but blank)"`. Now: unresolved
  omits the field (prints `""`), resolved-blank still dies with a message
  naming the distinction explicitly.
- `gfs_pattern` (`build_prune_section`, only reached when `gfs=yes`) — same
  shape.

`pattern` was **not** touched — it still calls `require_field` exactly as
before, per the reviewer's explicit instruction that the ordinary
non-GFS/non-send pattern contract is not relaxed by this phase.

`require_field()`'s own doc comment was updated (used to say 'prefix' and
'gfs_pattern' have no sensible empty meaning — no longer true; `gen-cron.sh`
is not frozen, so no authorization is needed to edit it).

**Found but deliberately NOT fixed: a stale comment in `snapsend.sh`.** Its
"no -m given" warning carries a comment claiming "every gen-cron.sh generated
line is safe from this -- 'prefix' is a required field there" — that sentence
is no longer true after this phase. `snapsend.sh` is a frozen engine file
(`docs/project/ENGINE-FREEZE.md`), and the freeze requires a review to
authorize a change **before** implementation, with a reviewer-owned
`<!-- authorizes-frozen: -->` marker naming the path — not something an
implementer can self-grant, and not something a comment-only diff is exempt
from (confirmed by actually attempting the edit and running
`./test/impact.sh --verify`, which correctly refused it: "FROZEN. snapsend.sh
changed, and nothing authorises it."). Reverted rather than routed around.
Flagging it here for the reviewer to decide: either open a REV authorizing
this specific comment fix (trivial, no behavior change), or leave it — the
comment is now misleading but not load-bearing for anything, since the
underlying engine behavior it describes was already correct and unchanged.

No change to `delsnaps.sh`, `snapsend.sh` (behavior), or `snapget.sh`: all
three engines already accepted an empty `-m`/positional-pattern argument
identically to it being omitted, confirmed by reading the code before
touching anything (see "Engine-side verification" below), matching the
Owner's own framing that this phase only removes an artificial generator-side
narrowing.

## Downstream effects checked, not just assumed

- `snapsend.sh`/`snapget.sh` command construction (`gen-cron.sh:1758`,
  `:1702`) always interpolates `-m "$prefix"` unconditionally; with
  `prefix=""` this becomes a literal `-m ""` in the generated line —
  confirmed by reading `snapsend.sh`'s own `MESSAGE=""` default and its
  `[ -z "$MESSAGE" ]` warning gate, which treats "never given" and "given as
  empty" identically. No generator-side conditional needed.
- `delsnaps.sh -G` command construction (`gen-cron.sh:1839`) always
  interpolates `"$pattern"` as its own quoted positional argument; with
  `gfs_pattern=""` this becomes the literal empty positional argument the
  reviewer's resolution asked for (`delsnaps.sh ... "" -G -H24 ...`).
  `delsnaps.sh` never validates a minimum pattern length — confirmed by
  reading its argument-parsing section (`datasets_list="$1"; pattern="$1"`,
  no non-empty check) — so this was already accepted, not newly tolerated.
- `validate_retain_patterns()` / `SCOPE_PATTERNS` (the same-scope
  pattern-overlap guard, BEGIN 3.7): an empty `gfs_pattern` is a member of
  `SCOPE_PATTERNS` like any other pattern. Bash glob matching means
  `[[ "$pj" == ""* ]]` is true for any `$pj` (an empty pattern followed by
  `*` is just `*`), so a prefixless GFS ladder colliding with another prune
  rule on the same scope is still caught by the existing guard, unchanged —
  confirmed by reading the exact `[[ ... == ...* ]]` comparison, not assumed.
- `test/run.sh`'s own "allow-list vs the lookups in the code" self-check
  (the `declared`/`used` field-coverage grep) needed
  `resolve_field_or_omit` added to its pattern alternation, or the two new
  call sites would silently stop contributing to that check's coverage.
  Fixed. While doing this, two of my own new prose comments turned out to
  false-positive against that same grep (a function name immediately
  followed by an ordinary lowercase word on the same source line reads as a
  fake "field lookup" — e.g. "resolve_field wherever" got scraped as field
  `wherever`, "require_field always" as field `always`). Reworded to put a
  parenthesis or punctuation immediately after every prose mention of a
  resolver function name; re-verified with the exact grep the suite runs
  before moving on.

## Test evidence

`test/run.sh` (the gencron suite), full run: **67/67**, up from 64/64 on the
pre-change base (3 new: 2 new goldens, 1 new negative; `blank-prefix`'s
`.err` substring was updated to match the new, more specific die message,
still pinning the same refusal).

New/changed fixtures:

- `test/fixtures/prefixless-matrix.conf` (new golden) — one fixture, four
  datasets, covering all four create/existing × prefix/no-prefix cells in
  one generated block: `create-prefixed`, `create-noprefix`,
  `existing-prefixed` (`flags = -e`), `existing-noprefix` (`flags = -e`).
  Verified by hand before writing `.expected` (not blessed blindly): the
  two no-prefix cells render `snapsend.sh -m ""` — with and without `-e` —
  and the two prefixed cells are byte-unchanged from what `require_field`
  always produced.
- `test/fixtures/gfs-no-pattern.conf` (new golden, **was**
  `test/negative/gfs-no-pattern.conf`) — `gfs=yes` with `gfs_pattern`
  omitted entirely used to be refused; it is now the accepted prefixless-
  ladder case. Moved rather than duplicated, with a comment explaining the
  move. Verified output: `delsnaps.sh -G "tank/store" "" -H24` — the exact
  empty positional pattern the reviewer's resolution specified.
- `test/negative/blank-gfs-pattern.conf` (new negative) — `gfs_pattern = `
  (present, blank) still refuses. No such case existed before (only
  entirely-missing `gfs_pattern` had a negative fixture, and that case
  changed meaning), so this is genuinely new coverage, not a duplicate.
- `test/negative/blank-prefix.conf` / `.err` — fixture unchanged; `.err`
  updated because the die message changed from a generic "did not resolve"
  to one that names the blank-vs-omitted distinction explicitly. Still
  pins the same refusal.
- `test/run.sh` itself — the field-coverage grep pattern, see above.

Negative control against the pre-Phase-3.5 generator — `git show
8693b4e3543f:gen-cron.sh` run via `GEN=` against the current fixture set:

```
FAIL golden/gfs-no-pattern        (old generator refuses; new one accepts)
FAIL golden/prefixless-matrix     (old generator refuses the two no-prefix cells)
FAIL negative/blank-gfs-pattern   (old generator's message text differs, but still rc=1 -- confirmed manually below)
FAIL negative/blank-prefix        (same -- message text differs, still rc=1)
PASS=63 FAIL=4
```

The two golden failures are the change itself, demonstrated: the exact
config that now produces a valid cron line used to be a hard refusal. The
two negative "failures" are message-text mismatches only — confirmed by
running the old generator directly against both blank fixtures:

```
$ bash /tmp/gen-cron-old.sh -c test/negative/blank-prefix.conf
gen-cron.sh: error: [dataset:tank/vm1] tier=hourly: send_schedule is set but 'prefix' did not resolve (missing, or set but blank)
rc=1
$ bash /tmp/gen-cron-old.sh -c test/negative/blank-gfs-pattern.conf
gen-cron.sh: error: [prune:tank/store]: gfs=yes needs 'gfs_pattern' ...
rc=1
```

Both still refuse (rc=1) under the old generator too — the blank-vs-omitted
distinction is not new *behavior* for the blank case on either side of the
change, only the message wording changed, which is exactly what the new
`.err` files pin going forward.

Dependency-selected cascade, per `test/impact.sh` run against the actual
staged diff (not guessed from `test/deps.conf` by hand):

| suite | result |
|---|---|
| `test/run.sh` (gencron) | 67/67 |
| `test/migrate/run.sh` | 52/52 |
| `test/profiles/run.sh` | 55/55 |
| `test/reconcile/run.sh` | 47/47 |
| `test/zfsbackup/run.sh` | see below |
| `test/cron2conf/run.sh` (cron-line-shape contract) | 11/11 |

`sudo ./test/scenarios/run.sh` (needs root, zfs, mbuffer) was **not
executed** — this environment has none of the three. Flagged as a manual
obligation per the impact graph's own output, not silently skipped.

## Bare-passive (`-e`, no `-m`) engine test

The scope note's own open item ("one small addition to
`test/snapsend`/`test/snapget` for the bare-passive cell, the only one of
the four with no direct test evidence") turned out to already be closed by
the time this phase started implementation — re-checked against the current
tree rather than trusted from the older assessment doc, since that doc is
now a week stale relative to `main`:

- `test/snapsend/run.sh`, "`-e` with no `-m`" section (around line 331):
  creates a real snapshot by another name, runs `snapsend.sh -e` with no
  `-m`, asserts exit 0, asserts the "no -m given" warning does **not** fire,
  and asserts the pre-existing snapshot (not a new one) is the one that
  actually reached the target.
- The same file's snapget/pull-direction section, "snapget `-e` with no
  `-m`" (around line 490): identical assertions for the pull direction.

Both need real ZFS and were **not re-run in this environment** (no ZFS on
this Windows dev box) — this is pre-existing coverage from an earlier
change, not something this delivery added or needs to add. Live
confirmation that these still pass on a real host remains an open manual
item, same status as `sudo ./test/scenarios/run.sh` above.

## What this delivery does NOT do

- Does not add a `snapshot_mode=` field. Passive stays `flags = -e`, per the
  reviewer's §3.
- Does not touch `pattern`/`require_field` for ordinary (non-GFS) prune —
  per the reviewer's §2 closing sentence, explicitly out of scope.
- Does not touch any engine file (`snapsend.sh`/`snapget.sh`/`delsnaps.sh`/
  `lib-zfs-snap.sh`/`check-snap-age.sh`) at all — all five are frozen
  (`docs/project/ENGINE-FREEZE.md`) and none of this phase's required
  behavior needed a frozen-file change; `./test/impact.sh --verify`'s
  engine-freeze check passes clean against the committed diff. A
  documentation-only edit to a stale `snapsend.sh` comment was attempted,
  correctly refused by that same check, and reverted rather than
  authorized around — see the note above.
- Does not run a live ZFS/host campaign — the reviewer's resolution §5
  explicitly says none is required "if implementation remains
  generator/config/test-only and the generated commands exercise
  already-existing engine semantics," which is the case here.

## Remaining risk / open items

- `sudo ./test/scenarios/run.sh` and the bare-passive `test/snapsend`
  sections have not been re-run on real ZFS in this delivery. Recommend
  running both on a real host before this is treated as fully verified,
  even though nothing in this diff should change their outcome.
- `docs/PROJECT_STATUS.md` refreshed alongside this delivery (see the
  updated row and version table); `./test/impact.sh --refresh-status` run
  against the staged diff.
- This is registered as an unreviewed direct-main delivery in
  `docs/project/DELIVERIES.md`, same protocol as Phase 2 property 6 and
  every other delivery this session. Gate 3.5 closure is the reviewer's
  call, not mine to declare.
