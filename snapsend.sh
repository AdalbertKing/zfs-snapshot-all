#!/bin/bash
set -o pipefail
# snapsend.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Author: [Your Name]
# Refactored: April 04, 2025
# Description: ZFS snapshot manager with force full send
#
# Usage: snapsend.sh [options] DATASETS [REMOTE]
# Options:
#   -m <MESSAGE>      Use MESSAGE as prefix for snapshot name (to label snapshots)
#   -e               Use existing latest snapshot instead of creating a new one
#   -z               Compress the data stream (default compressor: zstd).
#                    Ignored, with a log line, when the target is local: there
#                    is no link between the compressor and the decompressor,
#                    only a pipe on this same host, so it is pure CPU cost.
#   -Z               Compress with zstd explicitly (same as -z; kept for clarity)
#   -g               Compress with pigz instead -- the escape hatch for a host
#                    where zstd is missing or unwanted
#   -l <LEVEL>        Compression level (default: 3 for zstd, 6 for pigz -- each
#                    tool's own default; ranges differ, zstd 1-19 vs pigz 1-9)
#
# The compressor flags are last-one-wins, so appending one to an existing command
# is always well-defined.
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
#   -I               Full history send (send all snapshots if no common base)
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
#     parent and lands somewhere harmless under the target. But `-r` and `-I`
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
#                     of blindly trusting them (StrictHostKeyChecking=no is the
#                     default when -k is omitted, unchanged from prior versions --
#                     only opt into -k if you've already populated FILE, e.g. via
#                     ssh-keyscan, and verified the fingerprint out of band)
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
#                    An explicit -z/-Z/-g WINS: -A then logs that it stood
#                    down and honours your flag. -A fills in a decision you
#                    did not make; it never overrules one you did.
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
#   -i <TAG>          Identifier for this job. Folds TAG into both the lock
#                    key and the per-target bookmark name, so a second,
#                    genuinely independent job aimed at the SAME src/tgt pair
#                    (different retention, different snapshot pattern) gets
#                    its own lock and its own bookmark instead of serializing
#                    behind, or overwriting the incremental base of, the
#                    first job. Omit it (the default) to keep today's
#                    behaviour: all jobs to a given pair share one lock and
#                    one bookmark, so they always serialize.
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
# REMOTE format: [user@]host:dataset_path  (for remote replication).
# If REMOTE is omitted or has no ':', the backup is done locally to the target path.
#
# Examples:
#   snapsend.sh -v1 pool/data backuppool/data_backup
#   snapsend.sh -r pool/data user@backuphost:tank/backups/data
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v2.59'
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
PORT=22
USE_EXISTING_SNAPSHOT=0
# -q: quiesce the Proxmox guest that owns each dataset before snapshotting it.
# "no" (default), "agent" (qemu-guest-agent, VMs), "fs" (host fsfreeze, containers)
# or "auto" (pick per guest). See the QUIESCE section in lib-zfs-snap.sh.
QUIESCE=no
# Set once the quiesce window has actually created the snapshots, so no later
# code path creates a second, unquiesced copy.
QUIESCE_SNAPPED=0
RECURSIVE=0
FLAT_RECURSE=0
# -X: extended regexes; an expanded dataset is dropped if ANY of them matches.
# -S: drop the listed dataset itself, keep its descendants.
declare -a EXCLUDE_PATTERNS=()
SKIP_PARENT=0
DRY_RUN=0
FULL_HISTORY_SEND=0
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
# -o: raw flags appended verbatim to `zfs send` (e.g. "-L -e"). -x: recv-side
# property excludes, one -x per occurrence, accumulated as repeated "-x PROP".
EXTRA_SEND_OPTS=""
RECV_EXCLUDE_FLAGS=""
# -c: ssh cipher spec (ssh -c), appended to SSH_OPTS once built. Empty = let
# ssh/sshd negotiate their own default.
SSH_CIPHER=""
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
        snaps=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name -t snapshot -s creation $depth_option '$dataset' 2>/dev/null | awk -F '@' '{print \$2}'") || return 1
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
            tgt_children=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs list -H -o name -r '$tgt_dataset' 2>/dev/null" | grep -v "^${tgt_dataset}$")
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
        tgt_children=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name -r '$tgt_dataset' 2>/dev/null" | grep -v "^${tgt_dataset}$")
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
validate_remote_host() {
    local remote_user="$1"
    local remote_host="$2"
    
    [ -z "$remote_host" ] && return 0  # Skip check for local transfers
    
    # Get local machine ID (works on systemd-based distros)
    local local_machine_id
    local_machine_id=$(cat /etc/machine-id 2>/dev/null || echo "UNKNOWN")
    
    # Get remote machine ID through SSH
    local remote_machine_id
    remote_machine_id=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
        "cat /etc/machine-id 2>/dev/null || echo 'UNKNOWN'" 2>/dev/null)

    # Core safety check
    if [[ "$local_machine_id" != "UNKNOWN" && "$local_machine_id" == "$remote_machine_id" ]]; then
        log 0 "CRITICAL: Remote host $remote_host has identical machine-id to local system"
        log 0 "This indicates loopback transfer attempt. Aborting."
        exit 1
    fi

    # Fallback check for non-systemd systems
    if [[ "$local_machine_id" == "UNKNOWN" ]]; then
        local local_hostname
        local_hostname=$(hostname -f)
        local remote_hostname
        remote_hostname=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "hostname -f")
        
        if [[ "$local_hostname" == "$remote_hostname" ]]; then
            log 0 "CRITICAL: Remote hostname matches local ($local_hostname)"
            log 0 "Possible loopback transfer. Use local mode instead."
            exit 1
        fi
    fi
}
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
    local tgt_snaps
    if ! target_exists "$tgt_dataset" "$remote_user" "$remote_host"; then
        echo -n "null"
        return 0
    fi
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
    local snapshot_name="${dataset}@${MESSAGE}$(date '+%Y-%m-%d_%H-%M-%S')"
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
    
    local send_args
    local recv_args
    IFS=' ' read -r -a send_args <<< "$send_cmd"
    IFS=' ' read -r -a recv_args <<< "$recv_cmd"
    
    if [ -n "$remote_host" ]; then
        if [ $COMPRESSION -eq 1 ]; then
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "command -v $COMPRESSOR >/dev/null 2>&1"; then
                log 0 "Compression requested but $COMPRESSOR is not installed on remote host $remote_host"
                return 1
            fi
            if ! "${send_args[@]}" | $COMPRESS_PIPE | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer -q -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | $recv_cmd"; then
                return 1
            fi
        else
            if ! "${send_args[@]}" | ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "mbuffer -q -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $recv_cmd"; then
                return 1
            fi
        fi
    else
        # COMPRESSION is forced to 0 for a local target in section 5B, so this
        # branch is not reachable in normal operation. Kept because it is the
        # correct pipeline if compression is ever wanted here; the policy of not
        # wanting it lives in one place, not spread into the transport layer.
        if [ $COMPRESSION -eq 1 ]; then
            if ! "${send_args[@]}" | $COMPRESS_PIPE | mbuffer -q -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! "${send_args[@]}" | mbuffer -q -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | "${recv_args[@]}"; then
                return 1
            fi
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
            attempts=$(read_resume_attempts "$tgt_dataset")
            if [ "$attempts" -ge "$MAX_RESUME_ATTEMPTS" ]; then
                log 1 "Resume failed $attempts times for $tgt_dataset - abandoning stuck state"
                abandon_resume "$tgt_dataset" "$remote_user" "$remote_host"
                reset_resume_attempts "$tgt_dataset"
                # Giving up on this snapshot -- release whatever the original
                # failed attempt held, so it can be pruned like normal again.
                # A fresh $snapshot is about to be resolved below.
                local stuck_snap
                stuck_snap=$(read_inflight_snap "$tgt_dataset")
                [ -n "$stuck_snap" ] && release_snapshot "$stuck_snap" "" ""
                clear_inflight_snap "$tgt_dataset"
                log 1 "Abandoned - falling through to normal transfer logic"
            else
                increment_resume_attempts "$tgt_dataset"
                log 1 "Found resume token for $tgt_dataset - resuming interrupted transfer (attempt $((attempts + 1))/$MAX_RESUME_ATTEMPTS)"
                local resume_recv_flags="-F -s"
                [ $UNMOUNT -eq 1 ] && resume_recv_flags="$resume_recv_flags -u"
                [ -n "$RECV_EXCLUDE_FLAGS" ] && resume_recv_flags="$resume_recv_flags$RECV_EXCLUDE_FLAGS"
                local resume_send_cmd="zfs send -t $resume_token"
                local resume_recv_cmd="zfs recv $resume_recv_flags $tgt_dataset"
                log 4 "RAW RESUME SEND COMMAND: $resume_send_cmd"
                log 4 "RAW RESUME RECV COMMAND: $resume_recv_cmd"
                if transfer_data "$resume_send_cmd" "$resume_recv_cmd" "$remote_host" "$remote_user"; then
                    reset_resume_attempts "$tgt_dataset"
                    STATS_RESUMED="yes"
                    # Resumed stream landed -- release the hold placed on the
                    # original attempt (this run never recomputes $snapshot).
                    local resumed_snap
                    resumed_snap=$(read_inflight_snap "$tgt_dataset")
                    [ -n "$resumed_snap" ] && release_snapshot "$resumed_snap" "" ""
                    clear_inflight_snap "$tgt_dataset"
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
    record_inflight_snap "$tgt_dataset" "$snapshot"

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
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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
            protected_snaps=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$destroy_cmd"
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
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$create_cmd" || {
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
    local tgt_snaps
    if [ $RAW_SEND -eq 1 ] && ! target_exists "$tgt_dataset" "$remote_user" "$remote_host"; then
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
                clear_inflight_snap "$tgt_dataset"
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
        send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS -I ${src_dataset}@${common_snapshot} $snapshot"
    elif [ -n "$bookmark_base" ]; then
        log 1 "No common snapshot, but a bookmark still anchors an incremental: $bookmark_base"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $EXTRA_SEND_OPTS -i $bookmark_base $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history send"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS -R $snapshot"
        else
            log 1 "Performing standard full send"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS $snapshot"
        fi
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
            clear_inflight_snap "$tgt_dataset"
        fi
        return 1
    }

    # Transfer landed -- this snapshot is no longer "in flight", safe to prune
    # on the next delsnaps.sh run like any other.
    release_snapshot "$snapshot" "" ""
    clear_inflight_snap "$tgt_dataset"

    # Under -w the leaf was created by recv, not by us, so it never got
    # canmount=noauto at create time. Reapply it now: it is what keeps the
    # target unmounted across future receives and makes non-root incremental
    # receive possible. Best-effort -- an encrypted target is already unmounted
    # (keystatus=unavailable), so failing here costs nothing immediate.
    if [ $RAW_SEND -eq 1 ]; then
        if [ -n "$remote_host" ]; then
            ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
                "zfs set canmount=$TARGET_CANMOUNT '$tgt_dataset'" 2>/dev/null \
                || log 2 "Could not set canmount=$TARGET_CANMOUNT on $tgt_dataset (needs delegated 'canmount')"
        else
            zfs set canmount=$TARGET_CANMOUNT "$tgt_dataset" 2>/dev/null \
                || log 2 "Could not set canmount=$TARGET_CANMOUNT on $tgt_dataset (needs delegated 'canmount')"
        fi
    fi

    # Refresh the per-target bookmark to what was just sent, regardless of
    # which path got us here (-I, -i bookmark, or FULL) -- see
    # record_send_bookmark in lib-zfs-snap.sh. Source is always local here.
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
while getopts "m:ezZgl:v:rRnIuUfwVp:k:Aq:i:o:x:c:b:FX:S" opt; do
    case $opt in
        m) MESSAGE="$OPTARG";;
        i) IDENTIFIER="$OPTARG";;
        A) AUTOTUNE=1;;
        e) USE_EXISTING_SNAPSHOT=1;;
        q) QUIESCE="$OPTARG";;
        z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        Z) COMPRESSION=1; COMPRESSOR="zstd"; COMPRESSION_SET=1;;
        g) COMPRESSION=1; COMPRESSOR="pigz"; COMPRESSION_SET=1;;
        l) COMPRESSION_LEVEL="$OPTARG"; COMPRESSION_LEVEL_SET=1;;
        v) VERBOSE="$OPTARG";;
        r) RECURSIVE=1;;
        R) FLAT_RECURSE=1;;
        X) EXCLUDE_PATTERNS+=("$OPTARG");;
        S) SKIP_PARENT=1;;
        n) DRY_RUN=1;;
        I) FULL_HISTORY_SEND=1;;
        u) UNMOUNT=1;;   # no-op since v2.54 (this is the default); kept so existing cron lines keep parsing
        U) UNMOUNT=0;;
        f) FORCE_FULL_SEND=1;;
        w) RAW_SEND=1;;
        p) PORT="$OPTARG";;
        k) KNOWN_HOSTS_FILE="$OPTARG";;
        o) EXTRA_SEND_OPTS="$OPTARG";;
        x) RECV_EXCLUDE_FLAGS="$RECV_EXCLUDE_FLAGS -x $OPTARG";;
        c) SSH_CIPHER="$OPTARG";;
        b) BWLIMIT="$OPTARG";;
        F) RECONCILE=1;;
        V) echo "$VERSION"; exit 0;;
        *)
            echo "Blad: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -Z -g -l -v -r -R -X -S -n -I -u -f -w -p -k -A -q -i -o -x -c -b -U -F -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

if [ $FLAT_RECURSE -eq 1 ] && [ $RECURSIVE -eq 1 ]; then
    echo "Error: -r and -R are mutually exclusive (-r = one atomic zfs send -R stream, -R = independent per-dataset sends)" >&2
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

case "$QUIESCE" in
    no|agent|sync|auto) ;;
    fs) echo "Error: -q fs is gone -- ZFS does not implement FIFREEZE, so no ZFS mountpoint can be frozen from the host (measured). Use -q sync for containers, which flushes them instead." >&2; exit 1 ;;
    *) echo "Error: -q '$QUIESCE' -- expected no, agent, sync or auto." >&2; exit 1 ;;
esac

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

[ $# -ge 1 ] || { echo "Uzycie: $0 [opcje] DATASETS [REMOTE]" >&2; exit 1; }
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
# UNCHANGED from prior versions: StrictHostKeyChecking=no. Only opt into -k on
# a host where KNOWN_HOSTS_FILE has already been populated (e.g. ssh-keyscan)
# and the fingerprint verified out of band -- e.g. a backup host reaching
# across an untrusted network, unlike the trusted-LAN default use case here.
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -p "$PORT")
else
    SSH_OPTS=(-o StrictHostKeyChecking=no -p "$PORT")
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
# -i/IDENTIFIER is the one deliberate exception: it exists precisely to let a
# second, independent job aimed at the same pair opt OUT of this serialization.
LOCK_KEY=$(printf '%s\0%s\0%s' "$1" "${2:-}" "$IDENTIFIER" | md5sum | cut -d' ' -f1)
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
    else
        TARGET_BASE="$REMOTE"
    fi
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
    trap 'quiesce_thaw_all; tune_ssh_close "$REMOTE_USER@$REMOTE_HOST"' EXIT

    quiesce_snap_suffix="$(date '+%Y-%m-%d_%H-%M-%S')"
    # pool -> space-separated snapshot names. A space-joined string is safe as a
    # list here because ZFS dataset names cannot contain whitespace, and bash has
    # no array-of-arrays to hold this properly.
    declare -A QUIESCE_SNAPS_BY_POOL=()
    quiesce_snap_total=0
    for dataset in "${DATASETS[@]}"; do
        # Under -r the guests live in the CHILDREN, not in the named parent --
        # see quiesce_scope. The snapshot list still names the parent, because
        # `zfs snapshot -r parent@snap` covers the tree atomically by itself.
        while IFS= read -r quiesce_ds; do
            [ -n "$quiesce_ds" ] && quiesce_freeze "$quiesce_ds" "$QUIESCE"
        done < <(quiesce_scope "$dataset" "$RECURSIVE")
        quiesce_pool="${dataset%%/*}"
        QUIESCE_SNAPS_BY_POOL[$quiesce_pool]+=" ${dataset}@${MESSAGE}${quiesce_snap_suffix}"
        quiesce_snap_total=$((quiesce_snap_total + 1))
    done

    quiesce_recursive_flag=""
    [ $RECURSIVE -eq 1 ] && quiesce_recursive_flag="-r"
    log 1 "Quiesce: taking ${#QUIESCE_SNAPS_BY_POOL[@]} atomic snapshot(s), one per pool, covering $quiesce_snap_total dataset(s)"
    quiesce_snap_failed=0
    for quiesce_pool in "${!QUIESCE_SNAPS_BY_POOL[@]}"; do
        # Unquoted on purpose: the value is the space-separated list built above,
        # and each name has to reach zfs as its own argument.
        # shellcheck disable=SC2086
        if ! zfs snapshot $quiesce_recursive_flag ${QUIESCE_SNAPS_BY_POOL[$quiesce_pool]}; then
            log 0 "Quiesce: the atomic snapshot of pool '$quiesce_pool' failed"
            quiesce_snap_failed=1
            break
        fi
    done

    if [ $quiesce_snap_failed -eq 0 ]; then
        USE_EXISTING_SNAPSHOT=1
        # Separate from USE_EXISTING_SNAPSHOT because the snapshot-only branch in
        # process_dataset deliberately ignores that one -- see the comment there.
        QUIESCE_SNAPPED=1
    else
        # The guests are thawed by the trap either way. Failing here rather than
        # falling through matters: silently continuing would take unquiesced
        # snapshots one at a time and report success, which is the one outcome
        # someone who asked for -q must never get without being told.
        #
        # Any pool that already succeeded keeps its snapshots: they were taken
        # inside the freeze window and are perfectly valid, they match the
        # configured retention pattern like any other, and destroying them would
        # be throwing away good backups because a DIFFERENT pool failed.
        log 0 "Quiesce: the atomic snapshot failed -- refusing to fall back to unquiesced per-dataset snapshots"
        quiesce_thaw_all
        exit 1
    fi
    quiesce_thaw_all
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
        exit 0
    fi
fi
###############################################################################
#END 5B
###############################################################################
#END 5
