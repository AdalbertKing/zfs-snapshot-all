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
# Commands (see also DEPLOY-UX-AGREED-POSITION.md for the full model):
#   zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE]
#   zfs-backup.sh add-client NAME --peer=HOST --datasets="A B" [--target=..] [--port=N]
#   zfs-backup.sh activate-client NAME [--yes]
#   zfs-backup.sh status [NAME]
#   zfs-backup.sh test NAME
#   zfs-backup.sh remove-client NAME
#
# Two separate process points (agreed position §8): add-client (here) makes the
# pairing package; the peer runs deploy.sh --join by hand, unchanged, backend;
# activate-client (here) finishes the config, dry-runs, and installs on ONE
# explicit confirmation. Nothing is installed to cron before that confirmation
# (agreed position §10 -- no held/paused cron entry during seed either).
#
# Only the 'standard' profile is implemented (hourly keep=24, daily keep=14,
# thresholds matching the values already proven in production on pve0's
# rpool/data archive jobs). 'frequent'/'archive' profiles are declared but not
# implemented -- future work, not silently approximated here.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
SNAPGET="$SCRIPT_DIR/snapget.sh"
GENCRON="$SCRIPT_DIR/gen-cron.sh"

# Mirrors deploy.sh's own peer-pairing state locations exactly (see
# PAIRING-DESIGN.md) -- this file reads what --pair/--join already write, it
# never invents a parallel record of the same facts.
PEER_STATE_DIR="/etc/zfs-snapshot-all/peers"
PEER_KEY_DIR="/root/.ssh/pairing"

SERVER_CONF="/etc/zfs-snapshot-all/zfs-backup.conf"
CLIENTS_DIR="/etc/zfs-snapshot-all/clients"

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
zfs-backup.sh -- simple two-host backup deploy (pve1=appliance, pve2=source)

Usage:
  zfs-backup.sh setup-server [--target=POOL/PATH] [--config=FILE]
  zfs-backup.sh add-client NAME --peer=HOST --datasets="A B" [--target=X] [--port=N]
  zfs-backup.sh activate-client NAME [--yes]
  zfs-backup.sh status [NAME]
  zfs-backup.sh test NAME
  zfs-backup.sh remove-client NAME

Run on the backup appliance (pve1). The peer (pve2) side is unchanged:
  ./deploy.sh --join=/path/to/package.tgz

See docs/discussions/DEPLOY-UX-AGREED-POSITION.md for the model this follows.
EOF
}

# Identical to deploy.sh's own peer_label(): the key file name, manifest name
# and account name are all built from this, and it must produce the SAME
# string deploy.sh already used, or this script would look for the wrong files.
peer_label() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

client_name_valid() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}
client_conf_path() { echo "$CLIENTS_DIR/$1.conf"; }
peer_manifest_path() { echo "$PEER_STATE_DIR/$1.conf"; }

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

read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    [ -r "$SERVER_CONF" ] || return 0
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
}

# The two 'standard' profile templates. Both fields together (send_schedule +
# prune_schedule/pattern/keep + monitor_warn/monitor_crit) in ONE template is
# exactly what gen-cron.sh's [dataset:] section type supports natively
# ("create+send/pull + inline self-prune (own path)") -- no [prune:] section
# needed for the simple one-client-one-dataset case this profile targets.
# Thresholds match the values already proven live on pve0's archive jobs
# (90m/150m hourly, 30h/48h daily) rather than invented numbers.
STANDARD_TEMPLATES='
[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	keep           = 24
	monitor_warn   = 90m
	monitor_crit   = 150m

[template:standard_daily]
	send_schedule  = 12 0 * * *
	prefix         = automated_daily_
	notify_word    = backup
	prune_schedule = 40 0 * * *
	pattern        = automated_daily
	keep           = 14
	monitor_warn   = 30h
	monitor_crit   = 48h
'

ensure_cron_config() {
    local file="$1"
    if [ ! -e "$file" ]; then
        mkdir -p "$(dirname "$file")" || die "could not create $(dirname "$file")"
        {
            echo "[defaults]"
            echo "	host_label = $(hostname -s)"
        } > "$file" || die "could not create $file"
        log "created new cron config $file"
    fi
    if ! grep -q '^\[template:standard_hourly\]' "$file" 2>/dev/null; then
        printf '%s\n' "$STANDARD_TEMPLATES" >> "$file" || die "could not append standard templates to $file"
        log "added [template:standard_hourly]/[template:standard_daily] to $file"
    fi
}

# ------------------------------------------------------------------------------
cmd_setup_server() {
    local target="" config=""
    for a in "$@"; do
        case "$a" in
            --target=*) target="${a#*=}" ;;
            --config=*) config="${a#*=}" ;;
            *) die "setup-server: unknown option $a" ;;
        esac
    done

    bash "$DEPLOY" || die "deploy.sh bootstrap failed -- fix that before continuing"

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
    [ -z "$config" ] && config="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s).conf}"

    zfs create -p "$target" 2>/dev/null || zfs list "$target" >/dev/null 2>&1 || die "could not create or find target dataset $target"

    mkdir -p "$(dirname "$SERVER_CONF")" || die "could not create $(dirname "$SERVER_CONF")"
    {
        echo "# zfs-backup.sh server config -- edit by hand if needed, or re-run setup-server"
        echo "DEFAULT_TARGET=$target"
        echo "CRON_CONFIG=$config"
    } > "$SERVER_CONF" || die "could not write $SERVER_CONF"
    chmod 0644 "$SERVER_CONF"

    ensure_cron_config "$config"

    log "server ready: target=$target, cron config=$config"
}

# ------------------------------------------------------------------------------
cmd_add_client() {
    local name="${1:-}"; shift || true
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    local peer="" datasets="" target="" port=""
    for a in "$@"; do
        case "$a" in
            --peer=*)     peer="${a#*=}" ;;
            --datasets=*) datasets="${a#*=}" ;;
            --target=*)   target="${a#*=}" ;;
            --port=*)     port="${a#*=}" ;;
            *) die "add-client: unknown option $a" ;;
        esac
    done
    [ -n "$peer" ]     || die "add-client requires --peer=HOST"
    [ -n "$datasets" ] || die "add-client requires --datasets=\"A B\""

    local cpath; cpath=$(client_conf_path "$name")
    [ -e "$cpath" ] && die "client '$name' already exists ($cpath) -- use activate-client or remove-client first"

    read_server_conf
    if [ -z "$target" ]; then
        target="$DEFAULT_TARGET"
        [ -n "$target" ] || die "no --target given and no default set -- run setup-server first, or pass --target=POOL/PATH"
    fi

    local -a pair_args=(--pair --role=pull --peer="$peer" --peer-datasets="$datasets" --target="$target")
    [ -n "$port" ] && pair_args+=(--port="$port")
    bash "$DEPLOY" "${pair_args[@]}" || die "deploy.sh --pair failed -- see above"

    mkdir -p "$CLIENTS_DIR" || die "could not create $CLIENTS_DIR"
    {
        echo "# zfs-backup.sh client record -- managed by add-client/activate-client/remove-client"
        echo "CLIENT_NAME=$name"
        echo "PEER_HOST=$peer"
        echo "STATE=pending_enroll"
        echo "CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$cpath" || die "could not write $cpath"
    chmod 0600 "$cpath"

    log "client '$name' created, state=pending_enroll"
    log "next: copy the package above to $peer and run there:  ./deploy.sh --join=<package>"
    log "then here:  $0 activate-client $name"
}

# ------------------------------------------------------------------------------
cmd_activate_client() {
    local name="${1:-}"; shift || true
    local yes=0
    for a in "$@"; do
        case "$a" in
            --yes) yes=1 ;;
            *) die "activate-client: unknown option $a" ;;
        esac
    done
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name' -- run add-client first"
    # shellcheck disable=SC1090
    . "$cpath"
    [ "${STATE:-}" = "pending_enroll" ] || [ "${STATE:-}" = "active" ] \
        || die "client '$name' is in state '${STATE:-unknown}' -- expected pending_enroll or active"

    local label; label=$(peer_label "$PEER_HOST")
    local mpath; mpath=$(peer_manifest_path "$label")
    [ -r "$mpath" ] || die "no pairing manifest for '$PEER_HOST' at $mpath -- run add-client first"
    # shellcheck disable=SC1090
    . "$mpath"

    log "refreshing draft config from $PEER_HOST (also confirms --join has run there)..."
    bash "$DEPLOY" --pair --peer="$PEER_HOST" --draft-config \
        || die "could not reach $PEER_HOST or list its datasets -- has --join run there yet?"

    read_server_conf
    local cronfile="${CRON_CONFIG:-$SCRIPT_DIR/jobs.$(hostname -s).conf}"
    ensure_cron_config "$cronfile"

    local account="${PEER_SAVED_ACCOUNT:-root}"
    local keyfile; keyfile=$(local_keyfile_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local knownhosts; knownhosts=$(local_knownhosts_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local port="${PEER_SAVED_PORT:-22}"
    local flags="-K $keyfile"
    [ -f "$knownhosts" ] && flags="$flags -k $knownhosts" || warn "no pinned host key at $knownhosts -- job would fall back to accept-new"
    [ "$port" != "22" ] && flags="$flags -p $port"

    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing, re-run add-client"

    local ds localpath added=0 skipped=0
    local -a managed=()
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$label/$ds"
        managed+=("$localpath")
        if grep -qF "[dataset:$localpath]" "$cronfile" 2>/dev/null; then
            warn "[dataset:$localpath] already present in $cronfile -- leaving it untouched"
            skipped=$((skipped + 1))
            continue
        fi
        {
            echo
            echo "[dataset:$localpath]"
            echo "	use_template = standard_hourly,standard_daily"
            echo "	src          = ${account}@${PEER_HOST}:${ds}"
            echo "	flags        = $flags"
            echo "	notify       = ${name}-$(basename "$ds")"
        } >> "$cronfile" || die "could not append [dataset:$localpath] to $cronfile"
        added=$((added + 1))
    done
    log "cron config: $added dataset(s) added, $skipped already present -- $cronfile"

    log "validating generated config (no install yet)..."
    bash "$GENCRON" -c "$cronfile" >/dev/null || die "gen-cron.sh rejected $cronfile -- fix it by hand before retrying (see output above)"

    log "dry-run test of each dataset (snapget.sh -n)..."
    local failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$label/$ds"
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $flags "${account}@${PEER_HOST}:${ds}" "$localpath"; then
            log "  OK: $ds -> $localpath"
        else
            warn "  FAILED: $ds -> $localpath"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed the dry-run -- not installing. Fix and re-run activate-client."

    echo
    echo "Klient:        $name"
    echo "Peer:          $PEER_HOST"
    echo "Zrodla:        $PEER_SAVED_DATASETS"
    echo "Cel:           $PEER_SAVED_TARGET/$label"
    echo "Tryb:          pull"
    echo "Profil:        standard (hourly keep=24, daily keep=14)"
    echo "Test:          OK ($( printf '%s' "$PEER_SAVED_DATASETS" | wc -w ) dataset(s))"
    echo

    if [ "$yes" -ne 1 ]; then
        read -rp "Aktywowac backup? [t/N] " ans
        case "$ans" in t|T|tak|TAK) ;; *) die "not confirmed -- nothing installed" ;; esac
    fi

    bash "$GENCRON" -c "$cronfile" --install || die "gen-cron.sh --install failed"

    {
        cat "$cpath"
        echo "STATE=active"
        echo "ACTIVATED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "MANAGED_DATASETS=\"${managed[*]}\""
        echo "CRON_CONFIG=$cronfile"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    chmod 0600 "$cpath"

    log "client '$name' active."
}

# ------------------------------------------------------------------------------
cmd_status() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        [ -d "$CLIENTS_DIR" ] || { log "no clients yet"; return 0; }
        local f n
        for f in "$CLIENTS_DIR"/*.conf; do
            [ -e "$f" ] || continue
            ( CLIENT_NAME=""; PEER_HOST=""; STATE=""
              # shellcheck disable=SC1090
              . "$f"
              printf '%-20s peer=%-20s state=%s\n' "$CLIENT_NAME" "$PEER_HOST" "$STATE" )
        done
        return 0
    fi
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    cat "$cpath"
}

# ------------------------------------------------------------------------------
cmd_test() {
    local name="${1:-}"
    [ -n "$name" ] || die "test requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    [ "${STATE:-}" = "active" ] || die "client '$name' is not active (state=${STATE:-unknown})"
    local label; label=$(peer_label "$PEER_HOST")
    local mpath; mpath=$(peer_manifest_path "$label")
    # shellcheck disable=SC1090
    . "$mpath"
    local account="${PEER_SAVED_ACCOUNT:-root}"
    local keyfile; keyfile=$(local_keyfile_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local knownhosts; knownhosts=$(local_knownhosts_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local port="${PEER_SAVED_PORT:-22}"
    local flags="-K $keyfile"
    [ -f "$knownhosts" ] && flags="$flags -k $knownhosts"
    [ "$port" != "22" ] && flags="$flags -p $port"

    local ds failed=0
    for ds in $PEER_SAVED_DATASETS; do
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $flags "${account}@${PEER_HOST}:${ds}" "$PEER_SAVED_TARGET/$label/$ds"; then
            log "  OK: $ds"
        else
            warn "  FAILED: $ds"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed"
    log "all datasets OK"
}

# ------------------------------------------------------------------------------
# Removes exactly the [dataset:X] sections this client owns (tracked in
# MANAGED_DATASETS at activation time), never anything else in the shared
# host config file -- other clients' stanzas and hand-written sections must
# survive untouched.
remove_managed_sections() {
    local file="$1"; shift
    local -a targets=("$@")
    local tmp; tmp=$(mktemp) || die "mktemp failed"
    local ds header skip=0 in_target=0
    local -a headers=()
    for ds in "${targets[@]}"; do headers+=("[dataset:$ds]"); done
    while IFS= read -r line; do
        case "$line" in
            \[*\])
                in_target=0
                for header in "${headers[@]}"; do
                    [ "$line" = "$header" ] && in_target=1
                done
                ;;
        esac
        [ "$in_target" -eq 1 ] || printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    mv -f "$tmp" "$file" || die "could not update $file"
}

cmd_remove_client() {
    local name="${1:-}"
    [ -n "$name" ] || die "remove-client requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    [ "${STATE:-}" = "removed" ] && die "client '$name' is already removed"

    if [ -n "${MANAGED_DATASETS:-}" ] && [ -n "${CRON_CONFIG:-}" ] && [ -f "$CRON_CONFIG" ]; then
        log "removing this client's [dataset:] sections from $CRON_CONFIG"
        # shellcheck disable=SC2086
        remove_managed_sections "$CRON_CONFIG" $MANAGED_DATASETS
        bash "$GENCRON" -c "$CRON_CONFIG" --install || die "gen-cron.sh --install failed while removing '$name' -- fix $CRON_CONFIG by hand"
    else
        warn "no managed dataset list on file (client was never activated?) -- skipping cron removal"
    fi

    bash "$DEPLOY" --unpair --peer="$PEER_HOST" || die "deploy.sh --unpair failed -- see above"

    {
        cat "$cpath"
        echo "STATE=removed"
        echo "REMOVED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    log "client '$name' removed locally. Run the peer-side commands deploy.sh --unpair printed above."
}

# ------------------------------------------------------------------------------
case "${1:-}" in
    setup-server)    shift; cmd_setup_server "$@" ;;
    add-client)      shift; cmd_add_client "$@" ;;
    activate-client) shift; cmd_activate_client "$@" ;;
    status)          shift; cmd_status "$@" ;;
    test)            shift; cmd_test "$@" ;;
    remove-client)   shift; cmd_remove_client "$@" ;;
    -h|--help|"")    usage; exit 0 ;;
    *) echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
esac
