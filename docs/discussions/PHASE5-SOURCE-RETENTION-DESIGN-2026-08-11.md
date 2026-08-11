# REV-102 source retention — implementer answers to the 6 design questions

Status: implementer design, 2026-08-11. Builds ON the owner/reviewer working
agreement in `docs/discussions/SOURCE-TARGET-RETENTION-2026-08-11.md` (collector
owns both retentions; the default preset proposes the SAME ladder on both sides at
CREATE, then renders two INDEPENDENT editable native CONFIG policies; no runtime
coupling). REV-102 stays OPEN pending owner/reviewer sign-off on these answers.

Supersedes my earlier `-H48` short-source proposal: the owner chose **equal
initial values** (the current `24H/7D/4W/12M` ladder) on both sides, editable
before install — not a short asymmetric default.

## Q1 — the exact native CONFIG sections (PUSH and PULL)

Reuse the existing `prune.inc` GFS fragment for BOTH scopes; **no new template**,
`standard_hourly`/`keep_*` unchanged (minimal blast radius).

Local PUSH (`cmd_local_backup`), per root:
```
[dataset:<root>]            use_template=standard_hourly  dst=<target>   (send)
[prune:<root>]              GFS keep_* over <root>          (SOURCE retention)
[prune:<target>] recursive  GFS keep_* over <target>       (TARGET retention)
```
Remote PULL (`emit_client_sections`):
```
[dataset:<local-target>]    src=<acct>@<host>:<source>      (send)
[prune:<acct>@<host>:<source>] ssh_flags=<relationship>     (SOURCE retention, remote)
[prune:<local-target>] recursive GFS                        (TARGET retention)
```
Two independent `[prune:]` sections, initialized from the same fragment but
separately editable. The source `[prune:]` carries NO monitor (a remote scope
rejects `monitor_warn/crit`; check-snap-age is local-only).

## Q2 — remote prune reuses the relationship SSH boundary

The remote source `[prune:<host:source>]` `ssh_flags` are exactly the
relationship's pinned transport, taken from `LOAD_FLAGS`/`LOAD_KEYFILE`/
`LOAD_PORT`/`LOAD_ALIAS` that the pull already uses: `-K <keyfile> -p <port> -O
HostKeyAlias=<alias> -O UserKnownHostsFile=<alias_kh> ...`. gen-cron renders that
into `delsnaps.sh -K.. -p.. -O.. "<acct>@<host>:<source>" automated_hourly <ladder>`.
Same key, same host-key pinning, same identity as the transfer — no new channel,
no broad root SSH.

## Q3 — the destroy-grant gap (narrowest change)

Today the pairing (`deploy.sh --join`) delegates the collector account only what a
PULL needs on the source — `send,hold,snapshot` (and mount for receive on the
*target*), **not `destroy`**. `delsnaps.sh` needs `destroy` (and `mount`) on the
source datasets. So the narrowest change: **extend the source-side grant with
`destroy,mount` for the collector identity**, scoped to exactly the paired source
datasets, when a relationship opts into collector-owned source pruning. Activation
must **verify the grant and refuse** (fail closed) rather than install a remote
prune that fails every hour. This is the "narrow implementation gap" the review
anticipated: the grammar expresses the prune; the grant must catch up. Local PUSH
has no gap (same host/account).

## Q4 — incremental base survives source pruning + outage

The per-target **bookmark** machinery (`record_send_bookmark` in lib-zfs-snap.sh)
is the safety mechanism. On every successful send the source gets a bookmark of
the sent snapshot; a bookmark is NOT removed by the snapshot prune, so even after
the source snapshot ages out the next transfer can still be incremental from the
bookmark. Requirement: the **bookmark-prune age must exceed the source retention
window** (and any expected outage), so `[prune-bookmarks:]` never removes the base
the source prune relies on. For an outage longer than both, the correct behavior
is an explicit full-resend (the engine already falls back when no common base or
bookmark remains) — never a silent failure. The design pins: source `[prune:]`
touches only `automated_hourly_` snapshots, never bookmarks (`delsnaps -B` is a
separate op); and the bookmark age is coordinated with the source window.

## Q5 — migration for already-installed CONFIGs (no silent repair)

Changing the preset fixes NEW CREATE only. Existing relationships crossed the
one-way handoff and may hold deliberate edits; ordinary reactivation must not add
source retention as a hidden repair. Smallest boundary proposed:

- a **read-only audit** (`zfs-backup.sh audit-source-retention`) that lists every
  managed `[dataset:]`/relationship whose source creates `automated_hourly_*` but
  has no matching bounded source `[prune:]`, and prints the exact source-prune
  section(s)/cron line(s) it *would* add;
- a **previewed, confirmed transaction** to apply them — fold into the existing
  `migrate-profile` transactional model (workfile → validate → diff → confirm →
  atomic install/read-back) rather than a new public verb, since that command
  already exists to previewed-migrate a host and is idempotent. It must add ONLY
  the missing source `[prune:]`, leave any already-customized source retention
  untouched, and reconstruct no unrelated policy from today's profile.

Open for owner/reviewer: fold into `migrate-profile`, or a dedicated
`migrate-source-retention` if folding muddies that command's contract.

## Q6 — editable candidate, revalidated before commit

No new representation: the candidate IS native CONFIG v4 text. Slice-2 install
flow: render candidate (two `[prune:]` sections visible + a preview header
showing `SOURCE: 24H/7D/4W/12M` / `TARGET: 24H/7D/4W/12M`) → operator may edit the
candidate file → `gen-cron.sh -c` revalidate → `show_activation_proposal`
re-preview (final CONFIG + cron diff) → confirm → `atomic_replace_and_install`
with read-back. The profile is not consulted again after install.

## Sequencing (matches the review's phase gate)

1. Phase 5 transactional install stays blocked.
2. CREATE-time composition: both `[prune:source]` and `[prune:target]` (local +
   remote), independent, from the same initial ladder — generation tests +
   negative control vs `5423518…`; manual snapshots survive.
3. Remote grant: `deploy.sh --join` `destroy,mount` on source + fail-closed
   activation check.
4. Real-ZFS proof (local + remote): source ages out, target-only survives,
   manual survives, next transfer stays incremental (bookmark base). **Live-host
   obligation — this environment cannot run it; REV stays IMPLEMENTED not CLOSED
   until executed.**
5. Migration/audit path (Q5) settled and proven.
6. Close REV-102, then resume the Phase 5 install slice.

## The one product decision still open for the owner

The default window is decided as **equal to the current target ladder
(24H/7D/4W/12M) on both sides, editable**. The only remaining owner choice is
whether to keep those exact numbers as the shipped default or pick different ones;
the architecture (bounded + initially equal + independently editable) is fixed.

## Progress — step 2 (local PUSH composition) done; REV-102 stays OPEN

Owner directed implementing step 2 first, grant/migration later. Delivered for the
**local PUSH** path (`cmd_local_backup`, planning-only, no install):

- per root, alongside the existing `[prune:<target>]` GFS, a `[prune:<root>]`
  source-retention section from the same `prune.inc` ladder — two independent,
  separately-editable policies from the same initial values;
- both rendered as separate `delsnaps.sh -G -R ... "<scope>" "automated_" -H24 -D7
  -W4 -M12` lines (source scope vs target scope); only `automated_` is matched, so
  manual/foreign snapshots survive;
- the preview shows `Retencja ZRODLA` / `Retencja CELU` separately;
- `test/localbackup` 30/30 (+4); out-of-band control vs the reviewed base
  `5423518` shows 0 source-prune sections (the unbounded defect) vs 1 now.

**Explicitly deferred (per the agreed sequencing + owner "grant/migration later"):**

- **step 3 — remote PULL** `[prune:<host:source>]` in `emit_client_sections`: NOT
  emitted yet, on purpose. `emit_client_sections` is the installed `activate-client`
  path, so composing the remote source prune before the source `destroy` grant
  exists would install an hourly job that fails — the exact hazard REV-102 warns
  of. It lands with the grant + fail-closed activation check in step 3;
- **step 4** real-ZFS end-to-end (local + remote) — live-host obligation;
- **step 5** migration/audit path for already-installed CONFIGs.

REV-102 remains OPEN (Claude's move) until steps 3–5 land; no IMPLEMENTED response
is filed for a partial fix.
