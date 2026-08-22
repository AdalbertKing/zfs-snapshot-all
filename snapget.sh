#!/bin/bash
set -o pipefail
# snapget.sh (run with -V for version; see git log for full changelog) - twin of snapsend.sh
# ------------------------------------------------------------------------------
# Author: Wojciech Król <lurk@lurk.com.pl>
# Refactored: March 17, 2026
# Description: ZFS snapshot manager with force full pull
#
# Usage: snapget.sh [options] REMOTE_DATASETS [LOCAL_BASE]
# Options:
#   -m <MESSAGE>      Use MESSAGE as prefix for snapshot name (to label snapshots)
#   -e               Use existing latest snapshot on source instead of creating a new one
#   -z               Compress the data stream (default compressor: zstd). Redundant
#                    against a remote source -- see "COMPRESSION DEFAULT" below,
#                    this is now ON by default there. Ignored, with a log line,
#                    when the source is local: there is no link between the
#                    compressor and the decompressor, only a pipe on this same
#                    host, so it is pure CPU cost.
#   -Z               Compress with zstd explicitly (same as -z; kept for clarity)
#   -g               Compress with pigz instead -- the escape hatch for a host
#                    where zstd is missing or unwanted
#   -N               No compression. Opts out of the default-on behaviour against
#                    a remote source (see below). No-op against a local source,
#                    which never compresses regardless of any flag. Contradicts
#                    -z/-Z/-g (pick one).
#   -l <LEVEL>        Compression level (default: 3 for zstd, 6 for pigz -- each
#                    tool's own default; ranges differ, zstd 1-19 vs pigz 1-9)
#
# The compressor flags are last-one-wins, so appending one to an existing command
# is always well-defined.
#
# COMPRESSION DEFAULT: ON (zstd -3) whenever the source is remote and neither
# -z/-Z/-g nor -N was given -- new since v2.58 (mirrors snapsend.sh v2.64). A
# plain `-N` restores the old off-by-default behaviour for one invocation. -A,
# if given, still gets the final per-dataset say over whatever this picks.
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
#                    each DATASET into itself plus every descendant of the
#                    REMOTE source (`zfs list -r`, same call syncoid's
#                    getchilddatasets makes, run over ssh when the source is
#                    remote) BEFORE the main loop runs, then pulls each one as
#                    its own independent, non-recursive job -- same walk depth
#                    as -r (unlimited, ZFS itself has no -d cap), but the unit
#                    of work is one dataset instead of the whole subtree in
#                    one stream. A failing child does not abort its siblings
#                    (it lands in the existing FAILED_DATASETS report, same as
#                    today's comma-separated DATASETS already behave) and,
#                    unlike -r, a GUID collision on one child only forces a
#                    full re-pull of THAT child -- -F is a no-op under -R
#                    because the collision -F exists for cannot arise (see -F
#                    below). Mutually exclusive with -r.
#
#   Long spellings (Stage 2.3), exactly equivalent to the short flags:
#     --recursive=atomic   = -r
#     --recursive=flat     = -R
#     --recursive=no       = neither, stated explicitly
#   Exactly ONE recursion declaration per invocation. A second is refused even
#   when it agrees, and even when the two use different spellings -- so
#   `--recursive=no -r` is an error, not a silent -r.
#   -X <REGEX>        Under -R only: drop every expanded dataset whose full name
#                    ON THE SOURCE matches REGEX -- an extended regex as
#                    `grep -E` reads it, unanchored, so anchor it yourself with
#                    ^ / $ when you mean the whole name. Repeatable; a dataset
#                    goes if ANY -X hits. This is syncoid's --exclude with the
#                    same semantics. The name tested is the full source-side
#                    path exactly as given in REMOTE_DATASETS (or discovered
#                    under -R), i.e. what `zfs list` prints on the source host
#                    -- not the local name this script writes to, so one regex
#                    reads the same here as it does in the snapsend.sh command
#                    going the other way.
#                    Excluding a dataset does NOT exclude its descendants -- but
#                    mind the anchor: unanchored, a pattern matching a parent
#                    matches its children too, since a child's full name
#                    contains the parent's. See the longer note in snapsend.sh.
#   -S               Under -R only: skip-parent -- pull the descendants of each
#                    DATASET but never the DATASET itself. syncoid's
#                    --skip-parent.
#
# Both are -R-only, and rejected otherwise rather than ignored. Under -r the
# subtree is one atomic stream with nowhere to filter, and without recursion at
# all there is nothing to exclude FROM. If the filters leave nothing to pull,
# that is an error, not a silent success.
#   -n               Dry-run mode (show conflicting snapshots without receiving)
#   -H               Full history receive when no common base exists at all.
#                    Was -I; renamed to free -i for its real zfs meaning below.
#                    Mirrors snapsend.sh's -H.
#   -i               When a common snapshot IS found, pull only the DIFF to
#                    the newest one (`zfs send -i`) instead of every
#                    intermediate snapshot in between (`-I`, the default --
#                    no flag needed for that, it already happens). Mirrors
#                    snapsend.sh's -i exactly -- see there for the full
#                    reasoning, the live-verified -r interaction, and why -R
#                    needs no special-casing. No-op (logged at level 2) when
#                    there is no common snapshot to begin with.
#   -T <N>            Catch-up threshold: auto-switch THIS dataset to -i when
#                    more than N of its OWN snapshot intervals have elapsed
#                    since the common base. Mirrors snapsend.sh's -T exactly
#                    -- see there for the full reasoning (why relative to the
#                    dataset's own cadence, not an absolute time/count) and
#                    how the interval is measured. An explicit -i still wins
#                    outright. Omitted (the default) disables the check.
#   -u               Accepted and ignored. `zfs recv -u` (do not mount what was
#                    just received) is the DEFAULT since v2.49; this flag stays
#                    so the cron lines that already pass it keep parsing. Use -U
#                    to get mounting back.
#   -U               Mount the target after receive -- the opt-out from the
#                    default above. Wanted when the target is meant to be browsed
#                    (a restore staging area, an archive somebody reads from),
#                    not when it is pure replication storage. See the long note
#                    in snapsend.sh for the full reasoning; it applies verbatim
#                    here, and doubly so, because snapget's target is ALWAYS
#                    local -- an unwanted mount lands on this machine.
#   -f               Force full pull (destroy local target data and receive full snapshot)
#   -w               Raw send (zfs send -w on the REMOTE source): pull records
#                    exactly as they sit on disk. For an ENCRYPTED source this
#                    pulls ciphertext, so this host never needs the key -- and the
#                    source does not need it loaded either (a non-raw send of an
#                    encrypted dataset refuses with "dataset key must be loaded").
#                    A raw-received target comes up keystatus=unavailable and
#                    mounted=no; no -u needed. For an UNENCRYPTED source -w is
#                    effectively a no-op: verified on zfs-2.1.9 that raw and
#                    non-raw streams interoperate freely in both directions there.
#                    Rawness must NOT change mid-stream on an encrypted target.
#   -p <PORT>         SSH port to use (default: 22)
#   -c <CIPHER_SPEC>   SSH cipher(s) to request (ssh -c), e.g. "aes128-gcm@openssh.com"
#                    for a faster/weaker cipher on a CPU-bound link. Default (omitted)
#                    is whatever ssh/sshd negotiate on their own. No-op on a local run
#                    -- ssh is never invoked there.
#   -K <FILE>         SSH private key to authenticate with (ssh -i, plus -o
#                    IdentitiesOnly=yes so an agent holding OTHER keys can't get
#                    this account locked out by a max-auth-tries limit). Not
#                    "-i" -- that means skip-intermediates here (see above).
#   -O <SSH_OPTION>    Extra "ssh -o NAME=VALUE", verbatim, e.g.
#                    -O "ProxyJump=bastion". Repeatable. Syncoid's --sshoption.
#                    Placed FIRST on the ssh command line so it can override
#                    -p/-k/-c or even turn off multiplexing with
#                    -O ControlMaster=no -- OpenSSH keeps the first value it
#                    sees for a given key. No validation.
#   -b <RATE>         Cap the transfer rate. RATE is an mbuffer rate spec: a plain
#                    number of BYTES per second, or one with a b/k/M/G suffix
#                    (1024-based, mbuffer's own parser). BYTES, not bits -- a
#                    20 Mbps link is `-b 2M`. Default (omitted) is no limit.
#
#                    Applied as `mbuffer -r` to the mbuffer that is ALREADY in
#                    every pipeline, so this adds no process and no memory. In
#                    snapget that mbuffer is always LOCAL (the target side is),
#                    sitting immediately after ssh and BEFORE any decompression
#                    -- so the bytes it limits are the bytes actually crossing
#                    the link, compressed or not. Same position relative to the
#                    stream as snapsend's, which is on the remote side there.
#
#                    The mechanism is backpressure: mbuffer drains the stream at
#                    RATE, the socket stops being read, TCP closes its window and
#                    the remote sender blocks. Buffers ahead of it mean the first
#                    moments can outrun the limit before it settles -- tens of
#                    MB, irrelevant on any transfer worth throttling.
#
#                    On a LOCAL pull there is no link, but the limit still
#                    applies and still throttles pool-to-pool I/O.
#
#                    Interacts with -A on purpose: a limit makes the link slower
#                    than the probe measured, which makes compression MORE
#                    worthwhile, so -A decides against min(measured, -b).
#   -L <LABEL>        The backup relationship (zfs-backup.sh client) this run
#                    belongs to. If that relationship is paused
#                    (zfs-backup.sh pause-client), the run exits 0 with
#                    "SKIPPED: relationship LABEL is paused" BEFORE any lock,
#                    snapshot, hold, ssh or stream work, and logs the distinct
#                    stats status skipped_paused (never a fake success).
#                    Written into generated cron lines by gen-cron.sh's
#                    pair_label field; a run that omits -L is NOT gated --
#                    logical pause is orchestration, not a security boundary.
#   -k <FILE>         Verify remote host keys against this known_hosts file instead
#                     of the default (StrictHostKeyChecking=accept-new when -k is
#                     omitted: trust-on-first-use, then refuse if the key ever
#                     changes -- only opt into -k if you've already populated
#                     FILE, e.g. via ssh-keyscan, and verified the fingerprint
#                     out of band)
#   -o "<FLAGS>"       Extra raw flags appended verbatim to `zfs send` on the
#                    REMOTE source (e.g. -o "-L -e" for large_block/embed_data).
#                    Passed through with no validation -- same trust level as
#                    every other flag here. Skipped on the resume path: `zfs
#                    send -t <token>` already fixes the stream's format.
#   -x <PROPERTY>      Exclude PROPERTY from the local receive side (`zfs recv
#                    -x`). Repeatable. Applied on BOTH the normal and the
#                    resumed receive -- unlike -o, this is receive-side state
#                    and a resume token carries no property excludes of its own.
#   -F               Reconcile before pulling (recursively, under -r): if a
#                    CHILD dataset has a snapshot named like the incremental
#                    base but under a DIFFERENT GUID (independently created,
#                    not the same snapshot despite the name -- the one shape
#                    of divergence that actually breaks a recursive pull),
#                    upgrade THIS run to a full re-pull of the whole subtree,
#                    same as -f. Deliberately narrower than what `-n`
#                    reports: a target-only snapshot that does NOT collide by
#                    name (e.g. older history a shorter-retention source has
#                    since pruned, common on an archive target) is normal and
#                    left alone -- flagging that too would force an expensive
#                    full re-pull on every single run against such a target.
#                    Full-tree re-pull on a real collision is not a shortcut,
#                    it's required: `zfs send -R -I` decides full-vs-
#                    incremental PER CHILD from the SOURCE's own snapshot
#                    history, not from what survives on the target, so
#                    merely destroying the colliding snapshot still leaves
#                    that child an incremental component with nothing valid
#                    to land on (probed live on snapsend.sh: recv tears the
#                    child dataset down instead of just erroring). Opt-in;
#                    combine with `-n` first, though note `-n`'s report is
#                    broader than what `-F` actually acts on.
#   -A               Auto-tune the link: measure it, then decide whether -z is
#                    worth it for THIS data. Opt-in, remote transfers only, and
#                    it can flip nothing but compression. Decided separately for
#                    EACH dataset, since the ratio is a property of the data.
#                    Cached 7 days -- link speed per host, ratio per dataset;
#                    ZFS_SNAP_RETUNE=1 forces a re-probe.
#
#                    In snapget the SOURCE is remote and its compressor runs
#                    there (see transfer_data), so the ratio is measured on the
#                    far side -- probing locally would measure the wrong
#                    machine's disk and CPU.
#   -q <MODE>        Quiesce the Proxmox guest that owns each SOURCE dataset
#                    before snapshotting it: "no" (default), "agent"
#                    (qemu-guest-agent freeze, VMs), "sync" (`pct exec <id> --
#                    sync`, containers -- a FLUSH, not a freeze) or "auto".
#                    Turns a crash-consistent backup into a filesystem- (and,
#                    with an /etc/qemu/fsfreeze-hook, application-) consistent
#                    one.
#
#                    THE GUEST IS ON THE FAR SIDE, so unlike snapsend.sh's -q
#                    the entire freeze -> atomic snapshot -> thaw sequence runs
#                    in ONE remote invocation, carrying its own EXIT trap and a
#                    detached deadman timer. That shape is not an optimisation:
#                    it is what makes the thaw survive a dropped connection, a
#                    killed local job or a rebooted collector. A guest left
#                    frozen is an outage, i.e. strictly worse than never having
#                    quiesced. See the REMOTE QUIESCE section in
#                    lib-zfs-snap.sh.
#
#                    NEEDS PRIVILEGE ON THE SOURCE -- measured, not assumed:
#                    `qm`/`pct` talk to the PVE cluster IPC, and a delegated
#                    pull account cannot even read
#                    /etc/pve/qemu-server/<id>.conf. Two ways to satisfy it:
#                    pair with --as=root, or -- keeping the delegated account
#                    -- run `deploy.sh --join <package> --allow-quiesce` on the
#                    SOURCE host, which installs zfs-quiesce-helper and a sudo
#                    rule for that one script. With neither, this FAILS LOUDLY
#                    rather than quietly taking the crash-consistent snapshot
#                    the flag was meant to prevent.
#
#                    Ignored with -e (nothing is being created to quiesce) and
#                    with -n. Rejected for a LOCAL source: that is snapsend.sh's
#                    job, and this script has no local-freeze path.
#   -Q <SECONDS>     How long the remote deadman waits before thawing
#                    unconditionally (default 120, minimum 10). Only relevant
#                    with -q. Raise it for a guest whose agent is unusually slow
#                    to answer a freeze.
#
#                    Decides ONE thing on purpose: measured 2026-07-22,
#                    compress-or-not is worth ~29%, the zstd level ~2%, and
#                    mbuffer -m nothing at all. Ratio is measured on a real
#                    `zfs send` sample, never assumed (2.34x vs 1.29x on two
#                    datasets of the same host). Needs an existing snapshot to
#                    sample. Every failure path leaves your settings untouched.
#
#                    An explicit -z/-Z/-g or -N WINS: -A stands down and honours it.
#   -j <TAG>          Identifier for this job. Folds TAG into both the lock
#                    key and the per-target bookmark name, so a second,
#                    genuinely independent job aimed at the SAME src/tgt pair
#                    gets its own lock and its own bookmark instead of
#                    serializing behind, or overwriting the incremental base
#                    of, the first job. Omit it (the default) to keep today's
#                    behaviour: all jobs to a given pair share one lock and
#                    one bookmark. (Was -i; moved to free that letter for its
#                    literal zfs meaning -- see -i above.)
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
# REMOTE_DATASETS / LOCAL_BASE (v2.61+, flipped from earlier versions -- see
# git log if you remember the old `DATASETS [REMOTE]` shape): snapget.sh
# mirrors snapsend.sh exactly, just on the opposite side. The rule is one
# sentence: whichever side is READ is given LITERALLY (with a host: prefix
# when it is not this machine); whichever side is WRITTEN gets an optional
# BASE for relocation (never a host: prefix, because it is always this
# machine). For a pull, the READ side is remote -- so REMOTE_DATASETS is a
# comma list of the REAL, existing names on the source, each written
# [user@]host:dataset_path (exactly what `zfs list` shows there, no base
# arithmetic). All entries must share the same [user@]host. LOCAL_BASE is a
# plain local path -- never a host, never a ':' -- prepended to each entry's
# dataset_path to build where it lands here.
#
#   [user@]host:dataset_path[,[user@]host:dataset_path...]   REMOTE_DATASETS,
#                              always required. A bare dataset_path with no
#                              ':' at all (no host) pulls from a LOCAL source
#                              instead -- no ssh, used for local-to-local
#                              relocation/testing.
#   LOCAL_BASE                 Optional. Omit it for SYNC mode: the local
#                              name is then IDENTICAL to the remote one.
#                              Refused if the resolved host is THIS host
#                              (validate_remote_host, same guard as
#                              snapsend.sh).
#
# Examples:
#   snapget.sh -v1 backuphost:pool/data backuppool/data_backup
#     -> creates backuppool/data_backup/pool/data here
#   snapget.sh -r sourcehost:tank/data                    # sync: identical local name
#   snapget.sh pve2:rpool/data/v1,pve2:rpool/data/v2 hdd/backups/kopia-pve1
#     -> creates hdd/backups/kopia-pve1/rpool/data/v1 and .../v2 here
#
# THE TWIN: snapget.sh (pull) and snapsend.sh (push) share TWELVE function names.
#
# Merging the two engines was considered and REJECTED on 2026-08-04. What is
# left after the easy sharing is DIVERGENCE, not duplication: pull reads
# remotely and writes locally, push does the reverse, so the safety checks sit
# on opposite sides. Eight of the twelve carry that direction with IDENTICAL
# signatures and parameter names, so a merge needs a direction argument whose
# only failure mode is silent -- and it fails OPEN on common-base detection.
# test/snapsend/run.sh (which covers both scripts) is LOCAL MODE ONLY by design,
# so with empty remote_user/remote_host both branches collapse to the same call:
# the suite that would catch a reversed direction structurally cannot.
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
VERSION='v2.70'
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
# -b: cap the transfer rate. Applied as `mbuffer -r` to the mbuffer already in
# every pipeline, so this adds no process. BWLIMIT holds the raw spec as given
# (also read by tune_apply in lib-zfs-snap.sh, which caps the probed link speed
# with it); BWLIMIT_FLAG is the ready-made " -r <rate>" fragment, empty when no
# limit was asked for. Mirrors snapsend.sh.
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
        out=$(ssh "${SSH_OPTS[@]}" "$ruser@$rhost" "$dry" 2>/dev/null) || return 0
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
# -q: quiesce the Proxmox guest that owns each SOURCE dataset before
# snapshotting it. Unlike snapsend.sh's -q, the guest is on the REMOTE host
# here, so the whole freeze/snapshot/thaw runs in one remote invocation --
# see the REMOTE QUIESCE section in lib-zfs-snap.sh for why, and for the
# measured privilege constraint (it needs root, or a sudo rule, on the source).
QUIESCE=no
# How long the remote deadman waits before thawing unconditionally. Generous
# next to a snapshot (instantaneous) but far short of any real outage: a guest
# frozen this long is already a problem, and thawing it is always the safer
# side to err on. Overridable with -Q for a source whose agent is unusually
# slow to respond.
QUIESCE_DEADMAN=120
# Set once the remote quiesce window has actually created the snapshots, so no
# later code path creates a second, unquiesced copy. Mirrors snapsend.sh.
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
# -X: extended regexes, matched against the full source-side dataset name; an
# expanded dataset is dropped if ANY of them matches. -S: drop the listed
# dataset itself, keep its descendants. Mirrors snapsend.sh.
declare -a EXCLUDE_PATTERNS=()
SKIP_PARENT=0
DRY_RUN=0
# -H: full history receive when no common base exists at all (was -I). Mirrors
# snapsend.sh.
FULL_HISTORY_SEND=0
# -i: when a common snapshot is found, pull only the diff to newest (real
# `zfs send -i`) instead of every intermediate (`-I`, the default). Mirrors
# snapsend.sh.
SKIP_INTERMEDIATES=0
# -T: auto-switch to skip-intermediates when more than this many of the
# dataset's own snapshot intervals have elapsed since the common base. Empty
# (the default) disables the check. Mirrors snapsend.sh.
THRESHOLD_INTERVALS=""
# `zfs recv -u`: do not mount what was just received. ON BY DEFAULT since v2.49
# -- mirrors snapsend.sh v2.54, see the long note in its header. -U turns
# mounting back on; -u is still accepted and is now a no-op, so every existing
# cron line that passes it keeps working untouched.
UNMOUNT=1
# canmount for targets this script creates -- see snapsend.sh for the full note.
# Resolved from UNMOUNT after argument parsing so -U reaches the dataset, not
# just the recv flag.
TARGET_CANMOUNT="noauto"
FORCE_FULL_SEND=0
RAW_SEND=0
# -A: measure the link and the data, then decide whether compressing is worth
# it. Opt-in, and it can only ever flip COMPRESSION.
AUTOTUNE=0
# Set by -z/-Z/-g. Lets -A tell "user said nothing about compression" apart from
# "user explicitly asked for it" -- auto-tuning may fill the first case in, but
# must never silently overrule the second.
COMPRESSION_SET=0
# -N: opt out of the on-by-default compression for a remote source (see the
# REMOTE_HOST block in section 5B). Meaningless for a local source, which never
# compresses regardless.
NO_COMPRESS=0
# -o: raw flags appended verbatim to the remote `zfs send` (e.g. "-L -e"). -x:
# local recv-side property excludes, one -x per occurrence, accumulated as
# repeated "-x PROP".
EXTRA_SEND_OPTS=""
RECV_EXCLUDE_FLAGS=""
# -c: ssh cipher spec (ssh -c), appended to SSH_OPTS once built. Empty = let
# ssh/sshd negotiate their own default.
SSH_CIPHER=""
SSH_KEY=""
declare -a EXTRA_SSH_OPTS=()
# -F: reconcile (destroy target-only snapshots) before the real pull.
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
# with snapsend.sh and with the bookmark-fallback code that already needed
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
        # The remote command ends in a pipe, so ssh hands back awk's status: a
        # dataset that does not exist yields rc 0 and an empty list (awk had
        # nothing to read), and a NONZERO rc here therefore means ssh itself
        # failed. Callers of this function collect its output into an array and
        # drop the status, so without this line an unreachable host looks
        # exactly like a dataset with no snapshots. Control flow is unchanged --
        # the point is that the run says which one it was.
        snaps=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
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

    local src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host"))
    local tgt_snaps=($(get_sorted_snapshots "$tgt_dataset"))

    for tgt_snap in "${tgt_snaps[@]}"; do
        if [[ ! " ${src_snaps[*]} " == *" ${tgt_snap} "* ]] || ! validate_snapshot "$src_dataset" "$tgt_dataset" "$tgt_snap" "$remote_user" "$remote_host"; then
            CONFLICT_SNAPSHOTS+=("${tgt_dataset}@${tgt_snap}")
        fi
    done

    if [ $RECURSIVE -eq 1 ]; then
        local tgt_children
        tgt_children=$(zfs list -H -o name -r "$tgt_dataset" | grep -v "^${tgt_dataset}$")

        for tgt_child in $tgt_children; do
            local child_name="${tgt_child##*/}"
            local src_child="${src_dataset}/${child_name}"

            # "The source child is gone" makes every snapshot on the target
            # child a conflict. An unreachable host must NOT produce that
            # verdict: it would report a whole healthy target subtree as
            # conflicting, and this list is what -n shows the operator before
            # they reach for -f. So case 2 skips the child instead, having
            # already logged that the answer is unknown.
            probe_dataset "$src_child" "$remote_user" "$remote_host" "source child dataset"
            case $? in
                1)
                    local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child"))
                    for snap in "${tgt_child_snaps[@]}"; do
                        CONFLICT_SNAPSHOTS+=("${tgt_child}@${snap}")
                    done
                    continue
                    ;;
                2) continue ;;
            esac

            local child_common
            child_common=$(find_common_snapshot "$src_child" "$tgt_child" "$remote_user" "$remote_host")

            if [[ "$child_common" == "null" ]] || [[ -n "$parent_common" && "$child_common" != "$parent_common" ]]; then
                local tgt_child_snaps=($(get_sorted_snapshots "$tgt_child"))
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

    # Target is always local in snapget.sh.
    local tgt_children
    tgt_children=$(zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | grep -v "^${tgt_dataset}$")

    local tgt_child
    for tgt_child in $tgt_children; do
        local child_name="${tgt_child##*/}"
        local src_child="${src_dataset}/${child_name}"

        local tgt_guid
        tgt_guid=$(get_snapshot_guid "$tgt_child" "$base_name")
        if [ -n "$tgt_guid" ]; then
            local src_guid
            src_guid=$(get_snapshot_guid "$src_child" "$base_name" "$remote_user" "$remote_host")
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
# validate_remote_host() now lives in lib-zfs-snap.sh (shared with snapsend.sh,
# was byte-identical here) with a per-remote cache -- see the comment there.
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
    local src_guid
    src_guid=$(get_snapshot_guid "$src_dataset" "$snapshot" "$remote_user" "$remote_host")
    local tgt_guid
    tgt_guid=$(get_snapshot_guid "$tgt_dataset" "$snapshot")

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
    src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host")) || return 1

    # A target that does not exist has no snapshots and therefore no common
    # base -- "null", not an error. This is reachable under -w, where the leaf
    # is created by recv rather than pre-created, so the first pull legitimately
    # runs against a target that is not there yet.
    local tgt_snaps
    if ! target_exists "$tgt_dataset"; then
        echo -n "null"
        return 0
    fi
    tgt_snaps=($(get_sorted_snapshots "$tgt_dataset")) || return 1

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
    done <<< "$(get_snapshot_guids "$tgt_dataset")"

    local src_names=() src_guids=()
    while IFS=$'\t' read -r _n _g; do
        [ -z "$_n" ] && continue
        src_names+=("$_n"); src_guids+=("$_g")
    done <<< "$(get_snapshot_guids "$src_dataset" "$remote_user" "$remote_host")"

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
    local remote_user="$2"
    local remote_host="$3"
    local snapshot_name="${dataset}@${MESSAGE}${RUN_SUFFIX}"
    local recursive_flag=""
    [ $RECURSIVE -eq 1 ] && recursive_flag="-r"

    log 1 "Creating new source snapshot: $snapshot_name"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs snapshot $recursive_flag '$snapshot_name'" || return 1
    else
        zfs snapshot $recursive_flag "$snapshot_name" || return 1
    fi
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
# at the top). In snapget.sh the target is always local, so they're always
# called with an empty remote_host/user -- see the header comment there.
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

    announce_transfer_size "$send_cmd" "$remote_host" "$remote_user"

    local recv_args
    IFS=' ' read -r -a recv_args <<< "$recv_cmd"

    if [ -n "$remote_host" ]; then
        if [ $COMPRESSION -eq 1 ]; then
            if [ "$(remote_has_compressor "$remote_user" "$remote_host" "$COMPRESSOR")" != "yes" ]; then
                log 0 "Compression requested but $COMPRESSOR is not installed on remote host $remote_host"
                return 1
            fi
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$send_cmd | $COMPRESS_PIPE" | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "$send_cmd" | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | "${recv_args[@]}"; then
                return 1
            fi
        fi
    else
        local send_args
        IFS=' ' read -r -a send_args <<< "$send_cmd"
        # COMPRESSION is forced to 0 for a local source in section 5B, so this
        # branch is not reachable in normal operation. Kept because it is the
        # correct pipeline if compression is ever wanted here; the policy of not
        # wanting it lives in one place, not spread into the transport layer.
        if [ $COMPRESSION -eq 1 ]; then
            if ! "${send_args[@]}" | $COMPRESS_PIPE | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | $DECOMPRESS_PIPE | "${recv_args[@]}"; then
                return 1
            fi
        else
            if ! "${send_args[@]}" | mbuffer $MBUFFER_QUIET -s $BUFFER_SIZE -m $MEMORY$BWLIMIT_FLAG | "${recv_args[@]}"; then
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
# REV-20260802-033 slice 8 / ENROLMENT-AGREED-2026-08-02 U7-U8: "target is a
# live guest's disk" is checked separately from, and BEFORE, the written@
# divergence test below -- a live guest keeps writing, so a written@=0 read
# taken a moment earlier proves nothing about the instant `zfs recv -F`
# actually runs (the measured pve0/pve1 vsql2 case in that document is
# exactly this race, currently caught only by ZFS's own "dataset is busy" on
# an open zvol, which is not a safety property -- it disappears the moment
# the guest is stopped, the target is a container subvol instead of a zvol,
# or the guest lives on another cluster node).
#
# Reuses quiesce_guest_id/quiesce_guest_status (lib-zfs-snap.sh) exactly as
# the quiesce path does -- same dataset-name convention, same local-node-only
# reach (a guest whose config lives on another cluster node reads as
# kind=absent here, same as it does for quiesce; cluster-membership of the
# PEER is a separate, enrolment-time check in the wrapper, not this one).
# Deliberately fail-closed: if QUIESCE_VIA was never initialised (no -q on
# this run) and this account is not root, `qm`/`pct status` fails with a
# permission error and quiesce_guest_status returns non-zero -- treated here
# as "cannot prove it is safe", not as "must be stopped".
guest_disk_is_live() {   # <dataset> -> 0 if it IS a live guest disk, 1 otherwise
    local ds="$1" id status running
    id=$(quiesce_guest_id "$ds") || return 1
    if ! status=$(quiesce_guest_status "$id"); then
        log 0 "Refusing '$ds': it names guest $id, but this account could not determine whether that guest is running (no root, and no quiesce-helper access). Not assuming it is safe. Grant with: deploy.sh --backup-user=\$(id -un) --allow-quiesce, or run as root."
        return 0
    fi
    running=$(quiesce_field "$status" running)
    if [ "$running" = yes ]; then
        log 0 "Refusing '$ds': it is the disk of guest $id, which is currently RUNNING. An incremental receive here would discard whatever it has written since the last snapshot this pull knows about -- always true for a live dataset, not just on a bad day (see U7 in ENROLMENT-AGREED-2026-08-02.md)."
        return 0
    fi
    return 1
}

process_dataset() {
    local src_dataset="$1"
    local tgt_dataset="$2"
    local remote_user="$3"
    local remote_host="$4"
    STATS_RESUMED="no"
    # Local shadow: -F reconciliation below may escalate THIS run to a full
    # pull by flipping this, same as -f, without touching the global (which
    # would leak into other datasets in a multi-dataset invocation).
    local FORCE_FULL_SEND=$FORCE_FULL_SEND
    # Remembers whether -f itself was passed, before -F below can flip the
    # shadow above -- used only to keep the "(-f)" log message honest.
    local user_requested_full=$FORCE_FULL_SEND
    # One-time handover of state files written under the pre-v3 naming, before
    # anything reads them. See adopt_legacy_state in lib-zfs-snap.sh.
    adopt_legacy_state "$tgt_dataset" "$src_dataset"
    # Local shadow: -T's auto-check below may flip THIS dataset to
    # skip-intermediates without touching the global. Mirrors snapsend.sh.
    local SKIP_INTERMEDIATES=$SKIP_INTERMEDIATES
    validate_remote_host "$remote_user" "$remote_host"
    [ -n "$remote_host" ] && check_pool_health "$src_dataset" "$remote_user" "$remote_host"
    check_pool_health "$tgt_dataset" "" ""
    log 3 "================================================"
    log 3 "PROCESSING DATASET:"
    log 3 "SRC: $src_dataset"
    log 3 "TGT: $tgt_dataset"
    log 3 "REMOTE: $remote_user@$remote_host"
    log 3 "================================================"

    if [ $DRY_RUN -eq 1 ]; then
        local common_snapshot
        common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        find_conflicting_snapshots "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$common_snapshot"
        # A machine-readable verdict for callers that must know whether the
        # next real run would be incremental WITHOUT parsing prose
        # (REV-20260730-005 F2). zfs-backup.sh's verify-endpoint used to infer
        # it from the ABSENCE of the words "full send", which is a negative
        # heuristic over a log message: a reworded log line, a new planner
        # branch or any other rc=0 path with no such phrase would have been
        # read as "incremental confirmed". This is the positive form of the
        # same question, and it is the very fact the transfer itself branches
        # on -- $common_snapshot is what decides `zfs send -I base` versus a
        # full stream, so nothing can drift between the plan and the run.
        # Always exactly one line per dataset, on stdout, prefixed so it can
        # never be confused with logging (which goes to stderr).
        if [ -n "$common_snapshot" ]; then
            printf 'PLAN=INCREMENTAL base=%s src=%s tgt=%s\n' "$common_snapshot" "$src_dataset" "$tgt_dataset"
        else
            printf 'PLAN=FULL base=- src=%s tgt=%s\n' "$src_dataset" "$tgt_dataset"
        fi
        return 0
    fi

    if [[ "$src_dataset" == "$tgt_dataset" && -z "$remote_host" ]]; then
        log 1 "Running in local snapshot-only mode"
        snapshot=$(create_snapshot "$src_dataset" "$remote_user" "$remote_host") || return 1
        log 1 "Successfully created local snapshot: $snapshot"
        return 0
    fi

    # 1 = the peer answered and the dataset is not there; 2 = we never got an
    # answer (probe_dataset has already said why, in those words). Reporting a
    # connection failure as a missing dataset is the bug this shape exists to
    # prevent -- see the SSH FAILURE DISCRIMINATION block in lib-zfs-snap.sh.
    probe_dataset "$src_dataset" "$remote_user" "$remote_host" "source dataset"
    case $? in
        1)
            if [ -n "$remote_host" ]; then
                log 0 "Source dataset not found on remote host: $src_dataset"
            else
                log 0 "Source dataset not found: $src_dataset"
            fi
            return 1
            ;;
        2) return 1 ;;
    esac

    # Checked here, before anything is created, snapshotted or (under -f)
    # destroyed: a rawness mismatch can never succeed, so a doomed run must not
    # leave side effects behind. Skipped under -f, which destroys the target and
    # so has no seeding left to conflict with. Orientation is mirrored vs
    # snapsend.sh: here the SOURCE may be remote and the target is always local.
    if [ $FORCE_FULL_SEND -ne 1 ]; then
        check_raw_compatibility "$src_dataset" "$remote_user" "$remote_host" \
                                "$tgt_dataset" "" "" \
                                "$RAW_SEND" || return 1
    fi

    if [ $FORCE_FULL_SEND -ne 1 ]; then
        # target is always local in snapget.sh -- pass empty remote_user/host
        local resume_token
        resume_token=$(get_resume_token "$tgt_dataset" "" "")
        if [ -n "$resume_token" ]; then
            local attempts
            attempts=$(read_resume_attempts "$tgt_dataset" "$src_dataset")
            if [ "$attempts" -ge "$MAX_RESUME_ATTEMPTS" ]; then
                log 1 "Resume failed $attempts times for $tgt_dataset - abandoning stuck state"
                abandon_resume "$tgt_dataset" "" ""
                reset_resume_attempts "$tgt_dataset" "$src_dataset"
                # Giving up on this snapshot -- release whatever the original
                # failed attempt held on the (possibly remote) source, so it
                # can be pruned like normal again. A fresh $snapshot is about
                # to be resolved below.
                local stuck_snap
                stuck_snap=$(read_inflight_snap "$tgt_dataset" "$src_dataset")
                [ -n "$stuck_snap" ] && release_snapshot "$stuck_snap" "$remote_user" "$remote_host"
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
                    [ -n "$resumed_snap" ] && release_snapshot "$resumed_snap" "$remote_user" "$remote_host"
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
    # to receive onto; probed live on snapsend.sh: recv tears the child down
    # instead of just erroring). The only fix ZFS actually supports in one
    # command is upgrading this whole run to what -f already does: destroy
    # everything on target, recreate, full re-pull -- so that's what this
    # does, via the local FORCE_FULL_SEND shadow declared at the top of this
    # function, reusing -f's existing (already-guarded, already-tested)
    # machinery rather than half-reimplementing it. Target is always local
    # in snapget.sh, so the collision scan never needs ssh.
    #
    # Deliberately narrower than find_conflicting_snapshots/-n: a target-only
    # snapshot that does NOT collide by name is normal and harmless (longer
    # local retention -- see the pve0 archive job, where -n always "fails"
    # for exactly that reason, by design). Triggering on that broader
    # definition would force an expensive full re-pull on EVERY run against
    # any target with different retention.
    if [ $RECONCILE -eq 1 ] && [ $RECURSIVE -eq 1 ] && [ $FORCE_FULL_SEND -ne 1 ]; then
        local reconcile_common
        reconcile_common=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
        NAME_COLLISIONS=()
        find_recursive_name_collisions "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host" "$reconcile_common"
        if [ ${#NAME_COLLISIONS[@]} -gt 0 ]; then
            log 1 "Reconciling (-F): name collision(s) with a mismatched GUID would block the incremental pull:"
            printf '%s\n' "${NAME_COLLISIONS[@]}" | sort -u | while IFS= read -r collision; do log 1 "  $collision"; done
            log 1 "Upgrading this run to a full re-pull of the whole subtree (same as -f)"
            FORCE_FULL_SEND=1
        fi
        NAME_COLLISIONS=()
    fi

    # Work out WHAT is going to be pulled before touching the target in any
    # way. This ordering is load-bearing, not cosmetic: everything below either
    # creates the target dataset or, under -f, destroys it outright. Resolving
    # the source snapshot afterwards meant a run that could never succeed still
    # got that far -- `-f -e -m <prefix that matches nothing>` destroyed every
    # snapshot and all data on the local target and only THEN reported "no
    # source snapshots matching message". Same fix as snapsend.sh; keep the two
    # in step.
    if [ "$USE_EXISTING_SNAPSHOT" -eq 1 ]; then
        local src_snaps
        src_snaps=($(get_sorted_snapshots "$src_dataset" "$remote_user" "$remote_host")) || return 1
        if [ ${#src_snaps[@]} -eq 0 ]; then
            if [ $FLAT_RECURSE -eq 1 ]; then
                # Under -R the request is a SUBTREE and -e's family defines
                # membership in it: a member with no family -- the empty path
                # containers recv -p creates, and equally a bare root whose
                # family lives only in its descendants -- is scaffolding, not
                # a failure. The aggregate guard below still fails the run
                # when NOTHING in the whole expansion had a family.
                log 1 "No family on '$src_dataset' -- scaffolding under -R -e, skipped"
                ADOPT_SKIPPED=$((ADOPT_SKIPPED+1))
                return 0
            fi
            log 0 "No source snapshots found"
            return 1
        fi

        if [ -n "$MESSAGE" ]; then
            src_snaps=($(printf "%s\n" "${src_snaps[@]}" | grep "^$MESSAGE"))
            if [ ${#src_snaps[@]} -eq 0 ]; then
                if [ $FLAT_RECURSE -eq 1 ]; then
                    log 1 "No '$MESSAGE*' family on '$src_dataset' -- scaffolding under -R -e, skipped"
                    ADOPT_SKIPPED=$((ADOPT_SKIPPED+1))
                    return 0
                fi
                log 0 "No source snapshots matching message: $MESSAGE"
                return 1
            fi
        fi

        local latest_snap="${src_snaps[-1]}"
        snapshot="${src_dataset}@${latest_snap}"
    else
        snapshot=$(create_snapshot "$src_dataset" "$remote_user" "$remote_host") || return 1
        latest_snap="${snapshot##*@}"
    fi

    # Hold it for the whole transfer window, including across a resume that
    # spans later cron runs -- see HOLD-BASED PROTECTION in lib-zfs-snap.sh.
    # Source may be remote here. Released on the success path below and in
    # the resume branch above; deliberately left held on failure so a stuck
    # resume keeps its source snapshot until it either succeeds or is
    # abandoned.
    hold_snapshot "$snapshot" "$remote_user" "$remote_host"
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
        # The target is always local here, so this never goes over ssh.
        ensure_target_ancestors "$create_target" "" "" || {
            log 0 "Failed to create the ancestor path of $create_target"
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
            return 1
        }
        zfs list "$create_target" >/dev/null 2>&1 || zfs create -o canmount=$TARGET_CANMOUNT "$create_target" || {
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"; return 1; }
    fi

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        if [ $user_requested_full -eq 1 ]; then
            log 1 "Force full pull activated (-f)"
        else
            log 1 "Full re-pull activated (-F reconciliation)"
        fi

        local protected_snaps
        protected_snaps=$(zfs list -t snapshot -H -o name -r "$tgt_dataset" 2>/dev/null | grep -E '@(__replicate_|__migration__|vzdump)' || true)
        if [ -n "$protected_snaps" ]; then
            log 0 "Refusing force full pull: $tgt_dataset (or a descendant) holds snapshot(s) reserved by Proxmox VE (replication/migration/vzdump):"
            log 0 "$protected_snaps"
            log 0 "This target looks like it's managed by Proxmox VE outside this tool -- force full pull would destroy that state and break replication/migration/backup. Remove the conflicting job/snapshots yourself first if this is intentional."
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
            return 1
        fi

        log 2 "Destroying all snapshots and data on local target dataset"

        log 4 "EXECUTING DESTROY LOCALLY"
        zfs list -H -o name -r "$tgt_dataset" 2>/dev/null | tac | xargs -I{} sh -c 'zfs destroy -R "$@" 2>/dev/null || true' -- {} || true

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
        ensure_target_ancestors "$tgt_dataset" "" "" || {
            log 0 "Failed to create the ancestor path of $tgt_dataset"
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
            return 1
        }
        zfs create -o canmount=$TARGET_CANMOUNT "$tgt_dataset" || {
            log 0 "Hint: -f destroys and recreates the target, which needs to mount it. On Linux, non-root users cannot mount/unmount even with full 'zfs allow' delegation -- -f requires root."
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
            return 1
        }
        fi
    fi

    # Under -w the leaf target is deliberately NOT pre-created (recv builds it
    # from the raw stream), so on a first pull it does not exist yet and
    # get_sorted_snapshots fails -- `zfs list` on a missing dataset exits 1 and
    # pipefail propagates it. That is not an error here, it is the first-pull
    # case: a target that does not exist simply has no snapshots. Every other
    # mode still pre-creates the target, so a failure there remains a real one
    # and is still reported. Target is always local in snapget.sh.
    local tgt_snaps
    if [ $RAW_SEND -eq 1 ] && ! target_exists "$tgt_dataset"; then
        log 2 "Target does not exist yet -- raw receive will create it"
        tgt_snaps=()
    else
        tgt_snaps=($(get_sorted_snapshots "$tgt_dataset")) || {
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"; return 1; }
    fi

    log 3 "LATEST SOURCE SNAPSHOT: ${snapshot}"
    log 3 "EXISTING TARGET SNAPSHOTS:"
    for snap in "${tgt_snaps[@]}"; do
        log 3 "  ${tgt_dataset}@${snap}"
    done

    if [ $FORCE_FULL_SEND -eq 1 ]; then
        local common_snapshot="null"
    else
        if [[ " ${tgt_snaps[*]} " == *" ${latest_snap} "* ]]; then
            if validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
                log 1 "Snapshot already exists in target - skipping"
                release_snapshot "$snapshot" "$remote_user" "$remote_host"
                clear_inflight_snap "$tgt_dataset" "$src_dataset"
                return 0
            else
                log 1 "Snapshot exists but timestamps differ - forcing full pull"
                local common_snapshot="null"
            fi
        else
            local common_snapshot
            common_snapshot=$(find_common_snapshot "$src_dataset" "$tgt_dataset" "$remote_user" "$remote_host")
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
    # send_cmd is interpolated into the remote ssh command string (and only
    # word-split locally), so an empty flag var collapses harmlessly either way --
    # same reason recursive_send_flag can be empty.
    local raw_send_flag=""
    [ $RAW_SEND -eq 1 ] && raw_send_flag="-w"

    # Mirrors snapsend.sh, with the sides swapped: here the SOURCE is remote and
    # the TARGET pool is local, so the arguments are the other way round. Getting
    # them backwards would ask the wrong machine about its pool and show up only
    # as an unexplained fallback to plain sends.
    local comp_send_flag
    comp_send_flag=$(compressed_send_flag "$src_dataset" "$tgt_dataset" ""                         "${remote_host:+${remote_user}@${remote_host}}")
    [ -n "$comp_send_flag" ] && log 3 "Compressed send: using zfs send -c"

    local bookmark_base=""
    if [[ "$common_snapshot" == "null" ]] && [ $RECURSIVE -ne 1 ]; then
        # No common snapshot survives on either end -- before giving up to a
        # FULL pull, check for a bookmark left by a prior run (see
        # lib-zfs-snap.sh). Target is always local in snapget.sh, so the head
        # GUID lookup gets no remote args; the source (where bookmarks live)
        # may be remote, mirrored the same way find_common_snapshot already is.
        local tgt_head_guid=""
        if [ ${#tgt_snaps[@]} -gt 0 ]; then
            tgt_head_guid=$(get_snapshot_guid "$tgt_dataset" "${tgt_snaps[-1]}")
        fi
        bookmark_base=$(find_bookmark_base "$src_dataset" "$tgt_head_guid" "$remote_user" "$remote_host")
    fi

    # REV-20260802-033 slice 8 / U7: -F used to be unconditional below,
    # regardless of whether this run created "$tgt_dataset" or found it
    # already there. Fine for continuing this tool's OWN copy -- nothing
    # else ever writes into a path this pull created -- but sync mode
    # addresses the source's own path directly, so "already there" can mean
    # a pre-existing, independently-live dataset. Skipped entirely when
    # FORCE_FULL_SEND is already 1: that branch already destroyed and
    # recreated the target above, an explicit human decision (-f), and -F on
    # a freshly emptied target is a no-op.
    local recv_force_flag="-F"
    if [ $FORCE_FULL_SEND -ne 1 ] && target_exists "$tgt_dataset"; then
        if guest_disk_is_live "$tgt_dataset"; then
            abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
            return 1
        fi
        # REV-20260804-037/038 campaign: found live -- target_exists() alone
        # was treated as "has history that -F might silently roll back", but
        # the non-raw path above ALWAYS pre-creates $tgt_dataset (canmount=
        # noauto, empty, zero snapshots) specifically so a non-root receive
        # has somewhere to write into. That pre-created leaf made
        # target_exists() true on every first-ever seed, which then found no
        # recv_base (nothing to be common WITH yet) and refused outright --
        # the tool's own preparation step defeating its next one.
        #
        # `-F` stays SET here (recv_force_flag keeps its "-F" default from
        # above), not cleared: `zfs receive` itself refuses to write a new
        # filesystem stream into an already-existing destination without
        # -F, even one that is completely empty -- confirmed live ("cannot
        # receive new filesystem stream: ... exists / must specify -F to
        # overwrite it") clearing it produced exactly that error. The
        # distinction this whole gate exists for is not "-F yes or no", it
        # is "is -F safe here" -- and with zero snapshots there is nothing
        # for -F to roll back, so it is. A target WITH actual snapshots
        # still needs the recv_base/written@ reasoning below; guest_disk_is_live
        # above already covers the other danger this guard exists for (a
        # live, unsnapshotted guest disk occupying the same path in sync
        # mode) regardless of snapshot count.
        if [ ${#tgt_snaps[@]} -eq 0 ]; then
            :
        else
            # The snapshot this receive would resume from: the common one if a
            # real name/GUID match was found, else the target's own current head
            # if a bookmark rescued the incremental (same snapshot the bookmark
            # search matched by GUID) -- either way, the point after which
            # anything written to the target is about to be silently rolled back
            # by -F.
            local recv_base=""
            if [[ "$common_snapshot" != "null" ]]; then
                # REV-20260804-037/038 campaign: found live -- find_common_snapshot
                # returns the SOURCE-side name (what `zfs send -i` needs), but a
                # name-mismatched GUID match (the target's snapshot was renamed
                # since the last sync -- exactly the case that fallback exists
                # for) means the TARGET has no snapshot by that name at all.
                # written@ below is a TARGET-side query, so querying
                # written@$common_snapshot against a name the target does not
                # have returned "-" (property not applicable), which is neither
                # "0" nor empty and so read as "diverged, refuse" every time.
                # If the name matches on the target directly, use it as before;
                # otherwise re-resolve the TARGET's own name for that same GUID.
                if printf '%s\n' "${tgt_snaps[@]}" | grep -qFx -- "$common_snapshot"; then
                    recv_base="$common_snapshot"
                else
                    local common_guid
                    common_guid=$(get_snapshot_guid "$src_dataset" "$common_snapshot" "$remote_user" "$remote_host")
                    if [ -n "$common_guid" ]; then
                        local tname
                        for tname in "${tgt_snaps[@]}"; do
                            [ "$(get_snapshot_guid "$tgt_dataset" "$tname")" = "$common_guid" ] && { recv_base="$tname"; break; }
                        done
                    fi
                fi
            elif [ -n "$bookmark_base" ] && [ ${#tgt_snaps[@]} -gt 0 ]; then
                recv_base="${tgt_snaps[-1]}"
            fi
            if [ -z "$recv_base" ]; then
                log 0 "Refusing: '$tgt_dataset' already exists and shares no common snapshot (by GUID) with '$src_dataset' -- a full resend needs '-f', which destroys and recreates the target. That is a decision for a human to make explicitly, not this run's default."
                abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
                return 1
            fi
            # REV-20260804-037/038 campaign: found live -- `zfs get` without
            # -p human-formats size properties ("0B", "1.5K"), but this
            # compares against the plain string "0". A genuinely undiverged
            # target ("0B") therefore never matched "0" and was refused
            # anyway -- the exact false-positive shape of the bug this whole
            # gate exists to avoid, just triggered by string formatting
            # instead of a real divergence. -p forces raw, parsable bytes.
            local written; written=$(zfs get -Hp -o value "written@${recv_base}" "$tgt_dataset" 2>/dev/null)
            if [ "$written" != "0" ]; then
                if [ -z "$written" ]; then
                    log 0 "Refusing: could not determine how much '$tgt_dataset' has diverged from '@${recv_base}' (written@ query failed) -- not assuming it is safe for -F to roll back."
                else
                    log 0 "Refusing: '$tgt_dataset' has $written written since the common snapshot '@${recv_base}' -- something wrote to this target after the point this pull would resume from, and -F would silently discard it. If this is a live guest disk or otherwise not exclusively owned by this pull, investigate. Force explicitly with -f if the divergence is expected and safe to lose."
                fi
                abort_held_snapshot "$snapshot" "$tgt_dataset" "$remote_user" "$remote_host"
                return 1
            fi
            recv_force_flag=""
        fi
    elif [ $FORCE_FULL_SEND -ne 1 ]; then
        # target does not exist yet: nothing to roll back, -F would be a
        # harmless no-op here -- dropped anyway so this run never carries a
        # flag it does not need.
        recv_force_flag=""
    fi

    if [[ "$common_snapshot" != "null" ]]; then
        log 1 "Found valid common snapshot: ${src_dataset}@${common_snapshot}"
        # -T: mirrors snapsend.sh exactly, source may be remote here so both
        # remote args are passed through (empty for a local source).
        if [ $SKIP_INTERMEDIATES -eq 0 ] && [ -n "$THRESHOLD_INTERVALS" ]; then
            if [ "$(auto_skip_intermediates "$src_dataset" "$MESSAGE" "$common_snapshot" "$THRESHOLD_INTERVALS" "$remote_user" "$remote_host")" = "yes" ]; then
                log 1 "Catch-up (-T $THRESHOLD_INTERVALS): more than $THRESHOLD_INTERVALS of this dataset's own snapshot intervals have elapsed since the common base -- pulling only the diff to newest"
                SKIP_INTERMEDIATES=1
            fi
        fi
        # -i (SKIP_INTERMEDIATES): the diff to newest only -- literal
        # `zfs send -i` in place of the default `-I`. Mirrors snapsend.sh
        # exactly -- see there for the live-verified -r/-R reasoning.
        local incr_flag="-I"
        [ $SKIP_INTERMEDIATES -eq 1 ] && incr_flag="-i"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS $incr_flag ${src_dataset}@${common_snapshot} $snapshot"
    elif [ -n "$bookmark_base" ]; then
        log 1 "No common snapshot, but a bookmark still anchors an incremental: $bookmark_base"
        [ $SKIP_INTERMEDIATES -eq 1 ] && log 2 "-i requested but already sending a single diff via bookmark -- nothing to skip"
        send_cmd="zfs send $raw_send_flag $comp_send_flag $EXTRA_SEND_OPTS -i $bookmark_base $snapshot"
    else
        if [ $FULL_HISTORY_SEND -eq 1 ]; then
            log 1 "Performing full history pull"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS -R $snapshot"
        else
            log 1 "Performing standard full pull"
            send_cmd="zfs send $raw_send_flag $comp_send_flag $recursive_send_flag $EXTRA_SEND_OPTS $snapshot"
        fi
        [ $SKIP_INTERMEDIATES -eq 1 ] && log 2 "-i requested but there is no common snapshot to diff against -- nothing to skip"
    fi

    # -s makes ZFS SAVE partial receive state on interruption (and expose a
    # receive_resume_token) instead of rolling it back -- this is the
    # precondition for the resumable-transfer logic above to ever fire.
    # $recv_force_flag (computed above) is "-F" only when continuing this
    # pull's own prior work on an unwritten target, or after an explicit -f.
    local recv_flags="$recv_force_flag -s"
    [ $UNMOUNT -eq 1 ] && recv_flags="$recv_flags -u"
    [ -n "$RECV_EXCLUDE_FLAGS" ] && recv_flags="$recv_flags$RECV_EXCLUDE_FLAGS"
    local recv_cmd="zfs recv $recv_flags $tgt_dataset"

    log 4 "RAW REMOTE ZFS SEND COMMAND: $send_cmd"
    log 4 "RAW LOCAL ZFS RECV COMMAND: $recv_cmd"

    log 1 "Starting transfer..."
    transfer_data "$send_cmd" "$recv_cmd" "$remote_host" "$remote_user" || {
        log 0 "Transfer failed"
        [ $FORCE_FULL_SEND -eq 1 ] && log 0 "Hint: a full pull/-f-style receive does a forced rollback, which needs to mount/unmount the (local) target. On Linux, non-root users cannot do that even with full 'zfs allow' delegation -- if this failed on a mount/unmount permission error, this run needed root."
        # Only keep the hold if it is actually still useful: a
        # receive_resume_token means the resume branch above will need this
        # exact source snapshot on a later run. Without one (e.g. zfs recv
        # refused outright, before writing anything -- "destination has
        # snapshots" and similar), nothing will ever come back to release it,
        # so release now instead of stranding it un-prunable forever. Target
        # is always local in snapget.sh.
        if [ -z "$(get_resume_token "$tgt_dataset" "" "")" ]; then
            release_snapshot "$snapshot" "$remote_user" "$remote_host"
            clear_inflight_snap "$tgt_dataset" "$src_dataset"
        fi
        return 1
    }

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
    # BOUNDARY, stated rather than hidden: under -r the subtree travels as ONE
    # stream and this proves the ROOT landed. The descendants rode the same
    # stream and cannot have arrived separately, but they are not individually
    # checked here. Under -R each dataset is its own job and each is proven.
    if ! validate_snapshot "$src_dataset" "$tgt_dataset" "$latest_snap" "$remote_user" "$remote_host"; then
        log 0 "VERIFY FAILED: ${tgt_dataset}@${latest_snap} is not on the target with the source's GUID -- the transfer reported success but the snapshot cannot be confirmed. Treating this dataset as FAILED rather than reporting a backup that may not exist."
        return 1
    fi
    log 2 "Verified: ${tgt_dataset}@${latest_snap} carries the source's GUID"

    # Transfer landed -- this snapshot is no longer "in flight", safe to prune
    # on the next delsnaps.sh run like any other.
    release_snapshot "$snapshot" "$remote_user" "$remote_host"
    clear_inflight_snap "$tgt_dataset" "$src_dataset"

    # Under -w the leaf was created by recv, not by us, so it never got
    # canmount=noauto at create time. Reapply it now: it is what keeps the
    # target unmounted across future receives and makes non-root incremental
    # receive possible. Best-effort -- an encrypted target is already unmounted
    # (keystatus=unavailable), so failing here costs nothing immediate. Target
    # is always local in snapget.sh.
    if [ $RAW_SEND -eq 1 ]; then
        zfs set canmount=$TARGET_CANMOUNT "$tgt_dataset" 2>/dev/null \
            || log 2 "Could not set canmount=$TARGET_CANMOUNT on $tgt_dataset (needs delegated 'canmount')"
    fi

    # Same as snapsend.sh: under -r the descendants come out of the recursive
    # stream carrying the SOURCE's canmount, so the no-mount default would stop
    # at the leaf. Whole received subtree, filesystems only, skipped under -U.
    if [ $RECURSIVE -eq 1 ] && [ "$TARGET_CANMOUNT" = "noauto" ]; then
        zfs list -H -o name -t filesystem -r "$tgt_dataset" 2>/dev/null | while IFS= read -r d; do
            zfs set canmount=noauto "$d" 2>/dev/null
        done || log 2 "Could not set canmount=noauto across $tgt_dataset (needs delegated 'canmount')"
    fi

    # Refresh the per-target bookmark to what was just sent, regardless of
    # which path got us here (common-base incremental, bookmark incremental,
    # or FULL) -- see record_send_bookmark in lib-zfs-snap.sh. Source may be
    # remote here.
    [ $RECURSIVE -ne 1 ] && record_send_bookmark "$src_dataset" "$latest_snap" "$tgt_dataset" "$remote_user" "$remote_host" "$IDENTIFIER"

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
OPTSTRING="m:ezZgNl:v:rRniHj:uUfwVp:k:AT:o:x:c:b:FX:SK:O:q:Q:L:"

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

while getopts "m:ezZgNl:v:rRniHj:uUfwVp:k:AT:o:x:c:b:FX:SK:O:q:Q:L:" opt; do
    case $opt in
        m) MESSAGE="$OPTARG";;
        j) IDENTIFIER="$OPTARG";;
        A) AUTOTUNE=1;;
        q) QUIESCE="$OPTARG";;
        Q) QUIESCE_DEADMAN="$OPTARG";;
        e) USE_EXISTING_SNAPSHOT=1;;
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
        u) UNMOUNT=1;;   # no-op since v2.49 (this is the default); kept so existing cron lines keep parsing
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
            echo "Błąd: Nieznana opcja -$OPTARG" >&2
            echo "Dozwolone opcje: -m -e -z -Z -g -N -l -v -r -R -X -S -n -H -i -T -u -f -w -p -k -A -j -o -x -c -b -K -O -U -F -L -V" >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

if [ $NO_COMPRESS -eq 1 ] && [ $COMPRESSION_SET -eq 1 ]; then
    echo "Error: -N (no compression) contradicts -z/-Z/-g (compress with...) -- pick one." >&2
    exit 1
fi

# Two different modes keep their own message: it is the mistake people actually
# make, and the useful answer is what the two modes MEAN, not how many were
# given.
if [ $FLAT_RECURSE -eq 1 ] && [ $RECURSIVE -eq 1 ]; then
    echo "Error: -r and -R are mutually exclusive (-r = one atomic zfs recv -R stream, -R = independent per-dataset pulls)" >&2
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

# Rejected rather than ignored -- mirrors snapsend.sh: a filter that silently
# does nothing is worse than one that refuses, because it looks like it worked.
if [ $FLAT_RECURSE -eq 0 ]; then
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        echo "Error: -X needs -R. Under -r the subtree is one atomic stream with nowhere to filter; without recursion, just do not list the dataset." >&2
        exit 1
    fi
    if [ $SKIP_PARENT -eq 1 ]; then
        echo "Error: -S needs -R. There is no parent to skip unless -R is expanding one." >&2
        exit 1
    fi
fi

# grep exits 2 on a malformed pattern, 1 on "no match" -- empty input can only
# produce the latter, so >=2 is unambiguously a bad -X. Checked before any work.
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
    printf '' | grep -E -- "$_pat" >/dev/null 2>&1
    if [ $? -ge 2 ]; then
        echo "Error: -X '$_pat' is not a valid extended regex (grep -E rejects it)." >&2
        exit 1
    fi
done

# -U has to reach the dataset, not just the recv flag: a target created with
# canmount=noauto stays unmounted no matter how it is received, so flipping only
# the recv side would have made -U look supported while doing nothing.
[ $UNMOUNT -eq 0 ] && TARGET_CANMOUNT="on"

# Validated here rather than left to mbuffer: a typo would otherwise surface as
# a dead pipeline mid-transfer, after the source snapshot has already been taken.
if [ -n "$BWLIMIT" ]; then
    if [[ ! "$BWLIMIT" =~ ^[0-9]+[bkKmMgG]?$ ]]; then
        echo "Error: -b '$BWLIMIT' -- expected an mbuffer rate: a plain number of BYTES per second, or one with a b/k/M/G suffix (e.g. 2M, 500k). Note BYTES, not bits: a 20 Mbps link is -b 2M." >&2
        exit 1
    fi
    BWLIMIT_FLAG=" -r $BWLIMIT"
fi

# Validated here for the same reason as -b. Mirrors snapsend.sh.
if [ -n "$THRESHOLD_INTERVALS" ]; then
    if [[ ! "$THRESHOLD_INTERVALS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: -T '$THRESHOLD_INTERVALS' -- expected a positive integer: how many of a dataset's OWN snapshot intervals to tolerate before auto-switching that dataset to -i." >&2
        exit 1
    fi
fi

# Checked here, not left for ssh to report mid-transfer. Readable rather than
# just present: a world-readable key file makes ssh silently refuse it with
# "bad permissions", which an earlier check here would otherwise explain.
if [ -n "$SSH_KEY" ] && [ ! -r "$SSH_KEY" ]; then
    echo "Error: -K '$SSH_KEY' is not a readable file." >&2
    exit 1
fi

# Warned, not rejected -- see the identical block in snapsend.sh for the full
# reasoning. Under -e nothing is created here at all: the newest existing
# snapshot on the source is pulled in as-is, even one made by something else
# entirely, and that flexibility stays untouched.
if [ -z "$MESSAGE" ] && [ $USE_EXISTING_SNAPSHOT -ne 1 ]; then
    log 0 "WARNING: no -m given -- the new snapshot will be named with a bare timestamp, no prefix. No pattern-based delsnaps.sh retention job will ever match it, so it accumulates forever unless something specifically targets it."
fi

case "$QUIESCE" in
    no|agent|sync|auto) ;;
    *) echo "Error: -q '$QUIESCE' -- expected no, agent, sync or auto." >&2; exit 1 ;;
esac
case "$QUIESCE_DEADMAN" in
    ''|*[!0-9]*) echo "Error: -Q '$QUIESCE_DEADMAN' -- expected a positive integer (seconds before the remote deadman thaws unconditionally)." >&2; exit 1 ;;
    *) [ "$QUIESCE_DEADMAN" -ge 10 ] || { echo "Error: -Q '$QUIESCE_DEADMAN' -- must be at least 10 seconds; a deadman shorter than the freeze itself would thaw mid-window." >&2; exit 1; } ;;
esac

[ $# -ge 1 ] || { echo "Użycie: $0 [opcje] REMOTE_DATASETS [LOCAL_BASE]" >&2; exit 1; }

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

# Built once, used by both pipeline branches. -T0 lets zstd use every core (pigz
# is already multi-threaded by default); -c forces stdout so neither tool can
# decide to write a file. COMPRESS_PIPE runs on the REMOTE source side here.
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
# silent one: a VPN that stops passing packets without closing the connection
# leaves ssh waiting indefinitely, so the cron job never exits, never returns
# non-zero, and never fires notify-fail.sh. Every later run then hits the flock
# and skips, so backups stop while everything still looks healthy.
#
# ConnectTimeout covers a dead peer at connect time; ServerAlive* covers one that
# dies mid-transfer (4 x 15s = ~60s). Together they turn that hang into an
# ordinary failure -- which alerts AND leaves a resume token for the next run.
#
# These do NOT fire on a merely slow link: sshd answers keepalives at the
# protocol level regardless of what the payload is doing.
SSH_OPTS+=(-o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# -c: request a specific cipher (e.g. a faster/weaker one on a CPU-bound link).
# Omitted by default -- let ssh/sshd negotiate. No-op on a local run, since
# SSH_OPTS is built either way but ssh is never actually invoked there.
[ -n "$SSH_CIPHER" ] && SSH_OPTS+=(-c "$SSH_CIPHER")

# -K/-O go at the FRONT of the option list, so nothing appended above (base
# StrictHostKeyChecking/UserKnownHostsFile/-p, -c) can out-rank them: OpenSSH
# keeps the FIRST value it sees for a given key. Anything appended BELOW this
# point (tune_ssh_enable's ControlMaster trio) is therefore also out-ranked,
# which is the intended precedence -- an explicit -O ControlMaster=no must win.
#
# This block used to sit much further down, next to tune_ssh_enable. That was
# fine while every remote call happened after it, but the -R expansion below
# reads the REMOTE source over ssh (v2.61 moved it to the source side), and it
# ran with an SSH_OPTS that had no -i in it yet. Symptom: "Permission denied
# (publickey)" followed by "Source dataset not found on remote host", with a
# perfectly good key passed in -K. Invisible whenever the running account's
# DEFAULT ssh identity happens to be authorized on the peer -- i.e. invisible
# to root on a trusted cluster, and to the remote suite, which authenticates
# with each account's own key rather than a dedicated one. Found 2026-07-29 by
# running a pairing-key job as a delegated account.
if [ -n "$SSH_KEY" ] || [ ${#EXTRA_SSH_OPTS[@]} -gt 0 ]; then
    declare -a _front_ssh_opts=()
    [ -n "$SSH_KEY" ] && _front_ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
    for _o in "${EXTRA_SSH_OPTS[@]}"; do _front_ssh_opts+=(-o "$_o"); done
    SSH_OPTS=("${_front_ssh_opts[@]}" "${SSH_OPTS[@]}")
fi

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
# Flipped in v2.61: the READ side (remote) is always given literally, the
# WRITE side (local) gets the optional base. See the header doc above.
RAW_DATASETS=$1
LOCAL_BASE=${2:-}
IFS=',' read -ra RAW_DATASETS <<< "$RAW_DATASETS"

REMOTE_USER="root"
REMOTE_HOST=""
declare -a DATASETS=()
_first_item=1
for _item in "${RAW_DATASETS[@]}"; do
    _item_user="root"
    _item_host=""
    _item_path="$_item"
    if [[ "$_item" == *":"* ]]; then
        IFS=':' read -r _host_part _item_path <<< "$_item"
        if [[ "$_host_part" == *"@"* ]]; then
            IFS='@' read -r _item_user _item_host <<< "$_host_part"
        else
            _item_host="$_host_part"
        fi
    fi
    # A bare entry with no ':' at all (no host) is a LOCAL source -- no ssh,
    # used for local-to-local relocation/testing. Every entry must agree on
    # the same [user@]host: one ssh connection per run, and a silent partial
    # read from the wrong host is worse than refusing outright.
    if [ $_first_item -eq 1 ]; then
        REMOTE_USER="$_item_user"
        REMOTE_HOST="$_item_host"
        _first_item=0
    elif [ "$_item_host" != "$REMOTE_HOST" ] || [ "$_item_user" != "$REMOTE_USER" ]; then
        log 0 "All comma-separated REMOTE_DATASETS entries must share the same [user@]host -- got '${REMOTE_USER}@${REMOTE_HOST}' and '${_item_user}@${_item_host}'"
        exit 1
    fi
    DATASETS+=("$_item_path")
done

# LOCAL_BASE is always a plain local path, never a host. A leftover ':' or
# '@' here is almost certainly muscle memory from the pre-v2.61 argument
# order, where this position used to carry the remote host -- refuse instead
# of silently misreading it as a very strange literal local dataset name.
if [[ "$LOCAL_BASE" == *":"* ]] || [[ "$LOCAL_BASE" == *"@"* ]]; then
    log 0 "Second argument must be a plain local path, no host -- remote source(s) go in the FIRST argument as [user@]host:dataset now (v2.61+). Got: $LOCAL_BASE"
    exit 1
fi
LOCAL_BASE=$(echo "$LOCAL_BASE" | sed 's:^/+::; s:/+$::')

if [ $FLAT_RECURSE -eq 1 ]; then
    declare -a EXPANDED_DATASETS=()
    for ds in "${DATASETS[@]}"; do
        if [ -n "$REMOTE_HOST" ]; then
            # Both halves of this must tell a connection failure apart from a
            # real answer, and for opposite reasons. The probe used to report
            # ANY ssh failure as "Source dataset not found on remote host" --
            # verified live on 2026-07-29 with a wrong host key in a -k file:
            # ssh said "Host key verification failed" and this line still
            # blamed the dataset. The listing was worse in a quieter way: its
            # exit status was discarded entirely, so an unreachable host became
            # an empty child list, i.e. a silently narrowed set of datasets to
            # pull. See lib-zfs-snap.sh's SSH FAILURE DISCRIMINATION block.
            probe_dataset "$ds" "$REMOTE_USER" "$REMOTE_HOST" "source dataset"
            case $? in
                1) log 0 "Source dataset not found on remote host: $ds"; exit 1 ;;
                2) exit 1 ;;
            esac
            children=$(remote_list "$REMOTE_USER" "$REMOTE_HOST" \
                "expanding -R over the descendants of '$ds'" \
                "zfs list -H -o name -t filesystem,volume -r '$ds' 2>/dev/null") || exit 1
        else
            if ! zfs list -H "$ds" &>/dev/null; then
                log 0 "Source dataset not found: $ds"
                exit 1
            fi
            children=$(zfs list -H -o name -t filesystem,volume -r "$ds" 2>/dev/null)
        fi
        while IFS= read -r child; do
            [ -z "$child" ] && continue
            if [ $SKIP_PARENT -eq 1 ] && [ "$child" = "$ds" ]; then
                log 2 "Skip-parent (-S): not pulling $child itself"
                continue
            fi
            if dataset_excluded "$child"; then
                log 2 "Excluded (-X): $child"
                continue
            fi
            EXPANDED_DATASETS+=("$child")
        done <<< "$children"
    done
    # Every candidate filtered out is an error, not a quiet success -- see the
    # same block in snapsend.sh.
    if [ ${#EXPANDED_DATASETS[@]} -eq 0 ]; then
        log 0 "Flat-recursive (-R): nothing left to pull -- -X/-S filtered out every dataset under: ${DATASETS[*]}"
        exit 1
    fi
    mapfile -t DATASETS < <(printf '%s\n' "${EXPANDED_DATASETS[@]}" | sort -u)
    log 1 "Flat-recursive (-R): expanded to ${#DATASETS[@]} dataset(s): ${DATASETS[*]}"
fi

# Compress by default when the source is remote and the caller said nothing
# about it -- mirrors snapsend.sh section 5B (same reasoning: a plain
# invocation over ssh is the common case this most helps). An explicit
# -z/-Z/-g still wins outright; -N opts back out to the old default.
if [ -n "$REMOTE_HOST" ] && [ $COMPRESSION_SET -eq 0 ] && [ $NO_COMPRESS -eq 0 ]; then
    COMPRESSION=1
    log 1 "Compression: zstd -$COMPRESSION_LEVEL (default for a remote source -- pass -N to disable, -g for pigz, -A to auto-decide per dataset)"
fi

# A local pull has no link to save bytes on. The pipeline would be
#   zfs send | zstd -c | mbuffer | zstd -d -c | zfs recv
# i.e. compress and immediately decompress on the same machine, paying for both
# and gaining nothing -- there is no network between the two halves, only a pipe
# in memory. So -z/-Z/-g are dropped here rather than honoured, even though an
# explicit flag normally wins: this is not a preference we are overriding, it is
# an operation with no possible benefit. Mirrors snapsend.sh section 5B.
if [ $COMPRESSION -eq 1 ] && [ -z "$REMOTE_HOST" ]; then
    COMPRESSION=0
    [ $COMPRESSION_SET -eq 1 ] && \
        log 1 "Compression ignored: source is local, so compressing and decompressing on this same host would only cost CPU"
fi

# Connection reuse for every ssh call below. No-ops for a local run, and
# ControlMaster=auto falls back to an ordinary connection on failure.
tune_ssh_enable "$REMOTE_HOST"
trap 'tune_ssh_close "$REMOTE_USER@$REMOTE_HOST"' EXIT

# -K/-O were already prepended in section 5A above, before the -R expansion --
# see the note there. snapsend.sh still does it at this point because its own
# -R expansion reads the LOCAL source and needs no ssh at all.

# Catch the container-parent mistake before any work starts -- see the same
# block in snapsend.sh. One difference here, for the same reason snapget's -R
# expansion differs: the source may be REMOTE, so the check gets the remote
# args and rides the multiplexer opened just above (hence the placement after
# tune_ssh_enable, not next to the -R block). No re-prefixing needed any
# more -- $ds IS the full source-side name now.
if [ $RECURSIVE -eq 0 ] && [ $FLAT_RECURSE -eq 0 ]; then
    for ds in "${DATASETS[@]}"; do
        warn_if_unrecursed_children "$ds" "$REMOTE_USER" "$REMOTE_HOST"
    done
fi

# -A decides compress-or-not from a measurement, PER DATASET -- taken inside the
# loop below, not here, because the compression ratio is a property of the data
# and one dataset's ratio must not decide for the rest. Mirrors snapsend.sh
# section 5B; see the longer note there.
AUTOTUNE_ACTIVE=0
if [ $AUTOTUNE -eq 1 ] && [ -n "$REMOTE_HOST" ] && [ $DRY_RUN -ne 1 ]; then
    if [ $COMPRESSION_SET -eq 1 ]; then
        log 1 "Link tuning: -A ignored, compression was requested explicitly (-z/-Z/-g) -- honouring your flag"
    elif [ $NO_COMPRESS -eq 1 ]; then
        # -N is just as explicit a request as -z, in the other direction -- see
        # the longer note in snapsend.sh. Without this, gen-cron.sh's automatic
        # -A on every remote dst would silently re-enable compression a config
        # explicitly turned off.
        log 1 "Link tuning: -A ignored, compression was explicitly disabled (-N) -- honouring your flag"
    else
        AUTOTUNE_ACTIVE=1
        COMPRESSION_BASE=$COMPRESSION
    fi
fi

# ---- remote quiesce window -------------------------------------------------
# The pull twin of snapsend.sh's quiesce block. Same contract -- freeze, take
# every snapshot in one atomic call per pool, thaw, and only then transfer --
# except that all three happen on the SOURCE host inside a single ssh
# invocation, because that is the only shape in which the thaw survives losing
# the connection. See the REMOTE QUIESCE section in lib-zfs-snap.sh.
#
# Afterwards the normal loop runs with USE_EXISTING_SNAPSHOT=1: the snapshots
# already exist, and -e picks the newest matching -m, which is the one just
# made.
if [ "$QUIESCE" != "no" ] && [ $DRY_RUN -ne 1 ] && [ $USE_EXISTING_SNAPSHOT -ne 1 ]; then
    if [ -z "$REMOTE_HOST" ]; then
        # A local source is snapsend.sh's job; snapget.sh has no local-freeze
        # path and must not pretend the flag did something.
        log 0 "Quiesce: -q needs a REMOTE source (the guest has to be frozen where it runs). For a local source use snapsend.sh -q."
        exit 1
    fi
    quiesce_suffix="$(date '+%Y-%m-%d_%H-%M-%S')"
    declare -a QSCOPE=() QSNAPS=()
    for src_path in "${DATASETS[@]}"; do
        # Under -r the guests live in the CHILDREN of the named parent, so the
        # scope is expanded remotely; the snapshot list still names the parent,
        # because `zfs snapshot -r parent@snap` covers the tree atomically by
        # itself. Mirrors quiesce_scope()'s local reasoning.
        if [ $RECURSIVE -eq 1 ]; then
            while IFS= read -r _qds; do
                [ -n "$_qds" ] && QSCOPE+=("$_qds")
            done < <(remote_list "$REMOTE_USER" "$REMOTE_HOST" \
                        "expanding '$src_path' to find the guests to quiesce" \
                        "zfs list -H -o name -r '$src_path'")
        else
            QSCOPE+=("$src_path")
        fi
        QSNAPS+=("${src_path}@${MESSAGE}${quiesce_suffix}")
    done
    quiesce_rflag=""
    [ $RECURSIVE -eq 1 ] && quiesce_rflag="-r"
    log 1 "Quiesce: freezing on $REMOTE_HOST, then ${#QSNAPS[@]} atomic snapshot(s), then thawing -- all in one remote window"
    quiesce_remote_run "$REMOTE_USER" "$REMOTE_HOST" "$QUIESCE" "$quiesce_rflag" "$QUIESCE_DEADMAN" \
        "${QSCOPE[@]}" -- "${QSNAPS[@]}"
    case $? in
        0) USE_EXISTING_SNAPSHOT=1
           QUIESCE_SNAPPED=1 ;;
        *) # Same refusal as the local path: someone who asked for -q must
           # never silently receive a crash-consistent snapshot instead.
           log 0 "Quiesce: refusing to continue with unquiesced snapshots"
           exit 1 ;;
    esac
fi

declare -a FAILED_DATASETS=()
ADOPT_SKIPPED=0
for src_path in "${DATASETS[@]}"; do
    if [ -n "$LOCAL_BASE" ]; then
        dataset="${LOCAL_BASE}/${src_path}"
    else
        dataset="$src_path"
    fi
    dataset=$(echo "$dataset" | sed 's:///*:/:g; s:^/::')

    # "remote": snapget's source lives on the far side, so the ratio must be
    # measured there -- that is also where its compressor runs. src_path is
    # already the literal source-side name now, no prefixing needed.
    if [ $AUTOTUNE_ACTIVE -eq 1 ]; then
        COMPRESSION=$COMPRESSION_BASE
        tune_apply "$REMOTE_USER@$REMOTE_HOST" "$src_path" remote
    fi

    log 1 "Processing: ${REMOTE_HOST:-local}:$src_path => $dataset"

    if [ $DRY_RUN -eq 1 ]; then
        process_dataset "$src_path" "$dataset" "$REMOTE_USER" "$REMOTE_HOST"
    else
        stats_start=$(date +%s)
        if process_dataset "$src_path" "$dataset" "$REMOTE_USER" "$REMOTE_HOST"; then
            emit_stats "$dataset" "$src_path" "success" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
        else
            emit_stats "$dataset" "$src_path" "failed" "$(( $(date +%s) - stats_start ))" "$STATS_RESUMED"
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
    elif [ $USE_EXISTING_SNAPSHOT -eq 1 ] && [ $FLAT_RECURSE -eq 1 ] && [ "$ADOPT_SKIPPED" -ge ${#DATASETS[@]} ]; then
        # -e over -R skipped EVERY member as scaffolding: the requested subtree
        # carries no matching family anywhere, so "success" would report an
        # adoption that never happened. The per-member skip is not an error;
        # all of them together is the request not being satisfiable.
        echo "No matching family anywhere under the requested root(s) -- nothing was adopted (-e -R found only scaffolding)" >&2
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
