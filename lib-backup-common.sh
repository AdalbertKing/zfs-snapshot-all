# lib-backup-common.sh -- the small set of facts and helpers shared by
# zfs-backup.sh (the backup/orchestration surface) and zfs-restore.sh (the
# restore surface). Sourced, never executed.
#
# Why this file exists (2026-08-17): restore was split out of zfs-backup.sh into
# its own program, because restore is the one operation whose active side writes
# onto production -- the inverse of every other verb in this tree -- and that
# boundary deserves to be a FILE boundary, so "this file never destroys client
# data" is a structural property of zfs-backup.sh rather than a behavioural one.
# The split leaves exactly the helpers below wanted on both sides. They are
# moved, not duplicated: a second copy of read_server_conf is how the two
# programs would drift apart on what "the server config" even is.
#
# Deliberately NOT here: managed_source_prefix_for_scope / source_scope_is_bounded
# (used only by zfs-backup.sh's audit path), and everything restore_* (owned by
# zfs-restore.sh). The cut runs along USAGE, not along names.

# ------------------------------------------------------------------------------
# Fatal/diagnostic output. One implementation; both programs must fail the same
# way so that operator muscle memory and log greps transfer between them.
warn() { echo "!!! $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# The server-side config written by `zfs-backup.sh setup-server` and read by
# every later command. KEY=VALUE, sourced -- setup-server is the only writer.
SERVER_CONF="${SERVER_CONF:-/etc/zfs-snapshot-all/zfs-backup.conf}"

# Resets ONLY the fields this file actually carries, so a stale value from an
# earlier read cannot survive onto a host that has no server.conf. Those fields
# are exactly the two setup-server writes: DEFAULT_TARGET and CRON_CONFIG.
#
# It used to clear LOCAL_USER too. That was left over from when the account WAS
# a host-wide setting: setup-server stopped recording it -- who runs a
# relationship's jobs became a per-relationship decision that travels with the
# relationship -- but the clear stayed behind, silently destroying a decision
# made by the CALLER, on behalf of a file that never mentions it.
#
# The cost was not theoretical. cmd_activate_client and cmd_remove_client each
# carry a comment about the reset and put the value back afterwards, and those
# two workarounds made the behaviour look deliberate. cmd_local_backup then
# gained --local-user (2026-08-21), did not know to work around it, and shipped
# a flag that parsed correctly, set the variable correctly, and had it wiped a
# hundred lines later: the block went to root's crontab with nothing delegated,
# past a green CI, and it took probes either side of the gap to see why.
#
# A loader must not clear state it does not own.
read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    [ -r "$SERVER_CONF" ] || return 0
    # shellcheck disable=SC1090
    . "$SERVER_CONF"
}

# ------------------------------------------------------------------------------
# One field value of an installed [dataset:<localpath>] section, or empty if the
# section or the field is absent. Reads back what is ALREADY on disk -- the
# installed CONFIG is runtime truth -- not possibly-stale client state.
installed_dataset_field() {   # <cronfile> <local dataset path> <field>
    awk -v h="[dataset:$2]" -v fld="$3" '
        $0==h {f=1; next}
        f && /^\[/ {f=0}
        f {
            line=$0; sub(/^[ \t]+/,"",line)
            if (line ~ ("^" fld "[ \t]*=")) { sub(("^" fld "[ \t]*=[ \t]*"),"",line); print line; exit }
        }
    ' "$1" 2>/dev/null
}
