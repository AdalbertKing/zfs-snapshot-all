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
    # THE DIGEST LINE IS NOT A RELATIONSHIP JOB AND MUST NOT COME BACK.
    #
    # Every host in the estate still has one INSIDE its old managed block --
    # that is what fixtures-legacy is for, and the line stays in the corpus for
    # exactly that reason. Since 2026-08-22 the digest is a HOST job that
    # deploy.sh installs by adopt into its own block, and gen-cron.sh no longer
    # writes one: a host that got both had two digests, which pve1 did.
    #
    # So the old line disappearing from the regenerated block is the intended
    # migration, not drift, and it is asserted here rather than filtered away
    # quietly -- if gen-cron.sh ever starts emitting a digest again, this is
    # what says so.
    if printf '%s\n' "$want" | grep -qE '(alert-digest|/DIGEST)'; then
        if printf '%s\n' "$got" | grep -qE '(alert-digest|/DIGEST)'; then
            echo "FAIL legacy/$name-digest-dropped (gen-cron.sh regenerated a digest line; the host would get two)"
            fail=$((fail+1))
        else
            echo "PASS legacy/$name-digest-dropped"; pass=$((pass+1))
        fi
        want="$(printf '%s\n' "$want" | grep -vE '(alert-digest|/DIGEST)')"
    fi
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

# ---- the install that removes an old digest line must SAY SO ---------------
#
# The migration above is silent from the host's point of view: --install
# rewrites the managed block, the digest line inside it disappears, and the
# digest does not exist anywhere else until someone runs deploy.sh. Deployment
# is an hourly `git pull`, not an hourly deploy.sh, so that window is real and
# unbounded. A host in it queues findings and mails nothing -- pve9 spent
# months in exactly that state and the only reason anyone found out was a
# hand audit.
#
# Driven through the real gen-cron.sh --install against a stubbed crontab, on
# a config recovered from the legacy corpus -- i.e. from the shape hosts
# actually have. The negative control is the same install on a block with no
# digest line, which must stay quiet: a warning that fires either way teaches
# people to skip it.
INSTALL_TMP="$(mktemp -d)"
trap 'rm -rf "$INSTALL_TMP"' EXIT
mkdir -p "$INSTALL_TMP/bin" "$INSTALL_TMP/tabs" "$INSTALL_TMP/locks"
cat > "$INSTALL_TMP/bin/crontab" <<'STUB'
#!/bin/bash
d="${CRONTAB_DIR:?}"; u="$(id -un)"
[ "${1:-}" = "-u" ] && { u="$2"; shift 2; }
f="$d/$u"
if [ "${1:-}" = "-l" ]; then
    [ -f "$f" ] || { echo "no crontab for $u" >&2; exit 1; }
    cat "$f"; exit 0
fi
cat "${1:?}" > "$f"; exit 0
STUB
chmod +x "$INSTALL_TMP/bin/crontab"
# Same shim, and the same caveat, as test/cron/run.sh: this dev machine has no
# flock(1). It satisfies lib-cron.sh's two call shapes and nothing more.
if ! command -v flock >/dev/null 2>&1; then
cat > "$INSTALL_TMP/bin/flock" <<'STUB'
#!/bin/bash
mode="" timeout="" fd=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) timeout="$2"; shift 2 ;;
        -u) mode="unlock"; shift ;;
        -n) mode="${mode:-nonblock}"; shift ;;
        -x|-s) shift ;;
        *) fd="$1"; shift ;;
    esac
done
path=$(readlink /proc/self/fd/"$fd" 2>/dev/null) || exit 1
lockdir="${path}.lockdir"
[ "$mode" = unlock ] && { rmdir "$lockdir" 2>/dev/null; exit 0; }
deadline=$(( $(date +%s%N) + ${timeout:-1} * 1000000000 ))
while :; do
    mkdir "$lockdir" 2>/dev/null && exit 0
    [ "$(date +%s%N)" -ge "$deadline" ] && exit 1
    sleep 0.05
done
STUB
chmod +x "$INSTALL_TMP/bin/flock"
fi

install_case() {   # <name> <fixture> <expect-warning yes|no>
    local name="$1" fixture="$2" expect="$3" conf out rc me
    conf="$(mktemp)"
    if ! bash "$C2C" -f "$fixture" -o "$conf" >/dev/null 2>&1; then
        echo "FAIL install/$name (cron2conf.sh could not recover a config from the fixture)"
        fail=$((fail+1)); rm -f "$conf"; return
    fi
    me="$(id -un)"
    cp "$fixture" "$INSTALL_TMP/tabs/$me"
    # A lock directory PER CASE. The flock shim above locks with mkdir, and
    # unlike flock(2) that does not release when the process exits -- so the
    # first install left its lockdir behind and the second was refused with
    # "another gen-cron.sh --install is already running". The shim's own
    # caveat, met in practice.
    mkdir -p "$INSTALL_TMP/locks/$name"
    out="$(PATH="$INSTALL_TMP/bin:$PATH" CRONTAB_DIR="$INSTALL_TMP/tabs" \
           CRON_LOCK_DIR="$INSTALL_TMP/locks/$name" \
           env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG -u DIGEST_SCHEDULE \
           bash "$GEN" -c "$conf" --install 2>&1)"; rc=$?
    rm -f "$conf"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL install/$name (gen-cron.sh --install exited $rc)"; printf '  %s\n' "$out"
        fail=$((fail+1)); return
    fi
    local warned=no
    printf '%s\n' "$out" | grep -q 'this install REMOVES it' && warned=yes
    if [ "$warned" != "$expect" ]; then
        echo "FAIL install/$name (warning expected=$expect, got=$warned)"; printf '  %s\n' "$out"
        fail=$((fail+1)); return
    fi
    # And the line really is gone -- the warning must describe what happened,
    # not merely accompany it.
    if [ "$expect" = yes ] && grep -q 'alert-digest' "$INSTALL_TMP/tabs/$me"; then
        echo "FAIL install/$name (warned, but the digest line is still in the crontab)"
        fail=$((fail+1)); return
    fi
    echo "PASS install/$name"; pass=$((pass+1))
}

# The legacy fixtures carry /DIGEST, not the real script name the awk guard
# looks for, so the case is built from a copy with the real path substituted --
# a host's crontab names /root/scripts/alert-digest.sh.
sed 's#/DIGEST#/root/scripts/alert-digest.sh#' "$DIR/fixtures-legacy/basic.crontab" \
    > "$INSTALL_TMP/with-digest.crontab"
install_case with-digest "$INSTALL_TMP/with-digest.crontab" yes
install_case no-digest   "$DIR/fixtures-legacy/nodigest-delegated.crontab" no

echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
