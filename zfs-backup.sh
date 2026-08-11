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
# Commands:
#   zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE] [--local-user=NAME]
#   zfs-backup.sh add-client NAME --lan=HOST[:PORT] (--datasets="A B" | --mode=backup|sync) [--target=X] [--bandwidth=N] [--profile=NAME] [--join-remotely]
#   zfs-backup.sh seed NAME [--yes]
#   zfs-backup.sh set-endpoint NAME --host=HOST[:PORT]
#   zfs-backup.sh verify-endpoint NAME
#   zfs-backup.sh activate-client NAME [--yes] [--verbose]
#   zfs-backup.sh migrate-profile [--yes]
#   zfs-backup.sh audit-source-retention [--apply] [--yes]
#   zfs-backup.sh migrate-to-account ACCOUNT [--yes]
#   zfs-backup.sh status [NAME]
#   zfs-backup.sh test NAME
#   zfs-backup.sh remove-client NAME
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
GENCRON="$SCRIPT_DIR/gen-cron.sh"
LIBCRON="$SCRIPT_DIR/lib-cron.sh"
LIBSCOPE="$SCRIPT_DIR/lib-scope.sh"
LIBPROFILE="$SCRIPT_DIR/lib-profile.sh"
PROFILE_ROOT="${PROFILE_ROOT:-$SCRIPT_DIR/profiles}"
PROFILE_ACTIVE="${PROFILE_ACTIVE:-default}"

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

SERVER_CONF="/etc/zfs-snapshot-all/zfs-backup.conf"
CLIENTS_DIR="/etc/zfs-snapshot-all/clients"

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
warn() { echo "!!! $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
zfs-backup.sh -- simple two-host backup deploy (pve1=appliance, pve2=source)

Usage:
  zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE] [--local-user=NAME]
  zfs-backup.sh --source=DATASET --target=DATASET [--profile=NAME] [--config=FILE]  (LOCAL backup, plan/preview only; `local-backup ...` is an alias)
  zfs-backup.sh add-client NAME --lan=HOST[:PORT] (--datasets="A B" | --mode=backup|sync) [--target=X] [--bandwidth=N] [--profile=NAME] [--join-remotely]
  zfs-backup.sh seed NAME [--yes]
  zfs-backup.sh final-catchup NAME [--yes]
  zfs-backup.sh set-endpoint NAME --host=HOST[:PORT] [--skip-final-catchup] [--allow-stale-catchup]
  zfs-backup.sh verify-endpoint NAME
  zfs-backup.sh activate-client NAME [--yes] [--verbose]
  zfs-backup.sh migrate-profile [--yes]
  zfs-backup.sh audit-source-retention [--apply] [--yes]
  zfs-backup.sh migrate-to-account ACCOUNT [--yes]
  zfs-backup.sh pause-client NAME [--reason=TEXT]
  zfs-backup.sh resume-client NAME
  zfs-backup.sh disable-client NAME [--reason=TEXT]
  zfs-backup.sh enable-client NAME
  zfs-backup.sh status [NAME]
  zfs-backup.sh test NAME
  zfs-backup.sh remove-client NAME

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
    local -a opts=(-i "$keyfile" -p "$port" -o BatchMode=yes -o "HostKeyAlias=$alias" -o UserKnownHostsFile="$alias_kh" -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no)
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
# delegated identity holds exactly the `destroy` capability delsnaps.sh's plain
# `zfs destroy <snap>` needs on each source dataset. Re-derived from the command
# path, not a remembered grant: deploy.sh do_commit_scope already delegates
# `destroy` (ZFS_PERMS), so this WIDENS NOTHING -- it only refuses to install a
# remote prune whose authorization cannot be confirmed, rather than shipping an
# hourly job that fails or silently assuming the grant. Unlike check_inherited_grants
# (which WARNs), this DIES: a destructive job on a production source must not be
# installed on hope.
assert_source_prune_grant() {   # <account> <host> <port> <keyfile> <alias> <alias_kh> <source-dataset>...
    local account="$1" host="$2" port="$3" keyfile="$4" alias="$5" alias_kh="$6"; shift 6
    local -a opts=(-i "$keyfile" -p "$port" -o BatchMode=yes -o "HostKeyAlias=$alias" \
        -o UserKnownHostsFile="$alias_kh" -o StrictHostKeyChecking=yes \
        -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no)
    local ds out rc
    for ds in "$@"; do
        out=$(ssh "${opts[@]}" "${account}@${host}" "zfs allow -- '$ds'" 2>&1); rc=$?
        [ "$rc" -eq 0 ] || die "source-prune grant check: 'zfs allow $ds' on $host as $account failed (ssh/zfs exit $rc) -- refusing to install a remote source prune whose authorization cannot be confirmed. Output: $(printf '%s' "$out" | tail -2)"
        # The account's own permission line carries a comma-list of perms; `destroy`
        # is bounded by commas/space so grep -w matches it inside snapshot,destroy,send.
        if ! printf '%s\n' "$out" | grep -F -- "$account" | grep -qw destroy; then
            die "source-prune grant check FAILED CLOSED: the delegated identity '$account' does not hold 'destroy' on the source '$ds' (needed by delsnaps.sh's zfs destroy). The pairing already grants destroy via deploy.sh --commit-scope; re-run --commit-scope on $host if it is missing. Refusing to install a source-prune job that would fail every run -- and NOT widening the grant here."
        fi
    done
}

read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    LOCAL_USER=""
    [ -r "$SERVER_CONF" ] || return 0
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
}

# The 'standard' profile's four templates, values approved by the owner
# 2026-07-30: retain -H24/-D7/-W4/-M12. Daily/weekly/monthly send_schedule is
# midnight. No quiesce -- see file header. 'retain=', not 'keep=':
# gen-cron.sh's 'keep=' auto-derives a -H/-D/... flag from TIER_LETTER, keyed
# by the CANONICAL tier name (hourly/daily/...) -- these templates are named
# standard_<tier> to avoid colliding with a host's own hand-maintained
# hourly/daily/... templates in a DIFFERENT config file, so 'keep=' would fail
# to resolve a letter for them (found live, REV-20260730-001 fix commit
# 7ebfbf7). 'retain=' is the raw-flag escape hatch for exactly this case.
STANDARD_TEMPLATE_NAMES="standard_hourly"

STANDARD_TEMPLATE_standard_hourly='
[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
'

# ---- ONE send cadence, ONE ladder (REV-20260801-016 F2)
#
# An earlier version of this profile kept four named send tiers -- hourly,
# daily, weekly, monthly -- alongside the GFS ladder. That combined both models
# and gave the benefit of neither. `delsnaps.sh -G` buckets snapshots purely by
# CREATION TIME and never looks at the prefix, so the daily/weekly/monthly sends
# defined no retention tier at all: they only made extra snapshots and extra
# transfers, and they all fired at 00:00 against the same source and target
# while the hourly job followed a minute later.
#
# So there is one send cadence. The ladder turns those hourly snapshots into
# 24 hourly / 7 daily / 4 weekly / 12 monthly buckets, which is what GFS is for.
#
# Every keep_* tier therefore matches 'automated_hourly' -- the only prefix that
# now exists -- and only the finest tier carries monitor thresholds. Giving
# keep_daily a monitor on 'automated_daily' would watch a pattern nothing ever
# creates and sit at CRITICAL forever.
#
# ---- keep_* : retention and staleness, deliberately SEPARATE from standard_*
#
# gen-cron.sh accepts gfs= only in a [prune:] section, and a [dataset:] prunes
# exactly when its tiers resolve a prune_schedule. So a single template family
# cannot express "send here, keep by a GFS ladder over there": the dataset would
# prune flat per tier AND the ladder would prune the same snapshots, on the same
# schedule, and the two race.
#
# Hence two families. standard_* carries send_schedule/prefix and nothing else;
# keep_* carries prune_schedule/pattern/retain plus the staleness thresholds.
#
# The monitors live HERE, not on standard_*, and that is forced rather than
# chosen: in gen-cron.sh the [dataset:] monitor block is nested inside the
# prune_schedule branch, so a dataset that does not prune is not monitored
# either. Riding the [prune:] section makes each check recursive over the whole
# client subtree -- one alert per tier per client instead of one per dataset.
# That is a consolidation, not a loss: check-snap-age.sh -R names the offending
# dataset in the output the alert carries.
KEEP_TEMPLATE_NAMES="keep_hourly keep_daily keep_weekly keep_monthly"

KEEP_TEMPLATE_keep_hourly='
[template:keep_hourly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
	notify_word    = prune
	monitor_warn   = 90m
	monitor_crit   = 150m
'
KEEP_TEMPLATE_keep_daily='
[template:keep_daily]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -D7
	notify_word    = prune
'
KEEP_TEMPLATE_keep_weekly='
[template:keep_weekly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -W4
	notify_word    = prune
'
KEEP_TEMPLATE_keep_monthly='
[template:keep_monthly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -M12
	notify_word    = prune
'

# REV-20260730-003 F8 (review 2): checks EACH template independently and
# appends only what is actually missing -- a file with standard_hourly but
# missing standard_daily/weekly/monthly (hand-edited, or from an older
# version of this script) was previously considered "complete" because only
# standard_hourly was ever checked, AND a single-blob append would have
# duplicated whatever templates were already present.
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
# Source datasets that emit_client_sections wrote a REMOTE [prune:] for this run;
# the flow grant-checks exactly these before publishing (REV-20260811-102 step 3).
SOURCE_PRUNE_EMITTED_DS=()
# Per source dataset, the INSTALLED remote source [prune:] POLICY body captured
# before removal, so a re-activation preserves an admin's edited source retention
# and moves only topology (scope header + ssh_flags) -- REV-20260811-107.
declare -A SOURCE_PRUNE_PRESERVED=()

load_active_profile() {
    [ -n "$PROFILE_LOADED" ] && return 0
    local dir="$PROFILE_ROOT/$PROFILE_ACTIVE"
    # Validate before rendering. A profile that carries relationship-owned
    # fields must never reach a config, and finding that out from gen-cron
    # afterwards would mean it already had.
    profile_validate_dir "$dir" "$GENCRON" || die "profile '$PROFILE_ACTIVE': $PROFILE_ERR"
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
    local file="$1" name="$2" marker="# managed-by: zfs-backup.sh client=$name"
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
    local file="$1" name="$2" marker="# managed-by: zfs-backup.sh client=$name"
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
    {
        echo
        echo "[prune:$scope]"
        echo "	$marker"
        emit_source_prune_fragment "$PROFILE_PRUNE_FILE"
        echo "	recursive    = no"
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
managed_source_prefix_for_scope() {   # <rendered-crontab-file> <scope>
    local line pfx
    while IFS= read -r line; do
        case "$line" in *snapget*|*snapsend*) ;; *) continue ;; esac
        case "$line" in *"$2"*) ;; *) continue ;; esac
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

# The `src` value of an installed [dataset:<localpath>] section (account@host:ds), or
# empty if the section or its src field is absent. The audit keys the SOURCE scope off
# this -- the installed CONFIG is runtime truth -- not off possibly-stale client state.
installed_dataset_src() {   # <cronfile> <local dataset path>
    awk -v h="[dataset:$2]" '
        $0==h {f=1; next}
        f && /^\[/ {f=0}
        f {
            line=$0; sub(/^[ \t]+/,"",line)
            if (line ~ /^src[ \t]*=/) { sub(/^src[ \t]*=[ \t]*/,"",line); print line; exit }
        }
    ' "$1" 2>/dev/null
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
        {
            echo "[defaults]"
            echo "	host_label = $(hostname -s)"
        } > "$file" || die "could not create $file"
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
    sed -E \
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
    die "$n job line(s) overlap between root's managed block and the block this run would install into '$u' -- identical work, same schedule, same datasets, twice. The config PATHS differ, which is normal for this migration and is why that is not what was compared. Use 'zfs-backup.sh migrate-to-account $u' to move ownership in one transaction (root's block out, the account's block in, rollback if either half fails). Nothing has been changed."
}

# gen-cron.sh runs AS the dedicated account, so that account has to be able to
# READ the config. The default location is $SCRIPT_DIR/jobs.<host>.conf, which
# on a Proxmox host means /root/scripts/... -- and /root is 0700. Found on
# metropolis pve1, 2026-08-01: the account could not open the file at all, so
# --local-user with the default path would have failed at install time, after
# the preview had already been shown and accepted.
#
# Checked as the account itself rather than by reasoning about modes: group
# membership, ACLs and every parent directory on the path all get a vote, and
# `test -r` run as that user is the only thing that knows all of them.
assert_config_readable_by_target() {   # <config file>
    local file="$1" u; u=$(cron_target_user)
    [ "$u" = root ] && return 0
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
            echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
            echo "	flags        = $LOAD_FLAGS"
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
                    echo "	recursive    = no"
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
    emit_remote_source_prune "$workfile" "$name" "$marker" ${PEER_SAVED_DATASETS:-} || return 1
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

# `crontab -l` for whoever owns the jobs. Root can read another account's
# crontab with -u; as that account itself, -u is refused, so it is only added
# when it is actually needed.
crontab_for_target() {   # -> the target user's crontab on stdout
    local u tmp; u=$(cron_target_user)
    tmp=$(mktemp) || return 1
    if ! cron_read "$u" "$tmp"; then rm -f "$tmp"; return 1; fi
    cat "$tmp"; rm -f "$tmp"
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

runuser_test_x() {   # <user> <path>
    if command -v runuser >/dev/null 2>&1; then
        runuser --user "$1" -- test -x "$2"
    else
        su -s /bin/bash "$1" -c "$(printf '%q ' test -x "$2")"
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
    if ! gencron_as_target -c "$workfile" 2>/dev/null | _strip_source > "$after"; then
        rm -f "$before" "$after"; return 1
    fi

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
    # Opt-in, by owner decision: an existing collector keeps running its jobs as
    # root until someone asks otherwise. `--local-user=root` is accepted and
    # means the same as omitting it, so the flag can be written down in a runbook
    # without it changing behaviour.
    [ "$local_user" = root ] && local_user=""
    if [ -n "$local_user" ]; then
        case "$local_user" in
            *[!a-z0-9_-]* | "" | [!a-z_]*)
                die "setup-server: --local-user='$local_user' is not a valid account name (lowercase letters, digits, _ and -, not starting with a digit)" ;;
        esac
    fi

    if [ -n "$local_user" ]; then
        bash "$DEPLOY" --backup-user="$local_user" || die "deploy.sh bootstrap failed -- fix that before continuing"
    else
        bash "$DEPLOY" || die "deploy.sh bootstrap failed -- fix that before continuing"
    fi

    read_server_conf
    if [ -z "$target" ]; then
        if [ -n "$DEFAULT_TARGET" ]; then
            target="$DEFAULT_TARGET"
        else
            local pools candidates
            pools=$(zpool list -H -o name 2>/dev/null) || die "zpool list failed"
            candidates=$(printf '%s\n' "$pools" | grep -v '^rpool$')
            case "$(printf '%s\n' "$candidates" | grep -c .)" in
                0) target="rpool/backups"
                   warn "only 'rpool' exists -- proposing $target. Confirm this is really where you want backups (rpool is usually the OS/VM pool)." ;;
                1) target="${candidates}/backups" ;;
                *) die "multiple candidate pools found ($(printf '%s' "$candidates" | tr '\n' ' ')) -- pass --target=POOL/PATH explicitly" ;;
            esac
        fi
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
                config="$SCRIPT_DIR/jobs.$(hostname -s).conf"
            fi
        fi
    fi

    zfs create -p "$target" 2>/dev/null || zfs list "$target" >/dev/null 2>&1 || die "could not create or find target dataset $target"

    mkdir -p "$(dirname "$SERVER_CONF")" || die "could not create $(dirname "$SERVER_CONF")"
    {
        echo "# zfs-backup.sh server config -- edit by hand if needed, or re-run setup-server"
        echo "DEFAULT_TARGET=$target"
        echo "CRON_CONFIG=$config"
        echo "LOCAL_USER=$local_user"
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
        done < <(printf '%s\n' "$scope" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    done < <(grep -oE '^\[(dataset|prune):[^]]+\]' "$file")
    return 0
}

cmd_local_backup() {
    local target="" profile="default" config=""
    local -a source_flags=()
    for a in "$@"; do
        case "$a" in
            --source=*)  source_flags+=("${a#*=}") ;;
            --target=*)  target="${a#*=}" ;;
            --profile=*) profile="${a#*=}" ;;
            --config=*)  config="${a#*=}" ;;
            --plan)      ;;   # accepted and implied; the install verb is a later slice
            *) die "local-backup: unknown option $a" ;;
        esac
    done
    [ "${#source_flags[@]}" -gt 0 ] || die "local-backup: --source=<dataset>[,<dataset>...] is required (the dataset(s) to back up)"
    [ -n "$target" ] || die "local-backup: --target=<dataset> is required (where the backups land)"

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
        done < <(printf '%s\n' "$sv" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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
    [ -n "$config" ] || config="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s 2>/dev/null || hostname).conf}"

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

    if ! bash "$GENCRON" -c "$cand" >/dev/null 2>"$cand.err"; then
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
    bash "$GENCRON" -c "$cand"
    echo
    echo "To jest wylacznie plan. Instalacja transakcyjna (seed + atomowy zapis"
    echo "crona z odczytem zwrotnym) przyjdzie w kolejnym wycinku Fazy 5 -- ten"
    echo "wycinek celowo nie dotyka zadnego crontaba ani configu produkcyjnego."
    rm -f "$cand"
}

# ------------------------------------------------------------------------------
cmd_add_client() {
    local name="${1:-}"; shift || true
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    local lan="" datasets="" target="" bandwidth="" mode="" join_remotely=0 profile=""
    for a in "$@"; do
        case "$a" in
            --lan=*)       lan="${a#*=}" ;;
            --datasets=*)  datasets="${a#*=}" ;;
            --mode=*)      mode="${a#*=}" ;;
            --target=*)    target="${a#*=}" ;;
            --bandwidth=*) bandwidth="${a#*=}" ;;
            --profile=*)   profile="${a#*=}" ;;
            --join-remotely) join_remotely=1 ;;
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
    [ -n "$lan" ] || die "add-client requires --lan=HOST[:PORT] (the LAN address to seed over)"
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
        case "$bandwidth" in
            *[!0-9kKmMgG]* | "" | *[kKmMgG]*[kKmMgG]* | [kKmMgG]*)
                die "add-client: --bandwidth='$bandwidth' is not a byte rate (digits, optionally followed by one of k/M/G -- e.g. 20M). It is BYTES per second, not bits." ;;
        esac
    fi

    local cpath; cpath=$(client_conf_path "$name")
    [ -e "$cpath" ] && die "client '$name' already exists ($cpath) -- use seed/activate-client/remove-client"

    read_server_conf
    if [ "$mode" != sync ]; then
        if [ -z "$target" ]; then
            target="$DEFAULT_TARGET"
            [ -n "$target" ] || die "no --target given and no default set -- run setup-server first, or pass --target=POOL/PATH"
        fi
    fi

    local lan_host lan_port; read -r lan_host lan_port <<< "$(parse_endpoint_arg "$lan")"

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
    [ -n "${LOCAL_USER:-}" ] && pair_args+=(--local-user="$LOCAL_USER")
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
resolve_mode_datasets() {
    [ -n "${PEER_SAVED_MODE:-}" ] || return 0
    [ -z "${PEER_SAVED_DATASETS:-}" ] || return 0

    local -a ssh_opts=(-i "$LOAD_KEYFILE" -p "$LOAD_PORT" -o BatchMode=yes \
        -o "HostKeyAlias=$LOAD_ALIAS" -o "UserKnownHostsFile=$LOAD_ALIAS_KH" \
        -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no)
    # REV-20260804-037: NOT $LOAD_LABEL (see $COLLECTOR_LABEL's own comment
    # at its declaration for why these two are different labels, and why
    # using the wrong one here was invisible to every prior local test).
    local sfile_remote hfile_remote
    sfile_remote=$(peer_scope_path "$COLLECTOR_LABEL")
    hfile_remote=$(peer_scope_granted_hash_path "$COLLECTOR_LABEL")

    local scope_tmp hash_tmp
    scope_tmp=$(mktemp) || die "mktemp failed"
    hash_tmp=$(mktemp) || { rm -f "$scope_tmp"; die "mktemp failed"; }
    if ! ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$sfile_remote'" > "$scope_tmp" 2>/dev/null \
       || [ ! -s "$scope_tmp" ]; then
        rm -f "$scope_tmp" "$hash_tmp"
        die "could not fetch the scope file from $LOAD_HOST ($sfile_remote) -- has --draft-scope run there yet?"
    fi
    if ! ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "cat -- '$hfile_remote'" > "$hash_tmp" 2>/dev/null \
       || [ ! -s "$hash_tmp" ]; then
        rm -f "$scope_tmp" "$hash_tmp"
        die "could not fetch the granted-scope hash from $LOAD_HOST ($hfile_remote) -- has --commit-scope run there yet? (--draft-scope alone grants nothing)"
    fi

    local want_hash got_hash
    want_hash=$(tr -d ' \t\r\n' < "$hash_tmp")
    got_hash=$(sha256sum -- "$scope_tmp" 2>/dev/null | awk '{print $1}')
    rm -f "$hash_tmp"
    if [ -z "$got_hash" ] || [ "$want_hash" != "$got_hash" ]; then
        rm -f "$scope_tmp"
        die "the scope file on $LOAD_HOST does not match the hash --commit-scope last recorded there -- it was edited since the last commit (or committed differently) and never re-committed. Run --commit-scope on $LOAD_HOST first, then retry."
    fi

    scope_read "$scope_tmp" || { rm -f "$scope_tmp"; die "scope file fetched from $LOAD_HOST: $SCOPE_ERR"; }
    rm -f "$scope_tmp"

    local -a resolved=()
    local root ds
    for root in "${SCOPE_ROOTS[@]}"; do
        while IFS= read -r ds; do
            [ -n "$ds" ] || continue
            scope_includes "$ds" || continue
            case " ${resolved[*]:-} " in *" $ds "*) continue ;; esac
            resolved+=("$ds")
        done < <(ssh "${ssh_opts[@]}" "${LOAD_ACCOUNT}@${LOAD_HOST}" "zfs list -H -o name -r -- '$root'" 2>/dev/null)
    done
    [ "${#resolved[@]}" -gt 0 ] \
        || die "the scope file on $LOAD_HOST selects nothing that currently exists there -- nothing to back up"

    PEER_SAVED_DATASETS="${resolved[*]}"
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
    for a in "$@"; do case "$a" in --yes) yes=1 ;; *) die "seed: unknown option $a" ;; esac; done
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
        case "$ans" in t|T|tak|TAK) ;; *) die "not confirmed -- no transfer performed, state stays 'seeding'" ;; esac
    fi

    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        log "seeding $ds -> $localpath (real transfer, may take a while)..."
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -m automated_daily_ $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
    log "client '$name' seed complete. Next: if this collector relocates, run final-catchup first over the still-working link. If SSH now reaches the peer at a DIFFERENT host or port afterward, run set-endpoint with the new value; if the same host:port still works (e.g. a routed VPN), skip straight to verify-endpoint. Then activate-client."
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
    for a in "$@"; do case "$a" in --yes) yes=1 ;; *) die "final-catchup: unknown option $a" ;; esac; done
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
        case "$ans" in t|T|tak|TAK) ;; *) die "not confirmed -- nothing transferred" ;; esac
    fi

    local base; base=$(snapget_local_base)
    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        log "final catch-up $ds -> $localpath over '$(endpoint_display)'..."
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -m automated_daily_ $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
        out=$(bash "$SNAPGET" -n $pflags "${LOAD_ACCOUNT}@${phost}:${ds}" "$base" 2>"$errtmp"); local rc=$?
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
cmd_activate_client() {
    local name="${1:-}"; shift || true
    local yes=0 verbose=0
    for a in "$@"; do
        case "$a" in
            --yes) yes=1 ;;
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
    # REV-20260809-088 F1: STATE here is still whatever it was BEFORE this
    # call -- 'endpoint_verified' means this relationship has never reached
    # 'active' before, i.e. this really is the moment a NEW relationship is
    # being created and may first rely on a template identity. 'active'
    # means it is being re-activated (e.g. after set-endpoint) and its
    # already-installed policy must not be re-validated against whatever
    # the active profile currently renders.
    local is_new_relationship=0
    [ "${STATE:-}" = "endpoint_verified" ] && is_new_relationship=1
    case "${STATE:-}" in
        endpoint_verified|active) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- activate-client requires endpoint_verified (run seed, then verify-endpoint first). Fail-closed: no cron entry exists before this gate." ;;
    esac

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing"

    apply_client_profile_choice "$is_new_relationship" "${PROFILE:-}"

    read_server_conf
    [ -n "$recorded_cron_config" ] && CRON_CONFIG="$recorded_cron_config"
    local cronfile="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s).conf}"

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
        : > "$workfile" || die "could not create working copy $workfile"
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
    local failed=0
    local base; base=$(snapget_local_base)
    for ds in $PEER_SAVED_DATASETS; do
        localpath=$(client_local_path "$ds")
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
    echo "Spojnosc snapshotu:  crash-consistent -- quiesce NIE jest wlaczony w tym profilu."
    echo "                     (zdalny quiesce w trybie pull istnieje: snapget -q przez"
    echo "                      zfs-quiesce-helper, wymaga --allow-quiesce przy parowaniu)"
    echo "Test:                OK ($( printf '%s' "$PEER_SAVED_DATASETS" | wc -w ) dataset(s))"
    echo

    show_activation_proposal "$cronfile" "$workfile" || {
        rm -f "$workfile"
        die "gen-cron.sh could not render the proposed config -- nothing was touched"
    }

    if [ "$yes" -ne 1 ]; then
        read -rp "Aktywowac backup? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK) ;;
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
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    chmod 0600 "$cpath"

    log "client '$name' active (cron runs over endpoint '$(endpoint_display)')."
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
cmd_migrate_profile() {
    local yes=0 a
    for a in "$@"; do
        case "$a" in
            --yes) yes=1 ;;
            *) die "migrate-profile: unknown option $a" ;;
        esac
    done

    read_server_conf
    local cronfile="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s).conf}"
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
            t|T|y|Y) ;;
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
cmd_audit_source_retention() {   # [--apply] [--yes]
    local apply=0 yes=0 a
    for a in "$@"; do
        case "$a" in
            --apply) apply=1 ;;
            --yes)   yes=1 ;;
            *) die "audit-source-retention: unknown option $a" ;;
        esac
    done

    read_server_conf
    local cronfile="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s).conf}"
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
    local f missing=0 total_ds=0
    local -a report=()
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
    echo "  aktywne pull-datasety:            $total_ds"
    echo "  bez ograniczonej retencji zrodla: $missing"
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
            t|T|y|Y) ;;
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
# Host-level jobs: a SECOND tool-owned block in root's crontab.
#
# REV-20260801-020 F2. Some generated lines are host-level rather than
# collector-level -- alert-digest.sh above all, which is deliberately one per
# host and is never provisioned to a delegated account. When the collector block
# moves to an account those lines have nowhere to go. The first version of this
# migration parked them in root's crontab as ordinary unmanaged lines, and the
# reviewer's objection is exact: that splits one deployment between something
# the tool owns and something a human has to remember forever. A later
# migration would duplicate them, remove-client could not tell whether they
# belonged to it, and no preview could honestly show the whole change.
#
# So they get their own marked block, owned by this tool, rewritten wholesale
# and idempotently -- the same contract gen-cron.sh has with its own block, and
# for the same reason.
HOST_NAME='zfs-backup-host'
HOST_TAIL='(host-level jobs kept by zfs-backup.sh -- do not hand-edit)'
HOST_BEGIN="# BEGIN $HOST_NAME $HOST_TAIL"
HOST_END="# END $HOST_NAME"

# Replace (or insert, or delete) the host block inside a crontab held in a file.
# Empty <lines file> removes the block, which is what makes repeated migrations
# converge instead of accumulating.
set_host_block() {   # <crontab file> <lines file>
    local cron="$1" lines="$2" tmp
    tmp=$(mktemp) || die "mktemp failed"
    # MERGE, not replace -- REV-20260802-034 F1.
    #
    # This handed `lines` to cron_block_render as the COMPLETE new body, which
    # was right while this script was the block's only requester. Since
    # 2026-08-02 deploy.sh puts the root updater, the capacity check and the
    # account's auto-pull line in the same block, while `lines` here holds only
    # what this migration rescued out of the managed block (today: the digest).
    # Replacing from that partial inventory deleted the other three -- silently,
    # while reporting a healthy migration.
    #
    # So the rule a shared block needs: a requester adds its own lines and never
    # speaks for the rest of the body. An empty `lines` means this migration has
    # nothing to add, NOT that the block should go.
    #
    # Rendering still comes from lib-cron.sh, so "keep everything else byte for
    # byte" has one definition. The awk this originally replaced was correct,
    # and that was the point: a second correct implementation is still a second
    # thing to keep correct.
    cron_block_merge_render "$cron" "$HOST_NAME" "$lines" "$tmp" "$HOST_TAIL" \
        || die "${CRON_ERR:-could not render the $HOST_NAME block} -- nothing has been changed"
    mv -f "$tmp" "$cron"
}

# ------------------------------------------------------------------------------
# Capability probes. Read-only, and each one answers for the ACCOUNT, not for
# root -- the whole class of defect this migration kept hitting is root proving
# something about itself and the account failing at it later.

# Datasets a config actually manages, from its own section headers.
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

# ------------------------------------------------------------------------------
# WHAT THE JOBS ACTUALLY NEED (REV-20260801-026)
#
# The first version probed one fixed set -- snapshot,destroy,hold,release,mount --
# against every dataset a config mentioned. That is neither necessary nor
# sufficient, and pve2 showed both halves:
#
#   * NOT SUFFICIENT. A receive target needs receive/create/rollback/canmount,
#     none of which were probed. An account with the five would pass preflight
#     and then fail at 04:00 on `cannot receive: permission denied`.
#   * NOT NECESSARY. A `[prune:]` carrying `prune = no` is a MONITOR line; it
#     destroys nothing and needs no delegation at all. Those datasets were
#     reported as gaps on pve2, sending the operator to widen a grant for a job
#     that only reads.
#
# So the capabilities are derived from the RENDERED BLOCK -- the actual command
# lines the account would run -- rather than from a section type. That is the
# only description of the work that cannot drift from it, because it IS it.
#
# Remote scopes are identified exactly as snapsend.sh identifies them, and
# deliberately produce NO local requirement: what they need is ssh and a grant
# on the far side, which is a different question this verb does not answer.

# Flags that consume the NEXT token. Everything else that starts with '-' is
# boolean or glued (-R, -G, -B, -H24, -d30), and its following quoted token is a
# positional argument, not a value. Getting this list wrong makes a dataset be
# read as a flag value or vice versa -- so it is stated once, here, and pinned
# by a test against what gen-cron.sh can emit.
QCAP_VALUE_FLAGS=" -m -v -q -o -x -c -K -p -k -O -b -T -P -i -j "

# Positional (non-flag, non-flag-value) quoted arguments of one command, in
# order, one per line.
job_positionals() {   # <command string>
    printf '%s\n' "$1" | tr ' ' '\n' | awk -v vf="$QCAP_VALUE_FLAGS" '
        function isval(t) { return index(vf, " " t " ") > 0 }
        {
            tok = $0
            if (skip) { skip = 0; next }
            if (tok ~ /^-/) { if (isval(tok)) skip = 1; next }
            if (tok ~ /^".*"$/) { gsub(/^"|"$/, "", tok); print tok }
        }'
}

# The convention snapsend.sh itself uses (see its REMOTE parsing): a ':' makes
# it host:dataset, a bare '@' makes it sync-mode user@host. A local dataset name
# may legally contain ':' in ZFS, but the tool's own remote syntax claims it
# first, so this matches what the job will actually do rather than what ZFS
# would permit.
qcap_is_remote() {   # <arg>
    case "$1" in *:*|*@*) return 0 ;; esac
    return 1
}

qcap_add() {   # <dataset> <verbs csv>   -- appends to $QCAP_FILE
    qcap_is_remote "$1" && return 0
    [ -n "$1" ] || return 0
    printf '%s\t%s\n' "$1" "$2" >> "$QCAP_FILE"
}

qcap_add_list() {   # <comma list> <verbs csv>
    local d
    # printf '%s\n', not '%s': without the trailing newline `while read` never
    # runs its body for the LAST element, so a one-element list contributed
    # nothing at all and a two-element list contributed one. Caught by feeding
    # this a real rendered block and reading the table it produced, which is the
    # only way it shows -- the missing rows look exactly like datasets that
    # already have delegation.
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r d; do
        [ -n "$d" ] && qcap_add "$d" "$2"
    done
}

# Reads a rendered block, writes "<dataset>\t<verbs csv>" to stdout, merged.
block_capabilities() {   # <block file>
    QCAP_FILE=$(mktemp) || return 1
    local line cmd script pos p0 p1 n
    while IFS= read -r line; do
        case "$line" in [0-9]*|\**) ;; *) continue ;; esac
        cmd=$(printf '%s\n' "$line" | sed -E 's/^([^ ]+ +){5}//')
        # One cron line can carry several commands (the monitor idiom chains
        # notify calls); each is examined on its own.
        printf '%s\n' "$cmd" | tr ';' '\n' | while IFS= read -r one; do
            case "$one" in
                *snapsend.sh*)      script=snapsend ;;
                *snapget.sh*)       script=snapget ;;
                *delsnaps.sh*)      script=delsnaps ;;
                *) continue ;;
            esac
            pos=$(job_positionals "$one")
            p0=$(printf '%s\n' "$pos" | sed -n 1p)
            p1=$(printf '%s\n' "$pos" | sed -n 2p)
            case "$script" in
                snapsend)
                    # Sources. A send also writes a bookmark on the source, and
                    # holds the snapshot it just made; without a destination it
                    # is snapshot-only and needs neither send nor bookmark.
                    if [ -n "$p1" ]; then
                        qcap_add_list "$p0" "snapshot,hold,release,send,bookmark"
                        qcap_add "$p1" "receive,create,mount,canmount,rollback"
                    else
                        qcap_add_list "$p0" "snapshot,hold,release"
                    fi
                    ;;
                snapget)
                    # Mirrored: arg1 is the literal remote source, arg2 the
                    # LOCAL base that receives (see the pull-flip design).
                    qcap_add "$p1" "receive,create,mount,canmount,rollback"
                    ;;
                delsnaps)
                    case "$one" in
                        *" -B "*) qcap_add_list "$p0" "bookmark,destroy" ;;
                        *)        qcap_add_list "$p0" "destroy,hold,release" ;;
                    esac
                    ;;
            esac
        done
    done < "$1"
    # Merge the verbs of every mention of a dataset into one row.
    sort -u "$QCAP_FILE" | awk -F'\t' '
        { if ($1 != cur) { if (cur != "") print cur "\t" v; cur = $1; v = $2 }
          else v = v "," $2 }
        END { if (cur != "") print cur "\t" v }' \
    | awk -F'\t' '{ n = split($2, a, ","); delete seen; out = ""
                    for (i = 1; i <= n; i++) if (!(a[i] in seen)) { seen[a[i]] = 1; out = out (out == "" ? "" : ",") a[i] }
                    print $1 "\t" out }'
    rm -f "$QCAP_FILE"
}

# zfs allow reports grants made on the dataset AND on its ancestors, so asking
# about the leaf is enough. Parsed rather than probed with a real snapshot: a
# probe writes to production, and this runs before anything has been decided.
target_can_zfs() {   # <account> <dataset> <verbs csv>
    local acct="$1" ds="$2" want="$3" perms
    perms=$(zfs allow "$ds" 2>/dev/null | grep -E "^[[:space:]]*user $acct " | head -1) || return 1
    [ -n "$perms" ] || return 1
    local v
    for v in $(printf '%s' "$want" | tr ',' ' '); do
        case ",$perms," in *[,\ ]"$v"[,\ ]*) ;; *) return 1 ;; esac
    done
    return 0
}

# The same probe lib-zfs-snap.sh performs before it freezes anything, asked
# early instead of at 00:11 in a cron job.
# Overridable so the suite can drive the real code against a stub helper. In
# production nothing sets it.
QUIESCE_HELPER_PATH="${QUIESCE_HELPER_PATH:-/usr/local/sbin/zfs-quiesce-helper}"

target_can_quiesce() {   # <account>
    local acct="$1"
    [ -x "$QUIESCE_HELPER_PATH" ] || return 1
    runuser --user "$acct" -- sudo -n "$QUIESCE_HELPER_PATH" status >/dev/null 2>&1
}
# ------------------------------------------------------------------------------
# QUIESCE SCOPE, PER RENDERED JOB (REV-20260801-027)
#
# `target_can_quiesce` above proves the account can INVOKE the helper. That is a
# different statement from "the whitelist covers every guest the -q jobs will
# touch", and treating the first as evidence of the second is the same defect
# REV-026 fixed for `zfs allow`: the mechanism is present, the capabilities are
# not, and the first uncovered guest is discovered by cron after the migration.
#
# I had already hit this by hand on metropolis pve1 that morning -- walking
# guests 100/101/106/107 through the helper one at a time and finding 102
# refused. Doing it with fingers instead of putting it in the tool is exactly
# how a check fails to exist.
#
# The Proxmox naming convention IS the dataset-to-guest mapping; there is no
# property to ask. Replicated from lib-zfs-snap.sh's quiesce_guest_id rather
# than sourced, because sourcing the library into this wrapper would drag in its
# whole runtime; test/zfsbackup section 33 pins the two against each other so
# the copy cannot drift.
qscope_guest_id() {   # <dataset> -> guest id, or 1
    local leaf="${1##*/}"
    case "$leaf" in
        vm-*-disk-*|subvol-*-disk-*)
            leaf="${leaf#vm-}"; leaf="${leaf#subvol-}"
            printf '%s' "${leaf%%-disk-*}"
            ;;
        *) return 1 ;;
    esac
}

# Datasets whose RENDERED job asks to be quiesced. Recursion is expanded exactly
# as the runtime expands it (quiesce_scope): under -r/-R the guests live in the
# CHILDREN and the named parent matches no guest at all, so a job covering a
# whole pool would otherwise look like it quiesces nothing.
block_quiesce_scope() {   # <block file>  -> local push-side datasets, one per line
    local line cmd pos p0 d rec
    while IFS= read -r line; do
        case "$line" in [0-9]*|\**) ;; *) continue ;; esac
        cmd=$(printf '%s\n' "$line" | sed -E 's/^([^ ]+ +){5}//')
        printf '%s\n' "$cmd" | tr ';' '\n' | while IFS= read -r one; do
            case "$one" in *snapsend.sh*) ;; *) continue ;; esac
            case "$one" in *" -q "*) ;; *) continue ;; esac
            rec=0
            case "$one" in *" -r "*|*" -R "*) rec=1 ;; esac
            pos=$(job_positionals "$one")
            p0=$(printf '%s\n' "$pos" | sed -n 1p)
            printf '%s\n' "$p0" | tr ',' '\n' | while IFS= read -r d; do
                [ -n "$d" ] || continue
                qcap_is_remote "$d" && continue
                if [ "$rec" -eq 1 ]; then
                    zfs list -H -o name -r -- "$d" 2>/dev/null || printf '%s\n' "$d"
                else
                    printf '%s\n' "$d"
                fi
            done
        done
    done < "$1" | sort -u
}

# Remote quiesce (snapget -q) asks the SOURCE host to freeze, through a grant
# that lives over there. Nothing this verb can read proves it, so it is reported
# rather than silently passed or silently failed (REV-20260801-027 point 4).
block_has_remote_quiesce() {   # <block file>
    grep -qE '^[0-9*].*snapget\.sh.* -q ' "$1"
}

# Can the account actually quiesce this dataset's guest? Answered THROUGH THE
# HELPER, as the account -- the same boundary the job will hit at 00:11, not a
# reimplementation of it.
#
#   no guest / not on this node / stopped  -> fine, nothing to quiesce
#   running and answered                   -> covered
#   refused, unreadable, helper unusable   -> blocking
qscope_covered() {   # <account> <dataset> -> 0 covered/not-applicable, 1 blocking
    local acct="$1" ds="$2" id line
    id=$(qscope_guest_id "$ds") || return 0
    line=$(runuser --user "$acct" -- sudo -n "$QUIESCE_HELPER_PATH" status "$id" 2>/dev/null) || return 1
    case "$line" in
        *"kind=absent"*) return 0 ;;
        *"running=no"*)  return 0 ;;
        *"running=yes"*) return 0 ;;
        *) return 1 ;;
    esac
}


# ------------------------------------------------------------------------------
# ONE SURVEY, ASKED TWICE (owner decision 2026-08-02, option "b")
#
# Everything the account needs for the block it is about to be given, computed
# in one place so it can be asked at two moments: in the preflight, where it
# produces the remediation block, and again immediately before the crontabs are
# written, where it is the last chance to notice that the world changed since.
#
# The re-check is not paranoia about the world. It is about the GAP: the
# operator reads a command, runs it in another window, and comes back. What they
# actually ran is not knowable from here -- a narrower dataset list, a different
# account, a typo. Checking once, at the start, validates a state that no longer
# has to be the state at commit time.
CAP_ALL=""            # the FULL intended dataset set, not just what is missing
CAP_MISSING_ZFS=""; CAP_MISSING_ZFS_N=0
CAP_MISSING_Q="";   CAP_MISSING_Q_N=0
CAP_QN=0; CAP_HELPER=1; CAP_REMOTE_Q=0

capability_survey() {   # <account> <block file>  -> 0 if the account can run it all
    local acct="$1" blk="$2" d v tmp tab
    CAP_ALL=""; CAP_MISSING_ZFS=""; CAP_MISSING_ZFS_N=0
    CAP_MISSING_Q=""; CAP_MISSING_Q_N=0; CAP_QN=0; CAP_HELPER=1; CAP_REMOTE_Q=0
    tmp=$(mktemp) || return 1
    tab=$(printf '\t')

    while IFS="$tab" read -r d v; do
        [ -n "$d" ] || continue
        printf '%s\n' "$d" >> "$tmp"
        target_can_zfs "$acct" "$d" "$v" || {
            CAP_MISSING_ZFS="$CAP_MISSING_ZFS
  $d ($v)"
            CAP_MISSING_ZFS_N=$((CAP_MISSING_ZFS_N + 1)); }
    done < <(block_capabilities "$blk")

    while IFS= read -r d; do
        [ -n "$d" ] || continue
        CAP_QN=$((CAP_QN + 1))
        printf '%s\n' "$d" >> "$tmp"
        qscope_covered "$acct" "$d" || {
            CAP_MISSING_Q="$CAP_MISSING_Q
  $d (guest $(qscope_guest_id "$d" || echo '?'))"
            CAP_MISSING_Q_N=$((CAP_MISSING_Q_N + 1)); }
    done < <(block_quiesce_scope "$blk")

    [ "$CAP_QN" -gt 0 ] && { target_can_quiesce "$acct" || CAP_HELPER=0; }
    block_has_remote_quiesce "$blk" && CAP_REMOTE_Q=1

    CAP_ALL=$(sort -u "$tmp" | tr '\n' ' '); CAP_ALL="${CAP_ALL% }"
    rm -f "$tmp"

    [ "$CAP_MISSING_ZFS_N" -eq 0 ] && [ "$CAP_MISSING_Q_N" -eq 0 ] && [ "$CAP_HELPER" -eq 1 ]
}

# The remediation block: ONE ordered, copy-pasteable answer to "what now".
#
# It names the FULL dataset set, never just the missing ones, and that is a
# correctness requirement rather than a convenience. install_quiesce_grant
# REWRITES /etc/zfs-quiesce-allow/<account> from whatever --datasets it is given,
# so a command listing only the gaps would silently REVOKE quiesce for every
# guest that already had it. The first version of this message (2026-08-01,
# REV-027) printed exactly that list, and following it would have narrowed a
# working grant on any host where one guest was missing and others were not.
capability_remediation() {   # <account>
    local acct="$1" q=""
    # --add-quiesce, not --allow-quiesce: the latter REWRITES the whitelist from
    # the given list, and this list describes ONE config. A host can also carry
    # grants from another config, an older deployment or a peer relationship,
    # and none of those are visible from here (REV-20260802-028).
    [ "$CAP_QN" -gt 0 ] && q=" --add-quiesce"
    printf '\n  Do wykonania, w tej kolejnosci:\n\n'
    printf '    # 1. zdolnosci. PELNA lista datasetow, ktorych potrzebuja zadania
'
    printf '    #    z tego bloku -- nie tylko brakujace.
'
    printf '    #    --add-quiesce DOKLADA je do whitelisty quiesce i ZACHOWUJE
'
    printf '    #    wpisy, ktore juz tam sa -- takze te z innych configow, ze
'
    printf '    #    starszego wdrozenia albo z relacji peer. Nie myl z
'
    printf '    #    --allow-quiesce, ktore te liste NADPISUJE.
'
    printf '    deploy.sh --backup-user=%s --datasets="%s"%s\n' "$acct" "$CAP_ALL" "$q"
    printf '\n    # 2. dopiero teraz przelaczenie wlascicielstwa\n'
    printf '    zfs-backup.sh migrate-to-account %s --yes\n\n' "$acct"
    printf '  Krok 2 sprawdza te zdolnosci PONOWNIE, tuz przed zapisem crontabow,\n'
    printf '  wiec jesli krok 1 zostanie uruchomiony z inna lista niz powyzsza --\n'
    printf '  migracja odmowi zamiast przeniesc blok, ktorego konto nie uciagnie.\n'
}

# ------------------------------------------------------------------------------
# migrate-to-account: move an existing collector from root to a delegated
# account, as ONE transaction.
#
# REV-20260801-018/-019 required the transactional verb; REV-20260801-020 F1
# required that it also DISCOVER and CHECK the capabilities instead of leaving
# them to a runbook, and F3 required distinct phases. The phases below are the
# reviewer's, in the reviewer's order:
#
#   1 preflight  read-only: A/B/C equivalence, config, checkout, zfs allow,
#                quiesce, host-level lines. Available on its own via --preflight.
#   2 prepare    create only what is missing, touching NEITHER crontab.
#   3 preview    one combined proposal: root's block out, host block kept,
#                account's block in.
#   4 commit     one switch, with no interval in which both job sets are live.
#   5 verify     read both crontabs back AS THEIR OWNERS; roll both back on any
#                surprise.
#
# ORDER within phase 4: root's block comes OUT before the account's goes IN.
# The reviewer's REV-019 sketch had it the other way round. Installing first
# leaves BOTH blocks live for the width of one step, and these jobs include
# prunes -- two delsnaps runs racing over one dataset set is the outcome worth
# designing against. Removing first can only lose a tick. REV-019 point 4 asks
# for an end state of one or the other and never both; this order also never
# passes THROUGH both.
#
# The config is MOVED, never copied. A copy is precisely how two paths come to
# describe one workload, which is the defect REV-018 opened.
cmd_migrate_to_account() {
    local acct="" yes=0 preflight_only=0 a
    for a in "$@"; do
        case "$a" in
            --yes|-y)     yes=1 ;;
            --preflight)  preflight_only=1 ;;
            -*)           die "migrate-to-account: unknown option $a" ;;
            *)            [ -z "$acct" ] && acct="$a" || die "migrate-to-account: one account, not two" ;;
        esac
    done
    [ -n "$acct" ] || die "usage: zfs-backup.sh migrate-to-account <account> [--preflight] [--yes]"
    [ "$(id -u)" = 0 ] || die "this rewrites root's crontab and '$acct's -- run it as root"
    [ "$acct" = root ] && die "'root' is where the jobs already are"
    getent passwd "$acct" >/dev/null 2>&1 || die "no such account '$acct'"

    # ---- phase 1: preflight, read-only ---------------------------------------
    # A GAP is something only the operator can provide, and it blocks. A TODO is
    # something phase 2 will do itself, so it is reported but does not block --
    # keeping the two apart is what stops "this tool can fix it" from silently
    # becoming "this tool will proceed without it".
    local gaps=0
    _gap()  { printf '  [ BRAK ] %s\n' "$1"; gaps=$((gaps+1)); }
    _todo() { printf '  [ plan ] %s\n' "$1"; }
    _have() { printf '  [  ok  ] %s\n' "$1"; }
    echo "== preflight: root -> $acct =="

    local home; home=$(getent passwd "$acct" | cut -d: -f6)
    if [ -n "$home" ] && [ -d "$home" ]; then _have "konto ma katalog domowy ($home)"
    else _gap "konto nie ma katalogu domowego -- deploy.sh --backup-user=$acct"; fi

    if runuser_test_r "$acct" "$home/zfs-snapshot-all/gen-cron.sh"; then
        _have "konto ma wlasny checkout ($home/zfs-snapshot-all)"
    else
        _gap "konto nie ma czytelnego checkoutu -- deploy.sh --backup-user=$acct (nie moze uzyc kopii roota, /root jest 0700)"
    fi

    local rootcron acctcron
    rootcron=$(mktemp) || die "mktemp failed"
    acctcron=$(mktemp) || die "mktemp failed"
    crontab_of_or_die root    "$rootcron"
    crontab_of_or_die "$acct" "$acctcron"

    # REV-20260803-036 F5 follow-up: this verb commits through cron_replace_all,
    # the same primitive deploy.sh --pause/--resume use, and that primitive is
    # deliberately NOT guarded by cron_paused_guard -- guarding it unconditionally
    # would make --pause refuse itself. Left alone, that means migrate-to-account
    # could run during an operator's own maintenance window and silently commit
    # an active managed block over (or next to) a paused one -- exactly the
    # "next ordinary writer undoes the pause" failure mode F5 exists to close,
    # just via a different verb than the ones already guarded inside lib-cron.sh.
    # Checked here, explicitly, before any other preflight work: cheaper to ask
    # "is either side paused" once than to reconstruct which four checks would
    # have to duplicate cron_paused_guard's own logic at every write site below.
    if cron_fullcron_paused "$rootcron" || cron_block_paused "$rootcron" zfs-backup-managed \
        || cron_block_paused "$rootcron" zfs-backup-host; then
        rm -f "$rootcron" "$acctcron"
        die "root's crontab is currently paused (deploy.sh --pause) -- migrating now would commit an active managed block during a maintenance window that is supposed to have nothing changing. Run deploy.sh --resume first, then retry. Nothing has been changed."
    fi
    if cron_fullcron_paused "$acctcron" || cron_block_paused "$acctcron" zfs-backup-managed \
        || cron_block_paused "$acctcron" zfs-backup-host; then
        rm -f "$rootcron" "$acctcron"
        die "'$acct's crontab is currently paused (deploy.sh --pause) -- run deploy.sh --resume first, then retry. Nothing has been changed."
    fi

    if grep -q '^# BEGIN zfs-backup-managed' "$rootcron"; then
        _have "root ma blok zarzadzany ($(grep -cE '^[0-9*]' "$rootcron") linii zadan lacznie)"
    else
        rm -f "$rootcron" "$acctcron"
        die "root has no managed block -- there is nothing to migrate. If the jobs already run on an account, this is done."
    fi
    if grep -q '^# BEGIN zfs-backup-managed' "$acctcron"; then
        rm -f "$rootcron" "$acctcron"
        die "'$acct' ALREADY has a managed block. Migrating on top of it would replace jobs that are already running as that account -- reconcile the two by hand first. Nothing has been changed."
    fi

    local raw cfg
    raw=$(grep -m1 '^# Source: ' "$rootcron" | sed -E 's/^# Source: (.*) -- .*/\1/')
    [ -n "$raw" ] || { rm -f "$rootcron" "$acctcron"; die "root's managed block has no '# Source:' line, so the config behind it is unknown. Rebuild one from 'crontab -l' before ownership can move."; }
    cfg=$(normalize_cron_source "$raw")
    # The pve2 shape: jobs running, source file gone. Regenerating is impossible,
    # and inventing an empty config would delete the live block (see c6c98c2).
    if [ -f "$cfg" ]; then _have "config istnieje ($cfg)"
    else
        # Counted BEFORE the cleanup, not inside the message. Measured on
        # metropolis pve2, 2026-08-01: the message read "while  cron line(s)
        # depend on it" and printed a grep error, because $rootcron had already
        # been removed one line above. The number is the whole point of this
        # refusal -- it is what tells the operator how much is riding on a file
        # that is not there.
        local ndep; ndep=$(grep -cE '^[0-9*]' "$rootcron")
        rm -f "$rootcron" "$acctcron"
        die "root's block names '$raw' as its source and that file does not exist, while $ndep cron line(s) depend on it. Rebuild the config from 'crontab -l' first (cron2conf.sh does this) -- this verb will not invent one."
    fi

    local target_cfg="$cfg" needs_move=0
    if runuser_test_r "$acct" "$cfg"; then
        _have "konto czyta config"
    else
        target_cfg="/etc/zfs-snapshot-all/$(basename "$cfg")"
        [ -e "$target_cfg" ] && { rm -f "$rootcron" "$acctcron"; die "'$acct' cannot read $cfg so it must move to $target_cfg -- but that file already exists. Reconcile them by hand; this verb will not overwrite a config it did not write."; }
        needs_move=1
        _todo "konto nie czyta configu -- faza prepare przeniesie: $cfg -> $target_cfg"
    fi

    # Lines root runs that the account's render will not reproduce.
    #
    # The render has to happen in phase 1, but on the normal host it depends on
    # phase 2's work: the config is still under /root, which the account cannot
    # read, so gen-cron run AS the account cannot open it. Found by the first
    # live preflight on metropolis pve1 (2026-08-01), where this aborted the
    # whole check after correctly reporting every other gap.
    #
    # So phase 1 renders from a THROWAWAY readable copy in its own temp
    # directory, exactly as the hand procedure did. This copy is never
    # installed, never named in a '# Source:' that survives, and is deleted
    # before phase 2 runs -- the real config is still MOVED, never copied,
    # which is the property REV-20260801-018 turns on.
    LOCAL_USER="$acct"
    local newblock renderfrom rendertmp=""
    newblock=$(mktemp) || die "mktemp failed"
    renderfrom="$cfg"
    if [ "$needs_move" -eq 1 ]; then
        rendertmp=$(mktemp -d) || die "mktemp -d failed"
        chmod 0755 "$rendertmp"
        cp "$cfg" "$rendertmp/$(basename "$cfg")" && chmod 0644 "$rendertmp/$(basename "$cfg")" \
            || { LOCAL_USER=""; rm -rf "$rendertmp"; rm -f "$rootcron" "$acctcron" "$newblock"
                 die "could not stage a readable copy of $cfg for the preview -- nothing has been changed."; }
        renderfrom="$rendertmp/$(basename "$cfg")"
    fi
    if ! gencron_as_target -c "$renderfrom" > "$newblock" 2>/dev/null || [ ! -s "$newblock" ]; then
        LOCAL_USER=""; [ -n "$rendertmp" ] && rm -rf "$rendertmp"
        rm -f "$rootcron" "$acctcron" "$newblock"
        die "gen-cron.sh could not render the block as '$acct' -- so what the account would actually run is unknown. Nothing has been changed."
    fi
    [ -n "$rendertmp" ] && { rm -rf "$rendertmp"; rendertmp=""; }

    # Can the account RUN what it would be given? Asked here, while nothing has
    # been touched, and separately from the workload comparison below -- which
    # strips exactly these paths and is therefore blind to this by design.
    assert_block_runnable_by "$acct" "$newblock"

    # ---- what the rendered jobs actually need ------------------------------
    #
    # After the render, not before: the requirement is a property of the JOBS,
    # and until they are rendered there are no jobs to ask about.
    capability_survey "$acct" "$newblock" || :

    if [ "$CAP_MISSING_ZFS_N" -eq 0 ]; then
        _have "delegacja ZFS wystarczy dla kazdego zadania w bloku"
    else
        _gap "brak delegacji ZFS dla zadan, ktore powstana:$CAP_MISSING_ZFS"
    fi

    if [ "$CAP_QN" -gt 0 ]; then
        if [ "$CAP_HELPER" -eq 0 ]; then
            _gap "blok prosi o quiesce na $CAP_QN datasetach, a konto w ogole nie dosiega helpera (brak $QUIESCE_HELPER_PATH albo reguly sudo) -- te linie beda konczyc sie kodem 3"
        elif [ "$CAP_MISSING_Q_N" -gt 0 ]; then
            _gap "konto dosiega helpera, ale whitelist NIE POKRYWA tych zrodel z -q:$CAP_MISSING_Q"
        else
            _have "quiesce pokryty dla wszystkich $CAP_QN zrodel, ktore o niego prosza"
        fi
    fi

    # Remote quiesce is granted on the SOURCE host, by whoever runs --join
    # there. Nothing readable from here proves it, so it is stated rather than
    # passed silently (REV-20260801-027 point 4).
    if [ "$CAP_REMOTE_Q" -eq 1 ]; then
        _todo "blok uzywa quiesce ZDALNEGO (snapget -q) -- grant zyje na hoscie ZRODLOWYM i nie da sie go stad sprawdzic; potwierdza go 'deploy.sh --join <pakiet> --allow-quiesce' wykonany tam"
    fi

    # The render carries the throwaway path in its '# Source:' line. Phase 4
    # installs from $target_cfg and would write that instead, so rewrite it now
    # -- a preview that differs from the install is worse than no preview
    # (REV-20260801-015 §1), even when the difference is "only" a comment.
    if [ "$needs_move" -eq 1 ]; then
        local fixsrc; fixsrc=$(mktemp) || die "mktemp failed"
        sed "s|^# Source: .* -- |# Source: $target_cfg -- |" "$newblock" > "$fixsrc" \
            && mv -f "$fixsrc" "$newblock"
    fi
    local theirs mine dropped hostlines
    theirs=$(managed_block_fingerprint < "$rootcron")
    mine=$(managed_block_fingerprint < "$newblock")
    dropped=$(comm -23 <(printf '%s\n' "$theirs") <(printf '%s\n' "$mine"))
    hostlines=$(mktemp) || die "mktemp failed"
    local orphans; orphans=$(mktemp) || die "mktemp failed"
    if [ -n "$dropped" ]; then
        # REV-20260801-021, separate observation: "the account's render does not
        # reproduce it" is NOT the same as "it is host-level". The first version
        # kept every dropped line, which means an unrecognised send or prune
        # would be quietly parked in root's crontab -- ownership split in half
        # without anyone deciding it, which is the very thing the host block was
        # introduced to stop.
        #
        # Only lines this tool RECOGNISES as host-level are carried. Today that
        # is the digest, which is one-per-host by construction. Anything else
        # dropped is a defect in the migration, not a line to file away, and it
        # stops the run by name.
        sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p' "$rootcron" \
        | grep -E '^[0-9*]' \
        | while IFS= read -r orig; do
              fp=$(printf '%s\n' "$orig" | job_identity)
              printf '%s\n' "$dropped" | grep -qxF -- "$fp" || continue
              case "$fp" in
                  *alert-digest.sh*) printf '%s\n' "$orig" >> "$hostlines" ;;
                  *)                 printf '%s\n' "$orig" >> "$orphans" ;;
              esac
          done
        if [ -s "$orphans" ]; then
            local norph; norph=$(grep -cE '^[0-9*]' "$orphans")
            warn "root runs these job(s) and the block rendered for '$acct' does not reproduce them, yet they are not host-level either:"
            sed 's/^/    /' "$orphans" >&2
            LOCAL_USER=""; rm -f "$rootcron" "$acctcron" "$newblock" "$hostlines" "$orphans"
            die "$norph job line(s) would belong to nobody after this migration. Leaving them in root's crontab would split one deployment between the tool and a human memory; dropping them would stop a backup silently. Fix the config so the account's render covers them, or move them out of the managed block deliberately, then re-run. Nothing has been changed."
        fi
        if [ -s "$hostlines" ]; then
            _have "linie ogolnohostowe do zachowania: $(grep -cE '^[0-9*]' "$hostlines") (trafia do wlasnego bloku roota, nie luzem)"
        fi
    fi
    rm -f "$orphans"

    echo
    if [ "$preflight_only" -eq 1 ]; then
        LOCAL_USER=""; rm -f "$rootcron" "$acctcron" "$newblock" "$hostlines"
        [ "$gaps" -eq 0 ] && { log "preflight czysty -- migracja moze isc"; return 0; }
        capability_remediation "$acct"
        die "preflight: $gaps brakujacych zdolnosci (wyzej). Nic nie zmieniono."
    fi
    if [ "$gaps" -gt 0 ]; then
        capability_remediation "$acct"
        LOCAL_USER=""; rm -f "$rootcron" "$acctcron" "$newblock" "$hostlines"
        die "preflight found capabilities this account does not have (listed above). Provision them first -- every one of them fails closed at run time, which means failing cron jobs and no backups, not silent damage. Nothing has been changed."
    fi

    # ---- phase 3: one combined preview ---------------------------------------
    local rootnew; rootnew=$(mktemp) || die "mktemp failed"
    awk '/^# BEGIN zfs-backup-managed/{s=1} s==0{print} /^# END zfs-backup-managed/{s=0}' "$rootcron" > "$rootnew"
    set_host_block "$rootnew" "$hostlines"

    echo "=== root: $(grep -cE '^[0-9*]' "$rootcron") linii zadan -> $(grep -cE '^[0-9*]' "$rootnew") ==="
    diff -u --label "root (teraz)" --label "root (po)" "$rootcron" "$rootnew" || :
    echo
    # REV-20260801-021: the account side used to diff /dev/null against the
    # proposed block, which shows what will be ADDED and can never show what
    # would be REMOVED. Build the exact post-install crontab instead --
    # unmanaged lines preserved, any existing managed block replaced -- and diff
    # the real one against that. The verb refuses an existing managed block
    # anyway, so today the removal half is always empty; a preview that can only
    # be right by luck is not a preview.
    local acctnew; acctnew=$(mktemp) || die "mktemp failed"
    awk '/^# BEGIN zfs-backup-managed/{s=1} s==0{print} /^# END zfs-backup-managed/{s=0}' "$acctcron" > "$acctnew"
    cat "$newblock" >> "$acctnew"
    echo "=== $acct: $(grep -cE '^[0-9*]' "$acctcron") linii zadan -> $(grep -cE '^[0-9*]' "$acctnew") ==="
    diff -u --label "$acct (teraz)" --label "$acct (po)" "$acctcron" "$acctnew" || :
    rm -f "$acctnew"
    echo
    [ "$needs_move" -eq 1 ] && echo "config:  $cfg  ->  $target_cfg   (PRZENIESIONY, nie kopiowany)"
    echo

    if [ "$yes" -ne 1 ]; then
        read -rp "Przeniesc wlascicielstwo zadan root -> $acct? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK) ;;
            *) LOCAL_USER=""; rm -f "$rootcron" "$acctcron" "$newblock" "$hostlines" "$rootnew"
               die "not confirmed -- neither crontab was touched and the config was not moved" ;;
        esac
    fi

    # ---- phase 2/4: prepare, then commit -------------------------------------
    # Which side has actually been written. Without this the rollback tries to
    # restore a crontab nothing ever touched, and when THAT fails -- which it
    # does when the failure being rolled back was "this crontab is not
    # writable" -- it reports a scary "NOT restored" for a file that was never
    # in danger. Found by the live rollback test on metropolis pve1,
    # 2026-08-01: the run printed "'zfsbackup' crontab NOT restored" and then
    # "both crontabs restored" two lines later. Root's WAS restored byte for
    # byte; the account's had never changed. Both sentences were defensible and
    # together they were useless.
    local did_root=0 did_acct=0
    MTA_ROLLBACK_OK=1
    _mta_rollback() {
        MTA_ROLLBACK_OK=1
        warn "rolling back"
        if [ "$did_root" -eq 1 ]; then
            if cron_replace_all root "$rootcron"; then warn "  root's crontab restored"
            else warn "  ROOT CRONTAB NOT RESTORED ($CRON_ERR) -- restore by hand from $rootcron"; MTA_ROLLBACK_OK=0; fi
        else
            warn "  root's crontab was never written"
        fi
        if [ "$did_acct" -eq 1 ]; then
            if cron_replace_all "$acct" "$acctcron"; then warn "  '$acct' crontab restored"
            else warn "  '$acct' CRONTAB NOT RESTORED ($CRON_ERR) -- restore by hand from $acctcron"; MTA_ROLLBACK_OK=0; fi
        else
            warn "  '$acct' crontab was never written"
        fi
        if [ "$needs_move" -eq 1 ] && [ -f "$target_cfg" ] && [ ! -f "$cfg" ]; then
            if mv -f "$target_cfg" "$cfg"; then warn "  config moved back to $cfg"
            else warn "  CONFIG LEFT AT $target_cfg -- move it back by hand"; MTA_ROLLBACK_OK=0; fi
        fi
    }

    if [ "$needs_move" -eq 1 ]; then
        install -d -m 0755 /etc/zfs-snapshot-all || { LOCAL_USER=""; die "could not create /etc/zfs-snapshot-all -- nothing changed"; }
        mv -f "$cfg" "$target_cfg" || { LOCAL_USER=""; die "could not move $cfg to $target_cfg -- nothing changed"; }
        chmod 0644 "$target_cfg" || :
        log "config moved to $target_cfg (0644, readable by '$acct')"
    fi

    # ---- last look before anything is written ------------------------------
    #
    # The owner chose option (b) on 2026-08-02: the privileged grant stays a
    # separate, deliberate command, and this verb re-checks instead of running
    # it. Which makes this re-check the load-bearing half of that choice -- the
    # operator went away, ran something in another window, and came back. What
    # they actually ran is not knowable from here. Phase 1 validated a state
    # that no longer has to be the state now.
    #
    # Cheap: the block is already rendered, so this is the same two loops again.
    if ! capability_survey "$acct" "$newblock"; then
        [ "$needs_move" -eq 1 ] && [ -f "$target_cfg" ] && mv -f "$target_cfg" "$cfg"
        LOCAL_USER=""
        printf '%s
' "$CAP_MISSING_ZFS$CAP_MISSING_Q" >&2
        capability_remediation "$acct" >&2
        die "the capabilities checked in the preflight are NOT all there now, so the block would move to an account that cannot run it (listed above). Neither crontab was written; the config is back where it was."
    fi

    # REV-20260802-034 F3: through the shared writer, not a bare `crontab`.
    #
    # This is NOT wrapped in a lock spanning the whole transaction (root's
    # write, then the account's install, then verify) even though both touch
    # crontabs the same run cares about -- that design was sketched in the
    # F2 response and is wrong. gencron_as_target below spawns gen-cron.sh as
    # a SEPARATE PROCESS, and since REV-034 F2 it acquires the account's OWN
    # lock to install its block. Holding that same lock here, in the PARENT,
    # while WAITING for the child to finish would be a self-inflicted
    # deadlock: the child blocks on a lock the parent holds, and the parent
    # is blocked on the child. Each mutation is therefore its own locked,
    # verified operation -- root's replace here, the account's install via
    # gen-cron.sh's already-locked path, and a rollback restore of either
    # side through cron_replace_all again -- sequenced by did_root/did_acct
    # exactly as before, not by a lock held across the gap between them.
    if ! cron_replace_all root "$rootnew"; then
        [ "$needs_move" -eq 1 ] && mv -f "$target_cfg" "$cfg"
        LOCAL_USER=""; die "could not write root's crontab ($CRON_ERR) -- nothing else was attempted and root still runs its block"
    fi
    did_root=1
    log "root's collector block removed; host-level lines kept in their own block"

    if ! gencron_as_target -c "$target_cfg" --install; then
        _mta_rollback; LOCAL_USER=""
        if [ "$MTA_ROLLBACK_OK" -eq 1 ]; then
            die "installing the block as '$acct' failed. Rolled back completely -- root runs its jobs again and nothing was left half-moved."
        fi
        die "installing the block as '$acct' failed AND the rollback did not complete (see the lines above). This host is in a mixed state and needs a human NOW."
    fi
    did_acct=1

    # ---- phase 5: verify as the actual owners --------------------------------
    local vr va; vr=$(mktemp); va=$(mktemp)
    crontab_of_or_die root    "$vr"
    crontab_of_or_die "$acct" "$va"
    local nr na
    nr=$(grep -c '^# BEGIN zfs-backup-managed' "$vr" || :)
    na=$(grep -c '^# BEGIN zfs-backup-managed' "$va" || :)
    if [ "$nr" != 0 ] || [ "$na" != 1 ]; then
        rm -f "$vr" "$va"; _mta_rollback; LOCAL_USER=""
        [ "$MTA_ROLLBACK_OK" -eq 1 ]             && die "after the switch the blocks are not where they should be (root=$nr, $acct=$na). Rolled back completely."
        die "after the switch the blocks are not where they should be (root=$nr, $acct=$na) AND the rollback did not complete (see above). This host needs a human NOW."
    fi
    if [ -s "$hostlines" ] && ! grep -qF "$HOST_BEGIN" "$vr"; then
        rm -f "$vr" "$va"; _mta_rollback; LOCAL_USER=""
        [ "$MTA_ROLLBACK_OK" -eq 1 ]             && die "the host-level block did not survive the switch. Rolled back completely."
        die "the host-level block did not survive the switch AND the rollback did not complete (see above). This host needs a human NOW."
    fi
    rm -f "$vr" "$va"

    log "ownership migrated: root -> $acct. Config: $target_cfg"
    log "crontab backups kept for now: $rootcron (root), $acctcron ($acct) -- hold them until one tick has run clean"
    rm -f "$newblock" "$hostlines" "$rootnew"
    LOCAL_USER=""
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
    log "client '$name' paused (PAUSED_LOCAL). Managed jobs and labeled manual runs now exit 'SKIPPED: relationship $name is paused' before any snapshot/SSH work."
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
    local -a ssh_opts=(-i "$LOAD_KEYFILE" -p "$LOAD_PORT" -o BatchMode=yes \
        -o "HostKeyAlias=$LOAD_ALIAS" -o "UserKnownHostsFile=$LOAD_ALIAS_KH" \
        -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null \
        -o CheckHostIP=no -o ConnectTimeout=15)
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
    echo "Klient:            $CLIENT_NAME"
    echo "Stan:              ${STATE:-unknown}"
    if client_paused "$name"; then
        local PAUSED_AT="" PAUSED_REASON=""
        # shellcheck disable=SC1090
        . "$(pause_marker_path "$name")"
        echo "Pauza:             PAUSED_LOCAL od ${PAUSED_AT:-?}${PAUSED_REASON:+ (powod: $PAUSED_REASON)}"
        echo "                   joby i reczne uruchomienia Z etykieta '-L $name' sa pomijane;"
        echo "                   reczne uruchomienie BEZ etykiety NIE jest blokowane (pauza logiczna,"
        echo "                   nie granica bezpieczenstwa). Wznowienie: $0 resume-client $name"
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
        if bash "$SNAPGET" -n $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$base"; then
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
    # Without this, LOCAL_USER is unset here and every crontab operation below
    # silently targets ROOT -- on a collector with a dedicated account that
    # means reading the wrong crontab, comparing against the wrong '# Source:',
    # and, if the comparison had passed, rewriting the wrong user's jobs.
    # Found live on metropolis pve1, 2026-08-01: teardown refused because it was
    # looking at root's block while the client's lines were in the account's.
    # assert_cron_config_matches_installed caught it, which is the third time
    # today a guard turned a defect into a message instead of an incident.
    read_server_conf
    [ -n "$recorded_cron_config" ] && CRON_CONFIG="$recorded_cron_config"
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

    bash "$DEPLOY" --unpair --peer="$PEER_HOST" || die "deploy.sh --unpair failed -- see above"

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

    log "client '$name' removed locally. Run the peer-side commands deploy.sh --unpair printed above."
}

# ------------------------------------------------------------------------------
# Guarded (same idiom as update-control.sh) so test/zfsbackup/run.sh can
# `source` this file to reach the pure helper functions without also running
# the dispatch below. A real invocation always has BASH_SOURCE[0]==$0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        setup-server)     shift; cmd_setup_server "$@" ;;
        # REV-20260810-097 F3: the canonical public LOCAL entrypoint is the bare
        # high-level form `zfs-backup.sh --source=X --target=Y` (ACTIVE-WORK-PLAN
        # Phase 5). `local-backup` stays as an internal alias reaching the same
        # logic, but an operator is never required to learn it.
        --source=*|--target=*) cmd_local_backup "$@" ;;
        local-backup)     shift; cmd_local_backup "$@" ;;
        add-client)       shift; cmd_add_client "$@" ;;
        seed)             shift; cmd_seed "$@" ;;
        final-catchup)    shift; cmd_final_catchup "$@" ;;
        set-endpoint)     shift; cmd_set_endpoint "$@" ;;
        verify-endpoint)  shift; cmd_verify_endpoint "$@" ;;
        activate-client)  shift; cmd_activate_client "$@" ;;
        migrate-profile)  shift; cmd_migrate_profile "$@" ;;
        audit-source-retention) shift; cmd_audit_source_retention "$@" ;;
        migrate-to-account) shift; cmd_migrate_to_account "$@" ;;
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
