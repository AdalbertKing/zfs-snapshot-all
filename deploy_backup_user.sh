#!/bin/bash
# ------------------------------------------------------------------------------
# deploy_backup_user.sh
#
# Bootstraps a dedicated, delegated (non-root) service account for running
# zfs-snapshot-all (snapsend.sh/snapget.sh/delsnaps.sh) without root.
#
# Background: on Linux (unlike illumos/Solaris), a user delegated the ZFS
# 'mount' permission via `zfs allow` still cannot actually mount/unmount a
# filesystem dataset -- that needs CAP_SYS_ADMIN, which delegation does not
# grant. snapsend.sh/snapget.sh already work around this for routine
# incremental replication (new targets are created with canmount=noauto, so
# there's no mount/unmount cycle for a later `zfs receive` to trip over), but
# this account still cannot: bootstrap a brand-new MULTI-LEVEL target path
# from scratch (only the leaf gets canmount=noauto -- missing parents must
# already exist), run -f (force-full-send/pull), or run -F (clear-cut) if the
# target/dependent clone happens to be currently mounted. Those remain
# root's job; -f/-F now print a clear hint pointing at this when they fail
# for that reason instead of a raw zfs error.
#
# What this script DOES automate (idempotent, safe to re-run):
#   - the service account itself (locked password, SSH-key-only)
#   - a lock/state directory it can write to (LOCKDIR/STATS_LOG)
#   - a git checkout of zfs-snapshot-all it can read+execute (separate from
#     root's own /root/scripts checkout -- root's path/crontab are untouched)
#   - that account's own auto-pull cron line
#   - zfs allow delegation on the dataset(s) given as arguments (defaults to
#     rpool/data and rpool/ROOT/pve-1 -- the standard Proxmox VE VM/CT-disk
#     and root-filesystem locations). Delegation on a dataset WITHOUT -d
#     applies to it and all descendants, INCLUDING ones that don't exist yet
#     -- new VM/CT disks created later under rpool/data automatically
#     inherit it, no per-VM re-run needed.
#
# What this does NOT automate (host-specific, your call):
#   - exchanging its SSH pubkey with other hosts for remote replication
#   - the actual snapsend/snapget/delsnaps cron job lines
# See Part 6 (printed at the end) for these.
#
# Usage: bash deploy_backup_user.sh [username] [dataset ...]
#   username defaults to "zfsbackup"
#   dataset(s) default to: rpool/data  rpool/ROOT/pve-1
# ------------------------------------------------------------------------------
set -uo pipefail

USERNAME="${1:-zfsbackup}"
[ "$#" -gt 0 ] && shift
if [ "$#" -gt 0 ]; then
    DATASETS=("$@")
else
    DATASETS=(rpool/data "rpool/ROOT/pve-1")
fi
REPO_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
HOMEDIR="/home/$USERNAME"
REPO_DIR="$HOMEDIR/zfs-snapshot-all"

log() { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v git >/dev/null || die "git not found -- run deploy_new_server.sh's Part 1 first, or apt-get install git"

# ------------------------------------------------------------------------------
log "Part 1: service account"
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
log "Part 2: lock/state directory"
# ------------------------------------------------------------------------------
RUNDIR="$HOMEDIR/run"
mkdir -p "$RUNDIR"
chown "$USERNAME:$USERNAME" "$RUNDIR"
log "LOCKDIR for this account: $RUNDIR"

# ------------------------------------------------------------------------------
log "Part 3: SSH keypair (for remote replication as this account)"
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
log "Part 4: repo checkout at $REPO_DIR (readable+executable by $USERNAME)"
# ------------------------------------------------------------------------------
if [ -d "$REPO_DIR/.git" ]; then
    log "$REPO_DIR is already a git repo, pulling..."
    su "$USERNAME" -c "git -C '$REPO_DIR' remote get-url origin 2>/dev/null" | grep -qF "$REPO_URL" \
        || warn "existing repo's origin does not match $REPO_URL -- check manually"
    su "$USERNAME" -c "git -C '$REPO_DIR' pull --ff-only origin main" \
        || die "git pull --ff-only failed -- local repo has diverged, resolve manually"

elif [ -d "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
    log "$REPO_DIR exists with files but is not a git repo (plain scripts from an earlier manual copy?)"
    BACKUP_DIR="${REPO_DIR}.bak-preGit-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in snapsend.sh snapget.sh delsnaps.sh gen-cron.sh; do
        if [ -e "$REPO_DIR/$f" ]; then
            mv "$REPO_DIR/$f" "$BACKUP_DIR/"
            log "  moved $f -> $BACKUP_DIR/"
        fi
    done
    chown -R "$USERNAME:$USERNAME" "$BACKUP_DIR"

    su "$USERNAME" -c "cd '$REPO_DIR' && git init && git remote add origin '$REPO_URL' && git fetch origin && git checkout -b main --track origin/main" \
        || die "git init/checkout failed"

    log "Diff against backup (should be empty besides new .git/.gitignore/.gitattributes):"
    diff -rq "$BACKUP_DIR" "$REPO_DIR" 2>&1 | grep -v "^Only in $REPO_DIR:" || true

else
    log "$REPO_DIR does not exist or is empty -- plain clone"
    su "$USERNAME" -c "git clone '$REPO_URL' '$REPO_DIR'" || die "git clone failed"
fi
chmod +x "$REPO_DIR"/*.sh 2>/dev/null || true

# ------------------------------------------------------------------------------
log "Part 4b: auto-pull cron line (this account's own crontab, independent of root's)"
# ------------------------------------------------------------------------------
PULL_LINE="15 * * * * cd $REPO_DIR && git pull --ff-only origin main >>$HOMEDIR/git-pull.log 2>&1"
if su "$USERNAME" -c "crontab -l 2>/dev/null" | grep -qF "$REPO_DIR && git pull"; then
    log "auto-pull cron line already present, leaving it alone"
else
    su "$USERNAME" -c "(crontab -l 2>/dev/null; echo '$PULL_LINE') | crontab -" \
        || warn "could not install auto-pull cron line -- add it manually"
    log "added auto-pull cron line to $USERNAME's crontab"
fi

# ------------------------------------------------------------------------------
log "Part 4c: alerting access + log rotation for this account"
# ------------------------------------------------------------------------------
# This account cannot see ANYTHING under /root: that directory is 0700, so the
# notify scripts, the alert config and the alert queue are all out of reach.
# The shortcut of opening /root/scripts to a group is a privilege escalation --
# root executes those scripts from cron, so an account able to write there could
# replace them. Instead the two accounts share one group-writable DATA directory
# (created by deploy_new_server.sh) and this account gets its own copies of the
# two reporting scripts. alert-digest.sh stays root-only and reads the shared
# queue, so the host still sends exactly ONE mail a day covering both accounts.
ALERT_GROUP="zfsalert"
ALERT_SHARED_DIR="/var/lib/zfs-snapshot-all"
ALERT_CONF="/etc/zfs-alert.conf"

if ! getent group "$ALERT_GROUP" >/dev/null; then
    warn "group $ALERT_GROUP does not exist -- run deploy_new_server.sh on this host first; skipping alerting setup"
elif [ ! -d "$ALERT_SHARED_DIR" ]; then
    warn "$ALERT_SHARED_DIR missing -- run deploy_new_server.sh on this host first; skipping alerting setup"
else
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
            warn "/root/scripts/$s.sh not found -- run deploy_new_server.sh first; $USERNAME has no way to report findings"
        fi
    done
    [ -r "$ALERT_CONF" ] || warn "$ALERT_CONF missing -- this account will fall back to built-in defaults (daily)"
fi

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
$LOGROTATE_MARKER -- managed by deploy_backup_user.sh, re-run it to update.
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
log "Part 5: ZFS delegation on ${DATASETS[*]}"
# ------------------------------------------------------------------------------
ZFS_PERMS="snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount"
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
log "Automated part done. Manual steps remaining (Part 6, host-specific):"
log "===================================================================="
cat <<EOF

  1. If this account needs OTHER datasets besides ${DATASETS[*]}, re-run
     with them as extra arguments, e.g.:

       bash deploy_backup_user.sh $USERNAME rpool/data rpool/ROOT/pve-1 hdd/extra

     (safe to re-run -- zfs allow is idempotent and earlier parts skip
     what's already done). This exact permission set was live-tested
     against ZFS 2.1.9 on pve1/pve2 -- see the zfs-snapshot-all git history
     (commits around the LOCKDIR/canmount/hint changes) for what each
     permission is for and what happens if one is missing.

  2. For REMOTE replication (this account connecting to another host as
     $USERNAME@<host>), copy the public key printed above into

       ~$USERNAME/.ssh/authorized_keys

     on the OTHER host, and run this same script there too so both
     directions work.

  3. Every cron line / manual invocation for this account needs:

       LOCKDIR=$RUNDIR STATS_LOG=$HOMEDIR/zfs-snapshot-stats.log $REPO_DIR/<script>.sh ...

     Root's existing jobs are untouched -- they keep using /var/run and
     /root/scripts/zfs-snapshot-stats.log exactly as before.

  4. Before adding a real cron line, sanity-check it with a manual dry-run
     first (-n for snapsend.sh/snapget.sh) as $USERNAME, same as the
     root-cron guidance in deploy_new_server.sh.

EOF
