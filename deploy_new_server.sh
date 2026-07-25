#!/bin/bash
# ------------------------------------------------------------------------------
# deploy_new_server.sh
#
# Bootstrap procedure for propagating zfs-snapshot-all (snapsend.sh/snapget.sh/
# delsnaps.sh) from GitHub onto a new Proxmox/Debian host, including:
#   - verification and installation of every dependency the package needs
#     (see the table in Part 1 -- it is derived from what the scripts invoke)
#   - clone/update of /root/scripts/zfs-snapshot-all (handles both a fresh dir
#     and one that already has plain-file copies of the scripts sitting in it)
#   - zfs-alert.conf: how loudly this host reports problems. ZFS_ALERT_MODE is
#     'daily' by default (queue everything, one summary mail per host per day)
#     and 'immediate' mails each finding as it happens -- worth setting while
#     bringing a host up. Created once; never overwritten on re-run.
#     Provision it directly with --alerts=immediate.
#   - notify-fail.sh / notify-warn.sh: report an ALERT / WARN finding, either by
#     queueing it or by mailing at once, per that config.
#   - alert-digest.sh: in daily mode, the ONLY mail this host sends about
#     backups -- one message covering every ALERT and WARNING queued since the
#     last run, and no mail at all on a day with nothing to report.
#   - check-pool-capacity.sh pool/quota alert (fires on slow-fill BEFORE a job fails)
#   - smoke test of all five shipped executables + a live compressor round-trip
#   - auto-pull cron line
#
# This script IS tracked in the repo (alongside the 5 package scripts and
# deploy_backup_user.sh). On a brand-new host you still have to get it there
# before there is a checkout to run it from -- paste it via heredoc, scp it,
# or curl it from GitHub -- then run it as root:
#
#   bash deploy_new_server.sh
#
# It is idempotent: safe to re-run. It does NOT touch your crontab's actual
# snapsend/snapget/delsnaps job lines -- those are dataset-specific per host
# and are a manual step documented at the end (Part 5 below), because getting
# that wrong on a live host is exactly the kind of thing that bit us before.
# ------------------------------------------------------------------------------
set -uo pipefail

REPO_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
REPO_DIR="/root/scripts/zfs-snapshot-all"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-lurk@lurk.com.pl}"   # override: NOTIFY_EMAIL=foo@bar bash deploy_new_server.sh

# PROBLEMS lets --check-only return a meaningful exit code, so the audit can be
# driven from cron or a loop over hosts instead of being read by eye.
PROBLEMS=0
log() { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
die() { echo "FATAL: $*" >&2; exit 1; }

# --check-only: report what is missing or broken and change NOTHING. No package
# installs, no clone/pull, no files created, no crontab edits, and -- the one
# that matters most on a live host -- no test email. Use it to audit a server
# that is already running, where the full script's side effects are unwanted.
CHECK_ONLY=0
# How loudly this host alerts. Written into /root/scripts/zfs-alert.conf, which
# is the single place an operator changes it afterwards -- see Part 4 below.
#   daily     (default) every finding is queued; ONE mail per host per day
#   immediate every finding mails the moment it happens, rate-limited per
#             message. Worth choosing while BRINGING A HOST UP: a misconfigured
#             job you hear about within the hour is a five-minute fix; the same
#             mistake found in tomorrow's digest has already cost a night of
#             backups. Switch to daily once the host has run clean for a while.
ALERT_MODE="daily"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; shift ;;
        --alerts=*)   ALERT_MODE="${1#*=}"; shift ;;
        --alerts)     ALERT_MODE="${2:-}"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--check-only] [--alerts=daily|immediate]"
            echo "  --check-only       audit dependencies and the checkout; make no changes"
            echo "  --alerts=daily     (default) queue findings, one summary mail per host per day"
            echo "  --alerts=immediate mail every finding as it happens -- recommended while"
            echo "                     bringing a new host up, then switch back to daily"
            echo
            echo "Only used when /root/scripts/zfs-alert.conf does not exist yet; an existing"
            echo "one is never overwritten. Change the mode later by editing that file."
            exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done
case "$ALERT_MODE" in
    daily|immediate) ;;
    *) echo "--alerts must be 'daily' or 'immediate', got '$ALERT_MODE'" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$CHECK_ONLY" -eq 1 ] && log "CHECK-ONLY mode: nothing will be installed or modified"

# On Proxmox, apt-get update commonly fails on the pve-enterprise repo (401,
# no subscription) even though the other repos succeed. Try a plain install
# first (works if package lists are already cached); only fall back to
# `apt-get update` (tolerating the enterprise-repo failure) if that doesn't
# work. Shared by every package we need below.
apt_install_with_fallback() {
    local pkg="$1"
    apt-get install -y "$pkg" 2>/dev/null && return 0
    warn "plain install of $pkg failed, running apt-get update first (pve-enterprise 401 is expected/harmless here)"
    apt-get update || true
    apt-get install -y "$pkg"
}

# ------------------------------------------------------------------------------
log "Part 1: dependencies"
# ------------------------------------------------------------------------------
# The list below is derived from what the package's scripts ACTUALLY invoke, not
# from memory -- re-derive it with:
#   grep -ohE '\b(zfs|mbuffer|pigz|zstd|ssh|flock|mail|hostname|md5sum)\b' *.sh | sort -u
# and keep this table in step. Severity decides what a miss costs:
#
#   required     -- the package cannot work at all; missing => FATAL
#   compression  -- only jobs using -z/-Z/-g need it, but -z is on almost every
#                   real cron line, so treat a miss as loud
#   optional     -- degrades a feature, not the core; missing => warning
#
MISSING_OPTIONAL=""

# check_dep <command> <apt-package> <severity> <why>
check_dep() {
    local cmd="$1" pkg="$2" sev="$3" why="$4"

    if command -v "$cmd" >/dev/null 2>&1; then
        log "  [ok]      $cmd ($why)"
        return 0
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        case "$sev" in
            required) warn "  [MISSING] $cmd (apt: $pkg) -- REQUIRED: $why" ;;
            *)        warn "  [missing] $cmd (apt: $pkg) -- $why" ;;
        esac
        MISSING_OPTIONAL="$MISSING_OPTIONAL $cmd"
        return 1
    fi

    log "  [missing]  $cmd -- installing '$pkg' ($why)"
    apt_install_with_fallback "$pkg" >/dev/null 2>&1 || true

    if command -v "$cmd" >/dev/null 2>&1; then
        log "  [installed] $cmd"
        return 0
    fi

    case "$sev" in
        required)
            die "$cmd is REQUIRED and could not be installed from '$pkg' -- $why"
            ;;
        compression)
            warn "$cmd could not be installed from '$pkg' -- $why"
            MISSING_OPTIONAL="$MISSING_OPTIONAL $cmd"
            ;;
        *)
            warn "$cmd not available ('$pkg') -- $why"
            MISSING_OPTIONAL="$MISSING_OPTIONAL $cmd"
            ;;
    esac
    return 1
}

check_dep git      git              required    "cloning and auto-updating this repo"
check_dep flock    util-linux       required    "single-instance locking in all send/prune scripts"
check_dep mbuffer  mbuffer          required    "snapsend.sh/snapget.sh refuse to start without it, even without -z"
check_dep hostname hostname         required    "validate_remote_host uses 'hostname -f' to refuse loopback replication"
check_dep md5sum   coreutils        required    "per-target bookmark tags (lib-zfs-snap.sh)"
check_dep awk      gawk             required    "snapshot list parsing"

# zstd is the DEFAULT compressor since 2026-07-22 -- it measured better than pigz
# on BOTH ratio and throughput (see the benchmark table in snapsend.sh's header).
# So on a fresh host a missing zstd breaks every ordinary '-z' cron line, which
# is why it is checked BEFORE pigz and treated as loud.
check_dep zstd     zstd             compression "DEFAULT compressor for -z/-Z"
check_dep pigz     pigz             compression "alternative compressor, selected with -g"

check_dep ssh      openssh-client   optional    "remote push/pull; local-only hosts do not need it"
check_dep mail     mailutils        optional    "notify-fail.sh / capacity + staleness alerting"

# ------------------------------------------------------------------------------
log "Part 1b: ZFS itself"
# ------------------------------------------------------------------------------
# Deliberately separate from the table: on a host without ZFS this is not a
# missing utility, it is the wrong host. Installing zfsutils-linux would give a
# working CLI with no pool support, which fails later and much less clearly.
if ! command -v zfs >/dev/null 2>&1 && [ "$CHECK_ONLY" -eq 0 ]; then
    warn "zfs command not found -- attempting zfsutils-linux (expected already present on Proxmox)"
    apt_install_with_fallback zfsutils-linux >/dev/null 2>&1 || true
fi
command -v zfs >/dev/null 2>&1 || die "zfs not available -- this package manages ZFS snapshots and cannot do anything on this host"

# A CLI that cannot reach the kernel module is the failure that actually bites:
# every script would run and report nothing rather than failing loudly.
if ! zfs list -H >/dev/null 2>&1; then
    die "the 'zfs' command exists but 'zfs list' fails -- kernel module not loaded, or no pools imported. Fix that before deploying backups here."
fi
log "  [ok]      zfs $(zfs version 2>/dev/null | head -1 | awk '{print $NF}') -- $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')"

# ------------------------------------------------------------------------------
log "Part 2: deploy the repo into $REPO_DIR"
# ------------------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -d "$REPO_DIR/.git" ]; then
        log "checkout present at $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null))"
        d=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)
        [ -n "$d" ] && warn "checkout has local modifications -- 'git pull --ff-only' will fail:
$d"
    else
        warn "no git checkout at $REPO_DIR -- run without --check-only to create it"
    fi
else

mkdir -p "$(dirname "$REPO_DIR")"

if [ -d "$REPO_DIR/.git" ]; then
    log "$REPO_DIR is already a git repo, pulling..."
    git -C "$REPO_DIR" remote get-url origin 2>/dev/null | grep -qF "$REPO_URL" \
        || warn "existing repo's origin does not match $REPO_URL -- check manually"
    git -C "$REPO_DIR" pull --ff-only origin main \
        || die "git pull --ff-only failed -- local repo has diverged, resolve manually before continuing"

elif [ -d "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
    log "$REPO_DIR exists with files but is not a git repo (plain scripts from an earlier manual copy?)"
    log "Backing up any of the 3 tracked scripts that would collide with the checkout..."
    BACKUP_DIR="${REPO_DIR}.bak-preGit-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in snapsend.sh snapget.sh delsnaps.sh; do
        if [ -e "$REPO_DIR/$f" ]; then
            mv "$REPO_DIR/$f" "$BACKUP_DIR/"
            log "  moved $f -> $BACKUP_DIR/"
        fi
    done

    ( cd "$REPO_DIR" \
      && git init \
      && git remote add origin "$REPO_URL" \
      && git fetch origin \
      && git checkout -b main --track origin/main ) \
      || die "git init/checkout failed"

    log "Diff against backup (should be empty besides new .git/.gitignore/.gitattributes):"
    diff -rq "$BACKUP_DIR" "$REPO_DIR" 2>&1 | grep -v "^Only in $REPO_DIR:" || true

else
    log "$REPO_DIR does not exist or is empty -- plain clone"
    git clone "$REPO_URL" "$REPO_DIR" || die "git clone failed"
fi

fi   # end of CHECK_ONLY guard for Part 2

# ------------------------------------------------------------------------------
log "Part 3: verify the deployment"
# ------------------------------------------------------------------------------
cd "$REPO_DIR" || die "cannot cd into $REPO_DIR"
log "HEAD: $(git log -1 --oneline)"

FAIL=0

# lib-zfs-snap.sh is not optional: snapsend/snapget/delsnaps/gen-cron all source
# it and exit immediately if it is missing. Check it FIRST, because without it
# every -V below would fail and the real cause would be buried in the noise.
if [ ! -r lib-zfs-snap.sh ]; then
    die "lib-zfs-snap.sh missing from the checkout -- snapsend/snapget/delsnaps/gen-cron all source it and refuse to start. The clone is incomplete."
fi
log "  lib-zfs-snap.sh present"

# All five executables the package ships, not just the original three: gen-cron.sh
# (crontab generator) and check-snap-age.sh (staleness monitor) are part of the
# package now and are just as easy to get wrong silently.
for f in snapsend.sh snapget.sh delsnaps.sh gen-cron.sh check-snap-age.sh; do
    if [ ! -e "$f" ]; then
        warn "$f is missing from the checkout"
        FAIL=1
        continue
    fi
    if [ ! -x "$f" ]; then
        warn "$f is not executable (fixing with chmod +x)"
        chmod +x "$f"
    fi
    # Syntax check before execution: a truncated or CRLF-mangled file can still
    # be executable, and the failure it produces later is far less obvious.
    bash -n "$f" 2>/dev/null || { warn "$f fails 'bash -n' -- corrupt or wrong line endings?"; FAIL=1; continue; }
    v=$(./"$f" -V 2>&1) || { warn "$f -V failed: $v"; FAIL=1; continue; }
    log "  $f -> $v"
done
[ "$FAIL" -eq 0 ] || warn "one or more scripts failed the smoke test -- investigate before relying on cron"

# Prove the compressor actually round-trips ON THIS HOST rather than trusting
# that the binary being present means it works. Cheap, and catches a broken or
# shimmed install before a real transfer does.
for c in zstd pigz; do
    command -v "$c" >/dev/null 2>&1 || continue
    case "$c" in
        zstd) probe="zstd -T0 -3 -c" ; unprobe="zstd -d -c" ;;
        pigz) probe="pigz -6"        ; unprobe="pigz -d"    ;;
    esac
    if [ "$(echo zfs-snapshot-all | $probe | $unprobe 2>/dev/null)" = "zfs-snapshot-all" ]; then
        log "  $c round-trip ok"
    else
        warn "$c is installed but failed a compress/decompress round-trip -- jobs using it will break"
        FAIL=1
    fi
done

# ------------------------------------------------------------------------------
log "Part 4: notify-fail.sh (mail alerting on cron job failure)"
# ------------------------------------------------------------------------------
# Shared alerting state, deliberately OUTSIDE /root. /root is 0700, so a
# delegated non-root service account (deploy_backup_user.sh) cannot reach
# anything under it -- not the queue, not the config, not the notify scripts.
# The tempting shortcut, opening /root/scripts to a group, is a privilege
# escalation: that directory holds scripts root executes from cron, so a
# service account able to write there could replace them. Hence a separate
# group-writable directory that contains only data.
ALERT_GROUP="zfsalert"
ALERT_SHARED_DIR="/var/lib/zfs-snapshot-all"
if [ "$CHECK_ONLY" -eq 1 ]; then
    getent group "$ALERT_GROUP" >/dev/null || warn "  group $ALERT_GROUP missing -- a delegated account could not queue alerts"
    if [ -d "$ALERT_SHARED_DIR" ]; then
        log "  $ALERT_SHARED_DIR present ($(stat -c '%a %U:%G' "$ALERT_SHARED_DIR"))"
    else
        warn "  $ALERT_SHARED_DIR missing -- alert queue would fall back to a root-only path"
    fi
else
    getent group "$ALERT_GROUP" >/dev/null || { groupadd --system "$ALERT_GROUP" && log "created group $ALERT_GROUP"; }
    mkdir -p "$ALERT_SHARED_DIR/notify-state"
    chgrp -R "$ALERT_GROUP" "$ALERT_SHARED_DIR"
    # 2775: setgid, so every file created here inherits the group and stays
    # writable by the other account no matter which one created it.
    chmod 2775 "$ALERT_SHARED_DIR" "$ALERT_SHARED_DIR/notify-state"
    log "shared alert dir $ALERT_SHARED_DIR (2775 root:$ALERT_GROUP)"
fi

ALERT_CONF="/etc/zfs-alert.conf"
OLD_ALERT_CONF="/root/scripts/zfs-alert.conf"
OLD_QUEUE="/root/scripts/alert-queue.log"
if [ "$CHECK_ONLY" -eq 0 ]; then
    # Migrate a host that was set up before the split. Move, don't copy: two
    # readable configs would be two sources of truth, and the scripts prefer
    # /etc, so a stale /root copy would silently do nothing while looking live.
    if [ -f "$OLD_ALERT_CONF" ] && [ ! -f "$ALERT_CONF" ]; then
        sed -e "s#^ZFS_ALERT_QUEUE=.*#ZFS_ALERT_QUEUE=$ALERT_SHARED_DIR/alert-queue.log#" \
            -e "s#^ZFS_ALERT_STATE_DIR=.*#ZFS_ALERT_STATE_DIR=$ALERT_SHARED_DIR/notify-state#" \
            "$OLD_ALERT_CONF" > "$ALERT_CONF" && rm -f "$OLD_ALERT_CONF"
        chmod 0644 "$ALERT_CONF"
        log "migrated $OLD_ALERT_CONF -> $ALERT_CONF (queue/state repointed at $ALERT_SHARED_DIR)"
    fi
    # Anything already queued must ride along, or the next digest reports a
    # quiet day that was not quiet.
    if [ -s "$OLD_QUEUE" ]; then
        cat "$OLD_QUEUE" >> "$ALERT_SHARED_DIR/alert-queue.log" && rm -f "$OLD_QUEUE"
        chgrp "$ALERT_GROUP" "$ALERT_SHARED_DIR/alert-queue.log" 2>/dev/null
        chmod 0664 "$ALERT_SHARED_DIR/alert-queue.log" 2>/dev/null
        log "migrated queued findings from $OLD_QUEUE"
    fi
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -r "$ALERT_CONF" ]; then
        log "  $ALERT_CONF present (mode: $(sed -n 's/^ZFS_ALERT_MODE=\([a-z]*\).*/\1/p' "$ALERT_CONF" | head -1))"
    else
        warn "  $ALERT_CONF missing -- alerting falls back to built-in defaults (daily)"
    fi
elif [ -e "$ALERT_CONF" ]; then
    log "$ALERT_CONF exists -- NOT overwritten (it is yours to edit; current mode: $(sed -n 's/^ZFS_ALERT_MODE=\([a-z]*\).*/\1/p' "$ALERT_CONF" | head -1))"
else
    cat > "$ALERT_CONF" <<EOF
# zfs-alert.conf -- how this host reports backup problems.
# Sourced by notify-fail.sh, notify-warn.sh and alert-digest.sh. Plain shell:
# VAR=value, no spaces around '='. Re-running deploy_new_server.sh never
# overwrites this file, so local changes survive an upgrade.
#
# ---------------------------------------------------------------------------
#  ZFS_ALERT_MODE   daily | immediate      <-- THE ONE TO CHANGE
# ---------------------------------------------------------------------------
#   daily      (default) findings are queued and alert-digest.sh sends exactly
#              ONE mail per host per day, covering alerts and warnings
#              together. A day with nothing to report sends no mail at all.
#              Chosen because at fleet scale a mail per finding is a stream the
#              operator starts filtering away.
#
#   immediate  every ALERT mails the moment it happens. SET THIS WHILE BRINGING
#              A HOST UP: a job you misconfigured today is a five-minute fix if
#              you hear about it within the hour, and a lost night of backups if
#              you read about it in tomorrow's digest. Switch back to daily once
#              the host has run clean for a few days.
#              Known cost, and the reason daily is the default: the rate limit
#              is per MESSAGE, so two different jobs failing in the same cron
#              tick send two separate mails at the same second.
#
# In immediate mode a finding is NOT also queued, so it is never reported twice.
ZFS_ALERT_MODE=${ALERT_MODE}

# Same choice for WARNING-tier findings ("getting stale", not yet critical).
# Leave on daily unless you have a specific reason: warnings are by definition
# the ones that are not urgent, and making them immediate is how an inbox that
# gets read turns into one that gets filtered.
ZFS_WARN_MODE=daily

# Where alerts go. Changing it here changes it for all three scripts at once.
ZFS_ALERT_EMAIL=${NOTIFY_EMAIL}

# Immediate mode only: seconds before the SAME message may mail again.
# Ignored entirely in daily mode (the digest de-duplicates by counting instead).
ZFS_ALERT_COOLDOWN=14400

# Immediate mode only: where the per-message cooldown timestamps live.
ZFS_ALERT_STATE_DIR=${ALERT_SHARED_DIR}/notify-state

# Queue file used by daily mode. The digest consumes it and deletes it; if mail
# delivery fails the findings are put back rather than dropped.
ZFS_ALERT_QUEUE=${ALERT_SHARED_DIR}/alert-queue.log

# When the daily mail goes out. This is the cron SCHEDULE, so it lives in the
# crontab, not here -- gen-cron.sh emits it (DIGEST_SCHEDULE, default 0 7 * * *).
EOF
    chmod 0644 "$ALERT_CONF"
    log "created $ALERT_CONF (ZFS_ALERT_MODE=$ALERT_MODE)"
fi

LOGROTATE_CONF="/etc/logrotate.d/zfs-snapshot-all"
LOGROTATE_MARKER="# zfs-snapshot-all logrotate v1"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -f "$LOGROTATE_CONF" ]; then log "  $LOGROTATE_CONF present"; else warn "  $LOGROTATE_CONF missing -- cron.log grows without bound"; fi
elif [ -e "$LOGROTATE_CONF" ] && grep -qF "$LOGROTATE_MARKER" "$LOGROTATE_CONF" 2>/dev/null; then
    log "$LOGROTATE_CONF already current, leaving it alone"
else
    # Measured before writing this: ~0.1 MB/day, i.e. 4-56 MB after 200-500 days,
    # and ZFS compresses that ~11x on disk. So rotation is for bounded worst case
    # and quick greps, NOT for space -- and retention stays LONG on purpose,
    # because diagnosing a backup problem means comparing runs weeks apart.
    #
    # The file list is explicit, never /root/scripts/*.log: alert-queue.log and
    # warn-queue.log live there too and are STATE, not logs. Rotating them would
    # move the queue out from under alert-digest.sh and silently discard every
    # finding waiting to be mailed.
    #
    # No copytruncate: each cron line opens its log fresh via 2>>, so a plain
    # rename is safe -- a job running across the rotation just finishes writing
    # into the .1 file. copytruncate would be strictly worse here, since it can
    # lose whatever is written during the copy window.
    cat > "$LOGROTATE_CONF" <<EOF
$LOGROTATE_MARKER -- managed by deploy_new_server.sh, re-run it to update.
# Deliberately NOT a *.log glob: the alert queue lives in the same directory and
# is state, not a log -- rotating it would throw away queued findings.
/root/scripts/cron.log
/root/scripts/git-pull.log
/root/scripts/zfs-snapshot-stats.log
{
    monthly
    rotate 24
    maxsize 50M
    compress
    delaycompress
    notifempty
    missingok
    create 0644 root root
}
EOF
    chmod 0644 "$LOGROTATE_CONF"
    log "created $LOGROTATE_CONF (monthly, keep 24, compressed)"
fi

if [ "$CHECK_ONLY" -eq 0 ] && command -v logrotate >/dev/null; then
    logrotate --debug "$LOGROTATE_CONF" >/dev/null 2>&1 \
        && log "  logrotate config parses cleanly" \
        || warn "  logrotate rejected $LOGROTATE_CONF -- check it by hand"
fi

NOTIFY_SCRIPT="/root/scripts/notify-fail.sh"
NOTIFY_SCRIPT_MARKER="# notify-fail.sh v6"   # bump this comment when the heredoc body below changes
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$NOTIFY_SCRIPT" ]; then
        warn "  $NOTIFY_SCRIPT missing -- job failures would be silent"
    elif grep -qF "$NOTIFY_SCRIPT_MARKER" "$NOTIFY_SCRIPT" 2>/dev/null; then
        log "  $NOTIFY_SCRIPT present (current)"
    else
        warn "  $NOTIFY_SCRIPT present but outdated (wrong queue path, or mails immediately) -- re-run without --check-only to upgrade"
    fi
elif [ -e "$NOTIFY_SCRIPT" ] && grep -qF "$NOTIFY_SCRIPT_MARKER" "$NOTIFY_SCRIPT" 2>/dev/null; then
    log "$NOTIFY_SCRIPT already current, leaving it alone"
else
    [ -e "$NOTIFY_SCRIPT" ] && log "$NOTIFY_SCRIPT exists but predates v4 -- upgrading (no more immediate mail; queues into the daily digest)"
    cat > "$NOTIFY_SCRIPT" <<EOF
#!/bin/bash
$NOTIFY_SCRIPT_MARKER -- reports an ALERT-tier finding: a cron job that returned
# non-zero, a CRITICAL/UNKNOWN staleness result, or a DEGRADED/FAULTED pool.
#
# WHETHER IT MAILS NOW OR WAITS FOR THE DAILY DIGEST IS CONFIGURED, NOT BAKED IN.
# Set ZFS_ALERT_MODE in /root/scripts/zfs-alert.conf:
#   daily      (default) queue it; alert-digest.sh sends one mail a day
#   immediate  mail it right now, rate-limited per message via
#              ZFS_ALERT_COOLDOWN. Recommended while bringing a host up.
# A finding is reported through exactly one of the two paths, never both.
#
# Why daily is the default: the immediate path's cooldown is keyed on the
# MESSAGE, so every distinct finding keeps its own counter and two jobs failing
# in the same cron tick send two mails in the same second. Volume then scales
# with the number of distinct findings rather than with hosts, and an operator
# who filters that away is worse off than one who reads a single daily summary.
#
# Either way Proxmox's own ZED pool-health mail is untouched, so a disk actually
# dropping out still pages immediately through that separate path.
# Usage in cron: ... 2>>cron.log || /root/scripts/notify-fail.sh "job description"
JOB="\$1"
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # deploy_backup_user.sh) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"

MODE="\${ZFS_ALERT_MODE:-daily}"
QUEUE="\${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
EMAIL="\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"

if [ "\$MODE" != "immediate" ]; then
    # One line per finding: epoch, severity, text. Short single-line appends to
    # the same file from concurrent cron jobs do not interleave (under PIPE_BUF).
    printf '%s\tALERT\t%s\n' "\$(date +%s)" "\$JOB" >> "\$QUEUE"
    exit 0
fi

HOST=\$(hostname -f 2>/dev/null || hostname)
NOW=\$(date '+%Y-%m-%d %H:%M:%S')
NOW_EPOCH=\$(date +%s)
STATE_DIR="\${ZFS_ALERT_STATE_DIR:-/var/lib/zfs-snapshot-all/notify-state}"
COOLDOWN="\${ZFS_ALERT_COOLDOWN:-14400}"
mkdir -p "\$STATE_DIR"

KEY=\$(printf '%s' "\$JOB" | md5sum | cut -d' ' -f1)
LASTFILE="\$STATE_DIR/\$KEY"
if [ -f "\$LASTFILE" ] && [ \$(( NOW_EPOCH - \$(cat "\$LASTFILE") )) -lt "\$COOLDOWN" ]; then
    # stderr, so the cron line's own 2>>cron.log swallows it. Unredirected, this
    # single line was itself a cron mail on every tick -- 96/day per monitor.
    echo "notify-fail.sh: suppressed repeat within cooldown -- \${JOB}" >&2
    exit 0
fi
echo "\$NOW_EPOCH" > "\$LASTFILE"

echo "ZFS alert: '\${JOB}' na \${HOST} o \${NOW}. Sprawdz /root/scripts/cron.log." \\
    | mail -s "[ZFS BACKUP] ALERT: \${JOB} na \${HOST}" "\$EMAIL"
EOF
    chmod +x "$NOTIFY_SCRIPT"
    log "created/upgraded $NOTIFY_SCRIPT (v4, queues -> alert-digest.sh)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "skipping the test email (check-only)"
elif command -v mail >/dev/null; then
    log "sending a test email to confirm mail delivery works from THIS host..."
    # Sent directly, NOT through notify-fail.sh: since v4 that only queues, so
    # routing the delivery smoke test through it would prove nothing about mail.
    echo "deploy_new_server.sh: test delivery from $(hostname -f 2>/dev/null || hostname) at $(date '+%Y-%m-%d %H:%M:%S')" \
        | mail -s "[ZFS BACKUP] test na $(hostname -f 2>/dev/null || hostname)" "$NOTIFY_EMAIL"
    log "check the target inbox ($NOTIFY_EMAIL) and/or 'tail -20 /var/log/mail.log' to confirm delivery."
    log "If it does NOT arrive: this host's postfix likely can't deliver externally without a relay"
    log "(no relayhost configured is fine IF direct delivery to the recipient's MX works, as it did"
    log "for pve0/pve1 -- but that is not guaranteed on every network. If it fails, you'll need to"
    log "configure relayhost/smarthost credentials for this host manually -- that's a per-host"
    log "decision (which SMTP relay, credentials), not something this script can pick for you.)"
else
    warn "no 'mail' command -- install mailutils/postfix, then re-run this script, or create $NOTIFY_SCRIPT manually"
fi

# ------------------------------------------------------------------------------
log "Part 4a: notify-warn.sh + alert-digest.sh (daily WARNING digest)"
# ------------------------------------------------------------------------------
# Companion to notify-fail.sh: CRITICAL/BROKEN monitor findings still mail
# immediately (rate-limited, Part 4 above). WARNING findings ("getting stale",
# past monitor_warn but not yet monitor_crit) are not urgent enough to
# interrupt anyone, so notify-warn.sh only queues them; alert-digest.sh mails
# one summary per day and is silent if nothing queued. gen-cron.sh wires both
# into the crontab on its own (WARN_SCRIPT/DIGEST_SCRIPT/DIGEST_SCHEDULE) --
# this part only makes sure the two scripts exist on disk.
WARN_SCRIPT="/root/scripts/notify-warn.sh"
WARN_SCRIPT_MARKER="# notify-warn.sh v4"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$WARN_SCRIPT" ]; then
        warn "  $WARN_SCRIPT missing -- WARNING monitor lines would error out"
    elif grep -qF "$WARN_SCRIPT_MARKER" "$WARN_SCRIPT" 2>/dev/null; then
        log "  $WARN_SCRIPT present (current)"
    else
        warn "  $WARN_SCRIPT present but outdated (wrong queue path) -- re-run without --check-only to upgrade"
    fi
elif [ -e "$WARN_SCRIPT" ] && grep -qF "$WARN_SCRIPT_MARKER" "$WARN_SCRIPT" 2>/dev/null; then
    log "$WARN_SCRIPT already current, leaving it alone"
else
    cat > "$WARN_SCRIPT" <<EOF
#!/bin/bash
$WARN_SCRIPT_MARKER -- reports a WARNING-tier monitor finding ("getting stale",
# past monitor_warn but not yet monitor_crit).
#
# Same queue and same line format as notify-fail.sh, differing only in the
# severity column -- that is what lets one digest cover both tiers in one mail.
# Controlled by ZFS_WARN_MODE in /root/scripts/zfs-alert.conf, separately from
# ZFS_ALERT_MODE: daily (default) or immediate. Leave it on daily unless you
# have a specific reason -- warnings are by definition the findings that are not
# urgent, so mailing them on sight is the fastest way to train someone to ignore
# the mailbox.
# Usage in cron: ... ; [ \$rc -eq 1 ] && /root/scripts/notify-warn.sh "job description"
JOB="\$1"
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # deploy_backup_user.sh) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"

QUEUE="\${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
if [ "\${ZFS_WARN_MODE:-daily}" = "immediate" ]; then
    HOST=\$(hostname -f 2>/dev/null || hostname)
    echo "ZFS warning: '\${JOB}' na \${HOST} o \$(date '+%Y-%m-%d %H:%M:%S')." \\
        | mail -s "[ZFS BACKUP] WARNING: \${JOB} na \${HOST}" "\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"
    exit 0
fi
printf '%s\tWARN\t%s\n' "\$(date +%s)" "\$JOB" >> "\$QUEUE"
EOF
    chmod +x "$WARN_SCRIPT"
    log "created/upgraded $WARN_SCRIPT (v2, shared queue)"
fi

DIGEST_SCRIPT="/root/scripts/alert-digest.sh"
DIGEST_SCRIPT_MARKER="# alert-digest.sh v4"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$DIGEST_SCRIPT" ]; then
        warn "  $DIGEST_SCRIPT missing -- findings would queue forever and never be seen"
    elif grep -qF "$DIGEST_SCRIPT_MARKER" "$DIGEST_SCRIPT" 2>/dev/null; then
        log "  $DIGEST_SCRIPT present (current)"
    else
        warn "  $DIGEST_SCRIPT present but outdated (wrong queue path, or WARN-only) -- re-run without --check-only to upgrade"
    fi
elif [ -e "$DIGEST_SCRIPT" ] && grep -qF "$DIGEST_SCRIPT_MARKER" "$DIGEST_SCRIPT" 2>/dev/null; then
    log "$DIGEST_SCRIPT already current, leaving it alone"
else
    cat > "$DIGEST_SCRIPT" <<EOF
#!/bin/bash
$DIGEST_SCRIPT_MARKER -- THE only mail this host sends about backups. Once a day
# it summarises everything notify-fail.sh (ALERT) and notify-warn.sh (WARN)
# queued since the last run, in ONE message, and is completely silent on a day
# with nothing to report.
#
# One mail per host per day is the whole point: at fleet scale the previous
# design (immediate mail per finding, rate-limited per message text) produced
# mail proportional to the number of distinct findings, so two jobs failing in
# the same cron tick sent two mails in the same second. An operator who filters
# the alerting away is worse off than one who reads a single daily summary.
#
# A silent day means "nothing was queued" -- it does NOT prove the host is
# healthy, since a dead cron would also be silent. That is the accepted
# trade-off: no per-host heartbeat mail, because at 18 hosts a daily "all OK"
# from each is exactly the noise this replaced.
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # deploy_backup_user.sh) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"

QUEUE="\${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
LEGACY_QUEUE="/root/scripts/warn-queue.log"
HOST=\$(hostname -f 2>/dev/null || hostname)
TODAY=\$(date '+%Y-%m-%d')

PROCESSING="\${QUEUE}.processing"

# Claim the queue first, so findings arriving mid-run land in the NEXT digest
# rather than being summarised and then deleted unread.
if [ -s "\$QUEUE" ]; then
    mv "\$QUEUE" "\$PROCESSING"
else
    : > "\$PROCESSING"
fi

# One-time carry-over: anything left by notify-warn.sh v1, which wrote a
# two-column line (epoch, message) to a separate file. Normalised to WARN so a
# host upgraded mid-day does not silently drop what it had already queued.
if [ -s "\$LEGACY_QUEUE" ]; then
    awk -F'\t' 'NF>=2 { printf "%s\tWARN\t%s\n", \$1, \$2 }' "\$LEGACY_QUEUE" >> "\$PROCESSING"
    rm -f "\$LEGACY_QUEUE"
fi

[ -s "\$PROCESSING" ] || { rm -f "\$PROCESSING"; exit 0; }

# Collapse to one row per (severity, message): count, first-seen, last-seen.
# Sorted ALERT before WARN, then by count descending -- the worst and the
# noisiest end up at the top of the mail where they get read.
SUMMARY=\$(awk -F'\t' '
{
    sev = \$2; if (sev != "ALERT") sev = "WARN"
    key = sev "\t" \$3
    count[key]++
    if (!(key in first) || \$1 < first[key]) first[key] = \$1
    if (!(key in last)  || \$1 > last[key])  last[key]  = \$1
}
END {
    for (k in count) {
        split(k, p, "\t")
        rank = (p[1] == "ALERT") ? 0 : 1
        printf "%d\t%s\t%d\t%s\t%d\t%d\n", rank, p[1], count[k], p[2], first[k], last[k]
    }
}' "\$PROCESSING" | sort -t\$'\t' -k1,1n -k3,3nr)

ALERT_BODY=""
WARN_BODY=""
N_ALERT=0
N_WARN=0
while IFS=\$'\t' read -r rank sev cnt msg first_ep last_ep; do
    [ -n "\$sev" ] || continue
    t1=\$(date -d "@\$first_ep" '+%H:%M')
    t2=\$(date -d "@\$last_ep" '+%H:%M')
    range="\$t1"; [ "\$t1" != "\$t2" ] && range="\$t1 - \$t2"
    line=\$(printf '  x%-4s %-55s (%s)' "\$cnt" "\$msg" "\$range")
    if [ "\$sev" = "ALERT" ]; then
        N_ALERT=\$((N_ALERT + 1))
        ALERT_BODY="\${ALERT_BODY}\${line}
"
    else
        N_WARN=\$((N_WARN + 1))
        WARN_BODY="\${WARN_BODY}\${line}
"
    fi
done <<< "\$SUMMARY"

TOTAL=\$(wc -l < "\$PROCESSING")

if {
    printf 'Host: %s   Doba: %s   Zdarzen: %s\n' "\$HOST" "\$TODAY" "\$TOTAL"
    if [ "\$N_ALERT" -gt 0 ]; then
        printf '\nALERT -- zadanie padlo, backup przeterminowany albo pula nie jest ONLINE:\n\n%s' "\$ALERT_BODY"
    fi
    if [ "\$N_WARN" -gt 0 ]; then
        printf '\nWARNING -- starzeje sie, jeszcze nie critical:\n\n%s' "\$WARN_BODY"
    fi
    printf '\nSzczegoly: /root/scripts/cron.log na %s\n' "\$HOST"
} | mail -s "[ZFS] \$HOST \$TODAY -- \$N_ALERT alert / \$N_WARN warn" "\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"; then
    rm -f "\$PROCESSING"
else
    # Mail failed (no MTA, relay refused, mailutils missing). Put the findings
    # back so the next run retries them: this is the ONLY copy, and the whole
    # point of a once-a-day digest is that a lost run is a lost DAY of alerting.
    # Deleting on failure is what the v1 digest did, and it silently discarded
    # everything queued whenever delivery broke.
    cat "\$PROCESSING" >> "\$QUEUE" 2>/dev/null && rm -f "\$PROCESSING"
    echo "alert-digest.sh: mail delivery failed -- \$TOTAL finding(s) requeued for the next run" >&2
    exit 1
fi
EOF
    chmod +x "$DIGEST_SCRIPT"
    log "created/upgraded $DIGEST_SCRIPT (v2, one mail/day covering ALERT+WARN)"
fi

# ------------------------------------------------------------------------------
log "Part 4b: auto-pull cron line (keeps this host's copy in sync with GitHub)"
# ------------------------------------------------------------------------------
PULL_LINE="15 * * * * cd $REPO_DIR && git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$REPO_DIR && git pull"; then
    log "auto-pull cron line already present, leaving it alone"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "auto-pull cron line MISSING -- this host would never pick up updates"
else
    ( crontab -l 2>/dev/null; echo "$PULL_LINE" ) | crontab -
    log "added auto-pull cron line: $PULL_LINE"
fi

# ------------------------------------------------------------------------------
log "Part 4c: single-instance lock sanity check (flock)"
# ------------------------------------------------------------------------------
TESTLOCK="/tmp/deploy_new_server_flock_test.$$"
( exec 200>"$TESTLOCK"; flock 200; sleep 3 ) &
HOLDER=$!
sleep 1
if ( exec 201>"$TESTLOCK"; flock -n 201 ); then
    warn "flock did NOT block a concurrent holder -- locking will not work as expected on this host/filesystem"
else
    log "flock correctly blocked a concurrent holder -- locking works"
fi
wait "$HOLDER" 2>/dev/null
rm -f "$TESTLOCK"

# ------------------------------------------------------------------------------
log "Part 4d: check-pool-capacity.sh (pool/quota capacity alerting)"
# ------------------------------------------------------------------------------
# Catches slow-fill pool/quota exhaustion BEFORE it turns into a job failure --
# notify-fail.sh only fires after a snapsend/delsnaps job has already broken.
# Added 2026-07-10 after a real incident: pve2's hdd pool hit 96% full and a
# fileserver LXC (subvol-101-disk-1) was independently at 91% of its own
# refquota, neither of which any existing alert would have caught in advance.
CAPACITY_SCRIPT="/root/scripts/check-pool-capacity.sh"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -x "$CAPACITY_SCRIPT" ]; then log "  $CAPACITY_SCRIPT present"; else warn "  $CAPACITY_SCRIPT missing -- no early warning before a pool fills up"; fi
elif [ -e "$CAPACITY_SCRIPT" ]; then
    log "$CAPACITY_SCRIPT already exists, leaving it alone (edit THRESHOLD/MAILTO inside manually if needed)"
else
    cat > "$CAPACITY_SCRIPT" <<EOF
#!/bin/bash
# Alerts by email if any zpool, or any dataset with a refquota set, crosses a
# capacity threshold.
# Usage in cron: 0 8 * * * /root/scripts/check-pool-capacity.sh
THRESHOLD=85
HOST=\$(hostname -f 2>/dev/null || hostname)
MAILTO="${NOTIFY_EMAIL}"

alert() {
    echo "\$2" | mail -s "[ZFS CAPACITY] \$1" "\$MAILTO"
}

for pool in \$(zpool list -H -o name); do
    cap=\$(zpool list -H -o capacity "\$pool" | tr -d '%')
    if [ "\$cap" -ge "\$THRESHOLD" ]; then
        alert "pula '\${pool}' na \${HOST}: \${cap}%" \\
              "Pula '\${pool}' na \${HOST} jest zapelniona w \${cap}% (prog: \${THRESHOLD}%)."
    fi
done

# IMPORTANT: compare against 'referenced', not 'used' -- 'used' includes all
# retained snapshots and will read as 100%+ even when the live filesystem
# itself has headroom, because refquota only constrains 'referenced'.
zfs list -Hp -o name,referenced,refquota -t filesystem | while IFS=\$'\t' read -r name referenced refquota; do
    [ "\$refquota" = "0" ] && continue
    pct=\$(( referenced * 100 / refquota ))
    if [ "\$pct" -ge "\$THRESHOLD" ]; then
        alert "dataset '\${name}' na \${HOST}: \${pct}%" \\
              "Dataset '\${name}' na \${HOST} wykorzystuje \${pct}% swojego refquota (prog: \${THRESHOLD}%)."
    fi
done
EOF
    chmod +x "$CAPACITY_SCRIPT"
    log "created $CAPACITY_SCRIPT (alerts -> $NOTIFY_EMAIL, threshold 85%)"
fi

CAPACITY_LINE="0 8 * * * $CAPACITY_SCRIPT 2>>/root/scripts/cron.log"
if crontab -l 2>/dev/null | grep -qF "$CAPACITY_SCRIPT"; then
    log "capacity-check cron line already present, leaving it alone"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "capacity-check cron line MISSING -- no early warning before a pool fills up"
else
    ( crontab -l 2>/dev/null; echo "$CAPACITY_LINE" ) | crontab -
    log "added capacity-check cron line: $CAPACITY_LINE"
fi

echo
log "===================================================================="
log "Dependency summary"
log "===================================================================="
if [ -n "$MISSING_OPTIONAL" ]; then
    warn "still missing:$MISSING_OPTIONAL"
    case "$MISSING_OPTIONAL" in
        *zstd*) warn "  zstd is the DEFAULT compressor -- every cron line using -z will FAIL on this host until it is installed, or you must pass -g to force pigz instead" ;;
    esac
    case "$MISSING_OPTIONAL" in
        *mail*) warn "  without 'mail' this host can run backups but cannot TELL YOU when one breaks -- fix before relying on it unattended" ;;
    esac
    case "$MISSING_OPTIONAL" in
        *ssh*)  warn "  without ssh only local (same-host) jobs will work" ;;
    esac
else
    log "all dependencies present"
fi

# In check-only mode the exit code IS the result -- 0 means this host is ready,
# non-zero means something above needs attention. The full deploy path keeps
# returning 0 on warnings, because there the warnings are advisory and the work
# has already been done.
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$PROBLEMS" -gt 0 ]; then
        warn "audit found $PROBLEMS issue(s) on $(hostname -s 2>/dev/null || hostname)"
        exit 1
    fi
    log "audit clean on $(hostname -s 2>/dev/null || hostname)"
    exit 0
fi

echo
log "===================================================================="
log "Automated part done. Manual steps remaining (Part 5, NOT scripted):"
log "===================================================================="
cat <<'EOF'

  1. Add the actual snapsend.sh / snapget.sh / delsnaps.sh cron lines for
     THIS host's datasets. There is no generic template here on purpose --
     copying another host's dataset names blindly is how backups silently
     stop protecting the right data. For each job, follow the pattern
     already used on pve0/pve1:

       <schedule> /root/scripts/zfs-snapshot-all/snapsend.sh -m <prefix> \
         [-e] [-r] [-u] [-z] -v 3 <DATASETS> [<REMOTE>] \
         2>>/root/scripts/cron.log || /root/scripts/notify-fail.sh "<short job name>"

     Same pattern for delsnaps.sh (retention) -- always pass -R and a
     specific enough pattern (e.g. automated_hourly, not just automated_)
     unless a flat/blanket retention is genuinely what you want for that
     host.

  2. Before adding a new schedule, sanity-check it against what's ALREADY
     in crontab -l on this host -- specifically watch for jobs that can
     legitimately overrun into the next scheduled slot for a DIFFERENT job
     touching related data (this is what caused the original silent
     backup-gap bug and the near-miss on hdd/lxc weekly snapshots). The
     per-target flock lock (added 2026-07-07) protects against two
     invocations of the SAME target colliding, but does not protect two
     DIFFERENT jobs from stepping on each other's dataset lifecycle
     (e.g. a pruning job racing a send job on the same dataset).

  3. After adding cron lines, verify with a manual dry-run first:
       ./snapsend.sh -n <DATASETS> [<REMOTE>]   # -n = read-only, no side effects
     and only then let cron pick it up.

  4. If mail alerting (Part 4 above) needs a relay because direct postfix
     delivery didn't work: that requires host-specific SMTP credentials and
     is a decision for a human, not this script -- see the notes it printed
     above.

EOF
