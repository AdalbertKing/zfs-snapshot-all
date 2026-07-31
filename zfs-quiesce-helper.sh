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
# sudo rule for THIS script and nothing else. The script accepts five verbs on
# guest IDs it has been explicitly told about:
#
#     status [<id>]   with no id: "am I usable" probe, prints OK
#                     with an id: kind / running / frozen, one line
#     freeze <id>     VM: fsfreeze-freeze via qemu-guest-agent
#                     container: `pct exec -- sync` (a flush, not a freeze)
#     thaw   <id>     VM: fsfreeze-thaw; container: nothing to undo
#     writers <id>    Windows guest: VSS writer states (see below)
#     sqlfreeze <id> [seconds]
#                     Windows guest: did SQL Server actually freeze and resume
#                     its I/O in the last <seconds> (see below)
#
# No verb takes a command from the caller. `writers` and `sqlfreeze` DO use
# `qm guest exec`, which is the very capability this script exists to fence off
# -- so note what makes them safe: the command is a CONSTANT in this root-owned
# file. The single exception is sqlfreeze's look-back window, which is validated
# to be digits only and bounded before it is interpolated, so it cannot become an
# argument, a flag or a second statement. If someone later "generalises" either
# verb to accept a command, the fence is gone. Don't.
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
# So on Windows, qemu will never tell you anything about writer state. This verb
# is the only way to see it from the host.
#
# What writer state does NOT tell you -- measured on vsql2, 2026-07-31
# ---------------------------------------------------------------------
# An earlier version of this header claimed a `Failed` SqlServerWriter proves the
# snapshot was not application-consistent. That claim was WRONG, and the measured
# counter-example is worth keeping because it is easy to get wrong again:
#
#   A freeze-only requester -- which is exactly what qemu-ga is -- drives SQL
#   Server through `BACKUP DATABASE` to a VDI device and then calls AbortBackup
#   at thaw. SQL logs 3013/3271/4035 ("Processed 0 pages", Windows error 995 =
#   ERROR_OPERATION_ABORTED) and the writer ends in [10] Failed / Timed out.
#   That is the aftermath of a SUCCESSFUL freeze, not of a broken one.
#
# Verified end to end: on vsql2 the writer read [1] Stable immediately before a
# manual `qm guest cmd 100 fsfreeze-freeze` + `fsfreeze-thaw`, and [10] Failed
# immediately after, with the SAME writer instance id -- so nothing re-registered
# or crashed; the successful freeze itself put it there. Application event 24583
# then showed SQL being engaged at EVERY quiesce, nightly job included, both
# before and after an unrelated registry repair that day.
#
# Consequence, and the reason this verb no longer renders a verdict: writer state
# sampled AFTER a quiesce cannot distinguish a healthy quiesce from a broken one.
# Sampled BEFORE one it is more informative, but this script cannot enforce when
# it is called. So it reports the state machine and refuses to translate that
# into a health claim. A caller that alerts on class=failed will alert after
# every successful backup.
#
# Whether SQL's participation yields a RECOVERABLE image is a separate question
# that only a restore test answers. It has not been done.
#
# What `sqlfreeze` DOES answer, and what it does not
# --------------------------------------------------
# SQL Server logs, per database, on every snapshot-style backup:
#
#   3197  "I/O is frozen on database <db>."     -- flushed, holding writes
#   3198  "I/O was resumed on database <db>."   -- released
#
# A balanced 3197/3198 pair is the documented, POSITIVE signal that an
# application-level freeze really happened -- unlike writer state, which says
# nothing. Measured on vsql2 2026-07-31: both ids appear at every quiesce -- the
# 2h pvesr replication runs, the nightly snapsend job at 00:12, and a manual test
# at 16:48 -- perfectly balanced (227/227 on MSSQLSERVER, 187/187 on
# MSSQL$SQL2019).
#
# THE LIMIT (REV-20260731-010 §2). `sqlfreeze` answers "did SQL participate in at
# least one freeze/resume inside this window", NOT "did THIS backup run freeze
# SQL". Nothing ties an event to a caller. On a host where pvesr, snapsend and a
# human all quiesce the same guest, events from a neighbouring operation sitting
# inside the window read as `engaged` even if the run being judged never reached
# its snapshot. Correlating a specific run needs the freeze and the read to
# happen inside ONE operation -- record the highest EventRecordID first, freeze,
# snapshot, thaw, then read only what is newer -- which this verb does not do. It
# is a diagnostic report, not a proof gate, and it is deliberately not wired into
# any automatic verdict.
#
# GRANULARITY (REV-20260731-010 §4). Counting is per INSTANCE -- the event
# provider, `MSSQLSERVER` or `MSSQL$<name>` -- not per database, and `engaged`
# means at least one balanced pair was seen, not that every intended database was
# frozen. That is a consequence of the locale rule below, not an oversight: the
# database name lives in the message TEXT, which is translated, and parsing it is
# exactly the bug that broke the `writers` parser. A database that is offline,
# restoring or otherwise skipped logs nothing and is therefore invisible here, and
# the verb has no notion of which instances it ought to have found.
#
# Matching is on the numeric event ids, never on message text: this estate runs
# Polish Windows installs, where a text match finds nothing at all.
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

# `qm guest exec` answers in JSON; out-data carries the console text with escapes.
# perl is a hard dependency of PVE itself, so it is always here.
decode_out_data() {
    perl -0777 -ne '
        if (/"out-data"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
            $s = $1;
            $s =~ s/\\r//g; $s =~ s/\\n/\n/g;
            $s =~ s/\\"/"/g; $s =~ s/\\\\/\\/g;
            print $s;
        }'
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
        decoded=$(printf '%s' "$raw" | decode_out_data)
        if [ -z "$decoded" ]; then
            fail "VM $gid returned no writer list (not a Windows guest, or vssadmin needs elevation there)"
        fi
        # One line per writer, plus a summary. Deciding what counts as bad is
        # left to the caller ON PURPOSE -- policy does not belong inside the
        # privileged surface, and a plain report keeps this verb read-only.
        # Parsed WITHOUT matching any English label. vssadmin is localised: a
        # Polish guest prints "Nazwa modulu zapisujacego:" / "Stan: [1] Stabilne"
        # / "Ostatni blad:", and an earlier version of this parser -- which keyed
        # on /^Writer name:/, /State:/, /Last error:/ -- silently produced
        # total=0 there. vssadmin had run fine, so the empty-output guard above
        # did not fire either: it reported "no writers" instead of "I could not
        # read this". Measured on two live guests, 2026-07-31: VM 106 on pve1
        # (Polish) and VM 106 on metropolis pve1 (English).
        #
        # What is stable across locales is the STRUCTURE and the NUMBERS:
        #   - the writer name is the only single-quoted string in its block, and
        #     the names themselves stay English even on a localised system;
        #   - the state line always carries [N], and N is VSS_WRITER_STATE;
        #   - the error line is the first non-blank line after the state line.
        # \047 is a single quote -- written as an escape so this stays inside one
        # single-quoted shell string.
        printf '%s\n' "$decoded" | awk '
            index($0, "\047") > 0 {
                if (name != "") emit()
                line = $0
                sub(/^[^\047]*\047/, "", line)
                sub(/\047[^\047]*$/, "", line)
                name = line; state = ""; err = ""; num = -1; want_err = 0
                next
            }
            match($0, /\[[0-9]+\]/) {
                # Drop the label ahead of the first colon -- "State:" / "Stan:"
                # alike -- so the value reads the same in any language.
                state = $0; sub(/^[^:]*:[ \t]*/, "", state); sub(/[ \t]+$/, "", state)
                num = substr($0, RSTART + 1, RLENGTH - 2) + 0
                want_err = 1
                next
            }
            want_err && $0 ~ /[^ \t]/ {
                err = $0; sub(/^[^:]*:[ \t]*/, "", err); sub(/[ \t]+$/, "", err)
                want_err = 0
                next
            }
            function emit(   cls) {
                # VSS_WRITER_STATE: 1 is stable, 2-5 are the waiting states a
                # writer passes through around a snapshot, 6 and up are the
                # failure states. Classified by NUMBER because that is the part
                # that does not change with the guest language.
                #
                # These names describe the state machine OF THE WRITER. They are
                # (no apostrophes in here: this whole awk program lives inside a
                # single-quoted shell string, and one would end it early)
                # deliberately not health verdicts -- see the header: `failed`
                # right after a quiesce is the normal aftermath of a freeze-only
                # requester, and `transient` is normal mid-snapshot. Neither is
                # evidence about the snapshot. Lowercase on purpose: the old
                # SHOUTED "FAILED" invited exactly the alerting rule that would
                # fire after every successful backup.
                if      (num < 0)  cls = "unreadable"
                else if (num == 1) cls = "stable"
                else if (num <= 5) cls = "transient"
                else               cls = "failed"
                total++
                if (cls == "failed") failed++
                else if (cls == "transient") transient++
                else if (cls == "stable") stable++
                else unreadable++
                printf "writer=%s state=%s error=%s class=%s\n", name, state, err, cls
                name = ""; state = ""; err = ""; num = -1
            }
            END {
                if (name != "") emit()
                # total=0 means the parse failed, not that the guest has no
                # writers -- every Windows install has some. Say which it is.
                if (total == 0) {
                    print "WRITERS-UNREADABLE could not parse any writer from the guest reply"
                    exit 0
                }
                printf "WRITERS total=%d stable=%d transient=%d failed=%d unreadable=%d\n", \
                       total, stable, transient, failed, unreadable
                # Shipped with the data, not buried in a man page, because the
                # whole point of this change is that the numbers above read as a
                # verdict when they are not one.
                print "WRITERS-NOTE writer state is not a backup verdict; a freeze-only quiesce leaves writers failed"
            }'
        ;;

    sqlfreeze)
        gid=$(require_id "${1:-}") || exit $?
        # ${2-900}, not ${2:-900}: an ABSENT window means "use the default", but
        # an EMPTY one almost always means the caller interpolated a variable
        # that was not set. Defaulting that silently would answer a question
        # about a window nobody chose. Same rule the config parser applies to
        # blank fields.
        window="${2-900}"
        # The ONLY caller-influenced part of the command below. Digits only, and
        # bounded -- so it cannot become an argument, a flag or a second
        # statement. Everything else in that command is a constant in this
        # root-owned file, which is what keeps this verb a fence and not a
        # general-purpose `qm guest exec`.
        case "$window" in
            ''|*[!0-9]*) die "the look-back window must be a whole number of seconds" ;;
        esac
        [ "$window" -ge 1 ] && [ "$window" -le 86400 ] \
            || die "the look-back window must be between 1 and 86400 seconds"
        kind=$(guest_kind "$gid")
        [ "$kind" = qemu ] || fail "guest $gid is not a VM"
        guest_running "$gid" "$kind" || fail "VM $gid is not running"
        # SQL Server logs 3197 "I/O is frozen on database X" when it flushes and
        # holds writes for a snapshot, and 3198 "I/O was resumed on database X"
        # when it releases. A balanced pair is the documented signal that an
        # application-level quiesce happened -- unlike writer state, which says
        # nothing. It is NOT tied to any particular run, and counting is per
        # instance rather than per database; see the header for both limits.
        #
        # Matched on the numeric event ids, never on message text: this guest
        # estate has Polish Windows installs, and a text match would silently
        # find nothing there. Only double quotes inside -- the whole command is
        # one single-quoted shell string.
        # ONE physical line, deliberately. qemu-ga on Windows joins argv back
        # into a command line, and a multi-line -Command argument arrives as
        # nothing at all: "Cannot process the command because of a missing
        # parameter. A command must follow -Command." Measured on vsql2, not
        # guessed. Keep it one line even though it is long.
        ps_cmd='$ProgressPreference="SilentlyContinue"; $e = Get-WinEvent -FilterHashtable @{LogName="Application";Id=@(3197,3198);StartTime=(Get-Date).AddSeconds(-'"$window"')} -ErrorAction SilentlyContinue; if (-not $e) { "SQLFREEZE-NONE"; exit 0 }; $e | Group-Object ProviderName | ForEach-Object { $f = @($_.Group | Where-Object {$_.Id -eq 3197}).Count; $r = @($_.Group | Where-Object {$_.Id -eq 3198}).Count; $l = ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated.ToString("yyyy-MM-ddTHH:mm:ss"); "SQLFREEZE-INSTANCE {0} {1} {2} {3}" -f $_.Name,$f,$r,$l }'
        qexec_timeout=120
        raw=$(qm guest exec "$gid" --timeout "$qexec_timeout" -- \
                  powershell.exe -NoProfile -Command "$ps_cmd" 2>/dev/null) \
            || fail "could not query the event log in VM $gid (guest agent missing, or the guest is not Windows)"
        decoded=$(printf '%s' "$raw" | decode_out_data)
        # An empty reply is NOT "no SQL here" -- that answer arrives as the
        # SQLFREEZE-NONE sentinel and is handled below. Empty means no answer at
        # all, and the two reasons are worth telling apart.
        #
        # When the guest is still working when the timeout expires, qm prints
        # "timeout reached, returning pid" and answers with a bare {"pid": N} and
        # NO out-data -- while exiting 0, so the check above does not fire.
        # Measured on a Server 2008 guest here, where even `$PSVersionTable`
        # exceeds two minutes: PowerShell startup itself is the slow part, so
        # every PowerShell-based verb is unusable on such a guest.
        if [ -z "$decoded" ]; then
            case "$raw" in
                *'"pid"'*) fail "VM $gid did not answer within ${qexec_timeout}s -- it is still running the query (qm returned only a pid). Old Windows guests can need longer than any sane timeout just to start PowerShell" ;;
                *)         fail "no usable reply from VM $gid -- the guest may not be Windows, or PowerShell is unavailable there" ;;
            esac
        fi
        printf '%s\n' "$decoded" | awk -v gid="$gid" -v win="$window" '
            /^SQLFREEZE-INSTANCE/ {
                inst++; frozen += $3; resumed += $4
                if ($3 != $4) unbalanced++
                if ($5 > last) last = $5
                printf "instance=%s frozen=%s resumed=%s last=%s\n", $2, $3, $4, $5
            }
            END {
                # No events is NOT a failure: plenty of guests have no SQL at
                # all. It is simply the absence of evidence, and it says so.
                if (inst == 0) {
                    printf "SQLFREEZE guest=%s window=%ss verdict=no-freeze-seen\n", gid, win
                } else if (unbalanced > 0) {
                    printf "SQLFREEZE guest=%s window=%ss instances=%d frozen=%d resumed=%d verdict=unbalanced last=%s\n", \
                           gid, win, inst, frozen, resumed, last
                } else {
                    printf "SQLFREEZE guest=%s window=%ss instances=%d frozen=%d resumed=%d verdict=engaged last=%s\n", \
                           gid, win, inst, frozen, resumed, last
                }
                # Two caveats, both of which someone reading a verdict line in
                # isolation would otherwise supply wrongly from imagination.
                print "SQLFREEZE-NOTE SQL participated in at least one VSS freeze/resume within the selected window. This is not correlated to a specific snapshot run."
                print "SQLFREEZE-NOTE counted per instance, not per database; engaged does not prove the snapshot restores"
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
  zfs-quiesce-helper sqlfreeze <id> [seconds]
                                     SQL Server: was I/O actually frozen and
                                     resumed in the last <seconds> (default 900)

`writers` reports the writers' own state machine, NOT a health verdict. A
freeze-only quiesce (which is what qemu-ga performs) normally leaves writers in
a failed state, so class=failed sampled after a backup is expected and must not
be alerted on. Measured on vsql2 2026-07-31; see the header of this script.

Allowed guests are those whose disks live under the datasets listed in
/etc/zfs-quiesce-allow/<account>, written by deploy.sh --join. There is no
verb that runs caller-supplied code in a guest.
EOF
        exit 2 ;;

    *)  die "unknown verb '$verb' (status, freeze, thaw, writers, sqlfreeze)" ;;
esac

exit 0
