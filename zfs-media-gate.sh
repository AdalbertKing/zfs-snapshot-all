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
Usage: zfs-media-gate.sh <attach|detach|status> <pool> <label> [--dataset D] [--dir DIR]...
                         [--source DS --prefix P] [--stats FILE] [--quiet]

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
VERB=""; POOL=""; LABEL=""; DATASET=""; STATS=""; QUIET=0; _own=0; _erc=0; _fm=""
_skip=no; _rec_guid=""; _rec_snap=""; _now_guid=""; _new_snap=""
SOURCE=""; PREFIX=""; ENGINE_RC=""
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
        --source)     SOURCE="${2:-}"; shift 2 ;;
        --source=*)   SOURCE="${1#--source=}"; shift ;;
        --engine-rc)   ENGINE_RC="${2:-}"; shift 2 ;;
        --engine-rc=*) ENGINE_RC="${1#--engine-rc=}"; shift ;;
        --prefix)     PREFIX="${2:-}"; shift 2 ;;
        --prefix=*)   PREFIX="${1#--prefix=}"; shift ;;
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

# HOW LONG AN EXPORT MAY TAKE BEFORE IT IS CALLED STUCK.
#
# Measured on the lab, 2026-08-29: with the ZFS default failmode=wait, pulling a
# medium mid-run left `zpool export` in uninterruptible sleep for ELEVEN MINUTES
# and still going -- unkillable, and re-inserting the disk did not free it,
# because the kernel gave the returning disk a NEW device node while ZFS was
# still waiting on the old one.
#
# That matters far beyond one command. `detach` runs OUTSIDE the generated
# bracket's `if`, so a cron job that meets this hangs FOREVER: it holds its
# flock, every later run of the same job is refused as contended, and nothing
# alerts, because a job that never exits never reports a status. Silent,
# permanent death of a backup job -- the exact shape this package keeps hunting.
#
# So the export is bounded. A timeout is not a fix for the underlying I/O -- it
# cannot be -- but it converts an unkillable silence into a loud, non-zero
# answer that names the disk and tells the operator not to unplug it.
MEDIA_EXPORT_TIMEOUT="${MEDIA_EXPORT_TIMEOUT:-90}"
bounded_export() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$MEDIA_EXPORT_TIMEOUT" zpool export "$POOL" 2>/dev/null
        return $?
    fi
    zpool export "$POOL" 2>/dev/null
}
pool_guid() { zpool get -H -o value guid "$POOL" 2>/dev/null; }

# The GUID of the medium in the slot, WITHOUT importing it. `zpool import`'s scan
# prints `id: <guid>` for every importable pool, which is what makes a per-medium
# decision possible before the import window is opened at all.
scan_guid() {
    zpool import ${IMPORT_DIRS[@]+"${IMPORT_DIRS[@]}"} 2>/dev/null | awk -v p="$POOL" '
        $1=="pool:" { inpool = ($2==p) }
        inpool && $1=="id:" { print $2; exit }'
}

# The newest snapshot of the replica family on the source root. This is what a
# successful run has just put on the medium, and what a later run compares
# against to decide whether that medium is still current.
newest_source_snap() {
    [ -n "$SOURCE" ] && [ -n "$PREFIX" ] || return 1
    zfs list -H -t snapshot -o name -d 1 "$SOURCE" 2>/dev/null \
        | grep "@${PREFIX}" | tail -1 | sed 's/.*@//'
}

SYNCED="$STATE_DIR/$LABEL.synced"

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
    # THE ONE SENTENCE AN OPERATOR STANDING AT THE MACHINE NEEDS.
    #
    # Measured on the lab, 2026-08-29: pulling this disk while the pool is
    # imported is not a recoverable inconvenience. It hung `zpool export` in
    # unkillable sleep, and pulling during a write took the whole host down --
    # and so did the documented recovery (rescan the bus), twice. Upstream
    # OpenZFS has open issues for exactly this; the standing advice everywhere
    # is the same one: export before you unplug.
    #
    # Since no software here can make a surprise removal safe, the useful thing
    # is to make the WINDOW visible. The bracket already keeps it to the length
    # of one run; this says, in words, which side of it you are on.
    if imported; then
        check_dataset || exit $?
        say "medium '$POOL' for '$LABEL' is present -- DO NOT UNPLUG: the pool is imported and pulling it now can hang this host until it is reset."
        emit present; exit 0
    fi
    last="never"; [ -r "$SEEN" ] && last="$(cat "$SEEN" 2>/dev/null)"
    say "medium '$POOL' for '$LABEL' is away (last seen: $last) -- SAFE TO UNPLUG: the pool is not imported."
    emit absent; exit 1
    ;;

attach)
    # NOTHING TO SEND MEANS NOTHING TO RISK.
    #
    # The window in which pulling this disk can hang the host is exactly the
    # window in which its pool is imported. The bracket already keeps that to the
    # length of one run -- but it opened it on EVERY run, including the ones with
    # nothing to copy. On a source that is quiet most of the day that is the disk
    # exposed once an hour for no reason at all.
    #
    # So the question "is there anything to do" is answered on the SOURCE, before
    # the medium is touched. `written@<snap>` is the predicate: bytes written to
    # a dataset since that snapshot. Zero across the whole subtree means the last
    # replica snapshot still describes the source exactly, and the run would copy
    # nothing.
    #
    # `written@` LAGS BY A TRANSACTION GROUP, and that is accepted rather than
    # worked around. Data written seconds ago may still read as zero until the
    # txg commits (zfs_txg_timeout, 5s by default) -- measured again here while
    # proving this check, and already on record for this project. The worst it
    # can cost is ONE skipped run on an hourly schedule; the data is not lost and
    # the next run carries it. Forcing a sync to get a fresher number would mean
    # this check writing to the pool it exists to leave alone.
    #
    # Fail OPEN, deliberately. Anything unexpected -- no prior snapshot of this
    # family (a first seed), an unreadable property, a source that is not there --
    # imports and lets the engine decide. A check that skips a real backup
    # because it could not read a number would be far worse than one that
    # occasionally imports for nothing.
    #
    # REV-20260829-126 F1. The first cut of this asked only whether the SOURCE
    # was quiet, and skipped on that alone. That is not a fact about the disk in
    # the slot, and rotation is exactly where the difference bites:
    #
    #   medium A is synced through replica_s1 and carried off;
    #   medium B is inserted and takes the source to replica_s2;
    #   the source then goes quiet, so written@replica_s2 is zero;
    #   medium A comes back -- and was skipped, for ever, while still at s1.
    #
    # The log said there was nothing to copy, and the off-site copy silently
    # stopped advancing. On an archival dataset that is permanent.
    #
    # So the fast path now needs a fact about the MEDIUM, and it must be one that
    # can be had without importing it -- or the optimisation would cost the very
    # window it exists to avoid. Two things make that possible:
    #
    #   * `zpool import`'s scan prints each importable pool's GUID without
    #     importing anything, so the disk in the slot can be identified;
    #   * this run records, after a VERIFIED transfer, which source snapshot the
    #     medium of that GUID then held.
    #
    # Skipping therefore requires all three: the recorded GUID is the disk in the
    # slot, the snapshot it recorded is still the newest of the family, and
    # nothing has been written since. Anything else -- no record, unreadable,
    # a different disk, an older snapshot -- imports and lets the engine decide.
    if [ -n "$SOURCE" ] && [ -n "$PREFIX" ]; then
        _work=unknown
        if zfs list -H -o name "$SOURCE" >/dev/null 2>&1; then
            _work=no
            while IFS= read -r _ds; do
                [ -n "$_ds" ] || continue
                _snap="$(zfs list -H -t snapshot -o name -d 1 "$_ds" 2>/dev/null | grep "@${PREFIX}" | tail -1)"
                if [ -z "$_snap" ]; then _work=unknown; break; fi
                _w="$(zfs get -H -p -o value "written@${_snap##*@}" "$_ds" 2>/dev/null)"
                case "$_w" in
                    ''|*[!0-9]*) _work=unknown; break ;;
                    0) : ;;
                    *) _work=yes; break ;;
                esac
            done <<EOF
$(zfs list -H -o name -r "$SOURCE" 2>/dev/null)
EOF
        fi
        # A quiet source is necessary and NOT sufficient. Everything below is
        # about the medium, and every branch of it fails OPEN.
        if [ "$_work" = no ]; then
            _skip=no
            if [ ! -r "$SYNCED" ]; then
                say "'$SOURCE' is quiet, but there is no record of what '$POOL' last received, so this run cannot tell a current medium from a rotated stale one. Importing to let the engine decide."
            else
                _rec_guid="$(sed -n 's/^guid=//p' "$SYNCED" 2>/dev/null | head -1)"
                _rec_snap="$(sed -n 's/^snap=//p' "$SYNCED" 2>/dev/null | head -1)"
                _now_guid="$(scan_guid)"
                _new_snap="$(newest_source_snap)"
                if [ -z "$_rec_guid" ] || [ -z "$_rec_snap" ]; then
                    say "the record of what '$POOL' last received is unreadable, so it proves nothing. Importing to let the engine decide."
                elif [ -z "$_now_guid" ]; then
                    say "'$SOURCE' is quiet, but the medium for '$POOL' could not be identified without importing it. Importing rather than assuming it is the same disk."
                elif [ "$_rec_guid" != "$_now_guid" ]; then
                    say "'$SOURCE' is quiet, but the disk in the slot (guid $_now_guid) is NOT the one this record describes (guid $_rec_guid) -- a rotated medium that may be behind. Importing to let the engine decide."
                elif [ -z "$_new_snap" ] || [ "$_rec_snap" != "$_new_snap" ]; then
                    say "'$SOURCE' is quiet, but this medium last received '${_rec_snap}' and the family is now at '${_new_snap:-unknown}' -- it is behind. Importing to bring it up."
                else
                    _skip=yes
                fi
            fi
            if [ "$_skip" = yes ]; then
                say "SKIPPED: this medium (guid $_now_guid) already holds '$_rec_snap', which is still the newest '$PREFIX' snapshot, and nothing has been written to '$SOURCE' since. Nothing to copy, so the disk is left alone -- every minute this pool is NOT imported is a minute it can be pulled safely."
                emit skipped_nothing_to_do; exit 1
            fi
        fi
    fi

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
        bounded_export || say "and '$POOL' could NOT be exported again -- it is imported and unusable; look at it before pulling the disk."
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
        if bounded_export; then
            say "'$POOL' was exported again -- the machine is as it was before this run, and nothing was transferred."
            emit import_unrecorded
        else
            say "WARNING: could not export '$POOL' either. DO NOT UNPLUG THE DISK. The pool is imported, unrecorded, and this run cannot put it back -- export it by hand."
            emit import_unrecorded_stuck
        fi
        exit 2
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$SEEN" 2>/dev/null || :

    # failmode ON A DISK THAT LEAVES THE BUILDING.
    #
    # ZFS defaults to failmode=wait, which is right for a disk that is not going
    # anywhere and wrong for one whose whole purpose is to be unplugged. Measured
    # on the lab, 2026-08-29, on this exact shape:
    #
    #   * pulled between runs, pool exported      no harm
    #   * pulled with the pool imported, idle     `zpool export` hung in
    #                                             uninterruptible sleep, 11+ min,
    #                                             unkillable
    #   * pulled DURING a 300 MB write            the whole HOST went unreachable
    #                                             and needed a hard reset
    #
    # The third is not ZFS being fragile, it is arithmetic: zfs_txg_timeout is 5s
    # and zfs_dirty_data_max was 393 MB on that host, so the entire payload was
    # sitting in RAM with nowhere to go when the vdev vanished.
    #
    # WARNED, NOT CHANGED. failmode is a property of the administrator's pool and
    # silently rewriting it would be this tool deciding how someone else's data
    # behaves under failure. The command is right there.
    _fm="$(zpool get -H -o value failmode "$POOL" 2>/dev/null)"
    if [ "$_fm" = wait ]; then
        say "note: '$POOL' has failmode=wait, the ZFS default. On a disk that gets unplugged that turns a pull-while-imported into an unkillable hang rather than an error -- measured on the lab. Consider: zpool set failmode=continue $POOL"
    fi

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
    # Captured from the call itself. Reading $? after the `if` gives the status
    # of the COMPLETED if-statement -- zero when the branch was not taken -- so
    # the timeout could never be told apart from an ordinary refusal.
    # THE RECORD ADVANCES HERE, AND ONLY HERE.
    #
    # Written while the pool is still imported, because that is the only moment
    # its GUID can be read, and only when THIS run both owned the import and the
    # engine reported success. A run that skipped, failed, or was somebody else's
    # import leaves the record exactly as it was -- an unproved medium must never
    # be recorded as current.
    if [ "$ENGINE_RC" = 0 ] && [ -n "$SOURCE" ] && [ -n "$PREFIX" ]; then
        _now_guid="$(pool_guid)"
        _new_snap="$(newest_source_snap)"
        if [ -n "$_now_guid" ] && [ -n "$_new_snap" ]; then
            mkdir -p "$STATE_DIR" 2>/dev/null && \
                printf 'guid=%s\nsnap=%s\n' "$_now_guid" "$_new_snap" > "$SYNCED" 2>/dev/null || \
                say "note: could not record what '$POOL' now holds ($SYNCED) -- the next run will import it rather than trusting a record it does not have."
        fi
    fi

    bounded_export; _erc=$?
    if [ "$_erc" -eq 0 ]; then
        rm -f "$OURS" 2>/dev/null || :
        say "exported '$POOL' -- the disk can be unplugged."
        emit exported; exit 0
    fi
    if [ "$_erc" -eq 124 ]; then
        say "WARNING: exporting '$POOL' did not finish within ${MEDIA_EXPORT_TIMEOUT}s and was abandoned. DO NOT UNPLUG THE DISK. This is what a medium pulled DURING a run looks like: ZFS is waiting for a device that is not coming back, and with failmode=wait that wait has no end. The pool is still imported. Reconnect the disk if it was removed, then export by hand; if the export itself is stuck in uninterruptible sleep, only a reboot clears it."
        emit export_timeout; exit 2
    fi
    say "WARNING: could not export '$POOL'. DO NOT UNPLUG THE DISK. Something still holds the pool -- a mounted dataset, an open file, a running send. Find it (zpool export shows the reason above), then export by hand."
    emit export_failed; exit 2
    ;;
esac
