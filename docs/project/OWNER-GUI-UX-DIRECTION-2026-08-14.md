# BackUpAll GUI / UX direction

Date: 2026-08-14
Status: OWNER DIRECTION

## Principle

The public product is a language of **operator intent**, not a mirror of engine flags.

If relation metadata, installed CONFIG, ZFS state or a safe obvious default already determine an answer, the CLI/GUI must infer it rather than ask the administrator. The existence of an internal option is never a reason to add a public field, checkbox or dropdown. Historical transport-oriented knobs such as `--lan` are an example of implementation detail that should stay below the new public layer whenever the system can resolve it itself.

## Architecture

```text
administrator
    -> GUI / high-level CLI (intent)
    -> resolver + planner + defaults + validation
    -> canonical authorities: relation / CONFIG / ZFS facts
    -> orchestrator
    -> existing engines and legacy flags
```

One user intention may translate into many internal operations. The reverse mapping is forbidden as a design principle: many internal knobs must not become many GUI controls.

GUI and high-level CLI must use the same resolvers, planners, safety gates and authorities. No GUI-only state machine, provenance model, restore engine or shadow lifecycle database.

## Default-first UX

1. One safe interpretation -> use it.
2. One obvious common-case default -> use it and show it in preview.
3. Ask only for a real choice that changes intent or safety.
4. Ambiguous destructive target -> refuse / ask one focused question; never guess.
5. Internal mechanics stay hidden: transport, incremental/full choice, rollback technique, fencing, GUID verification, compression and legacy engine flags.

The ordinary path should therefore have very few fields.

## Progressive disclosure

Normal operator path shows only:
- what relationship / managed backup is being acted on;
- alternate destination only when requested;
- historical time only when requested (latest is default);
- resolved preview and consequences;
- destructive confirmation when necessary;
- final verification/result.

Expert capability remains first-class without polluting the normal form. An expert may point directly at an exact **managed backup copy** such as `hdd/backups/branch-01/rpool/data`, but only if existing project authorities resolve it unambiguously as a known managed copy. Unknown, ambiguous or unrelated local datasets refuse. Expert mode is more precise intent, not "show every engine flag".

## Restore model

Current minimal public direction:

```text
restore SOURCE [DESTINATION] [--at=TIME] [--yes]
```

The GUI should express the same model conceptually:

```text
WHAT   -> relationship/scope OR exact managed backup copy
WHERE  -> original/natural destination by default; explicit only for alternate target
WHEN   -> latest valid state by default; explicit only for history
PLAN   -> resolved source, physical copy, recovery point(s), destination,
          system-selected strategy and exact destructive consequences
CONFIRM -> consequential/destructive intent only
VERIFY  -> process result plus required GUID/state verification
```

The operator does not select incremental/full, rollback mechanics, write fence or GUID verification. Those are system decisions/proofs.

For FLAT historical recovery, a requested time resolves per dataset to the newest retained point at or before the requested time. The plan explains mixed times; the GUI must not imply a globally atomic point that did not exist.

## Backup/deployment model

The same rule applies outside Restore: user states source/destination/relationship intent; discovery and existing authorities resolve topology, endpoint, transport and reusable configuration; preview shows the plan; normal defaults handle the common case. Low-level verbs may remain for compatibility/diagnostics but do not define the GUI.

## GUI as views over project truth

A future GUI can naturally expose:
- Overview: relationships/jobs and measured health/status;
- Backup: create/resume backup by intent;
- Restore: known relationship or managed copy, original destination and latest by default;
- Details/Expert: resolved CONFIG facts, physical copy, history, verification evidence and exact remediation.

These are views/actions over canonical authorities, not new authorities.

## Safety UX

Safety is strong but quiet. Preflight, provenance, collision checks, recovery-point selection, fencing, GUID checks and retry/idempotency happen automatically. The operator sees facts and consequences, not configuration of the safety algorithm.

For destructive Restore the conceptual flow is:

```text
measure exact loss -> show -> confirm -> fence/final validation -> execute -> verify -> truthful final status
```

Safety mechanisms are not ordinary preferences and must not become bypass checkboxes merely because an engine can technically bypass them.

## Filter for every proposed GUI control

Before adding a control ask:
1. Does relation/CONFIG/ZFS already know it? -> infer.
2. Is there one safe common default? -> default it.
3. Is it intent or mechanics? -> hide mechanics.
4. Are two interpretations actually possible? -> no selector for theoretical ambiguity.
5. Is it frequent enough for the main path? -> otherwise expert/details or omit.
6. Can a clear preview replace configuration? -> prefer preview.

## Non-goals

This direction does not require rewriting all historical engine flags now, removing expert compatibility commands, implementing GUI before the orchestrator contracts stabilize, or creating separate local/remote products. One-host and multi-host layouts are one product; topology changes resolution facts, not the workflow.

## Current sequencing

REV-119 Restore safety gates are closed. The next primary technical work is the internal destructive execution slice. Public Restore grammar is still being minimized/finalized before freeze. GUI implementation comes later, but this direction constrains the architecture now so the internal and CLI work does not make the future GUI inherit engine complexity.

> The system may remain complicated under the hood. The administrator should not have to operate the complication.
