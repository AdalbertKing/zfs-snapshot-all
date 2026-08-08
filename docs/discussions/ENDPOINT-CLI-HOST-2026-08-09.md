# UX decision — public peer address flag is `--host=`, not `--lan=`

Date: 2026-08-09
Status: OWNER UX DECISION / target CLI, not yet implemented

## Decision

The high-level `zfs-backup.sh` interface must not expose the transport type in the peer-address option.

Reject for the target CLI:

```bash
./zfs-backup.sh add-client pve2 --lan=192.168.28.8
```

Also reject `--ip=` because the value may legitimately be a hostname.

Use:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8
```

or equivalently with DNS / hostname:

```bash
./zfs-backup.sh add-client pve2 --host=pve2.example.local
```

Port remains optional in the same value:

```bash
./zfs-backup.sh add-client pve2 --host=10.8.0.2:2222
```

## Semantics

`pve2` is the stable relationship identity.

`--host=HOST[:PORT]` is the current transport address used to reach that peer. It is allowed to change during the life of the relationship.

Therefore LAN/VPN are not relationship identities and must not appear in the public address vocabulary. Internally the implementation may continue to model this as `ACTIVE_ENDPOINT` plus known previous endpoints.

Conceptually:

```text
pve2                         = stable relationship identity
rpool/data                   = WHAT is protected
profile=default              = HOW it is protected
192.168.28.8 -> 10.8.0.2     = current host/address may change
```

## Relocation / VPN case

Initial enrolment may be:

```bash
./zfs-backup.sh add-client pve2 --host=192.168.28.8
```

If the peer remains reachable through a routed VPN at the same host:port, no address change is required.

If the reachable address changes, e.g. to `10.8.0.2`, the same high-level relationship command should accept the new host as an explicit transport update:

```bash
./zfs-backup.sh add-client pve2 --host=10.8.0.2
```

Because `pve2` already exists, this must NOT create a second relationship. It must recognise an address change, show the old and new values, preserve the existing pairing/relationship identity, and execute the safe endpoint-switch path (including whatever final-catchup / verification gates are required by the current state machine).

The change must never be silent. A typical proposal should make the mutation obvious:

```text
Relationship: pve2
Host: 192.168.28.8:22 -> 10.8.0.2:22
```

and require the normal explicit confirmation before persistent mutation.

## Compatibility / implementation note

The shipped code currently uses `--lan=` for `add-client` and `--host=` for `set-endpoint`. The backend already has the more general endpoint model (`ACTIVE_ENDPOINT`, known alternatives, stable client identity).

The target UX should therefore converge on one public spelling: `--host=HOST[:PORT]`.

During migration, `--lan=` may be retained temporarily as a compatibility alias if needed, but it should not appear in new documentation or the final happy-path CLI once the new surface is implemented.
