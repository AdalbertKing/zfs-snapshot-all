# REV-20260807-053 — operator runbook accuracy

**Reviewed head:** `e39521253bb40f2b1bba0cae59147b2a6e1385b5`  
**Scope:** `docs/PAUZA-I-BLOKADA.md` and the user-visible CLI text it quotes  
**Verdict:** **CHANGES REQUIRED**

The runbook is useful and mostly matches the shipped hard-disable model, but two operator-visible statements are factually wrong on the reviewed head. Because this file is explicitly the 2am operational reference, both should be corrected before treating it as authoritative.

## F1 — the runbook says hard disable needs one SSH connection, but the implementation deliberately uses two

The comparison table says:

> `Wymaga kontaktu z peerem | ... tak (jedno połączenie ssh)`

That is not the implementation. `cmd_disable_client` first calls `pair_control disable`, then calls `peer_pair_state`, which in turn performs a second `pair_control status`. The second connection is intentional: the design requires a read-back rather than trusting the write acknowledgement.

This matters operationally because a network interruption between those two connections is a supported `TRANSITION_INCOMPLETE` state. The runbook itself explains the read-back correctly a few paragraphs later, so the table currently contradicts both code and its own prose.

**Required correction:** change the table to say that hard disable requires peer reachability / multiple SSH exchanges (or simply omit the connection count). Do not promise exactly one SSH connection.

## F2 — the runbook reproduces a stale CLI message saying hard disable is unimplemented

The soft-pause example quotes the current `pause-client` output:

> `Hard disable (peer-side gate) is a separate, unimplemented stage.`

That line is indeed still emitted by `cmd_pause_client`, but hard disable is now shipped, live-campaigned, and closed in REV-052. Copying the stale output into the new operator runbook turns an existing CLI wording defect into documentation.

This is not merely cosmetic: an operator reading the runbook immediately above a working `disable-client` section is told by the command output that the same feature is unimplemented.

**Required correction:** update `cmd_pause_client` to describe hard disable as the stronger available control (for example: `Use disable-client for peer-side enforcement, including unlabeled manual commands`) and update the runbook example to the new exact output. Pin the wording in the existing pause/zfsbackup tests that already assert the limitation text.

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

## Test scope

This is a documentation + user-visible message correction. No live or two-host campaign is required. Run the targeted pause/zfsbackup suites that pin the message plus `impact.sh --verify`; update the runbook from the resulting exact output.
