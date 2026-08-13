# BackUpAll — portable continuation context

Date: 2026-08-14
Repository: `AdalbertKing/zfs-snapshot-all`

Purpose: seed for a new ChatGPT project thread after mobile/desktop chat desynchronization.

## Roles and workflow

- Claude = implementer.
- ChatGPT = independent reviewer / architect.
- Owner = final product/UX authority.
- GitHub is the current durable coordination channel.
- Peer context: `docs/internal/peer-context/CLAUDE.md` and `REVIEWER.md`.
- Formal reviews remain canonical for acceptance.

When Owner writes **Check**, do a fresh independent GitHub pass: read fresh `main`, perform safe write/read-back on `reviewer-write-probe` at the exact fresh SHA, inspect all new commits since reviewer baseline, review routing/REV/CI/peer-context, and act immediately when it is the reviewer's move. Report SHA, READ, WRITE/read-back, delta, findings, formal state and `czyj ruch`. Never assume previous capability or SHA is still current.

Owner expects autonomous continuation whenever the next action follows from repository state. Owner silence is not a blocker.

## Product philosophy

The user states **intent**; the program derives **mechanics**.

If relation metadata, installed CONFIG, ZFS state or a safe common default already determine an answer, do not ask the administrator for it. The public CLI and future GUI are an anti-corruption layer over historical engine complexity. Internal flags are not a template for public controls. `--lan` is explicitly remembered as the kind of implementation leakage not to repeat.

Normal public UX should have minimum tokens/fields, safe defaults, preview instead of configuration where derivation is possible, and fail closed on genuine ambiguity. Transport, incremental/full choice, rollback implementation, write fencing, GUID verification, compression and legacy engine flags are mechanics, not ordinary user choices.

Canonical GUI direction: `docs/project/OWNER-GUI-UX-DIRECTION-2026-08-14.md`.

## GUI direction

Future GUI must use the same resolver, planner, project authorities and safety gates as the high-level CLI. No GUI-only state machine or shadow source of truth.

Conceptually:

`administrator -> GUI/high-level CLI -> resolver/planner/defaults -> relation + CONFIG + ZFS facts -> orchestrator -> existing engines`

Normal GUI exposes only: what relationship/managed copy, alternate destination only when requested, historical time only when requested, resolved preview/consequences, required confirmation, and final verification/result.

Expert mode means more precise intent, not every engine knob. Direct selection of an exact managed backup copy is first-class if existing authorities prove its provenance unambiguously.

## Restore public direction

Minimal candidate remains:

`zfs-backup.sh restore SOURCE [DESTINATION] [--at=TIME] [--yes]`

Mental model:
- first positional = WHAT to recover;
- second positional = WHERE, only when different from natural/default destination;
- no historical modifier = latest valid backup state.

SOURCE must support both a normal relationship/scope selector and an exact managed backup-copy `POOL/PATH` for expert use. A physical path is accepted only if existing authorities map it unambiguously to a managed backup copy. Unknown, ambiguous or unrelated datasets refuse; never adopt arbitrary ZFS paths.

One-host and two-host restore are one product and one grammar. Transport/account syntax must not be required in the ordinary public family. Unknown destination identity should refuse rather than fall back to guessing, DNS probing or ad-hoc transport credentials.

For FLAT history, a requested time means per-dataset newest retained recovery point at or before that time. Do not present it as an atomic global instant.

Relevant Owner direction: `docs/discussions/RESTORE-CLI-LOW-PATH-OWNER-2026-08-13.md`.

## Restore default policy

Simple recovery = latest valid backup state back to original source. The program chooses transfer strategy from measured facts; the administrator chooses recovery intent, not incremental/full/rollback mechanics.

Default recovery does not require preserving divergent source state first. Required operator experience: exact measured consequences, explicit confirmation for destructive action, write fence/final validation, system-selected valid execution, GUID/state verification, and truthful cleanup/final result.

Consistency comes from installed CONFIG, never matching snapshot names. FLAT and ATOMIC semantics remain distinct.

## Current Phase 7 state

REV-119 is CLOSED. Accepted gate properties include exact pre-confirmation loss measurement, post-confirmation change detection by snapshot identity/set, source write fence through final validation, restoration of readonly value/provenance, truthful cleanup reporting, and direct regression for the boundary-snapshot failure branch.

Accepted implementation/evidence:
- production behavior `77df5b46b9ab48888f21e928f463a86dacee8293`
- final dedicated regression `a18aa627cb89d3a84aaaa9d6c0bce2bdef4da717`
- clean closure/routing head `d104f556055bca590d747d252877fa8333a8f432`, exact-head CI green and OPEN-THREADS empty at that point
- reviewer handoff `d2df3ee8750c123f0bb35c04a101225790a4e74c`
- GUI/UX direction `f6ca544937d90c51aff6163771c53c9c1e1e3d5e`

Always fetch fresh `main` before acting; these are historical anchors, not assumed current state.

## Next primary move

Continue Phase 7 with the internal destructive execution primitive under the reviewed gates, still without attaching the public parser. Keep the scope bounded to the already resolved local single-dataset path; preserve the fence and verified strategy, touch only approved blockers/state, verify final GUID/state, preserve truthful cleanup/failure reporting, use targeted tests and bounded live-ZFS evidence.

Do not broaden that internal slice into relation-level multi-dataset failure policy or cross-host public CLI. After the primitive is independently proven, perform one short final grammar pass and freeze the minimal public Restore surface before Gate 7.

Restore stays primary until Gate 7; full unified remote UX resumes after Gate 7 unless Owner reprioritizes.

## Anti-drift rules

- no second authority/state machine for convenience;
- HOST IS NOT A KEY; do not infer relation identity from hostname;
- ambiguity/provenance uncertainty -> refuse, never guess;
- relationship selector remains normal path; managed-copy path is expert parallel input;
- do not expose mechanics because old engine flags exist;
- do not describe technical measurement snapshots as preservation;
- do not claim atomic recovery for FLAT history;
- generated review routing is generated, not hand-edited;
- frozen engines remain frozen unless formally unfreezed/refreezed with evidence.

For every proposed public token or GUI control ask: Does the administrator truly need to specify this? Can the program already know it? Is there one safe default? Is it user intent or engine mechanics? If the program can know it, hide it.
