#!/bin/bash
# A `create` that FAILED destroyed nothing -- if nothing is there.
#
#   ./test/restore/createfail.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/createfail.sh   # negative control
#
# Sourced by test/restore/run.sh.
#
# RESTORE_ONE_CHANGED is set unconditionally before the engine, which is the
# right default: from that line on the engine MAY destroy. For mode `create` it
# may not -- the destination did not exist -- and reporting the dataset as
# "CHANGED AND UNFINISHED ... they need a person" sends somebody to inspect a
# machine where nothing happened.
#
# FOUND ON THE LAB, 2026-08-31: a `--onto` aimed outside the destination's grant
# failed on `create`, was reported CHANGED, and the summary said
# "(0 recovered, 0 untouched)" -- claiming nothing was untouched while the
# dataset plainly was. The destination did not exist on that host before or
# after, checked by hand.
#
# The demotion is ON PROOF ONLY, and the two cases that must NOT demote are the
# point of the file: a partial receive that left something behind, and a host
# that did not answer. "I could not ask" has never been "it is fine" anywhere
# else in this tree.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _cf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_cf_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _cf_standalone=1
fi

CF="$WORK/createfail"; mkdir -p "$CF"
printf '#!/bin/sh\nexit 1\n' > "$CF/eng"; chmod +x "$CF/eng"

cf_run() {   # <what the target says it holds> -> restore_one's exit status
    local remote="$1"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'REMOTE_SAYS=%q\n' "$remote"
        printf 'CF=%q\n' "$CF"
        printf 'RESTORE_ENGINE=%q\n' "$CF/eng"
        echo 'log() { shift; printf "%s\n" "$*" >&2; }'
        echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        cat <<'STUB'
# The target is ABSENT at classification time -- that is what makes the mode
# `create`. What it says AFTERWARDS is the case's variable, and the only thing
# that may demote the verdict.
# THE COUNTER LIVES IN A FILE, not a variable. Every caller reaches this
# through `$( )`, which is a subshell -- a value set inside one never reaches
# the next call, so a variable-based toggle answers "absent" every time and the
# cases below measure nothing. Same trap as unwrap_media_bracket in cron2conf.sh
# and run_policy in relpolicy.sh, both of which carry a paragraph about it.
restore_remote_state() {
    if [ ! -s "$CF/asked" ]; then echo 1 > "$CF/asked"; printf 'absent\n'; return 0; fi
    [ -n "$REMOTE_SAYS" ] && printf '%s\n' "$REMOTE_SAYS"
    return 0
}
restore_grant_require()  { return 0; }
restore_remote_ahead()   { return 0; }
restore_point_unique()   { return 0; }
restore_engine_argv()    { RESTORE_ENGINE_ARGV=(x); return 0; }
zfs() {
    case "$*" in
        *"-t snapshot"*) printf 'hdd/copy@p\t100\t777\n' ;;
    esac
}
STUB
        awk -v want="restore_one() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        echo 'RESTORE_POINT_NAME=p'
        echo 'restore_one hdd/copy acct@host:rpool/data'
    } > "$t"
    : > "$CF/asked"
    bash "$t" >/dev/null 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

# ---- THE CARRYING ASSERTION -------------------------------------------------
# The target says the dataset is absent: the failed create left nothing, so the
# dataset is UNTOUCHED (1), not CHANGED (2).
cf_run absent; rc=$?
case "$rc" in
    1) ok "createfail: A FAILED create WITH NOTHING THERE IS UNTOUCHED, NOT CHANGED" ;;
    *) bad "createfail: A FAILED create WITH NOTHING THERE IS UNTOUCHED, NOT CHANGED" "rc=$rc -- 2 sends somebody to inspect a machine where nothing happened" ;;
esac

# ---- something IS there: the loud verdict stays -----------------------------
# A partial receive that left debris behind is exactly what CHANGED is for.
cf_run 12345; rc=$?
case "$rc" in
    2) ok "createfail: ...but debris left behind keeps the loud verdict" ;;
    *) bad "createfail: ...but debris left behind keeps the loud verdict" "rc=$rc" ;;
esac

# ---- the host did not answer: the loud verdict stays ------------------------
# "I could not ask" is not "it is fine", here as everywhere else in this tree.
cf_run ''; rc=$?
case "$rc" in
    2) ok "createfail: ...and an unanswered question does not demote it either" ;;
    *) bad "createfail: ...and an unanswered question does not demote it either" "rc=$rc" ;;
esac

if [ "${_cf_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
