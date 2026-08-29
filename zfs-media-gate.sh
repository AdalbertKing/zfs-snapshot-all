#!/bin/bash
# ------------------------------------------------------------------------------
# zfs-media-gate.sh -- the import/export bracket around a replica onto removable
# media.
#
# THE SHAPE, from the owner (2026-08-28), modelled on FerroBackup's replica: a
# source may have several replica targets -- three in the case that prompted
# this -- and two of them are pools on disks that get unplugged and carried
# away. So a write to one of those is bracketed:
#
#     zpool import  ->  sync  ->  zpool export
#
# and the disk can be pulled the moment the run ends. Triggered from cron, or by
# something firing when the medium is inserted; this file does not care which.
#
# THE TRANSFER ITSELF IS NOT NEW. A replica onto a local pool is what
# `zfs-backup.sh local-backup` already installs -- snapsend to a local target.
# What was missing is everything around it, and one thing in particular:
#
#     THE ABSENCE OF ONE MEDIUM IS NOT AN ERROR.
#
# It is a disk in a safe. Every other relationship in this package treats an
# unreachable target as a fault because for them it is one; here it is the
# normal state most of the time, and one replica being away must not fail the
# run, alarm anyone, or affect the other two.
#
#   zfs-media-gate.sh attach <pool> <label>   import if needed; 0 = go, 1 = away
#   zfs-media-gate.sh detach <pool> <label>   export, but ONLY if we imported it
#   zfs-media-gate.sh status <pool> <label>   look, change nothing
#
# ONLY WHAT WE TOOK. If the pool was already imported when `attach` ran, it was
# somebody else's decision -- a person looking at it, another job, an operator
# mid-task -- and `detach` leaves it alone. Exporting a pool this run did not
# import would yank the floor out from under whoever did. Same discipline as the
# restore's pause, and for the same reason.
# ------------------------------------------------------------------------------
set -uo pipefail

VERSION='v1.1'

usage() {
    cat >&2 <<'EOF'
Usage: zfs-media-gate.sh <attach|detach|status> <pool> <label> [--dataset D] [--dir DIR]... [--stats FILE] [--quiet]

  attach   import the pool if it is not already imported.
             0  the medium is here -- run the job
             1  it is not here -- skip the job, quietly, WITHOUT alerting
             2  something is wrong and a human is needed
  detach   export the pool, but only if this tool imported it.
  status   report presence; change nothing.
EOF
    exit 2
}

# WHERE TO LOOK FOR THE DISK. `zpool import` scans /dev by default, which is
# right for a disk in a slot and wrong for anything else -- and when it is
# wrong the pool is simply not found, so a medium that IS present reads as
# away and the job skips for ever without saying anything is amiss.
#
# Found on the lab, 2026-08-29: a file-backed pool used to stand in for a
# removable disk was reported "not here" while sitting in /root. Repeatable,
# passed straight through to `zpool import -d`.
VERB=""; POOL=""; LABEL=""; DATASET=""; STATS=""; QUIET=0; _own=0
IMPORT_DIRS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help)    usage ;;
        --quiet)      QUIET=1; shift ;;
        --stats)      STATS="${2:-}"; shift 2 ;;
        --stats=*)    STATS="${1#--stats=}"; shift ;;
        --dataset)    DATASET="${2:-}"; shift 2 ;;
        --dataset=*)  DATASET="${1#--dataset=}"; shift ;;
        --dir)        IMPORT_DIRS+=(-d "${2:-}"); shift 2 ;;
        --dir=*)      IMPORT_DIRS+=(-d "${1#--dir=}"); shift ;;
        -*)           echo "unknown option: $1" >&2; usage ;;
        *)            if   [ -z "$VERB" ];  then VERB="$1"
                      elif [ -z "$POOL" ];  then POOL="$1"
                      elif [ -z "$LABEL" ]; then LABEL="$1"
                      else echo "too many arguments: $1" >&2; usage
                      fi; shift ;;
    esac
done
[ -n "$VERB" ] && [ -n "$POOL" ] && [ -n "$LABEL" ] || usage
case "$VERB" in attach|detach|status) ;; *) echo "unknown verb: $VERB" >&2; usage ;; esac

# A pool name and a label both reach a shell command and a file path. Checked
# here rather than assumed: this runs from cron with whatever the generator
# wrote, and from udev with whatever the rule passed.
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "zfs-media-gate: '$LABEL' is not a valid label" >&2; exit 2 ;; esac
case "$POOL"  in *[!A-Za-z0-9._:-]*|''|-*) echo "zfs-media-gate: '$POOL' is not a valid pool name" >&2; exit 2 ;; esac

command -v zfs   >/dev/null || { echo "zfs-media-gate: 'zfs' not found in PATH" >&2; exit 2; }
command -v zpool >/dev/null || { echo "zfs-media-gate: 'zpool' not found in PATH" >&2; exit 2; }

STATE_DIR="${MEDIA_STATE_DIR:-/var/lib/zfs-snapshot-all/media}"
SEEN="$STATE_DIR/$LABEL.last-seen"
OURS="$STATE_DIR/$LABEL.imported-by-us"

say() { [ "$QUIET" -eq 1 ] || printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
emit() {
    [ -n "$STATS" ] || return 0
    printf '{"time":"%s","script":"%s","pool":"%s","label":"%s","verb":"%s","status":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$(basename "$0")" "$POOL" "$LABEL" "$VERB" "$1" \
        >> "$STATS" 2>/dev/null || true
}
imported() { zpool list -H -o name "$POOL" >/dev/null 2>&1; }
pool_guid() { zpool get -H -o value guid "$POOL" 2>/dev/null; }

# Is the marker OURS, and about the pool that is in the slot right now?
#
# REV-20260829-124 F1. The already-imported branch of `attach` used to begin
# with `rm -f "$OURS"`, on the reasoning that a pool already imported was
# somebody else's decision. That is true exactly once: when we never imported
# it. It is false after our OWN run was interrupted between attach and detach --
# a kill, a reboot, an overlapping retry -- and there the marker is the only
# fact that says the pool is ours to put away. Deleting it turned a
# package-owned import into an apparently foreign one, so the following detach
# reported success without exporting, and every retry after that did the same.
# The disk stayed live indefinitely while the job said it was safe to unplug.
#
# The marker therefore records the pool's GUID. A marker whose GUID matches the
# pool in the slot is our interrupted run resuming. A marker whose GUID does NOT
# match means a different pool of the same name is in the slot while we still
# hold ownership of another one -- rotated media share a name, so this is
# reachable -- and there the answer is to stop, not to guess: exporting would
# hit the wrong disk and deleting the marker would discard the evidence that we
# still owe an export somewhere.
#
# The one case this cannot see: our run died, an operator exported the pool and
# imported it again themselves, and the GUID is naturally identical. We will
# treat that as ours and export it. Nothing observable distinguishes the two,
# the reviewer's criterion 1 asks for exactly this, and the window is only ever
# open between an interrupted attach and the next run.
# 0 = ours, and it is this pool.  1 = no marker, so foreign.
# 2 = a marker exists that this run cannot confirm against the pool in the slot.
#     NOT the same as 1, and the distinction is the whole point: 1 means we owe
#     nothing, 2 means we owe an export on SOME medium and must not guess which.
marker_is_ours() {
    [ -f "$OURS" ] || return 1
    local want cur
    want="$(sed -n 's/^guid=//p' "$OURS" 2>/dev/null | head -1)"
    cur="$(pool_guid)"
    [ -n "$want" ] && [ -n "$cur" ] || return 2
    [ "$want" = "$cur" ] || return 2
    return 0
}

# The dataset check, run after the pool is in. "The disk is not plugged in" and
# "a disk IS in the slot but not the one I was told to write to" are different
# events and only the first is normal -- the second is the wrong medium, or a
# rename, or a destroy. An operator handed one message for both learns to treat
# the dangerous one as routine.
check_dataset() {
    [ -n "$DATASET" ] || return 0
    zfs list -H -o name "$DATASET" >/dev/null 2>&1 && return 0
    say "REFUSING: pool '$POOL' is imported but '$DATASET' is not on it. That is not an absent medium -- it is the wrong one, or the dataset was renamed or destroyed. A human is needed."
    emit wrong_medium
    return 2
}

case "$VERB" in

status)
    if imported; then
        check_dataset || exit $?
        say "medium '$POOL' for '$LABEL' is present"
        emit present; exit 0
    fi
    last="never"; [ -r "$SEEN" ] && last="$(cat "$SEEN" 2>/dev/null)"
    say "medium '$POOL' for '$LABEL' is away (last seen: $last)"
    emit absent; exit 1
    ;;

attach)
    if imported; then
        marker_is_ours; _own=$?
        case "$_own" in
            0)  # Our own interrupted run. The marker STAYS.
                check_dataset || exit $?
                mkdir -p "$STATE_DIR" 2>/dev/null && date '+%Y-%m-%d %H:%M:%S' > "$SEEN" 2>/dev/null || :
                say "medium '$POOL' for '$LABEL' is already imported AND carries this package's ownership marker -- a previous run was interrupted before it could export. Keeping ownership; this run will export it when it is done."
                emit present_ours_resumed; exit 0 ;;
            2)  # A marker exists and we cannot match it to the pool in the slot.
                say "REFUSING: '$LABEL' still holds an ownership marker for '$POOL', but this run cannot match it to the pool that is imported now (marker guid: $(sed -n 's/^guid=//p' "$OURS" 2>/dev/null | head -1 | sed 's/^$/none/'); pool guid: $(pool_guid | sed 's/^$/unreadable/')). Exporting could hit the wrong disk and clearing the marker would discard the only record that an export is still owed. A human is needed."
                emit ownership_ambiguous; exit 2 ;;
        esac
        # No marker at all: somebody else's import, and it stays that way.
        check_dataset || exit $?
        mkdir -p "$STATE_DIR" 2>/dev/null && date '+%Y-%m-%d %H:%M:%S' > "$SEEN" 2>/dev/null || :
        say "medium '$POOL' for '$LABEL' was ALREADY imported -- using it, and detach will leave it as it found it."
        emit present_not_ours; exit 0
    fi

    # AMBIGUITY IS A REFUSAL, NOT A CHOICE. Rotated media are usually identical
    # disks holding a pool of the same name, and if two are plugged in at once
    # `zpool import` sees two candidates. Picking one would mean writing this
    # replica onto whichever disk ZFS happened to list first -- and the operator
    # would have no way to know which.
    cand="$(zpool import ${IMPORT_DIRS[@]+"${IMPORT_DIRS[@]}"} 2>/dev/null | awk -v p="$POOL" '$1=="pool:" && $2==p {n++} END{print n+0}')"
    if [ "$cand" -gt 1 ]; then
        say "REFUSING: $cand pools named '$POOL' are available to import. Rotated media often share a name, so this is two disks in at once. Unplug one, or import the one you mean by its id and re-run -- this will not choose for you."
        emit ambiguous; exit 2
    fi

    if ! zpool import ${IMPORT_DIRS[@]+"${IMPORT_DIRS[@]}"} "$POOL" 2>/dev/null; then
        last="never"; [ -r "$SEEN" ] && last="$(cat "$SEEN" 2>/dev/null)"
        say "SKIPPED: medium '$POOL' for '$LABEL' is not here (last seen: $last). Nothing was run and nothing is wrong -- plug it in and the next run catches up."
        emit skipped_absent; exit 1
    fi

    if ! check_dataset; then
        # We imported it and cannot use it. Put it back the way we found it
        # rather than leaving a pool imported that nobody asked for.
        zpool export "$POOL" 2>/dev/null || say "and '$POOL' could NOT be exported again -- it is imported and unusable; look at it before pulling the disk."
        exit 2
    fi
    # RECORDING THAT WE IMPORTED IT IS NOT BEST-EFFORT.
    #
    # REV-20260829-123 F2. This whole write used to end in `|| :`, so an
    # unwritable state directory produced exit 0 and the message that this run
    # would export the pool again -- while leaving no marker. `detach` then read
    # the missing marker as "somebody else imported it", left the pool active,
    # and also exited 0. A successful bracket could therefore leave a pool
    # imported while the job reported success: exactly when an operator believes
    # the disk is safe to unplug.
    #
    # So a failure here is a hard error, and the error path first puts the
    # machine back the way it found it.
    if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! printf 'pool=%s
guid=%s
' "$POOL" "$(pool_guid)" > "$OURS" 2>/dev/null; then
        say "could not record that this run imported '$POOL' (state dir: $STATE_DIR). Without that marker nothing would ever export it again, so this run will not proceed as if it had one."
        if zpool export "$POOL" 2>/dev/null; then
            say "'$POOL' was exported again -- the machine is as it was before this run, and nothing was transferred."
            emit import_unrecorded
        else
            say "WARNING: could not export '$POOL' either. DO NOT UNPLUG THE DISK. The pool is imported, unrecorded, and this run cannot put it back -- export it by hand."
            emit import_unrecorded_stuck
        fi
        exit 2
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$SEEN" 2>/dev/null || :
    say "imported '$POOL' for '$LABEL' -- this run will export it again when it is done."
    emit imported; exit 0
    ;;

detach)
    # PRESENCE IS THE FIRST QUESTION, OWNERSHIP THE SECOND.
    #
    # Found on the lab, 2026-08-29. These two tests used to run the other way
    # round, so the commonest case of all -- the disk is in a safe, attach
    # skipped, and detach still runs because it sits outside the `if` -- was
    # answered with "leaving 'rotlab' imported: this run did not import it".
    # The pool was not imported. It was not there at all.
    #
    # That is the line an operator reads every single night a medium is out,
    # and it says the opposite of the truth: it describes a pool left active on
    # a disk, which is the one state that makes unplugging dangerous. Whoever
    # eventually meets a REAL "leaving imported" -- somebody else's import, mid
    # task -- will have been taught for months that it means nothing.
    if ! imported; then
        # A marker here means the medium went away while this package still
        # held it -- pulled without a detach, or the host went down mid-run.
        # Said out loud, because an unclean removal is exactly the event that
        # can leave the pool on that disk needing a scrub, and nothing else
        # would ever mention it. The marker is still cleared: the pool is gone
        # with the disk, there is nothing left to export, and keeping it would
        # fail every future run closed for a medium that no longer exists.
        if [ -f "$OURS" ]; then
            say "WARNING: '$POOL' is no longer imported, but this package still held it -- the medium was removed without a detach, or a run was cut short. Nothing can be exported now. If that disk was pulled while a transfer was running, check it before trusting the copy on it."
            rm -f "$OURS" 2>/dev/null || :
            emit gone_while_held; exit 0
        fi
        say "'$POOL' is not imported -- nothing to export."
        emit already_gone; exit 0
    fi

    # OWNERSHIP IS A MATCH, NOT THE PRESENCE OF A FILE.
    #
    # REV-20260829-124 follow-up. This asked only whether the marker EXISTED,
    # and `detach` runs outside the generated bracket's `if` -- on purpose, so a
    # failed transfer still puts the pool back. Put together, `attach` could
    # refuse a wrong same-named medium with exit 2 and this could export that
    # very medium two statements later, deleting the marker that recorded what
    # we actually still owe an export on. The refusal was undone by the line
    # that follows it.
    #
    # So the same three-way answer `attach` uses: ours and this pool, nobody's,
    # or a marker that cannot be matched to what is in the slot. Only the first
    # exports.
    marker_is_ours; _own=$?
    case "$_own" in
        1)  say "leaving '$POOL' imported: this run did not import it, so putting it away is not this run's call."
            emit left_alone; exit 0 ;;
        2)  say "REFUSING to export '$POOL': this package holds an ownership marker that does not match the pool currently imported under that name (marker guid: $(sed -n 's/^guid=//p' "$OURS" 2>/dev/null | head -1 | sed 's/^$/none/'); pool guid: $(pool_guid | sed 's/^$/unreadable/')). Exporting would hit a disk this run never imported, and clearing the marker would discard the record that an export is still owed elsewhere. A human is needed."
            emit export_refused_ambiguous; exit 2 ;;
    esac
    # THE ONE FAILURE THAT MUST BE LOUD. An un-exported pool on a disk somebody
    # is about to unplug is how a replica gets corrupted, and this is the last
    # moment anything can say so.
    if zpool export "$POOL" 2>/dev/null; then
        rm -f "$OURS" 2>/dev/null || :
        say "exported '$POOL' -- the disk can be unplugged."
        emit exported; exit 0
    fi
    say "WARNING: could not export '$POOL'. DO NOT UNPLUG THE DISK. Something still holds the pool -- a mounted dataset, an open file, a running send. Find it (zpool export shows the reason above), then export by hand."
    emit export_failed; exit 2
    ;;
esac
