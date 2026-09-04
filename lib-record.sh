# lib-record.sh -- reading a KEY=VALUE file as DATA: relationship records,
# pairing manifests, the pause marker, the server conf. Sourced, never
# executed, by lib-backup-common.sh (for zfs-backup.sh and zfs-restore.sh) and
# by deploy.sh. It defines only the record_* functions below and expects the
# includer to provide `die` -- each program has its own, and the one refusal in
# here (a field named like a shell variable) must fail the way that program
# fails.
#
# It lives in its own file because deploy.sh cannot source lib-backup-common.sh:
# that file also defines die/warn and the server-conf paths, and deploy.sh has
# its own of each. One reader, two includers, no second copy.

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
# Field names pass two gates. The SHAPE gate: [A-Z][A-Z0-9_]*, minus the names
# that would change how the READER behaves (PATH, IFS, HOME, ...). The SET
# gate: the name must be one this package WRITES into that kind of file
# (record_field_allowed, one list per <set>). The second gate exists because
# the first one is not a boundary: assigning by name into the reader's own
# shell means ANY uppercase name a record carries lands on whatever variable
# of the reader has that name. REV-20260904-134 measured it with DIE_MAIN_PID=
# in a client record -- the field disarmed the fatal die, and the reader ran
# on past a FATAL -- and the same holds for SRC_PROFILE_NAME, PEER_MODE and
# every other uppercase global of either program. A deny-list can only name
# the ones already thought of; a list of what the package writes is finite,
# and test/zfsbackup's records section derives the writers from the program
# text and asserts each is on it, so a new field is refused in the suite, not
# on a host.

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

# The SET gate: is <name> a field this package writes into a <set> record?
#
# Each list is a superset of TODAY'S writers on purpose. A record on a host may
# carry a field an older release wrote -- ENDPOINT_LAN_HOST before the U9
# endpoint shape, EXCLUDE_SNAP_1 / EXCLUDE_1 before the 2026-09-01 rename,
# PEER_JOIN_REMOTELY before it became a flag -- and such a record must still
# LOAD, so that the refusal downstream can say what to do with it (the legacy
# EXCLUDE_ die names the new spelling). Every name any release ever wrote is
# therefore kept: measured from `git log -p --all` on 2026-09-04 over
# write_client_field, the manifest heredocs and the appended stamps.
#
# A numbered field is one of exactly four families -- EXCLUDE_FAMILY_<n>,
# EXCLUDE_CHILD_<n>, and the legacy EXCLUDE_SNAP_<n> and EXCLUDE_<n> -- with
# nothing but digits after the family's prefix.
#
# server.conf says "edit by hand if needed"; the hand may only set the three
# fields the package reads from it. Anything else is not a server.conf.
record_field_allowed() {   # <set> <name>
    case "$1" in
    client)
        case "$2" in
            CLIENT_NAME|PEER_HOST|STATE|ACTIVE_ENDPOINT|CREATED_ENDPOINT|INSTALLED_ENDPOINT|\
            CLIENT_TARGET|LOCAL_USER|PROFILE|SOURCE_PROFILE|PROFILE_DIGEST_RECORDED|\
            REQUESTED_DATASETS|MANAGED_DATASETS|MANAGED_PRUNE_SCOPE|RECURSION|PASSIVE|BANDWIDTH|CRON_CONFIG|\
            CREATED_AT|ACTIVATED_AT|SEED_COMPLETED_AT|REMOVED_AT|\
            ENDPOINT_KNOWN|ENDPOINT_VERIFIED_AT|ENDPOINT_VERIFIED_FOR|\
            FINAL_CATCHUP_AT|FINAL_CATCHUP_EPOCH|FINAL_CATCHUP_ENDPOINT|FINAL_CATCHUP_HOST|FINAL_CATCHUP_PORT|\
            MOVED_AT|MOVED_FROM|MOVED_TO|RUX_MODE|RUX_SOURCE|RUX_TARGET|\
            ENDPOINT_LAN_HOST|ENDPOINT_LAN_PORT|ENDPOINT_VPN_HOST|ENDPOINT_VPN_PORT) return 0 ;;
            EXCLUDE_FAMILY_*|EXCLUDE_CHILD_*|EXCLUDE_SNAP_*|EXCLUDE_*)
                # Four families, each matched on its own: the prefix is the
                # family and what follows it must be digits only. (The first
                # cut tested only the last underscore-separated component and
                # so admitted EXCLUDE_FOO_1 -- REV-134 follow-up.)
                local _rfa_n
                case "$2" in
                    EXCLUDE_FAMILY_*) _rfa_n="${2#EXCLUDE_FAMILY_}" ;;
                    EXCLUDE_CHILD_*)  _rfa_n="${2#EXCLUDE_CHILD_}" ;;
                    EXCLUDE_SNAP_*)   _rfa_n="${2#EXCLUDE_SNAP_}" ;;
                    *)                _rfa_n="${2#EXCLUDE_}" ;;
                esac
                case "$_rfa_n" in ''|*[!0-9]*) return 1 ;; esac
                return 0 ;;
        esac ;;
    manifest)
        case "$2" in
            PEER_SAVED_ROLE|PEER_SAVED_DATASETS|PEER_SAVED_REQUESTED|PEER_SAVED_TARGET|PEER_SAVED_AS|PEER_SAVED_MODE|\
            PEER_SAVED_ACCOUNT|PEER_SAVED_PORT|PEER_SAVED_BANDWIDTH|PEER_SAVED_LOCAL_USER|PEER_SAVED_RECURSIVE_ROOTS|\
            PEER_ROTATING|PEER_CURRENT_PUBKEY|PEER_PREVIOUS_PUBKEY|\
            PEER_JOIN_ROLE|PEER_JOIN_AS|PEER_JOIN_MODE|PEER_JOIN_DATASETS|PEER_JOIN_REQUESTED|PEER_JOIN_TARGET|\
            PEER_JOIN_ACCOUNT|PEER_JOIN_ACCOUNT_UID|PEER_JOIN_FINGERPRINT|PEER_JOIN_GRANTED_DATASETS|\
            PEER_JOIN_REMOTE|PEER_JOIN_REMOTE_AT|PEER_JOIN_REMOTE_FROM|PEER_JOIN_REMOTE_SESSION|PEER_JOIN_REMOTELY|\
            GRANTED_REMOTELY_BY) return 0 ;;
        esac ;;
    pause)
        case "$2" in PAUSED_AT|PAUSED_REASON) return 0 ;; esac ;;
    server)
        case "$2" in DEFAULT_TARGET|CRON_CONFIG|LOCAL_USER) return 0 ;; esac ;;
    *)  die "record_load: '$1' is not a record set this package reads (client, manifest, pause, server)" ;;
    esac
    return 1
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
        record_field_allowed "$_rl_set" "$_rl_key" \
            || die "$_rl_file: '$_rl_key' is not a field name this package writes in a $_rl_set record -- refusing to read the file as a record"
        record_unquote "${_rl_line#*=}" || return 2
        printf -v "$_rl_key" '%s' "$REPLY"
        case " ${!_rl_seen-} " in
            *" $_rl_key "*) ;;
            *) printf -v "$_rl_seen" '%s' "${!_rl_seen-}${!_rl_seen:+ }$_rl_key" ;;
        esac
    done < "$_rl_file"
}
