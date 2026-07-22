# lib-zfs-snap.sh -- shared helpers for snapsend.sh and snapget.sh
# ------------------------------------------------------------------------------
# NOT executable on its own -- meant to be `source`d. Holds only the helpers
# that were byte-for-byte identical in both scripts (logging, stats, and the
# resumable-transfer bookkeeping); every direction-specific function (send vs.
# pull) deliberately stays in each script, because that is where snapsend.sh and
# snapget.sh genuinely differ.
#
# These functions reference a few globals (VERBOSE, STATS_LOG, LOCKDIR,
# SSH_OPTS, and $0's basename). None are read at source time -- they are only
# used when the function is CALLED, which always happens after the sourcing
# script has set them up. So source this right after the global-config block.
# ------------------------------------------------------------------------------

###############################################################################
# LOGGING
###############################################################################
log() {
    local LEVEL=$1
    shift
    [ "$VERBOSE" -ge "$LEVEL" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# One line per processed dataset, appended to STATS_LOG. Best-effort: never
# lets a logging failure (e.g. unwritable path) break the actual backup.
emit_stats() {
    local dataset="$1" target="$2" status="$3" duration="$4" resumed="${5:-no}"
    {
        echo "$(date -u +%FT%TZ) script=$(basename "$0") dataset=${dataset} target=${target} status=${status} duration_s=${duration} resumed=${resumed}"
    } >> "$STATS_LOG" 2>/dev/null || true
}

###############################################################################
# RESUMABLE TRANSFER SUPPORT
###############################################################################
# If a prior zfs recv into $tgt_dataset was interrupted mid-stream, ZFS leaves
# a resume token on the TARGET dataset (receive_resume_token property). These
# helpers detect that, resume via `zfs send -t <token>`, and give up (via
# `zfs receive -A`, which discards only the partial state, not the dataset's
# existing history) after MAX_RESUME_ATTEMPTS failed resume attempts.
#
# In snapget.sh the target is ALWAYS local (its remote_host refers to the
# SOURCE), so get_resume_token/abandon_resume are always called there with an
# empty remote_host/user -- the parameters are kept anyway for symmetry with
# snapsend.sh, where the target can be remote.
MAX_RESUME_ATTEMPTS=3

get_resume_token() {
    local tgt_dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    local token
    if [ -n "$remote_host" ]; then
        token=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value receive_resume_token '$tgt_dataset' 2>/dev/null")
    else
        token=$(zfs get -H -o value receive_resume_token "$tgt_dataset" 2>/dev/null)
    fi
    if [ -n "$token" ] && [ "$token" != "-" ]; then
        echo "$token"
    fi
}

abandon_resume() {
    local tgt_dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    log 1 "Abandoning stuck resume state on $tgt_dataset (zfs receive -A)"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" "zfs receive -A '$tgt_dataset'"
    else
        zfs receive -A "$tgt_dataset"
    fi
}

# Resume-attempt counter is kept under LOCKDIR (same override as the lock), so a
# non-root run (LOCKDIR=~/run) can actually write it -- on the old hardcoded
# /var/run the counter was unwritable for non-root, reads always saw 0, the
# MAX_RESUME_ATTEMPTS guard never tripped, and a stuck resume was retried every
# run forever. LOCKDIR is set before process_dataset runs.
resume_state_file() {
    echo "${LOCKDIR:-/var/run}/$(basename "$0").resume-attempts.$(echo "$1" | tr '/' '_')"
}

read_resume_attempts() {
    cat "$(resume_state_file "$1")" 2>/dev/null || echo 0
}

increment_resume_attempts() {
    local f
    f=$(resume_state_file "$1")
    echo "$(($(read_resume_attempts "$1") + 1))" > "$f"
}

reset_resume_attempts() {
    rm -f "$(resume_state_file "$1")"
}

###############################################################################
# BOOKMARK-BACKED INCREMENTAL FALLBACK
###############################################################################
# A ZFS bookmark (dataset#mark) records only a snapshot's txg+GUID -- zero
# data blocks -- yet `zfs send -i` only needs that txg to compute a diff
# against a newer snapshot. So a bookmark survives deleting the snapshot it
# was made from and still anchors one more incremental. This is what saves a
# run from falling back to a FULL send when the common-base snapshot has
# already been pruned off the source (e.g. pvesr's ~12h retention on pve0)
# before this tool got around to shipping it onward.
#
# Scope for v1: single dataset only, no recursion. A recursive stream would
# need a bookmark (and a GUID match) on every child dataset, which none of
# this bookkeeping does yet -- callers gate these functions on
# `[ $RECURSIVE -ne 1 ]` and fall straight through to FULL otherwise.
#
# How syncoid avoids this problem: it doesn't send a single `-R` stream at
# all. `getchilddatasets()` enumerates the tree and `syncdataset()` -- the
# same single-dataset sync/bookmark logic used without -r -- runs once per
# child, in dependency order. So bookmarking "just works" per child with zero
# extra machinery, because recursion there is a loop over the single-dataset
# path, not a distinct code path. If -R here is ever replaced by an
# equivalent per-child loop calling process_dataset(), these functions need
# no changes to cover it -- confirmed by reading syncoid's source, 2026-07-22.
#
# NOT yet implemented: pruning of orphaned bookmarks (target retired, or
# just stale). Each successful transfer replaces the one bookmark it keeps
# per target, so these don't grow *per run* -- but a target dataset that
# stops being used entirely leaves its bookmark behind forever. Flagged as a
# follow-up, not silently forgotten.

# Emit the GUID of one dataset@snapshot. Mirrors get_timestamp's remote-vs-
# local branching but reads the `guid` property instead of `creation`.
get_snapshot_guid() {
    local dataset="$1"
    local snap="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"
    local guid
    if [ -n "$remote_host" ]; then
        guid=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value guid '${dataset}@${snap}' 2>/dev/null") || return 1
    else
        guid=$(zfs get -H -o value guid "${dataset}@${snap}" 2>/dev/null) || return 1
    fi
    [ -n "$guid" ] && echo "$guid"
}

# True when the dataset exists. Needed by the -w (raw send) path: raw streams
# carry their own dataset properties, so the leaf target must be created by
# `zfs recv` rather than pre-created by us -- which means "target missing" is a
# normal first-send state there, not a failure, and has to be told apart from
# a genuine lookup error.
target_exists() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -o name '$dataset' >/dev/null 2>&1"
    else
        zfs list -H -o name "$dataset" >/dev/null 2>&1
    fi
}

# Emit a dataset's `encryption` property ("off" for unencrypted). Empty when the
# dataset does not exist.
dataset_encryption() {
    local dataset="$1"
    local remote_user="${2:-}"
    local remote_host="${3:-}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs get -H -o value encryption '$dataset' 2>/dev/null"
    else
        zfs get -H -o value encryption "$dataset" 2>/dev/null
    fi
}

# Refuse a run whose rawness does not match what the existing target was seeded
# with. ZFS rejects these itself, but with messages that do not say what to do
# ("cannot perform raw receive on top of existing unencrypted dataset",
# "inherited key must be loaded"), and the refusal happens deep inside the pipe
# where it reads as a generic transfer failure.
#
# Verified on zfs-2.1.9: this only matters when the SOURCE is encrypted. For an
# unencrypted source, raw and non-raw streams interoperate freely in both
# directions and the two seedings are indistinguishable by property -- so the
# check deliberately does nothing there rather than guessing.
#
# Returns 0 to proceed, 1 to refuse. Skip it under -f, which destroys the target
# and therefore has no seeding left to conflict with.
check_raw_compatibility() {
    local src_dataset="$1" src_user="$2" src_host="$3"
    local tgt_dataset="$4" tgt_user="$5" tgt_host="$6"
    local raw="$7"

    local src_enc
    src_enc=$(dataset_encryption "$src_dataset" "$src_user" "$src_host")
    [ -z "$src_enc" ] && return 0
    [ "$src_enc" = "off" ] && return 0

    # Target absent = nothing seeded yet, any rawness is fine.
    local tgt_enc
    tgt_enc=$(dataset_encryption "$tgt_dataset" "$tgt_user" "$tgt_host")
    [ -z "$tgt_enc" ] && return 0

    if [ "$raw" -eq 1 ] && [ "$tgt_enc" = "off" ]; then
        log 0 "Refusing raw send: $src_dataset is encrypted ($src_enc) but the existing target $tgt_dataset is NOT ($tgt_enc)."
        log 0 "A raw stream cannot be received on top of an unencrypted dataset -- ZFS would reject it as \"cannot perform raw receive on top of existing unencrypted dataset\"."
        log 0 "The target was seeded by a non-raw run (note: a FAILED non-raw run also leaves an empty target behind). Either drop -w to keep sending decrypted, or destroy $tgt_dataset and let -w re-seed it from scratch."
        return 1
    fi

    if [ "$raw" -ne 1 ] && [ "$tgt_enc" != "off" ]; then
        log 0 "Refusing non-raw send: the existing target $tgt_dataset is encrypted ($tgt_enc), so it was seeded by a raw (-w) run."
        log 0 "A decrypted stream cannot be received into it -- ZFS would reject it as \"inherited key must be loaded\"."
        log 0 "Either add -w to keep this target raw, or destroy $tgt_dataset and let a non-raw run re-seed it."
        return 1
    fi

    return 0
}

###############################################################################
# SSH CONNECTION REUSE (ControlMaster)
###############################################################################
# One run makes many small ssh calls (timestamps, snapshot lists, property
# reads, target creation) plus the big transfer. Without multiplexing each of
# them pays a full handshake.
#
# Measured 2026-07-22, pve0 -> pve1 on a gigabit LAN: a bare `ssh host true`
# takes 150-230 ms, of which essentially all is handshake. With ControlMaster
# the same call costs ~8 ms, and the measured transfer throughput rose from
# 83.6 to 104.0 MB/s once the handshake stopped being counted inside it.
#
# Failure is non-fatal by construction: ControlMaster=auto falls back to an
# ordinary connection if the master cannot be created, so a bad socket path
# degrades to today's behaviour instead of breaking the run.

# Socket for the multiplexer. Lives in the tuning cache dir, NEVER in /var/run:
# that is tmpfs and, more importantly, not writable by the non-root zfsbackup
# account. Returns empty when no usable path exists, which disables reuse.
#
# The name is kept short on purpose -- a unix socket path is capped around 104
# characters, and ssh appends nothing but what we pass. Hence host_port rather
# than ssh's own %h/%p/%r tokens plus a long directory.
tune_control_path() {
    local host="$1"
    local dir safe p
    dir=$(tune_cache_dir) || return 0
    [ -n "$dir" ] || return 0
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    p="${dir}/cm.${safe}_${PORT:-22}"
    [ ${#p} -lt 100 ] && printf '%s' "$p"
}

# Appends multiplexing options to SSH_OPTS. Call once, AFTER SSH_OPTS is built
# and only when the run actually talks to a remote host. Sets TUNE_SOCK so the
# matching tune_ssh_close can shut the master down afterwards.
TUNE_SOCK=""
tune_ssh_enable() {
    local host="$1"
    [ -n "$host" ] || return 0
    TUNE_SOCK=$(tune_control_path "$host")
    if [ -z "$TUNE_SOCK" ]; then
        log 2 "ControlMaster disabled (no writable short socket path) -- each ssh call pays a full handshake"
        return 0
    fi
    SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=$TUNE_SOCK" -o ControlPersist=60)
    log 3 "ControlMaster socket: $TUNE_SOCK"
}

# Closes the multiplexer. Without this the master lingers for ControlPersist
# seconds after the script exits, holding a connection open for no reason.
# Best-effort: never fails the run.
tune_ssh_close() {
    local remote="$1"
    [ -n "$TUNE_SOCK" ] && [ -n "$remote" ] || return 0
    ssh -o "ControlPath=$TUNE_SOCK" -O exit "$remote" >/dev/null 2>&1 || true
    TUNE_SOCK=""
}

###############################################################################
# LINK TUNING (opt-in, -A)
###############################################################################
# Decides ONE thing: whether compressing the stream is worth it for this link
# and this data. That narrow scope is a measurement result, not an oversight --
# see the numbers below.
#
# Deliberately NOT tuned here:
#
#   mbuffer -m. Measured 2026-07-22, pve0 <-> pve1, 2 GB incompressible, real
#   `zfs recv` on the far side: 16M/128M/1G gave 109.9/109.3/109.8 MB/s to an
#   SSD target and 89.3/-/78.3-88.8 MB/s to a slow HDD target. A 64x change in
#   buffer size moved nothing beyond run-to-run noise, even in the slow-consumer
#   case that most favours a big buffer. Two sizing formulas (bandwidth x delay,
#   then bandwidth x recv-stall) were both refuted by that table, so there is
#   nothing here to tune -- just pick a small constant.
#
#   zstd level. On a slow link every level is far faster than the link, so the
#   highest ratio wins; but measured across levels the ratio barely moves
#   (1.293 -> 1.323 from -3 to -19, for 53x the CPU). Level choice is worth
#   ~2%, compress-or-not is worth ~29%. Only the latter is decided here.
#
# Everything degrades to the caller's existing settings: an unwritable cache,
# a failed probe, a missing snapshot, or a nonsensical measurement all leave
# COMPRESSION untouched rather than failing the backup.

TUNE_CACHE_TTL=$((7 * 24 * 3600))
TUNE_PROBE_VERSION=2
TUNE_SAMPLE_MB=64      # sample of a real `zfs send` stream used to measure ratio
TUNE_MARGIN_PCT=5      # below this gain, not worth burning CPU

# First writable persistent directory, or empty. NOT LOCKDIR: that is /var/run
# (tmpfs, wiped on reboot) for root but a real on-disk directory for the
# zfsbackup account, so a cache with a multi-day TTL would silently get two
# different lifetimes depending on who ran the script.
tune_cache_dir() {
    local candidates=() d
    if [ -n "${ZFS_SNAP_CACHE_DIR:-}" ]; then
        candidates=("$ZFS_SNAP_CACHE_DIR")
    else
        [ "$(id -u)" -eq 0 ] && candidates+=("/var/lib/zfs-snap")
        [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && candidates+=("$HOME/.cache/zfs-snap")
    fi
    for d in "${candidates[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        [ -w "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 0
}

# TWO caches, because the verdict has two inputs with different scopes.
#
#   linktune.<host>_<port>            MB/s the link can carry. A property of the
#                                     HOST (one host = one VPN link, agreed with
#                                     the operator), so every dataset in a run
#                                     shares it and only the first pays the probe.
#   streamtune.<host>_<port>.<hash>   ratio and pipeline rates. A property of the
#                                     DATA: the same host measured 2.34x on one
#                                     dataset and 1.29x on another. Keying this
#                                     per host too meant DATASETS[0]'s ratio
#                                     silently decided for every other dataset in
#                                     the run -- the bug this split fixes.
#
# The user@ part is stripped from the host in both, so root and zfsbackup share
# one measurement of the same link and the same data.
#
# What is cached is the MEASUREMENT, never the verdict: the verdict is recomputed
# from cached numbers on every run, so a change to TUNE_MARGIN_PCT or to
# tune_decide takes effect at once instead of after the TTL drains.
tune_cache_file() {
    local host="$1" dir safe
    dir=$(tune_cache_dir)
    [ -n "$dir" ] || return 1
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    printf '%s/linktune.%s_%s' "$dir" "$safe" "${PORT:-22}"
}

# Dataset is HASHED, not escaped. Names contain '/' and can be long, and any
# tr-style sanitiser would let 'tank/a-b' and 'tank/a_b' collapse onto one file,
# i.e. one dataset's ratio applied to another -- exactly the failure being fixed.
tune_stream_cache_file() {
    local host="$1" dataset="$2" dir safe hash
    dir=$(tune_cache_dir)
    [ -n "$dir" ] || return 1
    safe=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9.\-_' '_')
    hash=$(printf '%s' "$dataset" | md5sum | cut -c1-16)
    printf '%s/streamtune.%s_%s.%s' "$dir" "$safe" "${PORT:-22}" "$hash"
}

# Echoes a cached line if it is fresh AND was produced by the current probe
# method, returns 1 otherwise. The version must MATCH, not merely be present:
# bumping TUNE_PROBE_VERSION is the only way a change to HOW we measure can
# invalidate numbers from the old method, and without the comparison the field
# would be written and never read.
#
# ZFS_SNAP_RETUNE=1 forces a miss. Its name must stay in sync with the -A docs
# in both scripts; it is the only documented way to re-probe before the TTL.
tune_cache_read() {
    local f="$1" now="$2" line at ver
    [ "${ZFS_SNAP_RETUNE:-0}" -ne 1 ] || return 1
    [ -r "$f" ] || return 1
    line=$(cat "$f" 2>/dev/null) || return 1
    at=$(tune_field measured_at "$line")
    ver=$(tune_field probe_version "$line")
    [ -n "$at" ] && [ "$ver" = "$TUNE_PROBE_VERSION" ] || return 1
    [ $((now - at)) -lt $TUNE_CACHE_TTL ] && [ $((now - at)) -ge 0 ] || return 1
    printf '%s' "$line"
}

# Exact key match by splitting on whitespace, not a sed pattern: a regex loose
# enough to find `ratio=` also finds it inside `xratio=`, and the fields here
# deliberately share suffixes (raw_mbps, comp_mbps, link_mbps).
tune_field() {
    local k="$1" tok
    for tok in $2; do
        case "$tok" in
            "$k"=*) printf '%s' "${tok#*=}"; return 0 ;;
        esac
    done
    return 1
}

# Write-then-rename, and failure is swallowed: a cache that cannot be written is
# a slower next run, never a failed backup.
tune_cache_write() {
    local f="$1"; shift
    printf '%s\n' "$*" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
}

# Measures how fast this link moves incompressible bytes, in MB/s. Uses
# /dev/urandom precisely BECAUSE it is incompressible -- compressible probe data
# would measure the compressor instead of the link.
tune_probe_link() {
    local remote="$1" mb=32 t0 t1
    t0=$(date +%s.%N)
    dd if=/dev/urandom bs=1M count=$mb 2>/dev/null \
        | ssh "${SSH_OPTS[@]}" "$remote" "cat > /dev/null" 2>/dev/null || return 1
    t1=$(date +%s.%N)
    awk -v a="$t0" -v b="$t1" -v mb="$mb" \
        'BEGIN{d=b-a; if(d<=0){exit 1} printf "%.4f", mb/d}'
}

# Measures compression ratio and pipeline rate on a REAL `zfs send` stream from
# the dataset being backed up -- never on synthetic data. Ratio is a property of
# the DATA: the same host measured 2.34x on one dataset and 1.29x on another, so
# a table of ratios would be fiction.
#
# Three passes, not two. The first is a discarded warm-up: without it the first
# pass reads from disk and the second from ARC, so whichever runs second looks
# faster regardless of what it measures. That artefact was observed live
# (compressed pass "faster" than raw, which is arithmetically impossible).
#
# Streams throughout -- no temp files, so there is no way to fill a pool.
#
# Runs WHERE THE DATA IS. snapsend reads a local dataset, but snapget's source
# is the remote host and its compressor runs there too (snapget.sh:383,
# `ssh host "zfs send | $COMPRESS_PIPE"`), so probing locally would measure the
# wrong machine's disk and CPU entirely. Pass $2 to probe the remote side.
tune_probe_stream() {
    local dataset="$1" remote="${2:-}" script out raw_b raw_t comp_b comp_t

    # One self-contained snippet, run on whichever side owns the data, so the
    # sample never crosses the network -- only the four numbers come back.
    script='
      snap=$(zfs list -t snapshot -H -o name -s creation '"'$dataset'"' 2>/dev/null | tail -1)
      [ -n "$snap" ] || exit 1
      H="zfs send '"'"'$snap'"'"' 2>/dev/null | head -c '"$((TUNE_SAMPLE_MB * 1048576))"'"
      eval "$H | cat > /dev/null" || exit 1
      t0=$(date +%s.%N); rb=$(eval "$H | wc -c") || exit 1; t1=$(date +%s.%N)
      t2=$(date +%s.%N); cb=$(eval "$H | '"$COMPRESS_PIPE"' | wc -c") || exit 1; t3=$(date +%s.%N)
      echo "$rb $t0 $t1 $cb $t2 $t3"
    '
    if [ -n "$remote" ]; then
        out=$(ssh "${SSH_OPTS[@]}" "$remote" "$script" 2>/dev/null) || return 1
    else
        out=$(sh -c "$script" 2>/dev/null) || return 1
    fi

    local t0 t1 t2 t3
    read -r raw_b t0 t1 comp_b t2 t3 <<< "$out"
    [ -n "${t3:-}" ] || return 1
    [ "${raw_b:-0}" -gt 0 ] && [ "${comp_b:-0}" -gt 0 ] || return 1
    raw_t=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    comp_t=$(awk -v a="$t2" -v b="$t3" 'BEGIN{printf "%.4f", b-a}')

    awk -v rb="$raw_b" -v rt="$raw_t" -v cb="$comp_b" -v ct="$comp_t" 'BEGIN{
        if (rt<=0 || ct<=0) exit 1
        mb = rb/1048576
        raw = mb/rt; comp = mb/ct
        # Compression cannot make the source produce input bytes faster, so
        # comp > raw is always measurement error -- but the size of the error
        # says what kind, and only one kind is worth discarding.
        #
        # A LARGE excess means the runs were skewed (the artefact the warm-up
        # pass exists to prevent: one pass off disk, the next off ARC). Refuse,
        # rather than cache a lie for a week.
        if (comp > raw*1.5) exit 1
        # A SMALL one is expected and harmless. The two passes are not perfectly
        # symmetric -- the raw pass pushes all 64 MB into `wc`, the compressed
        # pass only the compressed bytes -- and a disk-bound source is noisy well
        # past a few percent (measured 88-120 MB/s for one unchanged setting).
        # Both effects grow exactly when compression works, so rejecting here
        # threw the measurement away on the datasets -A most needs to judge:
        # observed live on pve0 refusing both an incompressible dataset and a
        # highly compressible one, while ordinary VM disks (1.26x, 3.21x) passed.
        # Clamping keeps the usable part -- the true rate cannot exceed raw, so
        # raw is the honest estimate -- and errs against compression, never for it.
        if (comp > raw) comp = raw
        printf "%.4f %.4f %.4f", rb/cb, raw, comp
    }'
}

# effective = min(what the pipeline can produce, what the link can carry).
# Both sides in MB/s of UNCOMPRESSED data delivered, so they are comparable.
tune_decide() {
    local link="$1" ratio="$2" raw="$3" comp="$4"
    awk -v l="$link" -v r="$ratio" -v raw="$raw" -v c="$comp" -v m="$TUNE_MARGIN_PCT" 'BEGIN{
        plain = (raw < l ? raw : l)
        wcomp = (c < l*r ? c : l*r)
        if (plain <= 0) exit 1
        gain = (wcomp/plain - 1) * 100
        printf "%s %.1f", (gain > m ? "yes" : "no"), gain
    }'
}

# Entry point. Sets COMPRESSION (and logs why). Never returns non-zero in a way
# that could abort the caller -- every failure path just leaves settings alone.
# $3 ("remote"/"local") says which side owns the DATA -- snapsend sends local
# data to a remote host, snapget pulls remote data to a local target. The link
# probe always targets the remote host either way; only the stream probe cares.
tune_apply() {
    local remote="$1" dataset="$2" data_side="${3:-local}"
    # Deliberately a SEPARATE statement: inside one `local`, every word is
    # expanded before any assignment happens, so `host="${remote#*@}"` on the
    # line above would read an empty `remote` and yield "". That silently made
    # the cache filename host-less, i.e. every host sharing one cache entry --
    # a measurement of one link being applied to another.
    local host="${remote#*@}"
    local lf sf now cached verdict gain link stream ratio raw comp stream_remote=""
    [ "$data_side" = "remote" ] && stream_remote="$remote"

    lf=$(tune_cache_file "$host") && sf=$(tune_stream_cache_file "$host" "$dataset") || {
        log 1 "Link tuning: no writable cache dir -- leaving compression settings as given"
        return 0
    }
    now=$(date +%s)

    # --- link: per host, so this probe runs once per run no matter how many
    #     datasets follow. 32 MB of urandom per dataset would be a real cost.
    if cached=$(tune_cache_read "$lf" "$now"); then
        link=$(tune_field link_mbps "$cached")
        log 3 "Link tuning: cached link=${link}MB/s for $host"
    else
        link=$(tune_probe_link "$remote") || {
            log 1 "Link tuning: link probe failed -- leaving compression settings as given"
            return 0
        }
        tune_cache_write "$lf" \
            "measured_at=$now probe_version=$TUNE_PROBE_VERSION link_mbps=$link host=$host"
    fi

    # --- stream: per host AND dataset, because the ratio is a property of the
    #     data. This is the whole point of the split.
    if cached=$(tune_cache_read "$sf" "$now"); then
        ratio=$(tune_field ratio "$cached")
        raw=$(tune_field raw_mbps "$cached")
        comp=$(tune_field comp_mbps "$cached")
        log 3 "Link tuning: cached ratio=${ratio} for $dataset"
    else
        stream=$(tune_probe_stream "$dataset" "$stream_remote") || {
            log 1 "Link tuning: stream probe failed or gave an implausible result -- leaving compression settings as given"
            return 0
        }
        read -r ratio raw comp <<< "$stream"
        tune_cache_write "$sf" \
            "measured_at=$now probe_version=$TUNE_PROBE_VERSION ratio=$ratio raw_mbps=$raw comp_mbps=$comp dataset=$dataset"
    fi

    # A truncated or hand-edited cache file parses to empty fields, and awk would
    # happily turn those into 0 and a confident "no". Checked here rather than
    # trusted, so a damaged cache degrades to the caller's settings like every
    # other failure path in this section.
    [ -n "$link" ] && [ -n "$ratio" ] && [ -n "$raw" ] && [ -n "$comp" ] || {
        log 1 "Link tuning: cached measurement unreadable -- leaving compression settings as given"
        return 0
    }

    # `read` succeeds on the empty output of a failed awk, so its exit status
    # says nothing about tune_decide. The verdict itself is what gets checked.
    read -r verdict gain <<< "$(tune_decide "$link" "$ratio" "$raw" "$comp")"
    [ -n "$verdict" ] || {
        log 1 "Link tuning: could not evaluate -- leaving compression settings as given"
        return 0
    }

    [ "$verdict" = "yes" ] && COMPRESSION=1 || COMPRESSION=0
    log 1 "Link tuning: $dataset link=${link}MB/s ratio=${ratio} -> compress=${verdict} (gain ${gain}%)"
    return 0
}

###############################################################################
# COMPRESSED SEND (zfs send -c)
###############################################################################
# Sends records as they already sit on disk instead of decompressing them to
# build the stream and recompressing them on receive. Measured 2026-07-22 with
# `zfs send -nP` against real production snapshots on pve0:
#
#   hdd/data/vm-101-disk-0             6.6 GB -> 5.5 GB   (-18%)
#   rpool/data/vm-100-disk-0         342.2 GB -> 249.1 GB (-27%)
#   hdd/lxc/subvol-102-disk-0          1.1 GB -> 0.6 GB   (-47%)
#   hdd/backups/pve1/rpool/ROOT/pve-1  4.0 GB -> 1.7 GB   (-56%)
#
# Unlike -z this is not a trade: there is no compressor in the pipe, so it costs
# no CPU -- it SAVES the decompress/recompress that a plain send pays on both
# ends. That is why it applies to local transfers too, where -z is dropped.
#
# On by default because of those numbers, and because probing on zfs-2.1.9 found
# no interaction to be careful about:
#   full / -I incremental / -R recursive / -w raw / compression=off source  all OK
#   resume tokens are INDIFFERENT to it -- a token from a -c send resumes with or
#     without -c, and a token from a plain send resumes with -c. (Note how much
#     kinder that is than -w, where adding the flag to a resume aborts with
#     SIGABRT -- see the comment in process_dataset.)
#   a target already fed PLAIN streams accepts a -c incremental, and a target fed
#     -c accepts a plain incremental again, so switching is reversible mid-history
#
# The ONE hazard is the receiving pool. Probed exactly:
#
#   target features        source compression=off | lz4 | zstd
#   none (zpool create -d)          fail    fail    fail
#   lz4_compress only                ok      ok     fail
#
# So lz4_compress is required for a compressed stream AT ALL, even from an
# uncompressed dataset -- the stream FORMAT is what is gated, not the payload --
# and zstd-compressed records additionally need zstd_compress. Failure is not
# subtle ("pool must be upgraded to receive this stream") but it happens at recv
# time, i.e. after the send has started, so it is checked up front instead.
#
# Set ZFS_SNAP_NO_COMPRESSED_SEND=1 to force plain sends. Deliberately an env var
# rather than a flag: the guard below already handles the only known failure, so
# a CLI flag would be one more thing to thread through gen-cron configs for a
# case that should not arise.

# Cache per (pool, remote) -- one zpool query per run, not per dataset.
declare -A CSEND_POOL_CACHE=()

# "enabled" and "active" both mean the pool can take it; "disabled" cannot.
csend_pool_has() {
    local pool="$1" feature="$2" remote="$3" key="$pool/$feature/$remote" val
    if [ -n "${CSEND_POOL_CACHE[$key]+x}" ]; then
        printf '%s' "${CSEND_POOL_CACHE[$key]}"
        return 0
    fi
    if [ -n "$remote" ]; then
        val=$(ssh "${SSH_OPTS[@]}" "$remote" "zpool get -H -o value feature@$feature '$pool'" 2>/dev/null)
    else
        val=$(zpool get -H -o value "feature@$feature" "$pool" 2>/dev/null)
    fi
    case "$val" in
        enabled|active) val=yes ;;
        *)              val=no  ;;   # disabled, absent, or the query failed
    esac
    CSEND_POOL_CACHE["$key"]="$val"
    printf '%s' "$val"
}

# Echoes "-c" when a compressed send is safe for this transfer, nothing
# otherwise. Never fails the caller: an unanswerable question (query error,
# unreadable property) resolves to a plain send, which always works.
#
# BOTH sides are parameters because the two scripts are mirror images --
# snapsend reads a local dataset and writes to a possibly-remote pool, snapget
# reads a remote dataset and writes locally. Passing the wrong one asks the wrong
# machine about its pool, which is the sort of mistake that only shows up as an
# unexplained fallback to plain sends.
compressed_send_flag() {
    local src_dataset="$1" tgt_dataset="$2" tgt_remote="${3:-}" src_remote="${4:-}" pool comp
    [ "${ZFS_SNAP_NO_COMPRESSED_SEND:-0}" -ne 1 ] || return 0

    pool="${tgt_dataset%%/*}"
    [ -n "$pool" ] || return 0

    [ "$(csend_pool_has "$pool" lz4_compress "$tgt_remote")" = "yes" ] || {
        log 2 "Compressed send unavailable: target pool '$pool' lacks feature@lz4_compress"
        return 0
    }

    if [ -n "$src_remote" ]; then
        comp=$(ssh "${SSH_OPTS[@]}" "$src_remote" "zfs get -H -o value compression '$src_dataset'" 2>/dev/null)
    else
        comp=$(zfs get -H -o value compression "$src_dataset" 2>/dev/null)
    fi
    case "$comp" in
        zstd*)
            [ "$(csend_pool_has "$pool" zstd_compress "$tgt_remote")" = "yes" ] || {
                log 2 "Compressed send unavailable: '$src_dataset' uses $comp but target pool '$pool' lacks feature@zstd_compress"
                return 0
            }
            ;;
    esac

    printf '%s' "-c"
}

###############################################################################
# QUIESCE (-q) -- application-consistent snapshots of Proxmox guests
###############################################################################
# A ZFS snapshot of a running guest is CRASH-consistent: the image is whatever
# the guest happened to have on its virtual disk at that instant, exactly as if
# the power had been cut. Databases survive that (they replay their WAL on
# start), but they pay a recovery, and anything not yet fsync'd is gone.
#
# Quiescing asks the guest to flush and hold still first. Two mechanisms, because
# Proxmox has two kinds of guest:
#
#   qemu (VM)  -- a real freeze. `qm guest cmd <id> fsfreeze-freeze` runs INSIDE the guest via
#                 qemu-guest-agent, which also runs /etc/qemu/fsfreeze-hook --
#                 that is where a database's own quiesce belongs (MySQL FLUSH
#                 TABLES WITH READ LOCK, Postgres backup mode). Without such a
#                 hook this flushes the guest's page cache and freezes its
#                 filesystems: filesystem-consistent, not application-consistent.
#   lxc  (CT)  -- CANNOT BE FROZEN AT ALL on this stack. Containers have no
#                 guest agent, and freezing their dataset from the host does not
#                 work either: ZFS does not implement the FIFREEZE ioctl, so
#                 `fsfreeze -f` on any ZFS mountpoint returns "Operation not
#                 supported" -- measured on pve0 against a live container subvol
#                 AND against a freshly created empty dataset, so it is ZFS-wide,
#                 not a property of one filesystem. The best available is a FLUSH:
#                 `pct exec <id> -- sync` pushes the container's dirty pages into
#                 ZFS before the snapshot. That is strictly weaker than a freeze
#                 -- writes are never blocked, so a write landing between the sync
#                 and the snapshot is still caught mid-flight -- and it is named
#                 `sync` rather than `fs` so nobody reads it as a freeze.
#
# THE FREEZE WINDOW MUST CONTAIN ONLY `zfs snapshot`. A frozen filesystem blocks
# writes, so a guest stays stalled for as long as the window is open. Taking the
# snapshot is instantaneous; SENDING it is not (342 GB in one production case).
# The caller is therefore expected to freeze, snapshot every dataset in ONE
# atomic `zfs snapshot` call, thaw, and only then transfer.
#
# THAW IS GUARANTEED, not best-effort. A guest left frozen is an outage, so
# quiesce_freeze registers what it froze and quiesce_thaw_all is wired to an EXIT
# trap by the caller -- it runs on success, on failure, and on Ctrl-C.

# What is currently frozen, so the thaw is exact rather than a guess. Only VMs
# ever appear here: the container path flushes and returns, holding nothing.
declare -a QUIESCE_FROZEN=()
# Guests already handled in this run, VM or container alike. One guest owns
# several datasets (VM 107 has three disks, CT 102 has two), and quiescing is a
# property of the GUEST, not of the disk: freezing a VM twice would need thawing
# it twice, and re-syncing a container only widens the gap between the flush and
# the snapshot. Without this the second disk of a running VM hit the
# "already frozen" branch and shouted about it at log level 0.
declare -a QUIESCE_HANDLED=()

# Proxmox names guest disks vm-<id>-disk-N (VM) and subvol-<id>-disk-N (CT).
# That convention IS the dataset-to-guest mapping -- there is no property to ask.
# Anything that does not match belongs to no guest and is simply not quiesced.
quiesce_guest_id() {
    local ds="$1" leaf="${1##*/}"
    case "$leaf" in
        vm-*-disk-*|subvol-*-disk-*)
            leaf="${leaf#vm-}"; leaf="${leaf#subvol-}"
            printf '%s' "${leaf%%-disk-*}"
            ;;
        *) return 1 ;;
    esac
}

# "qemu", "lxc", or nothing. Read from /etc/pve, which is the cluster filesystem
# and therefore authoritative on this node.
quiesce_guest_kind() {
    local id="$1"
    [ -f "/etc/pve/qemu-server/${id}.conf" ] && { printf 'qemu'; return 0; }
    [ -f "/etc/pve/lxc/${id}.conf" ]        && { printf 'lxc';  return 0; }
    return 1
}

quiesce_guest_running() {
    local id="$1" kind="$2" st=""
    case "$kind" in
        qemu) st=$(qm  status "$id" 2>/dev/null) ;;
        lxc)  st=$(pct status "$id" 2>/dev/null) ;;
    esac
    case "$st" in *running*) return 0 ;; esac
    return 1
}

# Freezes whatever owns $1, if anything, and remembers it. Returns 0 even when it
# does nothing: a dataset with no guest, a stopped guest or an unreachable agent
# are all reasons to take an ordinary snapshot, not to fail a backup.
quiesce_freeze() {
    local ds="$1" mode="$2" id kind mnt
    [ "$mode" = "no" ] && return 0

    id=$(quiesce_guest_id "$ds") || { log 3 "Quiesce: '$ds' is not a Proxmox guest disk -- nothing to freeze"; return 0; }
    kind=$(quiesce_guest_kind "$id") || { log 2 "Quiesce: no guest $id on this node -- skipping"; return 0; }
    # Check AND mark here, as soon as the owning guest is known -- before the
    # running check, not after. The decision being deduplicated is "what do we do
    # about guest N", and that is settled once however it turns out. Marking only
    # on the freeze path left stopped guests to be re-examined per disk, which on
    # a recursive job over a whole pool means a `qm status` and a log line for
    # every disk of every stopped VM.
    case " ${QUIESCE_HANDLED[*]} " in
        *" $id "*) log 3 "Quiesce: guest $id already handled in this run"; return 0 ;;
    esac
    QUIESCE_HANDLED+=("$id")

    quiesce_guest_running "$id" "$kind" || { log 3 "Quiesce: guest $id is not running -- nothing to freeze"; return 0; }

    # An explicit mode that does not fit this guest is a config mistake worth
    # saying out loud, but still not worth failing a backup over.
    case "$mode/$kind" in
        agent/lxc)  log 1 "Quiesce: guest $id is a container, which has no qemu-guest-agent -- use quiesce=sync or auto"; return 0 ;;
        sync/qemu)  log 1 "Quiesce: guest $id is a VM; sync-in-guest is the container fallback and does nothing here -- use quiesce=agent or auto"; return 0 ;;
    esac

    case "$kind" in
        qemu)
            # Already frozen (a previous run died between freeze and thaw) is
            # reported rather than re-frozen: freezing twice needs two thaws.
            case "$(qm guest cmd "$id" fsfreeze-status 2>/dev/null)" in
                *frozen*) log 0 "Quiesce: guest $id was ALREADY frozen before this run -- leaving it alone, someone should investigate"; return 0 ;;
            esac
            if qm guest cmd "$id" fsfreeze-freeze >/dev/null 2>&1; then
                QUIESCE_FROZEN+=("qemu:$id")
                log 1 "Quiesce: froze VM $id via qemu-guest-agent"
            else
                log 1 "Quiesce: VM $id did not respond to fsfreeze-freeze (agent missing, disabled or busy) -- snapshot will be crash-consistent"
            fi
            ;;
        lxc)
            # A flush, not a freeze -- nothing is registered for thawing because
            # nothing is held.
            if pct exec "$id" -- sync >/dev/null 2>&1; then
                log 1 "Quiesce: flushed container $id (pct exec sync) -- ZFS cannot be frozen, so this is a flush, not a freeze"
            else
                log 1 "Quiesce: 'pct exec $id -- sync' failed -- snapshot will be crash-consistent"
            fi
            ;;
    esac
    return 0
}

# Which datasets to look for guests in. A RECURSIVE job names a PARENT --
# pve1's hourly job is `snapsend.sh -r rpool/data`, one line covering every VM on
# the pool -- and a parent's name matches no guest-disk pattern at all. Deriving
# guests from the argument alone therefore quiesced NOTHING on exactly the jobs
# that cover the most machines, while logging "not a Proxmox guest disk" and
# reporting success: a config that promised consistency and silently delivered
# none. So under -r the dataset is expanded to its children first.
#
# Only the NAMES are expanded. The snapshot itself stays a single recursive
# `zfs snapshot -r parent@snap`, which is already atomic across the whole tree.
quiesce_scope() {
    local ds="$1" recursive="${2:-0}"
    if [ "$recursive" -eq 1 ]; then
        zfs list -H -o name -r "$ds" 2>/dev/null
    else
        printf '%s\n' "$ds"
    fi
}

# Thaws everything this run froze, in reverse order, and empties the list so a
# second call is harmless -- the EXIT trap fires even after an explicit thaw.
# Every failure is shouted at log level 0: a guest that will not thaw is the one
# outcome here that is worse than no quiescing at all.
quiesce_thaw_all() {
    local i entry
    for (( i=${#QUIESCE_FROZEN[@]}-1; i>=0; i-- )); do
        entry="${QUIESCE_FROZEN[$i]}"
        case "$entry" in
            qemu:*)
                if qm guest cmd "${entry#qemu:}" fsfreeze-thaw >/dev/null 2>&1; then
                    log 1 "Quiesce: thawed VM ${entry#qemu:}"
                else
                    log 0 "Quiesce: FAILED TO THAW VM ${entry#qemu:} -- that guest is still frozen and needs manual 'qm guest cmd ${entry#qemu:} fsfreeze-thaw'"
                fi
                ;;
        esac
    done
    QUIESCE_FROZEN=()
    QUIESCE_HANDLED=()
}

# Short, stable per-target suffix for bookmark names -- lets one source
# dataset feed several targets without their bookmarks colliding or
# overwriting each other.
bookmark_target_tag() {
    printf '%s' "$1" | md5sum | cut -c1-8
}

# Look for a bookmark on $src_dataset whose GUID matches $tgt_head_guid --
# the ZFS-level proof that the bookmark's txg is a valid incremental base for
# whatever the target currently holds. Echoes "src_dataset#mark" on a match,
# nothing otherwise. Deliberately GUID-only, never name-based: a stale or
# renamed bookmark (source rolled back, target rebuilt independently) has a
# different GUID and correctly falls through to FULL instead of being
# trusted on a guess.
find_bookmark_base() {
    local src_dataset="$1"
    local tgt_head_guid="$2"
    local remote_user="${3:-}"
    local remote_host="${4:-}"
    [ -z "$tgt_head_guid" ] && return 0
    local marks
    if [ -n "$remote_host" ]; then
        marks=$(ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -t bookmark -o name,guid '$src_dataset' 2>/dev/null")
    else
        marks=$(zfs list -H -t bookmark -o name,guid "$src_dataset" 2>/dev/null)
    fi
    [ -z "$marks" ] && return 0
    local name guid
    while IFS=$'\t' read -r name guid; do
        [ "$guid" = "$tgt_head_guid" ] && { echo "$name"; return 0; }
    done <<< "$marks"
}

# After a successful transfer, refresh the per-target bookmark on the SOURCE
# to the snapshot that was just sent. This is the insurance policy itself:
# if the source's own retention deletes that snapshot before the next run,
# the bookmark (metadata only) still anchors the next incremental. Only one
# bookmark is kept per target (the old one is destroyed first), so this
# doesn't accumulate across runs -- see the orphan-pruning gap noted above.
# Best-effort: a failure here (e.g. missing 'zfs allow bookmark,destroy'
# delegation for a non-root sender) logs a warning but does not fail the
# transfer that already succeeded.
record_send_bookmark() {
    local src_dataset="$1"
    local sent_snap="$2"
    local tgt_dataset="$3"
    local remote_user="${4:-}"
    local remote_host="${5:-}"
    local tag mark full
    tag=$(bookmark_target_tag "$tgt_dataset")
    mark="tgt-${tag}"
    full="${src_dataset}#${mark}"
    if [ -n "$remote_host" ]; then
        ssh "${SSH_OPTS[@]}" "$remote_user@$remote_host" \
            "zfs list -H -t bookmark -o name '$full' >/dev/null 2>&1 && zfs destroy '$full'; zfs bookmark '${src_dataset}@${sent_snap}' '$full'" \
            || log 1 "Warning: failed to refresh bookmark $full on $remote_host (non-fatal)"
    else
        zfs list -H -t bookmark -o name "$full" >/dev/null 2>&1 && zfs destroy "$full"
        zfs bookmark "${src_dataset}@${sent_snap}" "$full" \
            || log 1 "Warning: failed to refresh bookmark $full (non-fatal)"
    fi
}
