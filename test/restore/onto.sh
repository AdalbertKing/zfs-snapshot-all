#!/bin/bash
# `--onto`: where a cross-host recovery LANDS, and the arithmetic behind it.
#
#   ./test/restore/onto.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/onto.sh    # negative control
#
# Sourced by test/restore/run.sh. Separate file for the same reason as
# relpolicy.sh and records.sh -- a control has to run these against a mutated
# tree in seconds, not in the ten minutes the battery costs on the implementer's
# box.
#
# Owner decision 2026-08-30. The relationship name stands alone, the datasets
# arrive through --source/--target, and the destination PATHS arrive through
# --onto. The retired `label:dataset` spelling is what this replaces: ':' is
# legal inside a ZFS dataset name, and that ambiguity was not theoretical --
# a legal copy location `.../pool/data:archive` was split at the first colon and
# refused while sitting in CONFIG (#132).

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _onto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_onto_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _onto_standalone=1
fi

# ---------------------------------------------------------------------------
# THE COMMON ROOT, AT NAME BOUNDARIES
#
# `rpool/data/vm-101` and `rpool/data/vm-1010` share `rpool/data`, NOT
# `rpool/data/vm-101`. A character-wise prefix would rebase the second one under
# a path assembled out of half of the first one's name -- which is a legal ZFS
# name, so nothing downstream would object and the data would simply arrive
# somewhere nobody chose.
onto_root() {   # <path>... -> the common root, or empty with status 1
    local t; t=$(mktemp)
    {
        echo 'set -u'
        awk -v want="restore_common_root() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'restore_common_root'
        local p; for p in "$@"; do printf ' %q' "$p"; done
        printf '\n'
    } > "$t"
    bash "$t" 2>/dev/null
    local rc=$?
    rm -f "$t"
    return "$rc"
}

r="$(onto_root rpool/data/vm-101-disk-0 rpool/data/vm-101-disk-1)"
if [ "$r" = "rpool/data" ]; then ok "root: four disks of one VM share their parent"
else bad "root: four disks of one VM share their parent" "got '$r'"; fi

# THE CARRYING ASSERTION. This is the one a character-wise prefix fails.
r="$(onto_root rpool/data/vm-101 rpool/data/vm-1010)"
if [ "$r" = "rpool/data" ]; then ok "root: A PREFIX IS TAKEN AT NAME BOUNDARIES, NOT MID-NAME"
else bad "root: A PREFIX IS TAKEN AT NAME BOUNDARIES, NOT MID-NAME" "got '$r' -- 'rpool/data/vm-101' means it cut inside a name"; fi

r="$(onto_root rpool/data rpool/data)"
if [ "$r" = "rpool/data" ]; then ok "root: one path is its own root"
else bad "root: one path is its own root" "got '$r'"; fi

r="$(onto_root rpool/data/x rpool/data)"
if [ "$r" = "rpool/data" ]; then ok "root: a parent and its child root at the parent"
else bad "root: a parent and its child root at the parent" "got '$r'"; fi

# Nothing in common is not a root of "" -- it is a refusal, because "rebase the
# relationship here" has no single meaning for roots in different pools.
if onto_root rpool/a hdd/b >/dev/null 2>&1; then
    bad "root: roots with nothing in common REFUSE rather than resolving to nothing"
else ok "root: roots with nothing in common REFUSE rather than resolving to nothing"; fi

# ---------------------------------------------------------------------------
# THE PAIRS
onto_plan() {   # <onto list> <from root>... -> "from|to" per line
    local list="$1"; shift
    local t; t=$(mktemp)
    {
        echo 'set -u'
        echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        echo 'RESTORE_ONTO_FROM=(); RESTORE_ONTO_TO=()'
        awk -v want="restore_common_root() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        awk -v want="restore_onto_plan() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'restore_onto_plan %q' "$list"
        local p; for p in "$@"; do printf ' %q' "$p"; done
        printf '\n'
        echo 'for ((i=0;i<${#RESTORE_ONTO_FROM[@]};i++)); do printf "%s|%s\n" "${RESTORE_ONTO_FROM[$i]}" "${RESTORE_ONTO_TO[$i]}"; done'
    } > "$t"
    bash "$t" 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

out="$(onto_plan 'hdd/data' rpool/data/vm-900-disk-0 rpool/data/vm-900-disk-1)"
if [ "$out" = "rpool/data|hdd/data" ]; then ok "plan: one --onto over a whole relationship rebases from the common root"
else bad "plan: one --onto over a whole relationship rebases from the common root" "$out"; fi

out="$(onto_plan 'hdd/a,hdd/b' rpool/x rpool/y)"
want="rpool/x|hdd/a
rpool/y|hdd/b"
if [ "$out" = "$want" ]; then ok "plan: two lists of equal length pair up positionally"
else bad "plan: two lists of equal length pair up positionally" "$out"; fi

# Never zip-to-shortest and never repeat: either would recover fewer datasets
# than the operator named, silently.
if onto_plan 'hdd/a' rpool/x rpool/y rpool/z >/dev/null 2>&1; then
    : # one onto over several roots is the whole-relationship form, allowed
fi
out="$(onto_plan 'hdd/a,hdd/b' rpool/x rpool/y rpool/z 2>&1)" && \
    bad "plan: mismatched list lengths refuse" "it accepted 2 against 3" || \
    case "$out" in
        *"same length"*) ok "plan: mismatched list lengths refuse" ;;
        *) bad "plan: mismatched list lengths refuse" "$out" ;;
    esac

out="$(onto_plan 'hdd/a,hdd/a' rpool/x rpool/y 2>&1)" && \
    bad "plan: two datasets may not land on one" "it accepted a duplicate destination" || \
    case "$out" in
        *"twice"*) ok "plan: two datasets may not land on one" ;;
        *) bad "plan: two datasets may not land on one" "$out" ;;
    esac

out="$(onto_plan 'hdd/a,,hdd/b' rpool/x rpool/y rpool/z 2>&1)" && \
    bad "plan: a stray comma refuses rather than shifting every pair" "it accepted an empty entry" || \
    case "$out" in
        *"empty entry"*) ok "plan: a stray comma refuses rather than shifting every pair" ;;
        *) bad "plan: a stray comma refuses rather than shifting every pair" "$out" ;;
    esac

out="$(onto_plan 'hdd/data' rpool/a hdd/b 2>&1)" && \
    bad "plan: a relationship with no common root refuses and names them" "it invented a base" || \
    case "$out" in
        *"share no common root"*rpool/a*) ok "plan: a relationship with no common root refuses and names them" ;;
        *) bad "plan: a relationship with no common root refuses and names them" "$out" ;;
    esac

# ---------------------------------------------------------------------------
# THE MAPPING: children keep their relative position
onto_dest() {   # <onto list> <from root>... ; scope in RESTORE_SCOPE_SRC via $SRCS
    local list="$1"; shift
    local t; t=$(mktemp)
    {
        echo 'set -u'
        echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        echo 'RESTORE_ONTO_FROM=(); RESTORE_ONTO_TO=(); RESTORE_SCOPE_DEST=()'
        echo 'RESTORE_DEST_PEER=acct@peer'
        printf 'RESTORE_SCOPE_SRC=('
        local p; for p in $SRCS; do printf '%q ' "$p"; done
        printf ')\n'
        awk -v want="restore_common_root() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        awk -v want="restore_onto_plan() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        awk -v want="restore_scope_dest() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'restore_onto_plan %q' "$list"
        for p in "$@"; do printf ' %q' "$p"; done
        printf '\n'
        echo 'restore_scope_dest /dev/null "" onto-relation'
        echo 'printf "%s\n" ${RESTORE_SCOPE_DEST[@]+"${RESTORE_SCOPE_DEST[@]}"}'
    } > "$t"
    bash "$t" 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

SRCS="rpool/data rpool/data/vm-900-disk-0 rpool/data/vm-900-disk-1"
out="$(onto_dest 'hdd/store' rpool/data)"
want="acct@peer:hdd/store
acct@peer:hdd/store/vm-900-disk-0
acct@peer:hdd/store/vm-900-disk-1"
if [ "$out" = "$want" ]; then ok "dest: children land under the new base at the same relative position"
else bad "dest: children land under the new base at the same relative position" "$out"; fi

# THE CARRYING ASSERTION FOR THE MAPPING: a selection may name a parent AND one
# of its children, each with its own destination. First-match would send the
# child to the parent's new home and leave the entry that named it unused.
SRCS="rpool/data rpool/data/vm-900-disk-0"
out="$(onto_dest 'hdd/store,hdd/elsewhere' rpool/data rpool/data/vm-900-disk-0)"
want="acct@peer:hdd/store
acct@peer:hdd/elsewhere"
if [ "$out" = "$want" ]; then ok "dest: THE LONGEST MATCH WINS, so a child named explicitly keeps its own destination"
else bad "dest: THE LONGEST MATCH WINS, so a child named explicitly keeps its own destination" "$out"; fi

# Without --onto nothing is rebased: the source path is kept verbatim. This is
# the form the 2026-08-28 two-host campaign ran, and it must not change.
SRCS="rpool/data rpool/data/vm-900-disk-0"
t=$(mktemp)
{
    echo 'set -u'
    echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
    echo 'RESTORE_ONTO_FROM=(); RESTORE_ONTO_TO=(); RESTORE_SCOPE_DEST=()'
    echo 'RESTORE_DEST_PEER=acct@peer'
    echo 'RESTORE_SCOPE_SRC=(rpool/data rpool/data/vm-900-disk-0)'
    awk -v want="restore_scope_dest() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
    echo 'restore_scope_dest /dev/null "" onto-relation'
    echo 'printf "%s\n" ${RESTORE_SCOPE_DEST[@]+"${RESTORE_SCOPE_DEST[@]}"}'
} > "$t"
plain="$(bash "$t" 2>&1)"; rm -f "$t"
want="acct@peer:rpool/data
acct@peer:rpool/data/vm-900-disk-0"
if [ "$plain" = "$want" ]; then ok "dest: with no --onto the source paths are kept, unchanged from the campaign form"
else bad "dest: with no --onto the source paths are kept, unchanged from the campaign form" "$plain"; fi

# ---- THE FIXTURE THAT WAS MISSING: a relationship's datasets carry a prefix ---
# `account@host:dataset`, not a bare path. Every case above used bare paths --
# which is what a fixture reaches for and not what a relationship holds -- and
# the whole feature refused every dataset on the lab because the roots kept the
# prefix while the paths compared against them had it stripped. The refusal even
# printed the same string on both sides of its own sentence.
SRCS="zfsbackup-pve9@192.168.28.9:hdd/labsrc zfsbackup-pve9@192.168.28.9:hdd/labsrc/vm-900-disk-0"
out="$(onto_dest 'hdd/odzysk' 'zfsbackup-pve9@192.168.28.9:hdd/labsrc')"
want="acct@peer:hdd/odzysk
acct@peer:hdd/odzysk/vm-900-disk-0"
if [ "$out" = "$want" ]; then ok "dest: A TRANSPORT-PREFIXED SOURCE STILL FINDS ITS REBASE ROOT"
else bad "dest: A TRANSPORT-PREFIXED SOURCE STILL FINDS ITS REBASE ROOT" "$out"; fi

if [ "${_onto_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
