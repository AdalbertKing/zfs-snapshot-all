#!/bin/bash
# Regression tests for cron2conf.sh -- the inverse of gen-cron.sh. No ZFS, no
# remote host: cron2conf.sh and gen-cron.sh are both pure text tools, so this
# runs anywhere bash + coreutils does.
#
#   test/cron2conf/run.sh
#
# Round-trip tests (fixtures/*.crontab): cron2conf.sh reconstructs a config
# from a synthetic managed block, then gen-cron.sh -c <that config> must
# render the SAME SET of lines back (order-insensitive: cron.sh's own
# documented guarantee is set-identity, not byte order -- see cron2conf.sh's
# header comment). Fixtures use invented hostnames/datasets (h1..h5, tank/*),
# never real infrastructure -- see reference_cron_configs_private_repo:
# resolved cron lines carry as much real topology as the config they came
# from, and this repo does not check that in.
#
# Negative tests (negative/*.crontab): must exit 1 (fatal) and print the
# substring in the matching .err file.
#
# Warn tests (warn/*.crontab): must exit 2 (reconstructed with an entity left
# out) and print the substring in the matching .err file.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for negative controls -- see the note in test/run.sh.
C2C="${C2C:-$DIR/../../cron2conf.sh}"
GEN="$DIR/../../gen-cron.sh"

pass=0 fail=0

extract_block() {
    # strip markers/Source/blank lines, sort -- order-insensitive comparison
    grep -v '^# BEGIN\|^# END\|^# Source:' | sed '/^[[:space:]]*$/d' | tr -d '\r' | sort
}

# ---- round-trip ----
for cf in "$DIR"/fixtures/*.crontab; do
    [ -e "$cf" ] || continue
    name="$(basename "$cf" .crontab)"
    conf="$(mktemp)"
    out="$(bash "$C2C" -f "$cf" -o "$conf" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL roundtrip/$name (cron2conf.sh exited $rc, expected 0)"; printf '  %s\n' "$out"
        fail=$((fail+1)); rm -f "$conf"; continue
    fi
    rendered="$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG -u DIGEST_SCHEDULE \
                bash "$GEN" -c "$conf" 2>&1)"
    genrc=$?
    if [ "$genrc" -ne 0 ]; then
        echo "FAIL roundtrip/$name (gen-cron.sh could not read the recovered config, rc=$genrc)"
        printf '  %s\n' "$rendered"; printf '  --- recovered config ---\n'; cat "$conf"
        fail=$((fail+1)); rm -f "$conf"; continue
    fi
    want="$(extract_block < "$cf")"
    got="$(printf '%s\n' "$rendered" | extract_block)"
    if [ "$want" = "$got" ]; then
        echo "PASS roundtrip/$name"; pass=$((pass+1))
    else
        echo "FAIL roundtrip/$name (recovered config renders a DIFFERENT set of lines)"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
        fail=$((fail+1))
    fi
    rm -f "$conf"
done

# ---- legacy round-trip: crontabs written BEFORE the ZFS-JOB markers ---------
#
# fixtures/ carries the shape gen-cron.sh emits today. fixtures-legacy/ carries
# the shape it emitted before 2026-08-17, and that is not history: deployment is
# an hourly `git pull`, so a host keeps its old-shape managed block until
# something runs --install there. Every host in the estate is in that state
# right now.
#
# This tool exists to rebuild a config that has been lost (pve2 needed exactly
# that once), so failing on the shape a host actually has would break it in the
# only situation it is for. The comparison strips the markers from the rendered
# side rather than requiring them absent: what must round-trip is the set of
# JOBS, and the markers are witness, not configuration.
strip_markers() {
    sed -E -e 's/^([^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+) echo "\$\(date -Is\) ZFS-JOB BEGIN [^"]*" >>[^;]*; /\1 /' \
           -e 's/e=\$\(mktemp 2>\/dev\/null\) \|\| e=[^;]*;/e=$(mktemp);/' \
           -e 's/; echo "\$\(date -Is\) ZFS-JOB END [^"]*" >>[^;]*;/;/'
}

for cf in "$DIR"/fixtures-legacy/*.crontab; do
    [ -e "$cf" ] || continue
    name="$(basename "$cf" .crontab)"
    conf="$(mktemp)"
    out="$(bash "$C2C" -f "$cf" -o "$conf" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL legacy/$name (cron2conf.sh exited $rc on a pre-marker crontab)"
        printf '  %s\n' "$out"; fail=$((fail+1)); rm -f "$conf"; continue
    fi
    rendered="$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG -u DIGEST_SCHEDULE \
                bash "$GEN" -c "$conf" 2>&1)"
    want="$(extract_block < "$cf")"
    got="$(printf '%s\n' "$rendered" | strip_markers | extract_block)"
    if [ "$want" = "$got" ]; then
        echo "PASS legacy/$name"; pass=$((pass+1))
    else
        echo "FAIL legacy/$name (a pre-marker crontab no longer round-trips)"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
        fail=$((fail+1))
    fi
    rm -f "$conf"
done

# The legacy corpus must actually BE legacy -- a marker leaking into it would
# turn every check above into a comparison of the new shape with itself.
if grep -l 'ZFS-JOB' "$DIR"/fixtures-legacy/*.crontab >/dev/null 2>&1; then
    echo "FAIL legacy/corpus-is-pre-marker (a fixtures-legacy crontab carries ZFS-JOB markers)"
    fail=$((fail+1))
else
    echo "PASS legacy/corpus-is-pre-marker"; pass=$((pass+1))
fi

# ---- negative (fatal, rc=1) ----
for cf in "$DIR"/negative/*.crontab; do
    [ -e "$cf" ] || continue
    name="$(basename "$cf" .crontab)"
    errf="$DIR/negative/$name.err"
    sub="$(cat "$errf" 2>/dev/null | tr -d '\r')"
    out="$(bash "$C2C" -f "$cf" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "$sub"; then
        echo "PASS negative/$name"; pass=$((pass+1))
    else
        echo "FAIL negative/$name (rc=$rc, want rc=1 and stderr containing: '$sub')"; printf '  %s\n' "$out"
        fail=$((fail+1))
    fi
done

# ---- warn (reconstructed but incomplete, rc=2) ----
for cf in "$DIR"/warn/*.crontab; do
    [ -e "$cf" ] || continue
    name="$(basename "$cf" .crontab)"
    errf="$DIR/warn/$name.err"
    sub="$(cat "$errf" 2>/dev/null | tr -d '\r')"
    out="$(bash "$C2C" -f "$cf" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "$sub"; then
        echo "PASS warn/$name"; pass=$((pass+1))
    else
        echo "FAIL warn/$name (rc=$rc, want rc=2 and stderr containing: '$sub')"; printf '  %s\n' "$out"
        fail=$((fail+1))
    fi
done

# ---- -V / -h smoke ----
v="$(bash "$C2C" -V)"; vrc=$?
if [ "$vrc" -eq 0 ] && [ -n "$v" ]; then
    echo "PASS misc/version"; pass=$((pass+1))
else
    echo "FAIL misc/version (rc=$vrc, output='$v')"; fail=$((fail+1))
fi

# ---- stdin input (no -f/-u) ----
conf="$(mktemp)"
bash "$C2C" -o "$conf" < "$DIR/fixtures/basic.crontab"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$conf" ]; then
    echo "PASS misc/stdin"; pass=$((pass+1))
else
    echo "FAIL misc/stdin (rc=$rc)"; fail=$((fail+1))
fi
rm -f "$conf"

echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
