#!/bin/bash
# `--from-copy`: recovering from a copy location when the relationship records
# are gone.
#
#   ./test/restore/fromcopy.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/fromcopy.sh   # negative control
#
# Sourced by test/restore/run.sh. Its own file for the same reason as the other
# sections: a negative control has to run it against a mutated tree in seconds.
#
# The landing engine (restore_safe_land) is STUBBED here, and that is the point
# of the boundary rather than a shortcut: this form's whole contract is what
# happens BEFORE anything is created. Whether the engine was entered at all is
# the assertion; what the engine does once entered is covered by the cases above
# that drive it for real.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _fc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_fc_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _fc_standalone=1
fi

FC="$WORK/fromcopy"; mkdir -p "$FC"

# Drive cmd_restore_from_copy with a zfs that answers from two files:
#   $FC/exists          one dataset name per line
#   $FC/rows.<mangled>  the snapshot listing for that copy, name<TAB>creation<TAB>guid
fc_run() {   # <copy list> <onto list> <snapshot> <at epoch> -> output; LANDED holds the calls
    local copies="$1" ontos="$2" snap="$3" at="$4"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'FC=%q\n' "$FC"
        echo 'die() { printf "FATAL: %s\n" "$*" >&2; exit 1; }'
        echo 'log() { shift; printf "%s\n" "$*" >&2; }'
        cat <<'STUB'
zfs() {
    case "$1 $2" in
        "list -H")
            case "$*" in
                *"-t snapshot"*)
                    local c="${!#}" f
                    f="$FC/rows.$(printf '%s' "$c" | tr '/' '_')"
                    [ -r "$f" ] || return 1
                    cat "$f"; return 0 ;;
                *" -r "*)
                    # Recursive listing: the dataset and everything under it,
                    # parent first, the order `zfs list -r` gives.
                    local d="${!#}"
                    grep -qFx -- "$d" "$FC/exists" 2>/dev/null || return 1
                    grep -E "^${d}(/|$)" "$FC/exists"; return 0 ;;
                *)  local d="${!#}"
                    grep -qFx -- "$d" "$FC/exists" 2>/dev/null || return 1
                    printf '%s\n' "$d"; return 0 ;;
            esac ;;
    esac
    return 0
}
# THE BOUNDARY UNDER TEST: was the landing engine entered, and with what. A
# refusal that still enters it has created something, which is the one thing
# this form promises never to do without a free destination.
restore_safe_land() { printf 'LAND %s@%s -> %s\n' "$1" "$2" "$3"; return 0; }
STUB
        awk -v want="restore_at_pick() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        awk -v want="cmd_restore_from_copy() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'cmd_restore_from_copy %q %q %q %q 1\n' "$copies" "$ontos" "$snap" "$at"
    } > "$t"
    bash "$t" 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

# One copy with three snapshots. The middle one is DELIBERATELY the newest by
# `creation` while carrying an older-looking name -- the discriminator this
# project has paid for twice: choosing on the name picks the story, choosing on
# creation picks the fact.
printf 'hdd/copyA\nhdd/copyB\nhdd/taken\n' > "$FC/exists"
{
  printf 'hdd/copyA@automated_2026-01-01_00-00-00\t1000\t11\n'
  printf 'hdd/copyA@automated_2026-06-15_12-00-00\t3000\t33\n'
  printf 'hdd/copyA@automated_2026-09-09_09-09-09\t2000\t22\n'
} > "$FC/rows.hdd_copyA"
printf 'hdd/copyB@s1\t1000\t44\nhdd/copyB@s2\t2000\t55\n' > "$FC/rows.hdd_copyB"

# ---- the happy path --------------------------------------------------------
out="$(fc_run 'hdd/copyA' 'hdd/wolne' '' '')"; rc=$?
case "$rc$out" in
    0*"LAND hdd/copyA@"*"-> hdd/wolne"*) ok "fromcopy: a copy lands on a free destination" ;;
    *) bad "fromcopy: a copy lands on a free destination" "rc=$rc" "$out" ;;
esac
# THE DISCRIMINATOR: newest by creation (3000), not the newest-LOOKING name.
case "$out" in
    *"@automated_2026-06-15_12-00-00 -> hdd/wolne"*) ok "fromcopy: the default recovery point is the newest by CREATION, not by name" ;;
    *) bad "fromcopy: the default recovery point is the newest by CREATION, not by name" "$out" ;;
esac

# ---- THE CARRYING ASSERTION: an occupied destination is never touched -------
out="$(fc_run 'hdd/copyA' 'hdd/taken' '' '')"; rc=$?
case "$rc" in
    2) ok "fromcopy: an occupied destination refuses" ;;
    *) bad "fromcopy: an occupied destination refuses" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"LAND "*) bad "fromcopy: ...AND THE LANDING ENGINE IS NEVER ENTERED" "$out" ;;
    *) ok "fromcopy: ...AND THE LANDING ENGINE IS NEVER ENTERED" ;;
esac
case "$out" in
    *"never overwrites"*) ok "fromcopy: ...saying it never overwrites, in those words" ;;
    *) bad "fromcopy: ...saying it never overwrites, in those words" "$out" ;;
esac

# ---- one bad pair refuses the WHOLE list, before anything lands -------------
out="$(fc_run 'hdd/copyA,hdd/copyB' 'hdd/wolne,hdd/taken' '' '')"; rc=$?
case "$out" in
    *"LAND "*) bad "fromcopy: ONE BAD PAIR STOPS THE WHOLE LIST BEFORE IT LANDS" "the good one landed anyway: $out" ;;
    *) ok "fromcopy: ONE BAD PAIR STOPS THE WHOLE LIST BEFORE IT LANDS" ;;
esac
case "$rc$out" in
    2*"1 of 2 pair(s)"*) ok "fromcopy: ...and says how many of how many" ;;
    *) bad "fromcopy: ...and says how many of how many" "rc=$rc" "$out" ;;
esac

# ---- a copy that is not there ----------------------------------------------
out="$(fc_run 'hdd/niema' 'hdd/wolne' '' '')"; rc=$?
case "$rc$out" in
    2*"no such dataset"*) ok "fromcopy: a copy location that does not exist is named as such" ;;
    *) bad "fromcopy: a copy location that does not exist is named as such" "rc=$rc" "$out" ;;
esac

# ---- a copy with no snapshots ----------------------------------------------
printf 'hdd/copyA\nhdd/copyB\nhdd/taken\nhdd/pusty\n' > "$FC/exists"
: > "$FC/rows.hdd_pusty"
out="$(fc_run 'hdd/pusty' 'hdd/wolne' '' '')"; rc=$?
case "$rc$out" in
    2*"no snapshot to restore from"*) ok "fromcopy: a copy with no snapshot refuses" ;;
    *) bad "fromcopy: a copy with no snapshot refuses" "rc=$rc" "$out" ;;
esac

# ---- --at resolves by creation, per copy -----------------------------------
# At epoch 2500 the only snapshot at-or-before is creation 2000, whose NAME is
# the newest-looking of the three. Name-based selection would pick a different
# one, so this pins the axis rather than the outcome.
out="$(fc_run 'hdd/copyA' 'hdd/wolne' '' '2500')"; rc=$?
case "$out" in
    *"@automated_2026-09-09_09-09-09 -> hdd/wolne"*) ok "fromcopy: --at takes the newest at-or-before BY CREATION" ;;
    *) bad "fromcopy: --at takes the newest at-or-before BY CREATION" "$out" ;;
esac
out="$(fc_run 'hdd/copyA' 'hdd/wolne' '' '500')"; rc=$?
case "$rc$out" in
    2*"at or before --at"*) ok "fromcopy: --at older than everything refuses rather than falling back to the newest" ;;
    *) bad "fromcopy: --at older than everything refuses rather than falling back to the newest" "rc=$rc" "$out" ;;
esac

# ---- a TIE on the newest creation refuses rather than picking by list order --
# REV-20260814-121's rule, applied to this form's default: the name is not a
# tie-breaker, and whichever row `zfs list` printed last is not a decision.
printf 'hdd/copyA\nhdd/copyB\nhdd/taken\nhdd/pusty\nhdd/remis\n' > "$FC/exists"
printf 'hdd/remis@a\t2000\t61\nhdd/remis@b\t2000\t62\n' > "$FC/rows.hdd_remis"
out="$(fc_run 'hdd/remis' 'hdd/wolne' '' '')"; rc=$?
case "$rc$out" in
    2*"tie"*) ok "fromcopy: a tie on the newest creation refuses, it does not pick by list order" ;;
    *) bad "fromcopy: a tie on the newest creation refuses, it does not pick by list order" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"LAND "*) bad "fromcopy: ...and creates nothing while refusing" "$out" ;;
    *) ok "fromcopy: ...and creates nothing while refusing" ;;
esac

# ---- --snapshot over a list is refused -------------------------------------
out="$(fc_run 'hdd/copyA,hdd/copyB' 'hdd/w1,hdd/w2' 's2' '')" && \
    bad "fromcopy: --snapshot over several copies refuses" "it accepted one name for two copies" || \
    case "$out" in
        *"not one atomic event"*) ok "fromcopy: --snapshot over several copies refuses" ;;
        *) bad "fromcopy: --snapshot over several copies refuses" "$out" ;;
    esac

# ---- two copies may not land on one destination ----------------------------
out="$(fc_run 'hdd/copyA,hdd/copyB' 'hdd/w1,hdd/w1' '' '')" && \
    bad "fromcopy: two copies may not land on one destination" "it accepted a duplicate" || \
    case "$out" in
        *"twice"*) ok "fromcopy: two copies may not land on one destination" ;;
        *) bad "fromcopy: two copies may not land on one destination" "$out" ;;
    esac

# ---- CHILDREN COME ALONG ---------------------------------------------------
# Found on the LAB, on this function the hour it shipped: naming a parent
# restored the parent alone and printed "Odtworzenie OK" while the two disks
# under it were silently absent. A success reported over an incomplete recovery
# is the worst thing this verb can do.
printf 'hdd/rodzic
hdd/rodzic/d0
hdd/rodzic/d1
hdd/copyA
hdd/copyB
hdd/taken
hdd/pusty
hdd/remis
' > "$FC/exists"
printf 'hdd/rodzic@s	1000	70
'    > "$FC/rows.hdd_rodzic"
printf 'hdd/rodzic/d0@s	1000	71
' > "$FC/rows.hdd_rodzic_d0"
printf 'hdd/rodzic/d1@s	1000	72
' > "$FC/rows.hdd_rodzic_d1"
out="$(fc_run 'hdd/rodzic' 'hdd/cel' '' '')"; rc=$?
n=0
for x in "hdd/rodzic@s -> hdd/cel" "hdd/rodzic/d0@s -> hdd/cel/d0" "hdd/rodzic/d1@s -> hdd/cel/d1"; do
    case "$out" in *"LAND $x"*) n=$((n+1)) ;; esac
done
if [ "$n" -eq 3 ]; then ok "children: NAMING A PARENT BRINGS ITS CHILDREN, each at the same relative position"
else bad "children: NAMING A PARENT BRINGS ITS CHILDREN, each at the same relative position" "landed $n of 3" "$out"; fi
case "$rc" in
    0) ok "children: ...and the run succeeds" ;;
    *) bad "children: ...and the run succeeds" "rc=$rc" "$out" ;;
esac
# The preview has to name them too: a confirmation that does not list what will
# be created is not the confirmation this contract means.
n=0
for x in hdd/cel hdd/cel/d0 hdd/cel/d1; do case "$out" in *"->  $x"*) n=$((n+1)) ;; esac; done
if [ "$n" -eq 3 ]; then ok "children: ...and every one of them is in the preview, before the question"
else bad "children: ...and every one of them is in the preview, before the question" "named $n of 3" "$out"; fi
# An occupied child destination refuses the WHOLE thing, like any other bad pair.
printf 'hdd/rodzic
hdd/rodzic/d0
hdd/rodzic/d1
hdd/cel2/d1
hdd/copyA
hdd/copyB
hdd/taken
hdd/pusty
hdd/remis
' > "$FC/exists"
out="$(fc_run 'hdd/rodzic' 'hdd/cel2' '' '')"; rc=$?
case "$out" in
    *"LAND "*) bad "children: an occupied CHILD destination refuses before anything lands" "$out" ;;
    *) ok "children: an occupied CHILD destination refuses before anything lands" ;;
esac

# ---- THE STAGING NAMESPACE, for a landing OUTSIDE <pool>/restore ------------
# Found on the lab, not here (2026-08-31): the landing half creates the LANDING's
# parent, and a relationship-addressed restore lands INSIDE <pool>/restore/... --
# so the staging namespace came along as an ancestor and nobody noticed it was
# never asked for. `--from-copy --onto hdd/odzysk0` lands elsewhere and the
# receive failed with `cannot open 'hdd/restore'`, after the preview and after
# the confirmation.
#
# This drives the REAL restore_safe_land, unstubbed, because the whole point is a
# coupling BETWEEN the two halves -- stubbing either one hides it.
fc_land() {   # <landing> -> the zfs calls, in order
    local landing="$1"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'FC=%q
' "$FC"
        echo 'die() { printf "FATAL: %s
" "$*" >&2; exit 1; }'
        echo 'warn() { printf "!!! %s
" "$*" >&2; }'
        cat <<'LSTUB'
zfs() {
    printf 'ZFS %s
' "$*" >> "$FC/calls"
    case "$1 $2" in
        "list -H")
            local d="${!#}"
            grep -qFx -- "$d" "$FC/exists" 2>/dev/null || return 1
            printf '%s
' "$d"; return 0 ;;
        "get -H") printf '%s
' 77; return 0 ;;
        "send "*) return 0 ;;
    esac
    return 0
}
LSTUB
        awk -v want="restore_safe_land() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'restore_safe_land %q %q %q %q 1
' "hdd/copyA" "s1" "$landing" "hdd/copyA"
    } > "$t"
    : > "$FC/calls"
    bash "$t" >/dev/null 2>&1
    rm -f "$t"
    cat "$FC/calls"
}

calls="$(fc_land hdd/odzysk0)"
case "$calls" in
    *"ZFS create -p hdd/restore"*) ok "staging: the staging namespace is created for a landing OUTSIDE <pool>/restore" ;;
    *) bad "staging: the staging namespace is created for a landing OUTSIDE <pool>/restore" "$calls" ;;
esac
# ...and before the receive, or the receive is the thing that discovers it.
case "$calls" in
    *"create -p hdd/restore"*"recv"*) ok "staging: ...before the receive, not discovered by it" ;;
    *) bad "staging: ...before the receive, not discovered by it" "$calls" ;;
esac

if [ "${_fc_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
