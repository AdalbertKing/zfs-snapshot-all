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

*Evidence: E1, E2, E3, E9, E30, E46, E47, E49.*

### R2 — A fact is true on ONE side of a boundary until measured on the other

Boundaries in this project: local vs remote host, branch vs `main`, index vs
working tree, my lab residue vs the estate's real state, this process vs another.
State the side you measured on. Never carry a conclusion across.

*Evidence: E4, E5, E6, E10, E17, E23, E26, E31, E34, E35, E38, E42, E45, E53.*

### R3 — A rule written in a comment is not applied by being written

When a comment states an invariant, grep for every site that should honour it and
check each. The gap between "the project knows this" and "this line does this" is
where the defects live.

*Evidence: E7, E2, E14, E16, E19, E21, E36, E41, E43, E50.*

### R4 — Never chain a mutation behind a step that can fail silently

`cmd_a && git add` is safe only if `cmd_a` fails loudly AND non-zero. Scripts
that print an error and exit 0, string replacements that match nothing, helpers
that do not exist — all of these continue the chain. Verify the intermediate
state, then mutate.

*Evidence: E8, E3, E27, E37, E39, E44.*

### R5 — Do not modify state something else is reading

Bash reads a script incrementally while executing it. Editing a suite mid-run
corrupts it from that offset. The same holds for a config another process is
sourcing, and for a branch a running job has checked out.

*Evidence: E11, E20, E33.*

### R6 — A green result is evidence only if you know what it should have printed

Count the assertions you expect by name and compare against the output. A total
that only goes up cannot tell you an assertion never ran.

*Evidence: E3, E9, E15, E24, E25, E28, E52.*

### R7 — Reproduce a fix's absence, not just its presence

Every fix ships with the failing control against the exact prior SHA. If the
control cannot be built, the fix is not understood well enough to ship.

*Evidence: applies to every entry; enforced by the review protocol.*

### R8 — Prefer the tool's own helper over a fresh implementation, and check it exists first

Before adding a flag, a parser or a knob: grep for one. Before using a test
helper, confirm the suite defines it. Before writing a resolver, check what the
renderer already uses.

*Evidence: E7, E3, E12, E29, E32, E34, E40.*

### R12 — A pass proves the shapes it ran, and the report must name them

Never write "proven end to end". Write which variants ran, which did not, and
what each one measured. A campaign that exercised one shape of a problem has
said nothing about the others, and the sentence "it works" is the mechanism by
which that silence becomes a claim.

The test of whether a pass is finished is not "did every step succeed". It is
"what did I not try", answered out loud.

A special case worth naming because it keeps happening: **testing the piece I
wrote instead of what comes out of it.** A component with a thorough suite,
wired into a caller with none, is an untested feature with a reassuring number
attached.

*Evidence: E13, E22.*

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

### E26 — A runbook asserted a fleet fact that a code comment remembered
**2026-09-03, lab runbook for PR #295.**

*Genesis.* The runbook I wrote for the host-side lab stated that "the fleet has
~20 relationship records per collector, some predating fields added later", and
built a whole test dimension on it (old records with missing fields read through
the new loader). The executor measured all seven hosts: **zero** records
everywhere -- `clients/` exists and is empty, production runs from
`jobs.<host>.conf`. The dimension was untestable; the executor had to reorder
the steps to create a record at all, and said so in the report.

*Cause.* The number came from a comment in `migrate_read_record` ("the record
dir on a real collector holds twenty files"), written for the estate as it was
in August, and I carried it across the boundary between "what the tree says
about the fleet" and "what the fleet is" without naming a measurement. A
runbook written from a session that cannot reach the hosts is exactly where R2
bites hardest: every fleet fact in it is on the far side of a boundary.

*Rule.* R2. In a runbook, a fact about the estate is either a step-0
measurement command with its expected output left blank, or it is not stated.
The corrected runbook now opens with `ls clients/ peers/ relationships/` and
says what to do when they are empty.

### E27 — A gated commit chain verified one state and recorded another
**2026-09-03, read_server_conf delivery (`6fd0802`).**

*Genesis.* I ran the delivery as one background chain: wait for suites, then
`impact.sh --verify`, `--refresh-status`, `git add`, commit, push. It pushed a
commit whose status digest was STALE: `--verify` on the pushed tree said so
immediately, and CI's graph job would have gone red.

*Cause.* Two errors in one chain. The order was wrong -- the digest is computed
over the STAGED files, and I refreshed it before staging the lib and the suite,
although the tool prints the correct order (`git add <intended>;
--refresh-status; git add PROJECT_STATUS.md`) every time it runs. And the chain
piped every gate through `tail -1`, so `--verify` passing on an empty stage and
`--refresh-status` warning about the not-yet-staged digest both read as one
reassuring line each. The mutation (commit, push) ran behind checks that had
measured a different state than the one it recorded.

*Rule.* R4. A verify that gates a commit runs on the exact staged state the
commit will record, after the last `git add`, and its full output is read --
not its last line. Fixed with a follow-up commit (`a2bc1b7`) carrying the
digest over the same content; the pushed history was not rewritten.

### E28 — My probe opened the descriptor it was asking about
**2026-09-03, cron suite section S (the eval removal).**

*Genesis.* Assertion S3 -- "release closes the lock descriptor" -- was red on
the branch AND on `main`, while `/proc/$$/fd` showed the descriptor gone. The
probe was `{ : >&"$fd"; } 2>/dev/null`. For the group's `2>/dev/null` bash
saves the real stderr on the lowest free descriptor >= 10, which was the
number the lock had just given back. The probe was measuring its own
scaffolding.

*Cause.* I wrote an instrument without asking what ELSE it does to the thing
it measures. The signal that it was the instrument, not the product, was there
in the first run: red on both sides of the change is not a product result.

*Rule.* R6. A red that does not move when the product changes is a reading of
the probe. Cross-check with a second instrument (`/proc` here) before touching
the product, and keep the probe out of the process whose state it reads --
section S now asks a child process to write to the inherited descriptor.

### E29 — I built a path from a variable an earlier section had repointed
**2026-09-03, zfsbackup suite section noeval.**

*Genesis.* `. "$SCRIPT_DIR/../harness.sh"` at the end of an 8800-line suite
resolved to `<repo>/../harness.sh`: section 96 sets `SCRIPT_DIR` to its own
fixture and never restores it. `product_fn` was "command not found", and the
marker assertion downstream passed for no reason, because the probe that would
have created the marker never ran.

*Cause.* I copied the sourcing line from the four suites that use it near their
top, where the variable still means what line 16 says. R8's "check it exists
first" applies to a value as much as to a helper: I used the variable without
checking what it held at that line.

*Rule.* R8. In a long suite, take paths from the variable nobody reassigns
(`$REPO`); and an assertion whose evidence is an ABSENCE (no marker file, no
output) must first prove the producing step ran (R6) -- the section now marks
the marker check "not measured" when the render did not run.

### E30 — A FATAL that could never fire, shipped as the fix for silent failure
**2026-09-03, test/harness.sh product_fn (PR #298), found in PR #301.**

*Genesis.* product_fn was written to replace the bare `eval "$(sed -n ...)"`
lift with one that FATALs on a missing anchor. Its FATAL was `exit 1`. Every
caller -- all twenty-four of them, by design -- wraps it in `$( )`, so the exit
ended the command substitution, the eval received an empty string, and the
suite carried on exactly as before. The helper was adopted in five suites,
merged, and described in two PR bodies and PROJECT_STATUS as "the FATAL",
without once having been made to fire from the position it is called from.

*Cause.* R1, verbatim: I proved the guard existed and never constructed the
input that should trigger it. The special shape here is worth naming: a guard
inside a command substitution cannot end the caller with `exit`, so any
"stop the suite" helper used as `$(helper)` needs a different mechanism
(`kill -TERM $$`), and the proof needs a child shell whose termination can be
observed. test/harness/run.sh H3-H7 now do that, with the old shape as the
negative control.

*Rule.* R1. And its corollary for helpers: run the guard from the exact
calling position it will have in production -- inside the substitution, the
subshell, the function -- not from a top-level shell where every exit works.

### E31 — A runbook that parks a host on a detached HEAD, written by someone who forgot the host updates itself
**2026-09-03, LAB-HOSTSCRIPTS runbook, caught by the executing thread.**

*Genesis.* Step 1 of the runbook checks the host's repository out at the
branch head (`git checkout --detach`). Every host runs `update-control.sh`
hourly at :15, which does `git merge --ff-only` on that checkout -- a
mechanism I had described myself, in the same runbook's closing paragraph, as
the thing that would roll the change out after the merge. A lab that crossed
:15 would have had its checkout moved under it. The executor placed an
`update-hold` on their own initiative and named the omission.

*Cause.* R2: the runbook was written from a session that cannot see the host,
and the host's own background processes stayed on the other side of that
boundary even while I was writing about them. The same shape as E26 (a fleet
fact carried from a comment), one step worse: this fact was not stale, it was
in the document, and I did not apply it to the procedure.

*Rule.* R2. For a runbook, the concrete check: list what RUNS on the host
unattended (cron, the updater, the digest) and ask of each step whether that
process can act on the same state in the meantime. The runbook now holds the
updater first and resumes it last.

### E32 — A runbook with a flag that does not exist, a probe that cannot run, and an increment with nothing in it
**2026-09-03, LAB-ENGINE-EVAL runbook, caught by the executing thread. Four
errors in one document; the first one repeated from the E31 correction.**

*Genesis.* (1) Step 0 said `update-control.sh --hold "…"`. The controller
knows `--self-update`, `--rollback` and `--resume-updates`; a hold is a
FILE (`update-hold` in the state directory, `UPDATE_HOLD_FILE` in deploy.sh).
The E31 correction of the hostscripts runbook, written the same day, carried
the same non-existent flag with "or: touch update-hold" in a trailing
comment, so the wrong form was the instruction and the right one the aside.
(2) Step 3 told the executor to prove the autotune probe on a LOCAL target.
Both engines gate autotune on `[ -n "$REMOTE_HOST" ]` (`snapsend.sh:2405`,
`snapget.sh:2449`), because a local send never compresses; the run exits 0
and proves nothing. (3) Step 3 snapshotted without writing data first: an
empty increment has no sample. (4) Step 4 diffed logs that differed by
mbuffer's optional progress line and by the data step 3 had added, so the
"empty diff" expectation could not be met by the method as written. The
executor resolved every one, measured both sides on the same data state,
and reported zero regressions.

*Cause.* R8, three times over: a flag written from memory of what the
controller OUGHT to offer, without `grep -n -- '--hold' deploy.sh`; a probe
placed on a path without reading the four-line gate that decides whether it
runs; a comparison designed without asking what the log contains that is
not behaviour. And R6 for (3): I did not know what the probe should print,
so I could not see that the step gave it nothing to print about. The
repetition of (1) inside the E31 fix is the R8 signal the header of this
file warns about: the rule was written down and not applied to the very
next document.

*Rule.* R8. For a runbook the concrete form: every flag, path and file
name in a command block is grepped in the tree before the block is
written, and every "expected" line is one the code demonstrably produces
on that path. The two runbooks now hold by writing the file and resume by
removing it; the probe step targets the remote side and writes data first;
the comparison strips the progress line and repeats both sides on one data
state.

### E33 — A suite edited while its first run was still reading it, and two runs writing one log
**2026-09-03, product_range round, caught by the run itself (a bash parse
error 8,400 lines in, then a "binary file" log).**

*Genesis.* Twelve edited suites were launched in the background to one log
file each. Three of them failed with `product_fn: command not found`
because they source the harness late or only in child scripts; I inserted
a `. harness.sh` line at the top of `test/zfsbackup/run.sh` while its first
run was still executing, then launched a second run into the SAME log
file. Bash reads a script incrementally, so the first run met the file
shifted by one line under it and died with a syntax error at line 8483;
both runs interleaved their output into one log, which grep then called a
binary file. Neither result was usable. Cleaning up, a `pkill -f` whose
pattern matched the shell issuing it killed that shell too.

*Cause.* R5, verbatim: "Editing a suite mid-run corrupts it from that
offset." The rule names this exact mechanism and I had read it that
morning. The second half, one log per RUN rather than per suite, is the
same rule seen from the file side: two writers on state a third process
was reading.

*Rule.* R5. Before editing a suite: `pgrep -af <suite>`; kill or wait,
never edit under it. One log file per launch, named by launch, not by
suite. A `pkill -f` pattern is anchored to the process's own argv shape
(`^bash ./test/...`) so it cannot match the shell issuing it.

### E34 — A runbook command that was not the verb it named, and a hold that did not hold
**2026-09-03, LAB-DRAFT-CONFIG runbook, caught by the executing thread on
pve9. The second runbook in a row with an invented command form (E32).**

*Genesis.* (1) The runbook said `deploy.sh --peer=X --draft-config`. The
flag is a SUB-MODE of `--pair`: only `do_pair` dispatches it, and without
`--pair` the run fell through to the default path -- a full host
deployment (git pull, scripts reinstalled, crontab rewritten) from a
command meant to draw a file of comments. It went through Phases 1-8 on
pve9 and moved the checkout. (2) Step 0 placed an `update-hold` "so the
host does not move". The hold gates `update-control.sh --self-update`
only; `deploy.sh`'s own Phase 2 pull ignores it, and printed in the same
run that updates were held. (3) A dataset declared at `--pair` that does
not exist on the peer makes `--join` refuse, so property (B) could not be
built the way the runbook said.

*Cause.* (1) is R8 for the second time in two documents: I had grepped
that `--draft-config` EXISTS (E32's rule) and stopped there, without
reading where it is dispatched from. Existence is not reachability (R1):
the flag was real, the command line was not. (2) is R2: "the hold stops
the host" was true for the updater and carried, unmeasured, to a program
that has its own pull. (3) is R1 again: the input meant to trigger the
UWAGA branch triggered a refusal one step earlier, which I would have
seen by constructing it.

*Rule.* R8, sharpened: for every command line in a runbook, find the
DISPATCH -- the `case`/`if` that reaches the function -- not just the
flag in the parser; and R1: build the input that reaches the branch,
then follow it through every gate on the way. The product now refuses
the bare form at argument time (rc=2) instead of deploying, and the
runbook's hold line says what the hold does and does not cover.

*Postscript, same day.* The positive control for that refusal, run as
root on this container, went past the root gate into a real `--pair`
preflight -- Phase 1 and a Phase 2 `git fetch` -- before dying on ZFS.
A test that reaches the product's deployment path as root is R5 in test
form (mutating the checkout the suite reads); the control now runs as an
unprivileged user or skips with its reason.

### E35 — An estimate built from textbook rates, with the repository's own rate one `git log` away
**2026-09-04, PYTHON-TRANSLATION-ESTIMATE, caught by the Owner ("this
package was built in a month").**

*Genesis.* The per-file estimate used 200/150/110 lines and 40 assertions
per day -- generic single-developer figures -- and arrived at 266 days for
a package whose history shows ~1,657 lines and ~59 assertions a day over
53 working days. The model was explicit and arguable, as intended, but its
constants came from outside the repository while the calibrating
measurement sat in the same tree.

*Cause.* R2. "How fast does work happen here" is a fact about THIS
project and its process; I carried a fact from the general case across
that boundary without measuring the specific one. Stating the assumption
openly made the error visible, not correct.

*Rule.* R2, applied to estimates: before quoting a rate, measure the rate
the same repository has already demonstrated (`git log` dates, lines,
assertions), state both, and let the measured one drive the number. The
document now carries the calibration (26 days, ×0.5 for translation
against a written spec, stated as the assumption) and keeps the old table
as the upper bound it is.

## 2b. Suite runs — was it worth it, and at what scale

Owner instruction, 2026-08-27: *"Mierz też zasadność puszczania suit i w jakiej
skali. Na tym stajemy realnie."* This is the largest single drain on a working
day, so it is measured here rather than argued about.

Record for every LOCAL suite run: why it was run, roughly what it cost, and
**what it found**. A class of run that never finds anything is a class to stop
paying for.

### 2026-09-08 — the selector that did not select, and what a section really costs

The Owner asked why an army of suites was running again when the plan was to
select. Measured by running it: a focused run executed **387 of 736**
assertions -- the flag skipped the early half and then paid for every section
added since, `saveprof` included (~25 min, four times that day). One `want()`
helper and an `if` per self-contained section later, the same runs cost this:

| `--section` | assertions | cost | note |
|---|---|---|---|
| `showscope` | 18 | **7 s** | |
| `statusjson` | 15 | **9 s** | |
| `records` | 9 | **16 s** | |
| `listjobs` | 24 | **21 s** | |
| `saveprof` | 29 | **860 s** | the outlier, and not the selector's fault |

`saveprof` is expensive by construction: REV-20260907-137's gate runs the REAL
`gen-cron.sh` for every case, and a gen-cron invocation costs milliseconds on a
Linux host (13 ms measured on pve10) against seconds under Git Bash. So the
rule this row produces is narrower than "run less": **`saveprof` is a CI
section, not a local one** -- everything else in this file is now cheap enough
to run on the spot.

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

### 2026-09-03 — ten Pull Requests in one day, on a Linux container

The workstation rule ("this Windows box is not on the list for full suites")
did not apply: this session ran on a Linux container with native bash, where
the full `zfsbackup` suite costs ~2.5 minutes, not 13-25. Every row below is
a run that happened; the "found" column is what it changed.

| suite | why run locally | cost | found |
|---|---|---|---|
| `zfsbackup` (full, ×3 on the branch; ×2 as `ZFSBACKUP=<main>` controls) | **edited it** (sections `records`/`fataldie`/`invocation`/`flags`/`noeval`/`3b`) | ~2.5 min each | **E29** — `. "$SCRIPT_DIR/../harness.sh"` resolved to `<repo>/../harness.sh` because section 96 repoints `SCRIPT_DIR`; the marker assertion downstream passed for no reason. The foreign-tree controls carry **four constant reds** (96A, 96B ×2, `assert_cron_config_matches_installed`) that compare a profile path against the suite's own tree and say nothing about the change — named here so nobody diagnoses them a third time |
| `cron` (×2 + `LIB=<main>` control) | **edited it** (section S) | <1 min | **E28** — the fd probe measured bash's own saved stderr, red on both sides of the change; `/proc` was the second instrument |
| `harness` (new, ×2) | **new suite** | <1 min | **E30** — while writing H3: `product_fn`'s FATAL was `exit 1` inside `$( )` and could never end a suite. The suite's own H7 control (the old shape continues with rc=0) is what shaped the fix (`kill -TERM $$`) |
| `moveclient` (×2 + `ZB=/dev/null` on branch and on main) | **edited it** (product_fn adoption) | <1 min | the adoption discriminator: FATAL rc=143 here, 41 lines of `command not found` and 8/33 on main |
| `alertmail` (×3 + `DEPLOY_SRC=<main>` control) | **edited it** (host-scripts section; digest and capacity from files) | <1 min | nothing beyond design; the control proved the section ends the suite on the absent installer |
| `draftscope` (×2, `DEPLOY_SRC=<main>` control) | **edited it** (anchor alternation) | <1 min | nothing; the alternation proven from both trees |
| `pairgate`, `join`, `joinmanifest`, `joinremote`, `runsuffix`, `restoregrant` | **edited them** (product_fn adoption) | ~2 min total | one mistake caught BEFORE the run by `bash -n`: my own `if false; then : else` placeholder left an orphaned `fi`. `restoregrant`'s three non-root cases red as always here, green in CI |
| `cron2conf` (×2 + `C2C=<main>` control) | **edited it** (fixture `pull.crontab`) | <1 min | nothing beyond the intended discriminator (main 28/1) |
| `impact` (×3) | `deps.conf` changed | <1 min | nothing |
| `pause`, `restore`, `quiescehelper`, `selfupdate`, `join`, `linkfields`, `rerun`, `joinmanifest`, `rux` | implicated only (`deploy.sh` / `lib-backup-common.sh` / `zfs-backup.sh` changed underneath) | ~3 min total | **nothing** — every one green first time; `restore`'s `get: command not found` noise is identical on main (a stub in the suite itself) |
| `harness` (×3) | **edited it** (`product_range`, H12–H17) | <1 min | **a wrong expectation in my own control** (H16 counted 9 lines to EOF, the file has 8 from the anchor) |
| `zfsbackup`, `linkfields`, `rerun` (first run) | **edited them** (`product_fn`/`product_range` sites) | 2.5 min / <1 / <1 | **`command not found` ×3** — the helpers were called before the harness was sourced (late, or only in child scripts); fixed by sourcing at the top |
| `zfsbackup` (second run, killed) | re-run after the fix | wasted | **E33**: edited under a running first run, two runs on one log |
| `zfsbackup` (third run), `linkfields`, `rerun` | re-run after E33 | 2.5 min / <1 / <1 | **one real difference**: the logrotate stanza site relied on sed printing EVERY range (root's stanza, then the account's) while `product_range` lifts the FIRST; re-anchored on the account's own path line, fourth run green |
| `draftscope`, `pause`, `moveclient`, `pairgate`, `quiescehelper`, `restore`, `subtree` | **edited them** (helper adoption) | <1 min each | nothing |
| `quiesce` (as `nobody`), `localbackup` (as `nobody`) | **edited them**; both refuse or fail as root | ~1 min each | nothing — the root failures (14 in `localbackup`) reproduce identically on `main` at `caf8f27`, environment not change |
| `join`, `selfupdate` | **edited them** (pair sub-mode refusal, recorded grant list on a direct run) | <1 min each | **a wrong control in my own test**: it expected "run as root" and this box IS root, so the correct form ran on to the ZFS preflight. The join section was then dropped at merge time: the fleet thread had landed the same guard with a program-level draftscope test (PR #318) |
| `join`, `selfupdate` vs `caf8f27` | negative control | <1 min each | exactly the four new join assertions and 29a red |

**Same pattern as 2026-08-27, stronger.** Every finding came from a suite I had
edited or written; the nine implicated-only runs found nothing across ten PRs.
Two of the four findings (E28, E30) were about the INSTRUMENT, not the product
— a red that did not move with the product, and a green that could not have
gone red — which is R6 and R1 again, and the reason a new assertion's negative
control is not optional.

**One new class of run.** A negative control on a foreign tree
(`ZFSBACKUP=<main>`, `DEPLOY_SRC=<main>`, `C2C=<main>`) is cheap and decisive
for the assertion under test, and it also produces a fixed set of unrelated
reds wherever a suite compares a path against ITS OWN tree. Read the
discriminator's line, count the rest against the list above, and stop.

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

### E13 — "Proven end to end", after running one shape of the problem
**2026-08-27, restore, second lab pass.**

*Genesis.* The first restore lab found eight defects, ended green, and I reported
it as working end to end. The owner asked for a second pass. It found **fourteen
more**, and the first of them was reachable by doing the one thing the first pass
never did: **running a backup after the restore**. The worst of them was reachable
by damaging data the way a real failure damages it — deleting files with **no
snapshot taken since** — at which point the verb reported
`all 3 dataset(s) in scope recovered` and changed nothing.

*Cause.* Every damage in the first pass had been snapshotted by a backup before
the restore ran, so the classifier's question ("is anything NEWER than the
point?") happened to be true every time. One shape, exercised repeatedly, read as
coverage. And the pass ended where the restore ended, so the state it left the
relationship in was never observed.

*Rule.* **R12.** Two concrete habits fall out of it: run the NEXT operation the
system would normally perform, because a verb's real output is the state it
leaves behind; and construct the damage the way the failure does, not the way the
fixture does.

### E14 — A distinction written into a function, dropped by its caller. Twice, in one file, in one hour
**2026-08-27, restore classification and verification.**

*Genesis.* `restore_remote_state` returned `absent`, a GUID, or nothing — and
nothing meant BOTH "the dataset exists and has no snapshots" and "the host did
not answer". Fixed by adding a third answer (F14). An hour later
`restore_remote_ahead`, whose own header says the caller can tell "nothing
differs" from "I could not ask" by the exit status, was being called as
`x="$(f ...)"; if [ -n "$x" ]` — status discarded (F20). An unanswered ssh read
as a clean target: no rollback, an empty increment, a clean report.

*Cause.* Producing a distinction feels like the work. Consuming it is the work.
The comment above the function made the file *look* careful at exactly the line
where it stopped being careful.

*Rule.* **R3.** When a function's contract has more outcomes than a string, grep
every call site and check that each reads all of them. In bash specifically:
`x="$(f)"` throws away `$?` — if the contract has a status, capture it on the
same line.

### E15 — I read an outcome and called it a mechanism
**2026-08-27, snapget `-F`.**

*Genesis.* A pull refused because the copy was ahead. I ran `-F`, saw the refusal
not appear, and shipped a message telling operators that `-F` "destroys exactly
those snapshots and then pulls the increment". `-F` does nothing of the kind: it
acts only on a name collision under a different GUID, and what it had actually
done was escalate that run to a full re-pull. The next `-F`, against a state with
no collision, refused like any other run and exposed it.

*Cause.* One observation, one inference, no reading of the flag the message was
about. The flag's own documentation was twenty lines above the code I was editing.

*Rule.* **R6**, in its product form: an outcome tells you what happened, not why.
Before describing a mechanism in a message an operator will act on, read the
mechanism. A remedy printed by a tool is a promise made in the tool's name.

### E16 — The remedy printed was the input that once broke a host
**2026-08-27, restore grant refusal.**

*Genesis.* Refusing an ungranted `replace`, the message printed
`deploy.sh --allow-restore= --replace` — empty label, because the collector never
records the peer's name for the relationship and the display took the caller's
(deliberately empty) variable. That exact input is **E1**: `--allow-restore=` with
no value fell past the grant dispatch and started reinstalling the machine.

*Cause.* A value correct for a decision (empty means "whatever the key bound")
was reused for display without asking whether it was printable. The authoritative
label was in hand the whole time, in the peer's own answer.

*Rule.* **R3**, plus: a message that contains a command is code. Check what it
renders when its inputs are empty, exactly as you would check a code path.

### E17 — Half a remedy, shipped twice, corrected by the step after the fix
**2026-08-27, the copy-is-ahead jam.**

*Genesis.* Three versions of one message. First `-f` (the account cannot run it).
Then "destroy the named snapshots" (measured, rc=0 — and the very next pull
refused again, because destroying a snapshot does not move the live filesystem,
so the copy stayed exactly where those snapshots had left it). Finally
`zfs rollback -r <copy>@<common>`, which does both halves in one command.

*Cause.* Each fix was verified by the step that had failed, and not by the step
after it. "The refusal is gone" is not "the operator can now get back to work".

*Rule.* **R2** across a boundary in TIME: a fix is proven by the next operation
the user would perform, not by the disappearance of the symptom. Run the workflow
one step further than the bug.

### E18 — A false alarm delivered in the middle of a recovery
**2026-08-27, the "what this costs the backup" report.**

*Genesis.* The run closed by telling the operator their next backup would refuse
and their only copy of a period was at stake. The next backup succeeded. The
record was written for every rollback, and a rollback that discards only live
writes destroys no snapshot — which is the ordinary case, because the ordinary
disaster is damage nobody has snapshotted yet.

*Cause.* One flag answering two questions: "did we roll back" and "is the copy
now ahead". Related, not the same, and the second is the one the warning is
about.

*Rule.* **R1**, from the other side: prove the guard does NOT fire when it should
not. A warning is a claim, and a claim that is often wrong costs exactly what the
true version of it was worth — here, telling somebody their last copy of a period
is about to be destroyed.

### E19 — A fourth opinion about ssh flags, missing the property the other three carry
**2026-08-27, restore connection handoff.**

*Genesis.* zfs-restore.sh needs its ssh options as a STRING (they cross an
`exec`), so I wrote one: key, alias, known_hosts, StrictHostKeyChecking,
BatchMode. It shipped without `ConnectTimeout` or `ServerAlive*`. A restore
aimed at a peer that never answers the SYN would have sat about 130 seconds per
call -- and a restore opens several probes per dataset before it transfers
anything, so that is minutes of silence in front of somebody recovering a
machine. This estate has already paid for that hang once (#44/#45/#46) and
built a counting assertion against it: test/zfsbackup counts ConnectTimeout and
ServerAlive against the BatchMode groups. It went 4 / 3 / 3 and failed.

*Cause.* `load_ssh_opts` builds exactly this set, bounded, and eight callers use
it. I did not look, because what I needed was "a string" and what existed was
"an array" -- so the shape of the container hid the fact that the content was
already written. The comment I wrote even said "the same pinning the engines
get", which was the moment to go and read what the engines get.

*Rule.* **R8.** And a sharper form of it for this shape: when a file already
builds three of something and you are writing the fourth, you are not writing a
new thing, you are copying an existing one -- so copy the whole contract, or
better, call the builder. Adding the three missing options would have fixed the
instance; using `load_ssh_opts` removed the class, because a fourth opinion
cannot drift from the other three if it does not exist.

*Also worth naming:* the assertion caught this on CI, four commits after I
introduced it, because I deferred the big suite to CI (correct by R9) and then
did not read CI until the end. R9 says run only what you edited; it does not say
read the result late. When you add a member of a class some suite exists to
guard, that suite is the one to run -- policy or no policy.

### E20 — A 488/0 that measured no single tree
**2026-08-28, test/zfsbackup in the background.**

*Genesis.* I started the big suite in the background against the tree as it
stood, then -- while it ran -- edited `zfs-backup.sh` to fix the ssh options CI
had just failed on. The suite finished PASS=488 FAIL=0, including the very
assertion that had been red.

*Cause.* E11 was editing a suite while it was RUNNING. This is the same rule one
step out: I edited the suite's SUBJECT. `test/zfsbackup` greps `zfs-backup.sh`
at assertion time, so section 7a read the file in whatever state it was in when
the run reached it -- after the fix, as it happens. Earlier sections read the
file before it. The number is a mix of two trees and is a measurement of
neither.

It would have been just as easy to go the other way: an assertion that passed
early and a file that broke later reads as green over a defect.

*Rule.* **R5.** A suite measures a tree, so the tree has to hold still for it.
If a fix cannot wait, kill the run rather than let it produce a number that
looks like evidence. The authority for this change is CI on 31e6ccd and 7e13dd6,
which ran against a fixed checkout -- not the local 488/0, which I am recording
here precisely because it looked like the better number.

### E21 — I appended a field to a tuple; two readers assumed the old last one
**2026-08-29, gen-cron send entities.**

*Genesis.* `media` went on the end of SEND_ENTITIES. Two consumers broke, both
silently: one matched the tuple's TAIL (`case "$rest" in *"${SEP}pull")`), and
one gave its last variable the whole remainder, because that is what `read`
does. Every pull section stopped being recognised -- in a coverage report whose
entire job is to say what is NOT covered.

*Cause.* I changed a shared data shape and looked only at the code I was
editing. The tuple has no schema; its readers each encode their own assumption
about it, and "direction is last" was one of them, written nowhere.

*Rule.* **R3.** When a shared structure grows, grep every reader of it, not
every reader you remembered. And the concrete idiom: a positional tuple should
be read by NAMING every field with a trailing catch-all, never by matching its
tail -- the first breaks loudly when the shape changes, the second does not
break at all.

*Caught by:* the reconcile suite, on CI, three commits after I introduced it.
Locally I had run the golden suite and the generator suites and they were all
green, because none of them exercises a pull section's coverage.


### E22 — 34/0 on the gate, and the line it was wired into had never once been run

**Genesis.** The removable-media replica. I wrote `zfs-media-gate.sh` and a suite
for it: attach, detach, the wrong medium, two disks of the same name, a failed
export, ownership recorded, ownership NOT recorded. 34 assertions, 0 failures,
every branch of the gate covered in both directions. The gate was fine.

Then the lab on pve0 ran the thing an operator would actually run -- the cron
line the generator emits -- and it had two defects, either of which alone would
have made the feature worse than not having it:

* the bracket was emitted as a command SEQUENCE (`if ...; fi; detach`) into a
  slot `job_cron_line` builds for ONE command (`CMD 2>"$e"; rc=$?`). Both halves
  of the wrapper bound to `detach` alone. So the engine's stderr never reached
  the job log -- it went to cron's own stderr, the mail flood this package
  exists to prevent -- and the recorded status was detach's. Measured: engine
  exited 1, the job logged rc=0, nobody was told. The whole point of the field
  is to buy ONE silence, the disk in a safe. It was buying all of them,
  including "your backup failed";
* the gate was handed the LANDING path, which the engine creates. On a freshly
  prepared disk it does not exist yet, so the first sync was refused as "the
  wrong medium" -- the right disk, refused, and after the first fix, alerting.
  A new removable disk could never be seeded.

**Cause.** I tested the component I wrote and never the thing it produces. The
gate's suite could not have caught either defect: neither lives in the gate.
They live in eleven characters of generated shell, and nothing anywhere executed
that text. I read the rendered line several times while writing it and it looked
right -- which is exactly the reading that a subshell's absence survives.

The same day, a third one from the same root: `detach` asked who owned the pool
before asking whether the pool was there, so the commonest case of all -- the
disk in a safe -- was answered with "leaving POOL imported". The suite passed on
BOTH orders. It asserted the exit status and never the sentence, so it was not
discriminating anything; it was counting.

**Rule.** R12, plus its new special case. A component suite is not a feature
suite. Run what the user runs: the generated line, executed, with only the leaf
commands stubbed -- `test/mediagate/run.sh` section G now does exactly that, and
the old bracket fails it. And when an assertion passes on both sides of a change,
it is not evidence, whatever the total says (R6).


### E23 — I reported an infrastructure fault from a probe the design never uses

**Genesis.** Closing out the day's queue, I had listed as an open item:
"metropolis: pve1 (28.9) does not accept pve9's key -- a leftover from an
earlier lab." It came from one command:

    pve9 $ ssh root@192.168.28.9        -> Permission denied (publickey)

I reported that to the owner twice, in two separate summaries, as an
infrastructure problem awaiting attention.

**It was not a problem at all.** The relationship between those two hosts is
healthy and has been all along: pve9 PULLS from metropolis hourly, and the
backups were arriving on schedule the whole time I was calling the link broken --
`automated_hourly_2026-08-29_17-51-01` had landed 47 minutes before I wrote it
down again. Measured with the identity the job actually uses:

    su zfsbackup -c 'ssh -i pairing-192.168.28.9_ed25519 ... zfsbackup-pve9@192.168.28.9 "zfs list ..."'
    hdd/labsrc
    rc=0

**Cause.** I probed root-to-root. The package does not use root-to-root, and has
not since the fleet migrated to delegated accounts on 2026-08-01. A relationship
runs as its own account with a per-peer pairing key, a pinned `HostKeyAlias`, and
its own `known_hosts` -- and the ABSENCE of root trust between two hosts is the
point of that design, not a defect in it. I tested the one path the architecture
deliberately does not have, and read its refusal as a fault.

Two further tells I walked past. `crontab -l` as root showed no job for that
peer, which should have prompted "then who is fetching this, and as whom?"
instead of confirming the fault. And a `grep -c "28\.9"` returned 4, which I
took as matches -- they were `28.98`, a different host entirely.

**Rule.** R2, and this is the sharpest form of it yet: the boundary is not only
host-to-host, it is IDENTITY. State which account and which key a probe used,
because "cannot connect" is meaningless without it. Before reporting a link
broken, find the job that uses it and run what IT runs. If no job uses the path
being probed, that is the finding -- not the refusal.

### E24 — I called two working mechanisms missing, from readings of zero

**Genesis.** Closing the lab round I handed the owner three open items. Two of
them were mine, not the package's.

*"Objetosci i przepustowosci nie ma."* I read 119 progress records and counted:

    wire_bytes  > 0 :  0 / 119
    rate_bps    > 0 :  0 / 119

and reported that the schema has the fields but nothing fills them — a gap to
close before the GUI. **The mechanism is complete.** `progress_watch` parses
`size`/progress lines for total and done, reads mbuffer's own log for wire, and
computes rate between ticks. It ticks every 2 seconds; every transfer in my
sample lasted 0-1 second and moved a few MB. One 600 MB run settled it:

    total_bytes = 630279464   done_bytes = 551425752
    wire_bytes  = 617611264   rate_bps   = 116537608   (6 s)

and the two sub-second datasets in the SAME run stayed at zero, exactly as the
design implies.

*"Rekordy rosna bez ograniczenia."* I grepped for cleanup patterns, found
nothing, and extrapolated to ~100k files a year. `progress_reap()` exists, is
called by BOTH engines on every run, keeps 7 days and skips records still
running. The oldest record on the host was seven days old — the reaper
working, which I read as its absence.

**Cause.** A reading of zero is a reading, and I treated it as a fact about the
code. I never asked what a NON-zero would have required: a transfer longer than
the sampler's tick, and a file older than the reaper's window. Neither existed
in anything I looked at. The grep for the reaper was the same mistake in the
other direction — I searched for words I expected (`clean`, `prune`, `rm -f`)
instead of for the thing (`progress_`), and concluded from my own vocabulary.

The cost was not only noise: I put both on the owner's list as work to do, and
he approved doing it. Two of the three items he authorised did not exist.

**Rule.** R6, from the other side. A zero, an empty grep and a missing field
are results, and a result is evidence only against a control that would have
produced the opposite. Before reporting a mechanism absent: build the case that
should exercise it, and only then say what you saw.


### E25 — I recorded a falsification I had not controlled, and it pointed away from the cause

**2026-08-31, restore verification.**

**Genesis.** A successful recovery was reported `CHANGED AND UNFINISHED` because
`written@point` read 8192. The predicate was wrong for a separate and sufficient
reason — it asked an accounting question after the step that disturbs the
accounting — so I fixed it to ask identity, and that fix stands.

But I also went looking for the 8192, took three readings, and wrote into
`PROJECT_STATUS.md`: not a txg lag, not the mount, **not the rollback itself
(0 in isolation)** — and then **"which step writes them: unestablished"**.

The third clause was false, and it was the answer. Measured later, step by step
on two lab pools: **every** `zfs rollback` leaves a constant residue — one
metadata block, one write per copy, rounded to the pool's sector. 1024 on a
512-byte pool, **8192** on `ashift=12` with two copies of metadata. It appears
even on a rollback where nothing had changed since the snapshot; a fresh `recv`
leaves zero. Two commands would have shown it.

**Cause.** R6 again, and the same shape as E24: I read a zero and promoted it to
a fact about the system without building the case that would have produced the
opposite. Worse than E24 in one respect — I did not merely report the zero, I
wrote **"unestablished"** next to it, which retires a question. A wrong
falsification is not neutral: it removes the one hypothesis that was true, and
anybody reading that paragraph afterwards inherits the exclusion.

That it did not cost anything is luck of my own making, not judgement: the fix
was deliberately built not to depend on the answer.

**Rule.** R6, second recurrence after E24 — which is the point, per this file's
own instruction. Concretely: **a falsification is a claim and needs the control a
claim needs.** Before writing "it is not X", produce the run where it IS X and
show the reading move. And never write "unestablished" while a two-command
experiment remains untried — write "not yet measured", which says whose move it
is.

### E36 — A gate whose comment said "what the package writes" and whose code said "anything but these"

**2026-09-04, REV-20260904-134, caught by the Reviewer with `DIE_MAIN_PID=`
in a client record.**

*Genesis.* `record_load` was written to read records as data, and its field
gate was documented as accepting "a field name a record may carry" -- the
fields this package writes. The implementation accepted every
`[A-Z][A-Z0-9_]*` name except a short deny-list of shell variables (PATH,
IFS, HOME ...). A record carrying `DIE_MAIN_PID=` therefore assigned the
reader's own control variable, disarmed the fatal `die` delivered one PR
earlier, and `set-endpoint` ran on past a FATAL to a second refusal. The
same hole was open for every uppercase global of both programs.

*Cause.* R3. The invariant was stated in the comment and in
`AI_PROJECT_RULES.md` ("records are data"), and the mechanism written under
it was the invariant's negation: a list of exceptions to "anything goes" is
not "only what we write". I checked the names I could think of instead of
enumerating the names the package writes -- which were one grep away
(`write_client_field`, the manifest heredocs, the stamps).

*Rule.* R3, sharpened for gates: **when the rule says "only X", the code
enumerates X.** A deny-list implements "not Y", a different rule, and the
distance between the two is every name nobody thought of. Enumerate from the
writers, derive the check from the program text in the suite so a new writer
fails there, and keep the list a superset of what older releases wrote so the
data already on hosts still loads.

*Postscript, same day.* The first cut of the numbered-field rule tested only
the component after the LAST underscore, so `EXCLUDE_FOO_1` passed -- the
Reviewer's follow-up on PR #328. Same rule, same failure: "digits after the
last underscore" is a property of many names; "one of these four prefixes
followed by digits only" is the enumeration. The negative probe in the suite
(`EXCLUDE_FOO`) had no digit and so never exercised the alternative I had
written -- R1 as well: construct the input the broad branch would accept.

### E37 — A commit and a push chained behind `impact.sh --verify | tail`

**2026-09-04, REV-20260904-134 delivery, caught by reading the output after
the push had already happened.**

*Genesis.* One shell line did the whole submission: regenerate the ledger,
stage, `./test/impact.sh --verify 2>&1 | tail -2 && git commit ... ; git
push`. `reviewctl --generate` refused (the implementation SHA was not on
`origin/main` yet -- it wants `REVIEWCTL_PUBREF=HEAD` on a branch), so the
ledger still said `OPEN | Claude`; `--verify` then failed and printed the
ledger diff -- and the commit ran anyway, because the status of a pipeline
is the status of `tail`. The push published a response whose ledger row
contradicted it. Fixed forward in the next commit, no history rewritten.

*Cause.* R4, verbatim: a mutation chained behind a step that can fail
silently. `| tail` turned a loud non-zero gate into a zero. The gate's own
message even said what to do.

*Rule.* R4, with the one mechanical shape that keeps producing it: **never
put a gate on the left of a pipe when a mutation follows `&&`.** Run the gate
bare (or `set -o pipefail`), read its exit status, then mutate in a separate
command. And a `--generate` that refuses is a stop, not a warning.

### E38 — "The product cannot do X", derived from one surface, while the product names a different one as authoritative

**2026-09-06, dyskusja o GUI, wykryte przez właściciela dwa razy z rzędu:
„Dlaczego piszesz, że tego nie robi” i „Usunięcie relacji i ustawienie jej od
nowa?”.**

*Genesis.* Projektując ekran ustawień TUI wyprowadziłem listę czasowników
`zfs-backup.sh` jednym wzorcem (`shift; cmd_`) i uznałem ją za pełny obraz
tego, co produkt umie. Z tego wyszły dwa fałszywe zdania do właściciela.
Pierwsze: że tworzenie relacji sprowadza się do `add-client` — wzorzec nie
łapie `rux_entry`, do którego dispatcher kieruje `--source=`/`--target=`,
czyli głównej formy jednokomendowej używanej w labach. Drugie, gorsze: że
retencji, harmonogramu i wykluczeń „nie da się zmienić na istniejącej
relacji”, na czym zbudowałem całą rekomendację (wyszarzone pola, czekanie na
Etap 4 planu). Tymczasem `docs/CONFIG-EXAMPLES.md` mówi w szóstej linii, że po
instalacji config JEST prawdą wykonania, a jego ręczna edycja to ścieżka
pierwszoklasowa; zmiana polityki to edycja pliku, `gen-cron.sh -c FILE` jako
podgląd i `--install` jako zastosowanie.

*Cause.* R2. Zmierzyłem jedną stronę granicy — powierzchnię czasowników CLI —
i orzekłem o drugiej, o zdolnościach produktu. Granica była tym wyraźniejsza,
że produkt sam nazywa swoją warstwę sterowania i nie jest nią CLI: „the
documentation, not the CLI, is the escape hatch for bespoke policy”. Do tego
doszła druga połowa: **napisałem zdanie o nieistnieniu, nie budując kontroli.**
Zdanie „nie ma na to drogi” jest twierdzeniem dokładnie tak samo jak „jest” i
potrzebuje tego samego dowodu; jedno `grep -rn 'hand-edit' docs/` by je obaliło
przed wysłaniem.

*Rule.* R2, wyostrzone dla twierdzeń o nieistnieniu: **zanim napiszesz, że
produkt czegoś nie potrafi, nazwij powierzchnię, którą przeszukałeś, i
przeszukaj tę, którą produkt sam nazywa rozstrzygającą.** Lista wyprowadzona
jednym wzorcem jest hipotezą o tym wzorcu, nie inwentarzem: sprawdź, co jeszcze
łapie punkt wejścia. A gdy odpowiadasz właścicielowi na pytanie „czy da się”,
odpowiedź „nie” wymaga cytatu, nie wnioskowania.

*Postscriptum, ten sam dzień, trzeci raz.* Właściciel: „zapomnieliśmy o
replice”. Oba dokumenty GUI napisałem wyłącznie o relacjach, bo listę rodzajów
sekcji wziąłem z `usage` w `gen-cron.sh`, gdzie jest ich pięć. Szósty,
`[replica:]`, w `usage` nie pada ani razu, choć `_allow_fields replica` i
`build_replica_section` w tym samym pliku istnieją. Ta sama przyczyna:
powierzchnia, którą przeszukałem, była pomocą narzędzia, a rozstrzygający był
jego kod. Kosztowało to więcej niż samą lukę, bo ukryło precedens: `add-replica`
jest **upsertem**, czyli dokładnie tym kształtem czasownika, który
projektowałem dla relacji jako nowy. Wniosek do reguły: gdy dokument opisuje
„wszystkie obiekty klasy X”, wylicz klasy z kodu, nie z `usage`, i napisz w
dokumencie, skąd wzięta jest lista — czytelnik ma widzieć, co było
przeszukane.

*Postscriptum drugie, ten sam dzień.* Poprawiłem tamtą lukę czytając **kod**
(`add-replica`, `_allow_fields replica`) i wciąż postawiłem replikę w złym
miejscu: jako czwartą oś zmiany konfiguracji relacji. Właściciel poprawił drugi
raz: replika jest konfiguracją kolektora, nie relacji. Zdanie rozstrzygające
leżało w `PROJECT_STATUS.md` od labu replik — „replika to inny RODZAJ zadania
(bez monitora, bez prune źródła, bez relacji)". Czyli nawet naprawiając błąd
przeszukałem warstwę niższą, niż trzeba: kod mówi, **co** obiekt ma, a zapis
projektowy mówi, **czym on jest**. Przy projektowaniu architektury informacji
najpierw szuka się zdania definiującego obiekt, dopiero potem jego pól.



### E39 — A commit that changed a status-covered file and skipped the status gate

**2026-09-07, package A of the GUI verbs, caught by CI going red on exactly the
check that exists for it.**

*Genesis.* The lab on pve10 found that `monitor --json` emitted invalid JSON for
any multi-dataset line. I fixed it, committed and pushed in one move to get the
branch green again -- and did not re-run `git add … ; ./test/impact.sh
--refresh-status ; git add docs/PROJECT_STATUS.md`. The fix touched
`zfs-backup.sh`, which declares the `project-status` obligation, so the digest in
`PROJECT_STATUS.md` no longer described what the commit recorded. Two CI jobs
failed (`graph`, `impact`) with the marker's own message naming the file. Fixed
forward in the next commit.

*Cause.* Not ignorance of the gate -- I had run it correctly one commit earlier.
It was HASTE: the previous commit was the "we are red, push the fix" one, and the
gate felt like ceremony standing between me and green. That is the exact moment
the gate is for. The marker is over the CONTENT of every file declaring the
obligation, so "I only changed code, not docs" is not an exemption; it is the
trigger.

*Second occurrence, SAME DAY, 2026-09-07.* A one-line deletion (a function
left dead by a refactor, caught by CI) went in without the gate, and CI went
red on `graph` for exactly the same reason. The trigger was identical and so
was the reasoning: the change felt too small to be worth three commands. It
is not the size of the change that decides -- it is whether the file declares
the obligation. `zfs-backup.sh` does, so every commit touching it runs the
gate, including the one-line ones.

*Rule.* R4's family, one shape further out: **the gate belongs to the COMMIT, not
to the session.** Every commit that touches a status-covered file runs the three
commands in order, including -- especially -- a hurried fix commit. If the reason
for skipping is "this one is urgent", that is the signal to run it.

### E40 — `${!arr[@]}` with a `set -u` guard is INDIRECT expansion, twice in one round

**2026-09-07, twice in the same work round: once in `list-profiles`, once in
`set-policy`. Both caught by running the code, neither by reading it.**

*Genesis.* This tree's idiom for iterating an array that may be empty under
`set -u` is `${arr[@]+"${arr[@]}"}`. Applied to the INDEX form it becomes
`${!files[@]+"${!files[@]}"}` -- and bash parses that as `${!VAR+word}`, i.e.
indirect expansion of a variable named `files[@]`. It expands to the array's
CONTENTS and then treats them as a variable name:

    ./zfs-backup.sh: line 10590: /d/…/Y5M12D31H24.conf /d/…/d30.conf …: invalid variable name

Written a second time an hour later, in a different function, for a different
array, because the first fix was applied at the site rather than remembered as a
shape.

*Cause.* Two bash constructs that read identically and parse differently. The
`+` guard is safe on `${arr[@]}` and changes the MEANING of `${!arr[@]}`.

*Rule.* R8's neighbourhood -- prefer what the tree already does, and check it
does what it looks like. Concretely: **never guard the index form.** Iterate with
a counter (`local n=${#arr[@]} i=0; while [ "$i" -lt "$n" ]`), or guard on the
count (`[ "${#arr[@]}" -eq 0 ] && return; for k in "${!arr[@]}"`). Both are
unambiguous and neither can turn into indirect expansion. The same family as the
`local a="$1" b=${#a}` trap already recorded in `lib-record.sh`: bash has several
places where a second reading is legal, and the compiler will not tell you which
one you wrote.


### E41 — I found the shape, fixed it at one site, and shipped it at two others

**2026-09-07, REV-20260907-136, caught by the Reviewer in code that was already
merged.**

*Genesis.* While writing `list-profiles` I found that a row emitted field by
field leaves HALF AN OBJECT in the middle of a JSON array when the emitter dies
part-way -- and made that row buffered. Two functions away, `status --json` and
`show-config` published records they had not validated either: `record_load`
dies for a disallowed field and returns non-zero for a malformed value, and
neither reader read that status. The reviewer reproduced all three forms,
including one where the answer changed depending on WHERE the bad line sat in
the file (155 bytes vs 163) -- the parser's partial state published as the
product's answer.

*Cause.* Not the bug; the REACTION to the bug. Having understood a shape, I
applied the remedy at the place I happened to be standing. The question that was
never asked out loud: *which other code has this shape?* It takes one grep --
`record_load` has two call sites in the new readers and both were wrong.

*Rule.* R3, and this is its third piece of evidence in one session (see E40,
where the same reflex wrote the same bash trap twice). **A defect found once is a
QUESTION about the whole tree, not a repair at one address.** When a fix is
written, grep for the shape -- the function, the field, the idiom -- and answer
in the commit message how many sites were found and why the others are clean.
"Fixed where I found it" is not a report.

### E42 — "snapget cannot copy locally", written from the usage line, corrected by the Owner

**2026-09-07, `OWNER-ENGINE-MERGE-2026-09-07.md`, caught by the Owner from the
fleet's own relationships.**

*Genesis.* A syntax table for the three engines put "(brak — cel lokalny,
źródło musi mieć hosta)" in snapget's local-to-local cell. The Owner: "snapget
potrafi lokalnie kopiować, przecież mamy relacje jednoserwerowe". Measured
afterwards: `snapget.sh:349-352` documents a bare dataset as a LOCAL source
("no ssh, used for local-to-local relocation/testing"), the parser leaves
`_item_host` empty for it, and `test/snapsend/run.sh` -- a suite I had cited
in the SAME document as "LOCAL MODE ONLY" -- runs snapget that way 27 times.

*Cause.* The claim was derived from the usage line (`REMOTE_DATASETS
[LOCAL_BASE]`) and the name of the first argument, not from the parser. Worse
than E38: the authoritative surface was not merely elsewhere, it was already in
my hands -- I had read the header block that says it, twenty lines below the
line I quoted, and had measured the suite's local mode the same hour. A fact
about one side of a boundary (the usage line) was carried across to the other
(what the parser accepts) without looking.

*Rule.* R2, and E38's lesson stated one notch harder: **a "the product does
not do X" belongs in a document only after the input that would exercise X has
been constructed and run, or the refusal that blocks it has been found by line
number.** A name in a usage string is a label, not a contract. The correction
went into the document as a fourth mode -- local in production -- in which the
two engines' duplication is total; the mistake made the argument stronger, which
is exactly why it should have been measured first.

### E43 — A drift alarm answered with a sentence, and the sentence was false

**2026-09-07, found while pricing the engine merge; the blessing is `fd26421`
of 2026-08-21, a different session.**

*Genesis.* `test/twins` refused, as designed, when `process_dataset` changed in
`snapget.sh` only. The bless commit recorded the decision: "-e (adopt the
existing family) EXISTS only on pull; push creates its snapshots and has no
adoption path, so there is no equivalent fix to mirror." `snapsend.sh:37`
documents `-e`; `USE_EXISTING_SNAPSHOT` drives the same code path at
`snapsend.sh:1371`; two days later one of the three scaffolding branches WAS
mirrored into push (`Only excluded families`, 1397) -- so the path was known
to exist. The other two branches and the aggregate guard never followed.
Measured today: push under `-R -e` fails a run over an empty path container
that pull skips, and reports success for a run in which every member was
scaffolding, where pull reports failure. Same flag, two behaviours, for
seventeen days, under a green alarm.

*Cause.* The alarm asks a question and accepts any answer. A claim about the
other twin ("has no adoption path") was written from memory of what push DOES,
not from a grep of what push HAS -- and nothing in the suite, the freeze entry
(which authorised `snapget.sh` alone and said nothing about the twin), or the
review asked for a line number. The `twin-functions` contract comment says the
alarm makes a fix in one direction "a QUESTION about the other"; it does not
say who checks the answer.

*Rule.* R3. A recorded exception is a claim about code and gets the same
proof as code: **a "the other side does not have X" blessing names the line
that would have X and shows it absent.** Structurally, in
`OWNER-ENGINE-MERGE-2026-09-07.md` section 8.2: a differing twin pair carries
a mandatory reason with a line number or a port-by deadline, and a freeze
entry naming one engine carries the twin's disposition. An alarm whose
answer is not checked is a comment (R3), and it has now been measured as one.

### E44 — A commit whose message describes an edit the commit does not contain

**2026-09-07, commit `5bd9cc5`, caught by me one command later.**

*Genesis.* One heredoc script edited three files; its third edit asserted on
an evidence line that had changed shape (E41 had already been appended to
R3's list) and the script died there. The next lines of the same shell call
were `git add`, `--refresh-status`, `--verify`, `commit`, `push` -- not gated
on the script's exit status. `--verify` was green (the two edits that landed
were consistent), so `5bd9cc5` went out with a message claiming "E43 under
R3" that the tree did not carry.

*Cause.* R4, verbatim: a mutation chained behind a step that can fail. The
heredoc printed a traceback and the shell went on, because nothing read its
exit status. The same shape as E37, one session later.

*Rule.* R4, evidence only -- no new rule. The mechanical form: a script that
edits files ends the command; staging and committing start the next one,
after the edit has been looked at. `python3 ... || exit 1` is the minimum
when they must share a call.

### E45 — A severity written from the call shape, corrected by reading the function

**2026-09-07, `OWNER-ENGINE-MERGE-2026-09-07.md` section 3, caught by my own
audit two hours later.**

*Genesis.* The gap table said the five `local x=$(...)` masks in snapsend.sh
put "a GUID compared against an empty string on the exact path this project
shipped three fail-open bugs on". The audit that then read `validate_snapshot`
in both engines found `if [ -z "$src_guid" ] || [ -z "$tgt_guid" ]; then
return 1` in both -- the empty answer is refused, the mask hid an exit status
nothing read. Hygiene, not fail-open.

*Cause.* The severity was inferred from the SHAPE of the call (`local x=$(...)`
masks rc, rc masked on a GUID read, GUID reads have been fail-open before)
without reading the eight lines below it. Same side-of-the-boundary error as
E42 in the same document, one section apart: the call shape is one side, what
the function does with the value is the other.

*Rule.* R2. Evidence only. The audit's own procedure -- extract and diff each
twinned function before classifying it -- is what caught it, and is now the
one that produces the `direction:`/`port-by:` reasons in `twins.sha256`, so a
severity claim about a twin has to survive a read of the twin.


### E46 - A proxy for the property, and a fixture that could not reach the branch

**2026-09-08, `list-jobs` as merged in PR #357, found by the Reviewer
(REV-20260908-138), P2, one day after the merge.**

*Genesis.* The verb refuses to publish job rows for a config it cannot read. I
tested that with `[ -f "$cfg" ]` and consumed the parser through
`done < <(config_section_dump "$cfg")`. `-f` proves the path is a regular file;
it does not prove the file can be OPENED, and a producer inside process
substitution has no exit status the loop can reach. So awk's refusal went to
stderr, the loop saw no lines, and an empty parse was indistinguishable from a
config with no sections: `rc=0`, `"jobs":[],"count":0,"unreadable":[]` -- the
verb recreating the exact failure it was written to prevent.

*Cause.* Two mistakes with one shape. I checked a PROXY for the property
(is it a regular file) instead of the property (can it be read), and my negative
fixture named a path that does not exist -- which fails the `-f` check one line
earlier and therefore could never reach the branch it was written for. The suite
passed 365/0 while the branch under test was unreachable.

*Rule.* R1, evidence. The mechanical form: when a check stands for "X will
work", the fixture must make X actually fail, and the assertion must prove the
branch ran -- not merely that the command survived. Where the property is
"a read succeeds", the read IS the test; and a producer whose status you cannot
read must be buffered, then checked, before anything is published.

### E47 - A selector that selected 0.4% of the file, used all day

**2026-09-08, `test/zfsbackup/run.sh`, caught by the Owner: "Dlaczego znowu
taka armie suit uruchamiasz? Miales robic selekcje".**

*Genesis.* The suite has had a `--section` flag for weeks, and I passed it on
every focused run: `--section saveprof`, `--section listjobs`,
`--section showscope`. Each took about twenty-five minutes on this box, which I
explained to myself as "the suite is slow here" and paid four times in one day.

Measured when the Owner asked: a focused run executed **387 of the suite's 736
assertions**. The flag was not decoration -- it did skip the early half -- but
every section I had ADDED sat outside its guard, each carrying the phrase
"Self-contained; always eligible, also under `--section X`". I wrote the words
"also under" while making the section ignore the flag. So a focused run still
paid for all of them, `saveprof` included, and `saveprof` alone costs **860 s**
because REV-20260907-137's gate runs the real `gen-cron.sh` per case.

*A SECOND MISTAKE, IN THE DIAGNOSIS ITSELF, and it is the reason this entry is
under R1 twice over.* Asked why, I measured the guard by finding the first `fi`
in column 1 and reported "41 lines of 11221, so a focused run executes 99.6% of
the suite". I told the Owner that number. It was wrong: 41 lines is the guard's
real span, but it cannot account for the 349 assertions a focused run actually
skipped, and I published the ratio without checking that it explained the
behaviour I had just seen. The honest number came from running the thing:
736 bare, 387 focused.

*Cause.* R1, twice. I never proved the guard could be reached -- the flag was
accepted, the named section ran, the output looked right, because everything
else ran too. Then I "measured" the guard with a script whose answer I did not
sanity-check against the runtime evidence sitting in front of me.

*Rule.* R1, evidence. When a flag claims to narrow work, measure the narrowing
by RUNNING it -- count the assertions, time the run -- and never by reading the
source for a span you then reason about. Here the fix is one `want()` helper and
an `if` around each self-contained section: `--section showscope` went from ~25
minutes to **7 seconds** (18 assertions), `--section listjobs` to 21 s (24).
The control that makes the change safe is the bare run, and it is not optional:
**736 before, 736 after, zero failures either way.**

### E48 - Nine defects in two days, and only two of them were mine to find

**2026-09-08, Owner: "Wyciagnij wnioski ze slabej skutecznosci suit w zderzeniu
z recenzentem i z rzeczywistoscia."** Not a single defect -- a measurement of
the whole apparatus.

*Genesis.* Counting the last two days: nine defects, of which the Reviewer found
three, the lab found three, a real production config found two, and the Owner
found one. The suites found **none of them** and stayed green throughout.

| defect | found by | why no suite could |
|---|---|---|
| readers published a REFUSED record (REV-136) | Reviewer | no fixture ever handed a refused record to a reader |
| the save-profile gate proved the renderer, not the generator (REV-137) | Reviewer | the negative case died in the renderer; nothing tested a value the renderer COPIES through |
| `-f` is not readability (REV-138) | Reviewer | the negative fixture named a nonexistent path -- it fails one check earlier, so the branch was unreachable |
| `monitor --json` emitted invalid JSON | lab | the stub printed one line per SCOPE; the engine prints one per DATASET |
| `show-scope --recursive` did nothing | lab | the stub answered identically whatever flags it was handed |
| `show-scope` named the wrong newest | lab | the stub's creation times were distinct; a real pool ties them |
| a red row for an account with no block | a real config | no fixture had a crontab without a managed block |
| `prefix` printed under a `pattern` column | a real config | the fixture's template set both, so either read looked right |
| `--section` did not select | Owner | nothing tests the test machinery |
| `list-jobs` read an INVENTED block header | the new suite, first run | every fixture for it was written by the same hand as the reader |

*Cause -- three classes, not nine problems.*

**A. The stub is written from the same belief as the code, so it cannot
contradict it.** Four of the ten. The suite agrees with itself while the estate
does something else. This is not carelessness that more care would fix: the
belief that produced the code produces the fixture in the same breath.

**B. The fixture cannot reach the branch it claims to test.** Three of the ten,
all found by the Reviewer. A refusal case that is refused EARLIER, or a negative
input too well-formed to reach the check. Green, for the wrong reason.

**C. Nobody tests the test machinery.** The selector, and the header grammar
that only hand-written fixtures ever used.

*Rule.* R1 for B and C -- prove the branch is reached, and measure a flag that
claims to narrow work. For A, a new discipline, and it is the reason
`test/realshape/` exists: **a stub is a claim about the world, and the claim
needs evidence.** Where a suite stubs an engine, the shape it assumes is pinned
against BYTES CAPTURED FROM A HOST, replayed verbatim. The captures are
sanitised for names and exact in structure, and the capture commands are
recorded beside them so they can be refreshed.

It earned its place on the first run: replayed against a captured production
block, `list-jobs` -- the verb written so the GUI would not show an empty window
on a busy host -- reported eleven running lines as unexplainable, because it
read the header with a grammar (`# BEGIN ... -- Source:`) no generator has ever
written. Four functions in this file and gen-cron.sh itself already read that
line correctly; I had written a fifth reader rather than looking. See also
[[feedback_convention_may_already_exist]]: the convention existed, in five
places, and I checked none of them.

### E49 - The same unchecked-producer defect, four lines below the one I was fixing

**2026-09-08, `show-scope` as merged in PR #362, found by the Reviewer
(REV-20260908-139), P2 -- one day after REV-138, in the same function.**

*Genesis.* REV-138 was about a producer whose failure was invisible through
process substitution. I fixed it, wrote a careful guard for the primary read of
`show-scope`, and four lines later wrote two more producers with no status check
at all:

    ubs=$(zfs get ... usedbysnapshots ... 2>/dev/null)
    case "$ubs" in ''|*[!0-9]*) ubs=0 ;; esac
    nbook=$(zfs list -t bookmark ... 2>/dev/null | grep -c . )

The `case` normalised a refusal to zero; the pipeline reported the counter's
status rather than the producer's. Both fields publish `0` as a legitimate
measurement, so the document asserted "no bookmarks" and "the snapshots occupy
no space" -- on the screen introduced to explain storage pressure.

*Cause.* R1 again, but the sharper form is about SCOPE OF A FIX. I treated the
defect as belonging to one call site. It belonged to a function: the property
"every producer's status is checked before its output is used" is a property of
`cmd_show_scope`, and I proved it for one of three. The reviewer's discriminator
is the one I did not write -- the primary read SUCCEEDING while a later one
fails.

*Rule.* R1, evidence. When a guard is added to one producer, every OTHER
producer in that function is part of the same change. The question to ask at fix
time is not "is this call checked now" but **"which calls in here are still
not"** -- and the answer is a grep over the function, not a memory of what was
just edited. Related: E41, where the same fix was applied at one site and
shipped missing at two others, one day earlier.

### E50 - I consolidated five copies without reading what they read

**2026-09-08, `cron_block_source()` as merged in PR #364, found by the Reviewer
(REV-20260908-140), P1.**

*Genesis.* `list-jobs` had shipped with a header grammar I invented, and the fix
was to use the one the tree already had -- in four inline copies plus
gen-cron.sh. I extracted a helper, pointed all five call sites at it, and wrote
in the commit message that the grammar now lives once. It does. It is also
wrong, and was wrong in all four copies before me: it takes the first
`# Source:` line in whatever it is handed, and four of the five callers hand it
the WHOLE crontab. cron permits arbitrary comments, so a line above this
project's block decided which config the install guards compared against -- and
`assert_cron_config_matches_installed` would then permit replacing the block
generated from a different config, deleting every send, prune and monitor line
it described.

*Cause.* R3, and a specific form of it. I treated consolidation as a mechanical
edit: same expression, fewer copies, no behaviour change -- which was true and
was the whole problem. **A helper is a claim that several callers want the same
thing.** Checking that claim is part of making it, and I checked only that the
five sites produced identical text, never what the text was reading. The defect
was pre-existing; the consolidation is what made it one line and therefore my
responsibility to have read.

*Rule.* R3, evidence. When several copies become one, state what the shared
function's INPUT is for each caller and check that the body is correct for the
widest of them. Here four callers pass a whole crontab and one passes a block:
the body has to be correct for the crontab, so the bounding belongs inside the
helper -- `sed -n '/BEGIN/,/END/p'` before the grep -- and not in a note asking
callers to narrow first. The caller that forgets is exactly what consolidation
is supposed to make impossible.
### E52 — The transfers screen was 25 lines tall on a 24-line terminal (2026-09-09, R6)

**Genesis.** Five TUI windows rendered as pure text. Every screen "looked
right" in the first render; the detail panel on Transfery ended after four
rows, which read as "the panel is short", not as "the panel is cut".

**Cause.** The two list boxes were sized by an arithmetic that counted rows
but not the header, the rule and the two borders of each box, so the sum of
boxes plus panel was 25 for a height of 24 and the last lines of the panel
were sliced off. Nothing measured the line count against the height until
the width/height assertion was written -- the same R6 shape as a green total
that cannot say an assertion never ran: a screen that fills the terminal
cannot say a line fell off the bottom.

**Rule.** R6. A rendered screen is evidence only when its line count and every
line's width are compared with the terminal size, in the test, for every
screen and every window, at 80, 120 and 200. The assertion exists now and it
is the one that found this.

### E53 — A fix that was "applied" three times and never written (2026-09-09, R2/R4)

**Genesis.** Replacing `"\t"` by `"|"` in `cmd_list_replicas` through a
Python patch fed to the Bash tool as a heredoc. The patch printed "edits: 1",
then "edits: 0" on the awk lines, and the third attempt with `repr()` showed
the file still carrying the tab.

**Cause.** The tool's heredoc drops one level of backslashes, so the literal
`"\t"` in the patch arrived as a quote-TAB-quote string that matched nothing.
A `replace()` that matches nothing is a silent no-op, and the print of the
count was the only thing that stopped the chain (R4). The fact "the patch
contains a backslash-t" was true on my side of the tool boundary and false on
the other (R2).

**Rule.** R4, and R2's boundary list gains one entry: **this tool's heredoc**.
Patches with backslashes go through a file written by the Write tool or build
the character with `chr(92)`; and every text replacement asserts that it
matched, so a no-op cannot pass as done.

