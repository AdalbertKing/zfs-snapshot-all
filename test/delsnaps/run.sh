#!/bin/bash
# Integration tests for delsnaps.sh, run against a REAL, throwaway ZFS pool
# backed by a sparse file.
#
# Why a real pool instead of a mocked `zfs` binary: the failure mode that
# actually costs data here is "delsnaps built a destroy command that removed
# more than it should have". A mock only proves the script called what the mock
# expected -- it re-asserts the implementation, not the outcome. Creating real
# snapshots and then checking WHICH ONES SURVIVED tests the thing we care about.
#
# Requires: root + zfs (so: run this on a PVE host, not the dev machine).
#
# SAFETY -- this suite never touches anything outside the pool it creates:
#   - the pool name carries this shell's PID and the run aborts if a pool by
#     that name somehow already exists;
#   - every delsnaps.sh invocation is scoped to "$POOL/...";
#   - STATS_LOG and LOCKDIR are redirected into a temp dir, so a test run leaves
#     production's /root/scripts/zfs-snapshot-stats.log and /var/run untouched;
#   - an EXIT trap destroys the pool and removes the backing file even if a
#     test fails midway.
#
# Usage: ./run.sh            (from anywhere; paths are resolved relative to it)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Defaults to the delsnaps.sh two levels up (the repo root). Override with
# DELSNAPS=/path/to/delsnaps.sh to test a copy staged somewhere else.
DELSNAPS="${DELSNAPS:-$(cd "$SCRIPT_DIR/../.." && pwd)/delsnaps.sh}"

[ -x "$DELSNAPS" ] || { echo "cannot find executable delsnaps.sh at $DELSNAPS" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root (creates a zpool)" >&2; exit 1; }
command -v zpool >/dev/null || { echo "zpool not found -- run this on a host with ZFS" >&2; exit 1; }

POOL="delsnaptest$$"
TMPD="$(mktemp -d)"
IMG="$TMPD/pool.img"

zpool list -H -o name 2>/dev/null | grep -qx "$POOL" && {
    echo "refusing to run: a pool named '$POOL' already exists" >&2; exit 1; }

cleanup() {
    zpool destroy -f "$POOL" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

truncate -s 256M "$IMG"
# mountpoint=none: nothing from this pool ever appears in the filesystem tree,
# which keeps the test invisible to the host and lets clones be destroyed
# without an unmount step.
zpool create -f -m none "$POOL" "$IMG" || { echo "zpool create failed" >&2; exit 1; }

# delsnaps.sh writes stats and takes a flock; point both at the temp dir so a
# test run cannot pollute or block production.
export STATS_LOG="$TMPD/stats.log"
export LOCKDIR="$TMPD"

PASS=0
FAIL=0

# --- helpers ----------------------------------------------------------------

# mkds <name...> -- create datasets under the test pool.
mkds() {
    local d
    for d in "$@"; do zfs create -p "$POOL/$d" || exit 1; done
}

# mksnaps <dataset> <snapname...> -- create snapshots in the given order.
#
# The 1s sleep is not padding: delsnaps.sh orders candidates with
# `zfs list -s creation`, and the creation property has one-second resolution.
# Snapshots made inside the same second would sort ambiguously and make
# count-mode assertions flaky for reasons that have nothing to do with the code
# under test.
mksnaps() {
    local ds="$1"; shift
    local first=1 s
    for s in "$@"; do
        [ "$first" -eq 1 ] || sleep 1
        first=0
        zfs snapshot "$POOL/$ds@$s" || exit 1
    done
}

# snaps_of <dataset> -- surviving snapshot names, oldest first, space separated.
snaps_of() {
    zfs list -H -o name -s creation -t snapshot "$POOL/$1" 2>/dev/null \
        | sed 's/.*@//' | tr '\n' ' ' | sed 's/ $//'
}

# check <label> <expected> <actual>
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL $label"
        echo "     expected: [$expected]"
        echo "     actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# run_del <args...> -- invoke delsnaps.sh quietly, remember its exit code.
RC=0
run_del() {
    "$DELSNAPS" "$@" >/dev/null 2>&1
    RC=$?
}

echo "=== delsnaps.sh integration tests (pool: $POOL) ==="

# --- count mode -------------------------------------------------------------

mkds keepn
mksnaps keepn auto_1 auto_2 auto_3 auto_4 auto_5
run_del "$POOL/keepn" "auto_" -H3
check "count: keeps the 3 newest, deletes the 2 oldest" \
      "auto_3 auto_4 auto_5" "$(snaps_of keepn)"
check "count: exit code 0 on success" "0" "$RC"

mkds keepall
mksnaps keepall auto_1 auto_2
run_del "$POOL/keepall" "auto_" -H10
check "count: keep-count above total deletes nothing" \
      "auto_1 auto_2" "$(snaps_of keepall)"

mkds keepzero
mksnaps keepzero auto_1 auto_2
run_del "$POOL/keepzero" "auto_" -H0
check "count: keep 0 deletes every match" "" "$(snaps_of keepzero)"

# Retention flags are slots that SUM into one keep-count -- -D1 -H2 means keep
# 3, not "1 daily and 2 hourly". Worth pinning: reading them as independent
# per-tier budgets is the obvious wrong assumption.
mkds sumslots
mksnaps sumslots auto_1 auto_2 auto_3 auto_4 auto_5
run_del "$POOL/sumslots" "auto_" -D1 -H2
check "count: -D1 -H2 sums to keep 3" \
      "auto_3 auto_4 auto_5" "$(snaps_of sumslots)"

# --- pattern matching -------------------------------------------------------

mkds patt
mksnaps patt auto_1 manual_1 auto_2 manual_2 auto_3
run_del "$POOL/patt" "auto_" -H1
check "pattern: non-matching snapshots are never candidates" \
      "manual_1 manual_2 auto_3" "$(snaps_of patt)"

# delsnaps matches by literal string PREFIX, so a short pattern silently
# swallows every longer tier that starts with it. This is the exact behaviour
# gen-cron.sh's same-scope overlap check exists to prevent in generated configs.
mkds prefix
mksnaps prefix automated_hourly_1 automated_daily_1 automated_hourly_2
run_del "$POOL/prefix" "automated_" -H1
check "pattern: is a prefix match, so 'automated_' also eats 'automated_daily_'" \
      "automated_hourly_2" "$(snaps_of prefix)"

# --- Proxmox-reserved snapshots (the guard that protects pvesr) --------------

# These must survive even though the pattern matches them: pruning one out from
# under pvesr/migration/vzdump breaks the replication chain irreparably.
mkds protected
mksnaps protected __replicate_101-0_1 __migration__1 vzdump_1 auto_1 auto_2
run_del "$POOL/protected" "" -H0
check "protected: __replicate_/__migration__/vzdump survive an empty pattern + keep 0" \
      "__replicate_101-0_1 __migration__1 vzdump_1" "$(snaps_of protected)"

# --- dry run ----------------------------------------------------------------

mkds dry
mksnaps dry auto_1 auto_2 auto_3
run_del -n "$POOL/dry" "auto_" -H1
check "dry-run: destroys nothing" "auto_1 auto_2 auto_3" "$(snaps_of dry)"
check "dry-run: exit code 0" "0" "$RC"

# --- recursion --------------------------------------------------------------

# -R must apply the rule to each dataset SEPARATELY (every child keeps its own
# newest N), not pool the snapshots and keep N across the whole subtree.
mkds tree tree/a tree/b
mksnaps tree auto_p1 auto_p2 auto_p3
mksnaps tree/a auto_a1 auto_a2 auto_a3
mksnaps tree/b auto_b1 auto_b2 auto_b3
run_del -R "$POOL/tree" "auto_" -H2
check "recursive: parent keeps its own newest 2" "auto_p2 auto_p3" "$(snaps_of tree)"
check "recursive: child a keeps its own newest 2" "auto_a2 auto_a3" "$(snaps_of tree/a)"
check "recursive: child b keeps its own newest 2" "auto_b2 auto_b3" "$(snaps_of tree/b)"

mkds tree2 tree2/a
mksnaps tree2 auto_p1 auto_p2 auto_p3
mksnaps tree2/a auto_a1 auto_a2 auto_a3
run_del "$POOL/tree2" "auto_" -H1
check "non-recursive: parent pruned" "auto_p3" "$(snaps_of tree2)"
check "non-recursive: child left completely untouched" \
      "auto_a1 auto_a2 auto_a3" "$(snaps_of tree2/a)"

# --- age mode ---------------------------------------------------------------

# Age mode can only be exercised at its boundaries here: snapshot creation
# times cannot be backdated on a real pool. -h1 puts the threshold an hour in
# the past (nothing is that old yet), -h0 puts it at "now" (everything just
# created is older).
mkds age
mksnaps age auto_1 auto_2
run_del "$POOL/age" "auto_" -h1
check "age: threshold in the past deletes nothing" "auto_1 auto_2" "$(snaps_of age)"

# The comparison is strict (creation < threshold), so a snapshot taken in the
# same second as the threshold survives. Sleep past that boundary before
# asserting, otherwise the newest snapshot's fate depends on how fast the
# preceding run finished.
sleep 2
run_del "$POOL/age" "auto_" -h0
check "age: threshold at now deletes everything strictly older" "" "$(snaps_of age)"

# --- mode mixing is rejected ------------------------------------------------

mkds mixed
mksnaps mixed auto_1 auto_2 auto_3
run_del "$POOL/mixed" "auto_" -H1 -d7
check "mixing age and count flags exits 1" "1" "$RC"
check "mixing age and count flags destroys nothing" \
      "auto_1 auto_2 auto_3" "$(snaps_of mixed)"

# --- clone dependency guard -------------------------------------------------

# A plain `zfs destroy` refuses a snapshot that has a dependent clone (a
# Proxmox linked clone is exactly this). delsnaps must report the failure and
# exit non-zero rather than reaching for -R and taking the clone down with it.
mkds cloned
mksnaps cloned auto_1 auto_2
zfs clone "$POOL/cloned@auto_1" "$POOL/theclone" || exit 1
run_del "$POOL/cloned" "auto_" -H1
check "clone guard: cloned snapshot survives a plain destroy" \
      "auto_1 auto_2" "$(snaps_of cloned)"
check "clone guard: failure is reported as exit 1" "1" "$RC"

# -F is the documented opt-out and must actually cascade.
run_del -F "$POOL/cloned" "auto_" -H1
check "clear-cut: -F removes the cloned snapshot" "auto_2" "$(snaps_of cloned)"

# --- local dataset names containing ':' -------------------------------------

# ZFS allows ':' in dataset names, so "remote" cannot simply mean "has a
# colon". A local name like pool/data:backup must NOT be mistaken for an ssh
# target -- if it were, delsnaps would try to reach a host named "$POOL" and
# silently prune nothing.
zfs create -p "$POOL/data:backup" || exit 1
mksnaps "data:backup" auto_1 auto_2 auto_3
run_del "$POOL/data:backup" "auto_" -H1
check "colon in a local dataset name is not treated as a remote host" \
      "auto_3" "$(snaps_of "data:backup")"

# --- no matches is not an error ---------------------------------------------

mkds nomatch
mksnaps nomatch manual_1
run_del "$POOL/nomatch" "auto_" -H1
check "no matching snapshots leaves them alone" "manual_1" "$(snaps_of nomatch)"
check "no matching snapshots is exit 0, not an error" "0" "$RC"

# --- summary ----------------------------------------------------------------

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
