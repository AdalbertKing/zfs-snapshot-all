# Claude's assessment — prefixless create/passive + single-series GFS

Date: 2026-08-09. Response to `docs/discussions/PREFIXLESS-PASSIVE-GFS-OWNER-DIRECTION-2026-08-09.md`.

I verified the engine-facts section against the actual code before answering
— all of it checks out, with one refinement on test coverage (item 5).

## Verification performed

- `-e` exists in both engines' real `getopts` strings (`snapsend.sh:1578`,
  `snapget.sh:1583`) and sets `USE_EXISTING_SNAPSHOT=1` — not a new or
  hypothetical flag.
- Create-with-no-prefix is **already live, already shipped** behavior:
  `snapsend.sh:1726` — `[ -z "$MESSAGE" ] && [ $USE_EXISTING_SNAPSHOT -ne 1 ]`
  — only **warns** ("no pattern-based delsnaps.sh retention job will ever
  match it"), never refuses. `gen-cron.sh`'s `require_field prefix`
  (`gen-cron.sh:1253`) is the only place that turns this into a hard error —
  confirmed the restriction is generator-only, exactly as the note claims.
- `gfs_pattern` is the same shape: `require_field gfs_pattern`
  (`gen-cron.sh:1369`) refuses blank, while `delsnaps.sh`'s own `-G` usage
  line (`delsnaps.sh:162`) documents an empty-pattern invocation as a normal,
  supported example, not an edge case.
- `-m "$prefix"` is interpolated directly into the generated command
  (`gen-cron.sh:1702`, `:1758`); `snapsend.sh`'s own default is
  `MESSAGE=""`, so `-m ""` and omitting `-m` entirely are already the same
  state to the engine. The generator does not need to conditionally drop the
  flag — it can always emit `-m "$prefix"` and let blank mean blank.

## 1. Earliest safe phase/commit boundary

Agree with the Reviewer's estimate, with one addition: **analysis and test
design can start now**, in parallel with REV-088 verification, because the
change surface is `gen-cron.sh` + `test/gencron`, which REV-088/Gate 2 does
not touch. Production implementation (the actual `require_field` →
`resolve_field` relaxation and the two `die`-removals) should wait for Gate
2 to close, since operating rule 1 says not to start a later phase while an
earlier gate is open, and this capability is closer to Phase 3/4 territory
than a Gate-2 fix.

## 2. Phase 3.5 or inside Phase 4

**Small Phase 3.5, not folded into Phase 4.** This change is entirely about
what native CONFIG/`gen-cron.sh` is *allowed to express* — a schema
relaxation, independent of Phase 3's actual subject (reactivation must
preserve installed policy) and independent of Phase 4's actual subject
(exposing `--profile=` as a public choice). Bundling it into Phase 4 risks
exactly what the Reviewer already named: shipping the public preset UX on
top of a generator that still can't express prefixless/passive, then having
to revise that public surface immediately after. Landing it as its own
narrow phase between 3 and 4 means Phase 4 starts from the corrected
schema and never has to know the restriction existed.

## 3. Estimated change surface

- `gen-cron.sh`: two call sites (`require_field prefix` → `resolve_field`,
  same for `gfs_pattern`), plus whatever conditional logic decides when the
  passive/`-e` flag is emitted (see question 4).
- `test/gencron/run.sh`: the four create/existing × prefix/no-prefix
  combinations at the generated-command boundary, plus prefixed and
  prefixless GFS renderings, plus negative controls against the current
  generator (must show it rejects what the new one accepts).
- `test/profiles`: only if the built-in default profile's shape needs to
  change to exercise this — it should not, since the default profile stays
  prefixed and this is an additive capability, not a default-behavior
  change.
- Dependency-driven cascade per `test/deps.conf`'s current
  `[file:gen-cron.sh]` entry (`gencron, scenarios, zfsbackup, migrate,
  profiles, reconcile`) plus `./test/impact.sh --verify` — most of that
  cascade should come back unaffected, since existing prefixed behavior is
  preserved byte/semantically, but the graph decides that, not my guess.

No `zfs-backup.sh` change is expected unless question 4 resolves toward a
new first-class field zfs-backup.sh's own profile/emit layer would need to
recognize.

## 4. Preferred CONFIG representation, and the strongest argument against it

**Preferred: keep expressing existing/passive through `flags = -e`, add no
new field for now.** Reasons:

- it already exists, already means exactly this, and needs zero schema
  growth in `gen-cron.sh --dump-fields`, `lib-profile.sh`'s field
  allow-lists, or documentation;
- avoids "two independent ways to state the same policy" — the note's own
  explicit constraint — since a new `snapshot_mode=` field would coexist
  with the `flags = -e` escape hatch that already reaches the same engine
  behavior, and the two would need to be kept consistent forever;
- matches "avoid a new mini-DSL if a small existing representation is
  sufficient" — there is nothing here that `flags` cannot already express.

**Strongest argument against this choice:** Phase 4 explicitly exists to
make presets legible to an administrator who should not need to know `-e`
is the flag that means "use what's already there." A preview built for that
audience showing `flags = -e` buried in a flags string is a worse
operator-facing artifact than a self-documenting `snapshot_mode = existing`
line would be — and retrofitting a friendly field name onto an
already-public preset surface later is a real cost, not a hypothetical one
(this project has now hit that exact "should have named it clearly the
first time" shape more than once this session — REV-088's own F1 is a
close cousin: a boundary drawn one layer too low). If the Owner or Reviewer
weighs discoverability for the *public* Phase 4 surface higher than schema
minimalism for the *current expert-only* surface, a first-class field is
the more defensible choice, and it is cheap to add now rather than after
Phase 4 ships.

Given the Owner did not require a spelling and Phase 4 has not started, I
would defer this specific sub-decision to when Phase 4's actual preview UX
is designed, rather than deciding it now for a capability that currently
has no public-facing consumer. Flagging that I could be wrong to defer it,
per the instruction to give the strongest argument against my own answer.

## 5. Existing evidence — partial, not complete

`test/snapsend/run.sh` already covers `-e -m PREFIX` thoroughly (anchors on
the newest snapshot **matching** the prefix, not overall-newest; a
non-matching prefix is a real error, not a silent full send). It does
**not** currently have a case for bare `-e` with no `-m` at all — the
"existing/passive + no prefix" cell of the matrix — though the code path
(`USE_EXISTING_SNAPSHOT` with empty `MESSAGE`) already exists and is
already reachable by hand today, just not through `gen-cron.sh`.

So: the engine behavior for three of the four matrix cells has direct test
evidence already; the fourth (bare passive, no prefix) is a **small,
local** test gap in `test/snapsend`/`test/snapget`, not a live-ZFS
unknown — the code exists, it is just untested at the moment. Closing that
gap belongs with this work (it is exactly what the note's own "prove all
four combinations" requirement asks for) but does not require a new host
campaign: it is the same local, ZFS-backed but non-production
`test/snapsend`/`test/snapget` harness already used for the other three
cells.

## Summary recommendation

1. Design/test work may start now, alongside REV-088 verification.
2. Land as its own small Phase 3.5, between the current Phase 3 and Phase 4.
3. Change surface: `gen-cron.sh` (2 field-requirement relaxations),
   `test/gencron`, one small addition to `test/snapsend`/`test/snapget` for
   the untested bare-passive cell, dependency-driven cascade + `--verify`.
4. Keep `flags = -e` for now; revisit a first-class field only when Phase
   4's actual preview design needs it — with the discoverability argument
   above on record in case that call should go the other way.
5. No new live ZFS campaign needed; one small local test addition closes
   the only real coverage gap.

---

## Addendum, found starting test design — a real tension with `require_field`'s own history

`test/negative/blank-prefix.conf` already exists, and already pins the
CURRENT refusal as correct behavior. It was not written as an arbitrary
restriction: `git log` on that file leads to `c90f6d1`, "Treat a blank
config value the same as a missing one for pattern/retain/prefix" —
`gen-cron.sh`'s own `ini_has()` tests whether a key was written at all, not
whether its value is non-empty, so a config-authoring typo like
`prefix = ` (nothing after `=`) used to silently resolve as "present" and
sail through the old "required field" check, which only guarded against
the key being ABSENT. Confirmed live at the time: it produced exactly the
bare-timestamp/empty-pattern/no-threshold accidents this direction note now
asks to make reachable on purpose. This is not a coincidence — it is the
same failure shape, described almost word-for-word in both documents.

Naively relaxing `require_field prefix`/`require_field gfs_pattern` to
accept blank would silently reopen that exact accident vector: nothing in
the CONFIG file distinguishes "administrator deliberately wants no prefix"
from "administrator meant to type one and left it blank by mistake" — both
produce byte-identical `prefix = ` text.

**There is a real distinction already sitting in the code, unused for this
purpose.** `resolve_field()` returns two genuinely different states:
*not found anywhere* in the dataset/template/defaults chain (return 1) vs.
*found, but blank* (return 0, empty value) — `require_field` currently
collapses both into one refusal. Recommendation: use that existing
distinction as the signal, rather than inventing a new one:

- the field **entirely omitted** (no `prefix =`/`gfs_pattern =` line
  resolves anywhere for this dataset/template/prune section) → the new,
  deliberate "no prefix"/"no pattern" case, now accepted;
- the field **present but blank** (`prefix = ` with nothing after `=`) →
  **stays a refusal**, unchanged from `c90f6d1`, because that is precisely
  the config-typo shape already measured to be dangerous and silent.

This reaches every cell in the owner's matrix (a profile/preset simply
does not emit a `prefix =` line at all for the no-prefix case, which is a
natural fit for how profiles already compose fragments) while adding zero
regression risk to the original fix — `test/negative/blank-prefix.conf`
itself would be **unchanged and still passing** under this design, since it
tests the present-but-blank shape, not the omitted one. A new golden case
for "template genuinely has no `prefix` field" would be the positive
counterpart.

This changes question 3's estimate slightly: the `gen-cron.sh` change is
not `require_field` → `resolve_field` (which would blur the two states),
but a small explicit branch that checks `ini_has` before deciding whether
blank/absent is acceptable — still narrow, still no new parser, but worth
recording precisely since it is different from what I proposed at first.
