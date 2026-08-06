# REV-20260807-052 — hard-disable package closure

**Reviewed head:** `9b57523447ba16b58f816c169d643cf266cff120`  
**Scope:** hard-disable steps 2–4, REV-049, REV-050, REV-051, final campaign evidence  

## Verdict

**APPROVED. PACKAGE CLOSED.**

The peer-side enforcement gate, installation at `deploy.sh --join`, collector-side disable/enable orchestration, failure convergence, monitoring behavior, and final two-relationship live campaign are accepted for the declared threat model.

## Finding closure

- **REV-049 CLOSED.** `authorized_keys` replacement now fails closed when ownership cannot be established; the original file remains untouched and the staged file is removed.
- **REV-050 CLOSED.** `gate_state_dir_ok` checks the actual group digit rather than matching the owner's permission digit; malformed stat output also refuses.
- **REV-051 F1 CLOSED.** Commit `8dd0c8a` rejects `.` and `..` in both the standalone gate and the installing side before any path or forced-command line is constructed.

REV-051 includes the required negative control: on reviewed head `4fecbc2`, label `..` entered ACTIVE and executed the proof command. On the fixed tree, both dot segments return `PAIR_GATE_MISUSE`/91 and execute nothing.

## Evidence accepted

Targeted results reported for the final fix:

- `pairgate 75/75`;
- `join 82/82`;
- `joinmanifest 10/10`;
- `joinremote 8/8`;
- `impact.sh --verify` clean.

The parser-only REV-051 correction did not change the installed forced-command shape, state layout, orchestration, or transfer path. A second full two-host campaign is therefore not required. The existing final campaign remains applicable and proves:

- data-plane refusal even when a manual command omits `-L`;
- local-first disable and peer-first enable ordering;
- read-back verification and retry convergence after partial failure;
- isolation of the second relationship;
- persistence across sshd restart and endpoint changes;
- byte-identical config, cron, key and grant material across disable/enable;
- incremental continuation after re-enable;
- teardown without residue.

## Threat-model boundary

Approval is for the documented **peer-side enforcement gate** model. The relationship's own authenticated key may execute `PAIR-CONTROL enable`; therefore DISABLED blocks scheduled, accidental and ordinary manual transfers, but is not a boundary against a deliberate holder of that key. The ADR and user-facing documentation now state that limitation.

## Remaining work

No code or test finding remains open against the hard-disable package. Operational backlog items such as rebuilding pve2's missing cron config and deciding the fate of `docs/OPS_MONITORING.md` are separate owner decisions and do not block this closure.
