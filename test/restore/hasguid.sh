#!/bin/bash
# `restore_remote_has_guid`: does the target still hold the recovery point?
#
#   ./test/restore/hasguid.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/hasguid.sh   # negative control
#
# Sourced by test/restore/run.sh.
#
# WHAT IS AND IS NOT ASSERTED HERE, because test/restoregrant/run.sh already
# argues the point and this file must not quietly contradict it: the remote MODE
# CLASSIFICATION is not asserted in any suite, on purpose -- it is decided by
# asking the far side, and an assertion over a stubbed classifier proves the
# stub. That half is proven on the lab.
#
# What IS honestly testable is this probe's CONTRACT: three answers, not two.
# 0 the guid is there, 1 it is not, 2 the question could not be asked. The third
# is the whole reason it is a function rather than a test inline -- collapsing
# "could not ask" into "not there" reads an unreachable host as "no common base"
# and escalates a rewind into destroying the dataset. That collapse has happened
# twice already in this file's history (F14, and the `_arc` bug in restore_one),
# which is why it gets a case rather than a comment.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _hg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_hg_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _hg_standalone=1
fi

# The ssh stub answers with whatever the case puts in $HG/answer, and fails
# outright when the case says so -- which is the only way to express "the host
# did not answer" without an unreachable host.
hg_probe() {   # <ssh behaviour: ok|dead> <what the far side prints> -> the probe's exit code
    local how="$1" says="$2"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'SAYS=%q\n' "$says"
        if [ "$how" = dead ]; then
            echo 'ssh() { return 255; }'
        else
            echo 'ssh() { printf "%s\n" "$SAYS"; return 0; }'
        fi
        echo 'SSH_OPTS=()'
        awk -v want="restore_remote_has_guid() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        echo 'restore_remote_has_guid acct@host rpool/data 12279236860074163308'
    } > "$t"
    bash "$t" >/dev/null 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

hg_probe ok YES; rc=$?
case "$rc" in 0) ok "hasguid: the guid is there -> 0" ;; *) bad "hasguid: the guid is there -> 0" "rc=$rc" ;; esac

hg_probe ok NO; rc=$?
case "$rc" in 1) ok "hasguid: the guid is not there -> 1" ;; *) bad "hasguid: the guid is not there -> 1" "rc=$rc" ;; esac

# A dataset that is gone is an honest "no": there is nothing to roll back to, and
# the caller's full-live classification is the right one.
hg_probe ok NODS; rc=$?
case "$rc" in 1) ok "hasguid: the dataset is not there at all -> 1, an honest no" ;; *) bad "hasguid: the dataset is not there at all -> 1, an honest no" "rc=$rc" ;; esac

# THE CARRYING ASSERTION. An unreachable host is 2, never 1: read as "no" it
# escalates a rewind into destroying the dataset, and this exact collapse has
# happened twice in this file already.
hg_probe dead ''; rc=$?
case "$rc" in
    2) ok "hasguid: AN UNANSWERED QUESTION IS 2, NOT 'NO'" ;;
    *) bad "hasguid: AN UNANSWERED QUESTION IS 2, NOT 'NO'" "rc=$rc -- 1 here would turn an unreachable host into a full replace" ;;
esac

# Anything the far side says that is not one of the three words is also 2. A
# truncated or garbled answer is not evidence of absence.
hg_probe ok 'bash: zfs: command not found'; rc=$?
case "$rc" in
    2) ok "hasguid: an answer that is not one of the three words is 2, not 'no'" ;;
    *) bad "hasguid: an answer that is not one of the three words is 2, not 'no'" "rc=$rc" ;;
esac

# And a missing argument is 2 rather than a probe that asks about nothing: an
# empty guid would match nothing and read as a confident "no".
t=$(mktemp)
{
    echo 'set -u'
    echo 'ssh() { printf "NO\n"; return 0; }'
    echo 'SSH_OPTS=()'
    awk -v want="restore_remote_has_guid() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
    echo 'restore_remote_has_guid acct@host rpool/data ""'
} > "$t"
bash "$t" >/dev/null 2>&1; rc=$?
rm -f "$t"
case "$rc" in
    2) ok "hasguid: an empty guid is 2, not a confident 'no'" ;;
    *) bad "hasguid: an empty guid is 2, not a confident 'no'" "rc=$rc" ;;
esac

if [ "${_hg_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
