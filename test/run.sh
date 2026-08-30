#!/bin/bash
# Regression tests for gen-cron.sh -- no dependencies beyond bash + coreutils,
# so it runs the same on the Debian hosts and a Git-Bash dev box.
#
#   test/run.sh              run all tests
#   test/run.sh --bless      regenerate every fixtures/*.expected from current
#                            gen-cron output (use ONLY after reviewing a diff you
#                            intend to accept; never bless blindly)
#
# Golden tests: fixtures/<name>.conf is generated and compared (ignoring the
# machine-specific "# Source:" line) against fixtures/<name>.expected.
# Negative tests: negative/<name>.conf must exit non-zero AND print the substring
# in negative/<name>.err.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a new case can be run against an OLDER gen-cron.sh as a
# negative control -- the only way to show a test actually pins the change
# rather than passing for unrelated reasons. `git stash` is not a substitute:
# it reverts the tests along with the code, so everything "passes" by not
# running (learned the hard way, REV-052).
GEN="${GEN:-$DIR/../gen-cron.sh}"

# Fixed, machine-independent paths so expected output is deterministic.
export REPO_DIR="/REPO" NOTIFY_SCRIPT="/NOTIFY" WARN_SCRIPT="/WARN" DIGEST_SCRIPT="/DIGEST" CRON_LOG="/LOG"

gen() { bash "$GEN" -c "$1" 2>&1; }
# Drop the machine-specific "# Source:" line and any stray CR, so the golden
# comparison is line-ending-insensitive (a CRLF checkout can't cause a false FAIL).
strip_source() { grep -v '^# Source:' | tr -d '\r'; }

pass=0 fail=0
BLESS=0
[ "${1:-}" = "--bless" ] && BLESS=1

# ---- golden ----
for cfg in "$DIR"/fixtures/*.conf; do
    [ -e "$cfg" ] || continue
    name="$(basename "$cfg" .conf)"
    exp="$DIR/fixtures/$name.expected"
    got="$(gen "$cfg" | strip_source)"
    if [ "$BLESS" -eq 1 ]; then
        printf '%s\n' "$got" > "$exp"
        echo "blessed golden/$name"
        continue
    fi
    if [ ! -f "$exp" ]; then
        echo "FAIL golden/$name (no .expected -- run with --bless after review)"; fail=$((fail+1)); continue
    fi
    want="$(strip_source < "$exp")"
    if [ "$got" = "$want" ]; then
        echo "PASS golden/$name"; pass=$((pass+1))
    else
        echo "FAIL golden/$name"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"); fail=$((fail+1))
    fi
done

[ "$BLESS" -eq 1 ] && exit 0

# ---- negative ----
for cfg in "$DIR"/negative/*.conf; do
    [ -e "$cfg" ] || continue
    name="$(basename "$cfg" .conf)"
    errf="$DIR/negative/$name.err"
    sub="$(cat "$errf" 2>/dev/null | tr -d '\r')"
    out="$(gen "$cfg")"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$sub"; then
        echo "PASS negative/$name"; pass=$((pass+1))
    else
        echo "FAIL negative/$name (rc=$rc, want error containing: '$sub')"; printf '  %s\n' "$out"; fail=$((fail+1))
    fi
done

# ---- [defaults] path settings ----
# These need the five environment variables UNSET, and this harness exports all
# of them at the top so golden output stays machine-independent. That export is
# exactly why the config-field path could never be exercised by an ordinary
# fixture: the environment always won, so a fixture would have passed whether or
# not the feature worked at all. Run explicitly with `env -u` instead.
check() {
    local what="$1" out="$2" want="$3"
    if printf '%s' "$out" | grep -qF -- "$want"; then
        echo "PASS paths/$what"; pass=$((pass+1))
    else
        echo "FAIL paths/$what (no '$want' in output)"; printf '  %s\n' "$out" | head -3; fail=$((fail+1))
    fi
}
pathcfg="$(mktemp)"
cat > "$pathcfg" <<'EOF'
[defaults]
	host_label    = t
	repo_dir      = /home/zfsbackup/zfs-snapshot-all
	notify_script = /home/zfsbackup/notify-fail.sh
	cron_log      = /home/zfsbackup/cron.log
[template:hourly]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:tank/x]
	use_template = hourly
EOF
noenv_out="$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG \
    bash "$GEN" -c "$pathcfg" 2>&1)"
# THE PATH IS NAMED ONCE AND REFERENCED, not pasted into every command.
# gen-cron.sh emits ZSA_REPO/ZSA_LOG/ZSA_NOTIFY ahead of the jobs because cron
# caps a command at 1000 bytes and an ordinary host was already at 890. So the
# claim -- "the configured repo_dir is what the jobs actually use" -- is checked
# in both halves: the value lands in the assignment, and the command references
# it. Checking only the concatenation would have passed on a build that emitted
# the assignment and then hardcoded something else in the line.
check "repo_dir from config"      "$noenv_out" "ZSA_REPO=/home/zfsbackup/zfs-snapshot-all"
check "repo_dir is referenced"    "$noenv_out" "\$ZSA_REPO/snapsend.sh"
check "notify_script from config" "$noenv_out" "/home/zfsbackup/notify-fail.sh"
check "cron_log from config"      "$noenv_out" "/home/zfsbackup/cron.log"
# The other half of the contract: an explicit environment variable still wins.
env_out="$(gen "$pathcfg")"
check "env out-ranks config"      "$env_out" "ZSA_REPO=/REPO"
check "env out-ranks config (referenced)" "$env_out" "\$ZSA_REPO/snapsend.sh"
rm -f "$pathcfg"

# ---- the host settings file is a fallback, never a widening ----------------
#
# Reviewer contract, 2026-08-26: `settings.ini` supplies `quiesce` ONLY when the
# tier named none. The second check is the one that matters -- a host default
# that could turn an explicit fail-closed `auto` into `auto,degrade` would mean
# an operator who wrote the safe value silently got the permissive one, which is
# the exact failure `,degrade` is designed not to be.
setcfg="$(mktemp)"; setini="$(mktemp)"
cat > "$setini" <<'EOF'
# a host that has decided crash-consistent beats nothing
quiesce = auto,degrade
EOF
cat > "$setcfg" <<'EOF'
[defaults]
	host_label = t
	dst        = backup/t
[template:hourly]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:tank/silent]
	use_template = hourly
	notify       = silent
[dataset:tank/explicit]
	use_template = hourly
	quiesce      = auto
	notify       = explicit
EOF
set_out="$(SETTINGS_FILE="$setini" gen "$setcfg")"
silent_line="$(printf '%s\n' "$set_out" | grep -F '(silent)' | head -1)"
explicit_line="$(printf '%s\n' "$set_out" | grep -F '(explicit)' | head -1)"
check "settings fallback fills a silent tier"     "$silent_line"   "-q auto,degrade"
check "settings does NOT widen an explicit auto"  "$explicit_line" "-q auto \""
# ...and the negative control for the fallback itself: with no settings file the
# silent tier must stay silent, or the first check above would pass against a
# gen-cron that always emitted the qualifier.
nofile_out="$(SETTINGS_FILE=/nonexistent/settings.ini gen "$setcfg")"
nofile_line="$(printf '%s\n' "$nofile_out" | grep -F '(silent)' | head -1)"
if printf '%s' "$nofile_line" | grep -qF -- '-q '; then
    echo "FAIL paths/settings absent leaves the tier unquiesced"; printf '  %s\n' "$nofile_line" | head -1; fail=$((fail+1))
else
    echo "PASS paths/settings absent leaves the tier unquiesced"; pass=$((pass+1))
fi
rm -f "$setcfg" "$setini"

# ---- allow-list vs the lookups in the code ----
# Unknown fields are now rejected, which turns "add a field, forget the
# allow-list" into a config that used to work and suddenly does not. This is
# the guard: every field name the code asks for by literal must be accepted.
#
# The accepted set comes from gen-cron.sh --dump-fields (authoritative, no
# source scraping). The used set is a grep, deliberately: if it misses a call
# site the test loses coverage, which is survivable -- a scraper that produced
# FALSE failures on a reformatted line would just get muted, which is not.
declared="$(bash "$GEN" --dump-fields | awk '{print $2}' | sort -u)"
used="$( { grep -oE '\b(resolve_field|require_field|resolve_field_tiered|resolve_field_or_omit) +"?[a-z_]+"?' "$GEN"
           grep -oE '\b(ini_has|ini_get) +("\$[a-z_]+"|defaults) +"?[a-z_]+"?' "$GEN"
         } | sed -E 's/.* +"?([a-z_]+)"?$/\1/' | sort -u )"
missing="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$used") | tr '\n' ' ')"
missing="$(printf '%s' "$missing" | sed 's/ *$//')"
if [ -z "$missing" ]; then
    echo "PASS fields/every looked-up field is in the allow-list"; pass=$((pass+1))
else
    echo "FAIL fields/looked up but not accepted: $missing"; fail=$((fail+1))
fi

echo "--------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
