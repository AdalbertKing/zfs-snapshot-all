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
GEN="$DIR/../gen-cron.sh"

# Fixed, machine-independent paths so expected output is deterministic.
export REPO_DIR="/REPO" NOTIFY_SCRIPT="/NOTIFY" CRON_LOG="/LOG"

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

echo "--------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
