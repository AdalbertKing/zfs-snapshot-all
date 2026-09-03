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

*Evidence: E4, E5, E6, E10, E17, E23, E26.*

### R3 — A rule written in a comment is not applied by being written

When a comment states an invariant, grep for every site that should honour it and
check each. The gap between "the project knows this" and "this line does this" is
where the defects live.

*Evidence: E7, E2, E14, E16, E19, E21.*

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

*Evidence: E11, E20.*

### R6 — A green result is evidence only if you know what it should have printed

Count the assertions you expect by name and compare against the output. A total
that only goes up cannot tell you an assertion never ran.

*Evidence: E3, E9, E15, E24, E25.*

### R7 — Reproduce a fix's absence, not just its presence

Every fix ships with the failing control against the exact prior SHA. If the
control cannot be built, the fix is not understood well enough to ship.

*Evidence: applies to every entry; enforced by the review protocol.*

### R8 — Prefer the tool's own helper over a fresh implementation, and check it exists first

Before adding a flag, a parser or a knob: grep for one. Before using a test
helper, confirm the suite defines it. Before writing a resolver, check what the
renderer already uses.

*Evidence: E7, E3, E12.*

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
