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
#
# What this does NOT automate (host/dataset-specific, your call):
#   - zfs allow delegation on the actual dataset(s) this account should manage
#   - exchanging its SSH pubkey with other hosts for remote replication
#   - the actual snapsend/snapget/delsnaps cron job lines
# See Part 5 (printed at the end) for these.
#
# Usage: bash deploy_backup_user.sh [username]
#   username defaults to "zfsbackup"
# ------------------------------------------------------------------------------
set -uo pipefail

USERNAME="${1:-zfsbackup}"
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
log "public key (see Part 5 below for what to do with it):"
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

echo
log "===================================================================="
log "Automated part done. Manual steps remaining (Part 5, host/dataset-specific):"
log "===================================================================="
cat <<EOF

  1. Delegate ZFS permissions on the SPECIFIC dataset(s) this account should
     manage (NOT scripted here -- picking the dataset scope is a security
     decision only you should make):

       zfs allow -u $USERNAME snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount <dataset>

     Repeat per top-level dataset this account needs (permissions propagate
     to all descendants). This exact permission set was live-tested against
     ZFS 2.1.9 on pve1/pve2 -- see the zfs-snapshot-all git history
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
