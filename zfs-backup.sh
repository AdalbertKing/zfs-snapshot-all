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
# Only the 'standard' profile is implemented -- values approved by the owner
# 2026-07-30: hourly retain 24, daily retain 7, weekly retain 4, monthly
# retain 12. Daily/weekly/monthly run at midnight with quiesce=agent (owner:
# "z flush koherentne" -- application-consistent via the Proxmox guest
# agent), matching this project's own established convention (see
# jobs.11.11.v4.conf: hourly plain, daily/weekly/monthly/annual quiesced).
# 'frequent'/'archive' profiles are declared but not implemented -- future
# work, not silently approximated here.
#
# REV-20260730-003 (two independent review passes, same day) found this first
# pass still missing several things a "generic competent admin" UX needs:
# HostKeyAlias-based endpoint independence, fail-closed on a missing pinned
# host key, transactional config edits (validate/dry-run BEFORE touching the
# real file, atomic swap + rollback-on-install-failure only after
# confirmation), a canonical-path (not basename) crontab-source check, and
# visibility into inherited `zfs allow` grants. All addressed in this pass.
# NOT yet addressed (reviewer explicitly said hold off until these): the
# seed/VPN-endpoint state machine, an `enroll`-style command on the peer, and
# human-readable `status` output -- these are real, larger product-UX work,
# not safety fixes, and are left for a follow-up pass.
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

# REV-20260730-003 F1/F2 (both review passes): the generated job must use a
# stable identity (HostKeyAlias) so a later LAN->VPN endpoint change is not,
# from OpenSSH's point of view, a change of host at all -- and a missing
# pinned host key must be a hard failure, never a silent fall-back to
# accept-new. `-o HostKeyAlias=X` makes ssh look up known_hosts under the
# alias X instead of the real hostname/IP, so the pinned-key FILE has to
# carry an entry keyed by that alias -- deploy.sh's own pinned file is keyed
# by the real host (ssh-keyscan's own output), so this derives a SECOND,
# alias-keyed file from the same already-verified key material rather than
# writing to deploy.sh's file at all (this file stays deploy.sh's, read-only
# from here, per the agreed position's "no changes to deploy.sh's public
# surface").
host_key_alias() { echo "zfs-client-$1"; }

# Returns the alias-keyed known_hosts path on success, or a non-zero exit and
# no output if there is no pinned key yet to derive it from -- callers must
# treat that as fatal (F2), never as "fall back to accept-new".
ensure_alias_known_hosts() {
    local label="$1" user="$2" port="$3"
    local src; src=$(local_knownhosts_path "$label" "$user")
    [ -f "$src" ] || return 1
    local keyline; keyline=$(grep -v '^#' "$src" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
    [ -n "$keyline" ] || return 1
    local rest; rest=$(printf '%s' "$keyline" | cut -d' ' -f2-)
    [ -n "$rest" ] || return 1
    local alias; alias=$(host_key_alias "$label")
    local dst="${src%_known_hosts}_alias_known_hosts"
    if [ "$port" != "22" ]; then
        printf '[%s]:%s %s\n' "$alias" "$port" "$rest" > "$dst" || return 1
    else
        printf '%s %s\n' "$alias" "$rest" > "$dst" || return 1
    fi
    chmod 0600 "$dst" 2>/dev/null
    printf '%s' "$dst"
}

# REV-20260730-003 F8 (review 1): show effective `zfs allow` at the target
# dataset AND every ancestor, so an inherited grant from an unrelated earlier
# relationship is visible before the admin confirms activation -- `zfs allow
# <ds>` only ever shows what was granted AT that exact dataset, never what a
# parent already grants (found live during --unpair work: a revoked grant did
# not mean lost access, see PAIRING-DESIGN.md). This does not try to compute
# "this relation's grant" vs "inherited" automatically -- it surfaces the raw
# picture at every level and leaves the judgment to the admin, since telling
# them apart programmatically needs more than this pass's scope.
show_effective_grants() {
    local ds="$1" account="$2" peer="$3" keyfile="$4" knownhosts="$5" alias="$6" port="$7"
    local -a opts=(-i "$keyfile" -p "$port" -o BatchMode=yes -o "HostKeyAlias=$alias" -o UserKnownHostsFile="$knownhosts" -o StrictHostKeyChecking=yes)
    local path="" seg
    IFS='/' read -ra _segs <<< "$ds"
    for seg in "${_segs[@]}"; do
        path="${path:+$path/}$seg"
        echo "    zfs allow $path :"
        ssh "${opts[@]}" "${account}@${peer}" "zfs allow '$path'" 2>&1 | sed 's/^/      /'
    done
}

read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    [ -r "$SERVER_CONF" ] || return 0
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
}

# The 'standard' profile's four templates, values approved by the owner
# 2026-07-30: retain -H24/-D7/-W4/-M12. Daily/weekly/monthly send_schedule is
# midnight (owner: "srodek nocy, najlepiej o 00:00") with quiesce=agent for an
# application-consistent snapshot ("z flush koherentne") -- hourly stays
# plain, matching this project's own established convention (jobs.11.11.v4.conf:
# hourly plain, daily/weekly/monthly/annual quiesced). 'retain=', not 'keep=':
# gen-cron.sh's 'keep=' auto-derives a -H/-D/... flag from TIER_LETTER, keyed
# by the CANONICAL tier name (hourly/daily/...) -- these templates are named
# standard_<tier> to avoid colliding with a host's own hand-maintained
# hourly/daily/... templates in a DIFFERENT config file, so 'keep=' would fail
# to resolve a letter for them (found live, REV-20260730-001 fix commit
# 7ebfbf7). 'retain=' is the raw-flag escape hatch for exactly this case.
STANDARD_TEMPLATE_NAMES="standard_hourly standard_daily standard_weekly standard_monthly"

STANDARD_TEMPLATE_standard_hourly='
[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
	monitor_warn   = 90m
	monitor_crit   = 150m
'
STANDARD_TEMPLATE_standard_daily='
[template:standard_daily]
	send_schedule  = 0 0 * * *
	prefix         = automated_daily_
	notify_word    = backup
	quiesce        = agent
	prune_schedule = 10 0 * * *
	pattern        = automated_daily
	retain         = -D7
	monitor_warn   = 30h
	monitor_crit   = 48h
'
STANDARD_TEMPLATE_standard_weekly='
[template:standard_weekly]
	send_schedule  = 0 0 * * 0
	prefix         = automated_weekly_
	notify_word    = backup
	quiesce        = agent
	prune_schedule = 20 0 * * 0
	pattern        = automated_weekly
	retain         = -W4
	monitor_warn   = 9d
	monitor_crit   = 12d
'
STANDARD_TEMPLATE_standard_monthly='
[template:standard_monthly]
	send_schedule  = 0 0 1 * *
	prefix         = automated_monthly_
	notify_word    = backup
	quiesce        = agent
	prune_schedule = 30 0 1 * *
	pattern        = automated_monthly
	retain         = -M12
'

# REV-20260730-003 F8 (review 2): checks EACH template independently and
# appends only what is actually missing -- a file with standard_hourly but
# missing standard_daily/weekly/monthly (hand-edited, or from an older
# version of this script) was previously considered "complete" because only
# standard_hourly was ever checked, AND a single-blob append would have
# duplicated whatever templates were already present.
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
    local t varname added=""
    for t in $STANDARD_TEMPLATE_NAMES; do
        grep -q "^\[template:$t\]" "$file" 2>/dev/null && continue
        varname="STANDARD_TEMPLATE_$t"
        printf '%s\n' "${!varname}" >> "$file" || die "could not append [template:$t] to $file"
        added="$added $t"
    done
    [ -n "$added" ] && log "added missing standard profile template(s) to $file:$added"
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
# are not the same file, and that gap is exactly the class of bug this check
# exists to close. A relative name in the crontab's own '# Source:' line is
# also ambiguous on its own: gen-cron.sh's default `-c` resolution is relative
# to ITS OWN directory, not to whatever directory happened to be the caller's
# cwd, so a bare "jobs.pve0.v4.conf" is normalized against $SCRIPT_DIR (where
# every config this script deals with actually lives), never against the
# current working directory of whoever is running zfs-backup.sh right now.
normalize_cron_source() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) p="$SCRIPT_DIR/$p" ;;
    esac
    readlink -f "$p" 2>/dev/null || printf '%s' "$p"
}
assert_cron_config_matches_installed() {
    local file="$1" raw existing want
    raw=$(crontab -l 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
    [ -n "$raw" ] || return 0
    existing=$(normalize_cron_source "$raw")
    want=$(normalize_cron_source "$file")
    [ "$existing" = "$want" ] && return 0
    die "the crontab's managed block was generated from '$raw' (resolved: $existing), not '$file' (resolved: $want) -- installing from a different file would DELETE every job '$raw' describes. Re-run with the matching --config=, or merge the two files by hand first (see the real incident this check exists for: project memory, 2026-07-30)."
}

# REV-20260730-003 F4/F6 (both passes): atomically swaps a validated working
# copy over the real config, installs, and rolls the real config back to
# exactly what it was before if --install then fails -- the real file is
# never left in a half-applied state, and never touched at all if anything
# before this point failed.
atomic_replace_and_install() {
    local realfile="$1" workfile="$2"
    local backup=""
    if [ -f "$realfile" ]; then
        backup=$(mktemp "$(dirname "$realfile")/.zfsbackup-backup.XXXXXX") || { rm -f "$workfile"; die "mktemp backup failed for $realfile"; }
        cp -p "$realfile" "$backup" || { rm -f "$workfile" "$backup"; die "could not back up $realfile before swap"; }
    fi
    if ! mv -f "$workfile" "$realfile"; then
        rm -f "$workfile" "$backup" 2>/dev/null
        die "could not atomically replace $realfile"
    fi
    if ! bash "$GENCRON" -c "$realfile" --install; then
        warn "gen-cron.sh --install failed after updating $realfile -- restoring its previous content"
        if [ -n "$backup" ]; then
            mv -f "$backup" "$realfile" || die "CRITICAL: could not restore $realfile from $backup either -- fix by hand, and do not re-run --install until it is correct"
            warn "$realfile restored -- crontab was NOT changed by this run"
        else
            rm -f "$realfile"
            warn "$realfile removed (it did not exist before this run) -- crontab was NOT changed"
        fi
        die "gen-cron.sh --install failed -- see above; $realfile has been restored to its prior state"
    fi
    [ -n "$backup" ] && rm -f "$backup"
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
    if [ -z "$config" ]; then
        if [ -n "$CRON_CONFIG" ]; then
            config="$CRON_CONFIG"
        else
            # If this host already has a gen-cron.sh-managed crontab block,
            # its own '# Source: <file>' line names the file actually in
            # charge -- default to THAT, never to a brand-new file next to
            # it, or the next --install silently deletes every existing job
            # (see assert_cron_config_matches_installed).
            local existing
            existing=$(crontab -l 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
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

    local account="${PEER_SAVED_ACCOUNT:-root}"
    local keyfile; keyfile=$(local_keyfile_path "$label" "${PEER_SAVED_LOCAL_USER:-}")
    local port="${PEER_SAVED_PORT:-22}"

    # REV-20260730-003 F1/F2 (both passes): a missing pinned host key is now
    # fatal, never a silent accept-new fallback, and the job uses a stable
    # HostKeyAlias instead of the literal peer address.
    local alias; alias=$(host_key_alias "$label")
    local alias_kh
    alias_kh=$(ensure_alias_known_hosts "$label" "${PEER_SAVED_LOCAL_USER:-}" "$port") \
        || die "no pinned host key found for '$PEER_HOST' -- refusing to activate without one (accept-new is not acceptable here). Re-run add-client, or verify --pair completed its host-key confirmation."
    local flags="-K $keyfile -k $alias_kh -O HostKeyAlias=$alias"
    [ "$port" != "22" ] && flags="$flags -p $port"

    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing, re-run add-client"

    # REV-20260730-003 F4/F6 (both passes): everything below builds and
    # validates a WORKING COPY of the config -- the real file is never
    # touched until validation, dry-run, AND confirmation all succeed, and
    # even then only via an atomic swap with rollback if --install then fails.
    ensure_cron_config_dryrun_copy() {
        local real="$1" work="$2"
        if [ -f "$real" ]; then
            cp -p "$real" "$work" || die "could not copy $real to a working copy"
        else
            : > "$work" || die "could not create working copy $work"
        fi
        ensure_cron_config "$work"
    }
    local workfile; workfile=$(mktemp "$(dirname "$cronfile")/.zfsbackup-work.XXXXXX") \
        || die "mktemp failed next to $cronfile"
    ensure_cron_config_dryrun_copy "$cronfile" "$workfile"

    local ds localpath added=0 skipped=0
    local -a managed=()
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$label/$ds"
        managed+=("$localpath")
        if grep -qF "[dataset:$localpath]" "$workfile" 2>/dev/null; then
            warn "[dataset:$localpath] already present -- leaving it untouched"
            skipped=$((skipped + 1))
            continue
        fi
        {
            echo
            echo "[dataset:$localpath]"
            echo "	use_template = standard_hourly,standard_daily,standard_weekly,standard_monthly"
            echo "	src          = ${account}@${PEER_HOST}:${ds}"
            echo "	flags        = $flags"
            echo "	notify       = ${name}-$(basename "$ds")"
        } >> "$workfile" || { rm -f "$workfile"; die "could not append [dataset:$localpath] to the working copy"; }
        added=$((added + 1))
    done
    log "cron config (working copy): $added dataset(s) added, $skipped already present"

    log "validating generated config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the generated config -- fix the underlying issue and re-run activate-client (see output above). $cronfile was NOT touched."
    fi

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
    if [ "$failed" -ne 0 ]; then
        rm -f "$workfile"
        die "$failed dataset(s) failed the dry-run -- not installing, $cronfile was NOT touched. Fix and re-run activate-client."
    fi

    log "effective zfs allow on $PEER_HOST (review for anything beyond this relation):"
    for ds in $PEER_SAVED_DATASETS; do
        show_effective_grants "$ds" "$account" "$PEER_HOST" "$keyfile" "$alias_kh" "$alias" "$port"
    done

    echo
    echo "Klient:        $name"
    echo "Peer:          $PEER_HOST"
    echo "Zrodla:        $PEER_SAVED_DATASETS"
    echo "Cel:           $PEER_SAVED_TARGET/$label"
    echo "Tryb:          pull"
    echo "Profil:        standard (retain hourly=-H24, daily=-D7, weekly=-W4, monthly=-M12; daily/weekly/monthly at 00:00 z quiesce=agent)"
    echo "Test:          OK ($( printf '%s' "$PEER_SAVED_DATASETS" | wc -w ) dataset(s))"
    echo

    if [ "$yes" -ne 1 ]; then
        read -rp "Aktywowac backup? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK) ;;
            *) rm -f "$workfile"; die "not confirmed -- $cronfile was NOT touched, nothing installed" ;;
        esac
    fi

    assert_cron_config_matches_installed "$cronfile"
    atomic_replace_and_install "$cronfile" "$workfile"

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
    local port="${PEER_SAVED_PORT:-22}"
    local alias; alias=$(host_key_alias "$label")
    local alias_kh
    alias_kh=$(ensure_alias_known_hosts "$label" "${PEER_SAVED_LOCAL_USER:-}" "$port") \
        || die "no pinned host key found for '$PEER_HOST' -- refusing to test without one (accept-new is not acceptable here)"
    local flags="-K $keyfile -k $alias_kh -O HostKeyAlias=$alias"
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
        assert_cron_config_matches_installed "$CRON_CONFIG"
        log "removing this client's [dataset:] sections from a working copy of $CRON_CONFIG"
        local workfile; workfile=$(mktemp "$(dirname "$CRON_CONFIG")/.zfsbackup-work.XXXXXX") \
            || die "mktemp failed next to $CRON_CONFIG"
        cp -p "$CRON_CONFIG" "$workfile" || { rm -f "$workfile"; die "could not copy $CRON_CONFIG"; }
        # shellcheck disable=SC2086
        remove_managed_sections "$workfile" $MANAGED_DATASETS
        if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
            rm -f "$workfile"
            die "gen-cron.sh rejected the config after removing '$name' -- $CRON_CONFIG was NOT touched. Investigate by hand before retrying."
        fi
        atomic_replace_and_install "$CRON_CONFIG" "$workfile"
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
# Guarded (same idiom as update-control.sh) so test/zfsbackup/run.sh can
# `source` this file to reach the pure helper functions (client_name_valid,
# peer_label, ensure_cron_config, remove_managed_sections, ...) without also
# running the dispatch below. A real invocation always has BASH_SOURCE[0]==$0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
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
fi
