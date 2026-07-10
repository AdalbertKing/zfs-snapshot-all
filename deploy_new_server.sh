#!/bin/bash
# ------------------------------------------------------------------------------
# deploy_new_server.sh
#
# Bootstrap procedure for propagating zfs-snapshot-all (snapsend.sh/snapget.sh/
# delsnaps.sh) from GitHub onto a new Proxmox/Debian host, including:
#   - git install
#   - clone/update of /root/scripts/zfs-snapshot-all (handles both a fresh dir
#     and one that already has plain-file copies of the scripts sitting in it)
#   - notify-fail.sh mail-alert helper (fires on job failure)
#   - check-pool-capacity.sh pool/quota alert (fires on slow-fill BEFORE a job fails)
#   - dependency + permission verification
#   - auto-pull cron line
#
# This script is NOT part of the git repo (zfs-snapshot-all only tracks the 3
# scripts) -- it is host-local infrastructure glue, same as cron.txt. Copy it
# to the target server yourself (paste via heredoc, scp, whatever) and run it
# as root:
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

log() { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

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
log "Part 1: git"
# ------------------------------------------------------------------------------
if ! command -v git >/dev/null; then
    log "git not found, installing..."
    apt_install_with_fallback git || die "could not install git"
fi
log "git: $(git --version)"

command -v flock >/dev/null || die "flock not found (util-linux) -- required by all 3 scripts for single-instance locking"
command -v mail  >/dev/null || warn "no 'mail' command -- notify-fail.sh alerting will not work until postfix/mailutils is installed"

# ------------------------------------------------------------------------------
log "Part 1b: mbuffer / pigz (required by snapsend.sh and snapget.sh)"
# ------------------------------------------------------------------------------
# mbuffer is required UNCONDITIONALLY by both scripts (they refuse to run
# without it, even without -z). pigz is only needed by jobs using -z, but since
# this deploy script can't know in advance which cron lines you'll add on this
# host, and it's a tiny package, install it too -- matches what pve0/pve1
# actually need since most of their jobs use -z.
if ! command -v mbuffer >/dev/null; then
    log "mbuffer not found, installing..."
    apt_install_with_fallback mbuffer || die "could not install mbuffer -- snapsend.sh/snapget.sh will refuse to run without it"
fi
log "mbuffer: $(command -v mbuffer)"

if ! command -v pigz >/dev/null; then
    log "pigz not found, installing..."
    apt_install_with_fallback pigz || warn "could not install pigz -- any cron line using -z will fail until this is fixed"
fi
if command -v pigz >/dev/null; then
    log "pigz: $(pigz --version 2>&1 | head -1)"
fi

# ------------------------------------------------------------------------------
log "Part 2: deploy the repo into $REPO_DIR"
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
log "Part 3: verify the deployment"
# ------------------------------------------------------------------------------
cd "$REPO_DIR" || die "cannot cd into $REPO_DIR"
log "HEAD: $(git log -1 --oneline)"

FAIL=0
for f in snapsend.sh snapget.sh delsnaps.sh; do
    if [ ! -x "$f" ]; then
        warn "$f is not executable (chmod +x $f)"
        chmod +x "$f"
    fi
    v=$(./"$f" -V 2>&1) || { warn "$f -V failed: $v"; FAIL=1; }
    log "  $f -> $v"
done
[ "$FAIL" -eq 0 ] || warn "one or more scripts failed the -V smoke test -- investigate before relying on cron"

# ------------------------------------------------------------------------------
log "Part 4: notify-fail.sh (mail alerting on cron job failure)"
# ------------------------------------------------------------------------------
NOTIFY_SCRIPT="/root/scripts/notify-fail.sh"
if [ -e "$NOTIFY_SCRIPT" ]; then
    log "$NOTIFY_SCRIPT already exists, leaving it alone (edit NOTIFY_EMAIL inside manually if needed)"
else
    cat > "$NOTIFY_SCRIPT" <<EOF
#!/bin/bash
# Sends a failure alert email for a cron job that returned non-zero.
# Usage in cron: ... 2>>cron.log || /root/scripts/notify-fail.sh "job description"
JOB="\$1"
HOST=\$(hostname -f 2>/dev/null || hostname)
NOW=\$(date '+%Y-%m-%d %H:%M:%S')

echo "Zadanie '\${JOB}' zakonczylo sie bledem na \${HOST} o \${NOW}. Sprawdz /root/scripts/cron.log." \\
    | mail -s "[ZFS BACKUP] FAILURE: \${JOB} na \${HOST}" ${NOTIFY_EMAIL}
EOF
    chmod +x "$NOTIFY_SCRIPT"
    log "created $NOTIFY_SCRIPT (alerts -> $NOTIFY_EMAIL)"
fi

if command -v mail >/dev/null; then
    log "sending a test alert to confirm mail delivery works from THIS host..."
    "$NOTIFY_SCRIPT" "deploy_new_server.sh test on $(hostname -f 2>/dev/null || hostname)"
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
log "Part 4b: auto-pull cron line (keeps this host's copy in sync with GitHub)"
# ------------------------------------------------------------------------------
PULL_LINE="15 * * * * cd $REPO_DIR && git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$REPO_DIR && git pull"; then
    log "auto-pull cron line already present, leaving it alone"
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
if [ -e "$CAPACITY_SCRIPT" ]; then
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
else
    ( crontab -l 2>/dev/null; echo "$CAPACITY_LINE" ) | crontab -
    log "added capacity-check cron line: $CAPACITY_LINE"
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
