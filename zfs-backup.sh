#!/bin/bash
set -uo pipefail
# ------------------------------------------------------------------------------
# zfs-backup.sh -- simple two-host deploy UX, orchestrating the existing engine.
#
# Implements the direction agreed 2026-07-30 in
# docs/discussions/DEPLOY-UX-AGREED-POSITION.md: pve1 (this host) is the sole
# backup-management appliance, pve2 (the peer) is a pure source. `snapget.sh`
# (pull) is the default engine. This file is a NEW, SEPARATE program that
# orchestrates deploy.sh/snapget.sh/gen-cron.sh as subprocesses -- it does not
# extend deploy.sh's own public surface (agreed position §2), specifically to
# avoid touching the just-verified self-update/rollback control plane
# (REV-20260730-001/002).
#
# Commands: see usage() below (or run with no arguments) for the authoritative,
# grouped list. Deliberately NOT duplicated here -- this header used to carry a
# second hand-maintained copy that drifted (it had lost final-catchup, pause/
# resume and disable/enable, and gave set-endpoint a stale signature). One list,
# one place.
#
# State machine (REV-20260730-004): pending_enroll -> seeding -> seed_complete
# -> endpoint_verified -> active. Cron is installed ONLY from endpoint_verified
# (or re-activating from active) -- never earlier, matching the agreed
# position's "no held/paused cron entry during seed" (§10) generalized to
# "no cron entry until the ACTIVE endpoint has been verified". `verify-
# endpoint` can be re-run against whichever endpoint is currently active, so
# every client (however many addresses it has ever used) goes through the
# identical gate.
#
# Endpoint model (REV-20260802-033 U9, superseding the REV-20260730-004
# fixed lan/vpn slots): ONE current endpoint (ACTIVE_ENDPOINT, a literal
# "host:port") plus an optional list of other addresses that have worked for
# this client before (ENDPOINT_KNOWN). A routed VPN that preserves the
# original host:port needs no `set-endpoint` call at all -- re-running
# `verify-endpoint` is the whole story. When the current address stops
# answering, `verify-endpoint` tries each known candidate before asking the
# operator for a genuinely new one; a candidate that answers is promoted to
# ACTIVE_ENDPOINT automatically. `ENDPOINT_LAN_*`/`ENDPOINT_VPN_*`/an
# `ACTIVE_ENDPOINT` value of literally "lan"/"vpn" are kept ONLY as read
# compatibility for client records written before this -- `active_endpoint_
# host_port()` resolves either shape; nothing new writes the old one.
#
# Stable relation identity (REV-20260730-004 F1): CLIENT_NAME is the address-
# independent identity used for the HostKeyAlias and all display/summary text.
# `label` (deploy.sh's own peer_label(), derived from the ORIGINAL --lan
# address used at add-client/--pair time) still exists, but is used ONLY to
# locate deploy.sh's own manifest/key files and the physical target dataset
# path deploy.sh itself already created under that name -- neither can change
# without deploy.sh re-pairing, and this file does not re-pair on an endpoint
# switch. Switching ACTIVE_ENDPOINT changes only which address/port the
# generated job connects through; it does not touch
# PEER_HOST, `label`, the target path, the pairing key, or the pinned host
# key -- deploy.sh's --draft-config is therefore called only once, during
# `seed` (always over the known-good LAN route), never again afterwards:
# calling it with a DIFFERENT --peer= address would make deploy.sh treat it
# as an entirely different, unpaired peer (peer_label() differs by address).
# Later steps (verify-endpoint, activate-client, test) reuse the
# already-fetched PEER_SAVED_DATASETS/TARGET from the manifest and connect
# directly via whichever endpoint is currently active.
#
# Only the 'standard' profile is implemented -- values approved by the owner
# 2026-07-30: hourly retain 24, daily retain 7, weekly retain 4, monthly
# retain 12, daily/weekly/monthly at midnight. No quiesce: gen-cron.sh
# rejects quiesce=agent on a pull dataset outright (snapget.sh has no remote-
# quiesce support -- the guest lives on the REMOTE peer). Per REV-20260730-004
# §6, the activation summary now says so explicitly: snapshots from this
# client are crash-consistent, not application-consistent, until either
# snapget.sh gains a remote-quiesce feature or that client runs push instead.
# 'frequent'/'archive' profiles are declared but not implemented.
#
# REV-20260730-003 (two review passes) and REV-20260730-004 (follow-up) found
# and fixed, across this file's history: HostKeyAlias/fail-closed host key
# (F1/F2), canonical-path crontab-source check (F5), transactional config
# edits with atomic swap + rollback (F4/F6), zfs-allow visibility (F8),
# per-template idempotent checks. REV-20260730-004 additionally required (and
# this pass implements): decoupling identity from address (this file's F1
# above), the seed/verify/active state machine, a categorized zfs-allow
# check (not just a raw dump), explicit crash-consistent labeling, and a
# crontab-level (not just config-file-level) backup/restore around
# `gen-cron.sh --install`.
#
# NOT yet built: an `enroll`-style command on the peer (pve2 still runs
# `deploy.sh --join` directly), human-readable `status` beyond a light
# summary, frequent/archive profiles, remote-quiesce.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
SNAPGET="$SCRIPT_DIR/snapget.sh"
SNAPSEND="$SCRIPT_DIR/snapsend.sh"
GENCRON="$SCRIPT_DIR/gen-cron.sh"
LIBCRON="$SCRIPT_DIR/lib-cron.sh"
LIBSCOPE="$SCRIPT_DIR/lib-scope.sh"
LIBPROFILE="$SCRIPT_DIR/lib-profile.sh"
# WHERE PROFILES LIVE, and the split is the one this tree already draws for
# everything else (see the note above RELATIONSHIPS_DIR): the PACKAGE holds what
# we ship, /etc holds what this host decided, /var/lib holds what is true right
# now.
#
#   PROFILE_ROOT       FACTORY profiles, shipped with the package. Replaced
#                      wholesale by `git pull`, so a host must never edit them --
#                      the next update would silently take the edit away.
#   PROFILE_USER_ROOT  the administrator's own, on this host. Survives every
#                      update because nothing in the package points at it.
#
# "Never carried to GitHub" is therefore not a rule anyone has to remember. It
# is a consequence of the LOCATION: /etc is not in the checkout, so there is no
# gesture -- not `git add .`, not a stray commit -- that could take a local
# profile upstream. A guarantee that needs discipline is not a guarantee.
PROFILE_ROOT="${PROFILE_ROOT:-$SCRIPT_DIR/profiles}"
PROFILE_USER_ROOT="${PROFILE_USER_ROOT:-/etc/zfs-snapshot-all/profiles}"
# The name of the profile a deployment gets when nobody names one. Written once
# and referred to, not spelled out at each of the six places that used to say
# "default" in a literal -- with six copies, "what does a plain run do" was a
# question you answered by grepping, and changing the answer meant finding all
# six.
#
# It is also what makes `--profile=default` TESTABLE: the explicit and the
# implicit path now resolve through the same name, so "an explicit default
# behaves exactly like no flag at all" is a property that can be asserted
# rather than assumed.
PROFILE_DEFAULT_NAME="default"
PROFILE_ACTIVE="${PROFILE_ACTIVE:-$PROFILE_DEFAULT_NAME}"

# Shared with zfs-restore.sh (die/warn, the server conf, the installed-config
# field reader) since the 2026-08-17 restore split. Sourced FIRST because the
# guards below use die-shaped failure and later code reads SERVER_CONF.
LIBCOMMON="$SCRIPT_DIR/lib-backup-common.sh"
[ -r "$LIBCOMMON" ] || { echo "cannot read $LIBCOMMON -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBCOMMON"

# The single crontab writer. Sourced, not reimplemented: this script used to
# hold its own reader, its own writer and its own block renderer, which is how
# three programs ended up with six ways of editing the same file. Missing is
# fatal rather than degraded -- a fallback would be a fourth implementation.
[ -r "$LIBCRON" ] || { echo "cannot read $LIBCRON -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBCRON"

# The scope file's grammar and reader (REV-20260802-033 slice 1), sourced for
# the same reason: slice 6 needs scope_read/scope_includes to interpret a
# scope file fetched from a mode-based peer, and a second implementation of
# that grammar is exactly the second representation REV-033 F2 forbids.
[ -r "$LIBSCOPE" ] || { echo "cannot read $LIBSCOPE -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBSCOPE"

# The profile boundary and renderer (REV-073/076/077/079/081). Sourced for the
# same reason as the two above: the rule about what a profile may own, and the
# encoding of its template names, must have exactly one implementation. B1
# makes this file the first production consumer of profiles/.
[ -r "$LIBPROFILE" ] || { echo "cannot read $LIBPROFILE -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBPROFILE"

# Mirrors deploy.sh's own peer-pairing state locations exactly (see
# PAIRING-DESIGN.md) -- this file reads what --pair/--join already write, it
# never invents a parallel record of the same facts.
PEER_STATE_DIR="/etc/zfs-snapshot-all/peers"
PEER_KEY_DIR="/root/.ssh/pairing"

# Every ssh below reaches a peer that may be down. With no bound the connect
# blocks on the kernel's SYN timeout (~130s to a black-holed address) before it
# fails -- long enough to stall a cron run on a dead peer, and, measured, the
# thing that turned the zfsbackup test leg into 34 minutes. ConnectTimeout caps
# the connect; ServerAlive* caps a peer that goes SILENT mid-command (connected,
# then the link dies) -- without it a short control command could still hang for
# as long as TCP takes to notice. These mirror the data-plane engine's own values
# (snapsend.sh/snapget.sh SSH_OPTS), so both planes fail a dead peer the same way.
# One ceiling for every call site; env-overridable, and deliberately not readonly
# (this file is sourced, sometimes more than once in a shell).
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
SSH_SERVER_ALIVE_INTERVAL="${SSH_SERVER_ALIVE_INTERVAL:-15}"
SSH_SERVER_ALIVE_COUNT="${SSH_SERVER_ALIVE_COUNT:-4}"

# REV-20260804-037: how the PEER names files ABOUT this collector -- the
# scope file/hash sidecar deploy.sh's do_pair/do_join write under
# peer_scope_path() on the peer live at <label>.scope, where <label> is
# unconditionally the collector's own `hostname -s` at pairing time
# (deploy.sh's `my_label`, never overridden or passed in). Distinct from
# $LOAD_LABEL (peer_label($PEER_HOST), the PEER's address as THIS side
# names its OWN local files about the relationship) -- confusing the two
# is exactly the bug this global exists to make impossible to reintroduce.
# Plain global, overridden the same way as the others (test fixtures).
COLLECTOR_LABEL="$(hostname -s 2>/dev/null || hostname)"

# SERVER_CONF lives in lib-backup-common.sh since the restore split -- both
# programs must agree on where the server config is, so neither defines it.
# THIS HOST'S DEFAULTS: SETTINGS_FILE and settings_get now live in lib-cron.sh,
# sourced above. They moved there on 2026-08-26 because gen-cron.sh needs the
# same reader -- a tier that names no `quiesce` falls back to the host's default,
# and gen-cron.sh is where a tier's fields are resolved. lib-cron.sh is the one
# file both programs already source; duplicating an ini parser so that two
# programs could disagree about what a host said was the alternative.

# CLIENTS_DIR lives in lib-backup-common.sh since 2026-08-26: zfs-restore.sh
# needs the same answer, and two definitions are two ways to disagree.
# Where crontabs live, for the "who has one" question in cron_known_accounts.
# Debian/Proxmox first, RHEL second. Only ever read, never written -- gen-cron
# remains the single writer, through crontab(1).
CRON_SPOOL_DIRS=(/var/spool/cron/crontabs /var/spool/cron)

# Shared cluster filesystem, world-searchable. A plain global (not read from
# the environment) like the others above -- overridden the same way in tests,
# by reassigning it in the subshell that calls the command under test.
PVE_NODES_DIR="/etc/pve/nodes"

# How recent a final catch-up must be to authorise an endpoint switch
# (REV-20260731-008 F1). 30 minutes: long enough to run the catch-up, walk
# to the rack and unplug the machine; short enough that "just before
# relocation" is still true. --allow-stale-catchup overrides it, loudly.
CATCHUP_MAX_AGE="${CATCHUP_MAX_AGE:-$(settings_get catchup_max_age 1800)}"

log()  { echo ">>> $*"; }
# warn/die live in lib-backup-common.sh since the restore split.

usage() {
    cat <<'EOF'
zfs-backup.sh -- simple two-host backup deploy (pve1=appliance, pve2=source)

Usage:
  zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE] [--local-user=NAME]
  zfs-backup.sh [--source=DATASET] [--target=DATASET] [--profile=NAME] [--config=FILE]
                [--local-user=NAME] [--install] [--yes|-y]
                                    LOCAL backup ('local-backup ...' is an alias).
                                    --source omitted:  proposed from this host's ZFS inventory and shown,
                                                       with every skipped dataset and its reason; a PROPOSED
                                                       source set will not install under --yes
                                    --target omitted:  proposed (server.conf default, else the pool layout)
                                                       and shown; a GUESSED target will not install under --yes
                                    --local-user:      account these jobs run as; omitted means root.
                                                       Same flag and same default as the remote form --
                                                       the account is a per-deployment decision, never a
                                                       host-wide setting. Created if missing, delegated on
                                                       every source AND on the target, and the block is
                                                       installed into ITS crontab.
                                    without --install: plans and previews, installs nothing
                                    --install:         seed first, then install the cron transactionally
                                    --yes | -y:        skip the interactive confirmation of that install
  zfs-backup.sh --source=HOST:DATASET --target=DATASET [--port=N] [--profile=NAME]
                [--name=NAME] [--local-user=NAME] [--install] [--yes|-y] [--verbose]
                                    REMOTE backup: pull DATASET from HOST into the local
                                    target. Composes the existing add-client -> seed ->
                                    activate lifecycle -- one command, resumable by re-
                                    running it identically after any interruption.
                                    --name omitted:    derived from HOST; only needed when
                                                       more than one relationship already
                                                       points at the same host
                                    --local-user=NAME: CREATE-time only. The account the
                                                       generated jobs run as (root, or any
                                                       delegated user -- created if absent).
                                                       OMIT IT AND THEY RUN AS ROOT. No host-
                                                       wide default, no guessing: name an
                                                       account to delegate. The choice is
                                                       recorded WITH the relationship, so
                                                       activate/remove read it back.
                                    without --install: read-only plan, touches neither host
                                    --install:          enrol (remote --join over SSH), seed,
                                                       verify endpoint, activate
                                    --join-remotely:   (DEFAULT) create the delegated account
                                                       on the source over your root-ssh channel
                                                       instead of printing a package to carry
                                                       there by hand. --manual-join opts out.
                                    --grant-remotely:  ALSO commit the scope on the source, so
                                                       the whole enrolment is ONE command
                                                       instead of stopping for
                                                       'deploy.sh --commit-scope' there and
                                                       being re-run. Off by default: granting
                                                       is the source's decision, and this is
                                                       the explicit opt-in to making it from
                                                       here. What it may NOT do: the scope it
                                                       commits is built from THIS command line,
                                                       so it is the requested dataset and never
                                                       wider; a pre-existing draft that selects
                                                       something else is refused rather than
                                                       overwritten; no root channel refuses
                                                       before anything changes; and the source
                                                       records GRANTED_REMOTELY_BY. The ordinary
                                                       fetch+hash+includes verification still
                                                       runs afterwards and still decides.
  zfs-backup.sh --source=HOST:DATASET --mode=sync [--port=N] [--profile=NAME]
                [--name=NAME] [--local-user=NAME] [--install] [--yes|-y]
                                    REMOTE sync: reproduce HOST:DATASET at the SAME path on
                                    this host (no --target -- the mapping is the identity).
                                    Same lifecycle and resumability as remote backup above.
  zfs-backup.sh restore --plan [--dataset=DATASET] [--config=FILE]
                                    READ-ONLY. What could be restored, from where, and when
                                    each snapshot was REALLY taken -- ZFS 'creation', never
                                    the name, plus the recovery STRATEGY and what it would
                                    destroy on the source.
  zfs-backup.sh restore --dataset=D --snapshot=S [--yes]
                                    SAFE restore into the derived restore namespace. The
                                    original path is never the target.
  zfs-backup.sh --source=HOST: [--target=X] [--profile=NAME] [--local-user=NAME] [--install] [--yes]
                                    REMOTE backup, DEFERRED scope: no dataset named. Pairs the
                                    source, the source proposes its own datasets, you pick
                                    before install. Backup-mode only; --target optional
                                    (proposed at pick time). --manual-join opts into the
                                    explicit two-sided form. Same resumability as above.
Replicas -- more copies of what this host already holds, usually onto disks
that get unplugged. Every field is a flag, and add-replica is an upsert, so a
front end never edits the config file:
  zfs-backup.sh add-replica NAME --source=DATASET --dst=POOL/BASE
                                    Default schedule is 02:30 nightly, after the
                                    daily tier: a replica is not an online mirror,
                                    and every run is a window in which the medium
                                    is at risk.
                                    [--schedule='30 2 * * *'] [--prefix=replica_]
                                    [--recursive=yes|no] [--fixed|--removable]
                                    [--history=all|newest|auto:N]
                                    [--notify=TEXT] [--plan|--install] [--yes]
                                    Plans by default; --install swaps the config and
                                    the crontab together. --removable (the default)
                                    brackets the run in zpool import/export, so a
                                    disk in a safe is a quiet skip, never an alert.
                                    Prepare the medium once, by hand, before the
                                    first run: zpool create POOL <device> and
                                    zfs create POOL/BASE. That dataset is what tells
                                    the gate the RIGHT disk is in the slot.
  zfs-backup.sh list-replicas [--json]
                                    Inventory plus live medium state: here (imported),
                                    available (in the slot, not imported), away (in a
                                    safe), wrong_medium (a disk IS in the slot and it
                                    is not this one). --json is the GUI data layer,
                                    same contract as `progress --json`.
  zfs-backup.sh run-replicas [--config=F]
                                    Run every replica job now. A medium that is
                                    not here skips quietly, so this is safe to
                                    fire on any insertion.
  zfs-backup.sh install-media-trigger [--install]
                                    OPTIONAL, and not implied by anything. A udev
                                    rule that runs the replicas when a disk
                                    carrying a ZFS label appears. add-replica
                                    never touches udev; a host that only wants the
                                    nightly run never runs this. Running both is
                                    fine -- the nightly run then finds nothing
                                    written and skips without importing.
  zfs-backup.sh remove-media-trigger [--install]
                                    Take that opt-in back. Removes only the rule
                                    this tool wrote; cron entries are untouched.
  zfs-backup.sh remove-replica NAME [--install] [--yes]
                                    Stops the job. The copy on that medium is left
                                    alone -- it is still a copy. Removing the LAST
                                    job in the config removes the whole managed
                                    cron block: an empty schedule is a legal
                                    outcome of a removal, not a broken config.

Explicit two-host lifecycle (the one-command --source= forms above wrap this):
  zfs-backup.sh add-client NAME --host=HOST[:PORT] [--target=X] [--bandwidth=N] [--profile=NAME]
                                    --bandwidth caps the LINK, not this one relationship: it is
                                    written into the pairing with that host and applies to every
                                    relationship over it. A different value on a peer that is
                                    already capped is refused, not applied.
                                    Default: backup mode; source datasets are discovered
                                    and accepted by deploy.sh --join on the source host.
                                    --lan, --mode and --datasets remain expert options.
                                    --requested=DATASET goes WITH --mode: it does not
                                    choose the datasets (the source's committed scope
                                    still does), it tells the source what was asked for
                                    so its scope DRAFT starts there instead of at every
                                    pool it has.
                                    --recursive=flat|atomic picks how a solid scope
                                    root is replicated. flat (default) sends each
                                    dataset on its own (-R): a failing child does not
                                    abort its siblings and each keeps a bookmark.
                                    atomic sends the whole subtree as ONE stream (-r)
                                    and DECLINES managed source retention -- under -r
                                    the engines keep no bookmark, so a source prune
                                    that ages out the last common snapshot ends the
                                    relationship until a destructive re-seed. Recorded
                                    on the client, so re-activation keeps the shape.
                                    --exclude-child=REGEX (repeatable) drops matching datasets
                                    from a flat expansion -- snapget/snapsend -X, an
                                    unanchored grep -E over the SOURCE-side name, so
                                    anchor it yourself when you mean the whole name.
                                    Recorded like --recursive, and refused together with
                                    --recursive=atomic, where one stream has nowhere to
                                    filter.
                                    --exclude-family=A,B names snapshot FAMILIES a passive
                                    pickup refuses to adopt -- snapget/snapsend -E. Two
                                    different things, so two names: -child drops DATASETS
                                    and takes a regex, hence one flag per pattern; -family
                                    drops SNAPSHOT NAMES and takes a comma list, because a
                                    snapshot name cannot contain a comma and a regex can.
  zfs-backup.sh seed NAME [--yes]   Real initial transfer; installs nothing to cron.
  zfs-backup.sh activate NAME [--host=HOST[:PORT]] [--yes] [--verbose]
                                    Finish the relationship in one command: optional final
                                    catch-up and endpoint switch, endpoint verification,
                                    config/cron preview and transactional installation.

  Steps 'activate' runs for you -- invoke directly only to recover a stuck
  activation. 'activate' is idempotent and resumable, so prefer re-running it:
  zfs-backup.sh set-endpoint NAME --host=HOST[:PORT] [--skip-final-catchup] [--allow-stale-catchup]
  zfs-backup.sh verify-endpoint NAME
  zfs-backup.sh final-catchup NAME [--yes]
  zfs-backup.sh activate-client NAME [--yes] [--verbose]

Client state control:
  zfs-backup.sh pause-client NAME [--reason=TEXT]
  zfs-backup.sh resume-client NAME
  zfs-backup.sh move-to-client FROM ONTO [--yes]
                                    The relationship's MACHINE was replaced. Hands the
                                    copy over to ONTO's machine: the copy does not move
                                    on disk, only which machine it is backed up from --
                                    so no re-seed. REFUSES until ONTO already holds the
                                    copy, proven by guid per dataset; recover it there
                                    first (restore FROM ONTO). Pauses FROM afterwards
                                    and keeps its record. Does not retire the old
                                    machine, and says so.
  zfs-backup.sh disable-client NAME [--reason=TEXT]
  zfs-backup.sh enable-client NAME

Config maintenance:
  zfs-backup.sh migrate-profile [--profile=NAZWA] [--yes]
  zfs-backup.sh set-bandwidth --peer=HOST --bandwidth=RATE [--yes]
                                    Change the PAIR's link cap and apply it to every
                                    ACTIVE relationship across that link, as ONE
                                    previewed transaction. --bandwidth= with no value
                                    REMOVES the cap.
  zfs-backup.sh audit-source-retention [--apply] [--yes]

Inspection / teardown:
  zfs-backup.sh status [NAME]
  zfs-backup.sh test NAME
  zfs-backup.sh remove-client NAME

Naming: a verb ending in '-client' acts on the RELATIONSHIP RECORD -- create
it, change its state, install its cron, delete it. A bare verb acts on the LINK
or the DATA: a transfer, an endpoint, a probe. Two deliberate exceptions:
'status' reads records but is host-wide when given no name, and 'activate' is
the composite that drives a record to active -- it keeps the short name because
it is the normal way to finish a relationship, and it is what you re-run.

pause-client/resume-client: LOGICAL pause of one relationship (REV-045).
Managed jobs and labeled manual runs skip before any snapshot/SSH work;
other clients are untouched, cron/config/grants/keys are never edited.
LIMITATION: a manual snapget.sh/snapsend.sh that omits '-L NAME' is NOT
blocked -- this is an orchestration switch, not a security boundary.

disable-client/enable-client: the PEER refuses this relationship's
data-plane commands, including manual ones carrying no -L. Order is
fixed: disable pauses locally first, then blocks at the peer and reads
the state back; enable clears the peer first, verifies, then lifts the
local pause. Any partial failure is reported as such and is safe to
retry. LIMIT: the relationship's own key can lift its own block; every
lift is logged on the peer.

State machine: pending_enroll -> seeding -> seed_complete -> endpoint_verified
-> active. Cron is installed only from endpoint_verified (or re-activating an
already-active client) -- never earlier.

Run on the backup appliance (pve1). The peer (pve2) side is unchanged:
  ./deploy.sh --join=/path/to/package.tgz

See docs/discussions/DEPLOY-UX-AGREED-POSITION.md and
docs/internal/reviews/responses/REV-20260730-004.md for the model this follows.
EOF
}

# Identical to deploy.sh's own peer_label(): the key file name, manifest name
# and account name are all built from this, and it must produce the SAME
# string deploy.sh already used, or this script would look for the wrong
# files. Used ONLY to locate deploy.sh's own state -- never for anything this
# script displays or builds itself (see the file header on stable identity).
peer_label() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

client_name_valid() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}
client_conf_path() { echo "$CLIENTS_DIR/$1.conf"; }
peer_manifest_path() { echo "$PEER_STATE_DIR/$1.conf"; }

# ------------------------------------------------------------------------------
# Relationship-scoped OPERATIONAL state (REV-20260804-045, logical pause).
# Deliberately not in /etc/zfs-snapshot-all: /etc holds what a relationship IS
# (identity, config -- immutable manifests, client records), /var/lib holds
# what is currently TRUE about it. The marker is written only by root's
# pause-client/resume-client below and read by snapget.sh/snapsend.sh's -L
# preflight running as the delegated account -- hence 0755/0644 root:root,
# chmod'ed explicitly so the setgid zfsalert parent cannot make the marker
# group-writable (an account must not be able to unpause itself).
#
# Logical pause is an ORCHESTRATION feature, not a security boundary: a
# command that omits -L is not blocked. The hard-disable half of REV-045
# (peer-side SSH gate) is deliberately NOT implemented in this stage.
# Overridable in the same form CLIENTS_DIR already uses. Not a new capability:
# it is what lets a suite drive the pause-aware refusals below without a live
# /var/lib, and the refusal that reads this was previously untestable for
# exactly that reason.
RELATIONSHIPS_DIR="${RELATIONSHIPS_DIR:-/var/lib/zfs-snapshot-all/relationships}"
pause_marker_path() { echo "$RELATIONSHIPS_DIR/$1/paused"; }
client_paused() { [ -f "$(pause_marker_path "$1")" ]; }
# Mirrors deploy.sh's own peer_scope_path/peer_scope_granted_hash_path
# exactly (REV-20260802-033 slices 4/T3) -- same reason as peer_manifest_path
# above: this reads what --draft-scope/--commit-scope already wrote on the
# PEER, it never invents a parallel path convention.
peer_scope_path() { echo "$PEER_STATE_DIR/$1.scope"; }
peer_scope_granted_hash_path() { echo "$PEER_STATE_DIR/$1.scope.sha256"; }

# Same question deploy.sh's local_keyfile_path/local_knownhosts_path answer:
# where the GENERATED job should look for the key/pinned host key. Kept in
# sync deliberately, same reasoning as update-control.sh's duplicated
# functions -- there is no source edge between these two files to declare.
local_keyfile_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_ed25519"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_ed25519"
}
local_knownhosts_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_known_hosts"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_known_hosts"
}

# REV-20260730-004 F1: the alias is now built from CLIENT_NAME (the stable,
# address-independent identity), not from `label` (deploy.sh's peer_label,
# derived from whatever address --pair happened to use). Switching endpoints
# never changes this.
host_key_alias() { echo "zfs-client-$1"; }

# Returns the alias-keyed known_hosts path on success, or a non-zero exit and
# no output if there is no pinned key yet to derive it from -- callers must
# treat that as fatal (F2), never as "fall back to accept-new". `label` here
# is still deploy.sh's own (to find its pinned file); `alias` is the stable
# CLIENT_NAME-based one this file writes.
ensure_alias_known_hosts() {
    local label="$1" user="$2" port="$3" alias="$4"
    local src; src=$(local_knownhosts_path "$label" "$user")
    [ -f "$src" ] || return 1
    local keyline; keyline=$(grep -v '^#' "$src" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
    [ -n "$keyline" ] || return 1
    local rest; rest=$(printf '%s' "$keyline" | cut -d' ' -f2-)
    [ -n "$rest" ] || return 1
    local dst="${src%_known_hosts}_alias_known_hosts"
    # ALWAYS the bare alias, never the [alias]:port form -- and the port
    # argument is deliberately not used here.
    #
    # When HostKeyAlias is set, OpenSSH looks the host key up under the alias
    # ALONE; it does not append the port the way it does for a real hostname.
    # This used to write '[alias]:port' whenever the port was not 22, so the
    # pinned key was filed under a name ssh never asks for, and EVERY endpoint
    # on a non-default port failed "Host key verification failed" with the
    # correct key sitting in the file. Port 22 worked, which is why it survived
    # this long: nothing in the estate used another port until an endpoint
    # switch to one was tried.
    #
    # Found live 2026-08-23 running issue #9's second path (LAN seed, then
    # activate --host=<other>:2222). ssh -v named it exactly:
    #     debug1: hostkeys_find_by_key_cb: found matching key in ...:1
    #     Host key verification failed.
    # -- found by the UpdateHostKeys scan, which searches by KEY, while the
    # lookup by NAME had already missed. Rewriting the same file's single entry
    # without the port made the identical connection succeed.
    #
    # The alias is per relationship and the key belongs to the host, so a name
    # without a port is also the semantically right thing to pin: changing the
    # port does not change who the peer is.
    # PRESERVE the other relationships' aliases. This file is per HOST while
    # the alias is per RELATIONSHIP -- the single-entry overwrite this used
    # to do meant the LAST enrolment won and every sibling relationship's
    # next cron run failed ssh 255 with "No ED25519 host key is known for
    # <its alias>" (measured, passive lab: three relationships, the file
    # held only labP2). Replace this alias's line, keep the rest.
    local tmp; tmp=$(mktemp) || return 1
    {
        [ -f "$dst" ] && awk -v a="$alias" '$1 != a' "$dst" 2>/dev/null
        printf '%s %s\n' "$alias" "$rest"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$dst" 2>/dev/null
    # This file lives in the account's own ~/.ssh but is written HERE, by root.
    # Without the chown it lands root:root 0600 -- and the account then cannot
    # read the pinned host key for the peer it is meant to pull from. ssh
    # answers "No ECDSA host key is known for <alias> ... Host key verification
    # failed", which reads like a missing or wrong key rather than a permission
    # problem on a file that is right there.
    #
    # Found live on metropolis pve1, 2026-08-01. deploy.sh --pair gets the other
    # two files right (key and known_hosts are both account-owned); only this
    # one, generated later by this wrapper, was left behind.
    #
    # Found live AGAIN 2026-08-06 (REV-045 slice 4): the owner must follow the
    # PATH, not the server conf. $user (PEER_SAVED_LOCAL_USER, this function's
    # own argument) is what chose ~account/.ssh as the destination -- but the
    # chown below keyed on $LOCAL_USER, which is set only by commands that
    # call read_server_conf first. In any other flow the file landed
    # root:root 0600 in the account's OWN ~/.ssh and every account-side pull
    # failed "Host key verification failed" with the correct pinned key
    # sitting right there, unreadable.
    local _lu="${user:-${LOCAL_USER:-}}" _lh=""
    [ -n "$_lu" ] && _lh=$(getent passwd "$_lu" 2>/dev/null | cut -d: -f6)
    if [ -n "$_lh" ]; then
        case "$dst" in
            "$_lh"/*) chown "$_lu":"$_lu" "$dst" 2>/dev/null ;;
        esac
    fi
    printf '%s' "$dst"
}

# ---- endpoint model (REV-20260802-033 U9, superseding REV-20260730-004 §2/§3) -
# The original two fixed slots (lan/vpn) are kept ONLY as a read-compat shape
# for client records written before this -- endpoint_host_var/endpoint_port_var
# exist solely to resolve THAT shape (see active_endpoint_host_port below).
# Nothing new ever writes ENDPOINT_LAN_*/ENDPOINT_VPN_* or an ACTIVE_ENDPOINT
# of literally "lan"/"vpn" again; a new or migrated record's ACTIVE_ENDPOINT
# is the literal "host:port" string, directly.
endpoint_host_var() { echo "ENDPOINT_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_HOST"; }
endpoint_port_var() { echo "ENDPOINT_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_PORT"; }

# Splits "HOST[:PORT]" -> echoes "HOST PORT" (default port 22). IPv6 literals
# in brackets are not handled here -- out of scope for this pass (LAN/VPN
# endpoints in this project are IPv4 RFC1918/WireGuard addresses today).
# REV-20260730-005 F1 (BLOCKER, and a real defect I introduced): these values
# are written into the client conf, which every other command reads back with
# `.` -- i.e. bash EXECUTES it, as root. Writing an unvalidated host meant a
# value like `$(id)`, `a;reboot`, a newline or even a plain space would either
# corrupt the state file or run as root on the next `status`/`seed`/
# `verify-endpoint`. Two independent defences, because either alone is one
# mistake away from the same hole:
#
#   1. VALIDATE here, to a charset that cannot express shell syntax at all --
#      hostnames and IPv4 literals only ([A-Za-z0-9.-], no leading/trailing
#      dot or dash), port a real 1-65535 integer.
#   2. QUOTE on write (printf %q, see write_client_field), so even a value
#      that somehow reached the file could not break out of its assignment.
#
# IPv6 literals are deliberately NOT accepted: they need brackets, which
# collide with the HOST:PORT split below, and no endpoint in this project is
# IPv6 today. Refusing them outright beats half-parsing them.
endpoint_host_valid() {
    case "$1" in
        ""|.*|-*|*.|*-) return 1 ;;
        *[!A-Za-z0-9.-]*) return 1 ;;
        *) return 0 ;;
    esac
}
endpoint_port_valid() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
    esac
}

# Splits "HOST[:PORT]" -> echoes "HOST PORT" (default port 22), dying on
# anything that is not a plain hostname/IPv4 and a real port number.
parse_endpoint_arg() {
    local a="$1" host port=22
    case "$a" in
        *:*) host="${a%:*}"; port="${a##*:}" ;;
        *)   host="$a" ;;
    esac
    endpoint_host_valid "$host" \
        || die "invalid endpoint host '$host' -- expected a hostname or IPv4 literal (letters, digits, dot, dash only; no leading/trailing dot or dash). This value is stored in a file that is sourced as root, so anything that could carry shell syntax is refused outright."
    endpoint_port_valid "$port" \
        || die "invalid endpoint port '$port' -- expected an integer 1-65535"
    printf '%s %s' "$host" "$port"
}

# Every write into a client conf goes through this: the value is %q-quoted, so
# a field can never become executable shell when the file is sourced back.
write_client_field() {
    printf '%s=%q\n' "$1" "$2"
}

# Reads ACTIVE_ENDPOINT from the already-`.`-sourced client conf vars --
# echoes "HOST PORT". Handles both record shapes (U9):
#
#   new:    ACTIVE_ENDPOINT is the literal "host:port" itself. A hostname can
#           never contain ':' (endpoint_host_valid's charset forbids it), so
#           "contains a colon" is an unambiguous discriminator against the
#           legacy shape below -- no separate version field needed.
#   legacy: ACTIVE_ENDPOINT is "lan" or "vpn", resolved through
#           ENDPOINT_<SLOT>_HOST/PORT exactly as before. Kept working
#           untouched; nothing new ever writes this shape again.
active_endpoint_host_port() {
    case "${ACTIVE_ENDPOINT:?no ACTIVE_ENDPOINT set}" in
        *:*)
            printf '%s %s' "${ACTIVE_ENDPOINT%:*}" "${ACTIVE_ENDPOINT##*:}"
            ;;
        *)
            local hv pv
            hv=$(endpoint_host_var "$ACTIVE_ENDPOINT")
            pv=$(endpoint_port_var "$ACTIVE_ENDPOINT")
            printf '%s %s' "${!hv:?no $hv set for active endpoint '$ACTIVE_ENDPOINT'}" "${!pv:-22}"
            ;;
    esac
}

# Human display for the current endpoint: bare "host:port" for a new-shape
# record (nothing extra to add), "slot (host:port)" for a legacy one where
# the slot name is itself extra information. Reads ACTIVE_ENDPOINT/LOAD_HOST/
# LOAD_PORT from the caller's scope.
endpoint_display() {
    if [ "${ACTIVE_ENDPOINT:-}" = "${LOAD_HOST:-}:${LOAD_PORT:-}" ]; then
        printf '%s' "${ACTIVE_ENDPOINT:-?}"
    else
        printf '%s (%s:%s)' "${ACTIVE_ENDPOINT:-?}" "${LOAD_HOST:-?}" "${LOAD_PORT:-?}"
    fi
}

# REV-20260730-004 F5: a categorized check, not just a raw `zfs allow` dump --
# walks from the pool root down to the dataset, and separates "grant found
# exactly here" from "grant found on an ancestor" (which `zfs allow <child>`
# never shows on its own -- found live during --unpair work, see
# PAIRING-DESIGN.md). Prints one clear warning line if any ancestor grants
# the same account; the raw per-level dump is shown only when verbose=1.
check_inherited_grants() {
    local ds="$1" account="$2" host="$3" port="$4" keyfile="$5" alias_kh="$6" alias="$7" verbose="$8"
    local -a opts; load_ssh_opts "$keyfile" "$alias" "$alias_kh" "$port"; opts=("${LOAD_SSH_OPTS[@]}")
    local path="" seg out found_exact=0 ancestors=""
    IFS='/' read -ra _segs <<< "$ds"
    for seg in "${_segs[@]}"; do
        path="${path:+$path/}$seg"
        out=$(ssh -n "${opts[@]}" "${account}@${host}" "zfs allow '$path'" 2>&1)
        if [ "$verbose" -eq 1 ]; then
            echo "    zfs allow $path :"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi
        if printf '%s' "$out" | grep -qF "$account"; then
            if [ "$path" = "$ds" ]; then
                found_exact=1
            else
                ancestors="$ancestors $path"
            fi
        fi
    done
    if [ -n "$ancestors" ]; then
        warn "konto $account ma szerszy odziedziczony dostep z:$ancestors -- '$ds' NIE jest izolowany do tej relacji"
    fi
    [ "$found_exact" -eq 1 ] || warn "brak jawnego grantu dokladnie na '$ds' -- sprawdz recznie (zfs allow $ds na $host)"
}

# REV-20260811-102 step 3 (owner "Q4"): before a collector-scheduled REMOTE source
# prune is installed, verify -- FAIL CLOSED -- that the relationship's already
# delegated identity holds the capabilities managed source retention depends on:
# `destroy`, which delsnaps.sh's plain `zfs destroy <snap>` needs on each source
# dataset, and (REV-20260812-111) `bookmark`, without which the continuity anchor
# that survives retention cannot be written. Re-derived from the command
# path, not a remembered grant: deploy.sh do_commit_scope already delegates
# `destroy` (ZFS_PERMS), so this WIDENS NOTHING -- it only refuses to install a
# remote prune whose authorization cannot be confirmed, rather than shipping an
# hourly job that fails or silently assuming the grant. Unlike check_inherited_grants
# (which WARNs), this DIES: a destructive job on a production source must not be
# installed on hope.
assert_source_prune_grant() {   # <account> <host> <port> <keyfile> <alias> <alias_kh> <source-dataset>...
    local account="$1" host="$2" port="$3" keyfile="$4" alias="$5" alias_kh="$6"; shift 6
    local -a opts; load_ssh_opts "$keyfile" "$alias" "$alias_kh" "$port"; opts=("${LOAD_SSH_OPTS[@]}")
    local ds out rc
    for ds in "$@"; do
        out=$(ssh -n "${opts[@]}" "${account}@${host}" "zfs allow -- '$ds'" 2>&1); rc=$?
        [ "$rc" -eq 0 ] || die "source-prune grant check: 'zfs allow $ds' on $host as $account failed (ssh/zfs exit $rc) -- refusing to install a remote source prune whose authorization cannot be confirmed. Output: $(printf '%s' "$out" | tail -2)"
        # The account's own permission line carries a comma-list of perms; `destroy`
        # is bounded by commas/space so grep -w matches it inside snapshot,destroy,send.
        if ! printf '%s\n' "$out" | grep -F -- "$account" | grep -qw destroy; then
            die "source-prune grant check FAILED CLOSED: the delegated identity '$account' does not hold 'destroy' on the source '$ds' (needed by delsnaps.sh's zfs destroy). The pairing already grants destroy via deploy.sh --commit-scope; re-run --commit-scope on $host if it is missing. Refusing to install a source-prune job that would fail every run -- and NOT widening the grant here."
        fi
        # REV-20260812-111 A: the SECOND capability managed source retention
        # depends on, checked on the SAME `zfs allow` output -- no extra round
        # trip. Once retention ages out the ordinary common snapshot, the only
        # thing that still anchors an incremental is the per-target bookmark
        # record_send_bookmark() refreshes after every non-recursive transfer.
        # That refresh is deliberately best-effort: measured live 2026-08-12 on
        # a source delegated everything EXCEPT `bookmark`, the transfer logged
        # "cannot create bookmark ...: permission denied" plus a non-fatal
        # warning and still returned 0. So the relationship activates looking
        # healthy, carries no insurance, and stops permanently the first time
        # the common base is lost -- the failure REV-102's campaign exposed and
        # REV-111 exists to prevent at activation time instead of at 03:00.
        # Same discipline as `destroy` above: deploy.sh --commit-scope already
        # delegates `bookmark` (ZFS_PERMS / do_commit_scope), so this VERIFIES
        # and never widens.
        if ! printf '%s\n' "$out" | grep -F -- "$account" | grep -qw bookmark; then
            die "source-prune grant check FAILED CLOSED: the delegated identity '$account' holds 'destroy' but NOT 'bookmark' on the source '$ds'. Managed source retention will eventually age out the ordinary common snapshot, and the bookmark that would still anchor the next incremental cannot be created -- the transfer keeps exiting 0 while carrying no continuity insurance, then refuses permanently once the common base is gone. deploy.sh --commit-scope already grants bookmark; re-run --commit-scope on $host if it is missing. Refusing to install source retention on a relationship whose continuity cannot be maintained -- and NOT widening the grant here."
        fi
    done
}

# REV-20260812-111 B: the other way a managed relationship can be born without
# continuity insurance -- not a missing grant, a transfer MODE that has no
# bookmark at all.
#
# Measured 2026-08-12 (REV-102 campaign, leg B3): an atomic `-r` relationship
# carries zero bookmarks, because both engines gate the whole bookmark path on
# `RECURSIVE -ne 1` -- they neither record one after a transfer nor consult one
# when the common base is gone. Managed source retention is precisely the thing
# that eventually removes that common base. The two together describe a
# relationship that is GUARANTEED to stop permanently and need a destructive
# re-seed; leg B4 measured that ending (explicit refusal, exit 1, TARGET tree
# preserved -- safe, but stopped).
#
# The high-level layer never emits `recursive = atomic`: every [dataset:] section
# it generates carries `recursive = no`. So this combination can only arrive from
# a hand-edited CONFIG -- which is exactly why the check reads the CANDIDATE about
# to be installed rather than trusting what this run generated.
#
# Deliberately NOT rewritten to `flat` (-R), which DOES keep per-dataset bookmarks
# (leg B5). atomic and flat are different transfer modes with different ordering
# and crash semantics; silently converting one into the other to satisfy a safety
# check is the "helpful repair" this project refuses everywhere else. Refuse, name
# both options, let a human choose.
assert_no_atomic_with_source_retention() {   # <configfile> <local dataset path>...
    local cfg="$1"; shift
    local lp rec
    for lp in "$@"; do
        rec="$(installed_dataset_field "$cfg" "$lp" recursive)"
        rec="$(printf '%s' "$rec" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        [ "$rec" = atomic ] || continue
        die "source-retention/recursion conflict on '[dataset:$lp]': it declares 'recursive = atomic' (one atomic -r stream for the whole subtree), and this run would install managed SOURCE retention on that relationship. An atomic relationship keeps NO bookmark -- the engines neither record nor consult one under -r -- so once retention ages out the last ordinary common snapshot there is nothing left to anchor an incremental, and the relationship stops permanently until someone performs a destructive re-seed. Refusing to install source retention on it. Resolve it deliberately: either set 'recursive = flat' (per-dataset -R, which does keep bookmark insurance -- but it is a DIFFERENT transfer mode, so change it because you want that mode, not because this message mentioned it), or leave source retention off for this relationship. Nothing was changed."
    done
}

# Phase 5 slice 3: propose a backup target when the operator did not name one.
# Extracted verbatim from cmd_setup_server rather than reimplemented -- the two
# callers must not drift into two different ideas of "where backups go".
#
# Echoes "<target>\t<provenance>" where provenance is `default` (an explicit
# earlier operator decision recorded in server.conf) or `heuristic` (this
# function guessed from the pool layout). Callers are expected to treat those
# two very differently: a guess may be proposed and shown, never acted on
# without a human looking at it.
#
# read_server_conf must have run first, exactly as in cmd_setup_server.
propose_backup_target() {
    if [ -n "${DEFAULT_TARGET:-}" ]; then
        printf '%s\t%s\n' "$DEFAULT_TARGET" default
        return 0
    fi
    local pools candidates
    pools=$(zpool list -H -o name 2>/dev/null) || die "zpool list failed"
    candidates=$(printf '%s\n' "$pools" | grep -v '^rpool$')
    case "$(printf '%s\n' "$candidates" | grep -c .)" in
        0) warn "only 'rpool' exists -- proposing rpool/backups. Confirm this is really where you want backups (rpool is usually the OS/VM pool)."
           printf '%s\t%s\n' "rpool/backups" heuristic ;;
        1) printf '%s\t%s\n' "${candidates}/backups" heuristic ;;
        *) die "multiple candidate pools found ($(printf '%s' "$candidates" | tr '\n' ' ')) -- pass --target=POOL/PATH explicitly" ;;
    esac
}

# KROK 5: propose the SOURCES when the operator did not name any.
#
# The target had this since slice 3; the source did not, and a local backup was
# refused outright without --source. That is the one piece of "clean host ->
# working backup" glue the binding plan still asks for: a first-time operator
# does not know which of this host's forty datasets are the ones worth copying,
# and making them find out by reading `zfs list` is the manual step the whole
# path exists to remove.
#
# A PROPOSAL, never a decision. Everything this prints is a guess from the pool
# layout, so it carries the same rule the guessed target carries: it may be
# shown, it may be planned with, and it may NOT be installed unattended.
#
# WHAT IS EXCLUDED, and why each one would be wrong rather than merely noisy.
# Every exclusion is REPORTED on stderr, because an invisible heuristic is
# indistinguishable from a bug to the operator who wonders where a dataset went:
#
#   pool root      a pool is a container, not a body of data. Proposing `hdd`
#                  would offer to snapshot the thing that holds the target;
#   the target     and everything under it -- a backup cannot land inside the
#                  thing it backs up (local_backup_overlap refuses it anyway,
#                  so proposing it would only produce a refusal);
#   under */ROOT   the OS root filesystem. This tool does not restore a bootable
#                  system, so offering it promises something it cannot keep;
#   swap           a swap zvol holds no data worth a snapshot, and snapshotting
#                  it pins every block it ever wrote;
#   already        a dataset an installed section already covers. Proposing it
#   covered        would compose into an overlap refusal on the very next step.
#
# A HIERARCHY IS NOT GUESSED AT -- REV of KROK 5 slice 1, F1.
#
# The first cut skipped any dataset that had a child and proposed the children
# instead, reasoning that a flat job on the parent would leave the children
# unbacked. That reasoning is right and the conclusion was wrong: a parent
# filesystem holds its own files independently of its children, so proposing
# only the children replaces APPARENT coverage with SILENT missing coverage --
# the operator accepts a proposal and the parent's data is simply not copied.
# The suite encoded that as the expected behaviour, so it went green.
#
# Measured rather than assumed (pve9, real ZFS): an empty parent reports
# usedbydataset=24576 and the same parent with 3 MiB of its own files reports
# 3173376. So "does the parent hold data" IS answerable -- but only against a
# threshold picked out of the air, and an emptiness floor differs with
# recordsize, compression and pool ashift. This function does not get to invent
# that number.
#
# So the layout decides, not a size: local-backup installs one FLAT job per
# root and `local_backup_overlap` refuses a parent and its child in the same
# set, which means there is no shape this PROPOSAL can emit that covers both.
# When the eligible datasets contain a parent/child pair, it therefore refuses
# to guess (rc=2) and hands the operator the whole eligible list to choose
# from, rather than choosing a half of it for them. That is the same stance the
# TARGET proposal already takes on multiple candidate pools: ambiguity refuses.
#
# Candidates on STDOUT, the skip report on STDERR -- deliberately not through a
# variable. This function is called inside a command substitution, where every
# assignment happens in the SUBSHELL and is gone by the time the caller looks;
# a report the caller cannot see is the same as no report. Like
# propose_backup_target it must also not be the place a die() happens inside
# that substitution -- the caller checks for an empty result instead.
propose_backup_sources() {   # <target> <installed config or ""> -> candidates, one per line
    local target="$1" cfg="${2:-}"
    local skipped="" eligible=""
    local all
    all=$(zfs list -H -o name -t filesystem,volume 2>/dev/null) || return 1
    [ -n "$all" ] || return 1

    # Covered paths, read from the installed config the same way the overlap
    # check reads it -- one source of truth for "this is already ours".
    local covered=""
    if [ -n "$cfg" ] && [ -r "$cfg" ]; then
        covered=$(sed -n 's/^\[dataset:\(.*\)\]$/\1/p' "$cfg")
    fi

    local ds child skip why
    while IFS= read -r ds; do
        [ -n "$ds" ] || continue
        skip=""; why=""
        case "$ds" in
            */*) ;;
            *) skip=1; why="pula, nie zbior danych" ;;
        esac
        if [ -z "$skip" ] && local_backup_overlap "$ds" "$target"; then
            skip=1; why="cel backupu (albo lezy w nim)"
        fi
        if [ -z "$skip" ]; then
            case "$ds" in
                */ROOT|*/ROOT/*) skip=1; why="system operacyjny -- ten pakiet nie odtwarza bootowalnego systemu" ;;
                */swap|*/swap/*) skip=1; why="swap -- snapshot przypina kazdy zapisany blok i nie niesie danych" ;;
            esac
        fi
        # "Already covered" is EXACT dataset identity, not path overlap -- and
        # that distinction is the same finding as the hierarchy one, in the
        # place it hides best.
        #
        # A local job is FLAT: [dataset:rpool/a] copies rpool/a's own blocks and
        # nothing else. So an installed parent does NOT cover a child created
        # under it later, and an installed child does not cover its parent. The
        # first version tested with local_backup_overlap, which meant a new
        # child under an installed parent was skipped as "already covered" and
        # silently never proposed -- apparent coverage over missing coverage,
        # exactly what the hierarchy rule exists to prevent, arrived at from the
        # other side.
        #
        # The one case where containment IS coverage is a section that says so:
        # `recursive` set to anything but no/off/0 means the installed job
        # really does walk the subtree, and then a descendant is genuinely
        # covered. Read from the section rather than assumed, so a config an
        # operator made recursive by hand is honoured.
        if [ -z "$skip" ] && [ -n "$covered" ]; then
            local c crec
            while IFS= read -r c; do
                [ -n "$c" ] || continue
                if [ "$ds" = "$c" ]; then
                    skip=1; why="juz objety zainstalowana polityka ([dataset:$c])"; break
                fi
                case "$ds" in
                    "$c"/*)
                        crec="$(installed_dataset_field "$cfg" "$c" recursive)"
                        crec="$(printf '%s' "$crec" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
                        case "$crec" in
                            ""|no|off|0) ;;   # flat parent: does NOT cover this child
                            *) skip=1; why="juz objety rekurencyjna sekcja [dataset:$c] (recursive=$crec)"; break ;;
                        esac
                        ;;
                esac
            done <<< "$covered"
        fi
        if [ -n "$skip" ]; then
            skipped="${skipped}  pominieto $ds -- $why"$'\n'
        else
            eligible="${eligible}${ds}"$'\n'
        fi
    done <<< "$all"
    [ -n "$skipped" ] && printf '%s' "$skipped" >&2

    # The hierarchy check, over the ELIGIBLE set only: a parent excluded above
    # (a pool root, the target, an OS root) is not part of any pair, because it
    # was never going to be proposed in the first place.
    #
    # Reported and refused rather than resolved: a parent cannot be dropped in
    # favour of its children (its own files would stop being copied) and it
    # cannot be proposed alongside them either (local_backup_overlap refuses
    # the pair). There is no third shape this function may emit, so the
    # operator gets the facts and the choice.
    local a b pairs=""
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            case "$b" in
                "$a"/*) pairs="${pairs}  $a  ->  $b"$'\n' ;;
            esac
        done <<< "$eligible"
    done <<< "$eligible"

    # Only the AMBIGUOUS SUBTREE is refused, not the whole proposal: a
    # hierarchy somewhere on the host says nothing about the datasets that are
    # not in it, and refusing everything would deny the operator the obvious
    # candidates because of one pair they may not even care about.
    #
    # Both members of every pair drop out. Not the parent alone -- that is the
    # defect this exists to fix (its own files stop being copied while the
    # proposal looks complete); and not the children alone either, because a
    # child proposed without its parent is the same claim in the other
    # direction. The subtree leaves together, loudly, with the pair named.
    if [ -n "$pairs" ]; then
        local amb="" keep=""
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            local hit=0
            while IFS= read -r b; do
                [ -n "$b" ] || continue
                case "$b" in "$a"/*) hit=1; break ;; esac
                case "$a" in "$b"/*) hit=1; break ;; esac
            done <<< "$eligible"
            if [ "$hit" -eq 1 ]; then amb="${amb}$a"$'\n'; else keep="${keep}$a"$'\n'; fi
        done <<< "$eligible"
        {
            printf '  poddrzewo dwuznaczne -- NIE proponuje go, wybierz jawnie:\n'
            printf '%s' "$pairs"
            printf '  rodzic trzyma wlasne pliki niezaleznie od dzieci, wiec dzieci NIE pokrywaja\n'
            printf '  rodzica; a plaskie zadanie na rodzica nie kopiuje dzieci, i oba w jednym\n'
            printf '  zestawie sa odrzucane jako nakladajace sie. Zadna z tych postaci nie jest\n'
            printf '  prawdziwa, wiec wybor nalezy do Ciebie:\n'
            printf '%s' "$amb" | sed 's/^/    --source=/'
        } >&2
        eligible="$keep"
    fi

    printf '%s' "$eligible"
    return 0
}

# read_server_conf lives in lib-backup-common.sh since the restore split.

# ---- the profile runtime (Slice B1) -----------------------------------------
#
# Until B1 the policy above lived in shell variables in this file. It now lives
# in profiles/<name>/, and this is the only place that reads it.
#
# The rendered artifacts are held in temporary files for the life of the
# process, not re-rendered per call: rendering twice is two chances to disagree,
# and the section names it produces end up in a config we then compare against.
PROFILE_LOADED=""
PROFILE_TPL_FILE=""
PROFILE_EXCL_FILE=""
PROFILE_LETTERS_FILE=""
PROFILE_DS_FILE=""
PROFILE_PRUNE_FILE=""
# BASHPID of the shell whose EXIT trap holds the release. Inherited by a
# subshell like any other variable, which is the point: the comparison against
# the subshell's own BASHPID is what tells it the trap is NOT armed there.
PROFILE_TRAP_PID=""
# BASHPID of the shell that sourced or executed this file, recorded at file
# scope because that is the one moment at which the answer is certain. It is
# what makes `trap -p EXIT` usable: in THIS shell the report is authoritative,
# in any other shell it may be an inherited string for a trap that is not armed
# there. See _profile_arm_release.
PROFILE_HOST_PID="$BASHPID"
# Source datasets that emit_client_sections wrote a REMOTE [prune:] for this run;
# the flow grant-checks exactly these before publishing (REV-20260811-102 step 3).
SOURCE_PRUNE_EMITTED_DS=()
# Per source dataset, the INSTALLED remote source [prune:] POLICY body captured
# before removal, so a re-activation preserves an admin's edited source retention
# and moves only topology (scope header + ssh_flags) -- REV-20260811-107.
declare -A SOURCE_PRUNE_PRESERVED=()

# Remove the rendered artifacts and REPORT what it could not remove.
#
# A cleanup that cannot admit its own failure launders the leftover
# (REV-20260813-119 F1.4), so this verifies the removal instead of trusting
# `rm -f`'s status -- `rm -f` is silent about a file it never had to touch and
# about one an unreadable-directory mode leaves in place. The warning names the
# exact surviving paths, because "some temporary file leaked" is not something
# an operator can act on.
#
# It does NOT turn a successful run into a failed one. Nothing this tool tells
# the operator -- what was installed, what was pruned, what the peer now holds
# -- becomes untrue because a scratch file in $TMPDIR survived. Flipping the
# status would report the transaction as failed when it succeeded, which is the
# larger lie. The warning is the report.
profile_release_tmp() {
    local f left=""
    for f in "$PROFILE_TPL_FILE" "$PROFILE_EXCL_FILE" "$PROFILE_DS_FILE" "$PROFILE_PRUNE_FILE" "$PROFILE_LETTERS_FILE"; do
        [ -n "$f" ] || continue
        rm -f "$f" 2>/dev/null
        [ -e "$f" ] && left="$left $f"
    done
    PROFILE_TPL_FILE=""; PROFILE_EXCL_FILE=""; PROFILE_DS_FILE=""; PROFILE_PRUNE_FILE=""; PROFILE_LETTERS_FILE=""; PROFILE_LOADED=""
    if [ -n "$left" ]; then
        warn "could not remove the rendered profile file(s):$left -- they are still in place"
        return 1
    fi
    return 0
}

# The candidate config a transactional command builds before it publishes.
#
# Every command that writes one already removes it on each of its OWN failure
# paths -- `rm -f "$workfile"; die ...` appears at each one. What none of them
# can reach is a die() raised INSIDE a function they called: ensure_cron_config
# refusing a floor conflict, emit_client_sections refusing a foreign section,
# a grant check failing. The shell exits from under the caller and the
# half-written candidate stays next to the live config, mode 0644, named
# .zfsbackup-work.XXXXXX. Harmless to the running estate -- nothing reads a
# file by that name -- but it is the same leak class that left 1824 rendered
# profile copies in pve0's /tmp, and it accumulates in the one directory an
# operator looks at when something has gone wrong.
#
# Hooked into the EXIT handler that already exists rather than arming a second
# trap: _profile_arm_release composes carefully with a consumer's own handler,
# and two independent traps would be one composition too many.
WORKFILE_TRACKED=""
workfile_track() {   # <path> -- release it if the shell dies before it is published
    WORKFILE_TRACKED="$1"
    _profile_arm_release
}
# Publishing or explicitly discarding it ends the tracking: the path is either
# gone or is now the live config, and removing THAT on exit would be a disaster
# rather than a cleanup.
workfile_untrack() { WORKFILE_TRACKED=""; }
workfile_release_tmp() {
    [ -n "$WORKFILE_TRACKED" ] || return 0
    local f="$WORKFILE_TRACKED"; WORKFILE_TRACKED=""
    rm -f "$f" 2>/dev/null
    [ -e "$f" ] && warn "could not remove the candidate config $f -- it is still in place"
    return 0
}

# The EXIT trap preserves the status the shell was already exiting with: the
# leak is a scratch-file problem, not a verdict on the run.
_profile_release_on_exit() { local rc=$?; workfile_release_tmp; profile_release_tmp; return "$rc"; }

# Arm the trap in THIS shell, at load time -- not at file scope.
#
# Bash resets traps in a subshell, so a file-scope trap would never fire for a
# profile loaded inside `( ... )`, and that is exactly where the measured leak
# came from: test/zfsbackup/run.sh drives its profile loads in subshells, and
# 2026-08-14 found 1824 rendered-profile copies in pve0's /tmp from two days of
# suite runs. Arming here covers every shell that actually renders a profile --
# the real invocation, and each subshell.
#
# BASHPID, not `trap -p`, decides whether this shell is already armed. Measured
# on bash 5.1.4: inside a subshell `trap -p EXIT` REPORTS an ancestor's action
# string even though that trap is not armed there and will not run there. A
# first version asked `trap -p` whether somebody else owned EXIT, read the
# suite's own parent trap in every subshell, concluded it should keep its hands
# off, and armed nothing -- the leak survived the fix and only the positive
# control caught it. BASHPID differs in every subshell, so keying on it asks the
# question that can actually be answered: did *this* shell arm it.
#
# The same measurement says a foreign trap must NOT be chained blindly: chaining
# a merely-reported action would re-run something that may belong to an ancestor
# -- in the suite's case `rm -rf "$WORK"`, executed inside every subshell,
# destroying the fixtures of a run still in progress.
#
# But replacing unconditionally was wrong in the other direction, and measurably
# so: `source ./zfs-backup.sh` followed by a profile load in the SAME shell
# deleted that shell's own EXIT trap. This file is sourceable by design (guarded
# dispatch; the suite sources it), so that is a consumer's cleanup silently
# discarded, not an internal detail.
#
# What separates the two cases is knowing which shell we are in, which is why
# PROFILE_HOST_PID is recorded at file scope:
#
#   BASHPID == PROFILE_HOST_PID  we are the shell that sourced/executed this
#                                file. Anything `trap -p EXIT` reports here is
#                                genuinely armed HERE, so ownership is decidable
#                                and a foreign action can be COMPOSED with --
#                                release first, then run what the caller armed.
#                                It would have run anyway; we only precede it.
#
#   otherwise                    a subshell. The report may be an inherited
#                                string for a trap that will never fire here, so
#                                it is not usable evidence and the ancestor
#                                hazard above applies. Replace, and stay bounded:
#                                this program installs no EXIT trap of its own,
#                                so nothing internal is displaced. A consumer
#                                that arms a trap inside its OWN subshell and
#                                then renders a profile there owns that
#                                composition.
_profile_arm_release() {
    [ "${PROFILE_TRAP_PID:-}" = "$BASHPID" ] && return 0
    # `bs` is a DOUBLED backslash on purpose: the replacement below is a pattern
    # context, where a backslash escapes the next character. A single one would
    # turn the '\'' we are looking for into three plain quotes, match nothing,
    # and hand the shell an unbalanced action string -- measured as
    # "unexpected EOF while looking for matching `'`" from the composed trap.
    local prev="" action="" q="'" bs='\\'
    # Only ask in the host shell, where the answer means something.
    [ "$BASHPID" = "${PROFILE_HOST_PID:-}" ] && prev="$(trap -p EXIT)"
    if [ -n "$prev" ]; then
        # `trap -p` prints a re-usable command: trap -- 'ACTION' EXIT, with any
        # embedded single quote written as '\''. Undo exactly that, in that
        # order; the quote case is not hypothetical, it is any handler that
        # quotes a path.
        action="${prev#trap -- }"
        action="${action% EXIT}"
        action="${action#$q}"
        action="${action%$q}"
        action="${action//$q$bs$q$q/$q}"
        # _profile_release_on_exit restores $?, so the caller's own handler sees
        # the status the shell was exiting with rather than our cleanup's.
        trap "_profile_release_on_exit; $action" EXIT
    else
        trap _profile_release_on_exit EXIT
    fi
    PROFILE_TRAP_PID="$BASHPID"
}

load_active_profile() {
    [ -n "$PROFILE_LOADED" ] && return 0
    # A caller that cleared PROFILE_LOADED to re-render is about to overwrite
    # these three variables; the files they point at have to go first or the
    # trap can only ever reach the LAST set. The suite reloads inside one
    # subshell, so this is a live path, not a defensive nicety.
    profile_release_tmp
    local dir="$(profile_file "$PROFILE_ACTIVE")"
    # Validate before rendering. A profile that carries relationship-owned
    # fields must never reach a config, and finding that out from gen-cron
    # afterwards would mean it already had.
    profile_validate_file "$dir" "$GENCRON" || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    # Arm BEFORE the first allocation, not after the last. Arming afterwards
    # left a window in which allocation 2 or 3 could fail, `die` could exit, and
    # everything already allocated survived with no trap to reach it -- measured:
    # failing the second render allocation left the first file behind. The
    # handler skips empty variables, so arming this early costs nothing and
    # covers every failure path without one release call per path.
    _profile_arm_release
    PROFILE_TPL_FILE=$(mktemp)   || die "mktemp failed"
    # Rendered separately because it composes differently -- see
    # profile_render_templates. The floors live here; the templates file stays
    # safe to concatenate with another profile's.
    PROFILE_EXCL_FILE=$(mktemp)  || die "mktemp failed"
    PROFILE_DS_FILE=$(mktemp)    || die "mktemp failed"
    PROFILE_PRUNE_FILE=$(mktemp) || die "mktemp failed"
    # ONE FILE IN, FOUR ARTIFACTS OUT. profile.conf is what an operator edits;
    # the split is this runtime's business and nobody else's. The tier-letter
    # table comes from gen-cron itself (--dump-tier-letters), so `keep = 24` in
    # a profile becomes `retain = -H24` without this file keeping a second copy
    # of what -W means.
    local _psplit_t _psplit_d _psplit_p
    _psplit_t=$(mktemp) || die "mktemp failed"
    _psplit_d=$(mktemp) || die "mktemp failed"
    _psplit_p=$(mktemp) || die "mktemp failed"
    PROFILE_LETTERS_FILE=$(mktemp) || die "mktemp failed"
    bash "$GENCRON" --dump-tier-letters > "$PROFILE_LETTERS_FILE" 2>/dev/null \
        || die "profile '$PROFILE_ACTIVE': could not read the tier-letter table from gen-cron.sh -- refusing to translate a retention against a table this run cannot see"
    profile_split_one_file "$dir" "$_psplit_t" "$_psplit_d" "$_psplit_p" "$PROFILE_EXCL_FILE" \
        || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    profile_render_templates "$_psplit_t" "$(profile_name_of "$PROFILE_ACTIVE")" "$PROFILE_TPL_FILE" "" "$PROFILE_LETTERS_FILE" \
        || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    profile_render_fragment "$_psplit_d" "$(profile_name_of "$PROFILE_ACTIVE")" "$PROFILE_DS_FILE"         || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    profile_render_fragment "$_psplit_p" "$(profile_name_of "$PROFILE_ACTIVE")" "$PROFILE_PRUNE_FILE"         || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    # The split halves were scaffolding for this function alone: they never
    # leave it, so they are removed here rather than joining the release list,
    # which exists for the artifacts the REST of the run reads.
    rm -f "$_psplit_t" "$_psplit_d" "$_psplit_p"
    PROFILE_LOADED=1
    return 0
}

# WHAT THIS RELATIONSHIP WAS GENERATED FROM, as one comparable value.
#
# REV F2. `migrate-profile --profile=prod` decided "already there" from the
# record's PROFILE string alone, so the file's own promise -- "an operator
# changes a retention here and nowhere else" -- was false for the case that
# matters most: edit `keep = 7` to `keep = 10` in profiles/prod/profile.conf,
# re-run the command, and it answers "nothing to migrate" while the installed
# cron still carries -D7. A name is not a version.
#
# TWO INPUTS, because either one alone would lie:
#
#   profile.conf   what the operator edits. Catches every retention, schedule,
#                  quiesce, monitor and version change.
#   the tier-letter table (gen-cron --dump-tier-letters)
#                  the RENDERER's contribution. `keep = 24` becomes `-H24`
#                  through that table, so a table change alters the installed
#                  policy without touching a byte of the profile. A digest over
#                  the operator's file alone would call that "unchanged".
#   PROFILE_RENDER_SCHEMA (lib-profile.sh)
#                  the renderer's own version. REV F2b: the first two inputs
#                  still miss a change to HOW a profile is rendered -- the
#                  namespacing, the fragment split, the keep translation. Same
#                  file, same table, different installed CONFIG, identical
#                  digest, and migrate-profile answering "nothing to migrate".
#                  A number a human bumps rather than a hash of the library,
#                  because only a human knows whether the OUTPUT changed; a
#                  hash would move on a comment edit and migrate the fleet for
#                  nothing.
#
# Not a security hash and not trying to be: md5 is what this tree already uses
# for the same job (delsnaps' lock key, clean-relationships' crontab
# comparison). It answers "is this still the thing I generated from".
profile_digest() {   # -> a comparable digest of the ACTIVE profile, or rc 1
    local dir="$(profile_file "$PROFILE_ACTIVE")"
    [ -r "$dir" ] || return 1
    local letters
    letters="$(bash "$GENCRON" --dump-tier-letters 2>/dev/null)" || return 1
    { cat "$dir"
      printf '%s' "$letters"
      printf 'render-schema=%s' "${PROFILE_RENDER_SCHEMA:-0}"
    } | md5sum | cut -d' ' -f1
}

# A PROFILE IS A FILE, and you may say which one.
#
#   --profile=prod                 a NAME. Looked up as <name>.conf, first in
#                                  this host's own directory, then in the
#                                  package's.
#   --profile=/path/to/mine.conf   a PATH. Anything containing '/' is taken as
#                                  the file itself, and nothing is searched.
#
# The two directories are the split this tree already draws everywhere else:
# the package holds what we ship and is replaced wholesale by `git pull`; /etc
# holds what this host decided and survives every update. "Never carried to
# GitHub" is therefore a consequence of the location, not a rule to remember --
# /etc is not in the checkout.
#
# Decided by the fleet rather than by convention: pve1 carries FOUR copies of
# the package (root's, the delegated account's, two in /tmp). A profiles.local/
# beside the checkout would exist once per copy, and "where are this host's
# profiles" would depend on which account ran the command.
profile_file() {   # <file name or path> -> the profile file to use
    local n="$1" d
    case "$n" in */*) printf '%s' "$n"; return 0 ;; esac
    # THE ARGUMENT IS A FILE NAME, taken literally. The first cut appended
    # `.conf` to it, so `--profile=firma.conf` went looking for firma.conf.conf
    # and only the extension-less shorthand worked -- the opposite of the
    # instruction, which was that a profile is a file and you may name it.
    for d in "$PROFILE_USER_ROOT" "$PROFILE_ROOT"; do
        [ -f "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }
    done
    # The shorthand survives as a compatible alias, because `--profile=default`
    # is what every existing record, test and habit already says.
    case "$n" in
        *.conf) : ;;
        *) for d in "$PROFILE_USER_ROOT" "$PROFILE_ROOT"; do
               [ -f "$d/$n.conf" ] && { printf '%s' "$d/$n.conf"; return 0; }
           done ;;
    esac
    # Nothing matched. Answer with the package path so the refusal that follows
    # names a place worth looking, rather than an empty string.
    case "$n" in
        *.conf) printf '%s' "$PROFILE_ROOT/$n" ;;
        *)      printf '%s' "$PROFILE_ROOT/$n.conf" ;;
    esac
}

# The name a profile is known BY, which is not the same thing as where it lives:
# it namespaces every template the profile renders (profile__<name>__<tier>), so
# it has to survive being given as a path and must never carry a '/'.
profile_name_of() {   # <name or path> -> the bare name
    local n="${1##*/}"
    printf '%s' "${n%.conf}"
}

# Phase 4: the profile choice is CREATE-time provenance, consulted only the
# one time a relationship first renders its sections. A re-activation never
# re-reads it -- same one-way handoff boundary REV-20260809-088/089 already
# draw for the profile in general: an operator's installed policy, and any
# customization on top of it, survive set-endpoint/re-activation untouched
# regardless of what the client record's PROFILE field says or whether it
# even exists (old client records predating this field pass "" here, which
# is a no-op -- PROFILE_ACTIVE keeps its env/default value, zero migration).
apply_client_profile_choice() {   # <is_new_relationship 0|1> <chosen profile name, may be empty>
    local is_new="$1" chosen="$2"
    if [ "$is_new" -eq 1 ] && [ -n "$chosen" ]; then
        PROFILE_ACTIVE="$chosen"
    fi
}
# COMPOSE the rendered fragment. Do not translate it.
#
# REV-20260809-082 F1. The first version pulled three named keys out of the
# fragment -- use_template, gfs, gfs_pattern -- and wrote them by hand. That is
# a second semantic layer over a contract that is already native CONFIG v4: the
# boundary validates every dataset/prune field gen-cron declares, so any OTHER
# valid field validated cleanly at the one declared boundary and was then
# silently dropped by its only consumer. The built-in fixture carries only
# use_template, so nothing failed -- a false green sitting exactly where B1 was
# meant to remove one.
#
# It is also more machinery, not less: every future native field would need
# another edit here although gen-cron.sh already owns its semantics. The owner's
# reduction direction and this finding point the same way.
#
# What the RELATIONSHIP owns -- recursive, pair_label, notify, src -- is still
# written by the caller and cannot collide, because lib-profile.sh refuses those
# fields inside a profile.
#
# "Cannot collide" is a claim about the refusal list, and until 2026-08-31 the
# list did not carry the case that mattered: `recursive` was refused on a
# [prune:] and allowed on a [dataset:]. A profile using it validated, this
# function pasted it in, the caller wrote its own line below, and gen-cron
# refused the finished config for a duplicate field. Both kinds are refused now.
# The lesson is the shape of the sentence above, not the field: a collision is
# impossible only for the exact fields the validator names.
profile_emit() {   # <rendered fragment>
    local raw
    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw%$'\r'}"
        [ -z "${raw//[[:space:]]/}" ] && continue
        case "$raw" in '#'*) continue ;; esac
        printf '\t%s\n' "${raw#"${raw%%[![:space:]]*}"}"
    done < "$1"
}

# Does the loaded profile declare a retention LADDER at all?
#
# PROFILE_GFS answers a question about the INSTALLED CONFIG -- detect_profile_gfs
# reads the file. On a FRESH config there is nothing to read, so it answers 1
# ("ladder"), and a flat profile's first relationship then emitted a [prune:]
# ladder section with nothing to put in it. Measured on pve9, 2026-08-25, on the
# first prod relationship ever created:
#
#     gen-cron.sh: error: [prune:hdd/prodlab-k1/192.168.28.9] has no use_template
#
# `prod` could not create its FIRST relationship, let alone a second. The unit
# tests missed it because they exercised ensure_cron_config (templates and the
# frozen-shape refusal) rather than emit_client_sections (the sections).
#
# This asks the only question that cannot be wrong: the profile that is about to
# be written -- does it carry a prune fragment? A profile whose tiers prune
# themselves (prod) has none, and emitting an empty ladder for it is a defect by
# construction, not a policy choice. Fail-closed on emptiness.
profile_declares_ladder() {   # -> 0 when the loaded profile carries a [prune] fragment
    [ -n "${PROFILE_LOADED:-}" ] || return 1
    # -s BEFORE reading, for the same stale-temp reason spelled out in
    # profile_retention_fragment: an unreadable path here printed "No such file
    # or directory" from profile_emit's redirection and made a shape question
    # look like a crash.
    [ -s "${PROFILE_PRUNE_FILE:-}" ] || return 1
    profile_emit "$PROFILE_PRUNE_FILE" | grep -q '[^[:space:]]'
}

# One rendered [template:NS] section, whole.
profile_template_section() {   # <namespaced name>
    awk -v want="[template:$1]" '
        $0 == want { emit=1; print; next }
        emit && /^\[/ { exit }
        emit { print }
    ' "$PROFILE_TPL_FILE"
}

# --- SOURCE retention split (REV-20260811-104 F1 / REV-20260811-106 F1) ---------
# SOURCE and TARGET retention must be independently editable after CREATE, so the
# SOURCE cron line needs its OWN template identities, byte-copied from the profile's
# actual prune policy. These are derived from the templates the rendered prune
# fragment REALLY references (its use_template list), NOT from a `keep_*` naming
# convention -- so the split works for ANY profile the validator accepts, including
# one whose prune templates are named e.g. ret_hourly (REV-106 F1: the previous
# `__keep_` textual rewrite silently left such a profile's SOURCE sharing the
# TARGET's template authority). One implementation, reused by local PUSH and the
# remote-PULL source prune under REV-102.
#
# Source identity = referenced identity with its LAST `__` turned into `__src_`:
# the built-in default (profile__default__keep_hourly) stays
# profile__default__src_keep_hourly -- unchanged from the accepted REV-104 output --
# while a custom profile__P__ret_hourly becomes profile__P__src_ret_hourly.

# The template identities a rendered prune fragment references via use_template.
profile_prune_ref_ids() {   # <rendered prune fragment>
    profile_emit "$1" | awk -F= '
        /^[[:space:]]*use_template[[:space:]]*=/ {
            gsub(/[[:space:]]/, "", $2)
            n = split($2, a, ",")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
        }'
}

profile_to_src_id() {   # <template identity>
    printf '%s' "$1" | sed 's/\(.*\)__/\1__src_/'
}

# The SOURCE template family: every template the prune fragment references, copied
# under its source identity. Fails CLOSED if a referenced template is absent from
# the rendered templates -- never a silent fall-back to the TARGET's authority
# (REV-106 required property 4). Runs the loop in the current shell (process
# substitution, not a pipe) so `die` aborts the whole run.
# <existing config> is optional and is what makes a SECOND local-backup on the
# same host possible: the source family is emitted once and stays, so a later
# run adding another source must skip the templates that are already there.
# Without this the candidate carried two [template:...src_keep_hourly] sections
# and gen-cron refused the whole thing -- measured on a host whose config still
# had the family from an earlier run.
emit_source_template_family() {   # <rendered prune fragment> [existing config]
    local id src section
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        src="$(profile_to_src_id "$id")"
        if [ -n "${2:-}" ] && [ -f "$2" ] && grep -qxF "[template:$src]" "$2"; then
            continue
        fi
        section="$(profile_template_section "$id")"
        [ -n "$section" ] || die "local-backup source-retention: profile '$PROFILE_ACTIVE' references prune template '$id' but no rendered [template:$id] exists -- refusing to emit a SOURCE retention that would silently reuse the TARGET's template authority (REV-20260811-106)"
        printf '[template:%s]\n' "$src"
        printf '%s\n' "$section" | tail -n +2
        echo
    done < <(profile_prune_ref_ids "$1")
}

# The SOURCE prune fragment: the normalized prune fragment with each use_template
# identity rewritten to its source identity (exact, comma-list aware -- never a
# substring rewrite that could couple ids sharing a prefix).
# Where this profile keeps its RETENTION, which is not the same question as
# where it keeps its ladder.
#
# REV F1 (2026-08-26), measured on pve1 while the lab was still running:
#
#     33 automated_hourly_   9 automated_daily_   3 automated_weekly_   3 automated_monthly_
#
# on the SOURCE, against zero [prune:account@host:...] sections in the
# collector's config. An active pull CREATES those four families with
# `snapget -m`; the inline prune from [dataset:] bounds only the collector's
# COPY. Both remote-source emitters were gated on `PROFILE_GFS -eq 1`, which is
# false for every flat profile, so `prod` created snapshots on a production host
# and pruned none of them there. That is REV-20260811-102's original defect
# reborn one profile shape over.
#
# The log line this used to print -- "the source's own snapshots stay the
# source's business" -- was written for the PASSIVE case, where the family
# genuinely belongs to somebody else. Applied to a pull that stamps the family
# itself, it is a disclaimer for our own mess. Passive is filtered out by its
# own branch long before this, so the shape gate was protecting nothing.
#
# A ladder profile keeps retention in [prune]; a flat profile keeps it in the
# tiers its [dataset] references. Both are a fragment carrying use_template, so
# the machinery below needs the right FILE, not a new mechanism.
# PROFILE_LOADED=1 WITH THE ARTIFACTS GONE IS A LIE, and it must be repaired by
# a function nobody calls inside `$( )`.
#
# The suite renders profiles inside subshells; a subshell's EXIT trap releases
# the temps and clears ITS copy of the variables, while the parent keeps the flag
# and paths to files that no longer exist. Twice I tried to answer that inside
# the resolver -- and the resolver's every caller reads it as
# `frag="$(profile_retention_fragment)"`, which is ITSELF a subshell. The
# re-render allocated fresh temps, the substitution ended, its trap removed them,
# and the caller got a path to nothing. The test caught it; the production
# callers had exactly the same shape.
#
# So the repair is separate and is called PLAINLY, in the caller's own shell,
# where an allocation survives. Guarded by profile_validate_file rather than by
# load_active_profile's die(), because a re-activation must keep working after
# its profile was renamed or removed (REV-20260809-090 F1).
profile_reload_if_stale() {   # no output; repairs a loaded-but-unrendered profile
    [ -n "${PROFILE_LOADED:-}" ] || return 0
    [ -s "${PROFILE_PRUNE_FILE:-}" ] && return 0
    [ -s "${PROFILE_DS_FILE:-}" ]    && return 0
    profile_validate_file "$(profile_file "$PROFILE_ACTIVE")" "$GENCRON" >/dev/null 2>&1 || return 0
    PROFILE_LOADED=""
    load_active_profile
}

# rc 0 = resolved (path on stdout); rc 2 = no profile is loaded, so there is
# nothing to CREATE from and nothing to say about the policy; rc 1 = a profile
# IS loaded and expresses no retention at all. The reviewer asked for exactly
# this split: "cannot see the artifacts" and "the policy is empty" must not be
# the same answer, because only one of them is a reason to carry on.
profile_retention_fragment() {   # -> retention fragment path; rc 1 empty, rc 2 unloaded
    # -s ONLY. The first cut probed the file's CONTENT with profile_emit, and
    # CI caught what that costs: the suite drives loads inside subshells, a
    # released temp leaves a STALE PATH behind in the parent, and reading it
    # printed "No such file or directory" from profile_emit's redirection. A
    # resolver must be answerable from what it can see, not from a file it hopes
    # is still there.
    [ -n "${PROFILE_LOADED:-}" ] || return 2
    [ -s "${PROFILE_PRUNE_FILE:-}" ] && { printf '%s' "$PROFILE_PRUNE_FILE"; return 0; }
    [ -s "${PROFILE_DS_FILE:-}" ]    && { printf '%s' "$PROFILE_DS_FILE";    return 0; }
    return 1
}

emit_source_prune_fragment() {   # <rendered prune fragment>
    profile_emit "$1" | while IFS= read -r line; do
        case "$line" in
            *use_template*=*)
                local pre val id out oldIFS
                pre="${line%%use_template*}"
                val="${line#*=}"; val="${val//[[:space:]]/}"
                out=""; oldIFS="$IFS"; IFS=,
                for id in $val; do
                    [ -n "$id" ] || continue
                    out="$out,$(profile_to_src_id "$id")"
                done
                IFS="$oldIFS"
                printf '%suse_template = %s\n' "$pre" "${out#,}"
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done
}

# Append the SOURCE template family to a config file, idempotently -- each source
# template only if the file does not already carry it. Same additive discipline
# ensure_cron_config uses for the target family, so a re-activation that preserves
# an installed source prune never rewrites its templates. Fails closed on a
# referenced template missing from the rendered set (never a silent shared
# authority).
append_source_templates_if_missing() {   # <workfile> <rendered prune fragment>
    local wf="$1" id src sec
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        src="$(profile_to_src_id "$id")"
        grep -q "^\[template:$src\]" "$wf" 2>/dev/null && continue
        sec="$(profile_template_section "$id")"
        [ -n "$sec" ] || die "remote source-retention: profile '$PROFILE_ACTIVE' references prune template '$id' but no rendered [template:$id] exists -- refusing to emit a SOURCE prune that would silently reuse the TARGET's template authority (REV-20260811-106)"
        # Drop monitor_warn/monitor_crit: this template drives a REMOTE prune scope,
        # and check-snap-age.sh is local-only -- gen-cron.sh rejects monitor fields
        # on a remote scope outright. Source-age monitoring is the source host's own
        # concern, not the collector's; the collector monitors the TARGET.
        # send_schedule/prefix go too, and for the same class of reason as the
        # monitor fields: this template drives a REMOTE PRUNE scope. A ladder
        # profile's prune tiers never carry them, so this is a no-op there --
        # but a FLAT profile's tiers are self-contained (they create AND prune),
        # and copying their creation half into a source-prune template would
        # declare that the collector stamps snapshots on somebody else's host
        # from a retention section.
        { printf '\n[template:%s]\n' "$src"
          printf '%s\n' "$sec" | tail -n +2 \
            | sed -E '/^[[:space:]]*(monitor_(warn|crit)|send_schedule|prefix)[[:space:]]*=/d'
        } >> "$wf" || die "could not append [template:$src] to $wf"
    done < <(profile_prune_ref_ids "$2")
}

# Remove every REMOTE source [prune:<account@host:ds>] this client wrote, whatever
# endpoint it named, identified by header shape (a prune scope with an '@' -- only
# a user@host remote scope has one; a dataset name never does) AND this client's
# own marker as the section's first content line (header text alone is not proof of
# authorship -- REV-20260802-033 U11). Used to fully regenerate the source prune on
# each activation so an endpoint switch moves it. A hand-written or foreign remote
# prune (no matching marker) is left untouched.
remove_client_remote_source_prunes() {   # <file> <name>
    # Split deliberately. `local a="$1" b="$2" c="...$b"` does NOT build c from
    # the b being assigned here: bash expands every word of the command before
    # performing any of its assignments, so `$b` is the CALLER's b. This function
    # therefore built its ownership marker from whatever `name` happened to exist
    # in the enclosing scope, and only worked because its one caller had a `name`
    # holding the same value. A caller whose `name` differed would have removed
    # sections belonging to a different client, or none -- and under `set -u` with
    # no enclosing `name` at all it dies outright, which is how this surfaced: a
    # unit test called it directly for the first time.
    local file="$1" name="$2"
    local marker="# managed-by: zfs-backup.sh client=$name"
    local tmp; tmp=$(mktemp) || die "mktemp failed"
    awk -v marker="$marker" '
        function flush(   i) {
            if (n > 0 && !(is_remote_prune && has_marker))
                for (i = 1; i <= n; i++) print buf[i]
            n = 0; is_remote_prune = 0; has_marker = 0; seen_content = 0
        }
        /^\[/ {
            flush()
            buf[++n] = $0
            is_remote_prune = ($0 ~ /^\[prune:[^]]*@[^]]*:[^]]*\]$/)
            next
        }
        {
            buf[++n] = $0
            if (!seen_content && $0 ~ /[^[:space:]]/) {
                seen_content = 1
                t = $0; sub(/^[[:space:]]+/, "", t)
                if (t == marker) has_marker = 1
            }
        }
        END { flush() }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; die "could not rewrite $file removing source prunes"; }
}

# Capture, per source dataset, the POLICY body of each INSTALLED remote source
# [prune:<account@host:ds>] this client owns (marker-verified) into
# SOURCE_PRUNE_PRESERVED[ds], BEFORE it is removed. The body is every line after
# the header (marker, use_template, gfs, gfs_pattern, recursive, ssh_flags, labels)
# -- i.e. the admin's installed policy. A re-activation replays it under the new
# scope, changing only topology (REV-20260811-107: reactivation must not regenerate
# installed source policy from the profile). Runs in the CURRENT shell so the
# associative array is populated (no pipe/subshell).
capture_client_remote_source_prunes() {   # <file> <name> ; fills SOURCE_PRUNE_PRESERVED
    SOURCE_PRUNE_PRESERVED=()
    # Same split, same reason as remove_client_remote_source_prunes above: a
    # marker built inside one `local` command reads the CALLER's `name`, not the
    # parameter being assigned beside it. This one is the capture half of the same
    # pair, so a wrong marker here would preserve another client's policy across a
    # re-activation instead of its own.
    local file="$1" name="$2"
    local marker="# managed-by: zfs-backup.sh client=$name"
    local line t cur_ds="" cur_body="" in_sec=0 is_remote=0 seen_content=0 has_marker=0
    _flush_cap() {
        [ "$in_sec" -eq 1 ] && [ "$is_remote" -eq 1 ] && [ "$has_marker" -eq 1 ] && [ -n "$cur_ds" ] \
            && SOURCE_PRUNE_PRESERVED["$cur_ds"]="${cur_body%$'\n'}"
    }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                _flush_cap
                cur_body=""; seen_content=0; has_marker=0; is_remote=0; cur_ds=""; in_sec=1
                case "$line" in
                    \[prune:*@*:*\])
                        is_remote=1
                        cur_ds="${line%\]}"; cur_ds="${cur_ds##*:}"   # source dataset = part after the last ':'
                        ;;
                esac
                ;;
            *)
                if [ "$in_sec" -eq 1 ]; then
                    cur_body+="$line"$'\n'
                    if [ "$seen_content" -eq 0 ] && [ -n "${line//[[:space:]]/}" ]; then
                        seen_content=1
                        t="${line#"${line%%[![:space:]]*}"}"
                        [ "$t" = "$marker" ] && has_marker=1
                    fi
                fi
                ;;
        esac
    done < "$file"
    _flush_cap
    unset -f _flush_cap
}

# The SSH connection flags for a remote source [prune:] scope: the pull's own
# transport flags minus -b (bandwidth is a transfer cap, not an SSH option, and
# gen-cron's ssh_flags accepts only -p/-k/-c/-K/-O). Pure function of the loaded
# endpoint (LOAD_*), so the CREATE emitter and the step-5 retrofit compute it the
# same way and cannot drift.
source_prune_sflags() {
    local s="-K ${LOAD_KEYFILE:-} -k ${LOAD_ALIAS_KH:-} -O HostKeyAlias=${LOAD_ALIAS:-} -O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no"
    [ "${LOAD_PORT:-22}" != "22" ] && s="$s -p $LOAD_PORT"
    printf '%s' "$s"
}

# Append ONE freshly generated remote source [prune:<scope>] section (the CREATE
# body: marker, the profile's SOURCE prune fragment, non-recursive scope, ssh_flags,
# labels). Shared by the step-3 CREATE path and the step-5 retrofit so both write an
# identical, independent, non-recursive source ladder.
append_source_prune_create() {   # <workfile> <name> <marker> <scope> <sflags> <ds> <retention fragment> [prune schedule expr]
    local wf="$1" name="$2" marker="$3" scope="$4" sflags="$5" ds="$6" retfrag="${7:-$PROFILE_PRUNE_FILE}"
    # EMPTY MEANS "inherit the template", which is what every section written
    # before this did. Passed in rather than derived here: schedule_pick_minute
    # reads the INSTALLED crontab, so calling it a second time inside one run
    # can answer differently once the send line is in place.
    local schedexpr="${8:-}"
    # Recursion here MIRRORS the pull's. A solid scope root pulls with -R, so
    # its children accumulate the tool-owned automated_ snapshots on the
    # source too -- a non-recursive source prune would cover the parent and
    # let every child's source pool fill without bound, which is REV-102's
    # exact defect reborn one level down. delsnaps' -R walks the remote
    # subtree at each run, same as the pull, so the two stay in step as
    # children come and go.
    local rec=no
    is_recursive_root "$ds" && rec=yes
    {
        echo
        echo "[prune:$scope]"
        echo "	$marker"
        emit_source_prune_fragment "$retfrag"
        [ -n "$schedexpr" ] && echo "	prune_schedule = $schedexpr"
        echo "	recursive    = $rec"
        echo "	ssh_flags    = $sflags"
        echo "	pair_label   = $name"
        echo "	notify       = ${name}-src-$(basename "$ds")"
    } >> "$wf"
}

# REV-20260811-102 step 3: the REMOTE source of a pull relationship accumulates the
# tool-owned automated_ snapshots the pull creates; standard_hourly does not
# self-prune, so without this the source pool fills (the exact REV-102 defect).
# Emit a per-source-dataset [prune:<account@host:ds>] that runs delsnaps over the
# SAME pinned SSH the pull uses, with the INDEPENDENT source retention family
# (REV-106) and NON-recursive scope (matches the per-dataset pull coverage, never
# walks into children this relationship does not manage). FAILS CLOSED first: the
# delegated account must already hold `destroy` on each source (delegated by
# deploy.sh --commit-scope) -- we verify, we do NOT widen. Only the (re)generated
# datasets, so a preserved re-activation opens no SSH and rewrites nothing.
emit_remote_source_prune() {   # <workfile> <name> <marker> [--schedule=EXPR] <source-ds...>
    local workfile="$1" name="$2" marker="$3"; shift 3
    # NAMED, not a fourth positional, and that is a correction rather than a
    # taste: the tail of this function is a variadic dataset list, so a new
    # positional in front of it silently eats the first DATASET. Measured --
    # the first cut did exactly that, the list came out empty, and the section
    # was not emitted at all. A dataset name can never look like --schedule=.
    local schedexpr=""
    case "${1:-}" in --schedule=*) schedexpr="${1#--schedule=}"; shift ;; esac
    [ "$#" -gt 0 ] || return 0
    # NO SHAPE GATE. `PROFILE_GFS -eq 1` used to stand here and it silently
    # excused every flat profile from bounding the families it creates on the
    # source -- see profile_retention_fragment for the measurement. What decides
    # is whether this profile HAS retention to express, and both shapes do.
    #
    # An EMPTY fragment is not an error here: a preserving re-activation loads no
    # profile at all (REV-20260809-090 F1) and must still reach the capture and
    # replay below, which is what MOVES an installed source prune to a new
    # endpoint (REV-20260811-107). Only the CREATE branch needs the fragment, and
    # it fails closed there.
    # THE SHAPE GATE HAD TWO JOBS AND I REMOVED BOTH. Skipping flat profiles was
    # wrong (F1). Not bolting source retention onto a FROZEN pre-GFS config was
    # right, and REV-20260809-091 F2 pins it: an endpoint-only reactivation of a
    # legacy host refreshes topology and leaves its policy alone. `PROFILE_GFS`
    # answered that by accident, because a legacy config reads as flat. The
    # question is about the NAME, and config_is_frozen_legacy already asks it.
    if config_is_frozen_legacy "$workfile"; then
        log "source retention NOT generated for '$name': $workfile carries the frozen pre-GFS family, whose policy this run must not extend. Migrate the host deliberately (zfs-backup.sh migrate-profile) if its source should be bounded."
        return 0
    fi
    local retfrag=""
    profile_reload_if_stale
    retfrag="$(profile_retention_fragment)" || retfrag=""
    # Pure config text -- no SSH here. The fail-closed grant check
    # (assert_source_prune_grant) runs in the FLOW, before the workfile is
    # published, so the two callers gate the INSTALL and this stays unit-testable
    # without a live host.
    [ -n "$retfrag" ] && append_source_templates_if_missing "$workfile" "$retfrag"
    # The source scope embeds the endpoint (account@host) in its SECTION HEADER, so
    # the scope is topology-derived like the [dataset:] `src` field and cannot be
    # refreshed in place -- the section must be rebuilt to move it. But the POLICY
    # inside it is CONFIG-v4 runtime truth after CREATE (REV-20260811-107): a
    # re-activation must MOVE only topology (scope header + ssh_flags) and PRESERVE
    # the installed policy body (use_template, gfs, retain), same topology-vs-policy
    # split REV-089 draws for [dataset:]. So: capture each installed body first,
    # remove the old sections, then per dataset replay the PRESERVED body under the
    # new scope (updating only ssh_flags); only a dataset with NO installed source
    # prune -- a genuine first CREATE -- is generated from the profile.
    capture_client_remote_source_prunes "$workfile" "$name"
    remove_client_remote_source_prunes "$workfile" "$name"
    local sflags; sflags="$(source_prune_sflags)"
    local ds scope
    for ds in "$@"; do
        scope="${LOAD_ACCOUNT:-root}@${LOAD_HOST:-}:${ds}"
        if [ -n "${SOURCE_PRUNE_PRESERVED[$ds]:-}" ]; then
            # RE-ACTIVATION: replay the installed policy body under the new scope,
            # rewriting only the topology-owned ssh_flags line. use_template, gfs,
            # gfs_pattern, retain (via the preserved templates) and labels survive an
            # admin edit exactly as installed.
            {
                echo
                echo "[prune:$scope]"
                printf '%s\n' "${SOURCE_PRUNE_PRESERVED[$ds]}" \
                    | sed -E "s|^([[:space:]]*ssh_flags[[:space:]]*=).*|\1 $sflags|"
            } >> "$workfile" || return 1
        else
            # FIRST CREATE: no installed source prune for this dataset -- generate
            # the policy from the profile.
            # FAIL CLOSED, and the reviewer was right that the previous version
            # did not. I replaced a die() with a log-and-continue and called
            # gen-cron the backstop -- but this branch writes NO section at all,
            # and gen-cron cannot reject a section that was never written. The
            # relationship would have been created, stamped four families on the
            # source, and bounded none of them. The argument was wrong, not the
            # code around it.
            #
            # Nothing is lost by refusing here. A CREATE always loads the profile
            # (PLAN_NEEDS_PROFILE is 1 whenever anything is generated), so an
            # unresolvable fragment on this path means either the profile really
            # expresses no retention or its artifacts vanished mid-run. Both are
            # reasons to stop before publishing, and neither is a reason to
            # publish a relationship that prunes nothing on the source.
            [ -n "$retfrag" ] || die "refusing to create source retention for '$ds': profile '$PROFILE_ACTIVE' yielded no retention fragment. Either it declares none at all, or its rendered artifacts are not readable in this run. This relationship would create automated_* families on ${LOAD_HOST:-the source} and bound none of them there -- which is the defect REV-20260811-102 exists to prevent. Nothing was installed."
            append_source_prune_create "$workfile" "$name" "$marker" "$scope" "$sflags" "$ds" "$retfrag" "$schedexpr" || return 1
        fi
        SOURCE_PRUNE_EMITTED_DS+=("$ds")
    done
}

# REV-20260811-102 step 5 / F4: the NARROW retrofit emitter. Unlike
# emit_remote_source_prune (which capture/remove/re-emits EVERY source prune to move
# its endpoint) and unlike emit_client_sections is_new=0 (which also refreshes the
# [dataset:] src/flags topology), this APPENDS ONLY a fresh source [prune:] for the
# named SCOPES and touches nothing else -- no [dataset:], no target prune, no
# existing bounded source prune. That is exactly the migration boundary the finding
# requires: "add only missing source retention, leave all other policy/topology
# byte-identical". Each scope is the INSTALLED [dataset:] src verbatim (CONFIG is
# truth), so the added prune targets exactly the endpoint the relationship pulls
# from. Records SOURCE_PRUNE_EMITTED_DS for the caller's grant gate.
emit_missing_source_prune() {   # <workfile> <name> <missing-source-scope...>
    local workfile="$1" name="$2"; shift 2
    [ "$#" -gt 0 ] || return 0
    # Same as emit_remote_source_prune: retention, not shape. This verb only ever
    # CREATES (it is the retrofit for relationships installed before source
    # retention existed), so an absent fragment is fatal rather than tolerated.
    config_is_frozen_legacy "$workfile" && return 0
    # This verb ONLY creates -- it is the retrofit for relationships installed
    # before source retention existed -- so returning success without writing a
    # section is the exact fail-open the finding names. It reported "nothing to
    # add" when what it meant was "I could not tell what to add".
    local retfrag rc
    profile_reload_if_stale
    retfrag="$(profile_retention_fragment)"; rc=$?
    [ "$rc" -eq 0 ] || die "audit-source-retention --apply: profile '$PROFILE_ACTIVE' yielded no retention fragment ($([ "$rc" -eq 2 ] && printf 'no profile is loaded in this run' || printf 'the profile expresses no retention at all')). Refusing to report success while adding nothing -- the relationships this verb exists to bound would stay unbounded. Nothing was installed."
    local marker="# managed-by: zfs-backup.sh client=$name"
    append_source_templates_if_missing "$workfile" "$retfrag"
    local sflags; sflags="$(source_prune_sflags)"
    local scope ds
    for scope in "$@"; do
        ds="${scope##*:}"
        # NO SCHEDULE, deliberately. This is the RETROFIT: it adds the bounded
        # source prune an existing relationship was missing, and nothing else.
        # A minute here would move a job on a host that never asked for it --
        # the same thing the empty-expression control in test/stagger exists to
        # forbid. The stagger belongs to CREATE, where the minute is chosen.
        #
        # Passed as an explicit empty string rather than left out: `schedexpr`
        # is a local of emit_remote_source_prune, a DIFFERENT function, and
        # bash would have handed this one whatever that caller happened to
        # have in scope. CI caught it as 57b, the byte-identical assertion.
        append_source_prune_create "$workfile" "$name" "$marker" "$scope" "$sflags" "$ds" "$retfrag" "" || return 1
        SOURCE_PRUNE_EMITTED_DS+=("$ds")
    done
}

# The high-level default's managed SOURCE snapshot family. The pull relationship
# creates these on the source (snapget -m <prefix>), and a bounded source prune must
# cover exactly this family. Used as the fallback when the relationship's own transfer
# line cannot be found in the render.
MANAGED_SOURCE_PREFIX_DEFAULT="automated_hourly_"

# The snapshot prefix a pull relationship actually CREATES on its source = the -m
# argument of its snapget/snapsend transfer line for the scope, read back from the
# rendered crontab. This is the family a bounded source prune has to cover. Falls back
# to the high-level default managed prefix if no transfer line names the scope.
#
# REV-20260811-110: the scope must match as an EXACT quoted argument ("<scope>"), the
# same identity level source_scope_is_bounded uses -- a substring test would let a
# neighbouring scope whose text CONTAINS this one (rpool/data vs rpool/data2, or a
# parent/child pair) hand this relationship the WRONG relationship's -m prefix.
managed_source_prefix_for_scope() {   # <rendered-crontab-file> <scope>
    local line pfx
    while IFS= read -r line; do
        case "$line" in *snapget*|*snapsend*) ;; *) continue ;; esac
        case "$line" in *"\"$2\""*) ;; *) continue ;; esac
        case "$line" in
            *" -m \""*) pfx="${line#*-m \"}"; pfx="${pfx%%\"*}" ;;
            *" -m "*)   pfx="${line#*-m }";   pfx="${pfx%% *}" ;;
            *) continue ;;
        esac
        [ -n "$pfx" ] && { printf '%s' "$pfx"; return 0; }
    done < "$1"
    printf '%s' "$MANAGED_SOURCE_PREFIX_DEFAULT"
}

# REV-20260811-102 step 5 / F3: decide whether a source scope has EFFECTIVE bounded
# retention -- not merely a [prune:] header, and not merely SOME delsnaps naming the
# scope, but a delsnaps job that actually bounds THIS relationship's managed source
# snapshot family. Reuses gen-cron's rendered command (no second CONFIG parser) and
# discriminates the prune semantics the finding requires (REV-102 F3 residual):
#   * it must be a SNAPSHOT prune, not a bookmark cleanup (`delsnaps -B` deletes
#     bookmarks, never `automated_hourly_*` snapshots);
#   * its pattern argument must COVER the managed source prefix -- every managed
#     snapshot (prefix + suffix) starts with the pattern, i.e. the managed prefix
#     begins with the pattern (a prune of an unrelated prefix does not bound us);
#   * it must carry a finite count/GFS retention flag.
# $1 is the rendered-crontab file, $2 the scope.
source_scope_is_bounded() {   # <rendered-crontab-file> <scope>
    local managed line rest pat
    managed="$(managed_source_prefix_for_scope "$1" "$2")"
    while IFS= read -r line; do
        case "$line" in *delsnaps*) ;; *) continue ;; esac
        case "$line" in *"\"$2\""*) ;; *) continue ;; esac
        # a bookmark-cleanup job does not delete snapshots -- never counts as bounding
        case "$line" in *" -B "*) continue ;; esac
        # the prune pattern = the quoted token immediately after the scope
        rest="${line#*\"$2\"}"
        pat="${rest#*\"}"; pat="${pat%%\"*}"
        [ -n "$pat" ] || continue
        # the pattern must cover the managed source family (managed prefix begins with
        # the pattern), else this prune bounds a different prefix, not ours
        case "$managed" in "$pat"*) ;; *) continue ;; esac
        # and it must carry a finite retention flag (GFS -H24 / count -c 24 / -d 30)
        case "$line" in
            *-H[0-9]*|*-D[0-9]*|*-W[0-9]*|*-M[0-9]*|*-Y[0-9]*) return 0 ;;
            *" -c "[0-9]*|*" -d "[0-9]*) return 0 ;;
        esac
    done < "$1"
    return 1
}

# installed_dataset_field lives in lib-backup-common.sh since the restore split
# (zfs-restore.sh derives copy locations from the same installed CONFIG).

# The `src` value of an installed [dataset:<localpath>] section (account@host:ds). The
# audit keys the SOURCE scope off this.
installed_dataset_src() {   # <cronfile> <local dataset path>
    installed_dataset_field "$1" "$2" src
}

# REV-20260811-108: is this installed pull relationship a PASSIVE external-snapshot
# source? A passive relationship transfers with `snapget -e`: it consumes an
# already-existing, externally-owned snapshot and this package does NOT own the source
# snapshot lifecycle, so it legitimately carries no source `[prune:]`. The audit must
# read this off the installed transfer `flags` (runtime truth) and never propose taking
# destructive source-retention ownership of it -- no new state token, just the flag
# that is already there.
#
# TWO SPELLINGS since 2026-08-31, and both have to be read. `-e` inside 'flags'
# is what every installed section carries and what this tool still writes; the
# named `passive` field is what CONFIG v4 gained when the scope options were
# split out of the flags sack, and a hand-written config may already use it.
# Reading only one of them would answer "not passive" for a job that is, and the
# caller uses that answer to decide whether to propose taking DESTRUCTIVE
# source-retention ownership of somebody else's snapshots.
installed_dataset_is_passive() {   # <cronfile> <local dataset path>
    local flags passive
    passive="$(installed_dataset_field "$1" "$2" passive)"
    [ "$passive" = yes ] && return 0
    [ "$passive" = no ]  && return 1
    flags="$(installed_dataset_field "$1" "$2" flags)"
    case " $flags " in *" -e "*) return 0 ;; *) return 1 ;; esac
}

# The same extraction, generalized to any CONFIG v4 file and any section
# header -- used to read back what is ALREADY on disk so it can be compared
# against what a template would render now, rather than only checking that
# a name is present (Phase 2 property 6, ACTIVE-WORK-PLAN.md).
cron_config_section() {   # <file> <exact header, e.g. '[template:foo]'>
    local file="$1" want="$2"
    awk -v want="$want" '
        $0 == want { emit=1; print; next }
        emit && /^\[/ { exit }
        emit { print }
    ' "$file" 2>/dev/null
}

# A config written before the profile split has prune_schedule INSIDE
# standard_*, so its [dataset:] sections prune themselves flat, per tier. This
# is read off the INSTALLED file, never from the profile -- which is why it can
# be answered before deciding whether the profile is needed at all
# (REV-20260810-090).
# Read by SHAPE, not by name. This used to look for the literal
# `[template:standard_hourly]` and ask whether that one section carried a
# prune_schedule -- which worked only for configs written by the built-in
# `default`, and answered "ladder" for every config whose tiers are named
# anything else. A profile transcribed from production (`hourly`, `daily`,
# `weekly`, `monthly`) is exactly that case: flat per-tier pruning that the
# name check reads as a ladder.
#
# The question is really about shape: does a template CREATE a family and PRUNE
# it in the same breath? A ladder keeps those apart -- one create-only template
# and several prune-only ones over its family. A flat per-tier config fuses
# them. So one template carrying both send_schedule and prune_schedule settles
# it, whatever anyone called it.
# TWO DIFFERENT QUESTIONS, one grep used to answer both -- and that conflation
# made `prod` a one-relationship-per-host profile. Measured 2026-08-25: a config
# generated from `prod` accepts its FIRST client (4 templates written) and the
# SECOND is refused with "uses the pre-GFS profile (standard_* still carries
# prune_schedule)" -- naming a family the file does not contain.
#
#   detect_profile_gfs   "does the policy in force prune from a separate
#                        ladder, or from the send tiers themselves?" That is a
#                        SHAPE question, it drives whether a [prune:] ladder is
#                        emitted, and a flat answer for `prod` is correct.
#
#   config_is_frozen_legacy  "is this the FROZEN pre-GFS family?" That is a
#                        NAME question. The frozen family is bare
#                        standard_hourly/daily/weekly/monthly -- written before
#                        profiles were namespaced. A modern flat profile is
#                        profile__<name>__<tier>: it prunes from its tiers too,
#                        but it is current policy, not frozen policy, and
#                        adding a second relationship to it is ordinary work.
#
# The refusal that reads this exists to stop the standard ladder being stacked
# on TOP of a legacy family that already self-prunes. A namespaced flat profile
# poses no such hazard: there is no second ladder to add, because emit's ladder
# branch is gated on the same shape answer.
config_is_frozen_legacy() {   # <file> -> 0 when the frozen pre-GFS family is present
    awk '
        /^\[template:standard_(hourly|daily|weekly|monthly)\]/ { intpl=1; next }
        /^\[/ { intpl=0 }
        intpl && /^[ \t]*prune_schedule[ \t]*=/ { print "frozen"; exit }
    ' "$1" 2>/dev/null | grep -q frozen
}

detect_profile_gfs() {   # <file> -> sets PROFILE_GFS
    PROFILE_GFS=1
    [ -r "$1" ] || return 0
    awk '
        /^\[template:/ { has_send=0; has_prune=0; intpl=1; next }
        /^\[/          { intpl=0 }
        intpl && /^[ 	]*send_schedule[ 	]*=/  { has_send=1 }
        intpl && /^[ 	]*prune_schedule[ 	]*=/ { has_prune=1 }
        intpl && has_send && has_prune { print "flat"; exit }
    ' "$1" 2>/dev/null | grep -q flat && PROFILE_GFS=0
    return 0
}

# Does this CONFIG already carry relationship policy anyone could be affected by?
#
# REV-20260810-092. [excluded:] is CONFIG-WIDE: gen-cron.sh resolves every one of
# them into a single PROTECT_FLAGS fragment and pastes it onto EVERY generated
# prune line in the file. So "add a missing floor" is not additive scaffolding
# once anything else is installed -- it silently rewrites the effective prune
# command of relationships that were there first, which is precisely what Gate 2
# forbids. A file with no [dataset:]/[prune:] section at all has no such
# relationship to disturb, and that is the only state in which the standard
# CONFIG-wide defaults may be laid down as a side effect.
config_has_relationship_policy() {   # <file> -> 0 when something is already installed
    grep -qE '^\[(dataset|prune):' "$1" 2>/dev/null
}

# The pve2 fail-closed guard (found live 2026-08-01), extracted so both
# ensure_cron_config and local-backup planning apply the SAME check rather than a
# second, weaker one: never treat a MISSING config as a blank file to (re)create
# when an installed crontab block still says it was generated from that path --
# creating it would let the next --install replace live jobs with nothing.
assert_config_not_claimed_if_missing() {   # <file> ; dies if a live block claims a missing file
    [ -e "$1" ] && return 0
    local claimed
    claimed=$(crontab_for_target 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
    [ -n "$claimed" ] || return 0
    [ "$(normalize_cron_source "$claimed")" = "$(normalize_cron_source "$1")" ] || return 0
    local jobs; jobs=$(crontab_for_target 2>/dev/null | grep -cE '^[0-9*]')
    die "refusing to create $1: the installed crontab block says it was generated FROM that file, and it is missing. Creating it would produce a config describing no jobs at all, and the next --install would replace $jobs live cron line(s) with nothing. Find or rebuild the real config first (the installed block is still the record of what should be in it: crontab -l), then re-run. Nothing has been changed."
}

# The one place that knows what a BRAND NEW cron config must contain before
# gen-cron.sh will look at it. There is exactly one required fact -- host_label,
# which every notification text is built from -- and it is defaultable from the
# host itself, so nothing about a fresh collector should ever require an operator
# to hand-write a config stanza.
#
# It is a function rather than two copies because it had two callers and only one
# of them did it. cmd_activate_client builds a WORKING COPY of the config, and
# when the collector has no config yet it created that copy EMPTY -- so
# ensure_cron_config, which seeds the defaults only when the file does not exist,
# saw a file that mktemp had already created and skipped the seeding. The result
# was a config carrying datasets and no [defaults], gen-cron refusing it, and the
# ordinary four-command enrolment stopping dead on a fresh two-server setup with
# "[defaults] must set host_label" -- a config repair the operator was told to do
# by hand. Measured live on pve1 -> pve2, 2026-08-14.
write_fresh_config_defaults() {   # <file>
    {
        echo "[defaults]"
        echo "	host_label = $(hostname -s)"
    } > "$1"
}

ensure_cron_config() {   # <file> [check_new_template_collision=0] [needs_profile=1] [global_policy_mode=auto]
    local file="$1"
    # REV-20260809-088 F1: the collision check below must fire ONLY at the
    # moment a genuinely NEW relationship is being created and is about to
    # rely on a template identity for the first time -- never on an ordinary
    # re-activation of an ALREADY-active relationship. This function itself
    # is called on every activate-client run, first activation and every
    # later endpoint-switch re-activation alike, and Phase 3's already-agreed
    # boundary is that reactivation preserves installed policy rather than
    # re-validating it against whatever the profile currently says. Callers
    # that are not creating a new relationship must pass nothing (or 0) here.
    local check_new_template_collision="${2:-0}"
    # REV-20260810-090 F1/F2. The profile is a CREATE-time input, so needing it
    # is a property of the operation, not of this function. An ordinary
    # reactivation that generates nothing passes 0 and never loads a profile:
    # under the one-way handoff an installed CONFIG must keep working after the
    # profile it was created from is renamed, removed or edited into something
    # that no longer validates. Callers that genuinely create policy
    # (setup-server, migrate-profile, a first activation, an activation that
    # must generate a section) pass 1, which is also the default -- a caller
    # that has not thought about it gets the old, safe behaviour.
    local needs_profile="${3:-1}"
    # REV-20260810-092. 'auto' lays down the CONFIG-wide safety defaults only
    # while the file carries no relationship policy at all -- initializing a new
    # CONFIG, where there is nothing installed for them to change. 'always' is
    # the explicit-migration escape hatch: migrate-profile is a previewed,
    # confirmed transaction that shows the operator the exact config and cron
    # diff before anything is installed, and it is also the one command that
    # INSTALLS the broad GFS ladder these floors exist to fence, so it must not
    # leave a legacy host with that ladder and no protection.
    local global_policy_mode="${4:-auto}"
    if [ ! -e "$file" ]; then
        # Found live on pve2, 2026-08-01. That host's crontab held 14 production
        # jobs whose '# Source:' named a config under a directory that had since
        # been deleted. setup-server read the Source line, adopted that path as
        # the cron config, and then CREATED it -- 38 lines of templates and not
        # one job section.
        #
        # That turns a SAFE state into an armed one. A missing config is safe:
        # gen-cron.sh -c refuses to run at all. A config that exists and
        # describes no jobs is a loaded gun, because --install replaces the whole
        # managed block with whatever it generates -- here, nothing -- and
        # assert_cron_config_matches_installed waves it through, since the Source
        # line does name this exact file. That guard compares identity; it has no
        # opinion about content.
        #
        # So: never create the file the installed block claims to come from.
        # Whoever meets this has a real config to find or rebuild, and telling
        # them that is the only useful thing to do. (Shared guard, also used by
        # local-backup planning.)
        assert_config_not_claimed_if_missing "$file"
        mkdir -p "$(dirname "$file")" || die "could not create $(dirname "$file")"
        write_fresh_config_defaults "$file" || die "could not create $file"
        log "created new cron config $file"
    fi
    # Adding a GFS [prune:] section on top of a pre-GFS config would prune the
    # same snapshots twice on the same schedule -- the race gen-cron.sh's own
    # docs warn about. Templates already present are never rewritten (that is
    # what makes this function safe to re-run), so such a host keeps flat
    # retention until someone migrates it deliberately.
    detect_profile_gfs "$file"

    # Slice B1 / owner option 3: the pre-GFS shape is FROZEN, not reinterpreted.
    #
    # Before B1 this branch emitted a second, flat-retention template family.
    # That family is no longer expressible -- profiles/ carries the GFS shape --
    # and the one thing this must never do is quietly hand a pre-GFS host the
    # GFS ladder instead: its standard_* still prunes on its own schedule, so
    # the two would prune the same snapshots on the same schedule, which is the
    # race gen-cron.sh's own documentation warns about.
    #
    # So it refuses, and names the way out. migrate-profile is transactional --
    # working copy, preview, confirmation, read-back -- and reaches this code
    # only after removing the legacy family, at which point the detection above
    # sees a GFS host and this refusal does not fire.
    #
    # REV-20260810-091 F2: gated on needs_profile, because the hazard it guards
    # is ADDING current-profile policy on top of legacy policy. When nothing is
    # being generated there is no second ladder to create, no double prune, and
    # therefore nothing to refuse -- a pre-GFS host's own flat retention keeps
    # working exactly as it did. Refusing anyway would make an endpoint change
    # depend on a policy migration, which is precisely what Phase 3 forbids.
    # Note detect_profile_gfs itself still runs unconditionally: PROFILE_GFS is
    # read downstream (the prune shape, the activation summary), and only the
    # REFUSAL is conditional.
    # NAME, not shape -- see config_is_frozen_legacy. Testing PROFILE_GFS here
    # refused every second relationship on a host running any flat profile,
    # because "the tiers prune themselves" is true of the frozen family AND of
    # `prod`. The hazard is stacking the standard ladder on a family that
    # already self-prunes, and that family is the bare standard_* one.
    if [ "$needs_profile" -eq 1 ] && config_is_frozen_legacy "$file"; then
        die "$file uses the pre-GFS profile (standard_* still carries prune_schedule), which is frozen. Adding the standard policy on top would prune the same snapshots twice on the same schedule. Migrate the host first, in one previewed transaction: zfs-backup.sh migrate-profile"
    fi

    # REV-20260810-090 F2: the whole template block below is additive -- it
    # appends any profile template the config does not already carry. That is
    # right when policy is genuinely being created, and wrong on an endpoint
    # refresh: an operator who deliberately removed a generated template they
    # no longer need must not have it silently restored as a side effect of
    # maintenance. The collision flag only decided whether a PRESENT name was
    # compared; it never decided whether an ABSENT one was written.
    if [ "$needs_profile" -eq 1 ]; then
    load_active_profile

    # Name by name, exactly as before (REV-20260809-079 F2): what suppresses an
    # append is THAT name already being present, never the config having some
    # other templates of its own. A host with hand-written sections still
    # receives the profile's, under the profile's own namespaced names -- it is
    # never given somebody else's template because a bare name happened to match.
    #
    # Phase 2 property 6 (ACTIVE-WORK-PLAN.md), corrected per REV-20260809-088:
    # presence-by-name alone answers "is something here", not "does a NEW
    # relationship that needs this identity conflict with what is already
    # here". This is a CREATE-time collision check, not a standing drift
    # gate -- it runs ONLY when the caller says a new relationship is being
    # created (check_new_template_collision=1), never on an ordinary
    # re-activation, so an already-installed CONFIG stays independent of
    # later profile edits exactly as the one-way handoff requires.
    #
    # The comparison is SEMANTIC (Gate 2's own wording), not raw text: two
    # renderings that differ only in accepted-but-cosmetic formatting (blank
    # lines, comment lines, leading whitespace, field order) are the same
    # template. `profile_emit` is the existing normalizer that already
    # strips comments/blanks and trims indentation for this exact field
    # grammar; sorting afterward makes the comparison field-order
    # independent, since CONFIG v4 fields are looked up by name, not
    # position.
    local t added=""
    for t in $PROFILE_TEMPLATE_NAMES; do
        if grep -q "^\[template:$t\]" "$file" 2>/dev/null; then
            if [ "$check_new_template_collision" -eq 1 ]; then
                local existing wanted existing_norm wanted_norm
                existing="$(cron_config_section "$file" "[template:$t]")"
                wanted="$(profile_template_section "$t")"
                existing_norm="$(profile_emit <(printf '%s\n' "$existing") | sort)"
                wanted_norm="$(profile_emit <(printf '%s\n' "$wanted") | sort)"
                if [ "$existing_norm" != "$wanted_norm" ]; then
                    die "[template:$t] already exists in $file with different effective policy than the template this new relationship needs. Refusing to silently reuse a conflicting template or silently overwrite the installed one.
$(diff <(printf '%s\n' "$existing_norm") <(printf '%s\n' "$wanted_norm"))
Resolve by hand: give the new relationship's profile a different template identity, or reconcile the two definitions deliberately, then retry -- not as a side effect of activation."
                fi
            fi
            continue
        fi
        printf '\n%s\n' "$(profile_template_section "$t")" >> "$file" \
            || die "could not append [template:$t] to $file"
        added="$added $t"
    done
    [ -n "$added" ] && log "added missing profile template(s) to $file:$added"
    fi

    # ENROLMENT-AGREED-2026-08-02 U6 / resolved question 2: every reserved
    # prefix this estate's own scripts write ("__replicate_" from pvesr,
    # "vzdump" from Proxmox backup jobs, "__migration__" from zfs send -w
    # migrations) gets a floor of 2 protected NEWEST snapshots, so the
    # collector's own generated prune sweep can never age one out into
    # delsnaps.sh's all-pattern garbage collection.
    #
    # [excluded:] is a CONFIG-WIDE mechanism -- gen-cron.sh pastes its
    # PROTECT_FLAGS fragment onto every emitted prune line in the whole file,
    # not just one client's -- so it is ensured ONCE here, not per-client in
    # emit_client_sections, which would die with "duplicate section" the
    # moment a second client activated. Only ADDS a missing floor: an
    # operator who already set a stronger keep for one of these is never
    # overridden or narrowed.
    #
    # REV-20260810-091 F1: and gated on needs_profile, for the same reason the
    # template loop is. This is CONFIG-WIDE policy scaffolding -- appropriate
    # when policy is being created or migrated, wrong as a side effect of an
    # endpoint refresh. After the handoff, native CONFIG v4 is runtime truth,
    # and endpoint maintenance is not the boundary at which it may be repaired
    # or normalized: an operator who deliberately removed one of these floors
    # must not find it silently restored by a set-endpoint follow-up.
    #
    # REV-20260810-092 F1: and only while the CONFIG carries no relationship
    # policy yet, or the caller is an explicit migration. Adding a floor to a
    # populated CONFIG is not additive -- PROTECT_FLAGS is global, so it rewrites
    # the effective prune command of every relationship already installed, and
    # "add one new independent relationship -> old relationships unchanged" is
    # exactly the Gate 2 invariant that would break. An administrator who
    # deliberately removed or narrowed one of these after CREATE keeps their
    # decision; a new relationship simply inherits the global policy as it
    # stands, the same policy every existing relationship is already running
    # under.
    # WHICH FAMILIES ARE FENCED IS NOW THE PROFILE'S ANSWER.
    #
    # It used to be a literal list here -- "__replicate_", "vzdump",
    # "__migration__", keep=2 -- which made the one policy every deployment on
    # this estate carries the one policy no profile could describe. "What does
    # a default deployment do" was a question you answered by reading this
    # function, not by reading `default`. Owner decision, 2026-08-25: reserved
    # families are profile-editable, so `profiles/<name>/templates.conf` names
    # them and this code renders what it is given.
    #
    # Read from the RENDERED profile, not the source directory: that is the
    # same text every other section comes from, so a profile that fails to
    # render cannot half-apply here.
    local prefix
    local -a floor_prefixes=() floor_keeps=()
    if [ -n "${PROFILE_EXCL_FILE:-}" ] && [ -r "${PROFILE_EXCL_FILE:-}" ]; then
        local _fl_pfx="" _fl_keep=""
        while IFS= read -r _fl_line; do
            case "$_fl_line" in
                '[excluded:'*']')
                    [ -n "$_fl_pfx" ] && { floor_prefixes+=("$_fl_pfx"); floor_keeps+=("$_fl_keep"); }
                    _fl_pfx="${_fl_line#\[excluded:}"; _fl_pfx="${_fl_pfx%\]}"; _fl_keep="" ;;
                '['*) [ -n "$_fl_pfx" ] && { floor_prefixes+=("$_fl_pfx"); floor_keeps+=("$_fl_keep"); }
                      _fl_pfx=""; _fl_keep="" ;;
                *keep*=*) [ -n "$_fl_pfx" ] && _fl_keep="$(printf '%s' "${_fl_line#*=}" | tr -d '[:space:]')" ;;
            esac
        done < "$PROFILE_EXCL_FILE"
        [ -n "$_fl_pfx" ] && { floor_prefixes+=("$_fl_pfx"); floor_keeps+=("$_fl_keep"); }
    fi
    local install_floors=0
    if [ "$needs_profile" -eq 1 ]; then
        case "$global_policy_mode" in
            always) install_floors=1 ;;
            *)      config_has_relationship_policy "$file" || install_floors=1 ;;
        esac
    fi
    if [ "$install_floors" -eq 1 ]; then
        local _i
        # TWO PASSES, AND THE ORDER IS THE POINT: every floor is checked before
        # any is written. The first cut checked and wrote in one loop, so a
        # conflict on the second family refused a run that had already appended
        # the first -- and the refusal said "nothing was changed" while the file
        # said otherwise. A gate that mutates before it refuses is not a gate.
        for _i in "${!floor_prefixes[@]}"; do
            prefix="${floor_prefixes[$_i]}"
            local keep="${floor_keeps[$_i]}"
            [ -n "$keep" ] || die "profile '$PROFILE_ACTIVE' declares [excluded:$prefix] without a keep -- a floor with no count is not a floor, and guessing one here would fence a family by an amount nobody chose"
            if grep -qF "[excluded:$prefix]" "$file" 2>/dev/null; then
                # IDENTICAL DEDUPLICATES, DIFFERENT REFUSES.
                #
                # A floor is CONFIG-WIDE: gen-cron folds every [excluded:] into
                # one PROTECT_FLAGS fragment pasted onto every prune line in the
                # file. So one config cannot fence a family two ways, and two
                # profiles that disagree about `keep` are not a merge problem --
                # they are a question only a human can answer.
                #
                # Skipping silently (what this did) means the FIRST profile to
                # be installed wins forever and the second one's declaration is
                # quietly void: an operator reading profile B sees a number that
                # is not in force anywhere.
                #
                # BUT THE TWO DIRECTIONS ARE NOT THE SAME QUESTION, and the
                # first cut of this treated them as one -- refusing on ANY
                # difference, which broke a property this tree had already
                # decided and pinned: "only ADDS a missing floor, never narrows
                # an operator's stronger keep" (REV-20260810-092). A floor is a
                # MINIMUM number kept, so the two values are not symmetric:
                #
                #   config >= profile   the config already protects the family
                #                       at least as much as the profile asks.
                #                       Keeping the config's number deletes
                #                       nothing anyone relies on, and an
                #                       operator who deliberately raised it
                #                       keeps their decision. Say it once, in
                #                       the log, and carry on.
                #   config <  profile   the config fences LESS than the policy
                #                       this relationship is being created
                #                       under. Proceeding would run it behind a
                #                       weaker guard than its own profile
                #                       declares; raising the floor here would
                #                       rewrite the prune command of every
                #                       relationship already in the file
                #                       (Gate 2). Neither is ours: REFUSE.
                local _have _hr _kr
                _have="$(section_field "$file" "[excluded:$prefix]" keep)"
                _have="$(printf '%s' "$_have" | tr -d '[:space:]')"
                _hr="$(floor_rank "$_have")" || die "[excluded:$prefix] in $file carries keep='$_have', which is neither a count nor 'all'. An unreadable floor cannot be compared with the profile's ($keep) and must not be guessed at -- gen-cron would refuse this file on the next render anyway. Fix that section by hand and re-run. No floor was written and nothing was installed."
                _kr="$(floor_rank "$keep")" || die "profile '$PROFILE_ACTIVE' declares [excluded:$prefix] keep='$keep', which is neither a count nor 'all'"
                # PROVENANCE DECIDES WHICH RULE APPLIES (REV F5).
                local _owner
                _owner="$(section_profile_marker "$file" "[excluded:$prefix]")"
                if [ -n "$_owner" ] && [ "$_owner" != "$PROFILE_ACTIVE" ] && [ "$_hr" -ne "$_kr" ]; then
                    # TWO PROFILES, TWO ANSWERS. Neither is an operator's
                    # deliberate hardening, so the asymmetry has nothing to
                    # protect and direction is irrelevant: one config cannot
                    # fence a family two ways, and silently keeping either
                    # number leaves the other profile displaying a policy that
                    # is in force nowhere.
                    die "[excluded:$prefix] in $file was declared by profile '$_owner' with keep=$_have, and profile '$PROFILE_ACTIVE' declares keep=$keep. A floor is CONFIG-WIDE, so one file cannot honour both, and neither is a hand-made decision this run may defer to. Make the two profiles agree on that family, or install them into separate configs, and re-run. No floor was written and nothing was installed."
                fi
                if [ "$_hr" -lt "$_kr" ]; then
                    die "[excluded:$prefix] in $file fences that family at keep=$_have, and profile '$PROFILE_ACTIVE' requires keep=$keep -- the config protects it LESS than the policy this relationship is being created under. Neither value is ours to pick: proceeding would give this relationship a weaker prune guard than its own profile declares, and raising the floor here would rewrite the prune command of every relationship already in this file. Make them agree, in the profile or in the config, and re-run. No floor was written and nothing was installed."
                fi
                [ "$_hr" -gt "$_kr" ] && log "[excluded:$prefix] in $file already fences that family at keep=$_have, more strongly than profile '$PROFILE_ACTIVE' asks (keep=$keep) -- keeping it, because nothing marks it as another profile's declaration and an operator's hand-made hardening is theirs to keep"
            fi
        done
        # PASS 2: write what is genuinely missing. Nothing here can refuse any
        # more -- every reason to refuse was exhausted above.
        for _i in "${!floor_prefixes[@]}"; do
            prefix="${floor_prefixes[$_i]}"
            grep -qF "[excluded:$prefix]" "$file" 2>/dev/null && continue
            {
                echo
                echo "[excluded:$prefix]"
                # Provenance, in the same idiom as every other generated section.
                # Without it the next profile cannot tell this floor from an
                # operator's hand-made one -- see section_profile_marker.
                echo "	# managed-by: zfs-backup.sh profile=$PROFILE_ACTIVE"
                echo "	keep = ${floor_keeps[$_i]}"
            } >> "$file" || die "could not append [excluded:$prefix] to $file"
            log "added missing reserved-prefix protection [excluded:$prefix] (keep=${floor_keeps[$_i]}) to $file"
        done
    elif [ "$needs_profile" -eq 1 ]; then
        # Inheriting the installed policy is the correct action, but doing it
        # silently is not: the new relationship is about to get a prune sweep
        # that runs WITHOUT a protection this estate normally carries, and the
        # operator should learn that here rather than from a missing pvesr or
        # vzdump snapshot later. A warning is neither a mutation nor a refusal,
        # and activate-client shows its full proposal before installing.
        local missing="" _diff="" _i2 _hv
        for _i2 in "${!floor_prefixes[@]}"; do
            prefix="${floor_prefixes[$_i2]}"
            if ! grep -qF "[excluded:$prefix]" "$file" 2>/dev/null; then
                missing="$missing $prefix"
                continue
            fi
            # A DISAGREEMENT here is reported, never refused, and that asymmetry
            # is deliberate. On this path the run is not writing floors at all --
            # the config already carries relationship policy, so the new
            # relationship inherits it exactly as installed (Gate 2). Refusing
            # would make a host unusable because an administrator once narrowed a
            # floor on purpose, which REV-20260810-092 explicitly protects. But
            # the profile's number is not in force, and saying nothing would let
            # an operator believe it was.
            # Same asymmetry as the install path. A config fencing MORE than the
            # profile asks is not worth a line of stderr on every single run; a
            # config fencing LESS is, because the relationship about to be
            # created inherits a guard weaker than its own policy declares.
            _hv="$(section_field "$file" "[excluded:$prefix]" keep)"
            _hv="$(printf '%s' "$_hv" | tr -d '[:space:]')"
            local _hvr _kvr
            if _hvr="$(floor_rank "$_hv")" && _kvr="$(floor_rank "${floor_keeps[$_i2]}")"; then
                [ "$_hvr" -lt "$_kvr" ] \
                    && _diff="$_diff $prefix(config=$_hv, profil=${floor_keeps[$_i2]})"
            else
                _diff="$_diff $prefix(config='$_hv' -- nieczytelne)"
            fi
        done
        [ -n "$_diff" ] && warn "$file fences these families MORE WEAKLY than profile '$PROFILE_ACTIVE' declares:$_diff -- the INSTALLED value stays in force for every relationship in this file, including the new one. The profile's number is not being applied here (that would change the prune command of relationships already running). Reconcile them deliberately if the profile is the one you meant."
        [ -n "$missing" ] && warn "$file has no [excluded:] floor for:$missing -- the new relationship inherits the CONFIG-wide protection policy exactly as installed, and it is NOT being repaired here (that would change the prune command of every relationship already in this file). If those floors are wanted, add them by hand, deliberately, in one edit that you can see affects everything."
    fi
    # Explicit: without it this function's exit status would be whatever the
    # last conditional happened to evaluate to -- the fail-open shape REV-084
    # was filed for.
    return 0
}

# gen-cron.sh --install replaces the ENTIRE managed block (BEGIN/END markers)
# in this user's crontab with whatever the given config generates -- there is
# exactly ONE managed block per crontab, shared by every config anyone has
# ever used on this host. Installing from a DIFFERENT file than whatever
# produced the block already there silently deletes every job the real one
# describes. Found live (2026-07-30, pve0): activate-client's own config file
# was different from the host's existing jobs.pve0.v4.conf, and --install
# wiped every real production cron line (vm-101, archive, hdd/lxc) until
# `gen-cron.sh -c jobs.pve0.v4.conf --install` restored them by hand.
#
# gen-cron.sh emits a `# Source: <file>` line as part of the managed block
# itself -- the one breadcrumb that says which file is authoritative for
# whatever is currently installed. Refuse outright if it names a different
# file than the one this run is about to use.
#
# REV-20260730-003 F5 (both review passes): comparing `basename` alone is not
# enough -- /etc/zfs/jobs.conf and /root/test/jobs.conf share a basename but
# are not the same file. A relative name in the crontab's own '# Source:'
# line is normalized against $SCRIPT_DIR (where gen-cron.sh's own default `-c`
# resolution actually looks), never against the caller's current working
# directory.
normalize_cron_source() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) p="$SCRIPT_DIR/$p" ;;
    esac
    readlink -f "$p" 2>/dev/null || printf '%s' "$p"
}
# Switching the collector to a dedicated account moves WHERE the managed block
# is installed. It does not move the block that is already there.
#
# Found before running the live pass, 2026-08-01: pve1's root crontab holds a
# managed block generated from jobs.pve1.v4.conf. Setting --local-user would
# install a block built from that SAME config into the account's crontab, while
# root's copy stays exactly where it is -- so every production job in it would
# run twice, on the same schedule, against the same datasets.
#
# assert_cron_config_matches_installed cannot see this: it reads the TARGET
# user's crontab, which has no managed block at all, finds no '# Source:' line,
# and correctly reports no conflict. The conflict is with a DIFFERENT user.
# REV-20260801-018/-019: the first version of this guard asked whether root's
# block came from the SAME CONFIG PATH, and that is the one question a real
# migration always answers "no" to. A delegated account cannot read a config
# under /root (0700), so the documented shape of this migration MOVES the file
# to /etc/zfs-snapshot-all/ -- and an operator who COPIES it instead, which is
# the more natural reflex, then has two paths describing one workload. The
# guard returned success, the account's block was installed alongside root's,
# and every send/prune/monitor ran twice.
#
# Path equality was never the property worth testing. What matters is whether
# the two blocks DO the same thing, so that is what is compared: each block is
# reduced to its job lines with the identity-dependent parts stripped out, and
# any intersection at all is a refusal. Two collectors on one host are still
# allowed when their jobs are genuinely disjoint -- that is a real deployment,
# not an accident.
#
# What gets stripped is exactly what an ownership change is ALLOWED to alter:
# the directory a script is called from, and the log a line redirects into.
# Everything that decides what the job DOES -- schedule, datasets, pattern,
# retention flags, quiesce, thresholds -- is left alone and must match for a
# line to count as overlapping.
#
# ONE definition of "the same job", used by the guard, by the migration verb's
# dropped-line detection and by the tests. Duplicating this sed was the obvious
# way to write it and the obvious way for the three to drift apart.
job_identity() {   # cron job lines on stdin -> identity-stripped lines on stdout
    # The ZFS-JOB BEGIN/END markers (gen-cron, 2026-08-17) are WITNESS, not
    # identity: they record that a run happened, they do not change what job it
    # is. Left in, they made every pre-marker installed block differ from every
    # post-marker render in this guard's verbatim comparison -- the lab3 final
    # run watched a legitimate re-activation refuse with "12 job line(s) would
    # be DELETED" whose only difference was the decoration. Stripped here, on
    # the one seam BOTH sides of the comparison already pass through, so old
    # and new shapes compare by the job they run. cron2conf.sh carries its own
    # copy of this normalization (strip_witness_markers) -- it is deployed
    # standalone and cannot source this file; a change to the marker shape must
    # visit both, and test/cron pins the emitted shape itself.
    sed -E \
        -e 's#^([0-9*][^ ]* [^ ]+ [^ ]+ [^ ]+ [^ ]+) echo "\$\(date -Is\) ZFS-JOB BEGIN [^"]*" >>[^;]*; #\1 #' \
        -e 's#e=\$\(mktemp 2>/dev/null\) \|\| e=[^;]*;#e=$(mktemp);#' \
        -e 's#; echo "\$\(date -Is\) ZFS-JOB END [^"]*" >>[^;]*;#;#' \
        -e 's#/[^ ;)"]*/(snapsend|snapget|delsnaps|check-snap-age|notify-fail|notify-warn|alert-digest)\.sh#\1.sh#g' \
        -e 's#/[^ ;)"]*/cron\.log#cron.log#g'
}
managed_block_fingerprint() {   # crontab text on stdin -> sorted job identities
    sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p' \
    | grep -E '^[0-9*]' \
    | job_identity \
    | sort -u
}

# "Could not read it" is not "there is nothing there" -- same rule as the
# preview (REV-20260801-016 F1), and REV-20260801-019 point 5 asks for it here
# too. A crontab this cannot read must abort the run, not read as empty and let
# an overlap check pass by default.
#
# Writes to a FILE the caller names rather than to stdout, and that is not a
# style choice. `die` is an exit, and an exit inside `$(...)` or inside a
# pipeline element leaves only the subshell -- the caller carries on with an
# empty string, which for an overlap check reads as "nothing overlaps". The
# first version of this returned its answer on stdout, and the fail-closed test
# for an unreadable crontab caught it failing OPEN: exactly the direction this
# helper exists to prevent.
crontab_of_or_die() {   # <user> <outfile>
    # The reading half lives in lib-cron.sh now, so "an unreadable crontab is
    # not an empty one" has ONE definition instead of one per program. Only the
    # die() belongs here: the library reports, the caller decides how loudly to
    # stop.
    cron_read "$1" "$2" \
        || die "$CRON_ERR -- this check exists to stop two identities running the same jobs. Nothing has been changed."
}

# REV-20260804-043: normalizes ONLY the mutable host in a generated pull
# line's -A "acct@host:path" argument to a placeholder -- account and path
# (which may itself legally contain a colon, per pc_is_dataset) are left
# exactly as they are. Anchored to the "-A \"...@" prefix so it can never
# match a colon that happens to appear later, inside the dataset path.
# A line with no such argument at all (delsnaps.sh/check-snap-age.sh -- no
# remote connection to switch) is returned unchanged.
# The endpoint has THREE spellings in a generated block, and this used to
# normalize only the first:
#
#   1. snapget.sh's  -A "acct@host:path"                      -- was covered;
#   2. delsnaps.sh's remote source-prune POSITIONAL argument
#      "acct@host:path" -- not covered. The comment at the call site said
#      delsnaps.sh lines have "no remote connection to switch", which stopped
#      being true when managed source retention gained a remote form;
#   3. the ssh port, which lives in its own -p flag and never travelled with
#      the host at all.
#
# So an endpoint switch that changed the port -- or that touched the source
# prune line -- left the relationship's OWN job lines looking like a foreign
# workload about to be deleted, and the guard refused. Measured live on
# 2026-08-23 (issue #9, second path), with a control that isolates it:
#
#   activate --host=<same endpoint>    -> EXIT=0, no-op
#   activate --host=<other host:port>  -> EXIT=1, "2 job line(s) would be DELETED"
#
# and the two "foreign" lines named in the refusal were that client's own
# backup and source-prune jobs. The first switch of a relationship's life
# succeeded only because no managed block existed yet to compare against; every
# switch after cron was installed was impossible.
#
# Still fail-closed by construction: only the host and the port are blanked.
# The account, the source dataset, the target dataset, the schedule, the
# retention flags, HostKeyAlias and everything else are compared verbatim, so a
# job that genuinely disappears is still reported -- a relationship losing one
# of two datasets cannot hide behind the other.
# THE PORT IS DELETED, NOT BLANKED, AND THAT IS THE WHOLE POINT: gen-cron.sh
# EMITS NO -p FLAG AT ALL FOR PORT 22.
#
# The first cut of this rewrote '-p 2222' to '-p <PORT>', which only compares
# equal when both sides carry the flag. Switching back to a port-22 endpoint
# compares a line holding '-p <PORT>' against one holding nothing, so the guard
# still called the relationship's own job a deletion. Measured on the real
# lines out of a live crontab, not on a fixture -- the fixture had '-p 22' on
# both sides, which the tool never produces.
# A cron line's first five fields are WHEN, not WHAT.
#
# The guard below refuses an install that would stop a job from running, and it
# decides "same job" by comparing line text. That made a SCHEDULE change look
# like a deletion: the spreader moving a relationship from :37 to :55 produced
# sixteen lines the guard could not match, and refused a previewed, confirmed
# migration in which nothing was lost and nothing stopped.
#
# Same treatment as the endpoint normalizer above, and for the same reason:
# normalize only the part that legitimately moves, compare everything else
# verbatim -- script, flags, account, source, target, retention, pattern,
# HostKeyAlias, notify text. A line whose COMMAND still appears is still being
# run, which is precisely what this guard is asking.
#
# WHAT THIS DOES NOT PROTECT, said plainly: a job moved to a valid but
# undesirable schedule is excused here. It always was -- a hand-edited config
# could do it, and gen-cron lints the expression it renders. What the guard
# still catches, unchanged, is a job that DISAPPEARS.
schedule_normalized_identity() {
    sed -E 's/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ /<SCHEDULE> /'
}

endpoint_normalized_identity() {
    sed -E -e 's/(-A "[^@"]+@)[^:"]+:/\1<ENDPOINT>:/' \
           -e 's/"([^"@ ]+@)[^:" ]+:/"\1<ENDPOINT>:/g' \
           -e 's/ -p [0-9]+ / /g' -e 's/ -p [0-9]+$//'
}

# REV-20260801-021 F1. The overlap guard below deliberately allows a target that
# runs DISJOINT jobs -- two collectors on one host is a real deployment. On its
# own that is fine; combined with the commit path it was not. `gen-cron.sh
# --install` owns and REPLACES the target's single managed block, and the
# proposal is rendered only from the config being installed, so an existing
# disjoint block is not merged into it -- it is deleted. Silently, because the
# overlap guard had just said the two workloads were unrelated.
#
# The property that matters is narrower than "does the target have a block":
# the install must not REMOVE job lines the target is running today. Anything
# the proposal reproduces is fine, by definition -- that is what installing it
# means.
# Is this lost line's COVERAGE still carried by one of the proposed lines?
#
# gen-cron merges datasets that resolve to the same policy into one job line:
# two sources sending to one store become `snapsend.sh ... "a,b" "store"`, and
# their monitors become `check-snap-age.sh "a,b" ...`. The line that used to say
# "a" therefore disappears -- and the anti-deletion guard, whose rule is "a line
# that vanishes is a job that stops", refuses. Measured live on pve9: adding a
# second local source was impossible for exactly this reason, with the first
# source's own lines named as the casualties.
#
# The guard's rule is a PROXY for the thing that matters, which is coverage. So
# the exemption is written against coverage and nothing else: a lost line is
# absorbed only when a proposed line is IDENTICAL to it except at exactly one
# quoted argument, where the lost line's comma-list is a SUBSET of the proposed
# one's. Same command, same schedule, same thresholds, same target, and every
# dataset it named still named.
#
# BOUND TO THE DATASET ARGUMENT, not to "whichever quoted value differs".
# The first cut accepted a widening at any single quoted argument, which proves
# set inclusion but not that the set is COVERAGE: a widened target, prefix or
# label would have impersonated preserved dataset coverage just as well. So the
# command is recognised first and the dataset argument is located by that
# command's own shape:
#
#   snapsend.sh / snapget.sh   ... "<sources>" "<target>"   -> second-to-last
#   delsnaps.sh                ... "<scope>" "<pattern>" -H..  -> second-to-last
#   check-snap-age.sh          [-R] "<datasets>" "<pattern>" .. -> first
#
# An unrecognised command gets no exemption at all. That is the fail-closed
# direction: a line this function cannot read the shape of is a line whose
# disappearance it must not excuse.
#
# What this deliberately does NOT excuse, and what the discriminators pin:
#   * a line whose dataset simply is not in the new block at all -- a deletion;
#   * a list that SHRINKS ("a,b" -> "a") -- that is a real loss of coverage,
#     and subset-in-the-wrong-direction is exactly how it would sneak through;
#   * a line that differs anywhere else as well -- a changed schedule or
#     threshold is a different job, not a merged one;
#   * a widening at the TARGET, the PREFIX or the LABEL -- inclusion in the
#     wrong argument is not coverage.
line_coverage_absorbed() {   # <lost line> ; proposed lines on stdin -> 0 absorbed
    LOST_LINE="$1" awk '
        # Split a line into a skeleton (quoted values replaced by \001) and the
        # ordered list of those quoted values.
        function shred(s, sk, vals,   out, n, i, ch, inq, cur) {
            out=""; n=0; inq=0; cur=""
            for (i=1; i<=length(s); i++) {
                ch=substr(s,i,1)
                if (ch=="\"") {
                    if (inq) { n++; vals[n]=cur; cur=""; out=out "\001"; inq=0 }
                    else inq=1
                    continue
                }
                if (inq) cur=cur ch; else out=out ch
            }
            sk[0]=out
            return n
        }
        function subset(a, b,   na, nb, i, j, av, bv, hit) {
            na=split(a, av, ","); nb=split(b, bv, ",")
            for (i=1; i<=na; i++) {
                hit=0
                for (j=1; j<=nb; j++) if (av[i]==bv[j]) { hit=1; break }
                if (!hit) return 0
            }
            return 1
        }
        # Which quoted argument of the WHOLE line is the DATASET list.
        #
        # Counting from the end of the line does not work, and the first cut got
        # it exactly backwards for that reason: a cron job line carries quoted
        # values that are not arguments at all -- the stderr redirect, the
        # notify-fail message, the tail subshell. So the argument region of the
        # command itself is isolated first (from the script name to its stderr
        # redirect), the position is resolved inside that region by the shape of
        # that command, and then shifted back by however many quoted values the
        # line carried before it.
        #
        # 0 means: not a shape this function can read. That is the fail-closed
        # answer -- no exemption is available for such a line.
        function count_quotes(s,   i, n) {
            n=0
            for (i=1; i<=length(s); i++) if (substr(s,i,1)=="\"") n++
            return int(n/2)
        }
        function dataset_arg(line,   cmd, at, seg, cut, before, n, kind) {
            kind=0
            if (line ~ /snapsend\.sh/)       { cmd="snapsend.sh";      kind=1 }
            else if (line ~ /snapget\.sh/)   { cmd="snapget.sh";       kind=1 }
            else if (line ~ /delsnaps\.sh/)  { cmd="delsnaps.sh";      kind=1 }
            else if (line ~ /check-snap-age\.sh/) { cmd="check-snap-age.sh"; kind=2 }
            else return 0
            at=index(line, cmd)
            if (at == 0) return 0
            before=count_quotes(substr(line, 1, at-1))
            seg=substr(line, at)
            cut=index(seg, " 2>")
            if (cut > 0) seg=substr(seg, 1, cut-1)
            n=count_quotes(seg)
            # kind 1: the command ends with "<datasets>" "<target-or-pattern>",
            #         so the dataset list is the second-to-last of its own args;
            # kind 2: check-snap-age takes "<datasets>" first.
            if (kind == 1) return (n >= 2) ? before + n - 1 : 0
            return (n >= 1) ? before + 1 : 0
        }
        BEGIN {
            ln=ENVIRON["LOST_LINE"]
            nl=shred(ln, lsk, lv)
            want=dataset_arg(ln)
        }
        {
            if (want == 0) next
            np=shred($0, psk, pv)
            if (np != nl || psk[0] != lsk[0]) next
            # The proposed line must be the same command, so the argument that
            # carries datasets sits in the same place in both.
            if (dataset_arg($0) != want) next
            diff=0; idx=0
            for (i=1; i<=nl; i++) if (lv[i] != pv[i]) { diff++; idx=i }
            # Identical would not have been called lost; more than one differing
            # argument is a different job, not a wider one.
            if (diff != 1) next
            # ...and the one that differs has to BE the dataset argument. A
            # widened target, prefix or label is inclusion in the wrong place.
            if (idx != want) next
            # Direction matters: the OLD list must be contained in the NEW one.
            # The reverse is coverage being dropped, which is the thing this
            # guard exists to catch.
            if (subset(lv[idx], pv[idx]) && !subset(pv[idx], lv[idx])) { print "ABSORBED"; exit }
        }
    ' | grep -q ABSORBED
}

assert_target_block_not_clobbered() {   # <config whose render is about to be installed>
    local file="$1" u; u=$(cron_target_user)
    local tcron; tcron=$(mktemp) || die "mktemp failed"
    crontab_of_or_die "$u" "$tcron"
    local current; current=$(managed_block_fingerprint < "$tcron"); rm -f "$tcron"
    [ -n "$current" ] || return 0

    local proposed; proposed=$(gencron_as_target -c "$file" 2>/dev/null | managed_block_fingerprint)
    [ -n "$proposed" ] || die "'$u' already runs a managed block and the block this run would install could not be rendered -- so whether the install would delete any of them is unknown. Refusing rather than guessing; nothing has been changed."

    local lost; lost=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$proposed"))

    # REV-20260804-042 Gate G (live route-switch test) / REV-20260804-043
    # (P1 correction to the first attempt at this): a legitimate
    # set-endpoint + activate-client cycle changes the live host:port
    # embedded in a client's pull line's -A "acct@host:path" argument,
    # which changes the line's literal text and therefore its identity
    # here -- even though it is still the SAME job, just reached a
    # different way. The first fix (2e02a7d) matched on HostKeyAlias
    # alone, which is shared by every job belonging to one client -- a
    # client with two datasets could lose one of them silently as long as
    # the OTHER one still appeared under the new endpoint, exactly the
    # deletion this guard exists to catch. Fixed by normalizing only the
    # mutable host between "acct@" and the following ":" in -A's argument
    # (endpoint_normalized below) and comparing the REST of each line
    # verbatim -- account, source dataset, target dataset, schedule,
    # retention, HostKeyAlias, everything else still has to match exactly.
    # A line with no -A "acct@host:..." shape at all (delsnaps.sh,
    # check-snap-age.sh -- no remote connection to switch) passes through
    # unnormalized, so it can only be excused here by being byte-identical
    # already, which the earlier comm(1) diff would not have called "lost"
    # in the first place -- fail-closed by construction, not by a special
    # case.
    if [ -n "$lost" ]; then
        local proposed_norm; proposed_norm=$(printf '%s\n' "$proposed" | endpoint_normalized_identity | sort -u)
        local still_lost="" line norm
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            norm=$(printf '%s\n' "$line" | endpoint_normalized_identity)
            if printf '%s\n' "$proposed_norm" | grep -qxF -- "$norm"; then
                continue
            fi
            # Second exemption, same shape as the endpoint one: not "this line
            # looks similar" but "every dataset this line covered is still
            # covered, by an otherwise identical line". See line_coverage_absorbed.
            if printf '%s\n' "$proposed" | line_coverage_absorbed "$line"; then
                continue
            fi
            # Third exemption: the job is still there, at a different minute.
            # Both sides are normalized on the endpoint FIRST, so a run that
            # changes the endpoint and the schedule together is still matched
            # by what it actually is -- one job, moved twice.
            if printf '%s\n' "$proposed_norm" \
                 | schedule_normalized_identity | grep -qxF -- \
                     "$(printf '%s\n' "$norm" | schedule_normalized_identity)"; then
                continue
            fi
            still_lost="$still_lost$line
"
        done <<< "$lost"
        lost="${still_lost%$'\n'}"
    fi
    [ -n "$lost" ] || return 0

    local n; n=$(printf '%s\n' "$lost" | grep -c .)
    warn "'$u' runs these job(s) today, and the block about to be installed does not contain them:"
    printf '%s\n' "$lost" | sed 's/^/    /' >&2
    die "$n job line(s) would be DELETED from '$u' by this install. gen-cron.sh replaces the whole managed block, so anything the new config does not describe simply stops running -- and a backup that stops running does not alert. Merge the two configs into one and install that, or move the other workload out of this account first. Nothing has been changed."
}

assert_no_foreign_managed_block() {   # <config whose render is about to be installed>
    local file="$1" u; u=$(cron_target_user)
    [ "$u" = root ] && return 0

    local rootcron; rootcron=$(mktemp) || die "mktemp failed"
    crontab_of_or_die root "$rootcron"
    local theirs; theirs=$(managed_block_fingerprint < "$rootcron"); rm -f "$rootcron"
    [ -n "$theirs" ] || return 0

    # Rendered the same way the install renders it, so the comparison is
    # against what would actually land in the account's crontab.
    local mine; mine=$(gencron_as_target -c "$file" 2>/dev/null | managed_block_fingerprint)
    [ -n "$mine" ] || die "root already runs a managed block, and the block this run would install into '$u' could not be rendered -- so whether they overlap is unknown. Refusing rather than guessing; nothing has been changed."

    local overlap; overlap=$(comm -12 <(printf '%s\n' "$theirs") <(printf '%s\n' "$mine"))
    [ -n "$overlap" ] || return 0

    local n; n=$(printf '%s\n' "$overlap" | grep -c .)
    warn "these job(s) already run from root's crontab and would run again as '$u':"
    printf '%s\n' "$overlap" | sed 's/^/    /' >&2
    die "$n job line(s) overlap between root's managed block and the block this run would install into '$u' -- identical work, same schedule, same datasets, twice. The config PATHS differ, which is normal and is why that is not what was compared. Take these jobs off root before installing them under '$u': clear root's managed block for this config (or remove the root-side relationship), then re-run this install. Nothing has been changed."
}

# gen-cron.sh runs AS the dedicated account, so that account has to be able to
# READ the config. The default location used to be $SCRIPT_DIR/jobs.<host>.conf,
# which on a Proxmox host means /root/scripts/... -- and /root is 0700. Found on
# metropolis pve1, 2026-08-01: the account could not open the file at all, so
# --local-user with the default path would have failed at install time, after
# the preview had already been shown and accepted. Since 2026-08-17 the default
# is /etc/zfs-snapshot-all (default_cron_config), but a RECORDED path can still
# point anywhere, so this check stays.
#
# Checked as the account itself rather than by reasoning about modes: group
# membership, ACLs and every parent directory on the path all get a vote, and
# `test -r` run as that user is the only thing that knows all of them.
assert_config_readable_by_target() {   # <config file>
    local file="$1" u; u=$(cron_target_user)
    [ "$u" = root ] && return 0
    # A config that does not exist yet cannot be unreadable -- the FIRST
    # activation on a fresh collector creates it at the end, via the atomic
    # swap, explicitly chmod 0644. Probing it here refused the whole lab3
    # final run one gate before the finish line (layer seven). What this
    # check is FOR -- an existing file at a path the account cannot open,
    # e.g. under /root -- still refuses below.
    [ -e "$file" ] || return 0
    local ok=1
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$u" -- test -r "$file" && ok=0
    else
        su -s /bin/bash "$u" -c "$(printf '%q ' test -r "$file")" && ok=0
    fi
    [ "$ok" -eq 0 ] && return 0
    die "'$u' cannot read $file, and gen-cron.sh runs AS that account -- the install would fail after you had already approved the preview. Put the config somewhere the account can reach (/etc/zfs-snapshot-all/ is root-owned and world-readable, and is where this tool keeps its other state) and pass it with --config=."
}

assert_cron_config_matches_installed() {
    local file="$1" raw existing want
    raw=$(crontab_for_target 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
    [ -n "$raw" ] || return 0
    existing=$(normalize_cron_source "$raw")
    want=$(normalize_cron_source "$file")
    [ "$existing" = "$want" ] && return 0
    die "the crontab's managed block was generated from '$raw' (resolved: $existing), not '$file' (resolved: $want) -- installing from a different file would DELETE every job '$raw' describes. Re-run with the matching --config=, or merge the two files by hand first (see the real incident this check exists for: project memory, 2026-07-30)."
}

# REV-20260730-003 F4/F6, hardened per REV-20260730-004 F7: atomically swaps
# a validated working copy over the real config, installs, and rolls back on
# failure at BOTH layers -- the config FILE (as before) AND, independently,
# the CRONTAB ITSELF, captured immediately before the swap. The reviewer's
# point: "crontab was NOT changed" used to be an assumption about
# gen-cron.sh's own atomicity, not something this wrapper actually proved or
# guaranteed. Now it does not need to assume that: it holds its own snapshot
# of `crontab -l` and restores it directly with `crontab <snapshot>` if
# --install fails, independent of whatever state the config file ends up in.
# Write one client's whole shape into a config working copy: a [dataset:]
# section per replicated dataset, plus the single [prune:] ladder that covers
# them. Extracted so activate-client and migrate-profile cannot drift -- a
# migration that produced a slightly different section than an activation would
# be the worst kind of bug here, since the difference only shows up as a cron
# line nobody compared.
#
# Requires load_client_and_connection() to have run. Sets `managed` (the local
# paths) and `prune_scope` in the CALLER's scope, which both callers then record
# in the client conf.
# ---- coverage overlap: one fail-closed preflight (REV-20260809-083) ---------
#
# The owner's create-only contract says a preset may APPEND a new independent
# task, and must refuse when the requested source overlaps coverage that already
# exists. Exact-path collisions were already refused by relationship ownership,
# but overlap that is not an exact match was not: relationship A owning
# `rpool/data` and relationship B later taking `rpool/data/vm-101` produce
# DIFFERENT section headers, so no marker check fires -- and the two then send
# and prune the same snapshots under different policy. Silent duplicate
# ownership, not cosmetic duplication.
#
# Deliberately the conservative rule the review asked for, NOT a second
# recursion model. A relationship with `recursive = no` does not really cover
# its children, so prefix rejection is stricter than semantics require. That is
# the accepted trade: a too-cautious refusal costs the expert one native CONFIG
# edit; a missing refusal costs a silent double-prune. If exact semantics are
# ever wanted, extract the coverage model `--reconcile` already has rather than
# copying it here.
path_overlaps() {   # <a> <b> -> 0 when either contains the other, or equal
    [ "$1" = "$2" ] && return 0
    case "$1" in "$2"/*) return 0 ;; esac
    case "$2" in "$1"/*) return 0 ;; esac
    return 1
}

# Prints one conflict per line: <other client> <TAB> <owned path> <TAB> <requested>.
# It PRINTS rather than dying, because a `die` inside $( ) kills only the
# subshell and reads as success to the caller -- a fail-open this project has
# already paid for once. The caller decides, on the text AND on the status.
coverage_conflicts() {   # <this client> <requested path>...
    local me="$1"; shift
    [ -d "$CLIENTS_DIR" ] || return 0
    local f
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        # A subshell per record: emit_client_sections runs with this client's
        # LOAD_*/MANAGED_* already loaded, and sourcing another record here
        # would overwrite them mid-emit.
        (
            CLIENT_NAME=""; STATE=""; MANAGED_DATASETS=""; MANAGED_PRUNE_SCOPE=""
            # REV-20260809-084 F1. This was `|| exit 0`, which turned an
            # unreadable or unparseable record into "no conflict" -- fail-OPEN,
            # and it made the refusal path in assert_no_coverage_overlap
            # unreachable for exactly the case that diagnostic describes. A
            # damaged state record is when the system knows LESS and must refuse
            # rather than guess. Exit 2 is distinct from "found nothing" so the
            # caller can tell the two apart.
            [ -r "$f" ] || exit 2
            # shellcheck disable=SC1090
            . "$f" 2>/dev/null || exit 2
            # A record that parses but names no relationship cannot be reasoned
            # about either: it may own anything.
            [ -n "${CLIENT_NAME:-}" ] || exit 2
            [ "${CLIENT_NAME:-}" = "$me" ] && exit 0
            [ "${STATE:-}" = removed ] && exit 0
            local owned req
            for owned in ${MANAGED_DATASETS:-} ${MANAGED_PRUNE_SCOPE:-}; do
                for req in "$@"; do
                    path_overlaps "$owned" "$req" \
                        && printf '%s\t%s\t%s\n' "${CLIENT_NAME:-$f}" "$owned" "$req"
                done
            done
            # Without this, the subshell's exit status is whatever the LAST
            # `path_overlaps && printf` happened to return -- 1 (false) for
            # any record whose final dataset/path pair does not overlap. That
            # turned every ordinary disjoint record into a false "unreadable"
            # once the line below started treating a nonzero subshell exit as
            # a read/parse failure. A record that was actually read and
            # scanned exits 0 no matter what the scan found; conflicts are
            # reported through the printed lines, not through the exit code.
            exit 0
        ) || { printf '!\t%s\t%s\n' "$f" "unreadable or unparseable relationship record"; return 2; }
    done
    return 0
}

assert_no_coverage_overlap() {   # <this client> <requested path>...
    local me="$1"; shift
    [ "$#" -gt 0 ] || return 0
    local conflicts rc=0
    conflicts="$(coverage_conflicts "$me" "$@")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        # coverage_conflicts() names the specific record it could not read or
        # parse on a line starting with "!" (REV-20260809-084); surface that
        # here instead of a generic message, so the operator knows which
        # record to fix rather than having to guess across CLIENTS_DIR.
        local badf reason badmsg="" tag
        while IFS=$'\t' read -r tag badf reason; do
            [ "$tag" = "!" ] || continue
            badmsg="$badmsg
  '$badf': $reason"
        done <<< "$conflicts"
        die "could not check whether '$me' overlaps existing coverage -- refusing rather than guessing; nothing has been changed$badmsg"
    fi
    [ -z "$conflicts" ] && return 0
    local line other owned req msg=""
    while IFS=$'\t' read -r other owned req; do
        [ -n "$other" ] || continue
        msg="$msg
  '$req' overlaps '$owned', already owned by relationship '$other'"
    done <<< "$conflicts"
    die "refusing to add '$me': it would take coverage another relationship already owns.$msg

Two high-level relationships covering the same datasets would send and prune the same snapshots under different policy. Nothing has been changed -- no config, no crontab.
If the overlap is intended, express it in native CONFIG v4 by hand; the high-level path deliberately will not."
}

# REV-20260809-089. The ownership test remove_managed_sections applies, made
# available WITHOUT mutating the file, so a re-activation can tell "this is my
# own installed section, preserve it" from "this is not mine". The two tests are
# deliberately identical: marker as the section's FIRST content line, or the
# path already recorded in this client's own MANAGED_DATASETS/
# MANAGED_PRUNE_SCOPE. A header match alone is NOT ownership (REV-20260802-033
# U11) -- an unowned header falls through to the regeneration path, where
# remove_managed_sections still refuses it exactly as before.
section_owned_by() {   # <file> <exact header> <client name> <path>
    local file="$1" want="$2" name="$3" path="$4" x first
    grep -qxF "$want" "$file" 2>/dev/null || return 1
    for x in ${MANAGED_DATASETS:-} ${MANAGED_PRUNE_SCOPE:-}; do
        [ "$x" = "$path" ] && return 0
    done
    first=$(cron_config_section "$file" "$want" | sed -n '2p')
    first="${first#"${first%%[![:space:]]*}"}"
    [ "$first" = "# managed-by: zfs-backup.sh client=$name" ]
}

# Replace ONE field's value inside ONE section, leaving every other line of that
# section -- profile policy, hand-added fields, comments, ordering, alignment --
# byte-identical. Everything up to and including the original '=' is kept, so a
# hand-formatted line keeps its own formatting. Returns 3 if the field is not
# present in the section: silently writing nothing would leave the relationship
# pointing at the OLD endpoint with no error, which is the failure this whole
# change exists to prevent.
update_section_field() {   # <file> <exact header> <field> <new value>
    local file="$1" want="$2" field="$3" value="$4" rc
    local tmp; tmp=$(mktemp) || return 1
    # ENVIRON, not -v: awk -v interprets backslash escapes in the value.
    FIELD_VALUE="$value" awk -v want="$want" -v field="$field" '
        $0 == want { emit=1; print; next }
        emit && /^\[/ { emit=0 }
        emit {
            line=$0
            sub(/^[ \t]+/, "", line)
            n=index(line, "=")
            if (n > 0) {
                key=substr(line, 1, n-1)
                gsub(/[ \t]+$/, "", key)
                if (key == field) {
                    found=1
                    p=index($0, "=")
                    printf "%s %s\n", substr($0, 1, p), ENVIRON["FIELD_VALUE"]
                    next
                }
            }
        }
        { print }
        END { if (!found) exit 3 }
    ' "$file" > "$tmp"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp"; return "$rc"; }
    mv_preserving_mode "$tmp" "$file"
}

# update_section_field's sibling for a field that may legitimately be ABSENT.
#
# 'flags' and 'src' always exist in a section this tool wrote, so refusing when
# they are missing is the right fail-closed answer. A link field is different:
# a relationship with no cap carries no 'bandwidth' line at all, and a cap that
# is later removed must take the line with it. Three cases, one function:
#
#   value non-empty, field present  -> rewrite in place (update_section_field)
#   value non-empty, field absent   -> insert at the end of the section
#   value empty                     -> delete the line if it is there
#
# Fail-closed on the one thing that is genuinely wrong: a section header that is
# not in the file at all returns 3, exactly as update_section_field does, rather
# than silently writing nothing and reporting success. Without that, a refresh
# aimed at a section that had been renamed or hand-removed would drop the cap
# and say it had applied it.
set_or_remove_section_field() {   # <file> <exact header> <field> <value>
    local file="$1" want="$2" field="$3" value="$4" rc
    if [ -n "$value" ]; then
        update_section_field "$file" "$want" "$field" "$value"
        rc=$?
        [ "$rc" -ne 3 ] && return "$rc"
        # Absent: insert. Anything but "not found" is a real failure.
    fi
    local tmp; tmp=$(mktemp) || return 1
    FIELD_VALUE="$value" awk -v want="$want" -v field="$field" '
        function flush_insert() {
            if (insert && ENVIRON["FIELD_VALUE"] != "") {
                printf "\t%s = %s\n", field, ENVIRON["FIELD_VALUE"]
                insert=0
            }
        }
        $0 == want { seen=1; emit=1; insert=1; print; next }
        emit && /^\[/ { flush_insert(); emit=0 }
        emit {
            line=$0
            sub(/^[ \t]+/, "", line)
            n=index(line, "=")
            if (n > 0) {
                key=substr(line, 1, n-1)
                gsub(/[ \t]+$/, "", key)
                # Deletion: drop the line and, with it, the reason to insert.
                if (key == field) { insert=0; next }
            }
        }
        { print }
        END { flush_insert(); if (!seen) exit 3 }
    ' "$file" > "$tmp"
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp"; return "$rc"; }
    mv_preserving_mode "$tmp" "$file"
}

# Which of this relationship's sections must be GENERATED, and therefore whether
# this activation needs a profile at all.
#
# REV-20260810-090. Deliberately computed WITHOUT consulting the profile: "does
# this run need the profile" cannot be answered by a function that has already
# loaded it. Everything here reads the installed config and the client record —
# ownership markers, the peer's dataset list, and `PROFILE_GFS`, which
# detect_profile_gfs() reads off the installed file, not off a profile.
#
# One implementation, two callers: cmd_activate_client() needs the answer BEFORE
# ensure_cron_config() so it can say whether a profile is required, and
# emit_client_sections() needs the same split to do the work. Two copies of this
# rule drifting apart is exactly the failure this project has paid for before,
# so there is only one.
declare -a PLAN_REGEN_DS=() PLAN_REGEN_PATHS=() PLAN_KEEP_DS=()
PLAN_PRUNE_SCOPE=""; PLAN_PRUNE_NEEDS_GEN=0; PLAN_NEEDS_PROFILE=0
client_section_plan() {   # <file> <client name> <is_new_relationship>
    local file="$1" name="$2" is_new="$3" ds localpath
    local sync_mode=0
    [ "${PEER_SAVED_MODE:-}" = sync ] && sync_mode=1
    PLAN_REGEN_DS=(); PLAN_REGEN_PATHS=(); PLAN_KEEP_DS=()
    PLAN_PRUNE_SCOPE=""; PLAN_PRUNE_NEEDS_GEN=0; PLAN_NEEDS_PROFILE=0

    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        if [ "$is_new" -eq 0 ] \
           && section_owned_by "$file" "[dataset:$localpath]" "$name" "$localpath" \
           && { [ "$sync_mode" -eq 0 ] || [ "${PROFILE_GFS:-1}" -ne 1 ] \
                || section_owned_by "$file" "[prune:$ds]" "$name" "$ds"; }; then
            # sync mode puts this client's [dataset:] and [prune:] at the SAME
            # path, and preserving one means never calling
            # remove_managed_sections on that path -- so the prune half would
            # escape the ownership check entirely. Require both, or regenerate.
            PLAN_KEEP_DS+=("$ds")
        else
            PLAN_REGEN_DS+=("$ds"); PLAN_REGEN_PATHS+=("$localpath")
        fi
    done

    if [ "${PROFILE_GFS:-1}" -eq 1 ]; then
        if [ "$sync_mode" -eq 1 ]; then
            local -a scopes=()
            for ds in $PEER_SAVED_DATASETS; do scopes+=("$ds"); done
            PLAN_PRUNE_SCOPE="${scopes[*]}"
            [ "${#PLAN_REGEN_DS[@]}" -gt 0 ] && PLAN_PRUNE_NEEDS_GEN=1
        else
            # One recursive ladder over the client's whole subtree: a dataset
            # newly in scope lands UNDER it without the section needing to
            # change, so an already-owned ladder needs no regeneration even
            # when some datasets do. LOAD_LABEL is peer_label "$PEER_HOST" --
            # the pairing peer, not the endpoint address -- so set-endpoint
            # does not move this path.
            PLAN_PRUNE_SCOPE="$PEER_SAVED_TARGET/$LOAD_LABEL"
            if [ "$is_new" -ne 0 ] \
               || ! section_owned_by "$file" "[prune:$PLAN_PRUNE_SCOPE]" "$name" "$PLAN_PRUNE_SCOPE"; then
                PLAN_PRUNE_NEEDS_GEN=1
            fi
        fi
    fi

    if [ "${#PLAN_REGEN_DS[@]}" -gt 0 ] || [ "$PLAN_PRUNE_NEEDS_GEN" -eq 1 ]; then
        PLAN_NEEDS_PROFILE=1
    fi

    # AFTER the needs-profile decision, never before -- the rule this function
    # is built on is that "does this run need the profile" cannot be answered by
    # something that has already loaded it. That rule is intact: the profile is
    # consulted only once the answer is already yes, and only to correct a shape
    # the CONFIG cannot know.
    #
    # PROFILE_GFS came from detect_profile_gfs reading the installed file. On a
    # fresh config that file says nothing, so it defaults to "ladder" and a flat
    # profile's ladder was planned, generated, and rejected by gen-cron for
    # having no use_template (measured live on pve9). A profile that declares no
    # prune fragment gets no ladder -- and no MANAGED_PRUNE_SCOPE recorded for
    # one either, which is what remove-client later reads.
    if [ "$PLAN_NEEDS_PROFILE" -eq 1 ] && [ "$PLAN_PRUNE_NEEDS_GEN" -eq 1 ]; then
        # VALIDATE BEFORE LOADING, and never die here. load_active_profile calls
        # die() on an unreadable or invalid profile, and REV-20260809-090 F1
        # requires the exact opposite of that on this path: an installed
        # relationship must keep re-activating after the profile it was created
        # from is renamed, removed, or edited into something that no longer
        # validates. CI caught it -- six re-activation assertions, all of them
        # mine, all of them the same mistake: making a decision depend on a
        # profile in a path where the profile legitimately is not there.
        #
        # When it cannot be read, the config's own answer stands, which is the
        # behaviour that existed before this block.
        if profile_validate_file "$(profile_file "$PROFILE_ACTIVE")" "$GENCRON" >/dev/null 2>&1; then
            load_active_profile
            if ! profile_declares_ladder; then
                PLAN_PRUNE_SCOPE=""; PLAN_PRUNE_NEEDS_GEN=0
            fi
        fi
    fi
    return 0
}

emit_client_sections() {   # <workfile> <client name> [is_new_relationship=0]
    local workfile="$1" name="$2" ds localpath
    local is_new_relationship="${3:-0}"
    # Reset per call: which source datasets got a REMOTE [prune:] this run. The
    # flow reads it after this returns to run the fail-closed grant check for
    # exactly those (and only those) before publishing -- an empty list on a
    # preserved re-activation means no SSH is opened at all (REV-20260811-102).
    SOURCE_PRUNE_EMITTED_DS=()
    # The profile is loaded LAZILY, below, once the plan says something must
    # actually be generated (REV-20260810-090 F1). The emitted sections
    # REFERENCE the profile templates ensure_cron_config appends, so when it IS
    # loaded both read the same rendered profile -- one loader, not two readers,
    # so activation and migration cannot drift.
    # REV-20260802-033 U11: this comment, as the section's first content
    # line, is what lets remove_managed_sections tell a section IT wrote from
    # a hand-written one that coincidentally shares the same header text --
    # header text alone was never proof of authorship, only of path. See the
    # marker check in remove_managed_sections for what happens on a mismatch.
    local marker="# managed-by: zfs-backup.sh client=$name"
    local sync_mode=0
    [ "${PEER_SAVED_MODE:-}" = sync ] && sync_mode=1

    # F7 (owner decision 2026-08-17, lab3): a sync relationship NEVER starts a
    # second snapshot family. If the source dataset already carries automated_*
    # snapshots, someone else is producing that family -- most importantly the
    # chained case, where the "source" is itself another collector's COPY. The
    # lab measured what two writers into one family do: pve9's UTC-named
    # snapshots landed in the same GFS creation-time bucket as link A's, the
    # copy's prune kept the wrong one, and BOTH links lost their common base
    # within 80 minutes -- the chain destroyed itself with every engine
    # individually working as designed. So a sync dataset whose source already
    # has the family becomes PASSIVE: snapget -e consumes the newest existing
    # snapshot, creates nothing on the source, and no remote source-prune is
    # emitted (the family's owner keeps sole retention authority). The audit
    # already understands this shape (installed_dataset_is_passive).
    # Per dataset, not per client: a mixed scope stays correct dataset by
    # dataset. Detection is one snapshot listing over the already-loaded
    # channel; `zfs list` needs no delegation, so this works pre-grant too.
    local -a passive_ds=()
    sync_ds_is_passive() {   # <source dataset> -> 0 if its family already exists
        case " ${passive_ds[*]:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
    }
    if [ "$sync_mode" -eq 1 ]; then
        local pds pds_rc
        # Ask about THIS profile's family, not the literal automated_ root.
        # Only when the plan is going to render from the profile anyway
        # (PLAN_NEEDS_PROFILE): a preserving reactivation must keep working
        # after its profile is renamed or removed (REV-090), and its
        # detection result feeds nothing -- no section is re-emitted.
        local sync_family_root=automated_
        [ "$PLAN_NEEDS_PROFILE" -eq 1 ] && sync_family_root=$(profile_family_root)
        for pds in $PEER_SAVED_DATASETS; do
            source_family_exists "$pds" "$sync_family_root"; pds_rc=$?
            [ "$pds_rc" -eq "$SOURCE_PROBE_UNKNOWN" ] \
                && die_probe_unknown "$pds" "whether this relationship consumes that family passively or stamps its own"
            if [ "$pds_rc" -eq 0 ]; then
                passive_ds+=("$pds")
                log "sync: '$pds' already carries a ${sync_family_root}* family on $LOAD_HOST -- PASSIVE consumption (snapget -e): no new snapshots on the source, no source prune, retention stays with the family's owner"
            fi
        done
    fi

    managed=()
    for ds in $PEER_SAVED_DATASETS; do
        managed+=("$(client_local_path "$ds")")
    done
    # Fail closed BEFORE the first mutation: remove_managed_sections below is
    # already a write to the working config (REV-20260809-083).
    [ "${#managed[@]}" -gt 0 ] && assert_no_coverage_overlap "$name" "${managed[@]}"

    # REV-20260809-089. The old code removed and regenerated EVERY section on
    # EVERY call. That is right exactly once -- at CREATE, when there is nothing
    # installed to preserve. On every later re-activation it re-derived the
    # installed policy from whatever the active profile renders TODAY, which
    # breaks the project's one-way handoff (PROFILE -> generate once -> CONFIG
    # v4 -> runtime truth): a hand-customized field was silently discarded, and
    # an edited shared profile silently re-pointed an already-installed
    # relationship at different policy.
    #
    # Split, not rewrite: a dataset whose section this client already owns is
    # PRESERVED and only its topology-owned fields are refreshed in place;
    # anything else (first activation, a dataset newly in scope, a section this
    # client does not own) takes the original remove-then-add path unchanged,
    # including its fail-closed refusal of a foreign section.
    #
    # Topology-owned = the fields that are a function of the ENDPOINT rather
    # than of policy, i.e. exactly the two this function computes from
    # LOAD_ACCOUNT/LOAD_HOST/LOAD_FLAGS -- `src` and `flags`. Those are what
    # set-endpoint changes, and they are the reason the unconditional rewrite
    # existed in the first place. `pair_label` and `notify` are NOT rewritten:
    # both are pure functions of $name (the relationship identity, fixed for the
    # life of the client record -- there is no rename command) and $ds (fixed
    # for a dataset that is already in scope; a dataset whose path changed is a
    # different dataset and lands in the regeneration branch above). Rewriting
    # them could therefore only ever write back the identical value, while
    # leaving them alone additionally preserves an operator edit -- so leaving
    # them is both semantically invariant and strictly safer.
    client_section_plan "$workfile" "$name" "$is_new_relationship"
    local -a regen_ds=() regen_paths=() keep_ds=()
    regen_ds=(${PLAN_REGEN_DS[@]+"${PLAN_REGEN_DS[@]}"})
    regen_paths=(${PLAN_REGEN_PATHS[@]+"${PLAN_REGEN_PATHS[@]}"})
    keep_ds=(${PLAN_KEEP_DS[@]+"${PLAN_KEEP_DS[@]}"})
    local prune_needs_gen="$PLAN_PRUNE_NEEDS_GEN"

    # REV-20260810-090 F1: only now, and only if the plan says something must be
    # written from it. A reactivation that preserves everything never touches the
    # profile, so an installed CONFIG keeps working after the profile it was
    # created from is renamed, removed, or edited into something that no longer
    # validates -- which is what "CONFIG v4 is runtime truth" has to mean.
    [ "$PLAN_NEEDS_PROFILE" -eq 1 ] && load_active_profile

    # Remove-then-add for the regenerated set only: that is what makes a re-run
    # after an endpoint switch pick up the new host/port/alias for a dataset
    # that has no installed section yet.
    [ "${#regen_paths[@]}" -gt 0 ] && remove_managed_sections "$workfile" "$name" "${regen_paths[@]}"

    for ds in ${keep_ds[@]+"${keep_ds[@]}"}; do
        localpath=$(client_local_path "$ds")
        update_section_field "$workfile" "[dataset:$localpath]" src "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" \
            || die "[dataset:$localpath] in $workfile has no 'src' field to refresh -- refusing to leave the relationship pointing at an unknown endpoint. Fix or remove that section by hand and re-run."
        # The recorded exclusions ride along, exactly as on the create path a
        # few lines down. Refreshing `flags` from $LOAD_FLAGS alone rewrote the
        # transport options AND silently dropped every -X the relationship was
        # enrolled with -- measured: the re-activation diff removed the line
        # carrying -X and added one without it, and the anti-deletion guard then
        # refused the install because two jobs appeared to be vanishing. A
        # preserved section must come back with everything it had, not with
        # everything this function happens to know about.
        update_section_field "$workfile" "[dataset:$localpath]" flags "$LOAD_FLAGS$(client_exclude_flags)$(client_passive_flags)" \
            || die "[dataset:$localpath] in $workfile has no 'flags' field to refresh -- refusing to leave the relationship carrying stale transport flags. Fix or remove that section by hand and re-run."
        # The link cap is refreshed the same way and for the same reason -- it
        # is a function of the RECORD, not of the installed policy. Unlike
        # 'flags' it may legitimately be absent (no cap), and a cap removed
        # from the record must take the field with it: a refresh that left a
        # stale 'bandwidth' behind would keep throttling a relationship the
        # operator had just uncapped, silently and for good.
        set_or_remove_section_field "$workfile" "[dataset:$localpath]" bandwidth "${LOAD_BANDWIDTH:-}" \
            || die "[dataset:$localpath] in $workfile could not be updated with the relationship's bandwidth setting -- refusing to leave the link cap out of step with the client record. Fix or remove that section by hand and re-run."
    done

    # One minute for this relationship, chosen once here and written into every
    # section it creates -- see schedule_pick_minute. Only for sections being
    # CREATED: a preserved section keeps whatever it already carries.
    local stagger_min stagger_prune stagger_send_expr stagger_prune_expr
    stagger_min=$(schedule_pick_minute "$name")
    stagger_prune=$(( (stagger_min + 20) % 60 ))
    stagger_send_expr=$(schedule_with_minute "$(schedule_template_expr send)" "$stagger_min")
    stagger_prune_expr=$(schedule_with_minute "$(schedule_template_expr prune)" "$stagger_prune")
    # A THIRD SLOT, for the prune that reaches the SOURCE over SSH.
    #
    # 63f69eb spread relationships "across the clock instead of stacking them on
    # one minute", and its own measurement named the cost: "all at :01 and all
    # pruning at :21 ... a thundering herd on the link, the source's disks and
    # sshd". It gave a minute to the send and to the LOCAL prune, and never
    # touched append_source_prune_create -- so the one job class that opens an
    # SSH session to the source, and therefore hits all three of the things that
    # sentence lists, was the one left stacked.
    #
    # Measured on the lab, 2026-08-30, two relationships: sends at :57 and :01,
    # local prunes at :17 and :21, and BOTH source prunes at :21 with the local
    # one -- three jobs, two of them over SSH to different hosts, in one minute.
    # It reproduced identically on a rebuild, so it is deterministic, not luck.
    #
    # +40 keeps the 20-minute gap the profile already had between send and
    # prune, and puts this a further 20 from both: three evenly spaced slots per
    # relationship rather than two and a pile-up.
    local stagger_src stagger_src_prune_expr
    stagger_src=$(( (stagger_min + 40) % 60 ))
    stagger_src_prune_expr=$(schedule_with_minute "$(schedule_template_expr prune)" "$stagger_src")
    # WHEN THE TIERS DISAGREE, SPREAD THEM ONE BY ONE instead of not at all.
    #
    # A section-level send_schedule overrides every tier the section names, so a
    # multi-cadence profile could not be given one -- and got no spreading, which
    # is how two `prod` relationships on pve9 came to fire two seconds apart.
    # gen-cron now resolves both schedules per tier, so each tier keeps its OWN
    # cadence and receives THIS relationship's minute.
    #
    # Built here, once, next to the single-field values, so both paths share
    # schedule_pick_minute's answer and the 20-minute send/prune gap.
    local _tier_sched=""
    if [ -z "$stagger_send_expr" ] || [ -z "$stagger_prune_expr" ]; then
        local _t _e
        while IFS="$(printf '\t')" read -r _t _e; do
            [ -n "$_t" ] && [ -n "$_e" ] || continue
            _tier_sched="$_tier_sched	send_schedule_$_t = $(schedule_with_minute "$_e" "$stagger_min")
"
        done < <([ -z "$stagger_send_expr" ] && schedule_tier_exprs send)
        while IFS="$(printf '\t')" read -r _t _e; do
            [ -n "$_t" ] && [ -n "$_e" ] || continue
            _tier_sched="$_tier_sched	prune_schedule_$_t = $(schedule_with_minute "$_e" "$stagger_prune")
"
        done < <([ -z "$stagger_prune_expr" ] && schedule_tier_exprs prune)
        [ -n "$_tier_sched" ] && log "schedule: spreading this relationship tier by tier (its profile declares several cadences, and one section-level value would have flattened them onto the first)"
    fi

    for ds in ${regen_ds[@]+"${regen_ds[@]}"}; do
        localpath=$(client_local_path "$ds")
        {
            echo
            echo "[dataset:$localpath]"
            echo "	$marker"
            profile_emit "$PROFILE_DS_FILE"
            if sync_ds_is_passive "$ds"; then
                # Dataset-level fields beat the template's (resolve_field), so
                # these four lines are the whole passive shape:
                #   -e            consume the newest EXISTING snapshot;
                #   prefix        the generic family, not one tier's -- the
                #                 owner's newest snapshot is the right one
                #                 whichever tier produced it;
                #   :31 schedule  offset off the owner's :01 -- pulling at the
                #                 same minute as the producer races it and
                #                 reproduces the same-minute bucket collision
                #                 the lab measured;
                #   3h/5h         thresholds sized to the CHAIN's cadence (the
                #                 copy is one hop behind the family's own
                #                 cadence; 90m thresholds would false-alarm on
                #                 a healthy chain -- the threshold-vs-cadence
                #                 lesson, third occurrence on this estate).
                echo "	prefix       = automated_"
                echo "	send_schedule = 31 * * * *"
                echo "	monitor_warn = 3h"
                echo "	monitor_crit = 5h"
                echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
                echo "	flags        = $LOAD_FLAGS -e"
            elif [ "${PASSIVE:-0}" = "1" ]; then
                # DECLARED passive (LAB-E, 2026-08-23) -- distinct from the
                # sync-chain branch above, which detects OUR OWN family: this
                # one is an operator decision recorded at create, works for a
                # FOREIGN family with any name or none, and therefore sets no
                # prefix at all (the passive profile template is prefixless).
                # monitor_exclude mirrors the -E list so the monitor is blind
                # to exactly the families the pickup refuses to adopt --
                # measured both ways in LAB-E: an aging excluded family must
                # not page, a fresh one must not paint a stale relation green.
                [ -n "$stagger_send_expr" ] && echo "	send_schedule = $stagger_send_expr"
                [ -n "$_tier_sched" ] && printf '%s' "$_tier_sched"
                echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
                echo "	flags        = $LOAD_FLAGS$(client_exclude_flags)$(client_passive_flags)"
            else
                [ -n "$stagger_send_expr" ] && echo "	send_schedule = $stagger_send_expr"
                [ -n "$_tier_sched" ] && printf '%s' "$_tier_sched"
                echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
                echo "	flags        = $LOAD_FLAGS$(client_exclude_flags)"
            fi
            # The LINK cap, as its own field rather than a -b hidden in the
            # string above: gen-cron.sh renders the identical token, and a
            # named field is the only form a layer above a hand edit can
            # speak about (it is profile-FORBIDDEN, which is a statement about
            # ownership -- the link belongs to this pair of hosts).
            [ -n "${LOAD_BANDWIDTH:-}" ] && echo "	bandwidth    = $LOAD_BANDWIDTH"
            # A solid scope root rides ENGINE recursion: snapget -R re-expands
            # the subtree on the source at every run, so a child created there
            # tomorrow joins at the next cron tick -- which is what the signed
            # include_children=yes means over time. Dataset-level field, so it
            # wins over any template default. The profile fragment carries no
            # 'recursive' of its own -- since 2026-08-31 because lib-profile.sh
            # refuses one, rather than because the shipped profiles happen not
            # to write it; a custom profile that did made this section carry the
            # field twice and gen-cron refused the whole config.
            # RECURSION comes off the client record (sourced by
            # load_client_and_connection), so re-activation reproduces the shape
            # the operator chose at enrolment instead of resetting it to the
            # default. Empty record = flat, which is what every relationship
            # enrolled before this flag existed carries.
            if is_recursive_root "$ds"; then
                if [ "${RECURSION:-}" = atomic ]; then
                    echo "	recursive    = atomic"
                else
                    echo "	recursive    = flat"
                fi
            fi
            echo "	pair_label   = $name"
            echo "	notify       = ${name}-$(basename "$ds")"
        } >> "$workfile" || return 1
    done

    prune_scope=""
    if [ "${PROFILE_GFS:-1}" -eq 1 ]; then
        if [ "$sync_mode" -eq 1 ]; then
            # REV-20260802-033 slice 8 / U7 required sync mapping: sync has no
            # single parent this client owns to sweep recursively -- each
            # dataset lands at its OWN top-level path, scattered across
            # whatever pools the source scope named. One [prune:] per dataset
            # instead, at exactly the paths already removed above via
            # `managed` -- no separate remove_managed_sections call needed,
            # those ARE the same paths. recursive=no: each entry is already
            # the exact leaf this client's own [dataset:] section writes to,
            # so there is nothing under it for a recursive sweep to find that
            # is not ALSO its own separately listed entry here -- recursive
            # would be the leaf-under-a-recursive-parent race this project
            # already fixed once for delsnaps (prune scope race).
            #
            # REV-20260809-089: a [prune:] section carries NO topology-owned
            # field at all -- it is pure policy plus name-derived labels. So a
            # preserved dataset's prune section needs no in-place refresh
            # either: the correct action on re-activation is to leave it
            # entirely alone. Only the regenerated datasets get one written,
            # and those are exactly the paths remove_managed_sections cleared
            # above (same paths -- sync's local name IS the source name), so
            # no separate removal call is needed here.
            for ds in ${regen_ds[@]+"${regen_ds[@]}"}; do
                {
                    echo
                    echo "[prune:$ds]"
                    echo "	$marker"
                    profile_emit "$PROFILE_PRUNE_FILE"
                    # Mirrors the pull's recursion, same reasoning as
                    # append_source_prune_create: a solid root's children are
                    # pulled by -R at every tick, so their landed snapshots
                    # must be pruned by -R at every tick too.
                    if is_recursive_root "$ds"; then
                        echo "	recursive    = yes"
                    else
                        echo "	recursive    = no"
                    fi
                    echo "	pair_label   = $name"
                    echo "	notify       = ${name}-$(basename "$ds")"
                } >> "$workfile" || return 1
            done
            prune_scope="$PLAN_PRUNE_SCOPE"
        else
            # One ladder for the whole client. gfs_pattern is 'automated_'
            # rather than any tier's own narrower pattern, because the ladder
            # has to see every snapshot it is bucketing. Recursive over the
            # client's subtree is safe here: every dataset of a client
            # carries the same single send tier, so a recursive sweep cannot
            # hit the "this leaf only has some of these tiers" trap that
            # forces per-leaf monitor carriers elsewhere in this estate.
            #
            # REV-20260809-089: the ladder carries no topology-owned field, and
            # it is ONE recursive section over the client's whole subtree -- a
            # dataset newly in scope lands under it without the section needing
            # to change. So on re-activation an already-owned ladder is left
            # untouched, not removed and re-derived from today's profile.
            prune_scope="$PLAN_PRUNE_SCOPE"
            if [ "$prune_needs_gen" -eq 1 ]; then
                remove_managed_sections "$workfile" "$name" "$prune_scope"
                {
                    echo
                    echo "[prune:$prune_scope]"
                    echo "	$marker"
                    profile_emit "$PROFILE_PRUNE_FILE"
                    # Declared-passive: the copy-side monitor rides these
                    # tiers, and it must be blind to exactly the families the
                    # pickup refuses to adopt (-E list), or an excluded family
                    # arriving by other means keeps a dead relation green.
                    if [ "${PASSIVE:-0}" = "1" ]; then
                        local _pex; _pex=$(client_passive_flags | awk '{for(i=1;i<=NF;i++) if ($i=="-E") printf "%s%s", (n++?",":""), $(i+1)}')
                        [ -n "$_pex" ] && echo "	monitor_exclude = $_pex"
                    fi
                    # Same stagger as the send side, keeping the 20-minute
                    # gap the profile had between them. A prune that wraps
                    # past the hour is fine: it deletes by age and keep-count,
                    # not by "did a backup just run".
                    [ -n "$stagger_prune_expr" ] && echo "	prune_schedule = $stagger_prune_expr"
                    echo "	recursive    = yes"
                    echo "	pair_label   = $name"
                    echo "	notify       = ${name}"
                } >> "$workfile" || return 1
            fi
        fi
    fi

    # REV-20260811-102 step 3: bound the REMOTE source's tool-owned automated_
    # snapshots too, over the same pinned SSH, with the INDEPENDENT source family.
    # FULLY regenerated for EVERY source dataset (not just the ones whose target
    # section regenerated): the source scope embeds the endpoint, so it must move
    # with an endpoint switch the way `src` does. The flow then grant-checks
    # exactly the emitted datasets before publishing. Covers sync and backup alike
    # -- the remote source path is `ds` in either mode.
    # Passive datasets are EXCLUDED from remote source retention by definition:
    # this client does not own that family, so it does not prune it. The lab
    # measured the alternative -- link B's src-src prune fighting link A's own
    # retention over the same middle dataset.
    local -a prune_src=()
    for ds in ${PEER_SAVED_DATASETS:-}; do
        sync_ds_is_passive "$ds" || prune_src+=("$ds")
    done
    # Atomic declines source retention -- decided at enrolment, recorded, and
    # honoured here rather than left for assert_no_atomic_with_source_retention
    # to refuse after the fact. That guard STAYS: it reads the candidate config,
    # so it still catches a hand-edited 'recursive = atomic' arriving next to a
    # source prune from anywhere else.
    if [ "${PASSIVE:-0}" = "1" ]; then
        log "source retention NOT generated for '$name': the relationship is DECLARED PASSIVE -- every source snapshot belongs to the foreign system that stamped it, and pruning another owner's family is how the sync chain destroyed one in 80 minutes. The copy-side ladder still bounds OUR disk."
    elif [ "${RECURSION:-}" = atomic ]; then
        log "source retention NOT generated for '$name': atomic recursion keeps no bookmark, so a managed source prune could age out the only anchor this relationship has (target retention is unaffected)"
    else
        emit_remote_source_prune "$workfile" "$name" "$marker" --schedule="$stagger_src_prune_expr" ${prune_src[@]+"${prune_src[@]}"} || return 1
    fi
    return 0
}

# snapget.sh's SECOND argument is the local BASE, not the final dataset: it
# appends the source's own dataset path underneath it (the pull addressing flip,
# snapget v2.61 -- arg1 is the literal remote host:name, arg2 mirrors snapsend's
# target base). gen-cron.sh gets this right, deriving the base by stripping the
# source path off a [dataset:] section. This wrapper did not, and passed the
# FINAL path as the base -- so seed, verify-endpoint and test all wrote and read
# one level too deep.
#
# Found on live hosts 2026-08-01: seed landed 40MB at
#   .../uxtest/<label>/hdd/backuptest_targets/uxsrc/hdd/backuptest_targets/uxsrc
# while the generated cron job targeted
#   .../uxtest/<label>/hdd/backuptest_targets/uxsrc
# so the seeded copy was invisible to the job that was supposed to continue it:
# PLAN=INCREMENTAL base=null, i.e. a full transfer on every run, forever, with
# verify-endpoint reporting "incremental confirmed" because it looked in the
# same wrong place as the seed.
# REV-20260802-033 slice 8 / ENROLMENT-AGREED-2026-08-02 U7 "required sync
# mapping": backup keeps the namespaced base above; sync carries NO base at
# all -- the local name is IDENTICAL to the remote one (this is snapget.sh's
# own documented convention for an omitted LOCAL_BASE, "sync: identical local
# name" -- not a new mechanism, just the first caller to actually select it).
# Every command below (seed, final-catchup, verify-endpoint, activate-client,
# test, emit_client_sections) goes through these two rather than branching on
# PEER_SAVED_MODE itself, so the mapping is decided in exactly one place.
snapget_local_base() {
    [ "${PEER_SAVED_MODE:-}" = sync ] && { printf ''; return 0; }
    printf '%s' "$PEER_SAVED_TARGET/$LOAD_LABEL"
}
client_local_path() {   # <source dataset> -> where it lands locally
    local ds="$1" base; base=$(snapget_local_base)
    if [ -n "$base" ]; then printf '%s/%s' "$base" "$ds"; else printf '%s' "$ds"; fi
}

# Which crontab, and whose paths.
#
# When the collector runs its jobs as a dedicated account, three things move
# together and getting one of them wrong is silent: the crontab the block is
# installed into, the alert/log paths the generated lines reference, and the
# identity gen-cron.sh itself runs as. They are kept in one place here so they
# cannot drift apart.
#
# The digest is deliberately NOT duplicated to the account: deploy.sh gives it
# notify-fail.sh and notify-warn.sh but not alert-digest.sh, precisely so root
# stays the only sender of the daily mail. digest_script=none is how that block
# opts out.
cron_target_user() { printf '%s' "${LOCAL_USER:-root}"; }

# The ONE grammar for --local-user, because three commands ask the same question
# and were each answering it with their own copy of this case statement --
# setup-server, add-client and (from 2026-08-21) local-backup. Three copies
# differing only in the prefix on the error is how they drift: the third was
# written by copying the second, which is also how local-backup inherited a
# missing LOCAL_USER restore that the second happened to have.
#
# `root` is a legal answer meaning "root runs them", not an account to create,
# so it is accepted here and the CALLER decides what that means for it.
local_user_name_valid() {   # <name> -> 0 valid (incl. 'root'), 1 not
    case "${1-}" in
        root) return 0 ;;
        *[!a-z0-9_-]* | "" | [!a-z_]*) return 1 ;;
    esac
    return 0
}
LOCAL_USER_GRAMMAR="lowercase letters, digits, _ and -, not starting with a digit"

# The receive-side delegation set. Mirrors deploy.sh's ZFS_PERMS (what --pair
# grants on a backup-mode target root) -- kept in step by test/zfsbackup's
# parity pin, not by sourcing deploy.sh (no source edge, see deps.conf).
ZFS_PERMS_LOCAL_RECEIVE="snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark"

# The default cron-config location for THIS host, used only when nothing has
# recorded one yet (no server.conf CRON_CONFIG, no client record, no installed
# managed block to read a Source line from). /etc/zfs-snapshot-all is the
# fleet's convention and is readable by the delegated account.
#
# It used to be $SCRIPT_DIR/jobs.<host>.conf, which fails twice over: on a
# Proxmox host $SCRIPT_DIR is under /root (0700 -- the account cannot read it;
# found live on metropolis pve1, 2026-08-01), and it puts operator state INSIDE
# the git checkout that hourly self-updates (found live 2026-08-17, lab3: a
# fresh RUX install wrote its config next to the code it came from).
# LAB6-F2 (2026-08-21): the default names the ACCOUNT, not just the host.
# A config belongs to an account+relationship, and the host-wide default was
# the second half of P10 still latent on the CREATION path: activating a
# bkpsvc relationship on a host whose root already ran one resolved to the
# SAME jobs.<host>.conf -- merge the sections and the next regeneration for
# EITHER account renders BOTH relationships into its crontab. Root keeps the
# historical bare name; every other account gets its own file. Fleet legacy
# (zfsbackup's v4 configs) is untouched: recorded values win over any default.
default_cron_config() {
    local u h
    u=$(cron_target_user)
    h=$(hostname -s 2>/dev/null || hostname)
    if [ "$u" = root ]; then
        echo "/etc/zfs-snapshot-all/jobs.$h.conf"
    else
        echo "/etc/zfs-snapshot-all/jobs.$h.$u.conf"
    fi
}

# --- SCHEDULE STAGGER ------------------------------------------------------
# Relationships created from the same profile inherit the same literal
# send_schedule, so every one of them fires in the SAME minute. Measured in
# the pve1>pve9 campaign: three relationships, two accounts, two different
# source hosts -- all at :01, all prune at :21. At fleet scale that is a
# thundering herd on the link, on the source's disks and on sshd (MaxStartups
# refuses connections, which looks like a network fault). The owner named it
# before the lab did.
#
# The minute is chosen ONCE, at create, and written into the section as a
# real send_schedule -- so the config keeps telling the truth about when the
# job runs, an operator can overwrite it by hand, and a re-activation never
# re-rolls it (a preserved section is untouchable, same rule as the profile).
#
# GLOBAL by owner decision: the collector's disks and CPU are shared by every
# relationship regardless of which source it pulls from, so the spread is
# computed across the whole host, not per source.
#
# Honest boundary: this can only avoid the minutes it can SEE -- the managed
# blocks of the accounts cron_known_accounts finds, plus the sections of the
# configs. A relationship installed in a crontab this host cannot enumerate
# stays invisible and may still collide. Same assumption the coverage guard
# already makes; stated rather than hidden.
# Every minute a cron MINUTE FIELD actually fires in. The first cut kept only
# fields matching ^[0-9]+$, so a perfectly valid `*/15` job was invisible to
# the collision check and a relationship hashing to 15 was placed straight on
# top of it (review finding, reproduced). Cron's minute grammar is small and
# entirely expandable, so expand it instead of ignoring what is not a literal.
schedule_expand_minutes() {   # <cron minute field> -> one minute per line
    local field="$1" part base step lo hi m
    [ -n "$field" ] || return 0
    # Split on newlines from tr, NOT `for part in $field` with IFS=,: an
    # unquoted '*' there is glob-expanded into filenames, so the commonest
    # wildcard silently produced nothing. Caught by the expander's own test.
    while IFS= read -r part; do
        [ -n "$part" ] || continue
        step=1
        case "$part" in *"/"*) step="${part##*/}"; base="${part%%/*}" ;; *) base="$part" ;; esac
        case "$step" in ''|*[!0-9]*) continue ;; esac
        [ "$step" -ge 1 ] 2>/dev/null || continue
        case "$base" in
            '*')     lo=0;  hi=59 ;;
            *-*)     lo="${base%%-*}"; hi="${base##*-}" ;;
            *)       lo="$base"; hi="$base" ;;
        esac
        case "$lo$hi" in ''|*[!0-9]*) continue ;; esac
        [ "$lo" -le "$hi" ] 2>/dev/null || continue
        [ "$hi" -le 59 ] 2>/dev/null || hi=59
        m="$lo"
        while [ "$m" -le "$hi" ]; do
            printf '%s
' "$m"
            m=$((m + step))
        done
    done <<< "$(printf '%s' "$field" | tr ',' '
')"
}

schedule_taken_minutes() {   # -> one minute per line, already-used send minutes
    local u tmp f _sched
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        tmp=$(mktemp) || continue
        if cron_read "$u" "$tmp"; then
            # First field of any line that actually runs a transfer engine.
            while IFS= read -r _sched; do
                [ -n "$_sched" ] && schedule_expand_minutes "$_sched"
            done < <(grep -E '(snapget|snapsend)\.sh' "$tmp" 2>/dev/null | awk '{print $1}')
        fi
        rm -f "$tmp"
    done < <(cron_known_accounts)
    # Sections that exist but are not installed yet.
    for f in /etc/zfs-snapshot-all/jobs.*.conf; do
        [ -r "$f" ] || continue
        while IFS= read -r _sched; do
            [ -n "$_sched" ] && schedule_expand_minutes "$_sched"
        done < <(sed -n -E 's/^[[:space:]]*send_schedule[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]].*//p' "$f" 2>/dev/null)
    done
}

# Deterministic start point, then the first free minute upwards. cksum, not
# $RANDOM: the same relationship must land on the same minute on every host
# and on every re-read, or the crontab diff becomes noise.
# The template's own cadence, with ONLY the minute field replaced. Writing a
# bare "M * * * *" would have silently converted a daily or weekly profile
# (e.g. "0 3 * * *") into an hourly one -- caught by the suite's assertion that
# a profile's cadence reaches the rendered cron. The spread is about WHICH
# minute inside the tier's own rhythm, never about the rhythm itself.
schedule_with_minute() {   # <cron expression> <minute> -> expression with field 1 replaced
    local expr="$1" min="$2"
    # NO expression means we do not know this profile's cadence -- either it
    # declares none, or its tiers disagree (see schedule_template_expr). Emit
    # nothing rather than inventing an hourly one: a section field overrides
    # every tier, so a guess here would rewrite the operator's policy.
    [ -n "$expr" ] || return 0
    printf '%s %s' "$min" "$(printf '%s' "$expr" | awk '{$1=""; sub(/^ /,""); print}')"
}

# The send/prune cadence this relationship's profile actually declares, read
# from the tier its dataset fragment references (use_template). Empty when the
# profile is not loaded -- the caller then keeps the hourly default, which is
# what every built-in profile uses.
# The same walk as schedule_template_expr, but WITHOUT the collapse: one line
# per referenced tier that declares the field, as "<tier><TAB><expression>".
#
# schedule_template_expr answers "is there ONE cadence here" and returns nothing
# when the tiers disagree -- correct, because a section-level field overrides
# every tier it names, so one value would flatten daily/weekly/monthly onto the
# hourly cadence. The consequence was that a multi-cadence profile got no
# spreading at all: measured on pve9, two `prod` relationships fired two seconds
# apart in the same minute, and a dozen would be the thundering herd the
# spreader exists to prevent.
#
# gen-cron resolves send_schedule/prune_schedule per tier as of 2026-08-26
# (resolve_field_tiered, the same helper `flags` has always used), so each tier
# can carry its own staggered minute at its own cadence. Nothing is collapsed
# and nothing is left unspread.
schedule_tier_exprs() {   # <send|prune> -> "<tier>\t<cron expression>" per tier
    local which="$1" frag tpl field one sect expr
    case "$which" in
        send)  frag="$PROFILE_DS_FILE";    field=send_schedule ;;
        prune) frag="$PROFILE_PRUNE_FILE"; field=prune_schedule ;;
        *) return 0 ;;
    esac
    # A flat profile prunes from the tiers its [dataset] references, so its
    # prune fragment is empty and the dataset one carries both halves.
    [ "$which" = prune ] && [ ! -s "${frag:-}" ] && frag="$PROFILE_DS_FILE"
    [ -n "${PROFILE_LOADED:-}" ] && [ -r "${frag:-}" ] || return 0
    tpl=$(awk -F= '/^[[:space:]]*use_template[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$frag")
    [ -n "$tpl" ] || return 0
    for one in ${tpl//,/ }; do
        [ -n "$one" ] || continue
        # PROFILE_ACTIVE can be a PATH: cmd_migrate_profile sets it from
        # --profile=, which accepts one, and the client record it then writes
        # carries that same string for load_client_profile to read back. So
        # this had the REV-20260827-122 F1 defect too, one site further on --
        # it would build [template:profile__/tmp/mine.conf__hourly], find
        # nothing, and `continue`. The comment above records what an empty
        # answer here costs: no stagger at all, which a two-source lab caught
        # in its first minute. Canonicalised at the point of use, the same way
        # the renderer and the migration removal loop derive it.
        case "$one" in
            profile__*) sect="$one" ;;
            *)          sect="profile__$(profile_name_of "$PROFILE_ACTIVE")__${one}" ;;
        esac
        expr=$(profile_template_section "$sect" 2>/dev/null | awk -F= -v f="$field" '$0 ~ "^[[:space:]]*"f"[[:space:]]*=" {sub(/^[[:space:]]*/,"",$2); sub(/[[:space:]]*$/,"",$2); print $2; exit}')
        [ -n "$expr" ] || continue
        printf '%s\t%s\n' "$sect" "$expr"
    done
}

schedule_template_expr() {   # <send|prune> -> the tier's cron expression, or nothing
    local which="$1" frag tpl field
    case "$which" in
        send)  frag="$PROFILE_DS_FILE";    field=send_schedule ;;
        prune) frag="$PROFILE_PRUNE_FILE"; field=prune_schedule ;;
        *) return 0 ;;
    esac
    [ -n "${PROFILE_LOADED:-}" ] && [ -r "${frag:-}" ] || return 0
    tpl=$(awk -F= '/^[[:space:]]*use_template[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$frag")
    [ -n "$tpl" ] || return 0
    # use_template is a LIST, and a field written into the SECTION overrides
    # EVERY tier it references (gen-cron). So the stagger may only touch this
    # field when all referenced tiers already declare the SAME cadence for it
    # -- otherwise writing one value would collapse a daily or weekly tier onto
    # the hourly one. Measured by review on a two-tier profile: daily
    # "2 3 * * *" became "17 * * * *". The built-in profiles all declare one
    # cadence per field, which is why the lab never showed it.
    local one first="" expr="" sect=""
    for one in ${tpl//,/ }; do
        [ -n "$one" ] || continue
        # The RENDERED fragment already carries the namespaced name
        # (profile_render_fragment writes `use_template = profile__P__tier`),
        # so prefixing again looked for profile__P__profile__P__tier and found
        # NOTHING -- every call returned empty. #148 hid that behind a default
        # hourly cadence; #149 turned it into "emit nothing", i.e. no stagger
        # at all. The two-source lab caught it in its first minute: both
        # relationships landed on the template's own :01. Accept both forms.
        # PROFILE_ACTIVE can be a PATH: cmd_migrate_profile sets it from
        # --profile=, which accepts one, and the client record it then writes
        # carries that same string for load_client_profile to read back. So
        # this had the REV-20260827-122 F1 defect too, one site further on --
        # it would build [template:profile__/tmp/mine.conf__hourly], find
        # nothing, and `continue`. The comment above records what an empty
        # answer here costs: no stagger at all, which a two-source lab caught
        # in its first minute. Canonicalised at the point of use, the same way
        # the renderer and the migration removal loop derive it.
        case "$one" in
            profile__*) sect="$one" ;;
            *)          sect="profile__$(profile_name_of "$PROFILE_ACTIVE")__${one}" ;;
        esac
        expr=$(profile_template_section "$sect" 2>/dev/null           | awk -F= -v f="$field" '$0 ~ "^[[:space:]]*"f"[[:space:]]*=" {sub(/^[[:space:]]*/,"",$2); sub(/[[:space:]]*$/,"",$2); print $2; exit}')
        # A tier that does not declare the field at all does not constrain it.
        [ -n "$expr" ] || continue
        if [ -z "$first" ]; then
            first="$expr"
        elif [ "$expr" != "$first" ]; then
            # >&2, NOT log's stdout: this function is CAPTURED by the caller
            # ( expr=$(schedule_template_expr send) ), so a diagnostic on
            # stdout BECOMES the value and is written into the config as
            # `send_schedule = 17 schedule: '...' differs ...`. The "leave it
            # to the profile" path would then emit invalid policy -- the exact
            # failure it exists to avoid. Same family as `die` inside $().
            log "schedule: '$field' differs between the tiers this profile references -- leaving it to the profile rather than collapsing them onto one cadence" >&2
            return 0
        fi
    done
    printf '%s' "$first"
}

schedule_pick_minute() {   # <relationship name> -> minute 0-59
    local name="$1" start taken probe i
    start=$(printf '%s' "$name" | cksum 2>/dev/null | awk '{print $1 % 60}')
    case "$start" in ''|*[!0-9]*) start=0 ;; esac
    taken=" $(schedule_taken_minutes | sort -un | tr '
' ' ') "
    for i in $(seq 0 59); do
        probe=$(( (start + i) % 60 ))
        case "$taken" in
            *" $probe "*) continue ;;
            *) printf '%s' "$probe"; return 0 ;;
        esac
    done
    # Every minute of the hour is already used. Grouping is unavoidable now,
    # so say so instead of pretending the spread worked.
    # >&2 for the same reason as above: the caller captures this function, so
    # a diagnostic on stdout would be returned as the MINUTE.
    log "schedule: all 60 minutes on this host already carry a transfer job -- '$name' shares minute $start" >&2
    printf '%s' "$start"
}

# `crontab -l` for whoever owns the jobs. Root can read another account's
# crontab with -u; as that account itself, -u is refused, so it is only added
# when it is actually needed.
crontab_for_target() {   # -> the target user's crontab on stdout
    local u tmp; u=$(cron_target_user)
    tmp=$(mktemp) || return 1
    if ! cron_read "$u" "$tmp"; then rm -f "$tmp"; return 1; fi
    cat "$tmp"; rm -f "$tmp"
}

# The '# Source:' path of the managed block installed in ONE account's crontab,
# or nothing if that account has no managed block. Uses cron_read directly
# rather than crontab_for_target, which resolves the account from LOCAL_USER --
# here the account is the question, not a global to be borrowed.
cron_source_for_user() {   # <account> -> its managed block's config path, or nothing
    local u="$1" tmp src
    tmp=$(mktemp) || return 1
    if ! cron_read "$u" "$tmp"; then rm -f "$tmp"; return 1; fi
    src=$(grep -m1 '^# Source: ' "$tmp" | sed -E 's/^# Source: (.*) -- .*/\1/')
    rm -f "$tmp"
    [ -n "$src" ] || return 1
    normalize_cron_source "$src"
}

# Every account this host might be running managed jobs as. CANDIDATES only --
# the caller decides membership by asking cron_source_for_user whether each one
# actually carries a managed block.
#
# Three sources, and the third was learned the hard way. Live on pve2,
# 2026-08-21, the first version of this returned root alone and the P10 refusal
# did not fire on the very host it was measured against:
#
#   * root, always;
#   * every account named by one of OUR OWN records (clients/, peers/);
#   * every account that HAS A CRONTAB.
#
# The first version stopped after the second bullet, reasoning that an account
# exists for reasons unrelated to this project and treating one as ours because
# it has a home directory is a local fact standing in for a decision. That
# reasoning is still right, and it is still why /home and passwd are not read.
# What it got wrong is the premise: it assumed every account running our jobs
# got there through a RELATIONSHIP. Production on this fleet did not. Those are
# plain local jobs in an account's crontab, older than the relationship model,
# and no record of ours has ever named them -- so the check looked past the
# exact thing it existed to find.
#
# The crontab spool is not an account enumeration in the sense that was
# rejected. It answers "who has a crontab", and the caller then filters on OUR
# OWN block marker, so an unrelated account cannot be claimed by this: it would
# have to be running a block we wrote.
cron_known_accounts() {   # -> one candidate per line, root first, deduplicated
    local f u
    {
        echo root
        for f in "$CLIENTS_DIR"/*.conf; do
            [ -r "$f" ] || continue
            u=$( . "$f" >/dev/null 2>&1; printf '%s' "${LOCAL_USER:-}" )
            [ -n "$u" ] && echo "$u"
        done
        for f in "$PEER_STATE_DIR"/*.conf; do
            [ -r "$f" ] || continue
            u=$( . "$f" >/dev/null 2>&1; printf '%s' "${PEER_SAVED_LOCAL_USER:-}" )
            [ -n "$u" ] && echo "$u"
        done
        # Debian/Proxmox spool first, then the RHEL layout. A name here is a
        # candidate and nothing more.
        local d
        for d in "${CRON_SPOOL_DIRS[@]}"; do
            [ -d "$d" ] || continue
            for f in "$d"/*; do
                [ -f "$f" ] || continue
                echo "${f##*/}"
            done
        done
    } 2>/dev/null | awk 'NF && !seen[$0]++'
}

# ------------------------------------------------------------------------------
# THE decision layer: WHICH cron config, and AS WHICH account.
#
# The crontab has one writer -- gen-cron.sh --install -- and that writer owns
# the lock and the validation, so none of its 18 requesters can diverge on
# either: they have no way to touch them. The config has no such owner.
# atomic_replace_and_install is an ENDING, not an owner; five commands each ran
# their own read-modify-write and, above it, their own answer to these two
# questions. Five answers, nothing comparing them, each locally sensible.
#
# What that cost, measured 2026-08-20/21:
#   * read_server_conf cleared LOCAL_USER, a field server.conf never carries.
#     Two of the five saved and restored it around the call; the third copied
#     the shape without the restore and shipped a --local-user that parsed, set
#     the variable, and lost it a hundred lines later, past a green CI.
#   * Two of the five resolve the config without the '# Source:' adoption step
#     and accept no flag to aim them, so on a host carrying two relationships
#     they silently operate on whichever one owns the default NAME (P10).
#
# Neither is a coding mistake. Both are what happens when a decision has five
# homes: a divergence is invisible until a host disagrees with it.
#
# So this function is the one home. It does not remove the differences between
# the commands -- those are real -- it makes them an ARGUMENT, visible side by
# side, instead of 2500 lines apart.
#
# Sets: CRON_CTX_FILE, CRON_CTX_USER, CRON_CTX_WHY_FILE, CRON_CTX_WHY_USER.
# Also assigns LOCAL_USER, because cron_target_user is what every crontab
# helper turns on and it reads exactly that.
#
# Policies -- what a caller may fall back to when nothing recorded a config:
#
#   record   Only a recorded value counts; an empty answer is left empty.
#            That emptiness MEANS "this relationship was never activated" and
#            remove-client reads it that way. Inventing a default there would
#            have it clean up a config it was never installed from.
#   aim      HOST-scoped commands only (migrate-profile, audit-source-
#            retention). Like adopt, but when nothing names an account it may
#            look at which accounts carry OUR managed blocks: one -> aim at
#            it, two -> refuse and name both. A relationship command must
#            NEVER use this policy -- for a relationship, "nobody named an
#            account" IS the answer (root), and inheriting one from whatever
#            else the host runs is how LAB6 R1 landed in production's crontab
#            (2026-08-21, reverted live).
#   adopt    recorded -> server.conf -> the '# Source:' line of the block
#            ALREADY INSTALLED in this account's crontab -> the host default.
#            Adoption is not a nicety: a crontab has ONE managed block, so
#            installing from a freshly-defaulted path DELETES every job the
#            installed file describes. The 2026-07-30 incident guard caught
#            exactly that and refused; adopting makes the refusal unnecessary.
#
# There used to be a third, 'host': recorded -> server.conf -> host default, no
# adoption. Three callers used it and none of them meant to -- it was not a
# decision, it was the absence of one, and it is what P10 measured. It is gone;
# what it encoded is now either an adoption or an explicit refusal to guess.
cron_context_resolve() {   # <policy> <explicit-config> <explicit-user> <recorded-config> <recorded-user>
    local policy="${1:?cron_context_resolve: policy is required}"
    local x_config="${2-}" x_user="${3-}" r_config="${4-}" r_user="${5-}"
    case "$policy" in
        record|adopt|aim) ;;
        *) die "cron_context_resolve: unknown policy '$policy' (record|adopt|aim)" ;;
    esac

    # The ACCOUNT first, and the order is load-bearing: the adoption step below
    # reads THIS account's crontab. Resolve it second and adoption would read
    # root's while installing into the account's -- which is the 2026-08-01
    # metropolis failure, where teardown looked at root's block while the
    # client's lines were in the account's.
    if [ -n "$x_user" ]; then
        # A literal "root" is an ANSWER, not an absence. Internally root is the
        # empty string (cron_target_user's own convention), but the two must
        # stay distinguishable up to this point or the ambiguity refusal below
        # rejects the very flag it tells the operator to use.
        CRON_CTX_USER="$x_user"
        [ "$x_user" = root ] && CRON_CTX_USER=""
        CRON_CTX_WHY_USER="named on the command line"
    elif [ -n "$r_user" ]; then
        CRON_CTX_USER="$r_user";  CRON_CTX_WHY_USER="recorded with the relationship"
        # Same normalization as the command-line branch above: 'root' is an
        # answer ("root runs them"), not an account name to delegate to.
        [ "$r_user" = root ] && CRON_CTX_USER=""
    elif [ -n "${PEER_SAVED_LOCAL_USER:-}" ]; then
        CRON_CTX_USER="$PEER_SAVED_LOCAL_USER"
        CRON_CTX_WHY_USER="the pairing manifest (the record predates the field)"
    else
        CRON_CTX_USER="";         CRON_CTX_WHY_USER="nothing recorded an account -- root"
    fi
    # Never from server.conf. The account is a fact of the RELATIONSHIP, and
    # setup-server deliberately records none; see cmd_setup_server.
    LOCAL_USER="$CRON_CTX_USER"

    CRON_CTX_FILE=""; CRON_CTX_WHY_FILE=""
    if [ -n "$x_config" ]; then
        CRON_CTX_FILE="$x_config"; CRON_CTX_WHY_FILE="named on the command line"
    elif [ -n "$r_config" ]; then
        CRON_CTX_FILE="$r_config"; CRON_CTX_WHY_FILE="recorded with the relationship"
    elif [ -n "${CRON_CONFIG:-}" ]; then
        CRON_CTX_FILE="$CRON_CONFIG"; CRON_CTX_WHY_FILE="server.conf"
    fi
    [ "$policy" = record ] && return 0
    if [ -n "$CRON_CTX_FILE" ]; then
        cron_context_assert_file_owner
        return 0
    fi

    # P10 -- and ONLY for policy 'aim'. This block guesses or refuses by what
    # the HOST is running, and that is the right question for exactly two
    # commands: migrate-profile and audit-source-retention, which operate on
    # "whatever is installed here" and need aiming when two things are.
    #
    # It is the WRONG question for a relationship command, and that was
    # measured the expensive way (LAB6 R1, 2026-08-21, live on pve1): a fresh
    # enrolment with no --local-user means ROOT -- but root had no managed
    # block after the lab teardown, production's zfsbackup was the "only
    # account with managed jobs", and this branch ADOPTED it. The lab's cron
    # lines landed in the PRODUCTION account's crontab and its v4 config,
    # with root-owned key paths that would have failed at :01. Reverted in
    # minutes; remove-client took out exactly its own lines.
    #
    # The distinction, stated once: for a relationship, "nobody named an
    # account" IS the answer (root) -- the relationship carries its own
    # identity and must never inherit one from whatever else the host runs.
    # For a host-scoped command, "nobody named an account" is a QUESTION, and
    # the host's installed blocks are the legitimate place to look for the
    # answer. One resolver, two policies, and the guessing branch is fenced
    # to the policy whose question it answers.
    if [ "$policy" = aim ] \
       && [ -z "$x_user" ] && [ -z "$r_user" ] && [ -z "${PEER_SAVED_LOCAL_USER:-}" ]; then
        local -a installed=()
        local acct asrc
        while IFS= read -r acct; do
            asrc=$(cron_source_for_user "$acct") || continue
            installed+=("$acct=$asrc")
        done < <(cron_known_accounts)
        if [ "${#installed[@]}" -gt 1 ]; then
            die "this host runs managed jobs as more than one account, and nothing in this command says which one you mean:
$(printf '    %s\n' "${installed[@]}")
Each account has its own crontab and its own config, so picking for you would
mean silently operating on one relationship while reporting on the host. Name
the one you mean:
    --local-user=<account>      (use root's own jobs with --local-user=root)
    --config=<path>             (if you would rather name the file directly)
Nothing was read and nothing was changed."
        fi
        if [ "${#installed[@]}" -eq 1 ]; then
            CRON_CTX_USER="${installed[0]%%=*}"
            [ "$CRON_CTX_USER" = root ] && CRON_CTX_USER=""
            LOCAL_USER="$CRON_CTX_USER"
            CRON_CTX_WHY_USER="the only account on this host with managed jobs"
            CRON_CTX_FILE="${installed[0]#*=}"
            CRON_CTX_WHY_FILE="adopted from the managed block already installed in ${CRON_CTX_USER:-root}'s crontab"
            return 0
        fi
    fi

    local src
    if src=$(cron_source_for_user "$(cron_target_user)"); then
        CRON_CTX_FILE="$src"
        CRON_CTX_WHY_FILE="adopted from the managed block already installed in ${CRON_CTX_USER:-root}'s crontab"
        return 0
    fi
    CRON_CTX_FILE="$(default_cron_config)"
    CRON_CTX_WHY_FILE="the account default -- nothing had recorded a config"
    # The default is account-scoped now, so a collision here means somebody
    # hand-drove another account's block from this account's default name --
    # unlikely, but the invariant is cheap to hold everywhere it can break.
    cron_context_assert_file_owner
}

# Run gen-cron.sh as the account that owns the jobs, with ITS paths. Running it
# as root and redirecting would install into root's crontab instead -- gen-cron
# writes to "this user's" crontab by design.
gencron_as_target() {   # <args...>
    local u; u=$(cron_target_user)
    if [ "$u" = root ]; then
        bash "$GENCRON" "$@"
        return $?
    fi
    local home; home=$(getent passwd "$u" | cut -d: -f6)
    [ -n "$home" ] || { warn "no home directory for '$u' -- cannot resolve its alert paths"; return 1; }

    # The ACCOUNT'S OWN checkout, not root's. /root is 0700 on a Proxmox host,
    # so a delegated account cannot read /root/scripts/zfs-snapshot-all at all
    # -- not gen-cron.sh, and not the snapget.sh/delsnaps.sh the generated cron
    # lines would name. deploy.sh --backup-user already provisions
    # $HOME/zfs-snapshot-all for exactly this reason and the hourly pull keeps
    # it current; running the account's copy also makes gen-cron bake the
    # account's own paths into the lines it emits, since it derives REPO_DIR
    # from where it lives.
    #
    # Found live on metropolis pve1, 2026-08-01: the install failed here, after
    # the preview had been accepted, and only the crontab rollback kept it from
    # being a mess.
    local account_gencron="$home/zfs-snapshot-all/gen-cron.sh"
    if ! runuser_test_r "$u" "$account_gencron"; then
        warn "'$u' has no readable $account_gencron -- a delegated account cannot use root's copy (/root is 0700), so it needs its own checkout. Run: deploy.sh --backup-user=$u"
        return 1
    fi

    # argv is PASSED, never re-assembled into a shell string (REV-20260801-017
    # F1). The previous version built `su -c "... $*"`, which hands the target
    # account's shell a sentence to re-parse: a config path containing a space
    # would arrive as two arguments. A high-level wrapper must not rest its
    # correctness -- let alone its safety -- on an undocumented "our paths never
    # contain spaces" assumption, and the preview would then have validated a
    # different file from the one installed.
    # REPO_DIR is pinned for the same reason as the other four, and its absence
    # here is what broke metropolis pve2 (2026-08-01). gen-cron.sh normally
    # DERIVES it from where it lives -- the account's own checkout, which is
    # right -- but a config carrying an explicit `[defaults] repo_dir` beats the
    # derivation, and a config rebuilt from root's crontab carries root's path
    # by definition. Environment beats config in gen-cron.sh, so pinning it here
    # makes the account's block name the account's scripts whatever the config
    # says.
    local -a envv=(
        "REPO_DIR=$home/zfs-snapshot-all"
        "NOTIFY_SCRIPT=$home/notify-fail.sh"
        "WARN_SCRIPT=$home/notify-warn.sh"
        "DIGEST_SCRIPT=none"
        "CRON_LOG=$home/cron.log"
        "GEN_CRON_LOCKFILE=$home/.gen-cron.install.lock"
    )
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$u" -- env "${envv[@]}" bash "$account_gencron" "$@"
    else
        # su has no argv-passing form, so every argument is quoted explicitly.
        # printf %q is the only thing standing between this and the defect
        # above; it is not an optimisation and must not be "simplified" away.
        local cmd; cmd=$(printf '%q ' env "${envv[@]}" bash "$account_gencron" "$@")
        su -s /bin/bash "$u" -c "$cmd"
    fi
}

# `test -r` AS the account. Modes alone cannot answer it: group membership,
# ACLs and every parent directory on the path all get a vote.
runuser_test_r() {   # <user> <path>
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$1" -- test -r "$2"
    else
        su -s /bin/bash "$1" -c "$(printf '%q ' test -r "$2")"
    fi
}

# E1 (audit 2026-08-21): the LOAD_* connection options were pasted, identically,
# NINE times -- and test/zfsbackup's BatchMode-count assertion was a copy-count
# guard standing in for this factorization (its own text records the pre-fix
# bug: a new copy forgot the timeouts). One builder; the grant-check callers
# pass their own key material, everyone else defaults to the LOAD_* context.
load_ssh_opts() {   # [keyfile alias alias_kh port] -> fills LOAD_SSH_OPTS[]
    # ${VAR:-} inside the defaults, deliberately: this can be reached from
    # contexts that probe BEFORE a connection is loaded (emit_client_sections'
    # passive-detection ssh runs under a test with no LOAD_* at all), and under
    # set -u a bare $LOAD_KEYFILE here would abort the whole shell -- where the
    # old inline arrays only failed the one command. Empty options make the
    # ssh fail exactly as loudly as the unbound expansion used to, minus the
    # collateral.
    local kf="${1:-${LOAD_KEYFILE:-}}" al="${2:-${LOAD_ALIAS:-}}" kh="${3:-${LOAD_ALIAS_KH:-}}" pt="${4:-${LOAD_PORT:-22}}"
    LOAD_SSH_OPTS=(-i "$kf" -p "$pt" -o BatchMode=yes \
        -o "HostKeyAlias=$al" -o "UserKnownHostsFile=$kh" \
        -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval="$SSH_SERVER_ALIVE_INTERVAL" -o ServerAliveCountMax="$SSH_SERVER_ALIVE_COUNT")
}

runuser_test_x() {   # <user> <path>
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$1" -- test -x "$2"
    else
        su -s /bin/bash "$1" -c "$(printf '%q ' test -x "$2")"
    fi
}

# Can THIS process actually run commands as <user>? Distinguishes "checked and
# failed" from "cannot check": an unprivileged run (CI, a non-root operator)
# cannot switch user at all, and a guard that read that inability as
# "unreachable" would refuse every install it cannot verify -- fail-closed in
# the wrong direction, on the machines where nothing real is at stake.
runuser_can() {   # <user> -> 0 this process can act as <user>
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$1" -- true 2>/dev/null
    else
        su -s /bin/bash "$1" -c true 2>/dev/null
    fi
}

# Every script the proposed block would RUN must be reachable by the account
# that will run it.
#
# Nothing checked this until 2026-08-01, and metropolis pve2 is what it costs.
# Its config -- rebuilt by cron2conf.sh from the live crontab, and therefore
# faithfully carrying root's paths as EXPLICIT `[defaults] repo_dir` -- rendered
# an account block naming /root/scripts/zfs-snapshot-all/*.sh. /root is 0700, so
# every one of those lines died with exit 126, and the host had no working
# backup job at all until it was noticed.
#
# The migration could not see it by construction: job_identity() STRIPS the
# script directory, on purpose, because that is the part that legitimately
# changes when ownership moves. So the workload comparison said "identical" --
# correctly -- about a block that could not execute. Two different questions,
# and only one of them was being asked.
#
# It is also the reason the per-line check reported rc=0: the generated cron
# idiom ends in `rm -f "$e"`, so the LINE succeeds whatever the job did. Only
# the monitors alerted, and only because they carry their own rc test.
assert_block_runnable_by() {   # <account> <block file>
    local acct="$1" blk="$2" p unreachable=""
    # A1 (2026-08-21): written after the 2026-08-01 metropolis pve2 incident
    # (config rebuilt by cron2conf carried a root repo_dir; /root is 0700; every
    # block line exited 126 and still reported rc=0 because the cron idiom ends
    # in `rm -f "$e"`) -- and then NEVER CALLED, for over two weeks, while
    # DEPLOY-PRECONDITIONS.md described it as an active precondition. Wired at
    # the atomic_replace_and_install chokepoint now, so every config writer
    # passes it. Skipped honestly where the check is impossible:
    if ! runuser_can "$acct"; then
        log "runnability check for '$acct' skipped -- this process cannot run commands as that account; a real install on a host runs as root and does check"
        return 0
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        runuser_test_x "$acct" "$p" || unreachable="$unreachable
  $p"
    done < <(grep -oE '/[^ "]*/(snapsend|snapget|delsnaps|check-snap-age|notify-fail|notify-warn|alert-digest)\.sh' "$blk" | sort -u)
    [ -z "$unreachable" ] && return 0
    die "the block that would be installed for '$acct' names scripts that '$acct' cannot execute:$unreachable

/root is 0700 on a Proxmox host, so an account cannot use root's checkout -- it
needs its own, and the generated lines must point at it. The usual cause is a
'[defaults] repo_dir' in the config pinning root's path; remove it and let the
path follow whoever runs the block. Nothing has been changed."
}

# Show the change itself, not a description of it.
#
# Everything activate-client prints above this is a SUMMARY. A yes/no answer to
# a summary is not consent to a change nobody displayed, and this project
# learned that the expensive way -- the standing rule here is that a regenerated
# crontab gets diffed before it is installed, never trusted because the summary
# read correctly.
#
# Two diffs, because they answer different questions:
#
#   config  -- what will be written to disk;
#   cron    -- what will actually RUN, which is the one that surprises people.
#              A template edit touches no [dataset:] section and still rewrites
#              every schedule in the block, so the config diff alone can look
#              tiny while the cron diff is enormous.
#
# gen-cron.sh without --install prints the block to stdout, so both sides of the
# cron diff are rendered the same way and a difference is real rather than a
# formatting artifact.
# THE INSTALLED BLOCK REMEMBERS WHICH CONFIG WROTE IT, AND SO SHOULD WE.
#
# There is ONE managed block in a crontab, and whichever config last rendered it
# owns the whole thing. So a command that resolves to config B silently replaces
# every line config A had put there -- including jobs B has never heard of.
#
# Measured the hard way on pve9, 2026-08-29: three replica jobs installed from
# /root/replab.conf vanished when `remove-client` ran and resolved to the
# canonical /etc/zfs-snapshot-all config instead. Nothing said a word; the
# crontab simply had three fewer jobs, and the only reason it was noticed was a
# hash in an unrelated audit line.
#
# The block already carries `# Source: <path>` on its second line. Comparing it
# costs one grep and turns a silent replacement into a sentence.
warn_if_block_has_other_source() {   # <config about to be installed>
    local want="$1" have
    have="$(crontab_for_target 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')"
    [ -n "$have" ] || return 0
    # Same normaliser the missing-config guard uses, so the two agree on what
    # "a different file" means rather than each having an opinion.
    [ "$(normalize_cron_source "$have")" != "$(normalize_cron_source "$want")" ] || return 0
    warn "the managed block currently installed was rendered from a DIFFERENT config:"
    warn "    installed from: $have"
    warn "    about to install from: $want"
    warn "  There is one managed block per crontab, so this replaces every job the other config put there -- including any this one does not describe. If both are meant to be live, they belong in one file."
}

show_activation_proposal() {   # <current config> <proposed config>
    local cronfile="$1" workfile="$2" before after rc=0
    before=$(mktemp) || return 1
    after=$(mktemp)  || { rm -f "$before"; return 1; }
    # gen-cron stamps the config's own path into a '# Source:' comment, and the
    # proposed config is still a temp file at this point -- so that one line
    # differs on every single run. Left in, it would show a change where there
    # is none and, worse, make "(bez zmian)" unreachable: the operator would
    # learn to skim a diff that always has something in it. The path is
    # normalised on both sides, because after the swap it IS the same file.
    _strip_source() { sed 's|^# Source: .*|# Source: <config>|'; }

    # LEFT SIDE IS THE LIVE CRONTAB, not a second rendering of the config
    # (REV-20260801-015 §1). Rendering the current config again would only show
    # what the config says SHOULD be installed, so every kind of drift -- a hand
    # edit, an interrupted deployment, a block installed from a different
    # config, a stale managed block -- was invisible, and the preview could
    # promise "no change" while --install went on to rewrite the live crontab.
    # Consent has to be against the state that will actually be modified.
    #
    # gen-cron replaces exactly the BEGIN/END managed block and leaves every
    # other cron line alone, so that block is both what to compare and the whole
    # of what the install can touch. An absent crontab or absent block yields an
    # empty left side, which is correct: everything is new.
    # "Could not read it" is NOT "there is nothing there" (REV-20260801-016 F1).
    # A permission error, a broken spool or a missing crontab binary would
    # otherwise render as an empty left side, i.e. as "all of this is new" --
    # and the operator is being asked to approve an exact live change, so a
    # guess in the reassuring direction is the wrong one.
    #
    # The one benign failure is a user who simply has no crontab yet: cron
    # exits non-zero and says so on stderr. That message is matched loosely and
    # everything else aborts, which puts the locale risk on the safe side -- a
    # translated "no crontab" makes this refuse rather than invent an answer.
    local cron_err cron_raw cron_rc
    cron_err=$(mktemp) || { rm -f "$before" "$after"; return 1; }
    cron_raw=$(crontab_for_target 2>"$cron_err"); cron_rc=$?
    if [ "$cron_rc" -ne 0 ] && ! grep -qi "no crontab" "$cron_err"; then
        warn "could not read the live crontab (rc=$cron_rc): $(tr -d '\n' < "$cron_err")"
        warn "refusing to preview against a crontab that could not be read -- an unreadable crontab is not an empty one, and nothing has been installed."
        rm -f "$before" "$after" "$cron_err"
        return 1
    fi
    rm -f "$cron_err"
    printf '%s\n' "$cron_raw" \
        | sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p' \
        | _strip_source > "$before"

    # The `!` tests the PIPELINE, which reports gen-cron's failure only because
    # this file sets `pipefail` at the top. Verified: a config gen-cron rejects
    # makes this function return 1 rather than showing a plausible empty diff.
    # Rendered through gencron_as_target, exactly as the install will be. The
    # first version called gen-cron directly, i.e. as ROOT -- so on a host with
    # a dedicated collector account the preview showed root's paths and root's
    # digest line while the install produced the account's. A preview that is
    # not the install is worse than none: it is a promise made in the wrong
    # environment (REV-20260801-015's own acceptance criterion).
    # The workfile is created by mktemp (0600, root-owned) next to the real
    # config, and the render below runs AS THE ACCOUNT -- which therefore
    # cannot open it. Found live 2026-08-17 (lab3 final run): the first
    # account-rendered activation on a fresh collector died as "could not
    # render", for a file-mode reason no message named. 0644 matches what the
    # atomic swap sets on the real config anyway.
    chmod 0644 "$workfile" 2>/dev/null || :
    # Render stderr goes to a file, not /dev/null: "could not render" with the
    # reason discarded cost a live debugging round on the very next line.
    local render_err; render_err=$(mktemp) || { rm -f "$before" "$after"; return 1; }
    if ! gencron_as_target -c "$workfile" 2>"$render_err" | _strip_source > "$after"; then
        warn "gen-cron.sh (as $(cron_target_user)) refused the proposed config:"
        sed 's/^/    /' "$render_err" >&2
        rm -f "$before" "$after" "$render_err"; return 1
    fi
    rm -f "$render_err"

    echo "--- proponowany config: $cronfile ---"
    if [ -f "$cronfile" ]; then
        if diff -q "$cronfile" "$workfile" >/dev/null 2>&1; then
            echo "  (bez zmian)"
        else
            diff -u "$cronfile" "$workfile" | tail -n +3 | sed 's/^/  /'
        fi
    else
        echo "  (nowy plik)"
        sed 's/^/  + /' "$workfile"
    fi
    echo
    echo "--- co sie zmieni w crontabie (lewa strona = to, co JEST teraz zainstalowane) ---"
    if diff -q "$before" "$after" >/dev/null 2>&1; then
        echo "  (bez zmian -- zainstalowany blok jest juz dokladnie taki)"
    else
        diff -u "$before" "$after" | tail -n +3 | sed 's/^/  /'
    fi
    echo
    rm -f "$before" "$after"
    return $rc
}

_restore_target_crontab() {   # <file>
    # cron_write, not a bare `crontab "$1"`: a restore that claims success
    # without looking is the worst lie this code can tell, because it is told on
    # the path where something has ALREADY gone wrong. The library writes and
    # then reads back.
    cron_write "$(cron_target_user)" "$1"
}

atomic_replace_and_install() {
    # Before anything is swapped: is this block somebody else's? Said here rather
    # than in each caller, because this is the one door they all go through.
    warn_if_block_has_other_source "${1:-}"
    local realfile="$1" workfile="$2"
    # From here the candidate is THIS function's: every path below either moves
    # it into place or removes it explicitly, so the exit-time net must let go
    # of it now. Releasing a path that has become the live config would be a
    # disaster dressed as a cleanup.
    workfile_untrack
    # A1: the runnability guard, FIRST, before any state is touched -- a
    # refusal here has nothing to roll back. Rendered from the workfile the
    # same way the install will render it; if the render itself fails, fall
    # through and let the --install path below report it with its own rollback.
    local _blk; _blk=$(mktemp) || { rm -f "$workfile"; die "mktemp failed for the runnability check"; }
    if gencron_as_target -c "$workfile" > "$_blk" 2>/dev/null; then
        if ! ( assert_block_runnable_by "$(cron_target_user)" "$_blk" ); then
            rm -f "$_blk" "$workfile"
            die "refusing to install: the rendered block is not runnable by $(cron_target_user) (see above) -- neither $realfile nor the crontab was touched"
        fi
    fi
    rm -f "$_blk"
    local backup="" crontab_backup
    crontab_backup=$(mktemp) || { rm -f "$workfile"; die "mktemp failed for crontab backup"; }
    crontab_for_target > "$crontab_backup" 2>/dev/null
    if [ -f "$realfile" ]; then
        backup=$(mktemp "$(dirname "$realfile")/.zfsbackup-backup.XXXXXX") || { rm -f "$workfile" "$crontab_backup"; die "mktemp backup failed for $realfile"; }
        cp -p "$realfile" "$backup" || { rm -f "$workfile" "$backup" "$crontab_backup"; die "could not back up $realfile before swap"; }
    fi
    # The config the collector account reads must stay readable by it. mktemp
    # made the working copy 0600 and the swap would carry that mode onto the
    # real file -- found live on metropolis pve1: gen-cron, running as the
    # account, got "Permission denied" on a config in a world-readable
    # directory.
    chmod 0644 "$workfile" 2>/dev/null || :
    if ! mv -f "$workfile" "$realfile"; then
        rm -f "$workfile" "$backup" "$crontab_backup" 2>/dev/null
        die "could not atomically replace $realfile"
    fi
    if ! gencron_as_target -c "$realfile" --install; then
        warn "gen-cron.sh --install failed after updating $realfile -- restoring both the config file and the crontab to their exact prior state"
        if [ -n "$backup" ]; then
            mv -f "$backup" "$realfile" || warn "CRITICAL: could not restore $realfile from $backup -- fix by hand"
        else
            rm -f "$realfile"
        fi
        if [ -s "$crontab_backup" ]; then
            _restore_target_crontab "$crontab_backup" || warn "CRITICAL: could not restore the crontab from $crontab_backup either -- restore by hand as $(cron_target_user): crontab $crontab_backup"
        fi
        rm -f "$crontab_backup"
        die "gen-cron.sh --install failed -- see above; $realfile and the crontab have been restored to their prior state"
    fi
    [ -n "$backup" ] && rm -f "$backup"
    rm -f "$crontab_backup"
}

# ------------------------------------------------------------------------------
# Live view of every transfer in flight, readable from ANY terminal -- not just
# the one that started the run. The engines keep one durable record per dataset
# while a send is running (lib-zfs-snap.sh, progress_watch); this only reads
# them. A record whose 'running' state has not been refreshed for a while is
# reported as such rather than shown as if it were current: the watcher can be
# killed with its run, and a stale number presented as live is exactly the kind
# of false health this project keeps finding.
cmd_progress() {
    local dir="${ZFS_PROGRESS_DIR:-/var/lib/zfs-snapshot-all/progress}"
    local f any=0
    # --json IS the product here, not a convenience: the point of this stage is
    # a data layer a future GUI or monitor can read, per dataset AND per
    # relation, without scraping human text. One JSON object: "jobs" is the raw
    # records verbatim (the engines own that schema), "relations" aggregates by
    # the label the engines stamp into every record -- summed bytes, worst-case
    # freshness, and a state that is "running" only if something actually runs.
    if [ "${1:-}" = "--json" ]; then
        local first=1
        printf '{"jobs":['
        for f in "$dir"/*.json; do
            [ -e "$f" ] || continue
            [ "$first" -eq 1 ] || printf ','
            first=0
            cat "$f"
        done
        printf '],"relations":['
        first=1
        # LIVE rows only. The reviewer's discriminator: one finished 100/100
        # record plus one current 25/100 used to aggregate as 200/125 "running"
        # -- history retained for the operator was silently inflating the live
        # relation state. Finished records stay in "jobs" (history is data);
        # the relation aggregate answers "how is it going NOW" and nothing else.
        for f in "$dir"/*.json; do [ -e "$f" ] && cat "$f"; done | awk -v now="$(date +%s)" '
            !/"state":"running"/ { next }
            { match($0,/"label":"[^"]*"/);        lb=substr($0,RSTART+9,RLENGTH-10)
              if (lb=="") lb="(bez etykiety)"
              match($0,/"total_bytes":[0-9]*/);   t=substr($0,RSTART+14,RLENGTH-14)+0
              match($0,/"done_bytes":[0-9]*/);    d=substr($0,RSTART+13,RLENGTH-13)+0
              match($0,/"updated_epoch":[0-9]*/); u=substr($0,RSTART+16,RLENGTH-16)+0
              run = ($0 ~ /"state":"running"/) ? 1 : 0
              tot[lb]+=t; don[lb]+=d; n[lb]++
              if (run) { running[lb]++; if (u<old[lb] || old[lb]==0) old[lb]=u }
            }
            END {
              first=1
              for (lb in n) {
                if (!first) printf ","
                first=0
                st = (running[lb]>0) ? "running" : "idle"
                age = (running[lb]>0) ? now-old[lb] : -1
                printf "{\"label\":\"%s\",\"jobs\":%d,\"running\":%d,\"total_bytes\":%d,\"done_bytes\":%d,\"state\":\"%s\",\"oldest_update_age\":%d}", lb, n[lb], running[lb]+0, tot[lb], don[lb], st, age
              }
            }'
        printf ']}\n'
        return 0
    fi
    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        any=1
        awk -v now="$(date +%s)" '
            function h(b,   u,i) { split("B KiB MiB GiB TiB PiB",u," "); i=1
                while (b>=1024 && i<6) { b/=1024; i++ }
                return sprintf(i==1?"%d %s":"%.1f %s", b, u[i]) }
            function dur(s) { if (s<0) return "?"
                return sprintf("%dh%02dm%02ds", s/3600, (s%3600)/60, s%60) }
            {
                match($0,/"dataset":"[^"]*"/);   ds=substr($0,RSTART+11,RLENGTH-12)
                tg=""; if (match($0,/"target":"[^"]*"/)) tg=substr($0,RSTART+10,RLENGTH-11)
                match($0,/"state":"[^"]*"/);     st=substr($0,RSTART+9,RLENGTH-10)
                match($0,/"total_bytes":[0-9]*/);  tot=substr($0,RSTART+14,RLENGTH-14)+0
                match($0,/"done_bytes":[0-9]*/);   don=substr($0,RSTART+13,RLENGTH-13)+0
                match($0,/"rate_bps":[0-9]*/);     rt=substr($0,RSTART+11,RLENGTH-11)+0
                match($0,/"eta_seconds":-?[0-9]*/);eta=substr($0,RSTART+14,RLENGTH-14)+0
                match($0,/"updated_epoch":[0-9]*/);upd=substr($0,RSTART+16,RLENGTH-16)+0
                pct = (tot>0) ? don*100/tot : 0
                age = now-upd
                stale = (st=="running" && age>30) ? "  (bez aktualizacji od " age "s -- moze nie zyc)" : ""
                # The filename is a hash now, so the record has to say what it
                # is about. Target included because it is what distinguishes
                # two simultaneous jobs for the same source.
                if (tg != "") printf "  %s  ->  %s\n", ds, tg; else printf "  %s\n", ds
                printf "    %s  %s / %s  (%.1f%%)   %s/s   pozostalo %s%s\n", st, h(don), h(tot), pct, h(rt), dur(eta), stale
            }' "$f"
    done
    [ "$any" -eq 1 ] || echo "  brak transferow w toku"
}

cmd_setup_server() {
    local target="" config="" local_user=""
    for a in "$@"; do
        case "$a" in
            --target=*)     target="${a#*=}" ;;
            --config=*)     config="${a#*=}" ;;
            --local-user=*) local_user="${a#*=}" ;;
            *) die "setup-server: unknown option $a" ;;
        esac
    done
    # setup-server no longer records a host-wide account: who runs a relationship's
    # jobs is decided per-relationship at add-client/deploy time (--local-user,
    # else root) and travels with that relationship. --local-user here is only a
    # convenience to PRE-CREATE a delegated account while bootstrapping the host;
    # it writes nothing to server.conf. root names no account to create.
    local delegate="$local_user"
    [ "$delegate" = root ] && delegate=""
    if [ -n "$delegate" ]; then
        local_user_name_valid "$delegate"             || die "setup-server: --local-user='$delegate' is not a valid account name ($LOCAL_USER_GRAMMAR)"
    fi

    if [ -n "$delegate" ]; then
        bash "$DEPLOY" --backup-user="$delegate" || die "deploy.sh bootstrap failed -- fix that before continuing"
    else
        bash "$DEPLOY" || die "deploy.sh bootstrap failed -- fix that before continuing"
    fi

    read_server_conf
    if [ -z "$target" ]; then
        # Slice 3 extracted this into propose_backup_target(); behaviour here is
        # unchanged, the logic simply now has one home shared with local-backup.
        #
        # Captured with `|| die`, NOT piped: the helper's own `die` (multiple
        # candidate pools) runs inside the command substitution's subshell, so it
        # cannot terminate this function. Without propagating the status, the
        # ambiguous-pool refusal would fail OPEN and setup-server would continue
        # with an empty target -- the exact shape of defect this project has been
        # bitten by before.
        local proposal
        proposal=$(propose_backup_target) || die "could not determine a backup target -- see the reason above"
        target="${proposal%%$'\t'*}"
    fi
    if [ -z "$config" ]; then
        if [ -n "$CRON_CONFIG" ]; then
            config="$CRON_CONFIG"
        else
            local existing
            existing=$(crontab_for_target 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
            if [ -n "$existing" ]; then
                config=$(normalize_cron_source "$existing")
                log "found an existing managed crontab block from '$existing' (resolved: $config) -- using it as the cron config (pass --config= to override)"
            else
                config="$(default_cron_config)"
            fi
        fi
    fi

    zfs create -p "$target" 2>/dev/null || zfs list "$target" >/dev/null 2>&1 || die "could not create or find target dataset $target"

    mkdir -p "$(dirname "$SERVER_CONF")" || die "could not create $(dirname "$SERVER_CONF")"
    {
        echo "# zfs-backup.sh server config -- edit by hand if needed, or re-run setup-server"
        echo "DEFAULT_TARGET=$target"
        echo "CRON_CONFIG=$config"
    } > "$SERVER_CONF" || die "could not write $SERVER_CONF"
    chmod 0644 "$SERVER_CONF"

    ensure_cron_config "$config"
    assert_config_readable_by_target "$config"

    log "server ready: target=$target, cron config=$config"
}

# ------------------------------------------------------------------------------
# Phase 5 slice 1: high-level LOCAL backup, planning/preview only.
#
#   zfs-backup.sh --source=rpool/data --target=hdd/backups     (bare, canonical)
#   zfs-backup.sh local-backup --source=... --target=...       (alias)
#
# One coherent local workflow -- distinct from add-client/activate-client, which
# pair two hosts for a remote PULL. It PROVES the explicit source exists on local
# ZFS (REV-097 F1), chooses a preset, composes the candidate CONFIG v4
# ADDITIVELY over the installed target config -- preserving existing jobs and
# refusing on overlap (REV-097 F2) -- and shows the full config + cron it WOULD
# install. This slice stops before install (read-only planning first, the same
# shape as the planned restore --plan); the transactional install lands in a
# later slice, so no crontab can be touched here. See
# docs/discussions/PHASE5-LOCAL-BACKUP-DESIGN-2026-08-10.md.

# local_backup_overlap SRC TGT -> rc 0 (overlap: REFUSE) when TGT and SRC are
# equal or one is nested in the other. Pure string test with trailing-slash
# boundaries so rpool/data does not spuriously match rpool/database.
local_backup_overlap() {
    local s="$1" t="$2"
    [ "$s" = "$t" ] && return 0
    case "$t/" in "$s/"*) return 0 ;; esac
    case "$s/" in "$t/"*) return 0 ;; esac
    return 1
}
# local_backup_same_pool SRC TGT -> rc 0 when the leading pool component matches.
local_backup_same_pool() { [ "${1%%/*}" = "${2%%/*}" ]; }

# The ownership marker a local-backup section carries, or "" for a section this
# tool did not write.
#
# Every section local-backup emits opens with
#   # managed-by: zfs-backup.sh local-backup <kind>=<value>
# and that line is the ONLY thing that distinguishes our own installed policy
# from a stranger's. Two blockers of the KROK 5 path were the same omission:
# nothing read the marker back, so the tool's own `[prune:<target>]` from the
# first run looked exactly like foreign coverage -- which made a second source
# unaddable, and made rerunning the identical successful command a FATAL
# instead of a no-op.
#
# Read, never inferred from the header: a hand-written `[prune:hdd/backups]`
# with the same name is NOT ours and must keep refusing.
local_backup_section_marker() {   # <file> <exact header> -> "<kind>=<value>" or ""
    [ -f "$1" ] || return 0
    awk -v want="$2" '
        $0 == want { inside=1; next }
        inside && /^\[/ { exit }
        inside && index($0, "# managed-by: zfs-backup.sh local-backup ") {
            sub(/^.*# managed-by: zfs-backup\.sh local-backup /, "")
            sub(/[ \t]+$/, "")
            print; exit
        }
    ' "$1" 2>/dev/null
}

# Which installed sections would genuinely COLLIDE with the jobs about to be
# written -- and "genuinely" is the whole point, because containment is not
# coverage for a flat job.
#
# The product contract this slice established: a flat [dataset:rpool/a] copies
# rpool/a and nothing else. It does not cover rpool/a/child, and a flat
# [dataset:rpool/a/child] does not cover the parent blocks either. Containment
# becomes coverage only when the installed section says `recursive`.
#
# The discovery side was taught this first, and that alone produced a false
# green: the proposal would offer a child under an installed flat parent, and
# this gate would then refuse the very candidate it had just proposed. So the
# rule lives here too, and both sides read it the same way.
#
#   exact identity        always a collision, whatever either side declares;
#   requested INSIDE an   a collision only when that installed section is
#   installed section     recursive -- otherwise it does not reach down there;
#   installed INSIDE a    a collision only when the job we are about to write
#   requested path        will be recursive over it. Sources are written flat,
#                         so this is the TARGET case: its retention IS emitted
#                         recursive, and a stranger's dataset under the store
#                         really would have its snapshots pruned by ours.
#
# The recursive paths are named by the caller rather than guessed here, because
# only the caller knows what it is about to emit.
#
# REV-20260811-098 stays: a section scope may name SEVERAL datasets
# comma-separated ([prune:a,b,c] -- metropolis pve2 has such sections), so each
# member is evaluated independently. Treating the comma-joined string as one
# path would miss an overlap with every member but the accidental prefix.
# WHERE THE LINK CAP COMES FROM, in one place that can be read on its own.
#
# A cap describes the WIRE, and the wire belongs to the PAIR OF HOSTS. Kept on
# the relationship record it had to be given twice for two relationships to the
# same peer, by hand, with nothing keeping them in step and nothing noticing
# when they drifted. It now lives in the pairing manifest, where one answer
# serves every relationship that flies over that link.
#
# A record written before the move is still honoured -- when the manifest is
# silent. No deployed relationship changes speed because of the move, and the
# operator is told once, with the exact command, where the value now belongs.
# The note goes to stderr because this function is read through a command
# substitution: on stdout it would BE the rate.
# One validator, because two copies of a grammar drift and this tree has paid
# for that before. Deliberately no stricter than the engines: a validator
# stricter than what snapsend accepts trades one visible error now for an
# invisible one every night.
assert_bandwidth_rate() {   # <value> <verb, for the message>
    local v="$1" verb="$2" core="$1"
    case "$core" in *[bkKmMgG]) core="${core%?}" ;; esac
    case "$core" in
        "" | *[!0-9]*)
            die "$verb: --bandwidth='$v' is not a byte rate the engines accept (digits, then at most one of b/k/M/G at the end -- e.g. 20M). It is BYTES per second, not bits." ;;
    esac
}

resolve_link_bandwidth() {   # <manifest value> <record value> <client> <peer> -> rate
    local from_pair="$1" from_record="$2" client="$3" peer="$4"
    if [ -n "$from_pair" ]; then printf '%s' "$from_pair"; return 0; fi
    if [ -n "$from_record" ]; then
        log "limit pasma '$from_record' pochodzi z rekordu relacji '$client' (zapis sprzed przeniesienia). Lacze nalezy do PARY hostow, wiec docelowe miejsce to manifest parowania -- ustaw je raz przez 'deploy.sh --pair --peer=$peer --bandwidth=$from_record', a bedzie obowiazywac kazda relacje z tym peerem." >&2
        printf '%s' "$from_record"
        return 0
    fi
    printf ''
}

config_section_overlap() {   # <file> <recursive-request or ""> <requested path>...
    local file="$1" rec_req="${2:-}"; shift 2
    [ -f "$file" ] || return 0
    local hdr scope member req srec
    while IFS= read -r hdr; do
        scope="${hdr#\[}"; scope="${scope%\]}"; scope="${scope#*:}"
        srec="$(section_field "$file" "$hdr" recursive)"
        srec="$(printf '%s' "$srec" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        case "$srec" in ""|no|off|0) srec="" ;; esac
        while IFS= read -r member; do
            [ -n "$member" ] || continue
            for req in "$@"; do
                if [ "$member" = "$req" ]; then
                    printf '
  %s (%s) overlaps requested %s' "$hdr" "$member" "$req"
                    continue
                fi
                case "$req" in
                    "$member"/*)
                        # The request lies under an installed section: only a
                        # recursive one reaches it.
                        [ -n "$srec" ] && printf '
  %s (%s, recursive=%s) covers requested %s' "$hdr" "$member" "$srec" "$req"
                        continue ;;
                esac
                case "$member" in
                    "$req"/*)
                        # An installed section lies under the request: only a
                        # request we will write recursively reaches IT.
                        [ -n "$rec_req" ] && [ "$req" = "$rec_req" ]                             && printf '
  %s (%s) lies under requested %s, which this run would cover recursively' "$hdr" "$member" "$req"
                        continue ;;
                esac
            done
        done < <(dataset_list_split "$scope")
    done < <(grep -oE '^\[(dataset|prune):[^]]+\]' "$file")
    return 0
}

# installed_dataset_field for any section kind, [prune:] included: the flat-vs-
# recursive question is asked of both, and reading only [dataset:] sections
# would have made every prune scope look flat.
section_field() {   # <file> <exact header> <field>
    awk -v h="$2" -v fld="$3" '
        $0==h {f=1; next}
        f && /^\[/ {f=0}
        f {
            line=$0; sub(/^[ 	]+/,"",line)
            if (line ~ ("^" fld "[ 	]*=")) { sub(("^" fld "[ 	]*=[ 	]*"),"",line); print line; exit }
        }
    ' "$1" 2>/dev/null
}

# A floor's `keep` is a MINIMUM, and gen-cron accepts `all` for it as well as a
# count (build_excluded_section). Comparing the two spellings as strings would
# call the strongest floor expressible unreadable, so rank them instead: `all`
# outranks every count. Returns 1 for anything gen-cron would itself reject, so
# an unreadable floor stays a finding rather than becoming a silent zero.
# WHO WROTE THIS FLOOR, if anyone said.
#
# REV F5. The asymmetric rule ("a stronger config value stands, a weaker one is
# refused") is right for an OPERATOR who deliberately hardened a family by hand.
# Applied to a floor another PROFILE installed, it is wrong in a way that
# reproduces the original defect: profile A declares keep=10, profile B declares
# keep=2, B is installed second, B's number is quietly void, and an operator
# reading profile B sees a policy in force nowhere.
#
# The code could not tell the two apart because the section carried no
# provenance. Now a floor this tool writes says which profile declared it, in
# the same `# managed-by:` idiom every other generated section already uses --
# and a section without the marker is, by construction, not ours.
#
# Backward compatible on purpose: every floor installed before this reads as
# unmarked, i.e. as the operator's, i.e. exactly the behaviour it has today.
section_profile_marker() {   # <file> <exact header> -> declaring profile, or empty
    awk -v h="$2" '
        $0==h {f=1; next}
        f && /^\[/ {exit}
        f && /^[ \t]*# managed-by: zfs-backup.sh profile=/ {
            sub(/^[ \t]*# managed-by: zfs-backup.sh profile=/, "")
            print; exit
        }
    ' "$1" 2>/dev/null
}

floor_rank() {   # <keep value> -> comparable integer on stdout
    case "$1" in
        all)         printf '%s' 2147483647 ;;
        ''|*[!0-9]*) return 1 ;;
        *)           printf '%s' "$1" ;;
    esac
}


###############################################################################
# REPLICAS -- the high-level face of [replica:] sections.
#
# Owner's direction, 2026-08-29: this has to be configurable from the top,
# because it is going into a GUI. That is not a request for convenience, it is a
# constraint on the shape: a form cannot hand-edit an INI file and cannot be told
# to paste `zpool create`. So every field of a [replica:] section is a flag here,
# add-replica is an UPSERT (the GUI's "save" is one call whether the row is new
# or edited), and the listing has a machine-readable form -- the same contract
# `progress --json` already sets as this project's data layer.
#
# What these verbs do NOT do is invent orchestration. The candidate config, the
# rendered preview and the atomic swap are the same three helpers local-backup
# and activate-client use, in the same order: plan by default, install only when
# asked.
###############################################################################

# Replace or append one [replica:NAME] block in a config file, in place.
# Everything outside the block is preserved byte for byte -- a config carries
# other people's sections and comments somebody wrote by hand.
replica_section_upsert() {   # <file> <name> <source> <dst> <schedule> <prefix> <recursive 0|1> <media> <notify> <history>
    local file="$1" name="$2" source="$3" dst="$4" sched="$5" pref="$6" rec="$7" media="$8" notify="$9"
    local history="${10:-}"
    local tmp; tmp=$(mktemp) || return 1
    awk -v want="[replica:$name]" '
        $0 == want { skip=1; next }
        skip && /^[[]/ { skip=0 }
        skip { next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    {
        printf '\n'
        printf '[replica:%s]\n' "$name"
        printf '\tsource    = %s\n' "$source"
        printf '\tdst       = %s\n' "$dst"
        printf '\tschedule  = %s\n' "$sched"
        printf '\tprefix    = %s\n' "$pref"
        [ -n "$media" ]  && printf '\tmedia     = %s\n' "$media"
        [ "$rec" = "1" ] && printf '\trecursive = yes\n'
        # 'all' is gen-cron's default and it emits nothing for it, so writing it
        # would put a field in the file that changes nothing.
        [ -n "$history" ] && [ "$history" != "all" ] && printf '\thistory   = %s\n' "$history"
        [ -n "$notify" ] && printf '\tnotify    = %s\n' "$notify"
        :
    } >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
}


# run-replicas -- every [replica:] job in the config, once, now.
#
# The owner's second trigger, 2026-08-29: "or immediately when the disk is
# plugged in". This is what udev calls; it is also what an administrator runs by
# hand after carrying a disk back from the safe.
#
# It does not reimplement the job. It renders the config through the SAME
# generator cron uses and runs the lines it produced, so there is exactly one
# description of what a replica run is. A medium that is not here skips quietly
# on its own -- that is the gate's whole contract -- so this can fire on every
# insertion without knowing which disk arrived.
cmd_run_replicas() {
    local config="" a
    for a in "$@"; do
        case "$a" in
            --config=*) config="${a#*=}" ;;
            -*)         die "run-replicas: unknown option '$a'" ;;
            *)          die "run-replicas: takes no positional arguments" ;;
        esac
    done
    local resolver_user; resolver_user="$(cron_target_user)"
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"
    [ -r "$config" ] || die "run-replicas: no readable config at $config"

    local block rc=0 n=0
    block="$(gencron_as_target -c "$config")" \
        || die "run-replicas: the config could not be rendered -- nothing was run"
    # The replica lines and only those: a bracketed job is a replica by
    # construction, because media_bracket is the only thing that emits one.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n+1))
        # Strip the five schedule fields; what is left is what cron runs.
        bash -c "$(printf '%s' "$line" | sed -E 's/^([^ ]+ ){5}//')" || rc=1
    done <<EOF
$(printf '%s' "$block" | grep 'zfs-media-gate.sh attach')
EOF
    [ "$n" -gt 0 ] || log "run-replicas: no [replica:] sections in $config -- nothing to run"
    return "$rc"
}

# install-media-trigger -- fire the replicas when a disk appears.
#
# OPTIONAL, AND NOT IMPLIED BY ANYTHING. Owner's direction, 2026-08-29: the
# insertion trigger is opt-in and must not arrive together with the schedule.
# `add-replica` never touches udev, and a host that only ever wants the nightly
# run simply never runs this verb. The two are independent: neither installs,
# implies or requires the other.
#
# ITS OWN VERB for the same reason. A udev rule is a durable change to how this
# machine reacts to hardware, which is a different layer from a cron entry; one
# command that quietly altered both would be one command too clever. The rule is
# printed before it is written, and writing it needs --install like everything
# else here.
#
# Running both is fine and costs nothing: a disk inserted in the evening runs its
# job, and the nightly run then finds nothing written since and skips without
# importing the medium at all.
cmd_install_media_trigger() {
    local config="" do_install=0 rules=/etc/udev/rules.d/90-zfs-replica.rules a
    for a in "$@"; do
        case "$a" in
            --config=*) config="${a#*=}" ;;
            --rules=*)  rules="${a#*=}" ;;
            --plan)     do_install=0 ;;
            --install)  do_install=1 ;;
            -*)         die "install-media-trigger: unknown option '$a'" ;;
            *)          die "install-media-trigger: takes no positional arguments" ;;
        esac
    done
    local resolver_user; resolver_user="$(cron_target_user)"
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"
    [ -r "$config" ] || die "install-media-trigger: no readable config at $config"
    grep -q '^\[replica:' "$config" \
        || die "install-media-trigger: $config has no [replica:] sections, so there is nothing for an inserted disk to trigger. Add one first: zfs-backup.sh add-replica ..."

    command -v systemd-run >/dev/null 2>&1 \
        || die "install-media-trigger: systemd-run is not on this host. The rule must not run the job itself -- a udev rule that blocks holds up every other device event on the machine -- and systemd-run --no-block is how it hands the work off."

    local body
    body="$(cat <<EOF
# Managed by zfs-backup.sh install-media-trigger -- do not hand-edit.
#
# Fires when a disk carrying a ZFS label appears. It does NOT know which replica
# the disk belongs to and does not need to: run-replicas tries them all and every
# medium that is not present skips quietly.
#
# --no-block is not optional. udev serialises device events, so a rule that waits
# for a backup would stall every other device on this machine for the length of
# the transfer.
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_TYPE}=="zfs_member", \\
  RUN+="$(command -v systemd-run) --no-block --unit=zfs-replica-insert-%k $SCRIPT_DIR/zfs-backup.sh run-replicas --config=$config"
EOF
)"
    echo ">>> reguła do zapisania w $rules:"
    echo "------------------------------------------------------------"
    printf '%s\n' "$body"
    echo "------------------------------------------------------------"
    if [ "$do_install" -ne 1 ]; then
        echo
        echo "To jest wylacznie plan -- nic nie zostalo zapisane."
        echo "Aby zainstalowac: powtorz to samo polecenie z --install."
        return 0
    fi
    printf '%s\n' "$body" > "$rules" || die "install-media-trigger: could not write $rules"
    chmod 0644 "$rules" 2>/dev/null || :
    udevadm control --reload-rules 2>/dev/null || warn "rule written, but 'udevadm control --reload-rules' failed -- it takes effect after the next reload or reboot"
    log "media trigger installed at $rules -- plugging in a replica disk now runs its job, and the run exports the pool again when it is done."
}

# remove-media-trigger -- take the opt-in back.
#
# An option that cannot be undone is not an option. This removes only the file
# this tool wrote, and says so rather than sweeping /etc/udev/rules.d for
# anything that looks related.
cmd_remove_media_trigger() {
    local rules=/etc/udev/rules.d/90-zfs-replica.rules do_install=0 a
    for a in "$@"; do
        case "$a" in
            --rules=*)  rules="${a#*=}" ;;
            --plan)     do_install=0 ;;
            --install)  do_install=1 ;;
            -*)         die "remove-media-trigger: unknown option '$a'" ;;
            *)          die "remove-media-trigger: takes no positional arguments" ;;
        esac
    done
    [ -f "$rules" ] || { log "no media trigger installed at $rules -- nothing to remove."; return 0; }
    grep -q 'Managed by zfs-backup.sh install-media-trigger' "$rules" \
        || die "remove-media-trigger: $rules exists but was not written by this tool. Refusing to delete somebody else's udev rule -- look at it and remove it by hand if it is yours."
    if [ "$do_install" -ne 1 ]; then
        echo ">>> do usuniecia: $rules"
        echo "To jest wylacznie plan -- nic nie zostalo usuniete."
        echo "Aby usunac: powtorz to samo polecenie z --install."
        return 0
    fi
    rm -f "$rules" || die "remove-media-trigger: could not remove $rules"
    udevadm control --reload-rules 2>/dev/null || warn "rule removed, but 'udevadm control --reload-rules' failed -- it stops applying after the next reload or reboot"
    log "media trigger removed. Replicas now run only on their schedule; the cron entries are untouched."
}

cmd_add_replica() {   # <name> --source=DS [--source=DS2 ...] --dst=POOL/BASE [...]
    local name="" source="" dst="" sched="" pref="replica_" rec=1 media="removable" notify="" history=""
    local config="" do_install=0 assume_yes=0 a _ans
    # --source IS REPEATABLE, and also takes a comma list, so a front end can
    # send either shape. One medium often holds more than one thing worth
    # keeping, and a second [replica:] onto the same disk is refused further
    # down for a good reason: two jobs sharing a pool export it out from under
    # each other mid-write. The list belongs on the job.
    local -a sources=() _sp=()
    local _s1
    for a in "$@"; do
        case "$a" in
            --source=*)    IFS=',' read -ra _sp <<< "${a#*=}"
                           for _s1 in "${_sp[@]}"; do [ -n "$_s1" ] && sources+=("$_s1"); done ;;
            --dst=*)       dst="${a#*=}" ;;
            --schedule=*)  sched="${a#*=}" ;;
            --prefix=*)    pref="${a#*=}" ;;
            --notify=*)    notify="${a#*=}" ;;
            # HOW MUCH OF THE GAP TRAVELS when a common snapshot survived.
            # Validated here as well as in gen-cron, so a typo fails at the
            # command line instead of after the config has been composed.
            --history=*)   history="${a#*=}"
                           case "$history" in
                               all|newest) ;;
                               auto:*)     case "${history#auto:}" in
                                               ''|*[!0-9]*) die "add-replica: --history=$history -- auto: takes a count, e.g. --history=auto:3" ;;
                                           esac ;;
                               *) die "add-replica: --history=$history -- expected 'all' (every snapshot in between, the default), 'newest' (only the diff to the newest) or 'auto:N' (let the engine decide, measured in this dataset's own snapshot intervals). It only matters when a common snapshot survived: once retention has eaten it, the bookmark anchors a single diff whatever this says." ;;
                           esac ;;
            --config=*)    config="${a#*=}" ;;
            --recursive=*) case "${a#*=}" in yes|1|true) rec=1 ;; no|0|false) rec=0 ;; *) die "add-replica: --recursive takes yes or no" ;; esac ;;
            # A replica onto a target that is ALWAYS there is a legitimate third
            # copy -- another pool in the same box. It simply does not get the
            # import/export bracket, and must not, or every run would export a
            # pool nobody asked to unmount.
            --fixed)       media="" ;;
            --removable)   media="removable" ;;
            --plan)        do_install=0 ;;
            --install)     do_install=1 ;;
            --yes|-y)      assume_yes=1 ;;
            -*)            die "add-replica: unknown option '$a'" ;;
            *)             if [ -z "$name" ]; then name="$a"; else die "add-replica: takes exactly one name; got a second: '$a'"; fi ;;
        esac
    done
    [ -n "$name" ] || die "uzycie: zfs-backup.sh add-replica NAZWA --source=DATASET [--source=DATASET2 ...] --dst=PULA/BAZA [--schedule='10 * * * *'] [--fixed] [--install]"
    case "$name" in *[!A-Za-z0-9._-]*) die "add-replica: '$name' -- letters, digits, dot, dash, underscore only (it names the medium and becomes the media gate's state file)" ;; esac
    [ "${#sources[@]}" -gt 0 ] || die "add-replica: --source= names the dataset on THIS host to copy (repeat it for more than one)"
    local _i _j
    for ((_i=0; _i<${#sources[@]}; _i++)); do
        for ((_j=_i+1; _j<${#sources[@]}; _j++)); do
            [ "${sources[_i]}" = "${sources[_j]}" ] \
                && die "add-replica: '${sources[_i]}' is named twice -- one run would send it into '$dst' twice"
        done
    done
    source="$(IFS=,; printf '%s' "${sources[*]}")"
    [ -n "$dst" ]    || die "add-replica: --dst= names the base dataset on the medium, e.g. usbrep1/replica"
    # ONCE A NIGHT, AFTER THE DAILY TIER -- not hourly.
    #
    # Owner's model, 2026-08-29: a replica is not an online mirror. The medium is
    # only at risk while its pool is imported, and every run opens that window,
    # so the number of runs IS the exposure. The daily tier sends at 01:11 in the
    # shipped profiles (00:11 in prod), so 02:30 is comfortably after it and
    # still inside the night.
    #
    # A replica that wanted to be closer to live would not be a replica; it would
    # be a second backup relationship, and those already exist.
    [ -n "$sched" ]  || sched="30 2 * * *"

    # THE SOURCE MUST EXIST. A replica of nothing is a job that alerts nightly.
    # Every one of them, checked here: with a list it is the second entry a
    # single check waves through, and the cost of that is discovered at 02:30.
    local _s2
    for _s2 in "${sources[@]}"; do
        zfs list -H -o name "$_s2" >/dev/null 2>&1 \
            || die "add-replica: '$_s2' is not a dataset on this host. A replica copies what this machine already holds."
    done

    # THE MEDIUM MAY BE IN A SAFE, AND THAT IS NOT AN ERROR.
    #
    # The base dataset on the target is what tells the gate the RIGHT disk is in
    # the slot, so when the pool is here it is checked and a mismatch refused.
    # When the pool is absent it CANNOT be checked -- and refusing would mean
    # fetching a disk out of the safe merely to add a line to a config. It is
    # said out loud instead, which is the rule the join scope follows too.
    local pool="${dst%%/*}"
    if zpool list -H -o name "$pool" >/dev/null 2>&1; then
        zfs list -H -o name "$dst" >/dev/null 2>&1 \
            || die "add-replica: pool '$pool' is imported but '$dst' is not on it. That dataset is what identifies the medium, so this is either the wrong disk or one that was never prepared: zfs create $dst"
    elif zpool import 2>/dev/null | awk -v p="$pool" '$1=="pool:" && $2==p {found=1} END{exit !found}'; then
        # In the slot, just not imported. Saying "not here" about a disk the
        # operator can see would be the same falsehood the listing used to tell.
        warn "medium '$pool' is in the slot but not imported, so '$dst' was not checked. The job imports it itself; if that dataset is not on it, the first run will refuse it as the wrong medium."
    else
        warn "medium '$pool' is not here, so '$dst' could not be checked. That is normal for a disk in a safe -- but if it was never prepared, the first run will refuse it as the wrong medium. Prepare it once: zpool create $pool <device> && zfs create $dst"
    fi

    local resolver_user; resolver_user="$(cron_target_user)"
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"

    # ONE MEDIUM, ONE REPLICA. Two hazards, both refused, and both are what a
    # form produces the first time somebody picks the same disk twice:
    #
    #   * the same dst -- two jobs writing one dataset, each with its own
    #     snapshot family, racing;
    #   * the same POOL under a different label -- worse, and not obvious. The
    #     gate's ownership marker is per LABEL, so the two jobs each believe
    #     they imported the pool, and whichever finishes first exports it out
    #     from under the other mid-write.
    #
    # Checked against the INSTALLED config and skipping this replica's own
    # section, so re-running add-replica for an existing name stays an upsert
    # rather than a collision with itself.
    if [ -f "$config" ]; then
        local _other _odst _opool
        while IFS="$(printf '	')" read -r _other _odst; do
            [ -n "$_other" ] || continue
            [ "$_other" = "$name" ] && continue
            [ "$_odst" = "$dst" ]                 && die "add-replica: [replica:$_other] already writes to '$dst'. Two replicas onto one target would race, each with its own snapshot family. Give this one its own dataset, or edit '$_other'."
            _opool="${_odst%%/*}"
            [ "$_opool" = "$pool" ]                 && die "add-replica: [replica:$_other] already uses the medium '$pool' (as $_odst). The media gate records ownership per LABEL, so two labels on one pool would each believe they imported it -- and whichever finished first would export it out from under the other, mid-write. One medium, one replica."
        done <<REPEOF
$(awk '
    /^\[replica:/ { if (n!="" && d!="") print n "\t" d
                    n=$0; sub(/^\[replica:/,"",n); sub(/\]$/,"",n); d=""; next }
    /^\[/ { if (n!="" && d!="") print n "	" d; n=""; d=""; next }
    n != "" { line=$0; sub(/^[ 	]+/,"",line); k=line; sub(/[ 	]*=.*$/,"",k); v=line; sub(/^[^=]*=[ 	]*/,"",v); if (k=="dst") d=v }
    END { if (n!="" && d!="") print n "	" d }
' "$config")
REPEOF
    fi

    local cand; cand=$(mktemp) || die "mktemp failed"
    chmod 0644 "$cand" 2>/dev/null || :
    if [ -f "$config" ]; then
        cp -p "$config" "$cand" || { rm -f "$cand"; die "could not read $config to plan against it"; }
    else
        assert_config_not_claimed_if_missing "$config"
        printf '[defaults]\n\thost_label = %s\n' "$COLLECTOR_LABEL" > "$cand" \
            || { rm -f "$cand"; die "could not create the candidate config"; }
    fi
    replica_section_upsert "$cand" "$name" "$source" "$dst" "$sched" "$pref" "$rec" "$media" "$notify" "$history" \
        || { rm -f "$cand"; die "could not compose the [replica:$name] section"; }

    show_activation_proposal "$config" "$cand" || {
        rm -f "$cand"
        die "gen-cron.sh could not render the proposed config -- nothing was touched"
    }
    if [ "$do_install" -ne 1 ]; then
        echo
        echo "To jest wylacznie plan -- nic nie zostalo zainstalowane."
        echo "Aby zainstalowac: powtorz to samo polecenie z --install."
        rm -f "$cand"
        return 0
    fi
    if [ "$assume_yes" -ne 1 ]; then
        _ans=""
        read -rp "Zainstalowac powyzsze? [t/N] " _ans </dev/tty 2>/dev/null || _ans=""
        case "$_ans" in t|T|tak|TAK|y|Y|yes|YES) ;; *) rm -f "$cand"; die "not confirmed -- nothing was installed" ;; esac
    fi
    atomic_replace_and_install "$config" "$cand" \
        || die "add-replica: the install failed -- see above. The config and crontab were rolled back together."
    log "replica '$name' installed: $source -> $dst"
}


# list-replicas [--json] -- the inventory, plus whether each medium is HERE.
#
# --json is the product, not a convenience, for the same reason it is on
# `progress`: a GUI must not scrape human text. The two are deliberately the
# same shape of answer -- one object, one array of records, fields named after
# the config fields they came from -- so a front end learns the convention once.
#
# `present` is asked of the gate rather than inferred, because the gate is the
# one piece that knows the difference between "the pool is not imported" and
# "the pool is imported but this is the WRONG disk". A listing that flattened
# those two into a boolean would hide the only dangerous one.
cmd_list_replicas() {
    local as_json=0 config="" a
    for a in "$@"; do
        case "$a" in
            --json)     as_json=1 ;;
            --config=*) config="${a#*=}" ;;
            -*)         die "list-replicas: unknown option '$a'" ;;
            *)          die "list-replicas: takes no positional arguments" ;;
        esac
    done
    local resolver_user; resolver_user="$(cron_target_user)"
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"
    [ -r "$config" ] || die "list-replicas: no readable config at $config"

    # Parsed with awk rather than sourced: a config is data, never a program.
    local rows; rows=$(awk '
        /^\[replica:/ {
            if (name != "") print name "\t" src "\t" dst "\t" sched "\t" pref "\t" media "\t" rec "\t" (hist==""?"all":hist)
            name=$0; sub(/^\[replica:/,"",name); sub(/\]$/,"",name)
            src=""; dst=""; sched=""; pref=""; media=""; rec="no"; hist=""; next
        }
        /^\[/ { if (name != "") { print name "\t" src "\t" dst "\t" sched "\t" pref "\t" media "\t" rec "\t" (hist==""?"all":hist); name="" } next }
        name != "" {
            line=$0; sub(/^[ \t]+/,"",line)
            k=line; sub(/[ \t]*=.*$/,"",k)
            v=line; sub(/^[^=]*=[ \t]*/,"",v)
            if (k=="source") src=v
            else if (k=="dst") dst=v
            else if (k=="schedule") sched=v
            else if (k=="prefix") pref=v
            else if (k=="media") media=v
            else if (k=="recursive") rec=v
            else if (k=="history") hist=v
        }
        END { if (name != "") print name "\t" src "\t" dst "\t" sched "\t" pref "\t" media "\t" rec "\t" (hist==""?"all":hist) }
    ' "$config")

    local gate="$SCRIPT_DIR/zfs-media-gate.sh"
    local name src dst sched pref media rec hist pool present last first=1
    if [ "$as_json" -eq 1 ]; then printf '{"replicas":['; fi
    if [ -z "$rows" ]; then
        if [ "$as_json" -eq 1 ]; then printf ']}\n'; else echo "brak sekcji [replica:] w $config"; fi
        return 0
    fi
    while IFS="$(printf '\t')" read -r name src dst sched pref media rec hist; do
        [ -n "$name" ] || continue
        pool="${dst%%/*}"
        present="unknown"; last=""
        if [ -x "$gate" ]; then
            if "$gate" status "$pool" "$name" --dataset "$dst" --quiet >/dev/null 2>&1; then
                present="here"
            else
                case "$?" in
                    1) present="away" ;;
                    2) present="wrong_medium" ;;
                esac
            fi
        fi
        # THREE STATES, NOT TWO. The gate answers "is this pool imported", which
        # is the right question for a job that is about to write. It is the
        # wrong one for a person looking at a list: a disk sitting in the slot
        # with its pool exported would read as "away", i.e. as a disk in a safe,
        # and that is the single most misleading thing a front end could show.
        # Asked here rather than in the gate so its exit contract, which the
        # generated cron lines depend on, is left exactly as it is.
        if [ "$present" = "away" ]; then
            if zpool import 2>/dev/null | awk -v p="$pool" '$1=="pool:" && $2==p {found=1} END{exit !found}'; then
                present="available"
            fi
        fi
        [ -r "/var/lib/zfs-snapshot-all/media/$name.last-seen" ] \
            && last="$(cat "/var/lib/zfs-snapshot-all/media/$name.last-seen" 2>/dev/null)"
        if [ "$as_json" -eq 1 ]; then
            [ "$first" -eq 1 ] || printf ','
            first=0
            # "source" stays the raw field, so a reader written against the
            # one-dataset shape keeps working; "sources" is the array a front
            # end should use, and it has one element when there is one source.
            # Emitting only the string would make a GUI parse a config grammar.
            local _js _jfirst=1 _jarr=""
            while IFS= read -r _js; do
                [ -n "$_js" ] || continue
                [ "$_jfirst" -eq 1 ] || _jarr="$_jarr,"
                _jfirst=0
                _jarr="$_jarr\"$_js\""
            done <<JSRC
$(printf '%s' "$src" | tr ',' '\n')
JSRC
            printf '{"name":"%s","source":"%s","sources":[%s],"dst":"%s","schedule":"%s","prefix":"%s","media":"%s","recursive":"%s","history":"%s","present":"%s","last_seen":"%s"}' \
                "$name" "$src" "$_jarr" "$dst" "$sched" "$pref" "${media:-fixed}" "$rec" "$hist" "$present" "$last"
        else
            printf '%-14s %-28s -> %-24s %-14s %-11s %s\n' "$name" "$src" "$dst" "$sched" "$hist" "$present"
            [ -n "$last" ] && printf '%-14s   ostatnio widziany: %s\n' "" "$last"
        fi
    done <<EOF
$rows
EOF
    if [ "$as_json" -eq 1 ]; then printf ']}\n'; fi
    return 0
}

# Does this config still describe any JOB?
#
# gen-cron.sh resolves cron lines from [dataset:], [prune:], [prune-bookmarks:]
# and [replica:]. [defaults], [template:] and [excluded:] are policy: they
# describe HOW a job would run and emit nothing on their own. A file holding
# only those is not a corrupt config, it is an EMPTY SCHEDULE.
config_has_job_sections() {   # <file>
    grep -qE '^\[(dataset|prune|prune-bookmarks|replica):' "$1"
}

# remove-replica NAME -- drop the section and reinstall the block.
#
# THE DATA ON THE MEDIUM IS NOT TOUCHED, and the message says so. Removing a
# replica means stopping the job that feeds it; the copy on that disk is still a
# copy, and deciding it is worthless is not this command's call to make.
#
# REMOVING THE LAST JOB HAD TO GO THROUGH gen-cron.sh AND COULD NOT.
# Measured on pve9, 2026-08-30, tearing a lab down: the config held three
# replicas, two came out, and the third died with
#
#     gen-cron.sh: error: no send/prune/monitor rules resolved from ...
#     FATAL: gen-cron.sh could not render the proposed config -- nothing was touched
#
# leaving a scheduled job pointing at a dataset that no longer existed. That
# guard is RIGHT when someone hands gen-cron.sh an emptied config -- it is a
# config that lost its contents -- and wrong as the answer to "remove the last
# job", where empty is the requested result.
#
# remove-client solved exactly this and the fix here is to use its answer, not
# a second one: ask the shared cron writer to remove the zfs-backup-managed
# block, THEN swap the config. Cron first, for its reason: if the config
# swapped first and the cron removal then failed, the config would describe
# zero jobs while the real cron lines survived, with nothing left recording
# what they were.
cmd_remove_replica() {
    local name="" config="" do_install=0 assume_yes=0 a _ans
    for a in "$@"; do
        case "$a" in
            --config=*) config="${a#*=}" ;;
            --plan)     do_install=0 ;;
            --install)  do_install=1 ;;
            --yes|-y)   assume_yes=1 ;;
            -*)         die "remove-replica: unknown option '$a'" ;;
            *)          if [ -z "$name" ]; then name="$a"; else die "remove-replica: takes exactly one name"; fi ;;
        esac
    done
    [ -n "$name" ] || die "uzycie: zfs-backup.sh remove-replica NAZWA [--install]"
    local resolver_user; resolver_user="$(cron_target_user)"
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"
    [ -r "$config" ] || die "remove-replica: no readable config at $config"
    grep -qxF "[replica:$name]" "$config" \
        || die "remove-replica: there is no [replica:$name] in $config. 'zfs-backup.sh list-replicas' shows what is there."

    local cand; cand=$(mktemp) || die "mktemp failed"
    chmod 0644 "$cand" 2>/dev/null || :
    awk -v want="[replica:$name]" '
        $0 == want { skip=1; next }
        skip && /^[[]/ { skip=0 }
        skip { next }
        { print }
    ' "$config" > "$cand" || { rm -f "$cand"; die "could not compose the config without [replica:$name]"; }

    local empties_schedule=0
    config_has_job_sections "$cand" || empties_schedule=1

    if [ "$empties_schedule" -eq 1 ]; then
        echo
        echo "'$name' is the LAST job in $config."
        echo "Removing it leaves no send, prune or replica rule at all, so the whole"
        echo "zfs-backup-managed block would be removed from $(cron_target_user)'s crontab."
        echo "Nothing else in that crontab is touched, and no dataset is touched."
    else
        show_activation_proposal "$config" "$cand" || { rm -f "$cand"; die "gen-cron.sh could not render the proposed config -- nothing was touched"; }
    fi
    if [ "$do_install" -ne 1 ]; then
        echo
        echo "To jest wylacznie plan -- nic nie zostalo zainstalowane."
        echo "Aby zainstalowac: powtorz to samo polecenie z --install."
        rm -f "$cand"
        return 0
    fi
    if [ "$assume_yes" -ne 1 ]; then
        _ans=""
        read -rp "Zainstalowac powyzsze? [t/N] " _ans </dev/tty 2>/dev/null || _ans=""
        case "$_ans" in t|T|tak|TAK|y|Y|yes|YES) ;; *) rm -f "$cand"; die "not confirmed -- nothing was installed" ;; esac
    fi
    if [ "$empties_schedule" -eq 1 ]; then
        if ! cron_block_remove "$(cron_target_user)" zfs-backup-managed; then
            rm -f "$cand"
            die "remove-replica: could not remove the zfs-backup-managed cron block for $(cron_target_user): ${CRON_ERR:-unknown error} -- $config was NOT touched. Re-running remove-replica is safe once this is resolved."
        fi
        chmod 0644 "$cand" 2>/dev/null || :
        if ! mv -f "$cand" "$config"; then
            rm -f "$cand"
            die "remove-replica: the zfs-backup-managed cron block for $(cron_target_user) has ALREADY been removed, but $config could not be updated to match (it still describes '$name'). Fix whatever blocked the rename, then re-run remove-replica -- cron_block_remove is idempotent, only this config swap remains."
        fi
    else
        atomic_replace_and_install "$config" "$cand" \
            || die "remove-replica: the install failed -- see above. The config and crontab were rolled back together."
    fi
    log "replica '$name' removed from the schedule. The COPY on that medium was not touched -- it is still a copy; deleting it is a separate, deliberate act."
}

cmd_local_backup() {
    # target_given separates "the operator did not say" from "the operator said
    # NOTHING GOES ANYWHERE". Both leave $target empty and they mean opposite
    # things: omitted asks this tool to PROPOSE a destination, `--target=''` declares
    # there is none and the snapshots stay in the source. Without the flag the
    # two are indistinguishable, which is why absence could not simply be given
    # the second meaning -- every command an operator runs today would have
    # silently changed shape.
    #
    # The spelling mirrors CONFIG v4, which this command writes: `dst =` blank
    # is already the one field where empty means "no destination at all"
    # (lint_flags says exactly that), while every other field refuses a blank as
    # a mistake. CLI and generated config say the same thing the same way.
    local target="" target_given=0 profile="$PROFILE_DEFAULT_NAME" config=""
    # Slice 2: plan stays the DEFAULT. An operator who ran slice 1's command
    # yesterday gets byte-identical behaviour today; installing is an explicit verb.
    local do_install=0 assume_yes=0
    local local_user="" local_user_given=0 resolver_user=""
    local -a source_flags=()
    for a in "$@"; do
        case "$a" in
            --source=*)  source_flags+=("${a#*=}") ;;
            --target=*)  target="${a#*=}"; target_given=1 ;;
            --profile=*) profile="${a#*=}" ;;
            --config=*)  config="${a#*=}" ;;
            --plan)      do_install=0 ;;   # explicit form of the default
            --install)   do_install=1 ;;
            --yes|-y)    assume_yes=1 ;;
            # Who runs these jobs. Same flag, same grammar and the same default
            # as add-client, because it is the same question -- a LOCAL backup
            # was the one shape that could not answer it, and only because this
            # parser refused the word. Everything underneath was already
            # account-aware: cron_target_user, crontab_for_target,
            # assert_config_readable_by_target and atomic_replace_and_install
            # all key off LOCAL_USER, and gencron_as_target runs the ACCOUNT's
            # own checkout so the emitted lines carry its paths. Measured on
            # pve9 2026-08-20: `setup-server --local-user=zfsbackup` created the
            # account and the block still landed in root's crontab, because
            # nothing here ever set LOCAL_USER.
            --local-user=*) local_user="${a#*=}"; local_user_given=1 ;;
            *) die "local-backup: unknown option $a" ;;
        esac
    done
    # KROK 5: --source may now be omitted, and the resolution happens further
    # down -- after the target is known, because a candidate that lands inside
    # the target is not a candidate. The flag stays authoritative when given
    # (EXPLICIT-SOURCE-BEATS-DISCOVERY, REV-20260811-101): a proposal is only
    # ever consulted when the operator named nothing at all.
    local sources_from=""
    [ "${#source_flags[@]}" -gt 0 ] && sources_from=explicit

    # The account decision, resolved exactly as add-client resolves it: the flag
    # or root, never a host-wide setting. setup-server deliberately records no
    # account -- "who runs a relationship's jobs is decided per-relationship and
    # travels with it" -- and a local backup is not an exception to that, it was
    # simply left out of it.
    #
    # LOCAL_USER is a global on purpose: cron_target_user reads it, and every
    # account-aware helper below reads cron_target_user. Setting it here is what
    # makes the whole existing path point at the account instead of at root.
    if [ "$local_user_given" -eq 1 ]; then
        local_user_name_valid "$local_user"             || die "local-backup: --local-user='$local_user' is not a valid account name ($LOCAL_USER_GRAMMAR). Nothing was created."
        # Two variables on purpose. $local_user is blanked for root because the
        # account-creation and zfs-allow logic below keys on "is there an
        # account to delegate to", and root is not one. The RESOLVER needs the
        # opposite distinction -- an explicit "root" is an answer to "which
        # account", and collapsing it into "" makes it indistinguishable from
        # silence, which is what sends --local-user=root back into the very
        # refusal that recommends it.
        resolver_user="$local_user"
        [ "$local_user" = root ] && local_user=""   # literal 'root' means root runs them
    else
        log "local-backup: no --local-user -- these jobs will run as root; pass --local-user=NAME to delegate them to an account"
    fi
    LOCAL_USER="$local_user"

    # A missing account is handled differently by the two verbs, and the
    # difference is the plan's own contract: "without --install: plans and
    # previews, installs nothing". Creating a Unix account is not nothing.
    #
    #   --install : create it, the same folding-in the remote form does. It is a
    #               local root action the operator running this already has, and
    #               a loud line beats stopping to say "go run the other command".
    #   plan      : REFUSE. gen-cron bakes the running copy's paths into every
    #               line, so a preview of an account that does not exist can
    #               only be rendered from root's copy -- a block that will never
    #               be installed. Showing it would be worse than showing
    #               nothing, and this tree's stance is to refuse rather than
    #               display something untrue.
    if [ -n "$LOCAL_USER" ] && ! id -u "$LOCAL_USER" >/dev/null 2>&1; then
        if [ "$do_install" -eq 1 ]; then
            log "local-backup: account '$LOCAL_USER' does not exist -- creating it now (deploy.sh --backup-user=$LOCAL_USER)"
            bash "$DEPLOY" --backup-user="$LOCAL_USER" \
                || die "local-backup: deploy.sh --backup-user=$LOCAL_USER failed -- see above; nothing was installed"
        else
            die "local-backup: --local-user='$LOCAL_USER' names an account that does not exist on this host, so this plan cannot show you the block that would actually be installed -- gen-cron writes the running copy's paths into every line, and only that account's own checkout produces the right ones. Nothing was created. Either create it first (deploy.sh --backup-user=$LOCAL_USER) and re-run this plan, or run the same command with --install, which creates it as part of the deployment."
        fi
    fi

    # Slice 3: --target may be omitted. Propose one through the SAME helper
    # setup-server uses, then make the proposal visible and correctable. Two
    # provenances, treated differently on purpose:
    #
    #   default    -- server.conf's DEFAULT_TARGET, i.e. a decision the operator
    #                 already made deliberately by running setup-server;
    #   heuristic  -- this run guessed it from the pool layout.
    #
    # A guess may be proposed and shown; it may not be acted on with nobody
    # looking. So --yes does NOT cover a guessed target: the operator either names
    # the target or confirms it interactively. That keeps "do not silently choose a
    # destructive destination" a property of the code and not of the wording.
    local target_from=""
    # NO DESTINATION AT ALL -- the single-host shape. `--target=''` says the
    # snapshots stay where they are made: each tier creates its family and
    # prunes it in place, and nothing is ever transferred. gen-cron already
    # renders exactly that from a [dataset:] with no `dst` (measured: one
    # snapsend argument, no target), so this is the composer learning a shape
    # the generator has always had.
    #
    # Checked BEFORE the proposal below, because that is the whole distinction:
    # an omitted --target still asks for a destination to be proposed, and every
    # command written before today keeps meaning what it meant.
    local no_copy=0
    if [ "$target_given" -eq 1 ] && [ -z "$target" ]; then
        no_copy=1
        # Same guard the proposed values carry, extended to a third case rather
        # than invented for it: a value nobody typed twice must not install
        # unattended. `--target="$VAR"` with VAR unset produces this exact
        # argv, and the difference between "I meant no copy" and "my variable
        # was empty" is not visible from here -- so the preview is where it has
        # to be seen.
        [ "$do_install" -eq 1 ] && [ "$assume_yes" -eq 1 ]             && die "--target='' (no copy: snapshots stay in the source) will not install under --yes. An empty target is also what an unset shell variable expands to, so this one is confirmed by eye: re-run without --yes, or without --install to preview first."
    elif [ -z "$target" ]; then
        read_server_conf
        local proposal
        # `|| die`, never a pipe: the helper's own die() for ambiguous pools runs
        # in this substitution's subshell and cannot stop us by itself.
        proposal=$(propose_backup_target) || die "local-backup: no --target given and no target could be proposed -- see the reason above, or pass --target=POOL/PATH"
        target="${proposal%%$'\t'*}"
        target_from="${proposal##*$'\t'}"
        [ -n "$target" ] || die "local-backup: --target=<dataset> is required (where the backups land)"
        case "$target_from" in
            default)   log "no --target given -- using the configured default '$target' (server.conf DEFAULT_TARGET; pass --target= to override)" ;;
            heuristic) log "no --target given -- PROPOSING '$target', guessed from the pool layout (pass --target= to choose another)" ;;
        esac
    fi

    read_server_conf
    # Policy 'host': no relationship record to read from, and no adoption --
    # preserved exactly as it was, NOT quietly upgraded. Adding adoption here is
    # the P10 change and it belongs in its own commit with its own test, not
    # smuggled in under a refactor that claims to change no behaviour.
    #
    # This is also the caller that has real flags to pass, which is why they are
    # arguments to the resolver rather than something it goes looking for: a
    # decision layer that reads its caller's locals is not one home, it is five
    # again with a shared address.
    cron_context_resolve adopt "$config" "$resolver_user" "" ""
    config="$CRON_CTX_FILE"

    # KROK 5: no --source at all. Propose, and say plainly that this is a guess.
    #
    # Resolved HERE and not at parse time for two reasons that are both about
    # correctness rather than tidiness: a candidate is judged against the TARGET
    # (which may itself have just been proposed), and against the INSTALLED
    # CONFIG (which cron_context_resolve has only now decided). Proposing before
    # either is known would offer datasets that the next step refuses.
    #
    # The proposal feeds the SAME --source parser below, so an accepted proposal
    # and a typed --source travel one code path; there is no second notion of
    # what a source set is.
    if [ -z "$sources_from" ]; then
        local proposed _p _prc
        # An ambiguous subtree is not an error here: the proposal drops it,
        # says so precisely on stderr, and returns whatever else it found. The
        # only failure this call has left is an inventory it could not read.
        proposed=$(propose_backup_sources "$target" "$config"); _prc=$?
        [ "$_prc" -eq 0 ] || die "local-backup: no --source given and this host's ZFS inventory could not be read -- name the dataset(s) with --source=<dataset>[,<dataset>...]"
        [ -n "$proposed" ]             || die "local-backup: no --source given and nothing on this host is a sensible candidate (see the skip reasons above) -- name the dataset(s) explicitly with --source=<dataset>[,<dataset>...]"
        sources_from=heuristic
        log "brak --source -- PROPOZYCJA z inwentarza ZFS tego hosta (przekaz --source=..., zeby wybrac inaczej):"
        while IFS= read -r _p; do [ -n "$_p" ] && log "  $_p"; done <<< "$proposed"
        source_flags=("$(printf '%s' "$proposed" | tr '
' ',' | sed 's/,$//')")
    fi

    # REV-20260811-101: one or more explicit roots are the authoritative WHAT
    # (EXPLICIT-SOURCE-BEATS-DISCOVERY). The canonical form is a comma list in one
    # --source; repeated --source flags are normalized into the SAME set rather
    # than the silent last-one-wins the scalar parser had. Split on commas, trim,
    # and de-duplicate exact repeats into one root list before anything is planned.
    local -a roots=(); local sv r u seen
    for sv in "${source_flags[@]}"; do
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            seen=0
            for u in ${roots[@]+"${roots[@]}"}; do [ "$u" = "$r" ] && { seen=1; break; }; done
            [ "$seen" -eq 0 ] && roots+=("$r")
        done < <(dataset_list_split "$sv")
    done
    [ "${#roots[@]}" -gt 0 ] || die "local-backup: --source resolved to no dataset name"

    # Skipped when there is no target: both checks ask "is this destination
    # well formed", and no-copy has no destination to ask about.
    if [ "$no_copy" -eq 0 ]; then
        case "$target" in *[!A-Za-z0-9_./:-]*|/*|*/) die "local-backup: --target='$target' is not a plain dataset name" ;; esac
        case "$target" in *:*) die "local-backup is LOCAL only -- --target='$target' names a remote host (contains ':'). Use add-client/activate-client for a remote pull." ;; esac
    fi
    case "$profile" in ""|*[!A-Za-z0-9_-]*) die "local-backup: --profile='$profile' is not a valid profile name" ;; esac

    # Every root: plain name, LOCAL, and it must EXIST (REV-097 F1). One missing
    # or invalid root refuses the WHOLE request -- no partial candidate for the
    # valid members.
    for r in "${roots[@]}"; do
        case "$r" in *[!A-Za-z0-9_./:-]*|/*|*/) die "local-backup: --source member '$r' is not a plain dataset name" ;; esac
        case "$r" in *:*) die "local-backup is LOCAL only -- --source member '$r' names a remote host (contains ':')." ;; esac
        zfs list -H -o name -- "$r" >/dev/null 2>&1 \
            || die "local-backup: source '$r' does not exist on this host (zfs list found nothing). Every explicit source must exist -- refusing the whole request, no fallback, no partial plan."
    done

    # Overlap refusals before any composition: no root may land inside the target
    # (self-reference), and no root may contain or equal another (parent/child in
    # the explicit set) -- refuse rather than invent precedence.
    # Vacuous without a destination: nothing lands anywhere, so nothing can
    # land inside its own source. The root-versus-root checks below still
    # run -- two sources that contain one another are still a mistake.
    if [ "$no_copy" -eq 0 ]; then
        for r in "${roots[@]}"; do
            local_backup_overlap "$r" "$target" \
                && die "local-backup: --target='$target' overlaps source '$r' (equal, or one nested in the other) -- a backup cannot land inside the thing it backs up."
        done
    fi
    local i j
    for ((i=0; i<${#roots[@]}; i++)); do
        for ((j=i+1; j<${#roots[@]}; j++)); do
            local_backup_overlap "${roots[i]}" "${roots[j]}" \
                && die "local-backup: sources '${roots[i]}' and '${roots[j]}' overlap (equal or parent/child) -- refusing; the high-level path will not invent precedence between overlapping roots."
        done
    done

    # Choose the preset. load_active_profile calls profile_validate_file, which
    # refuses a profile carrying any relationship-owned field before it can reach
    # a config, and dies with the profile named if it does not exist.
    PROFILE_ACTIVE="$profile"
    load_active_profile

    # REV-20260810-097 F2 (unchanged): the candidate is the ACTUAL ADDITIVE result
    # over the installed target CONFIG. Copy the existing config, or -- if missing
    # -- apply the shared fail-closed guard before inventing one; ensure_cron_config
    # then adds the profile templates/floors idempotently.
    local cand; cand=$(mktemp) || die "mktemp failed"
    # mktemp gives 0600 and this file is rendered by the TARGET ACCOUNT, not by
    # root -- gencron_as_target runs the account's own gen-cron on it. At 0600 it
    # simply could not be read, and the failure surfaced as gen-cron saying "no
    # sections found", which reads like a malformed config rather than a
    # permission problem. Found the moment a delegated local backup first ran for
    # real on pve9.
    #
    # 0644 is what the INSTALLED config carries at /etc/zfs-snapshot-all, so this
    # matches it rather than inventing a looser mode: a job config names datasets
    # and schedules, never a secret, and the account has to read it every run.
    chmod 0644 "$cand" 2>/dev/null || :
    if [ -f "$config" ]; then
        cp -p "$config" "$cand" || { rm -f "$cand"; die "could not read the existing config $config to plan against it"; }
    else
        assert_config_not_claimed_if_missing "$config"
        printf '[defaults]\n\thost_label = %s\n' "$COLLECTOR_LABEL" > "$cand" \
            || { rm -f "$cand"; die "could not create the candidate config"; }
    fi
    ensure_cron_config "$cand" 1 1

    # WHOSE coverage is already there -- the question the overlap check never
    # asked, and the reason two KROK 5 blockers looked like one refusal.
    #
    # A requested root falls into exactly one of three buckets:
    #
    #   ours      an installed [dataset:<root>] this tool wrote, sending to THIS
    #             same target. Nothing to do for it -- and nothing to refuse
    #             either, which is what makes an identical rerun a no-op;
    #   new       no section at all. This is the one to compose and install;
    #   disputed  a section exists but it is NOT ours, or it is ours and points
    #             at a DIFFERENT target. Fail-closed, unchanged: it goes into
    #             the overlap scan below and produces the same refusal it always
    #             did. A stranger's policy is not ours to extend, and "same
    #             source, other target" is a different request, not a rerun.
    local -a new_roots=() have_roots=() scan=()
    local _mk _dst
    for r in "${roots[@]}"; do
        if ! grep -qxF "[dataset:$r]" "$cand"; then
            new_roots+=("$r"); scan+=("$r"); continue
        fi
        _mk="$(local_backup_section_marker "$cand" "[dataset:$r]")"
        _dst="$(installed_dataset_field "$cand" "$r" dst)"
        if [ "$_mk" = "source=$r" ] && [ "$_dst" = "$target" ]; then
            have_roots+=("$r")
        else
            scan+=("$r")
        fi
    done

    # Refuse when a DISPUTED root, or the target, overlaps a section already
    # installed -- "add B, do not mutate A" (Gate 2). Nothing is written on
    # refusal.
    # The TARGET is the one requested path this run covers RECURSIVELY (its
    # retention is emitted `recursive = yes`), so it is named as such; the
    # sources are written flat and must not pretend to reach their children.
    # With no destination there is no recursively-claimed target path -- the
    # only coverage this run asserts is over its SOURCES, written flat.
    local conflict
    if [ "$no_copy" -eq 1 ]; then
        conflict="$(config_section_overlap "$cand" "" ${scan[@]+"${scan[@]}"})"
    else
        conflict="$(config_section_overlap "$cand" "$target" ${scan[@]+"${scan[@]}"} "$target")"
    fi
    # ...except this tool's own target retention for this very target. It is the
    # same store, written by this same command, and treating it as foreign is
    # exactly what made a second source impossible to add.
    local _tmk; _tmk="$(local_backup_section_marker "$cand" "[prune:$target]")"
    if [ "$_tmk" = "target=$target" ] && [ -n "$conflict" ]; then
        conflict="$(printf '%s' "$conflict" | grep -vF "  [prune:$target] ")"
        [ -z "${conflict//[[:space:]]/}" ] && conflict=""
    fi
    if [ -n "$conflict" ]; then
        rm -f "$cand"
        die "local-backup: a job for these sources / target '$target' would overlap coverage already in $config:$conflict
Nothing has been changed. Two jobs covering the same datasets would send and prune the same snapshots under different policy. If the overlap is intended, express it in native CONFIG v4 by hand; the high-level path deliberately will not."
    fi

    # IDEMPOTENT RERUN. Every requested root is already installed against this
    # target, so the durable state the operator asked for exists: say so and
    # stop. Not a re-render and not a re-seed -- re-seeding would take a fresh
    # snapshot and reinstall cron for a relationship that is already running,
    # which is a change disguised as a repetition. Same contract the four-command
    # remote path was given in KROK 3: a completed step repeats as a clean no-op.
    if [ "${#new_roots[@]}" -eq 0 ]; then
        rm -f "$cand"
        log "local-backup: zrodla ${roots[*]} sa juz zainstalowane w $config dla celu '$target' -- nic do zrobienia."
        echo
        echo "Backup lokalny JUZ AKTYWNY (bez zmian)."
        echo "  Zrodla:  ${roots[*]}"
        echo "  Cel:     $target"
        echo "  Config:  $config"
        return 0
    fi

    # From here on only the NEW roots are composed. An already-installed root
    # must not be emitted a second time: gen-cron refuses a duplicate section,
    # and re-emitting would also silently overwrite an operator's edits to the
    # policy that root is running under.
    roots=("${new_roots[@]}")

    # One independent [dataset:] per root (each sending to the target; dst=<target>
    # with no ':' is snapsend.sh's local-to-local branch). Then TWO independent
    # retention policies (REV-20260811-102), both initialized from the same GFS
    # ladder but rendered as separate, separately-editable sections:
    #   * SOURCE retention -- one [prune:<root>] per root, bounding the tool-owned
    #     automated_hourly_ snapshots the send creates ON THE SOURCE (without this
    #     the source pool fills, since standard_hourly does not self-prune);
    #   * TARGET retention -- one recursive [prune:<target>] over the store.
    # Only the tool-owned pattern is matched, so manual/foreign snapshots survive;
    # source and target are disjoint scopes (validated above), never coupled.
    # One minute per source, chosen once here, exactly as a relationship gets
    # one at create. Two reasons, and the second one is not cosmetic:
    #
    #   * two sources copying into the same store at the same minute compete for
    #     the same disks and the same pool, which is the stampede the stagger
    #     exists to end;
    #   * gen-cron MERGES datasets that resolve to the same (send_schedule, dst,
    #     prefix, flags) into ONE cron line. Adding a second source therefore
    #     rewrote the first source's line into a two-dataset one -- and the
    #     anti-deletion guard, correctly, called the old line deleted and
    #     refused the install. Measured live on pve9: seed of the second source
    #     succeeded, the install refused, nothing was left half-installed. A
    #     distinct minute keeps every line's identity stable, so adding a source
    #     leaves the existing lines untouched instead of arguing with a safety
    #     guard about whether a merge is a deletion.
    # Resolved BEFORE the emit block, once per root, because the same minute has
    # to reach two sections ([dataset:] and [prune:]) written in two separate
    # loops -- and because schedule_pick_minute reads the INSTALLED state, which
    # cannot see the sections this very run is about to add. Minutes already
    # handed out in this run are therefore tracked here, or two new sources
    # would be given the same one and merge exactly as before.
    local -A LB_SEND=() LB_PRUNE=()
    local _lb_min _lb_pmin _lb_used=" "
    for r in "${roots[@]}"; do
        _lb_min=$(schedule_pick_minute "local-backup:$r")
        while :; do
            case "$_lb_used" in
                *" $_lb_min "*) _lb_min=$(( (_lb_min + 1) % 60 )) ;;
                *) break ;;
            esac
        done
        _lb_used="$_lb_used$_lb_min "
        _lb_pmin=$(( (_lb_min + 20) % 60 ))
        LB_SEND[$r]="$(schedule_with_minute "$(schedule_template_expr send)" "$_lb_min")"
        LB_PRUNE[$r]="$(schedule_with_minute "$(schedule_template_expr prune)" "$_lb_pmin")"
    done

    {
        for r in "${roots[@]}"; do
            echo
            echo "[dataset:$r]"
            echo "	# managed-by: zfs-backup.sh local-backup source=$r"
            profile_emit "$PROFILE_DS_FILE"
            [ -n "${LB_SEND[$r]}" ] && echo "	send_schedule = ${LB_SEND[$r]}"
            # No `dst` line at all when nothing is copied. gen-cron reads an
            # absent dst as "create a snapshot and transfer nothing" -- the
            # same shape a hand-written single-host config has always used.
            [ "$no_copy" -eq 0 ] && echo "	dst          = $target"
            echo "	notify       = local-$(basename "$r")"
        done
        # Retention, not shape -- the same F1 correction as the remote path. A
        # local backup stamps the SAME four families on its source datasets, and
        # a flat profile bounded none of them there either.
        local LB_RETFRAG=""
        profile_reload_if_stale
        LB_RETFRAG="$(profile_retention_fragment)" || LB_RETFRAG=""
        if [ -n "$LB_RETFRAG" ]; then
            # REV-20260811-104 F1: SOURCE and TARGET retention must be independently
            # editable after CREATE, not two scopes sharing one template authority.
            # ensure_cron_config already put the target's prune templates in the
            # candidate; here we emit a DISTINCT source family, byte-copied from the
            # same values but under its own stable identity, so editing a source
            # retain in the candidate changes only the source cron line and target
            # retain only the target. REV-20260811-106 F1: the family is derived from
            # the templates the profile's prune fragment ACTUALLY references, not
            # from a `keep_*` naming convention, and fails closed if one is missing.
            emit_source_template_family "$LB_RETFRAG" "$cand"
            for r in "${roots[@]}"; do
                echo
                echo "[prune:$r]"
                echo "	# managed-by: zfs-backup.sh local-backup source-retention=$r"
                # REV-102 F2: source prune scope follows the (non-recursive) source
                # coverage -- delsnaps without -R, exactly the named dataset, never
                # walking into children like $r/vm-101 that this job does not back
                # up. REV-104 F1 / REV-106 F1: point use_template at the SOURCE
                # family (profile-agnostic rewrite) so its retention is independent
                # of the target's for ANY profile.
                emit_source_prune_fragment "$LB_RETFRAG"
                # Same reason as the send line: without its own minute, two
                # source prunes with identical policy merge into one delsnaps
                # line and the first one's identity changes underneath the
                # anti-deletion guard.
                [ -n "${LB_PRUNE[$r]}" ] && echo "	prune_schedule = ${LB_PRUNE[$r]}"
                echo "	notify       = local-src-$(basename "$r")"
            done
            # Once per target, not once per run: a second source landing in the
            # same store is covered by the retention that is already there, and
            # emitting it again would be a duplicate section gen-cron refuses --
            # while also discarding whatever the operator had edited into it.
            if [ "$no_copy" -eq 0 ] && ! grep -qxF "[prune:$target]" "$cand"; then
                echo
                echo "[prune:$target]"
                echo "	# managed-by: zfs-backup.sh local-backup target=$target"
                profile_emit "$PROFILE_PRUNE_FILE"
                echo "	recursive    = yes"
                echo "	notify       = local-$(basename "$target")"
            fi
        fi
    } >> "$cand" || { rm -f "$cand"; die "could not write the candidate config" ; }

    # Rendered through gencron_as_target, not `bash $GENCRON`, so the preview is
    # produced by the SAME identity and the same checkout that the install will
    # use. gen-cron derives its repo paths from where it lives, so root's copy
    # emits /root/scripts/... into every line while a delegated run emits
    # /home/<acct>/... -- a preview from the wrong copy is a preview of a block
    # that will never exist. Harmless while local backups could only be root;
    # not harmless the moment they can be delegated.
    if ! gencron_as_target -c "$cand" >/dev/null 2>"$cand.err"; then
        warn "$(cat "$cand.err" 2>/dev/null)"; rm -f "$cand" "$cand.err"
        die "the additive candidate config was rejected by gen-cron.sh (see above) -- refusing; $config was NOT touched"
    fi
    rm -f "$cand.err"

    echo
    echo "Plan lokalnego backupu (PODGLAD -- nic nie zostalo zainstalowane):"
    echo "  Zrodla (WHAT):    ${roots[*]}"
    echo "  Cel:              $target"
    for r in "${roots[@]}"; do
        local_backup_same_pool "$r" "$target" \
            && echo "  Uwaga:            zrodlo '$r' i cel dziela pule '${target%%/*}' -- awaria puli dotknie oba (to fakt, nie zakaz)"
    done
    echo "  Preset:           $profile"
    # REV-102: the two independent retention policies, both from the same preset
    # ladder at CREATE, editable separately in the candidate before install.
    local ladder
    ladder="$(grep -oE 'retain *= *-[HDWMY][0-9]+' "$PROFILE_TPL_FILE" 2>/dev/null | grep -oE '\-[HDWMY][0-9]+' | tr '\n' ' ')"
    echo "  Retencja ZRODLA:  GFS ${ladder:-(patrz profil)}(na kazdym zrodle -- ogranicza automated_hourly_ na produkcji)"
    echo "  Retencja CELU:    GFS ${ladder:-(patrz profil)}(na magazynie -- NIEZALEZNA; edytuj osobno w kandydacie przed instalacja)"
    echo "  Config docelowy:  $config$([ -f "$config" ] && echo ' (istnieje -- plan jest ADDYTYWNY: stare joby zachowane)' || echo ' (nowy)')"
    echo
    echo "--- kandydat CONFIG v4 (pelny: istniejace + nowy job) ---"
    cat "$cand"
    echo
    echo "--- wygenerowany blok crona (gen-cron.sh -c, pelny) ---"
    gencron_as_target -c "$cand"
    if [ "$do_install" -ne 1 ]; then
        echo
        echo "To jest wylacznie plan -- nic nie zostalo zainstalowane."
        echo "Aby zainstalowac: powtorz to samo polecenie z --install."
        rm -f "$cand"
        return 0
    fi

    # ---- slice 2: the transactional install -------------------------------------
    #
    # Order is the whole contract here: preview -> confirm -> SEED -> install.
    # The seed runs BEFORE any cron is installed, because the acceptance property
    # is that a failed or declined seed leaves no newly eligible managed cron and
    # stays retryable. Installing first and seeding after would leave an hourly
    # job pointing at a relationship that was never established -- the failure
    # mode this ordering exists to prevent.
    #
    # No new orchestration: preview, the four pre-install assertions and the
    # atomic swap are the SAME helpers activate-client uses. No durable local
    # relationship record is written either -- CLIENTS_DIR holds remote client
    # records, there is no local equivalent, and the installed CONFIG plus the
    # installed cron block already ARE the state (CONFIG is runtime truth
    # everywhere else in this tool). "active" is therefore a derived description,
    # not a stored token; inventing one for this slice is exactly what the plan
    # says not to do.
    show_activation_proposal "$config" "$cand" || {
        rm -f "$cand"
        die "gen-cron.sh could not render the proposed config -- nothing was touched"
    }

    # Slice 3's one hard rule: a GUESSED target never installs unattended. An
    # operator who named the target, or recorded one with setup-server, may use
    # --yes; a pool-layout guess has to be looked at by a human.
    if [ "$target_from" = heuristic ] && [ "$assume_yes" -eq 1 ]; then
        rm -f "$cand"
        die "local-backup: --yes cannot confirm a target this run GUESSED ('$target', from the pool layout). Name it with --target=$target if that is what you meant, or record it once with setup-server. Nothing was touched."
    fi

    # KROK 5, and the same rule for the same reason: a source set this run
    # PROPOSED is a guess about what matters on this host, and a guess does not
    # get installed with nobody looking. The operator either accepts it here, in
    # front of the rendered plan, or names the set with --source=.
    if [ "$sources_from" = heuristic ] && [ "$assume_yes" -eq 1 ]; then
        rm -f "$cand"
        die "local-backup: --yes cannot confirm a source set this run PROPOSED (${roots[*]}). Name them with --source=$(printf '%s' "${roots[*]}" | tr ' ' ',') if that is what you meant. Nothing was touched."
    fi

    if [ "$assume_yes" -ne 1 ]; then
        local ans
        [ "$sources_from" = heuristic ]             && log "zrodla powyzej sa PROPOZYCJA tego przebiegu, nie Twoim wyborem -- potwierdzajac, akceptujesz ten zestaw"
        read -rp "Zainstalowac ten backup lokalny? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) rm -f "$cand"; die "not confirmed -- $config was NOT touched, nothing installed" ;;
        esac
    fi

    # SEED: one real first send per root, through the same engine and the same
    # argument shape the generated cron line uses. A dry-run would not establish
    # the relationship, and the boundary asks for an established seed, not a
    # rehearsal. Failure here is terminal for this run and changes nothing --
    # re-running the identical command is the retry.
    # The snapshot prefix is NOT a constant here. It belongs to the profile's
    # template, and hardcoding a second copy of it is how the seed would silently
    # drift from the cron line it is supposed to establish. Read it back out of
    # the rendered candidate -- the same render the operator just approved -- and
    # fail closed if the line cannot be found, rather than seeding with a guess
    # that would create a snapshot family the installed job never prunes.
    local seed_prefix rendered_send
    rendered_send="$(gencron_as_target -c "$cand" 2>/dev/null | grep -F 'snapsend.sh' | grep -F -- "$target" | head -1)"
    # `[^"]*` rather than `.*` before -m: sed is greedy, so a leading `.*` would
    # bind to the LAST -m on the line. Refusing to cross a quote anchors this to
    # the send's own -m.
    #
    # Anchored at the engine's own name since 2026-08-17. This used to rely on
    # the send's -m being the FIRST quoted token on a generated line, which the
    # ZFS-JOB BEGIN marker ended: its label is now quoted and comes first, so the
    # match could no longer start at column 0. `s///` only replaces what it
    # matched, so everything left of the match survived into the result and the
    # prefix came back as
    #   `7 * * * * echo "$(date -Is) ZFS-JOB BEGIN h hourly backup"automated_`
    # -- non-empty, so the fail-closed guard below waved it through, and the seed
    # would have created a snapshot family the installed prune never matches.
    # Anchoring on `snapsend.sh` states the real invariant (the -m that belongs
    # to the send is the first one AFTER the send's own script name) instead of
    # an incidental fact about column order, and keeps the no-crossing-a-quote
    # property that stops it binding to a later -m.
    seed_prefix="$(printf '%s' "$rendered_send" | sed -n 's/^.*snapsend\.sh[^"]*-m[ ]*"\([^"]*\)".*/\1/p')"
    [ -n "$seed_prefix" ] || { rm -f "$cand"; die "could not read the snapshot prefix back out of the rendered cron line -- refusing to seed with a guessed prefix; $config was NOT touched"; }

    # DELEGATE BEFORE SEEDING, and delegate BOTH ends. A local backup reads the
    # source and writes the target on the same host, so a delegated account
    # needs permissions on each; the remote form only ever had to grant the
    # receive side, because the send side lives on the peer and is granted there
    # by --commit-scope.
    #
    # Before the seed rather than after, for the reason the whole install is
    # ordered this way: the seed runs as this account too, and a grant that
    # arrives afterwards would make the first transfer the one thing that only
    # works when run by root. Failing here costs nothing -- the config is still
    # a candidate and the crontab is untouched.
    # The TARGET is the landing parent and it need not exist yet -- the first
    # receive is what usually creates it. Granting on a dataset that is not
    # there fails, and granting on its parent instead would hand the account
    # the whole pool. So it is created explicitly first, narrow and empty, and
    # the grant lands exactly where the jobs will write. Same shape the remote
    # form uses for a sync landing parent, made explicit rather than assumed.
    if [ -n "$LOCAL_USER" ]; then
        local _ds
        if ! zfs list -H -o name -- "$target" >/dev/null 2>&1; then
            zfs create -p -- "$target" \
                || { rm -f "$cand"; die "local-backup: could not create the target '$target' to delegate it to '$LOCAL_USER' -- NOTHING was installed and $config is untouched"; }
            log "local-backup: created the landing target '$target' (it did not exist; the grant needs something to land on)"
        fi
        for _ds in "${roots[@]}" "$target"; do
            zfs allow -u "$LOCAL_USER" "$ZFS_PERMS_LOCAL_RECEIVE" -- "$_ds" \
                || { rm -f "$cand"; die "local-backup: zfs allow ($ZFS_PERMS_LOCAL_RECEIVE) on '$_ds' for '$LOCAL_USER' failed -- NOTHING was installed and $config is untouched. Without it the installed jobs would fail every run."; }
        done
        log "local-backup: delegated ($ZFS_PERMS_LOCAL_RECEIVE) to '$LOCAL_USER' on ${#roots[@]} source(s) and on '$target'"
    fi

    log "seed: pierwsza wysylka kazdego zrodla, prefiks '$seed_prefix' (to moze potrwac)..."
    local seed_failed=0 sr
    for sr in "${roots[@]}"; do
        if bash "$SNAPSEND" -m "$seed_prefix" -v 3 "$sr" "$target"; then
            log "  OK: $sr -> $target"
        else
            warn "  FAILED: $sr -> $target"
            seed_failed=$((seed_failed + 1))
        fi
    done
    if [ "$seed_failed" -ne 0 ]; then
        rm -f "$cand"
        die "$seed_failed zrodlo/zrodla nie przeszly seeda -- NIC nie zainstalowano, $config nietkniety. Napraw przyczyne i powtorz to samo polecenie."
    fi

    # Same pre-install assertions as activate-client, in the same order: a config
    # that disagrees with what is installed, a managed block belonging to another
    # config, a clobbered foreign block, or a config the cron target cannot read
    # each abort before the swap.
    assert_cron_config_matches_installed "$config"
    assert_no_foreign_managed_block "$cand"
    assert_target_block_not_clobbered "$cand"
    assert_config_readable_by_target "$config"
    atomic_replace_and_install "$config" "$cand"

    # Read-back: the installed crontab must actually contain the managed block for
    # this target. atomic_replace_and_install already restores on an --install
    # failure, so this catches the remaining case -- install reported success and
    # the block still is not there.
    local installed_block
    installed_block="$(crontab_for_target 2>/dev/null | sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p')"
    printf '%s' "$installed_block" | grep -qF -- "$target" \
        || die "instalacja zglosila sukces, ale odczyt zwrotny nie znalazl '$target' w zainstalowanym bloku -- sprawdz crontab recznie zanim uznasz backup za dzialajacy"

    echo
    echo "Backup lokalny AKTYWNY."
    echo "  Zrodla:  ${roots[*]}"
    # Named separately rather than folded into the line above: this run neither
    # seeded nor re-rendered them, and reporting them as though it had would be
    # the report claiming work it did not do.
    [ "${#have_roots[@]}" -gt 0 ] && echo "  Juz bylo: ${have_roots[*]} (bez zmian -- ani seeda, ani nowej sekcji)"
    echo "  Cel:     $target"
    echo "  Config:  $config"
    echo "  Seed:    OK (${#roots[@]} zrodlo/zrodel wyslane)"
    echo "  Cron:    zainstalowany i odczytany zwrotnie"
}

# ------------------------------------------------------------------------------
cmd_add_client() {
    local name="${1:-}"; shift || true
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    local lan="" datasets="" target="" bandwidth="" mode="" join_remotely=0 profile="" endpoint_option=""
    # LAB6 pass 7 F-1: the dataset the caller NAMED for a mode-based
    # relationship. Not --datasets (which would be a second, conflicting answer
    # to "what is the list", and --mode refuses it): the list still comes from
    # the source's committed scope. This only tells the source what was asked
    # for, so its draft can default to that instead of to every pool it has.
    local requested=""
    # See the note in the one-command form: 'atomic' was unreachable, which made
    # the engines' -r a mode the product could describe but never install.
    local recursion="" passive=0 exclude_family=""
    # Same disease, same cure. -X lived only in a hand-edited `flags`, and the
    # anti-deletion guard then refused every future activation of that client:
    # the regenerated job has no -X, so the installed one reads as a job about
    # to stop running. Measured on the lab -- the line the guard named WAS the
    # -X line. An exclusion has to be a recorded decision or it is a one-way door.
    local -a excludes=()
    # Batch B: the account is a DECISION, never a silent default. Empty here means
    # "not stated on the command line"; the resolution below decides what that
    # means, and refuses rather than guessing.
    local local_user="" local_user_given=0
    for a in "$@"; do
        case "$a" in
            --host=*|--lan=*)
                           [ -z "$endpoint_option" ] \
                               || die "add-client: pass exactly one endpoint option (--host is the normal form; --lan is the legacy alias)"
                           endpoint_option="${a%%=*}"
                           lan="${a#*=}" ;;
            --datasets=*)  datasets="${a#*=}" ;;
            --requested=*) requested="${a#*=}" ;;
            --recursive=*) recursion="${a#*=}" ;;
            --passive)     passive=1 ;;
            --exclude-family=*) exclude_family="${a#*=}" ;;
            --exclude-child=*) excludes+=("${a#*=}") ;;
            --mode=*)      mode="${a#*=}" ;;
            --target=*)    target="${a#*=}" ;;
            --bandwidth=*) bandwidth="${a#*=}" ;;
            --profile=*)   profile="${a#*=}" ;;
            --join-remotely) join_remotely=1 ;;
            --local-user=*) local_user="${a#*=}"; local_user_given=1 ;;
            *) die "add-client: unknown option $a" ;;
        esac
    done
    # Phase 4: CREATE-time choice only. Validated now, at enrolment, so a
    # typo'd/nonexistent profile fails before any pairing or key exchange
    # happens, not silently at the first activate-client. Zero-choice default
    # unchanged: an operator who never heard of profiles gets exactly the
    # same "default" behaviour as before this flag existed.
    [ -n "$profile" ] || profile="$PROFILE_DEFAULT_NAME"
    profile_validate_file "$(profile_file "$profile")" "$GENCRON" \
        || die "add-client: --profile='$profile': $PROFILE_ERR"
    [ -n "$lan" ] || die "add-client requires --host=HOST[:PORT] (the address used for the initial seed)"
    # The ordinary product path is backup. Dataset discovery belongs to the
    # source-side guided --join, so the collector no longer has to spell out
    # either an internal mode name or datasets it cannot be expected to know.
    # Explicit --datasets remains the expert/legacy path and explicit sync
    # remains available for the deliberately different same-path semantics.
    if [ -z "$mode" ] && [ -z "$datasets" ]; then
        mode=backup
    fi
    # REV-20260802-033 slice 6: --mode is the alternative to --datasets --
    # dataset selection deferred to the source's own scope file
    # (--draft-scope/--commit-scope on the peer) instead of named here.
    if [ -n "$mode" ]; then
        [ -z "$datasets" ] \
            || die "add-client: --mode and --datasets are alternative ways of choosing what to back up -- pass exactly one"
        case "$mode" in
            backup|sync) ;;
            *) die "add-client: --mode must be 'backup' or 'sync', got '$mode'" ;;
        esac
        # sync reproduces the source's own paths at the same paths on the
        # collector -- a --target here would be a second, conflicting answer
        # to "where does this go".
        [ "$mode" = sync ] && [ -n "$target" ] \
            && die "add-client: --mode=sync reproduces source paths at the same paths on the collector -- do not also pass --target"
    else
        [ -n "$datasets" ] || die "add-client requires --datasets=\"A B\" (or --mode=backup|sync, to let the source choose)"
    fi
    # Refused rather than ignored. Without a mode the list is --datasets and a
    # separate "what was asked for" would be a second answer to a question
    # already answered -- exactly the ambiguity deploy.sh's package validator
    # refuses on the far side, stated here so it fails at the command line
    # instead of two hosts later.
    [ -z "$requested" ] || [ -n "$mode" ] \
        || die "add-client: --requested= only means something with --mode= (it narrows the scope DRAFT the source writes for a deferred dataset list); with --datasets= the datasets already are the request"
    # ATOMIC AND SOURCE RETENTION ARE INSEPARABLE, so the choice is stated once,
    # here, and carried on the record -- not rediscovered by a guard three
    # commands later. Under -r the engines keep no bookmark: they neither record
    # nor consult one. Let managed source retention age out the last ordinary
    # common snapshot and the relationship stops permanently, until a
    # destructive re-seed. So enrolling atomic DECLINES source retention, and
    # says so out loud rather than quietly omitting a section.
    case "$recursion" in
        ""|flat|atomic) ;;
        no) die "add-client: --recursive=no is not a relationship shape this layer installs -- a scope root is replicated either per-dataset (flat, the default) or as one stream (atomic). Omit the flag for flat." ;;
        *)  die "add-client: --recursive must be 'flat' or 'atomic', got '$recursion'" ;;
    esac
    # The engines refuse -X without -R rather than ignoring it, so refusing the
    # same combination here means the operator hears it at the command line
    # instead of at 01:00 every night.
    [ "${#excludes[@]}" -eq 0 ] || [ "$recursion" != atomic ]         || die "add-client: --exclude-child needs per-dataset recursion. Under --recursive=atomic the subtree is ONE zfs send -r stream and there is nowhere in it to filter -- the engine refuses -X under -r rather than ignoring it. Drop --recursive=atomic to exclude, or drop --exclude-child to keep one atomic stream."
    # BYTES per second, with the usual k/M/G suffixes -- snapsend/snapget hand
    # this to mbuffer -r, which is a byte rate. Validated here rather than at
    # the far end of a generated cron line, where a typo becomes a nightly
    # failure mail instead of an error you can see now.
    if [ -n "$bandwidth" ]; then
        # The accepted set is THE ENGINE'S set (snapsend/snapget:
        # ^[0-9]+[bkKmMgG]?$), transcribed, not approximated. The previous
        # approximation disagreed in both directions (basket B8): '100b' was
        # legal to the engine and refused here, while '2M0' passed here, was
        # written into the client record, rebuilt into the cron line, and the
        # engine refused it EVERY NIGHT -- a validator stricter than its
        # engine trades one visible error now for an invisible one forever.
        assert_bandwidth_rate "$bandwidth" add-client
    fi

    # A declared-passive relationship defaults to the PASSIVE profile: its
    # templates are prefixless and its monitors run in any-mode -- the only
    # shape that matches the declaration. An explicit --profile= still wins.
    if [ "$passive" -eq 1 ] && [ "$profile" = "$PROFILE_DEFAULT_NAME" ]; then
        profile=passive
    fi

    local cpath; cpath=$(client_conf_path "$name")
    if [ -e "$cpath" ]; then
        # A record whose last STATE is 'removed' is a TOMBSTONE, not a live
        # relationship, and the two halves of the lifecycle disagreed about
        # that. remove-client deliberately KEEPS the file and appends
        # STATE=removed (it is the relationship's own history); add-client
        # refused on the file's mere existence. So a name could never be reused
        # after a normal teardown, and the refusal told the operator to run
        # "remove-client" -- which they had just run, and which would have
        # changed nothing. Found live on 2026-08-23 running the four-command
        # trial of issue #9 a second time.
        #
        # Every other scanner in this file already treats STATE=removed as
        # "not a relationship" (see the coverage-overlap probe); this makes
        # add-client agree with them.
        local _prev_state
        _prev_state=$( . "$cpath" >/dev/null 2>&1; printf '%s' "${STATE:-unknown}" )
        if [ "$_prev_state" = removed ]; then
            # Archived, not deleted, and deliberately NOT matching *.conf so no
            # scanner picks it up as a live record.
            local _arch="${cpath}.removed-$(date '+%Y%m%d-%H%M%S')"
            mv -f "$cpath" "$_arch"                 || die "client '$name' was removed earlier, but its old record $cpath could not be archived -- refusing to create a new relationship on top of it"
            log "name '$name' was used by a relationship that has been removed -- its record is kept as $_arch and the name is reused"
        else
            # IDEMPOTENT RERUN (contract of issue #9: "rerun resumes from
            # durable state", "clean rerun showing idempotent resume").
            # Repeating the four-command flow after an interruption -- or after
            # it already finished -- must not stop at step 1. A repeat that
            # asks for exactly what the record already says is a no-op, not an
            # error; a repeat that asks for something DIFFERENT is still a
            # refusal, because that is an operator changing a live
            # relationship by rerunning a creation command.
            local _same=1 _prev_host _prev_target _prev_user
            _prev_host=$( . "$cpath" >/dev/null 2>&1; printf '%s' "${PEER_HOST:-}" )
            _prev_target=$( . "$cpath" >/dev/null 2>&1; printf '%s' "${CLIENT_TARGET:-}" )
            _prev_user=$( . "$cpath" >/dev/null 2>&1; printf '%s' "${LOCAL_USER:-}" )
            # $lan is the RAW --host argument here; lan_host/lan_port are
            # parsed 120 lines further down, long after this gate. Compare
            # against the host half of the raw value instead of a variable
            # that does not exist yet -- under `set -u` reaching for it aborts
            # the command, which is how the first cut of this fix turned a
            # refusal into a crash (caught on the live rerun, not by the
            # suite, because the suite set the variable by hand).
            local _want_host="${lan%%:*}" _want_port=22
            case "$lan" in *:*) _want_port="${lan##*:}" ;; esac
            [ "$_prev_host" = "$_want_host" ] || _same=0
            [ -z "$target" ] || [ "$_prev_target" = "$target" ] || _same=0

            # THE PORT IS PART OF THE ENDPOINT, and it cannot be read off
            # ACTIVE_ENDPOINT: activate --host= rewrites that to the production
            # endpoint, so on a relationship already switched to a VPN it says
            # 10.99.0.2:22 while the LAN request said 192.168.28.8:2222.
            # CREATED_ENDPOINT records the original --host verbatim; older
            # records fall back to the pairing manifest's PEER_SAVED_PORT,
            # which --join wrote and nothing later rewrites. If neither is
            # available the endpoint cannot be confirmed, so this is NOT a
            # no-op -- an unconfirmed identity fails closed.
            local _prev_endpoint _prev_port=""
            _prev_endpoint=$( . "$cpath" >/dev/null 2>&1; printf '%s' "${CREATED_ENDPOINT:-}" )
            if [ -n "$_prev_endpoint" ]; then
                case "$_prev_endpoint" in *:*) _prev_port="${_prev_endpoint##*:}" ;; *) _prev_port=22 ;; esac
            else
                local _mf; _mf=$(peer_manifest_path "$(peer_label "$_prev_host")")
                [ -r "$_mf" ] && _prev_port=$( . "$_mf" >/dev/null 2>&1; printf '%s' "${PEER_SAVED_PORT:-}" )
            fi
            if [ -z "$_prev_port" ]; then
                _same=0
            else
                [ "$_prev_port" = "$_want_port" ] || _same=0
            fi

            # An EXPLICIT --local-user=root is a request for root, not a
            # wildcard. Only an OMITTED account says nothing about identity.
            # The previous form treated any explicit root as matching, so a
            # relationship recorded for bckp accepted a rerun asking for root.
            if [ -n "$local_user" ]; then
                [ "${_prev_user:-root}" = "$local_user" ] || _same=0
            fi
            if [ "$_same" -eq 1 ]; then
                log "client '$name' already exists (state '$_prev_state') and this call asks for the same host/target/account -- nothing to create, continuing"
                log "next: ./zfs-backup.sh seed $name    (or activate $name, if the seed already completed)"
                return 0
            fi
            die "client '$name' already exists ($cpath), state '$_prev_state', and this call asks for a DIFFERENT host/target/account than the one recorded (recorded: ${_prev_host}/${_prev_target}/${_prev_user:-root}; requested: ${_want_host}/${target:-<same>}/${local_user:-root}). Refusing to redefine a live relationship from a creation command -- use remove-client first, or correct the arguments."
        fi
    fi

    read_server_conf
    # ---- Batch B: the account the jobs will run as, decided here or not at all
    #
    # Every artifact this command produces is keyed to an account: the pairing key
    # and the pinned host key are written readable by it, the generated config
    # names it, the cron block is installed into ITS crontab, and the read-back
    # looks there. So getting it wrong is not a late error -- it is a relationship
    # whose jobs cannot open their own key.
    #
    # It used to be: pass --local-user only when server.conf happened to set
    # LOCAL_USER, and otherwise say "delegated to nobody, jobs will run as root"
    # and carry on. On an estate migrated to a delegated account that produced
    # root-run jobs out of a warning nobody had to answer -- measured live on pve1,
    # where the collector had no server.conf at all.
    #
    # The Owner's Batch B contract replaces that with a decision:
    #
    #   --local-user=NAME   explicit expert override, always wins
    #   --local-user=root   explicit, and therefore allowed: root is a choice here,
    #                       not a fallback
    #   otherwise           the collector's configured account (server.conf)
    #   nothing resolvable  refuse, naming the one command that fixes it
    #
    # The refusal keys off the resolved VALUE rather than the presence of a file,
    # because "configured with no account" and "never configured" both end here and
    # both need the same answer -- and because a check against a path on disk is
    # untestable, which is how an earlier attempt at this guard broke six unrelated
    # assertions without proving anything.
    if [ "$local_user_given" -eq 1 ]; then
        local_user_name_valid "$local_user"             || die "add-client: --local-user='$local_user' is not a valid account name ($LOCAL_USER_GRAMMAR). Nothing was created."
        # PROVISION THE COLLECTOR-SIDE ACCOUNT, here, at the one moment the
        # choice is made. LAB-E measured what its absence costs: activation
        # refused three separate times, each naming the next missing piece
        # (no repo copy -> no notify scripts -> no queue-group membership),
        # because the fleet's delegated accounts were provisioned by the
        # migration campaign and a FRESH account created by this flag got
        # nothing. Everything below is idempotent and matches what deploy.sh
        # gives an account (account-paths contract).
        # BEST-EFFORT, never fatal: the runnability guard at activation is the
        # enforcer and names the exact missing piece; this block exists so a
        # root operator never MEETS that guard. A non-root caller (tests, a
        # delegated shell) skips with a log line instead of dying on useradd.
        if ! id "$local_user" >/dev/null 2>&1; then
            if [ "$(id -u)" -eq 0 ] && useradd -m -s /bin/bash -c "zfs-snapshot-all collector account" "$local_user" 2>/dev/null; then
                passwd -l "$local_user" >/dev/null 2>&1 || true
                log "add-client: created account '$local_user' (uid $(id -u "$local_user")), password locked"
            else
                log "add-client: account '$local_user' does not exist and cannot be created here -- activation's runnability guard will name whatever is missing"
            fi
        fi
        local _lu_home; _lu_home=$(getent passwd "$local_user" 2>/dev/null | cut -d: -f6)
        if [ -n "$_lu_home" ] && [ "$(id -u)" -eq 0 ]; then
            if [ ! -x "$_lu_home/zfs-snapshot-all/gen-cron.sh" ]; then
                rm -rf "$_lu_home/zfs-snapshot-all"
                git clone -q "$SCRIPT_DIR" "$_lu_home/zfs-snapshot-all" 2>/dev/null                     && chown -R "$local_user:$local_user" "$_lu_home/zfs-snapshot-all"                     && log "add-client: provisioned $_lu_home/zfs-snapshot-all (accounts cannot use root's 0700 checkout)"                     || warn "add-client: could not clone the repo for '$local_user' -- activation will refuse with the exact path"
            else
                # An EXISTING clone is refreshed, not trusted: the closing
                # campaign met an account copy cloned hours earlier that
                # predated a monitor flag the freshly generated line used --
                # the account's own tool refused its own crontab line. Nothing
                # else updates account clones (the hourly pull is root's).
                #
                # The refresh must not rely on the clone's own remote: an old
                # clone may point at an unreachable origin (root's 0700
                # checkout, or a URL the account has no key for), and a
                # 'pull --ff-only' as the account then fails SILENTLY while
                # the stale tool keeps refusing fresh lines (measured: a
                # leftover clone parked on a wip branch). Root's checkout on
                # this host IS the deployed truth, so root hard-syncs the
                # account copy to its own HEAD and hands ownership back.
                # -c safe.directory: root touching an account-owned repo
                # trips git's dubious-ownership guard (measured: the refresh
                # warned and the stale clone survived a full clean rerun).
                git -c safe.directory="$_lu_home/zfs-snapshot-all" -C "$_lu_home/zfs-snapshot-all" fetch -q "$SCRIPT_DIR" HEAD 2>/dev/null                     && git -c safe.directory="$_lu_home/zfs-snapshot-all" -C "$_lu_home/zfs-snapshot-all" reset -q --hard FETCH_HEAD 2>/dev/null                     && chown -R "$local_user:$local_user" "$_lu_home/zfs-snapshot-all"                     || warn "add-client: could not refresh $_lu_home/zfs-snapshot-all -- the account may run an older tool than the lines generated for it"
            fi
            local _lu_s
            for _lu_s in notify-fail.sh notify-warn.sh; do
                [ -e "$_lu_home/$_lu_s" ] || { cp -p "/root/scripts/$_lu_s" "$_lu_home/$_lu_s" 2>/dev/null && chown "$local_user:$local_user" "$_lu_home/$_lu_s"; }
            done
            mkdir -p "$_lu_home/run" && chown "$local_user:$local_user" "$_lu_home/run"
            getent group zfsalert >/dev/null 2>&1 && usermod -aG zfsalert "$local_user" 2>/dev/null
            # Progress records (lib-zfs-snap.sh progress_watch/progress_done)
            # live under /var/lib/zfs-snapshot-all/progress. Created by root
            # flows it came out 2755 -- the delegated account, though a
            # zfsalert member, could not write, so account-run jobs produced
            # NO telemetry and progress_done leaked one 'Permission denied'
            # line per dataset into cron.log (measured, serwis control run).
            # Group-writable + setgid; best-effort like the rest of this block.
            if getent group zfsalert >/dev/null 2>&1; then
                local _lu_pd="${ZFS_PROGRESS_DIR:-/var/lib/zfs-snapshot-all/progress}"
                mkdir -p "$_lu_pd" 2>/dev/null
                chgrp zfsalert "$_lu_pd" 2>/dev/null && chmod 2775 "$_lu_pd" 2>/dev/null
            fi
        fi
    else
        # No --local-user: the jobs run as root. There is no host-wide account to
        # read and nothing to guess -- name an account to delegate them instead.
        local_user=""
        log "add-client: no --local-user -- '$name' jobs will run as root; pass --local-user=NAME to delegate them to an account"
    fi
    if [ "$mode" != sync ]; then
        if [ -z "$target" ]; then
            target="$DEFAULT_TARGET"
            [ -n "$target" ] || die "no --target given and no default set -- run setup-server first, or pass --target=POOL/PATH"
        fi
    fi

    local parsed_endpoint lan_host lan_port
    parsed_endpoint=$(parse_endpoint_arg "$lan") || return 1
    read -r lan_host lan_port <<< "$parsed_endpoint"

    # REV-20260802-033 slice 8 / U8: sync writes to the SAME path a live
    # guest might occupy; inside a shared PVE cluster that path can ALSO be
    # pvesr's own replication target after the guest migrates there -- two
    # independent replicators racing for one destination. The cluster
    # already answers this for free: node ownership is visible under
    # /etc/pve/nodes/ (shared cluster filesystem, world-searchable), keyed
    # by node NAME. Refused here, at enrolment, not at receive time.
    #
    # Matches this fleet's own hostname==PVE-node-name convention. A peer
    # reachable only by an IP whose PVE node name differs from --lan= is a
    # real, acknowledged gap of this specific check -- named in the slice 8
    # response rather than hidden, and not the only guard against the
    # underlying scenario: guest_disk_is_live in snapget.sh catches a live
    # guest's disk directly, per dataset, on every run, regardless of
    # whether this enrolment-time name match fires.
    if [ "$mode" = sync ]; then
        local -a cluster_candidates=("$lan_host")
        case "$lan_host" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                local resolved; resolved=$(getent hosts "$lan_host" 2>/dev/null | awk '{print $2}' | head -1)
                [ -n "$resolved" ] && cluster_candidates+=("${resolved%%.*}")
                ;;
        esac
        local cand
        for cand in "${cluster_candidates[@]}"; do
            if [ -d "$PVE_NODES_DIR/$cand" ]; then
                die "add-client: --mode=sync refused -- '$lan_host' (node '$cand') looks like a member of the SAME PVE cluster as this host. pvesr already replicates within a cluster and would fight this tool for the same destination after a guest migration (U8, ENROLMENT-AGREED-2026-08-02.md). Use --mode=backup instead -- it writes to this client's own namespace, where pvesr never looks."
            fi
        done
    fi

    local -a pair_args=(--pair --role=pull --peer="$lan_host")
    if [ -n "$mode" ]; then
        pair_args+=(--mode="$mode")
        [ -n "$requested" ] && pair_args+=(--peer-requested="$requested")
    else
        pair_args+=(--peer-datasets="$datasets")
    fi
    [ -n "$target" ] && pair_args+=(--target="$target")
    [ "$lan_port" != "22" ] && pair_args+=(--port="$lan_port")
    # The cap travels to the PAIRING, because the link does. Passed through
    # rather than stored here, so there is one home for it and not two that can
    # disagree.
    [ -n "$bandwidth" ] && pair_args+=(--bandwidth="$bandwidth")
    # Without this the pairing key and the pinned host key are readable only by
    # root, and the target root is delegated to nobody -- so the cron jobs this
    # client will run as $LOCAL_USER could not open their own key.
    # root is expressed to deploy.sh by OMITTING the flag, its existing contract.
    # Both an explicit 'root' AND an empty local_user (no --local-user given at
    # all -- the new default) mean exactly that: run as root, delegate nothing.
    # Only a real account name is passed through.
    # An EXISTING pairing already delegated this source host to ONE account
    # (keys, alias known_hosts and the manifest's PEER_SAVED_LOCAL_USER are
    # per-host). A second relationship naming a DIFFERENT account was
    # silently flipped to the paired one -- measured in the passive lab:
    # --local-user=root enrolled cleanly and its lines landed in bckp's
    # crontab, bckp's config, under bckp's keys, with no word said. Until
    # mixed accounts get their own pairing identities, the honest answer is
    # a refusal that names the conflict.
    local _mf_user_path; _mf_user_path=$(peer_manifest_path "$(peer_label "$lan_host")")
    if [ -r "$_mf_user_path" ]; then
        local _mf_user; _mf_user=$( . "$_mf_user_path" >/dev/null 2>&1; printf '%s' "${PEER_SAVED_LOCAL_USER:-root}" )
        local _want_user="${local_user:-root}"
        [ -z "$_mf_user" ] && _mf_user=root
        if [ "$_want_user" != "$_mf_user" ]; then
            die "add-client: this host's pairing with '$lan_host' is delegated to account '$_mf_user', and this relationship asked for '--local-user=$_want_user'. The pairing identity (key, pinned host key, manifest) is per source host, so a second account cannot ride it -- the previous behavior silently ran the new relationship as '$_mf_user' instead. Either use --local-user=$_mf_user, or unpair the host first if the delegation itself should change. Nothing was changed."
        fi
        # The cap is now per PAIR, which cuts both ways: a second relationship
        # asking for a different one is not asking about itself, it is asking to
        # re-cap every relationship that already flies over this link. That is a
        # deliberate act, not a side effect of enrolling something new -- so it
        # is refused here and named, rather than applied quietly in either
        # direction.
        local _mf_bw; _mf_bw=$( . "$_mf_user_path" >/dev/null 2>&1; printf '%s' "${PEER_SAVED_BANDWIDTH:-}" )
        if [ -n "$bandwidth" ] && [ "$bandwidth" != "$_mf_bw" ]; then
            die "add-client: this host's link to '$lan_host' is already capped at '${_mf_bw:-<bez limitu>}' by the pairing, and this relationship asked for '--bandwidth=$bandwidth'. The cap belongs to the PAIR of hosts -- changing it here would silently re-cap every relationship that already uses this link. Either drop --bandwidth to accept the pairing's limit, or change it deliberately for the whole link with 'deploy.sh --pair --peer=$lan_host --bandwidth=$bandwidth'. Nothing was changed."
        fi
    fi
    [ -n "$local_user" ] && [ "$local_user" != root ] && pair_args+=(--local-user="$local_user")
    # REV-20260802-033 slice 9 / U10: pass-through only -- this file does not
    # reimplement the remote scp/ssh/editor flow, deploy.sh --pair does it
    # (see do_pair). Off by default; --lan= alone still ends with the same
    # manual "copy this and run --join there" instructions as before.
    [ "$join_remotely" -eq 1 ] && pair_args+=(--join-remotely)
    # REV-20260804-039 F1: found live -- a process/terminal/SSH loss during
    # --join-remotely's interactive scope editor kills THIS process (add-
    # client's own), so the client record below is never written -- no
    # partial/misleading state is left, but nothing records that the PEER
    # may already be fully joined (do_pair's keypair generation is
    # idempotent: it reuses an existing, unconsumed key for this peer host
    # unless --rotate is given, and do_join's own collision handling
    # treats a resubmitted package with the SAME fingerprint as a no-op
    # reconfirmation, not a rotation -- confirmed live, twice, deliberately
    # killing an in-progress --join-remotely mid-edit and re-running this
    # exact command: the peer's account/key/manifest end up byte-identical
    # to a clean single run, and no second key or duplicate authorized_keys
    # line is ever created). The one thing missing was telling the operator
    # that plainly, rather than leaving them to guess whether it is safe.
    bash "$DEPLOY" "${pair_args[@]}" \
        || die "deploy.sh --pair failed or was interrupted -- see above. Re-running this EXACT add-client command is safe: the pairing key for this peer is reused (not regenerated) unless --rotate is passed, and --join is a no-op reconfirmation when the peer already has this exact key, never a duplicate account, key line, or rotation. If the peer is not reachable at all yet, nothing there has been touched either way."

    # REV-20260804-045: a reused name must not inherit an old pause. remove-
    # client clears its marker, but a crash between those steps -- or a
    # marker left by hand -- would otherwise start this client's life
    # secretly paused, with nothing anywhere saying why. Not silently
    # consumed and not silently kept: reported, then cleared.
    if client_paused "$name"; then
        warn "a stale PAUSED_LOCAL marker exists under $RELATIONSHIPS_DIR/$name (left by a previous relationship of this name) -- clearing it so the new client does not start paused"
        rm -f "$(pause_marker_path "$name")" || die "could not remove the stale pause marker $(pause_marker_path "$name")"
        rmdir "$RELATIONSHIPS_DIR/$name" 2>/dev/null || :
    fi

    mkdir -p "$CLIENTS_DIR" || die "could not create $CLIENTS_DIR"
    {
        echo "# zfs-backup.sh client record -- managed by add-client/seed/set-endpoint/verify-endpoint/activate-client/remove-client"
        echo "# Every value is %q-quoted on write: this file is sourced as root."
        write_client_field CLIENT_NAME       "$name"
        write_client_field PEER_HOST         "$lan_host"
        write_client_field STATE             pending_enroll
        # REV-20260802-033 U9: the literal address IS the endpoint now, no
        # named-slot indirection -- see active_endpoint_host_port.
        write_client_field ACTIVE_ENDPOINT   "$lan_host:$lan_port"
        # BANDWIDTH is deliberately NOT written here any more: the cap lives in
        # the pairing manifest (see load_client_and_connection). Writing a copy
        # would recreate the two-homes problem this move exists to end -- and
        # the stale copy would be the one an operator edits.
        write_client_field PROFILE           "$profile"
        # What THIS relationship asked for. The committed scope on the source
        # is per-COLLECTOR and grows with every relationship this host
        # enrols against that source; resolution filters it back down to
        # these roots (see scope_root_is_ours). Empty for sync mode -- there
        # the source's scope IS the request -- and absent on older records,
        # both of which keep the whole-scope legacy behavior.
        write_client_field REQUESTED_DATASETS "$datasets"
        # The endpoint AS REQUESTED at create, port included, kept verbatim.
        # ACTIVE_ENDPOINT cannot serve this purpose: activate --host= rewrites
        # it to the production endpoint. The rerun identity gate above needs
        # the original to tell "the same request again" from "a different one".
        write_client_field CREATED_ENDPOINT   "$lan"
        # The account CHOICE, persisted with the relationship (r_user in
        # cron_context_resolve). Without it, activation resolved the account
        # from the per-host pairing manifest -- which is how the silent
        # account flip above stayed invisible until the passive lab.
        write_client_field LOCAL_USER        "$local_user"
        # The TARGET is a fact of the RELATIONSHIP, recorded here at create.
        # The pairing manifest also carries a target, but the manifest is
        # per-HOST: the first relationship against a source wrote it, and a
        # second relationship (own --target) silently inherited the first
        # one's namespace -- the coverage guard then refused it as an
        # overlap (measured, labD beside labS). load_client_and_connection
        # lets this field override the manifest's; empty (sync mode) and
        # absent (older records) keep the manifest value, zero migration.
        write_client_field CLIENT_TARGET     "$target"
        # On the RECORD, so re-activation regenerates the same shape. A hand
        # edited config lost its 'recursive = atomic' the moment anything
        # regenerated the section; the record is the only place a decision
        # survives that.
        write_client_field RECURSION         "$recursion"
        # DECLARED passivity (LAB-E, 2026-08-23). Passive is a decision, not a
        # deduction: this relationship only ever ADOPTS the newest existing
        # snapshot (engine -e), stamps nothing on the source, and its monitor
        # watches "newest of anything" rather than a named family. Recorded at
        # CREATE like RECURSION, read back by seed and activation; never
        # sniffed from snapshot names -- the sync-chain probe taught us where
        # name-sniffing ends.
        write_client_field PASSIVE           "$passive"
        if [ -n "$exclude_family" ]; then
            local _esi=1 _esp
            for _esp in ${exclude_family//,/ }; do
                write_client_field "EXCLUDE_FAMILY_${_esi}" "$_esp"
                _esi=$((_esi + 1))
            done
        fi
        local _xi=0 _x
        for _x in ${excludes[@]+"${excludes[@]}"}; do
            _xi=$((_xi + 1))
            write_client_field "EXCLUDE_CHILD_$_xi" "$_x"
        done
        write_client_field CREATED_AT        "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$cpath" || die "could not write $cpath"
    chmod 0600 "$cpath"

    log "client '$name' created, state=pending_enroll, profile=$profile"
    if [ "$recursion" = atomic ]; then
        log "client '$name': ATOMIC recursion (-r) -- the whole subtree ships as ONE stream, and managed SOURCE retention is DECLINED for this relationship. Under -r the engines keep no bookmark, so a source prune that ages out the last common snapshot would end the relationship permanently. Target-side retention is unaffected; source snapshots are this source's own business."
    fi
    if [ "$join_remotely" -eq 1 ]; then
        log "next: see deploy.sh's own output above for whether --join-remotely succeeded on $lan_host, or fell back to manual instructions"
    else
        log "next: copy the package above to $lan_host and run there:  ./deploy.sh --join=<package>"
    fi
    log "then here:  $0 seed $name"
}

# REV-20260802-033 slice 6 (fetch/digest/generate): for a MODE-based client
# (PEER_SAVED_MODE set, PEER_SAVED_DATASETS empty because dataset selection
# was deferred to the peer -- slices 4/5), resolves the real leaf dataset
# list by fetching the peer's COMMITTED scope file and walking its actual
# tree, then sets PEER_SAVED_DATASETS as if it had always been in the
# manifest. This is the ONLY seam: every existing dataset-list consumer
# (seed, final-catchup, activate-client, emit_client_sections, migrate-
# profile, test) needs no change at all, because by the time any of them
# run, the list is populated exactly the way a legacy --peer-datasets
# client already provides it.
#
# T1 (ENROLMENT-AGREED-2026-08-02): `zfs list` is not restricted by `zfs
# allow`, so this walk succeeds even before --commit-scope has granted
# anything -- it enumerates what commit-scope is about to grant (or already
# has; either order works).
#
# T3: the fetched scope file must match the sha256 sidecar --commit-scope
# recorded when it last granted -- proof this is exactly what was granted
# from, not a source-side edit made since. A mismatch refuses outright
# rather than silently generating jobs for a scope nobody actually committed.
#
# Called from load_client_and_connection, which every caller above already
# invokes first -- not a new step operators need to remember.
# fetch_committed_scope <local outfile> -- fetch the peer's COMMITTED scope
# file over the already-loaded connection (LOAD_*), enforcing T3: the sha256
# sidecar only exists after --commit-scope, and the fetched file must match it.
# Dies, with whose-move-it-is instructions, when the draft is missing, the
# commit has not happened, or the file was edited since the commit. Shared by
# resolve_mode_datasets (sync) and rux_verify_requested_scope (backup) -- one
# implementation of "what did the source actually sign", not two.
fetch_committed_scope() {
    local outfile="$1"
    local -a ssh_opts; load_ssh_opts; ssh_opts=("${LOAD_SSH_OPTS[@]}")
    # REV-20260804-037: NOT $LOAD_LABEL (see $COLLECTOR_LABEL's own comment
    # at its declaration for why these two are different labels, and why
    # using the wrong one here was invisible to every prior local test).
    local sfile_remote hfile_remote
    sfile_remote=$(peer_scope_path "$COLLECTOR_LABEL")
    hfile_remote=$(peer_scope_granted_hash_path "$COLLECTOR_LABEL")

    local hash_tmp
    hash_tmp=$(mktemp) || die "mktemp failed"
    if ! ssh -n "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$sfile_remote'" > "$outfile" 2>/dev/null \
       || [ ! -s "$outfile" ]; then
        rm -f "$hash_tmp"
        # Name the RIGHT missing step. Until 2026-08-20 this said only "has
        # --draft-scope run there yet?", which is the wrong question whenever
        # the JOIN never completed -- and that is the common case, because the
        # one-command form attempts the join, prints manual instructions when it
        # fails, and then RESUMES PAST IT: re-running it from state
        # 'pending_enroll' does not retry the join, it goes straight to this
        # fetch. The operator was then sent to look at --draft-scope on a peer
        # that had never accepted the package at all. Measured on metropolis
        # 2026-08-20: the resume log was two lines, with zero join attempts.
        #
        # THE FIRST ATTEMPT AT THIS USED A DISCRIMINATOR THAT DOES NOT
        # DISCRIMINATE, and it is worth saying why rather than quietly replacing
        # it. It tested peers/<addr>.conf here and called its presence proof
        # that "the join completed", on the belief that --join writes it on the
        # SOURCE and it is copied back. It is not: the COLLECTOR writes that
        # file itself at --pair time, before any join, and it carries only
        # PEER_SAVED_* -- measured 2026-08-20 on a pair whose source provably
        # had no manifest and no account. So the "join has not completed" branch
        # was unreachable and every case got the draft advice, which is the very
        # bug the branch was added to fix, still happening.
        #
        # There IS no local fact that proves a remote join completed. The join
        # runs over there; when it is driven manually, nothing comes back until
        # a scope can be fetched -- which is the thing that just failed. So this
        # says both possibilities and orders them by likelihood instead of
        # picking one. Guessing here is what sent an operator to inspect a draft
        # on a peer that had never accepted the package.
        die "could not fetch the scope file from $LOAD_HOST ($sfile_remote).

Two things can cause this and NOTHING HERE CAN TELL THEM APART -- the join runs on $LOAD_HOST, and this host learns nothing about it until a scope can be read. Check in this order, on $LOAD_HOST:

  1. did the JOIN complete?   ls -l /etc/zfs-snapshot-all/peers/  and  id zfsbackup-<this host's label>
     If neither is there, the join is the missing step: copy the .tgz this command printed and run
     deploy.sh --join=<that file> there. Re-running THIS command does NOT retry the join -- it resumes past it.

  2. only if the join IS done: the scope draft is missing.
     Run deploy.sh --draft-scope on $LOAD_HOST, or re-run its --join, which drafts one."
    fi
    if ! ssh -n "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$hfile_remote'" > "$hash_tmp" 2>/dev/null \
       || [ ! -s "$hash_tmp" ]; then
        rm -f "$hash_tmp"
        die "the source $LOAD_HOST has GRANTED nothing yet: the scope draft exists there, but the grant (--commit-scope) is deliberately a source-side decision and never runs remotely. Whose move it is: on $LOAD_HOST, review the draft and run:
    deploy.sh --commit-scope=$COLLECTOR_LABEL
then re-run the exact command that printed this -- it resumes from where it stopped. (--draft-scope alone grants nothing.)"
    fi

    local want_hash got_hash
    want_hash=$(tr -d ' \t\r\n' < "$hash_tmp")
    got_hash=$(sha256sum -- "$outfile" 2>/dev/null | awk '{print $1}')
    rm -f "$hash_tmp"
    if [ -z "$got_hash" ] || [ "$want_hash" != "$got_hash" ]; then
        die "the scope file on $LOAD_HOST does not match the hash --commit-scope last recorded there -- it was edited since the last commit (or committed differently) and never re-committed. Run --commit-scope on $LOAD_HOST first, then retry."
    fi
}

# Does the source hold a COMMITTED scope for us? (T3 sidecar present and
# non-empty.) Probed over the relationship's own channel; a transport failure
# reads as "no", which is safe -- every caller is about to do real ssh work
# that will fail loudly on the same broken link.
# Is <ds> one of the roots the engine re-expands at every run?
is_recursive_root() {   # <dataset> -> 0 yes
    case " ${PEER_SAVED_RECURSIVE_ROOTS:-} " in *" $1 "*) return 0 ;; esac
    return 1
}

# The family probe for a dataset this relationship touches: does ANY dataset
# in its scope already carry an automated_* snapshot? Depth follows the
# recursion contract, and that is the point (LAB6-F4 round two, caught by the
# clean pass itself): for a RECURSIVE root the family may live only on
# DESCENDANTS -- the measured chain shape, where R3 stamps tree/child deep
# inside and the chain root itself is never snapshotted -- so a -d 1 probe of
# the root read "fresh" and the seed went active against a middle that was
# very much owned, recursively re-stamping all six datasets. A -d 1 probe
# stays correct for an enumerated dataset, whose children are separate list
# entries probed on their own. ONE probe for the seed, the catch-up and the
# emit-time passivity decision -- three copies of it would drift exactly like
# everything else this campaign measured.
#
# LAB6 pass 7 F-2 (2026-08-22): there was a FOURTH copy, hand-rolled inside
# activate-client's passive rehearsal, with `-d 1` hardcoded -- and it drifted
# exactly as promised. Measured on the R2 chain middle: this probe answered
# "family exists" (2 matches under -r) and chose PASSIVE, then the rehearsal
# answered "no snapshot reachable" (0 matches under -d 1) and refused the
# install, about the same dataset on the same host in the same run. The
# relationship was un-activatable while the line it was rehearsing was
# healthy -- snapget -R -e skips a family-less member as scaffolding and only
# fails when NOTHING in the expansion had a family. So the probe now also
# returns the newest match, and the rehearsal calls it instead of asking the
# same question its own way.
# The exclusions this relationship was enrolled with, rendered as engine flags.
# Read off the CLIENT RECORD (sourced by load_client_and_connection), never off
# the config -- a config edit is exactly what this replaces. Numbered fields
# rather than one packed string: a regex may contain anything, including the
# separator someone would have picked.
# The PASSIVE half of the flags a preserved/generated section must carry:
# ' -e' when the relationship declared passivity, plus one ' -E <prefix>' per
# recorded snapshot-family exclusion. Same shape and same reason as
# client_exclude_flags below -- a refreshed section must come back with
# everything the DECLARATION implies, or a re-activation quietly turns a
# passive relationship active and it starts stamping the source.
client_passive_flags() {
    local out="" i=1 v
    [ "${PASSIVE:-0}" = "1" ] || { printf ''; return 0; }
    out=" -e"
    while :; do
        eval "v=\${EXCLUDE_FAMILY_$i:-}"
        [ -n "$v" ] || break
        out="$out -E $v"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

client_exclude_flags() {   # -> " -X <re>" for each recorded exclusion
    local i=1 v out=""
    while :; do
        eval "v=\${EXCLUDE_CHILD_$i:-}"
        [ -n "$v" ] || break
        out="$out -X $v"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# TRI-STATE, and that is the whole point (fail-open found on review, measured
# 2026-08-22). This probe used to answer a yes/no question with a pipeline whose
# output is empty for BOTH "the source has no family" and "the source could not
# be reached" -- and the seed call site reads no-family as licence to run an
# ACTIVE seed, creating snapshots on a source this relationship may not own.
# Measured on the live chain with a working positive control:
#
#   live channel, dataset WITH a family    -> newest named, exists -> yes
#   live channel, dataset with no family   -> empty,        exists -> no
#   SAME dataset with a family, host down  -> empty,        exists -> no   <-- here
#
# The third row is how LAB6-F4's damage starts: an active seed against a chain
# middle owned by another relationship re-stamps it, that relationship's GFS
# ladder then destroys its own base, and the pulls wedge on a GUID refusal. A
# dead link must never be able to say "there is nothing here".
#
# So: rc 0 = the source answered (stdout may legitimately be empty),
#     rc 2 = the question could not be asked. Callers refuse on 2.
# A nonexistent dataset lands in 2 as well: `zfs list` exits non-zero for it,
# and "you asked about something that is not there" is not evidence of an
# empty family either.
SOURCE_PROBE_UNKNOWN=2
# --- profile-derived family root -------------------------------------------
# The FAMILY is whatever name makes a snapshot OURS, and until 2026-08-23 that
# name was the literal automated_ in six places -- correct for the built-in
# default and silently wrong for every other profile (measured, lab 'serwis':
# the seed stamped automated_daily_ onto both sides of a relationship whose
# ladder prunes serwis_* -- a snapshot no retention would ever touch, and an
# automated_* family on the source that would flip a future undeclared
# enrolment of the same source into a consumer).
#
# The root comes from the ACTIVE PROFILE, in the order the design already
# trusts: gfs_pattern first (retention had to know the family root to prune
# it -- default: automated_), else the send prefix with a recognizable tier
# word stripped (serwis_hourly_ -> serwis_), else the send prefix itself (a
# flat one-family profile: the seed then shares the cadence name; retention
# coverage wins over the one-tick monitor artefact, and the artefact ends at
# the first scheduled run). Empty result -- a prefixless profile, which never
# reaches an ACTIVE seed -- falls back to the historic automated_.
profile_family_root() {
    load_active_profile
    local root
    root=$(awk -F= 'NF==2 && $1 ~ /^[[:space:]]*gfs_pattern[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$PROFILE_PRUNE_FILE")
    if [ -z "$root" ]; then
        local pfx
        pfx=$(awk -F= 'NF==2 && $1 ~ /^[[:space:]]*prefix[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$PROFILE_TPL_FILE")
        case "$pfx" in
            *hourly_)  root="${pfx%hourly_}" ;;
            *daily_)   root="${pfx%daily_}" ;;
            *weekly_)  root="${pfx%weekly_}" ;;
            *monthly_) root="${pfx%monthly_}" ;;
            *)         root="$pfx" ;;
        esac
    fi
    printf '%s' "${root:-automated_}"
}

# The seed's name: root + daily_. For the default profile this is byte-for-
# byte the automated_daily_ the call-site comment below argues for; the
# argument itself (not the monitor's cadence name, but inside the ladder's
# reach) now holds for every profile instead of one.
profile_seed_prefix() { printf '%sdaily_' "$(profile_family_root)"; }

# The seed and the catch-up run OUTSIDE the activation plan, where nothing
# has chosen a profile yet -- but the client record has (create-time
# provenance, .-sourced into $PROFILE). Point the loader at it; a record
# predating the field keeps the env/default choice, zero migration.
seed_profile_context() {
    if [ -n "${PROFILE:-}" ] && [ "$PROFILE" != "$PROFILE_ACTIVE" ]; then
        profile_release_tmp
        PROFILE_ACTIVE="$PROFILE"
    fi
    load_active_profile
}

source_family_newest() {   # <dataset> [prefix] -> newest matching snapshot; rc 2 = unknown
    local depth='-d 1'
    is_recursive_root "$1" && depth='-r'
    # The caller's own prefix, because the rehearsal has one (the [dataset:]
    # section's `prefix`, i.e. what the installed line passes to -m) and the
    # passivity decision does not -- it asks about the FAMILY, whose name is
    # the project's automated_ root regardless of which tier stamped it.
    # ${2-...}, NOT ${2:-...}: an EMPTY prefix is a real answer ("any family",
    # the declared-passive rehearsal) and must survive; only an UNPASSED second
    # argument falls back to the automated_ root (the sync-chain guard and the
    # undeclared-seed probe, unchanged). The colon form ate the empty string
    # and the passive rehearsal silently probed automated_ again -- caught by
    # the closing campaign's dry-run refusing a source with three fresh
    # foreign snapshots on it.
    local pfx="${2-automated_}"
    load_ssh_opts
    # -p (parseable creation) so the sort is numeric on a stable field, not on
    # a locale-formatted date. The remote call is captured on its own so its
    # exit status is ITS status -- piping it straight into grep would hand the
    # caller grep's verdict, which is exactly the confusion this fixes.
    local out rc
    out=$(ssh -n "${LOAD_SSH_OPTS[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" \
            "zfs list -H -t snapshot $depth -o name,creation -p -- '$1'" 2>/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] && return "$SOURCE_PROBE_UNKNOWN"
    printf '%s\n' "$out" | grep "@${pfx}" | sort -k2,2n | tail -1 | cut -f1
    return 0
}

source_family_exists() {   # <dataset> [prefix] -> 0 family, 1 none, 2 could not ask
    local out rc
    out=$(source_family_newest "$1" "${2-automated_}"); rc=$?
    [ "$rc" -ne 0 ] && return "$SOURCE_PROBE_UNKNOWN"
    [ -n "$out" ]
}

# The one wording for "the probe could not answer", so three call sites cannot
# describe the same condition three ways. Names the dataset and the channel,
# says plainly that nothing was changed, and does NOT suggest a retry flag --
# there is none, and there should be none: the answer to an unreachable source
# is to make it reachable, not to proceed without it.
die_probe_unknown() {   # <dataset> <what-was-being-decided>
    die "cannot reach ${LOAD_ACCOUNT}@${LOAD_HOST} to ask whether '$1' already carries an automated_* family, so $2 cannot be decided. Treating an unreachable source as 'no family here' is how an active seed lands on a middle another relationship owns -- refusing instead. Nothing was changed. Fix the link (or the account's access to that dataset) and re-run; this command is resumable."
}

# ONE CONFIG = ONE ACCOUNT (LAB6-F2). A config file renders WHOLE into the
# target account's crontab -- gen-cron has no per-section account filter, and
# that is the single-writer design, not an omission. So a file that already
# drives another account's managed block must never become this context's
# answer: merging would make the next regeneration for either account render
# BOTH relationships' jobs into its crontab, one of them under an account
# whose keys it cannot read. Refused for the explicit flag too -- naming
# another account's file is answered with "use that account", not obeyed.
# remove-client (policy record) never comes through here: its recorded pair
# was installed together and teardown must not be lockable by this.
cron_context_assert_file_owner() {
    [ -n "${CRON_CTX_FILE:-}" ] || return 0
    local me="${CRON_CTX_USER:-root}" acct asrc
    while IFS= read -r acct; do
        [ "$acct" = "$me" ] && continue
        asrc=$(cron_source_for_user "$acct") || continue
        [ "$asrc" = "$CRON_CTX_FILE" ] || continue
        die "config '$CRON_CTX_FILE' already drives ${acct}'s managed crontab block, and this run resolves to account '${me}'. One config file renders WHOLE into one account's crontab, so sharing it would install ${acct}'s jobs under '${me}' (and vice versa) at the next regeneration. Say which you mean:
    --local-user=$acct           (join that account's existing config)
    --config=<different path>    (give '${me}' its own file; the default is $(default_cron_config))
Nothing was read and nothing was changed."
    done < <(cron_known_accounts)
    return 0
}

# TRI-STATE for the same reason as the family probe, and this one decides more:
# `has_committed_scope || return 0` below means "no signed scope -- keep the
# recorded dataset list". `ssh "test -s ..."` returns non-zero for BOTH "the
# sidecar is not there" (test's own 1) and "the link is down" (ssh's 255), so a
# transport failure silently downgraded a relationship from THE SIGNED SCOPE IS
# THE CONTRACT (#101) back to whatever list happened to be recorded -- the exact
# split #101 exists to end, reachable by unplugging a cable.
#
# ssh already distinguishes them: it reserves 255 for its own failures and
# passes the remote command's status through otherwise. The status was there;
# the code discarded it. This project has a name for that mistake already --
# never blame the data for a link failure.
#
#   rc 0 = a committed scope is present
#   rc 1 = the source answered, and there is none
#   rc 2 = could not ask
has_committed_scope() {
    local -a ssh_opts; load_ssh_opts; ssh_opts=("${LOAD_SSH_OPTS[@]}")
    local rc
    ssh -n "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" \
        "test -s '$(peer_scope_granted_hash_path "$COLLECTOR_LABEL")'" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        # 255 is ssh's own; anything else is a remote shell that could not even
        # run `test` (no shell, refused command, killed). Neither is evidence
        # about the sidecar.
        *) return "$SOURCE_PROBE_UNKNOWN" ;;
    esac
}

resolve_mode_datasets() {
    # THE SIGNED SCOPE IS THE CONTRACT (owner decision A, LAB6-F1 2026-08-21).
    #
    # Until now only mode-based (sync / deferred-backup) relationships resolved
    # their list from the source's committed scope; an explicit request
    # (--datasets / --source=HOST:A,B) was terminal. LAB6 R1 measured what that
    # split costs: the request named hdd/lab6/tree, the auto-draft carried
    # include_children = yes, the source SIGNED a grant over four datasets --
    # and the job replicated two. tree/a and tree/b had a signed grant, zero
    # snapshots, zero protection, and every report was green. The grant read as
    # proof of coverage while the request quietly decided coverage.
    #
    # So: when a committed scope EXISTS, it supersedes the recorded request for
    # every relationship kind. The request still seeds the draft, still shapes
    # --grant-remotely, and rux_verify_requested_scope still asserts it is
    # COVERED by what was signed -- but what replicates is what the source's
    # administrator signed, parent and children per include_parent/
    # include_children. A legacy relationship with no committed scope keeps its
    # recorded list: there is no signed contract to supersede it with.
    #
    # Boundary, stated honestly: the list is resolved at seed/activate time.
    # A child dataset created on the source LATER joins at the next
    # re-activation, not automatically at the next cron tick.
    if [ -n "${PEER_SAVED_MODE:-}" ]; then
        [ -z "${PEER_SAVED_DATASETS:-}" ] || return 0
    else
        [ -n "${PEER_SAVED_DATASETS:-}" ] || return 0
        local scope_rc; has_committed_scope; scope_rc=$?
        # ENDPOINT_PROBE: the caller's whole job is to find out WHICH address
        # answers, so "this one does not" is its expected input, not a fatal.
        # Regression found in CI on 2026-08-22 and it was mine: the refusal
        # below is right for anything that will ACT on the dataset list, and
        # verify-endpoint acts on nothing -- it picks an address. Killing it at
        # the door removed endpoint failover entirely (U9: "falls back to a
        # known candidate when the current endpoint does not answer"), because
        # load_client_and_connection runs ONCE, against the current endpoint,
        # before the candidate loop ever starts. The list is left exactly as
        # recorded and is resolved for real by the next load against the address
        # that did answer -- which is the one that installs.
        if [ "$scope_rc" -eq "$SOURCE_PROBE_UNKNOWN" ] && [ "${ENDPOINT_PROBE:-0}" -eq 1 ]; then
            warn "could not ask ${LOAD_ACCOUNT}@${LOAD_HOST} for its committed scope -- carrying the recorded dataset list through endpoint probing only; whichever address answers is asked again before anything is installed"
            return 0
        fi
        [ "$scope_rc" -eq "$SOURCE_PROBE_UNKNOWN" ] \
            && die "cannot reach ${LOAD_ACCOUNT}@${LOAD_HOST} to find out whether it has signed a scope for this relationship, so there is no way to tell a source that granted nothing from a source this host cannot talk to. Continuing would fall back to the recorded dataset list and replicate it as if no signature existed -- which is the split THE SIGNED SCOPE IS THE CONTRACT (#101) closed. Refusing; nothing was changed. Fix the link and re-run."
        [ "$scope_rc" -eq 0 ] || return 0
    fi

    local -a ssh_opts; load_ssh_opts; ssh_opts=("${LOAD_SSH_OPTS[@]}")

    local scope_tmp
    scope_tmp=$(mktemp) || die "mktemp failed"
    fetch_committed_scope "$scope_tmp"

    scope_read "$scope_tmp" || { rm -f "$scope_tmp"; die "scope file fetched from $LOAD_HOST: $SCOPE_ERR"; }
    rm -f "$scope_tmp"

    # A SOLID root -- include_parent=yes, include_children=yes, no excludes --
    # stays ONE entry, marked recursive, and the engine expands it on the
    # source AT EVERY RUN (snapget -R does a remote `zfs list -r` before each
    # transfer). That is what makes the signed contract hold over time: a
    # child created on the source tomorrow is inside the signed subtree, and
    # it joins at the next cron tick, not at the next re-activation. The
    # owner rejected the frozen-enumeration boundary in exactly those words.
    #
    # A root the operator NARROWED -- excludes, or parent/children switched
    # off -- cannot ride engine recursion (the engine would take the whole
    # subtree), so it is enumerated here and its membership DOES freeze at
    # activation. That is the honest cost of a hand-carved scope, and it is
    # said out loud below rather than discovered from a backup missing a
    # dataset.
    local -a resolved=()
    PEER_SAVED_RECURSIVE_ROOTS=""
    local root ds
    # The committed scope belongs to the COLLECTOR, not to this relationship:
    # after a second enrolment against the same source it is the UNION of
    # every relationship's grant (measured, labD after labS: labD's seed
    # resolved labS's trees and the --yes guard refused -- and without the
    # guard it would have replicated a sibling's datasets). The record knows
    # what THIS relationship asked for; a root disjoint from that request is
    # a sibling's and is skipped. A root that CONTAINS the request is kept
    # whole -- adopting a deliberately broader grant is a real use, and the
    # interactive consent / --yes sync guard still owns that decision.
    local -a _req_roots=()
    if [ -n "${REQUESTED_DATASETS:-}" ]; then
        local _rr
        while IFS= read -r _rr; do [ -n "$_rr" ] && _req_roots+=("$_rr"); done < <(dataset_list_split "$REQUESTED_DATASETS")
    fi
    scope_root_is_ours() {   # <scope root> -> 0 keep, 1 sibling's
        [ "${#_req_roots[@]}" -gt 0 ] || return 0
        local q
        for q in "${_req_roots[@]}"; do
            case "$1" in "$q" | "$q"/*) return 0 ;; esac
            case "$q" in "$1"/*) return 0 ;; esac
        done
        return 1
    }
    for root in "${SCOPE_ROOTS[@]}"; do
        if ! scope_root_is_ours "$root"; then
            log "scope root '$root' is outside this relationship's request (a sibling relationship's grant) -- skipped"
            continue
        fi
        if [ "${SCOPE_PARENT[$root]}" = yes ] && [ "${SCOPE_CHILDREN[$root]}" = yes ] \
           && [ -z "${SCOPE_EXCLUDE[$root]}" ] && [ -z "${SCOPE_EXCLUDE_TREE[$root]}" ]; then
            case " ${resolved[*]:-} " in *" $root "*) continue ;; esac
            resolved+=("$root")
            PEER_SAVED_RECURSIVE_ROOTS="${PEER_SAVED_RECURSIVE_ROOTS:+$PEER_SAVED_RECURSIVE_ROOTS }$root"
            continue
        fi
        while IFS= read -r ds; do
            [ -n "$ds" ] || continue
            scope_includes "$ds" || continue
            case " ${resolved[*]:-} " in *" $ds "*) continue ;; esac
            resolved+=("$ds")
        done < <(ssh -n "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "zfs list -H -o name -r -- '$root'" 2>/dev/null)
        log "scope root '$root' is hand-narrowed (excludes or include_* switched off) -- its membership is enumerated NOW and a dataset created there later joins at the next re-activation, not the next cron tick"
    done
    [ "${#resolved[@]}" -gt 0 ] \
        || die "the scope file on $LOAD_HOST selects nothing that currently exists there -- nothing to back up"

    PEER_SAVED_DATASETS="${resolved[*]}"
    [ -n "$PEER_SAVED_RECURSIVE_ROOTS" ] \
        && log "recursive root(s) -- the engine re-expands these on the source at every run: $PEER_SAVED_RECURSIVE_ROOTS"
    # Unconditional, and that is the point. This is the moment the list stops
    # being the source's business and becomes what this host will replicate,
    # and until 2026-08-21 it was the one fact nobody printed: cmd_seed's
    # `Zrodla:` line lives inside `if [ "$yes" -ne 1 ]`, so an automated run
    # moved real data having never named what it was moving. Logged here rather
    # than at the gates because there is exactly one producer and two consumers.
    log "scope on $LOAD_HOST resolves to ${#resolved[@]} dataset(s): ${resolved[*]}"
}

# The dataset the operator actually named, if anything recorded one.
# RUX_SOURCE is 'host:dataset' and is written by the rux one-command path only;
# a plain `add-client --mode=sync` never had a requested dataset, so this is
# empty there and the comparison below correctly declines to invent one.
sync_requested_dataset() {   # -> dataset half of RUX_SOURCE, or nothing
    case "${RUX_SOURCE:-}" in
        *:*) printf '%s' "${RUX_SOURCE#*:}" ;;
    esac
}

# What a sync relationship RESOLVED, minus what was asked for.
#
# The gap this measures (2026-08-20 campaign, P5): rux drops the dataset half of
# --source=HOST:DATASET before calling add-client, because a sync add-client
# refuses --datasets. So --pair carries no dataset list, the source drafts its
# scope from an EMPTY request, and an empty request drafts the whole branch
# inventory of every pool. Accept that draft and the relationship quietly
# carries datasets nobody asked for -- measured: one enrolment naming one
# dataset replicated three, one of them another relationship's.
#
# rux_verify_requested_scope cannot see this. It asks whether the request is
# COVERED by the committed scope, which is true here: the scope is WIDER, and
# wider is the direction that hurts. Sync lands every dataset at the SAME path
# on this host, so an unrequested extra is a collision, not a bonus backup.
sync_scope_extra_datasets() {   # -> space-separated datasets outside the request
    local requested ds
    requested=$(sync_requested_dataset)
    [ -n "$requested" ] || return 0
    # The request is a LIST now. Matching only the first item would report every
    # other requested dataset as "extra" and refuse a perfectly correct scope
    # under --yes -- the guard turning on the thing it was built to permit.
    local -a want=()
    while IFS= read -r _w; do want+=("$_w"); done < <(dataset_list_split "$requested")
    local -a extra=()
    local _w hit
    for ds in ${PEER_SAVED_DATASETS:-}; do
        hit=0
        for _w in "${want[@]}"; do
            case "$ds" in
                "$_w" | "$_w"/*) hit=1; break ;;
            esac
        done
        [ "$hit" -eq 1 ] && continue
        extra+=("$ds")
    done
    [ "${#extra[@]}" -gt 0 ] || return 0
    printf '%s' "${extra[*]}"
}

# The --yes gate for the above, and deliberately ONLY the --yes gate.
# An interactive run already prints `Zrodla:` and requires a `t`, so an operator
# who reads a wider list can still consent to it on purpose -- that is a real
# use (adopting an existing broader grant) and refusing it would be us deciding
# for them. --yes has no reader. It cannot consent to something it never saw,
# so it refuses rather than assuming the silence meant yes.
assert_sync_scope_within_request() {   # <yes-flag> <command-name>
    [ "${1:-0}" -eq 1 ] || return 0
    local extra; extra=$(sync_scope_extra_datasets)
    [ -n "$extra" ] || return 0
    local requested; requested=$(sync_requested_dataset)
    die "$2: refusing to run under --yes. This relationship asked for '$requested', but the scope committed on $PEER_HOST resolves to dataset(s) outside it: $extra
  full resolved list: $PEER_SAVED_DATASETS
A sync relationship reproduces each source path verbatim on this host, so every
extra entry above writes to a path this relationship was never granted -- where
something else may already live. The extras exist because a sync enrolment sends
no dataset list to the source, so the source drafted its scope from the whole
pool inventory and that draft was accepted.
Narrow it on $PEER_HOST (label '$(peer_label "$PEER_HOST")'), then re-run:
  ./deploy.sh --draft-scope=$(peer_label "$PEER_HOST")   # edit: keep only what this relationship takes
  ./deploy.sh --commit-scope=$(peer_label "$PEER_HOST")
or re-run the enrolment with --grant-remotely, which signs a scope of exactly
the requested dataset. Nothing was transferred and nothing was installed.
Dropping --yes shows you the list and lets you consent to it deliberately."
}

# Shared setup for every command that connects to an already-paired peer:
# sources the client conf + deploy.sh's peer manifest, derives the stable
# alias, and resolves the CURRENTLY ACTIVE endpoint's host/port. Sets:
# label, mpath (unused after sourcing), account, keyfile, alias, alias_kh,
# host, port, flags.
load_client_and_connection() {
    local cpath="$1"
    # Reset before sourcing: records predating a field must not inherit the
    # previous client's value when one process loads several records.
    #
    # BANDWIDTH joins that list here, and it is the reason the list exists at
    # all. A record without the field does not overwrite the variable, so in the
    # commands that load several records in one shell -- migrate-profile,
    # audit-source-retention -- a capped client A followed by an uncapped client
    # B left B carrying A's cap: `-b 2M` on B's engine call and a `bandwidth`
    # line in B's section. A relationship that never asked for a limit gets
    # quietly slowed, in the direction nobody notices, because a transfer that
    # is slower than it should be still succeeds.
    CLIENT_TARGET=""
    # The cap now has a SECOND source -- the pairing manifest -- and it is
    # cleared for the identical reason spelled out above, not a new one.
    BANDWIDTH=""
    PEER_SAVED_BANDWIDTH=""
    # The numbered exclusion fields, cleared for the same reason and BEFORE the
    # source below: they are read back by name, so a value left over from a
    # previously loaded record would be attributed to this one. No two-client
    # path was found in a single process, so this is consistency with the two
    # fields above rather than a defect being fixed -- said plainly because the
    # difference matters if someone later looks for the measurement.
    unset ${!EXCLUDE_@}
    # shellcheck disable=SC1090
    . "$cpath"
    # LEGACY EXCLUSION FIELDS -- refuse, never ignore.
    #
    # The fields were renamed on 2026-09-01 (EXCLUDE_SNAP_n -> EXCLUDE_FAMILY_n,
    # EXCLUDE_n -> EXCLUDE_CHILD_n). The CLI and the CONFIG halves of that rename
    # both fail LOUDLY on the old spelling -- an unknown option, an unknown
    # field. This half would not have: the readers look the new names up by
    # name, so an old record would simply come back with no exclusions, and the
    # next re-activation would drop every -X and -E it was enrolled with without
    # a word. Silence is the one failure mode this package does not accept.
    #
    # Measured before the rename on all five hosts: zero records carry these.
    # So this refusal should never fire -- which is exactly why it has to exist
    # rather than be argued away, because "should never" is a claim about a
    # measurement, not about the code.
    local _leg
    for _leg in ${!EXCLUDE_@}; do
        case "$_leg" in
            EXCLUDE_SNAP_[0-9]*) die "$cpath carries the legacy field '$_leg'. It was renamed to EXCLUDE_FAMILY_${_leg#EXCLUDE_SNAP_} on 2026-09-01 and is no longer read -- continuing would silently drop this relationship's snapshot-family exclusions. Rename the field in that file and re-run." ;;
            EXCLUDE_FAMILY_*|EXCLUDE_CHILD_*) ;;
            EXCLUDE_[0-9]*) die "$cpath carries the legacy field '$_leg'. It was renamed to EXCLUDE_CHILD_${_leg#EXCLUDE_} on 2026-09-01 and is no longer read -- continuing would silently drop this relationship's child exclusions. Rename the field in that file and re-run." ;;
        esac
    done
    local label; label=$(peer_label "$PEER_HOST")
    LOAD_LABEL="$label"
    local mpath; mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$PEER_HOST' at $mpath -- run add-client first"
    # shellcheck disable=SC1090
    . "$mpath"

    # Relationship-owned facts override their per-host manifest defaults --
    # see the CLIENT_TARGET note at the record writer.
    [ -n "${CLIENT_TARGET:-}" ] && PEER_SAVED_TARGET="$CLIENT_TARGET"

    LOAD_ACCOUNT="${PEER_SAVED_ACCOUNT:-root}"
    LOAD_KEYFILE=$(local_keyfile_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    LOAD_ALIAS=$(host_key_alias "$CLIENT_NAME")
    local host port; read -r host port <<< "$(active_endpoint_host_port)"
    LOAD_HOST="$host"; LOAD_PORT="$port"
    LOAD_ALIAS_KH=$(ensure_alias_known_hosts "$label" "${PEER_SAVED_LOCAL_USER:-}" "$port" "$LOAD_ALIAS") \
        || die "no pinned host key found for '$PEER_HOST' -- refusing to proceed without one (accept-new is not acceptable here)"
    # GlobalKnownHostsFile=/dev/null: found live (2026-07-30, pve0, endpoint
    # switched from IP to a hostname resolving to the SAME host) -- ssh
    # consults /etc/ssh/ssh_known_hosts (the SYSTEM-WIDE file) in ADDITION to
    # -o UserKnownHostsFile even when HostKeyAlias is set, keyed by the
    # literal connected address, not the alias. pve0's system file already
    # had an unrelated RSA entry for 192.168.11.11 (pre-existing, nothing to
    # do with this project), which OpenSSH treated as an "Offending key"
    # conflict against the real ED25519 key and aborted -- even though the
    # alias-keyed file matched correctly. Without this, any host that
    # happens to already have a stale/unrelated system known_hosts entry for
    # a peer's address breaks endpoint verification for a reason that has
    # nothing to do with this project's own pinning.
    #
    # CheckHostIP=no: also found live in the same test -- even with the alias
    # match succeeding, OpenSSH's CheckHostIP (on by default) separately
    # records the numeric IP's key as a courtesy anti-spoofing measure,
    # WRITING a second, hashed-hostname entry into our alias-keyed file as a
    # side effect of a successful connection. Harmless (it only records a key
    # already proven trusted via the alias), but it defeats the point of a
    # file meant to contain exactly and only what this script generated --
    # disabled since a single pinned alias entry is already this project's
    # whole trust model; the extra IP-spoofing check adds nothing here.
    LOAD_FLAGS="-K $LOAD_KEYFILE -k $LOAD_ALIAS_KH -O HostKeyAlias=$LOAD_ALIAS -O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no"
    [ "$port" != "22" ] && LOAD_FLAGS="$LOAD_FLAGS -p $port"
    # -b caps the receive-side mbuffer: per-CLIENT, not per-host -- a peer at
    # the end of a slow VPN gets a ceiling while a LAN peer on the same
    # collector does not.
    #
    # It used to ride inside LOAD_FLAGS, i.e. inside the same string as the
    # pairing key and the pinned host key, because that string was the only
    # thing a generated section could carry. Since the CONFIG v4 link split it
    # has a field of its own ('bandwidth'), so it is kept OUT of LOAD_FLAGS and
    # written as that field -- one option, one home, and a profile-forbidden
    # field instead of an unnameable substring.
    #
    # Direct engine invocations (seed, the dry-run probes) build a COMMAND LINE
    # rather than a config and therefore still append the flag; they say so at
    # each call site by using $LOAD_BW_FLAG.
    #
    # WHERE THE CAP LIVES: the PAIRING MANIFEST, not the relationship record.
    #
    # A cap describes the WIRE, and the wire belongs to the pair of hosts. Two
    # relationships to the same peer over the same link had to be given the same
    # limit twice, by hand, with nothing keeping them in step -- and nothing
    # noticing when they drifted. The manifest is per-host, so one answer serves
    # every relationship that flies over it, which is what "same link" means.
    #
    # A record written before the move still wins nothing and loses nothing: it
    # is honoured when the manifest is silent, so no deployed relationship
    # changes speed because of this commit, and the operator is told once where
    # the value now belongs.
    LOAD_BANDWIDTH="$(resolve_link_bandwidth "${PEER_SAVED_BANDWIDTH:-}" "${BANDWIDTH:-}" "$CLIENT_NAME" "$PEER_HOST")"
    LOAD_BW_FLAG=""
    [ -n "$LOAD_BANDWIDTH" ] && LOAD_BW_FLAG=" -b $LOAD_BANDWIDTH"

    # Slice 6: a no-op for a legacy (--peer-datasets) client -- PEER_SAVED_DATASETS
    # is already non-empty from the manifest sourced above. Only a mode-based
    # client (PEER_SAVED_MODE set, list deferred to the peer) triggers the fetch.
    resolve_mode_datasets
}

# ------------------------------------------------------------------------------
# seed: the ONLY step that runs deploy.sh --draft-config (always over the LAN
# endpoint -- see file header) and the ONLY step that performs a REAL,
# non-dry-run initial transfer. Installs nothing to cron.
cmd_seed() {
    local name="${1:-}"; shift || true
    local yes=0
    for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; *) die "seed: unknown option $a" ;; esac; done
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name' -- run add-client first"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        pending_enroll|seeding) ;;
        # IDEMPOTENT RERUN, same contract as add-client above: a seed whose
        # work is already durably done is a no-op, not an error. The states
        # below are exactly the ones reached AFTER a successful seed, so
        # repeating the four-command flow walks through this step instead of
        # stopping on it. Any other state is still refused.
        seed_complete|endpoint_change_pending|endpoint_verified|active)
            log "client '$name' is in state '${STATE}' -- the seed is already done, nothing to transfer"
            log "next: ./zfs-backup.sh activate $name"
            return 0 ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- seed expects pending_enroll (or seeding, to retry)" ;;
    esac

    # Slice 6: --draft-config is dataset-list-specific (it lists EVERY dataset
    # on the peer as an unfiltered candidate when PEER_SAVED_DATASETS is
    # empty, which is always true for a mode-based client) -- skip it there.
    # load_client_and_connection below calls resolve_mode_datasets, which
    # fetches the peer's committed scope file over the same LAN link and so
    # is this client's equivalent connectivity-and-readiness check.
    local label; label=$(peer_label "$PEER_HOST")
    local mpath; mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$PEER_HOST' at $mpath -- has --join run there yet?"
    local peer_mode; peer_mode=$( . "$mpath"; echo "${PEER_SAVED_MODE:-}" )

    if [ -n "$peer_mode" ]; then
        log "mode-based client ($peer_mode) -- dataset list comes from the peer's committed scope file, not --draft-config"
    else
        log "refreshing dataset list from $PEER_HOST over LAN (also confirms --join has run there)..."
        bash "$DEPLOY" --pair --peer="$PEER_HOST" --draft-config \
            || die "could not reach $PEER_HOST or list its datasets -- has --join run there yet?"
    fi

    {
        cat "$cpath"
        echo "STATE=seeding"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing"
    # Before assert_no_coverage_overlap, not after: that guard asks whether two
    # relationships collide on this host, which is a fine question and a
    # different one. This asks whether THIS relationship is about to move data
    # nobody requested -- and it is cheaper to answer, because it needs no
    # local paths. Placed ahead of every mktemp in this function so the refusal
    # has nothing to clean up.
    assert_sync_scope_within_request "$yes" "seed"

    # REV-20260809-085 F1. This is the earliest point where every candidate
    # local destination path is known, and the LAST point before the real,
    # non-dry-run transfer below. The backup-mode namespace is keyed by
    # peer_label(PEER_HOST) (see LOAD_LABEL in load_client_and_connection),
    # NOT by this client's own name -- so two differently-named relationships
    # against the SAME peer land in the SAME namespace, and without this
    # check a second one could receive real data into another relationship's
    # coverage before emit_client_sections()'s activate-time guard ever runs.
    # Reuses the same canonical assert_no_coverage_overlap() rather than a
    # second overlap implementation; that guard is itself fail-closed on
    # unreadable/unparseable/nameless active records (REV-20260809-084).
    local ds seed_candidates=()
    for ds in $PEER_SAVED_DATASETS; do
        seed_candidates+=("$(client_local_path "$ds")")
    done
    assert_no_coverage_overlap "$name" "${seed_candidates[@]}"

    local base; base=$(snapget_local_base)
    if [ "$yes" -ne 1 ]; then
        echo "Klient:  $name"
        echo "Zrodla:  $PEER_SAVED_DATASETS"
        if [ -n "$base" ]; then
            echo "Cel:     $base"
        else
            echo "Cel:     (sync -- ta sama sciezka co zrodlo, dla kazdego datasetu osobno)"
        fi
        read -rp "Wykonac PELNY transfer teraz (rzeczywiste dane, bez -n)? [t/N] " ans
        case "$ans" in t|T|tak|TAK|y|Y|yes|YES) ;; *) die "not confirmed -- no transfer performed, state stays 'seeding'" ;; esac
    fi

    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        log "seeding $ds -> $localpath (real transfer, may take a while)..."
        # 'automated_daily_', deliberately NOT the hourly prefix the recurring
        # job uses. Written down 2026-08-20 after a lab run made it look like an
        # oversight; it is not, and the reason is worth having at the call site.
        #
        # The seed is ONE snapshot, taken once, and it is not a member of the
        # cadence anything monitors. The default profile's monitor watches
        # 'automated_hourly' -- so a seed named 'automated_hourly_' would be a
        # fresh matching snapshot sitting there whether or not the hourly job
        # ever runs, i.e. the newest thing the staleness check can see would be
        # an artefact of enrolment rather than evidence of a working schedule.
        # Under the daily name the monitor finds no match and falls back to the
        # dataset's own creation time, which keeps growing if the job is broken.
        #
        # The GFS ladder prunes on 'automated_', which matches both, so the seed
        # is retained and aged like any other snapshot rather than living
        # forever outside retention. Verified live on metropolis 2026-08-20:
        # after enrolment the monitor returned rc=0 with no hourly snapshot yet.
        # shellcheck disable=SC2086
        # LAB6-F4 (2026-08-21, live): the seed was the one ACTIVE act left on a
        # chain middle. lab4's F7 made the recurring CRON line passive when the
        # source already carries an automated_* family -- but the seed still
        # stamped its own recursive @automated_daily_ onto the source
        # unconditionally. On the pve9<->pve1<-pve2 chain, R2's seed stamped
        # R3's TARGET; at the next :21, R3's own GFS ladder kept the younger
        # foreign snapshot and destroyed R3's base (zpool history: destroy at
        # 16:21:02, first tick after the stamp); every later R3 pull then
        # refused on zero common GUID -- correctly fail-closed, and wedged.
        #
        # Same probe, same shape, same wording as the emit-time passive
        # detection: an existing automated_* family on the source means this
        # relationship is a CONSUMER there. It adopts the newest existing
        # snapshot as its base (-e, generic automated_ prefix) and creates
        # nothing. A fresh source probes negative and seeds exactly as before.
        seed_profile_context
        local seed_root; seed_root=$(profile_family_root)
        local -a seed_flags=(-m "$(profile_seed_prefix)")
        # DECLARED passive (LAB-E, 2026-08-23): no probe, no family name, no
        # stamp. The relationship SAID it is passive at create, so the seed
        # adopts the newest existing snapshot whatever it is called (engine -e
        # with no mask -- measured: newest wins regardless of prefix) and the
        # engine's own "no snapshots" refusal is the empty-source answer. The
        # automated_* probe below stays ONLY for undeclared relationships,
        # where it is the sync-chain guard it was built as -- it detects OUR
        # OWN family stamped by another instance, and was never able to see a
        # foreign one (that blindness, measured, is why the declaration
        # exists).
        if [ "${PASSIVE:-0}" = "1" ]; then
            # -e PLUS the declared exclusions. The bare -e here adopted the
            # newest snapshot of ANYTHING -- including the very families the
            # relationship declared excluded, whenever an excluded one was
            # freshest (measured, passive lab: the seed shipped smiec_* to
            # the target while the installed line right next to it carried
            # -E smiec_). The closing campaign missed it because its excluded
            # snapshot happened to be older than the adopted one. Same
            # fields, same flags, same meaning as the installed line:
            # client_passive_flags is the one place that renders them.
            read -r -a seed_flags <<< "$(client_passive_flags)"
        else
        local fam_rc; source_family_exists "$ds" "$seed_root"; fam_rc=$?
        [ "$fam_rc" -eq "$SOURCE_PROBE_UNKNOWN" ]             && die_probe_unknown "$ds" "whether this seed adopts that family or creates one"
        if [ "$fam_rc" -eq 0 ]; then
            seed_flags=(-m "$seed_root" -e)
            log "seed: '$ds' already carries an automated_* family on $LOAD_HOST -- PASSIVE seed (-e): adopting the newest existing snapshot as the base, creating nothing on the source"
        fi
        fi
        # The seed obeys the same exclusions the installed job will. Without
        # this an excluded dataset lands ONCE, at seed time, and is then never
        # touched again -- a copy that exists, is stale from its first hour, and
        # no monitor covers because no job names it. Measured on the lab: -X
        # kept tree/a out of every cron run while the seed had already put it
        # there. Only under -R, because that is the only shape -X applies to and
        # the engines refuse it otherwise.
        if is_recursive_root "$ds"; then
            seed_flags+=(-R)
            local _sx
            for _sx in $(client_exclude_flags); do seed_flags+=("$_sx"); done
        fi
        if bash "$SNAPGET" "${seed_flags[@]}" $LOAD_FLAGS$LOAD_BW_FLAG "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
            log "  OK: $ds"
        else
            warn "  FAILED: $ds"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed to seed -- state stays 'seeding', fix and re-run seed $name"

    {
        cat "$cpath"
        echo "STATE=seed_complete"
        printf 'SEED_COMPLETED_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    # REV-20260802-033 F4 / owner decisions 13-14: set-endpoint is conditional,
    # not a standard step -- it is needed only when the address used by SSH
    # actually changes (a new host or port). A routed site-to-site VPN that
    # preserves the original host:port needs no endpoint mutation at all: just
    # re-run verify-endpoint against the endpoint already on record. Saying
    # "then set-endpoint" followed by "verify-endpoint" here used to read as
    # a fixed two-step sequence, which is exactly the failure mode F4 warns
    # about -- an administrator inventing or repeating an address that never
    # changed. "the collector relocates", not "the source" (U9): confirmed in
    # code that this scenario is the collector being physically moved. The
    # OTHER party in this sentence -- the machine SSH connects to -- is the
    # peer, not "the source": that word is reserved for the machine that
    # moves, and this message already used it once for the collector two
    # sentences earlier, so reusing it here for the peer would say "moved"
    # about the wrong end again in a subtler way (slice 10, REV-20260802-033).
    # Issue #9: the ordinary path is four commands, so the third one names the
    # fourth and nothing else. This used to recite the low-level sequence --
    # final-catchup, set-endpoint, verify-endpoint, activate-client -- which is
    # exactly the sequencing the operator is not supposed to have to know, and it
    # said it even when none of it applied. Those verbs remain available for
    # expert repair; they are no longer the instruction an ordinary seed hands out.
    log "client '$name' seed complete."
    log "next: ./zfs-backup.sh activate $name"
    log "      (add --host=HOST[:PORT] if SSH now reaches the peer at a DIFFERENT host or port than the one just seeded, e.g. a routed VPN address; activate then handles the final catch-up, the endpoint switch, verification, the cron preview and its installation)"
}

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# REV-20260730-005 F3 / REV-20260731-007 §7: one last incremental over the
# endpoint that still works, immediately before THIS COLLECTOR is physically
# moved (REV-20260802-033 U9 confirmed in code that this message used to name
# the wrong machine -- "the source" -- when the one actually being relocated,
# in this project's own scenario, is the collector running this command).
#
# Without it the common base is as old as the seed, so the first transfer over
# the new link carries every change since then -- over a VPN, which is the slow
# link, and at the moment nobody is watching. It also proves the incremental
# path works over the OLD endpoint while the old endpoint is still there to be
# proven on: if the base has gone, you find out while you can still fix it
# cheaply.
#
# Deliberately a real transfer, not `-n`. A dry run says a plan exists; it does
# not move the data, and moving the data is the entire point.
cmd_final_catchup() {
    local name="${1:-}"; shift || true
    local yes=0
    for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; *) die "final-catchup: unknown option $a" ;; esac; done
    [ -n "$name" ] || die "final-catchup requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        seed_complete|endpoint_verified|active|endpoint_change_pending) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- final-catchup needs a seeded client" ;;
    esac

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list"

    if [ "$yes" -ne 1 ]; then
        echo "Klient:   $name"
        echo "Endpoint: $(endpoint_display)"
        echo "Zrodla:   $PEER_SAVED_DATASETS"
        read -rp "Wykonac koncowy transfer przyrostowy teraz? [t/N] " ans
        case "$ans" in t|T|tak|TAK|y|Y|yes|YES) ;; *) die "not confirmed -- nothing transferred" ;; esac
    fi

    local base; base=$(snapget_local_base)
    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        log "final catch-up $ds -> $localpath over '$(endpoint_display)'..."
        # 'automated_daily_', deliberately NOT the hourly prefix the recurring
        # job uses. Written down 2026-08-20 after a lab run made it look like an
        # oversight; it is not, and the reason is worth having at the call site.
        #
        # The seed is ONE snapshot, taken once, and it is not a member of the
        # cadence anything monitors. The default profile's monitor watches
        # 'automated_hourly' -- so a seed named 'automated_hourly_' would be a
        # fresh matching snapshot sitting there whether or not the hourly job
        # ever runs, i.e. the newest thing the staleness check can see would be
        # an artefact of enrolment rather than evidence of a working schedule.
        # Under the daily name the monitor finds no match and falls back to the
        # dataset's own creation time, which keeps growing if the job is broken.
        #
        # The GFS ladder prunes on 'automated_', which matches both, so the seed
        # is retained and aged like any other snapshot rather than living
        # forever outside retention. Verified live on metropolis 2026-08-20:
        # after enrolment the monitor returned rc=0 with no hourly snapshot yet.
        # shellcheck disable=SC2086
        # LAB6-F4 (2026-08-21, live): the seed was the one ACTIVE act left on a
        # chain middle. lab4's F7 made the recurring CRON line passive when the
        # source already carries an automated_* family -- but the seed still
        # stamped its own recursive @automated_daily_ onto the source
        # unconditionally. On the pve9<->pve1<-pve2 chain, R2's seed stamped
        # R3's TARGET; at the next :21, R3's own GFS ladder kept the younger
        # foreign snapshot and destroyed R3's base (zpool history: destroy at
        # 16:21:02, first tick after the stamp); every later R3 pull then
        # refused on zero common GUID -- correctly fail-closed, and wedged.
        #
        # Same probe, same shape, same wording as the emit-time passive
        # detection: an existing automated_* family on the source means this
        # relationship is a CONSUMER there. It adopts the newest existing
        # snapshot as its base (-e, generic automated_ prefix) and creates
        # nothing. A fresh source probes negative and seeds exactly as before.
        seed_profile_context
        local seed_root; seed_root=$(profile_family_root)
        local -a seed_flags=(-m "$(profile_seed_prefix)")
        # DECLARED passive (LAB-E, 2026-08-23): no probe, no family name, no
        # stamp. The relationship SAID it is passive at create, so the seed
        # adopts the newest existing snapshot whatever it is called (engine -e
        # with no mask -- measured: newest wins regardless of prefix) and the
        # engine's own "no snapshots" refusal is the empty-source answer. The
        # automated_* probe below stays ONLY for undeclared relationships,
        # where it is the sync-chain guard it was built as -- it detects OUR
        # OWN family stamped by another instance, and was never able to see a
        # foreign one (that blindness, measured, is why the declaration
        # exists).
        if [ "${PASSIVE:-0}" = "1" ]; then
            # -e PLUS the declared exclusions. The bare -e here adopted the
            # newest snapshot of ANYTHING -- including the very families the
            # relationship declared excluded, whenever an excluded one was
            # freshest (measured, passive lab: the seed shipped smiec_* to
            # the target while the installed line right next to it carried
            # -E smiec_). The closing campaign missed it because its excluded
            # snapshot happened to be older than the adopted one. Same
            # fields, same flags, same meaning as the installed line:
            # client_passive_flags is the one place that renders them.
            read -r -a seed_flags <<< "$(client_passive_flags)"
        else
        local fam_rc; source_family_exists "$ds" "$seed_root"; fam_rc=$?
        [ "$fam_rc" -eq "$SOURCE_PROBE_UNKNOWN" ]             && die_probe_unknown "$ds" "whether this seed adopts that family or creates one"
        if [ "$fam_rc" -eq 0 ]; then
            seed_flags=(-m "$seed_root" -e)
            log "seed: '$ds' already carries an automated_* family on $LOAD_HOST -- PASSIVE seed (-e): adopting the newest existing snapshot as the base, creating nothing on the source"
        fi
        fi
        # The seed obeys the same exclusions the installed job will. Without
        # this an excluded dataset lands ONCE, at seed time, and is then never
        # touched again -- a copy that exists, is stale from its first hour, and
        # no monitor covers because no job names it. Measured on the lab: -X
        # kept tree/a out of every cron run while the seed had already put it
        # there. Only under -R, because that is the only shape -X applies to and
        # the engines refuse it otherwise.
        if is_recursive_root "$ds"; then
            seed_flags+=(-R)
            local _sx
            for _sx in $(client_exclude_flags); do seed_flags+=("$_sx"); done
        fi
        if bash "$SNAPGET" "${seed_flags[@]}" $LOAD_FLAGS$LOAD_BW_FLAG "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
            log "  OK: $ds"
        else
            warn "  FAILED: $ds"
            failed=$((failed + 1))
        fi
    done
    # Recorded ONLY on a complete success. A partial catch-up must not satisfy
    # the gate in set-endpoint -- that would let the weakest dataset decide the
    # whole relocation was safe.
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed -- NOT recording a final catch-up. Fix and re-run: final-catchup $name"

    # REV-20260731-008 F1: the endpoint NAME alone proves almost nothing -- it
    # survives a change of host or port, and it never goes stale. Record the
    # exact transport that was just proven to work, and when.
    #
    # REV-20260802-033 U9: FINAL_CATCHUP_ENDPOINT is now always the literal
    # "$LOAD_HOST:$LOAD_PORT" (never "$ACTIVE_ENDPOINT" directly), so
    # set-endpoint's gate can compare it by simple string equality regardless
    # of whether THIS client's record is legacy-shaped (ACTIVE_ENDPOINT still
    # "lan"/"vpn") or already migrated. A legacy client's most recent
    # pre-upgrade catch-up (recorded as "lan"/"vpn") will read as unmatched
    # once -- fail-closed, asks for a fresh one instead of trusting a record
    # in a format this comparison no longer parses.
    {
        cat "$cpath"
        write_client_field FINAL_CATCHUP_ENDPOINT "$LOAD_HOST:$LOAD_PORT"
        write_client_field FINAL_CATCHUP_HOST "$LOAD_HOST"
        write_client_field FINAL_CATCHUP_PORT "$LOAD_PORT"
        printf 'FINAL_CATCHUP_EPOCH=%s\n' "$(date '+%s')"
        printf 'FINAL_CATCHUP_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    chmod 0600 "$cpath"
    log "client '$name': final catch-up over '$(endpoint_display)' complete. This collector may now be relocated. If the peer is still reachable at the SAME host:port afterward (e.g. a routed VPN), no set-endpoint call is needed at all -- just re-run: $0 verify-endpoint $name"
}

cmd_set_endpoint() {
    local name="${1:-}"; shift || true
    local host="" skip_catchup=0 allow_stale=0
    for a in "$@"; do
        case "$a" in
            --host=*) host="${a#*=}" ;;
            --skip-final-catchup) skip_catchup=1 ;;
            --allow-stale-catchup) allow_stale=1 ;;
            *) die "set-endpoint: unknown option $a" ;;
        esac
    done
    [ -n "$host" ] || die "set-endpoint requires --host=HOST[:PORT]"

    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        seed_complete|endpoint_verified|active) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- set-endpoint needs seed_complete or later (seed must finish first)" ;;
    esac

    # parse_endpoint_arg dies on anything that is not a plain hostname/IPv4 and
    # a real port; write_client_field %q-quotes what survives (F1).
    local new_host new_port; read -r new_host new_port <<< "$(parse_endpoint_arg "$host")"
    local new_endpoint="$new_host:$new_port"
    local leaving_host leaving_port; read -r leaving_host leaving_port <<< "$(active_endpoint_host_port)"
    local leaving_endpoint="$leaving_host:$leaving_port"

    # REV-20260802-033 U9: the routed-VPN case needs no set-endpoint call at
    # all, by construction -- if the address given IS already current, there
    # is nothing to gate or write. This is what makes "set-endpoint is
    # optional, not a standard step" true structurally, not just by habit.
    if [ "$new_endpoint" = "$leaving_endpoint" ]; then
        log "client '$name': '$new_endpoint' is already the current endpoint -- nothing to change. (A routed VPN that preserves the same host:port needs no set-endpoint call at all; run verify-endpoint directly.)"
        return 0
    fi

    # The gate (REV-20260731-007 §7). A DIFFERENT endpoint is the relocation
    # moment, so the catch-up must already have happened over the endpoint
    # being left -- while it still worked. A catch-up recorded against some
    # OTHER address says nothing about this switch.
    #
    # REV-20260802-033 U9 simplification: FINAL_CATCHUP_ENDPOINT is now
    # always the literal address it was recorded against (cmd_final_catchup),
    # the same domain as $leaving_endpoint here -- so a single string compare
    # replaces the old three-way name+host+port cross-check.
    #
    # Skippable, because the reviewer's case is real: sometimes the collector
    # is already unplugged and there is nothing left to catch up over. Then it
    # is a deliberate, logged decision rather than an accident.
    if [ "$skip_catchup" -eq 1 ]; then
        warn "SKIPPING the final catch-up over '$leaving_endpoint' at your request. The first transfer over '$new_endpoint' will carry everything since $( [ -n "${FINAL_CATCHUP_AT:-}" ] && echo "$FINAL_CATCHUP_AT" || echo "the seed (${SEED_COMPLETED_AT:-unknown})" ) -- over the slow link, unattended. Only correct if the collector is already disconnected from '$leaving_endpoint'."
    else
        local why=""
        if [ "${FINAL_CATCHUP_ENDPOINT:-}" != "$leaving_endpoint" ]; then
            why="no final catch-up has been run over '$leaving_endpoint'"
        else
            local age=$(( $(date '+%s') - ${FINAL_CATCHUP_EPOCH:-0} ))
            if [ "${FINAL_CATCHUP_EPOCH:-0}" -le 0 ]; then
                why="the recorded catch-up predates freshness tracking, so its age cannot be established"
            elif [ "$age" -gt "$CATCHUP_MAX_AGE" ]; then
                if [ "$allow_stale" -eq 1 ]; then
                    warn "the catch-up over '$leaving_endpoint' is $((age / 60)) min old (limit $((CATCHUP_MAX_AGE / 60)) min) and you passed --allow-stale-catchup. Everything written since ${FINAL_CATCHUP_AT:-?} will cross the slow link on the first transfer."
                else
                    why="the catch-up over '$leaving_endpoint' is $((age / 60)) min old (limit $((CATCHUP_MAX_AGE / 60)) min). Writes since then would all cross the slow link"
                fi
            fi
        fi
        if [ -n "$why" ]; then
            die "refusing to switch '$name' from '$leaving_endpoint' to '$new_endpoint': $why.
  Run it BEFORE disconnecting, while the old link still works:
      $0 final-catchup $name
  It keeps the first transfer over the new link small and proves the incremental
  base is intact while it is still cheap to fix.
  If the collector is ALREADY disconnected and there is nothing to catch up over,
  say so explicitly: $0 set-endpoint $name --host=$new_host:$new_port --skip-final-catchup"
        fi
        log "final catch-up over '$leaving_endpoint' recorded at ${FINAL_CATCHUP_AT:-?} -- proceeding with the switch"
    fi

    # ENDPOINT_KNOWN (U9): the address being left is remembered as a fallback
    # candidate for a future verify-endpoint, and the one being switched TO is
    # dropped from that list if it was already on it (it is current now, not
    # "known-other"). A legacy record's dormant second slot (whichever of
    # ENDPOINT_LAN_*/ENDPOINT_VPN_* is NOT the one ACTIVE_ENDPOINT names) is
    # folded in on this, its first switch since the upgrade -- otherwise that
    # address would simply be lost rather than becoming a known candidate.
    local -a kept=()
    local k
    for k in ${ENDPOINT_KNOWN:-}; do
        [ "$k" = "$new_endpoint" ] && continue
        [ "$k" = "$leaving_endpoint" ] && continue
        kept+=("$k")
    done
    kept+=("$leaving_endpoint")
    case "${ACTIVE_ENDPOINT:-}" in
        lan|vpn)
            local other=vpn; [ "$ACTIVE_ENDPOINT" = vpn ] && other=lan
            local ov; ov=$(endpoint_host_var "$other"); ov="${!ov:-}"
            if [ -n "$ov" ]; then
                local op; op=$(endpoint_port_var "$other"); op="${!op:-22}"
                local other_endpoint="$ov:$op"
                case " ${kept[*]} " in *" $other_endpoint "*) ;; *) [ "$other_endpoint" != "$new_endpoint" ] && kept+=("$other_endpoint") ;; esac
            fi
            ;;
    esac

    local out="$cpath.new"
    cp -p "$cpath" "$out" || die "could not copy $cpath"
    {
        write_client_field ACTIVE_ENDPOINT "$new_endpoint"
        write_client_field ENDPOINT_KNOWN "${kept[*]}"
        # Switching the active endpoint means the OLD verification no longer
        # says anything about THIS endpoint -- require a fresh verify-endpoint
        # before cron can be (re)installed against it.
        #
        # REV-20260730-005 F4: an ALREADY-ACTIVE client keeps its installed
        # cron line running against the endpoint it was generated for, which
        # used to be recorded only as "STATE=seed_complete" -- so `status`
        # said seed_complete while backups were in fact still running fine
        # over the old endpoint, and nothing anywhere named the divergence.
        # The desired endpoint (ACTIVE_ENDPOINT) and the one the installed
        # cron actually uses (INSTALLED_ENDPOINT, written by activate-client)
        # are separate fields, and a pending change gets its own state rather
        # than being flattened into an earlier one.
        if [ "${STATE:-}" = "active" ]; then
            write_client_field STATE endpoint_change_pending
        elif [ "${STATE:-}" != "seed_complete" ]; then
            write_client_field STATE seed_complete
        fi
    } >> "$out"
    mv -f "$out" "$cpath"
    chmod 0600 "$cpath"
    if [ "${STATE:-}" = "active" ]; then
        warn "endpoint changed to '$new_endpoint', but the INSTALLED cron still runs over '${INSTALLED_ENDPOINT:-?}'. Backups keep working over the old endpoint until: verify-endpoint $name, then activate-client $name."
    fi
    log "client '$name' desired endpoint is now '$new_endpoint' ('$leaving_endpoint' kept as a known candidate)"
}

# REV-20260730-005 F2: this used to conclude "incremental" from the ABSENCE
# of the words "full send" in snapget.sh's prose output -- a negative
# heuristic over a log message, which a reworded line or any new rc=0
# planner branch would silently have turned into a false "verified".
# snapget.sh -n now prints exactly one machine-readable verdict per dataset
# on STDOUT (logging goes to stderr): PLAN=INCREMENTAL / PLAN=FULL, derived
# from the same $common_snapshot the real transfer branches on. Anything
# that is not a recognised PLAN= line is treated as unknown and FAILS --
# fail-closed, per the review.
#
# REV-20260802-033 U9: extracted from cmd_verify_endpoint so it can be run
# against ANY candidate host:port, not just the one already on record --
# verify-endpoint below calls this once per candidate until one comes back
# clean. Sets $PROBE_DETAIL to a human-readable report of whatever went
# wrong (empty on success). Re-derives the alias known_hosts file itself
# (ensure_alias_known_hosts, keyed by port) rather than reusing the outer
# LOAD_ALIAS_KH/LOAD_FLAGS, because a fallback candidate can use a different
# port than the one those were built for.
probe_snapget_endpoint() {   # <host> <port>
    local phost="$1" pport="$2"
    PROBE_DETAIL=""
    local pkh; pkh=$(ensure_alias_known_hosts "$LOAD_LABEL" "${PEER_SAVED_LOCAL_USER:-}" "$pport" "$LOAD_ALIAS") || {
        PROBE_DETAIL="  no pinned host key for port $pport (never verified there before)"
        return 1
    }
    local pflags="-K $LOAD_KEYFILE -k $pkh -O HostKeyAlias=$LOAD_ALIAS -O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no"
    [ "$pport" != "22" ] && pflags="$pflags -p $pport"
    [ -n "${LOAD_BANDWIDTH:-}" ] && pflags="$pflags -b $LOAD_BANDWIDTH"

    local base; base=$(snapget_local_base)
    local ds out plan errtmp failed=0 unknown=0 needs_full=0
    errtmp=$(mktemp) || die "mktemp failed"
    for ds in $PEER_SAVED_DATASETS; do
        # stdout carries the machine-readable PLAN= verdict; stderr carries
        # the human log, captured separately (never mixed into $out, which is
        # what made the old text heuristic fragile) but not discarded either
        # -- REV-20260802-033 F4, the source-IP/firewall diagnostic lives here.
        # shellcheck disable=SC2086
        out=$(bash "$SNAPGET" -n $(is_recursive_root "$ds" && printf %s -R) $pflags "${LOAD_ACCOUNT}@${phost}:${ds}" "$base" 2>"$errtmp"); local rc=$?
        if [ "$rc" -ne 0 ]; then
            failed=$((failed + 1))
            PROBE_DETAIL="${PROBE_DETAIL}  FAILED (rc=$rc): $ds"$'\n'
            if [ -s "$errtmp" ]; then
                while IFS= read -r errline; do PROBE_DETAIL="${PROBE_DETAIL}    $errline"$'\n'; done < "$errtmp"
            fi
            continue
        fi
        plan=$(printf '%s\n' "$out" | grep -m1 '^PLAN=' || true)
        case "$plan" in
            # base=null is NOT an incremental: it means "no common snapshot",
            # i.e. a full transfer on every run, forever -- the exact shape the
            # 2026-08-01 live defect wore, and LAB-E measured this verdict
            # slipping through as "incremental-only confirmed" for an EXCLUDED
            # child the probe should never have asked about. It now counts as
            # needing a full, so activation stops and names the dataset.
            "PLAN=INCREMENTAL base=null"*)
                needs_full=$((needs_full + 1))
                PROBE_DETAIL="${PROBE_DETAIL}  FULL-FOREVER (base=null): $ds"$'\n' ;;
            PLAN=INCREMENTAL*) ;;
            PLAN=FULL*)
                needs_full=$((needs_full + 1))
                PROBE_DETAIL="${PROBE_DETAIL}  $ds would need a FULL transfer -- no common base"$'\n' ;;
            *)
                unknown=$((unknown + 1))
                PROBE_DETAIL="${PROBE_DETAIL}  $ds: no PLAN= verdict (got: ${plan:-<none>})"$'\n'
                # rc=0 with no verdict was UNDIAGNOSABLE: the engine's stderr
                # was captured but printed only on rc!=0, so this branch said
                # '<none>' and nothing else -- LAB-E and the closing campaign
                # both stalled here blind. The engine's own last lines ARE the
                # reason; show them.
                if [ -s "$errtmp" ]; then
                    while IFS= read -r errline; do PROBE_DETAIL="${PROBE_DETAIL}    $errline"$'\n'; done < <(tail -n 4 "$errtmp")
                fi ;;
        esac
    done
    rm -f "$errtmp"
    [ "$failed" -eq 0 ] && [ "$unknown" -eq 0 ] && [ "$needs_full" -eq 0 ]
}

# ------------------------------------------------------------------------------
# REV-20260730-004 §3.6: must do SSH + host-key verification + snapget -n, and
# confirm a full transfer is NOT required (i.e. an incremental base already
# exists) -- not just "the command exited 0", which a first-ever send would
# also do.
#
# REV-20260802-033 U9: tries the CURRENT endpoint first; if it does not come
# back clean, tries each address in ENDPOINT_KNOWN in turn -- addresses that
# have worked for this client before -- rather than immediately asking the
# operator to type one in. Only when NONE of them work does this refuse and
# point at set-endpoint. A candidate that answers and is not the one already
# on record is PROMOTED to ACTIVE_ENDPOINT: it already proved itself once,
# which is the entire reason known candidates are kept at all.
cmd_verify_endpoint() {
    local name="${1:-}"
    [ -n "$name" ] || die "verify-endpoint requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        seed_complete|endpoint_verified|endpoint_change_pending) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- verify-endpoint needs seed_complete, endpoint_change_pending, or endpoint_verified (to re-check)" ;;
    esac

    # Endpoint probing tolerates an unreachable source: that is the question it
    # is asking. Everything else keeps the refusal.
    ENDPOINT_PROBE=1 load_client_and_connection "$cpath"
    local current="$LOAD_HOST:$LOAD_PORT"
    log "verifying endpoint '$current' for '$name'..."

    local -a candidates=("$current")
    local k
    for k in ${ENDPOINT_KNOWN:-}; do
        [ "$k" = "$current" ] && continue
        candidates+=("$k")
    done

    local chosen="" tried_report=""
    local cand ch cp
    for cand in "${candidates[@]}"; do
        ch="${cand%:*}"; cp="${cand##*:}"
        if probe_snapget_endpoint "$ch" "$cp"; then
            chosen="$cand"
            break
        fi
        tried_report="${tried_report}'$cand':"$'\n'"$PROBE_DETAIL"
        [ "$cand" != "$current" ] && warn "  '$cand' (known candidate) did not answer either"
    done

    if [ -z "$chosen" ]; then
        # A DELIBERATE refusal is not a dead endpoint. The probe is a
        # data-plane command, so a disabled relationship refuses it at the
        # peer -- and the old message then blamed the address, sending the
        # operator to hunt a network problem that does not exist. Same rule
        # as the ssh-exit-255 discrimination elsewhere in this estate: never
        # blame the link for an answer the far end gave on purpose. Found
        # live during the hard-disable campaign, 2026-08-06.
        case "$tried_report" in
            *PAIR_DISABLED*)
                die "relationship '$name' is DISABLED at the peer, so its endpoints cannot be verified -- the peer answered, it refused. This is not an address problem.
Enable it first: $0 enable-client $name   (then re-run verify-endpoint)" ;;
        esac
        die "none of the known endpoints answered for '$name' (tried: ${candidates[*]}):
$tried_report
If the peer has a genuinely new address, record it: $0 set-endpoint $name --host=NEW"
    fi

    if [ "$chosen" != "$current" ]; then
        warn "current endpoint '$current' did not answer; '$chosen' (a previously known address) did -- promoting it to the active endpoint."
    fi

    {
        cat "$cpath"
        if [ "$chosen" != "$current" ]; then
            write_client_field ACTIVE_ENDPOINT "$chosen"
            local -a kept=("$current")
            for k in ${ENDPOINT_KNOWN:-}; do
                [ "$k" = "$chosen" ] && continue
                [ "$k" = "$current" ] && continue
                kept+=("$k")
            done
            write_client_field ENDPOINT_KNOWN "${kept[*]}"
        fi
        write_client_field STATE                endpoint_verified
        write_client_field ENDPOINT_VERIFIED_AT "$(date '+%Y-%m-%d %H:%M:%S')"
        write_client_field ENDPOINT_VERIFIED_FOR "$chosen"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    log "client '$name': endpoint '$chosen' verified, incremental-only confirmed for every dataset. Ready for activate-client."
}

# ------------------------------------------------------------------------------
activation_is_new_relationship() {   # <state> <installed-endpoint>
    [ "$1" = endpoint_verified ] && [ -z "$2" ]
}

cmd_activate_client() {
    local name="${1:-}"; shift || true
    local yes=0 verbose=0
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            --verbose) verbose=1 ;;
            *) die "activate-client: unknown option $a" ;;
        esac
    done
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name' -- run add-client first"
    # shellcheck disable=SC1090
    . "$cpath"
    # A re-activation (endpoint switch, etc.) already has its own CRON_CONFIG
    # on record from the FIRST activation. read_server_conf below unconditionally
    # resets CRON_CONFIG="" and only refills it from $SERVER_CONF -- on a host
    # with no server.conf (setup-server never run with an explicit --config),
    # that reset was never undone, so the recorded value was silently replaced
    # by a freshly recomputed default path. A client re-activating would then
    # write its next managed sections into the WRONG file, leaving the actually
    # installed crontab/config orphaned with no record of where it lives.
    # Captured here, before that reset, and restored after it.
    local recorded_cron_config="${CRON_CONFIG:-}"
    local recorded_local_user="${LOCAL_USER:-}"
    # REV-20260809-088 F1: STATE here is still whatever it was BEFORE this
    # call -- 'endpoint_verified' means this relationship has never reached
    # 'active' before, i.e. this really is the moment a NEW relationship is
    # being created and may first rely on a template identity. 'active'
    # means it is being re-activated (e.g. after set-endpoint) and its
    # already-installed policy must not be re-validated against whatever
    # the active profile currently renders.
    local is_new_relationship=0
    # An endpoint change also passes through endpoint_verified, but it already
    # has an installed endpoint/config. Treating every endpoint_verified state
    # as CREATE would regenerate policy during a transport-only change. The
    # durable installed-endpoint fact distinguishes first activation from a
    # resumed re-activation without adding another state.
    activation_is_new_relationship "${STATE:-}" "${INSTALLED_ENDPOINT:-}" \
        && is_new_relationship=1
    case "${STATE:-}" in
        endpoint_verified|active) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- activate-client requires endpoint_verified (run seed, then verify-endpoint first). Fail-closed: no cron entry exists before this gate." ;;
    esac

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing"
    # Also checked in cmd_seed, and both are needed rather than one: activate is
    # reachable directly on an already-seeded client, and it is the step that
    # installs the RECURRING job. Seed moves the data once; activate is what
    # makes an unrequested dataset keep arriving every hour.
    assert_sync_scope_within_request "$yes" "activate"

    apply_client_profile_choice "$is_new_relationship" "${PROFILE:-}"

    read_server_conf
    # Both halves in one call, and HERE rather than at the cronfile line below,
    # because the sync delegation a few lines down already needs the account.
    # That is why the account resolution used to live up here and the config
    # resolution a hundred lines further on: two questions, one answer each,
    # separated by enough code that nobody saw they were the same decision.
    # The ladder is unchanged (recorded -> server.conf -> adopt -> default for
    # the config; record -> manifest -> root for the account); only its home is.
    cron_context_resolve adopt "" "" "$recorded_cron_config" "$recorded_local_user"
    log "activate: jobs run as ${CRON_CTX_USER:-root} ($CRON_CTX_WHY_USER -- recorded with the relationship below)"

    # Sync mode: the RECEIVE-side delegation that backup mode gets at --pair
    # time (deploy.sh grants ZFS_PERMS on target/label) has no counterpart,
    # because at --pair time a sync relationship's dataset list is still
    # deferred to the source -- there is nothing to grant on yet. Found live
    # 2026-08-17 (lab3): the seed (root) passed, and the first cron run as the
    # account died with 'cannot receive incremental stream: permission denied'.
    # HERE the list is resolved, so this is where the grant belongs: on each
    # dataset's local landing path (sync = the same path, so the parent must
    # exist to carry the delegation; zfs receive -p creates children under it).
    # Idempotent -- zfs allow re-applied is a no-op -- and skipped for root.
    if [ "${PEER_SAVED_MODE:-}" = sync ] && [ -n "${LOCAL_USER:-}" ] && [ "$LOCAL_USER" != root ]; then
        local sync_ds sync_parent
        for sync_ds in $PEER_SAVED_DATASETS; do
            sync_parent="${sync_ds%/*}"
            [ "$sync_parent" != "$sync_ds" ] || sync_parent="$sync_ds"
            if ! zfs list -H -o name -- "$sync_parent" >/dev/null 2>&1; then
                zfs create -p -- "$sync_parent" \
                    || die "activate: could not create the local landing parent '$sync_parent' for sync dataset '$sync_ds'"
                log "activate: created local landing parent $sync_parent (sync reproduces the source path here)"
            fi
            zfs allow -u "$LOCAL_USER" "$ZFS_PERMS_LOCAL_RECEIVE" -- "$sync_parent" \
                || die "activate: zfs allow ($ZFS_PERMS_LOCAL_RECEIVE) on $sync_parent for '$LOCAL_USER' failed"
        done
        log "activate: sync receive delegated ($ZFS_PERMS_LOCAL_RECEIVE) to '$LOCAL_USER' on the local landing parent(s)"
    fi
    # The SAME delegation for backup mode, which never had it: only the sync
    # branch above delegated local receive, so a backup relationship's
    # delegated account failed every pull with 'cannot receive incremental
    # stream: permission denied' -- masked for weeks because the SEED runs as
    # root and the cron idiom's last command always exits 0 (measured,
    # passive lab, the first scheduled tick). Backup mode lands everything
    # under one base (target/<label>), so one grant there covers the
    # relationship -- including the account-run ladder prune (destroy is in
    # the set).
    if [ "${PEER_SAVED_MODE:-}" != sync ] && [ -n "${LOCAL_USER:-}" ] && [ "$LOCAL_USER" != root ]; then
        local bk_base; bk_base=$(snapget_local_base)
        if [ -n "$bk_base" ]; then
            zfs list -H -o name -- "$bk_base" >/dev/null 2>&1                 || zfs create -p -- "$bk_base"                 || die "activate: could not create the local backup base '$bk_base'"
            zfs allow -u "$LOCAL_USER" "$ZFS_PERMS_LOCAL_RECEIVE" -- "$bk_base"                 || die "activate: zfs allow ($ZFS_PERMS_LOCAL_RECEIVE) on $bk_base for '$LOCAL_USER' failed"
            log "activate: backup receive delegated ($ZFS_PERMS_LOCAL_RECEIVE) to '$LOCAL_USER' on $bk_base"
        fi
    fi
    # Resolution order: recorded CRON_CONFIG -> the Source line of the block
    # ALREADY INSTALLED in the target account's crontab -> only then the /etc
    # default. The middle step is what the lab3 final run proved necessary:
    # once the install goes to the ACCOUNT's crontab (F3), that crontab may
    # already carry a production block generated from a different file, and a
    # crontab has ONE managed block -- installing from a freshly-defaulted path
    # would DELETE every job the installed file describes. The 2026-07-30
    # incident guard caught exactly that and refused; this makes the refusal
    # unnecessary by adopting the installed truth, same as setup-server already
    # does. New sections MERGE into the host's one config, which is the
    # single-writer design, not a workaround.
    # Resolved once, at the top of this function, together with the account.
    local cronfile="$CRON_CTX_FILE"
    log "activate: config $cronfile ($CRON_CTX_WHY_FILE)"

    # REV-20260730-003 F4/F6: everything below builds and validates a WORKING
    # COPY of the config -- the real file is never touched until validation,
    # dry-run, AND confirmation all succeed, and even then only via an atomic
    # swap with rollback if --install then fails (atomic_replace_and_install,
    # hardened per REV-20260730-004 F7 to also back up/restore the crontab
    # itself, not just the config file).
    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX") \
        || die "mktemp failed next to $cronfile"
        workfile_track "$workfile"
    if [ -f "$cronfile" ]; then
        cp -p "$cronfile" "$workfile" || { rm -f "$workfile"; die "could not copy $cronfile to a working copy"; }
    else
        # A collector with no config yet -- the ordinary first enrolment. This
        # used to leave the working copy EMPTY, and because mktemp had already
        # created the file, ensure_cron_config's "seed a brand new config" branch
        # never ran: it only fires when the file does not exist. The run then
        # built datasets on top of nothing, gen-cron refused the result for a
        # missing [defaults] host_label, and the four-command flow stopped on a
        # fresh two-server setup telling the operator to repair a config by hand.
        write_fresh_config_defaults "$workfile" || { rm -f "$workfile"; die "could not create working copy $workfile"; }
    fi
    # mktemp makes it 0600, and `cp -p` would carry the original's mode over.
    # Both the PREVIEW and the install read this file as the collector account,
    # so it has to be readable before either runs -- not after the swap.
    chmod 0644 "$workfile" || { rm -f "$workfile"; die "could not set the mode on $workfile"; }
    # REV-20260810-090 F1/F2: decide whether this run needs a profile at all
    # BEFORE ensure_cron_config, because ensure_cron_config is where the profile
    # would otherwise be loaded and its templates appended. The plan is computed
    # from the installed config and the client record only -- no profile is
    # consulted to answer "is a profile required", which would be circular.
    # PROFILE_GFS is read off the installed file first, for the same reason.
    detect_profile_gfs "$workfile"
    client_section_plan "$workfile" "$name" "$is_new_relationship"
    ensure_cron_config "$workfile" "$is_new_relationship" "$PLAN_NEEDS_PROFILE"

    # First activation generates the sections from the profile. A re-activation
    # (e.g. after set-endpoint) refreshes only the endpoint-owned fields inside
    # the sections already installed, so an operator's customization and the
    # policy the relationship was created with both survive -- REV-20260809-089,
    # and the same one-way-handoff boundary REV-20260809-088 F1 drew for
    # ensure_cron_config, one level down.
    local ds localpath
    local -a managed=()
    emit_client_sections "$workfile" "$name" "$is_new_relationship" || { rm -f "$workfile"; die "could not write the sections for '$name' into the working copy"; }

    log "cron config (working copy): ${#managed[@]} dataset(s) written for endpoint '$(endpoint_display)'"

    log "validating generated config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the generated config -- fix the underlying issue and re-run activate-client (see output above). $cronfile was NOT touched."
    fi

    log "dry-run test of each dataset (snapget.sh -n)..."
    # The dry-run must rehearse THE LINE THAT WILL RUN, not a stripped-down
    # cousin of it. It used to call snapget with no -m, no -e, and -- for a
    # sync client -- an EMPTY-STRING base argument where the generated line
    # has none at all. On the lab3 chain that combination made snapget exit 1
    # while the real installed line was perfectly healthy: the gate rejected
    # a working deployment by testing a different one. The prefix and the
    # passive -e are read back from the WORKFILE's own [dataset:] section --
    # the same sections the install is about to publish -- and the base
    # argument is OMITTED (not passed empty) exactly when the generated line
    # omits it.
    local failed=0
    local base; base=$(snapget_local_base)
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        local dr_prefix dr_flags
        dr_prefix=$(installed_dataset_field "$workfile" "$localpath" prefix)
        dr_flags=$(installed_dataset_field "$workfile" "$localpath" flags)
        case " $dr_flags " in
        *" -e "*)
            # PASSIVE dataset: `snapget -n -e` is the wrong rehearsal. On an
            # already-up-to-date pair it exits 1 with no message ("nothing to
            # transfer" is indistinguishable from failure at the exit-code
            # level), which refused the lab3 chain one gate before the finish
            # line. What a passive line needs to work is exactly two things,
            # both testable without moving data: the newest snapshot of the
            # family is REACHABLE over the account's own channel, and the
            # local landing exists or its parent is delegated. The engine's
            # silent rc=1 is a separate finding (frozen file; TODO).
            #
            # LAB6 pass 7 F-2: through the SHARED probe, so the depth follows
            # the recursion contract the installed line follows. This used to
            # inline a -d 1 lookup and refused a recursive root whose family
            # lives on descendants -- the chain-middle shape -- while the
            # passivity decision three lines above, using the shared probe,
            # had already said the family was there.
            local newest newest_rc
            # A prefixless section (declared passive, Phase 3.5) has no family
            # NAME to probe for -- the family is "whatever is newest". The old
            # automated_ fallback made the rehearsal blind to exactly the
            # relationships it was rehearsing (LAB-E audit, hostage H3).
            local _drp="${dr_prefix:-automated_}"
            case " $(installed_dataset_field "$workfile" "$localpath" flags) " in
                *" -e "*) [ -n "$dr_prefix" ] || _drp="" ;;
            esac
            newest=$(source_family_newest "$ds" "$_drp"); newest_rc=$?
            if [ "$newest_rc" -eq "$SOURCE_PROBE_UNKNOWN" ]; then
                # Distinct from "no snapshot reachable": that verdict is about
                # the SOURCE's contents, this one is about not having reached
                # it. Reported as a failure either way -- the install must not
                # proceed on an unasked question -- but named for what it is,
                # because the two need different fixes.
                warn "  UNKNOWN (passive): $ds -> $localpath -- could not ask ${LOAD_ACCOUNT}@${LOAD_HOST} what it carries (link or access, not content)"
                failed=$((failed + 1))
            elif [ -n "$newest" ]; then
                # The full name, not just the snapshot: under -R the family may
                # be on a descendant, and WHICH dataset carries it is the half
                # of the answer an operator cannot reconstruct from the other.
                log "  OK (passive): $ds -> $localpath -- newest family snapshot reachable: $newest"
            else
                warn "  FAILED (passive): $ds -> $localpath -- no '${_drp:-<any>}*' snapshot reachable on $LOAD_HOST via the pairing channel$(is_recursive_root "$ds" && echo " (searched the whole subtree, as the installed -R line would)")"
                failed=$((failed + 1))
            fi
            continue ;;
        esac
        local -a dr_args=(-n)
        [ -n "$dr_prefix" ] && dr_args+=(-m "$dr_prefix")
        # F3 (2026-08-21): this dry-run was the one snapget call that did not
        # mirror the recursive-root flag, so the ACTIVATION preview warned
        # "neither -r nor -R was given" about a relationship whose installed
        # line carries -R -- a proposal disagreeing with what it proposes.
        is_recursive_root "$ds" && dr_args+=(-R)
        # shellcheck disable=SC2086
        if [ -n "$base" ]; then
            set -- "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"
        else
            set -- "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
        fi
        # shellcheck disable=SC2086
        if bash "$SNAPGET" "${dr_args[@]}" $LOAD_FLAGS$LOAD_BW_FLAG "$@"; then
            log "  OK: $ds -> $localpath"
        else
            warn "  FAILED: $ds -> $localpath"
            failed=$((failed + 1))
        fi
    done
    if [ "$failed" -ne 0 ]; then
        rm -f "$workfile"
        die "$failed dataset(s) failed the dry-run -- not installing, $cronfile was NOT touched. Fix and re-run activate-client."
    fi

    log "zfs allow check on $LOAD_HOST (categorized -- see REV-20260730-004 F5):"
    for ds in $PEER_SAVED_DATASETS; do
        check_inherited_grants "$ds" "$LOAD_ACCOUNT" "$LOAD_HOST" "$LOAD_PORT" "$LOAD_KEYFILE" "$LOAD_ALIAS_KH" "$LOAD_ALIAS" "$verbose"
    done

    # REV-20260811-102 step 3: a REMOTE source prune was emitted for these datasets
    # this run; it must NOT be installed unless the delegated account already holds
    # `destroy` on each source (delegated by deploy.sh --commit-scope). Verify fail
    # closed -- we do NOT widen. Empty on a preserved re-activation, so no SSH then.
    if [ "${#SOURCE_PRUNE_EMITTED_DS[@]}" -gt 0 ]; then
        # REV-20260812-111 B: cheapest gate first -- this one is a file read, the
        # grant check below costs an ssh round trip per source.
        local -a atomic_paths=(); local ads
        for ads in ${PEER_SAVED_DATASETS:-}; do atomic_paths+=("$(client_local_path "$ads")"); done
        if [ "${#atomic_paths[@]}" -gt 0 ]; then
            ( assert_no_atomic_with_source_retention "$workfile" "${atomic_paths[@]}" ) \
                || { rm -f "$workfile"; die "atomic-recursion guard refused -- $cronfile was NOT touched, nothing installed."; }
        fi
        ( assert_source_prune_grant "$LOAD_ACCOUNT" "$LOAD_HOST" "$LOAD_PORT" \
              "$LOAD_KEYFILE" "$LOAD_ALIAS" "$LOAD_ALIAS_KH" "${SOURCE_PRUNE_EMITTED_DS[@]}" ) \
            || { rm -f "$workfile"; die "source-prune grant check failed -- $cronfile was NOT touched, nothing installed."; }
    fi

    echo
    echo "Klient:              $name"
    echo "Peer (LAN parowania): $PEER_HOST"
    echo "Endpoint aktywny:    $(endpoint_display)"
    echo "Zrodla:              $PEER_SAVED_DATASETS"
    if [ -n "$base" ]; then
        echo "Cel:                 $base"
    else
        echo "Cel:                 (sync -- ta sama sciezka co zrodlo, dla kazdego datasetu osobno)"
    fi
    echo "Tryb:                pull"
    if [ "${PROFILE_GFS:-1}" -eq 1 ]; then
        echo "Profil:              standard GFS -- jedna wysylka co godzine (:01), jedna"
        echo "                     kaskadowa drabina retencji (:21): -H24 -D7 -W4 -M12"
    else
        echo "Profil:              legacy (plaska retencja per tier -- ten host ma config"
        echo "                     sprzed podzialu profilu)"
    fi
    # F7: name the passive shape out loud BEFORE consent -- a silent non-passive
    # choice on a chained middle dataset is exactly what the lab watched destroy
    # both links' common bases in 80 minutes.
    if grep -qE '^\s*flags\s*=.*\s-e(\s|$)' "$workfile" 2>/dev/null; then
        echo "Tryb pasywny:        TAK dla czesci/calosci zakresu -- ta relacja KONSUMUJE"
        echo "                     istniejaca rodzine snapshotow zrodla (snapget -e):"
        echo "                     zadnych nowych snapshotow na zrodle, zadnego prune"
        echo "                     zrodla; retencja rodziny zostaje u jej wlasciciela."
    fi
    echo "Spojnosc snapshotu:  crash-consistent -- quiesce NIE jest wlaczony w tym profilu."
    echo "                     (zdalny quiesce w trybie pull istnieje: snapget -q przez"
    echo "                      zfs-quiesce-helper, wymaga --allow-quiesce przy parowaniu)"
    echo "Test:                OK ($( printf '%s' "$PEER_SAVED_DATASETS" | wc -w ) dataset(s))"
    # Snapshot NAMES embed local wall-clock time; ZFS `creation` is the truth,
    # but every human and every filename sorts by the name. Found live
    # 2026-08-17 (lab3): a fresh cloud VM defaulted to UTC while the rest of
    # the estate runs CEST, and the chain's snapshots disagreed by two hours
    # with their own names' timestamps -- exactly the name-vs-creation trap
    # restore --plan flags. Warn-only: clocks are host policy, not this
    # tool's, and the transfer itself is unaffected.
    local peer_tz local_tz
    local_tz=$(date +%z)
    peer_tz=$(load_ssh_opts; ssh -n "${LOAD_SSH_OPTS[@]}" \
        "${LOAD_ACCOUNT}@${LOAD_HOST}" "date +%z" 2>/dev/null)
    if [ -n "$peer_tz" ] && [ "$peer_tz" != "$local_tz" ]; then
        warn "strefy czasowe sie roznia: ten host $local_tz, zrodlo $PEER_HOST $peer_tz -- nazwy snapshotow beda nosic INNY czas niz reszta floty (restore --plan bedzie to flagowac jako rozjazd nazwa<->creation). Wyrownaj timedatectl set-timezone na obu, jesli to nie jest zamierzone."
    fi
    echo

    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "gen-cron.sh could not render the proposed config -- nothing was touched"
    }

    if [ "$yes" -ne 1 ]; then
        read -rp "Aktywowac backup? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) rm -f "$workfile"; die "not confirmed -- $cronfile was NOT touched, nothing installed" ;;
        esac
    fi

    assert_cron_config_matches_installed "$cronfile"
    assert_no_foreign_managed_block "$workfile"
    assert_target_block_not_clobbered "$workfile"
    assert_config_readable_by_target "$cronfile"
    atomic_replace_and_install "$cronfile" "$workfile"

    {
        cat "$cpath"
        write_client_field STATE            active
        write_client_field ACTIVATED_AT     "$(date '+%Y-%m-%d %H:%M:%S')"
        write_client_field MANAGED_DATASETS "${managed[*]}"
        # Recorded rather than derived: remove-client only knows the dataset
        # paths, and reconstructing their common parent by string surgery would
        # be a guess. Empty on a pre-GFS host, which is exactly the signal
        # remove-client needs to skip it.
        write_client_field MANAGED_PRUNE_SCOPE "${prune_scope:-}"
        write_client_field CRON_CONFIG      "$cronfile"
        # REV-20260730-005 F4: what the cron line ACTUALLY connects through,
        # as opposed to ACTIVE_ENDPOINT which is what we want it to use. They
        # are equal right now, by construction -- the job was just generated
        # from this endpoint -- but set-endpoint can move the desired one
        # without touching the installed job, and `status` has to be able to
        # tell the operator which is which.
        write_client_field INSTALLED_ENDPOINT "$ACTIVE_ENDPOINT"
        # The account the jobs run as, recorded with the relationship so
        # remove-client (and any re-activation) reads it back rather than
        # re-deriving it from a host-wide file. Empty means root.
        write_client_field LOCAL_USER       "${LOCAL_USER:-}"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    chmod 0600 "$cpath"

    log "client '$name' active (cron runs over endpoint '$(endpoint_display)')."
}

# ------------------------------------------------------------------------------
# Run one existing low-level command in a child process. Keeping the child
# boundary is deliberate: the low-level commands use die()/exit for failures;
# the high-level orchestrator must catch that exit and finish with ONE stable
# resume instruction instead of disappearing halfway through the sequence.
activation_step() {   # <resume-command> <low-level command...>
    local resume="$1"; shift
    if ! bash "$SCRIPT_DIR/zfs-backup.sh" "$@"; then
        die "activation stopped during '$1'. Fix the reported cause, then run exactly: $resume"
    fi
}

# The normal completion path for a seeded two-host relationship. It composes
# the already-tested state-machine verbs; no transfer, grant or cron semantics
# are reimplemented here. Safe retries are obtained from durable state after
# every step: a fresh final catch-up is reused, an already-selected endpoint is
# not switched again, a verified endpoint is not probed twice, and an active
# relationship with the requested endpoint is a no-op success.
cmd_activate() {
    local name="${1:-}"; shift || true
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    local requested_host="" yes=0 verbose=0 a
    for a in "$@"; do
        case "$a" in
            --host=*) requested_host="${a#*=}" ;;
            --yes|-y) yes=1 ;;
            --verbose) verbose=1 ;;
            *) die "activate: unknown option $a" ;;
        esac
    done

    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name' -- run add-client first"

    local resume="./zfs-backup.sh activate $name"
    [ -n "$requested_host" ] && resume="$resume --host=$requested_host"
    [ "$yes" -eq 1 ] && resume="$resume --yes"
    [ "$verbose" -eq 1 ] && resume="$resume --verbose"

    local STATE="" ACTIVE_ENDPOINT="" INSTALLED_ENDPOINT="" ENDPOINT_VERIFIED_FOR=""
    local FINAL_CATCHUP_ENDPOINT="" FINAL_CATCHUP_EPOCH="" PEER_HOST=""
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        pending_enroll|seeding)
            die "client '$name' is not seeded yet. Run: ./zfs-backup.sh seed $name" ;;
        seed_complete|endpoint_verified|endpoint_change_pending|active) ;;
        *) die "client '$name' has unknown state '${STATE:-}' -- refusing to guess" ;;
    esac

    local current_host current_port current_endpoint
    read -r current_host current_port <<< "$(active_endpoint_host_port)"
    current_endpoint="$current_host:$current_port"

    local requested_endpoint="$current_endpoint" requested_port
    if [ -n "$requested_host" ]; then
        local parsed_endpoint
        parsed_endpoint=$(parse_endpoint_arg "$requested_host") || return 1
        read -r requested_host requested_port <<< "$parsed_endpoint"
        requested_endpoint="$requested_host:$requested_port"
    fi

    # Fully completed retry: no transfer, probe or cron rewrite.
    if [ "${STATE:-}" = active ] \
            && [ "$requested_endpoint" = "$current_endpoint" ] \
            && [ "${INSTALLED_ENDPOINT:-}" = "${ACTIVE_ENDPOINT:-}" ]; then
        log "client '$name' is already active on '$current_endpoint' -- nothing to do."
        return 0
    fi

    if [ "$requested_endpoint" != "$current_endpoint" ]; then
        local catchup_fresh=0 now age
        case "${FINAL_CATCHUP_EPOCH:-}" in
            ''|*[!0-9]*) ;;
            *)
                now=$(date '+%s')
                age=$(( now - FINAL_CATCHUP_EPOCH ))
                [ "${FINAL_CATCHUP_ENDPOINT:-}" = "$current_endpoint" ] \
                    && [ "$age" -ge 0 ] && [ "$age" -le "$CATCHUP_MAX_AGE" ] \
                    && catchup_fresh=1
                ;;
        esac
        if [ "$catchup_fresh" -eq 1 ]; then
            log "reusing the fresh final catch-up already recorded for '$current_endpoint'"
        else
            local -a catchup=(final-catchup "$name")
            [ "$yes" -eq 1 ] && catchup+=(--yes)
            activation_step "$resume" "${catchup[@]}"
        fi
        activation_step "$resume" set-endpoint "$name" --host="$requested_endpoint"
    fi

    # Reload after any catch-up/switch; the file is the state machine's source
    # of truth and makes an interrupted run resume at the next unfinished step.
    STATE="" ACTIVE_ENDPOINT="" INSTALLED_ENDPOINT="" ENDPOINT_VERIFIED_FOR=""
    # shellcheck disable=SC1090
    . "$cpath"
    read -r current_host current_port <<< "$(active_endpoint_host_port)"
    current_endpoint="$current_host:$current_port"

    if [ "${STATE:-}" != endpoint_verified ] \
            || [ "${ENDPOINT_VERIFIED_FOR:-}" != "$current_endpoint" ]; then
        case "${STATE:-}" in
            seed_complete|endpoint_change_pending|endpoint_verified)
                activation_step "$resume" verify-endpoint "$name" ;;
            active)
                die "client '$name' is active, but its installed/current endpoint record is inconsistent. Re-run exactly: $resume" ;;
            *) die "activate cannot verify client '$name' from state '${STATE:-unknown}'. Re-run exactly: $resume" ;;
        esac
    else
        log "endpoint '$current_endpoint' was already verified -- continuing"
    fi

    STATE="" ACTIVE_ENDPOINT="" INSTALLED_ENDPOINT=""
    # shellcheck disable=SC1090
    . "$cpath"
    if [ "${STATE:-}" != active ]; then
        local -a install=(activate-client "$name")
        [ "$yes" -eq 1 ] && install+=(--yes)
        [ "$verbose" -eq 1 ] && install+=(--verbose)
        activation_step "$resume" "${install[@]}"
    fi

    STATE="" ACTIVE_ENDPOINT="" INSTALLED_ENDPOINT=""
    # shellcheck disable=SC1090
    . "$cpath"
    [ "${STATE:-}" = active ] && [ "${INSTALLED_ENDPOINT:-}" = "${ACTIVE_ENDPOINT:-}" ] \
        || die "activation returned without a matching active/install record. Re-run exactly: $resume"
    log "client '$name' is active; endpoint and installed cron both use '${ACTIVE_ENDPOINT}'."
}

# ------------------------------------------------------------------------------
# migrate-profile: put a host onto a profile, in one decision.
#
# REV-20260801-016 F3. Leaving a legacy host alone is safe, but telling its
# administrator that migration is "a deliberate edit" pushes the internal
# standard_*/keep_* split onto exactly the person this workflow exists to spare.
# The tool generates the new configuration itself, validates it, shows the exact
# config and cron diff, and asks once.
#
# It rebuilds every ACTIVE client through emit_client_sections(), the same
# function activate-client uses, so a migrated host lands on byte-identical
# sections rather than on a second implementation of the same shape.
# ------------------------------------------------------------------------------
# set-bandwidth: change a PAIR's link cap as ONE transaction over every
# relationship that flies across that link.
#
# REV F4b, and the owner chose this shape over "make the runtime read the
# manifest": it is how the rest of this tool already works, and it keeps CONFIG
# as the runtime truth.
#
# The problem it closes: the cap belongs to the PAIR and lives in the pairing
# manifest, but an ACTIVE relationship carries it MATERIALISED in its
# [dataset:] section and in the installed cron line. `deploy.sh --pair
# --bandwidth=NEW` rewrites the manifest and nothing else, so the manifest said
# one thing while every running job used another -- until somebody re-activated
# each relationship by hand, one at a time, remembering to. Two sources of
# truth, drifting, with no moment at which anyone was told.
#
# One preview, one confirmation, one crontab. If a pair carries six
# relationships, six sections move together or none does.
#
# ORDER: the CONFIG swap happens first and the manifest second. The swap is the
# guarded, previewed, rollback-capable half (atomic_replace_and_install backs up
# both the file and the crontab); the manifest is a single line. If the swap
# fails, the manifest still describes what is actually running. If the manifest
# write fails afterwards, the jobs are already correct and the operator is told
# exactly which one line to fix -- the smaller of the two gaps, chosen
# deliberately rather than by accident.
cmd_set_bandwidth() {   # --peer=HOST --bandwidth=RATE [--config=PATH] [--local-user=NAME] [--yes]
    local yes=0 a peer="" rate="" rate_given=0 config_arg="" local_user_arg=""
    for a in "$@"; do
        case "$a" in
            --yes|-y)       yes=1 ;;
            --peer=*)       peer="${a#*=}" ;;
            --bandwidth=*)  rate="${a#*=}"; rate_given=1 ;;
            --config=*)     config_arg="${a#*=}" ;;
            --local-user=*) local_user_arg="${a#*=}"
                local_user_name_valid "$local_user_arg" \
                    || die "set-bandwidth: --local-user='$local_user_arg' is not a valid account name ($LOCAL_USER_GRAMMAR)" ;;
            *) die "set-bandwidth: unknown option $a" ;;
        esac
    done
    [ -n "$peer" ] || die "set-bandwidth: --peer=HOST is required -- the cap belongs to a PAIR, so the peer is the thing being capped, not a relationship"
    # An EMPTY rate is a real request (remove the cap) and must be distinguished
    # from an omitted flag, same discriminator as deploy.sh's own
    # PEER_BANDWIDTH_GIVEN and for the same reason.
    [ "$rate_given" -eq 1 ] || die "set-bandwidth: --bandwidth=RATE is required (use --bandwidth= with no value to REMOVE the cap)"
    [ -z "$rate" ] || assert_bandwidth_rate "$rate" set-bandwidth

    read_server_conf
    cron_context_resolve aim "$config_arg" "$local_user_arg" "" ""
    local cronfile="$CRON_CTX_FILE"
    [ -f "$cronfile" ] || die "no cron config at $cronfile -- nothing to re-cap"

    local label; label=$(peer_label "$peer")
    local mpath;  mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$peer' at $mpath -- the cap belongs to a pairing, so pair the host first (deploy.sh --pair)"
    local old_rate; old_rate="$(grep -m1 '^PEER_SAVED_BANDWIDTH=' "$mpath" | cut -d= -f2-)"

    # Which relationships fly across this link. Fields are cleared before each
    # record because a record is a `.`-sourced file and this loop reads several
    # in one shell -- the same defect the tree fixed for BANDWIDTH itself.
    # TWO PARALLEL ARRAYS, no packed string. The first cut joined name and
    # dataset list with ${SEP} -- which gen-cron defines and this file does not,
    # so under `set -u` it would have died on an unbound variable the moment a
    # pair had a relationship. Caught before it shipped, but the lesson is the
    # cheaper one: do not invent a separator when two arrays say it plainly.
    local f seen="" _n=0
    local -a tgt_name=() tgt_ds=()
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        case "$f" in *removed*) continue ;; esac
        for _n in $seen; do unset "$_n"; done
        seen="$seen $(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{print $1}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
        # shellcheck disable=SC1090
        . "$f"
        [ "${STATE:-}" = active ] || continue
        [ "$(peer_label "${PEER_HOST:-}")" = "$label" ] || continue
        tgt_name+=("${CLIENT_NAME:-$(basename "$f" .conf)}")
        tgt_ds+=("${MANAGED_DATASETS:-}")
    done

    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX") \
        || die "mktemp failed next to $cronfile"
    chmod 0644 "$workfile" || { rm -f "$workfile"; die "could not set the mode on $workfile"; }
    cp -p "$cronfile" "$workfile" || { rm -f "$workfile"; die "could not copy $cronfile"; }
    chmod 0644 "$workfile" 2>/dev/null || :

    local _i cname dslist ds moved=0
    for _i in ${tgt_name[@]+"${!tgt_name[@]}"}; do
        cname="${tgt_name[$_i]}"; dslist="${tgt_ds[$_i]}"
        for ds in $dslist; do
            # set_or_remove, not update: a relationship with no cap carries no
            # `bandwidth` line at all, and removing a cap must take the line
            # with it rather than leave a stale one throttling the link.
            set_or_remove_section_field "$workfile" "[dataset:$ds]" bandwidth "$rate" \
                || { rm -f "$workfile"; die "set-bandwidth: [dataset:$ds] is not in $cronfile -- relationship '$cname' records a dataset its config does not describe. Refusing to re-cap a config that does not match its records. Nothing was changed."; }
            moved=$((moved + 1))
        done
    done

    # gencron_as_target, NOT a bare gen-cron. The rule exists because a render by
    # the wrong copy, as the wrong account, previews a block that will never be
    # installed -- gen-cron bakes the running copy's paths and the target
    # account's environment into every line. activate-client validates its
    # candidate this way; so does this. Asking for an allow-list exemption would
    # have been the easier fix and the wrong one.
    log "validating the re-capped config (working copy only, nothing real touched yet)..."
    if ! gencron_as_target -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the re-capped config -- $cronfile was NOT touched (see output above)"
    fi
    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "could not render the preview -- nothing was touched"
    }

    echo "Limit lacza pary '$peer': '${old_rate:-<brak>}'  ->  '${rate:-<brak>}'"
    echo "Relacji do przepisania: ${#tgt_name[@]} (sekcji: $moved)"
    echo
    if [ "$yes" -ne 1 ]; then
        read -rp "Zastosowac ten limit do WSZYSTKICH relacji tej pary? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) rm -f "$workfile"; die "not confirmed -- $cronfile was NOT touched, the manifest was NOT changed, nothing installed" ;;
        esac
    fi

    # PREPARE the manifest before touching anything, so the only step left after
    # the swap is a rename on the same filesystem. Writing it afterwards meant a
    # failure there left the jobs re-capped and the manifest stale -- the same
    # two-sources-of-truth split this command exists to end, just moved later in
    # the sequence.
    #
    # And APPEND when the key is absent. The first version only rewrote a line
    # that was already there: a manifest predating the field (or written by an
    # older deploy.sh) silently kept no cap at all while the CONFIG got one, and
    # `mv` reported success. My own test could not see it, because its fixture
    # always started with PEER_SAVED_BANDWIDTH=2M.
    local mtmp; mtmp=$(mktemp "$(dirname "$mpath")/.manifest.XXXXXX") \
        || die "cannot write next to the pairing manifest $mpath -- nothing was changed"
    if ! { awk -v v="$rate" '
               /^PEER_SAVED_BANDWIDTH=/ { print "PEER_SAVED_BANDWIDTH=" v; seen=1; next }
               { print }
               END { if (!seen) print "PEER_SAVED_BANDWIDTH=" v }
           ' "$mpath" > "$mtmp"; }; then
        rm -f "$mtmp"
        die "could not prepare the updated pairing manifest -- nothing was changed"
    fi
    # Our own rollback copy. atomic_replace_and_install keeps one only for its
    # OWN failure paths and removes it on success, so a failure AFTER it returns
    # has nothing to fall back on unless we kept a copy ourselves.
    local rollback; rollback=$(mktemp "$(dirname "$cronfile")/.zfsbackup-rollback.XXXXXX") \
        || { rm -f "$mtmp"; die "mktemp failed for the rollback copy -- nothing was changed"; }
    cp -p "$cronfile" "$rollback" || { rm -f "$mtmp" "$rollback"; die "could not take a rollback copy of $cronfile -- nothing was changed"; }

    assert_cron_config_matches_installed "$cronfile"
    assert_no_foreign_managed_block "$workfile"
    assert_target_block_not_clobbered "$workfile"
    assert_config_readable_by_target "$cronfile"
    atomic_replace_and_install "$cronfile" "$workfile"

    # ALL TOGETHER OR NOTHING, which is what this command claims to be. A warn
    # and a zero exit left the jobs on the new cap and the manifest on the old --
    # exactly the divergence being fixed, and the next relationship written
    # against this peer would have restored the old value from the manifest.
    #
    # The remaining step is a rename within one directory. If even that fails,
    # put the CONFIG back and say so with a non-zero status, so config, crontab
    # and manifest are left agreeing with each other.
    if ! mv -f "$mtmp" "$mpath"; then
        rm -f "$mtmp"
        local restored="restored"
        cp -p "$rollback" "$cronfile" 2>/dev/null || restored="NOT restored"
        gencron_as_target -c "$cronfile" --install >/dev/null 2>&1 || restored="config restored, CRONTAB NOT reinstalled"
        rm -f "$rollback"
        die "the pairing manifest $mpath could not be published, so the cap change was rolled back ($restored). Config, crontab and manifest are left on the OLD value '${old_rate:-<none>}'. Fix whatever prevents writing next to the manifest and re-run."
    fi
    chmod 0600 "$mpath" 2>/dev/null || :
    rm -f "$rollback"

    log "link cap for '$peer' is now '${rate:-<none>}' -- ${#tgt_name[@]} relationship(s) rewritten and installed in one transaction."
}

#
# THE DESTINATION WAS HARDCODED until 2026-08-25: legacy flat-per-tier -> the
# standard GFS ladder, because that was the only migration in existence. With
# `default`, `passive` and `prod` as real profiles, "put this host on profile
# X" became an ordinary operation with no command behind it -- an operator's
# only route was editing the config by hand, which is exactly what this
# function was written to spare them. --profile=NAME is that command; omitting
# it still means `default`, so the original migration is unchanged.
#
# Generalising it needed three things the hardcoded version could skip:
#
#   1. PROFILE_GFS is DERIVED from the destination's shape, not asserted. It
#      decides whether a GFS ladder is emitted at all.
#   2. The client's [prune:] sections are swept by MARKER before regeneration.
#      A ladder sits at the PARENT of the datasets, so the path-driven
#      remove_managed_sections cannot reach it -- and the whole ladder-emitting
#      branch is inside `if PROFILE_GFS`, so migrating to a FLAT profile would
#      never have run the removal either. GFS -> flat would have left the old
#      ladder next to the new per-tier prune: two pruners, same snapshots.
#   3. Orphaned templates are found by reference-counting, not by name.
# Sourcing several client records in ONE shell is how this command works, and a
# record is a `.`-sourced file: a field a record does NOT carry keeps whatever
# the previous record left behind.
#
# REV F3. Record A carries PROFILE=prod, record B is older and has no PROFILE
# field at all -- after `. A` then `. B`, B still reads prod. In the precheck
# that is a false "already on profile"; in the post-install loop it is a record
# that silently never gets its PROFILE written. Exactly the class of defect this
# tree just fixed for BANDWIDTH, whose comment in load_client_and_connection
# names migrate-profile as one of the callers that needs the reset -- and these
# loops were written without it.
#
# The `( : )` line beside each source is a shellcheck no-op. It isolates
# NOTHING; anyone reading it as a subshell (I did) will make this mistake again.
MIGRATE_RECORD_FIELDS=""
migrate_read_record() {   # <path> -- source it with no field left over from the last one
    # NOT A HAND-PICKED LIST, and the first version of this was one. It reset
    # STATE/PROFILE/CLIENT_NAME/PROFILE_DIGEST_RECORDED -- the fields I could
    # see -- and the lab found what that misses within the hour: EXCLUDE_1 from
    # an old, REMOVED record leaked into an active one, and the proposed cron
    # line grew a `-X skip` the relationship had never asked for. The record
    # dir on a real collector holds twenty files; a numbered field
    # (EXCLUDE_<n>) cannot be enumerated ahead of time at all, which is exactly
    # the shape a hand-written list is guaranteed to miss.
    #
    # So: remember every name any record has assigned, clear them all before
    # the next source, and let the record itself decide what it defines. A
    # record that carries a field gets its value; one that does not carries
    # nothing -- which is what a fresh shell would have given it.
    #
    # The `. "$1"` is still subshell-free on purpose: the caller needs the
    # values. That is why the clearing has to be explicit.
    local f
    for f in $MIGRATE_RECORD_FIELDS; do unset "$f"; done
    MIGRATE_RECORD_FIELDS="$MIGRATE_RECORD_FIELDS $(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{print $1}' "$1" 2>/dev/null | sort -u | tr '\n' ' ')"
    # shellcheck disable=SC1090
    . "$1"
}

cmd_migrate_profile() {   # [--profile=NAME] [--config=PATH] [--local-user=NAME] [--yes]
    local yes=0 a config_arg="" local_user_arg="" target_profile=""
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            # The destination used to be hardcoded: legacy flat-per-tier ->
            # the standard GFS ladder, and nothing else. That was the only
            # migration that existed when it was written. With `default`,
            # `passive` and `prod` as real profiles, "move this host onto
            # profile X" is an ordinary operation and had no command at all --
            # an operator's only route was editing the config by hand.
            --profile=*)    target_profile="${a#*=}" ;;
            --config=*)     config_arg="${a#*=}" ;;
            --local-user=*) local_user_arg="${a#*=}"
                local_user_name_valid "$local_user_arg" \
                    || die "migrate-profile: --local-user='$local_user_arg' is not a valid account name ($LOCAL_USER_GRAMMAR)"
                # NOT blanked to "" here. The resolver has to tell an explicit
                # "root" from "nothing said", and blanking made them identical
                # -- so --local-user=root, the remedy the refusal itself
                # prints, landed straight back in the refusal. Found live on
                # pve2 and pve1, 2026-08-21.
                ;;
            *) die "migrate-profile: unknown option $a" ;;
        esac
    done

    read_server_conf
    # P10: this used to have no way to be aimed. It resolved server.conf, then
    # the host default -- a name, on a host where a config belongs to a
    # relationship -- and rewrote whatever it landed on. The two flags above are
    # what make the refusal below an answerable question rather than a wall.
    cron_context_resolve aim "$config_arg" "$local_user_arg" "" ""
    local cronfile="$CRON_CTX_FILE"
    [ -f "$cronfile" ] || die "no cron config at $cronfile -- nothing to migrate (run setup-server first)"

    # Same zero-choice default and the same validation as add-client: an
    # operator who never heard of profiles gets exactly the behaviour this
    # command had before the flag existed, and a typo fails HERE rather than
    # halfway through rewriting a config.
    [ -n "$target_profile" ] || target_profile="$PROFILE_DEFAULT_NAME"
    profile_validate_file "$(profile_file "$target_profile")" "$GENCRON" \
        || die "migrate-profile: --profile='$target_profile': $PROFILE_ERR"
    # Point the loader at the DESTINATION before anything reads the profile.
    # emit_client_sections loads lazily and caches on PROFILE_LOADED, so the
    # first thing to render must already see the target -- otherwise the whole
    # migration would quietly run on whatever profile happened to be active.
    if [ "$PROFILE_ACTIVE" != "$target_profile" ]; then
        profile_release_tmp
        PROFILE_LOADED=""
        PROFILE_ACTIVE="$target_profile"
    fi
    load_active_profile

    # ALREADY THERE? Ask the client RECORDS, not the config's shape.
    #
    # The old test was a grep for a flat [template:standard_hourly] -- a fine
    # question when there was exactly one destination, and meaningless now:
    # `prod` IS flat per tier, so that grep would call an already-migrated prod
    # host "not migrated yet" and re-run forever. Each record carries the
    # profile it was created from (write_client_field PROFILE), which is the
    # fact this question is actually about. Records predating the field hold
    # "", which correctly reads as "not on the target".
    # A NAME IS NOT A VERSION (REV F2). Matching PROFILE alone made an edited
    # profile unappliable: change `keep = 7` to `keep = 10` in the one file the
    # operator is told to edit, re-run this command, and it answered "nothing to
    # migrate" while the installed cron still carried -D7. The digest is what
    # makes "already on profile X" a statement about the policy rather than
    # about a string.
    #
    # A record predating the field holds "" and therefore never matches, so an
    # old relationship migrates once and gains its digest -- no special case.
    local _f _on_target=1 _actives=0 _want_digest
    _want_digest="$(profile_digest)" || _want_digest=""
    for _f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$_f" ] || continue
        migrate_read_record "$_f"
        [ "${STATE:-}" = active ] || continue
        _actives=$((_actives + 1))
        [ "${PROFILE:-}" = "$target_profile" ] || _on_target=0
        [ -n "$_want_digest" ] && [ "${PROFILE_DIGEST_RECORDED:-}" != "$_want_digest" ] && _on_target=0
    done
    # A legacy config can hold records that already SAY `default` while the
    # sections are still flat per tier -- that is the original migration this
    # command was written for, and it must still be detected.
    local _legacy=0
    sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$cronfile" | grep -q "prune_schedule" && _legacy=1
    if [ "$_on_target" -eq 1 ] && [ "$_actives" -gt 0 ] && [ "$_legacy" -eq 0 ]; then
        log "$cronfile is already on profile '$target_profile' ($_actives active client(s), profile unchanged since they were generated) -- nothing to migrate."
        return 0
    fi

    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX")         || die "mktemp failed next to $cronfile"
    workfile_track "$workfile"
    # mktemp makes 0600. The preview and the install both read this file AS the
    # collector account, so it has to be readable by it -- and the mode has to
    # be right BEFORE either of them runs, not after the swap.
    chmod 0644 "$workfile" || { rm -f "$workfile"; die "could not set the mode on $workfile"; }
    cp -p "$cronfile" "$workfile" || { rm -f "$workfile"; die "could not copy $cronfile"; }
    chmod 0644 "$workfile" 2>/dev/null || :

    # The LEGACY flat family goes before ensure_cron_config, and this is not
    # housekeeping -- it is what lets the call succeed at all. ensure_cron_config
    # refuses to add current policy on top of a pre-GFS config (the two would
    # prune the same snapshots on the same schedule), and that refusal reads the
    # very templates being replaced here. A no-op on any host that is not legacy.
    local t
    for t in standard_hourly standard_daily standard_weekly standard_monthly; do
        remove_template_section "$workfile" "$t"
    done
    # AND THE DESTINATION'S OWN TEMPLATES, which is what makes an EDITED profile
    # appliable rather than merely detectable (REV F2).
    #
    # ensure_cron_config's template block is additive by design: "what suppresses
    # an append is THAT name already being present". Right for an endpoint
    # refresh, and wrong here -- migrating from `prod` to `prod` after the
    # operator changed keep = 7 to keep = 10 found profile__prod__daily already
    # in the file, appended nothing, and left `retain = -D7` installed. The
    # ONE identity for the templates, derived the way the RENDERER derives it.
    #
    # REV-20260827-122 F1: this loop interpolated $target_profile raw. Given a
    # profile by path -- `--profile=/tmp/mine.conf`, which the same function
    # accepts a few lines above -- it searched for
    #     [template:profile__/tmp/mine.conf__...]
    # while profile_render_templates had written
    #     [template:profile__mine__...]
    # so nothing matched and no old template was removed. ensure_cron_config is
    # ADDITIVE, so the already-present old templates then suppressed the append
    # of the edited policy, the candidate installed cleanly carrying the OLD
    # retention, and the record was stamped with the NEW digest afterwards. The
    # next run reads that digest and takes the "nothing to migrate" path. Silent
    # divergence between what the records claim and what the crontab enforces,
    # in RETENTION, which is the one number a backup is judged by.
    #
    # profile_name_of is the same helper the renderer uses, and its own comment
    # says the name "has to survive being given as a path and must never carry a
    # '/'" -- the rule existed; this site did not apply it.
    local _tpl_ns; _tpl_ns="$(profile_name_of "$target_profile")"

    # digest made the run HAPPEN; this makes it MEAN something. Measured: the
    # assertion failed with before='-D7' after='-D7' until this loop existed.
    #
    # Safe because migrate-profile is the one verb where the profile is meant to
    # win: the sections referencing these names are regenerated a few lines
    # below, and the whole candidate is validated by the real gen-cron before
    # anything is published.
    while IFS= read -r t; do
        # Trimmed in bash rather than through sed: the header is bracketed on
        # both sides, and every layer of quoting between here and a sed script
        # is another place for a backslash to go missing.
        t="${t#\[template:}"; t="${t%\]}"
        [ -n "$t" ] || continue
        remove_template_section "$workfile" "$t"
    done < <(grep -oE "^\[template:profile__${_tpl_ns}__[^]]+\]" "$workfile" 2>/dev/null)
    # Everything ELSE orphaned is swept after the clients are rewritten, when it
    # is finally known what still references what -- see
    # remove_orphan_profile_templates.

    # REV-20260810-092: 'always'. This is the explicit-migration boundary the
    # review carves out -- a previewed, confirmed transaction that shows the
    # exact config and cron diff first, and the one command that installs the
    # broad GFS ladder the reserved-prefix floors exist to fence.
    ensure_cron_config "$workfile" 0 1 always

    # PROFILE_GFS DESCRIBES THE INSTALLED CONFIG, NOT A PROFILE. detect_profile_gfs
    # reads the FILE (see its call in ensure_cron_config, and the note above
    # client_section_plan), which during a migration is still the shape being
    # migrated AWAY from. The hardcoded version got away with asserting
    # PROFILE_GFS=1 because its destination was always the ladder; asserting the
    # source's shape for an arbitrary destination is how `--profile=prod` came
    # out carrying an empty GFS [prune:] section -- the ladder branch ran, and a
    # flat profile has no [prune] fragment to fill it with. Measured, not
    # reasoned: gen-cron rejected the candidate with "[prune:...] has no
    # use_template", which is the same emptiness the source-prune emitters
    # already gate on.
    #
    # So ask the DESTINATION, with the same detector, pointed at the profile's
    # own rendered templates: a tier carrying both send_schedule and
    # prune_schedule is flat, anything else is a ladder. One rule, one
    # implementation, two inputs.
    detect_profile_gfs "$PROFILE_TPL_FILE"

    local f name migrated=0
    local -a managed=(); local prune_scope=""
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        migrate_read_record "$f"
        [ "${STATE:-}" = active ] || { log "skipping client '${CLIENT_NAME:-$f}' (state=${STATE:-unknown}) -- only active clients have cron sections to rewrite"; continue; }
        name="$CLIENT_NAME"
        load_client_and_connection "$f"
        # REV-20260809-089: full generation, deliberately. Every other caller
        # must NOT re-derive installed policy from the active profile -- but
        # re-deriving it is the entire purpose of migrate-profile, which exists
        # precisely to move a host off the legacy profile in one decision. This
        # is the one call site where the profile is meant to win.
        # The client's own [prune:] sections go first, all of them. With
        # is_new=1 every dataset regenerates, so emit_client_sections re-emits
        # exactly what the NEW profile calls for -- and only a marker-driven
        # sweep can reach a GFS ladder parked at the parent path when the
        # destination profile has no ladder at all.
        remove_client_prune_sections "$workfile" "$name"
        emit_client_sections "$workfile" "$name" 1 || { rm -f "$workfile"; die "could not rewrite sections for '$name'"; }
        # REV-20260811-102 step 3: same fail-closed source-prune grant gate as
        # activate-client, per client -- never migrate a config that installs a
        # remote source prune the delegated account cannot actually run.
        if [ "${#SOURCE_PRUNE_EMITTED_DS[@]}" -gt 0 ]; then
            # REV-20260812-111 B, same gate as activate-client, per client.
            local -a atomic_paths=(); local ads
            for ads in ${PEER_SAVED_DATASETS:-}; do atomic_paths+=("$(client_local_path "$ads")"); done
            if [ "${#atomic_paths[@]}" -gt 0 ]; then
                ( assert_no_atomic_with_source_retention "$workfile" "${atomic_paths[@]}" ) \
                    || { rm -f "$workfile"; die "atomic-recursion guard refused for '$name' -- nothing migrated or installed."; }
            fi
            ( assert_source_prune_grant "$LOAD_ACCOUNT" "$LOAD_HOST" "$LOAD_PORT" \
                  "$LOAD_KEYFILE" "$LOAD_ALIAS" "$LOAD_ALIAS_KH" "${SOURCE_PRUNE_EMITTED_DS[@]}" ) \
                || { rm -f "$workfile"; die "source-prune grant check failed for '$name' -- nothing migrated or installed."; }
        fi
        migrated=$((migrated + 1))
    done
    [ "$migrated" -gt 0 ] || log "no active clients -- migrating the templates only"

    # Now, and not before: what a template is worth is decided by what still
    # references it, and that is only settled once every client has been
    # rewritten onto the destination profile.
    remove_orphan_profile_templates "$workfile"

    log "validating the migrated config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the migrated config -- $cronfile was NOT touched (see output above)"
    fi

    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "could not render the migration preview -- nothing was touched"
    }

    local _shape="drabina GFS"
    [ "${PROFILE_GFS:-1}" -eq 1 ] || _shape="plaska retencja per tier"
    echo "Migracja profilu:  ->  '$target_profile'  ($_shape)"
    echo "Klientow do przepisania: $migrated"
    echo
    if [ "$yes" -ne 1 ]; then
        read -rp "Zmigrowac ten host na profil '$target_profile'? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) rm -f "$workfile"; die "not confirmed -- $cronfile was NOT touched, nothing installed" ;;
        esac
    fi

    assert_cron_config_matches_installed "$cronfile"
    assert_no_foreign_managed_block "$workfile"
    assert_target_block_not_clobbered "$workfile"
    assert_config_readable_by_target "$cronfile"
    atomic_replace_and_install "$cronfile" "$workfile"

    # THE RECORDS FOLLOW THE CONFIG, and only once the config is really
    # installed. PROFILE is create-time provenance that seed_profile_context
    # still reads: leaving it saying `default` on a host now running `prod`
    # would make the next seed ask about the wrong family root -- a silent lie
    # of exactly the kind a migration is supposed to end. It is also what makes
    # a second run of this command a no-op instead of an endless "not migrated
    # yet".
    #
    # After the swap, not before: a failed swap must never leave records ahead
    # of the file they describe. A failure HERE is the one direction that
    # cannot be made atomic, so it is named per record instead of swallowed.
    local _rf _stale=""
    for _rf in "$CLIENTS_DIR"/*.conf; do
        [ -e "$_rf" ] || continue
        migrate_read_record "$_rf"
        [ "${STATE:-}" = active ] || continue
        # The digest moves with the name, or the next run would think the edit
        # had not been applied and migrate the same host forever.
        [ "${PROFILE:-}" = "$target_profile" ] \
            && [ -n "$_want_digest" ] && [ "${PROFILE_DIGEST_RECORDED:-}" = "$_want_digest" ] && continue
        # Same idiom as activate-client: the record is `.`-sourced, so an
        # appended assignment is the update -- last one wins.
        if { cat "$_rf"; write_client_field PROFILE "$target_profile"
             [ -n "$_want_digest" ] && write_client_field PROFILE_DIGEST_RECORDED "$_want_digest"
             : ; } > "${_rf}.new" \
             && mv -f "${_rf}.new" "$_rf"; then
            chmod 0600 "$_rf" 2>/dev/null || :
        else
            rm -f "${_rf}.new"
            _stale="$_stale ${CLIENT_NAME:-$_rf}"
        fi
    done
    [ -n "$_stale" ] && warn "the config is now on profile '$target_profile', but these client records still name the old one:$_stale -- seed and catch-up read that field, so set PROFILE=$target_profile in them by hand before the next seed"

    log "host migrated to profile '$target_profile' ($migrated client(s) rewritten)."
}

# REV-20260811-102 step 5: add SOURCE retention to relationships installed BEFORE
# step 3, WITHOUT silent repair. Changing the preset only fixes new CREATE; an
# ordinary reactivation must not add source retention as a hidden repair (that would
# violate CONFIG-is-runtime-truth), so this is the ONE explicit, previewed verb that
# does it. Read-only by default (audit): scans the installed CONFIG and lists every
# active pull relationship whose remote source has no bounded [prune:account@host:ds].
#
# REV-20260811-102 F3: "bounded" is decided by EFFECTIVE retention, not header
# existence -- the installed config is rendered through the REAL gen-cron.sh once and
# a source is bounded only if that render emits a delsnaps job for its exact scope. A
# section header that does not resolve to a bounded delsnaps (e.g. it never validated,
# or resolves to nothing) is reported as unbounded, not silently accepted.
#
# REV-20260811-102 F4: --apply is NARROWER than reactivation. It appends ONLY the
# missing source [prune:] sections (emit_missing_source_prune) and their templates; it
# never calls emit_client_sections, so it does not refresh [dataset:] src/flags, move
# an existing source-prune endpoint, or touch target prune. The migration changes only
# the intended source-retention material, in the same previewed/confirmed/grant-checked
# transaction migrate-profile uses.
cmd_audit_source_retention() {   # [--config=PATH] [--local-user=NAME] [--apply] [--yes]
    local apply=0 yes=0 a config_arg="" local_user_arg=""
    for a in "$@"; do
        case "$a" in
            --apply) apply=1 ;;
            --yes)   yes=1 ;;
            --config=*)     config_arg="${a#*=}" ;;
            --local-user=*) local_user_arg="${a#*=}"
                local_user_name_valid "$local_user_arg" \
                    || die "audit-source-retention: --local-user='$local_user_arg' is not a valid account name ($LOCAL_USER_GRAMMAR)"
                # NOT blanked to "" here. The resolver has to tell an explicit
                # "root" from "nothing said", and blanking made them identical
                # -- so --local-user=root, the remedy the refusal itself
                # prints, landed straight back in the refusal. Found live on
                # pve2 and pve1, 2026-08-21.
                ;;
            *) die "audit-source-retention: unknown option $a" ;;
        esac
    done

    read_server_conf
    # P10: measured on pve2 and pve1 2026-08-21. This command printed
    # "1 active pull dataset, nothing to add" while describing the LAB, having
    # never opened production in the delegated account's config. It was not
    # wrong about anything it looked at -- it looked at one of two.
    cron_context_resolve aim "$config_arg" "$local_user_arg" "" ""
    local cronfile="$CRON_CTX_FILE"
    log "audit: config $cronfile ($CRON_CTX_WHY_FILE), as ${CRON_CTX_USER:-root} ($CRON_CTX_WHY_USER)"
    [ -f "$cronfile" ] || die "no cron config at $cronfile -- nothing to audit (run setup-server first)"

    # F3: render the INSTALLED config once through the real gen-cron.sh. Effective
    # bounded retention is read from this, not from section headers. An installed
    # config that does not validate cannot be audited safely -- refuse rather than
    # guess which sources are bounded.
    local rendered; rendered=$(mktemp) || die "mktemp failed"
    if ! bash "$GENCRON" -c "$cronfile" >"$rendered" 2>"$rendered.err"; then
        local gcerr; gcerr=$(cat "$rendered.err" 2>/dev/null)
        rm -f "$rendered" "$rendered.err"
        die "installed config $cronfile does not validate through gen-cron.sh -- cannot audit effective source retention until it does:
$gcerr"
    fi
    rm -f "$rendered.err"

    # --- read-only audit: which active pull relationships lack a bounded source prune ---
    local f missing=0 total_ds=0 passive=0
    local -a report=() passive_report=()
    local -A MISS_SRC=()   # client file -> space-separated missing source SCOPES (account@host:ds)
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        # shellcheck disable=SC1090
        ( . "$f"; [ "${STATE:-}" = active ] ) || continue
        # shellcheck disable=SC1090
        . "$f"
        [ "${STATE:-}" = active ] || continue
        load_client_and_connection "$f"
        local ds localpath src
        for ds in ${PEER_SAVED_DATASETS:-}; do
            localpath="$(client_local_path "$ds")"
            # The source scope is the INSTALLED [dataset:] src, not LOAD_*: CONFIG is
            # truth. A dataset with no installed remote [dataset:] section has nothing
            # to bound here.
            src="$(installed_dataset_src "$cronfile" "$localpath")"
            [ -n "$src" ] || continue
            case "$src" in *@*:*) ;; *) continue ;; esac
            # REV-20260811-108: a PASSIVE external-snapshot relationship (installed
            # transfer flags carry -e) consumes externally-owned snapshots and this
            # package does not own the source snapshot lifecycle. It legitimately has
            # no source [prune:]; adding one would take destructive ownership of
            # snapshots we did not create. Never enter it into MISS_SRC -- report it as
            # intentionally outside source-retention ownership instead.
            if installed_dataset_is_passive "$cronfile" "$localpath"; then
                passive=$((passive + 1))
                passive_report+=("  $CLIENT_NAME: source '$src' -> pasywne (-e): poza wlasnoscia retencji zrodla, pomijam")
                continue
            fi
            total_ds=$((total_ds + 1))
            if ! source_scope_is_bounded "$rendered" "$src"; then
                missing=$((missing + 1))
                MISS_SRC["$f"]="${MISS_SRC["$f"]:-} $src"
                report+=("  $CLIENT_NAME: source '$src' -> would add [prune:$src] (delsnaps -G, non-recursive, __src_keep_* ladder, over the pull's pinned SSH)")
            fi
        done
    done
    rm -f "$rendered"

    echo "Audyt retencji ZRODLA (config: $cronfile)"
    echo "  aktywne pull-datasety (zarzadzane): $total_ds"
    echo "  pasywne (-e, poza wlasnoscia):      $passive"
    echo "  bez ograniczonej retencji zrodla:   $missing"
    if [ "$passive" -gt 0 ]; then
        printf '%s\n' "${passive_report[@]}"
    fi
    if [ "$missing" -eq 0 ]; then
        echo "Kazda aktywna relacja pull ma juz ograniczona retencje zrodla -- nic do dodania."
        return 0
    fi
    printf '%s\n' "${report[@]}"
    echo

    if [ "$apply" -ne 1 ]; then
        echo "To jest audyt TYLKO-DO-ODCZYTU -- $cronfile NIE zostal ruszony."
        echo "Aby DODAC brakujaca retencje zrodla (w podgladanej, potwierdzanej, grant-checkowanej"
        echo "transakcji, ktora ZACHOWUJE cala pozostala polityke): zfs-backup.sh audit-source-retention --apply"
        return 0
    fi

    # --- --apply (F4): append ONLY the missing source prune sections, nothing else ---
    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX") \
        || die "mktemp failed next to $cronfile"
        workfile_track "$workfile"
    chmod 0644 "$workfile" 2>/dev/null || :
    cp -p "$cronfile" "$workfile" || { rm -f "$workfile"; die "could not copy $cronfile"; }
    chmod 0644 "$workfile" 2>/dev/null || :
    PROFILE_GFS=1
    # Initialize the missing source retention from the same preset (default profile
    # family), once; --apply is a retrofit "from the same preset", not a per-client
    # profile reapplication.
    load_active_profile

    local name touched=0
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        local miss="${MISS_SRC["$f"]:-}"
        [ -n "${miss// /}" ] || continue
        # shellcheck disable=SC1090
        . "$f"
        [ "${STATE:-}" = active ] || continue
        name="$CLIENT_NAME"
        load_client_and_connection "$f"
        # F4 fail-closed: the source scope is the INSTALLED [dataset:] src. If the
        # client's current endpoint disagrees with it, the relationship is in a state
        # drift the retrofit must NOT paper over -- refuse and tell the operator to
        # reconcile (re-activate) first, rather than opportunistically "repairing" the
        # endpoint or grant-checking/pruning the wrong host.
        local scope ds expected
        for scope in $miss; do
            ds="${scope##*:}"
            expected="${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
            [ "$scope" = "$expected" ] || { rm -f "$workfile"; die "client '$name': installed source endpoint '$scope' disagrees with the current relationship endpoint '$expected' -- reconcile the endpoint (re-activate) before retrofitting source retention; nothing was changed."; }
        done
        # NARROW: append only the missing source prune(s) for this client. Records
        # SOURCE_PRUNE_EMITTED_DS; reset first so the grant gate sees exactly these.
        SOURCE_PRUNE_EMITTED_DS=()
        emit_missing_source_prune "$workfile" "$name" $miss \
            || { rm -f "$workfile"; die "could not emit missing source prune for '$name'"; }
        # fail-closed grant gate for exactly the source datasets this run emitted a
        # source prune for -- same discipline as activate-client/migrate-profile.
        if [ "${#SOURCE_PRUNE_EMITTED_DS[@]}" -gt 0 ]; then
            # REV-20260812-111 B: the retrofit path must refuse the same
            # combination it would otherwise silently create on an existing host.
            # Local paths come from the scopes this retrofit is about, not from
            # the whole client -- --apply is narrow by construction (F4).
            local -a atomic_paths=(); local ascope
            for ascope in $miss; do atomic_paths+=("$(client_local_path "${ascope##*:}")"); done
            if [ "${#atomic_paths[@]}" -gt 0 ]; then
                ( assert_no_atomic_with_source_retention "$workfile" "${atomic_paths[@]}" ) \
                    || { rm -f "$workfile"; die "atomic-recursion guard refused for '$name' -- nothing added or installed."; }
            fi
            ( assert_source_prune_grant "$LOAD_ACCOUNT" "$LOAD_HOST" "$LOAD_PORT" \
                  "$LOAD_KEYFILE" "$LOAD_ALIAS" "$LOAD_ALIAS_KH" "${SOURCE_PRUNE_EMITTED_DS[@]}" ) \
                || { rm -f "$workfile"; die "source-prune grant check failed for '$name' -- nothing added or installed."; }
        fi
        touched=$((touched + 1))
    done

    log "validating the audited config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the config with the added source retention -- $cronfile was NOT touched"
    fi

    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "could not render the audit preview -- nothing was touched"
    }
    echo "Dodanie retencji ZRODLA do $missing relacji(-i) bez niej ($touched aktywny(-ch) klient(ow) zmienionych)."
    echo
    if [ "$yes" -ne 1 ]; then
        read -rp "Dodac brakujaca retencje zrodla? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) rm -f "$workfile"; die "not confirmed -- $cronfile was NOT touched, nothing installed" ;;
        esac
    fi

    assert_cron_config_matches_installed "$cronfile"
    assert_no_foreign_managed_block "$workfile"
    assert_target_block_not_clobbered "$workfile"
    assert_config_readable_by_target "$cronfile"
    atomic_replace_and_install "$cronfile" "$workfile"
    log "source retention added to $missing relationship(s); all other policy preserved."
}


# ------------------------------------------------------------------------------
# Capability probes. Read-only, and each one answers for the ACCOUNT, not for
# root -- the whole class of defect this migration kept hitting is root proving
# something about itself and the account failing at it later.

# Datasets a config actually manages, from its own section headers.
#
# NO PRODUCTION CALLER since migrate-to-account was retired on 2026-08-19, and
# deliberately kept anyway. It is the TESTED definition of how a section scope
# is split and trimmed, and assert_no_overlapping_policy re-implements that
# same convention inline -- its comment says so by name ("the same comma split
# and whitespace trim config_datasets() applies"). Deleting this would leave
# the convention with an inline implementation and no test.
#
# That makes it the same shape as the snapsend/snapget twins: one rule, two
# implementations, only one watched. The right repair is for the planner to
# CALL this rather than restate it -- which is a change to the planner, so it
# belongs with lab testing rather than with a cleanup sweep. Flagged
# 2026-08-20 so the next dead-code pass does not simply remove it.
config_datasets() {   # <config file>
    # SPLIT ON COMMAS. `[prune:a,b,c]` is one section naming three datasets, and
    # gen-cron.sh has always allowed it -- metropolis pve2 has two such sections.
    # Without the split the whole string was handed to `zfs allow` as a single
    # dataset name, which fails, so every one of those datasets was reported
    # missing and the message printed the comma-joined blob as if it were a
    # dataset. A false alarm that also destroys the operator's ability to read
    # the true ones next to it.
    sed -n -E 's/^\[(dataset|prune):(.+)\]$/\2/p' "$1" | tr ',' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u
}





# Remove one [template:<name>] section, whole. Used only by migrate-profile:
# ensure_cron_config deliberately never rewrites a template that is present, so
# the legacy ones have to go before the new ones can be put back.
# Every [prune:] section this client owns, gone -- by MARKER, not by path.
#
# remove_managed_sections takes dataset paths and clears [dataset:X]/[prune:X]
# for each. That is right for its callers and wrong for a profile migration: a
# GFS ladder sits at the PARENT of the datasets (see the comment in
# remove_managed_sections about the two never sharing a path), so a path-driven
# sweep cannot reach it. Migrating from a GFS profile to a flat one would then
# leave the old ladder in place next to the new per-tier prune -- two pruners
# over the same snapshots, which is the shape this estate has already been
# bitten by. emit_client_sections re-emits whatever the NEW profile needs
# (is_new=1 regenerates every dataset), so removing all of them first is safe.
remove_client_prune_sections() {   # <file> <client name>
    local file="$1" name="$2" tmp
    tmp=$(mktemp) || die "mktemp failed"
    local marker="# managed-by: zfs-backup.sh client=$name"
    local line in_prune=0 first=0 owned=0
    local -a buf=()
    flush_prune_section() {
        if [ "$owned" -ne 1 ]; then
            local l
            for l in ${buf[@]+"${buf[@]}"}; do printf '%s\n' "$l" >> "$tmp"; done
        fi
        buf=()
    }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[prune:*\])
                flush_prune_section
                in_prune=1; first=1; owned=0; buf=("$line"); continue ;;
            \[*\])
                flush_prune_section
                in_prune=0; printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        if [ "$in_prune" -eq 1 ]; then
            # Authorship is the FIRST content line, exactly as
            # remove_managed_sections decides it. Header text alone was never
            # proof of authorship, only of path.
            if [ "$first" -eq 1 ] && [ -n "${line//[[:space:]]/}" ]; then
                first=0
                [ "${line#"${line%%[![:space:]]*}"}" = "$marker" ] && owned=1
            fi
            buf+=("$line")
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    flush_prune_section
    unset -f flush_prune_section
    mv_preserving_mode "$tmp" "$file" || die "could not update $file"
}

# A template nobody references is dead weight, and leaving it behind is what
# makes a migration an APPEND instead. The previous version removed four
# hardcoded legacy names; this asks the file instead, so it works for any
# profile. gen-cron only allows use_template on [dataset:]/[prune:]
# (POLICY_FIELDS carries no use_template), so templates cannot nest and one
# pass over the file is a complete reference count.
#
# DELIBERATELY NARROW: only templates this tool generates are candidates --
# namespaced `profile__*` sections, plus the four legacy names the hardcoded
# version removed. An operator's own unreferenced template is left alone; a
# migration is not a housekeeping sweep of somebody else's file.
remove_orphan_profile_templates() {   # <file>
    local file="$1" t refs
    refs=$(awk -F= '
        /^[ \t]*use_template[ \t]*=/ {
            gsub(/[[:space:]]/, "", $2)
            n = split($2, a, ",")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
        }' "$file" | sort -u)
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            profile__*|standard_hourly|standard_daily|standard_weekly|standard_monthly) ;;
            *) continue ;;
        esac
        printf '%s\n' "$refs" | grep -qxF "$t" && continue
        remove_template_section "$file" "$t"
        log "removed orphaned [template:$t] -- nothing references it after the migration"
    done < <(grep -oE '^\[template:[^]]+\]' "$file" | sed 's/^\[template://; s/\]$//')
}

remove_template_section() {   # <file> <template name>
    local file="$1" tname="$2" tmp
    tmp=$(mktemp) || die "mktemp failed"
    local in_target=0
    while IFS= read -r line; do
        case "$line" in
            \[*\]) [ "$line" = "[template:$tname]" ] && in_target=1 || in_target=0 ;;
        esac
        [ "$in_target" -eq 1 ] || printf '%s
' "$line" >> "$tmp"
    done < "$file"
    mv_preserving_mode "$tmp" "$file" || die "could not update $file"
}

# ------------------------------------------------------------------------------
# pause-client / resume-client (REV-20260804-045, logical pause only).
# Neither touches cron, config, ZFS grants, keys, or the client record --
# the ONLY mutation is the marker under $RELATIONSHIPS_DIR. Both idempotent.
cmd_pause_client() {
    local name="${1:-}"; shift || :
    local reason="" a
    for a in "$@"; do
        case "$a" in
            --reason=*) reason="${a#*=}" ;;
            *) die "pause-client: unknown option $a (only --reason=TEXT)" ;;
        esac
    done
    [ -n "$name" ] || die "pause-client requires a client name"
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    [ "$(id -u)" = 0 ] || die "pause state lives under $RELATIONSHIPS_DIR -- run as root"
    # Pause only what exists: a typo'd name must not create orphan state that
    # a future client of that name would silently inherit.
    [ -r "$(client_conf_path "$name")" ] || die "no client '$name' -- nothing to pause (client records: $CLIENTS_DIR)"
    local marker; marker=$(pause_marker_path "$name")
    if [ -f "$marker" ]; then
        log "client '$name' is already paused:"
        sed 's/^/      /' "$marker"
        return 0
    fi
    local mdir; mdir=$(dirname "$marker")
    mkdir -p "$mdir" || die "could not create $mdir"
    # Explicit modes: the setgid 2775 zfsalert parent would otherwise hand
    # the group write on this state to every delegated account.
    chmod 0755 "$RELATIONSHIPS_DIR" "$mdir" || die "could not set permissions on $mdir"
    # Stage-then-rename in the same directory, the project's usual commit
    # shape -- a torn marker must not exist even across a crash.
    {
        printf 'PAUSED_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        [ -n "$reason" ] && printf 'PAUSED_REASON="%s"\n' "$reason"
        :
    } > "$marker.new" || { rm -f "$marker.new"; die "could not write $marker.new"; }
    chmod 0644 "$marker.new" || { rm -f "$marker.new"; die "could not chmod $marker.new"; }
    mv "$marker.new" "$marker" || { rm -f "$marker.new"; die "could not commit $marker"; }
    log "client '$name' paused (PAUSED_LOCAL). TRANSFER and MONITOR jobs, and labeled manual runs, now exit 'SKIPPED: relationship $name is paused' before any snapshot/SSH work."
    # RETENTION IS NOW INSIDE THE PAUSE, AND THIS LINE HAD TO CHANGE WITH IT.
    #
    # It used to read "NOT covered: retention ... delsnaps lines carry no '-L'
    # and keep pruning on schedule", which was true and measured on metropolis
    # 2026-08-20. On the owner's direction delsnaps.sh gained -L and the
    # generator now emits it on all four prune shapes, so the sentence became
    # the exact inverse of the code -- REV-20260829-124 F2. An operator reading
    # it during a pause would believe retention was still eroding the common
    # base and could take recovery action that is both unnecessary and, if it
    # means resuming early, actively wrong.
    log "Covered: retention too. This relationship's delsnaps lines carry '-L $name' and exit before any listing, SSH or destroy while the pause stands -- on the source as well as the target."
    log "NOT covered: an engine invoked BY HAND without -L. The pause is a property of the relationship label, so a manual snapsend/snapget/delsnaps that does not name the label is outside it by construction, and deliberately so: the pause exists to stop the schedule, not to take the machine away from the administrator sitting at it."
    # In-flight contract (REV-045 boundary 4): a run already past its
    # preflight finishes -- pause gates the NEXT run, it kills nothing.
    local running
    running=$(pgrep -af "snap(get|send)\.sh .*-L $name( |$)" 2>/dev/null || :)
    if [ -n "$running" ]; then
        log "NOTE: a transfer for '$name' is in flight RIGHT NOW -- it will finish; only subsequent runs are blocked:"
        printf '      %s\n' "$running"
    fi
    # The second sentence used to say hard disable was "a separate,
    # unimplemented stage". It shipped and closed (REV-052), so that line
    # became a command telling its operator a working feature does not
    # exist -- and it had already been copied verbatim into the runbook
    # (REV-053 F2). A limitation notice is only useful if it also names
    # what does not have the limitation.
    log "LIMITATION: this is logical pause -- a manual snapget.sh/snapsend.sh that OMITS '-L $name' is not blocked. For enforcement at the peer, including unlabeled manual commands, use: $0 disable-client $name"
}

cmd_resume_client() {
    local name="${1:-}"
    [ -n "$name" ] || die "resume-client requires a client name"
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    [ "$(id -u)" = 0 ] || die "pause state lives under $RELATIONSHIPS_DIR -- run as root"
    # No client-record requirement here, unlike pause: resume doubles as the
    # cleanup path for a marker whose client is already gone.
    local marker; marker=$(pause_marker_path "$name")
    if [ ! -f "$marker" ]; then
        log "client '$name' is not paused -- nothing to do"
        return 0
    fi
    rm -f "$marker" || die "could not remove $marker"
    rmdir "$(dirname "$marker")" 2>/dev/null || :
    log "client '$name' resumed -- the next scheduled run proceeds normally. Snapshots aged while paused; the first run simply catches up incrementally."
}

# ------------------------------------------------------------------------------
# Hard disable (ADR-0012 DISABLED): the peer-side state, driven from here.
#
# The control channel IS the relationship's own gated key -- there is no
# second trust path to the peer, and inventing one (root-to-root ssh) would
# undo the pairing model. The gate accepts three exact literal verbs and
# nothing else; see zfs-pair-gate.sh for why they take no arguments.
pair_control() {   # <verb> -> prints the gate's reply, non-zero on failure
    local verb="$1"
    local -a ssh_opts; load_ssh_opts; ssh_opts=("${LOAD_SSH_OPTS[@]}")
    ssh -n "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "PAIR-CONTROL $verb"
}

# Reads the peer's own view. Returns 0 and sets PEER_PAIR_STATE, or non-zero
# when the peer could not be asked at all -- which is NEVER reported as
# "active": an unreachable peer is an unknown peer.
peer_pair_state() {
    local out rc
    out=$(pair_control status 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        PEER_PAIR_STATE=""
        PEER_PAIR_ERROR="$out"
        return 1
    fi
    PEER_PAIR_STATE=$(printf '%s' "$out" | sed -n 's/^PAIR_STATE=//p' | head -1)
    [ -n "$PEER_PAIR_STATE" ] || { PEER_PAIR_ERROR="the gate answered without a PAIR_STATE line: $out"; return 1; }
    return 0
}

cmd_disable_client() {
    local name="${1:-}"; shift || :
    local reason="" a
    for a in "$@"; do
        case "$a" in
            --reason=*) reason="${a#*=}" ;;
            *) die "disable-client: unknown option $a (only --reason=TEXT)" ;;
        esac
    done
    [ -n "$name" ] || die "disable-client requires a client name"
    client_name_valid "$name" || die "invalid client name '$name'"
    [ "$(id -u)" = 0 ] || die "pause state lives under $RELATIONSHIPS_DIR -- run as root"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    load_client_and_connection "$cpath"

    # ORDER (ADR-0012): local pause FIRST, so no scheduled job can start a
    # transfer in the window between deciding to disable and the peer knowing
    # about it. If the remote half then fails, the relationship is stopped
    # locally and the operator is told exactly that -- stopped, not disabled.
    if client_paused "$name"; then
        log "local pause already in place for '$name'"
    else
        cmd_pause_client "$name" ${reason:+--reason="$reason"} >/dev/null \
            || die "could not establish the local pause -- nothing was sent to the peer"
        log "local pause established for '$name'"
    fi

    log "asking the peer to disable this relationship..."
    local out rc
    out=$(pair_control disable 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "the peer did NOT confirm the disable (ssh/gate said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160))"
        warn "STATE: PAUSED_LOCAL, peer NOT disabled -- scheduled jobs and labeled manual runs are stopped, but a manual command that omits -L would still reach the peer."
        die "retry the same command once the peer is reachable: $0 disable-client $name -- it is a safe retry, the local pause is already in place and the peer verb is idempotent"
    fi

    # READ-BACK, not the write's own reply: the reply says what the gate
    # believed it did, the read-back says what the next connection will see.
    if ! peer_pair_state; then
        warn "the disable was accepted but reading the peer's state back failed: ${PEER_PAIR_ERROR:-unknown}"
        die "STATE: TRANSITION_INCOMPLETE. Re-run $0 disable-client $name to confirm; nothing was rolled back, and the peer may well be disabled already"
    fi
    if [ "$PEER_PAIR_STATE" != "DISABLED" ]; then
        die "STATE: TRANSITION_INCOMPLETE -- the peer reports '$PEER_PAIR_STATE' after a disable it accepted. Do not assume this relationship is blocked; investigate the gate on the peer before relying on it"
    fi
    log "client '$name' is DISABLED: the peer refuses this relationship's data-plane commands, including manual ones that carry no -L."
    log "LIMIT: the relationship's own key can lift this itself ($0 enable-client $name, or PAIR-CONTROL enable over the same key). Every lift is logged on the peer."
}

cmd_enable_client() {
    local name="${1:-}"
    [ -n "$name" ] || die "enable-client requires a client name"
    client_name_valid "$name" || die "invalid client name '$name'"
    [ "$(id -u)" = 0 ] || die "pause state lives under $RELATIONSHIPS_DIR -- run as root"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    load_client_and_connection "$cpath"

    # ORDER (ADR-0012), the mirror image: the REMOTE block goes first and is
    # verified, and only then does the local pause lift. Clearing the local
    # pause first would let a scheduled job start against a peer that is
    # still refusing -- a nightly alert instead of a backup.
    log "asking the peer to enable this relationship..."
    local out rc
    out=$(pair_control enable 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "the peer did NOT confirm the enable (ssh/gate said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160))"
        die "STATE unchanged: still disabled on the peer and paused locally. Safe to retry: $0 enable-client $name"
    fi
    if ! peer_pair_state; then
        die "the enable was accepted but reading the peer's state back failed: ${PEER_PAIR_ERROR:-unknown}. Local pause left IN PLACE deliberately -- retry $0 enable-client $name rather than assume"
    fi
    if [ "$PEER_PAIR_STATE" != "ACTIVE" ]; then
        die "STATE: TRANSITION_INCOMPLETE -- the peer still reports '$PEER_PAIR_STATE'. Local pause left in place; retry $0 enable-client $name"
    fi
    log "peer confirms ACTIVE"

    if client_paused "$name"; then
        cmd_resume_client "$name" >/dev/null || die "the peer is enabled but the LOCAL pause could not be cleared -- STATE: PAUSED_LOCAL. Retry $0 enable-client $name (the peer verb is idempotent) or clear it with $0 resume-client $name"
    fi
    log "client '$name' is ACTIVE again on both sides. The next scheduled run catches up incrementally."
}

# ------------------------------------------------------------------------------
# What this relationship is doing NOW, what it did LAST, and what is safe next.
#
# `status` used to describe only the enrolment: state, endpoint, timestamps. It
# never read the history, so it could not answer the question an operator
# actually has at 08:00 -- "did last night work?" -- and it printed `Zrodla: ?`
# for every mode-based client, because for those the dataset list lives in the
# peer's committed scope, not in the manifest it was reading.
#
# Both are answered from LOCAL, authoritative sources: the installed CONFIG (what
# cron really pulls), the stats JSONL (what happened), and the progress records
# (what is happening). No ssh: status must work when the peer is unreachable,
# which is exactly when it is most likely to be run.
status_sources_from_config() {   # <client name> -> the src= of every section it owns
    local name="$1" cfg="${CRON_CONFIG:-}" line cur="" out=""
    [ -n "$cfg" ] && [ -r "$cfg" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "[dataset:"*) cur="" ;;
            *"managed-by: zfs-backup.sh client=$name") cur="yes" ;;
            *"src"*=*)
                [ "$cur" = yes ] || continue
                out="$out ${line#*= }" ;;
        esac
    done < "$cfg"
    out="${out# }"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

status_last_result() {   # <local target prefix> -> "<time> <status> <duration>s" or nothing
    local prefix="$1" log="${STATS_LOG:-/root/scripts/zfs-snapshot-stats.log}"
    [ -r "$log" ] || return 1
    grep -F "\"dataset\":\"$prefix" "$log" 2>/dev/null | grep -F '"script":"snapget.sh"' | tail -1 \
    | sed -n 's/.*"time":"\([^"]*\)".*"status":"\([^"]*\)".*"duration_s":\([0-9]*\).*/\1 \2 \3/p'
}

status_running_now() {   # <local target prefix> -> one line per live record
    local prefix="$1" dir="${ZFS_PROGRESS_DIR:-/var/lib/zfs-snapshot-all/progress}" f
    [ -d "$dir" ] || return 1
    local any=1
    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        grep -q '"state":"running"' "$f" 2>/dev/null || continue
        grep -qF "\"target\":\"$prefix" "$f" 2>/dev/null || continue
        any=0
        awk -v now="$(date +%s)" '
            function h(b,   u,i){split("B KiB MiB GiB TiB",u," ");i=1
                while(b>=1024&&i<5){b/=1024;i++} return sprintf(i==1?"%d %s":"%.1f %s",b,u[i])}
            { match($0,/"dataset":"[^"]*"/); ds=substr($0,RSTART+11,RLENGTH-12)
              match($0,/"total_bytes":[0-9]*/); t=substr($0,RSTART+14,RLENGTH-14)+0
              match($0,/"done_bytes":[0-9]*/);  d=substr($0,RSTART+13,RLENGTH-13)+0
              match($0,/"updated_epoch":[0-9]*/); u=substr($0,RSTART+16,RLENGTH-16)+0
              p = (t>0)? d*100/t : 0
              stale = (now-u>30) ? sprintf("  (bez aktualizacji od %ds)", now-u) : ""
              printf "                   %s  %s / %s (%.1f%%)%s\n", ds, h(d), h(t), p, stale }' "$f"
    done
    return $any
}

cmd_status() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        [ -d "$CLIENTS_DIR" ] || { log "no clients yet"; return 0; }
        local f
        for f in "$CLIENTS_DIR"/*.conf; do
            [ -e "$f" ] || continue
            ( CLIENT_NAME=""; STATE=""; ACTIVE_ENDPOINT=""
              # shellcheck disable=SC1090
              . "$f"
              pausemark=""
              client_paused "$CLIENT_NAME" && pausemark="  PAUSED_LOCAL"
              printf '%-20s state=%-18s endpoint=%s%s\n' "$CLIENT_NAME" "$STATE" "$ACTIVE_ENDPOINT" "$pausemark" )
        done
        return 0
    fi
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    local mpath; mpath=$(peer_manifest_path "$(peer_label "${PEER_HOST:-}")")
    [ -r "$mpath" ] && { # shellcheck disable=SC1090
        . "$mpath"; }
    local host port; read -r host port <<< "$(active_endpoint_host_port 2>/dev/null || echo "? ?")"
    local LOAD_HOST="$host" LOAD_PORT="$port"
    # The peer's own view, asked out loud (2026-08-20, measured on metropolis).
    # Until this existed, a relationship the peer was refusing outright showed
    # only PAUSED_LOCAL -- together with a sentence promising that unlabeled
    # manual runs are NOT blocked, which was false at exactly that moment. The
    # hard pause lives on the PEER; there is nothing local to read, so it has
    # to be asked.
    #
    # In a subshell: load_client_and_connection sets the LOAD_* family that
    # this function otherwise builds by hand, and it may die -- neither may
    # touch the display state built above. A peer that cannot be asked (down,
    # or status run by a user who cannot read the relationship's key under
    # /root/.ssh/pairing) is reported as UNKNOWN, never as active.
    #
    # Only the detail view asks. The no-argument list stays local and fast, and
    # its PAUSED_LOCAL flag is a sound hint: disable-client establishes the
    # local pause FIRST, so a disabled relationship is a paused one there too.
    local peerstate
    peerstate=$( load_client_and_connection "$cpath" >/dev/null 2>&1 \
                 && peer_pair_state >/dev/null 2>&1 \
                 && printf '%s' "$PEER_PAIR_STATE" ) || peerstate=""

    echo "Klient:            $CLIENT_NAME"
    echo "Stan:              ${STATE:-unknown}"
    if [ "$peerstate" = "DISABLED" ]; then
        echo "Blokada u peera:   DISABLED -- peer odmawia komend tej relacji, TAKZE recznych bez '-L $name'."
        echo "                   To jest granica bezpieczenstwa, nie tylko pauza logiczna."
        echo "                   Zdjecie: $0 enable-client $name"
    elif [ -z "$peerstate" ]; then
        echo "Blokada u peera:   NIEZNANA -- nie udalo sie zapytac bramy (peer nieosiagalny albo brak dostepu do klucza relacji; sprobuj jako root). Nie zakladaj, ze relacja jest aktywna u peera."
    fi
    if client_paused "$name"; then
        local PAUSED_AT="" PAUSED_REASON=""
        # shellcheck disable=SC1090
        . "$(pause_marker_path "$name")"
        echo "Pauza:             PAUSED_LOCAL od ${PAUSED_AT:-?}${PAUSED_REASON:+ (powod: $PAUSED_REASON)}"
        echo "                   joby i reczne uruchomienia Z etykieta '-L $name' sa pomijane;"
        if [ "$peerstate" != "DISABLED" ]; then
            echo "                   reczne uruchomienie BEZ etykiety NIE jest blokowane (pauza logiczna,"
            echo "                   nie granica bezpieczenstwa). Wznowienie: $0 resume-client $name"
        else
            echo "                   Wznowienie: $0 enable-client $name (zdejmuje obie warstwy)"
        fi
        echo "                   Pauza NIE obejmuje retencji: linie delsnaps nie maja '-L' i tna dalej,"
        echo "                   takze po stronie zrodla. Drabinka GFS ogranicza skutek."
    fi
    echo "Endpoint docelowy: $(endpoint_display)"
    # Legacy display (records that predate U9): the dormant slot, if any.
    [ -n "${ENDPOINT_LAN_HOST:-}" ] && echo "  lan:  ${ENDPOINT_LAN_HOST}:${ENDPOINT_LAN_PORT:-22}"
    [ -n "${ENDPOINT_VPN_HOST:-}" ] && echo "  vpn:  ${ENDPOINT_VPN_HOST}:${ENDPOINT_VPN_PORT:-22}"
    [ -n "${ENDPOINT_KNOWN:-}" ] && echo "  znane:  $ENDPOINT_KNOWN"
    # REV-20260730-005 F4: name the divergence outright rather than leaving the
    # operator to infer it from a state word. The dangerous reading this
    # prevents is "status says seed_complete, so nothing is running" while the
    # installed cron is in fact still backing up fine over the old endpoint --
    # and its mirror image, assuming a freshly-set endpoint is already live.
    if [ -n "${INSTALLED_ENDPOINT:-}" ]; then
        echo "Cron dziala przez: $INSTALLED_ENDPOINT"
        if [ "${INSTALLED_ENDPOINT:-}" != "${ACTIVE_ENDPOINT:-}" ]; then
            echo "UWAGA:             backup nadal chodzi przez '${INSTALLED_ENDPOINT}'."
            echo "                   '${ACTIVE_ENDPOINT}' jest zapisany, ale NIEzweryfikowany i NIEwdrozony."
            echo "Nastepny krok:     $0 verify-endpoint $CLIENT_NAME, potem $0 activate-client $CLIENT_NAME"
        fi
    else
        echo "Cron dziala przez: (jeszcze nie aktywowany -- brak linii cron)"
    fi
    # The manifest is the wrong place to ask for a MODE-BASED client: there the
    # dataset list lives in the peer's committed scope, which is why this line
    # printed "?" for every such relationship. The installed CONFIG is local,
    # authoritative, and describes what cron actually pulls tonight.
    local _st_src
    _st_src=$(status_sources_from_config "$CLIENT_NAME")         || _st_src="${PEER_SAVED_DATASETS:-?}"
    echo "Zrodla:            $_st_src"
    echo "Cel:               ${MANAGED_DATASETS:-(jeszcze nie aktywowany)}"
    echo "Spojnosc:          ${QUIESCE_MODE:-crash-consistent (bez quiesce)}"
    echo "Utworzono:         ${CREATED_AT:-?}"
    [ -n "${SEED_COMPLETED_AT:-}" ]    && echo "Seed ukonczony:    $SEED_COMPLETED_AT"
    [ -n "${ENDPOINT_VERIFIED_AT:-}" ] && echo "Endpoint zweryf.:  $ENDPOINT_VERIFIED_AT (${ENDPOINT_VERIFIED_FOR:-?})"
    [ -n "${ACTIVATED_AT:-}" ]         && echo "Aktywowano:        $ACTIVATED_AT"
    [ -n "${REMOVED_AT:-}" ]           && echo "Usunieto:          $REMOVED_AT"

    # NOW, LAST, and what is safe next -- the three questions status could not
    # answer before. Each is stated only when it is actually known: an absent
    # history says so rather than being reported as "no failures".
    local _st_prefix="${MANAGED_PRUNE_SCOPE:-${MANAGED_DATASETS:-}}"
    _st_prefix=${_st_prefix%% *}
    if [ -n "$_st_prefix" ]; then
        echo
        if status_running_now "$_st_prefix"; then
            echo "Teraz:             (transfer w toku -- szczegoly wyzej)"
        else
            echo "Teraz:             nic nie biegnie dla tej relacji"
        fi
        local _st_last; _st_last=$(status_last_result "$_st_prefix")
        if [ -n "$_st_last" ]; then
            set -- $_st_last
            echo "Ostatni wynik:     $2 ($1, trwal ${3}s)"
            if [ "$2" != success ]; then
                echo "Nastepny krok:     sprawdz $0 test $CLIENT_NAME i log w ${CRON_LOG:-cron.log}"
            fi
        else
            echo "Ostatni wynik:     brak zapisu w historii (${STATS_LOG:-/root/scripts/zfs-snapshot-stats.log})"
            echo "                   -- to NIE znaczy 'bez awarii', tylko 'nie wiadomo'"
        fi
    fi
}

# ------------------------------------------------------------------------------
cmd_test() {
    local name="${1:-}"
    [ -n "$name" ] || die "test requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        endpoint_verified|active) ;;
        *) die "client '$name' is not ready to test (state=${STATE:-unknown})" ;;
    esac

    load_client_and_connection "$cpath"
    local ds failed=0
    local base; base=$(snapget_local_base)
    for ds in $PEER_SAVED_DATASETS; do
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $(is_recursive_root "$ds" && printf %s -R) $LOAD_FLAGS$LOAD_BW_FLAG "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
            log "  OK: $ds"
        else
            warn "  FAILED: $ds"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed"
    log "all datasets OK (endpoint: $(endpoint_display))"
}

# ------------------------------------------------------------------------------
# Removes exactly the [dataset:X] sections this client owns (tracked in
# MANAGED_DATASETS at activation time, or passed explicitly), never anything
# else in the shared host config file -- other clients' stanzas and
# hand-written sections must survive untouched.
# Replace a file's contents while KEEPING its mode.
#
# The rewrite idiom here is `tmp=$(mktemp); ...; mv -f "$tmp" "$file"`, and
# mktemp creates 0600 -- so every such rewrite silently re-moded the config to
# root-only. On a collector with a dedicated account that is fatal and almost
# invisible: gen-cron runs AS the account and gets "Permission denied" on a
# config in a world-readable directory, several steps after whatever last
# rewrote it. Found on metropolis pve1, 2026-08-01, after chmod'ing the file by
# hand twice and watching it go back.
mv_preserving_mode() {   # <tmp> <destination>
    local tmp="$1" dest="$2" mode=""
    [ -e "$dest" ] && mode=$(stat -c %a "$dest" 2>/dev/null)
    mv -f "$tmp" "$dest" || return 1
    [ -n "$mode" ] && chmod "$mode" "$dest" 2>/dev/null
    return 0
}

# REV-20260802-033 U11: header text alone used to be treated as proof of
# ownership -- match [dataset:X]/[prune:X] by path, delete unconditionally.
# But a header is only proof of PATH, not of who wrote the section: an
# operator could have hand-written a section at the exact path a client
# later comes to manage (to pin a custom template, say), and the old logic
# would silently delete it on the client's very first activate-client.
#
# emit_client_sections now writes a marker comment as each section's first
# content line ("# managed-by: zfs-backup.sh client=<name>"). A header match
# is accepted as this function's own prior output -- and dropped, same as
# before -- if EITHER the marker is present, OR the path was already listed
# in this client's OWN previously-recorded MANAGED_DATASETS/
# MANAGED_PRUNE_SCOPE (set by `. "$cpath"`/`. "$f"` in every caller before
# this runs). That second test is what keeps every client activated before
# this marker existed working unchanged on its very next rewrite -- their
# sections predate the marker and this call adds it going forward -- while a
# header match on a path this client has never managed before, with no
# marker, is refused: it looks hand-written, not generated, and deleting it
# silently would be worse than stopping here.
remove_managed_sections() {   # <file> <client name> <target-path>...
    local file="$1" name="$2"; shift 2
    local -a targets=("$@")
    local tmp; tmp=$(mktemp) || die "mktemp failed"
    local marker="# managed-by: zfs-backup.sh client=$name"
    local ds header i in_candidate=0 first_line=0 owned=0 trimmed candidate_ds=""
    local -a headers=() header_ds=() section_buf=()
    # Both section types for each path. The GFS profile gives a client one
    # [prune:<target>/<label>] alongside its [dataset:] sections, and a function
    # that only knew about [dataset:] would append a second prune section on
    # every re-activation -- two ladders, same scope, same schedule, racing.
    # Removing [prune:X] when X is a dataset path is a harmless no-op: the two
    # never share a path, since the prune scope is the parent of the datasets.
    for ds in "${targets[@]}"; do
        headers+=("[dataset:$ds]" "[prune:$ds]")
        header_ds+=("$ds" "$ds")
    done

    is_previously_managed() {   # <path>
        local p="$1" x
        for x in ${MANAGED_DATASETS:-}; do [ "$x" = "$p" ] && return 0; done
        # REV-20260802-033 slice 8: sync mode records ONE prune scope PER
        # dataset here (no shared parent to sweep recursively), so this can no
        # longer be a single exact-match value -- word-split it exactly like
        # MANAGED_DATASETS above. Still correct for backup mode's one-entry
        # case, which is just a list of length one.
        for x in ${MANAGED_PRUNE_SCOPE:-}; do [ "$x" = "$p" ] && return 0; done
        return 1
    }

    flush_section() {
        if [ "$owned" -eq 1 ]; then
            : # this is emit_client_sections' own prior output -- drop it
        else
            local l
            for l in "${section_buf[@]}"; do printf '%s\n' "$l" >> "$tmp"; done
        fi
        section_buf=()
    }

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                flush_section
                in_candidate=0
                candidate_ds=""
                owned=0
                for i in "${!headers[@]}"; do
                    if [ "$line" = "${headers[$i]}" ]; then
                        in_candidate=1
                        candidate_ds="${header_ds[$i]}"
                        break
                    fi
                done
                if [ "$in_candidate" -eq 1 ] && is_previously_managed "$candidate_ds"; then
                    owned=1
                    first_line=0
                else
                    first_line=1
                fi
                section_buf+=("$line")
                continue
                ;;
        esac
        if [ "$in_candidate" -eq 1 ] && [ "$first_line" -eq 1 ]; then
            first_line=0
            trimmed="${line#"${line%%[![:space:]]*}"}"
            if [ "$trimmed" = "$marker" ]; then
                owned=1
            else
                rm -f "$tmp"
                die "$file has a [dataset:]/[prune:] section at a path client '$name' manages, but its first line is not '$marker' and this path was never previously recorded as managed by '$name' -- this looks hand-written, not something activate-client generated. Resolve the naming collision by hand (rename or remove the hand-written section) before re-running."
            fi
        fi
        section_buf+=("$line")
    done < "$file"
    flush_section

    mv_preserving_mode "$tmp" "$file" || die "could not update $file"
}

# ==============================================================================
# move-to-client -- the relationship's machine is replaced; the COPY stays put
# ==============================================================================
#
# Owner decision, 2026-08-28 (docs/project/OWNER-MOVE-TO-CLIENT-2026-08-28.md):
# a relationship whose machine is being replaced is not cloned, it MOVES. The
# copy on this collector stays exactly where it is; what changes is which
# machine the relationship points at.
#
# The shape this exists to avoid is the expensive one. Pairing the new machine
# and letting it build its own copy costs a full re-seed: after recovering 10 TB
# onto it, the next backup sends the same 10 TB back, because the two copies
# share no snapshot. Moving the copy keeps ONE lineage across the machine swap,
# which is also the honest description of what happened -- the data did not
# change custodian, the machine under it did.
#
# This verb does NOT recover. It refuses until the data is already on the new
# machine, and the GUID proof below is what it refuses on. Recovery and
# hand-over are different failure domains: a recovery takes hours and may need
# several attempts, the hand-over is seconds and transactional. Composed, they
# make a verb that can be half-done in two incompatible ways, and a verb that
# both produces the proof's condition and checks it is checking its own work.
#
# It does not retire the old relationship either -- it PAUSES it. A pause is
# reversible and a retirement is not, and a move that dies halfway has to leave
# a state the operator can walk back out of.
#
# And it decides nothing else. The old machine may still be alive and stops
# being backed up; this says so plainly and does not require anyone to declare a
# retirement or answer a question the tool invented. The admin has a tool.

# Does the destination machine actually hold this copy? By GUID, per dataset.
#
# THE WHOLE SAFETY OF THE OPERATION. Without it move-to-client is a config edit
# that silently repoints a backup at a machine which does not have the data, and
# nothing discovers that until the next pull -- by which time the old
# relationship is paused and the new one has no common base.
#
# GUID and not name: a name is what a host chose to call a snapshot, and this
# estate has measured two hosts writing different names for the same instant.
# The GUID is what `zfs send -I` will match on, so it is the thing that decides
# whether the next backup is an increment or a re-seed.
#
# Prints nothing and returns 0 when proven; prints the reason and returns 1
# otherwise. An unreadable answer is a refusal, never a pass.
# The newest snapshot of a LOCAL dataset.
#
# source_family_newest answers the same question for a REMOTE source and cannot
# be reused: it always opens ssh to LOAD_ACCOUNT@LOAD_HOST, and what
# move_guid_proof needs is the collector's own copy, on this machine. So this is
# a second probe -- named, in one place, rather than inlined, so the assertion
# that pins "one probe implementation per side" keeps biting if a third appears.
local_newest_snapshot() {   # <dataset> -> newest snapshot name, or nothing
    zfs list -H -t snapshot -o name -s creation -d 1 "$1" 2>/dev/null | tail -1
}

move_guid_proof() {   # <copy dataset> <destination path> <account@host>
    local copy="$1" destpath="$2" peer="$3" snap guid remote
    snap=$(local_newest_snapshot "$copy")
    [ -n "$snap" ] || { echo "    $copy has no snapshot at all, so there is nothing to prove it by"; return 1; }
    snap="${snap#*@}"
    guid=$(zfs get -H -o value guid "${copy}@${snap}" 2>/dev/null)
    [ -n "$guid" ] || { echo "    could not read the guid of ${copy}@${snap} on this collector"; return 1; }
    remote=$(ssh -n "${LOAD_SSH_OPTS[@]}" "$peer" \
        "zfs get -H -o value guid '${destpath}@${snap}'" 2>/dev/null)
    if [ -z "$remote" ]; then
        echo "    ${destpath}@${snap} is not on ${peer%%@*}'s machine -- the copy's newest snapshot has not been recovered there"
        return 1
    fi
    if [ "$remote" != "$guid" ]; then
        echo "    ${destpath}@${snap} exists there but is a DIFFERENT snapshot (guid $remote, expected $guid) -- same name, other data"
        return 1
    fi
    return 0
}

# Re-tag one section's managed-by marker. Not a field, so update_section_field
# cannot do it: it is the second line of the section and it is what
# section_owned_by reads to decide whose section this is. Changing it IS the
# hand-over; everything else in this verb follows from it.
section_retag_client() {   # <file> <exact header> <old name> <new name>
    local file="$1" want="$2" old="$3" new="$4"
    local tmp; tmp=$(mktemp) || return 1
    awk -v want="$want" -v old="# managed-by: zfs-backup.sh client=$old" \
        -v new="# managed-by: zfs-backup.sh client=$new" '
        $0 == want { emit=1; print; next }
        emit && /^\[/ { emit=0 }
        emit {
            line=$0; sub(/^[ \t]+/, "", line)
            if (line == old) { print new; hit=1; next }
        }
        { print }
        END { exit(hit ? 0 : 3) }
    ' "$file" > "$tmp"
    local rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return "$rc"; fi
    cat "$tmp" > "$file" && rm -f "$tmp"
}

# Swap the transport inside a flags string, leaving everything else byte for
# byte. Rewriting the whole field would be easier and would silently drop the
# bandwidth cap, the autotune flag and anything else a profile put there -- so
# only the four things that name the OTHER MACHINE are touched: the key, the
# known_hosts file, the host-key alias and the relationship label.
move_reflag() {   # <old flags string> <new label>
    local f="$1" newlabel="$2"
    f=$(printf '%s' "$f" | sed -E \
        -e "s#(-K )[^ ]+#\1${LOAD_KEYFILE}#" \
        -e "s#(-k )[^ ]+#\1${LOAD_ALIAS_KH}#" \
        -e "s#(-O HostKeyAlias=)[^ ]+#\1${LOAD_ALIAS}#" \
        -e "s#(-L )[^ ]+#\1${newlabel}#")
    printf '%s' "$f"
}

# Rename ONE section header, leaving its body untouched. The source-side
# [prune:] scope carries the peer INSIDE the header --
# [prune:acct@old-host:pool/ds] -- so a hand-over has to move the header, not
# just a field. Refuses (3) when the header is not there rather than writing
# nothing, for the same reason update_section_field does: a silent no-op would
# leave the relationship pruning the OLD machine with no error.
section_rename_header() {   # <file> <old header> <new header>
    local file="$1" old="$2" new="$3"
    grep -qxF "$old" "$file" 2>/dev/null || return 3
    local tmp; tmp=$(mktemp) || return 1
    awk -v old="$old" -v new="$new" '$0 == old { print new; next } { print }' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file" && rm -f "$tmp"
}

# Every section the config marks as belonging to one relationship.
#
# NOT the client record's MANAGED_DATASETS/MANAGED_PRUNE_SCOPE. Those list the
# collector-side paths, and a relationship owns more than that: the SOURCE-side
# [prune:acct@host:path] section is not in either list, because its scope is not
# a local path.
#
# Measured on the lab, 2026-08-28, in the diff of the first real move: the
# transfer line and the monitor moved to the new machine and the source-side
# prune stayed pointing at the OLD one -- so after the hand-over it would have
# gone on destroying snapshots on a machine the relationship no longer covers,
# on schedule, under a relationship that is supposed to be stopped.
#
# The marker is the authority on ownership -- it is what section_owned_by reads
# and what the re-tag rewrites -- so asking the config directly cannot miss a
# shape the record does not happen to track.
config_sections_of_client() {   # <file> <client name> -> one exact header per line
    local file="$1" name="$2"
    awk -v marker="# managed-by: zfs-backup.sh client=$name" '
        /^\[/ { hdr=$0; next }
        {
            line=$0; sub(/^[ \t]+/, "", line)
            if (line == marker && hdr != "") { print hdr; hdr="" }
        }
    ' "$file"
}

cmd_move_to_client() {   # <from> <onto> [--yes]
    local from="" to="" yes=0 a
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            -*) die "move-to-client: unknown option '$a'" ;;
            *)  if   [ -z "$from" ]; then from="$a"
                elif [ -z "$to" ];   then to="$a"
                else die "move-to-client: takes exactly two relationships -- the one to move FROM and the one to move ONTO. Got a third: '$a'."
                fi ;;
        esac
    done
    [ -n "$from" ] && [ -n "$to" ] || die "uzycie: zfs-backup.sh move-to-client <from> <onto> [--yes]
Moves a relationship's COPY to a different machine's relationship. The copy does
not move on disk -- what changes is which machine it is backed up from. The data
must ALREADY be on the new machine (zfs-backup.sh restore <from> <onto>)."
    [ "$from" != "$to" ] || die "move-to-client: '$from' onto itself is not a move."

    local from_rec="$CLIENTS_DIR/$from.conf" to_rec="$CLIENTS_DIR/$to.conf"
    [ -r "$from_rec" ] || die "move-to-client: no relationship record for '$from' ($from_rec). 'zfs-backup.sh status' lists them."
    [ -r "$to_rec" ]   || die "move-to-client: no relationship record for '$to' ($to_rec). Pair the new machine first -- the destination is a relationship this host already holds a key for, not a hostname."

    # A PAUSED DESTINATION WOULD RECEIVE A SCHEDULE THAT DOES NOT RUN.
    #
    # Found on the moveclient-live lab, 2026-08-29. The verb pauses the SOURCE at
    # the end, and never asks about the destination. Move A onto B and then later
    # B back onto A, and A is still paused from the first move: it takes the
    # sections, the crontab is installed, the verb prints "'A' carries the
    # schedule" -- and every one of those jobs exits SKIPPED, because the pause is
    # a property of the label they now carry. Measured: snapget answered
    # "SKIPPED: relationship alfa is paused" on the very line the hand-over had
    # just installed.
    #
    # That is false health of the exact kind this package keeps finding, and the
    # tool announces it as success.
    #
    # Refused rather than resumed. A paused destination is the NORMAL state
    # mid-restore -- pause the twin, restore onto it, hand the schedule over --
    # so lifting the pause silently would be the tool overruling the very
    # transaction the administrator opened. It says which command ends it, and
    # stops before touching anything.
    if client_paused "$to"; then
        die "move-to-client: '$to' is PAUSED, so the schedule this would hand it could not run -- every job carrying '-L $to' exits SKIPPED. That is the normal state while a machine is being restored onto; end it deliberately when the restore is done: zfs-backup.sh resume-client $to. Nothing has been changed."
    fi

    # What <from> manages, read from its own record -- the same source
    # remove-client reads, so the two verbs cannot disagree about what belongs
    # to a relationship.
    # The record answers two questions and no more: WHICH config, and as WHICH
    # account. What the relationship OWNS is asked of the config, because the
    # marker there is the authority -- see config_sections_of_client, and the
    # source-side prune the record's lists do not carry.
    local rec_cfg rec_user
    rec_cfg=$(  . "$from_rec" >/dev/null 2>&1; printf '%s' "${CRON_CONFIG:-}" )
    rec_user=$( . "$from_rec" >/dev/null 2>&1; printf '%s' "${LOCAL_USER:-}" )

    read_server_conf
    cron_context_resolve adopt "" "" "$rec_cfg" "$rec_user"
    local cronfile="$CRON_CTX_FILE"
    [ -n "$cronfile" ] && [ -r "$cronfile" ] || die "move-to-client: no readable installed config for '$from' (${cronfile:-none resolved}) -- nothing to rewrite."

    local mds="" mps="" _h
    while IFS= read -r _h; do
        case "$_h" in
            "[dataset:"*) _h="${_h#[dataset:}"; mds="$mds ${_h%]}" ;;
            "[prune:"*)   _h="${_h#[prune:}";   mps="$mps ${_h%]}" ;;
        esac
    done < <(config_sections_of_client "$cronfile" "$from")
    [ -n "$mds" ] || die "move-to-client: $cronfile marks no [dataset:] section as managed by '$from', so there is nothing to hand over."

    # The DESTINATION's connection: its key, its pinned host key, its port. Every
    # question below is asked of that machine, and the flags written into the
    # config are built from these same values, so the proof and the installed job
    # cannot end up talking to different hosts.
    load_client_and_connection "$to_rec" || die "move-to-client: could not load the connection for '$to'."
    load_ssh_opts
    local peer="${LOAD_ACCOUNT}@${LOAD_HOST}"

    echo ">>> move-to-client: '$from' -> '$to'"
    echo ">>>   the copy stays where it is; what moves is which machine it is backed up from."
    echo ">>>   destination: $peer"
    echo

    # ---- THE PROOF, before a single signpost is touched --------------------
    echo ">>> proving '$to' already holds the copy (by guid, per dataset)"
    local ds srcfield destpath failed=0 proven=0
    for ds in $mds; do
        srcfield="$(section_field "$cronfile" "[dataset:$ds]" src)"
        [ -n "$srcfield" ] || { echo "    [dataset:$ds] records no src -- cannot tell what path it should hold"; failed=1; continue; }
        destpath="${srcfield#*@}"; destpath="${destpath#*:}"
        if move_guid_proof "$ds" "$destpath" "$peer"; then
            echo "    OK  $ds  ->  $peer:$destpath"
            proven=$((proven + 1))
        else
            failed=1
        fi
    done
    if [ "$failed" -ne 0 ]; then
        die "move-to-client: NOTHING was changed. The datasets above are not on '$to' yet, so switching the backup over would point it at a machine without the data -- and nothing would discover that until the next pull, by which time '$from' is paused and '$to' has no common base.
Recover them first:
    zfs-backup.sh restore $from $to
then run this again."
    fi
    echo ">>>   $proven dataset(s) proven present."
    echo

    # ---- the rewrite, on a workfile ---------------------------------------
    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX") \
        || die "move-to-client: mktemp failed next to $cronfile"
    workfile_track "$workfile"
    cat "$cronfile" > "$workfile" || die "move-to-client: could not copy $cronfile"

    local hdr newsrc newflags rc
    for ds in $mds; do
        hdr="[dataset:$ds]"
        section_owned_by "$workfile" "$hdr" "$from" "$ds" \
            || die "move-to-client: $hdr is not recorded as managed by '$from'. Refusing to take over a section this relationship does not own."
        srcfield="$(section_field "$workfile" "$hdr" src)"
        destpath="${srcfield#*@}"; destpath="${destpath#*:}"
        newsrc="${peer}:${destpath}"
        update_section_field "$workfile" "$hdr" src "$newsrc" \
            || die "move-to-client: could not rewrite src in $hdr (rc=$?)"
        newflags="$(move_reflag "$(section_field "$workfile" "$hdr" flags)" "$to")"
        [ -z "$newflags" ] || update_section_field "$workfile" "$hdr" flags "$newflags" \
            || die "move-to-client: could not rewrite flags in $hdr"
        set_or_remove_section_field "$workfile" "$hdr" pair_label "$to" \
            || die "move-to-client: could not rewrite pair_label in $hdr"
        section_retag_client "$workfile" "$hdr" "$from" "$to" \
            || die "move-to-client: could not re-tag $hdr as managed by '$to' (rc=$?)"
        echo ">>>   $hdr  src -> $newsrc"
    done

    # The prune scopes. Two shapes, and they move differently: a COLLECTOR-side
    # scope is a local path and keeps its header, while a SOURCE-side scope
    # carries the peer inside the header and has to be renamed outright.
    # Every [prune:] the config marks as this relationship's, collector-side and
    # source-side alike. $mps (the record's list) carries only the local scopes.
    local newhdr sc
    while IFS= read -r hdr; do
        case "$hdr" in "[prune:"*) ;; *) continue ;; esac
        sc="${hdr#[prune:}"; sc="${sc%]}"
        case "$sc" in
            *@*:*)
                destpath="${sc#*@}"; destpath="${destpath#*:}"
                newhdr="[prune:${peer}:${destpath}]"
                newflags="$(move_reflag "$(section_field "$workfile" "$hdr" ssh_flags)" "$to")"
                [ -z "$newflags" ] || update_section_field "$workfile" "$hdr" ssh_flags "$newflags" \
                    || die "move-to-client: could not rewrite ssh_flags in $hdr"
                set_or_remove_section_field "$workfile" "$hdr" pair_label "$to" || die "move-to-client: pair_label in $hdr"
                section_retag_client "$workfile" "$hdr" "$from" "$to" || die "move-to-client: re-tag $hdr"
                if [ "$newhdr" != "$hdr" ]; then
                    section_rename_header "$workfile" "$hdr" "$newhdr" \
                        || die "move-to-client: could not rename $hdr to $newhdr (rc=$?)"
                fi
                echo ">>>   $hdr  ->  $newhdr" ;;
            *)
                set_or_remove_section_field "$workfile" "$hdr" pair_label "$to" || die "move-to-client: pair_label in $hdr"
                section_retag_client "$workfile" "$hdr" "$from" "$to" || die "move-to-client: re-tag $hdr"
                echo ">>>   $hdr  stays (collector-side scope), now '$to'" ;;
        esac
    done < <(config_sections_of_client "$workfile" "$from")
    echo

    # ---- the record transitions, PREPARED BEFORE ANYTHING GOES LIVE --------
    #
    # REV-20260829-123 F1. This used to install the config and both crontabs
    # first and append to the records afterwards, with a failed append reduced
    # to a warning -- so a full disk or a read-only /etc could leave the new
    # sections installed while the destination's record said it owned nothing,
    # or leave both records claiming the same datasets. `status`, a second move
    # and remove-client all read those records, so the next administrative
    # action would have operated on false ownership. And the command carried on
    # to pause the old relationship and print success over it.
    #
    # Both new records are now written IN FULL, into temporary files in the same
    # directory as the originals, before a single live byte is replaced. That is
    # what proves the directory is writable and has room. What is left after the
    # install is a rename within one directory -- and if even that fails, the
    # rollback below puts the config, both crontabs and both records back, and
    # the old relationship is never paused.
    local to_tmp from_tmp
    to_tmp="$(mktemp "$(dirname "$to_rec")/.movebak.XXXXXX")"     || die "move-to-client: mktemp failed next to $to_rec -- nothing has been changed."
    from_tmp="$(mktemp "$(dirname "$from_rec")/.movebak.XXXXXX")" || { rm -f "$to_tmp"; die "move-to-client: mktemp failed next to $from_rec -- nothing has been changed."; }
    _mv_cleanup() { rm -f "$to_tmp" "$from_tmp" 2>/dev/null || :; }

    {
        cat "$to_rec"
        write_client_field MANAGED_DATASETS    "${mds# }"
        write_client_field MANAGED_PRUNE_SCOPE "${mps# }"
        write_client_field CRON_CONFIG         "$cronfile"
        write_client_field LOCAL_USER          "${CRON_CTX_USER:-}"
        write_client_field MOVED_FROM          "$from"
        write_client_field MOVED_AT            "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$to_tmp" || { _mv_cleanup; die "move-to-client: could not write '$to'\''s new record -- nothing has been changed."; }
    {
        cat "$from_rec"
        write_client_field MANAGED_DATASETS    ""
        write_client_field MANAGED_PRUNE_SCOPE ""
        write_client_field MOVED_TO            "$to"
        write_client_field MOVED_AT            "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$from_tmp" || { _mv_cleanup; die "move-to-client: could not write '$from'\''s new record -- nothing has been changed."; }
    [ -s "$to_tmp" ] && [ -s "$from_tmp" ] || { _mv_cleanup; die "move-to-client: a prepared record came out empty -- refusing to install a config whose ownership records cannot follow it. Nothing has been changed."; }

    # Byte copies to go back to, because atomic_replace_and_install discards its
    # own backups once it succeeds.
    local cfg_bak rec_to_bak rec_from_bak cron_bak
    cfg_bak="$(mktemp)"; rec_to_bak="$(mktemp)"; rec_from_bak="$(mktemp)"; cron_bak="$(mktemp)"
    cp -p "$cronfile" "$cfg_bak" && cp -p "$to_rec" "$rec_to_bak" && cp -p "$from_rec" "$rec_from_bak" \
        || { _mv_cleanup; rm -f "$cfg_bak" "$rec_to_bak" "$rec_from_bak" "$cron_bak"; die "move-to-client: could not take a rollback copy of the config and records -- nothing has been changed."; }
    crontab_for_target > "$cron_bak" 2>/dev/null || :

    # ---- preview, confirm, install ----------------------------------------
    show_activation_proposal "$cronfile" "$workfile" || { _mv_cleanup; die "move-to-client: the proposed config could not be previewed -- nothing has been changed."; }
    if [ "$yes" -ne 1 ]; then
        printf "Wykonac to przeniesienie? [t/N] "
        local ans; read -r ans
        case "$ans" in [tTyY]*) ;; *) die "move-to-client: przerwane -- nic nie zostalo zmienione." ;; esac
    fi
    atomic_replace_and_install "$cronfile" "$workfile" || { _mv_cleanup; rm -f "$cfg_bak" "$rec_to_bak" "$rec_from_bak" "$cron_bak"; die "move-to-client: the install failed -- see above. The config and crontab were rolled back together, and neither record was touched."; }

    # A rename within one directory, after the content was already written
    # there. If it still fails, everything goes back and nothing is paused.
    if ! mv -f "$to_tmp" "$to_rec" || ! mv -f "$from_tmp" "$from_rec"; then
        warn "move-to-client: the config and crontab installed, but the ownership records could not be put in place. Rolling BOTH back so nothing is left claiming what it does not own."
        cp -p "$cfg_bak" "$cronfile"      || warn "CRITICAL: could not restore $cronfile from $cfg_bak -- fix by hand"
        cp -p "$rec_to_bak" "$to_rec"     || warn "CRITICAL: could not restore $to_rec -- fix by hand"
        cp -p "$rec_from_bak" "$from_rec" || warn "CRITICAL: could not restore $from_rec -- fix by hand"
        [ -s "$cron_bak" ] && { _restore_target_crontab "$cron_bak" || warn "CRITICAL: could not restore the crontab from $cron_bak -- restore by hand as $(cron_target_user): crontab $cron_bak"; }
        _mv_cleanup; rm -f "$cfg_bak" "$rec_to_bak" "$rec_from_bak" "$cron_bak"
        die "move-to-client: NOTHING was moved. '$from' has NOT been paused and still owns its sections."
    fi
    rm -f "$cfg_bak" "$rec_to_bak" "$rec_from_bak" "$cron_bak" 2>/dev/null || :

    # ---- and only now, the old relationship stands down --------------------
    # AFTER the install, deliberately. Pausing first would stop the old
    # machine's backups for however long the install takes, and if the install
    # then failed the operator would be left with a paused relationship and an
    # unchanged config -- a state that looks like a half-move and is not one.
    if cmd_pause_client "$from" --reason="moved to '$to' on $(date -Is)" >/dev/null 2>&1; then
        echo ">>> '$from' PAUSED -- its record and its manifest are untouched, and resume-client brings it back."
    else
        warn "the move is installed, but '$from' could NOT be paused. Its schedule still points at the old machine and will now find its sections gone. Pause it by hand: zfs-backup.sh pause-client $from"
    fi

    echo
    echo ">>> done. What is now true:"
    echo ">>>   the copy is unchanged on disk and is backed up from $peer."
    echo ">>>   '$to' carries the schedule; '$from' is paused and keeps its record."
    echo "!!!   the OLD machine is no longer backed up by anything. If it is still"
    echo "!!!   running and still matters, that is now yours to decide -- this verb"
    echo "!!!   does not retire it and has not touched it."
}

cmd_remove_client() {
    local name="${1:-}"
    [ -n "$name" ] || die "remove-client requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    # read_server_conf below unconditionally resets CRON_CONFIG="" and only
    # refills it from $SERVER_CONF -- on a host with no server.conf, that
    # reset is never undone, so the CRON_CONFIG this client actually recorded
    # at activation is silently replaced with an empty string, and the branch
    # below reads it as "never activated" and skips cron cleanup entirely.
    # Live-found 2026-08-09 (metropolis pve1, REV-082/083/085 live proof):
    # remove-client warned "no managed dataset list on file (client was never
    # activated?)" for a client that plainly HAD been. Captured here, before
    # the reset, and restored after it -- same defect and same fix shape as
    # cmd_activate_client's re-activation case.
    local recorded_cron_config="${CRON_CONFIG:-}"
    local recorded_local_user="${LOCAL_USER:-}"
    # Without this, LOCAL_USER is unset here and every crontab operation below
    # silently targets ROOT -- on a collector with a dedicated account that
    # means reading the wrong crontab, comparing against the wrong '# Source:',
    # and, if the comparison had passed, rewriting the wrong user's jobs.
    # Found live on metropolis pve1, 2026-08-01: teardown refused because it was
    # looking at root's block while the client's lines were in the account's.
    # assert_cron_config_matches_installed caught it, which is the third time
    # today a guard turned a defect into a message instead of an incident.
    read_server_conf
    # Policy 'record', and it is the only caller that wants it. The branch below
    # keys cron cleanup on CRON_CONFIG being NON-EMPTY -- an empty answer is not
    # a missing answer here, it is the statement "this client was never
    # activated, so there is no managed block of its to remove". Let this fall
    # back to the host default like activate-client does and teardown would go
    # rewriting a config it was never installed from.
    #
    # The account half is the same ladder as everywhere else and is what stops
    # the removal below from targeting root's crontab while the jobs live in the
    # delegated account's -- clearing nothing, then --unpair refusing on the
    # lines it failed to remove (found live 2026-08-19, lab3 pve9 sync/passive).
    cron_context_resolve record "" "" "$recorded_cron_config" "$recorded_local_user"
    CRON_CONFIG="$CRON_CTX_FILE"
    [ "${STATE:-}" = "removed" ] && die "client '$name' is already removed"

    if [ -n "${MANAGED_DATASETS:-}" ] && [ -n "${CRON_CONFIG:-}" ] && [ -f "$CRON_CONFIG" ]; then
        assert_cron_config_matches_installed "$CRON_CONFIG"
        assert_no_foreign_managed_block "$CRON_CONFIG"
        log "removing this client's [dataset:] sections from a working copy of $CRON_CONFIG"
        local workfile; workfile=$(mktemp "$(dirname "$CRON_CONFIG")/.zfsbackup-work.XXXXXX") \
            || die "mktemp failed next to $CRON_CONFIG"
            workfile_track "$workfile"
        cp -p "$CRON_CONFIG" "$workfile" || { rm -f "$workfile"; die "could not copy $CRON_CONFIG"; }
        chmod 0644 "$workfile" 2>/dev/null || :
        # shellcheck disable=SC2086
        remove_managed_sections "$workfile" "$name" $MANAGED_DATASETS ${MANAGED_PRUNE_SCOPE:-}
        # The REMOTE source prune too. It is a [prune:<account@host:ds>] section
        # this client wrote, and it is not in MANAGED_DATASETS or
        # MANAGED_PRUNE_SCOPE -- both of those record TARGET paths, and the source
        # scope is an endpoint, so remove_managed_sections was never told about it.
        #
        # Measured live (pve1<->pve2, 2026-08-14): removal left that one section
        # behind, the very next step regenerated cron FROM the uncleaned config and
        # reinstalled the line, and --unpair then refused because of the line the
        # removal had just recreated. The documented remedy -- strip the section
        # and re-run gen-cron --install -- cannot be followed either, because a
        # config whose last rule was that section has no rules left and gen-cron
        # rightly refuses to install nothing.
        #
        # Same helper activation already uses to move the source prune across an
        # endpoint switch, so the ownership rule is unchanged: marker-verified,
        # and a hand-written or foreign remote prune is left alone.
        remove_client_remote_source_prunes "$workfile" "$name"
        if grep -qE '^\[(dataset|prune):' "$workfile"; then
            if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
                rm -f "$workfile"
                die "gen-cron.sh rejected the config after removing '$name' -- $CRON_CONFIG was NOT touched. Investigate by hand before retrying."
            fi
            atomic_replace_and_install "$CRON_CONFIG" "$workfile"
        else
            # REV-20260804-039 F2: found live (Gate J) -- gen-cron.sh
            # deliberately refuses to render/install a config with zero
            # send/prune/monitor rules (a real, older safety feature, not
            # something to weaken), so removing a collector's LAST client
            # left nothing for it to render and this whole branch used to
            # die here, unconditionally, on the single most ordinary
            # teardown a small collector ever does. A collector with one
            # client is a normal deployment, not an edge case.
            #
            # No managed sections remain to install, so there is nothing
            # for gen-cron.sh to do -- ask the shared cron writer directly
            # to remove exactly the zfs-backup-managed block (its own
            # diff/lock/rollback semantics, the same primitive --pause
            # uses to touch a block without disturbing anything else in
            # the crontab), THEN swap the config file. Cron first: if the
            # config swapped first and the cron removal then failed, the
            # config would already describe zero jobs while real cron
            # lines survived, with nothing left recording what they were.
            log "no managed sections remain after removing '$name' -- asking the cron writer to remove the zfs-backup-managed block entirely, then updating $CRON_CONFIG"
            if ! cron_block_remove "$(cron_target_user)" zfs-backup-managed; then
                rm -f "$workfile"
                die "could not remove the zfs-backup-managed cron block for $(cron_target_user): ${CRON_ERR:-unknown error} -- $CRON_CONFIG was NOT touched and the client record was NOT updated. Investigate by hand before retrying; re-running remove-client is safe once this is resolved."
            fi
            chmod 0644 "$workfile" 2>/dev/null || :
            if ! mv -f "$workfile" "$CRON_CONFIG"; then
                rm -f "$workfile"
                # REV-20260804-041: found by review -- this used to warn and
                # fall through into --unpair and STATE=removed, which is
                # worse than the failure it was reporting: the client record
                # would claim removal complete while $CRON_CONFIG still
                # described '$name', with no way to retry because the
                # record no longer says there is anything left to remove.
                # Die here instead, before any of that: the client record
                # is untouched by this point (its own STATE=removed write is
                # still below, unreached), so remove-client is a plain safe
                # retry -- cron_block_remove above is already idempotent
                # (a block that is already absent renders identically to
                # what is there and no-ops), it is only this config-file
                # swap that needs to succeed.
                die "the zfs-backup-managed cron block for $(cron_target_user) has ALREADY been removed, but $CRON_CONFIG could not be updated to match (still describes '$name') -- refusing to call --unpair or mark '$name' removed on top of that mixed state. Fix whatever blocked the rename (disk full, permissions on $(dirname "$CRON_CONFIG")), then re-run remove-client $name -- it is a safe retry: the cron side is already done and idempotent, only this config swap remains."
            fi
        fi
    else
        warn "no managed dataset list on file (client was never activated?) -- skipping cron removal"
    fi

    # P8. The pairing record is keyed by the peer ADDRESS, not by the
    # relationship, so two relationships to the same peer SHARE one
    # peers/<addr>.conf. --unpair deletes it. Removing the first relationship
    # therefore left the second in 'seeding' with "no pairing manifest" -- and
    # remove-client refuses a client in that state, so the survivor became
    # unremovable by its own verb. Measured in the 2026-08-20 campaign.
    #
    # Nothing here can be fixed by ordering: whichever goes first takes the
    # record. So ask whether anyone else is still using it, and if so leave it
    # and SAY that it was left, naming who holds it. The last relationship out
    # unpairs; the others just stop referring to it.
    # this_peer is captured BEFORE the loop: sourcing another client's record
    # sets PEER_HOST from that file, so comparing against the live variable
    # inside the subshell would compare it with itself and match every time.
    local this_peer="$PEER_HOST"
    local -a peer_shared_with=()
    local _f _other
    for _f in "$CLIENTS_DIR"/*.conf; do
        [ -r "$_f" ] || continue
        _other=$( . "$_f" >/dev/null 2>&1
                  [ "${CLIENT_NAME:-}" = "$name" ] && exit 0
                  [ "${STATE:-}" = removed ] && exit 0
                  [ "${PEER_HOST:-}" = "$this_peer" ] && printf '%s' "${CLIENT_NAME:-}" )
        [ -n "$_other" ] && peer_shared_with+=("$_other")
    done
    if [ "${#peer_shared_with[@]}" -gt 0 ]; then
        log "leaving the pairing with $PEER_HOST in place -- it is keyed by the peer ADDRESS and ${peer_shared_with[*]} still uses it. This client's own state is removed below; --unpair is the last relationship's job, not this one's."
    else
        bash "$DEPLOY" --unpair --peer="$PEER_HOST" || die "deploy.sh --unpair failed -- see above"
    fi

    {
        cat "$cpath"
        echo "STATE=removed"
        printf 'REMOVED_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"

    # REV-20260804-045: teardown removes THIS relationship's operational
    # state and nothing else's -- exact path, no globbing.
    if client_paused "$name"; then
        rm -f "$(pause_marker_path "$name")" \
            && log "cleared this client's PAUSED_LOCAL marker" \
            || warn "could not remove $(pause_marker_path "$name") -- remove it by hand, or the next client named '$name' will report (and clear) it at add-client"
    fi
    rmdir "$RELATIONSHIPS_DIR/$name" 2>/dev/null || :

    if [ "${#peer_shared_with[@]}" -gt 0 ]; then
        log "client '$name' removed locally. NO peer-side commands to run: the pairing with $PEER_HOST stays, because ${peer_shared_with[*]} still uses it."
    else
        log "client '$name' removed locally. Run the peer-side commands deploy.sh --unpair printed above."
    fi
}

# ------------------------------------------------------------------------------
# deploy_continue_lifecycle NAME YES VERBOSE
#
# Shared tail of the one-command two-host path: given a client record that
# already exists (any STATE), drive it to ACTIVE using the existing,
# individually reviewed lifecycle -- seed -> activate -- and nothing else.
# A standalone continuation so the RUX unified entry point (rux_remote_install)
# reaches an identical seed->activate after its OWN enrolment step, instead of a
# second copy of this state dispatch. (It was extracted from the former `deploy`
# verb, retired 2026-08-19 in favour of --source=HOST: for the deferred form.)
# Precondition: the caller
# has already ensured a client record for NAME exists (enrolled it just now,
# or is resuming one found on disk) -- this function only drives forward from
# whatever STATE is currently recorded.
deploy_continue_lifecycle() {
    local name="$1" yes="$2" verbose="$3"
    local cpath; cpath=$(client_conf_path "$name")
    local state; state=$( . "$cpath"; echo "${STATE:-}" )

    case "$state" in
        pending_enroll|seeding)
            log "deploy: seeding '$name'"
            local -a seed_args=("$name")
            [ "$yes" -eq 1 ] && seed_args+=(--yes)
            cmd_seed "${seed_args[@]}"
            ;;
        seed_complete|endpoint_verified|endpoint_change_pending|active) ;;
        *) die "deploy: client '$name' is in unexpected state '$state' -- resolve with the lifecycle commands (status/seed/activate) before retrying" ;;
    esac

    log "deploy: activating '$name'"
    local -a act_args=("$name")
    [ "$yes" -eq 1 ]     && act_args+=(--yes)
    [ "$verbose" -eq 1 ] && act_args+=(--verbose)
    cmd_activate "${act_args[@]}"

    log "deploy: '$name' is active."
}

# ------------------------------------------------------------------------------
# RUX -- unified remote deployment UX.
#
# Owner decision, docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md
# (status: OWNER DECISION / MUST DO). One grammar for local AND remote:
#
#   --source=DATASET             local source       (unchanged: cmd_local_backup)
#   --source=HOST:DATASET        remote source, pulled by THIS host
#   --target=DATASET             local destination root (backup mode)
#   --mode=sync                  identity-preserving mapping; no --target
#   --install / (absent)         execute the reviewed plan / preview only
#
# This is a UX reduction, not a new engine: it composes the EXISTING add-
# client -> seed -> activate lifecycle (deploy_continue_lifecycle) and the
# existing --join scope/grant confirmation. It adds
# no second grant mechanism and no second state machine -- the non-goals in
# the design doc are the boundary of this feature.

# rux_is_remote_source <source value> -> rc 0 when it names HOST:DATASET (a
# local dataset name never legally contains ':' in this tool's own remote
# syntax: snapsend.sh's REMOTE parsing claims ':' for host:dataset first).
rux_is_remote_source() {
    case "$1" in *:*) return 0 ;; esac
    return 1
}

# rux_split_source <source> -> prints "HOST<TAB>DATASET" or refuses. HOST here
# never carries an embedded port (mirrors --peer=HOST --port=N elsewhere in
# this file) -- a non-default port is --port=N, separately.
rux_split_source() {
    local s="$1" host="${1%%:*}" dataset="${1#*:}"
    # HOST alone (no colon) is a LOCAL source and never reaches here. HOST: with an
    # empty dataset is the DEFERRED-scope form -- the source proposes its own
    # datasets at pair time and the operator picks -- so only the host is required.
    [ -n "$host" ] \
        || die "rux: --source='$s' is not a valid remote source (need HOST:DATASET, or HOST: for deferred scope)"
    # Basket B6: the same colon separates a DATASET here and a PORT in
    # --host=HOST:PORT, one screen apart in the same script. A dataset that is
    # all digits is legal to ZFS, so this cannot be refused outright -- but it
    # is almost certainly the other flag's grammar arriving in this one, and
    # 'pool 22 does not exist' three commands later names the symptom, not the
    # mistake.
    case "$dataset" in
        *[!0-9]*|'') ;;
        *) warn "rux: --source='$s' -- '$dataset' is all digits, which reads like a PORT. Here the colon separates the DATASET (--source=HOST:pool/path); a port goes in --port=$dataset. Proceeding, in case a pool really is named '$dataset'." ;;
    esac
    printf '%s\t%s\n' "$host" "$dataset"
}

# rux_resolve_name <host> <explicit name, may be empty> -> prints the
# relationship name to use. The common one-relationship-per-peer case needs no
# naming argument at all (Owner doc, "Relationship identity"): derive it from
# the peer, the same way deploy.sh's own peer_label() already names its keys
# and manifests. Only refuses to guess when more than one existing
# relationship already points at this host.
rux_resolve_name() {
    local host="$1" explicit="$2"
    if [ -n "$explicit" ]; then
        client_name_valid "$explicit" \
            || die "rux: --name='$explicit' is not a valid client name (letters, digits, dot, dash, underscore only)"
        printf '%s\n' "$explicit"
        return 0
    fi
    local -a matches=()
    if [ -d "$CLIENTS_DIR" ]; then
        local f
        for f in "$CLIENTS_DIR"/*.conf; do
            [ -e "$f" ] || continue
            local CLIENT_NAME="" PEER_HOST="" STATE=""
            # shellcheck disable=SC1090
            . "$f"
            # A record whose last STATE is 'removed' is a tombstone, not a
            # relationship. Counting it here made rux demand --name on a host
            # with NOTHING live pointing at it -- LAB-E hit this with two
            # tombstones and zero live relations. Same rule as add-client's
            # reuse path and the coverage-overlap probe (#124): removed is
            # invisible everywhere, or it is a trap somewhere.
            [ "${STATE:-}" = removed ] && continue
            [ "$PEER_HOST" = "$host" ] && matches+=("$CLIENT_NAME")
        done
    fi
    case "${#matches[@]}" in
        0)
            local derived; derived=$(peer_label "$host")
            client_name_valid "$derived" \
                || die "rux: could not derive a valid client name from host '$host' -- pass --name=NAME explicitly"
            printf '%s\n' "$derived"
            ;;
        1) printf '%s\n' "${matches[0]}" ;;
        *) die "rux: more than one existing relationship already points at '$host' (${matches[*]}) -- pass --name=NAME to say which one. Refusing to guess." ;;
    esac
}

# rux_check_conflict <client conf path> <host> <dataset> <target> <mode>
# A relationship found by host match must have been created by THIS entry
# point (RUX_SOURCE recorded) and must match the CURRENT request exactly, or
# this refuses rather than silently mutating/adopting it (Owner doc, retry/
# idempotence contract).
rux_check_conflict() {
    local cpath="$1" host="$2" dataset="$3" target="$4" mode="$5"
    local RUX_SOURCE="" RUX_TARGET="" RUX_MODE="" CLIENT_NAME=""
    # shellcheck disable=SC1090
    . "$cpath"
    [ -n "$RUX_SOURCE" ] \
        || die "rux: a relationship for '$host' already exists ('$CLIENT_NAME') but was not created through this unified entry point -- use the expert lifecycle commands (status/seed/activate/remove-client) to inspect or resolve it. Nothing was changed."
    local want_source="$host:$dataset"
    if [ "$RUX_SOURCE" != "$want_source" ] || [ "${RUX_TARGET:-}" != "$target" ] || [ "${RUX_MODE:-}" != "$mode" ]; then
        die "rux: the existing relationship '$CLIENT_NAME' already requests source='$RUX_SOURCE' target='${RUX_TARGET:-}' mode='${RUX_MODE:-backup}', which conflicts with this request (source='$want_source' target='$target' mode='${mode:-backup}'). Refusing to silently mutate or adopt it -- resolve by hand (status/remove-client), or re-run with the ORIGINAL request to resume it."
    fi
}

# rux_verify_requested_scope <client conf path> <requested dataset>
# The source side still has to validate/confirm/grant the exact scope before
# a seed is allowed (Owner doc, "Scope and explicit source") -- this does not
# invent a second grant mechanism, it only checks that what --join actually
# came back with covers what the operator asked for, and refuses with the
# exact reason instead of silently seeding a different source. A no-op until
# the peer manifest exists (join not yet complete -- the seed step below
# reports that on its own terms).
rux_verify_requested_scope() {
    local cpath="$1" requested="$2"
    local PEER_HOST=""
    # shellcheck disable=SC1090
    . "$cpath"
    [ -n "$PEER_HOST" ] || return 0
    local mpath; mpath=$(peer_manifest_path "$(peer_label "$PEER_HOST")")
    [ -r "$mpath" ] || return 0
    local PEER_SAVED_MODE=""
    # shellcheck disable=SC1090
    . "$mpath"
    # Sync relationships defer their dataset list to the source's scope file;
    # resolve_mode_datasets enforces T3 for them inside load_client_and_
    # connection, so a second fetch here would only duplicate the same check.
    [ "${PEER_SAVED_MODE:-}" = sync ] && return 0

    # Backup (dataset-addressed) path. The manifest's own PEER_SAVED_DATASETS
    # is written at --pair time FROM THE REQUEST (--datasets=...), so checking
    # the request against it proves nothing -- it compares the request with
    # itself. Found live 2026-08-17 (lab3): the check passed, the seed ran
    # against a source whose operator had never committed the scope, and died
    # with a raw 'cannot create snapshots: permission denied' instead of
    # naming whose move it is. The grant's only proof is the source-side scope
    # file plus the sha256 sidecar that ONLY --commit-scope writes (T3), so
    # that is what this verifies against -- fetched over the pairing channel,
    # via the same fetch_committed_scope the sync path uses. This verifies,
    # it never widens: nothing here creates or edits anything on the source.
    load_client_and_connection "$cpath"
    local scope_tmp; scope_tmp=$(mktemp) || die "mktemp failed"
    fetch_committed_scope "$scope_tmp"
    scope_read "$scope_tmp" || { rm -f "$scope_tmp"; die "scope file fetched from $LOAD_HOST: $SCOPE_ERR"; }
    rm -f "$scope_tmp"
    # Every requested dataset, not just the first. --source carries a LIST now,
    # and a containment check that stopped at item one would let items two and
    # three through ungranted -- a guard that reads as passing while covering a
    # fraction of what it was asked about.
    local _rq _missing=""
    while IFS= read -r _rq; do
        scope_includes "$_rq" || _missing="${_missing:+$_missing, }$_rq"
    done < <(dataset_list_split "$requested")
    [ -z "$_missing" ] \
        || die "rux: requested source(s) '$_missing' not covered by the scope '$PEER_HOST' actually COMMITTED (active roots: ${SCOPE_ROOTS[*]:-none}) -- the source-side grant differs from what was asked. Fix the scope on the source (edit + deploy.sh --commit-scope) or re-run naming datasets the source actually granted. Nothing was seeded."
}

# rux_remote_plan <host> <port> <dataset> <target> <mode> <profile> <name>
# READ-ONLY. No enrolment, SSH write, seed, CONFIG write or cron write --
# shows what is already known locally and what installing would still need to
# establish remotely.
rux_remote_plan() {
    local host="$1" port="$2" dataset="$3" target="$4" mode="$5" profile="$6" explicit_name="$7"
    [ -n "$profile" ] || profile="$PROFILE_DEFAULT_NAME"

    local name; name=$(rux_resolve_name "$host" "$explicit_name") || return 1
    local cpath; cpath=$(client_conf_path "$name")
    local state="(none -- fresh relationship)"
    [ -e "$cpath" ] && state=$( . "$cpath"; echo "${STATE:-unknown}" )

    echo "RUX plan (read-only -- nothing on either host is touched without --install)"
    echo "  relationship name:            $name"
    if [ -n "$port" ] && [ "$port" != 22 ]; then
        echo "  remote source:                 $host:$dataset (port $port)"
    else
        echo "  remote source:                 $host:$dataset"
    fi
    if [ "$mode" = sync ]; then
        echo "  mode:                          sync (identity-preserving -- lands at '$dataset' on this host)"
    else
        echo "  mode:                          backup"
        if [ -z "$dataset" ]; then
            echo "  scope:                         DEFERRED -- the source proposes its datasets at pair time; you pick before install"
        fi
        echo "  local target:                  ${target:-<proposed at pick time>}"
    fi
    echo "  preset (CREATE-time only):     $profile"
    echo "  current lifecycle position:    $state"
    case "$state" in
        "(none -- fresh relationship)")
            echo "  stages that would run:         add-client (enrol + attempt remote join) -> seed -> activate"
            echo "  remote join:                    attempted automatically over SSH from this host; on failure, one manual join command is printed and re-running this SAME command resumes"
            ;;
        pending_enroll)
            # NOT the same as seeding, although it used to be reported that way.
            # pending_enroll means the record exists and the join has not been
            # confirmed -- and resuming does NOT retry the join, it goes on to
            # the scope fetch. Saying "seed -> activate" here promised a
            # continuation that cannot happen while the peer has not accepted
            # the package. Measured on metropolis 2026-08-20.
            echo "  stages that would run:         seed -> activate, BUT ONLY once the join is complete on the peer"
            echo "  note:                          re-running this command does NOT retry the join. If it fell back to"
            echo "                                 manual, finish it on the peer first (deploy.sh --join=<the .tgz>)."
            ;;
        seeding)
            echo "  stages that would run:         seed -> activate"
            ;;
        removed)
            # Its own case since 2026-08-20. It used to fall into the catch-all
            # below and be called an "unknown state", pointing at
            # status/seed/activate -- none of which can revive a removed record,
            # and nothing else in the tree can either: `removed` is terminal.
            echo "  stages that would run:         NONE -- this relationship was removed and cannot be revived."
            echo "  to back this peer up again:    use a different relationship name (--name=NEW), which enrols"
            echo "                                 alongside the removed record and leaves its history intact."
            ;;
        seed_complete|endpoint_verified|endpoint_change_pending)
            echo "  stages that would run:         activate"
            ;;
        active)
            echo "  stages that would run:         (already active -- re-running is a clean no-op/refresh check)"
            ;;
        *)
            echo "  stages that would run:         unknown state '$state' -- resolve with status/seed/activate before installing"
            ;;
    esac
}

# rux_remote_install <host> <port> <dataset> <target> <mode> <profile> <yes> <verbose> <name>
# Orchestrates the existing lifecycle to ACTIVE. Safe to re-run after
# interruption at any stage (Owner doc, "Critical retry/idempotence
# contract") -- progress is derived from the client record already on disk,
# never a second state store.
# ------------------------------------------------------------------------------
# --grant-remotely (owner decision 2026-08-17, docs/discussions/
# ZFSBACKUP-ONLY-DEPLOYMENT-2026-08-17.md accepted verbatim). One narrow
# consent: commit, on the source, a scope EQUAL TO THE REQUEST -- over the
# operator's own root-ssh channel, the same one --join-remotely already used
# to create the delegated account there. It amends REV-20260802-033 U10's
# "the grant never runs remotely" with an explicit, audited opt-in; the
# DEFAULT path stays two-touch and U10-shaped.
#
# Properties held to exactly:
#   * the committed scope is by construction the requested dataset, never
#     wider -- the stanza is generated here from the command line, not taken
#     from whatever happens to lie on the source;
#   * a pre-existing draft that selects something DIFFERENT refuses -- an
#     operator prepared that file, and force is not permission to overwrite
#     another person's pending decision;
#   * no root channel -> refuse EARLY, before any state changes, with the
#     exact trust to establish;
#   * the source keeps an audit fact (GRANTED_REMOTELY_BY in the join
#     manifest) saying the consent came from outside and from whom;
#   * verification stays the same authority as ever: after this returns, the
#     ordinary fetch+hash+includes check (rux_verify_requested_scope /
#     resolve_mode_datasets) still runs and still decides.
#
# All remote work here rides root-ssh, deliberately including the
# already-committed probe: the account channel would recurse into
# resolve_mode_datasets' own T3 fetch for sync-mode clients -- the very check
# this function exists to satisfy first.
# -n ON EVERY ssh IN THIS FILE, AND IT IS NOT COSMETIC.
#
# ssh without -n reads its standard input to EOF and forwards it to the remote
# command. Nothing here ever wants that -- no call site pipes anything in -- but
# every one of them SWALLOWS whatever the operator's stdin was carrying. The
# visible consequence is that a confirmation prompt printed AFTER an ssh call
# can never be answered from a pipe, because the answer was already eaten:
#
#     ./zfs-backup.sh seed <name>      < answers      -> "not confirmed"
#     ./zfs-backup.sh activate <name>  < answers      -> "not confirmed"
#
# Both resolve the peer's scope over ssh before asking. Measured on pve9,
# 2026-08-23:
#
#     printf 'ZOSTALO<NL>' | { ssh root@peer true; read -r x; echo "[${x:-PUSTO}]"; }
#       -> [PUSTO]
#
# On a terminal it works, because stdin is the tty and ssh does not consume the
# keystrokes typed after it exits -- so this never showed up in hand testing,
# only the moment anything was scripted. Found running issue #9's trial.
#
# `-n` is the documented fix (ssh(1): redirect stdin from /dev/null). It is safe
# at every site because no call in this file feeds ssh anything; a site that
# ever needs to must drop -n deliberately and say why.
# THE ONE root-ssh call that CARRIES A PAYLOAD ON STDIN. rux_root_ssh gained -n
# in the 2026-08-23 sweep (#127) -- correctly, every other call only reads --
# and that silently broke --grant-remotely: the scope stanza is piped into
# `cat > file` on the source, -n pointed stdin at /dev/null, and the file
# arrived EMPTY. The config-grammar guard downstream refused the empty scope
# ("selects nothing"), so the failure was loud and nothing was granted from it
# -- fail-closed held -- but the automatic enrolment was dead. Found live in
# the LAB-E campaign, hours after the sweep.
#
# The sweep completeness test could not see this: it greps for `| ssh`, and
# here the pipe enters a WRAPPER. Hence the marker below, which that test now
# keys on instead of guessing.
rux_root_ssh_in() {   # <host> <port> <command...> -- stdin-carrier: NO -n
    local host="$1" port="$2"; shift 2
    ssh -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o StrictHostKeyChecking=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval="$SSH_SERVER_ALIVE_INTERVAL" \
        -p "${port:-22}" "root@$host" "$@"
}

rux_root_ssh() {   # <host> <port> <command...>
    local host="$1" port="$2"; shift 2
    ssh -n -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o StrictHostKeyChecking=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval="$SSH_SERVER_ALIVE_INTERVAL" -o ServerAliveCountMax="$SSH_SERVER_ALIVE_COUNT" \
        -p "${port:-22}" "root@$host" "$@"
}

# rux_grant_remotely_preflight <host> <port>
#
# Everything --grant-remotely needs BEFORE the first byte of state is written,
# because the function that used to ask these questions runs after
# cmd_add_client -- so the "refuse EARLY, before any state changes" property
# above was documented but not delivered. By the time the old checks fired, the
# client record, the keypair and the pairing package already existed and the
# join had already been attempted.
#
# Two questions, and the second is the one 2026-08-20 found the hard way. This
# flag's whole promise is "one command instead of four", and it can only keep
# that promise on a pair that is ALREADY joined: the grant is committed to the
# account `zfsbackup-<label>`, and it is the JOIN that creates that account on
# the source. On an unjoined pair there is nothing to grant to, so the flag
# cannot deliver -- and finding that out mid-run leaves a half-built client to
# clean up before the operator can take the ordinary path anyway.
#
# Refusing is therefore the kinder answer, not the stricter one. Nothing here
# is a security decision: the default two-sided path remains fully available
# and is printed verbatim.
rux_grant_remotely_preflight() {   # <host> <port> [will_join_now=0]
    local host="$1" port="$2" will_join_now="${3:-0}"
    if ! rux_root_ssh "$host" "$port" "true" >/dev/null 2>&1; then
        die "--grant-remotely: no root ssh channel to $host (BatchMode, pinned /root/.ssh/known_hosts). Establish it first -- e.g. install this host's root key there: ssh-copy-id root@$host -- or drop --grant-remotely and run the grant on the source yourself: deploy.sh --commit-scope=$COLLECTOR_LABEL. Nothing was changed anywhere."
    fi
    # The manifest requirement holds only when THIS run will not create it.
    # The one-command flow's own add-client performs the join (--join-remotely,
    # the default) minutes after this gate -- demanding a PRE-existing join
    # there made the "whole enrolment is ONE command" promise false for the
    # first-ever pairing of a clean host, and the LAB-E closing campaign met
    # exactly that on a source with no leftovers. With --manual-join the join
    # will NOT happen in this run, and the early refusal below stays exactly
    # as the 2026-08-20 live failure demanded.
    [ "$will_join_now" -eq 1 ] && return 0
    local mfile; mfile=$(peer_manifest_path "$COLLECTOR_LABEL")
    if ! rux_root_ssh "$host" "$port" "test -s '$mfile'" >/dev/null 2>&1; then
        die "--grant-remotely: $host has not joined '$COLLECTOR_LABEL' yet (no $mfile there), so there is no delegated account to grant to and this flag cannot do the whole enrolment in one command. Nothing was changed anywhere -- no client record, no keys, no package.

Use the ordinary two-sided path instead; it ends in the same place:
  1. here:        $0 --source=... --target=... --install --yes
                  (stops and prints a package plus the exact command for $host)
  2. on $host:    deploy.sh --join=<package>      <- accepts the scope, asks
  3. on $host:    deploy.sh --commit-scope=$COLLECTOR_LABEL
  4. here:        re-run the exact command from step 1 -- it resumes

Add --grant-remotely again on a LATER relationship with $host: once the pair is
joined it does step 3 for you."
    fi
}

rux_grant_remotely() {   # <host> <port> <requested dataset>
    local host="$1" port="$2" requested="$3"
    local sfile hfile
    sfile=$(peer_scope_path "$COLLECTOR_LABEL")
    hfile=$(peer_scope_granted_hash_path "$COLLECTOR_LABEL")

    if ! rux_root_ssh "$host" "$port" "true" >/dev/null 2>&1; then
        die "--grant-remotely: no root ssh channel to $host (BatchMode, pinned /root/.ssh/known_hosts). Establish it first -- e.g. install this host's root key there: ssh-copy-id root@$host -- or drop --grant-remotely and run the grant on the source yourself: deploy.sh --commit-scope=$COLLECTOR_LABEL. Nothing was changed anywhere."
    fi

    if rux_root_ssh "$host" "$port" "test -s '$hfile'" >/dev/null 2>&1; then
        # A committed scope exists. Until 2026-08-23 this branch said "nothing
        # to grant" unconditionally -- true for a re-run of the SAME
        # relationship, and a dead end for the SECOND relationship to the same
        # source: its new root was never granted and the ordinary verification
        # below failed with "not covered by the scope actually COMMITTED"
        # (measured, labD after labS). The request this flag is allowed to
        # sign is unchanged -- exactly the requested roots -- so a committed
        # scope is EXTENDED by appending the missing request-shaped stanzas
        # and re-running --commit-scope, which reconciles grants exactly like
        # the first commit did. Roots already carrying a stanza are left
        # alone; a broader operator-written stanza that covers the request
        # without naming it gains a redundant, audited, harmless child stanza.
        local committed_headers missing="" _rh
        committed_headers=$(rux_root_ssh "$host" "$port" "cat -- '$sfile' 2>/dev/null"             | awk '/^\[dataset:/{print}')
        while IFS= read -r _rh; do
            case "$committed_headers" in
                *"[dataset:$_rh]"*) ;;
                *) missing+="$_rh"$'
' ;;
            esac
        done < <(dataset_list_split "$requested")
        if [ -z "$missing" ]; then
            log "--grant-remotely: $host already has a committed scope for '$COLLECTOR_LABEL' covering the request -- nothing to grant"
            return 0
        fi
        # Extend only a file that IS the committed version. A file whose bytes
        # differ from the granted hash is an operator's pending edit, and this
        # flag is not permission to build on top of it.
        rux_root_ssh "$host" "$port" "[ \"\$(sha256sum -- '$sfile' | awk '{print \$1}')\" = \"\$(cat -- '$hfile')\" ]" >/dev/null 2>&1             || die "--grant-remotely: the scope file on $host differs from the last committed version -- an operator is editing it. Commit or align it there (deploy.sh --commit-scope=$COLLECTOR_LABEL), then re-run. Nothing was changed."
        local extend_repo="" _xd
        for _xd in "$SCRIPT_DIR" /root/scripts/zfs-snapshot-all /root/zfs-snapshot-all; do
            if rux_root_ssh "$host" "$port" "test -x '$_xd/deploy.sh'" >/dev/null 2>&1; then extend_repo="$_xd"; break; fi
        done
        [ -n "$extend_repo" ] || die "--grant-remotely: could not find deploy.sh on $host -- cannot re-commit the extended scope"
        local ext_stamp; ext_stamp="root@$(hostname -s 2>/dev/null || hostname) $(date '+%Y-%m-%d %H:%M:%S %Z')"
        log "--grant-remotely: extending the committed scope on $host with $(printf '%s' "$missing" | wc -l) new root(s) and re-committing (audited)"
        {
            printf '
# Extended by --grant-remotely from %s.
' "$ext_stamp"
            while IFS= read -r _rh; do
                [ -n "$_rh" ] || continue
                printf '[dataset:%s]
include_parent = yes
include_children = yes
' "$_rh"
            done <<< "$missing"
        } | rux_root_ssh_in "$host" "$port" "cat >> '$sfile'"             || die "--grant-remotely: could not append to the scope file on $host -- nothing was committed"
        rux_root_ssh "$host" "$port" "cd '$extend_repo' && ./deploy.sh --commit-scope='$COLLECTOR_LABEL'" 2>&1 | tail -4             || die "--grant-remotely: deploy.sh --commit-scope='$COLLECTOR_LABEL' FAILED on $host (see above). The scope file was extended; finish or inspect locally there."
        local ext_mfile; ext_mfile=$(peer_manifest_path "$COLLECTOR_LABEL")
        rux_root_ssh "$host" "$port" "printf 'GRANTED_REMOTELY_BY=%q
' '$ext_stamp (extension)' >> '$ext_mfile'"             || warn "--grant-remotely: the extension is committed but the audit line could not be appended to $ext_mfile on $host -- add it by hand"
        log "--grant-remotely: extension committed on $host as '$COLLECTOR_LABEL', audit recorded"
        return 0
    fi

    local remote_repo="" d
    for d in "$SCRIPT_DIR" /root/scripts/zfs-snapshot-all /root/zfs-snapshot-all; do
        if rux_root_ssh "$host" "$port" "test -x '$d/deploy.sh'" >/dev/null 2>&1; then remote_repo="$d"; break; fi
    done
    [ -n "$remote_repo" ] || die "--grant-remotely: could not find deploy.sh on $host (tried $SCRIPT_DIR, /root/scripts/zfs-snapshot-all, /root/zfs-snapshot-all) -- is the package deployed there?"

    # The scope this flag is allowed to sign: exactly the request -- one stanza
    # per requested dataset, because --source now carries a LIST like every
    # other dataset argument in the package (dataset_list_split, lib-scope.sh).
    # A single-item list renders byte-identical to what this wrote before, so an
    # existing draft written by an earlier run still compares equal below.
    local want="" _rq
    while IFS= read -r _rq; do
        want+=$(printf '[dataset:%s]\ninclude_parent = yes\ninclude_children = yes\n' "$_rq")
        want+=$'\n'
    done < <(dataset_list_split "$requested")
    want="${want%$'\n'}"

    # The comparison has to be list-against-list. Comparing the peer's stanzas
    # to a single "[dataset:$requested]" would refuse every multi-dataset
    # request outright, and -- worse -- would compare a two-line block against a
    # one-line string and call a MATCHING scope a conflict.
    local want_headers; want_headers=$(dataset_list_split "$requested" | sed 's/^/[dataset:/; s/$/]/')
    local existing_active
    existing_active=$(rux_root_ssh "$host" "$port" "cat -- '$sfile' 2>/dev/null" \
        | awk '/^# ==========/{exit} /^\[dataset:/{print}')
    if [ -n "$existing_active" ] && [ "$existing_active" != "$want_headers" ]; then
        # The pending-decision guard protects a HUMAN's choice -- and the lab3
        # final run tripped it on a file no human ever touched: a sync-mode
        # join carries no dataset list, so the join's own remote scope stage
        # auto-drafts the full branch inventory seconds before this check, and
        # a fresh sync enrolment under --grant-remotely would refuse EVERY
        # time. A draft is provably the enrolment's own automatic one when
        # BOTH hold on the source: no commit-hash sidecar exists (nothing was
        # ever signed from it), and the file is not older than the join this
        # manifest records (both timestamps read on the SOURCE's clock, so
        # skew between hosts cannot fake it). That file is ours to replace
        # with the request. Anything else -- edited, committed, or predating
        # the join -- keeps the refusal below.
        local mfile_r; mfile_r=$(peer_manifest_path "$COLLECTOR_LABEL")
        if rux_root_ssh "$host" "$port" "test ! -s '$hfile' && j=\$(sed -n 's/^PEER_JOIN_REMOTE_AT=\"\\(.*\\)\"/\\1/p' '$mfile_r' | tail -1) && [ -n \"\$j\" ] && [ \"\$(stat -c %Y -- '$sfile')\" -ge \"\$(date -d \"\$j\" +%s)\" ]" >/dev/null 2>&1; then
            log "--grant-remotely: the draft on $host is this enrolment's own auto-draft (no commit, not older than the join) -- replacing it with the request"
        else
            die "--grant-remotely: $host already carries a DRAFT scope for '$COLLECTOR_LABEL' selecting something different:
$existing_active
than the request:
$want_headers
An operator prepared that file, and this flag is not permission to overwrite their pending decision. Either commit it locally there (deploy.sh --commit-scope=$COLLECTOR_LABEL), align it with the request, or remove it and re-run. Nothing was changed."
        fi
    fi

    local stamp; stamp="root@$(hostname -s 2>/dev/null || hostname) $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "--grant-remotely: writing the request-shaped scope and committing it on $host (audited)"
    {
        printf '# Scope for peer %s -- GENERATED BY --grant-remotely from %s.\n' "$COLLECTOR_LABEL" "$stamp"
        printf '# Equal to the request by construction; widen only by editing here and re-running --commit-scope locally.\n'
        printf '%s\n' "$want"
    } | rux_root_ssh_in "$host" "$port" "cat > '$sfile'" \
        || die "--grant-remotely: could not write the scope file on $host -- nothing was committed"

    rux_root_ssh "$host" "$port" "cd '$remote_repo' && ./deploy.sh --commit-scope='$COLLECTOR_LABEL'" 2>&1 | tail -4 \
        || die "--grant-remotely: deploy.sh --commit-scope='$COLLECTOR_LABEL' FAILED on $host (see above). The scope file was written; finish or inspect locally there."

    local mfile; mfile=$(peer_manifest_path "$COLLECTOR_LABEL")
    rux_root_ssh "$host" "$port" "printf 'GRANTED_REMOTELY_BY=%q\n' '$stamp' >> '$mfile'" \
        || warn "--grant-remotely: the grant is committed but the audit line could not be appended to $mfile on $host -- add it by hand"
    log "--grant-remotely: committed on $host as '$COLLECTOR_LABEL', audit recorded"
}

rux_remote_install() {
    local host="$1" port="$2" dataset="$3" target="$4" mode="$5" profile="$6" yes="$7" verbose="$8" explicit_name="$9" local_user="${10}" grant_remotely="${11:-0}" manual_join="${12:-0}"

    local name; name=$(rux_resolve_name "$host" "$explicit_name") || return 1
    # A declared-passive relationship defaults to the PASSIVE profile: its
    # templates are prefixless and its monitors run in any-mode, which is the
    # only shape that matches the declaration. An explicit --profile= still
    # wins -- the operator may have a customised passive variant.
    if [ "$passive" -eq 1 ] && { [ -z "$profile" ] || [ "$profile" = "$PROFILE_DEFAULT_NAME" ]; }; then
        profile=passive
    fi

    local cpath; cpath=$(client_conf_path "$name")
    local state=""
    [ -e "$cpath" ] && state=$( . "$cpath"; echo "${STATE:-}" )
    # Same tombstone rule: a removed record must not block the unified path
    # either -- add-client (called below) archives it and reuses the name.
    [ "$state" = removed ] && state=""

    # Which account the generated jobs run as. Decided ONCE, here, at create:
    #
    #   --local-user=NAME   names the account -- root, or any delegated user
    #                       (created below if it does not exist yet). Always wins.
    #   omitted             root. There is no host-wide guess, no adopted account,
    #                       no server.conf lookup: the job runs as whoever you did
    #                       NOT delegate it to. Want a delegated account? Name it.
    #                       That is the whole rule.
    #
    # The decision then travels WITH THE RELATIONSHIP -- the manifest's
    # PEER_SAVED_LOCAL_USER and the client record's LOCAL_USER field -- so activate
    # and remove read it back rather than re-deriving it. A resume ($state set)
    # never re-resolves. An empty local_user reaches cron_target_user as root.
    if [ -z "$state" ] && [ -z "$local_user" ]; then
        log "rux: no --local-user -- the generated jobs will run as root; pass --local-user=NAME to delegate them to an account instead"
    fi

    # --grant-remotely's preconditions are asked HERE, ahead of the first thing
    # that changes anything -- the account creation just below, then the client
    # record, keys and package. Only for a NEW relationship: a resume has
    # already paid those costs, and rux_grant_remotely's own checks still guard
    # the grant itself either way.
    # Spelled as an `if`, not a `&&` chain, on purpose: this is a gate, and a
    # gate must not depend on nobody ever adding `set -e` to this file.
    if [ "$grant_remotely" -eq 1 ] && [ -z "$state" ]; then
        rux_grant_remotely_preflight "$host" "$port" "$([ "$manual_join" -eq 1 ] && echo 0 || echo 1)"
    fi

    # Accepted semantics: --local-user names the account this relationship
    # runs as; on a fresh host it does not exist yet, and creating it is a
    # LOCAL root action (the operator running this is already root here).
    # The one-command promise folds it in with a loud line instead of
    # stopping to tell the operator to run the same thing by hand.
    if [ -n "$local_user" ] && ! id -u "$local_user" >/dev/null 2>&1; then
        log "rux: local account '$local_user' does not exist -- creating it now (deploy.sh --backup-user=$local_user)"
        bash "$DEPLOY" --backup-user="$local_user" \
            || die "rux: deploy.sh --backup-user=$local_user failed -- see above; nothing was enrolled"
    fi

    if [ -z "$state" ]; then
        local hostarg="$host"
        [ -n "$port" ] && [ "$port" != 22 ] && hostarg="$host:$port"
        local -a add_args=("$name" --host="$hostarg")
        if [ "$mode" = sync ]; then
            add_args+=(--mode=sync)
            # LAB6 pass 7 F-1: this line is the whole fix. `--source=HOST:DATASET
            # --mode=sync` names a dataset; before this it went no further than
            # RUX_SOURCE on this host, so the source was asked to draft a scope
            # from silence and drafted its entire estate. The list a sync
            # relationship replicates is still whatever the source COMMITS --
            # this only makes the draft it commits from start at what was asked.
            [ -n "$dataset" ] && add_args+=(--requested="$dataset")
        else
            # Deferred scope (empty dataset): pass NO --datasets, so add-client
            # leaves the dataset selection to the source's own scope draft at
            # pair time -- exactly what the retired `deploy` verb did. An explicit
            # dataset is named; --target stays optional either way (proposed).
            [ -n "$dataset" ] && add_args+=(--datasets="$dataset")
            [ -n "$target" ] && add_args+=(--target="$target")
        fi
        [ -n "$profile" ] && add_args+=(--profile="$profile")
        [ -n "$recursion" ] && add_args+=(--recursive="$recursion")
        [ "$passive" -eq 1 ] && add_args+=(--passive)
        [ -n "$exclude_family" ] && add_args+=(--exclude-family="$exclude_family")
        for _x in ${excludes[@]+"${excludes[@]}"}; do add_args+=(--exclude-child="$_x"); done
        [ -n "$local_user" ] && add_args+=(--local-user="$local_user")
        # The one-command promise applies here too: attempt the remote join over
        # SSH from this host by default (Owner doc, "Join behavior"); --manual-join
        # opts into the explicit two-sided form instead.
        [ "$manual_join" -eq 1 ] || add_args+=(--join-remotely)
        log "rux: enrolling '$name' (source=$host:${dataset:-<deferred>}, mode=${mode:-backup})"
        cmd_add_client "${add_args[@]}"
        {
            write_client_field RUX_SOURCE "$host:$dataset"
            write_client_field RUX_TARGET "$target"
            write_client_field RUX_MODE   "$mode"
        } >> "$cpath"
    else
        log "rux: resuming '$name' from state '$state'"
        rux_check_conflict "$cpath" "$host" "$dataset" "$target" "$mode"
    fi

    # The grant step runs BEFORE the verification and never replaces it: what
    # --grant-remotely wrote is proven the same way a hand-committed scope is.
    [ "$grant_remotely" -eq 1 ] && rux_grant_remotely "$host" "$port" "$dataset"

    rux_verify_requested_scope "$cpath" "$dataset"

    deploy_continue_lifecycle "$name" "$yes" "$verbose"
}

# rux_entry -- the dispatcher's --source=*/--target=* case reaches this
# instead of cmd_local_backup directly, so it can decide local vs remote
# BEFORE any argument reaches an entrypoint that would refuse ':' in --source.
# Local behaviour is byte-for-byte unchanged: cmd_local_backup is called with
# the ORIGINAL, unmodified argument vector.
# P7: refuse a relationship whose "remote" source is this very host.
#
# The engines already refuse it -- validate_remote_host in lib-zfs-snap.sh
# compares /etc/machine-id and aborts. But that lives in the engine, and the
# PLANNER never calls it, so `--source=<our own address> --mode=sync` planned
# clean with rc=0. Follow that plan and you build an account, a key pair and a
# set of cron lines, and the refusal finally arrives at the first job -- long
# after the state exists. A guard that fires only after the damage is not the
# same guard, it is a post-mortem.
#
# This is deliberately NOT the machine-id check. That one needs an ssh channel,
# and at PLAN time there is no key and no pairing yet -- requiring one would
# mean the plan could not run until after the thing it is meant to prevent.
# Asking "is this address mine?" needs no peer at all, and for SELF-detection a
# local fact is not standing in for a remote one: if the address is on one of my
# interfaces, it IS me. Sound, not complete -- an address that reaches this host
# by NAT or an alias still gets through here, and validate_remote_host remains
# the backstop for exactly that. The point is to catch the ordinary mistake at
# the moment it is typed rather than three commands later.
#
# The engine's own check is not called and not duplicated: this asks a different
# question by a different means, so there is no second copy to drift.
rux_refuse_self_source() {   # <host> <original --source string>
    local host="$1" src="$2" a
    local -a mine=()
    # -o keeps one address per line; the `addr` field is 'A.B.C.D/len'.
    while read -r a; do [ -n "$a" ] && mine+=("${a%%/*}"); done < <(
        ip -o addr show scope global 2>/dev/null | awk '{print $4}'
    )
    mine+=(127.0.0.1 ::1 localhost)
    [ -n "$(hostname -s 2>/dev/null)" ] && mine+=("$(hostname -s)")
    [ -n "$(hostname -f 2>/dev/null)" ] && mine+=("$(hostname -f)")
    for a in "${mine[@]}"; do
        [ "$host" = "$a" ] || continue
        die "rux: --source='$src' names THIS host ('$host' is $(hostname -s 2>/dev/null || echo 'one of our own addresses')).

A relationship replicates between two machines. Pointed at itself it would
create an account, a key pair and cron lines here, and only fail at the first
real job -- when the engine's own loopback check finally sees it.

If you meant a backup that stays on this machine, that is the local form and it
needs no peer at all:
    zfs-backup.sh --source=<dataset> --target=<dataset> [--install]
Nothing was created."
    done
}

rux_entry() {
    local source="" a
    for a in "$@"; do
        case "$a" in --source=*) source="${a#*=}" ;; esac
    done
    if ! rux_is_remote_source "${source:-}"; then
        cmd_local_backup "$@"
        return $?
    fi

    local target="" mode="" profile="" port="" name="" local_user=""
    local do_install=0 assume_yes=0 verbose=0 grant_remotely=0 manual_join=0
    # The transfer SHAPE for a solid scope root. Same vocabulary the engines
    # already use for --recursive, deliberately: flat = per-dataset -R (the
    # default this layer has always emitted), atomic = one -r stream for the
    # whole subtree. Before this, `atomic` existed in the engines and in the
    # config grammar but no command could produce it -- reaching it meant hand
    # editing a generated config, and the first re-activation wrote the edit
    # back out. A mode the product cannot install is a mode nobody can operate.
    local recursion="" passive=0 exclude_family=""
    local -a excludes=()
    for a in "$@"; do
        case "$a" in
            --source=*)  : ;;
            --target=*)  target="${a#*=}" ;;
            --mode=*)    mode="${a#*=}" ;;
            --recursive=*) recursion="${a#*=}" ;;
            --passive)     passive=1 ;;
            --exclude-family=*) exclude_family="${a#*=}" ;;
            --exclude-child=*) excludes+=("${a#*=}") ;;
            --profile=*) profile="${a#*=}" ;;
            --port=*)    port="${a#*=}" ;;
            --name=*)    name="${a#*=}" ;;
            --local-user=*) local_user="${a#*=}" ;;
            --grant-remotely) grant_remotely=1 ;;
            --manual-join) manual_join=1 ;;
            --install)   do_install=1 ;;
            --plan)      do_install=0 ;;
            --yes|-y)    assume_yes=1 ;;
            --verbose)   verbose=1 ;;
            *) die "rux: unknown option $a" ;;
        esac
    done

    local host dataset
    IFS=$'\t' read -r host dataset < <(rux_split_source "$source")
    # Deferred scope: --source=HOST: (no dataset). The source proposes its own
    # datasets at pair time and the operator picks. Backup-mode only -- sync
    # reproduces a NAMED source path, so it must be told which one.
    local deferred=0; [ -z "$dataset" ] && deferred=1

    rux_refuse_self_source "$host" "$source"

    if [ -n "$mode" ] && [ "$mode" != sync ]; then
        die "rux: --mode must be 'sync' for a remote source (the ordinary backup case needs no --mode at all)"
    fi
    if [ "$deferred" -eq 1 ] && [ "$mode" = sync ]; then
        die "rux: --source=HOST: (deferred scope) is backup-mode only -- name the dataset as --source=HOST:DATASET for a sync relationship"
    fi
    if [ "$mode" = sync ] && [ -n "$target" ]; then
        die "rux: --mode=sync reproduces the source path at the same path on this host -- do not also pass --target"
    fi
    # --target is required only for an EXPLICIT backup dataset. Deferred scope
    # leaves it optional (proposed at pick time), like the local backup form.
    if [ "$mode" != sync ] && [ "$deferred" -eq 0 ] && [ -z "$target" ]; then
        die "rux: --target=DATASET is required for a backup-mode remote source (or pass --mode=sync to reproduce the source path)"
    fi

    if [ "$do_install" -eq 1 ]; then
        rux_remote_install "$host" "$port" "$dataset" "$target" "$mode" "$profile" "$assume_yes" "$verbose" "$name" "$local_user" "$grant_remotely" "$manual_join"
    else
        [ "$grant_remotely" -eq 1 ] && log "rux: --grant-remotely is noted, but --plan is read-only -- nothing is granted without --install"
        rux_remote_plan "$host" "$port" "$dataset" "$target" "$mode" "$profile" "$name"
    fi
}

# ------------------------------------------------------------------------------
# Guarded (same idiom as update-control.sh) so test/zfsbackup/run.sh can
# `source` this file to reach the pure helper functions without also running
# the dispatch below. A real invocation always has BASH_SOURCE[0]==$0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        setup-server)     shift; cmd_setup_server "$@" ;;
        # REV-20260810-097 F3: the canonical public entrypoint is the bare
        # high-level form `zfs-backup.sh --source=X --target=Y` (ACTIVE-WORK-PLAN
        # Phase 5). RUX (docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md)
        # extends the SAME form to a remote source (--source=HOST:DATASET):
        # rux_entry decides local vs remote before either entrypoint sees the
        # arguments, so a local --source is still byte-for-byte cmd_local_backup.
        # `local-backup` stays a LOCAL-only internal alias, unchanged.
        --source=*|--target=*) rux_entry "$@" ;;
        --version) echo "zfs-backup.sh (zfs-snapshot-all) $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"; exit 0 ;;
        local-backup)     shift; cmd_local_backup "$@" ;;
        add-replica)      shift; cmd_add_replica "$@" ;;
        list-replicas)    shift; cmd_list_replicas "$@" ;;
        remove-replica)   shift; cmd_remove_replica "$@" ;;
        run-replicas)     shift; cmd_run_replicas "$@" ;;
        install-media-trigger) shift; cmd_install_media_trigger "$@" ;;
        remove-media-trigger)  shift; cmd_remove_media_trigger "$@" ;;
        # Forwarded, not implemented: restore lives in zfs-restore.sh since the
        # 2026-08-17 split -- it is the one operation whose active side writes
        # onto production, so it is not this file's code. Both spellings work
        # and behave identically; exec so exit codes pass through untouched.
        restore)
            # THE CONNECTION IS RESOLVED HERE, where the paths are already known.
            #
            # A restore under push writes onto the machine being recovered, so it
            # opens ssh to it -- with that relationship's key, its known_hosts and
            # its port. This file owns those paths (load_client_and_connection);
            # zfs-restore.sh deriving them a second time would be two answers to
            # "which key reaches which host", and being wrong there aims a
            # recovery at the wrong machine.
            #
            # Best-effort and silent on failure: a LOCAL restore needs no
            # connection, `--plan` opens none, and an unresolvable relationship
            # is refused by zfs-restore.sh with a better message than anything
            # this dispatch could produce before it has parsed the arguments.
            shift
            # WHICH RELATIONSHIP'S CONNECTION: the one being WRITTEN TO, which is
            # not always the one being read from.
            #
            # `restore A:ds B:ds` recovers relation A's copy onto relation B's
            # machine (owner grammar, 2026-08-13). The copy is local to this
            # collector and opens no connection; the ssh goes to B. So when there
            # is a second address, it decides the key, the known_hosts and the
            # port -- not the first.
            #
            # FOUND BY THE PROPERTY, NOT BY THE GRAMMAR. The first version of
            # this walked the arguments counting bare words, which is a second
            # opinion about the grammar living outside the parser that owns it --
            # and it was wrong immediately: the split form `--at 2026-08-10
            # 12:00` puts a bare word in the argument list that is a TIME, not an
            # address.
            #
            # So it asks the only question this dispatch actually cares about:
            # is there a readable client record under this word? A time is not.
            # A dataset path is not. A relation label is. The LAST such word wins,
            # which is the destination when there are two and the source when
            # there is one -- today's behaviour, unchanged, for every existing
            # form.
            #
            # zfs-restore.sh remains the only place that decides what the words
            # MEAN. If this picks a connection the parser then disagrees with,
            # the failure is a refused ssh against a named host, not a silent
            # recovery aimed somewhere else.
            # NOT `local`: this dispatch is at top level, not inside a
            # function, and bash refuses `local` there -- "can only be used in a
            # function", printed on every restore run. It did not break the
            # connection resolution (the assignments below still happened), so
            # the only symptom was a line of noise in front of a recovery, which
            # is exactly where noise costs the most.
            _rc_conn=""; _rc_a=""
            for _rc_a in "$@"; do
                case "$_rc_a" in
                    -*) continue ;;
                esac
                [ -r "$CLIENTS_DIR/${_rc_a%%:*}.conf" ] && _rc_conn="$_rc_a"
            done
            if [ -n "$_rc_conn" ]; then
                if load_client_and_connection "$CLIENTS_DIR/${_rc_conn%%:*}.conf" >/dev/null 2>&1; then
                    # The same pinning the engines get, spelled as raw ssh
                    # flags because zfs-restore.sh calls ssh directly rather than
                    # through an engine -- and BUILT BY THE ONE BUILDER, not by
                    # a second hand-written copy of the same option set.
                    #
                    # This WAS a hand-written string, and it shipped without
                    # ConnectTimeout or ServerAlive* -- so a restore aimed at a
                    # peer that never answers the SYN would have sat ~130s per
                    # call, which is the hang this estate already paid for
                    # (#44/#45/#46) and built a counting assertion against.
                    # test/zfsbackup counts those options against the BatchMode
                    # groups, and that count is what caught it.
                    #
                    # Adding the three missing options would have fixed the
                    # instance. Using load_ssh_opts removes the class: there is
                    # one place that decides how this host reaches a peer, every
                    # other caller already uses it, and a fourth opinion about
                    # ssh flags cannot drift from the other three if it does not
                    # exist.
                    #
                    # Joined with "*" rather than passed as an array because it
                    # crosses an exec boundary into zfs-restore.sh, which
                    # word-splits it back -- see that file's own note on why
                    # that is safe here (these are flags and paths, and neither
                    # carries a space by this installer's own rules).
                    load_ssh_opts
                    RESTORE_SSH_OPTS="${LOAD_SSH_OPTS[*]}"
                    # The engine speaks its OWN flags for the same pinning
                    # (-K/-k/-O), not raw ssh flags. Both forms are exported from
                    # the one place that knows the paths, so they cannot disagree
                    # about which key reaches which host.
                    RESTORE_ENGINE_SSH="-K ${LOAD_KEYFILE:-} -k ${LOAD_ALIAS_KH:-} -O HostKeyAlias=${LOAD_ALIAS:-} -O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no"
                    [ -n "${LOAD_PORT:-}" ] && RESTORE_ENGINE_SSH="$RESTORE_ENGINE_SSH -p $LOAD_PORT"
                    # AND WHO IT IS. A destination relationship only has to be
                    # PAIRED, not activated: it contributes a machine to write
                    # to, and that is in its client record, not in the config.
                    #
                    # Reading it from the config instead would force the twin to
                    # be activated first -- and an activated twin owns its own
                    # (empty) copy sections, so after move-to-client it would own
                    # two sets: the real copy it took over and the empty one it
                    # was born with, both pulling the same source into different
                    # places. Found by walking the lab setup on paper before
                    # running it.
                    RESTORE_DEST_PEER="${LOAD_ACCOUNT:-}@${LOAD_HOST:-}"
                    [ "$RESTORE_DEST_PEER" = "@" ] && RESTORE_DEST_PEER=""
                    export RESTORE_SSH_OPTS RESTORE_ENGINE_SSH RESTORE_DEST_PEER
                fi
            fi
            exec bash "$SCRIPT_DIR/zfs-restore.sh" "$@" ;;
        add-client)       shift; cmd_add_client "$@" ;;
        seed)             shift; cmd_seed "$@" ;;
        activate)         shift; cmd_activate "$@" ;;
        final-catchup)    shift; cmd_final_catchup "$@" ;;
        set-endpoint)     shift; cmd_set_endpoint "$@" ;;
        verify-endpoint)  shift; cmd_verify_endpoint "$@" ;;
        activate-client)  shift; cmd_activate_client "$@" ;;
        migrate-profile)  shift; cmd_migrate_profile "$@" ;;
        set-bandwidth)    shift; cmd_set_bandwidth "$@" ;;
        audit-source-retention) shift; cmd_audit_source_retention "$@" ;;
        pause-client)     shift; cmd_pause_client "$@" ;;
        move-to-client)   shift; cmd_move_to_client "$@" ;;
        resume-client)    shift; cmd_resume_client "$@" ;;
        disable-client)   shift; cmd_disable_client "$@" ;;
        enable-client)    shift; cmd_enable_client "$@" ;;
        status)           shift; cmd_status "$@" ;;
        progress)         shift; cmd_progress "$@" ;;
        test)             shift; cmd_test "$@" ;;
        remove-client)    shift; cmd_remove_client "$@" ;;
        -h|--help|"")     usage; exit 0 ;;
        *) echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
    esac
fi
