# Pausing and disabling a relation: operator guide

Polish version: [PAUZA-I-BLOKADA.md](../pl/PAUZA-I-BLOKADA.md).

Two different tools for two different situations. Design: `docs/adr/ADR-0012-pair-pause-architecture.md`
and `docs/design/pair-pause.md`. Here is only what you type and what you see.

## Which one to use

| | **soft pause** (`pause-client`) | **hard disable** (`disable-client`) |
|---|---|---|
| Who enforces | the collector (this host) | the **peer** (the other server) |
| Stops cron jobs | yes | yes |
| Stops a manual command **with** the `-L` label | yes | yes |
| Stops a manual command **without** `-L` | **no** | **yes** |
| Needs contact with the peer | no | yes: the peer must be reachable (a write, then a separate read-back) |
| Typical use | maintenance window, disk swap, a noisy neighbour on the link | "this relation must stay down and nobody may touch it by accident" |

Both leave cron, the config, the keys and the ZFS grants **untouched**: nothing is rewritten,
removed or granted anew. The pause covers retention too: the relation's `delsnaps` lines carry `-L NAME`
and during a pause they exit before listing or deleting anything, on the source and on the target side. The reason: pruning
on a source that has just been rolled back from the copy can delete the only common snapshot.

**A limit you need to know about:** the relation's own key can lift its own disable
(`PAIR-CONTROL enable`). The hard disable stops automation, a mistake and an ordinary manual command,
but it will not stop someone who has that key and uses it deliberately. Every lift is written to the log on the peer.

---

## Soft pause

```bash
zfs-backup.sh pause-client alpha --reason='disk swap in the rack'
```

```text
>>> client 'alpha' paused (PAUSED_LOCAL). TRANSFER and MONITOR jobs, and labeled manual runs, now exit 'SKIPPED: relationship alpha is paused' before any snapshot/SSH work.
>>> Covered: retention too. This relationship's delsnaps lines carry '-L alpha' and exit before any listing, SSH or destroy while the pause stands -- on the source as well as the target.
>>> NOT covered: an engine invoked BY HAND without -L. The pause is a property of the relationship label, so a manual snapsend/snapget/delsnaps that does not name the label is outside it by construction, and deliberately so: the pause exists to stop the schedule, not to take the machine away from the administrator sitting at it.
>>> LIMITATION: this is logical pause -- a manual snapget.sh/snapsend.sh that OMITS '-L alpha'
    is not blocked. For enforcement at the peer, including unlabeled manual commands,
    use: zfs-backup.sh disable-client alpha
```

To lift it:

```bash
zfs-backup.sh resume-client alpha
```

What you see in the cron log when a job hits the pause:

```text
<date time> - SKIPPED: relationship alpha is paused (resume: zfs-backup.sh resume-client alpha)
```

A `delsnaps` line during a pause says the same, with a note that nothing was deleted:

```text
SKIPPED: relationship alpha is paused -- no snapshot was destroyed (resume: zfs-backup.sh resume-client alpha)
```

and in `zfs-snapshot-stats.log` there is **a status of its own**, never a feigned success:

```json
{"time":"...","script":"snapget.sh","dataset":"...","status":"skipped_paused","duration_s":0}
```

In the meantime the monitor wakes nobody, but it does not stay silent either:

```text
OK -- relationship alpha is paused (zfs-backup.sh pause-client); staleness is expected until resume-client
```

---

## Hard disable

```bash
zfs-backup.sh disable-client alpha --reason='down until further notice'
```

```text
>>> local pause established for 'alpha'
>>> asking the peer to disable this relationship...
>>> client 'alpha' is DISABLED: the peer refuses this relationship's data-plane commands,
    including manual ones that carry no -L.
>>> LIMIT: the relationship's own key can lift this itself (…enable-client alpha …)
```

The order is fixed and deliberate: **first the local pause** (so that no job starts in the window
between the decision and the information reaching the peer), then the peer, and last the **read-back**, because
the reply to a write says only what the gate thought it had done.

Lifting is exactly the reverse: first the peer, verification, and only at the end the local pause.

```bash
zfs-backup.sh enable-client alpha
```

When the peer is unreachable, nothing is made up:

```text
!!! the peer did NOT confirm the disable (ssh/gate said: …)
!!! STATE: PAUSED_LOCAL, peer NOT disabled -- scheduled jobs and labeled manual runs are stopped,
    but a manual command that omits -L would still reach the peer.
FATAL: retry the same command once the peer is reachable … it is a safe retry
```

Retrying is safe: the verbs on the peer side are idempotent.

What someone sees who tries manually despite the disable:

```text
PAIR_DISABLED: relationship alpha is disabled by administrator
```

The gate's exit codes are distinguishable, because over ssh they are the only information that comes back:

| code | meaning |
|---|---|
| 91 | `PAIR_GATE_MISUSE`: wrong label, no label, an attempt at an interactive session |
| 92 | `PAIR_UNKNOWN`: there is no such relation on this host |
| 93 | `PAIR_DISABLED`: the relation is disabled |
| 255 | that is ssh, not us: no connection or authentication |

---

## State

```bash
zfs-backup.sh status              # list
zfs-backup.sh status alpha         # details
```

```text
alpha                 state=active             endpoint=10.0.0.1:22  PAUSED_LOCAL
```

```text
Klient:            alpha
Stan:              active
Pauza:             PAUSED_LOCAL od <date time> (powod: down until further notice)
                   joby i reczne uruchomienia Z etykieta '-L alpha' sa pomijane;
                   reczne uruchomienie BEZ etykiety NIE jest blokowane (pauza logiczna,
                   nie granica bezpieczenstwa). Wznowienie: ./zfs-backup.sh resume-client alpha
```

The state on the peer side, when you want to ask directly:

```bash
ssh -i /root/.ssh/pairing/<peer>_ed25519 zfsbackup-<collector>@<peer> 'PAIR-CONTROL status'
```

```text
PAIR_STATE=DISABLED
PAIR_LABEL=kolektor
DISABLED_AT=<date time>
DISABLED_REASON=down until further notice
```

---

## What changed in the config and in cron

### Config: one field

`activate-client` adds `pair_label` to every section it generates. Hand-written sections
without this field behave exactly as before: no label means no gating.
A relation written by the tool looks like this (abridged; a full example in
[DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md), section 6):

```ini
[relation:alpha]
	tiers = hourly
	…                                          # policy: minutes, retention, thresholds

[dataset:hdd/backups/10.0.0.1/tank/data]       # the copy at the collector
	relation     = alpha
	side         = target
	src          = zfsbackup-arc@10.0.0.1:tank/data
	flags        = -i -K /root/.ssh/pairing/10.0.0.1_ed25519
	pair_label   = alpha

[prune:zfsbackup-arc@10.0.0.1:tank/data]       # source prune, over SSH
	relation     = alpha
	side         = source
	pair_label   = alpha
```

In a section with `relation = …`, `pair_label` must equal the relation's name. The field is **inherited
from nowhere**: not from `[template:]`, not from `[defaults]`. A label that spilled over into sections that are not its own
would mean that one pause stops somebody else's backup.

The field reaches the section's monitor **and** the `delsnaps` line, so the pause also stops
deletion on the storage.

### Cron: one flag

The transfer line (abridged):

```text
59 * * * * … snapget.sh -m "automated_" -i -K …/10.0.0.1_ed25519 -A -L alpha "zfsbackup-arc@10.0.0.1:tank/data" "hdd/backups/10.0.0.1" …
```

The monitor line:

```text
*/15 * * * * d=$(… check-snap-age.sh -L alpha "hdd/backups/10.0.0.1/tank/data" "automated_" 90m 3h 2>&1); …
```

The retention line, also with `-L`, so the pause stops it:

```text
30 2 * * * … delsnaps.sh -L alpha "hdd/backups/10.0.0.1/tank/data,…" "automated_" -H24 …
```

Two relations with identical thresholds will not merge into one monitor line: `pair_label` goes
into the grouping key. Otherwise pausing one would silence the other's alarm.

### The same line in plain words

Someone who reads these lines once in half a year, during a failure, has no time to reconstruct the meaning of the flags from memory.
So here is a breakdown of the same example, piece by piece:

```text
-i -K /root/.ssh/pairing/10.0.0.1_ed25519 -A -L alpha "zfsbackup-arc@10.0.0.1:tank/data" "hdd/backups/10.0.0.1"
```

| fragment | what it means | where it came from |
|---|---|---|
| `-i` | when catching up, **jump straight to the newest state** instead of going through all the snapshots on the way. Faster and less data, but the copy will not have the intermediate states | from your `flags` in the config |
| `-K …/10.0.0.1_ed25519` | log in to the other server **with this specific key**. It does what `ssh -i` does, but the letter `i` was already taken (see above), so the key got `K` | from your `flags` in the config |
| `-A` | **measure the link and decide by itself** whether compression pays off. The result is remembered for a week: link speed per host, data compressibility per dataset | added by the generator, by default |
| `-L alpha` | this transfer belongs to **relation `alpha`**. The only reason: when the relation is paused or disabled, the job backs out before doing anything | from `pair_label` |
| `"zfsbackup-arc@10.0.0.1:tank/data"` | **where we take from**: account `zfsbackup-arc` on `10.0.0.1`, dataset `tank/data`. The address is literal: exactly what `zfs list` shows there | from `src` |
| `"hdd/backups/10.0.0.1"` | **the base directory, not the destination.** The script appends the original path from the source underneath | from the header of the `[dataset:]` section |

The last row is the most common misunderstanding. The data will land **not** in `hdd/backups/10.0.0.1`,
but in:

```text
hdd/backups/10.0.0.1/tank/data
```

**The whole thing in one sentence:** *every hour take from `tank/data` on `10.0.0.1` what I do not have yet, log in
with the pairing key, if it is behind, jump straight to the newest state, decide about compression by itself, put it under
`hdd/backups/10.0.0.1`, and back off completely if relation `alpha` is paused.*

---

## Peer side: what `deploy.sh` does

Nothing has to be typed by hand: `--join` installs the gate when the relation is set up.

```text
>>> pair gate installed at /usr/local/sbin/zfs-pair-gate; relationship state at /var/lib/zfs-snapshot-all/relationships/kolektor
>>> installed the gated key line in /home/zfsbackup-kolektor/.ssh/authorized_keys
    (forced command: /usr/local/sbin/zfs-pair-gate kolektor); every other line preserved
```

The key line after this operation:

```text
command="/usr/local/sbin/zfs-pair-gate kolektor",restrict ssh-ed25519 AAAAC3Nza… 
```

The label in this line is **the collector's name**, not the client's name on the collector: the gate recognises
the relation by the key, so what you call it on your side does not matter to it.

Three things worth remembering:

- the gate lives **outside** the repository directory (`/usr/local/sbin`), so that rolling back the code cannot
  remove it;
- the other lines in `authorized_keys` (your own keys, other tools) stay byte for byte;
  the swap is atomic and refuses if it cannot preserve the file's owner;
- the old "bare" key of the same relation **does not stay next to** the gated one. Left in place it
  would authenticate bypassing the gate, and every disable would be a fiction.

Lifting a disable directly on the peer, when the collector has no way to reach it:

```bash
rm -f /var/lib/zfs-snapshot-all/relationships/<label>/disabled
```

---

## Pitfalls

- **`verify-endpoint` on a disabled relation.** Its probe is a data-plane command, so the peer
  rejects it. The tool says so outright ("relationship is DISABLED at the peer … This is not an
  address problem"): do not hunt for a network fault, lift the disable first.
- **`remove-client` does not clean up the peer.** It prints the commands to run there (`deploy.sh --leave=<label>`)
  and they have to be run by hand. Skipping it leaves a manifest that, at the next `--join` under the same
  label, will rightly block enrolment as a collision.
- **One relation per pair of hosts.** A second client for the same peer address interweaves the state on both
  sides.
