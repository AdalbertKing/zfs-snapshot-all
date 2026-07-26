#!/bin/bash
# ------------------------------------------------------------------------------
# deploy.sh -- one script, one host, everything zfs-snapshot-all needs.
#
# Replaces the old deploy_new_server.sh + deploy_backup_user.sh pair. That split
# was historical, not conceptual: it forced an ordering ("run the other one
# first") that lived in a human's head rather than in the code, duplicated the
# helpers and the repo-checkout logic, and produced two separate --check-only
# verdicts for one machine. Everything below runs in the only correct order.
#
# What it does, in order:
#   1 dependencies          6 smoke test of the shipped executables
#   2 repo checkout         7 root auto-pull cron line
#   3 shared alert state    8 delegated non-root account (optional, see below)
#   4 notify + digest
#   5 capacity alerting
#
# Idempotent: safe to re-run, every part skips what is already done. It does NOT
# touch the actual snapsend/snapget/delsnaps job lines -- those are per-host and
# belong to gen-cron.sh.
#
#   bash deploy.sh                      # host setup; maintains an existing
#                                       # delegated account if one is found
#   bash deploy.sh --check-only         # audit, change nothing
#   bash deploy.sh --alerts=immediate   # mail every finding (see below)
#   bash deploy.sh --backup-user=zfsbackup   # also CREATE the delegated account
# ------------------------------------------------------------------------------
set -uo pipefail

# ==============================================================================
#  WHAT THIS HOST GETS -- edit here, or override with a flag for one run
# ==============================================================================
# Where alerts are mailed.
NOTIFY_EMAIL="${NOTIFY_EMAIL:-lurk@lurk.com.pl}"

# daily     = queue findings, ONE summary mail per host per day (default)
# immediate = mail each finding as it happens. Worth setting while bringing a
#             host up: a misconfigured job you hear about within the hour is a
#             five-minute fix, the same mistake read in tomorrow's digest has
#             already cost a night of backups.
# Only used when /etc/zfs-alert.conf does not exist yet -- an existing one is
# never overwritten, so a hand-edited mode survives every re-run.
ALERT_MODE="daily"

# The delegated non-root account. THIS VARIABLE IS ABOUT CREATION, NOT
# MAINTENANCE:
#   empty        -- never create an account, but AUTO-DETECT an existing one and
#                   keep it maintained (scripts, log rotation, alert access)
#   "zfsbackup"  -- create it if missing, then maintain it
# So a bare `bash deploy.sh` does the right thing on every host in the fleet
# without anyone having to remember which machine has an account and which does
# not; creating one stays a deliberate, explicit act.
BACKUP_USER=""
BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"

REPO_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
REPO_DIR="/root/scripts/zfs-snapshot-all"
# ==============================================================================

# PROBLEMS lets --check-only return a meaningful exit code for the WHOLE host,
# account included -- so an audit can be driven from a loop over 18 hosts
# instead of being read by eye.
PROBLEMS=0
log() { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
die() { echo "FATAL: $*" >&2; exit 1; }

CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only)   CHECK_ONLY=1; shift ;;
        --alerts=*)     ALERT_MODE="${1#*=}"; shift ;;
        --alerts)       ALERT_MODE="${2:-}"; shift 2 ;;
        --backup-user=*) BACKUP_USER="${1#*=}"; shift ;;
        --backup-user)  BACKUP_USER="${2:-}"; shift 2 ;;
        --datasets=*)   BACKUP_USER_DATASETS="${1#*=}"; shift ;;
        --datasets)     BACKUP_USER_DATASETS="${2:-}"; shift 2 ;;
        --email=*)      NOTIFY_EMAIL="${1#*=}"; shift ;;
        --email)        NOTIFY_EMAIL="${2:-}"; shift 2 ;;
        -h|--help)
            cat <<'USAGE'
Usage: deploy.sh [options]
  --check-only            audit only; install, create and modify nothing
  --alerts=daily          (default) queue findings, one summary mail per day
  --alerts=immediate      mail each finding at once -- use while bringing a host up
  --backup-user=NAME      also create the delegated non-root account NAME.
                          Omit it and an EXISTING account is still detected and
                          maintained; only creation needs to be asked for.
  --datasets="A B"        datasets to delegate to that account
  --email=ADDR            where alerts are mailed
Defaults are the config block at the top of this script -- edit them there to
make them permanent for a host.
USAGE
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
log "Phase 1: dependencies"
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
log "Phase 2: deploy the repo into $REPO_DIR"
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
log "Phase 6: verify the deployment"
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
log "Phase 4: notify-fail.sh (alert reporting)"
# ------------------------------------------------------------------------------
# Shared alerting state, deliberately OUTSIDE /root. /root is 0700, so a
# delegated non-root service account (phase 8) cannot reach
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
    # An existing queue may predate the umask fix and be 0644, which locks out
    # whichever account did not happen to create it. Cheap to correct every run.
    if [ -f "$ALERT_SHARED_DIR/alert-queue.log" ]; then
        chgrp "$ALERT_GROUP" "$ALERT_SHARED_DIR/alert-queue.log" 2>/dev/null
        chmod 0664 "$ALERT_SHARED_DIR/alert-queue.log" 2>/dev/null
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
# VAR=value, no spaces around '='. Re-running deploy.sh never
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
$LOGROTATE_MARKER -- managed by deploy.sh, re-run it to update.
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
NOTIFY_SCRIPT_MARKER="# notify-fail.sh v9"   # bump this comment when the heredoc body below changes
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
# Usage in cron:
#   ... || /root/scripts/notify-fail.sh "job description" "what it actually said"
#
# The SECOND argument is the finding itself: the failing command's own output, or
# check-snap-age.sh's verdict line carrying the real dataset, age and thresholds.
# Without it the digest can only report that something called "pve0 hourly backup
# (vm-101)" went wrong -- a label from the config, nothing anyone can act on --
# while the actual text went to cron.log where nobody reads it. Optional, so cron
# lines generated before v4.16 keep working unchanged.
JOB="\$1"
DETAIL="\${2:-}"
# The ENVIRONMENT wins over the config file. Sourcing the config last looks
# harmless until you notice these are exactly the knobs a test sets: a run with
# ZFS_ALERT_QUEUE pointed at a scratch file silently used the PRODUCTION queue
# instead -- summarised it, mailed it and deleted it. Snapshot the env values
# before the config can overwrite them, then put them back.
_E_MODE="\${ZFS_ALERT_MODE:-}"; _E_WMODE="\${ZFS_WARN_MODE:-}"
_E_QUEUE="\${ZFS_ALERT_QUEUE:-}"; _E_EMAIL="\${ZFS_ALERT_EMAIL:-}"
_E_STATE="\${ZFS_ALERT_STATE_DIR:-}"
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # phase 8) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"
_restore_env() {
    [ -n "\$_E_MODE" ]  && ZFS_ALERT_MODE="\$_E_MODE"
    [ -n "\$_E_WMODE" ] && ZFS_WARN_MODE="\$_E_WMODE"
    [ -n "\$_E_QUEUE" ] && ZFS_ALERT_QUEUE="\$_E_QUEUE"
    [ -n "\$_E_EMAIL" ] && ZFS_ALERT_EMAIL="\$_E_EMAIL"
    [ -n "\$_E_STATE" ] && ZFS_ALERT_STATE_DIR="\$_E_STATE"
    return 0
}
_restore_env

MODE="\${ZFS_ALERT_MODE:-daily}"
QUEUE="\${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
EMAIL="\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"

if [ "\$MODE" != "immediate" ]; then
    # One line per finding: epoch, severity, text. Short single-line appends to
    # the same file from concurrent cron jobs do not interleave (under PIPE_BUF).
    # 0002, so that if THIS process is the one that recreates the queue after
    # the digest consumed it, the file lands group-writable. Both root and the
    # delegated account append here; whichever gets there first would otherwise
    # create it 0644 and lock the other one out until the next digest run.
    umask 0002
    # Four tab-separated columns now: epoch, severity, label, detail. A finding
    # has to stay ONE line -- concurrent appends from separate cron jobs are only
    # atomic while each write is a single short line (PIPE_BUF) -- so the detail
    # is flattened: tabs to spaces so the field split survives, newlines to \001,
    # which alert-digest.sh turns back into newlines. A control byte rather than
    # a backslash escape, because nothing in a ZFS error message can collide
    # with it and there is no un-escaping to get wrong.
    DETAIL_FLAT=\$(printf '%s' "\$DETAIL" | tr '\t' ' ' | tr '\n' '\001')
    printf '%s\tALERT\t%s\t%s\n' "\$(date +%s)" "\$JOB" "\$DETAIL_FLAT" >> "\$QUEUE"
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

{
    printf "ZFS alert: '%s' na %s o %s.\n" "\${JOB}" "\${HOST}" "\${NOW}"
    if [ -n "\$DETAIL" ]; then
        printf '\nCo zglosilo zadanie:\n\n'
        printf '%s\n' "\$DETAIL" | sed 's/^/    /'
    fi
    printf '\nPelny log: /root/scripts/cron.log na %s\n' "\${HOST}"
} | mail -s "[ZFS BACKUP] ALERT: \${JOB} na \${HOST}" "\$EMAIL"
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
    echo "deploy.sh: test delivery from $(hostname -f 2>/dev/null || hostname) at $(date '+%Y-%m-%d %H:%M:%S')" \
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
log "Phase 4a: notify-warn.sh + alert-digest.sh (the daily digest)"
# ------------------------------------------------------------------------------
# Companion to notify-fail.sh: CRITICAL/BROKEN monitor findings still mail
# immediately (rate-limited, Part 4 above). WARNING findings ("getting stale",
# past monitor_warn but not yet monitor_crit) are not urgent enough to
# interrupt anyone, so notify-warn.sh only queues them; alert-digest.sh mails
# one summary per day and is silent if nothing queued. gen-cron.sh wires both
# into the crontab on its own (WARN_SCRIPT/DIGEST_SCRIPT/DIGEST_SCHEDULE) --
# this part only makes sure the two scripts exist on disk.
WARN_SCRIPT="/root/scripts/notify-warn.sh"
WARN_SCRIPT_MARKER="# notify-warn.sh v7"
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
# Usage in cron:
#   ... ; [ \$rc -eq 1 ] && /root/scripts/notify-warn.sh "label" "\$verdict"
# The second argument is check-snap-age.sh's own verdict line -- dataset,
# pattern, newest snapshot, actual age, thresholds. See notify-fail.sh for why a
# label alone is not enough to act on.
JOB="\$1"
DETAIL="\${2:-}"
# The ENVIRONMENT wins over the config file. Sourcing the config last looks
# harmless until you notice these are exactly the knobs a test sets: a run with
# ZFS_ALERT_QUEUE pointed at a scratch file silently used the PRODUCTION queue
# instead -- summarised it, mailed it and deleted it. Snapshot the env values
# before the config can overwrite them, then put them back.
_E_MODE="\${ZFS_ALERT_MODE:-}"; _E_WMODE="\${ZFS_WARN_MODE:-}"
_E_QUEUE="\${ZFS_ALERT_QUEUE:-}"; _E_EMAIL="\${ZFS_ALERT_EMAIL:-}"
_E_STATE="\${ZFS_ALERT_STATE_DIR:-}"
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # phase 8) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"
_restore_env() {
    [ -n "\$_E_MODE" ]  && ZFS_ALERT_MODE="\$_E_MODE"
    [ -n "\$_E_WMODE" ] && ZFS_WARN_MODE="\$_E_WMODE"
    [ -n "\$_E_QUEUE" ] && ZFS_ALERT_QUEUE="\$_E_QUEUE"
    [ -n "\$_E_EMAIL" ] && ZFS_ALERT_EMAIL="\$_E_EMAIL"
    [ -n "\$_E_STATE" ] && ZFS_ALERT_STATE_DIR="\$_E_STATE"
    return 0
}
_restore_env

QUEUE="\${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
if [ "\${ZFS_WARN_MODE:-daily}" = "immediate" ]; then
    HOST=\$(hostname -f 2>/dev/null || hostname)
    {
        printf "ZFS warning: '%s' na %s o %s.\n" "\${JOB}" "\${HOST}" "\$(date '+%Y-%m-%d %H:%M:%S')"
        [ -n "\$DETAIL" ] && { printf '\nCo zglosil monitor:\n\n'; printf '%s\n' "\$DETAIL" | sed 's/^/    /'; }
    } | mail -s "[ZFS BACKUP] WARNING: \${JOB} na \${HOST}" "\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"
    exit 0
fi
# See notify-fail.sh: keep a recreated queue writable by BOTH accounts.
umask 0002
DETAIL_FLAT=\$(printf '%s' "\$DETAIL" | tr '\t' ' ' | tr '\n' '\001')
printf '%s\tWARN\t%s\t%s\n' "\$(date +%s)" "\$JOB" "\$DETAIL_FLAT" >> "\$QUEUE"
EOF
    chmod +x "$WARN_SCRIPT"
    log "created/upgraded $WARN_SCRIPT (v2, shared queue)"
fi

DIGEST_SCRIPT="/root/scripts/alert-digest.sh"
DIGEST_SCRIPT_MARKER="# alert-digest.sh v8"
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
# The ENVIRONMENT wins over the config file. Sourcing the config last looks
# harmless until you notice these are exactly the knobs a test sets: a run with
# ZFS_ALERT_QUEUE pointed at a scratch file silently used the PRODUCTION queue
# instead -- summarised it, mailed it and deleted it. Snapshot the env values
# before the config can overwrite them, then put them back.
_E_MODE="\${ZFS_ALERT_MODE:-}"; _E_WMODE="\${ZFS_WARN_MODE:-}"
_E_QUEUE="\${ZFS_ALERT_QUEUE:-}"; _E_EMAIL="\${ZFS_ALERT_EMAIL:-}"
_E_STATE="\${ZFS_ALERT_STATE_DIR:-}"
CONF="\${ZFS_ALERT_CONF:-}"
if [ -z "\$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # phase 8) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "\$c" ] && { CONF="\$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "\$CONF" ] && . "\$CONF"
_restore_env() {
    [ -n "\$_E_MODE" ]  && ZFS_ALERT_MODE="\$_E_MODE"
    [ -n "\$_E_WMODE" ] && ZFS_WARN_MODE="\$_E_WMODE"
    [ -n "\$_E_QUEUE" ] && ZFS_ALERT_QUEUE="\$_E_QUEUE"
    [ -n "\$_E_EMAIL" ] && ZFS_ALERT_EMAIL="\$_E_EMAIL"
    [ -n "\$_E_STATE" ] && ZFS_ALERT_STATE_DIR="\$_E_STATE"
    return 0
}
_restore_env

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
# The fourth column (detail) is what the finding actually SAID -- the failing
# command's output, or the monitor's verdict with the real age and thresholds.
# Kept from the LAST occurrence: for a condition repeating every 15 minutes the
# most recent reading is the one that describes the state now. Lines queued
# before v8/v6 have no fourth column and simply carry no detail.
SUMMARY=\$(awk -F'\t' '
{
    sev = \$2; if (sev != "ALERT") sev = "WARN"
    key = sev "\t" \$3
    count[key]++
    if (!(key in first) || \$1 < first[key]) first[key] = \$1
    if (!(key in last)  || \$1 > last[key])  { last[key] = \$1; detail[key] = \$4 }
}
END {
    for (k in count) {
        split(k, p, "\t")
        rank = (p[1] == "ALERT") ? 0 : 1
        printf "%d\t%s\t%d\t%s\t%d\t%d\t%s\n", rank, p[1], count[k], p[2], first[k], last[k], detail[k]
    }
}' "\$PROCESSING" | sort -t\$'\t' -k1,1n -k3,3nr)

ALERT_BODY=""
WARN_BODY=""
N_ALERT=0
N_WARN=0
while IFS=\$'\t' read -r rank sev cnt msg first_ep last_ep detail; do
    [ -n "\$sev" ] || continue
    t1=\$(date -d "@\$first_ep" '+%H:%M')
    t2=\$(date -d "@\$last_ep" '+%H:%M')
    range="\$t1"; [ "\$t1" != "\$t2" ] && range="\$t1 - \$t2"
    line=\$(printf '  x%-4s %-55s (%s)' "\$cnt" "\$msg" "\$range")
    # Unflatten and indent under the heading it belongs to. \001 went in where
    # the newlines were; a multi-line failure comes back out as multiple lines.
    #
    # A row with NO detail says so, rather than just looking thin: silence there
    # is ambiguous -- it could be an entry queued before the detail existed, or
    # a caller that forgot to pass it -- and the reader cannot tell which.
    if [ -n "\$detail" ]; then
        line="\$line
\$(printf '%s' "\$detail" | tr '\001' '\n' | sed 's/^/        /')"
    else
        line="\$line
        (bez szczegolow -- wpis zakolejkowany przed przebudowa alertow)"
    fi
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
    (umask 0002; cat "\$PROCESSING" >> "\$QUEUE") 2>/dev/null && rm -f "\$PROCESSING"
    echo "alert-digest.sh: mail delivery failed -- \$TOTAL finding(s) requeued for the next run" >&2
    exit 1
fi
EOF
    chmod +x "$DIGEST_SCRIPT"
    log "created/upgraded $DIGEST_SCRIPT (v2, one mail/day covering ALERT+WARN)"
fi

# ------------------------------------------------------------------------------
log "Phase 7: auto-pull cron line (keeps this host's copy in sync with GitHub)"
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
log "Phase 6a: single-instance lock sanity check (flock)"
# ------------------------------------------------------------------------------
TESTLOCK="/tmp/deploy_flock_test.$$"
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
log "Phase 5: check-pool-capacity.sh (pool/quota capacity alerting)"
# ------------------------------------------------------------------------------
# Catches slow-fill pool/quota exhaustion BEFORE it turns into a job failure --
# notify-fail.sh only fires after a snapsend/delsnaps job has already broken.
# Added 2026-07-10 after a real incident: pve2's hdd pool hit 96% full and a
# fileserver LXC (subvol-101-disk-1) was independently at 91% of its own
# refquota, neither of which any existing alert would have caught in advance.
CAPACITY_SCRIPT="/root/scripts/check-pool-capacity.sh"
CAPACITY_SCRIPT_MARKER="# check-pool-capacity.sh v2"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$CAPACITY_SCRIPT" ]; then
        warn "  $CAPACITY_SCRIPT missing -- no early warning before a pool fills up"
    elif grep -qF "$CAPACITY_SCRIPT_MARKER" "$CAPACITY_SCRIPT" 2>/dev/null; then
        log "  $CAPACITY_SCRIPT present (current)"
    else
        warn "  $CAPACITY_SCRIPT present but outdated (mails on its own instead of joining the daily digest) -- re-run without --check-only to upgrade"
    fi
elif [ -e "$CAPACITY_SCRIPT" ] && grep -qF "$CAPACITY_SCRIPT_MARKER" "$CAPACITY_SCRIPT" 2>/dev/null; then
    log "$CAPACITY_SCRIPT already current, leaving it alone"
else
    cat > "$CAPACITY_SCRIPT" <<EOF
#!/bin/bash
$CAPACITY_SCRIPT_MARKER -- warns before a zpool, or a dataset with a refquota,
# fills up. Catches slow exhaustion BEFORE it turns into a failed job.
#
# It reports through notify-fail.sh rather than mailing directly. Sending its
# own mail made it the one thing on the host that ignored the one-mail-per-day
# rule, and at fleet scale a second channel is a second thing to start
# filtering. Going through the queue also means the finding arrives with its
# numbers attached, in the same digest as everything else.
# Usage in cron: 0 8 * * * /root/scripts/check-pool-capacity.sh
THRESHOLD=85
HOST=\$(hostname -f 2>/dev/null || hostname)
NOTIFY="\${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"

alert() {
    if [ -x "\$NOTIFY" ]; then
        "\$NOTIFY" "\$1" "\$2"
    else
        echo "\$2" | mail -s "[ZFS CAPACITY] \$1" "${NOTIFY_EMAIL}"
    fi
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



# ------------------------------------------------------------------------------
log "Phase 8: delegated non-root account"
# ------------------------------------------------------------------------------
# BACKUP_USER is about CREATION. Maintenance is automatic: if it is empty we
# look for an account that already has its own checkout and keep that one up to
# date. That is what lets a bare `bash deploy.sh` be correct on every host in
# the fleet without anyone tracking which machine has an account.
CREATE_ACCOUNT=1
if [ -z "$BACKUP_USER" ]; then
    CREATE_ACCOUNT=0
    for _cand in /home/*/zfs-snapshot-all; do
        [ -d "$_cand" ] || continue
        _owner=$(stat -c %U "$(dirname "$_cand")" 2>/dev/null) || continue
        id "$_owner" >/dev/null 2>&1 && { BACKUP_USER="$_owner"; break; }
    done
    [ -n "$BACKUP_USER" ] && log "detected existing delegated account: $BACKUP_USER (maintaining it; pass --backup-user to create one)"
fi

if [ -z "$BACKUP_USER" ]; then
    log "no delegated account on this host and none requested -- skipping (pass --backup-user=NAME to create one)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    if id "$BACKUP_USER" >/dev/null 2>&1; then
        log "  account $BACKUP_USER exists"
        id -nG "$BACKUP_USER" | tr ' ' '
' | grep -qx "zfsalert" || warn "  $BACKUP_USER not in group zfsalert -- it could not queue alerts"
        [ -x "/home/$BACKUP_USER/notify-fail.sh" ] || warn "  /home/$BACKUP_USER/notify-fail.sh missing -- that account cannot report findings"
        [ -f "/etc/logrotate.d/zfs-snapshot-all-$BACKUP_USER" ] || warn "  no logrotate stanza for $BACKUP_USER"
    else
        warn "  account $BACKUP_USER does not exist -- re-run without --check-only to create it"
    fi
elif [ "$CREATE_ACCOUNT" -eq 0 ] && ! id "$BACKUP_USER" >/dev/null 2>&1; then
    log "no delegated account to maintain -- skipping"
else
    USERNAME="$BACKUP_USER"
    HOMEDIR="/home/$USERNAME"
    # shellcheck disable=SC2206
    DATASETS=($BACKUP_USER_DATASETS)
    ACCOUNT_REPO_DIR="$HOMEDIR/zfs-snapshot-all"
    # ------------------------------------------------------------------------------
    log "Phase 8a: service account $USERNAME"
    # ------------------------------------------------------------------------------
    if id "$USERNAME" >/dev/null 2>&1; then
        log "user $USERNAME already exists, leaving it alone"
    else
        useradd -m -s /bin/bash -c "zfs-snapshot-all delegated backup account" "$USERNAME" \
            || die "useradd failed"
        passwd -l "$USERNAME" >/dev/null || warn "could not lock password for $USERNAME"
        log "created user $USERNAME (uid $(id -u "$USERNAME")), password locked (SSH key only)"
    fi

    # ------------------------------------------------------------------------------
    log "Phase 8b: lock/state directory"
    # ------------------------------------------------------------------------------
    RUNDIR="$HOMEDIR/run"
    mkdir -p "$RUNDIR"
    chown "$USERNAME:$USERNAME" "$RUNDIR"
    log "LOCKDIR for this account: $RUNDIR"

    # ------------------------------------------------------------------------------
    log "Phase 8c: SSH keypair"
    # ------------------------------------------------------------------------------
    SSHDIR="$HOMEDIR/.ssh"
    if [ -f "$SSHDIR/id_ed25519" ]; then
        log "SSH keypair already exists, leaving it alone"
    else
        su "$USERNAME" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C '${USERNAME}@$(hostname -s)'" \
            || die "ssh-keygen failed"
    fi
    log "public key (see Part 6 below for what to do with it):"
    cat "$SSHDIR/id_ed25519.pub"

    # ------------------------------------------------------------------------------
    log "Phase 8d: repo checkout at $ACCOUNT_REPO_DIR (readable+executable by $USERNAME)"
    # ------------------------------------------------------------------------------
    if [ -d "$ACCOUNT_REPO_DIR/.git" ]; then
        log "$ACCOUNT_REPO_DIR is already a git repo, pulling..."
        su "$USERNAME" -c "git -C '$ACCOUNT_REPO_DIR' remote get-url origin 2>/dev/null" | grep -qF "$REPO_URL" \
            || warn "existing repo's origin does not match $REPO_URL -- check manually"
        su "$USERNAME" -c "git -C '$ACCOUNT_REPO_DIR' pull --ff-only origin main" \
            || die "git pull --ff-only failed -- local repo has diverged, resolve manually"

    elif [ -d "$ACCOUNT_REPO_DIR" ] && [ -n "$(ls -A "$ACCOUNT_REPO_DIR" 2>/dev/null)" ]; then
        log "$ACCOUNT_REPO_DIR exists with files but is not a git repo (plain scripts from an earlier manual copy?)"
        BACKUP_DIR="${REPO_DIR}.bak-preGit-$(date +%Y%m%d%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        for f in snapsend.sh snapget.sh delsnaps.sh gen-cron.sh; do
            if [ -e "$ACCOUNT_REPO_DIR/$f" ]; then
                mv "$ACCOUNT_REPO_DIR/$f" "$BACKUP_DIR/"
                log "  moved $f -> $BACKUP_DIR/"
            fi
        done
        chown -R "$USERNAME:$USERNAME" "$BACKUP_DIR"

        su "$USERNAME" -c "cd '$ACCOUNT_REPO_DIR' && git init && git remote add origin '$REPO_URL' && git fetch origin && git checkout -b main --track origin/main" \
            || die "git init/checkout failed"

        log "Diff against backup (should be empty besides new .git/.gitignore/.gitattributes):"
        diff -rq "$BACKUP_DIR" "$ACCOUNT_REPO_DIR" 2>&1 | grep -v "^Only in $ACCOUNT_REPO_DIR:" || true

    else
        log "$ACCOUNT_REPO_DIR does not exist or is empty -- plain clone"
        su "$USERNAME" -c "git clone '$REPO_URL' '$ACCOUNT_REPO_DIR'" || die "git clone failed"
    fi
    # Only the standalone executables, NEVER a blanket *.sh. lib-zfs-snap.sh is
    # sourced, not executed, and git tracks it as 100644 -- chmod +x on it makes
    # the checkout permanently dirty with a mode change, and the hourly
    # `git pull --ff-only` this account runs then FAILS the first time that file
    # changes upstream. Found on both metropolis accounts, inherited from the
    # old deploy_backup_user.sh.
    for f in snapsend.sh snapget.sh delsnaps.sh gen-cron.sh check-snap-age.sh deploy.sh; do
        [ -e "$ACCOUNT_REPO_DIR/$f" ] && chmod +x "$ACCOUNT_REPO_DIR/$f"
    done

    # ------------------------------------------------------------------------------
    log "Phase 8e: auto-pull cron line (this account's own crontab)"
    # ------------------------------------------------------------------------------
    PULL_LINE="15 * * * * cd $ACCOUNT_REPO_DIR && git pull --ff-only origin main >>$HOMEDIR/git-pull.log 2>&1"
    if su "$USERNAME" -c "crontab -l 2>/dev/null" | grep -qF "$ACCOUNT_REPO_DIR && git pull"; then
        log "auto-pull cron line already present, leaving it alone"
    else
        su "$USERNAME" -c "(crontab -l 2>/dev/null; echo '$PULL_LINE') | crontab -" \
            || warn "could not install auto-pull cron line -- add it manually"
        log "added auto-pull cron line to $USERNAME's crontab"
    fi

    # ------------------------------------------------------------------------------
    log "Phase 8f: alerting access + log rotation for this account"
    # ------------------------------------------------------------------------------
    # This account cannot see ANYTHING under /root: that directory is 0700, so the
    # notify scripts, the alert config and the alert queue are all out of reach.
    # The shortcut of opening /root/scripts to a group is a privilege escalation --
    # root executes those scripts from cron, so an account able to write there could
    # replace them. Instead the two accounts share one group-writable DATA directory
    # (created in phase 3 above) and this account gets its own copies of the
    # two reporting scripts. alert-digest.sh stays root-only and reads the shared
    # queue, so the host still sends exactly ONE mail a day covering both accounts.
    ALERT_GROUP="zfsalert"
    ALERT_SHARED_DIR="/var/lib/zfs-snapshot-all"
    ALERT_CONF="/etc/zfs-alert.conf"

    # No "did you run the other script first" guard here any more: phase 3 of THIS
    # script created the group and the shared directory a few hundred lines above.
    # Removing that ordering dependency is the whole point of the merge.
        if id -nG "$USERNAME" | tr ' ' '\n' | grep -qx "$ALERT_GROUP"; then
            log "$USERNAME already in group $ALERT_GROUP"
        else
            usermod -aG "$ALERT_GROUP" "$USERNAME" && log "added $USERNAME to group $ALERT_GROUP"
            log "  NOTE: group membership applies to NEW sessions -- this account's cron picks it up on its next run"
        fi

        # Same two scripts root has, same shared queue, same config. Only the digest
        # is not duplicated: two digests would mean two mails per host per day.
        for s in notify-fail notify-warn; do
            if [ -f "/root/scripts/$s.sh" ]; then
                install -o "$USERNAME" -g "$USERNAME" -m 0755 "/root/scripts/$s.sh" "$HOMEDIR/$s.sh" \
                    && log "installed $HOMEDIR/$s.sh (copy of root's, same shared queue)"
            else
                warn "/root/scripts/$s.sh not found -- $USERNAME has no way to report findings"
            fi
        done
        [ -r "$ALERT_CONF" ] || warn "$ALERT_CONF missing -- this account will fall back to built-in defaults (daily)"

    LOGROTATE_CONF="/etc/logrotate.d/zfs-snapshot-all-$USERNAME"
    LOGROTATE_MARKER="# zfs-snapshot-all $USERNAME logrotate v1"
    if [ -e "$LOGROTATE_CONF" ] && grep -qF "$LOGROTATE_MARKER" "$LOGROTATE_CONF" 2>/dev/null; then
        log "$LOGROTATE_CONF already current, leaving it alone"
    else
        # A SEPARATE stanza from root's, and the reason is 'create': rotating these
        # with root's stanza would hand the fresh file to root:root, and this account
        # -- which owns the directory but not that file -- could no longer append.
        # Its cron would stop logging silently, since the redirect is >> in the
        # background with nobody reading the error.
        cat > "$LOGROTATE_CONF" <<EOF
$LOGROTATE_MARKER -- managed by deploy.sh, re-run it to update.
$HOMEDIR/git-pull.log
$HOMEDIR/zfs-snapshot-stats.log
{
    monthly
    rotate 24
    maxsize 50M
    compress
    delaycompress
    notifempty
    missingok
    su $USERNAME $USERNAME
    create 0644 $USERNAME $USERNAME
}
EOF
        chmod 0644 "$LOGROTATE_CONF"
        log "created $LOGROTATE_CONF (monthly, keep 24, owned by $USERNAME)"
    fi
    if command -v logrotate >/dev/null; then
        logrotate --debug "$LOGROTATE_CONF" >/dev/null 2>&1 \
            && log "  logrotate config parses cleanly" \
            || warn "  logrotate rejected $LOGROTATE_CONF -- check it by hand"
    fi

    # ------------------------------------------------------------------------------
    log "Phase 8g: ZFS delegation on ${DATASETS[*]}"
    # ------------------------------------------------------------------------------
    # 'bookmark' is easy to leave out and fails quietly: without it every send
    # ends "cannot create bookmark ... permission denied", logged as non-fatal,
    # and the transfer still succeeds -- so nothing alerts. What is lost is the
    # bookmark-backed incremental fallback: once the common-base SNAPSHOT is
    # pruned on the source, that pair can only recover with a full resend.
    # Found live on metropolis pve1, 2026-07-25.
    ZFS_PERMS="snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark"
    for ds in "${DATASETS[@]}"; do
        if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
            warn "dataset $ds does not exist on this host -- skipping (create it first, then: zfs allow -u $USERNAME $ZFS_PERMS $ds)"
            continue
        fi
        zfs allow -u "$USERNAME" "$ZFS_PERMS" "$ds" || die "zfs allow failed for $ds"
        log "delegated on $ds:"
        zfs allow "$ds" | grep "$USERNAME" || true
    done

    echo
    log "===================================================================="
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
