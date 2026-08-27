# Implementer error log

Owner instruction, 2026-08-27: every mistake the implementer makes is recorded
here with its **genesis**, its **cause** and the **rule** it produces; the file is
read **before every work round** and the rules applied. A derivative of this
project is intended as training material for how to implement changes, so the
entries are written to teach, not to apologise.

## How to use this file

**Read section 1 before starting a round. That is the whole obligation.** The
rules are short on purpose. The entries below them exist to prove each rule was
paid for, and to be read when a rule seems arbitrary — never as a reading list.

When a new mistake happens: add an entry, then ask whether it fits an existing
rule. If it does, add it to that rule's evidence and **do not invent a new rule**
— a repeated mistake under an existing rule is a much more important signal than
a new category, because it means the rule is not being applied.

---

## 1. The rules

### R1 — Prove the guard can be reached, not that it exists

A refusal that cannot execute is worse than no refusal: it reads as protection in
review and provides none. Before trusting any guard, construct the input that
should trigger it and watch it trigger.

Applies to: `if` conditions, loop shapes that decide whether a case is ever
constructed, assertion helpers, and error paths.

*Evidence: E1, E2, E3, E9.*

### R2 — A fact is true on ONE side of a boundary until measured on the other

Boundaries in this project: local vs remote host, branch vs `main`, index vs
working tree, my lab residue vs the estate's real state, this process vs another.
State the side you measured on. Never carry a conclusion across.

*Evidence: E4, E5, E6, E10.*

### R3 — A rule written in a comment is not applied by being written

When a comment states an invariant, grep for every site that should honour it and
check each. The gap between "the project knows this" and "this line does this" is
where the defects live.

*Evidence: E7, E2.*

### R4 — Never chain a mutation behind a step that can fail silently

`cmd_a && git add` is safe only if `cmd_a` fails loudly AND non-zero. Scripts
that print an error and exit 0, string replacements that match nothing, helpers
that do not exist — all of these continue the chain. Verify the intermediate
state, then mutate.

*Evidence: E8, E3.*

### R5 — Do not modify state something else is reading

Bash reads a script incrementally while executing it. Editing a suite mid-run
corrupts it from that offset. The same holds for a config another process is
sourcing, and for a branch a running job has checked out.

*Evidence: E11.*

### R6 — A green result is evidence only if you know what it should have printed

Count the assertions you expect by name and compare against the output. A total
that only goes up cannot tell you an assertion never ran.

*Evidence: E3, E9.*

### R7 — Reproduce a fix's absence, not just its presence

Every fix ships with the failing control against the exact prior SHA. If the
control cannot be built, the fix is not understood well enough to ship.

*Evidence: applies to every entry; enforced by the review protocol.*

### R8 — Prefer the tool's own helper over a fresh implementation, and check it exists first

Before adding a flag, a parser or a knob: grep for one. Before using a test
helper, confirm the suite defines it. Before writing a resolver, check what the
renderer already uses.

*Evidence: E7, E3, E12.*

### R9, R10, R11 — on running suites

Stated with their measurements in section 2b, because the case for them is the
cost data rather than an argument:

- **R9** — run locally only a suite you edited; everything else goes to CI.
- **R10** — verify a suite's targeted mode works before paying for the full run.
- **R11** — never edit a suite that is running, or run one you are still editing.

---

## 2. The entries

### E1 — `--allow-restore=` with an empty value provisioned the host
**2026-08-27, restore grant.**

*Genesis.* The three grant verbs were dispatched with `if [ -n "$LABEL" ]`. A
typo — `--allow-restore=` with nothing after it — left the label empty, the
dispatch did not fire, and `deploy.sh` fell through to Phase 1 and began
installing packages. A verb answering a **permission** question was rebuilding
the machine on its way past.

*Cause.* The presence of a flag and the value of a flag were the same variable.
The empty case was representable and unhandled.

*Rule.* R1, and a concrete idiom: track "was it given" separately from "what was
it" (`*_GIVEN`), which this codebase already does for `--bandwidth`. Reviewer
finding F4 of 2026-08-26 was the same shape on `--commit-scope`; it recurred
through a typo three commits later.

### E2 — A refusal the loop could never reach (REV-20260827-122 F2)
**2026-08-27, restore scope parser.**

*Genesis.* The comment above the guard said a list ending in `,` must be refused.
The loop ran `while [ -n "$rest" ]`, so for `a,` it resolved `a`, emptied the
tail, and exited **before** constructing the empty final member the guard tested
for. The doubled-comma case passed, so coverage looked complete.

*Cause.* The guard was written against the *idea* of the input; the loop's exit
condition decided which inputs could ever exist.

*Rule.* R1 and R3. The existing test passing next door is not coverage of the
neighbouring case — enumerate the shapes (leading / doubled / trailing / only a
separator) and run each.

### E3 — Seven assertions that were never assertions
**2026-08-27, `test/zfsbackup` section 122.**

*Genesis.* I wrote `check "<desc>" "<want>" "<got>"` in a suite that defines only
`ok` and `bad`. Bash printed `check: command not found` to stderr; the counters
never saw them. The run reported `PASS=138 FAIL=0` while the assertion carrying
the entire finding had not executed. It was about to be submitted as proof of a
P1 fix.

*Cause.* I assumed a helper by habit from another suite instead of reading this
one's harness.

*Rule.* R8 (confirm the helper exists) and R6 (diff the expected label list
against the output — three of ten present is what exposed it).

### E4 — A PR closed on reasoning about the wrong branch
**2026-08-27, PR #62.**

*Genesis.* I closed it stating that the three-file profile layout "no longer
exists" and that `prod.conf` already ships its content. Both were true of
`stage/profile-one-file` — **unmerged** — and false of `main`, which is what that
PR targeted. The outcome was right; the stated reason was not.

*Cause.* I had been working on the branch all day and read its tree as the
project's state.

*Rule.* R2. Before making a claim about what a repository contains, name the ref
and read it (`git show <ref>:<path>`). The correction was posted publicly on the
PR rather than quietly amended.

### E5 — "The collector connects hourly" — it had zero jobs
**2026-08-26, lab reasoning.**

*Genesis.* Two design arguments about restore rested on pve9 connecting to pve1
every hour. It did not: pve9 had no jobs at all and every relationship record
read `STATE=removed`. The owner challenged it with one word ("Napewno?").

*Cause.* A plausible property of the design was reported as an observed fact.

*Rule.* R2. State the command that produced the fact, or do not state the fact.

### E6 — Trust that was my own residue
**2026-08-26, lab reasoning.**

*Genesis.* I argued from root↔root trust existing between two lab hosts. It
existed because my own earlier labs had run as root and left it there.

*Cause.* Measuring an environment I had contaminated, without asking what had
put the property there.

*Rule.* R2, and its sharper form: when a convenient precondition is found, ask
what created it before building on it. The lab was rebuilt from zero.

### E7 — A rule stated in the code, ignored by three sites (REV-20260827-122 F1)
**2026-08-27, profile migration.**

*Genesis.* `profile_name_of`'s comment says the profile name "has to survive
being given as a path and must never carry a '/'". The renderer applied it. The
template-removal loop and two schedule-stagger lookups interpolated the raw
string instead, so a profile given by path matched nothing — silently keeping the
old retention while recording the new digest.

*Cause.* The invariant lived in a comment next to one helper rather than in the
call sites that depended on it.

*Rule.* R3 and R8. The reviewer named one site; grepping the invariant found
three. When a review names an instance, look for the class.

### E8 — Conflict markers committed because `git add` ran behind a failed script
**2026-08-27, rebase of #162.**

*Genesis.* A Python resolver failed on a CRLF mismatch (its `assert` raised), but
the shell chain continued into `git add` and `git rebase --continue`, committing
a file full of `<<<<<<<` markers.

*Cause.* Two errors compounding: matching a multi-line string against a CRLF file,
and chaining a mutation behind a step whose failure I did not check.

*Rule.* R4. The rebase was aborted, the resolver rewritten to work on **lines**
rather than one string, and a guard added that refuses to stage while any tracked
file still carries a marker.

### E9 — A variable that did not exist, in a message on a refusal path
**2026-08-27, restore grant check.**

*Genesis.* A refusal message interpolated `${_rg_replace_hint}`, which was never
defined. Under `set -u` it would have aborted the very path meant to explain a
refusal — reached only when something had already gone wrong.

*Cause.* A draft placeholder left in code that looked finished.

*Rule.* R1 and R6. Error paths need the same execution as success paths; it was
caught by reading the function before splicing it, not by any test.

### E10 — A negative control that could not load its own libraries
**2026-08-27, REV-122 evidence.**

*Genesis.* To prove a regression fails on the prior SHA, I extracted the old
`zfs-backup.sh` to `/tmp` and pointed the suite at it. It resolved its libraries
relative to its own location, found none, and the run died before reaching the
section under test — producing a "result" that measured nothing.

*Cause.* Moving a file out of the tree changed a property the file depends on.

*Rule.* R2 (the copy is not the original) and R6 (the run "completed" — only the
missing section labels showed it had not). Re-run with the old file placed inside
the repo, and deleted in the same command.

### E11 — Editing a suite while it was running
**2026-08-27.**

*Genesis.* I edited `test/zfsbackup/run.sh` to hoist two helpers while a
ten-minute run of that same file was in flight. Bash re-read from a shifted
offset and executed garbage (`line 5199: --section: command not found`). The
result was void, and briefly looked like a real failure.

*Cause.* Treating a running script as a static artifact.

*Rule.* R5. Nothing that a background job reads may be modified until it exits.

### E12 — About to modify a frozen engine for a knob that already existed
**2026-08-27, restore recovery point.**

*Genesis.* I concluded that `snapsend.sh` had no way to send a chosen snapshot
(`-e` takes the newest) and proposed adding a flag to a frozen engine. The owner
asked whether we had not already provided for it. We had: `-e` filters the
candidate list by `-m` first, so a full snapshot name as `-m` selects exactly
one.

*Cause.* I read the flag's summary line instead of its implementation.

*Rule.* R8. Before extending a frozen file, read the code path, not the usage
text. Measured afterwards and worth carrying: `-m` is used as a **regex**
(`grep "^$MESSAGE"`), so a name containing `.` can over-match — handled in the
restore layer by requiring exactly one match, without touching the engine.

---

## 2b. Suite runs — was it worth it, and at what scale

Owner instruction, 2026-08-27: *"Mierz też zasadność puszczania suit i w jakiej
skali. Na tym stajemy realnie."* This is the largest single drain on a working
day, so it is measured here rather than argued about.

Record for every LOCAL suite run: why it was run, roughly what it cost, and
**what it found**. A class of run that never finds anything is a class to stop
paying for.

### 2026-08-27 — the day this file was opened

| suite | why run locally | cost | found |
|---|---|---|---|
| `quiesce` | **edited it** (default flip) | ~1 min | **10 real failures** — every ambient-default assertion; then a genuine product defect (the diagnosis was logged AFTER the gate, so degrading dropped the remedy) |
| `restoregrant` | **new suite** | <1 min | **a P1-class defect** — `--allow-restore=` with an empty value fell into Phase 1 and began installing packages |
| `stagger` | **edited it** | <1 min | **a regression I had just introduced** — the harness did not lift the helper my fix calls |
| `profiles` | **edited it** | <1 min | **a stale assertion** — it read only the first `delsnaps` line, passing a two-family profile on half its retention |
| `impact` | deps.conf changed | <1 min | **a missing suite row** in `PROJECT_STATUS.md` |
| `cron` | **edited it** | <1 min | nothing (new code, all green first time) |
| `run.sh` (gen-cron) | **edited fixtures** | ~2 min | nothing; validated new goldens |
| `restore` | edited it | ~1 min | nothing after the fix; the F2 control was run separately at function level |
| `pairgate` | `zfs-pair-gate.sh` changed | <1 min | nothing |
| `pause` | `deploy.sh` changed | <1 min | nothing |
| `linkfields`, `rerun`, `rux` | `zfs-backup.sh` changed | ~2 min total | nothing |
| `zfsbackup` | `zfs-backup.sh` changed | **~35 min across four attempts** | section 122 result — but see below |
| `localbackup` | `zfs-backup.sh`/`profiles/` changed | **not run** | documented liar on this workstation (56/1 locally against fully green CI on the same SHA) — sent to CI |

### What the numbers say

**Every local run that found something was a suite I had edited.** Every suite run
because a file it covers changed, without my having touched its subject
(`pairgate`, `pause`, `linkfields`, `rerun`, `rux`), was green and told me
nothing I did not already know. That is the existing "Which executor" rule in
`CLAUDE.md` earning its place — and the measurement now supports it instead of
just asserting it.

**One suite cost more than all the others combined.** `zfsbackup` took roughly
thirty-five minutes across four attempts: one corrupted because I edited the file
mid-run (E11), one to get section 122 green, one negative control that could not
load its libraries (E10), one that worked. Its targeted mode — the thing built
exactly to avoid this — had been broken since the helpers were moved inside the
skipped block, so `--section` died before reaching any section. **Five lines of
fix turned a 15-minute run into a 2-minute one.**

### R9 — Run locally only what you edited; everything else is CI's job

A suite whose subject you changed must run here, because not running a test you
just wrote is its own defect. A suite merely implicated by a changed file goes to
CI, which runs the whole battery in parallel in 1-2 minutes for free.

*Evidence: the table above — five findings, all from edited suites; zero findings
from six implicated-but-untouched suites.*

### R10 — Fix the targeted path before paying for the full battery

If a suite has a `--section`/`--only` mode, verify it works **before** running the
whole thing. A broken selector is invisible: it does not error, it just runs the
wrong subset or dies early looking like a failure.

*Evidence: ~30 minutes lost on 2026-08-27 to a selector broken by an unrelated
refactor; the repair was five lines and had gone unnoticed since REV-109 built
that mode.*

### R11 — Never run a suite you are still editing, and never edit one that is running

Both directions are real. Bash reads a script incrementally, so an edit mid-run
executes garbage from that offset; and a suite edited between two runs of a
comparison invalidates the comparison.

*Evidence: E11.*

### How to keep this honest

Add a row per local suite run, including the ones that found nothing — those are
the rows that make the rule measurable. When a row says "found nothing" for the
third time in the same circumstances, the run should stop happening and the rule
should say so.

---

## 3. What the pattern says

Eleven of the twelve entries are one of two shapes:

**Something looked executed and was not** (E1, E2, E3, E8, E9, E11) — a guard
unreachable, an assertion absent, a mutation behind a failed step, a script
rewritten under its own interpreter.

**A fact from one side of a boundary was asserted about the other** (E4, E5, E6,
E10) — branch vs `main`, lab residue vs estate, a copy vs the original.

Neither is complexity. Both are the same underlying failure: **the difference
between what the code says it does and what it does was never measured.** The
mechanisms that actually catch these — negative controls, the engine freeze, the
status-digest gate, an owner asking "napewno?" — work because they force that
measurement. Personal care does not scale; a control that fails loudly does.
