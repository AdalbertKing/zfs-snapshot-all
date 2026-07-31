#!/bin/bash
# zfs-quiesce-helper -- the ONLY privileged thing a delegated backup account may
# do to a guest on this host.
#
# Why it exists
# -------------
# Remote quiesce (snapget.sh -q) has to freeze a guest on the SOURCE host before
# snapshotting it. Freezing means `qm guest cmd`, which needs root: a delegated
# account cannot even read /etc/pve/qemu-server/<id>.conf (0640 root:www-data),
# and `qm` without root dies with "Unable to load access control list". Measured
# on pve1, not assumed.
#
# Handing the collector root on the source would undo the entire point of the
# pairing model, and `sudo qm` is barely better -- `qm guest exec` runs ARBITRARY
# CODE inside the guest, and `qm` can also destroy VMs. So the account gets a
# sudo rule for THIS script and nothing else. The script accepts four verbs on
# guest IDs it has been explicitly told about:
#
#     status [<id>]   with no id: "am I usable" probe, prints OK
#                     with an id: kind / running / frozen, one line
#     freeze <id>     VM: fsfreeze-freeze via qemu-guest-agent
#                     container: `pct exec -- sync` (a flush, not a freeze)
#     thaw   <id>     VM: fsfreeze-thaw; container: nothing to undo
#     writers <id>    Windows guest: VSS writer states (see below)
#
# No verb takes a command from the caller. `writers` DOES use `qm guest exec`,
# which is the very capability this script exists to fence off -- so note what
# makes it safe: the command is a CONSTANT in this root-owned file, and the only
# thing the caller influences is which whitelisted guest it runs in. If someone
# later "generalises" this verb to accept a command, the fence is gone. Don't.
# The same rule governs any future hook trigger: the guest owns the code at a
# FIXED path, the collector owns only the trigger, never a string off the wire.
#
# Why `writers` exists at all
# ---------------------------
# Verified against qemu's own source (v7.2.0 -- the version PVE 7.4 ships -- and
# also v8.2.0 and master):
#
#   Linux guest: if /etc/qemu/fsfreeze-hook exits non-zero, qga does
#     `error_setg(errp, "fsfreeze hook has failed with status %d", status)` and
#     the freeze ABORTS. A failed application quiesce is loud, for free.
#
#   Windows guest: requester.cpp calls GatherWriterStatus() and checks only that
#     the gathering itself succeeded. There is not ONE call to GetWriterStatus()
#     or reference to VSS_WRITER_STATE in that file, in any of those versions.
#     Individual writer failure is never inspected -- and VSS deliberately lets
#     DoSnapshotSet succeed with a broken writer skipped, which is exactly why
#     the API offers GetWriterStatus for the backup application to check.
#
# So on Windows a dead SqlServerWriter produces a snapshot that reports success
# and is NOT application-consistent, and no version of qemu will ever tell you.
# That is not hypothetical: it is what happened on vsql2, for months, unseen.
# This verb is the only way to see it from the host.
#
# Whitelist
# ---------
# /etc/zfs-quiesce-allow/<account>, one DATASET per line -- the same list the
# `zfs allow` grants are derived from, written by `deploy.sh --join`. Guest ids
# are resolved from it at call time, not stored. So the rule reads "you may
# quiesce guests whose disks live under the datasets you are already allowed to
# replicate", and the two grants cannot drift apart. Comments (#) and blank
# lines are ignored.
#
# The account is taken from $SUDO_USER, which sudo sets and the caller cannot
# forge. Run directly as root with no SUDO_USER, every id is allowed -- root
# could call `qm` itself anyway, so pretending otherwise would be theatre.
#
# Exit codes: 0 ok, 2 refused (unknown verb, malformed or non-whitelisted id),
# 3 the underlying qm/pct call failed, 4 no whitelist for this account.

set -u

# Both roots are overridable so the test suite can run this without root and
# without a PVE host. That is NOT a hole in the sudo boundary: sudo's default
# env_reset strips these on the way in, and the sudoers rule deploy.sh writes
# deliberately does not carry SETENV -- so a delegated account cannot point the
# whitelist at a file it controls. Do not add SETENV to that rule.
ALLOW_DIR="${ZFS_QUIESCE_ALLOW_DIR:-/etc/zfs-quiesce-allow}"
PVE_CONF_DIR="${ZFS_QUIESCE_PVE_DIR:-/etc/pve}"

die()  { echo "zfs-quiesce-helper: $*" >&2; exit 2; }
fail() { echo "zfs-quiesce-helper: $*" >&2; exit 3; }

# Which account is asking. sudo sets SUDO_USER; a caller cannot set it for the
# privileged side of the boundary.
caller="${SUDO_USER:-}"
if [ -z "$caller" ] && [ "$(id -u)" = "0" ]; then
    caller="root"
fi
[ -n "$caller" ] || die "cannot determine the calling account"

# The whitelist holds DATASETS, not guest ids, and the ids are derived from it
# at call time. Storing ids would freeze the answer at --join time: a VM created
# next month under an already-delegated dataset would be refused, and someone
# would "fix" it by widening the rule. Deriving live means the permission says
# what it should say -- "you may quiesce guests whose disks live under the
# datasets you are already allowed to replicate" -- and cannot drift from the
# zfs allow grants, since deploy.sh writes both from one list.
#
# Root without sudo bypasses it entirely. Anyone else with no whitelist file is
# refused: absence means "this account was never granted quiesce", which must
# never read as "allow everything".
id_is_allowed() {
    local want="$1" root leaf name
    [ "$caller" = "root" ] && [ -z "${SUDO_USER:-}" ] && return 0
    local f="$ALLOW_DIR/$caller"
    if [ ! -f "$f" ]; then
        echo "zfs-quiesce-helper: no quiesce whitelist for account '$caller' ($f) -- this account was never granted guest quiesce on this host" >&2
        exit 4
    fi
    while IFS= read -r root; do
        root="${root%%#*}"
        root="${root#"${root%%[![:space:]]*}"}"
        root="${root%"${root##*[![:space:]]}"}"
        [ -n "$root" ] || continue
        # -- so a dataset that starts with '-' is an operand, never an option.
        while IFS= read -r name; do
            leaf=${name##*/}
            case "$leaf" in
                vm-*-disk-*|subvol-*-disk-*)
                    leaf=${leaf#vm-}; leaf=${leaf#subvol-}
                    [ "${leaf%%-disk-*}" = "$want" ] && return 0 ;;
            esac
        done < <(zfs list -r -H -o name -- "$root" 2>/dev/null)
    done < "$f"
    return 1
}

# Guest ids are numeric in PVE. Validating the shape first means nothing that
# could be an option or a path ever reaches qm/pct.
require_id() {
    local gid="${1:-}"
    [ -n "$gid" ] || die "this verb needs a guest id"
    case "$gid" in
        ''|*[!0-9]*) die "'$gid' is not a numeric guest id" ;;
    esac
    id_is_allowed "$gid" || die "guest $gid is not on the quiesce whitelist for account '$caller'"
    printf '%s' "$gid"
}

# qemu / lxc / absent. The conf files are the authority, same as the engine's
# own detection -- and reading them is precisely what the delegated account
# cannot do for itself.
guest_kind() {
    if   [ -f "$PVE_CONF_DIR/qemu-server/$1.conf" ]; then echo qemu
    elif [ -f "$PVE_CONF_DIR/lxc/$1.conf" ];        then echo lxc
    else echo absent; fi
}

guest_running() {
    local st
    case "$2" in
        qemu) st=$(qm  status "$1" 2>/dev/null) ;;
        lxc)  st=$(pct status "$1" 2>/dev/null) ;;
        *)    return 1 ;;
    esac
    case "$st" in *running*) return 0 ;; *) return 1 ;; esac
}

verb="${1:-}"
shift || true

case "$verb" in
    status)
        # No id: the privilege probe. It answers "is this account allowed to
        # quiesce anything here at all", which is what a run needs to know
        # BEFORE it freezes the first guest.
        if [ $# -eq 0 ]; then
            if [ "$caller" != "root" ] || [ -n "${SUDO_USER:-}" ]; then
                [ -f "$ALLOW_DIR/$caller" ] || {
                    echo "zfs-quiesce-helper: no quiesce whitelist for account '$caller'" >&2
                    exit 4
                }
            fi
            echo "OK account=$caller"
            exit 0
        fi
        gid=$(require_id "${1:-}") || exit $?
        kind=$(guest_kind "$gid")
        if [ "$kind" = absent ]; then
            echo "id=$gid kind=absent running=no frozen=unknown"
            exit 0
        fi
        if guest_running "$gid" "$kind"; then running=yes; else running=no; fi
        frozen=unknown
        if [ "$kind" = qemu ] && [ "$running" = yes ]; then
            case "$(qm guest cmd "$gid" fsfreeze-status 2>/dev/null)" in
                *frozen*) frozen=yes ;;
                *thawed*) frozen=no  ;;
            esac
        fi
        echo "id=$gid kind=$kind running=$running frozen=$frozen"
        ;;

    freeze)
        gid=$(require_id "${1:-}") || exit $?
        kind=$(guest_kind "$gid")
        case "$kind" in
            qemu)
                qm guest cmd "$gid" fsfreeze-freeze >/dev/null 2>&1 \
                    || fail "VM $gid did not respond to fsfreeze-freeze (agent missing, disabled or busy)"
                echo "froze VM $gid via qemu-guest-agent" ;;
            lxc)
                # ZFS has no FIFREEZE, so a container gets a flush. Saying so
                # out loud matters: it is weaker than a freeze, and the caller
                # should not mistake one for the other.
                pct exec "$gid" -- sync >/dev/null 2>&1 \
                    || fail "'pct exec $gid -- sync' failed"
                echo "flushed container $gid (sync) -- a flush, not a freeze" ;;
            *)  fail "no guest $gid on this host" ;;
        esac
        ;;

    thaw)
        gid=$(require_id "${1:-}") || exit $?
        kind=$(guest_kind "$gid")
        case "$kind" in
            qemu)
                qm guest cmd "$gid" fsfreeze-thaw >/dev/null 2>&1 \
                    || fail "FAILED TO THAW VM $gid -- it is STILL FROZEN and needs a manual 'qm guest cmd $gid fsfreeze-thaw' on this host"
                echo "thawed VM $gid" ;;
            lxc)
                echo "container $gid was flushed, not frozen -- nothing to thaw" ;;
            *)  fail "no guest $gid on this host" ;;
        esac
        ;;

    writers)
        gid=$(require_id "${1:-}") || exit $?
        kind=$(guest_kind "$gid")
        [ "$kind" = qemu ] || fail "guest $gid is not a VM -- VSS writers are a Windows-guest concept"
        guest_running "$gid" "$kind" || fail "VM $gid is not running"
        # The command is fixed here, in root's file. See the header.
        raw=$(qm guest exec "$gid" --timeout 60 -- \
                  cmd.exe /c "vssadmin list writers" 2>/dev/null) \
            || fail "could not run the writer query in VM $gid (guest agent missing, or the guest is not Windows)"
        # `qm guest exec` answers in JSON; out-data carries the console text with
        # escapes. perl is a hard dependency of PVE itself, so it is always here.
        decoded=$(printf '%s' "$raw" | perl -0777 -ne '
            if (/"out-data"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
                $s = $1;
                $s =~ s/\\r//g; $s =~ s/\\n/\n/g;
                $s =~ s/\\"/"/g; $s =~ s/\\\\/\\/g;
                print $s;
            }')
        if [ -z "$decoded" ]; then
            fail "VM $gid returned no writer list (not a Windows guest, or vssadmin needs elevation there)"
        fi
        # One line per writer, plus a summary. Deciding what counts as bad is
        # left to the caller ON PURPOSE -- policy does not belong inside the
        # privileged surface, and a plain report keeps this verb read-only.
        printf '%s\n' "$decoded" | awk '
            /^Writer name:/      { if (name != "") emit(); name = $0; sub(/^Writer name: */, "", name); gsub(/^'"'"'|'"'"'$/, "", name) }
            /State:/             { state = $0; sub(/^ *State: */, "", state) }
            /Last error:/        { err = $0; sub(/^ *Last error: */, "", err) }
            function emit(   cls) {
                # VSS_WRITER_STATE: 1 is stable, 2-5 are waiting states that a
                # writer passes through around a snapshot, 6 and up are the
                # failures. Classifying by the TEXT vssadmin prints rather than
                # by the number keeps this readable and survives the numbering.
                #
                # "Waiting for completion" must NOT read as a fault: it is the
                # normal state right after a snapshot, and treating anything
                # other than Stable as broken would alert after every SUCCESSFUL
                # backup -- noise that gets alerting switched off, which is how
                # the vsql2 failure stayed invisible in the first place.
                if      (state ~ /Failed/) cls = "FAILED"
                else if (state ~ /\[1\]/)  cls = "ok"
                else                       cls = "in-progress"
                total++
                if (cls == "FAILED") failed++; else if (cls == "in-progress") waiting++
                printf "writer=%s state=%s error=%s class=%s\n", name, state, err, cls
                name = ""; state = ""; err = ""
            }
            END {
                if (name != "") emit()
                printf "WRITERS total=%d failed=%d in_progress=%d\n", total, failed, waiting
            }'
        ;;

    ''|-h|--help|help)
        cat >&2 <<'EOF'
zfs-quiesce-helper -- narrow privileged surface for delegated backup accounts.

  zfs-quiesce-helper status          probe: is this account allowed to quiesce here
  zfs-quiesce-helper status <id>     kind / running / frozen for one guest
  zfs-quiesce-helper freeze <id>     VM: fsfreeze-freeze   container: sync
  zfs-quiesce-helper thaw   <id>     VM: fsfreeze-thaw     container: no-op
  zfs-quiesce-helper writers <id>    Windows guest: VSS writer states

Allowed guests are those whose disks live under the datasets listed in
/etc/zfs-quiesce-allow/<account>, written by deploy.sh --join. There is no
verb that runs caller-supplied code in a guest.
EOF
        exit 2 ;;

    *)  die "unknown verb '$verb' (status, freeze, thaw, writers)" ;;
esac

exit 0
