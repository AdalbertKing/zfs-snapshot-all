# Test-impact graphs: turning "did I test enough?" into a tool's answer

This describes a small, portable technique, not a framework. It is two files —
a hand-written declaration and a ~350-line bash resolver — and it exists to
answer one question mechanically instead of from memory:

> I changed these files. What am I now obliged to run, and what can no test
> cover at all?

It was built for a ZFS backup toolkit (7 shell scripts, 6 test suites, 4
production hosts) after judgement failed twice in one day. It is not specific
to that project. The ideas below transfer to any codebase where "run the whole
suite" is too slow, too expensive, or — the interesting case — **not actually
sufficient**.

---

## Why this exists: two failures a green suite did not prevent

**1. A change nobody thought to re-test.** A patch touched `delsnaps.sh`. Its
suite existed, was fast, and was not run — not out of laziness, but because
the change *looked* like it belonged to a different area. The gap surfaced
days later.

**2. A green suite as a false alibi.** A different change ran 161/161 green.
One run as a *delegated non-root account* then found **four** defects in a
row. The suite was not wrong; it was structurally incapable of reaching those
paths, because the test runner is root and root cannot reproduce a
permission-denied failure. Nothing in the codebase said so out loud, so
"161/161" read as "covered".

Both failures share a root cause: **the mapping from a change to its
obligations lived only in someone's head.** Every other part of the process
was written down and automated. That one was not.

---

## The model

Three kinds of edge connect a changed file to an obligation. **Only one of
them is derivable from the code**, and that asymmetry is the whole design.

### 1. Source edges — derived, never maintained

`a.sh` sources `b.sh`. The resolver parses this out of the code itself, so
changing the lib pulls in every consumer's obligations automatically. Nothing
to keep in sync by hand.

`--verify` fails if what the parser finds disagrees with what is declared, so
this stays honest as the code moves.

### 2. Suite edges — declared, because intent is not parseable

Which suite exercises which file. Declared by hand for two reasons: a suite's
subject is usually a variable (`$SNAPSEND`, `$LIB`), and — more importantly —
"exercises" is a claim about *intent*, not a fact about text. A suite that
merely imports a file is not testing it.

### 3. Contracts — the actual payload

**Two files that must agree although neither includes the other.** No parser
will ever find these, they are invisible to coverage tools, and they are
where the expensive mistakes live. From the original project:

| Contract | The trap |
|---|---|
| `monitor-exit-codes` | A generator hardcodes another script's exit codes *in a string it emits*. Add a code on one side, the other silently misroutes it. |
| `delegation-verbs` | A deploy script grants exactly the permissions the runtime scripts invoke. A missing one fails **non-fatally** — the feature just quietly stops working, with no alert, forever. |
| `account-paths` | The deploy script *provisions* `$HOME/x`; the runtime scripts *default* to `$HOME/x`. Two separate files, no reference between them, silently drifted apart. |
| `hold-tag` | A magic string duplicated in two files that don't import each other. |
| `ssh-flag-parity` | Three tools deliberately expose the same flag set, and a config generator hardcodes that set as an accept-list before pasting it into a command line. |

Every one of those had already broken something before it was written down.
That is the test for whether a contract is worth declaring: **has this pair
ever surprised you, or could a rename in one file leave the other quietly
wrong?**

### And: manual obligations as first-class citizens

Some paths cannot be automated **in principle**, not merely "not yet":

- an SSH path where the tool deliberately refuses loopback, so it needs a
  second real machine;
- privilege-denied paths that the root-running test harness cannot reach;
- destructive operations no unattended suite should perform.

The graph names these and prints them alongside the suites. A tool that says
*"and these three things no test covers — do them by hand"* is worth more
than a green checkmark that quietly means less than it appears to.

---

## What it looks like in use

```
$ ./test/impact.sh
CHANGED (3)
  delsnaps.sh
  snapget.sh
  snapsend.sh

SUITES TO RUN
  sudo ./test/delsnaps/run.sh    (needs root, zfs -- because delsnaps.sh changed)
  ./test/remote/run.sh --peer …  (needs a SECOND host -- because snapsend.sh changed)

CONTRACTS TO RE-CHECK  (nothing in the code enforces these)
  delegation-verbs  (with: deploy.sh snapget.sh)
      why:   a missing verb fails non-fatally and therefore silently…
      check: every `zfs <verb>` the scripts call must appear in ZFS_PERMS

MANUAL -- NO SUITE COVERS THIS
  nonroot-account  (because snapsend.sh changed)
      why: root cannot reach either failure…
      how: su - <account>, then run … with NO environment overrides
```

Cheap local suites are listed first, so a failure there saves the trip to a
real host.

Other modes:

```bash
./test/impact.sh HEAD~3..HEAD   # what a commit range obliged
./test/impact.sh -f a.sh -f b.sh # ask about specific files, no git
./test/impact.sh --all           # the full battery
./test/impact.sh --graph         # mermaid rendering
./test/impact.sh --verify        # drift check
```

---

## `--verify` is half the value

A graph nobody validates rots into decoration within a month. `--verify`
fails when:

- a declared file no longer exists;
- **a tracked source file is missing from the graph entirely** — so a new
  script nobody decided about breaks the build, deliberately;
- a contract is listed on one side only (asymmetric membership);
- a suite/manual/contract name is referenced but never declared;
- a declared suite's command is not executable **as tracked in git** — see
  the war story below;
- a derived source edge is absent from the declaration.

The graph's own test suite asserts `--verify` against the **real tree**, not a
fixture. If it fails, the graph is stale — that *is* the finding.

---

## Porting it to another project

The resolver is generic; only the declaration is project-specific.

**1. Copy two files:** `test/impact.sh` (the resolver) and
`test/impact/run.sh` (its self-test). Both are plain bash + coreutils.

**2. Write your own `test/deps.conf`.** The format:

```ini
[file:src/thing.sh]
suites    = unit, integration
manual    = needs-real-hardware
contracts = magic-string-sync

[file:test/fixtures/]          # trailing "/" covers everything beneath
suites    = unit

[suite:unit]
cmd    = ./test/unit/run.sh
needs   = nothing              # "nothing" sorts these first in output
covers  = what it actually exercises, honestly

[manual:needs-real-hardware]
why = the reason no suite can ever do this
how = the concrete steps

[contract:magic-string-sync]
members = a.sh, b.sh
why     = why they must agree, and what breaks silently if they don't
check   = how to verify it by hand
```

**3. Adjust the source-edge parser** if your language isn't shell — the
regex that finds `. "$DIR/lib.sh"` is the only language-specific part.
Python `import`, Go `import`, JS `require`/`import` all work the same way; the
rest of the tool is language-agnostic because it only ever deals in file
paths.

**4. Run `--verify` in CI.** That is what keeps it alive.

### Sizing guidance

Worth it when: suites are slow or need special environments (hardware, a
second host, root, a real database); some paths are *structurally* untestable;
or magic strings/permissions/schemas are duplicated across files that don't
import each other.

Not worth it when: one fast suite covers everything and always runs. Then
"run everything" is already the right answer and this is pure overhead.

---

## Field notes — mistakes made building it

Each of these was found live, and each is a trap the next person will hit too.

**Config continuation lines must be decided by indentation, not by looking
for `=`.** Wrapped prose like `gets canmount=on` otherwise parses as a new
key and silently truncates the field — losing exactly the explanation an
operator needs. Structural rules beat content-sniffing.

**A helper that took `$1` as a grep pattern got called as `outgrep -i pat`**
and quietly searched for the string `-i`. The two cases expecting *zero*
matches then passed for the wrong reason. **A false green is worse than a
red.** Assertions that expect nothing deserve extra scrutiny.

**Running a suite through `| tail` returns tail's status.** A red suite got
committed that way. Capture the status first, or run unpiped.

**Git on Windows does not record the executable bit.** Three test scripts
landed in the index as `100644`; deployment is `git pull`, so every host got
files it could not run — while `test -x` passed locally and hid it. `--verify`
now reads `git ls-files -s` rather than the working copy, because **the index
is what ships**.

**Mermaid node IDs must be word characters only.** A path-derived ID like
`F_test/impact/run_sh` parses as a link and silently breaks the entire
diagram, while the file still appears in the source — easy to miss.

**The count-of-suites assertion was hardcoded.** It broke the moment a suite
was added. Derive such counts from the declaration; the thing that goes stale
is the assertion, not the code.

---

## The idea worth stealing, if nothing else

Write down the obligations a change creates — including **the ones no test
can discharge** — and make a tool print them. The value is not automation;
it is that "what does this change oblige?" stops being a judgement call made
under time pressure, by whoever happens to be looking, and becomes a
reviewable artifact that a machine checks for drift.
