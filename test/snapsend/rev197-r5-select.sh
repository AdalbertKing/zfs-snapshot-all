#!/usr/bin/env bash
# REV-20261112-197 round 5 (F1e): the Reviewer's selection reproduction
# (docs/internal/reviews/evidence/rev197-r4-repro.md), turned into a regression.
# It cuts the existing-snapshot selection out of both engines at a given SHA,
# stubs only the inventory and the owner stamp, and runs no ZFS, ssh or host
# operation -- so it runs anywhere, including the Windows box.
#
#   ./test/snapsend/rev197-r5-select.sh <sha>        expect the fixed contract
#   ./test/snapsend/rev197-r5-select.sh <sha> old    expect the rejected one (negative control)
#
# Exit 0 when every case matches the expectation for the chosen mode.
set -u
rev="${1:?usage: $0 <sha> [old]}"; mode="${2:-new}"
repo="$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
log() { :; }
get_sorted_snapshots() { printf '%s\n' "$INVENTORY"; }
mark_source_owner() { :; }
fails=0
select_case() {   # <engine> <name> <inventory> <flat> <expected-new> <expected-old>
    local engine=$1 name=$2 inv=$3 flat=$4 want out rc actual
    if [ "$mode" = old ]; then want=$6; else want=$5; fi
    printf 'select_impl() {\n' > "$tmp/sel"
    git -C "$repo" show "$rev:$engine" | awk '/^    local src_all=\(\)/ {p=1} /^    # A20:/ {exit} p {print}' >> "$tmp/sel"
    printf 'printf "selected=%%s\\n" "$snapshot"\n}\n' >> "$tmp/sel"
    # shellcheck disable=SC1090
    source "$tmp/sel"
    INVENTORY=$inv FLAT_RECURSE=$flat ADOPT_SKIPPED=0 ADOPT_EMPTY=0
    out=$(select_impl); rc=$?
    if [ "$rc" -ne 0 ]; then actual=refused; elif [ -z "$out" ]; then actual=skipped-success; else actual=${out#selected=tank@}; fi
    if [ "$actual" = "$want" ]; then printf 'PASS %s %s => %s\n' "$engine" "$name" "$actual"
    else printf 'FAIL %s %s => %s (expected %s)\n' "$engine" "$name" "$actual" "$want"; fails=$((fails+1)); fi
}
MESSAGE=rep_ SNAP_MESSAGE=rep_ RUN_SUFFIX=2026-11-12_01-00-00
own="${SNAP_MESSAGE}${RUN_SUFFIX}"; foreign=rep_2026-11-12_02-00-00
src_dataset=tank tgt_dataset=medium remote_user='' remote_host=''
USE_EXISTING_SNAPSHOT=1 QUIESCE_SNAPPED=1 SOURCE_KEEP=1
EXCLUDE_SNAPS=()
for engine in snapget.sh snapsend.sh; do
    select_case "$engine" foreign-present       "$own $foreign"  0 "$own"   "$own"
    select_case "$engine" own-missing-foreign   "$foreign"       0 refused  refused
    select_case "$engine" serial                "$own"           0 "$own"   "$own"
    select_case "$engine" flat-missing-empty    ''               1 refused  skipped-success
    select_case "$engine" flat-missing-other    'other_2026-11-12_00-00-00' 1 refused skipped-success
    EXCLUDE_SNAPS=(excluded_)
    select_case "$engine" flat-missing-excluded 'excluded_2026-11-12_00-00-00' 1 refused skipped-success
    EXCLUDE_SNAPS=(rep_)
    select_case "$engine" own-present-excluded  "$own"           1 refused  skipped-success
    EXCLUDE_SNAPS=()
    # Passive -e (no quiesce window): the Owner's 2026-11-07 distinction is unchanged.
    QUIESCE_SNAPPED=0
    select_case "$engine" passive-flat-empty    ''               1 skipped-success skipped-success
    select_case "$engine" passive-flat-other    'other_2026-11-12_00-00-00' 1 skipped-success skipped-success
    QUIESCE_SNAPPED=1
done
echo "fails=$fails (mode $mode, $rev)"
[ "$fails" -eq 0 ]
