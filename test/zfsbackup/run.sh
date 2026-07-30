#!/bin/bash
# Tests for zfs-backup.sh's pure/local logic: name validation, peer_label
# parity with deploy.sh's own, cron-config templating idempotency, and the
# section-removal logic used by remove-client.
#
# No root, no ZFS, no network, no live deploy.sh/--pair/--join call: this
# suite only exercises the functions that do not touch a peer or a pool.
# Everything that DOES (add-client's --pair call, activate-client's
# --draft-config/snapget.sh -n/gen-cron.sh --install) needs a real pairing
# between two hosts and is covered by manual live verification instead --
# see docs/reviews/responses/ for that evidence once it exists.
#
#   ./test/zfsbackup/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZFSBACKUP="${ZFSBACKUP:-$REPO/zfs-backup.sh}"
[ -r "$ZFSBACKUP" ] || { echo "cannot find zfs-backup.sh at $ZFSBACKUP" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# Source, not exec: guarded by the same BASH_SOURCE==$0 idiom update-control.sh
# uses, so this reaches the helper functions without running the dispatch.
# shellcheck disable=SC1090
source "$ZFSBACKUP"

# --- 1. client_name_valid ----------------------------------------------------
for good in pve2 metropolis-pve1 client.1 a_b; do
    if client_name_valid "$good"; then ok "client_name_valid accepts '$good'"; else bad "client_name_valid accepts '$good'" "rejected"; fi
done
for bad_name in "" "pve2/x" "pve2 x" 'pve2;rm' "pve2\`id\`"; do
    if client_name_valid "$bad_name"; then bad "client_name_valid rejects '$bad_name'" "accepted"; else ok "client_name_valid rejects '$bad_name'"; fi
done

# --- 2. peer_label matches deploy.sh's own -----------------------------------
# deploy.sh's peer_label() is `tr -c 'A-Za-z0-9._-' '-'` on $PEER_HOST -- this
# is the exact string this repo grep-checked in deploy.sh; kept identical here
# on purpose (no source edge, see the comment above peer_label() in
# zfs-backup.sh) so a future edit to one that misses the other is caught here.
deploy_peer_label() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }
for host in pve2 192.168.28.8 "metropolis.example.com" "host with spaces"; do
    want="$(deploy_peer_label "$host")"
    got="$(peer_label "$host")"
    if [ "$got" = "$want" ]; then
        ok "peer_label('$host') matches deploy.sh's own transform"
    else
        bad "peer_label('$host') matches deploy.sh's own transform" "got=$got want=$want"
    fi
done

# --- 3. local_keyfile_path / local_knownhosts_path (root case, no getent) ---
kf="$(local_keyfile_path "pve2" "")"
kh="$(local_knownhosts_path "pve2" "")"
if [ "$kf" = "/root/.ssh/pairing/pve2_ed25519" ]; then
    ok "local_keyfile_path (root) matches deploy.sh's PEER_KEY_DIR layout"
else
    bad "local_keyfile_path (root) matches deploy.sh's PEER_KEY_DIR layout" "got=$kf"
fi
if [ "$kh" = "/root/.ssh/pairing/pve2_known_hosts" ]; then
    ok "local_knownhosts_path (root) matches deploy.sh's PEER_KEY_DIR layout"
else
    bad "local_knownhosts_path (root) matches deploy.sh's PEER_KEY_DIR layout" "got=$kh"
fi

# --- 4. ensure_cron_config: creates, templates, and is idempotent -----------
CF="$WORK/jobs.test.conf"
ensure_cron_config "$CF"
if [ -f "$CF" ] && grep -q '^\[defaults\]' "$CF" && grep -q '^\[template:standard_hourly\]' "$CF" && grep -q '^\[template:standard_daily\]' "$CF"; then
    ok "ensure_cron_config creates [defaults] + both standard templates"
else
    bad "ensure_cron_config creates [defaults] + both standard templates" "$(cat "$CF" 2>/dev/null)"
fi

before_lines=$(wc -l < "$CF")
ensure_cron_config "$CF"
after_lines=$(wc -l < "$CF")
hourly_count=$(grep -c '^\[template:standard_hourly\]' "$CF")
if [ "$before_lines" = "$after_lines" ] && [ "$hourly_count" = "1" ]; then
    ok "ensure_cron_config is idempotent (no duplicate templates on a second call)"
else
    bad "ensure_cron_config is idempotent" "before=$before_lines after=$after_lines hourly_count=$hourly_count"
fi

# A file that already exists (hand-written) must never be touched/recreated --
# only the templates get appended if genuinely missing.
CF2="$WORK/jobs.existing.conf"
printf '[defaults]\n\thost_label = existing\n\n[dataset:rpool/other]\n\tuse_template = hourly\n' > "$CF2"
orig_md5=$(md5sum "$CF2" | cut -d' ' -f1)
ensure_cron_config "$CF2"
if grep -q 'host_label = existing' "$CF2" && grep -q 'dataset:rpool/other' "$CF2" && grep -q '^\[template:standard_hourly\]' "$CF2"; then
    ok "ensure_cron_config appends templates to an existing hand-written file without disturbing it"
else
    bad "ensure_cron_config appends templates to an existing hand-written file without disturbing it" "$(cat "$CF2")"
fi

# --- 5. remove_managed_sections: removes ONLY the named sections ------------
CF3="$WORK/jobs.remove.conf"
cat > "$CF3" <<'EOF'
[defaults]
	host_label = x

[template:standard_hourly]
	send_schedule = 1 * * * *

[dataset:hdd/backups/pve2/rpool/data]
	use_template = standard_hourly
	notify       = pve2-data

[dataset:hdd/backups/pve3/rpool/data]
	use_template = standard_hourly
	notify       = pve3-data
EOF
remove_managed_sections "$CF3" "hdd/backups/pve2/rpool/data"
if ! grep -qF '[dataset:hdd/backups/pve2/rpool/data]' "$CF3" \
   && grep -qF '[dataset:hdd/backups/pve3/rpool/data]' "$CF3" \
   && grep -qF '[template:standard_hourly]' "$CF3" \
   && grep -qF 'notify       = pve3-data' "$CF3"; then
    ok "remove_managed_sections removes exactly the named client's section, leaves the rest"
else
    bad "remove_managed_sections removes exactly the named client's section, leaves the rest" "$(cat "$CF3")"
fi

# Multiple datasets for one client, in one call.
CF4="$WORK/jobs.remove2.conf"
cat > "$CF4" <<'EOF'
[dataset:a/b]
	notify = a
[dataset:a/c]
	notify = b
[dataset:keep/me]
	notify = c
EOF
remove_managed_sections "$CF4" "a/b" "a/c"
if ! grep -qF '[dataset:a/b]' "$CF4" && ! grep -qF '[dataset:a/c]' "$CF4" && grep -qF '[dataset:keep/me]' "$CF4"; then
    ok "remove_managed_sections handles multiple target sections in one call"
else
    bad "remove_managed_sections handles multiple target sections in one call" "$(cat "$CF4")"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
