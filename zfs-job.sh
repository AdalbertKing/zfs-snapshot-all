#!/bin/bash
# ------------------------------------------------------------------------------
# zfs-job.sh -- the envelope every generated cron line used to carry inline.
#
# WHY IT MOVED OUT OF THE LINE. Measured on pve9, 2026-08-30: the envelope is
# 336 characters and it is repeated in EVERY job, while cron refuses a command
# over 1000 bytes. An ordinary two-relationship host was already at 890 on its
# backup lines and 934 on a one-source replica; a second source on the replica
# reached 1160 and crontab(1) said only "command too long", which reached the
# operator as an install that rolled back for no stated reason.
#
# The first attempt shortened the PATHS instead, by naming them once as crontab
# variables. It bought ~140 bytes and cost something worth more: a line copied
# out of the crontab and run by hand -- which is what an admin does to diagnose
# a job -- stopped working, with `$ZSA_LOG: ambiguous redirect`. Owner's
# judgement, and it is right: the envelope is one third of every line and the
# paths are not the problem.
#
# So the envelope lives here and the line keeps its ENGINE COMMAND in plain
# sight:
#
#     30 2 * * * /path/zfs-job.sh "pve9 replica copy (weekly)" \
#                  --log=/root/scripts/cron.log \
#                  --notify=/root/scripts/notify-fail.sh -- <engine command>
#
# The line is self-contained: copy it, run it, it behaves exactly as cron runs
# it. Nothing is hidden -- what executes is still readable in `crontab -l` --
# and cron2conf.sh can still read the engine call back out of it.
#
# THE CONTRACT THIS PRESERVES, byte for byte in the log:
#
#   ZFS-JOB BEGIN <label>            on entry
#   <the command's stderr>           appended, whatever it was
#   ZFS-JOB END <label> rc=<n>       on exit, with the COMMAND's status
#   the notify script                called only when rc is not 0, with the
#                                    label and the last N lines of stderr
#   the WARN script, instead         when rc is 75 (EX_TEMPFAIL): the engine
#                                    skipped the run because the previous one
#                                    still holds its lock (2026-10-06). Nothing
#                                    was copied, which is worth knowing, and
#                                    nothing broke, which is not worth a
#                                    failure mail -- so it joins the digest.
#
# AND IT EXITS 0 REGARDLESS. That is deliberate and is not laziness: the inline
# envelope ended in `rm -f "$e"`, so the line always exited 0, and cron mails
# whatever a job writes OR returns non-zero for. Alerting is the notify
# script's job precisely so that cron does not also mail -- exiting with the
# command's status here would add a second, unrate-limited mail per failure,
# which is the flood notify-fail.sh's cooldown exists to prevent.
#
# ...EXCEPT WHEN A HUMAN STARTED IT (2026-10-12, live campaign on pve9b):
# `run-replicas` (F7 on F6, the udev trigger) and F8 on F2 run the very same line
# and read ITS status -- and saw 0 for a replica whose copy had failed ("dataset
# key must be loaded", END rc=1 in the log). ZFS_JOB_PROPAGATE_RC=1 makes the
# wrapper exit with the command's status; cron never sets it, so cron's contract
# above is unchanged.
# ------------------------------------------------------------------------------
set -u

VERSION='v1.2'

usage() {
    cat >&2 <<'EOF'
Usage: zfs-job.sh <label> [--log=FILE] [--notify=SCRIPT] [--detail=N] -- <command>...

  Runs <command>, brackets it with ZFS-JOB BEGIN/END markers in the log, and
  calls the notify script when it fails. Everything after -- is the command and
  is executed as given.

  --log     where the markers and the command's stderr go
            (default: <this script's parent dir>/cron.log)
  --notify  called as: <script> "<label>" "<last N lines of stderr>"
            (default: <this script's parent dir>/notify-fail.sh)
  --warn    called the same way when the command exits 75 (skipped: the
            previous run still holds the lock), INSTEAD of --notify
            (default: notify-warn.sh beside the --notify script)
  --detail  how many trailing stderr lines the notification carries (default 8)
  --pve-guests=HOST:ID[,ID...]
            the command snapshots or prunes the live disks of these Proxmox
            guests, which must run on HOST ("" = this host). When the host is a
            member of a PVE cluster and a guest's config is under another node,
            the command is NOT run: END rc=76 and the notify script is called
            (the disk here is a pvesr replication target). Written by gen-cron.sh.
            The id `tree` marks a recursive line over a parent (rpool/data): the
            guests are read from the tree at run time (see TREES below).

  Exits 0 whatever the command returned -- see the header for why. The
  command's own status is recorded in the END marker and is what decides
  whether anyone is notified.
EOF
    exit 2
}

# Defaults derived from where this script sits, because that is the one thing
# it can know without being told: the package is deployed to <base>/zfs-snapshot-all
# and writes its log and notify script to <base>/. True for root
# (/root/scripts/) and for a delegated account (/home/<acct>/) alike.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_base="$(dirname "$_here")"

LABEL=""; LOG="$_base/cron.log"; NOTIFY="$_base/notify-fail.sh"; WARN=""; DETAIL=8; GUESTS=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help)    usage ;;
        --log=*)      LOG="${1#--log=}"; shift ;;
        --notify=*)   NOTIFY="${1#--notify=}"; shift ;;
        --warn=*)     WARN="${1#--warn=}"; shift ;;
        --detail=*)   DETAIL="${1#--detail=}"; shift ;;
        --pve-guests=*) GUESTS="${1#--pve-guests=}"; shift ;;
        --)           shift; break ;;
        -*)           echo "zfs-job: unknown option: $1" >&2; usage ;;
        *)            if [ -z "$LABEL" ]; then LABEL="$1"; shift
                      else echo "zfs-job: takes exactly one label" >&2; usage; fi ;;
    esac
done

[ -n "$LABEL" ] || { echo "zfs-job: no label" >&2; usage; }
[ "$#" -gt 0 ]  || { echo "zfs-job: nothing to run -- the command follows --" >&2; usage; }
case "$DETAIL" in ''|*[!0-9]*) echo "zfs-job: --detail takes a count" >&2; usage ;; esac

# The stderr file, and the fallback the inline envelope also had. A failing
# mktemp used to leave $e empty, which made `2>"$e"` an ambiguous redirect and
# the command never ran AT ALL -- silently. That is the 2026-08-09 signature the
# fallback exists to prevent, and it is kept here for the same reason.
e=$(mktemp 2>/dev/null) || e="$LOG.err.$$"

printf '%s ZFS-JOB BEGIN %s\n' "$(date -Is)" "$LABEL" >>"$LOG" 2>/dev/null

# PVE GUEST GUARD (owner 2026-10-28; gen-cron.sh job_cron_line has the why).
# Where a guest runs is a fact of the cluster file system: its config sits under
# /etc/pve/nodes/<node>/{qemu-server,lxc}/<id>.conf. Those directories are
# world-searchable, so a delegated account can test the file's EXISTENCE without
# reading it (measured on pve2 as zfsbackup, 2026-10-28; .members and
# storage.cfg are not readable). The host the line expects is mapped to a node
# by name -- this fleet's hostname == node name -- or, for an address, by
# getent. Nothing is decided where the answer is not known: not a cluster
# member, a host that is no node of this cluster (another cluster's guest ids
# mean nothing here), or a guest defined nowhere (a destroyed guest's disk).
PVE_NODES="${ZFS_JOB_PVE_NODES:-/etc/pve/nodes}"
pve_node_of() {   # <host, "" = this one> -> its node name in this cluster
    local h="${1#*@}" n r
    if [ -z "$h" ]; then
        n="$(readlink "${ZFS_JOB_PVE_LOCAL:-/etc/pve/local}" 2>/dev/null)"; n="${n##*/}"
        [ -n "$n" ] || n="$(hostname -s 2>/dev/null)"
        [ -n "$n" ] && [ -d "$PVE_NODES/$n" ] && { printf '%s' "$n"; return 0; }
        return 1
    fi
    for n in "$h" "${h%%.*}"; do
        [ -d "$PVE_NODES/$n" ] && { printf '%s' "$n"; return 0; }
    done
    r="$(getent hosts "$h" 2>/dev/null | awk '{print $2; exit}')"; r="${r%%.*}"
    [ -n "$r" ] && [ -d "$PVE_NODES/$r" ] && { printf '%s' "$r"; return 0; }
    return 1
}
guest_moved="" guest_unsure="" want="" tree_moved=""
if [ -n "$GUESTS" ] && [ -d "$PVE_NODES" ]; then
    want="$(pve_node_of "${GUESTS%%:*}")" || want=""
    _ids="${GUESTS#*:}"
    for _id in ${_ids//,/ }; do
        case "$_id" in ''|*[!0-9]*) continue ;; esac
        for _d in "$PVE_NODES"/*/; do
            _n="${_d%/}"; _n="${_n##*/}"
            if [ -f "$_d/qemu-server/$_id.conf" ] || [ -f "$_d/lxc/$_id.conf" ]; then
                if [ -z "$want" ]; then
                    # The guest IS in this cluster, but the line's host could not be
                    # told apart as a node: run as before, and say so -- a silent
                    # "not decided" is the gap this guard exists to close.
                    guest_unsure="${guest_unsure:+$guest_unsure, }guest $_id (on $_n)"
                elif [ "$_n" != "$want" ]; then
                    guest_moved="${guest_moved:+$guest_moved, }guest $_id runs on $_n"
                fi
            fi
        done
    done
fi

# TREES (owner 2026-10-29, variant A). A recursive line over a parent names no
# guest; which guests' disks sit under it is a fact of the pool, read here at run
# time: `zfs list -r` of each tree the command names (over the line's own ssh
# options for a remote tree), the guest id from the disk's name (vm-/subvol-/
# base-N-disk-M), and where the guest runs from its config's existence, as above.
# A disk under the tree whose guest runs on ANOTHER node is a pvesr replica here.
# A flat-recursive engine call (-R: one snapshot per dataset) leaves exactly those
# disks out with -X and runs -- the config keeps its one line, the rest of the tree
# keeps its snapshots, and a WARN names what was left out; anything else (a prune,
# an atomic -r) cannot leave a child out and is NOT RUN, rc 76, as for a single
# guest. Nothing is decided where the tree cannot be listed: the command runs and
# WARNs, like an unmapped host.
tree_out="" tree_unsure="" tree_x=()
case ",${GUESTS#*:}," in *,tree,*) _tree=1 ;; *) _tree=0 ;; esac
if [ "$_tree" = 1 ] && [ -d "$PVE_NODES" ] && [ -n "$want" ]; then
    _ssh=() _w="" _p="" _rest=("${@:2}") _i=0 _pat="" _src_done=""
    while [ "$_i" -lt "${#_rest[@]}" ]; do
        _w="${_rest[$_i]}"; _p="${_rest[$((_i + 1))]:-}"
        case "$_w" in
            -K) _ssh+=(-i "$_p"); _i=$((_i + 1)) ;;
            -k) _ssh+=(-o "UserKnownHostsFile=$_p"); _i=$((_i + 1)) ;;
            -O) _ssh+=(-o "$_p"); _i=$((_i + 1)) ;;
            -p) _ssh+=(-p "$_p"); _i=$((_i + 1)) ;;
            -c) _ssh+=(-c "$_p"); _i=$((_i + 1)) ;;
        esac
        _i=$((_i + 1))
    done
    for _w in "${@:2}"; do
        # a dataset or [user@]host:dataset; a leading / is a FILE (zfs list would map it
        # to its file system), a word without / or : is a prefix, a label or a value
        # A dataset word has a '/' or is account@host:dataset. A bare "x:y" is an option's
        # VALUE -- every generated prune carries -P "__replicate_:2", which used to be taken
        # for the source, so the real tree was never listed and the prune ran over the
        # replica disk (campaign pve10, 2026-10-29: kampcap/data with CT 902 on another node).
        case "$_w" in -*|/*|*[!A-Za-z0-9_.:/@,-]*) continue ;; */*|*@*:*) ;; *) continue ;; esac
        # ONLY the SOURCE: the first dataset word (snapget/snapsend SOURCE DEST, delsnaps
        # DATASETS PATTERN). A copy's TARGET is full of other nodes' guest disks -- that
        # is what a backup is -- and must not be read as replicas.
        [ -n "${_src_done:-}" ] && break
        _src_done=1
        for _t in ${_w//,/ }; do
            _h=""; _ds="$_t"
            # remote = a ':' with no '/' before the first ':' -- the engines' own rule
            # (delsnaps.sh parse_remote): host:ds and user@host:ds alike; a local name may
            # carry a ':' after its pool/ (tank/data:x). REV-20261030-184: host:ds was skipped.
            case "$_t" in *:*) case "${_t%%:*}" in */*) ;; *) _h="${_t%%:*}"; _ds="${_t#*:}" ;; esac ;; esac
            case "$_ds" in */*|[A-Za-z]*) ;; *) continue ;; esac
            if [ -n "$_h" ]; then
                _list="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${_ssh[@]}" "$_h" "zfs list -H -o name -r -- '$_ds'" 2>/dev/null)" || _list="!"
            else
                _list="$(zfs list -H -o name -r -- "$_ds" 2>/dev/null)" || _list="!"
            fi
            if [ "$_list" = "!" ]; then
                # a word that is no dataset (a snapshot prefix with a slash, say) lists
                # nothing; only a REMOTE tree that cannot be read is a real "not known"
                [ -n "$_h" ] && tree_unsure="${tree_unsure:+$tree_unsure, }$_t"
                continue
            fi
            while IFS= read -r _c; do
                _b="${_c##*/}"
                case "$_b" in vm-*-disk-*|subvol-*-disk-*|base-*-disk-*) ;; *) continue ;; esac
                _id="${_b#*-}"; _id="${_id%%-*}"
                case "$_id" in ''|*[!0-9]*) continue ;; esac
                for _d in "$PVE_NODES"/*/; do
                    _n="${_d%/}"; _n="${_n##*/}"
                    [ "$_n" = "$want" ] && continue
                    if [ -f "$_d/qemu-server/$_id.conf" ] || [ -f "$_d/lxc/$_id.conf" ]; then
                        case " $tree_out " in *" $_c "*) ;; *)
                            tree_out="${tree_out:+$tree_out }$_c"
                            tree_moved="${tree_moved:+$tree_moved, }$_c (guest $_id runs on $_n)"
                            _pat="${_c//./[.]}"
                            tree_x+=(-X "^$_pat(/|\$)") ;;
                        esac
                    fi
                done
            done <<< "$_list"
        done
    done
    if [ -n "$tree_out" ]; then
        case "${1##*/} ${*:2} " in
            snapget.sh*" -R "*|snapsend.sh*" -R "*) set -- "$1" "${tree_x[@]}" "${@:2}" ;;
            *) guest_moved="${guest_moved:+$guest_moved, }$tree_moved"; tree_moved="" ;;
        esac
    fi
fi

if [ -n "$guest_moved" ]; then
    printf 'zfs-job: NOT RUN -- %s, not on %s: the disk there is a replication target (pvesr), and our snapshots or prunes on it would be undone or would break replication. Back this guest up where it runs, or move it back. (pve_guest_guard = no turns this check off.)\n' \
        "$guest_moved" "$want" >"$e"
    rc=76
else
    "$@" 2>"$e"
    rc=$?
fi

cat "$e" >>"$LOG" 2>/dev/null
printf '%s ZFS-JOB END %s rc=%s\n' "$(date -Is)" "$LABEL" "$rc" >>"$LOG" 2>/dev/null

# Beside the notify script by default: deploy.sh installs the two together, in
# /root/scripts/ for root and in the account's home for a delegated account, so
# the generated lines need no extra argument (they are near cron's 1000-byte
# limit already -- see the header).
[ -n "$WARN" ] || WARN="$(dirname "$NOTIFY")/notify-warn.sh"
if [ "$rc" -eq 75 ]; then
    [ -x "$WARN" ] && "$WARN" "$LABEL -- skipped, the previous run still holds the lock" \
        "$(tail -n "$DETAIL" "$e" 2>/dev/null)" 2>>"$LOG"
elif [ "$rc" -ne 0 ] && [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$LABEL" "$(tail -n "$DETAIL" "$e" 2>/dev/null)" 2>>"$LOG"
elif [ -n "${tree_moved:-}" ]; then
    _u="zfs-job: guest guard: left out of this run, a pvesr replica here: $tree_moved -- the rest of the tree ran; back those guests up where they run"
    printf '%s\n' "$_u" >>"$LOG" 2>/dev/null
    [ -x "$WARN" ] && "$WARN" "$LABEL -- guest disks left out" "$_u" 2>>"$LOG"
elif [ -n "${tree_unsure:-}" ]; then
    _u="zfs-job: guest guard: could not list the tree $tree_unsure, so guests under it were not checked"
    printf '%s\n' "$_u" >>"$LOG" 2>/dev/null
    [ -x "$WARN" ] && "$WARN" "$LABEL -- guest guard not checked" "$_u" 2>>"$LOG"
elif [ -n "$guest_unsure" ]; then
    _u="zfs-job: guest guard: cannot tell which PVE node '${GUESTS%%:*}' is, so where $guest_unsure runs was not checked -- set pve_node = <node> in the section (or pve_guest_guard = no)"
    printf '%s\n' "$_u" >>"$LOG" 2>/dev/null
    [ -x "$WARN" ] && "$WARN" "$LABEL -- guest guard not checked" "$_u" 2>>"$LOG"
fi

rm -f "$e"
[ "${ZFS_JOB_PROPAGATE_RC:-0}" = 1 ] && exit "$rc"
exit 0
