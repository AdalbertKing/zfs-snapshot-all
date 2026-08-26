# Lab rebuilt from zero — findings

Date: 2026-08-26. Owner direction: *"Stwórz lab od zera. Wyczyść wszystko. Masz
skrypt do tego — od razu go sprawdź. Certyfikaty też pomiędzy pve9 i pve1.
Produkcji nie tykaj."*

## Why it was rebuilt

Two design arguments about restore were built on the pve1↔pve9 pair, and both
rested on facts that turned out to be **residue from my own earlier lab work**:

1. *"root↔root trust exists between these hosts"* — it did, because the labs were
   run as root and left it there;
2. *"the collector connects to the source every hour"* — it did not. pve9 ran
   **zero** pull jobs and **every** relationship record on it ended in
   `STATE=removed`; the pve1 relationships were labs I had torn down.

Neither was a property of the estate. A restore design built on a contaminated
lab would have fitted the lab. Hence: clean everything, verify, rebuild.

This is the same failure mode as
[[feedback_controls_can_be_contaminated]] — a measurement that is true, and true
only because of what the measurer did earlier.

## F1 — `clean-relationships.sh` mangles the dataset names it exists to report

A client record stores its dataset list `%q`-quoted, so the separator between two
names is an escaped space:

```
MANAGED_DATASETS=hdd/lab9r1/192.168.28.99/hdd/lab9/tree\ hdd/lab9r1/192.168.28.99/hdd/lab9/flat
```

The discovery loop splits on whitespace and never decodes the quoting:

```bash
for d in $(grep -hE '^(RUX_TARGET|MANAGED_DATASETS|PEER_JOIN_GRANTED_DATASETS)=' ... \
           | cut -d= -f2- | tr -d "'\"" | tr ',' ' '); do
```

so the first name is reported as `.../tree\`, with a trailing backslash. That
string is not a legal ZFS name and cannot be pasted into a `zfs destroy`.

**Why it matters more than it looks.** The block's own comment states its purpose:
the tool deliberately does **not** remove data, it *names* it, because once the
client record is deleted nothing on the host links that dataset to anything at
all (measured 2026-08-20, `hdd/lab4direct`). A mangled name defeats exactly the
one job this code has. It appears in both the audit and the purge output, so it
is in the shared discovery function.

**Fix:** decode the record the way it was written, or split on a separator the
quoting cannot produce. Reading the value with the shell's own unquoting
(`eval`-free) is the awkward part — the values are `%q`-quoted precisely because
the file is sourced elsewhere.

## F2 — the audit reports data it has not checked; the purge checks

The audit prints `data <name>` straight from the records, by design ("costs no
`zfs` call"). The purge, on the same names, prints

```
data hdd/s1-tgt is ALREADY GONE -- the record named it, the pool does not have it
```

So the destructive verb verifies and the read-only one does not. On pve1 **every**
dataset the audit listed was already gone.

Separately each choice is defensible. Together with F1 they are not: an operator
reading the audit cannot tell *"this is gone"* from *"this name is corrupted"*,
and both look like *"this dataset is still here"*.

## F3 — our own in-flight hold leaked and blocked cleanup for four days

`hdd/osrc` on pve9 refused to be destroyed:

```
cannot destroy snapshot hdd/osrc@ord_2026-08-22_22-10-16: dataset is busy
$ zfs holds hdd/osrc@ord_2026-08-22_22-10-16
NAME                              TAG                  TIMESTAMP
hdd/osrc@ord_2026-08-22_22-10-16  zfssnapall_inflight  Sat Aug 22 22:10 2026
```

`zfssnapall_inflight` is **ours**. A run that died mid-transfer on 2026-08-22 left
the hold behind, and it was still there on 2026-08-26 with no job running
anywhere on that host. This is the class of defect
[[project_skip_path_hold_leak_fix]] already fixed once, in another path.

Not fixed here — recorded. Releasing it by hand unblocked the cleanup.

## F4 — `--commit-scope` runs host setup, and that surprised a production host

`deploy.sh --commit-scope=pve9` on pve1 did not only commit the scope. It ran the
standard host phases and **added a cron line to production root's crontab**:

```
0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log
```

The line is benign and arguably wanted. The surprise is the shape: a verb whose
name says "commit the scope" — a decision about permissions — also performs host
provisioning. An operator running it on a production machine to answer a
permission question does not expect their crontab to change.

Left in place pending the owner's decision.

## F5 — not ours, but recorded: pve1's `authorized_keys` carries a broken key

`/root/.ssh/authorized_keys` on pve1 contains an RSA key pasted in the old SSH2
`---- BEGIN SSH2 PUBLIC KEY ----` block format, spread over a dozen lines. In
`authorized_keys` a key must be one line, so sshd ignores those lines entirely.

Pre-existing, unrelated to this project, **not touched**. The file was backed up
(`authorized_keys.bak-20260826`) before the one line this work did remove.

## What the rebuilt lab is

| | pve9 (collector) | pve1 (source) |
|---|---|---|
| before | 23 orphan relationships, `hdd/osrc` residue, 2 stale `root@pve1` keys | 3 orphan lab relationships, 1 stale `root@pve9` key |
| after | zero traces, empty pool | zero lab traces, production untouched |

Then enrolled fresh, through the **untrusted** path (`--manual-join`): the
collector could not reach the source, so it produced a pairing package, the
package was carried over, and the source committed its own scope.

```
pve1  hdd/labsrc/vm-900-disk-0  (6 MB)   ->  pve9  hdd/labcoll/192.168.28.9/hdd/labsrc/vm-900-disk-0
      hdd/labsrc/vm-900-disk-1  (4 MB)   ->        hdd/labcoll/192.168.28.9/hdd/labsrc/vm-900-disk-1
```

Two disks of one guest, deliberately: that is the case the restore work needs —
one machine, several datasets, one command. Seed verified by GUID on all three
datasets, not by the run's own success message.

Both crontab changes on pve9 are the account's (`zfsbackup`), not root's.

## What the lab immediately settled

The restore planner, run against the real relationship, says:

> `Strategia: (zrodlo ... jest ZDALNE -- ustalenie strategii wymaga odpytania
> tamtego hosta; ten wycinek tego nie robi)`

The collector reaches the source as `zfsbackup-pve9@192.168.28.9`. **Nothing goes
the other way.** So the conclusion from the design discussion holds, and now it
holds against a real relationship rather than lab residue: restore-as-pull needs
a channel from the machine being restored to the collector, and that channel does
not exist and is not created by any current verb.
