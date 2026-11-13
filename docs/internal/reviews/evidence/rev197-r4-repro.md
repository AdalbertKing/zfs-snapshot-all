# REV-197 round 4 — Reviewer executable selection reproduction

Reviewer-owned evidence, 2026-11-13. Run from a full repository clone with Git and Bash (or set `REPO` to that clone). Copy the Bash block into a temporary script and run it. This extracts candidate selection code from the exact rejected and submitted SHAs; it stubs the snapshot inventory and ownership setter. It executes no ZFS, SSH, transfer, guest, or host operation. The final aggregate expression is copied from the engine's guard and is explicitly a reduced expression test, not a full end-to-end run.

Expected: ordinary foreign selection is repaired on the new candidate; both twins still return `skipped-success` for flat quiesce with own-window point absent and empty/wrong-family/excluded inventories. A mixed subtree's aggregate expression reports success. Those latter successes are the defect, so the reproduction exits 0 when it has reproduced them. A future regression test must assert safe refusal instead.

```bash
#!/usr/bin/env bash
set -u
repo="${REPO:-$(git rev-parse --show-toplevel)}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log() { printf 'log%d: %s\n' "$1" "$2" >&2; }
get_sorted_snapshots() { printf '%s\n' "$INVENTORY"; }
mark_source_owner() { :; }
select_case() {
 local engine=$1 rev=$2 name=$3 inv=$4 flat=$5 expected=$6 out rc
 printf 'select_impl() {\n' > "$tmp/selection"
 git -C "$repo" show "$rev:$engine" | awk '/^    local src_all=\(\)/ {p=1} /^    # A20:/ {exit} p {print}' >> "$tmp/selection"
 printf 'printf "selected=%%s\\n" "$snapshot"\n}\n' >> "$tmp/selection"
 source "$tmp/selection"
 INVENTORY=$inv
 FLAT_RECURSE=$flat
 ADOPT_SKIPPED=0
 ADOPT_EMPTY=0
 out=$(select_impl); rc=$?
 if [ "$rc" -ne 0 ]; then actual=refused; elif [ -z "$out" ]; then actual=skipped-success; else actual=${out#selected=tank@}; fi
 printf '%s %s %s => %s\n' "$engine" "$rev" "$name" "$actual"
 [ "$actual" = "$expected" ] || { printf 'expected %s rc=%s out=%s\n' "$expected" "$rc" "$out" >&2; exit 1; }
}
MESSAGE=rep_
SNAP_MESSAGE=rep_
RUN_SUFFIX=2026-11-12_01-00-00
own="${SNAP_MESSAGE}${RUN_SUFFIX}"
foreign=rep_2026-11-12_02-00-00
src_dataset=tank
tgt_dataset=medium
remote_user=''
remote_host=''
USE_EXISTING_SNAPSHOT=1
QUIESCE_SNAPPED=1
SOURCE_KEEP=1
EXCLUDE_SNAPS=()
for engine in snapget.sh snapsend.sh; do
 select_case "$engine" f350fe365005840e7f21005e860a7fff3a37a541 foreign-present "$own $foreign" 0 "$foreign"
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 foreign-present "$own $foreign" 0 "$own"
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 own-missing-foreign "$foreign" 0 refused
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 serial "$own" 0 "$own"
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 flat-own-missing-empty '' 1 skipped-success
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 flat-own-missing-other-family 'other_2026-11-12_00-00-00' 1 skipped-success
 EXCLUDE_SNAPS=(excluded_)
 select_case "$engine" be46158f37ec92932dfe96a6826189f9b041d943 flat-own-missing-excluded 'excluded_2026-11-12_00-00-00' 1 skipped-success
 EXCLUDE_SNAPS=()
done
printf 'PASS: extracted selection code matched all expectations\n'
# Aggregate expressions copied from each twin's end-of-run guard. One skipped
# successful member plus one transferred member leaves FAILED_DATASETS empty and
# ADOPT_SKIPPED < total, so the guard reports success despite the missing member.
DATASETS=(tank/parent tank/child)
FAILED_DATASETS=()
ADOPT_SKIPPED=1
ADOPT_EMPTY=1
if [ ${#FAILED_DATASETS[@]} -gt 0 ]; then aggregate=failed
elif [ $USE_EXISTING_SNAPSHOT -eq 1 ] && [ $FLAT_RECURSE -eq 1 ] && [ "$ADOPT_SKIPPED" -ge ${#DATASETS[@]} ] && [ "$ADOPT_EMPTY" -lt "$ADOPT_SKIPPED" ]; then aggregate=failed
else aggregate=success; fi
printf 'mixed subtree: one missing member, one transferred => aggregate=%s\n' "$aggregate"
[ "$aggregate" = success ] || exit 1
```

