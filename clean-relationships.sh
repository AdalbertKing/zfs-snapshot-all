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
#
# Exit: 0 audit clean or purge done, 1 error, 2 usage, 3 orphans found (audit)
# ------------------------------------------------------------------------------
VERSION="v1.0"

CLIENTS_DIR="${CLIENTS_DIR:-/etc/zfs-snapshot-all/clients}"
PEER_STATE_DIR="${PEER_STATE_DIR:-/etc/zfs-snapshot-all/peers}"
REL_STATE_DIR="${REL_STATE_DIR:-/var/lib/zfs-snapshot-all/relationships}"
PEER_KEY_DIR="${PEER_KEY_DIR:-/root/.ssh/pairing}"
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
for a in "$@"; do
    case "$a" in
        -V|--version)   echo "$VERSION"; exit 0 ;;
        -h|--help)      usage 0 ;;
        --purge=*)      PURGE_TARGET="${a#*=}" ;;
        --purge-orphans) PURGE_ORPHANS=1 ;;
        --yes)          ASSUME_YES=1 ;;
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

    # Collector: pairing keys, keyed by address. Four files per peer, and only
    # three of them are removed by remove-client -- _alias_known_hosts survives,
    # and it is the one the generated cron lines actually pass to -k.
    for f in "$PEER_KEY_DIR"/*_ed25519 "$PEER_KEY_DIR"/*_alias_known_hosts; do
        [ -e "$f" ] || continue
        b=$(basename "$f"); b="${b%_ed25519}"; b="${b%_alias_known_hosts}"
        SEEN_ADDR["$b"]=1
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
    local id="$1" addr="${NAME_ADDR[$id]:-}" f
    [ -e "$CLIENTS_DIR/$id.conf" ]       && echo "client	$CLIENTS_DIR/$id.conf"
    [ -e "$PEER_STATE_DIR/$id.conf" ]    && echo "manifest	$PEER_STATE_DIR/$id.conf"
    [ -e "$PEER_STATE_DIR/$id.scope" ]   && echo "scope	$PEER_STATE_DIR/$id.scope"
    [ -e "$PEER_STATE_DIR/$id.scope.sha256" ] && echo "scope	$PEER_STATE_DIR/$id.scope.sha256"
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
    fi
}

# ------------------------------------------------------------------------------
# REPORT
# ------------------------------------------------------------------------------
ORPHANS=()
report() {
    local ids id verdict reason art n=0
    ids=$(printf '%s\n' "${!SEEN_NAME[@]}" "${!SEEN_LABEL[@]}" | grep -v '^$' | sort -u)
    [ -n "$ids" ] || { log "no relationship traces on this host at all"; return 0; }
    while read -r id; do
        [ -n "$id" ] || continue
        IFS=$'\t' read -r verdict reason <<< "$(classify "$id")"
        art=$(artefacts_for "$id")
        echo
        echo "  $id  [$verdict]"
        echo "      $reason"
        if [ -n "$art" ]; then
            printf '%s\n' "$art" | while IFS=$'\t' read -r fam path; do
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

# ------------------------------------------------------------------------------
# PURGE
# ------------------------------------------------------------------------------
# ORDER IS THE WHOLE POINT, and it is the mistake this file was written after.
# The package's own verbs run FIRST, while the manifest they read still exists:
# deploy.sh --leave revokes the ZFS delegation, removes the account with its
# home, and deletes the manifest and scope. Hand-removing that manifest first
# strands the account somewhere no tool can reach it, and the operator is left
# doing by hand precisely what the whitelist rule exists to avoid.
purge_one() {
    local id="$1" verdict reason art fam path rc=0
    IFS=$'\t' read -r verdict reason <<< "$(classify "$id")"
    if [ "$verdict" != ORPHAN ]; then
        warn "$id is $verdict ($reason) -- refusing. Stop the relationship first (zfs-backup.sh remove-client / deploy.sh --leave), then re-run."
        return 1
    fi

    log "purging '$id'"

    # 1. The source's own verb, only when its map is still there.
    if [ -s "$PEER_STATE_DIR/$id.conf" ] && [ -x "$DEPLOY" ]; then
        log "  deploy.sh --leave=$id (its manifest is present, so the tool can still do this properly)"
        if bash "$DEPLOY" --leave="$id" </dev/null >/dev/null 2>&1; then
            log "  --leave succeeded"
        else
            warn "  --leave failed or refused -- continuing with the explicit list, and saying so rather than pretending it worked"
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

    # 3. known_hosts is deliberately not touched -- same stance remove-client
    #    takes, and for the same reason.
    local addr="${NAME_ADDR[$id]:-}"
    [ -n "$addr" ] && log "  known_hosts left alone (our record of who they are, not a permission for them). To drop it: ssh-keygen -f /root/.ssh/known_hosts -R $addr"
    return "$rc"
}

# ------------------------------------------------------------------------------
main() {
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

    if [ "$PURGING" -eq 0 ]; then
        if [ "${#ORPHANS[@]}" -gt 0 ]; then
            log "${#ORPHANS[@]} orphan(s): ${ORPHANS[*]}"
            log "remove them with: $0 --purge-orphans --yes"
            return 3
        fi
        log "nothing orphaned -- every trace on this host belongs to a live relationship"
        return 0
    fi

    local -a targets=()
    if [ "$PURGE_ORPHANS" -eq 1 ]; then
        targets=("${ORPHANS[@]}")
        [ "${#targets[@]}" -gt 0 ] || { log "no orphans to purge"; return 0; }
    else
        targets=("$PURGE_TARGET")
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        warn "would purge: ${targets[*]} -- re-run with --yes to do it. Nothing was changed."
        return 0
    fi

    local t rc=0
    for t in "${targets[@]}"; do purge_one "$t" || rc=1; done

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
