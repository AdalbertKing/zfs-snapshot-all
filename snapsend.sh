#!/bin/bash
set -o pipefail
# snapsend.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Author: Wojciech Król <lurk@lurk.com.pl>
# Refactored: April 04, 2025
# Description: ZFS snapshot manager with force full send
#
# Usage: snapsend.sh [options] DATASETS [REMOTE]
# Options:
#   -m <MESSAGE>      Use MESSAGE as prefix for snapshot name (to label snapshots)
#   -e               Use existing latest snapshot instead of creating a new one
#   -z               Compress the data stream (default compressor: zstd). Redundant
#                    against a remote target -- see "COMPRESSION DEFAULT" below,
#                    this is now ON by default there. Ignored, with a log line,
#                    when the target is local: there is no link between the
#                    compressor and the decompressor, only a pipe on this same
#                    host, so it is pure CPU cost.
#   -Z               Compress with zstd explicitly (same as -z; kept for clarity)
#   -g               Compress with pigz instead -- the escape hatch for a host
#                    where zstd is missing or unwanted
#   -N               No compression. Opts out of the default-on behaviour against
#                    a remote target (see below). No-op against a local target,
#                    which never compresses regardless of any flag. Contradicts
#                    -z/-Z/-g (pick one).
#   -l <LEVEL>        Compression level (default: 3 for zstd, 6 for pigz -- each
#                    tool's own default; ranges differ, zstd 1-19 vs pigz 1-9)
#
# The compressor flags are last-one-wins, so appending one to an existing command
# is always well-defined.
#
# COMPRESSION DEFAULT: ON (zstd -3) whenever the target is remote and neither
# -z/-Z/-g nor -N was given. This is new since v2.64 -- earlier versions defaulted
# to off everywhere and required an explicit -z. A plain `-N` restores that old
# behaviour for one invocation. -A, if given, still gets the final per-dataset say
# over whatever this default picks.
#
# WHY zstd IS THE DEFAULT (measured 2026-07-22 on pve0, Xeon E5-1620 v2, 8 cores,
# against a real 1.5 GB `zfs send` stream of a production VM disk):
#
#     compressor      ratio    MB/s      effective MB/s over a 1Gbps link
#     zstd -3 -T0     2.34x     454      292   <- best overall
#     zstd -1 -T0     2.13x     739      266
#     zstd -9 -T0     2.48x      79       79
#     pigz -6         2.19x     143      143   <- the previous default
#     pigz -1         2.05x     265      256
#     lzop -1         1.67x     351      209
#
# zstd -3 beats the old pigz -6 default on BOTH axes at once: a better ratio AND
# ~3.2x the throughput, so this is not a speed-vs-size trade. Note the effective
# column: on a fast link the LINK is the bottleneck, so the higher ratio wins and
# zstd -3 beats even the faster zstd -1. Higher zstd levels only pay off below
# ~5 Mbps, and then by ~6% for 5.7x the CPU -- not worth a default.
# Requires the chosen compressor on BOTH ends (checked before transfer).
#   -v <LEVEL>        Verbosity level for logging (0=errors only, up to 4=debug)
#   -r               Recursive mode (include child datasets in send/recv)
#   -R               Flat-recursive mode, syncoid/sanoid-compatible: expands
#                    each DATASET into itself plus every descendant (`zfs list
#                    -r`, same call syncoid's getchilddatasets makes) BEFORE
#                    the main loop runs, then sends each one as its own
#                    independent, non-recursive job -- same walk depth as -r
#                    (unlimited, ZFS itself has no -d cap), but the unit of
#                    work is one dataset instead of the whole subtree in one
#                    stream. A failing child does not abort its siblings (it
#                    lands in the existing FAILED_DATASETS report, same as
#                    today's comma-separated DATASETS already behave) and,
#                    unlike -r, a GUID collision on one child only forces a
#                    full resend of THAT child -- -F is a no-op under -R
#                    because the collision -F exists for cannot arise (see -F
#                    below). Mutually exclusive with -r. Quiescing still takes
#                    one atomic snapshot across the whole expanded set before
#                    the per-child sends start.
#
#   Long spellings (Stage 2.3), exactly equivalent to the short flags:
#     --recursive=atomic   = -r
#     --recursive=flat     = -R
#     --recursive=no       = neither, stated explicitly
#   Exactly ONE recursion declaration per invocation. A second is refused even
#   when it agrees, and even when the two use different spellings -- so
#   `--recursive=no -r` is an error, not a silent -r.
#   -X <REGEX>        Under -R only: drop every expanded dataset whose full name
#                    matches REGEX -- an extended regex as `grep -E` reads it,
#                    unanchored, so anchor it yourself with ^ / $ when you mean
#                    the whole name. Repeatable; a dataset goes if ANY -X hits.
#                    This is syncoid's --exclude with the same semantics.
#                    Excluding a dataset does NOT exclude its descendants: every
#                    expanded name is tested on its own, and `zfs create -p`
#                    still makes the skipped level on the target as an empty
#                    dataset, so a surviving child has somewhere to land.
#                    BUT MIND THE ANCHOR: unanchored, a pattern that matches a
#                    parent matches its children as well, since a child's full
#                    name contains the parent's. `-X swap` drops rpool/swap AND
#                    rpool/swap/inner; `-X 'swap$'` drops only rpool/swap.
#                    Both behaviours are legitimate -- decide which you meant.
#   -S               Under -R only: skip-parent -- send the descendants of each
#                    DATASET but never the DATASET itself. syncoid's
#                    --skip-parent. This is the container case: rpool/data holds
#                    no data of its own and exists only to group vm-*-disk-*
#                    beneath it.
#
# Both are -R-only, and rejected otherwise rather than ignored. Under -r the
# subtree is one atomic `zfs send -R` stream with nowhere to filter, and without
# recursion at all there is nothing to exclude FROM -- you just do not list the
# dataset. If the filters leave nothing to send, that is an error, not a silent
# success: a typo in a -X regex must not look like a clean run in cron.
#   -n               Dry-run mode (show conflicting snapshots without sending)
#   -H               Full history send (send all snapshots if no common base).
#                    Was -I; renamed so -I doesn't collide with -i below and,
#                    unlike -i, never matched what real `zfs send -I` means
#                    anyway (this is about the NO-common-base case, not about
#                    intermediates) -- H for "full History" is honest about it.
#   -i               When a common snapshot IS found, send only the DIFF to
#                    the newest one (`zfs send -i`) instead of every
#                    intermediate snapshot in between (`zfs send -I`, the
#                    default -- no flag needed for that, it already happens).
#                    Chosen to match `zfs send -i` literally: an admin who
#                    knows the real flag gets the real letter. Intended for a
#                    target that has been offline a long time -- with the
#                    default every hourly/daily/etc snapshot taken while it
#                    was gone lands on the target and is streamed in full;
#                    -i carries only the final state, in one step. Trade-off:
#                    the target gains none of the intermediate snapshots' OWN
#                    history (nothing to prune later that was never there, and
#                    nothing to restore FROM at those points in time) -- only
#                    the base and the newest exist there afterward.
#                    Combines with -r: `zfs send -R -i` is valid and recursive
#                    (verified live: base+newest land on every dataset in the
#                    subtree, intermediates on none), so one -i decision covers
#                    the whole tree atomically, same as the -I default does.
#                    Also correct, with no special-casing needed, under -R:
#                    each expanded dataset already gets its own independent
#                    common-base lookup and send command, so -i just flips
#                    that same per-dataset choice for each of them in turn.
#                    A no-op (logged at level 2) when there is no common
#                    snapshot to begin with -- the bookmark-fallback path
#                    already sends a single diff, and neither full-send path
#                    (-H's own "no common base" meaning, or a plain full send)
#                    does an incremental at all, so there is nothing to skip
#                    in either case.
#   -T <N>            Catch-up threshold: auto-switch THIS dataset to -i when
#                    more than N of its OWN snapshot intervals have elapsed
#                    since the common base -- e.g. N=24 means "about a day"
#                    for an hourly job (own interval ~1h) but "about 24 days"
#                    for a daily job (own interval ~24h), so the SAME number
#                    lands in the right place for either cadence without
#                    per-tier configuration. Deliberately relative, not an
#                    absolute time or snapshot count: those create a cliff at
#                    an arbitrary line (23h offline keeps everything, 26h
#                    keeps nothing, for a 3-hour difference that means
#                    nothing on its own), whereas "how many of ITS OWN
#                    intervals" scales the cliff to match what each tier's
#                    snapshots are actually worth. Own interval is MEASURED
#                    (gap between the two newest snapshots on the source
#                    matching this run's -m prefix), never assumed -- same
#                    house style as -A. Unmeasurable (fewer than two matching
#                    snapshots, a degenerate interval, an unreadable common
#                    snapshot) always resolves to "no", i.e. today's default
#                    (-I) stays untouched. An explicit -i still wins outright
#                    and skips this check entirely -- -T only fills in a
#                    decision nobody made explicitly, per dataset, same as -A
#                    never overrules an explicit -z/-Z/-g/-N. Omitted (the
#                    default) disables the auto-check completely.
#   -u               Accepted and ignored. `zfs recv -u` (do not mount what was
#                    just received) is the DEFAULT since v2.54; this flag stays
#                    so the cron lines that already pass it keep parsing. Use -U
#                    to get mounting back.
#   -U               Mount the target after receive -- the opt-out from the
#                    default above. Wanted when the target is meant to be browsed
#                    (a restore staging area, an archive somebody reads from),
#                    not when it is pure replication storage.
#
# WHY NOT MOUNTING IS THE DEFAULT: a replication target is storage, not a
# filesystem anyone works in, and mounting it ranges from clutter to hazard.
#
#   * Properties do not normally travel: a plain `zfs send` carries no
#     properties, so a received dataset inherits `mountpoint` from its new
#     parent and lands somewhere harmless under the target. But `-r` and `-H`
#     both send a REPLICATION stream (`zfs send -R`), which DOES carry them --
#     and a source whose mountpoint is set locally then brings that path along.
#     `rpool/ROOT/pve-1` on a Proxmox host has `mountpoint=/` set locally, so a
#     recursive backup of it, received without -u, asks ZFS to mount a copy of
#     the root filesystem over the live root. Verified on the fleet 2026-07-25:
#     that dataset really is backed up daily, and really does have a local
#     mountpoint.
#   * Even where it lands harmlessly, a mounted copy of every container rootfs
#     is walked by anything that scans the filesystem (updatedb, AV, backup
#     agents) for no benefit.
#   * A non-root receiver cannot mount at all: on Linux mount(2) needs
#     CAP_SYS_ADMIN no matter what `zfs allow` grants, so without -u the receive
#     fails outright for the delegated zfsbackup deployments.
#
# Nothing already mounted is unmounted by this: `-u` only decides whether the
# dataset is mounted AFTER a receive, so existing targets simply stop coming
# back up as runs replace them.
#   -f               Force full send (destroy target data and send full snapshot)
#   -w               Raw send (zfs send -w): send records exactly as they sit on
#                    disk. For an ENCRYPTED source this ships ciphertext, so the
#                    target never needs the key -- and the source does not need it
#                    loaded either (a non-raw send of an encrypted dataset refuses
#                    with "dataset key must be loaded"). A raw-received target
#                    comes up keystatus=unavailable and mounted=no; no -u needed.
#                    For an UNENCRYPTED source -w is effectively a no-op: verified
#                    on zfs-2.1.9 that raw and non-raw streams interoperate freely
#                    in both directions there. Rawness must NOT change mid-stream
#                    on an encrypted target -- see the guardrail in process_dataset.
#   -p <PORT>         SSH port to use (default: 22)
#   -c <CIPHER_SPEC>   SSH cipher(s) to request (ssh -c), e.g. "aes128-gcm@openssh.com"
#                    for a faster/weaker cipher on a CPU-bound link. Default (omitted)
#                    is whatever ssh/sshd negotiate on their own. No-op on a local run
#                    -- ssh is never invoked there.
#   -L <LABEL>        The backup relationship (zfs-backup.sh client) this run
#                    belongs to. If that relationship is paused
#                    (zfs-backup.sh pause-client), the run exits 0 with
#                    "SKIPPED: relationship LABEL is paused" BEFORE any lock,
#                    snapshot, hold, ssh or stream work, and logs the distinct
#                    stats status skipped_paused (never a fake success).
#                    Written into generated cron lines by gen-cron.sh's
#                    pair_label field; a run that omits -L is NOT gated --
#                    logical pause is orchestration, not a security boundary.
#   -K <FILE>         SSH private key to authenticate with (ssh -i, plus -o
#                    IdentitiesOnly=yes so an ssh-agent holding OTHER keys can't
#                    make the server try them first and get this account locked
#                    out by a max-auth-tries limit). Not "-i" -- that means
#                    skip-intermediates here (see above). Default: whatever the
#                    invoking user's own ssh would pick (agent, ~/.ssh/config).
#   -O <SSH_OPTION>    Extra "ssh -o NAME=VALUE", verbatim, e.g.
#                    -O "ProxyJump=bastion". Repeatable; each becomes its own
#                    -o. Syncoid's --sshoption. Placed FIRST on the ssh command
#                    line -- OpenSSH keeps the FIRST value it sees for a given
#                    key and ignores later ones (verified: `-o Port=2222 -p 22`
#                    connects on 2222, not 22), so putting -K/-O ahead of -p/-k/
#                    -c/ControlMaster lets an explicit -O override any of them,
#                    including turning multiplexing off with
#                    -O ControlMaster=no. No validation -- same trust level as
#                    -o (raw send flags).
#   -b <RATE>         Cap the transfer rate. RATE is an mbuffer rate spec: a plain
#                    number of BYTES per second, or one with a b/k/M/G suffix
#                    (1024-based, mbuffer's own parser). BYTES, not bits -- a
#                    20 Mbps link is `-b 2M`. Default (omitted) is no limit.
#
#                    Applied as `mbuffer -r` to the mbuffer that is ALREADY in
#                    every pipeline, so this adds no process and no memory. That
#                    mbuffer sits on the receiving side, immediately after the
#                    wire and BEFORE any decompression -- which is exactly where
#                    the bytes being limited are the bytes actually crossing the
#                    link, in both the compressed and uncompressed cases. A
#                    source-side limiter would have had to sit after the
#                    compressor to mean the same thing.
#
#                    The mechanism is backpressure: mbuffer drains the stream at
#                    RATE, the socket stops being read, TCP closes its window and
#                    the sender blocks. Steady-state wire rate settles at RATE.
#                    Buffers ahead of it (mbuffer's own -m 16M, the TCP window,
#                    ssh's) mean the first moments of a transfer can outrun the
#                    limit before it settles -- tens of MB, irrelevant on any
#                    transfer worth throttling.
#
#                    On a LOCAL transfer there is no link, but the limit still
#                    applies and is still useful: it throttles pool-to-pool I/O
#                    so a big backup doesn't starve the guests.
#
#                    Interacts with -A on purpose: a limit makes the link slower
#                    than the probe measured, which makes compression MORE
#                    worthwhile, so -A decides against min(measured, -b) rather
#                    than against the raw probe.
#   -k <FILE>         Verify remote host keys against this known_hosts file instead
#                     of the default (StrictHostKeyChecking=accept-new when -k is
#                     omitted: trust-on-first-use, then refuse if the key ever
#                     changes -- only opt into -k if you've already populated
#                     FILE, e.g. via ssh-keyscan, and verified the fingerprint
#                     out of band)
#   -o "<FLAGS>"       Extra raw flags appended verbatim to `zfs send` (e.g.
#                    -o "-L -e" for large_block/embed_data). Passed through with
#                    no validation -- same trust level as every other flag here.
#                    Skipped on the resume path: `zfs send -t <token>` already
#                    fixes the stream's format, and stacking more flags on top of
#                    a token is what aborts -w (see above), so nothing is risked
#                    there for a value nobody asked to be resumed.
#   -x <PROPERTY>      Exclude PROPERTY from the receive side (`zfs recv -x`).
#                    Repeatable. Applied on BOTH the normal and the resumed
#                    receive -- unlike -o, this is receive-side state and a
#                    resume token carries no property excludes of its own.
#   -F               Reconcile before sending (recursively, under -r): if a
#                    CHILD dataset has a snapshot named like the incremental
#                    base but under a DIFFERENT GUID (independently created,
#                    not the same snapshot despite the name -- the one shape
#                    of divergence that actually breaks a recursive send),
#                    upgrade THIS run to a full resend of the whole subtree,
#                    same as -f. Deliberately narrower than what `-n`
#                    reports: a target-only snapshot that does NOT collide by
#                    name (e.g. older history a shorter-retention source has
#                    since pruned, common on an archive target) is normal and
#                    left alone -- flagging that too would force an expensive
#                    full resend on every single run against such a target.
#                    Full-tree resend on a real collision is not a shortcut,
#                    it's required: `zfs send -R -I` decides full-vs-
#                    incremental PER CHILD from the SOURCE's own snapshot
#                    history, not from what survives on the target, so
#                    merely destroying the colliding snapshot still leaves
#                    that child an incremental component with nothing valid
#                    to land on (probed live: recv tears the child dataset
#                    down instead of just erroring). Opt-in; combine with
#                    `-n` first, though note `-n`'s report is broader than
#                    what `-F` actually acts on.
#   -A               Auto-tune the link: measure it, then decide whether -z is
#                    worth it for THIS data. Opt-in, remote transfers only, and
#                    it can flip nothing but compression. Decided separately for
#                    EACH dataset, since the ratio is a property of the data.
#                    Measurements are cached 7 days -- link speed per host (one
#                    host = one link, probed once per run), ratio per dataset --
#                    so the ~10s probe runs at most weekly; set
#                    ZFS_SNAP_RETUNE=1 to force a re-probe, or just don't pass -A.
#
#                    It decides ONE thing on purpose. Measured 2026-07-22:
#                    compress-or-not is worth ~29%, choosing the zstd level
#                    ~2%, and mbuffer -m nothing at all (16M/128M/1G were
#                    indistinguishable against a real zfs recv, even to a slow
#                    HDD target). So the level stays fixed and the buffer is
#                    not tuned -- two sizing formulas were tried and both were
#                    refuted by measurement.
#
#                    Ratio is measured on a real `zfs send` sample from the
#                    dataset, never assumed: the same host measured 2.34x on
#                    one dataset and 1.29x on another. Needs an existing
#                    snapshot to sample -- on a dataset's very first run there
#                    is none yet, so tuning quietly stands down that once.
#                    Every failure path leaves your settings untouched.
#
#                    An explicit -z/-Z/-g or -N WINS either way: -A then logs
#                    that it stood down and honours your flag. -A fills in a
#                    decision you did not make; it never overrules one you did.
#   -q <MODE>         Quiesce the Proxmox guest owning each dataset before
#                    snapshotting it, so the snapshot is filesystem-consistent
#                    instead of crash-consistent. MODE is one of:
#                      no    (default) do nothing
#                      agent qemu-guest-agent fsfreeze -- VMs
#                      sync  `pct exec <id> -- sync` -- containers. A FLUSH, not a
#                            freeze: containers have no guest agent, and ZFS does
#                            not implement FIFREEZE, so no ZFS mountpoint can be
#                            frozen from the host either (measured on pve0, on a
#                            live subvol and on a fresh empty dataset alike).
#                            Writes are never blocked, so this is strictly weaker
#                            than the VM path -- it flushes what the container has
#                            buffered, and nothing more.
#                      auto  pick per guest from its type
#
#                    A FAILED FREEZE STILL TAKES THE SNAPSHOT (owner direction,
#                    2026-08-27). It is crash-consistent, carries `_crash_` in
#                    its name, and the run exits 8 so cron reports it rather
#                    than calling it a clean backup. Append `,strict` --
#                    `-q auto,strict` -- for the opposite: no snapshot at all,
#                    and the run fails, which is the right answer for data whose
#                    restore procedure begins by discarding a crash-consistent
#                    copy. `,degrade` is still accepted and now asks for what it
#                    would get anyway.
#
#                    The dataset-to-guest mapping is the Proxmox naming
#                    convention (vm-<id>-disk-N, subvol-<id>-disk-N); anything
#                    else owns no guest and is snapshotted normally. Under -r the
#                    named dataset is a PARENT whose name matches nothing, so the
#                    tree is expanded and the guests are taken from the children.
#                    Each guest is quiesced once per run however many disks it
#                    owns.
#
#                    THE FREEZE WINDOW CONTAINS ONLY `zfs snapshot`. Writes are
#                    blocked while frozen, so the window must not contain the
#                    transfer -- and because one guest can own several datasets
#                    (VM 107 has three disks), all of them are snapshotted in ONE
#                    atomic `zfs snapshot` call PER POOL inside a single window.
#                    Per-dataset freezing would give one machine several different
#                    points in time, which is the very thing being prevented.
#
#                    Why per pool and not one call for everything: `zfs snapshot`
#                    takes multiple names only within a single pool. Given a list
#                    spanning two (e.g. rpool/data/vm-106-disk-0 plus
#                    hdd/vm-disks/subvol-101-disk-0) it refuses the whole call with
#                    "cannot create snapshots : multiple snapshots of same fs not
#                    allowed" -- a misleading message for what is really a same-pool
#                    constraint, verified on zfs-2.1.9. Coherence does not depend on
#                    the single ioctl anyway: the guests stay frozen across all of
#                    the calls, so nothing can write between them and every disk
#                    still lands on the same point in time.
#
#                    Thaw is guaranteed by an EXIT trap and shouts at log level 0
#                    if it fails -- a guest left frozen is an outage.
#
#                    Filesystem-consistent is NOT application-consistent. A
#                    database still replays its log on start. For a real quiesce,
#                    put the engine's own (MySQL FLUSH TABLES WITH READ LOCK,
#                    Postgres backup mode) in the guest's /etc/qemu/fsfreeze-hook,
#                    which the agent runs inside the freeze.
#
#                    Ignored with -e (nothing is being created to quiesce) and
#                    with -n.
#   -j <TAG>          Identifier for this job. Folds TAG into both the lock
#                    key and the per-target bookmark name, so a second,
#                    genuinely independent job aimed at the SAME src/tgt pair
#                    (different retention, different snapshot pattern) gets
#                    its own lock and its own bookmark instead of serializing
#                    behind, or overwriting the incremental base of, the
#                    first job. Omit it (the default) to keep today's
#                    behaviour: all jobs to a given pair share one lock and
#                    one bookmark, so they always serialize. (Was -i; moved to
#                    free that letter for its literal zfs meaning -- see -i.)
#   -V               Print version and exit
#
# COMPRESSED SEND is automatic (`zfs send -c`) and needs no flag: records are
# sent as they already sit on disk, instead of being decompressed to build the
# stream and recompressed on receive. Measured on real production snapshots
# 2026-07-22: streams 18-56% smaller (342 GB -> 249 GB on one VM disk). Unlike
# -z it costs no CPU -- it removes work rather than adding it -- so it applies to
# LOCAL transfers too. Skipped automatically when the target pool cannot take the
# stream (needs feature@lz4_compress at all, plus feature@zstd_compress for
# zstd-compressed records); set ZFS_SNAP_NO_COMPRESSED_SEND=1 to force plain.
#
# REMOTE format, three shapes:
#   [user@]host:dataset_path   BACKUP mode -- sends into dataset_path (a BASE:
#                              the actual target is dataset_path/<local dataset
#                              name>, so this nests under wherever dataset_path
#                              points).
#   [user@]host                SYNC mode -- no ':', but the '@' makes this
#                              unambiguously a remote address (a ZFS dataset
#                              name can never contain '@', so there is no
#                              parsing overlap with a local path). Mirrors to
#                              the IDENTICAL dataset path on that host instead
#                              of nesting under a base -- for keeping a second
#                              host a live mirror of this one. Refused if the
#                              resolved host turns out to be THIS host
#                              (validate_remote_host compares /etc/machine-id)
#                              -- a dataset cannot sync to itself.
#   dataset_path (no ':', no '@')  LOCAL mode -- local-to-local copy under a
#                              different name, nothing remote at all.
#
# Examples:
#   snapsend.sh -v1 pool/data backuppool/data_backup
#   snapsend.sh -r pool/data user@backuphost:tank/backups/data
#   snapsend.sh -r pool/data user@backuphost              # sync: mirrors as pool/data on backuphost
#
# THE TWIN: snapsend.sh (push) and snapget.sh (pull) share TWELVE function names.
#
# Merging the two engines was considered and REJECTED on 2026-08-04. What is
# left after the easy sharing is DIVERGENCE, not duplication: push reads locally
# and writes remotely, pull does the reverse, so the safety checks sit on
# opposite sides. Eight of the twelve carry that direction with IDENTICAL
# signatures and parameter names, so a merge needs a direction argument whose
# only failure mode is silent -- and it fails OPEN on common-base detection.
# test/snapsend/run.sh is LOCAL MODE ONLY by design, so with empty
# remote_user/remote_host both branches collapse to the same call: the suite
# that would catch a reversed direction structurally cannot.
#
# The decision was therefore DO NOT MERGE, ALARM ON DRIFT. The alarm is
# test/twins/run.sh plus the twin-functions contract in test/deps.conf, which
# pins each side's function bodies SEPARATELY -- so the two are free to differ,
# and neither is free to change unnoticed.
#
# Whatever is shared and carries no direction already lives in lib-zfs-snap.sh,
# which both scripts source. Before moving anything else there, read the
# 2026-08-04 entry in docs/PROJECT_STATUS.md: this looks like obvious
# duplication and is not.
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v2.72'
MESSAGE=""
IDENTIFIER=""
VERBOSE=0
COMPRESSION=0
# Which compressor -z/-Z/-g selected, and whether -l was given explicitly. zstd
# is the default because it measured strictly better than pigz on this hardware
# -- see the benchmark table in the header. The level default differs per tool
# (zstd 3, pigz 6 -- each tool's own), so it can only be resolved after argument
# parsing.
COMPRESSOR="zstd"
COMPRESSION_LEVEL=6
COMPRESSION_LEVEL_SET=0
BUFFER_SIZE="128k"
# 16M, not the 1G this used to be. Measured 2026-07-22 against a real `zfs recv`
# -- 14 runs of 2 GB, both transfer paths, including the slow-consumer case that
# most favours a big buffer:
#
#   remote, SSD target:  16M 109.9 | 128M 109.3 | 1G 109.8 MB/s
#   remote, HDD target:  16M 89.3/86.6          | 1G 78.3/88.8
#   local,  HDD target:  16M 119.7/108.1/107.9/87.4 | 1G 100.3/117.0/117.6/88.5
#
# A 64x change moves nothing outside run-to-run noise -- and that noise (88 to
# 120 MB/s for one unchanged setting) is far larger than any gap between
# settings. So the old 1G bought no throughput; it just reserved memory that on
# these hosts belongs to the VMs.
#
# mbuffer's job is absorbing consumer stalls (a `zfs recv` txg commit), not
# holding the TCP window -- that is the kernel's, and bandwidth-delay product
# for these links is tens of KB. Two sizing formulas built on those ideas were
# tried and both were refuted by the table above, hence a flat constant.
MEMORY="16M"
# -b: cap the transfer rate. Applied as `mbuffer -r` to the mbuffer that is
# already in every pipeline, so this adds no process. BWLIMIT holds the raw
# spec as given (also read by tune_apply in lib-zfs-snap.sh, which caps the
# probed link speed with it); BWLIMIT_FLAG is the ready-made " -r <rate>"
# fragment, empty when no limit was asked for.
BWLIMIT=""
BWLIMIT_FLAG=""
# ---------------------------------------------------------------------------
# WATCHING A LONG TRANSFER (owner-authorized 2026-08-22)
#
# Steady state has nothing to watch: measured on production the same day, a
# 4.39 TB dataset's hourly incremental was 624 bytes and 532 runs averaged 0.3s.
# The case that needs an eye is the SEED -- the owner's words, "wyobraz sobie
# task inicjalny 4TB, puszczamy i nic nie widzimy" -- and it is exactly the case
# no history can help with, because a first run has nothing to compare against.
#
# mbuffer has counted bytes and rate all along; every pipeline in this file ran
# it with -q. So this is not new machinery, it is a mute being lifted -- and
# lifted ONLY where somebody is looking. From cron nobody is, and mbuffer's
# status would land in the stderr that cron appends to cron.log, turning the
# one file an operator greps into a rate meter. So: stderr on a tty means show,
# anything else means keep the mute exactly as before.
#
# There is no percentage here on purpose. mbuffer cannot be told a total (pv
# can, and syncoid uses it, but pv is installed on none of these hosts while
# mbuffer is everywhere). So the total is ANNOUNCED once, up front, from a
# `zfs send -nP` dry run, and the live counter is mbuffer's own. Two numbers,
# one line apart, no new dependency.
MBUFFER_QUIET="-q"
[ -t 2 ] && MBUFFER_QUIET=""

# What this transfer is about to move, said once before it starts. Fail-SOFT by
# construction: a size we could not measure is a line we do not print, never a
# transfer we do not run. The dry run reuses the REAL send command with -nP
# spliced in after `zfs send`, so it can never describe a different stream than
# the one that follows.
announce_transfer_size() {   # <send_cmd> <remote_host> <remote_user>
    [ -t 2 ] || return 0
    local send_cmd="$1" rhost="$2" ruser="$3" dry out size
    case "$send_cmd" in
        "zfs send "*) dry="zfs send -nP ${send_cmd#zfs send }" ;;
        *) return 0 ;;
    esac
    if [ -n "$rhost" ]; then
        out=$(ssh -n "${SSH_OPTS[@]}" "$ruser@$rhost" "$dry" 2>/dev/null) || return 0
    else
        out=$(eval "$dry" 2>/dev/null) || return 0
    fi
    size=$(printf '%s\n' "$out" | awk '$1=="size"{print $2; exit}')
    [ -n "$size" ] || return 0
    log 0 "about to move $(human_bytes "$size") -- mbuffer reports progress below"
}

# Bytes as a human reads them. Local to this file's reporting; nothing decides
# anything on it.
human_bytes() {   # <bytes>
    local b="$1"
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB PiB", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

PORT=22
USE_EXISTING_SNAPSHOT=0
declare -a EXCLUDE_SNAPS=()
# -q: quiesce the Proxmox guest that owns each dataset before snapshotting it.
# "no" (default), "agent" (qemu-guest-agent, VMs), "fs" (host fsfreeze, containers)
# or "auto" (pick per guest). See the QUIESCE section in lib-zfs-snap.sh.
QUIESCE=no
# Set once the quiesce window has actually created the snapshots, so no later
# code path creates a second, unquiesced copy.
QUIESCE_SNAPPED=0
RECURSIVE=0
FLAT_RECURSE=0
# Exactly ONE recursion declaration per invocation (Stage 2.2, REV-054 A4).
# Counted rather than inferred from the resulting flags: -r -r leaves RECURSIVE
# at 1 and is indistinguishable afterwards from a single -r, so the count has
# to be kept while parsing. RECURSION_SPELLINGS records what was actually
# written so the refusal can quote it back.
RECURSION_DECLS=0
RECURSION_SPELLINGS=""
declare_recursion() {   # <spelling>
    RECURSION_DECLS=$((RECURSION_DECLS+1))
    RECURSION_SPELLINGS="${RECURSION_SPELLINGS:+$RECURSION_SPELLINGS }$1"
}
# -X: extended regexes; an expanded dataset is dropped if ANY of them matches.
# -S: drop the listed dataset itself, keep its descendants.
declare -a EXCLUDE_PATTERNS=()
SKIP_PARENT=0
DRY_RUN=0
# -H: full history send when no common base exists at all (was -I -- renamed,
# see the header, to stop colliding with -i's real zfs meaning below).
FULL_HISTORY_SEND=0
# -i: when a common snapshot is found, send only the diff to newest (real
# `zfs send -i`) instead of every intermediate (`-I`, the default). See the
# header for why -- this is the letter's literal zfs meaning on purpose.
SKIP_INTERMEDIATES=0
# -T: auto-switch a dataset to skip-intermediates when more than this many of
# ITS OWN snapshot intervals have elapsed since the common base. Empty (the
# default) disables the check. See the header for the full reasoning.
THRESHOLD_INTERVALS=""
# `zfs recv -u`: do not mount what was just received. ON BY DEFAULT since v2.54
# -- a replication target is storage, not a filesystem anybody browses, and
# mounting it is at best clutter and at worst dangerous (see the header). -U
# turns mounting back on; -u is still accepted and is now a no-op, so every
# existing cron line that passes it keeps working untouched.
UNMOUNT=1
# The canmount value given to targets THIS script creates. `noauto` is what
# actually keeps a target unmounted -- more so than `zfs recv -u`, which only
# governs the moment of receipt -- and it is what makes non-root receive
# possible at all (see the long comment at the create call). Resolved from
# UNMOUNT after argument parsing, so -U reaches the dataset itself and not just
# the recv flag; without that, -U would be silently powerless on any target this
# script created.
TARGET_CANMOUNT="noauto"
FORCE_FULL_SEND=0
RAW_SEND=0
# -A: measure the link and the data, then decide whether compressing is worth
# it. Opt-in, and it can only ever flip COMPRESSION -- never the target, the
# snapshot, or anything else that could change what gets written.
AUTOTUNE=0
# Set by -z/-Z/-g. Lets -A tell "user said nothing about compression" apart from
# "user explicitly asked for it" -- auto-tuning may fill the first case in, but
# must never silently overrule the second.
COMPRESSION_SET=0
# -N: opt out of the on-by-default compression for a remote target (see the
# REMOTE_HOST block in section 5B). Meaningless for a local target, which never
# compresses regardless.
NO_COMPRESS=0
# -o: raw flags appended verbatim to `zfs send` (e.g. "-L -e"). -x: recv-side
# property excludes, one -x per occurrence, accumulated as repeated "-x PROP".
EXTRA_SEND_OPTS=""
RECV_EXCLUDE_FLAGS=""
# -c: ssh cipher spec (ssh -c), appended to SSH_OPTS once built. Empty = let
# ssh/sshd negotiate their own default.
SSH_CIPHER=""
SSH_KEY=""
declare -a EXTRA_SSH_OPTS=()
# -F: reconcile (destroy target-only snapshots) before the real send.
RECONCILE=0
declare -a CONFLICT_SNAPSHOTS=()
# Used only by -F -- see find_recursive_name_collisions.
declare -a NAME_COLLISIONS=()
# Default paths follow the ACCOUNT, not root. A delegated non-root run cannot
# read anything under /root (0700), so defaulting there gave it a stats log it
# could not write ("Permission denied" once per dataset), a notify script it
# could not execute, and a lock dir it could not create -- while deploy.sh had
# already provisioned $HOME/run, $HOME/zfs-snapshot-stats.log (its logrotate
# stanza rotates exactly that path) and $HOME/notify-fail.sh for it. The two
# sides now agree. An explicit environment variable still wins over both.
if [ "$(id -u)" -eq 0 ]; then
    ZFS_SNAP_DEFAULT_STATS="/root/scripts/zfs-snapshot-stats.log"
    ZFS_SNAP_DEFAULT_NOTIFY="/root/scripts/notify-fail.sh"
    ZFS_SNAP_DEFAULT_LOCKDIR="/var/run"
else
    # HOME is set by cron and by `su`, but not by `env -i` or a bare systemd
    # unit -- fall back to the passwd entry rather than resolving "$HOME/run"
    # to "/run" and failing with a message that points at the wrong thing.
    _zfs_snap_home="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
    ZFS_SNAP_DEFAULT_STATS="$_zfs_snap_home/zfs-snapshot-stats.log"
    ZFS_SNAP_DEFAULT_NOTIFY="$_zfs_snap_home/notify-fail.sh"
    ZFS_SNAP_DEFAULT_LOCKDIR="$_zfs_snap_home/run"
fi
STATS_LOG="${STATS_LOG:-$ZFS_SNAP_DEFAULT_STATS}"
# Same script notify-fail.sh already is for cron-line failures (see gen-cron.sh)
# -- reused directly by check_pool_health in lib-zfs-snap.sh so a DEGRADED pool
# alerts through the existing rate-limited path instead of a new one.
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$ZFS_SNAP_DEFAULT_NOTIFY}"
KNOWN_HOSTS_FILE=""

# Shared helpers (logging, stats, resumable-transfer bookkeeping) live in a
# sibling library so snapsend.sh and snapget.sh can't drift apart on them.
# Sourced here, right after config, so the functions exist before any call --
# they read globals (VERBOSE/STATS_LOG/LOCKDIR/SSH_OPTS) only when called, all
# of which are set by then.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -r "$LIB_DIR/lib-zfs-snap.sh" ]; then
    echo "Error: required library $LIB_DIR/lib-zfs-snap.sh not found (is the repo checkout complete?)" >&2
    exit 1
fi
# shellcheck source=lib-zfs-snap.sh
. "$LIB_DIR/lib-zfs-snap.sh"
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [HELPER FUNCTIONS]
###############################################################################

###############################################################################
#BEGIN 2B [SNAPSHOT METADATA OPERATIONS]
###############################################################################
# get_snapshot_guid / get_snapshot_guids live in lib-zfs-snap.sh -- shared
# with snapget.sh and with the bookmark-fallback code that already needed
# per-snapshot GUID lookups.
###############################################################################
#END 2B

###############################################################################
#BEGIN 2C [SNAPSHOT LIST OPERATIONS]
###############################################################################
get_sorted_snapshots() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    
    local depth_option="-d 1"
    [ $RECURSIVE -eq 1 ] && depth_option=""
    
    local snaps
    if [ -n "$remote_host" ]; then
        # Same reasoning as snapget.sh's copy of this function: the remote
        # command ends in a pipe, so ssh returns awk's status and a nonzero rc
        # here means ssh itself failed, not that the dataset has no snapshots.
        # Callers array-collect the output and drop the status, so say it here.
        snaps=$(ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name -t snapshot -s creation $depth_option '$dataset' 2>/dev/null | awk -F '@' '{print \$2}'") || {
            local _rc=$?
            if [ $_rc -eq 255 ]; then
                log 0 "Cannot reach $remote_user@$remote_host over ssh (exit 255) while listing the snapshots of '$dataset' -- a CONNECTION-level failure (authentication, host key, network or DNS), NOT an empty dataset."
            else
                log 0 "Could not list the snapshots of '$dataset' on $remote_user@$remote_host (exit $_rc) -- treating this as a failure, not as an empty dataset."
            fi
            return 1
        }
    else
        snaps=$(zfs list -H -o name -t snapshot -s creation $depth_option "$dataset" 2>/dev/null | awk -F '@' '{print $2}') || return 1
    fi
    echo "$snaps"
}
###############################################################################
#END 2C

###############################################################################
#BEGIN 2D [CONFLICT DETECTION LOGIC]
###############################################################################
find_conflicting_snapshots() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    local parent_common="${5:-}"
    
    local src_snaps=($(get_sorted_snapshots "$src_dataset"))
    local tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host"))

    for tgt_snap in "${tgt_snaps[@]}"; do
        if [[ ! " ${src_snaps[*]} " == *" ${tgt_snap} "* ]] || ! validate_snapshot "$src_dataset" "$tgt_dataset" "$tgt_snap" "$remote_user" "$remote_host"; then
            CONFLICT_SNAPSHOTS+=("${tgt_dataset}@${tgt_snap}")
        fi
    done

    if [ $RECURSIVE -eq 1 ]; then
        local tgt_children
        if [ -n "$remote_host" ]; then
            # The ssh status was discarded here (the pipe into grep swallowed
            # it), so an unreachable target host produced an empty child list
            # and this scan reported "no conflicts" -- a clean bill of health
            # for a host it never reached. remote_list makes that case say so;
            # the caller is a -n report, so stopping the walk is right.
            tgt_children=$(remote_list "$remote_user" "$remote_host" \
                "listing the children of target '$tgt_dataset'" \
                "zfs list -H -o name -r '$tgt_dataset' 2>/dev/null") || return 1
            tgt_children=$(printf '%s' "$tgt_children" | grep -v "^${tgt_dataset}$")
        else
            tgt_children=$(zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | grep -v "^${tgt_dataset}$")
        fi

        for tgt_child in $tgt_children; do
            local child_name="${tgt_child##*/}"
            local src_child="${src_dataset}/${child_name}"
            
            if ! zfs list -H "$src_child" &>/dev/null; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child" "$remote_user" "$remote_host"))
                for snap in "${tgt_child_snaps[@]}"; do
                    CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                done
                continue
            fi

            local child_common=$(find_common_snapshot "$src_child" "$tgt_child" "$remote_user" "$remote_host")
            
            if [[ "$child_common" == "null" ]] || [[ -n "$parent_common" && "$child_common" != "$parent_common" ]]; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child" "$remote_user" "$remote_host"))
                for snap in "${tgt_child_snaps[@]}"; do
                    CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                done
            fi

            find_conflicting_snapshots "$src_child" "$tgt_child" "$remote_user" "$remote_host" "$child_common"
        done
    fi
}
###############################################################################
#END 2D
###############################################################################
###############################################################################
#BEGIN 2E [RECONCILE: NARROW CHILD COLLISION CHECK, -F ONLY]
###############################################################################
# Deliberately narrower than find_conflicting_snapshots (which also flags
# perfectly harmless target-only history from a longer local retention --
# see the pve0 archive job, where -n always "fails" for exactly that reason,
# by design: source has pruned snapshots the archive target still keeps).
# Reusing that broader scan to trigger an automatic full resend would fire
# on EVERY run against any target with different retention, defeating
# incremental sends entirely.
#
# This only flags BASE_NAME existing on a child under a DIFFERENT GUID than
# the same name on its source counterpart -- the one shape of divergence
# that actually blocks `zfs send -R -I @BASE_NAME ...`, because that
# incremental is keyed to BASE_NAME for every child that has it, regardless
# of what else the child does or doesn't have. A child simply missing
# BASE_NAME is not flagged -- zfs sends that branch in full within the same
# -R stream on its own, no help needed.
find_recursive_name_collisions() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    local base_name="$5"

    [ -z "$base_name" ] && return 0
    [ "$base_name" = "null" ] && return 0

    local tgt_children
    if [ -n "$remote_host" ]; then
        # -F decides whether to force a FULL resend from what this finds, so an
        # unreachable host must not come back as "no collisions". Returning 1
        # leaves NAME_COLLISIONS untouched, which keeps the incremental path --
        # the safe direction: the transfer that follows will fail on the same
        # dead connection rather than destroy and refill a target on the
        # strength of an answer nobody received.
        tgt_children=$(remote_list "$remote_user" "$remote_host" \
            "listing the children of target '$tgt_dataset' for the -F collision scan" \
            "zfs list -H -o name -r '$tgt_dataset' 2>/dev/null") || return 1
        tgt_children=$(printf '%s' "$tgt_children" | grep -v "^${tgt_dataset}$")
    else
        tgt_children=$(zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | grep -v "^${tgt_dataset}$")
    fi

    local tgt_child
    for tgt_child in $tgt_children; do
        local child_name="${tgt_child##*/}"
        local src_child="${src_dataset}/${child_name}"

        # Source is always local in snapsend.sh.
        local tgt_guid
        tgt_guid=$(get_snapshot_guid "$tgt_child" "$base_name" "$remote_user" "$remote_host")
        if [ -n "$tgt_guid" ]; then
            local src_guid
            src_guid=$(get_snapshot_guid "$src_child" "$base_name")
            if [ -z "$src_guid" ] || [ "$src_guid" != "$tgt_guid" ]; then
                NAME_COLLISIONS+=("${tgt_child}@${base_name}")
            fi
        fi

        find_recursive_name_collisions "$src_child" "$tgt_child" "$remote_user" "$remote_host" "$base_name"
    done
}
###############################################################################
#END 2E
###############################################################################
###############################################################################
#BEGIN 2F [HOST VALIDATION]
###############################################################################
# validate_remote_host() now lives in lib-zfs-snap.sh (shared with snapget.sh,
# byte-identical) with a per-remote cache: the remote side of a run is the same
# host for every dataset in DATASETS, so this used to pay a full ssh round trip
# per dataset for an answer that cannot change mid-run.
###############################################################################
#END 2F

#END 2

###############################################################################
#BEGIN 3 [CORE LOGIC]
###############################################################################

###############################################################################
#BEGIN 3A [SNAPSHOT VALIDATION]
###############################################################################
validate_snapshot() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local snapshot="$3"
    local remote_user="$4"
    local remote_host="$5"

    # GUID, not creation timestamp: it's ZFS's own identity for a snapshot
    # (1-second creation resolution can't tell two distinct snapshots apart),
    # and it's what survives a rename on either side -- see find_common_snapshot.
    local src_guid=$(get_snapshot_guid "$src_dataset" "$snapshot")
    local tgt_guid=$(get_snapshot_guid "$tgt_dataset" "$snapshot" "$remote_user" "$remote_host")

    if [ -z "$src_guid" ] || [ -z "$tgt_guid" ]; then
        return 1
    fi
    [ "$src_guid" = "$tgt_guid" ] && return 0 || return 1
}

# PROVE THE WHOLE SUBTREE LANDED, not just its root. Mirror of snapget.sh's
# function -- same question, opposite direction: here the SOURCE is local and
# the TARGET is remote.
#
# The verification below used to stop at the root under -r, on this stated
# assumption: "the descendants rode the same stream and cannot have arrived
# separately". MEASURED FALSE (2026-08-24, campaign pve1>pve9, on the pull
# engine): `zfs recv` of a -R stream SKIPS a descendant whose local state
# cannot accept the increment, lands everything else, and exits 0. The
# receive side behaves the same whoever pushed the stream, so the push engine
# carried the identical hole.
#
# Cost: two `zfs list` calls (one per side), not one per dataset. Only the
# datasets that REALLY carry the snapshot on the source are required on the
# target -- a dataset created after the snapshot legitimately does not have
# it, and -X exclusions never entered the stream in the first place.
validate_subtree() {   # <src> <tgt> <snapshot> [ruser] [rhost] -> 0 ok, 1 something lagged
    local src="$1" tgt="$2" snap="$3" ruser="${4:-}" rhost="${5:-}"
    local src_have tgt_have
    # FAIL CLOSED on an inventory error -- see the note in snapget.sh: a check
    # that vanishes when the link breaks is not a check. Review finding.
    src_have=$(zfs list -H -o name -t snapshot -r "$src" 2>/dev/null) || {
        log 0 "VERIFY FAILED (subtree): could not list the source's snapshots to prove every descendant landed. Refusing to report success on an unasked question."
        return 1; }
    if [ -n "$rhost" ]; then
        tgt_have=$(ssh -n "${SSH_OPTS[@]}" "$ruser@$rhost"             "zfs list -H -o name -t snapshot -r '$tgt' 2>/dev/null") || {
            log 0 "VERIFY FAILED (subtree): could not list the target's snapshots on $rhost to prove every descendant landed. Refusing to report success on an unasked question."
            return 1; }
    else
        tgt_have=$(zfs list -H -o name -t snapshot -r "$tgt" 2>/dev/null) || {
            log 0 "VERIFY FAILED (subtree): could not list the target's snapshots to prove every descendant landed. Refusing to report success on an unasked question."
            return 1; }
    fi

    local line ds rel missing=""
    while IFS= read -r line; do
        case "$line" in *"@$snap") ;; *) continue ;; esac
        ds="${line%@*}"
        [ "$ds" = "$src" ] && continue          # the root is proven by GUID above
        rel="${ds#$src/}"
        dataset_excluded "$ds" && continue      # -X: never travelled, cannot lag
        # EXACT LINE, not substring: `pool/t/a@s3-extra` contains
        # `pool/t/a@s3` and was being accepted as proof that @s3 exists.
        # Review finding, reproduced. -F literal, -x whole line.
        printf '%s
' "$tgt_have" | grep -Fxq "$tgt/$rel@$snap"             || missing="$missing $tgt/$rel"
    done <<< "$src_have"

    [ -z "$missing" ] && return 0
    log 0 "VERIFY FAILED (subtree): the stream reported success but these descendants did not receive @${snap}:$missing"
    log 0 "A recursive receive skips a descendant whose local state cannot accept the increment and still exits 0. Treating this run as FAILED rather than reporting a backup that is missing part of the tree. Reconcile the target (-F) or re-pull it (-f) once you know why it diverged."
    return 1
}
###############################################################################
#END 3A

###############################################################################
#BEGIN 3B [SNAPSHOT MANAGEMENT]
###############################################################################
find_common_snapshot() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    
    local src_snaps
    src_snaps=($(get_sorted_snapshots "$src_dataset")) || return 1

    # A target that does not exist has no snapshots and therefore no common
    # base -- "null", not an error. This is reachable under -w, where the leaf
    # is created by recv rather than pre-created, so the first send legitimately
    # runs against a target that is not there yet.
    #
    # target_exists is three-valued: 2 means the host could not be reached, and
    # collapsing that into "null" here would announce a first send (full stream,
    # no common base) purely because ssh was broken.
    local tgt_snaps
    target_exists "$tgt_dataset" "$remote_user" "$remote_host"
    case $? in
        1) echo -n "null"; return 0 ;;
        2) return 1 ;;
    esac
    tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host")) || return 1

    for ((i=${#src_snaps[@]}-1; i>=0; i--)); do
        for ((j=${#tgt_snaps[@]}-1; j>=0; j--)); do
            if [[ "${src_snaps[$i]}" == "${tgt_snaps[$j]}" ]]; then
                validate_snapshot "$src_dataset" "$tgt_dataset" "${src_snaps[$i]}" "$remote_user" "$remote_host" && {
                    echo -n "${src_snaps[$i]}"
                    return 0
                }
            fi
        done
    done

    # Names didn't line up -- the snapshot that both sides share may have
    # been renamed on one of them since the last sync (dataset move, manual
    # tidy-up, etc). GUID is unaffected by rename, and `zfs receive` keys an
    # incremental off the stream's embedded fromguid, not off matching
    # names, so a source-side name is all `-i` needs. Scan every pair,
    # newest-target-first, for a source snapshot still carrying that GUID.
    local tgt_names=() tgt_guids=()
    while IFS=$'\t' read -r _n _g; do
        [ -z "$_n" ] && continue
        tgt_names+=("$_n"); tgt_guids+=("$_g")
    done <<< "$(get_snapshot_guids "$tgt_dataset" "$remote_user" "$remote_host")"

    local src_names=() src_guids=()
    while IFS=$'\t' read -r _n _g; do
        [ -z "$_n" ] && continue
        src_names+=("$_n"); src_guids+=("$_g")
    done <<< "$(get_snapshot_guids "$src_dataset")"

    for ((j=${#tgt_guids[@]}-1; j>=0; j--)); do
        [ -z "${tgt_guids[$j]}" ] && continue
        for ((i=${#src_guids[@]}-1; i>=0; i--)); do
            if [[ "${src_guids[$i]}" == "${tgt_guids[$j]}" ]]; then
                echo -n "${src_names[$i]}"
                return 0
            fi
        done
    done

    echo -n "null"
}

create_snapshot() {
    local dataset="$1"
    local snapshot_name="${dataset}@${SNAP_MESSAGE}${RUN_SUFFIX}"
    local recursive_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_flag="-r"
    
    log 1 "Creating new snapshot: $snapshot_name"
    zfs snapshot $recursive_flag "$snapshot_name" || return 1
    echo "$snapshot_name"
}
###############################################################################
#END 3B

###############################################################################
#BEGIN 3D [RESUMABLE TRANSFER SUPPORT]
###############################################################################
# MAX_RESUME_ATTEMPTS and the resume helpers (get_resume_token, abandon_resume,
# resume_state_file, read/increment/reset_resume_attempts) are byte-identical
# between snapsend.sh and snapget.sh, so they live in lib-zfs-snap.sh (sourced
# at the top). See the header comment there.
###############################################################################
#END 3D

###############################################################################
#BEGIN 3C [DATA TRANSFER OPERATIONS]
###############################################################################
transfer_data() {
    local send_cmd="$1"
    local recv_cmd="$2"
    local remote_host="$3"
    local remote_user="$4"
    
    log 3 "EXECUTING TRANSFER:"
    log 3 "SEND CMD: $send_cmd"
    log 3 "RECV CMD: $recv_cmd"

    # PUSH: the source is THIS host, so the dry run is local. $remote_host here
    # is the DESTINATION -- measuring the stream there would be asking the wrong
    # machine about the wrong dataset, which is why it is not passed on.
    announce_transfer_size "$send_cmd" "" ""

    # LIVE PROGRESS (2026-08-23). Same mechanism as snapget.sh, mirrored for the
    # PUSH direction: here `zfs send` runs LOCALLY, so its -v -P output is on our
    # own stderr rather than arriving over ssh. The ssh in this direction
    # RECEIVES the stream on stdin, which is why it must never be given -n and
    # why the capture goes on the send, not on the ssh.
    #
    # The stderr is captured to a file, a watcher reads it alongside, and the
    # progress lines are stripped before the file is replayed -- the alerting
    # path takes `tail -n 8` of this stream when a job fails, and progress lines
    # there would replace the reason with a byte counter.
    local _pg_snap _pg_err _pg_pid _pg_rc=0
    progress_reap
    _pg_snap=${send_cmd##* }
    local _pg_tgt=${recv_cmd##* }
    local PG_MODE PG_BASE; progress_classify "$send_cmd"
    if [ "${PROGRESS_ENABLED:-1}" = "1" ]; then
        case "$send_cmd" in
            "zfs send "*) send_cmd="zfs send -v -P ${send_cmd#zfs send }" ;;
        esac
        _pg_err=$(mktemp 2>/dev/null) || _pg_err=""
    fi

    local send_args
    local recv_args
    IFS=' ' read -r -a send_args <<< "$send_cmd"
    IFS=' ' read -r -a recv_args <<< "$recv_cmd"
    
    if [ -n "$remote_host" ]; then
        if [ $COMPRESSION -eq 1 ]; then
            if [ "$(remote_has_compressor "$remote_user" "$remote_host" "$COMPRESSOR")" != "yes" ]; then
                log 0 "Compression requested but $COMPRESSOR is not installed on remote host $remote_host"
                return 1
            fi
            [ -n "$_pg_err" ] && _pg_pid=$(progress_watch "$_pg_err" "$_pg_snap" "$_pg_tgt" "${remote_host:-local}" push "$PG_MODE" "$PG_BASE")
            if ! "${send_args[@]}" 2>${_pg_err:-/dev/stderr} | $COMPRESS_PIPE | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | $recv_cmd"; then
                _pg_rc=1
            fi
            if [ -n "$_pg_err" ]; then
                progress_done "$_pg_pid" "$_pg_snap" "$_pg_tgt" "$([ $_pg_rc -eq 0 ] && echo ok || echo failed)"
                progress_strip "$_pg_err"
                [ -s "$_pg_err" ] && cat "$_pg_err" >&2
                rm -f "$_pg_err"
            fi
            if [ $_pg_rc -ne 0 ]; then return 1; fi
        else
            [ -n "$_pg_err" ] && _pg_pid=$(progress_watch "$_pg_err" "$_pg_snap" "$_pg_tgt" "${remote_host:-local}" push "$PG_MODE" "$PG_BASE")
            if ! "${send_args[@]}" 2>${_pg_err:-/dev/stderr} | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $recv_cmd"; then
                _pg_rc=1
            fi
            if [ -n "$_pg_err" ]; then
                progress_done "$_pg_pid" "$_pg_snap" "$_pg_tgt" "$([ $_pg_rc -eq 0 ] && echo ok || echo failed)"
                progress_strip "$_pg_err"
                [ -s "$_pg_err" ] && cat "$_pg_err" >&2
                rm -f "$_pg_err"
            fi
            if [ $_pg_rc -ne 0 ]; then return 1; fi
        fi
    else
        # COMPRESSION is forced to 0 for a local target in section 5B, so this
        # branch is not reachable in normal operation. Kept because it is the
        # correct pipeline if compression is ever wanted here; the policy of not
        # wanting it lives in one place, not spread into the transport layer.
        if [ $COMPRESSION -eq 1 ]; then
            [ -n "$_pg_err" ] && _pg_pid=$(progress_watch "$_pg_err" "$_pg_snap" "$_pg_tgt" "${remote_host:-local}" push "$PG_MODE" "$PG_BASE")
            if ! "${send_args[@]}" 2>${_pg_err:-/dev/stderr} | $COMPRESS_PIPE | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
                _pg_rc=1
            fi
            if [ -n "$_pg_err" ]; then
                progress_done "$_pg_pid" "$_pg_snap" "$_pg_tgt" "$([ $_pg_rc -eq 0 ] && echo ok || echo failed)"
                progress_strip "$_pg_err"
                [ -s "$_pg_err" ] && cat "$_pg_err" >&2
                rm -f "$_pg_err"
            fi
            if [ $_pg_rc -ne 0 ]; then return 1; fi
        else
            [ -n "$_pg_err" ] && _pg_pid=$(progress_watch "$_pg_err" "$_pg_snap" "$_pg_tgt" "${remote_host:-local}" push "$PG_MODE" "$PG_BASE")
            if ! "${send_args[@]}" 2>${_pg_err:-/dev/stderr} | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | "${recv_args[@]}"; then
                _pg_rc=1
            fi
            if [ -n "$_pg_err" ]; then
                progress_done "$_pg_pid" "$_pg_snap" "$_pg_tgt" "$([ $_pg_rc -eq 0 ] && echo ok || echo failed)"
                progress_strip "$_pg_err"
                [ -s "$_pg_err" ] && cat "$_pg_err" >&2
                rm -f "$_pg_err"
            fi
            if [ $_pg_rc -ne 0 ]; then return 1; fi
        fi
    fi
}
###############################################################################
#END 3C
###############################################################################
#END 3

###############################################################################
#BEGIN 4 [MAIN PROCESSING]
###############################################################################
process_dataset() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    STATS_RESUMED="no"
    # Local shadow: -F reconciliation below may escalate THIS run to a full
    # send by flipping this, same as -f, without touching the global (which
    # would leak into other datasets in a multi-dataset invocation).
    local FORCE_FULL_SEND=$FORCE_FULL_SEND
    # Remembers whether -f itself was passed, before -F below can flip the
    # shadow above -- used only to keep the "(-f)" log message honest.
    local user_requested_full=$FORCE_FULL_SEND
    # One-time handover of state files written under the pre-v3 naming, before
    # anything reads them. See adopt_legacy_state in lib-zfs-snap.sh.
    adopt_legacy_state "$tgt_dataset" "$src_dataset"
    # Local shadow: -T's auto-check below may flip THIS dataset to
    # skip-intermediates without touching the global -- each dataset in a
    # multi-dataset invocation gets its own fresh copy of whatever the user
    # actually passed on the command line, and its own independent measurement.
    local SKIP_INTERMEDIATES=$SKIP_INTERMEDIATES
    validate_remote_host "$remote_user" "$remote_host"
    check_pool_health "$src_dataset" "" ""
    [ -n "$remote_host" ] && check_pool_health "$tgt_dataset" "$remote_user" "$remote_host"
    log 3 "================================================"
    log 3 "PROCESSING DATASET:"
    log 3 "SRC: $src_dataset"
    log 3 "TGT: $tgt_dataset"
    log 3 "REMOTE: $remote_user@$remote_host"
    log 3 "================================================"

    if [ $DRY_RUN -eq 1 ]; then
        local common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        find_conflicting_snapshots "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$common_snapshot"
        return 0
    fi

    if [[ "$src_dataset" == "$tgt_dataset" && -z "$remote_host" ]]; then
        log 1 "Running in local snapshot-only mode"
        # This branch creates a snapshot unconditionally -- it predates
        # USE_EXISTING_SNAPSHOT and deliberately still ignores it, because a
        # snapshot-only run with -e would otherwise do nothing at all. But the
        # quiesce window has ALREADY created this dataset's snapshot, and making
        # a second one here would be an unquiesced copy taken moments later,
        # silently undoing both the freeze and the atomicity of the single
        # multi-dataset `zfs snapshot` it came from. Checked separately from
        # USE_EXISTING_SNAPSHOT so -e keeps its own meaning.
        if [ "${QUIESCE_SNAPPED:-0}" -eq 1 ]; then
            log 1 "Snapshot for $src_dataset was already taken inside the quiesce window -- not creating a second, unquiesced one"
            return 0
        fi
        snapshot=$(create_snapshot "$src_dataset") || return 1
        log 1 "Successfully created local snapshot: $snapshot"
        return 0
    fi

    if ! zfs list -H "$src_dataset" &>/dev/null; then
        log 0 "Source dataset not found: $src_dataset"
        return 1
    fi

    # Checked here, before anything is created, snapshotted or (under -f)
    # destroyed: a rawness mismatch can never succeed, so a doomed run must not
    # leave side effects behind. Skipped under -f, which destroys the target and
    # so has no seeding left to conflict with. Source is always local here.
    if [ $FORCE_FULL_SEND -ne 1 ]; then
        check_raw_compatibility "$src_dataset" "" "" \
                                "$tgt_dataset" "$remote_user" "$remote_host" \
                                "$RAW_SEND" || return 1
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        local resume_token
        resume_token=$(get_resume_token "$tgt_dataset" "$remote_user" "$remote_host")
        if [ -n "$resume_token" ]; then
            local attempts
            attempts=$(read_resume_attempts "$tgt_dataset" "$src_dataset")
            if [ "$attempts" -ge "$MAX_RESUME_ATTEMPTS" ]; then
                log 1 "Resume failed $attempts times for $tgt_dataset - abandoning stuck state"
                abandon_resume "$tgt_dataset" "$remote_user" "$remote_host"
                reset_resume_attempts "$tgt_dataset" "$src_dataset"
                # Giving up on this snapshot -- release whatever the original
                # failed attempt held, so it can be pruned like normal again.
                # A fresh $snapshot is about to be resolved below.
                local stuck_snap
                stuck_snap=$(read_inflight_snap "$tgt_dataset" "$src_dataset")
                [ -n "$stuck_snap" ] && release_snapshot "$stuck_snap" "" ""
                clear_inflight_snap "$tgt_dataset" "$src_dataset"
                log 1 "Abandoned - falling through to normal transfer logic"
            else
                increment_resume_attempts "$tgt_dataset" "$src_dataset"
                log 1 "Found resume token for $tgt_dataset - resuming interrupted transfer (attempt $((attempts + 1))/$MAX_RESUME_ATTEMPTS)"
                local resume_recv_flags="-F -s"
                [ $UNMOUNT -eq 1 ] && resume_recv_flags="$resume_recv_flags -u"
                [ -n "$RECV_EXCLUDE_FLAGS" ] && resume_recv_flags="$resume_recv_flags$RECV_EXCLUDE_FLAGS"
                local resume_send_cmd="zfs send -t $resume_token"
                local resume_recv_cmd="zfs recv $resume_recv_flags $tgt_dataset"
                log 4 "RAW RESUME SEND COMMAND: $resume_send_cmd"
                log 4 "RAW RESUME RECV COMMAND: $resume_recv_cmd"
                if transfer_data "$resume_send_cmd" "$resume_recv_cmd" "$remote_host" "$remote_user"; then
                    reset_resume_attempts "$tgt_dataset" "$src_dataset"
                    STATS_RESUMED="yes"
                    # Resumed stream landed -- release the hold placed on the
                    # original attempt (this run never recomputes $snapshot).
                    local resumed_snap
                    resumed_snap=$(read_inflight_snap "$tgt_dataset" "$src_dataset")
                    [ -n "$resumed_snap" ] && release_snapshot "$resumed_snap" "" ""
                    clear_inflight_snap "$tgt_dataset" "$src_dataset"
                    log 1 "Resumed transfer completed successfully"
                    return 0
                else
                    log 0 "Resume attempt failed"
                    # Still under MAX_RESUME_ATTEMPTS -- leave the hold in
                    # place for the next attempt.
                    return 1
                fi
            fi
        fi
    fi

    # -F: if any child (recursively) has a snapshot named like the resolved
    # top-level common snapshot but under a MISMATCHED GUID, this run's
    # `zfs send -R -I` would ship an incremental keyed to that name for
    # every child that has it -- fails hard for this one, and destroying its
    # snapshot doesn't help either (source still offers that name, so the
    # stream still tries an incremental against a target with nothing left
    # to receive onto; probed live: recv tears the child down instead of
    # just erroring). The only fix ZFS actually supports in one command is
    # upgrading this whole run to what -f already does: destroy everything
    # on target, recreate, full resend -- so that's what this does, via the
    # local FORCE_FULL_SEND shadow declared at the top of this function,
    # reusing -f's existing (already-guarded, already-tested) machinery
    # rather than half-reimplementing it.
    #
    # Deliberately narrower than find_conflicting_snapshots/-n: a target-only
    # snapshot that does NOT collide by name is normal and harmless (longer
    # local retention -- see the pve0 archive job, where -n always "fails"
    # for exactly that reason, by design). Triggering on that broader
    # definition would force an expensive full resend on EVERY run against
    # any target with different retention.
    if [ $RECONCILE -eq 1 ] && [ $RECURSIVE -eq 1 ] && [ $FORCE_FULL_SEND -ne 1 ]; then
        local reconcile_common
        reconcile_common=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        NAME_COLLISIONS=()
        find_recursive_name_collisions "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$reconcile_common"
        if [ ${#NAME_COLLISIONS[@]} -gt 0 ]; then
            log 1 "Reconciling (-F): name collision(s) with a mismatched GUID would block the incremental send:"
            printf '%s\n' "${NAME_COLLISIONS[@]}" | sort -u | while IFS= read -r collision; do log 1 "  $collision"; done
            log 1 "Upgrading this run to a full resend of the whole subtree (same as -f)"
            FORCE_FULL_SEND=1
        fi
        NAME_COLLISIONS=()
    fi

    # Work out WHAT is going to be sent before touching the target in any way.
    # This ordering is load-bearing, not cosmetic: everything below either
    # creates the target dataset or, under -f, destroys it outright. Resolving
    # the source snapshot afterwards meant a run that could never succeed still
    # got that far -- `-f -e -m <prefix that matches nothing>` destroyed every
    # snapshot and all data on the target and only THEN reported "no source
    # snapshots matching message", leaving the backup gone until the next
    # successful full send. Confirmed live before the fix.
    if [ "$USE_EXISTING_SNAPSHOT" -eq 1 ]; then
        local src_snaps
        src_snaps=($(get_sorted_snapshots "$src_dataset")) || return 1
        if [ ${#src_snaps[@]} -eq 0 ]; then
            log 0 "No source snapshots found"
            return 1
        fi

        # -E exclusions (declared-passive, 2026-08-23): the owner's model for
        # passive is "take the NEWEST, whatever it is called, minus the
        # excluded families". Names are data from a foreign system, so this is
        # a prefix skip-list, not a recogniser -- an excluded name can never be
        # adopted as the base, and the newest NON-excluded snapshot wins even
        # when an excluded one is newer.
        if [ ${#EXCLUDE_SNAPS[@]} -gt 0 ]; then
            local _xs=() _sn _xp _hit
            for _sn in "${src_snaps[@]}"; do
                _hit=0
                for _xp in "${EXCLUDE_SNAPS[@]}"; do
                    case "$_sn" in "$_xp"*) _hit=1; break ;; esac
                done
                [ "$_hit" -eq 0 ] && _xs+=("$_sn")
            done
            src_snaps=(${_xs[@]+"${_xs[@]}"})
            if [ ${#src_snaps[@]} -eq 0 ]; then
                if [ $FLAT_RECURSE -eq 1 ]; then
                    log 1 "Only excluded families on '$src_dataset' -- scaffolding under -R -e, skipped"
                    ADOPT_SKIPPED=$((ADOPT_SKIPPED+1))
                    return 0
                fi
                log 0 "Every source snapshot on '$src_dataset' matches an -E exclusion -- nothing eligible to adopt"
                return 1
            fi
        fi

        if [ -n "$MESSAGE" ]; then
            src_snaps=($(printf "%s\n" "${src_snaps[@]}" | grep "^$MESSAGE"))
            if [ ${#src_snaps[@]} -eq 0 ]; then
                log 0 "No source snapshots matching message: $MESSAGE"
                return 1
            fi
        fi

        local latest_snap="${src_snaps[-1]}"
        snapshot="${src_dataset}@${latest_snap}"
    else
        snapshot=$(create_snapshot "$src_dataset") || return 1
        latest_snap="${snapshot##*@}"
    fi

    # Hold it for the whole transfer window, including across a resume that
    # spans later cron runs -- see HOLD-BASED PROTECTION in lib-zfs-snap.sh.
    # Source is always local in snapsend.sh. Released on the success path
    # below and in the resume branch above; deliberately left held on failure
    # so a stuck resume keeps its source snapshot until it either succeeds or
    # is abandoned.
    hold_snapshot "$snapshot" "" ""
    record_inflight_snap "$tgt_dataset" "$src_dataset" "$snapshot"

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        log 2 "Creating target dataset: $tgt_dataset"
        # canmount=noauto: a freshly created target starts unmounted and stays
        # that way across zfs receive's own mount/unmount cycles. On Linux,
        # unprivileged users can't mount/unmount at all (unlike illumos), so
        # this is what makes non-root incremental receive into this dataset
        # possible afterward. Only applies to this leaf -- any -p-created
        # ancestor still needs to already exist for a non-root run to succeed.
        # Setting canmount here needs its own delegated 'canmount' property
        # permission (zfs allow) in addition to create/mount/receive -- it is
        # NOT bundled into the 'create' permission despite being set at
        # create time. Confirmed live: "permission denied" without it.
        #
        # EXCEPTION for -w: a raw stream carries the source dataset's own
        # properties, encryption included, so `zfs recv` has to CREATE the leaf
        # itself. Pre-creating it here makes it a plain unencrypted dataset and
        # ZFS then refuses the stream outright:
        #   "zfs receive -F cannot be used to destroy an encrypted filesystem
        #    or overwrite an unencrypted one with an encrypted one"
        # So under -w only the PARENT is ensured (ancestors must exist for a
        # non-root receive) and the leaf is left to recv. canmount=noauto is
        # reapplied after a successful transfer instead of at create time.
        local create_target="$tgt_dataset"
        [ $RAW_SEND -eq 1 ] && create_target="${tgt_dataset%/*}"
        # Ancestors first, each explicitly canmount=noauto -- `zfs create -p`
        # would give them canmount=on and a non-root receive dies mounting them.
        # See ensure_target_ancestors() in lib-zfs-snap.sh.
        ensure_target_ancestors "$create_target" "$remote_user" "$remote_host" || {
            log 0 "Failed to create the ancestor path of $create_target"
            abort_held_snapshot "$snapshot" "$tgt_dataset"
            return 1
        }
        if [ -n "$remote_host" ]; then
            ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list '$create_target' >/dev/null 2>&1 || zfs create -o canmount=$TARGET_CANMOUNT '$create_target'" || {
                    abort_held_snapshot "$snapshot" "$tgt_dataset"; return 1; }
        else
            zfs list "$create_target" >/dev/null 2>&1 || zfs create -o canmount=$TARGET_CANMOUNT "$create_target" || {
                abort_held_snapshot "$snapshot" "$tgt_dataset"; return 1; }
        fi
    fi

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        if [ $user_requested_full -eq 1 ]; then
            log 1 "Force full send activated (-f)"
        else
            log 1 "Full resend activated (-F reconciliation)"
        fi

        local protected_snaps
        if [ -n "$remote_host" ]; then
            protected_snaps=$(ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list -t snapshot -H -o name -r '$tgt_dataset' 2>/dev/null" | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        else
            protected_snaps=$(zfs list -t snapshot -H -o name -r "$tgt_dataset" 2>/dev/null | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        fi
        if [ -n "$protected_snaps" ]; then
            log 0 "Refusing force full send: $tgt_dataset (or a descendant) holds snapshot(s) reserved by Proxmox VE (replication/migration/vzdump):"
            log 0 "$protected_snaps"
            log 0 "This target looks like it's managed by Proxmox VE outside this tool -- force full send would destroy that state and break replication/migration/backup. Remove the conflicting job/snapshots yourself first if this is intentional."
            abort_held_snapshot "$snapshot" "$tgt_dataset"
            return 1
        fi

        log 2 "Destroying all snapshots and data on target dataset"

        local destroy_cmd="zfs list -H -o name -r \"$tgt_dataset\" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R \"\$@\" 2>/dev/null || true' -- {}"
        log 4 "RAW ZFS DESTROY COMMAND: $destroy_cmd"  # debug logging
        
        if [ -n "$remote_host" ]; then
            log 4 "EXECUTING DESTROY ON REMOTE: $remote_host"
            ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$destroy_cmd"
        else
            log 4 "EXECUTING DESTROY LOCALLY"
            zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R "$@" 2>/dev/null || true' -- {} || true
        fi

        # Under -w the leaf must be left for recv to create from the raw stream
        # (see the creation block above) -- recreating it plain here would put
        # back exactly the unencrypted dataset the raw stream cannot land on,
        # turning every -f -w run into a guaranteed failure. The destroy above
        # already removed the leaf; ancestors survive it, so recv has what it
        # needs.
        if [ $RAW_SEND -eq 1 ]; then
            log 2 "Not recreating target dataset (-w: raw receive creates it)"
        else
        log 2 "Recreating target dataset"
        ensure_target_ancestors "$tgt_dataset" "$remote_user" "$remote_host" || {
            log 0 "Failed to create the ancestor path of $tgt_dataset"
            abort_held_snapshot "$snapshot" "$tgt_dataset"
            return 1
        }
        local create_cmd="zfs create -o canmount=$TARGET_CANMOUNT \"$tgt_dataset\""
        log 4 "RAW ZFS CREATE COMMAND: $create_cmd"

        if [ -n "$remote_host" ]; then
            ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$create_cmd" || {
                log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root on $remote_host."
                abort_held_snapshot "$snapshot" "$tgt_dataset"
                return 1
            }
        else
            zfs create -o canmount=$TARGET_CANMOUNT "$tgt_dataset" || {
                log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root."
                abort_held_snapshot "$snapshot" "$tgt_dataset"
                return 1
            }
        fi
        fi
    fi

    # Under -w the leaf target is deliberately NOT pre-created (recv builds it
    # from the raw stream), so on a first send it does not exist yet and
    # get_sorted_snapshots fails -- `zfs list` on a missing dataset exits 1 and
    # pipefail propagates it. That is not an error here, it is the first-send
    # case: a target that does not exist simply has no snapshots. Every other
    # mode still pre-creates the target, so a failure there remains a real one
    # and is still reported.
    # Three-valued again: rc 2 (host unreachable) must not be read as the
    # first-send case, which would skip the snapshot listing entirely and send a
    # full raw stream at a host we never reached.
    local tgt_snaps tgt_state=0
    if [ $RAW_SEND -eq 1 ]; then
        target_exists "$tgt_dataset" "$remote_user" "$remote_host"
        tgt_state=$?
        [ $tgt_state -eq 2 ] && { abort_held_snapshot "$snapshot" "$tgt_dataset"; return 1; }
    fi
    if [ $RAW_SEND -eq 1 ] && [ $tgt_state -eq 1 ]; then
        log 2 "Target does not exist yet -- raw receive will create it"
        tgt_snaps=()
    else
        tgt_snaps=($(get_sorted_snapshots "$tgt_dataset" "$remote_user" "$remote_host")) || {
            abort_held_snapshot "$snapshot" "$tgt_dataset"; return 1; }
    fi

    log 3 "LATEST SOURCE SNAPSHOT: ${snapshot}"
    log 3 "EXISTING TARGET SNAPSHOTS:"
    for snap in "${tgt_snaps[@]}"; do
        log 3 "  ${tgt_dataset}@${snap}"
    done

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        [ $user_requested_full -eq 1 ] && log 1 "Force full send activated (-f)"
        local common_snapshot="null"
    else
        if [[ " ${tgt_snaps[*]} " == *" ${latest_snap} "* ]]; then
            if validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
                log 1 "Snapshot already exists in target - skipping"
                release_snapshot "$snapshot" "" ""
                clear_inflight_snap "$tgt_dataset" "$src_dataset"
                return 0
            else
                log 1 "Snapshot exists but timestamps differ - forcing full send"
                local common_snapshot="null"
            fi
        else
            local common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        fi
    fi

    local send_cmd
    local recursive_send_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_send_flag="-R"

    # -w rides along on every send path below EXCEPT the resume path above:
    # `zfs send -t <token>` already encodes rawness in the token, and passing -w
    # on top of it does not just error, it aborts (SIGABRT / rc=134,
    # "internal error: Invalid argument" on zfs-2.1.9). Verified, not assumed.
    #
    # Note the two send_args word-splits in transfer_data use IFS=' ', and space
    # is IFS whitespace, so runs of spaces collapse -- an empty flag var leaves
    # no stray empty argument. Same reason recursive_send_flag can be empty.
    local raw_send_flag=""
    [ $RAW_SEND -eq 1 ] && raw_send_flag="-w"

    # -c rides the same paths as -w and is likewise absent from the resume path,
    # but for the opposite reason: not because it would break there (probing
    # showed resume tokens are entirely indifferent to it) but because there is
    # nothing to decide -- the token already fixes the stream format.
    local comp_send_flag
    comp_send_flag=$(compressed_send_flag "$src_dataset" "$tgt_dataset" \
                        "${remote_host:+${remote_user}@${remote_host}}")
    [ -n "$comp_send_flag" ] && log 3 "Compressed send: using zfs send -c"

    local bookmark_base=""
    if [[ "$common_snapshot" == "null" ]] && [ $RECURSIVE -ne 1 ]; then
        # No common snapshot survives on either end -- before giving up to a
        # FULL send, check for a bookmark left by a prior run (see
        # lib-zfs-snap.sh). Source is always local in snapsend.sh, so
        # find_bookmark_base gets no remote args; the target's head GUID is
        # queried with the same remote params tgt_snaps already used.
        local tgt_head_guid=""
        if [ ${#tgt_snaps[@]} -gt 0 ]; then
            tgt_head_guid=$(get_snapshot_guid "$tgt_dataset" "${tgt_snaps[-1]}" "$remote_user" "$remote_host")
        fi
        bookmark_base=$(find_bookmark_base "$src_dataset" "$tgt_head_guid")
    fi

    if [[ "$common_snapshot" != "null" ]]; then
        log 1 "Found valid common snapshot: ${src_dataset}@${common_snapshot}"
        # -T: only when the user did NOT already say -i explicitly (the shadow
        # above is 1 from the start of this call in that case, so this whole
        # block is skipped -- an explicit flag always wins over an inferred
        # one, same precedent as -A never overruling an explicit -z/-Z/-g/-N).
        if [ $SKIP_INTERMEDIATES -eq 0 ] && [ -n "$THRESHOLD_INTERVALS" ]; then
            if [ "$(auto_skip_intermediates "$src_dataset" "$MESSAGE" "$common_snapshot" "$THRESHOLD_INTERVALS" "" "")" = "yes" ]; then
                log 1 "Catch-up (-T $THRESHOLD_INTERVALS): more than $THRESHOLD_INTERVALS of this dataset's own snapshot intervals have elapsed since the common base -- sending only the diff to newest"
                SKIP_INTERMEDIATES=1
            fi
        fi
        # -i (SKIP_INTERMEDIATES): the diff to newest only, none of the
        # snapshots in between -- literal `zfs send -i` in place of the
        # default `-I`. Valid combined with $recursive_send_flag (verified
        # live: `zfs send -R -i` is accepted and correctly elides
        # intermediates on every dataset in the subtree, same as -I does today).
        local incr_flag="-I"
        [ $SKIP_INTERMEDIATES -eq 1 ] && incr_flag="-i"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS $incr_flag ${src_dataset}@${common_snapshot} $snapshot"
    elif [ -n "$bookmark_base" ]; then
        log 1 "No common snapshot, but a bookmark still anchors an incremental: $bookmark_base"
        [ $SKIP_INTERMEDIATES -eq 1 ] && log 2 "-i requested but already sending a single diff via bookmark -- nothing to skip"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $EXTRA_SEND_OPTS -i $bookmark_base $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history send"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS -R $snapshot"
        else
            log 1 "Performing standard full send"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS $snapshot"
        fi
        [ $SKIP_INTERMEDIATES -eq 1 ] && log 2 "-i requested but there is no common snapshot to diff against -- nothing to skip"
    fi

    # -s makes ZFS SAVE partial receive state on interruption (and expose a
    # receive_resume_token) instead of rolling it back -- this is the
    # precondition for the resumable-transfer logic above to ever fire.
    local recv_flags="-F -s"
    [ $UNMOUNT -eq 1 ] && recv_flags="$recv_flags -u"
    [ -n "$RECV_EXCLUDE_FLAGS" ] && recv_flags="$recv_flags$RECV_EXCLUDE_FLAGS"
    local recv_cmd="zfs recv $recv_flags $tgt_dataset"

    log 4 "RAW ZFS SEND COMMAND: $send_cmd"
    log 4 "RAW ZFS RECV COMMAND: $recv_cmd"

    log 1 "Starting transfer..."
    transfer_data "$send_cmd" "$recv_cmd" "$remote_host" "$remote_user" || {
        log 0 "Transfer failed"
        [ $FORCE_FULL_SEND -eq 1 ] && log 0 "Hint: a full send/-f-style receive does a forced rollback, which needs to mount/unmount the target. On Linux, non-root users cannot do that even with full 'zfs allow' delegation -- if this failed on a mount/unmount permission error, this run needed root${remote_host:+ on $remote_host}."
        # Only keep the hold if it is actually still useful: a
        # receive_resume_token means the resume branch above will need this
        # exact source snapshot on a later run. Without one (e.g. zfs recv
        # refused outright, before writing anything -- "destination has
        # snapshots" and similar), nothing will ever come back to release it,
        # so release now instead of stranding it un-prunable forever.
        if [ -z "$(get_resume_token "$tgt_dataset" "$remote_user" "$remote_host")" ]; then
            release_snapshot "$snapshot" "" ""
            clear_inflight_snap "$tgt_dataset" "$src_dataset"
        fi
        return 1
    }

    # Transfer landed -- this snapshot is no longer "in flight", safe to prune
    # on the next delsnaps.sh run like any other.
    # PROVE IT LANDED (owner-directed 2026-08-22). Until now the ONLY evidence
    # a transfer worked was that the pipeline exited 0 -- which says the
    # processes did not crash, not that the data is on the target. Every live
    # campaign in this project has been verified by a human comparing GUIDs by
    # hand afterwards, precisely because the tool could not say it. A backup
    # tool whose success means "nothing threw an error" is the wrong instrument
    # for the one question it exists to answer.
    #
    # validate_snapshot is not new: it already compares ZFS's own identity for
    # a snapshot on both sides, and this file already trusts it to decide
    # whether an existing target snapshot is the same one. Reusing it here
    # rather than writing a second comparator keeps one definition of "the same
    # snapshot" -- two would drift, and this project has spent the day paying
    # for exactly that kind of duplication.
    #
    #
    # AND IT SITS HERE, BEFORE THE DURABLE YES. Caught in review: the first cut
    # of this check ran AFTER release_snapshot, clear_inflight_snap and
    # record_send_bookmark. So a failed verification returned 1 while the hold
    # protecting the snapshot was already gone, the in-flight marker was already
    # cleared, and the bookmark already pointed at a target nobody had
    # confirmed -- durable state saying "done" about a transfer the function was
    # in the middle of calling failed. The retry would then find its base
    # unprotected and prunable. A proof that runs after the thing it is meant to
    # gate is decoration.
    # Under -r this proves the ROOT landed; validate_subtree right below proves
    # every descendant did too. The boundary noted here until 2026-08-24 --
    # "the descendants rode the same stream and cannot have arrived
    # separately" -- was measured FALSE and is now checked, not assumed.
    # Under -R each dataset is its own job and each is proven on its own pass.
    if ! validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
        progress_mark_verified "$tgt_dataset" verify_failed
        log 0 "VERIFY FAILED: ${tgt_dataset}@${latest_snap} is not on the target with the source's GUID -- the transfer reported success but the snapshot cannot be confirmed. Treating this dataset as FAILED rather than reporting a backup that may not exist."
        return 1
    fi
    # Under -r the descendants are NOT individually proven by the check above
    # -- and they cannot be assumed, see validate_subtree.
    if [ $RECURSIVE -eq 1 ] && ! validate_subtree "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
        progress_mark_verified "$tgt_dataset" verify_failed
        return 1
    fi
    log 2 "Verified: ${tgt_dataset}@${latest_snap} carries the source's GUID"
    progress_mark_verified "$tgt_dataset" verified

    release_snapshot "$snapshot" "" ""
    clear_inflight_snap "$tgt_dataset" "$src_dataset"

    # Under -w the leaf was created by recv, not by us, so it never got
    # canmount=noauto at create time. Reapply it now: it is what keeps the
    # target unmounted across future receives and makes non-root incremental
    # receive possible. Best-effort -- an encrypted target is already unmounted
    # (keystatus=unavailable), so failing here costs nothing immediate.
    if [ $RAW_SEND -eq 1 ]; then
        if [ -n "$remote_host" ]; then
            ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs set canmount=$TARGET_CANMOUNT '$tgt_dataset'" 2>/dev/null \
                || log 2 "Could not set canmount=$TARGET_CANMOUNT on $tgt_dataset (needs delegated 'canmount')"
        else
            zfs set canmount=$TARGET_CANMOUNT "$tgt_dataset" 2>/dev/null \
                || log 2 "Could not set canmount=$TARGET_CANMOUNT on $tgt_dataset (needs delegated 'canmount')"
        fi
    fi

    # Under -r the DESCENDANTS are created by `zfs recv` out of the recursive
    # stream, not by this script, so they arrive carrying the source's own
    # canmount -- "on" for any ordinary dataset. The no-mount default (v2.54)
    # therefore stopped at the leaf: measured on metropolis 2026-07-25, a source
    # child with canmount=on replicated with -r produced a MOUNTABLE child on
    # the backup host, while the same source under -R came out noauto. That is
    # exactly the shadow-mount hazard the default exists to prevent, and it is
    # also what a delegated account cannot receive, since it may not mount.
    # Applied to the whole received subtree, filesystems only (a volume has no
    # canmount). Skipped under -U, where mounting is what was asked for.
    if [ $RECURSIVE -eq 1 ] && [ "$TARGET_CANMOUNT" = "noauto" ]; then
        local canmount_cmd="zfs list -H -o name -t filesystem -r '$tgt_dataset' 2>/dev/null | while IFS= read -r d; do zfs set canmount=noauto \"\$d\" 2>/dev/null; done"
        if [ -n "$remote_host" ]; then
            ssh -n "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$canmount_cmd" 2>/dev/null \
                || log 2 "Could not set canmount=noauto across $tgt_dataset (needs delegated 'canmount')"
        else
            eval "$canmount_cmd" 2>/dev/null \
                || log 2 "Could not set canmount=noauto across $tgt_dataset (needs delegated 'canmount')"
        fi
    fi

    # Refresh the per-target bookmark to what was just sent, regardless of
    # which path got us here (common-base incremental, bookmark incremental,
    # or FULL) -- see record_send_bookmark in lib-zfs-snap.sh. Source is
    # always local here.
    [ $RECURSIVE -ne 1 ] && record_send_bookmark "$src_dataset" "$latest_snap" "$tgt_dataset" "" "" "$IDENTIFIER"

    log 1 "Transfer completed successfully"
    return 0
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [ENTRY POINT]
###############################################################################

###############################################################################
#BEGIN 5A [ARGUMENT PARSING]
###############################################################################
PAIR_LABEL=""
# --- long options (Stage 2.3) ------------------------------------------------
#
# getopts has no long options, so the only place to handle them is a pre-pass
# over "$@". It must be getopts-EQUIVALENT or it becomes the very bug REV-054
# fixed in the generator: walking flags without knowing which letters take an
# argument, so `-m --recursive=flat` -- a MESSAGE that happens to look like a
# flag -- gets rewritten as a declaration.
#
# Two rules it copies from getopts, deliberately:
#   * `--` ends option processing;
#   * the first non-option argument ends it too.
# Anything after either point is data and is passed through untouched.
#
# The letters that take an argument are read FROM THE OPTSTRING, not from a
# second list. A hand-kept list is a list that drifts, and a drift here is
# silent: it mis-parses one specific invocation and looks fine everywhere else.
#
# The recursion long forms set the variables DIRECTLY and emit nothing, rather
# than being rewritten to -r/-R. If they emitted short flags, getopts would
# count a second declaration for the same one the user wrote, and the refusal
# would quote a spelling that never appeared on the command line.
OPTSTRING="m:ezZgNl:v:rRniHj:uUfwVp:k:Aq:T:o:x:c:b:FX:SK:O:L:"

opt_takes_arg() {   # <letter>
    case "$OPTSTRING" in *"$1:"*) return 0 ;; *) return 1 ;; esac
}

# Does this short-option token take its value from the NEXT argv?
#
# Yes only when some letter in the cluster takes an argument AND nothing
# follows it inside the token. `-m` yes; `-em` yes (e takes none, m does, and
# the token ends); `-mfoo` no, foo IS the value; `-ez` no.
cluster_needs_next() {   # <token beginning with a single dash>
    local t="${1#-}" i c
    for (( i=0; i<${#t}; i++ )); do
        c="${t:i:1}"
        if opt_takes_arg "$c"; then
            [ $(( i + 1 )) -eq ${#t} ] && return 0
            return 1        # the remainder of the token is the value
        fi
    done
    return 1
}

translate_long_options() {
    local -a out=()
    local a mode last
    while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
            --)  out+=("$@"); break ;;
            --recursive=*)
                mode="${a#--recursive=}"
                case "$mode" in
                    atomic) RECURSIVE=1;    declare_recursion "$a" ;;
                    flat)   FLAT_RECURSE=1; declare_recursion "$a" ;;
                    # A full declaration, not the absence of one: it says "do
                    # not recurse", and a second declaration after it is still
                    # one too many. Emitting nothing here is what makes
                    # `--recursive=no -r` refuse instead of collapsing to -r
                    # (REV-20260807-060 A4, on my own first design).
                    no)     declare_recursion "$a" ;;
                    *) echo "Error: --recursive= takes atomic, flat or no (got '$mode')" >&2; exit 1 ;;
                esac
                shift ;;
            --recursive)
                echo "Error: --recursive needs a mode: --recursive=atomic|flat|no" >&2; exit 1 ;;
            --*)
                echo "Error: unknown option $a" >&2; exit 1 ;;
            -?*)
                out+=("$a"); shift
                # Walk the cluster the way getopts does, left to right. The
                # FIRST letter that takes an argument consumes the rest of the
                # token as its value; if there is no rest, it consumes the NEXT
                # argv, which must then not be inspected as an option.
                #
                # REV-20260808-069 F1: this used to fire only when the token was
                # exactly two characters, so `-m --recursive=flat` was handled
                # and the legal clustered form `-em --recursive=flat` was not --
                # the message was read as a recursion declaration. "The last
                # letter of a two-character token" is not the getopts grammar,
                # it is one case of it.
                cluster_needs_next "$a" && [ $# -gt 0 ] && { out+=("$1"); shift; } ;;
            *)
                # First non-option argument: getopts stops here, so do we.
                out+=("$@"); break ;;
        esac
    done
    TRANSLATED_ARGS=("${out[@]+"${out[@]}"}")
}

# Assigned through a GLOBAL array, not printed and re-read. A process
# substitution would put the whole walk in a SUBSHELL, so RECURSIVE,
# FLAT_RECURSE and the declaration counter would be set in a child that then
# exits -- the same subshell trap that made the first run-suffix test pass
# against unchanged code. It also keeps arguments containing whitespace or
# newlines intact, with no delimiter to choose.
TRANSLATED_ARGS=()
if [ $# -gt 0 ]; then
    translate_long_options "$@"
    set -- "${TRANSLATED_ARGS[@]+"${TRANSLATED_ARGS[@]}"}"
fi

while getopts "m:ezZgNl:v:rRniHj:uUfwVp:k:Aq:T:o:x:c:b:FX:SK:O:L:E:" opt; do
    case $opt in
        m) MESSAGE="$OPTARG";;
        j) IDENTIFIER="$OPTARG";;
        A) AUTOTUNE=1;;
        e) USE_EXISTING_SNAPSHOT=1;;
        E) EXCLUDE_SNAPS+=("$OPTARG");;
        q) QUIESCE="$OPTARG";;
        z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        Z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        g) COMPRESSION=1; COMPRESSOR="pigz"; COMPRESSION_SET=1;;
        N) NO_COMPRESS=1;;
        l) COMPRESSION_LEVEL="$OPTARG"; COMPRESSION_LEVEL_SET=1;;
        v) VERBOSE="$OPTARG";;
        r) RECURSIVE=1; declare_recursion -r;;
        R) FLAT_RECURSE=1; declare_recursion -R;;
        X) EXCLUDE_PATTERNS+=("$OPTARG");;
        S) SKIP_PARENT=1;;
        n) DRY_RUN=1;;
        H) FULL_HISTORY_SEND=1;;
        i) SKIP_INTERMEDIATES=1;;
        T) THRESHOLD_INTERVALS="$OPTARG";;
        u) UNMOUNT=1;;   # no-op since v2.54 (this is the default); kept so existing cron lines keep parsing
        U) UNMOUNT=0;;
        f) FORCE_FULL_SEND=1;;
        w) RAW_SEND=1;;
        p) PORT="$OPTARG";;
        k) KNOWN_HOSTS_FILE="$OPTARG";;
        o) EXTRA_SEND_OPTS="$OPTARG";;
        x) RECV_EXCLUDE_FLAGS="$RECV_EXCLUDE_FLAGS -x $OPTARG";;
        c) SSH_CIPHER="$OPTARG";;
        K) SSH_KEY="$OPTARG";;
        O) EXTRA_SSH_OPTS+=("$OPTARG");;
        b) BWLIMIT="$OPTARG";;
        F) RECONCILE=1;;
        L) PAIR_LABEL="$OPTARG";;
        V) echo "$VERSION"; exit 0;;
        *)
            echo "Blad: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -Z -g -N -l -v -r -R -X -S -n -H -i -T -u -f -w -p -k -A -q -j -o -x -c -b -K -O -U -F -L -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

# Two different modes keep their own message: it is the mistake people actually
# make, and the useful answer is what the two modes MEAN, not how many were
# given.
if [ $FLAT_RECURSE -eq 1 ] && [ $RECURSIVE -eq 1 ]; then
    echo "Error: -r and -R are mutually exclusive (-r = one atomic zfs send -R stream, -R = independent per-dataset sends)" >&2
    exit 1
fi
# A repeat of the SAME mode is refused too. It is harmless today -- but the
# rule is about the declaration, not its effect, and once --recursive=<mode>
# exists a spelling that "collapses harmlessly" is exactly how
# `--recursive=no -r` would quietly become -r.
if [ $RECURSION_DECLS -gt 1 ]; then
    echo "Error: recursion declared more than once ($RECURSION_SPELLINGS). Exactly one declaration per invocation, even when they agree." >&2
    exit 1
fi

if [ $NO_COMPRESS -eq 1 ] && [ $COMPRESSION_SET -eq 1 ]; then
    echo "Error: -N (no compression) contradicts -z/-Z/-g (compress with...) -- pick one." >&2
    exit 1
fi

# Rejected rather than ignored: a filter that silently does nothing is worse
# than one that refuses, because it looks like it worked.
if [ $FLAT_RECURSE -eq 0 ]; then
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        echo "Error: -X needs -R. Under -r the subtree is one atomic 'zfs send -R' stream with nowhere to filter; without recursion, just do not list the dataset." >&2
        exit 1
    fi
    if [ $SKIP_PARENT -eq 1 ]; then
        echo "Error: -S needs -R. There is no parent to skip unless -R is expanding one." >&2
        exit 1
    fi
fi

# Checked here so a bad regex fails before any snapshot is taken, not halfway
# through the expansion. grep exits 2 on a malformed pattern, 1 on "no match" --
# empty input can only ever produce the latter, so >=2 is unambiguously a bad -X.
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
    printf '' | grep -E -- "$_pat" >/dev/null 2>&1
    if [ $? -ge 2 ]; then
        echo "Error: -X '$_pat' is not a valid extended regex (grep -E rejects it)." >&2
        exit 1
    fi
done

# `-q <mode>[,strict|,degrade]`. quiesce_parse_mode (lib-zfs-snap.sh) is the ONE
# parser for both engines, so a qualifier cannot come to mean two things; it
# prints its own message on anything it does not accept, including `no,<qual>`, a
# misspelled qualifier and a repeated one. QUIESCE afterwards holds the BARE
# mode, which is what every quiesce function below already expects, and
# QUIESCE_DEGRADE holds the answer to a failed freeze -- 1 by default since
# 2026-08-27, 0 only when the tier wrote `,strict`.
quiesce_parse_mode "$QUIESCE" || exit 1
QUIESCE="$QUIESCE_MODE"

# -U has to reach the dataset, not just the recv flag: a target created with
# canmount=noauto stays unmounted no matter how it is received, so flipping only
# the recv side would have made -U look supported while doing nothing.
[ $UNMOUNT -eq 0 ] && TARGET_CANMOUNT="on"

# Validated here rather than left to mbuffer: a typo would otherwise surface as
# a dead pipeline mid-transfer, after the snapshot has already been taken.
if [ -n "$BWLIMIT" ]; then
    if [[ ! "$BWLIMIT" =~ ^[0-9]+[bkKmMgG]?$ ]]; then
        echo "Error: -b '$BWLIMIT' -- expected an mbuffer rate: a plain number of BYTES per second, or one with a b/k/M/G suffix (e.g. 2M, 500k). Note BYTES, not bits: a 20 Mbps link is -b 2M." >&2
        exit 1
    fi
    BWLIMIT_FLAG=" -r $BWLIMIT"
fi

# Validated here for the same reason as -b: a typo should fail before any
# snapshot is taken, not silently disable the check (0 or a negative number
# would otherwise mean "always" or "never" by accident rather than by intent).
if [ -n "$THRESHOLD_INTERVALS" ]; then
    if [[ ! "$THRESHOLD_INTERVALS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: -T '$THRESHOLD_INTERVALS' -- expected a positive integer: how many of a dataset's OWN snapshot intervals to tolerate before auto-switching that dataset to -i." >&2
        exit 1
    fi
fi

# Checked here, not left for ssh to report mid-transfer after the snapshot is
# already taken. Readable rather than just present: a key file that exists but
# is world-readable makes ssh silently refuse it with "bad permissions" and no
# earlier warning here would explain that failure at all.
if [ -n "$SSH_KEY" ] && [ ! -r "$SSH_KEY" ]; then
    echo "Error: -K '$SSH_KEY' is not a readable file." >&2
    exit 1
fi

# Warned, not rejected -- deliberately still allowed. Only applies when a NEW
# snapshot is actually about to be created: under -e nothing is created here at
# all, and -e's own no-prefix path (see USE_EXISTING_SNAPSHOT above) exists
# precisely so the newest snapshot on a dataset -- even one made by something
# else entirely, a manual `zfs snapshot`, another tool -- can be picked up and
# sent. That flexibility is the point and stays untouched.
#
# What actually changes: `${MESSAGE}$(date ...)` with MESSAGE empty produces a
# bare timestamp, e.g. "2026-07-26_22-51-22" instead of
# "automated_hourly_2026-07-26_22-51-22". delsnaps.sh matches by literal
# string PREFIX, so a real retention job's pattern (which is never empty) will
# never match it -- confirmed live: such a snapshot survived a real
# `delsnaps.sh -n ... "automated_hourly_"` untouched. It is not deleted by
# anything, ever, unless a rule targets it specifically. Every gen-cron.sh
# generated line is safe from this -- 'prefix' is a required field there -- so
# this is purely an interactive/manual-invocation risk. Verbosity 0: the same
# reasoning as the container-parent warning, a default-verbosity cron run is
# the one place a mistake like this survives unnoticed.
if [ -z "$MESSAGE" ] && [ $USE_EXISTING_SNAPSHOT -ne 1 ]; then
    log 0 "WARNING: no -m given -- the new snapshot will be named with a bare timestamp, no prefix. No pattern-based delsnaps.sh retention job will ever match it, so it accumulates forever unless something specifically targets it."
fi

[ $# -ge 1 ] || { echo "Uzycie: $0 [opcje] DATASETS [REMOTE]" >&2; exit 1; }

# REV-20260804-045 (logical pause): -L names the backup relationship this
# invocation belongs to (the zfs-backup.sh client). If that relationship is
# paused (pause-client wrote the marker), exit HERE -- before the lock, any
# snapshot, hold, ssh or stream work -- with exit 0 so cron stays quiet, and
# a stats status of its own so a paused run can never be read back as a
# fresh successful backup (same pattern as skipped_lock below). A run that
# OMITS -L is deliberately not gated: logical pause is an orchestration
# switch, not a security boundary, and this file does not pretend otherwise.
RELATIONSHIPS_DIR="${RELATIONSHIPS_DIR:-/var/lib/zfs-snapshot-all/relationships}"
if [ -n "$PAIR_LABEL" ]; then
    case "$PAIR_LABEL" in
        *[!A-Za-z0-9._-]*)
            echo "Error: -L '$PAIR_LABEL' -- a relationship label is letters, digits, dot, dash, underscore only." >&2
            exit 1 ;;
    esac
    if [ -f "$RELATIONSHIPS_DIR/$PAIR_LABEL/paused" ]; then
        log 0 "SKIPPED: relationship $PAIR_LABEL is paused (resume: zfs-backup.sh resume-client $PAIR_LABEL)"
        emit_stats "${1:-}" "${2:-}" "skipped_paused" "0"
        exit 0
    fi
fi
###############################################################################
#END 5A

# Resolve the compression level default now that the compressor and -l are both
# known: each tool keeps its OWN default (zstd 3, pigz 6) rather than sharing one
# number, because the scales are not comparable -- zstd 6 measured 4x slower than
# zstd 3 for 4% more ratio, so silently carrying pigz's 6 over to zstd would have
# made the new default look like a regression.
if [ "$COMPRESSOR" = "zstd" ] && [ $COMPRESSION_LEVEL_SET -eq 0 ]; then
    COMPRESSION_LEVEL=3
fi

# Built once, used by both pipeline branches below. -T0 lets zstd use every core
# (pigz is already multi-threaded by default); -c forces stdout so neither tool
# can decide to write a file.
if [ "$COMPRESSOR" = "zstd" ]; then
    COMPRESS_PIPE="zstd -T0 -$COMPRESSION_LEVEL -c"
    DECOMPRESS_PIPE="zstd -d -c"
else
    COMPRESS_PIPE="pigz -$COMPRESSION_LEVEL"
    DECOMPRESS_PIPE="pigz -d"
fi

# Reported where the compressor is CHOSEN, not where it is used. COMPRESS_PIPE
# is invariant across datasets, so this belongs here rather than once per
# transfer -- and it keeps the flag-to-compressor mapping observable even for a
# local run, which no longer reaches the compressed pipeline at all.
[ $COMPRESSION -eq 1 ] && log 3 "COMPRESSOR: $COMPRESS_PIPE"

# Verify required commands are available
if [ $COMPRESSION -eq 1 ] && ! command -v "$COMPRESSOR" >/dev/null; then
    log 0 "Compression requested but $COMPRESSOR is not installed."
    exit 1
fi
if ! command -v mbuffer >/dev/null; then
    log 0 "Required command 'mbuffer' not found. Install mbuffer to proceed."
    exit 1
fi

command -v zfs >/dev/null || { echo "Error: zfs command not found." >&2; exit 1; }
command -v flock >/dev/null || { echo "Error: flock command not found." >&2; exit 1; }

# Built once, used by every ssh invocation below. Default (-k omitted) is
# StrictHostKeyChecking=accept-new: the FIRST connection to a given host trusts
# and records its key (same as "no" ever did), but every connection AFTER that
# is checked against what got recorded -- a host key that changes later (a
# swapped/MITM'd box, a reused IP pointing somewhere else) is refused instead of
# silently trusted again. Only opt into -k on a host where KNOWN_HOSTS_FILE has
# already been populated (e.g. ssh-keyscan) and the fingerprint verified out of
# band -- e.g. a backup host reaching across an untrusted network, unlike the
# trusted-LAN default use case here.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$PORT")
fi

# Fail fast instead of hanging forever. Without these there is NO timeout of any
# kind on the ssh side, and the worst case is not a broken backup -- it is a
# silent one:
#
#   a VPN that stops passing packets without closing the connection (the usual
#   way a NAT'd tunnel dies) leaves ssh waiting indefinitely. The cron job never
#   exits, so it never returns non-zero, so notify-fail.sh never fires. The next
#   hour's run hits the flock, logs "already running", and skips -- and so does
#   every run after it. Backups stop while everything still looks fine, until
#   check-snap-age.sh eventually notices the snapshots going stale hours later.
#
# ConnectTimeout covers a dead peer at connect time; ServerAlive* covers one
# that dies mid-transfer (4 x 15s = ~60s to notice). Together they turn that
# hang into an ordinary failure -- which fires the alert AND leaves a resume
# token, so the next run continues the stream instead of restarting it.
#
# These do NOT fire on a merely slow link: sshd answers keepalives at the
# protocol level regardless of what the payload is doing, so a long `zfs recv`
# txg commit or a saturated 20 Mbps VPN keeps replying and never trips the
# counter.
SSH_OPTS+=(-o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# -c: request a specific cipher (e.g. a faster/weaker one on a CPU-bound link).
# Omitted by default -- let ssh/sshd negotiate. No-op on a local run, since
# SSH_OPTS is built either way but ssh is never actually invoked there.
[ -n "$SSH_CIPHER" ] && SSH_OPTS+=(-c "$SSH_CIPHER")

###############################################################################
#BEGIN 5A2 [SINGLE-INSTANCE LOCK]
###############################################################################
# Prevent two invocations that target the SAME datasets+remote from racing to
# send/recv into the same target dataset (e.g. a manual run overlapping with a
# scheduled cron run). The lock is keyed on the operation target (datasets +
# remote), NOT just the script name, so unrelated jobs (different datasets) run
# concurrently instead of blocking each other. Options (-v, -z, ...) are
# deliberately excluded from the key, so a manual run and a cron run of the same
# target still serialize even if their option formatting differs (-v3 vs -v 3).
# -j/IDENTIFIER is the one deliberate exception: it exists precisely to let a
# second, independent job aimed at the same pair opt OUT of this serialization.
LOCK_KEY=$(printf '%s\0%s\0%s' "$1" "${2:-}" "$IDENTIFIER" | md5sum | cut -d' ' -f1)
# One suffix per RUN, not per dataset (Etap 2.1).
#
# create_snapshot() used to call date(1) itself, so a flat-recursive run over a
# subtree that crossed a second boundary produced DIFFERENT snapshot names for
# datasets belonging to the same run -- and a run that cannot be correlated
# cannot be restored as a coherent set. `atomic` was never affected (one
# `zfs snapshot -r` call) and neither was -q (which already computed one suffix
# before freezing); this closes the remaining case.
#
# Computed once here so there is exactly one definition. The quiesce path below
# consumes this same value rather than deriving its own.
#
# What this does NOT claim: a shared suffix proves a shared RUN, not a shared
# point in time. Under plain flat the snapshots are still taken one after
# another. Restore must report which of the three guarantees applies.
RUN_SUFFIX="$(date '+%Y-%m-%d_%H-%M-%S')"
# The prefix this run WRITES, which is not always the family it MATCHES. They
# differ in exactly one case -- a degraded quiesce, where the created names gain
# `crash_` while every family comparison (-e adoption, -T intermediate counting,
# delsnaps retention, check-snap-age) must keep using the unmarked family the
# operator configured. Prefix matching is what makes the two compatible: the
# marker sits between the family and the timestamp, so `automated_daily_crash_x`
# still belongs to `automated_daily_`.
SNAP_MESSAGE="$MESSAGE"
LOCKDIR="${LOCKDIR:-$ZFS_SNAP_DEFAULT_LOCKDIR}"
[ -d "$LOCKDIR" ] && [ -w "$LOCKDIR" ] || { echo "Error: LOCKDIR '$LOCKDIR' is not a writable directory (create it or point LOCKDIR at one, e.g. LOCKDIR=~/run for a non-root run)." >&2; exit 1; }
LOCKFILE="$LOCKDIR/$(basename "$0").${LOCK_KEY}.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log 0 "Another instance targeting the same datasets is already running (lock: $LOCKFILE) - skipping this run"
    emit_stats "$1" "${2:-}" "skipped_lock" "0"
    exit 0
fi
###############################################################################
#END 5A2

###############################################################################
#BEGIN 5B [MAIN LOGIC]
###############################################################################
DATASETS=$1
REMOTE=${2:-}
IFS=',' read -ra DATASETS <<< "$DATASETS"

# -R: expand each entry into itself + every descendant (source is always
# local here), same `zfs list -r` call syncoid's getchilddatasets makes --
# unlimited depth, no -d cap. `zfs list -r` guarantees a dataset is listed
# before any of its own descendants, so this order is safe to feed straight
# into the per-dataset loop below with no topological sort needed. `sort -u`
# only needs to dedupe overlapping inputs (e.g. "pool/a,pool/a/b" given
# together) -- it cannot break parent-before-child ordering, since a parent
# name is always lexicographically less than "parent/anything".
if [ $FLAT_RECURSE -eq 1 ]; then
    declare -a EXPANDED_DATASETS=()
    for ds in "${DATASETS[@]}"; do
        if ! zfs list -H "$ds" &>/dev/null; then
            log 0 "Source dataset not found: $ds"
            exit 1
        fi
        while IFS= read -r child; do
            [ -z "$child" ] && continue
            if [ $SKIP_PARENT -eq 1 ] && [ "$child" = "$ds" ]; then
                log 2 "Skip-parent (-S): not sending $child itself"
                continue
            fi
            if dataset_excluded "$child"; then
                log 2 "Excluded (-X): $child"
                continue
            fi
            EXPANDED_DATASETS+=("$child")
        done < <(zfs list -H -o name -t filesystem,volume -r "$ds" 2>/dev/null)
    done
    # An empty set here means every candidate was filtered out. Failing loudly
    # is the point: a -X typo or an -S on a childless dataset would otherwise
    # exit 0 having sent nothing, which in cron is indistinguishable from a
    # healthy run and stays invisible until a restore needs the data.
    if [ ${#EXPANDED_DATASETS[@]} -eq 0 ]; then
        log 0 "Flat-recursive (-R): nothing left to send -- -X/-S filtered out every dataset under: ${DATASETS[*]}"
        exit 1
    fi
    mapfile -t DATASETS < <(printf '%s\n' "${EXPANDED_DATASETS[@]}" | sort -u)
    log 1 "Flat-recursive (-R): expanded to ${#DATASETS[@]} dataset(s): ${DATASETS[*]}"
fi

TARGET_BASE=""
REMOTE_USER="root"
REMOTE_HOST=""

if [[ -n "$REMOTE" ]]; then
    if [[ "$REMOTE" == *":"* ]]; then
        IFS=':' read -r remote_part target_base <<< "$REMOTE"

        if [[ "$remote_part" == *"@"* ]]; then
            IFS='@' read -r REMOTE_USER REMOTE_HOST <<< "$remote_part"
        else
            REMOTE_HOST="$remote_part"
        fi

        TARGET_BASE=$(echo "$target_base" | sed 's:^/+::; s:/+$::')
    elif [[ "$REMOTE" == *"@"* ]]; then
        # SYNC mode: bare user@host, no path. A ZFS dataset name can never
        # contain '@' (it is the snapshot separator), so this can never collide
        # with a local-path REMOTE -- unambiguous by construction, no heuristic
        # guessing. TARGET_BASE stays "" so the target resolves to the SAME
        # dataset name on the remote host, not nested under anything.
        # validate_remote_host (called downstream wherever REMOTE_HOST is
        # non-empty) refuses if that host turns out to be this one.
        IFS='@' read -r REMOTE_USER REMOTE_HOST <<< "$REMOTE"
    else
        TARGET_BASE="$REMOTE"
    fi
fi

# Compress by default when the target is remote and the caller said nothing
# about it (-z/-Z/-g absent, -N absent): a plain invocation over ssh is the
# common case this most helps, and zstd -3 measured a net win on both ratio and
# throughput -- see the WHY block at the top of this file. An explicit -z/-Z/-g
# still wins outright (COMPRESSION_SET already true, so this branch does not
# fire), and -N opts all the way back out to the old "off unless asked" default.
# -A, if also given, still gets the final say per dataset (see AUTOTUNE_ACTIVE
# below) -- this only decides what happens in ITS absence.
if [ -n "$REMOTE_HOST" ] && [ $COMPRESSION_SET -eq 0 ] && [ $NO_COMPRESS -eq 0 ]; then
    COMPRESSION=1
    log 1 "Compression: zstd -$COMPRESSION_LEVEL (default for a remote target -- pass -N to disable, -g for pigz, -A to auto-decide per dataset)"
fi

# A local send has no link to save bytes on. The pipeline would be
#   zfs send | zstd -c | mbuffer | zstd -d -c | zfs recv
# i.e. compress and immediately decompress on the same machine, paying for both
# and gaining nothing -- there is no network between the two halves, only a pipe
# in memory. So -z/-Z/-g are dropped here rather than honoured, even though an
# explicit flag normally wins: this is not a preference we are overriding, it is
# an operation with no possible benefit.
#
# Deliberately placed AFTER the REMOTE_HOST parse above and BEFORE the tuning
# block below -- the target is not known any earlier, and the check for the
# compressor being installed must not fail a job that will not compress.
if [ $COMPRESSION -eq 1 ] && [ -z "$REMOTE_HOST" ]; then
    COMPRESSION=0
    [ $COMPRESSION_SET -eq 1 ] && \
        log 1 "Compression ignored: target is local, so compressing and decompressing on this same host would only cost CPU"
fi

# Connection reuse for every ssh call below (one run makes many). Safe to call
# unconditionally: it no-ops for a local run, and ControlMaster=auto falls back
# to an ordinary connection if the master cannot be set up.
tune_ssh_enable "$REMOTE_HOST"
trap 'tune_ssh_close "$REMOTE_USER@$REMOTE_HOST"' EXIT

# -K/-O go at the FRONT of the whole option list, added last so nothing appended
# above (base StrictHostKeyChecking/UserKnownHostsFile/-p, -c, and tune_ssh_enable's
# ControlMaster options) can out-rank them. OpenSSH keeps the FIRST value it sees
# for a given key and ignores later ones -- verified live (`-o Port=2222 -p 22`
# connects on 2222) -- so prepending is what makes an explicit -O actually able
# to override any of those, including disabling multiplexing with
# -O ControlMaster=no.
if [ -n "$SSH_KEY" ] || [ ${#EXTRA_SSH_OPTS[@]} -gt 0 ]; then
    declare -a _front_ssh_opts=()
    [ -n "$SSH_KEY" ] && _front_ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
    for _o in "${EXTRA_SSH_OPTS[@]}"; do _front_ssh_opts+=(-o "$_o"); done
    SSH_OPTS=("${_front_ssh_opts[@]}" "${SSH_OPTS[@]}")
fi

# Catch the container-parent mistake before any work starts: a dataset with
# children, sent without -r/-R, ships nothing but the parent and still reports
# success. Skipped only when a recursion flag is already set (the children are
# covered then); deliberately NOT skipped under -n, since a preview run is the
# best possible moment to be told the job is aimed at an empty container.
# Source is always local in snapsend.sh, hence the empty remote args.
if [ $RECURSIVE -eq 0 ] && [ $FLAT_RECURSE -eq 0 ]; then
    for ds in "${DATASETS[@]}"; do
        warn_if_unrecursed_children "$ds" "" ""
    done
fi

# -A decides compress-or-not from a measurement, PER DATASET -- the decision is
# taken inside the loop below, not here. The compression ratio is a property of
# the data (2.34x on one dataset, 1.29x on another, same host), so deciding once
# from DATASETS[0] would apply one dataset's ratio to all the others. The link
# half of the measurement is still probed once per host and cached, so the extra
# datasets only cost a stream probe each.
#
# Skipped in dry-run: -n must not push 32 MB over the link just to report what
# it would have done.
AUTOTUNE_ACTIVE=0
if [ $AUTOTUNE -eq 1 ] && [ -n "$REMOTE_HOST" ] && [ $DRY_RUN -ne 1 ]; then
    if [ $COMPRESSION_SET -eq 1 ]; then
        log 1 "Link tuning: -A ignored, compression was requested explicitly (-z/-Z/-g) -- honouring your flag"
    elif [ $NO_COMPRESS -eq 1 ]; then
        # Same reasoning as the COMPRESSION_SET branch above: -N is just as
        # explicit a request as -z is, only in the other direction, and -A
        # "fills in a decision you did not make; it never overrules one you
        # did" applies here too. Without this, gen-cron.sh's automatic -A on
        # every remote dst would silently re-enable compression a config
        # explicitly turned off.
        log 1 "Link tuning: -A ignored, compression was explicitly disabled (-N) -- honouring your flag"
    else
        AUTOTUNE_ACTIVE=1
        # The baseline to fall back to. tune_apply leaves COMPRESSION untouched
        # when a probe fails, which without this would mean "keep the PREVIOUS
        # dataset's verdict" rather than "keep what the user asked for".
        COMPRESSION_BASE=$COMPRESSION
    fi
fi

# Quiesce runs HERE, before the transfer loop, and not inside it. Two reasons,
# and both are the whole point of the feature:
#
#   1. A frozen filesystem blocks writes, so the guest is stalled for as long as
#      the window is open. `zfs snapshot` is instantaneous; sending is not (342 GB
#      in one measured case). So the window contains the snapshot and nothing else.
#   2. One guest can own several datasets -- VM 107 has three disks, CT 102 has
#      two. Freezing and thawing per dataset would produce one window each, i.e.
#      three different points in time for one machine, which is exactly the
#      incoherence being prevented. ONE `zfs snapshot` with every dataset of a
#      pool as an argument is atomic (verified on zfs-2.1.9), so all disks land
#      on the same instant.
#
# The snapshots are grouped BY POOL because `zfs snapshot` accepts multiple names
# only within one pool -- a cross-pool list is rejected outright, taking nothing
# at all (see the -q documentation above for the exact message and why it is
# misleading). Splitting per pool costs nothing in coherence: every guest stays
# frozen until the last group is done, so no write can slip between the calls.
#
# Afterwards the normal loop runs with USE_EXISTING_SNAPSHOT=1: the snapshots
# already exist, and -e picks the newest matching -m, which is the one just made.
if [ "$QUIESCE" != "no" ] && [ $DRY_RUN -ne 1 ] && [ $USE_EXISTING_SNAPSHOT -ne 1 ]; then
    # Wired before the first freeze, so an interrupt between freeze and thaw
    # still thaws. The autotune trap is replaced rather than added to, because
    # bash allows one EXIT trap -- both actions live in this one.
    # `|| :` so a failed thaw cannot stop the trap before tune_ssh_close: the
    # failure is already recorded in QUIESCE_THAW_FAILED and shouted at level 0,
    # and losing the ssh master socket on top of it helps nobody. On the normal
    # path the explicit call below has already run and turned that into exit 3.
    trap 'quiesce_thaw_all || :; tune_ssh_close "$REMOTE_USER@$REMOTE_HOST"' EXIT

    # Decide HOW guests are reached -- and refuse here if they cannot be reached
    # at all -- before a single snapshot is taken. Up front on purpose: the
    # answer is the same for every dataset, and discovering it per guest is how
    # "cannot ask" came to be logged as "not running" once per disk while the
    # run reported success.
    # QUIESCE_DEGRADED is the one flag the rest of this block reads. It is set by
    # quiesce_degrade_gate, which only says yes after it has rolled back
    # everything this run created and thawed everything it froze -- so by the
    # time it is 1, the host is in the state it was in before -q was attempted.
    # Every remaining quiesce step is then SKIPPED rather than aborted, and the
    # run continues down the ordinary unquiesced path below.
    quiesce_init "$QUIESCE" || :

    quiesce_snap_suffix="$RUN_SUFFIX"   # one definition, see RUN_SUFFIX above
    # pool -> space-separated snapshot names. A space-joined string is safe as a
    # list here because ZFS dataset names cannot contain whitespace, and bash has
    # no array-of-arrays to hold this properly.
    declare -A QUIESCE_SNAPS_BY_POOL=()
    quiesce_snap_total=0
    for dataset in "${DATASETS[@]}"; do
        [ "$QUIESCE_DEGRADED" -eq 1 ] && break
        # Under -r the guests live in the CHILDREN, not in the named parent --
        # see quiesce_scope. The snapshot list still names the parent, because
        # `zfs snapshot -r parent@snap` covers the tree atomically by itself.
        while IFS= read -r quiesce_ds; do
            [ -n "$quiesce_ds" ] && quiesce_prepare "$quiesce_ds" "$QUIESCE"
            [ "$QUIESCE_DEGRADED" -eq 1 ] && break
        done < <(quiesce_scope "$dataset" "$RECURSIVE")
        # Before the append, not after: a degraded run must not leave a
        # half-built list of quiesced names behind for the pool loop to use.
        [ "$QUIESCE_DEGRADED" -eq 1 ] && break
        quiesce_pool="${dataset%%/*}"
        QUIESCE_SNAPS_BY_POOL[$quiesce_pool]+=" ${dataset}@${SNAP_MESSAGE}${quiesce_snap_suffix}"
        quiesce_snap_total=$((quiesce_snap_total + 1))
    done

    quiesce_recursive_flag=""
    [ $RECURSIVE -eq 1 ] && quiesce_recursive_flag="-r"
    # NOW the VMs are frozen -- after every container flush, after every list has
    # been built, with nothing left to do but the snapshot itself. REV-20260801-024:
    # the old code froze them during the loop above and then spent up to 16
    # seconds flushing containers, by which time Windows had released the freeze
    # on its own and nothing noticed.
    [ "$QUIESCE_DEGRADED" -eq 1 ] || quiesce_freeze_pending || :

    quiesce_snap_failed=0
    if [ "$QUIESCE_DEGRADED" -eq 0 ]; then
        log 1 "Quiesce: taking ${#QUIESCE_SNAPS_BY_POOL[@]} atomic snapshot(s), one per pool, covering $quiesce_snap_total dataset(s)"
        for quiesce_pool in "${!QUIESCE_SNAPS_BY_POOL[@]}"; do
            # BEFORE EVERY POOL, not once before the loop (REV-20260802-029).
            # ZFS is atomic within a pool and there is no way to be atomic across
            # them, so a multi-pool job is N separate commands -- and a slow or
            # blocked first one can eat the whole window. Checking once certified a
            # boundary that the second pool never had.
            if ! quiesce_still_frozen "pool '$quiesce_pool'"; then
                log 0 "Quiesce: refusing to snapshot pool '$quiesce_pool' -- the freeze it was supposed to happen inside is not there (reason above)"
                # The only degrade point outside the library, because this is the
                # only refusal decided here rather than there. The gate is given the
                # recursive flag because pools snapshotted earlier in THIS loop do
                # exist and have to go before anything crash-consistent is taken --
                # REV-20260802-030's rule that the SET is what downstream reads.
                quiesce_degrade_gate "$quiesce_recursive_flag" "the freeze was already gone at the boundary before pool '$quiesce_pool'" && break
                quiesce_abandon_set "$quiesce_recursive_flag" 3
            fi
            # Unquoted on purpose: the value is the space-separated list built above,
            # and each name has to reach zfs as its own argument.
            # shellcheck disable=SC2086
            if ! zfs snapshot $quiesce_recursive_flag ${QUIESCE_SNAPS_BY_POOL[$quiesce_pool]}; then
                log 0 "Quiesce: the atomic snapshot of pool '$quiesce_pool' failed"
                quiesce_snap_failed=1
                break
            fi
            # Recorded only after zfs says it made them, so the ledger can never
            # name something that does not exist.
            # shellcheck disable=SC2206
            QUIESCE_CREATED+=(${QUIESCE_SNAPS_BY_POOL[$quiesce_pool]})
        done
    fi

    if [ "$QUIESCE_DEGRADED" -eq 1 ]; then
        # ONE coherent set, which is why nothing is kept from the attempt above:
        # the gate proved that everything created inside the window is gone and
        # nothing is frozen, so the ordinary loop below now takes the WHOLE set
        # again -- every dataset, none of them quiesced, all of them saying so in
        # their names. No run ever mixes plain and `_crash_` names.
        SNAP_MESSAGE="$(quiesce_crash_message "$MESSAGE")"
        log 0 "Quiesce: continuing WITHOUT quiesce -- the default since 2026-08-27; name ',strict' on this tier to refuse instead. This run's snapshots will be named '${SNAP_MESSAGE}${RUN_SUFFIX}' -- crash-consistent, still part of the '${MESSAGE}' family for retention and monitoring -- and the run will exit 8 so cron reports it instead of calling it a clean backup."
    elif [ $quiesce_snap_failed -eq 0 ]; then
        USE_EXISTING_SNAPSHOT=1
        # Separate from USE_EXISTING_SNAPSHOT because the snapshot-only branch in
        # process_dataset deliberately ignores that one -- see the comment there.
        QUIESCE_SNAPPED=1
    else
        # Failing here rather than falling through matters: silently continuing
        # would take unquiesced snapshots one at a time and report success,
        # which is the one outcome someone who asked for -q must never get
        # without being told.
        log 0 "Quiesce: the atomic snapshot failed -- refusing to fall back to unquiesced per-dataset snapshots"
        quiesce_abandon_set "$quiesce_recursive_flag" 1
    fi
    # A guest left frozen is an outage. Reporting it in the log and exiting 0
    # makes it an outage nobody goes looking for, so it fails the run
    # (REV-20260801-023). The snapshots already taken are valid and are kept --
    # they were made inside the freeze window; what failed is the release.
    if ! quiesce_thaw_all; then
        log 0 "Quiesce: at least one guest could not be thawed (named above) -- failing the run so this is not reported as a clean backup"
        exit 3
    fi
fi

declare -a FAILED_DATASETS=()
for dataset in "${DATASETS[@]}"; do
    if [ $AUTOTUNE_ACTIVE -eq 1 ]; then
        COMPRESSION=$COMPRESSION_BASE
        tune_apply "$REMOTE_USER@$REMOTE_HOST" "$dataset"
    fi
    if [ -n "$TARGET_BASE" ]; then
        tgt_path="${TARGET_BASE}/${dataset}"
    else
        tgt_path="$dataset"
    fi
    tgt_path=$(echo "$tgt_path" | sed 's:///*:/:g; s:^/::')
    
    log 1 "Processing: $dataset => ${REMOTE_HOST:-local}:$tgt_path"
    
    if [ $DRY_RUN -eq 1 ]; then
        process_dataset "$dataset" "$tgt_path" "$REMOTE_USER" "$REMOTE_HOST"
    else
        stats_start=$(date +%s)
        if process_dataset "$dataset" "$tgt_path" "$REMOTE_USER" "$REMOTE_HOST"; then
            emit_stats "$dataset" "$tgt_path" "success" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
        else
            emit_stats "$dataset" "$tgt_path" "failed" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
            FAILED_DATASETS+=("$dataset")
        fi
    fi
done

if [ $DRY_RUN -eq 1 ]; then
    if [ ${#CONFLICT_SNAPSHOTS[@]} -gt 0 ]; then
        printf "%s\n" "${CONFLICT_SNAPSHOTS[@]}" | sort -u
        exit 1
    else
        exit 0
    fi
else
    if [ ${#FAILED_DATASETS[@]} -gt 0 ]; then
        printf "%s\n" "${FAILED_DATASETS[@]}" >&2
        exit 1
    else
        echo "All datasets processed successfully" >&2
        # Reviewer contract condition 6: a real transfer error OUTRANKS the
        # degradation, which is why this is decided last and only on the
        # otherwise-clean path. Returning non-zero before the transfer would
        # have kept the snapshot on the source and lost the very thing
        # `,degrade` exists to preserve -- the durable copy on the far side.
        if [ "${QUIESCE_DEGRADED:-0}" -eq 1 ]; then
            log 0 "Quiesce: the transfer completed, but this run was DEGRADED -- the snapshots it shipped are crash-consistent, not application-consistent, and are named '${SNAP_MESSAGE}${RUN_SUFFIX}'. Exiting 8 so this is reported rather than filed as a clean backup."
            exit 8
        fi
        exit 0
    fi
fi
###############################################################################
#END 5B
###############################################################################
#END 5
