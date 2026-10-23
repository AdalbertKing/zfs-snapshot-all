#!/bin/bash
# Safe U65 reproducer: execute the exact Python formatter embedded in
# tui/edit-relation.sh against show-tiers-shaped JSON. No ZFS, network, config
# installation or host state is touched.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$REPO/tui/edit-relation.sh"
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# Extract and run the production formatter itself, rather than a rewritten
# model of its comparison.
sed -n '/^srcret_words()/,/^sargs_words()/p' "$SRC" |
    awk '/^import json, sys/{copy=1} copy && /^PYEOF$/{exit} copy{print}' \
    >"$TMP/formatter.py"

if grep -q 'tg = {t.get("name")' "$TMP/formatter.py" &&
   grep -q 'print("tyle samo co w kopii"' "$TMP/formatter.py"; then
    ok "production source-retention formatter extracted"
else
    bad "production source-retention formatter extracted"
fi

cat >"$TMP/equal.json" <<'EOF'
{"target":[{"name":"hourly","keep":"24","retain":""},{"name":"daily","keep":"7","retain":""}],"source":[{"name":"hourly","keep":"24","retain":""},{"name":"daily","keep":"7","retain":""}]}
EOF
cat >"$TMP/different-count.json" <<'EOF'
{"target":[{"name":"hourly","keep":"24","retain":""},{"name":"daily","keep":"7","retain":""}],"source":[{"name":"hourly","keep":"12","retain":""},{"name":"daily","keep":"7","retain":""}]}
EOF
cat >"$TMP/missing-daily.json" <<'EOF'
{"target":[{"name":"hourly","keep":"24","retain":""},{"name":"daily","keep":"7","retain":""}],"source":[{"name":"hourly","keep":"24","retain":""}]}
EOF

equal="$(python3 "$TMP/formatter.py" "$TMP/equal.json")"
different="$(python3 "$TMP/formatter.py" "$TMP/different-count.json")"
missing="$(python3 "$TMP/formatter.py" "$TMP/missing-daily.json")"

if [ "$equal" = "tyle samo co w kopii" ]; then
    ok "equal source and target are reported equal"
else
    bad "equal source and target are reported equal: got [$equal]"
fi

if [ "$different" = "godzinowe 12, dobowe 7" ]; then
    ok "different count is reported from persisted source tiers"
else
    bad "different count is reported from persisted source tiers: got [$different]"
fi

# --drop-src-tier=daily is a supported state: the source does not run daily,
# while the target still retains/prunes its daily tier. These maps are unequal.
if [ "$missing" = "godzinowe 24" ]; then
    ok "missing source daily tier is not reported equal"
else
    bad "missing source daily tier is not reported equal: got [$missing]"
fi

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
