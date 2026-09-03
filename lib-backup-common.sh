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

# `die` FROM INSIDE A COMMAND SUBSTITUTION HAS TO END THE PROGRAM.
#
# `exit 1` alone is correct in the main shell and a no-op everywhere a value is
# read through `$( )`: `config="$(pick ...)"` runs pick in a SUBSHELL, so the
# exit kills the subshell, the assignment gets the empty string, and the caller
# carries on. Measured on the lab, 2026-08-27, `restore lab1 --plan` on a real
# collector printed THREE consecutive FATALs and exited 0. A verb that prints
# FATAL and returns success is worse than one that crashes.
#
# zfs-restore.sh fixed it for itself first ("the same change to zfs-backup.sh's
# ~9000 lines is not something a lab evening can prove safe"); since 2026-09-03
# both programs share this one. $$ is the MAIN shell's pid even inside $( );
# $BASHPID is the current shell's. They differ exactly when we are in a
# subshell, which is the case that used to fail open: then the main shell is
# sent TERM, whose trap (armed below) exits 1 -- bash runs it as soon as the
# substitution it is waiting on completes, so the caller's next line does not
# run. Proven both ways before shipping: with the kill the next line does not
# run and the status is 1; without it the line runs and the status is 0.
#
# ARMED ONLY WHEN THE FILE IS THE PROGRAM: each program calls die_arm_fatal
# under its `BASH_SOURCE[0] == $0` guard. `$$` is the shell that sourced it, and
# a harness that sources the program to call its functions directly IS that
# shell -- the signal would kill the harness (measured: test/restore/run.sh
# went down silently before its first assertion). When sourced, `die` therefore
# stays `exit 1`, the fail-open behaviour this fixes. Said plainly rather than
# papered over: a suite that sources a program CANNOT observe the fatal-die
# property and must not claim to. It is proven by running the program.
#
# The one legitimate "die means only this subshell" site -- cmd_status probing
# the peer through load_client_and_connection to report UNKNOWN rather than
# abort the view -- says so explicitly with die_confine_to_subshell inside its
# `$( )`. That is the whole opt-out: a name at the site, never a global switch.
DIE_MAIN_PID=""
die() {
    echo "FATAL: $*" >&2
    [ -n "$DIE_MAIN_PID" ] && [ "$BASHPID" != "$DIE_MAIN_PID" ] && kill -TERM "$DIE_MAIN_PID" 2>/dev/null
    exit 1
}
die_arm_fatal() {   # call once, from the program's main shell, under its BASH_SOURCE guard
    DIE_MAIN_PID=$$
    trap 'exit 1' TERM
}
die_confine_to_subshell() {   # call INSIDE a $( ): a die there ends the subshell only
    DIE_MAIN_PID=""
}

# ------------------------------------------------------------------------------
# The server-side config written by `zfs-backup.sh setup-server` and read by
# every later command. KEY=VALUE, read as DATA through record_load below (it was
# `.`-sourced until 2026-09-03, the last reader in these two programs that
# still executed its file) -- setup-server is the only writer.
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
#
# record_load honours that by construction: its own clearing covers only the
# fields a PREVIOUS load into the `server` set assigned, i.e. fields this very
# file carried -- never a field the caller set and the file does not mention.
# A legacy server.conf that still carries LOCAL_USER= (setup-server wrote it
# once; two suite fixtures keep that shape) is read exactly as sourcing read it:
# the file's value lands in the variable, on the first read and on every later
# one. The two explicit resets stay for the host with NO server.conf at all,
# where nothing is loaded and a stale value from an earlier read would survive.
read_server_conf() {
    DEFAULT_TARGET=""
    CRON_CONFIG=""
    [ -r "$SERVER_CONF" ] || return 0
    record_load server "$SERVER_CONF"
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

# ------------------------------------------------------------------------------
# WHERE A RELATIONSHIP LIVES
# ------------------------------------------------------------------------------
# One client record per relationship, and both programs must agree on where they
# are: zfs-backup.sh WRITES them, zfs-restore.sh READS them to answer "which
# relationship is `pve2`". A second copy of this path in the second program is a
# way for the two to disagree about what exists, so it lives here.
#
# Overridable from the environment because zfs-restore.sh is its own program and
# its suite has to point it at a fixture directory; zfs-backup.sh's own suites
# reassign the same name in a subshell, which still wins because this is read at
# source time and they run afterwards.
CLIENTS_DIR="${CLIENTS_DIR:-/etc/zfs-snapshot-all/clients}"

# ------------------------------------------------------------------------------
# RECORDS ARE DATA: record_get / record_load live in lib-record.sh, shared with
# deploy.sh, which cannot source this file (it has its own die/warn). Sourced
# through this file's own directory, not the program's SCRIPT_DIR, so a suite
# that sources this file directly gets the reader too.
_LIBCOMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$_LIBCOMMON_DIR/lib-record.sh" ] || { echo "cannot read $_LIBCOMMON_DIR/lib-record.sh -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
. "$_LIBCOMMON_DIR/lib-record.sh"
# Where a peer's pairing state lives -- the layout deploy.sh writes and
# zfs-backup.sh reads: lib-pairing.sh, shared with deploy.sh for the same
# reason as the record reader above.
[ -r "$_LIBCOMMON_DIR/lib-pairing.sh" ] || { echo "cannot read $_LIBCOMMON_DIR/lib-pairing.sh -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
. "$_LIBCOMMON_DIR/lib-pairing.sh"
