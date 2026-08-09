# Create-only presets and relationship-owned deletion — checked against the code

Answer to §13–§15 of `PROFILE-PREINSTALL-NOT-FULL-CONFIG-2026-08-09.md`. No code
changed. Everything below was read out of the tree, not recalled.

## §14 — deletion: agreed, and it is already built

Nothing to construct. `remove-client` already does what §14 describes, in that
order, and the ownership test is already relationship identity rather than
resemblance:

- sections are identified by `# managed-by: zfs-backup.sh client=<name>` plus
  this client's recorded `MANAGED_DATASETS` / `MANAGED_PRUNE_SCOPE`
  (`is_previously_managed()` word-splits both, so sync mode's per-dataset prune
  scopes work as a list);
- a header match with **no** marker and no prior record is refused as
  hand-written rather than deleted;
- the shared CONFIG survives; only this relationship's sections go;
- teardown then runs `deploy.sh --unpair` and marks `STATE=removed`.

There is no reverse template matching anywhere and no profile history to
consult. I agree there should never be.

**One property worth stating because §14 depends on it:** the marker records
*who owns the section*, not *which profile it resembles*. That is exactly why
deletion needs no profile knowledge — and it is also why the preset layer can
stay create-only without losing the ability to clean up after itself.

## §13 — create-only and overlap refusal: partly built, and the gap is specific

**Already refused:**

| case | what refuses it |
|---|---|
| same client name enrolled twice | `add-client` — `client '<name>' already exists` |
| a section at a path another client owns | `remove_managed_sections` refuses a marker naming a different client |
| a section at a path nobody marked | refused as hand-written |
| an install that would delete cron lines a target runs today | `assert_target_block_not_clobbered()` |

So the **exact-path** collision §13 describes is already covered, and covered by
relationship identity, which is the right test.

**Not refused, and this is the real gap:** *overlapping* coverage that is not an
exact path match. Nothing compares a newly requested source root against the
subtrees other clients already cover. Client A owning `rpool/data` and client B
later requesting `rpool/data/vm-101` produces two different section headers, so
no marker check fires, and the two would prune and send the same snapshots on
different schedules — the prune-scope race this project already fixed once for
`delsnaps`.

I am naming it rather than fixing it, because §13's rule and the smallest safe
implementation are not obviously the same thing:

- a **path-prefix** refusal is one comparison and catches the case above;
- but a client with `recursive = no` covering `rpool/data` does **not** actually
  cover `rpool/data/vm-101`, so a naive prefix test would refuse a legitimate
  deployment;
- reading recursion per section to decide is the beginning of the coverage model
  `--reconcile` already has, and duplicating it here would be a second one.

**My recommendation:** refuse on path prefix *in either direction*, plainly, with
a message naming the other client, and accept that it is stricter than strictly
necessary. §5 already says V1 may simply refuse and send the expert to native
CONFIG. A refusal that is occasionally too cautious costs one manual edit; a
missing refusal costs a silent double-prune.

Not implementing that until it is agreed — it is a behaviour change to
enrolment, not a defect fix.

## §13 — "existing CONFIG is not a reason to refuse": confirmed, already true

`ensure_cron_config()` appends and never rewrites: templates are added only when
that name is absent, and client sections are added per dataset. A CONFIG holding
bespoke manual policy for `rpool/data` receives a new `rpool/lxc` package without
the existing sections being touched. Measured shape, not intent — this is what
the emit path does today.

The transactional part §13 asks for is also already there: `migrate-profile` and
activation both build a working copy, validate it through the real
`gen-cron.sh`, show config and cron preview, ask, then install atomically.

## §15 — one correction to the summary of my analysis

The summary is accurate except in one direction I want to tighten rather than
accept the credit for.

I wrote that `PROFILE_ACTIVE` is process-local and no runtime operation requires
a persisted profile identity. That remains true. But it is a statement about
**today's** code, and today's code has exactly one preset and no selection. It is
evidence that persistence buys nothing *now*, not proof that it never could.

If a second preset ever ships and an operator can choose, the question returns as
"which preset did I use for this source" — and the honest answer then is
provenance in a comment, not state. I would rather that limit be written down
now than discovered as a surprise later.

## What I think should be built next, smallest first

1. **Nothing** for §14 — it exists.
2. **Documentation** for the expert path (§7 of the earlier note): the native
   CONFIG shapes are all running on this fleet already, so the examples can be
   copied from measurement.
3. **The overlap refusal**, if agreed, as one comparison with a clear message.

Everything else in the earlier Stage 5 C/D plan stays deleted.
