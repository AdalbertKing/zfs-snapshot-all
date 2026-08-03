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
#   zfs-backup.sh add-client NAME --lan=HOST[:PORT] --datasets="A B" [--target=X] [--bandwidth=N]
#   zfs-backup.sh seed NAME [--yes]
#   zfs-backup.sh set-endpoint NAME --vpn=HOST[:PORT] | --lan=HOST[:PORT]
#   zfs-backup.sh verify-endpoint NAME
#   zfs-backup.sh activate-client NAME [--yes] [--verbose]
#   zfs-backup.sh migrate-profile [--yes]
#   zfs-backup.sh migrate-to-account ACCOUNT [--yes]
#   zfs-backup.sh status [NAME]
#   zfs-backup.sh test NAME
#   zfs-backup.sh remove-client NAME
#
# State machine (REV-20260730-004): pending_enroll -> seeding -> seed_complete
# -> endpoint_verified -> active. Cron is installed ONLY from endpoint_verified
# (or re-activating from active) -- never earlier, matching the agreed
# position's "no held/paused cron entry during seed" (§10) generalized to
# "no cron entry until the ACTIVE endpoint has been verified", not just LAN
# vs VPN specifically. `verify-endpoint` can be re-run against whichever
# endpoint (lan or vpn) is currently active, so a permanently-LAN-only client
# and a LAN-seed-then-VPN client go through the identical gate.
#
# Stable relation identity (REV-20260730-004 F1): CLIENT_NAME is the address-
# independent identity used for the HostKeyAlias and all display/summary text.
# `label` (deploy.sh's own peer_label(), derived from the ORIGINAL --lan
# address used at add-client/--pair time) still exists, but is used ONLY to
# locate deploy.sh's own manifest/key files and the physical target dataset
# path deploy.sh itself already created under that name -- neither can change
# without deploy.sh re-pairing, and this file does not re-pair on an endpoint
# switch. Switching the ACTIVE_ENDPOINT (lan->vpn or back) changes only which
# address/port the generated job connects through; it does not touch
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

# The single crontab writer. Sourced, not reimplemented: this script used to
# hold its own reader, its own writer and its own block renderer, which is how
# three programs ended up with six ways of editing the same file. Missing is
# fatal rather than degraded -- a fallback would be a fourth implementation.
[ -r "$LIBCRON" ] || { echo "cannot read $LIBCRON -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBCRON"

# Mirrors deploy.sh's own peer-pairing state locations exactly (see
# PAIRING-DESIGN.md) -- this file reads what --pair/--join already write, it
# never invents a parallel record of the same facts.
PEER_STATE_DIR="/etc/zfs-snapshot-all/peers"
PEER_KEY_DIR="/root/.ssh/pairing"

SERVER_CONF="/etc/zfs-snapshot-all/zfs-backup.conf"
CLIENTS_DIR="/etc/zfs-snapshot-all/clients"

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
  zfs-backup.sh add-client NAME --lan=HOST[:PORT] --datasets="A B" [--target=X] [--bandwidth=N]
  zfs-backup.sh seed NAME [--yes]
  zfs-backup.sh final-catchup NAME [--yes]
  zfs-backup.sh set-endpoint NAME --vpn=HOST[:PORT] | --lan=HOST[:PORT] [--skip-final-catchup]
  zfs-backup.sh verify-endpoint NAME
  zfs-backup.sh activate-client NAME [--yes] [--verbose]
  zfs-backup.sh migrate-profile [--yes]
  zfs-backup.sh migrate-to-account ACCOUNT [--yes]
  zfs-backup.sh status [NAME]
  zfs-backup.sh test NAME
  zfs-backup.sh remove-client NAME

State machine: pending_enroll -> seeding -> seed_complete -> endpoint_verified
-> active. Cron is installed only from endpoint_verified (or re-activating an
already-active client) -- never earlier.

Run on the backup appliance (pve1). The peer (pve2) side is unchanged:
  ./deploy.sh --join=/path/to/package.tgz

See docs/discussions/DEPLOY-UX-AGREED-POSITION.md and
docs/reviews/responses/REV-20260730-004.md for the model this follows.
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
    local _lu="${LOCAL_USER:-}" _lh=""
    [ -n "$_lu" ] && _lh=$(getent passwd "$_lu" 2>/dev/null | cut -d: -f6)
    if [ -n "$_lh" ]; then
        case "$dst" in
            "$_lh"/*) chown "$_lu":"$_lu" "$dst" 2>/dev/null ;;
        esac
    fi
    printf '%s' "$dst"
}

# ---- endpoint model (REV-20260730-004 §2/§3) --------------------------------
# Two fixed slots, lan and vpn, matching the reviewer's own minimal model --
# not a fully generic named-endpoint system, since the actual required
# scenario (LAN seed, then relocate to VPN) only ever needs these two.
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

# Reads ACTIVE_ENDPOINT plus its ENDPOINT_<X>_HOST/PORT from the already-
# `.`-sourced client conf vars -- echoes "HOST PORT".
active_endpoint_host_port() {
    local hv pv
    hv=$(endpoint_host_var "${ACTIVE_ENDPOINT:?}")
    pv=$(endpoint_port_var "$ACTIVE_ENDPOINT")
    printf '%s %s' "${!hv:?no $hv set for active endpoint '$ACTIVE_ENDPOINT'}" "${!pv:-22}"
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
ensure_cron_config() {
    local file="$1"
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
        # them that is the only useful thing to do.
        local claimed
        claimed=$(crontab_for_target 2>/dev/null | grep -m1 '^# Source: ' | sed -E 's/^# Source: (.*) -- .*/\1/')
        if [ -n "$claimed" ] && [ "$(normalize_cron_source "$claimed")" = "$(normalize_cron_source "$file")" ]; then
            local jobs; jobs=$(crontab_for_target 2>/dev/null | grep -cE '^[0-9*]')
            die "refusing to create $file: the installed crontab block says it was generated FROM that file, and it is missing. Creating it would produce a config describing no jobs at all, and the next --install would replace $jobs live cron line(s) with nothing. Find or rebuild the real config first (the installed block is still the record of what should be in it: crontab -l), then re-run. Nothing has been changed."
        fi
        mkdir -p "$(dirname "$file")" || die "could not create $(dirname "$file")"
        {
            echo "[defaults]"
            echo "	host_label = $(hostname -s)"
        } > "$file" || die "could not create $file"
        log "created new cron config $file"
    fi
    # A config written before the profile split has prune_schedule INSIDE
    # standard_*, so its [dataset:] sections prune themselves flat, per tier.
    # Adding a GFS [prune:] section on top of that would prune the same
    # snapshots twice on the same schedule -- the race gen-cron.sh's own docs
    # warn about. Templates already present are never rewritten (that is what
    # makes this function safe to re-run), so such a host keeps flat retention
    # until someone migrates it deliberately.
    PROFILE_GFS=1
    if grep -q "^\[template:standard_hourly\]" "$file" 2>/dev/null; then
        if sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$file" | grep -q "prune_schedule"; then
            PROFILE_GFS=0
            log "$file uses the pre-GFS profile (standard_* still carries prune_schedule) -- keeping flat per-tier retention for this host. Migration is a deliberate edit, not something activate-client will do behind your back."
        fi
    fi

    local t varname added=""
    for t in $STANDARD_TEMPLATE_NAMES; do
        grep -q "^\[template:$t\]" "$file" 2>/dev/null && continue
        varname="STANDARD_TEMPLATE_$t"
        printf '%s\n' "${!varname}" >> "$file" || die "could not append [template:$t] to $file"
        added="$added $t"
    done
    if [ "$PROFILE_GFS" -eq 1 ]; then
        for t in $KEEP_TEMPLATE_NAMES; do
            grep -q "^\[template:$t\]" "$file" 2>/dev/null && continue
            varname="KEEP_TEMPLATE_$t"
            printf '%s\n' "${!varname}" >> "$file" || die "could not append [template:$t] to $file"
            added="$added $t"
        done
    fi
    [ -n "$added" ] && log "added missing profile template(s) to $file:$added"
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
emit_client_sections() {   # <workfile> <client name>
    local workfile="$1" name="$2" ds localpath
    managed=()
    for ds in $PEER_SAVED_DATASETS; do
        managed+=("$PEER_SAVED_TARGET/$LOAD_LABEL/$ds")
    done
    # Remove-then-add unconditionally, never skip-if-present: that is what makes
    # a re-run after an endpoint switch actually pick up the new host/port/alias
    # instead of leaving the old connection details in place forever.
    [ "${#managed[@]}" -gt 0 ] && remove_managed_sections "$workfile" "${managed[@]}"
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$LOAD_LABEL/$ds"
        {
            echo
            echo "[dataset:$localpath]"
            echo "	use_template = standard_hourly"
            echo "	src          = ${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}"
            echo "	flags        = $LOAD_FLAGS"
            echo "	notify       = ${name}-$(basename "$ds")"
        } >> "$workfile" || return 1
    done

    # One ladder for the whole client. gfs_pattern is 'automated_' rather than
    # any tier's own narrower pattern, because the ladder has to see every
    # snapshot it is bucketing. Recursive over the client's subtree is safe
    # here: every dataset of a client carries the same single send tier, so a
    # recursive sweep cannot hit the "this leaf only has some of these tiers"
    # trap that forces per-leaf monitor carriers elsewhere in this estate.
    prune_scope=""
    if [ "${PROFILE_GFS:-1}" -eq 1 ]; then
        prune_scope="$PEER_SAVED_TARGET/$LOAD_LABEL"
        remove_managed_sections "$workfile" "$prune_scope"
        {
            echo
            echo "[prune:$prune_scope]"
            echo "	use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly"
            echo "	recursive    = yes"
            echo "	gfs          = yes"
            echo "	gfs_pattern  = automated_"
            echo "	notify       = ${name}"
        } >> "$workfile" || return 1
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
snapget_local_base() { printf '%s' "$PEER_SAVED_TARGET/$LOAD_LABEL"; }

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
cmd_add_client() {
    local name="${1:-}"; shift || true
    client_name_valid "$name" || die "invalid client name '$name' (letters, digits, dot, dash, underscore only)"
    local lan="" datasets="" target="" bandwidth=""
    for a in "$@"; do
        case "$a" in
            --lan=*)       lan="${a#*=}" ;;
            --datasets=*)  datasets="${a#*=}" ;;
            --target=*)    target="${a#*=}" ;;
            --bandwidth=*) bandwidth="${a#*=}" ;;
            *) die "add-client: unknown option $a" ;;
        esac
    done
    [ -n "$lan" ]      || die "add-client requires --lan=HOST[:PORT] (the LAN address to seed over)"
    [ -n "$datasets" ] || die "add-client requires --datasets=\"A B\""
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
    if [ -z "$target" ]; then
        target="$DEFAULT_TARGET"
        [ -n "$target" ] || die "no --target given and no default set -- run setup-server first, or pass --target=POOL/PATH"
    fi

    local lan_host lan_port; read -r lan_host lan_port <<< "$(parse_endpoint_arg "$lan")"

    local -a pair_args=(--pair --role=pull --peer="$lan_host" --peer-datasets="$datasets" --target="$target")
    [ "$lan_port" != "22" ] && pair_args+=(--port="$lan_port")
    # Without this the pairing key and the pinned host key are readable only by
    # root, and the target root is delegated to nobody -- so the cron jobs this
    # client will run as $LOCAL_USER could not open their own key.
    [ -n "${LOCAL_USER:-}" ] && pair_args+=(--local-user="$LOCAL_USER")
    bash "$DEPLOY" "${pair_args[@]}" || die "deploy.sh --pair failed -- see above"

    mkdir -p "$CLIENTS_DIR" || die "could not create $CLIENTS_DIR"
    {
        echo "# zfs-backup.sh client record -- managed by add-client/seed/set-endpoint/verify-endpoint/activate-client/remove-client"
        echo "# Every value is %q-quoted on write: this file is sourced as root."
        write_client_field CLIENT_NAME       "$name"
        write_client_field PEER_HOST         "$lan_host"
        write_client_field STATE             pending_enroll
        write_client_field ACTIVE_ENDPOINT   lan
        write_client_field ENDPOINT_LAN_HOST "$lan_host"
        write_client_field ENDPOINT_LAN_PORT "$lan_port"
        write_client_field BANDWIDTH         "$bandwidth"
        write_client_field CREATED_AT        "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$cpath" || die "could not write $cpath"
    chmod 0600 "$cpath"

    log "client '$name' created, state=pending_enroll"
    log "next: copy the package above to $lan_host and run there:  ./deploy.sh --join=<package>"
    log "then here:  $0 seed $name"
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

    log "refreshing dataset list from $PEER_HOST over LAN (also confirms --join has run there)..."
    bash "$DEPLOY" --pair --peer="$PEER_HOST" --draft-config \
        || die "could not reach $PEER_HOST or list its datasets -- has --join run there yet?"

    {
        cat "$cpath"
        echo "STATE=seeding"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing"

    if [ "$yes" -ne 1 ]; then
        echo "Klient:  $name"
        echo "Zrodla:  $PEER_SAVED_DATASETS"
        echo "Cel:     $PEER_SAVED_TARGET/$LOAD_LABEL"
        read -rp "Wykonac PELNY transfer teraz (rzeczywiste dane, bez -n)? [t/N] " ans
        case "$ans" in t|T|tak|TAK) ;; *) die "not confirmed -- no transfer performed, state stays 'seeding'" ;; esac
    fi

    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$LOAD_LABEL/$ds"
        log "seeding $ds -> $localpath (real transfer, may take a while)..."
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -m automated_daily_ $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$PEER_SAVED_TARGET/$LOAD_LABEL"; then
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
    log "client '$name' seed complete. Next: relocate if needed, then set-endpoint/verify-endpoint, then activate-client."
}

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# REV-20260730-005 F3 / REV-20260731-007 §7: one last incremental over the
# endpoint that still works, immediately before the source is physically moved.
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
        echo "Endpoint: $ACTIVE_ENDPOINT ($LOAD_HOST:$LOAD_PORT)"
        echo "Zrodla:   $PEER_SAVED_DATASETS"
        read -rp "Wykonac koncowy transfer przyrostowy teraz? [t/N] " ans
        case "$ans" in t|T|tak|TAK) ;; *) die "not confirmed -- nothing transferred" ;; esac
    fi

    local ds localpath failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$LOAD_LABEL/$ds"
        log "final catch-up $ds -> $localpath over '$ACTIVE_ENDPOINT'..."
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -m automated_daily_ $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$PEER_SAVED_TARGET/$LOAD_LABEL"; then
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
    {
        cat "$cpath"
        write_client_field FINAL_CATCHUP_ENDPOINT "$ACTIVE_ENDPOINT"
        write_client_field FINAL_CATCHUP_HOST "$LOAD_HOST"
        write_client_field FINAL_CATCHUP_PORT "$LOAD_PORT"
        printf 'FINAL_CATCHUP_EPOCH=%s\n' "$(date '+%s')"
        printf 'FINAL_CATCHUP_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    chmod 0600 "$cpath"
    log "client '$name': final catch-up over '$ACTIVE_ENDPOINT' complete. The source may now be disconnected and moved."
}

cmd_set_endpoint() {
    local name="${1:-}"; shift || true
    local lan="" vpn="" skip_catchup=0 allow_stale=0
    for a in "$@"; do
        case "$a" in
            --lan=*) lan="${a#*=}" ;;
            --vpn=*) vpn="${a#*=}" ;;
            --skip-final-catchup) skip_catchup=1 ;;
            --allow-stale-catchup) allow_stale=1 ;;
            *) die "set-endpoint: unknown option $a" ;;
        esac
    done
    [ -n "$lan" ] || [ -n "$vpn" ] || die "set-endpoint requires --lan=HOST[:PORT] and/or --vpn=HOST[:PORT]"

    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    case "${STATE:-}" in
        seed_complete|endpoint_verified|active) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- set-endpoint needs seed_complete or later (seed must finish first)" ;;
    esac

    # The gate (REV-20260731-007 §7). Switching to a DIFFERENT endpoint is the
    # relocation moment, so the catch-up must already have happened over the
    # endpoint being left -- while it still worked. A catch-up recorded against
    # some OTHER endpoint says nothing about this switch, so the recorded name
    # must match the one being left, not merely be present.
    #
    # Skippable, because the reviewer's case is real: sometimes the source is
    # already unplugged and there is nothing left to catch up over. Then it is a
    # deliberate, logged decision rather than an accident.
    local leaving="${ACTIVE_ENDPOINT:-}"
    local switching_to=""
    [ -n "$vpn" ] && switching_to="vpn"
    if [ -n "$switching_to" ] && [ "$switching_to" != "$leaving" ]; then
        if [ "$skip_catchup" -eq 1 ]; then
            warn "SKIPPING the final catch-up over '$leaving' at your request. The first transfer over '$switching_to' will carry everything since $( [ -n "${FINAL_CATCHUP_AT:-}" ] && echo "$FINAL_CATCHUP_AT" || echo "the seed (${SEED_COMPLETED_AT:-unknown})" ) -- over the slow link, unattended. Only correct if the source is already disconnected."
        else
            # REV-20260731-008 F1. The name alone was too weak a claim: it
            # survived a change of host or port on that endpoint, and it never
            # went stale. So the recorded catch-up must match the transport
            # being LEFT exactly, and be recent -- otherwise "the last transfer
            # happened just before relocation" is not what it proves.
            local lh lp
            lh=$(endpoint_host_var "$leaving"); lh="${!lh:-}"
            lp=$(endpoint_port_var "$leaving"); lp="${!lp:-22}"
            local why=""
            if [ "${FINAL_CATCHUP_ENDPOINT:-}" != "$leaving" ]; then
                why="no final catch-up has been run over '$leaving'"
            elif [ "${FINAL_CATCHUP_HOST:-}" != "$lh" ] || [ "${FINAL_CATCHUP_PORT:-22}" != "$lp" ]; then
                why="the recorded catch-up used ${FINAL_CATCHUP_HOST:-?}:${FINAL_CATCHUP_PORT:-?}, but '$leaving' now points at $lh:$lp -- it proves nothing about the transport actually being left"
            else
                local age=$(( $(date '+%s') - ${FINAL_CATCHUP_EPOCH:-0} ))
                if [ "${FINAL_CATCHUP_EPOCH:-0}" -le 0 ]; then
                    why="the recorded catch-up predates freshness tracking, so its age cannot be established"
                elif [ "$age" -gt "$CATCHUP_MAX_AGE" ]; then
                    if [ "$allow_stale" -eq 1 ]; then
                        warn "the catch-up over '$leaving' is $((age / 60)) min old (limit $((CATCHUP_MAX_AGE / 60)) min) and you passed --allow-stale-catchup. Everything written since ${FINAL_CATCHUP_AT:-?} will cross the slow link on the first transfer."
                    else
                        why="the catch-up over '$leaving' is $((age / 60)) min old (limit $((CATCHUP_MAX_AGE / 60)) min). Writes since then would all cross the slow link"
                    fi
                fi
            fi
            if [ -n "$why" ]; then
                die "refusing to switch '$name' from '$leaving' to '$switching_to': $why.
  Run it BEFORE disconnecting the source, while the old link still works:
      $0 final-catchup $name
  It keeps the first transfer over the new link small and proves the incremental
  base is intact while it is still cheap to fix.
  If the source is ALREADY disconnected and there is nothing to catch up over,
  say so explicitly: $0 set-endpoint $name --vpn=... --skip-final-catchup"
            fi
            log "final catch-up over '$leaving' ($lh:$lp) recorded at ${FINAL_CATCHUP_AT:-?} -- proceeding with the switch"
        fi
    fi

    local new_active="$ACTIVE_ENDPOINT"
    local out="$cpath.new"
    cp -p "$cpath" "$out" || die "could not copy $cpath"
    # parse_endpoint_arg dies on anything that is not a plain hostname/IPv4 and
    # a real port; write_client_field %q-quotes what survives (F1).
    if [ -n "$vpn" ]; then
        local h p; read -r h p <<< "$(parse_endpoint_arg "$vpn")"
        {
            write_client_field ENDPOINT_VPN_HOST "$h"
            write_client_field ENDPOINT_VPN_PORT "$p"
        } >> "$out"
        new_active="vpn"
    fi
    if [ -n "$lan" ]; then
        local h2 p2; read -r h2 p2 <<< "$(parse_endpoint_arg "$lan")"
        {
            write_client_field ENDPOINT_LAN_HOST "$h2"
            write_client_field ENDPOINT_LAN_PORT "$p2"
        } >> "$out"
        # Moving an endpoint invalidates any catch-up recorded against it: the
        # transport it proved no longer exists (REV-20260731-008 F1).
        if [ "${FINAL_CATCHUP_ENDPOINT:-}" = "lan" ]            && { [ "${FINAL_CATCHUP_HOST:-}" != "$h2" ] || [ "${FINAL_CATCHUP_PORT:-22}" != "$p2" ]; }; then
            {
                write_client_field FINAL_CATCHUP_ENDPOINT ""
                printf 'FINAL_CATCHUP_EPOCH=0
'
            } >> "$out"
            warn "the 'lan' endpoint moved to $h2:$p2, so the catch-up recorded against ${FINAL_CATCHUP_HOST:-?}:${FINAL_CATCHUP_PORT:-?} no longer applies -- it has been invalidated"
        fi
    fi
    # Switching the active endpoint means the OLD verification no longer says
    # anything about THIS endpoint -- require a fresh verify-endpoint before
    # cron can be (re)installed against it.
    #
    # REV-20260730-005 F4: an ALREADY-ACTIVE client keeps its installed cron
    # line running against the endpoint it was generated for, which used to be
    # recorded only as "STATE=seed_complete" -- so `status` said seed_complete
    # while backups were in fact still running fine over the old endpoint, and
    # nothing anywhere named the divergence. Now the desired endpoint
    # (ACTIVE_ENDPOINT) and the one the installed cron actually uses
    # (INSTALLED_ENDPOINT, written by activate-client) are separate fields, and
    # a pending change gets its own state rather than being flattened into an
    # earlier one.
    write_client_field ACTIVE_ENDPOINT "$new_active" >> "$out"
    if [ "${STATE:-}" = "active" ]; then
        write_client_field STATE endpoint_change_pending >> "$out"
        warn "endpoint changed to '$new_active', but the INSTALLED cron still runs over '${INSTALLED_ENDPOINT:-?}'. Backups keep working over the old endpoint until: verify-endpoint $name, then activate-client $name."
    elif [ "${STATE:-}" != "seed_complete" ]; then
        write_client_field STATE seed_complete >> "$out"
    fi
    mv -f "$out" "$cpath"
    chmod 0600 "$cpath"
    log "client '$name' desired endpoint is now '$new_active'"
}

# ------------------------------------------------------------------------------
# REV-20260730-004 §3.6: must do SSH + host-key verification + snapget -n, and
# confirm a full transfer is NOT required (i.e. an incremental base already
# exists) -- not just "the command exited 0", which a first-ever send would
# also do.
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
    log "verifying endpoint '$ACTIVE_ENDPOINT' ($LOAD_HOST:$LOAD_PORT) for '$name'..."

    # REV-20260730-005 F2: this used to conclude "incremental" from the ABSENCE
    # of the words "full send" in snapget.sh's prose output -- a negative
    # heuristic over a log message, which a reworded line or any new rc=0
    # planner branch would silently have turned into a false "verified".
    # snapget.sh -n now prints exactly one machine-readable verdict per dataset
    # on STDOUT (logging goes to stderr): PLAN=INCREMENTAL / PLAN=FULL, derived
    # from the same $common_snapshot the real transfer branches on. Anything
    # that is not a recognised PLAN= line is treated as unknown and FAILS --
    # fail-closed, per the review.
    local ds localpath failed=0 needs_full=0 unknown=0 out plan
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$LOAD_LABEL/$ds"
        # stdout only: stderr carries the human log, and mixing them back
        # together is exactly what made the old text heuristic fragile.
        # shellcheck disable=SC2086
        out=$(bash "$SNAPGET" -n $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$PEER_SAVED_TARGET/$LOAD_LABEL" 2>/dev/null); local rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "  FAILED (rc=$rc): $ds"
            failed=$((failed + 1))
            continue
        fi
        plan=$(printf '%s\n' "$out" | grep -m1 '^PLAN=' || true)
        case "$plan" in
            PLAN=INCREMENTAL*) log "  OK (incremental): $ds  [${plan#PLAN=INCREMENTAL }]" ;;
            PLAN=FULL*)
                warn "  $ds would require a FULL transfer through this endpoint -- no common base"
                needs_full=$((needs_full + 1)) ;;
            *)
                warn "  $ds: snapget.sh -n gave no PLAN= verdict (got: ${plan:-<none>}) -- treating as UNKNOWN, not as incremental"
                unknown=$((unknown + 1)) ;;
        esac
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed connectivity/host-key verification through '$ACTIVE_ENDPOINT'"
    [ "$unknown" -eq 0 ] || die "$unknown dataset(s) returned no machine-readable plan -- refusing to mark verified on an unknown result. Check that snapget.sh is v2.65+ on this host."
    if [ "$needs_full" -ne 0 ]; then
        die "$needs_full dataset(s) would need a full resend through '$ACTIVE_ENDPOINT' -- refusing to mark verified. If this endpoint genuinely has no common base (e.g. never seeded through it), seed again or investigate before proceeding."
    fi

    {
        cat "$cpath"
        write_client_field STATE                endpoint_verified
        write_client_field ENDPOINT_VERIFIED_AT "$(date '+%Y-%m-%d %H:%M:%S')"
        write_client_field ENDPOINT_VERIFIED_FOR "$ACTIVE_ENDPOINT"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    log "client '$name': endpoint '$ACTIVE_ENDPOINT' verified, incremental-only confirmed for every dataset. Ready for activate-client."
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
    case "${STATE:-}" in
        endpoint_verified|active) ;;
        *) die "client '$name' is in state '${STATE:-unknown}' -- activate-client requires endpoint_verified (run seed, then verify-endpoint first). Fail-closed: no cron entry exists before this gate." ;;
    esac

    load_client_and_connection "$cpath"
    [ -n "${PEER_SAVED_DATASETS:-}" ] || die "manifest for '$PEER_HOST' has no dataset list -- something is wrong with the pairing"

    read_server_conf
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
    ensure_cron_config "$workfile"

    # Remove-then-add every managed dataset's section unconditionally (not
    # skip-if-present): this is what makes re-running activate-client after
    # an endpoint switch actually pick up the new host/port/alias in the
    # generated job, instead of silently leaving the OLD connection details
    # in an already-present section forever.
    local ds localpath
    local -a managed=()
    emit_client_sections "$workfile" "$name" || { rm -f "$workfile"; die "could not write the sections for '$name' into the working copy"; }

    log "cron config (working copy): ${#managed[@]} dataset(s) written for endpoint '$ACTIVE_ENDPOINT'"

    log "validating generated config (working copy only, nothing real touched yet)..."
    if ! bash "$GENCRON" -c "$workfile" >/dev/null; then
        rm -f "$workfile"
        die "gen-cron.sh rejected the generated config -- fix the underlying issue and re-run activate-client (see output above). $cronfile was NOT touched."
    fi

    log "dry-run test of each dataset (snapget.sh -n)..."
    local failed=0
    for ds in $PEER_SAVED_DATASETS; do
        localpath="$PEER_SAVED_TARGET/$LOAD_LABEL/$ds"
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$PEER_SAVED_TARGET/$LOAD_LABEL"; then
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

    echo
    echo "Klient:              $name"
    echo "Peer (LAN parowania): $PEER_HOST"
    echo "Endpoint aktywny:    $ACTIVE_ENDPOINT ($LOAD_HOST:$LOAD_PORT)"
    echo "Zrodla:              $PEER_SAVED_DATASETS"
    echo "Cel:                 $PEER_SAVED_TARGET/$LOAD_LABEL"
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

    log "client '$name' active (cron runs over endpoint '$ACTIVE_ENDPOINT')."
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
    ensure_cron_config "$workfile"

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
        emit_client_sections "$workfile" "$name" || { rm -f "$workfile"; die "could not rewrite sections for '$name'"; }
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
              printf '%-20s state=%-18s endpoint=%s\n' "$CLIENT_NAME" "$STATE" "$ACTIVE_ENDPOINT" )
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
    echo "Klient:            $CLIENT_NAME"
    echo "Stan:              ${STATE:-unknown}"
    echo "Endpoint docelowy: ${ACTIVE_ENDPOINT:-?} ($host:$port)"
    [ -n "${ENDPOINT_LAN_HOST:-}" ] && echo "  lan:  ${ENDPOINT_LAN_HOST}:${ENDPOINT_LAN_PORT:-22}"
    [ -n "${ENDPOINT_VPN_HOST:-}" ] && echo "  vpn:  ${ENDPOINT_VPN_HOST}:${ENDPOINT_VPN_PORT:-22}"
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
    for ds in $PEER_SAVED_DATASETS; do
        # shellcheck disable=SC2086
        if bash "$SNAPGET" -n $LOAD_FLAGS "${LOAD_ACCOUNT}@${LOAD_HOST}:${ds}" "$PEER_SAVED_TARGET/$LOAD_LABEL"; then
            log "  OK: $ds"
        else
            warn "  FAILED: $ds"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ] || die "$failed dataset(s) failed"
    log "all datasets OK (endpoint: $ACTIVE_ENDPOINT)"
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

remove_managed_sections() {
    local file="$1"; shift
    local -a targets=("$@")
    local tmp; tmp=$(mktemp) || die "mktemp failed"
    local ds header in_target=0
    local -a headers=()
    # Both section types for each path. The GFS profile gives a client one
    # [prune:<target>/<label>] alongside its [dataset:] sections, and a function
    # that only knew about [dataset:] would append a second prune section on
    # every re-activation -- two ladders, same scope, same schedule, racing.
    # Removing [prune:X] when X is a dataset path is a harmless no-op: the two
    # never share a path, since the prune scope is the parent of the datasets.
    for ds in "${targets[@]}"; do headers+=("[dataset:$ds]" "[prune:$ds]"); done
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
    mv_preserving_mode "$tmp" "$file" || die "could not update $file"
}

cmd_remove_client() {
    local name="${1:-}"
    [ -n "$name" ] || die "remove-client requires a client name"
    local cpath; cpath=$(client_conf_path "$name")
    [ -r "$cpath" ] || die "no client '$name'"
    # shellcheck disable=SC1090
    . "$cpath"
    # Without this, LOCAL_USER is unset here and every crontab operation below
    # silently targets ROOT -- on a collector with a dedicated account that
    # means reading the wrong crontab, comparing against the wrong '# Source:',
    # and, if the comparison had passed, rewriting the wrong user's jobs.
    # Found live on metropolis pve1, 2026-08-01: teardown refused because it was
    # looking at root's block while the client's lines were in the account's.
    # assert_cron_config_matches_installed caught it, which is the third time
    # today a guard turned a defect into a message instead of an incident.
    read_server_conf
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
        remove_managed_sections "$workfile" $MANAGED_DATASETS ${MANAGED_PRUNE_SCOPE:-}
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
        printf 'REMOVED_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${cpath}.new" && mv -f "${cpath}.new" "$cpath"
    log "client '$name' removed locally. Run the peer-side commands deploy.sh --unpair printed above."
}

# ------------------------------------------------------------------------------
# Guarded (same idiom as update-control.sh) so test/zfsbackup/run.sh can
# `source` this file to reach the pure helper functions without also running
# the dispatch below. A real invocation always has BASH_SOURCE[0]==$0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        setup-server)     shift; cmd_setup_server "$@" ;;
        add-client)       shift; cmd_add_client "$@" ;;
        seed)             shift; cmd_seed "$@" ;;
        final-catchup)    shift; cmd_final_catchup "$@" ;;
        set-endpoint)     shift; cmd_set_endpoint "$@" ;;
        verify-endpoint)  shift; cmd_verify_endpoint "$@" ;;
        activate-client)  shift; cmd_activate_client "$@" ;;
        migrate-profile)  shift; cmd_migrate_profile "$@" ;;
        migrate-to-account) shift; cmd_migrate_to_account "$@" ;;
        status)           shift; cmd_status "$@" ;;
        test)             shift; cmd_test "$@" ;;
        remove-client)    shift; cmd_remove_client "$@" ;;
        -h|--help|"")     usage; exit 0 ;;
        *) echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
    esac
fi
