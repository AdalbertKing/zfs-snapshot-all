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
# ONE send cadence since REV-20260801-016 F2, so standard_daily must NOT be
# created -- a second send tier would add snapshots and transfers that the GFS
# ladder, which buckets by time and ignores prefixes, gives no retention meaning.
if [ -f "$CF" ] && grep -q '^\[defaults\]' "$CF" && grep -q '^\[template:standard_hourly\]' "$CF"    && ! grep -q '^\[template:standard_daily\]' "$CF" && grep -q '^\[template:keep_monthly\]' "$CF"; then
    ok "ensure_cron_config creates [defaults], one send tier, and the keep ladder"
else
    bad "ensure_cron_config creates [defaults], one send tier, and the keep ladder" "$(cat "$CF" 2>/dev/null)"
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

# --- final-catchup gate (REV-20260730-005 F3 / REV-20260731-007 §7) ----------
#
# Switching a client from LAN to VPN is the relocation moment. Without a final
# incremental over the link that still works, the first VPN transfer carries
# everything since the SEED -- over the slow link, unattended. The gate makes
# that a decision instead of an accident.
#
# Run in subshells: the refusal path calls die, which would take this suite with
# it. CLIENTS_DIR is reassigned rather than parameterised because the file is
# sourced, so the assignment is simply in scope.
GATE="$WORK/clients"; mkdir -p "$GATE"
mk_client() {   # mk_client <name> <extra lines...>
    local n="$1"; shift
    { echo "CLIENT_NAME=$n"
      echo "STATE=active"
      echo "PEER_HOST=10.0.0.9"
      echo "ACTIVE_ENDPOINT=lan"
      echo "INSTALLED_ENDPOINT=lan"
      echo "ENDPOINT_LAN_HOST=10.0.0.9"
      echo "ENDPOINT_LAN_PORT=22"
      echo 'SEED_COMPLETED_AT="2026-07-01 00:00:00"'
      for l in "$@"; do echo "$l"; done
    } > "$GATE/$n.conf"
}
gate_run() {    # gate_run <name> <args...>  -> prints output, sets $?
    ( CLIENTS_DIR="$GATE"; cmd_set_endpoint "$@" ) 2>&1
}

mk_client c1
out=$(gate_run c1 --vpn=10.9.9.9); r=$?
if [ "$r" != 0 ] && case "$out" in *"final-catchup c1"*) true ;; *) false ;; esac; then
    ok "gate: switching to vpn without a catch-up is refused, and names the command"
else
    bad "gate: switching to vpn without a catch-up is refused, and names the command" "rc=$r out=$out"
fi

# A catch-up recorded against the endpoint being LEFT is what makes the switch
# safe. Anything else -- including one recorded against the endpoint being
# switched TO -- says nothing about this switch.
# The full record, not just the name: REV-20260731-008 F1 tightened this
# contract deliberately, and a bare FINAL_CATCHUP_ENDPOINT no longer suffices.
mk_client c2 'FINAL_CATCHUP_ENDPOINT=lan' 'FINAL_CATCHUP_HOST=10.0.0.9'              'FINAL_CATCHUP_PORT=22' "FINAL_CATCHUP_EPOCH=$(date '+%s')"              'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
out=$(gate_run c2 --vpn=10.9.9.9); r=$?
[ "$r" = 0 ] && ok "gate: a catch-up over the endpoint being left lets the switch through" \
             || bad "gate: a catch-up over the endpoint being left lets the switch through" "rc=$r out=$out"

mk_client c3 'FINAL_CATCHUP_ENDPOINT=vpn' 'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
out=$(gate_run c3 --vpn=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "gate: a catch-up over the WRONG endpoint does not count" \
              || bad "gate: a catch-up over the WRONG endpoint does not count" "rc=$r"

# The reviewer's case: the source is already unplugged, so there is nothing to
# catch up over. Allowed, but it must warn -- and say what it will cost.
mk_client c4
out=$(gate_run c4 --vpn=10.9.9.9 --skip-final-catchup); r=$?
if [ "$r" = 0 ] && case "$out" in *SKIPPING*) true ;; *) false ;; esac; then
    ok "gate: --skip-final-catchup proceeds but warns"
else
    bad "gate: --skip-final-catchup proceeds but warns" "rc=$r out=$out"
fi

# Not every set-endpoint is a relocation. Correcting the LAN address of a
# client that stays on LAN must not demand a catch-up.
mk_client c5
out=$(gate_run c5 --lan=10.0.0.10); r=$?
[ "$r" = 0 ] && ok "gate: changing the LAN address only is not gated" \
             || bad "gate: changing the LAN address only is not gated" "rc=$r out=$out"

# --- catch-up freshness and identity (REV-20260731-008 F1) -------------------
#
# The endpoint NAME alone was too weak a claim: it survived a change of host or
# port on that endpoint, and it never went stale. A catch-up run on Monday
# authorised a Friday relocation, and a catch-up against one LAN address
# authorised a switch away from a different one.

NOW=$(date '+%s')
mk_fresh() {   # mk_fresh <name> <age-seconds> [host] [port]
    local n="$1" age="$2" h="${3:-10.0.0.9}" p="${4:-22}"
    mk_client "$n"         "FINAL_CATCHUP_ENDPOINT=lan"         "FINAL_CATCHUP_HOST=$h"         "FINAL_CATCHUP_PORT=$p"         "FINAL_CATCHUP_EPOCH=$((NOW - age))"         'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
}

mk_fresh f1 60
out=$(gate_run f1 --vpn=10.9.9.9); r=$?
[ "$r" = 0 ] && ok "fresh: a 1-minute-old catch-up against the exact endpoint passes"              || bad "fresh: a 1-minute-old catch-up against the exact endpoint passes" "rc=$r out=$out"

mk_fresh f2 7200
out=$(gate_run f2 --vpn=10.9.9.9); r=$?
if [ "$r" != 0 ] && case "$out" in *"120 min old"*) true ;; *) false ;; esac; then
    ok "stale: a 2-hour-old catch-up is refused, and the age is named"
else
    bad "stale: a 2-hour-old catch-up is refused, and the age is named" "rc=$r out=$out"
fi

# Same endpoint name, different machine behind it. The old record proves a
# transport that is not the one being left.
mk_fresh f3 60 10.0.0.77
out=$(gate_run f3 --vpn=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "identity: a catch-up against a different HOST does not count"               || bad "identity: a catch-up against a different HOST does not count" "rc=$r"

mk_fresh f4 60 10.0.0.9 2222
out=$(gate_run f4 --vpn=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "identity: a catch-up against a different PORT does not count"               || bad "identity: a catch-up against a different PORT does not count" "rc=$r"

# The override exists because relocation plans slip; it must not be silent.
mk_fresh f5 7200
out=$(gate_run f5 --vpn=10.9.9.9 --allow-stale-catchup); r=$?
if [ "$r" = 0 ] && case "$out" in *"--allow-stale-catchup"*) true ;; *) false ;; esac; then
    ok "override: --allow-stale-catchup proceeds but says what it costs"
else
    bad "override: --allow-stale-catchup proceeds but says what it costs" "rc=$r out=$out"
fi

# A record written before freshness tracking existed has no epoch, so its age
# is unknowable -- treat that as unproven rather than as fresh.
mk_client f6 "FINAL_CATCHUP_ENDPOINT=lan" "FINAL_CATCHUP_HOST=10.0.0.9" "FINAL_CATCHUP_PORT=22"
out=$(gate_run f6 --vpn=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "legacy: a record with no epoch is not treated as fresh"               || bad "legacy: a record with no epoch is not treated as fresh" "rc=$r"

# Moving the endpoint the catch-up was recorded against invalidates it, at the
# moment of the move rather than silently later.
mk_fresh f7 60
out=$(gate_run f7 --lan=10.0.0.55); r=$?
if [ "$r" = 0 ] && case "$out" in *"no longer applies"*) true ;; *) false ;; esac; then
    ok "invalidation: moving the LAN endpoint drops the catch-up recorded for it"
else
    bad "invalidation: moving the LAN endpoint drops the catch-up recorded for it" "rc=$r out=$out"
fi

# --- 8. show_activation_proposal --------------------------------------------
#
# activate-client used to print a SUMMARY and then ask for a yes/no. A yes to a
# description is not consent to a change nobody displayed. These cases pin that
# the change itself is shown, and specifically that BOTH diffs exist -- the
# config diff and the cron diff answer different questions, and case 3 below is
# the whole reason the second one is not redundant.
PROP="$WORK/proposal"; mkdir -p "$PROP"
prop_cfg() {   # prop_cfg <file> <hourly-schedule> [extra dataset]
    cat > "$1" <<EOF
[defaults]
	host_label = testhost

[template:standard_hourly]
	send_schedule  = $2
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24

[dataset:tank/backups/peer1/rpool/data]
	use_template = standard_hourly
	src          = robot@10.0.0.1:rpool/data
	notify       = peer1-data
EOF
    if [ -n "${3:-}" ]; then
        cat >> "$1" <<EOF

[dataset:tank/backups/peer1/$3]
	use_template = standard_hourly
	src          = robot@10.0.0.1:$3
	notify       = peer1-extra
EOF
    fi
}

# A crontab stub: the left side of the cron diff now comes from the LIVE
# crontab, so every case here has to say what is installed. CRONTAB_FIXTURE
# names the file the stub replays for `crontab -l`.
PSTUB="$WORK/propbin"; mkdir -p "$PSTUB"
cat > "$PSTUB/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-l" ] || exit 0
# CRONTAB_MODE lets a case pick which reality the stub presents:
#   (unset) -- replay CRONTAB_FIXTURE
#   none    -- this user has no crontab (benign: cron exits 1 and says so)
#   broken  -- a real read failure (permissions, spool, missing binary)
case "${CRONTAB_MODE:-}" in
    none)   echo "no crontab for tester" >&2; exit 1 ;;
    broken) echo "/var/spool/cron/crontabs/tester: Permission denied" >&2; exit 1 ;;
esac
[ -n "${CRONTAB_FIXTURE:-}" ] && [ -f "$CRONTAB_FIXTURE" ] && cat "$CRONTAB_FIXTURE"
exit 0
EOF
chmod +x "$PSTUB/crontab"
prop_run() {   # prop_run <installed-fixture> <current cfg> <proposed cfg>
    local fx="$1"; shift
    CRONTAB_FIXTURE="$fx" PATH="$PSTUB:$PATH" GENCRON="$REPO/gen-cron.sh"         show_activation_proposal "$1" "$2" 2>&1
}
prop_rc() {    # prop_rc <mode> <current cfg> <proposed cfg> -> exit status only
    local mode="$1"; shift
    ( CRONTAB_MODE="$mode" PATH="$PSTUB:$PATH" GENCRON="$REPO/gen-cron.sh"         show_activation_proposal "$1" "$2" ) >/dev/null 2>&1
    echo $?
}
: > "$PROP/empty.cron"

# 1. Nothing installed yet: everything is new on both sides.
prop_cfg "$PROP/new.conf" "1 * * * *"
out=$(prop_run "$PROP/empty.cron" "$PROP/absent.conf" "$PROP/new.conf")
if case "$out" in *"(nowy plik)"*) true ;; *) false ;; esac    && case "$out" in *"snapget.sh"*) true ;; *) false ;; esac; then
    ok "proposal: a first client shows the new file and the cron lines it creates"
else
    bad "proposal: a first client shows the new file and the cron lines it creates" "$out"
fi

# 2. The installed block is already exactly what the proposal renders.
prop_cfg "$PROP/same-a.conf" "1 * * * *"
prop_cfg "$PROP/same-b.conf" "1 * * * *"
bash "$REPO/gen-cron.sh" -c "$PROP/same-a.conf" > "$PROP/installed.cron" 2>/dev/null
out=$(prop_run "$PROP/installed.cron" "$PROP/same-a.conf" "$PROP/same-b.conf")
if [ "$(printf '%s' "$out" | grep -c 'bez zmian')" = 2 ]; then
    ok "proposal: an unchanged re-activation says 'no change' on both diffs"
else
    bad "proposal: an unchanged re-activation says 'no change' on both diffs" "$out"
fi

# 3. REV-20260801-015 §1, the case the old preview could not see: the config is
#    unchanged, but the LIVE crontab drifted. Rendering the config twice said
#    "no change" while --install would have rewritten the schedule.
prop_cfg "$PROP/drift.conf" "1 * * * *"
prop_cfg "$PROP/drift-installed.conf" "44 * * * *"
bash "$REPO/gen-cron.sh" -c "$PROP/drift-installed.conf" > "$PROP/drifted.cron" 2>/dev/null
out=$(prop_run "$PROP/drifted.cron" "$PROP/drift.conf" "$PROP/drift.conf")
cron_part="${out#*crontabie}"
if case "$cron_part" in *"-44 * * * *"*) true ;; *) false ;; esac    && case "$cron_part" in *"+1 * * * *"*) true ;; *) false ;; esac    && case "$cron_part" in *"bez zmian"*) false ;; *) true ;; esac; then
    ok "proposal: drift between config and live crontab is shown, not hidden"
else
    bad "proposal: drift between config and live crontab is shown, not hidden" "$out"
fi

# 4. A template-only edit moves no [dataset:] section and still rewrites every
#    schedule -- the reason the cron diff is not redundant with the config diff.
prop_cfg "$PROP/tmpl-a.conf" "1 * * * *"
prop_cfg "$PROP/tmpl-b.conf" "*/5 * * * *"
bash "$REPO/gen-cron.sh" -c "$PROP/tmpl-a.conf" > "$PROP/tmpl.cron" 2>/dev/null
out=$(prop_run "$PROP/tmpl.cron" "$PROP/tmpl-a.conf" "$PROP/tmpl-b.conf")
cron_part="${out#*crontabie}"
if case "$cron_part" in *"*/5 * * * *"*) true ;; *) false ;; esac    && case "$cron_part" in *"bez zmian"*) false ;; *) true ;; esac; then
    ok "proposal: a template-only edit still shows the changed cron lines"
else
    bad "proposal: a template-only edit still shows the changed cron lines" "$out"
fi

# 5. A proposed config gen-cron rejects must abort the preview, not show a
#    plausible empty diff (REV-20260801-015 §2).
printf '[dataset:tank/x]
	use_template = nieistniejacy
' > "$PROP/broken.conf"
prop_run "$PROP/empty.cron" "$PROP/absent.conf" "$PROP/broken.conf" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
    ok "proposal: an unrenderable proposal fails closed"
else
    bad "proposal: an unrenderable proposal fails closed" "zwrocilo 0"
fi

# 6. REV-20260801-016 F1: a crontab that cannot be READ is not an empty one.
#    "no crontab for <user>" is the one benign failure; anything else has to
#    abort before the prompt, because the operator is approving an exact live
#    change and a guess in the reassuring direction is the wrong guess.
prop_cfg "$PROP/rd.conf" "1 * * * *"
if [ "$(prop_rc none "$PROP/absent.conf" "$PROP/rd.conf")" = 0 ]; then
    ok "proposal: a user with no crontab is a normal empty left side"
else
    bad "proposal: a user with no crontab is a normal empty left side" "odmowilo"
fi
if [ "$(prop_rc broken "$PROP/absent.conf" "$PROP/rd.conf")" != 0 ]; then
    ok "proposal: an unreadable crontab aborts instead of reading as empty"
else
    bad "proposal: an unreadable crontab aborts instead of reading as empty" "zwrocilo 0"
fi

# --- 9. the GFS profile and its compatibility guard -------------------------
#
# Retention moved from a flat count per tier per dataset to ONE cascading
# delsnaps.sh -G ladder per client. gen-cron.sh accepts gfs= only in a
# [prune:] section, and a [dataset:] prunes exactly when its tiers resolve a
# prune_schedule -- so the profile had to split into two template families.
# The dangerous half of that change is what happens to a host written before
# it, whose standard_* templates still carry prune_schedule: adding a ladder
# there would prune the same snapshots twice on the same schedule.
PROF="$WORK/profile"; mkdir -p "$PROF"

ensure_cron_config "$PROF/fresh.conf" >/dev/null 2>&1
if grep -q "^\[template:keep_hourly\]" "$PROF/fresh.conf" \
   && grep -q "^\[template:standard_hourly\]" "$PROF/fresh.conf" \
   && [ "${PROFILE_GFS:-}" = 1 ] \
   && ! sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$PROF/fresh.conf" | grep -q prune_schedule; then
    ok "profile: a fresh config gets both families, and standard_* no longer prunes"
else
    bad "profile: a fresh config gets both families, and standard_* no longer prunes" "$(cat "$PROF/fresh.conf")"
fi

# The guard. A pre-split config must be left alone: no keep_* injected, and the
# flag that suppresses the ladder must be off.
cat > "$PROF/legacy.conf" <<'EOF'
[defaults]
	host_label = oldhost

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
EOF
ensure_cron_config "$PROF/legacy.conf" >/dev/null 2>&1
if [ "${PROFILE_GFS:-}" = 0 ] && ! grep -q "^\[template:keep_" "$PROF/legacy.conf"; then
    ok "profile: a pre-GFS config keeps flat retention and gets no keep_* templates"
else
    bad "profile: a pre-GFS config keeps flat retention and gets no keep_* templates" \
        "PROFILE_GFS=${PROFILE_GFS:-unset}; $(grep -c '^\[template:keep_' "$PROF/legacy.conf") keep_* sections"
fi

# remove_managed_sections has to see [prune:] too, or a re-activation appends a
# second ladder over the same scope on the same schedule.
cat > "$PROF/rm.conf" <<'EOF'
[defaults]
	host_label = h

[prune:tank/backups/peer1]
	use_template = keep_hourly
	gfs          = yes

[dataset:tank/other]
	use_template = standard_hourly
EOF
remove_managed_sections "$PROF/rm.conf" "tank/backups/peer1"
if ! grep -q "^\[prune:tank/backups/peer1\]" "$PROF/rm.conf" && grep -q "^\[dataset:tank/other\]" "$PROF/rm.conf"; then
    ok "profile: remove_managed_sections drops a [prune:] section and spares the rest"
else
    bad "profile: remove_managed_sections drops a [prune:] section and spares the rest" "$(cat "$PROF/rm.conf")"
fi

# End to end through the real generator: the whole point of the change is ONE
# ladder line instead of a flat prune per tier.
ensure_cron_config "$PROF/gen.conf" >/dev/null 2>&1
cat >> "$PROF/gen.conf" <<'EOF'

[dataset:tank/backups/peer1/rpool/data]
	use_template = standard_hourly
	src          = robot@10.0.0.1:rpool/data
	notify       = peer1-data

[prune:tank/backups/peer1]
	use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly
	recursive    = yes
	gfs          = yes
	gfs_pattern  = automated_
	notify       = peer1
EOF
gen_out=$(bash "$REPO/gen-cron.sh" -c "$PROF/gen.conf" 2>&1)
ladders=$(printf '%s\n' "$gen_out" | grep -c -- "delsnaps.sh -G")
flat=$(printf '%s\n' "$gen_out" | grep "delsnaps.sh" | grep -vc -- "-G")
if [ "$ladders" = 1 ] && [ "$flat" = 0 ]; then
    ok "profile: renders exactly one GFS ladder and no flat per-tier prune"
else
    bad "profile: renders exactly one GFS ladder and no flat per-tier prune" \
        "ladders=$ladders flat=$flat
$gen_out"
fi
if printf '%s\n' "$gen_out" | grep -q -- '-G -R "tank/backups/peer1" "automated_" -H24 -D7 -W4 -M12'; then
    ok "profile: the ladder carries every tier's count in order"
else
    bad "profile: the ladder carries every tier's count in order" "$(printf '%s\n' "$gen_out" | grep -- '-G')"
fi

# REV-20260801-016 F2 required assertions for the single-cadence option.
sends=$(printf '%s\n' "$gen_out" | grep -c "snapget.sh")
if [ "$sends" = 1 ]; then
    ok "profile: exactly one send job per dataset"
else
    bad "profile: exactly one send job per dataset" "$sends"
fi
# No two sends for the same dataset may share a minute -- with one cadence that
# is structural, and the assertion is what keeps a future second tier from
# quietly reintroducing the 00:00 pile-up.
dupmin=$(printf '%s\n' "$gen_out" | grep "snapget.sh" | awk '{print $1,$2,$3,$4,$5}' | sort | uniq -d | wc -l)
[ "$dupmin" = 0 ] && ok "profile: no two send jobs share a schedule slot" \
                  || bad "profile: no two send jobs share a schedule slot" "$dupmin kolizji"
# Exactly one staleness check: only the finest tier carries thresholds, because
# a monitor on 'automated_daily' would watch a prefix nothing creates and sit at
# CRITICAL forever.
mons=$(printf '%s\n' "$gen_out" | grep -c "check-snap-age.sh")
if [ "$mons" = 1 ] && printf '%s\n' "$gen_out" | grep -q 'check-snap-age.sh -R "tank/backups/peer1" "automated_hourly"'; then
    ok "profile: exactly one monitor, on the prefix that actually exists"
else
    bad "profile: exactly one monitor, on the prefix that actually exists" \
        "$mons monitorow: $(printf '%s\n' "$gen_out" | grep -o 'check-snap-age.sh[^)]*' | cut -c1-70)"
fi

# --- 10. --bandwidth validation ---------------------------------------------
# mbuffer -r takes BYTES per second. A value that looks like a bit rate, or a
# typo, has to be refused here rather than in a cron line at 01:00.
bw_rc() { ( cmd_add_client "bwtest" --lan=10.0.0.1 --datasets="tank/x" --bandwidth="$1" ) >/dev/null 2>&1; echo $?; }
bw_bad=0
for v in "20Mb" "abc" "M20" "20MM" "" "20 M"; do
    [ "$(bw_rc "$v")" = 0 ] && bw_bad=$((bw_bad+1))
done
[ "$bw_bad" = 0 ] && ok "bandwidth: every malformed rate is refused" \
                  || bad "bandwidth: every malformed rate is refused" "$bw_bad wartosci przeszlo"

# --- 11. remove_template_section / migrate-profile building blocks ----------
#
# REV-20260801-016 F3: migration is an action of the tool, not template surgery
# by the administrator. ensure_cron_config deliberately never rewrites a
# template that is present, so the legacy ones have to be removed before the new
# families can go back -- that removal is the piece worth pinning.
MIG="$WORK/migrate"; mkdir -p "$MIG"
cat > "$MIG/legacy.conf" <<'EOF'
[defaults]
	host_label = oldhost

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24

[template:standard_daily]
	send_schedule  = 0 0 * * *
	prefix         = automated_daily_
	prune_schedule = 10 0 * * *
	pattern        = automated_daily
	retain         = -D7

[dataset:tank/backups/peer1/rpool/data]
	use_template = standard_hourly,standard_daily
	notify       = peer1-data
EOF
cp "$MIG/legacy.conf" "$MIG/work.conf"
remove_template_section "$MIG/work.conf" standard_hourly
remove_template_section "$MIG/work.conf" standard_daily
if ! grep -q '^\[template:standard_' "$MIG/work.conf"    && grep -q '^\[dataset:tank/backups/peer1/rpool/data\]' "$MIG/work.conf"    && grep -q '^\[defaults\]' "$MIG/work.conf"; then
    ok "migrate: remove_template_section drops the legacy templates and nothing else"
else
    bad "migrate: remove_template_section drops the legacy templates and nothing else" "$(cat "$MIG/work.conf")"
fi

# After removal, ensure_cron_config must recognise the file as NON-legacy and
# put the new families in -- that is the whole migration in two steps.
PROFILE_GFS=1
ensure_cron_config "$MIG/work.conf" >/dev/null 2>&1
if [ "${PROFILE_GFS:-}" = 1 ] && grep -q '^\[template:keep_monthly\]' "$MIG/work.conf"    && ! sed -n '/^\[template:standard_hourly\]/,/^\[/p' "$MIG/work.conf" | grep -q prune_schedule; then
    ok "migrate: the rebuilt config is on the GFS profile"
else
    bad "migrate: the rebuilt config is on the GFS profile" "PROFILE_GFS=${PROFILE_GFS:-unset}"
fi

# And the untouched legacy file must still read as legacy, so a host that never
# ran the migration keeps flat retention.
ensure_cron_config "$MIG/legacy.conf" >/dev/null 2>&1
[ "${PROFILE_GFS:-}" = 0 ] && ok "migrate: an unmigrated host still reads as legacy"                            || bad "migrate: an unmigrated host still reads as legacy" "PROFILE_GFS=${PROFILE_GFS:-unset}"

# --- 12. the dedicated collector account (--local-user) ---------------------
#
# Three things move together when the collector runs its jobs as a dedicated
# account, and getting one wrong is silent: which crontab the block lands in,
# whose alert/log paths the generated lines name, and who gen-cron.sh runs as.
# The stub records what was asked for so each can be checked.
LU="$WORK/localuser"; mkdir -p "$LU/bin"
cat > "$LU/bin/crontab" <<EOF
#!/bin/bash
echo "crontab \$*" >> "$LU/calls"
[ "\$1" = "-u" ] && exit 0
[ "\$1" = "-l" ] && exit 0
exit 0
EOF
chmod +x "$LU/bin/crontab"
lu_calls() { : > "$LU/calls"; }

# root (the default, and --local-user=root): plain `crontab -l`, no -u.
lu_calls
( LOCAL_USER=""; PATH="$LU/bin:$PATH"; crontab_for_target >/dev/null 2>&1 )
if grep -qx "crontab -l" "$LU/calls" && ! grep -q -- "-u" "$LU/calls"; then
    ok "local-user: with no dedicated account the block stays in root's crontab"
else
    bad "local-user: with no dedicated account the block stays in root's crontab" "$(cat "$LU/calls")"
fi

# a dedicated account: every read has to be -u <account>, or the preview would
# compare against the WRONG crontab and the install would land in another.
lu_calls
( LOCAL_USER="zfsbackup"; PATH="$LU/bin:$PATH"; crontab_for_target >/dev/null 2>&1 )
if grep -qx "crontab -u zfsbackup -l" "$LU/calls"; then
    ok "local-user: a dedicated account's own crontab is the one read"
else
    bad "local-user: a dedicated account's own crontab is the one read" "$(cat "$LU/calls")"
fi

lu_calls
( LOCAL_USER="zfsbackup"; PATH="$LU/bin:$PATH"; _restore_target_crontab /tmp/whatever >/dev/null 2>&1 )
if grep -qx "crontab -u zfsbackup /tmp/whatever" "$LU/calls"; then
    ok "local-user: a rollback restores the dedicated account's crontab, not root's"
else
    bad "local-user: a rollback restores the dedicated account's crontab, not root's" "$(cat "$LU/calls")"
fi

# The digest must NOT be duplicated into the account's block: deploy.sh gives it
# notify-fail/notify-warn but deliberately not alert-digest.sh, so root stays the
# only sender of the daily mail. gen-cron's digest_script=none is that opt-out,
# and this asserts the generator honours it.
dg=$(DIGEST_SCRIPT=none bash "$REPO/gen-cron.sh" -c "$PROF/gen.conf" 2>&1 | grep -c "alert-digest")
withdg=$(bash "$REPO/gen-cron.sh" -c "$PROF/gen.conf" 2>&1 | grep -c "alert-digest")
if [ "$dg" = 0 ] && [ "$withdg" = 1 ]; then
    ok "local-user: digest_script=none drops the digest line, and only then"
else
    bad "local-user: digest_script=none drops the digest line, and only then" "none=$dg default=$withdg"
fi

# --- 13. never create the config the installed block claims to come from ----
#
# Found live on pve2, 2026-08-01. Its crontab held 14 production jobs whose
# '# Source:' named a config in a directory that had since been deleted.
# setup-server adopted that path and CREATED it: templates only, no job
# sections. A missing config is SAFE (gen-cron -c refuses to run); a config that
# exists and describes nothing is armed, because --install replaces the whole
# managed block with whatever it generates. And
# assert_cron_config_matches_installed passes it, since the Source line does
# name that exact file -- it compares identity, not content.
SRC="$WORK/srcguard"; mkdir -p "$SRC/bin"
cat > "$SRC/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-l" ] || exit 0
echo "# BEGIN zfs-backup-managed"
echo "# Source: $SRC/gone.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "1 * * * * /root/scripts/zfs-snapshot-all/snapget.sh something"
echo "21 * * * * /root/scripts/zfs-snapshot-all/delsnaps.sh something"
echo "# END zfs-backup-managed"
EOF
chmod +x "$SRC/bin/crontab"

out=$( PATH="$SRC/bin:$PATH" LOCAL_USER="" bash -c "source '$ZFSBACKUP'; ensure_cron_config '$SRC/gone.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SRC/gone.conf" ]    && case "$out" in *"replace 2 live cron line"*) true ;; *) false ;; esac; then
    ok "src-guard: refuses to create the config the installed block came from, and counts what is at stake"
else
    bad "src-guard: refuses to create the config the installed block came from, and counts what is at stake" "rc=$rc created=$([ -e "$SRC/gone.conf" ] && echo tak || echo nie) out=$out"
fi

# A DIFFERENT path is not the claimed one, so creating it stays allowed --
# otherwise a host could never gain a second config at all.
out=$( PATH="$SRC/bin:$PATH" LOCAL_USER="" bash -c "source '$ZFSBACKUP'; ensure_cron_config '$SRC/other.conf'" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -e "$SRC/other.conf" ]; then
    ok "src-guard: an unrelated config path is still created normally"
else
    bad "src-guard: an unrelated config path is still created normally" "rc=$rc out=$out"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
