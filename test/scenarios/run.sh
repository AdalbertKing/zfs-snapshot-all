#!/bin/bash
# Operational scenario tests -- whole workflows, not mechanisms.
#
# Every other suite in this repo tests a COMPONENT in isolation: does gen-cron
# emit the right string, does delsnaps keep the right count, does snapsend pick
# the right incremental base. All of them can pass while the actual operational
# chain is broken, because nothing exercises the HANDOFFS between them:
#
#     INI config -> gen-cron.sh -> a crontab line -> that line actually running
#                -> a snapshot -> a transfer -> retention pruning it later
#                -> a monitor noticing -> an alert carrying the reason
#
# These scenarios run that chain end to end on real ZFS, executing the
# generated cron lines VERBATIM rather than re-typing equivalent commands by
# hand -- which is the whole point: a hand-typed equivalent is a different
# thing from what cron will actually run, and the difference is where the bugs
# have historically been.
#
# Scenarios are derived from test/deps.conf's contracts and manual obligations,
# not invented: each one states which contract it exercises.
#
# Usage:  ./test/scenarios/run.sh [--parent <scratch-parent-dataset>]
#
# SAFETY: everything lives under <parent>/scen<PID>, refuses to start if that
# exists, and an EXIT trap destroys it even if a scenario fails partway. Needs
# root + zfs + mbuffer. Local-mode only -- the ssh path is test/remote/run.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
DELSNAPS="${DELSNAPS:-$REPO/delsnaps.sh}"
GENCRON="${GENCRON:-$REPO/gen-cron.sh}"
CHECKAGE="${CHECKAGE:-$REPO/check-snap-age.sh}"

PARENT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --parent) shift; PARENT="${1:-}" ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (creates datasets)" >&2; exit 1; }
command -v zfs     >/dev/null || { echo "zfs not found" >&2; exit 1; }
command -v mbuffer >/dev/null || { echo "mbuffer not found" >&2; exit 1; }
for f in "$SNAPSEND" "$DELSNAPS" "$GENCRON" "$CHECKAGE"; do
    [ -x "$f" ] || { echo "not executable: $f" >&2; exit 1; }
done

# Pick a scratch parent automatically if not told: prefer an existing dedicated
# test dataset, else the first pool. Never guesses a production path.
if [ -z "$PARENT" ]; then
    for cand in hdd/backuptest rpool hdd; do
        zfs list -H "$cand" >/dev/null 2>&1 && { PARENT="$cand"; break; }
    done
fi
[ -n "$PARENT" ] || { echo "no scratch parent found -- pass --parent" >&2; exit 1; }
zfs list -H "$PARENT" >/dev/null 2>&1 || { echo "no such dataset: $PARENT" >&2; exit 1; }

ROOT="$PARENT/scen$$"
zfs list -H "$ROOT" >/dev/null 2>&1 && { echo "refusing: $ROOT exists" >&2; exit 1; }

TMPD="$(mktemp -d)"
export STATS_LOG="$TMPD/stats.log"
export LOCKDIR="$TMPD"
# Alerts must land somewhere this test owns, never the host's real queue.
export ZFS_ALERT_QUEUE="$TMPD/alert-queue.log"
export ZFS_ALERT_CONF="$TMPD/zfs-alert.conf"
cat > "$ZFS_ALERT_CONF" <<EOF
ZFS_ALERT_MODE=daily
ZFS_WARN_MODE=daily
ZFS_ALERT_QUEUE=$TMPD/alert-queue.log
EOF

cleanup() {
    local s
    for s in $(zfs list -H -o name -t snapshot -r "$ROOT" 2>/dev/null); do
        zfs release zfssnapall_inflight "$s" 2>/dev/null
    done
    zfs destroy -R "$ROOT" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

PASS=0
FAIL=0
CURRENT_SCENARIO=""
scenario() { CURRENT_SCENARIO="$1"; echo; echo "=== SCENARIO: $1"; echo "    ($2)"; }
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS $label"; PASS=$((PASS + 1))
    else
        echo "  FAIL [$CURRENT_SCENARIO] $label"
        echo "       expected: [$expected]"
        echo "       actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# Count matching lines, robustly. `grep -c` prints "0" and exits 1 when a file
# exists with no match, but prints NOTHING and exits 2 when the file is absent
# -- so the obvious `$(grep -c ... || echo 0)` emits TWO values in the first
# case (a "0" from grep AND a "0" from the fallback), which silently breaks
# every assertion built on it.
countmatch() {
    local n
    n=$(grep -c "$1" "$2" 2>/dev/null) || n=0
    printf '%s' "${n:-0}"
}

# Total lines in a file that may not exist yet.
countlines() {
    [ -s "$1" ] || { printf '0'; return; }
    wc -l < "$1" | tr -d ' '
}

mk() { zfs create -o canmount=noauto "$1" 2>/dev/null; }
snaps_of()  { zfs list -H -o name -t snapshot -d1 "$1" 2>/dev/null | sed 's/.*@//' | sort | tr '\n' ' ' | sed 's/ $//'; }
count_of()  { zfs list -H -o name -t snapshot -d1 "$1" 2>/dev/null | wc -l; }
exists()    { zfs list -H "$1" >/dev/null 2>&1 && echo yes || echo no; }
guid_of()   { zfs get -H -o value guid "$1" 2>/dev/null; }

# Extract just the command part of a generated cron line (drop the 5 schedule
# fields), so the test can execute EXACTLY what cron would, wrapper and all.
cron_cmd() { sed -E 's/^([^ ]+ ){5}//'; }

mk "$ROOT" || { echo "cannot create $ROOT" >&2; exit 1; }
echo "=== operational scenarios (scratch: $ROOT)"

# An "aged" snapshot, taken FIRST so the rest of the run ages it for free.
# S2 needs one older than a warn threshold, and check-snap-age.sh's smallest
# unit is a minute (m/h/d -- seconds are deliberately not a valid unit), so
# something in this file has to be at least ~1 minute old. Taking it up front
# means S1's real work absorbs most of that wait instead of an idle sleep.
mk "$ROOT/aged"
zfs snapshot "$ROOT/aged@automated_hourly_1"
AGED_AT="$(date +%s)"

# ============================================================================
# S1. The full config -> crontab -> execution -> retention -> monitor chain.
#     Contracts: gen-cron-flags, monitor-exit-codes.
#     Never covered before: every suite stops at "the right string was emitted".
# ============================================================================
scenario "S1 config-to-cron-to-execution" \
         "contracts: gen-cron-flags, monitor-exit-codes"

SRC="$ROOT/s1src"
mk "$SRC"
mk "$SRC/child"

cat > "$TMPD/s1.conf" <<EOF
[defaults]
	host_label = scen
[template:hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	prune_schedule = 51 * * * *
	pattern        = automated_hourly_
	keep           = 3
	monitor_warn   = 90m
	monitor_crit   = 3h
[dataset:$SRC]
	use_template = hourly
	dst          = $ROOT/s1bk
EOF

REPO_DIR="$REPO" NOTIFY_SCRIPT="$TMPD/notify-fail.sh" WARN_SCRIPT="$TMPD/notify-warn.sh" \
DIGEST_SCRIPT="$TMPD/alert-digest.sh" CRON_LOG="$TMPD/cron.log" \
    "$GENCRON" -c "$TMPD/s1.conf" > "$TMPD/s1.cron" 2>"$TMPD/s1.err"
check "gen-cron produced a block" "0" "$?"

# Stand-in notify scripts: record what they were handed, including the detail
# argument, so the alert chain can be asserted without touching the host's own.
for n in notify-fail notify-warn; do
    cat > "$TMPD/$n.sh" <<EOF
#!/bin/bash
printf '%s\t%s\t%s\n' "$n" "\$1" "\$2" >> "$TMPD/alerts.log"
EOF
    chmod +x "$TMPD/$n.sh"
done

SEND_LINE="$(grep 'snapsend.sh' "$TMPD/s1.cron" | head -1 | cron_cmd)"
check "a send line was generated" "1" "$([ -n "$SEND_LINE" ] && echo 1 || echo 0)"

# Run the emitted line VERBATIM -- mktemp wrapper, redirections, notify call.
eval "$SEND_LINE"
check "the generated send line runs clean" "1" "$(count_of "$SRC")"
check "the target received it" "1" "$(count_of "$ROOT/s1bk/$SRC")"
check "no alert was raised on success" "0" "$(countlines "$TMPD/alerts.log")"

# Four more sends so retention has something to cut (keep=3).
for i in 2 3 4 5; do sleep 1; eval "$SEND_LINE"; done
check "five snapshots exist before pruning" "5" "$(count_of "$SRC")"

PRUNE_LINE="$(grep 'delsnaps.sh' "$TMPD/s1.cron" | head -1 | cron_cmd)"
eval "$PRUNE_LINE"
check "the generated prune line keeps exactly 'keep = 3'" "3" "$(count_of "$SRC")"
check "pruning raised no alert" "0" "$(countlines "$TMPD/alerts.log")"

# The monitor line, verbatim: a fresh snapshot must be OK (rc=0, no alert).
MON_LINE="$(grep 'check-snap-age.sh' "$TMPD/s1.cron" | head -1 | cron_cmd)"
eval "$MON_LINE"
check "monitor on a fresh snapshot raises nothing" "0" \
      "$(countlines "$TMPD/alerts.log")"

# ============================================================================
# S2. A monitor that FIRES, end to end, with the reason in the alert.
#     Contract: monitor-exit-codes. The rc=1/2/>=3 arms are a string emitted by
#     one file and interpreted by another; this runs all three for real.
# ============================================================================
scenario "S2 monitor fires and the alert carries the reason" \
         "contract: monitor-exit-codes"

: > "$TMPD/alerts.log"

# WARNING needs a snapshot genuinely older than the warn threshold, and the
# smallest valid unit is 1m -- so wait out whatever of that minute S1 did not
# already consume. Deterministic rather than timing-dependent: the assertion
# below is only reached once the snapshot really is old enough.
AGE_NEEDED=65
ELAPSED=$(( $(date +%s) - AGED_AT ))
if [ "$ELAPSED" -lt "$AGE_NEEDED" ]; then
    echo "    (waiting $(( AGE_NEEDED - ELAPSED ))s for the aged snapshot to cross 1m)"
    sleep $(( AGE_NEEDED - ELAPSED ))
fi
MON_WARN="$("$CHECKAGE" "$ROOT/aged" automated_hourly_ 1m 999h 2>&1; echo "rc=$?")"
check "check-snap-age exits 1 (WARNING) past warn threshold" "1" \
      "$(printf '%s' "$MON_WARN" | sed -n 's/^rc=//p')"

# CRITICAL without any waiting: a dataset that exists but has NO snapshot
# matching the pattern is critical by definition, which is also the more
# operationally interesting case (a backup job that silently stopped running).
MON_CRIT="$("$CHECKAGE" "$ROOT" automated_hourly_ 90m 3h 2>&1; echo "rc=$?")"
check "check-snap-age exits 2 (CRITICAL) when no snapshot matches at all" "2" \
      "$(printf '%s' "$MON_CRIT" | sed -n 's/^rc=//p')"

MON_UNK="$("$CHECKAGE" "$ROOT/does-not-exist" automated_hourly_ 90m 3h 2>&1; echo "rc=$?")"
check "check-snap-age exits 3 (UNKNOWN) on a missing dataset" "3" \
      "$(printf '%s' "$MON_UNK" | sed -n 's/^rc=//p')"

# Now the emitted cron idiom itself, with a threshold that forces WARNING:
# proves the rc arms in the generated string route to the right script AND
# that the verdict text travels as the second argument.
cat > "$TMPD/s2.conf" <<EOF
[defaults]
	host_label = scen
[template:hourly]
	prune_schedule = 51 * * * *
	pattern        = automated_hourly_
	keep           = 3
	monitor_warn   = 1m
	monitor_crit   = 999h
[prune:$ROOT/aged]
	use_template = hourly
	prune        = no
	notify       = s2
EOF
REPO_DIR="$REPO" NOTIFY_SCRIPT="$TMPD/notify-fail.sh" WARN_SCRIPT="$TMPD/notify-warn.sh" \
DIGEST_SCRIPT="$TMPD/alert-digest.sh" CRON_LOG="$TMPD/cron.log" \
    "$GENCRON" -c "$TMPD/s2.conf" > "$TMPD/s2.cron" 2>/dev/null
MON2="$(grep 'check-snap-age.sh' "$TMPD/s2.cron" | head -1 | cron_cmd)"
: > "$TMPD/alerts.log"
eval "$MON2"
check "the WARN arm fired exactly once" "1" \
      "$(countmatch '^notify-warn' "$TMPD/alerts.log")"
check "the ALERT arm did NOT fire" "0" \
      "$(countmatch '^notify-fail' "$TMPD/alerts.log")"
check "the alert carried the verdict text, not just a label" "1" \
      "$([ "$(countmatch 'dataset=' "$TMPD/alerts.log")" -gt 0 ] && echo 1 || echo 0)"

# ============================================================================
# S3. A failing job reports the REASON, not just its config label.
#     Contract: notify-markers (the detail-carrying chain).
# ============================================================================
scenario "S3 a failing job's own output reaches the alert" \
         "contract: notify-markers"

cat > "$TMPD/s3.conf" <<EOF
[defaults]
	host_label = scen
[template:hourly]
	send_schedule = 1 * * * *
	prefix        = automated_hourly_
[dataset:$ROOT/does-not-exist]
	use_template = hourly
	dst          = $ROOT/s3bk
EOF
REPO_DIR="$REPO" NOTIFY_SCRIPT="$TMPD/notify-fail.sh" WARN_SCRIPT="$TMPD/notify-warn.sh" \
DIGEST_SCRIPT="$TMPD/alert-digest.sh" CRON_LOG="$TMPD/cron.log" \
    "$GENCRON" -c "$TMPD/s3.conf" > "$TMPD/s3.cron" 2>/dev/null
FAIL_LINE="$(grep 'snapsend.sh' "$TMPD/s3.cron" | head -1 | cron_cmd)"
: > "$TMPD/alerts.log"
eval "$FAIL_LINE"
check "the failing job raised exactly one alert" "1" \
      "$(countmatch '^notify-fail' "$TMPD/alerts.log")"
check "the alert's detail field is non-empty" "1" \
      "$(awk -F'\t' 'NF>=3 && $3!=""' "$TMPD/alerts.log" 2>/dev/null | wc -l)"
# Presence, not a line count: the detail is deliberately multi-line (a failing
# job's last 8 stderr lines), so `grep -c` counts every matching line and
# asserting "exactly 1" fails for the wrong reason.
check "the detail names the actual dataset that failed" "yes" \
      "$(grep -q 'does-not-exist' "$TMPD/alerts.log" 2>/dev/null && echo yes || echo no)"

# ============================================================================
# S4. Multi-tier retention must not leak across tiers.
#     Contract: gen-cron-flags (same-scope pattern overlap) -- but the real
#     question is behavioural: does an hourly prune ever eat a daily snapshot?
# ============================================================================
scenario "S4 tiers prune independently, no cross-tier damage" \
         "contract: gen-cron-flags (pattern isolation)"

T4="$ROOT/s4"
mk "$T4"
for i in 1 2 3 4 5; do zfs snapshot "$T4@automated_hourly_$i"; done
for i in 1 2 3;       do zfs snapshot "$T4@automated_daily_$i";  done
for i in 1 2;         do zfs snapshot "$T4@automated_weekly_$i"; done
check "10 snapshots seeded across three tiers" "10" "$(count_of "$T4")"

"$DELSNAPS" "$T4" automated_hourly_ -H2 >/dev/null 2>&1
check "hourly prune kept exactly 2 hourly" "2" \
      "$(zfs list -H -o name -t snapshot -d1 "$T4" | grep -c 'automated_hourly_')"
check "hourly prune did not touch daily" "3" \
      "$(zfs list -H -o name -t snapshot -d1 "$T4" | grep -c 'automated_daily_')"
check "hourly prune did not touch weekly" "2" \
      "$(zfs list -H -o name -t snapshot -d1 "$T4" | grep -c 'automated_weekly_')"

# The trap this guards: "automated_" is a PREFIX of all three tier patterns.
"$DELSNAPS" -n "$T4" automated_ -H1 > "$TMPD/s4dry.log" 2>&1
check "a too-broad pattern would hit ALL tiers (dry-run proves the hazard)" "6" \
      "$(grep -c 'Would delete' "$TMPD/s4dry.log")"

# ============================================================================
# S5. Disaster recovery: can a backup actually be restored?
#     No contract -- but this is the only question that ultimately matters, and
#     nothing in this repo has ever asserted it end to end.
# ============================================================================
scenario "S5 restore a destroyed source from its backup" \
         "the question the whole toolkit exists to answer"

S5="$ROOT/s5src"
mk "$S5"
zfs snapshot "$S5@automated_hourly_1"
ORIG_GUID="$(guid_of "$S5@automated_hourly_1")"
"$SNAPSEND" -m automated_hourly_ -e "$S5" "$ROOT/s5bk" >/dev/null 2>&1
check "backup taken" "yes" "$(exists "$ROOT/s5bk/$S5")"

BK_SNAP="$(zfs list -H -o name -t snapshot -d1 "$ROOT/s5bk/$S5" | head -1)"
zfs destroy -R "$S5"
check "source destroyed (simulated disaster)" "no" "$(exists "$S5")"

# Restore: send the backup back to where the source used to be.
zfs send "$BK_SNAP" 2>/dev/null | zfs recv -o canmount=noauto "$S5" 2>/dev/null
check "restore completed" "yes" "$(exists "$S5")"
check "restored snapshot has the ORIGINAL guid (bit-identical stream)" \
      "$ORIG_GUID" "$(guid_of "$S5@automated_hourly_1")"

# ============================================================================
# S6. Bookmark fallback: the source snapshot is pruned before the target
#     catches up. Without a bookmark this is a full resend; with one it stays
#     incremental. Exercised here as a real sequence, not a unit assertion.
# ============================================================================
scenario "S6 incremental survives the common snapshot being pruned" \
         "bookmark-backed fallback, end to end"

S6="$ROOT/s6src"
mk "$S6"
"$SNAPSEND" -m auto_ "$S6" "$ROOT/s6bk" >/dev/null 2>&1
check "first send landed" "1" "$(count_of "$ROOT/s6bk/$S6")"
check "a bookmark was recorded on the source" "1" \
      "$(zfs list -H -t bookmark -o name -d1 "$S6" 2>/dev/null | wc -l)"

FIRST_SNAP="$(zfs list -H -o name -t snapshot -d1 "$S6" | head -1)"
sleep 1
"$SNAPSEND" -m auto_ "$S6" "$ROOT/s6bk" >/dev/null 2>&1
# Destroy the common base on the SOURCE only -- the bookmark must carry it.
zfs destroy "$FIRST_SNAP" 2>/dev/null
check "common base pruned from the source" "1" "$(count_of "$S6")"

sleep 1
"$SNAPSEND" -m auto_ "$S6" "$ROOT/s6bk" >/dev/null 2>&1
check "the next send still succeeds" "0" "$?"
check "the target holds all three snapshots (incremental, not reseeded)" "3" \
      "$(count_of "$ROOT/s6bk/$S6")"

# ============================================================================
# S7. Hygiene after everything: no held snapshots, no leftover state.
#     Contract: hold-tag.
# ============================================================================
scenario "S7 nothing left holding anything" "contract: hold-tag"

HELD=0
for s in $(zfs list -H -o name -t snapshot -r "$ROOT" 2>/dev/null); do
    zfs holds -H "$s" 2>/dev/null | grep -q zfssnapall && HELD=$((HELD + 1))
done
check "no in-flight hold survived any scenario" "0" "$HELD"
check "the stats log recorded the runs as JSON lines" "1" \
      "$([ -s "$STATS_LOG" ] && echo 1 || echo 0)"

echo
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
