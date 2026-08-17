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

read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    LOCAL_USER=""
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
