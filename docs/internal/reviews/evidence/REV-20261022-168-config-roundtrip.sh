#!/bin/bash
# Isolated reproduction for REV-20261022-168.
# No network, ZFS, account, cron installation or live-host operation is used.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/clients"

cat > "$T/clients/q.conf" <<'EOF'
CLIENT_NAME=q
STATE=active
RUX_MODE=local
REQUESTED_DATASETS=tank/data
CLIENT_TARGET=
PROFILE=default
EOF

# Start from the repository's known-valid relationship fixture, then change
# only the relationship identity and one accepted wording value.
cp "$ROOT/test/fixtures/relation-local.conf" "$T/jobs.conf"
sed -i \
    -e 's/\[relation:L\]/[relation:q]/' \
    -e 's/relation     = L/relation     = q/g' \
    -e '0,/hourly.notify_word    = snapshot/s//hourly.notify_word    = snap"shot/' \
    "$T/jobs.conf"

pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

if bash "$ROOT/gen-cron.sh" -c "$T/jobs.conf" >/dev/null 2>&1; then
    ok "gen-cron accepts the relation value containing a double quote"
else
    bad "population control: gen-cron rejected the input"
fi

if CLIENTS_DIR="$T/clients" SERVER_CONF="$T/no-server" \
     bash -c 'source "$1"; cmd_export_relation q --json --config="$2"' \
     x "$ROOT/zfs-backup.sh" "$T/jobs.conf" > "$T/q.json" 2> "$T/export.err" \
   && grep -qF '"hourly.notify_word":"snap\"shot"' "$T/q.json"; then
    ok "export-relation JSON preserves and escapes the value"
else
    bad "export control did not preserve the value"
fi

# An exported document made from this exact config must compare identical.
CLIENTS_DIR="$T/clients" CFG="$T/jobs.conf" DOCFILE="$T/q.json" \
    bash -c '
      source "$1"
      cron_context_resolve() { CRON_CTX_FILE="$CFG"; }
      assert_cron_config_matches_installed() { :; }
      doc=$(cat "$DOCFILE")
      import_restore_relblock q "$doc" --check
    ' x "$ROOT/zfs-backup.sh" >/dev/null 2>&1
check_rc=$?
if [ "$check_rc" -eq 0 ]; then
    ok "identity check recognises the exported block"
else
    bad "identity check reports a difference for the same exported block (rc=$check_rc)"
fi

# Exercise the shipped restore function, stubbing only installation boundaries.
cp "$T/jobs.conf" "$T/restored.conf"
CLIENTS_DIR="$T/clients" CFG="$T/restored.conf" DOCFILE="$T/q.json" GEN="$ROOT/gen-cron.sh" \
    bash -c '
      source "$1"
      cron_context_resolve() { CRON_CTX_FILE="$CFG"; }
      assert_cron_config_matches_installed() { :; }
      gencron_as_target() { bash "$GEN" "$@"; }
      atomic_replace_and_install() { cp "$2" "$1"; }
      doc=$(cat "$DOCFILE")
      import_restore_relblock q "$doc"
    ' x "$ROOT/zfs-backup.sh" >/dev/null 2> "$T/restore.err"
restore_rc=$?
before=$(awk -F= '/hourly.notify_word/{v=$2; sub(/^[ \t]+/, "", v); print v}' "$T/jobs.conf")
after=$(awk -F= '/hourly.notify_word/{v=$2; sub(/^[ \t]+/, "", v); print v}' "$T/restored.conf")
if [ "$restore_rc" -eq 0 ] && [ "$after" = "$before" ]; then
    ok "successful import preserves the exact value"
else
    bad "successful import changed notify_word: before=[$before] after=[$after] rc=$restore_rc"
fi

echo "--------------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
