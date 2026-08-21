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
PROFILE_ROOT="${PROFILE_ROOT:-$SCRIPT_DIR/profiles}"
PROFILE_ACTIVE="${PROFILE_ACTIVE:-default}"

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
CLIENTS_DIR="/etc/zfs-snapshot-all/clients"
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
CATCHUP_MAX_AGE="${CATCHUP_MAX_AGE:-1800}"

log()  { echo ">>> $*"; }
# warn/die live in lib-backup-common.sh since the restore split.

usage() {
    cat <<'EOF'
zfs-backup.sh -- simple two-host backup deploy (pve1=appliance, pve2=source)

Usage:
  zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE] [--local-user=NAME]
  zfs-backup.sh --source=DATASET [--target=DATASET] [--profile=NAME] [--config=FILE]
                [--local-user=NAME] [--install] [--yes|-y]
                                    LOCAL backup ('local-backup ...' is an alias).
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
Explicit two-host lifecycle (the one-command --source= forms above wrap this):
  zfs-backup.sh add-client NAME --host=HOST[:PORT] [--target=X] [--bandwidth=N] [--profile=NAME]
                                    Default: backup mode; source datasets are discovered
                                    and accepted by deploy.sh --join on the source host.
                                    --lan, --mode and --datasets remain expert options.
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
  zfs-backup.sh disable-client NAME [--reason=TEXT]
  zfs-backup.sh enable-client NAME

Config maintenance:
  zfs-backup.sh migrate-profile [--yes]
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
RELATIONSHIPS_DIR="/var/lib/zfs-snapshot-all/relationships"
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
    if [ "$port" != "22" ]; then
        printf '[%s]:%s %s\n' "$alias" "$port" "$rest" > "$dst" || return 1
    else
        printf '%s %s\n' "$alias" "$rest" > "$dst" || return 1
    fi
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
        out=$(ssh "${opts[@]}" "${account}@${host}" "zfs allow '$path'" 2>&1)
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
        out=$(ssh "${opts[@]}" "${account}@${host}" "zfs allow -- '$ds'" 2>&1); rc=$?
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
    for f in "$PROFILE_TPL_FILE" "$PROFILE_DS_FILE" "$PROFILE_PRUNE_FILE"; do
        [ -n "$f" ] || continue
        rm -f "$f" 2>/dev/null
        [ -e "$f" ] && left="$left $f"
    done
    PROFILE_TPL_FILE=""; PROFILE_DS_FILE=""; PROFILE_PRUNE_FILE=""; PROFILE_LOADED=""
    if [ -n "$left" ]; then
        warn "could not remove the rendered profile file(s):$left -- they are still in place"
        return 1
    fi
    return 0
}

# The EXIT trap preserves the status the shell was already exiting with: the
# leak is a scratch-file problem, not a verdict on the run.
_profile_release_on_exit() { local rc=$?; profile_release_tmp; return "$rc"; }

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
    local dir="$PROFILE_ROOT/$PROFILE_ACTIVE"
    # Validate before rendering. A profile that carries relationship-owned
    # fields must never reach a config, and finding that out from gen-cron
    # afterwards would mean it already had.
    profile_validate_dir "$dir" "$GENCRON" || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    # Arm BEFORE the first allocation, not after the last. Arming afterwards
    # left a window in which allocation 2 or 3 could fail, `die` could exit, and
    # everything already allocated survived with no trap to reach it -- measured:
    # failing the second render allocation left the first file behind. The
    # handler skips empty variables, so arming this early costs nothing and
    # covers every failure path without one release call per path.
    _profile_arm_release
    PROFILE_TPL_FILE=$(mktemp)   || die "mktemp failed"
    PROFILE_DS_FILE=$(mktemp)    || die "mktemp failed"
    PROFILE_PRUNE_FILE=$(mktemp) || die "mktemp failed"
    profile_render_templates "$dir" "$PROFILE_ACTIVE" "$PROFILE_TPL_FILE"         || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    profile_render_fragment "$dir/dataset.inc" "$PROFILE_ACTIVE" "$PROFILE_DS_FILE"         || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    profile_render_fragment "$dir/prune.inc" "$PROFILE_ACTIVE" "$PROFILE_PRUNE_FILE"         || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
    PROFILE_LOADED=1
    return 0
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
# What the RELATIONSHIP owns -- recursive on a prune scope, pair_label, notify,
# src -- is still written by the caller and cannot collide, because
# lib-profile.sh refuses those fields inside a profile.
profile_emit() {   # <rendered fragment>
    local raw
    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw%$'\r'}"
        [ -z "${raw//[[:space:]]/}" ] && continue
        case "$raw" in '#'*) continue ;; esac
        printf '\t%s\n' "${raw#"${raw%%[![:space:]]*}"}"
    done < "$1"
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
emit_source_template_family() {   # <rendered prune fragment>
    local id src section
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        section="$(profile_template_section "$id")"
        [ -n "$section" ] || die "local-backup source-retention: profile '$PROFILE_ACTIVE' references prune template '$id' but no rendered [template:$id] exists -- refusing to emit a SOURCE retention that would silently reuse the TARGET's template authority (REV-20260811-106)"
        src="$(profile_to_src_id "$id")"
        printf '[template:%s]\n' "$src"
        printf '%s\n' "$section" | tail -n +2
        echo
    done < <(profile_prune_ref_ids "$1")
}

# The SOURCE prune fragment: the normalized prune fragment with each use_template
# identity rewritten to its source identity (exact, comma-list aware -- never a
# substring rewrite that could couple ids sharing a prefix).
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
        { printf '\n[template:%s]\n' "$src"
          printf '%s\n' "$sec" | tail -n +2 | sed -E '/^[[:space:]]*monitor_(warn|crit)[[:space:]]*=/d'
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
append_source_prune_create() {   # <workfile> <name> <marker> <scope> <sflags> <ds>
    local wf="$1" name="$2" marker="$3" scope="$4" sflags="$5" ds="$6"
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
        emit_source_prune_fragment "$PROFILE_PRUNE_FILE"
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
emit_remote_source_prune() {   # <workfile> <name> <marker> <source-ds...>
    local workfile="$1" name="$2" marker="$3"; shift 3
    [ "$#" -gt 0 ] || return 0
    [ "${PROFILE_GFS:-1}" -eq 1 ] || return 0
    # Pure config text -- no SSH here. The fail-closed grant check
    # (assert_source_prune_grant) runs in the FLOW, before the workfile is
    # published, so the two callers gate the INSTALL and this stays unit-testable
    # without a live host.
    append_source_templates_if_missing "$workfile" "$PROFILE_PRUNE_FILE"
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
            append_source_prune_create "$workfile" "$name" "$marker" "$scope" "$sflags" "$ds" || return 1
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
    [ "${PROFILE_GFS:-1}" -eq 1 ] || return 0
    local marker="# managed-by: zfs-backup.sh client=$name"
    append_source_templates_if_missing "$workfile" "$PROFILE_PRUNE_FILE"
    local sflags; sflags="$(source_prune_sflags)"
    local scope ds
    for scope in "$@"; do
        ds="${scope##*:}"
        append_source_prune_create "$workfile" "$name" "$marker" "$scope" "$sflags" "$ds" || return 1
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
installed_dataset_is_passive() {   # <cronfile> <local dataset path>
    local flags; flags="$(installed_dataset_field "$1" "$2" flags)"
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
detect_profile_gfs() {   # <file> -> sets PROFILE_GFS
    PROFILE_GFS=1
    if grep -q "^\[template:standard_hourly\]" "$1" 2>/dev/null; then
        if sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$1" | grep -q "prune_schedule"; then
            PROFILE_GFS=0
        fi
    fi
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
    if [ "$needs_profile" -eq 1 ] && [ "$PROFILE_GFS" -eq 0 ]; then
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
    local prefix
    local install_floors=0
    if [ "$needs_profile" -eq 1 ]; then
        case "$global_policy_mode" in
            always) install_floors=1 ;;
            *)      config_has_relationship_policy "$file" || install_floors=1 ;;
        esac
    fi
    if [ "$install_floors" -eq 1 ]; then
        for prefix in "__replicate_" "vzdump" "__migration__"; do
            grep -qF "[excluded:$prefix]" "$file" 2>/dev/null && continue
            {
                echo
                echo "[excluded:$prefix]"
                echo "	keep = 2"
            } >> "$file" || die "could not append [excluded:$prefix] to $file"
            log "added missing reserved-prefix protection [excluded:$prefix] (keep=2) to $file"
        done
    elif [ "$needs_profile" -eq 1 ]; then
        # Inheriting the installed policy is the correct action, but doing it
        # silently is not: the new relationship is about to get a prune sweep
        # that runs WITHOUT a protection this estate normally carries, and the
        # operator should learn that here rather than from a missing pvesr or
        # vzdump snapshot later. A warning is neither a mutation nor a refusal,
        # and activate-client shows its full proposal before installing.
        local missing=""
        for prefix in "__replicate_" "vzdump" "__migration__"; do
            grep -qF "[excluded:$prefix]" "$file" 2>/dev/null || missing="$missing $prefix"
        done
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
endpoint_normalized_identity() {
    sed -E 's/(-A "[^@"]+@)[^:"]+:/\1<ENDPOINT>:/'
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
        local pds
        for pds in $PEER_SAVED_DATASETS; do
            if load_ssh_opts; ssh "${LOAD_SSH_OPTS[@]}" \
                   "${LOAD_ACCOUNT}@${LOAD_HOST}" "zfs list -H -t snapshot -d 1 -o name -- '$pds'" 2>/dev/null \
                 | grep -q '@automated_'; then
                passive_ds+=("$pds")
                log "sync: '$pds' already carries an automated_* family on $LOAD_HOST -- PASSIVE consumption (snapget -e): no new snapshots on the source, no source prune, retention stays with the family's owner"
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
        update_section_field "$workfile" "[dataset:$localpath]" flags "$LOAD_FLAGS" \
            || die "[dataset:$localpath] in $workfile has no 'flags' field to refresh -- refusing to leave the relationship carrying stale transport flags. Fix or remove that section by hand and re-run."
    done

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
            else
                echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
                echo "	flags        = $LOAD_FLAGS"
            fi
            # A solid scope root rides ENGINE recursion: snapget -R re-expands
            # the subtree on the source at every run, so a child created there
            # tomorrow joins at the next cron tick -- which is what the signed
            # include_children=yes means over time. Dataset-level field, so it
            # wins over any template default (and the profile fragment
            # deliberately carries no 'recursive' of its own).
            if is_recursive_root "$ds"; then
                echo "	recursive    = flat"
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
    emit_remote_source_prune "$workfile" "$name" "$marker" ${prune_src[@]+"${prune_src[@]}"} || return 1
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
    local realfile="$1" workfile="$2"
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

# config_section_overlap FILE PATH... -> prints one line per existing
# [dataset:]/[prune:] section in FILE whose scope overlaps a requested PATH.
# path_overlaps is the same containment test the pull coverage guard uses. Empty
# output means the requested job is disjoint from every job already in the file.
config_section_overlap() {   # <file> <path>...
    local file="$1"; shift
    [ -f "$file" ] || return 0
    local hdr scope member req
    while IFS= read -r hdr; do
        scope="${hdr#\[}"; scope="${scope%\]}"; scope="${scope#*:}"
        # REV-20260811-098: a section scope may name SEVERAL datasets comma-
        # separated ([prune:a,b,c] -- metropolis pve2 has such sections), so
        # evaluate each member independently, using the same comma split and
        # whitespace trim config_datasets() applies. Treating the whole
        # comma-joined string as one path would miss an overlap with any member
        # but the accidental prefix, letting the planner accept a job installed
        # policy already covers.
        while IFS= read -r member; do
            [ -n "$member" ] || continue
            for req in "$@"; do
                path_overlaps "$member" "$req" \
                    && printf '\n  %s (%s) overlaps requested %s' "$hdr" "$member" "$req"
            done
        done < <(dataset_list_split "$scope")
    done < <(grep -oE '^\[(dataset|prune):[^]]+\]' "$file")
    return 0
}

cmd_local_backup() {
    local target="" profile="default" config=""
    # Slice 2: plan stays the DEFAULT. An operator who ran slice 1's command
    # yesterday gets byte-identical behaviour today; installing is an explicit verb.
    local do_install=0 assume_yes=0
    local local_user="" local_user_given=0 resolver_user=""
    local -a source_flags=()
    for a in "$@"; do
        case "$a" in
            --source=*)  source_flags+=("${a#*=}") ;;
            --target=*)  target="${a#*=}" ;;
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
    [ "${#source_flags[@]}" -gt 0 ] || die "local-backup: --source=<dataset>[,<dataset>...] is required (the dataset(s) to back up)"

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
    if [ -z "$target" ]; then
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

    case "$target" in *[!A-Za-z0-9_./:-]*|/*|*/) die "local-backup: --target='$target' is not a plain dataset name" ;; esac
    case "$target" in *:*) die "local-backup is LOCAL only -- --target='$target' names a remote host (contains ':'). Use add-client/activate-client for a remote pull." ;; esac
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
    for r in "${roots[@]}"; do
        local_backup_overlap "$r" "$target" \
            && die "local-backup: --target='$target' overlaps source '$r' (equal, or one nested in the other) -- a backup cannot land inside the thing it backs up."
    done
    local i j
    for ((i=0; i<${#roots[@]}; i++)); do
        for ((j=i+1; j<${#roots[@]}; j++)); do
            local_backup_overlap "${roots[i]}" "${roots[j]}" \
                && die "local-backup: sources '${roots[i]}' and '${roots[j]}' overlap (equal or parent/child) -- refusing; the high-level path will not invent precedence between overlapping roots."
        done
    done

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

    # Choose the preset. load_active_profile calls profile_validate_dir, which
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

    # Refuse when any root OR the target overlaps a section already installed --
    # "add B, do not mutate A" (Gate 2). Nothing is written on refusal.
    local conflict; conflict="$(config_section_overlap "$cand" ${roots[@]+"${roots[@]}"} "$target")"
    if [ -n "$conflict" ]; then
        rm -f "$cand"
        die "local-backup: a job for these sources / target '$target' would overlap coverage already in $config:$conflict
Nothing has been changed. Two jobs covering the same datasets would send and prune the same snapshots under different policy. If the overlap is intended, express it in native CONFIG v4 by hand; the high-level path deliberately will not."
    fi

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
    {
        for r in "${roots[@]}"; do
            echo
            echo "[dataset:$r]"
            echo "	# managed-by: zfs-backup.sh local-backup source=$r"
            profile_emit "$PROFILE_DS_FILE"
            echo "	dst          = $target"
            echo "	notify       = local-$(basename "$r")"
        done
        if [ "${PROFILE_GFS:-1}" -eq 1 ]; then
            # REV-20260811-104 F1: SOURCE and TARGET retention must be independently
            # editable after CREATE, not two scopes sharing one template authority.
            # ensure_cron_config already put the target's prune templates in the
            # candidate; here we emit a DISTINCT source family, byte-copied from the
            # same values but under its own stable identity, so editing a source
            # retain in the candidate changes only the source cron line and target
            # retain only the target. REV-20260811-106 F1: the family is derived from
            # the templates the profile's prune fragment ACTUALLY references, not
            # from a `keep_*` naming convention, and fails closed if one is missing.
            emit_source_template_family "$PROFILE_PRUNE_FILE"
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
                emit_source_prune_fragment "$PROFILE_PRUNE_FILE"
                echo "	notify       = local-src-$(basename "$r")"
            done
            echo
            echo "[prune:$target]"
            echo "	# managed-by: zfs-backup.sh local-backup target=$target"
            profile_emit "$PROFILE_PRUNE_FILE"
            echo "	recursive    = yes"
            echo "	notify       = local-$(basename "$target")"
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

    if [ "$assume_yes" -ne 1 ]; then
        local ans
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
    [ -n "$profile" ] || profile="default"
    profile_validate_dir "$PROFILE_ROOT/$profile" "$GENCRON" \
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
        local _bw_core="$bandwidth"
        case "$_bw_core" in *[bkKmMgG]) _bw_core="${_bw_core%?}" ;; esac
        case "$_bw_core" in
            "" | *[!0-9]*)
                die "add-client: --bandwidth='$bandwidth' is not a byte rate the engines accept (digits, then at most one of b/k/M/G at the end -- e.g. 20M). It is BYTES per second, not bits." ;;
        esac
    fi

    local cpath; cpath=$(client_conf_path "$name")
    [ -e "$cpath" ] && die "client '$name' already exists ($cpath) -- use seed/activate-client/remove-client"

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
    else
        pair_args+=(--peer-datasets="$datasets")
    fi
    [ -n "$target" ] && pair_args+=(--target="$target")
    [ "$lan_port" != "22" ] && pair_args+=(--port="$lan_port")
    # Without this the pairing key and the pinned host key are readable only by
    # root, and the target root is delegated to nobody -- so the cron jobs this
    # client will run as $LOCAL_USER could not open their own key.
    # root is expressed to deploy.sh by OMITTING the flag, its existing contract.
    # Both an explicit 'root' AND an empty local_user (no --local-user given at
    # all -- the new default) mean exactly that: run as root, delegate nothing.
    # Only a real account name is passed through.
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
        write_client_field BANDWIDTH         "$bandwidth"
        write_client_field PROFILE           "$profile"
        write_client_field CREATED_AT        "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$cpath" || die "could not write $cpath"
    chmod 0600 "$cpath"

    log "client '$name' created, state=pending_enroll, profile=$profile"
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
    if ! ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$sfile_remote'" > "$outfile" 2>/dev/null \
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
    if ! ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$hfile_remote'" > "$hash_tmp" 2>/dev/null \
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

has_committed_scope() {
    local -a ssh_opts; load_ssh_opts; ssh_opts=("${LOAD_SSH_OPTS[@]}")
    ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" \
        "test -s '$(peer_scope_granted_hash_path "$COLLECTOR_LABEL")'" >/dev/null 2>&1
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
        has_committed_scope || return 0
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
    for root in "${SCOPE_ROOTS[@]}"; do
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
        done < <(ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "zfs list -H -o name -r -- '$root'" 2>/dev/null)
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
    # shellcheck disable=SC1090
    . "$cpath"
    local label; label=$(peer_label "$PEER_HOST")
    LOAD_LABEL="$label"
    local mpath; mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$PEER_HOST' at $mpath -- run add-client first"
    # shellcheck disable=SC1090
    . "$mpath"

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
    # -b caps the receive-side mbuffer. It rides in the same flags string as the
    # ssh options because it is per-CLIENT, not per-host: the whole point is
    # that a peer at the end of a slow VPN gets a ceiling while a LAN peer on
    # the same collector does not.
    [ -n "${BANDWIDTH:-}" ] && LOAD_FLAGS="$LOAD_FLAGS -b $BANDWIDTH"

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
        if bash "$SNAPGET" -m automated_daily_ $(is_recursive_root "$ds" && printf %s -R) $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
        if bash "$SNAPGET" -m automated_daily_ $(is_recursive_root "$ds" && printf %s -R) $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
    [ -n "${BANDWIDTH:-}" ] && pflags="$pflags -b $BANDWIDTH"

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
            PLAN=INCREMENTAL*) ;;
            PLAN=FULL*)
                needs_full=$((needs_full + 1))
                PROBE_DETAIL="${PROBE_DETAIL}  $ds would need a FULL transfer -- no common base"$'\n' ;;
            *)
                unknown=$((unknown + 1))
                PROBE_DETAIL="${PROBE_DETAIL}  $ds: no PLAN= verdict (got: ${plan:-<none>})"$'\n' ;;
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

    load_client_and_connection "$cpath"
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
            local newest
            newest=$(load_ssh_opts; ssh "${LOAD_SSH_OPTS[@]}" \
                "${LOAD_ACCOUNT}@${LOAD_HOST}" \
                "zfs list -H -t snapshot -d 1 -o name,creation -p -- '$ds' 2>/dev/null | grep '@${dr_prefix:-automated_}' | sort -k2,2n | tail -1 | cut -f1")
            if [ -n "$newest" ]; then
                log "  OK (passive): $ds -> $localpath -- newest family snapshot reachable: ${newest#*@}"
            else
                warn "  FAILED (passive): $ds -> $localpath -- no '${dr_prefix:-automated_}*' snapshot reachable on $LOAD_HOST via the pairing channel"
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
        if bash "$SNAPGET" "${dr_args[@]}" $LOAD_FLAGS "$@"; then
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
    peer_tz=$(load_ssh_opts; ssh "${LOAD_SSH_OPTS[@]}" \
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
# migrate-profile: take a host off the pre-GFS profile, in one decision.
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
cmd_migrate_profile() {   # [--config=PATH] [--local-user=NAME] [--yes]
    local yes=0 a config_arg="" local_user_arg=""
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
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

    if ! sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$cronfile" | grep -q "prune_schedule"; then
        log "$cronfile is already on the standard GFS profile -- nothing to migrate."
        return 0
    fi

    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX")         || die "mktemp failed next to $cronfile"
    # mktemp makes 0600. The preview and the install both read this file AS the
    # collector account, so it has to be readable by it -- and the mode has to
    # be right BEFORE either of them runs, not after the swap.
    chmod 0644 "$workfile" || { rm -f "$workfile"; die "could not set the mode on $workfile"; }
    cp -p "$cronfile" "$workfile" || { rm -f "$workfile"; die "could not copy $cronfile"; }
    chmod 0644 "$workfile" 2>/dev/null || :

    # Drop every legacy send template, then let ensure_cron_config put the new
    # families back. Removing them is what makes this a migration rather than an
    # append: the old standard_daily/weekly/monthly sections would otherwise sit
    # there defining schedules nothing references.
    local t
    for t in standard_hourly standard_daily standard_weekly standard_monthly; do
        remove_template_section "$workfile" "$t"
    done
    PROFILE_GFS=1
    # REV-20260810-092: 'always'. This is the explicit-migration boundary the
    # review carves out -- a previewed, confirmed transaction that shows the
    # exact config and cron diff first, and the one command that installs the
    # broad GFS ladder the reserved-prefix floors exist to fence.
    ensure_cron_config "$workfile" 0 1 always

    local f name migrated=0
    local -a managed=(); local prune_scope=""
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        ( : ) # no-op: keep shellcheck quiet about the subshell-free sourcing below
        # shellcheck disable=SC1090
        . "$f"
        [ "${STATE:-}" = active ] || { log "skipping client '${CLIENT_NAME:-$f}' (state=${STATE:-unknown}) -- only active clients have cron sections to rewrite"; continue; }
        name="$CLIENT_NAME"
        load_client_and_connection "$f"
        # REV-20260809-089: full generation, deliberately. Every other caller
        # must NOT re-derive installed policy from the active profile -- but
        # re-deriving it is the entire purpose of migrate-profile, which exists
        # precisely to move a host off the legacy profile in one decision. This
        # is the one call site where the profile is meant to win.
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

    log "validating the migrated config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the migrated config -- $cronfile was NOT touched (see output above)"
    fi

    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "could not render the migration preview -- nothing was touched"
    }

    echo "Migracja: plaska retencja per tier  ->  standardowa polityka GFS"
    echo "Klientow do przepisania: $migrated"
    echo
    if [ "$yes" -ne 1 ]; then
        read -rp "Zmigrowac ten host na standardowa polityke GFS? [t/N] " ans
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
    log "host migrated to the standard GFS profile ($migrated client(s) rewritten)."
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
    # Said out loud because the old wording ("managed jobs") was read as all of
    # them, and retention is managed too. Measured on metropolis 2026-08-20: a
    # paused relationship still ran both of its delsnaps lines, the one over the
    # SOURCE included. That is not a generator oversight -- the label becomes
    # snapget/snapsend/check-snap-age -L, and delsnaps.sh has no such flag at
    # all -- so the honest move is to name the gap rather than imply it away.
    log "NOT covered: retention. This relationship's delsnaps lines carry no '-L' and keep pruning on schedule, on the source as well as the target. The GFS ladder bounds what that can erode, so a pause measured in hours or days cannot cost you the common base; a pause left running for months could."
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
    ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "PAIR-CONTROL $verb"
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
    echo "Zrodla:            ${PEER_SAVED_DATASETS:-?}"
    echo "Cel:               ${MANAGED_DATASETS:-(jeszcze nie aktywowany)}"
    echo "Spojnosc:          ${QUIESCE_MODE:-crash-consistent (bez quiesce)}"
    echo "Utworzono:         ${CREATED_AT:-?}"
    [ -n "${SEED_COMPLETED_AT:-}" ]    && echo "Seed ukonczony:    $SEED_COMPLETED_AT"
    [ -n "${ENDPOINT_VERIFIED_AT:-}" ] && echo "Endpoint zweryf.:  $ENDPOINT_VERIFIED_AT (${ENDPOINT_VERIFIED_FOR:-?})"
    [ -n "${ACTIVATED_AT:-}" ]         && echo "Aktywowano:        $ACTIVATED_AT"
    [ -n "${REMOVED_AT:-}" ]           && echo "Usunieto:          $REMOVED_AT"
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
        if bash "$SNAPGET" -n $(is_recursive_root "$ds" && printf %s -R) $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
            local CLIENT_NAME="" PEER_HOST=""
            # shellcheck disable=SC1090
            . "$f"
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
    [ -n "$profile" ] || profile="default"

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
rux_root_ssh() {   # <host> <port> <command...>
    local host="$1" port="$2"; shift 2
    ssh -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
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
rux_grant_remotely_preflight() {   # <host> <port>
    local host="$1" port="$2"
    if ! rux_root_ssh "$host" "$port" "true" >/dev/null 2>&1; then
        die "--grant-remotely: no root ssh channel to $host (BatchMode, pinned /root/.ssh/known_hosts). Establish it first -- e.g. install this host's root key there: ssh-copy-id root@$host -- or drop --grant-remotely and run the grant on the source yourself: deploy.sh --commit-scope=$COLLECTOR_LABEL. Nothing was changed anywhere."
    fi
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
        log "--grant-remotely: $host already has a committed scope for '$COLLECTOR_LABEL' -- nothing to grant, the ordinary verification below decides whether it covers the request"
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
    } | rux_root_ssh "$host" "$port" "cat > '$sfile'" \
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
    local cpath; cpath=$(client_conf_path "$name")
    local state=""
    [ -e "$cpath" ] && state=$( . "$cpath"; echo "${STATE:-}" )

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
        rux_grant_remotely_preflight "$host" "$port"
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
        else
            # Deferred scope (empty dataset): pass NO --datasets, so add-client
            # leaves the dataset selection to the source's own scope draft at
            # pair time -- exactly what the retired `deploy` verb did. An explicit
            # dataset is named; --target stays optional either way (proposed).
            [ -n "$dataset" ] && add_args+=(--datasets="$dataset")
            [ -n "$target" ] && add_args+=(--target="$target")
        fi
        [ -n "$profile" ] && add_args+=(--profile="$profile")
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
    for a in "$@"; do
        case "$a" in
            --source=*)  : ;;
            --target=*)  target="${a#*=}" ;;
            --mode=*)    mode="${a#*=}" ;;
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
        # Forwarded, not implemented: restore lives in zfs-restore.sh since the
        # 2026-08-17 split -- it is the one operation whose active side writes
        # onto production, so it is not this file's code. Both spellings work
        # and behave identically; exec so exit codes pass through untouched.
        restore)          shift; exec bash "$SCRIPT_DIR/zfs-restore.sh" "$@" ;;
        add-client)       shift; cmd_add_client "$@" ;;
        seed)             shift; cmd_seed "$@" ;;
        activate)         shift; cmd_activate "$@" ;;
        final-catchup)    shift; cmd_final_catchup "$@" ;;
        set-endpoint)     shift; cmd_set_endpoint "$@" ;;
        verify-endpoint)  shift; cmd_verify_endpoint "$@" ;;
        activate-client)  shift; cmd_activate_client "$@" ;;
        migrate-profile)  shift; cmd_migrate_profile "$@" ;;
        audit-source-retention) shift; cmd_audit_source_retention "$@" ;;
        pause-client)     shift; cmd_pause_client "$@" ;;
        resume-client)    shift; cmd_resume_client "$@" ;;
        disable-client)   shift; cmd_disable_client "$@" ;;
        enable-client)    shift; cmd_enable_client "$@" ;;
        status)           shift; cmd_status "$@" ;;
        test)             shift; cmd_test "$@" ;;
        remove-client)    shift; cmd_remove_client "$@" ;;
        -h|--help|"")     usage; exit 0 ;;
        *) echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
    esac
fi
