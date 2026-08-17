# Owner decision — `--grant-remotely`

Date: 2026-08-17
Status: OWNER DECISION (recorded by the implementer; the owner accepted the
semantics of `docs/discussions/ZFSBACKUP-ONLY-DEPLOYMENT-2026-08-17.md` §3
verbatim: "Akceptuję tę semantykę. Implementuj.").

## What is decided

1. The flag is named **`--grant-remotely`** — the adverbial form matching the
   existing `--join-remotely`, naming exactly the action consented to. The
   name `--force-*` was considered and rejected: this tree's own restore
   design records that a `--force` which changes a safe command into a
   consequential one is a refused shape, and "force" names pressure, not
   intent.
2. **REV-20260802-033 U10 is amended**: "finalize (`--commit-scope`, the
   grant) never runs remotely" becomes "…never runs remotely, **unless
   `--grant-remotely` explicitly authorizes it**". The default path stays
   two-touch and U10-shaped.
3. Binding semantics (all six properties of the accepted table):
   scope committed equals the request by construction, never wider; a
   differing pre-existing draft refuses even under the flag; missing root
   channel refuses early, before any state change; the source keeps an audit
   fact (`GRANTED_REMOTELY_BY` in the join manifest + gate-visible log); the
   flag implies `--join-remotely`; `--local-user` naming a missing account
   creates it locally with a loud line, consented via the `--yes` preview.
4. Verification is unchanged in authority: after a remote grant, the ordinary
   committed-scope check (fetch + sha256 sidecar + `scope_includes`) still
   runs and still decides.

## Why

The lab3 campaign (2026-08-17) measured that every departure from the
one-command vision of `OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md` had one
of two causes: the U10 boundary or a missing root-ssh channel. It also
measured that `--join-remotely` already performs root actions on the source
(account, key, gate) over the operator's own ssh — so in the remote-operator
scenario the mandatory second touch protects ceremony, not a boundary. The GUI
direction sharpens this: a click that pastes a command is not more deliberate
than a flag that names the consent.

## What this does not decide

- F7 (chained-topology snapshot families; passive sync-from-copy) — separate
  decision, still open.
- Any relaxation of topology guards or of the pause/disable/gate mechanisms.
