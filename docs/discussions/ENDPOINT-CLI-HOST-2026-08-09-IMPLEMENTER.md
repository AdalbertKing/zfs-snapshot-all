# Implementer note on `--host=` — agreed, with one trap the decision must carry

Response to `ENDPOINT-CLI-HOST-2026-08-09.md` and the root/delegated UX section
added to `DEPLOY-SEQUENCES.md`. Both are target-CLI documents; nothing here is
implemented and this note changes no code.

## Agreed, and the shipped facts check out

I verified the three claims about current behaviour rather than taking them:

| claim | measured in the tree |
|---|---|
| `add-client` takes `--lan=`, `set-endpoint` takes `--host=` | yes — `zfs-backup.sh:1388`, `:1861` |
| empty `LOCAL_USER` targets root's crontab | yes — `cron_target_user() { printf '%s' "${LOCAL_USER:-root}"; }`, `:1028` |
| `--local-user=root` is accepted and equivalent to omitting it | yes — `:1316` and the comment there |

The reasoning is right too. `--lan` names the transport type in a value that may
later be a VPN address, and `--ip` is wrong because the value may be a hostname.
`--host=HOST[:PORT]` is the only spelling that stays true.

The role split in the deployment note is also what the code already does, and I
have nothing to add to it: the account is one parameter, not a second procedure.

## The trap: `add-client NAME --host=NEW` must not reach the pairing path

The `--host` document proposes that re-running `add-client pve2 --host=10.8.0.2`
on an **existing** relationship recognises an address change and runs the safe
endpoint-switch path. I agree with the UX. The implementation has a specific way
to get it wrong, and it is worth writing down before anyone builds it.

`deploy.sh`'s `peer_label()` is **derived from the address** used at
`add-client`/`--pair` time. That label is not cosmetic — it locates deploy.sh's
manifest, its key files, and the physical target dataset path deploy.sh created
under that name. The comment at `zfs-backup.sh:52` states the consequence
already: calling `--draft-config` with a *different* `--peer=` address makes
deploy.sh treat it as **an entirely different, unpaired peer**.

That is precisely why `set-endpoint` exists as its own verb today. It changes
which address the generated job connects through and touches nothing else:
not `PEER_HOST`, not `label`, not the target path, not the pairing key, not the
pinned host key.

So the merged spelling is safe **only** if the collapsed command dispatches on
whether the relationship already exists:

- **name unknown** → enrolment, and the address becomes the label, as today;
- **name known, address differs** → endpoint switch, and the new address must
  **never** be handed to deploy.sh's pairing path;
- **name known, address identical** → no-op, which `set-endpoint` already
  implements.

Written down now because this is the class of thing that is cheap as a sentence
and expensive as a rewrite. The UX change is one flag; the routing behind it is
the whole safety property.

## One question back

`--lan=` retained "temporarily as a compatibility alias if needed" leaves the
duration open. My read of the owner's stated CLI philosophy — fewest illogical
aliases, most defaults — is that a permanent alias is exactly what he does not
want. I would rather the alias be either absent from the start or dated, since
an undated compatibility alias becomes a permanent second spelling.

Not deciding that myself.

## Status of these two documents

Both carry owner-decision headings for decisions I have not heard directly. I am
treating them as recorded design intent to implement when the single-host layer
is built, not as authorisation to change the shipped CLI today, and I have said
so to the owner rather than assuming either way.
