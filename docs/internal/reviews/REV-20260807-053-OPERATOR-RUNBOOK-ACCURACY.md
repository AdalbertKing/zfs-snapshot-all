# REV-20260807-053 — operator runbook accuracy

**Reviewed head:** `e39521253bb40f2b1bba0cae59147b2a6e1385b5`  
**Scope:** `docs/PAUZA-I-BLOKADA.md` and the user-visible CLI text it quotes  
**Verdict:** **ACCEPTED**

The runbook is useful and mostly matches the shipped hard-disable model. The two operator-visible inaccuracies found on the original reviewed head were corrected in `54c69179640d304df84144358352fd20d4e9f686` and independently rechecked against the diff and the response in `c072e1986cb1c480da25e52171e8112ba3af0087`.

## F1 — the runbook says hard disable needs one SSH connection, but the implementation deliberately uses two

The original comparison table said:

> `Wymaga kontaktu z peerem | ... tak (jedno połączenie ssh)`

That was not the implementation. `cmd_disable_client` first calls `pair_control disable`, then calls `peer_pair_state`, which in turn performs a second `pair_control status`. The second connection is intentional: the design requires a read-back rather than trusting the write acknowledgement.

This matters operationally because a network interruption between those two connections is a supported `TRANSITION_INCOMPLETE` state.

**Closure:** fixed in `54c6917`. The table now states that the peer must be reachable for a write and a separate read-back; it no longer promises a one-connection implementation.

## F2 — the runbook reproduces a stale CLI message saying hard disable is unimplemented

The original soft-pause example quoted the then-current `pause-client` output:

> `Hard disable (peer-side gate) is a separate, unimplemented stage.`

That line was stale after REV-052 closed the hard-disable package.

**Closure:** fixed in `54c6917`. `cmd_pause_client` now points the operator to `disable-client NAME` for peer-side enforcement, including unlabeled manual commands. The runbook was updated to the same output, and `test/zfsbackup/run.sh` now asserts that the pointer is present and the word `unimplemented` is absent.

## What is accepted

The following parts of the runbook match the reviewed implementation and prior closure:

- soft pause versus peer-side enforcement distinction;
- unlabeled manual transfers are stopped only by hard disable;
- self-enable limitation of the relationship key is stated prominently;
- cron/config/keys/grants are not rewritten by pause/disable toggles;
- disable ordering is local pause → peer disable → peer state read-back;
- enable ordering is peer enable → state read-back → local resume;
- gate exit codes 91/92/93 versus SSH 255;
- the `pair_label`/`-L` carriage and retention-not-gated model;
- forced-command gate installation at `--join` and removal of stale bare copies of the same key;
- the operational traps from the live campaigns are worth keeping.

## Verification and closure

Verified directly from the patch for `54c6917`:

- F1 documentation claim corrected;
- F2 production CLI text corrected;
- exact runbook example corrected;
- regression assertion added to `test/zfsbackup/run.sh`.

Claude reports `zfsbackup 292/292`, `pause 74/74`, and `impact.sh --verify` clean in `docs/internal/reviews/responses/REV-20260807-053.md`. Those declared results are consistent with the submitted test change; no live/two-host rerun is required for this documentation + user-visible-message scope.

**Final verdict:** **ACCEPTED — REV-053 CLOSED.**
