#!/bin/bash
# What a relationship record that CANNOT BE READ is called, and what a record
# that is merely incomplete is called -- because those were the same sentence.
#
#   ./test/restore/records.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/records.sh   # negative control
#
# Sourced by test/restore/run.sh, so the default battery is unchanged. Separate
# file for the same reason as relpolicy.sh: a negative control has to run these
# against a mutated tree, and the battery costs ten minutes on the implementer's
# box against under two seconds here.
#
# FOUND ON THE LAB, not by a suite (pve9, 2026-08-31). The client records are
# 0600 root:root; a recovery started as the delegated account was told the record
# "carries no CLIENT_NAME" -- for a field that was sitting in the file. The read
# is `2>/dev/null`, so an unreadable file and a field-less file produce the same
# nothing, and the refusal blamed the one it could name. An operator follows that
# message to the wrong place, on the one verb where the machine is already down.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _rec_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_rec_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _rec_standalone=1
fi

REC="$WORK/records"; mkdir -p "$REC/clients"

# Drive restore_relations_sane over a CLIENTS_DIR built per case.
rec_run() {   # <clients dir> -> the refusal (or nothing) on stdout
    local dir="$1"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'CLIENTS_DIR=%q\n' "$dir"
        echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        echo 'log() { shift; printf "%s\n" "$*" >&2; }'
        awk -v want="restore_relations_sane() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        echo 'restore_relations_sane'
    } > "$t"
    bash "$t" 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

# ---- the record that cannot be opened ---------------------------------------
# Skipped when the suite runs as root, because root can read a 0000 file and the
# case would then assert nothing. Said out loud rather than silently passing: a
# case that cannot fail is worse than a case that is absent.
printf 'CLIENT_NAME=src8\n' > "$REC/clients/src8.conf"
chmod 000 "$REC/clients/src8.conf" 2>/dev/null
if [ -r "$REC/clients/src8.conf" ]; then
    echo "SKIP records: unreadable-record cases need a non-root runner (this one can read 0000)"
else
    out="$(rec_run "$REC/clients")"
    case "$out" in
        *"cannot be READ"*) ok "records: an unreadable record is called unreadable" ;;
        *) bad "records: an unreadable record is called unreadable" "$out" ;;
    esac
    # THE CARRYING ASSERTION. The old message named the content, and that is the
    # sentence an operator acts on.
    case "$out" in
        *"carries no CLIENT_NAME"*) bad "records: ...and NOT blamed on its content" "$out" ;;
        *) ok "records: ...and NOT blamed on its content" ;;
    esac
    case "$out" in
        *"permission problem"*) ok "records: ...saying plainly which kind of problem it is" ;;
        *) bad "records: ...saying plainly which kind of problem it is" "$out" ;;
    esac
fi
chmod 644 "$REC/clients/src8.conf" 2>/dev/null

# ---- THE CONTROL: a readable record that really has no CLIENT_NAME ----------
# Without this the fix could have been "stop saying carries no CLIENT_NAME",
# which would lose a real refusal. The two messages have to stay distinct.
rm -f "$REC/clients"/*.conf
printf 'SOMETHING_ELSE=1\n' > "$REC/clients/src9.conf"
out="$(rec_run "$REC/clients")"
case "$out" in
    *"carries no CLIENT_NAME"*) ok "records: a readable record with no CLIENT_NAME is still called that" ;;
    *) bad "records: a readable record with no CLIENT_NAME is still called that" "$out" ;;
esac
case "$out" in
    *"cannot be READ"*) bad "records: ...and is NOT called a permission problem" "$out" ;;
    *) ok "records: ...and is NOT called a permission problem" ;;
esac

# ---- a well-formed record passes -------------------------------------------
rm -f "$REC/clients"/*.conf
printf 'CLIENT_NAME=src9\n' > "$REC/clients/src9.conf"
if out="$(rec_run "$REC/clients")"; then ok "records: a well-formed record is accepted"
else bad "records: a well-formed record is accepted" "$out"; fi

# ---- the multi-config refusal reads as sentences, not as one word -----------
# `...zfsbackup.confEach belongs to a different account` -- measured on pve9,
# 2026-08-31. The path and the next sentence had no separator between them.
mc="$WORK/multicfg"; mkdir -p "$mc"
: > "$mc/jobs.h.conf"; : > "$mc/jobs.h.acct.conf"
t=$(mktemp)
{
    echo 'set -u'
    echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
    printf 'found=(%q %q)\n' "$mc/jobs.h.conf" "$mc/jobs.h.acct.conf"
    awk -v want="restore_pick_config() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB" \
        | sed -n '/more than one installed config/,/^        fi$/p'
} > "$t"
mc_out="$(bash "$t" 2>&1)"; rm -f "$t"
case "$mc_out" in
    *".confEach"*) bad "records: the two-config refusal does not run the path into the next sentence" "$mc_out" ;;
    *) ok "records: the two-config refusal does not run the path into the next sentence" ;;
esac
case "$mc_out" in
    *"Each belongs to a different account"*) ok "records: ...and still says why it will not choose" ;;
    *) bad "records: ...and still says why it will not choose" "$mc_out" ;;
esac

if [ "${_rec_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
