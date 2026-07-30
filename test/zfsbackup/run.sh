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

# --- 6. assert_cron_config_matches_installed --------------------------------
# REAL incident, live on pve0, 2026-07-30: activate-client installed from a
# NEW config file while the host's crontab was already managed by a
# DIFFERENT one (jobs.pve0.v4.conf) -- gen-cron.sh --install replaces the
# WHOLE managed block, so this deleted every real production job until
# `gen-cron.sh -c jobs.pve0.v4.conf --install` restored them by hand. This
# function is the fix: refuse before --install if the crontab's own
# '# Source: <file>' line names a different file. A fake `crontab` stub
# ahead of PATH stands in for the real one -- no root/crontab needed.
STUBDIR="$WORK/stubbin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/crontab" <<'EOF'
#!/bin/bash
if [ "$1" = "-l" ]; then
    echo "# BEGIN zfs-backup-managed"
    echo "# Source: jobs.pve0.v4.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    echo "# END zfs-backup-managed"
fi
EOF
chmod +x "$STUBDIR/crontab"

# REV-20260730-003 F5 (both passes): basename-only comparison would wrongly
# pass here (a DIFFERENT real file, e.g. /root/other/jobs.pve0.v4.conf, shares
# a basename with the one actually installed) -- canonical-path resolution
# must catch it. A relative name in the crontab's own '# Source:' line (the
# real, common shape) resolves against $SCRIPT_DIR, so the SAME relative
# name used as the target must pass.
out="$(PATH="$STUBDIR:$PATH" bash -c "source '$ZFSBACKUP'; assert_cron_config_matches_installed '$REPO/jobs.pve0.v4.conf'" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "assert_cron_config_matches_installed: same file, relative source resolved against \$SCRIPT_DIR, passes"
else
    bad "assert_cron_config_matches_installed: same file, relative source resolved against \$SCRIPT_DIR, passes" "rc=$rc out=$out"
fi

out="$(PATH="$STUBDIR:$PATH" bash -c "source '$ZFSBACKUP'; assert_cron_config_matches_installed '/root/other/jobs.pve0.v4.conf'" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "different file would DELETE"; then
    ok "assert_cron_config_matches_installed: DIFFERENT real file with the SAME basename still refuses"
else
    bad "assert_cron_config_matches_installed: DIFFERENT real file with the SAME basename still refuses" "rc=$rc out=$out"
fi

cat > "$STUBDIR/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-l" ] && exit 1
EOF
chmod +x "$STUBDIR/crontab"
out="$(PATH="$STUBDIR:$PATH" bash -c "source '$ZFSBACKUP'; assert_cron_config_matches_installed '/anything.conf'" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "assert_cron_config_matches_installed: no existing managed block at all passes (first-ever install)"
else
    bad "assert_cron_config_matches_installed: no existing managed block at all passes" "rc=$rc out=$out"
fi

# --- 7. host_key_alias / ensure_alias_known_hosts (REV-20260730-003 F1/F2) --
got="$(host_key_alias pve2)"
if [ "$got" = "zfs-client-pve2" ]; then
    ok "host_key_alias produces a stable, predictable alias"
else
    bad "host_key_alias produces a stable, predictable alias" "got=$got"
fi

# REV-20260730-004 F1: ensure_alias_known_hosts now takes the alias as an
# explicit 4th arg (derived by the caller from CLIENT_NAME, not from `label`)
# -- the alias-keyed file must carry the STABLE alias, decoupled from
# whatever `label` (deploy.sh's own peer_label, address-derived) happens to
# be used to locate the source pinned-key file.
KHDIR="$WORK/pairing"; mkdir -p "$KHDIR"
printf '192.168.11.11 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest\n' > "$KHDIR/192.168.11.11_known_hosts"
alias_out=$(PEER_KEY_DIR="$KHDIR" bash -c "source '$ZFSBACKUP'; PEER_KEY_DIR='$KHDIR' ensure_alias_known_hosts 192.168.11.11 '' 22 zfs-client-pve2")
if [ -f "$alias_out" ] && grep -q '^zfs-client-pve2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest$' "$alias_out"; then
    ok "ensure_alias_known_hosts (port 22) writes an alias-keyed known_hosts under the STABLE alias, not the address-derived label"
else
    bad "ensure_alias_known_hosts (port 22) writes an alias-keyed known_hosts under the STABLE alias" "alias_out=$alias_out content=$(cat "$alias_out" 2>&1)"
fi

alias_out2=$(PEER_KEY_DIR="$KHDIR" bash -c "source '$ZFSBACKUP'; PEER_KEY_DIR='$KHDIR' ensure_alias_known_hosts 192.168.11.11 '' 2222 zfs-client-pve2")
if [ -f "$alias_out2" ] && grep -q '^\[zfs-client-pve2\]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest$' "$alias_out2"; then
    ok "ensure_alias_known_hosts (non-default port) uses bracket:port notation"
else
    bad "ensure_alias_known_hosts (non-default port) uses bracket:port notation" "alias_out2=$alias_out2 content=$(cat "$alias_out2" 2>&1)"
fi

rc=0
out="$(PEER_KEY_DIR="$KHDIR" bash -c "source '$ZFSBACKUP'; PEER_KEY_DIR='$KHDIR' ensure_alias_known_hosts nosuchclient '' 22 zfs-client-nope" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    ok "ensure_alias_known_hosts fails (no output) when there is no pinned key to derive from"
else
    bad "ensure_alias_known_hosts fails (no output) when there is no pinned key to derive from" "rc=$rc out=$out"
fi

# --- 8. endpoint model (REV-20260730-004): parse_endpoint_arg / var names ---
got="$(parse_endpoint_arg 192.168.11.11)"
if [ "$got" = "192.168.11.11 22" ]; then
    ok "parse_endpoint_arg defaults to port 22 when none given"
else
    bad "parse_endpoint_arg defaults to port 22 when none given" "got=$got"
fi
got="$(parse_endpoint_arg 10.8.0.11:2222)"
if [ "$got" = "10.8.0.11 2222" ]; then
    ok "parse_endpoint_arg splits HOST:PORT"
else
    bad "parse_endpoint_arg splits HOST:PORT" "got=$got"
fi

got="$(endpoint_host_var lan)"
if [ "$got" = "ENDPOINT_LAN_HOST" ]; then ok "endpoint_host_var(lan)"; else bad "endpoint_host_var(lan)" "got=$got"; fi
got="$(endpoint_port_var vpn)"
if [ "$got" = "ENDPOINT_VPN_PORT" ]; then ok "endpoint_port_var(vpn)"; else bad "endpoint_port_var(vpn)" "got=$got"; fi

# --- 8b. REV-20260730-005 F1: endpoint input is stored in a file that is
# later SOURCED AS ROOT, so anything that could carry shell syntax must be
# refused before it is ever written. The reviewer named the exact cases; each
# one below must exit non-zero, not be silently accepted or half-parsed.
for badep in 'host;id' '$(id)' '`id`' 'a b' '' 'host&whoami' 'ho|st' 'host
newline' '-leadingdash' 'trailingdash-' '.leadingdot' 'trailingdot.' 'host/../x'; do
    if ( parse_endpoint_arg "$badep" ) >/dev/null 2>&1; then
        bad "parse_endpoint_arg rejects unsafe host '$badep'" "ACCEPTED it"
    else
        ok "parse_endpoint_arg rejects unsafe host '$(printf '%q' "$badep")'"
    fi
done
for badport in 0 65536 99999 abc '' '-1' '22x'; do
    if ( parse_endpoint_arg "host:$badport" ) >/dev/null 2>&1; then
        bad "parse_endpoint_arg rejects bad port '$badport'" "ACCEPTED it"
    else
        ok "parse_endpoint_arg rejects bad port '$badport'"
    fi
done
for goodep in 'pve2' '192.168.11.11' 'pve1-vpn-test' 'a.b.c.d' 'host:1' 'host:65535'; do
    if ( parse_endpoint_arg "$goodep" ) >/dev/null 2>&1; then
        ok "parse_endpoint_arg accepts legitimate endpoint '$goodep'"
    else
        bad "parse_endpoint_arg accepts legitimate endpoint '$goodep'" "REJECTED it"
    fi
done

# write_client_field must produce a line that survives being sourced back with
# its value intact and nothing executed -- the second half of the F1 defence.
inj='$(touch /tmp/zfsbackup-pwned-'"$$"')'
line="$(write_client_field TESTVAL "$inj")"
( eval "$line"; [ "$TESTVAL" = "$inj" ] ) \
    && [ ! -e "/tmp/zfsbackup-pwned-$$" ] \
    && ok "write_client_field survives a command-substitution payload (value intact, nothing executed)" \
    || bad "write_client_field survives a command-substitution payload" "line=$line"
rm -f "/tmp/zfsbackup-pwned-$$"

out="$(bash -c "source '$ZFSBACKUP'; ACTIVE_ENDPOINT=vpn ENDPOINT_VPN_HOST=10.8.0.11 ENDPOINT_VPN_PORT=2222; active_endpoint_host_port" 2>&1)"
if [ "$out" = "10.8.0.11 2222" ]; then
    ok "active_endpoint_host_port resolves the currently active endpoint's host/port"
else
    bad "active_endpoint_host_port resolves the currently active endpoint's host/port" "out=$out"
fi

# --- 9. real bug, live on pve0 (2026-07-30): unquoted date in a client conf -
# `echo "CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')"` writes a date containing a
# SPACE with no quotes around the value -- sourcing that line later splits it
# into an assignment (CREATED_AT=2026-07-30) plus a second bare "command"
# (20:32:38), which bash tries to execute and fails with "command not found".
# Harmless functionally (source keeps going, no -e), but it is real, visible,
# spurious error output on every single client-conf source -- confirmed live.
# All date fields must be double-quoted in the file so sourcing is silent.
CF9="$WORK/dates.conf"
printf 'CREATED_AT="%s"\nACTIVATED_AT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date '+%Y-%m-%d %H:%M:%S')" > "$CF9"
out="$(bash -c "set -u; . '$CF9'" 2>&1)"
if [ -z "$out" ]; then
    ok "a quoted date field sources with no stray 'command not found' output"
else
    bad "a quoted date field sources with no stray 'command not found' output" "out=$out"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
