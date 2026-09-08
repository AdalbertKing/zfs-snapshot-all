# Captured shapes, not invented ones

These files are **verbatim output from real hosts**, sanitised for names and
paths but not for structure: field counts, separators, spacing, line
multiplicity and exit statuses are exactly what the estate produced.

## Why they exist

Nine defects in two days (2026-09-07/08), and three of them came from the same
place: **a stub written from the same belief as the code under test cannot
contradict that belief.**

| defect | the stub's belief | what the host actually does |
|---|---|---|
| `monitor --json` emitted invalid JSON | one output line per monitored scope | **one line per DATASET** -- a two-dataset scope prints two (`check-snap-age.critical-multi.txt`) |
| `show-scope --recursive` did nothing | the stub answers the same whatever flags it is handed | `zfs list` does not recurse without `-r`, and the answer changes |
| `show-scope` reported the wrong newest | snapshots have distinct creation times | `creation` has one-second resolution, so a recursive snapshot ties them all |

A fourth belief is in here too, and it is the one that surprised me most:
**`check-snap-age.sh` prints NOTHING when everything is fine** (`rc=0`, empty
stdout -- `check-snap-age.multi.txt`), while my stub echoed a cheerful `OK:` line.
A reader that treated empty output as "could not tell" would behave one way in
the suite and the other way on the estate.

## The rule these files serve

**A stub is a claim about the world, and a claim needs evidence.** Where a suite
stubs an engine, the shape of that stub is checked here against what the engine
really printed. The suite `test/realshape/run.sh` does two things with each
capture:

1. feeds the REAL bytes to the reader that has to parse them, and asserts the
   reader survives and reports what the capture says;
2. asserts the SHAPE the stubs elsewhere in the tree rely on -- field count,
   separator, how many lines one invocation can produce -- so a stub that drifts
   away from reality turns red here instead of passing quietly for weeks.

## Sanitisation, and why the content is not the point

Production configs live in a **separate private repository** by the Owner's
decision, so nothing here carries a real hostname, dataset or job title. Names
were substituted (`hostA`, `backupacct`, `rpool/ROOT/os`, ...) with the
structure preserved byte for byte: same number of tab-separated fields, same
line counts, same `key=value` ordering, same exit statuses.

If a capture ever needs refreshing, take it the same way it was taken, then run
the same substitutions:

```sh
# on a host with a real installed block and real snapshots
crontab -l -u <account> | sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p'
zfs list -H -p -t snapshot -d 1 -o name,creation,used <dataset>
./check-snap-age.sh "<ds1>,<ds2>" "<pattern>" <warn> <crit>; echo "RC=$?"
```

Captured 2026-09-08 from the production collector and the lab node.

| file | what it pins |
|---|---|
| `crontab-managed-block.txt` | the installed block: the `# Source:` header, the `zfs-job.sh "TITLE" ... -- <engine> <args>` wrapper, and the bare `d=$(...)` monitor shape |
| `zfs-snapshots.txt` | `zfs list -H -p` output: three TAB-separated fields, parseable creation and used |
| `check-snap-age.multi.txt` | **silence on success** -- rc=0, no stdout |
| `check-snap-age.unknown.txt` | one line, rc=3, for a dataset that does not exist |
| `check-snap-age.critical-multi.txt` | **two lines from one invocation**, rc=2 -- the shape that broke `monitor --json` |
