#!/bin/bash
# Regression tests for the runnable expert examples in docs/examples/*.conf.
#
#   test/configexamples/run.sh
#
# docs/CONFIG-EXAMPLES.md presents docs/examples/*.conf as RUNNABLE artifacts:
# each is promised to render through the real gen-cron.sh, and operators are told
# they may copy and re-run them. That is a dependency edge --
#   gen-cron.sh grammar/rendering -> docs/examples/*.conf -> documented behavior
# -- so a generator/schema change or an edit to an example must re-test here
# (REV-20260810-094). No ZFS, no remote host: gen-cron.sh is a pure text tool.
#
# Two layers:
#   1. every docs/examples/*.conf must render (gen-cron.sh -c, exit 0). A new
#      example added without its own assertions is still held to "it parses".
#   2. each current example is pinned to the few SEMANTIC line properties it
#      exists to teach -- not just exit 0, so a change that renders but renders
#      the WRONG shape is caught (the REV-089/090 lesson: green exit is not proof
#      of the property).
#
# A negative control at the end mutates a runnable example and proves the
# semantic assertions would fail on drift, so a green run means something.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for a negative control against an older generator -- same idiom as
# test/run.sh's GEN and test/cron2conf/run.sh's C2C.
GEN="${GEN:-$DIR/../../gen-cron.sh}"
EXAMPLES="$DIR/../../docs/examples"

pass=0 fail=0

# Render a config with the same deterministic environment cron2conf's suite
# uses, so path/schedule defaults do not leak from the caller's shell.
render() {
    env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT \
        -u CRON_LOG -u DIGEST_SCHEDULE bash "$GEN" -c "$1" 2>&1
}

# assert_has HAYSTACK NEEDLE LABEL -- NEEDLE (extended regex) must appear.
assert_has() {
    if printf '%s\n' "$1" | grep -qE -- "$2"; then
        echo "PASS $3"; pass=$((pass+1)); return 0
    fi
    echo "FAIL $3 (expected to match: $2)"; fail=$((fail+1)); return 1
}
# assert_absent HAYSTACK NEEDLE LABEL -- NEEDLE must NOT appear.
assert_absent() {
    if printf '%s\n' "$1" | grep -qE -- "$2"; then
        echo "FAIL $3 (should not have matched: $2)"; fail=$((fail+1)); return 1
    fi
    echo "PASS $3"; pass=$((pass+1)); return 0
}
# count_matches HAYSTACK NEEDLE -> prints the number of matching lines.
count_matches() { printf '%s\n' "$1" | grep -cE -- "$2"; }

# ---- layer 1: every example renders cleanly ----
shopt -s nullglob
found=0
for cf in "$EXAMPLES"/*.conf; do
    found=$((found+1))
    name="$(basename "$cf" .conf)"
    out="$(render "$cf")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS renders/$name"; pass=$((pass+1))
    else
        echo "FAIL renders/$name (gen-cron.sh -c exited $rc)"; printf '  %s\n' "$out"
        fail=$((fail+1))
    fi
done
if [ "$found" -eq 0 ]; then
    echo "FAIL renders/* (no docs/examples/*.conf found -- suite subject is missing)"; fail=$((fail+1))
fi

# ---- layer 2: semantic properties each example teaches ----

# independent-tiers: two INDEPENDENT count-based prune tiers, NOT a GFS ladder.
r="$(render "$EXAMPLES/independent-tiers.conf")"
assert_has "$r" 'snapsend\.sh -m "automated_hourly_" -e "tank/vm-100-disk-0"'   'independent-tiers/hourly-send'
assert_has "$r" 'delsnaps\.sh "tank/vm-100-disk-0" "automated_hourly" -H24'      'independent-tiers/hourly-keep-24'
assert_has "$r" 'delsnaps\.sh "tank/vm-100-disk-0" "automated_daily" -D14'       'independent-tiers/daily-keep-14'
assert_absent "$r" 'delsnaps\.sh -G|gfs'                                          'independent-tiers/no-gfs-ladder'

# selective-quiesce: per-dataset -q, separated (not merged), plain dataset unchanged.
r="$(render "$EXAMPLES/selective-quiesce.conf")"
assert_has "$r" 'snapsend\.sh -m "automated_" -q agent "tank/vm-101-disk-0"'     'selective-quiesce/vm101-agent'
assert_has "$r" 'snapsend\.sh -m "automated_" -q sync "tank/subvol-102-disk-0"'  'selective-quiesce/ct102-sync'
assert_has "$r" 'snapsend\.sh -m "automated_" "tank/scratch"'                    'selective-quiesce/scratch-plain-send'
assert_absent "$r" 'tank/scratch" -q|-q [a-z]+ "tank/scratch'                    'selective-quiesce/scratch-no-quiesce'
# three distinct send lines: no merge across differing -q
[ "$(count_matches "$r" 'snapsend\.sh')" -eq 3 ] \
    && { echo "PASS selective-quiesce/three-separate-sends"; pass=$((pass+1)); } \
    || { echo "FAIL selective-quiesce/three-separate-sends (want 3 snapsend lines, got $(count_matches "$r" 'snapsend\.sh'))"; fail=$((fail+1)); }

# short-local-long-store: short local self-prune vs long store retention.
r="$(render "$EXAMPLES/short-local-long-store.conf")"
assert_has "$r" 'delsnaps\.sh "tank/akta" "automated_hourly" -H48'               'short-local/local-keep-48'
assert_has "$r" 'delsnaps\.sh -R "backup/kancelaria" "automated_daily" -D90'     'short-local/store-keep-90'

# manual-prune: recursive store prune, monitor-only carrier (no dup prune), bookmarks.
r="$(render "$EXAMPLES/manual-prune.conf")"
assert_has "$r" 'delsnaps\.sh -R "backup/store" "automated_hourly" -H72'         'manual-prune/hourly-72'
assert_has "$r" 'delsnaps\.sh -R "backup/store" "automated_weekly" -W12'         'manual-prune/weekly-12'
assert_has "$r" 'delsnaps\.sh -B "tank/akta" "tgt-" -d30'                        'manual-prune/bookmark-prune'
# the hot leaf is a MONITOR carrier only: a check line for it, but no second
# delsnaps line on backup/store/hot (that would race the recursive parent).
assert_has    "$r" 'check-snap-age\.sh "backup/store/hot" "automated_hourly"'    'manual-prune/hot-monitor-present'
assert_absent "$r" 'delsnaps\.sh[^\n]*"backup/store/hot"'                        'manual-prune/hot-no-duplicate-prune'

# ---- negative control: the semantic assertions must FAIL on drift ----
# Mutate a runnable example (keep 24 -> 99) and confirm the pinned assertion no
# longer holds. If this "expected FAIL" instead passed, the assertion is not
# actually discriminating and every green run above would be worthless.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed 's/keep           = 24/keep           = 99/' "$EXAMPLES/independent-tiers.conf" > "$tmp"
rmut="$(render "$tmp")"
if printf '%s\n' "$rmut" | grep -qE -- 'delsnaps\.sh "tank/vm-100-disk-0" "automated_hourly" -H24'; then
    echo "FAIL negctl/keep-drift-detected (mutated example still shows -H24 -- assertion is not discriminating)"
    fail=$((fail+1))
else
    echo "PASS negctl/keep-drift-detected (mutated example renders -H99, so the -H24 assertion would fail as intended)"
    pass=$((pass+1))
fi

echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
