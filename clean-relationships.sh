#!/bin/bash
set -uo pipefail
# clean-relationships.sh (run with -V for version)
# ------------------------------------------------------------------------------
# Description: answers "what relationship traces are on THIS host, and which of
# them are dead?" -- and, when told to, removes the dead ones.
#
# Why this exists. The package already has two removal verbs and both do their
# own job correctly:
#
#     zfs-backup.sh remove-client NAME     the collector's half
#     deploy.sh --leave=LABEL              the source's half
#
# What was missing is the question they cannot answer. Tearing three
# relationships off three hosts on 2026-08-20 and inventorying before and after
# every single call produced the taxonomy below -- and, more usefully, two
# mistakes that are easy to repeat and were repeated:
#
#   * the --leave list was derived from the chain topology someone had BUILT,
#     which missed a live account left over from an older lab where the host
#     had been a source. The question is "what is on this host", never "what do
#     I remember putting here";
#   * peers/<label>.conf was hand-deleted BEFORE deploy.sh --leave ran. That
#     manifest is the map --leave reads to know what to revoke, so it refused
#     -- correctly, it does not guess -- and the account was stranded beyond
#     the reach of the tool that exists to remove it.
#
# THE CORE DIFFICULTY, and the reason a cleanup keyed on one name misses
# things: one relationship has up to THREE identities on disk.
#
#     side       key       artefacts
#     ---------  --------  --------------------------------------------------
#     collector  NAME      clients/<name>.conf, the cron lines' -L argument
#     collector  ADDRESS   peers/<addr>.conf, the four pairing key files,
#                          pairing/<addr>.conf.suggested, <host>-to-<addr>.tgz
#     source     LABEL     peers/<label>.conf, relationships/<label>/,
#                          the account zfsbackup-<label>
#
# `remove-client` is keyed on NAME and ADDRESS and removes peers/<addr>.conf --
# while peers/<LABEL>.conf, keyed the other way, survives it. That asymmetry is
# invisible unless you list the directory before and after, which is exactly
# how it was found.
#
# WHAT THIS TOOL WILL NOT DO
#   * it does not sweep by pattern. Every removal is an exact path derived from
#     a discovered identity. `hdd/kopie` once looked like a test dataset and was
#     a real copy target; a `grep -i test` cleanup would have taken it;
#   * it does not touch anything it classifies as LIVE, and when it cannot
#     classify something it says UNKNOWN and leaves it;
#   * it does not remove known_hosts entries. remove-client's stance is right
#     and is kept: that file is our record of who they are, not a permission
#     for them. The ssh-keygen line is printed, never run;
#   * it does not remove the shared gate binary, the alert tree, the delegated
#     BACKUP account, or anything belonging to the host's own jobs.
#
# Usage:
#   clean-relationships.sh                      audit, read-only (default)
#   clean-relationships.sh --purge=NAME|LABEL|ADDR --yes
#   clean-relationships.sh --purge-orphans --yes
#   clean-relationships.sh --release-hold=SNAPSHOT --yes
#
# Exit: 0 audit clean or purge done, 1 error, 2 usage, 3 orphans found (audit)
# ------------------------------------------------------------------------------
VERSION="v1.0"

CLIENTS_DIR="${CLIENTS_DIR:-/etc/zfs-snapshot-all/clients}"
PEER_STATE_DIR="${PEER_STATE_DIR:-/etc/zfs-snapshot-all/peers}"
REL_STATE_DIR="${REL_STATE_DIR:-/var/lib/zfs-snapshot-all/relationships}"
PEER_KEY_DIR="${PEER_KEY_DIR:-/root/.ssh/pairing}"
# Where a purge records what it is about to make unfindable. NOT under
# relationships/ -- that subtree has its own ownership model and Phase 4's group
# sweep is pruned around it; a plain record has no business living there.
TOMBSTONE_DIR="${TOMBSTONE_DIR:-/var/lib/zfs-snapshot-all/removed}"
# Named rather than found on PATH, so "is zfs here?" is a question a test can
# answer either way on any machine. Deciding it by emptying PATH would make the
# result depend on the runner -- the exact flake test/pairgate already
# documents, where a suite passed only on hosts that happened to lack `logger`.
ZFS_BIN="${ZFS_BIN:-zfs}"
# DUPLICATED from lib-zfs-snap.sh, which this script does not source -- the same
# duplication delsnaps.sh already carries, and covered by the same `hold-tag`
# contract in test/deps.conf. It is the tag OUR transfers place; pvesr and vzdump
# place holds of their own and those are none of this tool's business.
HOLD_TAG="${HOLD_TAG:-zfssnapall_inflight}"
PAIRING_DIR="${PAIRING_DIR:-/root/scripts/pairing}"
HOME_ROOT="${HOME_ROOT:-/home}"
DEPLOY="${DEPLOY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.sh}"
ZFSBACKUP="${ZFSBACKUP:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zfs-backup.sh}"

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "clean-relationships.sh: error: $*" >&2; exit 1; }

usage() {
    sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

PURGE_TARGET=""
PURGE_ORPHANS=0
ASSUME_YES=0
RELEASE_HOLD=""
for a in "$@"; do
    case "$a" in
        -V|--version)   echo "$VERSION"; exit 0 ;;
        -h|--help)      usage 0 ;;
        --purge=*)      PURGE_TARGET="${a#*=}" ;;
        --purge-orphans) PURGE_ORPHANS=1 ;;
        --release-hold=*) RELEASE_HOLD="${a#*=}" ;;
        --yes|-y)       ASSUME_YES=1 ;;
        *) echo "unknown option: $a" >&2; usage 2 ;;
    esac
done
[ -n "$PURGE_TARGET" ] && [ "$PURGE_ORPHANS" -eq 1 ] && \
    die "--purge= and --purge-orphans are different questions -- pick one"

PURGING=0
{ [ -n "$PURGE_TARGET" ] || [ "$PURGE_ORPHANS" -eq 1 ]; } && PURGING=1

# Root is required because the DEFAULT paths are system paths -- that is the
# entire reason for the check, so it is written that way rather than as a bare
# `id -u`. When every operative directory has been pointed somewhere else, this
# run cannot reach /etc, /var/lib, /root or any account, and demanding root
# would only mean the removal path could never be exercised by a test. Not a
# backdoor: overriding these is not something a real host does by accident, and
# a run that has done so is provably sandboxed.
ON_REAL_HOST=0
for _d in "$CLIENTS_DIR:/etc/zfs-snapshot-all/clients" \
          "$PEER_STATE_DIR:/etc/zfs-snapshot-all/peers" \
          "$REL_STATE_DIR:/var/lib/zfs-snapshot-all/relationships" \
          "$PEER_KEY_DIR:/root/.ssh/pairing" \
          "$TOMBSTONE_DIR:/var/lib/zfs-snapshot-all/removed" \
          "$HOME_ROOT:/home"; do
    [ "${_d%%:*}" = "${_d#*:}" ] && ON_REAL_HOST=1
done
if [ "$PURGING" -eq 1 ] && [ "$ON_REAL_HOST" -eq 1 ] && [ "$(id -u)" != 0 ]; then
    die "purging touches /etc, /var/lib, /root and accounts -- run as root"
fi

# peer_label -- the same transform deploy.sh and zfs-backup.sh apply, mirrored
# rather than sourced: this script must run on a host whose package state is
# inconsistent, which is exactly when sourcing 6000 lines is a bad idea.
peer_label() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

# ------------------------------------------------------------------------------
# DISCOVERY -- one pass per artefact family, keyed by whichever identity that
# family actually uses on disk. Nothing is inferred from a list; every entry
# below exists because a file or an account exists.
# ------------------------------------------------------------------------------
declare -A SEEN_NAME=()     # collector-side relationship names
declare -A SEEN_ADDR=()     # collector-side peer addresses
declare -A SEEN_LABEL=()    # source-side peer labels
declare -A NAME_STATE=()    # name -> last STATE= in its client record
declare -A NAME_ADDR=()     # name -> the address it points at
declare -A CRON_LABELS=()   # labels/names any crontab still references

discover() {
    local f b n

    # Collector: client records. The STATE log is append-only, so the LAST
    # STATE line is the current one -- reading the first would call every
    # removed relationship "pending_enroll".
    for f in "$CLIENTS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .conf)
        SEEN_NAME["$b"]=1
        NAME_STATE["$b"]=$(grep -E '^STATE=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)
        n=$(grep -E '^PEER_HOST=' "$f" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "'\"")
        [ -n "$n" ] && { NAME_ADDR["$b"]="$n"; SEEN_ADDR["$n"]=1; }
    done

    # peers/ holds BOTH keyings in one directory: <addr>.conf written by the
    # collector, <label>.conf written by the source. They are told apart by
    # content, not by the name -- a label that happens to look like a hostname
    # and an address are not distinguishable by shape.
    for f in "$PEER_STATE_DIR"/*.conf; do
        [ -e "$f" ] || continue
        b=$(basename "$f" .conf)
        if grep -qE '^PEER_JOIN_ACCOUNT=' "$f" 2>/dev/null; then
            SEEN_LABEL["$b"]=1          # source side: this peer joined us
        else
            SEEN_ADDR["$b"]=1           # collector side: we paired with them
        fi
    done

    # Source: gate state and the delegated per-peer account. Both are keyed by
    # label, and either can exist without the other -- which is the whole
    # point of looking at both.
    # ...and from the SCOPE files on their own. Discovery above keys on
    # peers/<id>.conf, so once that file is gone the .scope/.scope.sha256/
    # .scope.request beside it become undiscoverable -- not merely unlisted.
    # Measured on pve9, 2026-09-03: a full --leave left pve10.scope.request
    # behind and this audit answered "nothing orphaned", which is the one
    # answer it exists to get right. A leftover whose .conf is gone is the
    # MOST orphaned a trace can be, so it has to seed an id of its own.
    for f in "$PEER_STATE_DIR"/*.scope "$PEER_STATE_DIR"/*.scope.sha256 "$PEER_STATE_DIR"/*.scope.request; do
        [ -e "$f" ] || continue
        b=$(basename "$f"); b="${b%.request}"; b="${b%.sha256}"; b="${b%.scope}"
        SEEN_LABEL["$b"]=1
    done

    for f in "$REL_STATE_DIR"/*/; do
        [ -d "$f" ] || continue
        SEEN_LABEL["$(basename "$f")"]=1
    done
    for f in "$HOME_ROOT"/zfsbackup-*; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        # The bare delegated BACKUP account is `zfsbackup` with no suffix and is
        # NOT a relationship -- it runs this host's own jobs. The glob cannot
        # match it, and this guard says so out loud anyway, because removing it
        # would take the host's backups with it.
        [ "$b" = "zfsbackup" ] && continue
        SEEN_LABEL["${b#zfsbackup-}"]=1
    done

    # Collector: pairing keys, keyed by address. Four files per peer.
    #
    # Until 2026-09-03 only three of them were removed on teardown --
    # _alias_known_hosts survived, and it is the one the generated cron lines
    # actually pass to -k. This comment recorded that as a standing fact for
    # months; deploy.sh --unpair now removes it, so a fresh teardown leaves
    # none of the four. The scan stays: it is what finds the ones already made,
    # and a key file is a trace whoever wrote it.
    for f in "$PEER_KEY_DIR"/*_ed25519 "$PEER_KEY_DIR"/*_alias_known_hosts; do
        [ -e "$f" ] || continue
        b=$(basename "$f"); b="${b%_ed25519}"; b="${b%_alias_known_hosts}"
        SEEN_ADDR["$b"]=1
    done

    # THE DELEGATED ACCOUNT KEEPS ITS OWN COPIES, somewhere else and named
    # differently: /home/<acct>/.ssh/pairing-<addr>_* -- a PREFIX, where root
    # uses a directory. This file scanned only root's until 2026-08-20, which
    # made it blind in exactly the shape that matters most: a relationship
    # installed with --local-user runs from the account's crontab and uses the
    # account's keys, so on a production host the tool was reporting the half
    # nobody uses. Measured on pve1 the moment a delegated relationship was
    # built: five key files there, one of them
    # `pairing-192.168.28.190_alias_known_hosts` -- an address named by no
    # config and no cron line on that host, which is precisely what this tool
    # exists to surface and could not see.
    for f in "$HOME_ROOT"/*/.ssh/pairing-*; do
        [ -e "$f" ] || continue
        b=$(basename "$f"); b="${b#pairing-}"
        b="${b%_ed25519}"; b="${b%.pub}"; b="${b%_alias_known_hosts}"; b="${b%_known_hosts}"
        [ -n "$b" ] && SEEN_ADDR["$b"]=1
    done

    # Anything a crontab still calls by label is LIVE by definition, whatever
    # the files say. This is the authority the classification below leans on.
    local u tab
    for u in root $(ls -1 "$HOME_ROOT" 2>/dev/null); do
        id "$u" >/dev/null 2>&1 || continue
        tab=$(crontab -l -u "$u" 2>/dev/null) || continue
        while read -r n; do
            [ -n "$n" ] && CRON_LABELS["$n"]=1
        done < <(printf '%s\n' "$tab" | grep -oE '\-L [A-Za-z0-9._-]+' | awk '{print $2}' | sort -u)
    done
}

# classify <identity> -> LIVE | ORPHAN | UNKNOWN, reason on stdout after a tab
#
# LIVE wins on any evidence at all. The asymmetry is deliberate: calling a live
# relationship dead deletes a working backup's credentials, calling a dead one
# live leaves a directory lying about. Those are not comparable mistakes.
classify() {
    local id="$1" state=""
    [ -n "${CRON_LABELS[$id]+x}" ] && { printf 'LIVE\ta crontab still runs jobs labelled -L %s\n' "$id"; return; }
    if [ -n "${SEEN_NAME[$id]+x}" ]; then
        state="${NAME_STATE[$id]:-}"
        case "$state" in
            removed|"") ;;   # terminal, or a record with no state at all
            *) printf 'LIVE\tclient record says STATE=%s\n' "$state"; return ;;
        esac
    fi
    # Source side: an account that still exists AND a manifest naming it is a
    # relationship the peer can still use, whatever this host remembers.
    if [ -n "${SEEN_LABEL[$id]+x}" ] && id "zfsbackup-$id" >/dev/null 2>&1 \
       && [ -s "$PEER_STATE_DIR/$id.conf" ]; then
        printf 'LIVE\taccount zfsbackup-%s exists and its join manifest is present\n' "$id"; return
    fi
    printf 'ORPHAN\tno cron line, no live client record, no usable join manifest\n'
}

# artefacts_for <identity> -- every path this identity owns that EXISTS, one
# per line, prefixed by a family tag. Existence is checked here so the report
# and the purge cannot drift apart: they both read this list.
#
# DEDUPLICATED, and not for tidiness. The DEFAULT relationship name IS the
# peer's address, so on a collector that took the default the identity and the
# address are the same string and several families resolve to one file --
# measured on pve2, where peers/192.168.28.99.conf was reported twice under two
# different family names. A duplicate in a list an operator is about to approve
# is a list they cannot check.
artefacts_for() { _artefacts_raw "$@" | awk -F'\t' '!seen[$2]++'; }

_artefacts_raw() {
    # An identity that IS an address -- an orphan key file with no client
    # record left to name it -- resolves to itself. Without this the
    # address-keyed families below were unreachable for exactly the entries
    # that have lost everything else.
    local id="$1" addr="${NAME_ADDR[$id]:-}" f d
    [ -n "$addr" ] || { [ -n "${SEEN_ADDR[$id]+x}" ] && addr="$id"; }
    [ -e "$CLIENTS_DIR/$id.conf" ]       && echo "client	$CLIENTS_DIR/$id.conf"
    # The DATA this relationship owns, reported and never removed. Reading it
    # costs no `zfs` call -- the client record and the join manifest both name
    # it in plain text -- and the reason to report it is that the record is
    # about to be deleted. Measured 2026-08-20: hdd/lab4direct outlived its
    # relationship, and once clients/lab4-direct.conf was gone nothing on the
    # host linked that dataset to anything at all. Removing data is a separate
    # decision with a separate blast radius, so this tool names it and stops.
    #
    # THE SEPARATOR IS AN ESCAPED SPACE, and reading it as whitespace corrupts
    # the name. These records are `%q`-quoted because they are sourced as root
    # elsewhere, so a list of two datasets is stored as
    #
    #     MANAGED_DATASETS=hdd/a/tree\ hdd/a/flat
    #
    # ...ON THE COLLECTOR. The SOURCE half does not use %q. Measured on pve1,
    # 2026-08-30, on a live lab relationship:
    #
    #     PEER_JOIN_GRANTED_DATASETS="hdd/labsrc hdd/labsrc/vm-900-disk-0 ..."
    #
    # -- double-quoted, separated by BARE spaces. Neither separator this code
    # knew, so all three names stayed glued into one string, `zfs list` was
    # asked for a dataset of that name, and the audit answered ALREADY GONE for
    # three datasets that were all present. That is the failure direction that
    # matters: an operator clearing a host is told the data is already gone and
    # leaves live data behind, and the purge reads the same field.
    #
    # A bare space is therefore ALSO always a separator, for the reason already
    # stated below: no legal ZFS name can contain one.
    #
    # The first version split on whitespace and reported `hdd/a/tree\` -- with a
    # trailing backslash, which is not a legal ZFS name and cannot be pasted into
    # the `zfs destroy` this line exists to hand the operator. Found on pve1,
    # 2026-08-26.
    #
    # Decoded WITHOUT eval or source: this file is data and stays data. That is
    # safe here for a reason worth stating rather than assuming -- a ZFS dataset
    # name may contain only [A-Za-z0-9_.:/-] (measured: `zfs create hdd/x,y` is
    # refused, "invalid character ','"), so neither a space nor a comma can occur
    # INSIDE a name, and `\ ` in this field can only ever be the separator.
    # Any OTHER backslash means the value is not what this code thinks it is, so
    # it is reported as suspect instead of being quietly half-decoded.
    local d exists
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$d" in
            *\\*) printf 'data\t%s   (SUSPECT: this name still contains a backslash after decoding -- do not paste it into a destroy)\n' "$d"
                  continue ;;
        esac
        # F2: SAY whether it is still there. The audit used to print these
        # straight from the record without asking ZFS ("costs no zfs call"),
        # while the purge checked and said "ALREADY GONE". So the destructive
        # verb verified and the read-only one did not -- and combined with the
        # mangling above, an operator could not tell "this is gone" from "this
        # name is corrupted" from "this dataset is still here".
        # The VALUE only. Whether it still exists is printed by the reporter --
        # this field is also read by the PURGE, which feeds it to `zfs list`, so
        # a label appended here becomes part of a dataset name downstream. The
        # first cut did exactly that and made the purge report an existing
        # dataset as ALREADY GONE.
        printf 'data	%s
' "$d"
    done < <(grep -hE '^(RUX_TARGET|MANAGED_DATASETS|PEER_JOIN_GRANTED_DATASETS)=' \
                 "$CLIENTS_DIR/$id.conf" "$PEER_STATE_DIR/$id.conf" 2>/dev/null \
             | cut -d= -f2- | tr -d "'\"" | sed 's/\\ /\n/g' | tr ', \t' '\n\n\n')
    [ -e "$PEER_STATE_DIR/$id.conf" ]    && echo "manifest	$PEER_STATE_DIR/$id.conf"
    [ -e "$PEER_STATE_DIR/$id.scope" ]   && echo "scope	$PEER_STATE_DIR/$id.scope"
    [ -e "$PEER_STATE_DIR/$id.scope.sha256" ] && echo "scope	$PEER_STATE_DIR/$id.scope.sha256"
    [ -e "$PEER_STATE_DIR/$id.scope.request" ] && echo "scope	$PEER_STATE_DIR/$id.scope.request"
    [ -d "$REL_STATE_DIR/$id" ]          && echo "gate	$REL_STATE_DIR/$id"
    id "zfsbackup-$id" >/dev/null 2>&1   && echo "account	zfsbackup-$id"
    # The home directory is listed SEPARATELY from the account on purpose. UID
    # reuse means a directory named after a dead account can be owned by a live
    # one -- measured on pve2, where two such directories belonged to the
    # running zfsbackup-pve1. `id` is the only honest test of an account's
    # existence; the directory's owner proves nothing.
    [ -d "$HOME_ROOT/zfsbackup-$id" ] && ! id "zfsbackup-$id" >/dev/null 2>&1 \
        && echo "homedir	$HOME_ROOT/zfsbackup-$id"
    # Address-keyed families, reachable only through the client record.
    if [ -n "$addr" ]; then
        [ -e "$PEER_STATE_DIR/$addr.conf" ] && echo "pairing	$PEER_STATE_DIR/$addr.conf"
        for f in "$PEER_KEY_DIR/${addr}_ed25519" "$PEER_KEY_DIR/${addr}_ed25519.pub" \
                 "$PEER_KEY_DIR/${addr}_known_hosts" "$PEER_KEY_DIR/${addr}_alias_known_hosts"; do
            [ -e "$f" ] && echo "key	$f"
        done
        [ -e "$PAIRING_DIR/$addr.conf.suggested" ] && echo "scaffold	$PAIRING_DIR/$addr.conf.suggested"
        for f in "$PAIRING_DIR"/*-to-"$addr".tgz; do
            [ -e "$f" ] && echo "scaffold	$f"
        done
        # The delegated account's own copies, prefix-named rather than in a
        # directory. Globbed across every account because the relationship that
        # created them may be gone -- which is when finding them matters.
        for f in "$HOME_ROOT"/*/.ssh/pairing-"$addr"_*; do
            [ -e "$f" ] && echo "key	$f"
        done
    fi
}

# ------------------------------------------------------------------------------
# REPORT
# ------------------------------------------------------------------------------
ORPHANS=()
report() {
    local ids id verdict reason art n=0
    # Addresses are included, and were not until 2026-08-20 -- SEEN_ADDR was
    # collected and never reported, so a key file whose client record had
    # already been deleted was invisible to the tool written to find exactly
    # that. Only addresses no NAME already accounts for, otherwise every live
    # relationship would appear twice under its own two identities.
    local claimed=" "
    for id in "${!NAME_ADDR[@]}"; do claimed="$claimed${NAME_ADDR[$id]} "; done
    local orphan_addrs=""
    for id in "${!SEEN_ADDR[@]}"; do
        case "$claimed" in *" $id "*) continue ;; esac
        [ -n "${SEEN_NAME[$id]+x}" ] && continue
        [ -n "${SEEN_LABEL[$id]+x}" ] && continue
        orphan_addrs="$orphan_addrs$id"$'\n'
    done
    ids=$(printf '%s\n' "${!SEEN_NAME[@]}" "${!SEEN_LABEL[@]}" $orphan_addrs | grep -v '^$' | sort -u)
    # "no RELATIONSHIP traces", and the qualifier is the fix. This sentence used
    # to read as "nothing is here", and on pve9 (2026-08-30) it was printed on a
    # host carrying 35 archived records and three scheduled replica jobs against
    # a dataset the same run had just called orphaned. The sections below say
    # what this line does not cover, so a reader keeps reading.
    [ -n "$ids" ] || log "no relationship traces on this host (archived records and replica jobs are reported separately below)"
    [ -n "$ids" ] || return 0
    while read -r id; do
        [ -n "$id" ] || continue
        IFS=$'\t' read -r verdict reason <<< "$(classify "$id")"
        art=$(artefacts_for "$id")
        echo
        echo "  $id  [$verdict]"
        echo "      $reason"
        if [ -n "$art" ]; then
            printf '%s\n' "$art" | while IFS=$'\t' read -r fam path; do
                # F2: SAY whether the data is still there. The audit printed
                # these straight from the record without asking ZFS, while the
                # purge checked -- the destructive verb verified and the
                # read-only one did not.
                #
                # THREE states, not two (reviewer, 2026-08-26). A missing `zfs`
                # must never read as "it is there": an unlabelled line looks
                # like a healthy one, and this report is what an operator acts
                # on. rc 1 from `zfs list` is the dataset's absence, which it
                # states in those words; any OTHER failure is the question not
                # having been answered, and says so.
                if [ "$fam" = data ]; then
                    case "$path" in
                        *SUSPECT*) : ;;   # already carries its own warning
                        *)
                            if ! command -v "$ZFS_BIN" >/dev/null 2>&1; then
                                path="$path   (UNVERIFIABLE -- no $ZFS_BIN on this host)"
                            else
                                "$ZFS_BIN" list -H -o name -- "$path" >/dev/null 2>&1
                                case $? in
                                    0) path="$path   (PRESENT)" ;;
                                    1) path="$path   (ALREADY GONE)" ;;
                                    *) path="$path   (UNVERIFIABLE -- $ZFS_BIN could not answer)" ;;
                                esac
                            fi ;;
                    esac
                fi
                printf '      %-9s %s\n' "$fam" "$path"
            done
        else
            echo "      (no files -- known only from a crontab reference)"
        fi
        [ "$verdict" = ORPHAN ] && { ORPHANS+=("$id"); n=$((n+1)); }
    done <<< "$ids"
    echo
    return 0
}

# report_archived_records -- the records add-client set aside when a name was
# reused, which this audit could not see.
#
# Measured on pve9, 2026-08-30: `clean-relationships.sh` ended with "no
# relationship traces on this host at all" while THIRTY-FIVE
# `<name>.conf.removed-<ts>` files sat in the clients directory, carrying peer
# addresses, delegated account names, dataset paths and key fingerprints from a
# week of labs.
#
# Archiving them is right and is not what this fixes -- a removed relationship's
# history is worth keeping, and the suffix deliberately does not match `*.conf`
# so no scanner mistakes one for a live record. What was wrong is the SENTENCE:
# a tool whose whole job is "what is on this host" said nothing is, while
# something was. They are reported and never removed: deleting a record is the
# operator's call, and this tool does not delete records it did not create.
report_archived_records() {
    local f n=0 oldest="" newest=""
    for f in "$CLIENTS_DIR"/*.conf.removed-*; do
        [ -e "$f" ] || continue
        n=$((n+1))
        [ -z "$oldest" ] && oldest="$(basename "$f")"
        newest="$(basename "$f")"
    done
    [ "$n" -gt 0 ] || return 0
    echo
    echo "  ARCHIVED RECORDS ($n)"
    echo "      Relationships that were removed and whose NAME was later reused."
    echo "      Not live, not orphaned, and not this tool's to delete -- but they"
    echo "      name peers, delegated accounts, datasets and key fingerprints, so"
    echo "      they are said out loud rather than left to be discovered."
    echo "      oldest: $oldest"
    echo "      newest: $newest"
    echo "      Read one before deciding: cat $CLIENTS_DIR/$oldest"
    return 0
}

# report_replica_jobs -- the scheduled work this audit did not know existed.
#
# Measured on pve9, 2026-08-30: the audit reported `hdd/labcoll` under DATA
# WITHOUT A RELATIONSHIP and then ended with "no relationship traces on this
# host at all" -- while THREE replica jobs in root's crontab were still
# scheduled to copy that very dataset onto removable media. They fire, find
# nothing, and alert.
#
# The audit could not see them for two reasons, and both are fixed here:
#
#   * a replica is a [replica:] section, a section type that did not exist when
#     this tool was written, and it is not a relationship -- so nothing looked;
#   * the config driving them need not live under /etc/zfs-snapshot-all at all.
#     The managed block names it on its own second line ("# Source: <path>"),
#     which this tool HASHED for its production-safety check and never read.
#
# Reported, never removed. `zfs-backup.sh remove-replica` owns that, and the
# copy on the medium is a copy.
report_replica_jobs() {
    local u tab src line name sources dst n=0
    for u in root $(ls -1 "$HOME_ROOT" 2>/dev/null); do
        id "$u" >/dev/null 2>&1 || continue
        tab="$(crontab -l -u "$u" 2>/dev/null)" || continue
        [ -n "$tab" ] || continue
        src="$(printf '%s\n' "$tab" | sed -n 's/^# Source: \(.*\) -- DO NOT EDIT.*$/\1/p' | head -1)"
        [ -n "$src" ] || continue
        if [ ! -r "$src" ]; then
            echo
            echo "  SCHEDULE WITHOUT ITS CONFIG ($u)"
            echo "      $u's managed block says it was generated from $src,"
            echo "      and that file is not readable. The jobs still run; nothing"
            echo "      on this host can regenerate or amend them."
            n=$((n+1))
            continue
        fi
        while IFS= read -r line; do
            case "$line" in
                '[replica:'*']') name="${line#\[replica:}"; name="${name%\]}" ;;
                *) continue ;;
            esac
            sources="$(awk -v want="[replica:$name]" '
                $0 == want { inb=1; next }
                inb && /^[[]/ { exit }
                inb && $1 == "source" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
            ' "$src")"
            dst="$(awk -v want="[replica:$name]" '
                $0 == want { inb=1; next }
                inb && /^[[]/ { exit }
                inb && $1 == "dst" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
            ' "$src")"
            [ "$n" -eq 0 ] && { echo; echo "  REPLICA JOBS (scheduled, not relationships)"; }
            n=$((n+1))
            echo "      $name  ($u)  -> ${dst:-?}"
            echo "        config: $src"
            local one missing=""
            while IFS= read -r one; do
                [ -n "$one" ] || continue
                if command -v "$ZFS_BIN" >/dev/null 2>&1 \
                   && ! "$ZFS_BIN" list -H -o name -- "$one" >/dev/null 2>&1; then
                    missing="$missing $one"
                fi
            done <<EOF
$(printf '%s' "$sources" | tr ',' '\n')
EOF
            if [ -n "$missing" ]; then
                echo "        !! SOURCE GONE:$missing -- this job runs nightly and will alert"
            else
                echo "        source: ${sources:-?}"
            fi
        done < "$src"
    done
    return 0
}

# report_orphaned_data -- datasets a tombstone says belonged to a relationship
# that is gone, and which are still on disk.
#
# The claim is made from the RECORD, not from the shape of a name. There is no
# pattern matching here and there must not be: `hdd/kopie` once looked exactly
# like a test dataset and was a real copy target, and a sweep would have taken
# it. A dataset is reported only when something wrote down that a relationship
# owned it -- which is why the tombstone above had to exist first.
#
# `zfs` is used, and only to ASK. This is the single place in the file that
# touches it, it is read-only, and its absence is a skip rather than an error:
# the rest of the tool must keep working on a host where zfs is broken, which
# is a state this tool is specifically for.
# A HOLD OUTLIVES THE RELATIONSHIP THAT PLACED IT.
#
# The engine keeps `zfssnapall_inflight` deliberately when a transfer dies with a
# resume token: the next run needs that exact snapshot. That is correct. What
# nothing noticed until 2026-08-26 is the case where the next run is never coming
# -- the relationship was torn down, the job removed, the lab dismantled.
#
# Measured that day on pve9: a hold placed 2026-08-22 by a run that died was still
# there four days later, with zero jobs on the host, and `zfs destroy` refused with
#
#     cannot destroy snapshot ...: dataset is busy
#
# which names neither the hold nor the tag. Retention hits the same wall silently
# on every run, and the pool grows.
#
# "PROBABLY LEAKED" IS NOT GOOD ENOUGH (reviewer, 2026-08-26). Age proves nothing:
# a hold placed a second ago and one placed last week are equally innocent if a
# transfer owns them. So a hold is called ORPHANED only against evidence, and the
# evidence is the state the engine itself writes down:
#
#   * a RUNNING engine  -- any snapsend/snapget on this host could own any hold,
#     and nothing here can tell which. One running process makes every verdict
#     unproven, which is the fail-closed direction;
#   * an IN-FLIGHT RECORD naming this snapshot -- `<engine>.inflight-snap.<key>`
#     in the lock directory, written before the transfer and cleared after. This
#     is the direct claim, and it is per SNAPSHOT, so it convicts precisely;
#   * a RESUME TOKEN -- and this is the honest limit. The token is a property of
#     the RECEIVING dataset, which for a pull relationship lives on another host
#     this tool does not talk to. What can be checked is the local side; a local
#     token anywhere means some transfer intends to continue, and that is enough
#     to withhold the verdict. A remote one cannot be seen at all, and the report
#     says so rather than implying the check was complete.
#
# Scanned in the lock directories the engines actually use: /var/run for root,
# $HOME/run for a delegated account (lib-zfs-snap.sh's ZFS_SNAP_DEFAULT_LOCKDIR).
HOLD_PS_CMD="${HOLD_PS_CMD:-ps -eo args=}"
HOLD_FACTS_LOADED=0
HOLD_ENGINE_RUNNING=0
HOLD_LOCAL_RESUME=0
HOLD_INFLIGHT_CLAIMS=""
hold_load_facts() {
    [ "$HOLD_FACTS_LOADED" -eq 1 ] && return 0
    HOLD_FACTS_LOADED=1
    # The process table, through a named command so a suite can pin it. Left as
    # the real `ps` by default; overridable because otherwise this check's answer
    # depends on whether a transfer happens to be running on the machine running
    # the tests -- the exact flake test/pairgate already documents.
    #
    # A bracketed first character so the pattern cannot match the grep that is
    # carrying it -- both are in the process table at the same moment.
    if $HOLD_PS_CMD 2>/dev/null | grep -qE '[s]napsend\.sh|[s]napget\.sh|[z]fs send'; then
        HOLD_ENGINE_RUNNING=1
    fi
    local d f
    for d in /var/run "$HOME_ROOT"/*/run; do
        [ -d "$d" ] || continue
        for f in "$d"/*.inflight-snap.*; do
            [ -f "$f" ] || continue
            HOLD_INFLIGHT_CLAIMS="$HOLD_INFLIGHT_CLAIMS
$(cat "$f" 2>/dev/null)"
        done
    done
    if command -v "$ZFS_BIN" >/dev/null 2>&1; then
        if "$ZFS_BIN" get -H -o value receive_resume_token 2>/dev/null | grep -qv '^-$'; then
            HOLD_LOCAL_RESUME=1
        fi
    fi
    return 0
}

# -> prints "ORPHANED" | "IN-USE <why>" | "UNPROVEN <why>"
hold_verdict() {   # <snapshot>
    local snap="$1"
    hold_load_facts
    if printf '%s\n' "$HOLD_INFLIGHT_CLAIMS" | grep -qxF -- "$snap"; then
        printf 'IN-USE inflight a transfer recorded this exact snapshot as in flight'
        return 0
    fi
    if [ "$HOLD_ENGINE_RUNNING" -eq 1 ]; then
        printf 'UNPROVEN engine a transfer is running on this host and may own this hold'
        return 0
    fi
    if [ "$HOLD_LOCAL_RESUME" -eq 1 ]; then
        printf 'UNPROVEN localtoken a dataset here carries a receive_resume_token, so some transfer means to continue'
        return 0
    fi
    # THE RECEIVING SIDE CANNOT BE EXCLUDED FROM HERE, and that is decisive.
    #
    # Found in review, 2026-08-26, and it is a P1 in the first cut of this:
    # `/var/run` is NOT persistent. Reboot the source and the in-flight record
    # is gone -- while the ZFS hold and the resume token on the REMOTE receiver
    # both survive. The first version then saw no process, no local token and no
    # record, called that ORPHANED, and released the snapshot the remote resume
    # still needed.
    #
    # I had already WRITTEN that the remote side is invisible from here, and
    # ruled on it anyway. Stating a boundary does not make a decision across it
    # safe. Absence of a file in a tmpfs is absence of evidence, not evidence of
    # absence.
    #
    # So ORPHANED is not concluded automatically. Everything this host can see
    # has been checked and none of it convicts -- which is a different sentence
    # from 'nothing owns this hold', and the report says the different sentence.
    # Releasing is left to --release-hold, where a human supplies the judgement
    # this code cannot: they know whether that relationship still exists.
    printf 'UNPROVEN remote nothing HERE claims it, but the receiver is not observable from this host (a pull target keeps its resume token on the far side, and /var/run does not survive a reboot)'
    return 0
}

# Every hold of OURS on this host, with its verdict. Returns 1 when at least one
# is ORPHANED -- that is the finding; IN-USE and UNPROVEN are not.
#
# One `zfs get` finds every held snapshot; `zfs holds` runs only for those, so a
# healthy host costs one call.
#
# NOT released here. This is the audit.
report_leaked_holds() {
    command -v "$ZFS_BIN" >/dev/null 2>&1 || return 0
    local snap refs shown=0 v findings=0
    while IFS="$(printf '\t')" read -r snap refs; do
        [ -n "$snap" ] || continue
        case "$refs" in ''|0|*[!0-9]*) continue ;; esac
        # OURS only. A pvesr hold on a replicated dataset is load-bearing for
        # somebody else's replication, and this project already measured what
        # touching one costs.
        "$ZFS_BIN" holds -H "$snap" 2>/dev/null | cut -f2 | grep -qxF "$HOLD_TAG" || continue
        v="$(hold_verdict "$snap")"
        if [ "$shown" -eq 0 ]; then
            echo
            echo "  HELD SNAPSHOTS -- ours ('$HOLD_TAG')"
            echo "      A hold is placed by a transfer and released when it finishes. One"
            echo "      that outlived its run blocks 'zfs destroy' with 'dataset is busy'"
            echo "      -- naming neither the hold nor the tag -- and silently fails"
            echo "      retention on that dataset every run."
            shown=1
        fi
        printf '      %-8s %s\n' "${v%% *}" "$snap"
        case "$v" in
            IN-USE*)
                # Healthy: a transfer running right now says this is its
                # snapshot. Nothing to do and nothing to report as wrong.
                printf '               ^ %s
' "${v#* * }" ;;
            *)
                # Everything else is a finding. Not because we know it is
                # abandoned -- since the review we deliberately do not claim
                # that -- but because a hold nothing running claims still blocks
                # `zfs destroy` and still fails retention on that dataset every
                # run, silently. The operator has to know, whoever owns it.
                findings=$((findings + 1))
                printf '               ^ %s
' "${v#* }"
                printf '               %s --release-hold=%s --yes
' "$0" "$snap" ;;
        esac
    done < <("$ZFS_BIN" get -H -o name,value -t snapshot userrefs 2>/dev/null)
    if [ "$shown" -eq 1 ]; then
        echo "      A resume token on a REMOTE target cannot be seen from here, so a"
        echo "      pull relationship's continuation is outside this evidence."
        echo "      None of these is released automatically. If you know the"
        echo "      relationship is gone, name the one you mean:"
        echo "        $0 --release-hold=<snapshot> --yes"
    fi
    [ "$findings" -gt 0 ] && return 1
    return 0
}

# ONE snapshot, named on the command line, and that is the whole point.
#
# The first cut let --purge-orphans release everything it had called ORPHANED.
# Review killed that, correctly: this host cannot see a pull relationship's
# receiver, so it cannot know whether a resume token still needs the snapshot,
# and /var/run losing the in-flight record to a reboot is not evidence that
# nothing does.
#
# What remains is a verb that supplies the missing judgement from the only place
# it exists -- the operator, who knows whether that relationship is still alive.
# They name the exact snapshot; nothing is inferred, nothing is swept.
#
# Still refused if anything THIS host can see says the hold is in use. The human
# is being asked about the far side, not about facts the machine already holds.
release_named_hold() {   # <snapshot>
    local snap="$1" v
    command -v "$ZFS_BIN" >/dev/null 2>&1 || die "no $ZFS_BIN on this host -- cannot release anything"
    "$ZFS_BIN" holds -H "$snap" 2>/dev/null | cut -f2 | grep -qxF "$HOLD_TAG" \
        || die "'$snap' does not carry a '$HOLD_TAG' hold -- nothing here to release. 'zfs holds $snap' will say what it does carry, and a hold that is not ours is not this tool's to touch."
    # The REASON CODE, not the wording. hold_verdict prints
    # "<class> <code> <reason>", and only ONE code may be overridden by a human:
    # `remote`, the case where everything this host can see is clean and the only
    # unknown is the far side. That is the judgement the operator has and the
    # code does not.
    #
    # The other three are LOCAL facts, and the commit that introduced this verb
    # said so in its own message -- while the gate only refused IN-USE, so
    # `--release-hold --yes` would still have released a snapshot with a running
    # transfer or a local resume token. Found in review, 2026-08-26.
    v="$(hold_verdict "$snap")"
    local vcode="${v#* }"; vcode="${vcode%% *}"
    case "$vcode" in
        remote) ;;
        inflight)   die "refusing: a transfer recorded '$snap' as in flight. Releasing now would pull the snapshot out from under a transfer that is still running -- this is not the far side, it is this host saying so." ;;
        engine)     die "refusing: a snapsend/snapget/zfs send is running on this host and may own this hold. Wait for it, or confirm it is not this snapshot's; --release-hold answers for the FAR side, not for facts visible here." ;;
        localtoken) die "refusing: a dataset on this host carries a receive_resume_token, so some transfer means to continue. Clear or complete it first ('zfs receive -A <target>' abandons one); --release-hold does not override local evidence." ;;
        *)          die "refusing: unrecognised verdict '$v' for '$snap' -- not releasing on an answer this code does not understand." ;;
    esac
    if [ "$ASSUME_YES" -ne 1 ]; then
        warn "would release $HOLD_TAG on $snap -- re-run with --yes to do it. Nothing was changed."
        return 0
    fi
    if "$ZFS_BIN" release "$HOLD_TAG" "$snap" 2>/dev/null; then
        log "released $HOLD_TAG on $snap"
        return 0
    fi
    warn "could not release $HOLD_TAG on $snap -- it is still held; 'zfs holds $snap' will say who by"
    return 1
}

# Kept, and now unreachable by design: hold_verdict no longer concludes ORPHANED,
# so this releases nothing. Left in place rather than deleted because the day the
# receiver becomes checkable -- a relational lookup of the real target, which is
# the reviewer's other permitted route -- this is where that answer plugs in.
release_orphaned_holds() {
    command -v "$ZFS_BIN" >/dev/null 2>&1 || return 0
    local snap refs v done_any=0
    while IFS="$(printf '\t')" read -r snap refs; do
        [ -n "$snap" ] || continue
        case "$refs" in ''|0|*[!0-9]*) continue ;; esac
        "$ZFS_BIN" holds -H "$snap" 2>/dev/null | cut -f2 | grep -qxF "$HOLD_TAG" || continue
        v="$(hold_verdict "$snap")"
        [ "${v%% *}" = ORPHANED ] || { log "  hold on $snap NOT released -- ${v#* }"; continue; }
        if "$ZFS_BIN" release "$HOLD_TAG" "$snap" 2>/dev/null; then
            log "  released $HOLD_TAG on $snap"
        else
            warn "  could not release $HOLD_TAG on $snap -- it is still held; 'zfs holds $snap' will say who by"
        fi
        done_any=1
    done < <("$ZFS_BIN" get -H -o name,value -t snapshot userrefs 2>/dev/null)
    [ "$done_any" -eq 1 ] || log "  no orphaned holds to release"
    return 0
}

report_orphaned_data() {
    [ -d "$TOMBSTONE_DIR" ] || return 0
    local f ds line name shown=0
    if ! command -v "$ZFS_BIN" >/dev/null 2>&1; then
        log "tombstones exist in $TOMBSTONE_DIR but zfs is not available -- cannot check whether that data is still here. The records are still in $TOMBSTONE_DIR; read them by hand."
        return 0
    fi
    for f in "$TOMBSTONE_DIR"/*; do
        [ -f "$f" ] || continue
        name=$(sed -n 's/^REMOVED_NAME=//p' "$f" | head -1)
        while IFS= read -r ds; do
            [ -n "$ds" ] || continue
            "$ZFS_BIN" list -H -o name "$ds" >/dev/null 2>&1 || continue
            if [ "$shown" -eq 0 ]; then
                echo
                echo "  DATA WITHOUT A RELATIONSHIP"
                echo "      Still on disk, and the relationship that produced it is gone."
                echo "      This tool does not destroy datasets. Decide, then run the line yourself."
                shown=1
            fi
            printf '      %-40s (was %s, see %s)\n' "$ds" "${name:-?}" "$(basename "$f")"
            printf '        zfs destroy -r %s   # then delete %s\n' "$ds" "$(basename "$f")"
        done < <(sed -n 's/^DATA=//p' "$f")
    done
    # Said out loud rather than left as a silent limit: anything purged before
    # tombstones existed, or removed by remove-client/--leave directly, has no
    # record and cannot be found here. Inferring it from dataset names would be
    # the sweep this tool refuses to do.
    [ "$shown" -eq 1 ] && echo "      (only data a tombstone recorded can appear here -- earlier removals left no record)"
    return 0
}

# ------------------------------------------------------------------------------
# PURGE
# ------------------------------------------------------------------------------
# ORDER IS THE WHOLE POINT, and it is the mistake this file was written after.
# The package's own verbs run FIRST, while the manifest they read still exists:
# deploy.sh --leave revokes the ZFS delegation, removes the account with its
# home, and deletes the manifest and scope. Hand-removing that manifest first
# strands the account somewhere no tool can reach it, and the operator is left
# doing by hand precisely what the whitelist rule exists to avoid.
# QUEUED ALERTS BELONG TO THE RELATIONSHIP THAT CAUSED THEM.
#
# Found live 2026-08-22: pve1's alert queue held four findings about lab6-r1 and
# a torn-down lab9 attempt -- relationships purged hours earlier -- and the next
# 07:00 digest would have mailed the owner about backups that no longer exist.
# Neither remove-client nor this tool touched the queue, so every teardown left
# its complaints behind to be delivered later, out of context and unanswerable.
#
# That is how alerting dies. This project has the receipt: 384 mails in one
# night, and the reflex it produced was MAILTO="" rather than a fix.
#
# The findings are NOT discarded. They move into the relationship's tombstone --
# the file that already exists to be the last thing naming what this
# relationship left behind. So the history stays exactly where someone asking
# "what was this?" will look, and tomorrow's digest reports only what is still
# true.
#
# Matching is on the label the monitor itself writes in parentheses, e.g.
# "pve1 profile__default__keep_hourly stale (lab6-r1)" -- the same string
# gen-cron put in the notify argument, so it cannot drift from the record.
ALERT_QUEUE="${ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
drain_queued_alerts() {   # <relationship id> <tombstone file or empty>
    local id="$1" tomb="${2:-}"
    [ -s "$ALERT_QUEUE" ] || return 0
    local mine tmp
    mine=$(grep -F "($id)" "$ALERT_QUEUE" 2>/dev/null) || true
    [ -n "$mine" ] || return 0
    local n; n=$(printf '%s
' "$mine" | grep -c .)
    # NO ARCHIVE, NO DELETION. write_tombstone writes nothing when the
    # relationship owned no data, so there can be no file to append to -- and
    # deleting the findings anyway would be exactly the "discarded" behaviour
    # this function exists to avoid. Stale alerts are recoverable; deleted ones
    # are not, so the queue keeps them and says why.
    if [ -z "$tomb" ] || [ ! -f "$tomb" ]; then
        log "  $n queued finding(s) for '$id' left in the alert queue -- this relationship owned no data, so there is no tombstone to keep them in and they will not be deleted without one"
        return 0
    fi
    if [ -n "$tomb" ] && [ -f "$tomb" ]; then
        {
            echo "#"
            echo "# Findings this relationship had queued when it was purged. They were"
            echo "# removed from the alert queue so the next digest does not report a"
            echo "# backup that no longer exists -- kept here because they DID happen."
            printf '%s
' "$mine" | sed 's/^/QUEUED_ALERT=/'
        } >> "$tomb" 2>/dev/null || warn "  could not append the queued findings to $tomb -- leaving them in the queue rather than losing them"
    fi
    # Read-and-rewrite under a lock on the queue itself. The writers are
    # notify-fail.sh and notify-warn.sh, which APPEND -- so without this, a
    # finding appended between the read and the write is silently dropped by
    # the rewrite. Rare, and exactly the kind of rare that costs an alert.
    # flock is already a dependency this project refuses to start without.
    tmp=$(mktemp "${ALERT_QUEUE}.XXXXXX" 2>/dev/null) || { warn "  could not rewrite $ALERT_QUEUE -- its findings for '$id' stay queued"; return 0; }
    if ! ( flock -w 10 9 || exit 1
           grep -vF "($id)" "$ALERT_QUEUE" > "$tmp" 2>/dev/null
           cat "$tmp" > "$ALERT_QUEUE" 2>/dev/null ) 9>>"$ALERT_QUEUE"; then
        rm -f "$tmp"
        warn "  could not rewrite $ALERT_QUEUE under a lock -- its findings for '$id' stay queued rather than risk losing one appended alongside"
        return 0
    fi
    rm -f "$tmp"
    log "  moved $n queued finding(s) for '$id' out of the alert queue${tomb:+ and into $(basename "$tomb")}"
}

# write_tombstone <id> -- record what this purge is about to make unfindable.
#
# The defect this closes was walked into on 2026-08-20: the purge deletes the
# client record, and that record is the ONLY thing on the host naming the data
# the relationship produced. hdd/lab4direct outlived its relationship and, the
# moment clients/lab4-direct.conf was gone, nothing linked those 12 MB to
# anything at all -- not a config file, not a cron line, nothing. Asked "what
# is this?", the host had no answer, and neither did this tool.
#
# So the record is written BEFORE the removal, not after, and the removal is
# REFUSED if the relationship owns data and the record cannot be written. The
# order is the property: a tombstone written afterwards is a tombstone that a
# crash halfway through would have skipped, on precisely the run that needed it.
write_tombstone() {   # <id> <data lines...>  -> 0 written or nothing to record
    local id="$1"; shift
    [ "$#" -gt 0 ] || return 0          # no data: nothing would be lost
    mkdir -p "$TOMBSTONE_DIR" 2>/dev/null || { warn "  could not create $TOMBSTONE_DIR"; return 1; }
    local f="$TOMBSTONE_DIR/$id.$(date +%Y%m%d-%H%M%S)"
    {
        echo "# clean-relationships.sh tombstone"
        echo "#"
        echo "# The relationship below was purged from this host. Its own record named"
        echo "# this data and that record is gone, so this file is now the only thing"
        echo "# that does. Nothing here has been destroyed -- this tool never destroys"
        echo "# datasets, on either side of a relationship."
        echo "REMOVED_NAME=$id"
        echo "REMOVED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "REMOVED_ON=$(hostname)"
        local d
        for d in "$@"; do echo "DATA=$d"; done
        echo "#"
        echo "# If that data is no longer wanted, destroy it deliberately and by hand:"
        for d in "$@"; do echo "#   zfs destroy -r $d"; done
        echo "# Then delete this file. While it exists, the audit reports that data as"
        echo "# orphaned, which is the whole point of it existing."
    } > "$f" 2>/dev/null || { warn "  could not write $f"; return 1; }
    chmod 0644 "$f" 2>/dev/null || :
    log "  recorded what this removes: $f"
    # Published so the purge can append to the same file -- see
    # drain_queued_alerts, which puts the relationship's queued findings where
    # the record of the relationship already is.
    TOMBSTONE_WRITTEN="$f"
    return 0
}

purge_one() {
    local id="$1" verdict reason art fam path rc=0
    # Cleared HERE, before write_tombstone can set it -- never after. The first
    # cut reset it AFTER the write, which silently emptied the path
    # drain_queued_alerts is handed, so every queued finding was deleted from
    # the queue and archived nowhere. The PR that introduced it claimed
    # "findings are NOT discarded" and the claim was false. It survived my own
    # live test because I called drain_queued_alerts directly with an explicit
    # path -- proving the function while leaving the wiring unproven.
    # --purge-orphans loops over several relationships in one run, so the reset
    # is needed; it just has to happen before, not after.
    TOMBSTONE_WRITTEN=""
    IFS=$'\t' read -r verdict reason <<< "$(classify "$id")"
    if [ "$verdict" != ORPHAN ]; then
        warn "$id is $verdict ($reason) -- refusing. Stop the relationship first (zfs-backup.sh remove-client / deploy.sh --leave), then re-run."
        return 1
    fi

    # BEFORE anything is touched, including --leave, which removes the join
    # manifest that carries PEER_JOIN_GRANTED_DATASETS.
    local -a owned=()
    while IFS=$'\t' read -r fam path; do
        [ "$fam" = data ] && owned+=("$path")
    done <<< "$(artefacts_for "$id")"
    if ! write_tombstone "$id" "${owned[@]+"${owned[@]}"}"; then
        warn "$id owns data (${owned[*]}) and the record of it could not be written -- REFUSING to purge. Removing the last thing that names this data, without leaving anything that names it, is the failure this record exists to prevent."
        return 1
    fi

    log "purging '$id'"

    # 1. The source's own verb, only when its map is still there.
    if [ -s "$PEER_STATE_DIR/$id.conf" ] && [ -x "$DEPLOY" ]; then
        log "  deploy.sh --leave=$id (its manifest is present, so the tool can still do this properly)"
        local lout lrc
        lout=$(bash "$DEPLOY" --leave="$id" </dev/null 2>&1); lrc=$?
        if [ "$lrc" -eq 0 ]; then
            log "  --leave succeeded"
        else
            warn "  --leave failed or refused -- continuing with the explicit list, and saying so rather than pretending it worked"
            printf '%s\n' "$lout" | grep -E '^FATAL' | sed 's/^/      /' >&2
            # One refusal deserves naming, because its wording is honest but
            # its most common cause is not what it describes. --leave refuses
            # while a `zfssnapall_inflight` hold exists and says "retry once
            # the transfer completes" -- correct when a transfer is running,
            # and a dead end when the hold was LEAKED by one that died. Seen
            # live on 2026-08-20: the hold sat on a snapshot whose successor
            # had already been received, so nothing was ever going to complete,
            # and on the receiving side an interrupted `zfs receive` had left a
            # `%recv` stub that was failing the hourly retention as well.
            case "$lout" in
                *zfssnapall_inflight*)
                    warn "      ^ that refusal assumes a transfer is RUNNING. If none is, the hold leaked and nothing will ever complete it. Check, in this order:"
                    warn "          ps -eo args | grep '[z]fs send'                    # is one actually running?"
                    warn "          zfs holds <the snapshot named above>               # who holds it"
                    warn "          on the RECEIVER: zfs list -t all -r <target> | grep %recv"
                    warn "        A leftover %recv also fails that target's retention every run. Clear with 'zfs receive -A <target>' there, then 'zfs release zfssnapall_inflight <snapshot>' here, then re-run this." ;;
            esac
        fi
    elif id "zfsbackup-$id" >/dev/null 2>&1; then
        warn "  account zfsbackup-$id exists but its join manifest does not: --leave cannot run. This is the stranded case -- the account is removed below by hand, which is the only route left."
    fi

    # 2. Whatever the tools left, by exact path. Re-read AFTER --leave: the
    #    list must describe the tree as it is now, not as it was.
    art=$(artefacts_for "$id")
    if [ -z "$art" ]; then
        log "  nothing left"
        return 0
    fi
    while IFS=$'\t' read -r fam path; do
        [ -n "$path" ] || continue
        case "$fam" in
            data)
                # Named once more on the way out, because the record that knew
                # about it is being deleted in this same run.
                #
                # P9: but only if it is still there. This printed "DATA LEFT IN
                # PLACE" for a dataset destroyed moments earlier -- cosmetic
                # exactly until someone believes it. A tombstone's whole job is
                # to say what survived, and this one asserted the survival of
                # something it had never looked at. Same family as the rest of
                # the campaign; the audit path already checks.
                if "$ZFS_BIN" list -H -o name -- "$path" >/dev/null 2>&1; then
                    log "  DATA LEFT IN PLACE: $path -- this tool never destroys datasets. If it is no longer wanted: zfs destroy -r $path"
                else
                    log "  data $path is ALREADY GONE -- the record named it, the pool does not have it; nothing was left in place"
                fi
                continue ;;
            account)
                if deluser --remove-home "$path" >/dev/null 2>&1; then
                    log "  removed account $path (with its home)"
                else
                    warn "  could not remove account $path"; rc=1
                fi ;;
            gate|homedir)
                # rmdir, not rm -rf: it refuses a non-empty directory on its
                # own, so the safety is in the tool rather than in this
                # script's belief that the directory is empty.
                if rmdir "$path" 2>/dev/null; then
                    log "  removed $path"
                elif [ -d "$path" ]; then
                    warn "  $path is NOT empty -- left in place, inspect it: $(ls -A "$path" | tr '\n' ' ')"; rc=1
                fi ;;
            *)
                if rm -f "$path"; then log "  removed $path"; else warn "  could not remove $path"; rc=1; fi ;;
        esac
    done <<< "$art"

    # 3. The findings this relationship had queued. Done AFTER the artefacts,
    #    so a purge that failed halfway leaves the queue untouched and the
    #    complaints still deliverable -- an alert is worth more than tidiness.
    drain_queued_alerts "$id" "${TOMBSTONE_WRITTEN:-}"

    # 4. known_hosts is deliberately not touched -- same stance remove-client
    #    takes, and for the same reason.
    local addr="${NAME_ADDR[$id]:-}"
    [ -n "$addr" ] && log "  known_hosts left alone (our record of who they are, not a permission for them). To drop it: ssh-keygen -f /root/.ssh/known_hosts -R $addr"
    return "$rc"
}

# ------------------------------------------------------------------------------
main() {
    # Named, single, and first: it answers a question about ONE snapshot and has
    # nothing to do with the relationship inventory below.
    if [ -n "$RELEASE_HOLD" ]; then
        release_named_hold "$RELEASE_HOLD"
        return $?
    fi
    discover

    # Production safety: every crontab on this host, hashed before and after.
    # A relationship cleanup has no business changing what the delegated
    # account runs, and "I did not touch it" is not evidence.
    local -A TAB_BEFORE=()
    local u
    for u in root $(ls -1 "$HOME_ROOT" 2>/dev/null); do
        id "$u" >/dev/null 2>&1 || continue
        TAB_BEFORE["$u"]=$(crontab -l -u "$u" 2>/dev/null | md5sum | cut -d' ' -f1)
    done

    echo "== relationship traces on $(hostname) =="
    report
    report_archived_records
    report_replica_jobs
    report_orphaned_data
    local held=0
    report_leaked_holds || held=1

    if [ "$PURGING" -eq 0 ]; then
        if [ "${#ORPHANS[@]}" -gt 0 ]; then
            log "${#ORPHANS[@]} orphan(s): ${ORPHANS[*]}"
            log "remove them with: $0 --purge-orphans --yes"
            return 3
        fi
        if [ "$held" -eq 1 ]; then
            # Not folded into the orphan count: a held snapshot is a different
            # kind of finding and needs a different action. But it must not be
            # reported under a clean exit either -- "nothing orphaned" while a
            # dataset silently cannot be pruned is the false all-clear this tool
            # exists to prevent.
            log "no orphaned relationships, but held snapshots were found (above) -- retention on those datasets is failing silently"
            return 3
        fi
        log "nothing orphaned -- every trace on this host belongs to a live relationship"
        return 0
    fi

    local -a targets=()
    if [ "$PURGE_ORPHANS" -eq 1 ]; then
        targets=("${ORPHANS[@]}")
        # NOT a plain early return. A host can have zero orphaned relationships
        # and still be carrying a leaked hold -- that is exactly the pve9 case
        # this whole check came from -- and returning here would leave the only
        # verb that can release it unreachable. Found by its own test.
        if [ "${#targets[@]}" -eq 0 ]; then
            log "no orphaned relationships to purge"
            echo
            log "orphaned holds ('$HOLD_TAG'):"
            # NOT released here. This host cannot see a pull relationship's receiver,
            # so it cannot know whether a resume token still needs the snapshot --
            # and /var/run losing the in-flight record to a reboot proves nothing.
            # They are listed; --release-hold=<snapshot> is where a human decides.
            report_leaked_holds || :
            return 0
        fi
    else
        targets=("$PURGE_TARGET")
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        warn "would purge: ${targets[*]} -- re-run with --yes to do it. Nothing was changed."
        return 0
    fi

    local t rc=0
    for t in "${targets[@]}"; do purge_one "$t" || rc=1; done

    # A SEPARATE, NAMED STEP. Holds are not keyed on a relationship -- the leak
    # outlives it -- so this is not part of purging any one of them; it is the
    # explicit path the reviewer required, and it runs only here, only under
    # --yes, and only on holds proven ORPHANED. Everything else is named and
    # left alone.
    echo
    log "orphaned holds ('$HOLD_TAG'):"
    # NOT released here. This host cannot see a pull relationship's receiver,
    # so it cannot know whether a resume token still needs the snapshot --
    # and /var/run losing the in-flight record to a reboot proves nothing.
    # They are listed; --release-hold=<snapshot> is where a human decides.
    report_leaked_holds || :

    echo
    log "crontab check (a relationship cleanup must not have touched these):"
    for u in "${!TAB_BEFORE[@]}"; do
        local now; now=$(crontab -l -u "$u" 2>/dev/null | md5sum | cut -d' ' -f1)
        if [ "$now" = "${TAB_BEFORE[$u]}" ]; then
            log "  $u: unchanged (${now:0:12})"
        else
            warn "  $u: CHANGED (${TAB_BEFORE[$u]:0:12} -> ${now:0:12}) -- investigate before trusting this run"
            rc=1
        fi
    done
    return "$rc"
}

main
