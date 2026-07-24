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
#   - notify-fail.sh mail-alert helper (fires on job failure, CRITICAL/UNKNOWN
#     staleness, or a DEGRADED/FAULTED pool -- rate-limited per unique message)
#   - notify-warn.sh + alert-digest.sh (queues WARNING-tier staleness findings,
#     mails one grouped summary/day instead of one mail per occurrence)
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
case "${1:-}" in
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help)
        echo "Usage: $0 [--check-only]"
        echo "  --check-only   audit dependencies and the checkout; make no changes"
        exit 0 ;;
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
NOTIFY_SCRIPT="/root/scripts/notify-fail.sh"
NOTIFY_SCRIPT_MARKER="# notify-fail.sh v3"   # bump this comment when the heredoc body below changes
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$NOTIFY_SCRIPT" ]; then
        warn "  $NOTIFY_SCRIPT missing -- job failures would be silent"
    elif grep -qF "$NOTIFY_SCRIPT_MARKER" "$NOTIFY_SCRIPT" 2>/dev/null; then
        log "  $NOTIFY_SCRIPT present (v3, rate-limited)"
    else
        warn "  $NOTIFY_SCRIPT present but pre-v3 (old \"job failed\" wording, or no rate-limit) -- re-run without --check-only to upgrade"
    fi
elif [ -e "$NOTIFY_SCRIPT" ] && grep -qF "$NOTIFY_SCRIPT_MARKER" "$NOTIFY_SCRIPT" 2>/dev/null; then
    log "$NOTIFY_SCRIPT already at v3, leaving it alone (edit NOTIFY_EMAIL/NOTIFY_COOLDOWN inside manually if needed)"
else
    [ -e "$NOTIFY_SCRIPT" ] && log "$NOTIFY_SCRIPT exists but predates v3 -- upgrading (rate-limit + neutral wording)"
    cat > "$NOTIFY_SCRIPT" <<EOF
#!/bin/bash
$NOTIFY_SCRIPT_MARKER -- sends an alert email for a cron job that returned
# non-zero, a CRITICAL/UNKNOWN staleness finding, or a DEGRADED/FAULTED pool.
# Suppresses repeat sends of the SAME message within a cooldown window so a
# flapping check (schedule drift, a stuck CRITICAL) does not flood the inbox
# with dozens of identical mails. Wording is deliberately NOT "job failed" --
# JOB is not always a job that failed (e.g. a pool-health finding is a report,
# not a failure), so a fixed "zakonczylo sie bledem" would misdescribe it.
# Usage in cron: ... 2>>cron.log || /root/scripts/notify-fail.sh "job description"
JOB="\$1"
HOST=\$(hostname -f 2>/dev/null || hostname)
NOW=\$(date '+%Y-%m-%d %H:%M:%S')
NOW_EPOCH=\$(date +%s)

STATE_DIR="/root/scripts/notify-state"
COOLDOWN="\${NOTIFY_COOLDOWN:-14400}"   # 4h default; override: NOTIFY_COOLDOWN=3600 notify-fail.sh "..."
mkdir -p "\$STATE_DIR"

KEY=\$(printf '%s' "\$JOB" | md5sum | cut -d' ' -f1)
LASTFILE="\$STATE_DIR/\$KEY"

if [ -f "\$LASTFILE" ] && [ \$(( NOW_EPOCH - \$(cat "\$LASTFILE") )) -lt "\$COOLDOWN" ]; then
    echo "notify-fail.sh: suppressed repeat within cooldown -- \${JOB}" >&2
    exit 0
fi
echo "\$NOW_EPOCH" > "\$LASTFILE"

echo "ZFS alert: '\${JOB}' na \${HOST} o \${NOW}. Sprawdz /root/scripts/cron.log." \\
    | mail -s "[ZFS BACKUP] ALERT: \${JOB} na \${HOST}" ${NOTIFY_EMAIL}
EOF
    chmod +x "$NOTIFY_SCRIPT"
    log "created/upgraded $NOTIFY_SCRIPT (v3, alerts -> $NOTIFY_EMAIL, cooldown 4h)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "skipping the test email (check-only)"
elif command -v mail >/dev/null; then
    log "sending a test alert to confirm mail delivery works from THIS host..."
    NOTIFY_COOLDOWN=0 "$NOTIFY_SCRIPT" "deploy_new_server.sh test on $(hostname -f 2>/dev/null || hostname)"
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
WARN_SCRIPT_MARKER="# notify-warn.sh v1"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -x "$WARN_SCRIPT" ]; then log "  $WARN_SCRIPT present"; else warn "  $WARN_SCRIPT missing -- WARNING monitor lines would error out"; fi
elif [ -e "$WARN_SCRIPT" ] && grep -qF "$WARN_SCRIPT_MARKER" "$WARN_SCRIPT" 2>/dev/null; then
    log "$WARN_SCRIPT already at v1, leaving it alone"
else
    cat > "$WARN_SCRIPT" <<EOF
#!/bin/bash
$WARN_SCRIPT_MARKER -- queues a WARNING-tier monitor finding for
# alert-digest.sh to summarize once a day, instead of mailing it immediately.
# Usage in cron: ... ; [ \$rc -eq 1 ] && /root/scripts/notify-warn.sh "job description"
JOB="\$1"
QUEUE="/root/scripts/warn-queue.log"
printf '%s\t%s\n' "\$(date +%s)" "\$JOB" >> "\$QUEUE"
EOF
    chmod +x "$WARN_SCRIPT"
    log "created $WARN_SCRIPT"
fi

DIGEST_SCRIPT="/root/scripts/alert-digest.sh"
DIGEST_SCRIPT_MARKER="# alert-digest.sh v1"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -x "$DIGEST_SCRIPT" ]; then log "  $DIGEST_SCRIPT present"; else warn "  $DIGEST_SCRIPT missing -- WARNING findings would queue forever and never be seen"; fi
elif [ -e "$DIGEST_SCRIPT" ] && grep -qF "$DIGEST_SCRIPT_MARKER" "$DIGEST_SCRIPT" 2>/dev/null; then
    log "$DIGEST_SCRIPT already at v1, leaving it alone"
else
    cat > "$DIGEST_SCRIPT" <<EOF
#!/bin/bash
$DIGEST_SCRIPT_MARKER -- once a day, mails one summary of everything
# notify-warn.sh queued since the last run instead of leaving each WARNING
# unmailed and invisible. Silent (no mail at all) if nothing queued.
QUEUE="/root/scripts/warn-queue.log"
HOST=\$(hostname -f 2>/dev/null || hostname)
TODAY=\$(date '+%Y-%m-%d')

[ -s "\$QUEUE" ] || exit 0

PROCESSING="\${QUEUE}.processing"
mv "\$QUEUE" "\$PROCESSING"

SUMMARY=\$(awk -F'\t' '
{
    key = \$2
    count[key]++
    if (!(key in first) || \$1 < first[key]) first[key] = \$1
    if (!(key in last)  || \$1 > last[key])  last[key]  = \$1
}
END {
    for (k in count) printf "%d\t%s\t%d\t%d\n", count[k], k, first[k], last[k]
}' "\$PROCESSING" | sort -t\$'\t' -k1,1nr)

BODY=""
UNIQUE=0
while IFS=\$'\t' read -r cnt msg first_ep last_ep; do
    UNIQUE=\$((UNIQUE + 1))
    t1=\$(date -d "@\$first_ep" '+%H:%M')
    t2=\$(date -d "@\$last_ep" '+%H:%M')
    range="\$t1"; [ "\$t1" != "\$t2" ] && range="\$t1 - \$t2"
    BODY="\${BODY}\$(printf '  x%-4s %-55s (%s)\n' "\$cnt" "\$msg" "\$range")
"
done <<< "\$SUMMARY"

TOTAL=\$(wc -l < "\$PROCESSING")

printf 'WARNING -- getting stale, nie jeszcze critical:\n\n%s' "\$BODY" \\
    | mail -s "[ZFS DIGEST] \$HOST -- \$TODAY (\$UNIQUE unikalnych, \$TOTAL zdarzen)" ${NOTIFY_EMAIL}

rm -f "\$PROCESSING"
EOF
    chmod +x "$DIGEST_SCRIPT"
    log "created $DIGEST_SCRIPT"
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
