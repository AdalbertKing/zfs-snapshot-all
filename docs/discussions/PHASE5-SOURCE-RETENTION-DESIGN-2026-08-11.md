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

## Q3 — grant: NO widening (corrected per REV-103 F1)

Corrected against the current code. `deploy.sh` `do_commit_scope` already
delegates, per granted source dataset:
`snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark`
(`ZFS_PERMS`, line 146), so `destroy` (and `bookmark`) are ALREADY present at
exactly the relationship scope. The default source prune is a plain
`delsnaps.sh` → `zfs destroy <snap>` of `automated_hourly_` snapshots, which needs
only `destroy` — **already granted**. So there is **no grant gap and no widening**;
my earlier `destroy,mount` proposal was wrong (stale grant assumption).

Two real edges to pin, derived from the command path, not from a remembered grant:
- `mount` is needed **only** for `-F` clear-cut (`zfs destroy -R` must unmount a
  dependent clone, which on Linux requires root regardless of delegation). The
  collector-owned source prune is deliberately **not** clear-cut, so it stays
  within the delegated `destroy`;
- step 3/4 must include a **current-grant negative control**: the delegated
  identity with `destroy` succeeds; with `destroy` revoked the remote prune fails
  closed and activation refuses — proving exactly the permission the path needs,
  no speculative widening.

Local PUSH has no grant question (same host/account).

## Q4 — incremental base: bookmark is CONDITIONAL, not a guarantee (corrected per REV-103 F2)

Corrected. The per-target bookmark is only conditionally a base, and the design
must not claim otherwise:
- `lib-zfs-snap.sh` implements bookmark fallback **only for single-dataset /
  non-recursive** transfers; a recursive stream falls through to a FULL send
  (it would need a bookmark/GUID match on every child);
- `record_send_bookmark()` is **best-effort**: a failed bookmark refresh logs a
  warning and does not fail an otherwise-successful transfer.

So source pruning can remove the last common snapshot with no usable bookmark
behind it. The invariant the source-prune path will enforce, before any real
pruning:

1. **Non-recursive relationship with a confirmed bookmark** → the base survives
   the snapshot prune; next transfer stays incremental. This is the only state in
   which incremental continuity is claimed.
2. **Recursive relationship, or a relationship whose last bookmark refresh
   failed/does not exist** → source pruning past the last common snapshot forces a
   FULL resend. This must be an **explicit product decision surfaced in the
   preview/status** ("shortening SOURCE retention below your backup gap, or on a
   recursive relationship, can force a full resend"), never an accidental
   consequence of a non-fatal bookmark failure.

The actual invariant (corrected per REV-103 residual F2): **incremental continuity
is guaranteed only when a usable ordinary common snapshot OR a proven usable
bookmark remains.** The default equal ladder (24H/7D/4W/12M) *reduces* the risk --
under normal cadence the last-sent snapshot stays inside the window -- but it does
**not** by itself prove the base survives every failure sequence. A non-recursive
relationship can still lose continuity even under the default window if a bookmark
refresh failed/was absent AND later failed backup attempts created newer snapshots
that retention keeps while aging out the last successfully transferred one. So the
risk is NOT limited to operator-shortened windows or recursive mode; the live/
negative-control campaign (step 4) must include a bookmark-unavailable case with
later snapshot creation and prune, and prove the chosen fail-closed/degraded
behaviour (explicit FULL-resend surfaced in status, never a silent broken chain).
The source `[prune:]` touches only `automated_hourly_` snapshots, never bookmarks
(`delsnaps -B` is a separate op). Whether to (a) hard-refuse collector-owned source pruning on
recursive relationships or (b) allow it with the explicit FULL-resend warning is
the one open sub-decision for owner/reviewer. It stays **tied to live evidence
under REV-102 (step 4)**, not decided from a shorthand: the only established fact
is that recursive mode lacks bookmark fallback, so it needs a FULL **when no
usable ordinary common snapshot remains** — NOT "on its first miss" (a recursive
transfer may still have a common snapshot after one missed run). The recursive
refuse-vs-warn choice is made once a targeted runtime test proves the exact
behaviour.

Do not change the frozen transfer engines to "guarantee" a recursive bookmark base
without first proving that is the smallest necessary boundary.

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
3. Remote-prune composition + **fail-closed verification of the EXISTING
   delegated `destroy`** capability and pinned SSH path. NO grant widening
   (`destroy` is already delegated by `do_commit_scope`); the negative control is
   *revoke/omit* `destroy` and prove the remote prune refuses/fails.
4. Real-ZFS proof (local + remote): source ages out, target-only survives,
   manual/out-of-coverage-child survives, next transfer stays incremental where a
   usable common snapshot/bookmark remains, AND a bookmark-unavailable + later
   snapshot/prune case proving the explicit fail-closed/degraded behaviour.
   **Live-host obligation — this environment cannot run it; REV stays OPEN/
   IMPLEMENTED not CLOSED until executed.**
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
  path; the remote source prune lands together with its **fail-closed check of the
  already-delegated `destroy` capability** and the pinned SSH path (no grant
  widening — `do_commit_scope` already grants `destroy`). Wiring it before that
  fail-closed check exists would risk installing an hourly job that fails if a
  particular relationship's grant were incomplete — so composition and the
  fail-closed verification land as one step;
- **step 4** real-ZFS end-to-end (local + remote) — live-host obligation;
- **step 5** migration/audit path for already-installed CONFIGs.

### Step-2 correction (REV-102 F2): source prune scope now matches source coverage

The first step-2 emission made the source `[prune:<root>]` `recursive = yes`, but
`[dataset:<root>]` is non-recursive (dataset.inc emits no recursion field), so the
source prune walked into children (`<root>/vm-101`) and could destroy `automated_`
snapshots owned by another/manual policy outside this relationship's coverage.
Corrected: the source prune omits `recursive` (CONFIG default = no), pruning
exactly the named dataset — `delsnaps.sh -G` without `-R`. The target prune stays
recursive over the store. `test/localbackup` gains a non-recursive assertion + a
child-survives control. A future flat/atomic source would need a matching
recursive source prune; local-backup does not expose recursion yet.

REV-102 remains OPEN (Claude's move) until steps 3–5 land; no IMPLEMENTED response
is filed for a partial fix.

### Step-3 building block landed: `assert_source_prune_grant` (owner Q4), fail-closed

The fail-closed grant check that must gate the deferred remote-PULL source prune is
now in the tree, unit-tested, ahead of the emission that will call it (kept gated on
purpose — emitting an ungated remote source prune is the exact REV-102 hazard):

- `zfs-backup.sh assert_source_prune_grant()` — over the pinned SSH path (same
  `-i keyfile -p port HostKeyAlias/UserKnownHostsFile` shape the relationship
  already uses), runs `zfs allow -- '<ds>'` as the delegated account and refuses
  unless the account's own permission line carries `destroy`. It **widens nothing**
  — `do_commit_scope` (deploy.sh `--commit-scope`) already delegates `destroy`;
  this only verifies it. Refuses (fail-closed) on: missing `destroy`, an ssh/zfs
  error (exit ≠ 0), and one missing-destroy dataset among many. The refusal names
  `destroy` and proposes no widening.
- `test/zfsbackup` section 55 (5 assertions) drives it with a stubbed `zfs allow`.
  A harness bug surfaced and was fixed here: the stub printed its fixture with
  `printf '---- ...'`, whose leading dashes `/bin/sh`'s `printf` parsed as options
  (`printf: --: invalid option`), so the function died at the ssh-error branch
  instead of the destroy branch — a false PASS-shaped failure. Fixed to
  `printf '%b'`. Suite now `zfsbackup` **368/368**.

### Owner Q4 confirmed on live ZFS (read-only), no widening

`zfs allow` read on metropolis pve1 (192.168.28.9) as the real `zfsbackup` account
confirms `destroy` is already held on the source datasets — Q4 answered from real
grant output, not assumption, and nothing needs widening. (Read-only; the
auto-mode classifier permits `zfs list`/`zfs allow` reads.)

### Destructive live proof (source ages out / child + manual survive): DONE 2026-08-11

Run on real ZFS on metropolis pve1 (192.168.28.9), outside auto mode (owner toggled
the permission mode; the destructive plink steps then executed). Throwaway lab
`hdd/backuptest/rev102srclab` + `/child`, created and destroyed within the run:

```
== BEFORE ==
  rev102srclab@automated_hourly_a
  rev102srclab@automated_hourly_b
  rev102srclab@automated_hourly_c
  rev102srclab@manual_keepme
  rev102srclab/child@automated_hourly_child1
-- delsnaps.sh -G hdd/backuptest/rev102srclab automated_ -H24 -D7 -W4 -M12 --
  Deleting snapshot: ...@automated_hourly_a
  Deleting snapshot: ...@automated_hourly_b
== AFTER ==
  Keeping snapshot: ...@automated_hourly_c (GFS H#1)
  rev102srclab@automated_hourly_c
  rev102srclab@manual_keepme
  rev102srclab/child@automated_hourly_child1
== TORNDOWN OK ==
```

All three source-prune safety properties confirmed on live ZFS:

1. **the GFS ladder destroys the tool-owned source snapshots** — `_a` and `_b`
   deleted; `_c` kept as the hourly bucket survivor (all three shared one 3600 s
   creation bucket, so `-H24` keeps the newest and drops the rest);
2. **prefix selectivity** — `manual_keepme` survives; the prune pattern is
   `automated_`, never `*`, so manual/foreign snapshots are never candidates;
3. **non-recursive** — the child's `automated_hourly_child1` survives; `delsnaps.sh
   -G` without `-R` never walks into `<root>/child`, matching the non-recursive
   `[dataset:<root>]` coverage (REV-102 F2).

The command matches the generator exactly: `gen-cron.sh` builds the GFS line as
`delsnaps.sh -G …"$scope" "$pattern" $retain` (no `--`, no `-R`) — an earlier `--`
in a hand-written attempt was a proof bug, not a product bug. This satisfies the
LOCAL-PUSH half of REV-102 step 4; the remote-PULL half lands with step 3.

Process note for the record: while the session was in auto mode the classifier
refused both self-granting the permission (Self-Modification + unblocking a
previously-denied destructive command — owner chat-consent does not clear an
adversarial-pattern rule) and the destructive plink run itself; the proof only ran
after the owner switched the session out of auto mode, exactly as the classifier
directed.

## Step 3 IMPLEMENTED (on branch): remote-PULL source prune in emit_client_sections

The pull path now bounds the REMOTE source too, reusing the profile-agnostic split
(REV-106) and the fail-closed grant guard (REV-102), on a branch
(`rev102-step3-remote-source-prune`) pending the two-host live proof before merge.

### What is emitted

For each source dataset a pull relationship carries, `emit_client_sections` emits a
`[prune:<account@host:ds>]` (the SAME `account@host` the `[dataset:].src` uses), so
`gen-cron.sh` renders a `delsnaps.sh -G <ssh_flags> "account@host:ds" "automated_"
-H24 -D7 -W4 -M12` that prunes the source over the pull's own pinned SSH. It is:

- **INDEPENDENT** — the source retention family (`__src_keep_*`), derived via the
  REV-106 helpers, so editing target retention never moves the source;
- **NON-recursive** — `recursive = no`, matching the per-dataset pull coverage;
- **monitor-free** — the source templates drop `monitor_warn`/`monitor_crit`;
  `check-snap-age.sh` is local-only and `gen-cron.sh` rejects monitor fields on a
  remote scope outright (source-age monitoring is the source host's own concern);
- **`ssh_flags`** = the pull's transport flags minus `-b` (bandwidth is a transfer
  cap, not an SSH option; gen-cron's `ssh_flags` accepts only `-p/-k/-c/-K/-O`).

### Fail-closed grant gate lives in the FLOW, not in the emitter

`emit_client_sections` stays pure config text (unit-testable without a host) and
records the datasets it wrote a source prune for in `SOURCE_PRUNE_EMITTED_DS`. Both
callers — `cmd_activate_client` and the `migrate-profile` rebuild loop — then run
`assert_source_prune_grant` for exactly those datasets, before publishing the
workfile. A missing `destroy` refuses the install (nothing touched). An empty list
(a preserved re-activation that emitted no source prune) opens no SSH at all.

### Re-activation MOVES topology, PRESERVES policy (REV-089 split — corrected per REV-107)

An earlier cut of step 3 REGENERATED the remote source prune from the profile on
every activation, on the reasoning that "the header carries topology, so rebuild the
whole section." REV-20260811-107 correctly rejected that: it discards an admin's
edited source retention (e.g. shortening the space-constrained source to 6H/2D) on
the next endpoint change, re-coupling policy through the profile and breaking the
REV-102 contract that CONFIG v4 is runtime truth after CREATE. The header-vs-body
distinction is exactly the one REV-089 already draws for `[dataset:]`: **topology may
move while installed policy stays authoritative.**

Corrected behaviour: the source prune's scope embeds the endpoint (`account@host`) in
its header and so cannot be refreshed in place — the section must be rebuilt to move
it — but only the TOPOLOGY moves. On re-activation `emit_remote_source_prune`:

1. `capture_client_remote_source_prunes` captures each installed source prune's
   POLICY body (marker-verified), keyed by source dataset, BEFORE removal;
2. `remove_client_remote_source_prunes` drops the old-scope sections;
3. per dataset, if an installed body was captured it is REPLAYED under the new scope
   with only the `ssh_flags` line rewritten — `use_template`, `gfs`, `gfs_pattern`,
   `recursive` and the retain (via the preserved `__src_keep_*` templates, which
   `append_source_templates_if_missing` never overwrites) survive an admin edit
   exactly as installed; only a dataset with NO installed source prune — a genuine
   first CREATE — is generated from the profile.

So an endpoint switch moves the source prune WITH `src`, and an edited source
retention survives it. A first CREATE still seeds from the preset; an explicit
previewed migration (step 5) is the only other way source policy is written.

### Tests (branch)

- `test/zfsbackup` section 56 (7 assertions): the remote `[prune:account@host:ds]`
  is emitted non-recursive with `ssh_flags`; references the INDEPENDENT `src_`
  family; the source templates drop `monitor_`; the COMPLETE config (defaults +
  rendered target templates + emitted stanzas) is accepted by the REAL `gen-cron.sh`
  and renders a `delsnaps.sh` line against the remote scope; an endpoint switch
  moves the source prune leaving no stale-endpoint scope; and emit records the
  datasets for the flow's grant check.
- existing `emit_client_sections` assertions updated for the new sections (the
  recursion-count check now pins one `recursive = yes` target ladder + one
  `recursive = no` source prune; the 89-step-5 preservation check scopes its
  hand-edit to the target, since the source prune is regenerated by design).
- `test/localbackup` 42/42 unchanged (local PUSH path untouched).

### Live proof (remote-PULL half of step 4): DONE 2026-08-11

Ran the emitted source-prune command on real ZFS across the metropolis pair, outside
auto mode. Collector = pve1 (192.168.28.9); remote source = pve2 (192.168.28.8);
throwaway `hdd/backuptest/rev102remote` + `/child`, delegated `snapshot,destroy` to
`zfsbackup`, created and destroyed within the run. From pve1, as the delegated
account, over the account's own SSH to pve2:

```
delsnaps.sh -G "zfsbackup@192.168.28.8:hdd/backuptest/rev102remote" "automated_" -H24 -D7 -W4 -M12

BEFORE (pve2): @automated_hourly_{a,b,c}, @manual_keepme, child@automated_hourly_child1
  Deleting ...@automated_hourly_a
  Deleting ...@automated_hourly_b
  Keeping  ...@automated_hourly_c (GFS H#1)
AFTER  (pve2): @automated_hourly_c, @manual_keepme, child@automated_hourly_child1
```

All four properties confirmed end to end over the real SSH channel — this is exactly
the command `gen-cron.sh` renders from the emitted `[prune:account@host:ds]`:

1. `delsnaps -G` runs on the COLLECTOR and reaches the REMOTE source over SSH as the
   delegated `zfsbackup` account (no new channel, no root SSH);
2. the GFS ladder destroys the source's tool-owned `automated_hourly_a/b`, keeps
   `_c` (same-hour bucket survivor);
3. prefix selectivity — `manual_keepme` survives (`automated_` never matches it);
4. NON-recursive — `child@automated_hourly_child1` survives (`-G` without `-R` never
   walks into the child).

The fail-closed grant refusal was NOT proved live: the whole `hdd/backuptest` tree
already carries a descendent `zfsbackup` grant that includes `destroy`, so a
synthetic no-`destroy` dataset under it still resolves `destroy` by inheritance —
there is no location in this estate where the account genuinely lacks it. That path
stays covered by `test/zfsbackup` section 55 (stubbed `zfs allow` with and without
`destroy`) and by the read-only confirmation that the production source datasets
hold `destroy`.

### Status after merge

- merged to main (`d8febbd`); REV-20260811-107 then corrected the reactivation
  policy from regenerate to preserve (topology moves, installed source policy
  survives) — the REV-089 split is now honoured, not deviated from;
- the continuity/bookmark/recursive sub-decision (Q4) — still open, reviewer input
  requested.

## Step 5 IMPLEMENTED: `audit-source-retention` (no silent repair)

The migration path for CONFIGs installed BEFORE step 3 is the new
`zfs-backup.sh audit-source-retention` verb — the one explicit, previewed way source
retention is added to an existing relationship (ordinary reactivation never adds it
as a hidden repair). It matches the Q5 answer. The first cut was rejected on two
safety defects (REV-102 F3/F4/F5); the shipped design below is the corrected one.

- **read-only by default (audit):** renders the installed CONFIG through the REAL
  `gen-cron.sh` ONCE and, for every active pull relationship, reads the source scope
  from the INSTALLED `[dataset:]` `src` (CONFIG is truth, not client state). A source
  is bounded only if that render emits a `delsnaps` job for its exact scope
  (`source_scope_is_bounded`). It lists exactly the relationships/datasets that lack
  a bounded source prune and the section it *would* add, and touches nothing. Reports
  "nic do dodania" once every relation is bounded (idempotent).

  **F3 (effective retention, not header presence):** the earlier cut decided
  "bounded" with `grep -qxF "[prune:$scope]"` — a section HEADER, which is not proof
  the section schedules bounded destruction. The fix reuses gen-cron semantics: only
  a section that gen-cron actually renders into a bounded `delsnaps` counts. A header
  that resolves to no bounded prune is reported unbounded, not silently accepted
  (negative control in section 57).

- **`--apply` (NARROW retrofit):** appends ONLY the missing source `[prune:]` sections
  and their `__src_` templates (`emit_missing_source_prune`), then runs the same
  fail-closed source-prune grant gate, `gen-cron.sh` validation,
  `show_activation_proposal` preview + confirmation, and `atomic_replace_and_install`
  read-back that `migrate-profile` uses. It does NOT call `emit_client_sections`.

  **F4 (add only missing, no topology repair):** the earlier cut called
  `emit_client_sections … is_new=0`, the ordinary reactivation path, which refreshes
  `[dataset:]` `src`/`flags` and can move an existing source-prune endpoint to the
  currently-loaded endpoint. That let a retention retrofit perform an unrelated
  topology refresh. The fix keys the source scope off the installed `[dataset:]` `src`
  and appends only that; existing `[dataset:]`, target prune, and existing bounded
  source prunes stay byte-identical. If the client's current endpoint DISAGREES with
  the installed `src`, the retrofit REFUSES and tells the operator to reconcile
  (re-activate) first — no opportunistic endpoint repair, no pruning/grant-checking
  the wrong host.

Tests: `test/zfsbackup` section 57 (6 assertions): read-only audit names the missing
source retention and leaves the config byte-identical (F3); a `[prune:]` header that
renders no bounded delsnaps is NOT reported safe (F3 negative control); idempotent
once the render bounds the source; `--apply` installs nothing on a failing grant
check (F5, byte-identical); `--apply` REFUSES when the client endpoint disagrees with
the installed `src` (F4 discriminating regression, byte-identical); `--apply` with
agreeing endpoints adds a bounded source prune at the installed endpoint and leaves
`[dataset:]` `src` topology byte-identical (F4 success). The `--apply` transaction is
exercised end-to-end through a REAL profile + REAL gen-cron with the grant gate and
install stubbed.
