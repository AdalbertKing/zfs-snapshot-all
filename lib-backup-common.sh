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
# A RELATIONSHIP RECORD IS DATA, AND IS READ AS DATA
# ------------------------------------------------------------------------------
# Client records, pairing manifests and the peer conf are KEY=VALUE files that
# this package writes itself (write_client_field %q-quotes every value; deploy.sh
# writes the manifest from a heredoc). Until 2026-09-03 every reader `.`-sourced
# them -- which is to say, EXECUTED them as bash -- in one of two shapes:
#
#     u=$( . "$f" >/dev/null 2>&1; printf '%s' "${LOCAL_USER:-}" )    # one field
#     . "$cpath"                                                       # all fields
#
# Both shapes have the same two costs. A sourced file can run anything, so a
# record is trusted as CODE by the account that reads it -- root, or the delegated
# account -- and the "treat records as data" rule in docs/AI_PROJECT_RULES.md was
# a rule the readers did not apply. And a sourced record only ADDS variables: a
# field the file does not carry keeps whatever the previous record left behind.
# Measured three separate times, each fixed with its own ad-hoc list of resets:
# BANDWIDTH leaking from a capped client to an uncapped one (load_client_and_
# connection), EXCLUDE_1 leaking from a REMOVED record into an active one
# (migrate_read_record, whose comment records that the hand-picked list it
# replaced "found what that misses within the hour"), and PEER_HOST leaking
# across the remove-client peer scan (a subshell per record, plus a captured
# copy of the outer value). The shape of the defect is the mechanism, so the
# fix is one mechanism:
#
#   record_get  <file> <FIELD> [default]   one field, to stdout, nothing assigned
#   record_load <set> <file>               every field, assigned by name, after
#                                          clearing every field a previous load
#                                          into the same <set> assigned
#
# Neither executes the file. Values are unquoted the way bash would have read
# the word -- bare, backslash-escaped, '...', "..." and $'...' (the shapes
# printf %q produces, plus the heredoc shapes deploy.sh writes) -- with the one
# deliberate difference that "$VAR", `cmd` and $(cmd) inside a value stay
# LITERAL: a record cannot make its reader run anything. A bare value ends at
# the first unquoted blank; sourcing would have executed what followed it as a
# command, and this reader neither executes nor keeps it.
#
# Clearing assigns the EMPTY STRING rather than unsetting. Every reader in both
# programs asks for a field as ${FIELD:-}, ${FIELD:-default} or `[ -n ]`, under
# which empty and absent are the same answer; and several callers declare the
# fields `local` before loading (rux_resolve_name, rux_check_conflict,
# rux_verify_requested_scope, cmd_status's list view) precisely so that the load
# cannot touch the caller's globals. `unset` from inside this function would
# remove that local and send the assignment to the global behind it -- bash
# dynamic scoping -- which is the clobber those locals exist to prevent.
# The one enumeration over field NAMES, ${!EXCLUDE_@} in the legacy-field
# refusal, tolerates an empty member; the numbered reads use ${EXCLUDE_..._$i:-}.
#
# <set> is a word naming which KIND of file is being loaded (client, manifest,
# ...). It exists because the clearing must be per kind: load_client_and_
# connection loads the client record and then the peer manifest into the same
# shell, and clearing "everything the last load assigned" across both would wipe
# the record's fields the moment the manifest arrived. Each set remembers its
# own field names, in RECORD_FIELDS_<set>.
#
# Field names are restricted to [A-Z][A-Z0-9_]* -- every field either program
# writes is that shape -- and a handful of names that would change how the
# READER behaves (PATH, IFS, HOME, ...) are refused outright. Sourcing let a
# record set them; nothing this package writes ever has, so a record that does is
# not a record.

record_unquote() {   # <word as it appears after KEY=>  -> REPLY, the value
    local s="$1" out="" i=0 c nx mode=bare
    local n=${#s}   # a second `local`: one statement expands all its words BEFORE assigning any of them
    # Fast path: a word with none of the characters a shell would interpret IS
    # its own value. This is the shape of nearly every field ever written.
    case "$s" in
        *[\\\'\"\$\`\ \	]*) ;;
        *) REPLY="$s"; return 0 ;;
    esac
    while [ "$i" -lt "$n" ]; do
        c="${s:$i:1}"
        case "$mode" in
        bare)
            case "$c" in
                \\) i=$((i + 1)); out+="${s:$i:1}" ;;
                \') mode=single ;;
                \") mode=double ;;
                \$) if [ "${s:$((i + 1)):1}" = "'" ]; then mode=ansi; i=$((i + 1)); else out+='$'; fi ;;
                ' '|'	') break ;;
                *) out+="$c" ;;
            esac ;;
        single)
            if [ "$c" = "'" ]; then mode=bare; else out+="$c"; fi ;;
        double)
            case "$c" in
                \\) nx="${s:$((i + 1)):1}"
                    case "$nx" in
                        \"|\\|\$|\`) i=$((i + 1)); out+="$nx" ;;
                        *) out+='\' ;;
                    esac ;;
                \") mode=bare ;;
                *) out+="$c" ;;
            esac ;;
        ansi)
            case "$c" in
                \\) nx="${s:$((i + 1)):1}"; i=$((i + 1))
                    case "$nx" in
                        n) out+=$'\n' ;;  t) out+=$'\t' ;;  r) out+=$'\r' ;;
                        a) out+=$'\a' ;;  b) out+=$'\b' ;;  f) out+=$'\f' ;;
                        v) out+=$'\v' ;;  e|E) out+=$'\e' ;;
                        \\) out+='\' ;;   \') out+="'" ;;   \") out+='"' ;;
                        [0-7])
                            # \NNN octal, up to three digits: the form %q uses
                            # for every byte outside the printable ASCII range,
                            # which under cron's C locale means every non-ASCII
                            # character of a dataset name.
                            local oct="$nx" k=1
                            while [ "$k" -lt 3 ]; do
                                case "${s:$((i + 1)):1}" in
                                    [0-7]) i=$((i + 1)); oct+="${s:$i:1}"; k=$((k + 1)) ;;
                                    *) break ;;
                                esac
                            done
                            printf -v c "\\$oct"; out+="$c" ;;
                        x)  local hex="" k=0
                            while [ "$k" -lt 2 ]; do
                                case "${s:$((i + 1)):1}" in
                                    [0-9a-fA-F]) i=$((i + 1)); hex+="${s:$i:1}"; k=$((k + 1)) ;;
                                    *) break ;;
                                esac
                            done
                            if [ -n "$hex" ]; then printf -v c "\\x$hex"; out+="$c"; else out+='\x'; fi ;;
                        *) out+="\\$nx" ;;
                    esac ;;
                \') mode=bare ;;
                *) out+="$c" ;;
            esac ;;
        esac
        i=$((i + 1))
    done
    REPLY="$out"
    # A quote opened and never closed is not a value. `.` refused such a file
    # outright (a parse error), and test/zfsbackup section 46 pins that a
    # record which cannot be read must REFUSE the coverage check, not vanish
    # from it: the reader has to say "malformed", not guess.
    [ "$mode" = bare ]
}

# A field name a record may carry. Refuses the ones that would change how THIS
# process behaves -- the reader's own environment is not the record's to set.
record_field_name_ok() {   # <name>
    case "$1" in
        *[!A-Z0-9_]*|[!A-Z]*) return 1 ;;
        PATH|IFS|HOME|SHELL|PWD|OLDPWD|CDPATH|ENV|BASH_ENV|GLOBIGNORE|LANG|LC_*|PS[0-9]|BASH*|TMPDIR|SERVER_CONF|CLIENTS_DIR) return 1 ;;
    esac
    return 0
}

record_get() {   # <file> <FIELD> [default]  -> stdout. Last assignment wins; default when absent OR empty, like ${FIELD:-default}
    local _rg_file="$1" _rg_want="$2" _rg_line _rg_val=""
    [ -r "$_rg_file" ] || return 1
    while IFS= read -r _rg_line || [ -n "$_rg_line" ]; do
        case "$_rg_line" in "$_rg_want="*) ;; *) continue ;; esac
        # A malformed value reads as absent -- what the sourcing subshell
        # returned when `.` failed to parse the file -- and the status says so.
        record_unquote "${_rg_line#*=}" || { printf '%s' "${3:-}"; return 2; }
        _rg_val="$REPLY"
    done < "$_rg_file"
    [ -n "$_rg_val" ] || _rg_val="${3:-}"
    printf '%s' "$_rg_val"
}

# Returns 1 when the file cannot be read and 2 when it is not a record: a line
# that is neither blank, a comment nor KEY=value, or a value with an unclosed
# quote. Fields before the bad line are already assigned by then, which is
# also what `.` left behind when it stopped at a parse error; a caller that
# treats "cannot read" as "must refuse" (coverage_conflicts) checks the status.
record_load() {   # <set> <file> -> assigns every field; clears what the last load into <set> assigned
    local _rl_set="$1" _rl_file="$2" _rl_line _rl_key _rl_f
    local _rl_seen="RECORD_FIELDS_$1"
    [ -r "$_rl_file" ] || return 1
    for _rl_f in ${!_rl_seen-}; do printf -v "$_rl_f" ''; done
    while IFS= read -r _rl_line || [ -n "$_rl_line" ]; do
        case "$_rl_line" in
            [A-Z]*=*) ;;
            *) # blank or comment lines pass; anything else is not a record
               _rl_f="${_rl_line#"${_rl_line%%[![:space:]]*}"}"
               case "$_rl_f" in ''|'#'*) continue ;; *) return 2 ;; esac ;;
        esac
        _rl_key="${_rl_line%%=*}"
        record_field_name_ok "$_rl_key" \
            || die "$_rl_file: '$_rl_key' is not a field name this package writes -- refusing to read the file as a record"
        record_unquote "${_rl_line#*=}" || return 2
        printf -v "$_rl_key" '%s' "$REPLY"
        case " ${!_rl_seen-} " in
            *" $_rl_key "*) ;;
            *) printf -v "$_rl_seen" '%s' "${!_rl_seen-}${!_rl_seen:+ }$_rl_key" ;;
        esac
    done < "$_rl_file"
}
