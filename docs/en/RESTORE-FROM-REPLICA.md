# Restore from a replica (removable medium)

Polish version: [ODZYSK-Z-REPLIKI.md](../pl/ODZYSK-Z-REPLIKI.md).

All commands as **root on the collector**. Examples: the medium's pool is `repl`.

The replica is a mirror of the copy tree: `repl/replica/<path of the copy on the collector>`.
No relation points to it — the disk lies in a drawer and is in nobody's records.
That is why it is addressed through `--from-copy`, which does not need a relation
record.

## 1. Look before you touch

```
zfs-media-gate.sh status repl weekly
```

`repl` is the pool name, `weekly` the job label — both from the `[replica:weekly]`
section in the config. It answers whether the medium is there and whether it may be
unplugged.

## 2. Connect

```
zfs-media-gate.sh attach repl weekly
```

The exit codes mean three different things: `0` the medium is there, `1` **it is not
there, and that is not an error**, `2` something is wrong and a human is needed.

## 3. See what lies on it

```
zfs list -H -o name -r repl/replica | head -30
```

## 3a. The key of an encrypted medium

`zfs-media-gate.sh attach` imports the pool but **does not load the key**. `restore --from-copy`
does it itself before anything else: first from the medium's key file on this host (the one
`prepare-media` saved), then from `--key-file=PATH`, and when there is none -- it asks for the key
(typed without echo) or for a file path. A key loaded by the restore is unloaded at the end.

## 4a. Restore ONTO THE COPY DATASET — the one for big data

```
zfs-backup.sh restore \
    --from-copy repl/replica/hdd/backups/<host>/<path> \
    --onto      hdd/backups/<host>/<path> \
    --overwrite --config=/etc/zfs-snapshot-all/jobs.<host>.<account>.conf
```

The target **must exist**. A delta is applied, or just a rollback — the message
`SAM ROLLBACK, bez transferu` means: the copy already had the replica's newest
point, so only the newer snapshots were removed, **zero bytes on the link**.

That is why this mode exists. Landing in free space (4b) at 10 TB needs as much
space again and moves every byte, whereas the copy dataset is already in place and
shares history with the replica.

**Without `--yes`** it shows the set of losses and asks. Answer `n` to just have a
look.

## 4b. Restore ALONGSIDE, when you want to inspect first

```
zfs-backup.sh restore \
    --from-copy repl/replica/hdd/backups/<host>/<path> \
    --onto      hdd/podglad
```

The target **must be free**; this form never overwrites. Children travel together,
each at its relative position.

By default **only the point** lands (one snapshot). `--with-history` carries all the
copy's snapshots up to that point (the oldest in full, then the increments) -- the
restored copy of the collector then has history and retention does not start from
zero.

## 5. Disconnect

```
zfs-media-gate.sh detach repl weekly
```

It exports **only if it imported itself** — a pool brought up by hand will not be
taken from under the operator.

## Good to know

**The config must be named** when a host has more than one. Each belongs to a
different account and carries different relations; choosing for the operator could
aim the restore by someone else's records.

**Several datasets at once** with a comma, positional pairs:
`--from-copy a,b --onto x,y`. The lists must be of equal length.

**The pause happens by itself.** The source has no relation, but **the target does**
— the collector's copy is written by pull. The run recognises the relation that owns
the target and puts its schedule on hold for the duration of the restore
(`paused 'src9'` … `resumed 'src9'`). Nothing has to be stopped by hand.

**Restored datasets are not mounted** — `recv -u`, deliberately. To look inside:
`zfs set mountpoint=… && zfs mount`.

## When the disk is yanked DURING a run

`prepare-media` creates the medium's pool with `failmode=continue`. Below is the ZFS
behaviour observed in tests, when a disk is lost during a write (`wait` is the ZFS
default, for a pool created otherwise than by `prepare-media`):

| | a write **already in flight** | a **new** write after the disk is lost |
|---|---|---|
| `continue` (a pool from `prepare-media`) | stuck in `D`, survives `kill -9` | `Input/output error` at once |
| `wait` (the ZFS default) | stuck in `D`, survives `kill -9` | also stuck in `D` |

**Neither kills the host.** In the tests `zpool status` kept answering and the other
pools were `ONLINE`. What kills a host is `panic` — a value we do not use here.

**Unblocking, and this is the real lever:**

```
zpool clear <pool>
```

Merely plugging the disk back in **is not enough** — the pool stays `SUSPENDED` and
the process stays stuck. Only `zpool clear` releases it, and then the queued signal
finally arrives. It works the same with both `failmode` settings.

**The medium's `failmode` is `continue`, set by `prepare-media`.** Changing it to
`wait` buys little — it does not save a process caught mid-write, and neither
setting threatens the host. The safeguard is what the gate already does: the pool is
imported **only within the run window**, and `status` says when it may be unplugged.
The exposure exists only during a run, not between runs.
