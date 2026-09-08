#!/bin/bash
# ============================================================================
# realshape -- THE SUITE THAT CHECKS WHAT THE OTHER SUITES BELIEVE
#
# Owner, 2026-09-08: "Wyciagnij wnioski ze slabej skutecznosci suit w zderzeniu
# z recenzentem i z rzeczywistoscia."
#
# Nine defects in two days. Three of them share one cause, and it is not
# carelessness: A STUB IS WRITTEN FROM THE SAME BELIEF AS THE CODE UNDER TEST,
# so it cannot contradict that belief. The suite agrees with itself and stays
# green while the estate does something else.
#
#   * `monitor --json` emitted invalid JSON for a scope covering two datasets.
#     The stub printed one line per SCOPE; check-snap-age.sh prints one per
#     DATASET. The suite could not have caught it: its stub was the defect.
#   * `show-scope --recursive` did nothing, because `zfs list` needs -r. The
#     stub answered identically whatever flags it was handed.
#   * `show-scope` reported the wrong newest snapshot, because `creation` has
#     one-second resolution and a real pool ties them. The stub's timestamps
#     were conveniently distinct.
#
# So this suite does not stub anything. It replays BYTES CAPTURED FROM HOSTS
# (test/realshape/captures/, sanitised for names, exact in structure) and asserts
# two things:
#
#   1. the reader that must parse that output really parses it;
#   2. the SHAPE the stubs elsewhere depend on is still the shape reality has --
#      so a stub drifting from the estate turns red HERE instead of passing
#      quietly for weeks.
#
# Text tools only. No ZFS, no root, no host.
# ============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$REPO/test/realshape/captures"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; shift; [ $# -gt 0 ] && printf '  %s\n' "$@"; }

for f in crontab-managed-block.txt zfs-snapshots.txt check-snap-age.multi.txt \
         check-snap-age.unknown.txt check-snap-age.critical-multi.txt; do
    [ -f "$FIX/$f" ] || { echo "FATAL: brak fikstury $f" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# 1. THE SHAPES THEMSELVES. These assertions have no product in them: they pin
# what the ESTATE produces, so that when an engine changes its output the tree
# finds out here rather than through a reader that quietly mis-parses it.
# ---------------------------------------------------------------------------
nf=$(awk -F'\t' '{print NF}' "$FIX/zfs-snapshots.txt" | sort -u | tr '\n' ' ')
if [ "$nf" = "3 " ]; then
    ok "shape: zfs list -H -p gives exactly three TAB-separated fields on every line"
else
    bad "shape: zfs list -H -p gives three TAB fields" "pola na linie: $nf"
fi
if awk -F'\t' '{ if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) bad=1 } END { exit bad+0 }' "$FIX/zfs-snapshots.txt"; then
    ok "shape: -p really means parseable -- creation and used are plain integers"
else
    bad "shape: creation and used are integers under -p" "$(head -1 "$FIX/zfs-snapshots.txt")"
fi

# THE ONE THAT COST A DEFECT: one invocation, several lines.
lines=$(grep -c '^CRITICAL ' "$FIX/check-snap-age.critical-multi.txt")
if [ "$lines" -eq 2 ]; then
    ok "shape: ONE check-snap-age invocation prints one line PER DATASET (2 here), not one per scope"
else
    bad "shape: one invocation prints one line per dataset" "policzono $lines"
fi
if grep -q '^RC=2$' "$FIX/check-snap-age.critical-multi.txt"; then
    ok "shape: ...and the exit status is the worst verdict, once (2)"
else
    bad "shape: the exit status is the worst verdict" "$(tail -1 "$FIX/check-snap-age.critical-multi.txt")"
fi
# THE ONE THAT SURPRISED ME: silence means healthy.
body=$(grep -v '^RC=' "$FIX/check-snap-age.multi.txt" | grep -c '[^[:space:]]' || true)
if [ "$body" -eq 0 ] && grep -q '^RC=0$' "$FIX/check-snap-age.multi.txt"; then
    ok "shape: a HEALTHY check prints NOTHING and exits 0 -- silence is the good news"
else
    bad "shape: a healthy check prints nothing, rc=0" "$(cat "$FIX/check-snap-age.multi.txt")"
fi
if grep -q '^UNKNOWN dataset=.* -- does not exist' "$FIX/check-snap-age.unknown.txt" \
   && grep -q '^RC=3$' "$FIX/check-snap-age.unknown.txt"; then
    ok "shape: a missing dataset is UNKNOWN with a reason, rc=3 -- never silence"
else
    bad "shape: a missing dataset is UNKNOWN rc=3" "$(cat "$FIX/check-snap-age.unknown.txt")"
fi

# The installed block: the two line shapes every reader of it has to survive.
# THE GRAMMAR I GOT WRONG. gen-cron.sh writes the path on the block's SECOND
# line, `# Source: <path> -- DO NOT EDIT BY HAND, ...`; list-jobs shipped with a
# reader for `# BEGIN ... -- Source:`, a shape no generator has ever written. It
# matched every fixture I wrote by hand and nothing on the estate: replayed
# against this capture, the verb reported eleven running lines as unexplainable.
if head -1 "$FIX/crontab-managed-block.txt" | grep -q '^# BEGIN zfs-backup-managed' \
   && sed -n 2p "$FIX/crontab-managed-block.txt" | grep -q '^# Source: .* -- DO NOT EDIT'; then
    ok "shape: the block names its config on its SECOND line, not inside the BEGIN line"
else
    bad "shape: the block's Source line is line two" "$(head -2 "$FIX/crontab-managed-block.txt")"
fi
if grep -qE '^[0-9*/, -]+ [^ ]*zfs-job\.sh "[^"]+" .* -- [^ ]*(snapsend|snapget|delsnaps)\.sh ' "$FIX/crontab-managed-block.txt"; then
    ok "shape: a work line is <schedule> zfs-job.sh \"TITLE\" ... -- <engine> <args>"
else
    bad "shape: the work line shape" "$(grep -m1 snapsend "$FIX/crontab-managed-block.txt")"
fi
if grep -qE '^[0-9*/, -]+ d=\$\([^ ]*check-snap-age\.sh ' "$FIX/crontab-managed-block.txt"; then
    ok "shape: a monitor line is a bare d=\$(check-snap-age.sh ...) -- a DIFFERENT shape from the wrapper"
else
    bad "shape: the monitor line shape" "$(grep -m1 check-snap-age "$FIX/crontab-managed-block.txt")"
fi

# ---------------------------------------------------------------------------
# 2. THE READERS, FED THE REAL BYTES. Not "does the reader work" -- the other
# suites answer that against stubs. This asks whether it survives what the
# estate actually prints.
# ---------------------------------------------------------------------------
. "$REPO/zfs-backup.sh"

# --- show-scope against real `zfs list` output ------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/zfs" <<EOF
#!/bin/sh
case "\$*" in
  *"-t snapshot"*) cat "$FIX/zfs-snapshots.txt" ;;
  *get*usedbysnapshots*) echo 497012736 ;;
  *"-t bookmark"*) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/zfs"
rs_out=$( export PATH="$WORK/bin:$PATH"; cmd_show_scope rpool/ROOT/os --pattern=automated_daily --json 2>/dev/null )
if printf '%s' "$rs_out" | grep -q '"total_snapshots":7'; then
    ok "show-scope: parses REAL zfs output -- all seven snapshots, from the host's own bytes"
else
    bad "show-scope: parses real zfs output" "$rs_out"
fi
if printf '%s' "$rs_out" | grep -q '"pattern":"automated_daily","count":7'; then
    ok "show-scope: ...and the family the host really carries is the family reported"
else
    bad "show-scope: the real family is counted" "$rs_out"
fi
if printf '%s' "$rs_out" | grep -q '"newest":"automated_daily_2026-09-08_00-21-01"'; then
    ok "show-scope: ...and the newest is the one the host stamped last"
else
    bad "show-scope: the newest from real output" "$rs_out"
fi

# --- monitor --json against the real engine shapes --------------------------
# THE DEFECT THIS REPLAYS: a scope covering two datasets makes the engine print
# TWO lines, and the reader used to paste them into JSON unescaped.
mkdir -p "$WORK/mon"
cat > "$WORK/mon/engine.sh" <<EOF
#!/bin/bash
# Not an invention: it replays a capture, including the exit status.
sed '/^RC=/d' "$FIX/check-snap-age.critical-multi.txt"
exit 2
EOF
chmod +x "$WORK/mon/engine.sh"
cat > "$WORK/mon/crontab" <<'EOF'
#!/bin/sh
who=root
[ "$1" = "-u" ] && who="$2"
[ -f "$MONX/crontab.$who" ] && cat "$MONX/crontab.$who" || { echo "no crontab for $who" >&2; exit 1; }
EOF
chmod +x "$WORK/mon/crontab"
mkdir -p "$WORK/mon/bin"; mv "$WORK/mon/crontab" "$WORK/mon/bin/crontab"
# One monitor line, whose scope covers TWO datasets -- taken from the captured
# block's own shape.
cat > "$WORK/mon/crontab.root" <<'EOF'
# BEGIN zfs-backup-managed -- Source: /etc/zfs-snapshot-all/jobs.conf
*/15 * * * * d=$(/r/check-snap-age.sh "rpool/ROOT/os,hdd/backups/hostA/rpool/ROOT/os" "automated_daily" 1m 2m 2>&1); rc=$?
# END zfs-backup-managed
EOF
mon_out=$( export PATH="$WORK/mon/bin:$PATH" MONX="$WORK/mon"
           CLIENTS_DIR="$WORK/mon/none"; PEER_STATE_DIR="$WORK/mon/none"
           CRON_SPOOL_DIRS=("$WORK/mon/none")
           CHECKSNAPAGE="$WORK/mon/engine.sh"
           cmd_monitor --json 2>/dev/null )
if printf '%s' "$mon_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
   || printf '%s' "$mon_out" | python -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "monitor: TWO engine lines from ONE invocation still produce valid JSON (the 2026-09-07 defect)"
else
    bad "monitor: two engine lines produce valid JSON" "$mon_out"
fi
if printf '%s' "$mon_out" | grep -q '"verdict":"CRITICAL"'; then
    ok "monitor: ...and the verdict from the real exit status is carried through"
else
    bad "monitor: the verdict from a real rc" "$mon_out"
fi

# --- list-jobs against the real installed block -----------------------------
# The block is real; the config it names is written here, because production
# configs live in a separate private repository and only the block's SHAPE is
# what this suite is entitled to.
mkdir -p "$WORK/lj/bin" "$WORK/lj/spool"; : > "$WORK/lj/spool/backupacct"
# Only the PATH is redirected at the local config; every other byte of the
# block -- including the header grammar under test -- is the host's.
sed "s|^# Source: .*|# Source: $WORK/lj/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead|" \
    "$FIX/crontab-managed-block.txt" > "$WORK/lj/crontab.backupacct"
cat > "$WORK/lj/jobs.conf" <<'EOF'
[defaults]
	host_label = hostA

[template:daily]
	send_schedule  = 21 0 * * *
	prune_schedule = 41 0 * * *
	prefix         = automated_daily_
	pattern        = automated_daily
	keep           = 7

[dataset:rpool/ROOT/os]
	use_template = daily
	dst          = hdd/backups/hostA
EOF
cat > "$WORK/lj/bin/crontab" <<'EOF'
#!/bin/sh
who=root
[ "$1" = "-u" ] && who="$2"
[ -f "$LJX/crontab.$who" ] && cat "$LJX/crontab.$who" || { echo "no crontab for $who" >&2; exit 1; }
EOF
chmod +x "$WORK/lj/bin/crontab"
lj_out=$( export PATH="$WORK/lj/bin:$PATH" LJX="$WORK/lj"
          CLIENTS_DIR="$WORK/lj/none"; PEER_STATE_DIR="$WORK/lj/none"
          CRON_SPOOL_DIRS=("$WORK/lj/spool")
          cmd_list_jobs --json 2>/dev/null )
if printf '%s' "$lj_out" | grep -q '"lines_in_block":11'; then
    ok "list-jobs: counts the ELEVEN engine lines the production block really carries"
else
    bad "list-jobs: counts the real block's engine lines" "$lj_out"
fi
if printf '%s' "$lj_out" | grep -q '"scope":"rpool/ROOT/os","tier":"daily","direction":"local"'; then
    ok "list-jobs: ...and reads the real header's config to derive the row"
else
    bad "list-jobs: derives a row from the real block's Source header" "$lj_out"
fi

# ---------------------------------------------------------------------------
# 3. THE MACHINERY ITSELF. Class C of the 2026-09-08 analysis: nobody tested the
# test harness, so `--section` accepted a name, ran that section, and ran every
# other one too -- for weeks, at about twenty-five minutes a call. The flag
# looked right because the named section's assertions were all present.
#
# So the assertion is not "the section ran". It is "NOTHING ELSE ran".
# ---------------------------------------------------------------------------
sel_out=$( bash "$REPO/test/zfsbackup/run.sh" --section statusjson 2>&1 )
sel_own=$(printf '%s' "$sel_out" | grep -c '^PASS statusjson:' || true)
sel_foreign=$(printf '%s' "$sel_out" | grep -cE '^(PASS|FAIL) (saveprof|listjobs|showscope|records|monitorjson):' || true)
if [ "$sel_own" -gt 0 ] && [ "$sel_foreign" -eq 0 ]; then
    ok "selector: --section statusjson runs that section and NOTHING else ($sel_own assertions, 0 foreign)"
else
    bad "selector: --section runs only the named section" "wlasnych=$sel_own obcych=$sel_foreign"
fi
# ...and every name the usage line offers must actually be a section, or the
# operator is told to type something that silently runs everything.
# The names the usage line offers, taken from the line itself and cut at the
# closing paren -- the first version of this assertion swallowed `>&2; exit 2`
# and reported shell fragments as ungated sections.
sel_names=$(sed -n 's/.*known: \([^)]*\)).*/\1/p' "$REPO/test/zfsbackup/run.sh" | head -1 | tr '|' ' ')
sel_missing=""
for n in $sel_names; do
    # gated directly, or resolved by want()'s alias table -- both really select.
    grep -q "^if want $n; then" "$REPO/test/zfsbackup/run.sh" && continue
    grep -q "retention:$n" "$REPO/test/zfsbackup/run.sh" && continue
    sel_missing="$sel_missing $n"
done
if [ -n "$sel_names" ] && [ -z "$sel_missing" ]; then
    ok "selector: every name the usage offers really selects -- gated, or an explicit alias"
else
    bad "selector: a name is offered but selects nothing" "nazwy=[$sel_names] bez bramki:$sel_missing"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
