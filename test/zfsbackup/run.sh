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
# see docs/internal/reviews/responses/ for that evidence once it exists.
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

# REV-20260811-109 L0 targeted execution. `--section <id>` runs ONLY the named focused
# group and skips every unrelated earlier/later assertion, so a narrow REV-102/108/110
# audit correction can be iterated in seconds instead of the whole suite. No argument
# runs the FULL regression suite (L1) with equivalent coverage -- the targeted group
# is self-contained (it builds its own fixtures below) and is ALSO run by the full
# suite, so there is one source of truth, not a fork. Supported id: `retention` (the
# REV-102/108/110 source-retention audit group) and numeric aliases.
ONLY_SECTION=""
if [ "${1:-}" = "--section" ]; then ONLY_SECTION="${2:-}"; fi
case "$ONLY_SECTION" in
    ""|retention|57|58|59|102|108|110) ;;
    *) echo "unknown --section '$ONLY_SECTION' (known: retention | 57 | 58 | 59)" >&2; exit 2 ;;
esac

# Everything from here to the retention group is full-suite-only: skipped under a
# targeted --section run. The retention group (below the matching `fi`) is self-
# contained and always eligible.
if [ -z "$ONLY_SECTION" ]; then

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
if [ -f "$CF" ] && grep -q '^\[defaults\]' "$CF" && grep -q '^\[template:profile__default__standard_hourly\]' "$CF"    && ! grep -q '^\[template:profile__default__standard_daily\]' "$CF" && grep -q '^\[template:profile__default__keep_monthly\]' "$CF"; then
    ok "ensure_cron_config creates [defaults], one send tier, and the keep ladder"
else
    bad "ensure_cron_config creates [defaults], one send tier, and the keep ladder" "$(cat "$CF" 2>/dev/null)"
fi

before_lines=$(wc -l < "$CF")
ensure_cron_config "$CF"
after_lines=$(wc -l < "$CF")
hourly_count=$(grep -c '^\[template:profile__default__standard_hourly\]' "$CF")
if [ "$before_lines" = "$after_lines" ] && [ "$hourly_count" = "1" ]; then
    ok "ensure_cron_config is idempotent (no duplicate templates on a second call)"
else
    bad "ensure_cron_config is idempotent" "before=$before_lines after=$after_lines hourly_count=$hourly_count"
fi

# Phase 2 property 6 (ACTIVE-WORK-PLAN.md), corrected per REV-20260809-088:
# the collision check is CREATE-time only (check_new_template_collision=1,
# passed by activate-client ONLY on a relationship's first activation) and
# compares SEMANTICS, not raw text -- an ordinary re-activation call
# (the default, flag omitted/0) must never fail just because the active
# profile's current rendering differs from what is already installed.
real_section="$(profile_template_section "profile__default__standard_hourly")"
stale_section="$(printf '%s\n' "$real_section" | sed 's/^\(\tsend_schedule *= *\).*/\1 59 23 * * */')"
# A cosmetically different but semantically IDENTICAL rendering: reordered
# fields and a comment line -- accepted-but-cosmetic per profile_emit's own
# normalization (strips comment lines and blank lines, trims indentation);
# field order does not change CONFIG v4 lookup semantics. The comment is
# unindented (column 0), matching this project's own comment convention and
# what profile_emit's own '#'* case actually recognizes -- an indented '#'
# is not a comment to that normalizer, so it must not be used here either.
cosmetic_section="$(cat <<'EOF'
[template:profile__default__standard_hourly]
	notify_word    = backup
# reordered and commented, same fields
	prefix         = automated_hourly_
	send_schedule  = 1 * * * *
EOF
)"

# 1. Ordinary call (re-activation shape): DIFFERENT content on the ALREADY-
#    PRESENT template must NOT refuse, and that specific section must be
#    left exactly as installed -- independent of whatever the active
#    profile renders today. The fixture deliberately carries only this one
#    template, so ensure_cron_config legitimately appends the others
#    (keep_hourly etc.) and the reserved-prefix floors regardless; the
#    property under test is about THIS section, not the whole file.
CF3="$WORK/jobs.reactivation-stale.conf"
{ echo "[defaults]"; echo "	host_label = x"; echo; echo "$stale_section"; } > "$CF3"
out=$(ensure_cron_config "$CF3" 2>&1); rc=$?
after_section="$(cron_config_section "$CF3" "[template:profile__default__standard_hourly]")"
if [ "$rc" -eq 0 ] && [ "$after_section" = "$stale_section" ]; then
    ok "ensure_cron_config: an ordinary (re-activation) call never fails on profile drift, and never touches the installed section"
else
    bad "ensure_cron_config: an ordinary (re-activation) call never fails on profile drift, and never touches the installed section" "rc=$rc out=$out after=[$after_section]"
fi

# 2. CREATE-time call (flag=1), content matching the current profile exactly:
#    no false positive.
CF4="$WORK/jobs.create-matching.conf"
{ echo "[defaults]"; echo "	host_label = x"; echo; echo "$real_section"; } > "$CF4"
out=$(ensure_cron_config "$CF4" 1 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "ensure_cron_config: CREATE-time call reuses a template matching the current profile (no false positive)"
else
    bad "ensure_cron_config: CREATE-time call reuses a template matching the current profile (no false positive)" "rc=$rc out=$out"
fi

# 3. CREATE-time call, cosmetically different but SEMANTICALLY equal
#    rendering: reuse, not refuse -- Gate 2 says "identical SEMANTIC
#    template may be reused", not byte-identical text.
CF5="$WORK/jobs.create-cosmetic.conf"
{ echo "[defaults]"; echo "	host_label = x"; echo; echo "$cosmetic_section"; } > "$CF5"
out=$(ensure_cron_config "$CF5" 1 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "ensure_cron_config: CREATE-time call reuses a semantically-equal template despite cosmetic formatting differences"
else
    bad "ensure_cron_config: CREATE-time call reuses a semantically-equal template despite cosmetic formatting differences" "rc=$rc out=$out"
fi

# 4. CREATE-time call, genuinely different policy: refuses, leaves the file
#    untouched.
CF6="$WORK/jobs.create-conflict.conf"
{ echo "[defaults]"; echo "	host_label = x"; echo; echo "$stale_section"; } > "$CF6"
before_md5=$(md5sum "$CF6" | cut -d' ' -f1)
out=$(ensure_cron_config "$CF6" 1 2>&1); rc=$?
after_md5=$(md5sum "$CF6" | cut -d' ' -f1)
if [ "$rc" -ne 0 ] && [ "$before_md5" = "$after_md5" ] && case "$out" in *"different effective policy"*) true ;; *) false ;; esac; then
    ok "ensure_cron_config: CREATE-time call refuses a genuinely conflicting template and leaves the file untouched"
else
    bad "ensure_cron_config: CREATE-time call refuses a genuinely conflicting template and leaves the file untouched" "rc=$rc out=$out"
fi

# ENROLMENT-AGREED-2026-08-02 U6 / resolved question 2: a floor of 2
# protected NEWEST snapshots for every reserved prefix this estate's own
# scripts write, so the collector's own prune sweep can never age one out.
if grep -qF '[excluded:__replicate_]' "$CF" && grep -qF '[excluded:vzdump]' "$CF" && grep -qF '[excluded:__migration__]' "$CF" \
   && [ "$(sed -n '/^\[excluded:__replicate_\]/,/^\[/p' "$CF" | grep -c 'keep = 2')" = 1 ] \
   && [ "$(sed -n '/^\[excluded:vzdump\]/,/^\[/p' "$CF" | grep -c 'keep = 2')" = 1 ] \
   && [ "$(sed -n '/^\[excluded:__migration__\]/,/^\[/p' "$CF" | grep -c 'keep = 2')" = 1 ]; then
    ok "ensure_cron_config adds a keep=2 floor for all three reserved prefixes"
else
    bad "ensure_cron_config adds a keep=2 floor for all three reserved prefixes" "$(cat "$CF")"
fi

before_lines=$(wc -l < "$CF")
ensure_cron_config "$CF"
after_lines=$(wc -l < "$CF")
excl_count=$(grep -c '^\[excluded:' "$CF")
if [ "$before_lines" = "$after_lines" ] && [ "$excl_count" = 3 ]; then
    ok "ensure_cron_config's reserved-prefix floor is idempotent (no duplicate [excluded:] sections)"
else
    bad "ensure_cron_config's reserved-prefix floor is idempotent" "before=$before_lines after=$after_lines excl_count=$excl_count"
fi

# An operator who already protects a prefix more strongly is never narrowed.
CF_EXCL="$WORK/jobs.excl.conf"
printf '[defaults]\n\thost_label = x\n\n[excluded:vzdump]\n\tkeep = 10\n' > "$CF_EXCL"
ensure_cron_config "$CF_EXCL" >/dev/null 2>&1
if [ "$(grep -c 'keep = 10' "$CF_EXCL")" = 1 ] && grep -qF '[excluded:__replicate_]' "$CF_EXCL" && grep -qF '[excluded:__migration__]' "$CF_EXCL"; then
    ok "ensure_cron_config only ADDS a missing floor, never narrows an operator's stronger keep"
else
    bad "ensure_cron_config only ADDS a missing floor, never narrows an operator's stronger keep" "$(cat "$CF_EXCL")"
fi

# A file that already exists (hand-written) must never be touched/recreated --
# only the templates get appended if genuinely missing.
CF2="$WORK/jobs.existing.conf"
printf '[defaults]\n\thost_label = existing\n\n[dataset:rpool/other]\n\tuse_template = hourly\n' > "$CF2"
orig_md5=$(md5sum "$CF2" | cut -d' ' -f1)
ensure_cron_config "$CF2"
if grep -q 'host_label = existing' "$CF2" && grep -q 'dataset:rpool/other' "$CF2" && grep -q '^\[template:profile__default__standard_hourly\]' "$CF2"; then
    ok "ensure_cron_config appends templates to an existing hand-written file without disturbing it"
else
    bad "ensure_cron_config appends templates to an existing hand-written file without disturbing it" "$(cat "$CF2")"
fi

# --- 5. remove_managed_sections: removes ONLY the named sections ------------
# REV-20260802-033 U11: header text is no longer sufficient on its own -- a
# section is only removed if its first content line is the ownership marker
# emit_client_sections writes ("# managed-by: zfs-backup.sh client=<name>"),
# or the path was already recorded in the caller's own MANAGED_DATASETS
# (the legacy/back-compat path, tested separately below). These fixtures
# carry the marker, matching what emit_client_sections actually generates.
CF3="$WORK/jobs.remove.conf"
cat > "$CF3" <<'EOF'
[defaults]
	host_label = x

[template:standard_hourly]
	send_schedule = 1 * * * *

[dataset:hdd/backups/pve2/rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	use_template = standard_hourly
	notify       = pve2-data

[dataset:hdd/backups/pve3/rpool/data]
	# managed-by: zfs-backup.sh client=pve3
	use_template = standard_hourly
	notify       = pve3-data
EOF
remove_managed_sections "$CF3" "pve2" "hdd/backups/pve2/rpool/data"
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
	# managed-by: zfs-backup.sh client=x
	notify = a
[dataset:a/c]
	# managed-by: zfs-backup.sh client=x
	notify = b
[dataset:keep/me]
	notify = c
EOF
remove_managed_sections "$CF4" "x" "a/b" "a/c"
if ! grep -qF '[dataset:a/b]' "$CF4" && ! grep -qF '[dataset:a/c]' "$CF4" && grep -qF '[dataset:keep/me]' "$CF4"; then
    ok "remove_managed_sections handles multiple target sections in one call"
else
    bad "remove_managed_sections handles multiple target sections in one call" "$(cat "$CF4")"
fi

# --- 5b. remove_managed_sections: U11 ownership marker enforcement ----------
# A header match with NO marker and no prior MANAGED_DATASETS record looks
# hand-written -- refuse rather than silently delete it.
CF5="$WORK/jobs.foreign.conf"
cat > "$CF5" <<'EOF'
[dataset:tank/handwritten]
	use_template = custom
	notify       = someone
EOF
out=$( PATH="$PATH" bash -c "source '$ZFSBACKUP'; remove_managed_sections '$CF5' newclient tank/handwritten" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"looks hand-written"*) true ;; *) false ;; esac \
   && grep -qF '[dataset:tank/handwritten]' "$CF5"; then
    ok "remove_managed_sections refuses a header match with no marker and no prior record"
else
    bad "remove_managed_sections refuses a header match with no marker and no prior record" "rc=$rc out=$out file=$(cat "$CF5")"
fi

# The back-compat path: a section that predates the marker (no marker line
# at all) is still removed if the CALLER already recorded this exact path in
# its own MANAGED_DATASETS -- this is what keeps every client activated
# before U11 shipped working unchanged on its very next rewrite.
CF6="$WORK/jobs.legacy.conf"
cat > "$CF6" <<'EOF'
[dataset:tank/legacy/pve2/data]
	use_template = standard_hourly
	notify       = pve2-data
EOF
out=$( bash -c "source '$ZFSBACKUP'; MANAGED_DATASETS='tank/legacy/pve2/data'; remove_managed_sections '$CF6' pve2 tank/legacy/pve2/data" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '[dataset:tank/legacy/pve2/data]' "$CF6"; then
    ok "remove_managed_sections removes a marker-less section already recorded in MANAGED_DATASETS (legacy client)"
else
    bad "remove_managed_sections removes a marker-less section already recorded in MANAGED_DATASETS (legacy client)" "rc=$rc out=$out file=$(cat "$CF6" 2>/dev/null)"
fi

# A marker naming a DIFFERENT client is a real collision signal, not absence
# of a marker -- must also refuse (path-uniqueness makes this unlikely in
# practice, but a manual edit could still produce it).
CF7="$WORK/jobs.wrongowner.conf"
cat > "$CF7" <<'EOF'
[dataset:tank/shared]
	# managed-by: zfs-backup.sh client=otherclient
	notify = x
EOF
out=$( bash -c "source '$ZFSBACKUP'; remove_managed_sections '$CF7' thisclient tank/shared" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"looks hand-written"*) true ;; *) false ;; esac; then
    ok "remove_managed_sections refuses a header match whose marker names a different client"
else
    bad "remove_managed_sections refuses a header match whose marker names a different client" "rc=$rc out=$out"
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
    ok "active_endpoint_host_port resolves a LEGACY (slot-named) endpoint's host/port"
else
    bad "active_endpoint_host_port resolves a LEGACY (slot-named) endpoint's host/port" "out=$out"
fi

# REV-20260802-033 U9: a new-shape record carries the literal "host:port" in
# ACTIVE_ENDPOINT directly, no slot indirection -- distinguished from the
# legacy shape purely by the presence of ':' (never valid in a bare hostname).
out="$(bash -c "source '$ZFSBACKUP'; ACTIVE_ENDPOINT=10.8.0.11:2222; active_endpoint_host_port" 2>&1)"
if [ "$out" = "10.8.0.11 2222" ]; then
    ok "active_endpoint_host_port resolves a NEW-shape (literal host:port) endpoint (U9)"
else
    bad "active_endpoint_host_port resolves a NEW-shape (literal host:port) endpoint (U9)" "out=$out"
fi

out="$(bash -c "source '$ZFSBACKUP'; ACTIVE_ENDPOINT=10.8.0.11:2222 LOAD_HOST=10.8.0.11 LOAD_PORT=2222; endpoint_display" 2>&1)"
if [ "$out" = "10.8.0.11:2222" ]; then
    ok "endpoint_display shows a bare host:port for a new-shape record (nothing extra to add)"
else
    bad "endpoint_display shows a bare host:port for a new-shape record" "out=$out"
fi
out="$(bash -c "source '$ZFSBACKUP'; ACTIVE_ENDPOINT=vpn LOAD_HOST=10.8.0.11 LOAD_PORT=2222; endpoint_display" 2>&1)"
if [ "$out" = "vpn (10.8.0.11:2222)" ]; then
    ok "endpoint_display shows 'slot (host:port)' for a legacy record"
else
    bad "endpoint_display shows 'slot (host:port)' for a legacy record" "out=$out"
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

# --- final-catchup gate (REV-20260730-005 F3 / REV-20260731-007 §7), -------
# rebuilt on the U9 one-current-endpoint model (REV-20260802-033) -----------
#
# Switching a client's endpoint is the relocation moment. Without a final
# incremental over the link that still works, the first transfer over the new
# one carries everything since the SEED -- over the slow link, unattended.
# The gate makes that a decision instead of an accident. Under U9 there is
# only ONE current endpoint (a literal "host:port", no named slots), so every
# actual change goes through this same gate uniformly -- the old asymmetry
# ("correcting the inactive slot is not gated") no longer exists because
# there is no inactive slot to correct.
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
      echo "ACTIVE_ENDPOINT=10.0.0.9:22"
      echo "INSTALLED_ENDPOINT=10.0.0.9:22"
      echo 'SEED_COMPLETED_AT="2026-07-01 00:00:00"'
      for l in "$@"; do echo "$l"; done
    } > "$GATE/$n.conf"
}
gate_run() {    # gate_run <name> <args...>  -> prints output, sets $?
    ( CLIENTS_DIR="$GATE"; cmd_set_endpoint "$@" ) 2>&1
}

mk_client c1
out=$(gate_run c1 --host=10.9.9.9); r=$?
if [ "$r" != 0 ] && case "$out" in *"final-catchup c1"*) true ;; *) false ;; esac; then
    ok "gate: switching without a catch-up is refused, and names the command"
else
    bad "gate: switching without a catch-up is refused, and names the command" "rc=$r out=$out"
fi

# A catch-up recorded against the endpoint being LEFT is what makes the switch
# safe. Anything else -- including one recorded against the endpoint being
# switched TO -- says nothing about this switch. Under U9, FINAL_CATCHUP_ENDPOINT
# is now always the literal address it was recorded against (cmd_final_catchup),
# so this is a plain string match against ACTIVE_ENDPOINT's own domain.
mk_client c2 'FINAL_CATCHUP_ENDPOINT=10.0.0.9:22' 'FINAL_CATCHUP_HOST=10.0.0.9'              'FINAL_CATCHUP_PORT=22' "FINAL_CATCHUP_EPOCH=$(date '+%s')"              'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
out=$(gate_run c2 --host=10.9.9.9); r=$?
[ "$r" = 0 ] && ok "gate: a catch-up over the endpoint being left lets the switch through" \
             || bad "gate: a catch-up over the endpoint being left lets the switch through" "rc=$r out=$out"

mk_client c3 'FINAL_CATCHUP_ENDPOINT=10.9.9.9:22' 'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
out=$(gate_run c3 --host=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "gate: a catch-up over the WRONG endpoint does not count" \
              || bad "gate: a catch-up over the WRONG endpoint does not count" "rc=$r"

# The reviewer's case: the collector is already unplugged, so there is nothing
# to catch up over. Allowed, but it must warn -- and say what it will cost.
mk_client c4
out=$(gate_run c4 --host=10.9.9.9 --skip-final-catchup); r=$?
if [ "$r" = 0 ] && case "$out" in *SKIPPING*) true ;; *) false ;; esac; then
    ok "gate: --skip-final-catchup proceeds but warns"
else
    bad "gate: --skip-final-catchup proceeds but warns" "rc=$r out=$out"
fi

# U9's central claim, now directly testable: giving the ALREADY-current
# host:port is a no-op -- no gate, no catch-up demand, no state mutation.
# This is what makes "no set-endpoint call needed for a routed VPN" true by
# construction rather than by an operator simply not calling it.
mk_client c5
out=$(gate_run c5 --host=10.0.0.9:22); r=$?
if [ "$r" = 0 ] && case "$out" in *"already the current endpoint"*) true ;; *) false ;; esac; then
    ok "gate: giving the endpoint already on record is a no-op (U9)"
else
    bad "gate: giving the endpoint already on record is a no-op (U9)" "rc=$r out=$out"
fi

# ENDPOINT_KNOWN (U9): the address being left is remembered as a fallback
# candidate once the switch actually happens.
mk_client c6 'FINAL_CATCHUP_ENDPOINT=10.0.0.9:22' 'FINAL_CATCHUP_HOST=10.0.0.9'              'FINAL_CATCHUP_PORT=22' "FINAL_CATCHUP_EPOCH=$(date '+%s')"              'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
gate_run c6 --host=10.9.9.9 >/dev/null 2>&1
known=$(grep -m1 '^ENDPOINT_KNOWN=' "$GATE/c6.conf" 2>/dev/null || true)
if case "$known" in *"10.0.0.9:22"*) true ;; *) false ;; esac; then
    ok "set-endpoint records the address just left as a known candidate (U9)"
else
    bad "set-endpoint records the address just left as a known candidate (U9)" "$known"
fi

# A legacy record's dormant second slot (never migrated) is folded into
# ENDPOINT_KNOWN on its first switch, rather than silently lost.
mk_client c7 'ACTIVE_ENDPOINT=lan' 'ENDPOINT_LAN_HOST=10.0.0.9' 'ENDPOINT_LAN_PORT=22'          'ENDPOINT_VPN_HOST=10.9.9.5' 'ENDPOINT_VPN_PORT=1194'          'FINAL_CATCHUP_ENDPOINT=10.0.0.9:22' 'FINAL_CATCHUP_HOST=10.0.0.9'          'FINAL_CATCHUP_PORT=22' "FINAL_CATCHUP_EPOCH=$(date '+%s')"          'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
gate_run c7 --host=10.9.9.9:2222 >/dev/null 2>&1
known7=$(grep -m1 '^ENDPOINT_KNOWN=' "$GATE/c7.conf" 2>/dev/null || true)
if case "$known7" in *"10.0.0.9:22"*"10.9.9.5:1194"*) true ;; *"10.9.9.5:1194"*"10.0.0.9:22"*) true ;; *) false ;; esac; then
    ok "set-endpoint migrating a legacy record folds its dormant slot into ENDPOINT_KNOWN too"
else
    bad "set-endpoint migrating a legacy record folds its dormant slot into ENDPOINT_KNOWN too" "$known7"
fi

# --- catch-up freshness (REV-20260731-008 F1, simplified under U9) ----------
#
# The endpoint NAME alone was too weak a claim under the old lan/vpn model: it
# survived a change of host or port on that slot, and it never went stale.
# Under U9 there is no slot indirection left to exploit -- FINAL_CATCHUP_ENDPOINT
# IS the literal address -- so identity is now just the string match tested
# above (c3); what remains genuinely separate is freshness (age).

NOW=$(date '+%s')
mk_fresh() {   # mk_fresh <name> <age-seconds> [host:port]
    local n="$1" age="$2" hp="${3:-10.0.0.9:22}"
    mk_client "$n"         "FINAL_CATCHUP_ENDPOINT=$hp"         "FINAL_CATCHUP_EPOCH=$((NOW - age))"         'FINAL_CATCHUP_AT="2026-07-31 10:00:00"'
}

mk_fresh f1 60
out=$(gate_run f1 --host=10.9.9.9); r=$?
[ "$r" = 0 ] && ok "fresh: a 1-minute-old catch-up against the exact endpoint passes"              || bad "fresh: a 1-minute-old catch-up against the exact endpoint passes" "rc=$r out=$out"

mk_fresh f2 7200
out=$(gate_run f2 --host=10.9.9.9); r=$?
if [ "$r" != 0 ] && case "$out" in *"120 min old"*) true ;; *) false ;; esac; then
    ok "stale: a 2-hour-old catch-up is refused, and the age is named"
else
    bad "stale: a 2-hour-old catch-up is refused, and the age is named" "rc=$r out=$out"
fi

# The override exists because relocation plans slip; it must not be silent.
mk_fresh f5 7200
out=$(gate_run f5 --host=10.9.9.9 --allow-stale-catchup); r=$?
if [ "$r" = 0 ] && case "$out" in *"--allow-stale-catchup"*) true ;; *) false ;; esac; then
    ok "override: --allow-stale-catchup proceeds but says what it costs"
else
    bad "override: --allow-stale-catchup proceeds but says what it costs" "rc=$r out=$out"
fi

# A record written before freshness tracking existed has no epoch, so its age
# is unknowable -- treat that as unproven rather than as fresh.
mk_client f6 "FINAL_CATCHUP_ENDPOINT=10.0.0.9:22"
out=$(gate_run f6 --host=10.9.9.9); r=$?
[ "$r" != 0 ] && ok "legacy: a record with no epoch is not treated as fresh"               || bad "legacy: a record with no epoch is not treated as fresh" "rc=$r"

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
if grep -q "^\[template:profile__default__keep_hourly\]" "$PROF/fresh.conf" \
   && grep -q "^\[template:profile__default__standard_hourly\]" "$PROF/fresh.conf" \
   && [ "${PROFILE_GFS:-}" = 1 ] \
   && ! sed -n '/^\[template:profile__default__standard_hourly\]/,/^\[/p' "$PROF/fresh.conf" | grep -q prune_schedule; then
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
# Slice B1 / owner option 3 changed the answer here, and the change IS the
# point: the pre-GFS shape is FROZEN, so ordinary activation REFUSES rather
# than leaving the host quietly half-configured. Silently handing it the GFS
# ladder would prune the same snapshots twice on the same schedule.
#
# The call runs in a SUBSHELL because the refusal is a die(): sourced straight
# into the harness it takes the whole suite down -- which is exactly what
# happened while writing this. 88 of 292 cases ran and there was no summary
# line at all to say so, so "4 failures" was a floor, not a result.
legacy_md5_before=$(md5sum "$PROF/legacy.conf" | cut -d' ' -f1)
legacy_out=$( ensure_cron_config "$PROF/legacy.conf" 2>&1 ); legacy_rc=$?
legacy_md5_after=$(md5sum "$PROF/legacy.conf" | cut -d' ' -f1)
if [ "$legacy_rc" -ne 0 ]; then
    ok "profile: a pre-GFS config is REFUSED by ordinary activation, not converted"
else
    bad "profile: a pre-GFS config is REFUSED by ordinary activation, not converted" "rc=$legacy_rc"
fi
# A refusal that mutated the file on its way out would be the worst of both.
if [ "$legacy_md5_before" = "$legacy_md5_after" ]; then
    ok "profile: the pre-GFS refusal leaves the config byte-identical"
else
    bad "profile: the pre-GFS refusal leaves the config byte-identical"
fi
# A frozen profile with no stated way out is just a wall.
case "$legacy_out" in
    *migrate-profile*) ok "profile: the pre-GFS refusal names migrate-profile as the way out" ;;
    *) bad "profile: the pre-GFS refusal names migrate-profile as the way out" "$legacy_out" ;;
esac
if ! grep -q "^\[template:profile__default__keep_" "$PROF/legacy.conf"; then
    ok "profile: no ladder is injected into a pre-GFS config"
else
    bad "profile: no ladder is injected into a pre-GFS config"
fi

# remove_managed_sections has to see [prune:] too, or a re-activation appends a
# second ladder over the same scope on the same schedule.
cat > "$PROF/rm.conf" <<'EOF'
[defaults]
	host_label = h

[prune:tank/backups/peer1]
	# managed-by: zfs-backup.sh client=peer1
	use_template = keep_hourly
	gfs          = yes

[dataset:tank/other]
	use_template = standard_hourly
EOF
remove_managed_sections "$PROF/rm.conf" "peer1" "tank/backups/peer1"
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
	use_template = profile__default__standard_hourly
	src          = robot@10.0.0.1:rpool/data
	notify       = peer1-data

[prune:tank/backups/peer1]
	use_template = profile__default__keep_hourly,profile__default__keep_daily,profile__default__keep_weekly,profile__default__keep_monthly
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
# -P "...:2" x3: ensure_cron_config's reserved-prefix floor (U6, tested in
# section 4) applies globally, so it rides on this ladder line too, between
# the recursion flag and the scope.
if printf '%s\n' "$gen_out" | grep -q -- '-G -R -P "__replicate_:2" -P "vzdump:2" -P "__migration__:2" "tank/backups/peer1" "automated_" -H24 -D7 -W4 -M12'; then
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
if [ "${PROFILE_GFS:-}" = 1 ] && grep -q '^\[template:profile__default__keep_monthly\]' "$MIG/work.conf"    && ! sed -n '/^\[template:profile__default__standard_hourly\]/,/^\[/p' "$MIG/work.conf" | grep -q prune_schedule; then
    ok "migrate: the rebuilt config is on the GFS profile"
else
    bad "migrate: the rebuilt config is on the GFS profile" "PROFILE_GFS=${PROFILE_GFS:-unset}"
fi

# And the untouched legacy file must still read as legacy, so a host that never
# ran the migration keeps flat retention.
# And the untouched legacy file must still be REFUSED, so a host that never ran
# the migration is never quietly converted by an ordinary activation. Subshell
# again -- the refusal is a die().
mig_legacy_md5=$(md5sum "$MIG/legacy.conf" | cut -d' ' -f1)
( ensure_cron_config "$MIG/legacy.conf" >/dev/null 2>&1 ); mig_legacy_rc=$?
if [ "$mig_legacy_rc" -ne 0 ] && [ "$mig_legacy_md5" = "$(md5sum "$MIG/legacy.conf" | cut -d' ' -f1)" ]; then
    ok "migrate: an unmigrated host is still refused, and left untouched"
else
    bad "migrate: an unmigrated host is still refused, and left untouched" "rc=$mig_legacy_rc"
fi

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

# --- 14. snapget local-base parity with gen-cron -----------------------------
#
# snapget.sh's second argument is the local BASE and it appends the source's own
# dataset path underneath. gen-cron.sh derives that base by stripping the source
# path off a [dataset:] section; this wrapper passed the FINAL path instead, so
# seed/verify-endpoint/test wrote and read one level too deep.
#
# Found live 2026-08-01: seed put 40MB at
#   .../uxtest/<label>/hdd/backuptest_targets/uxsrc/hdd/backuptest_targets/uxsrc
# while the generated job targeted .../uxtest/<label>/hdd/backuptest_targets/uxsrc
# -- PLAN=INCREMENTAL base=null, a full transfer every run, with verify-endpoint
# reporting success because it looked in the same wrong place.
#
# Asserted as PARITY against the real generator rather than as a literal string:
# the two sides have to agree, and which convention they agree on is gen-cron's
# to define.
PEER_SAVED_TARGET="hdd/backuptest_targets/uxtest"
LOAD_LABEL="192.168.28.8"
pb_ds="hdd/backuptest_targets/uxsrc"
wrapper_base=$(snapget_local_base)

cat > "$WORK/parity.conf" <<EOF
[defaults]
	host_label = h

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup

[dataset:$PEER_SAVED_TARGET/$LOAD_LABEL/$pb_ds]
	use_template = standard_hourly
	src          = robot@10.0.0.1:$pb_ds
	notify       = p
EOF
# The last quoted argument of the emitted snapget line IS the local base.
" "~" | cut -c1-200)"
# One sed, no `grep -m1`: an early-exiting grep in a pipeline under `pipefail`
# (inherited from the sourced zfs-backup.sh) sends gen-cron a SIGPIPE and the
# substitution comes back empty -- which reads exactly like "the generator
# emitted nothing" and cost a debugging round to tell apart.
gencron_base=$(bash "$REPO/gen-cron.sh" -c "$WORK/parity.conf" 2>/dev/null | awk '/snapget/{sub(/ 2>.*/,""); n=split($0,a,"\""); print a[n-1]; exit}')
if [ -n "$gencron_base" ] && [ "$wrapper_base" = "$gencron_base" ]; then
    ok "snapget-base: the wrapper and gen-cron agree on the local base"
else
    bad "snapget-base: the wrapper and gen-cron agree on the local base"         "wrapper='$wrapper_base' gen-cron='$gencron_base'"
fi
# And the base must NOT carry the dataset suffix, which is the shape of the bug.
case "$wrapper_base" in
    *"$pb_ds") bad "snapget-base: the base must not repeat the source dataset path" "$wrapper_base" ;;
    *)         ok "snapget-base: the base must not repeat the source dataset path" ;;
esac
# No call site may pass the final path again.
leftover=$(grep -c 'SNAPGET" .*:\${ds}" "\$localpath"' "$ZFSBACKUP")
[ "$leftover" = 0 ] && ok "snapget-base: no call site passes the final dataset path as the base"                     || bad "snapget-base: no call site passes the final dataset path as the base" "$leftover"

# --- 15. gencron_as_target passes argv, never a shell sentence ---------------
#
# REV-20260801-017 F1. The old form built `su -c "... bash gen-cron.sh $*"`,
# handing the target account's shell a sentence to re-parse. A config path with
# a space arrived as two arguments; a metacharacter arrived as something else
# entirely -- and the preview would then have validated a different file from
# the one installed. The stub records its own argv with a separator, so
# "one argument" is checkable rather than assumed.
AV="$WORK/argv"; mkdir -p "$AV/bin"
cat > "$AV/bin/runuser" <<EOF
#!/bin/bash
: > "$AV/argv"
for a in "\$@"; do printf '%s\n' "\$a" >> "$AV/argv"; done
exit 0
EOF
chmod +x "$AV/bin/runuser"
cat > "$AV/bin/getent" <<'EOF'
#!/bin/bash
[ "$1" = passwd ] && echo "zfsbackup:x:1001:1001::/home/zfsbackup:/bin/bash"
exit 0
EOF
chmod +x "$AV/bin/getent"

# A path with a space AND a quote -- both legal in a filename, both fatal to a
# re-parsed shell string.
nasty="$WORK/con fig's.conf"
: > "$nasty"
( LOCAL_USER="zfsbackup"; GENCRON="$REPO/gen-cron.sh"; PATH="$AV/bin:$PATH"
  gencron_as_target -c "$nasty" --install ) >/dev/null 2>&1

if [ "$(grep -cxF "$nasty" "$AV/argv")" = 1 ]; then
    ok "argv: the config path arrives as exactly one argument, spaces and quotes intact"
else
    bad "argv: the config path arrives as exactly one argument, spaces and quotes intact" "$(cat "$AV/argv")"
fi
# The account's own alert paths must ride along, and the digest must be off.
if grep -qxF "DIGEST_SCRIPT=none" "$AV/argv" && grep -qxF "NOTIFY_SCRIPT=/home/zfsbackup/notify-fail.sh" "$AV/argv"; then
    ok "argv: the account's alert paths are passed, with the digest disabled"
else
    bad "argv: the account's alert paths are passed, with the digest disabled" "$(cat "$AV/argv")"
fi
# And nothing may have been split: --install stays its own argument.
[ "$(grep -cxF -- "--install" "$AV/argv")" = 1 ] \
    && ok "argv: later flags are not merged or re-split" \
    || bad "argv: later flags are not merged or re-split" "$(cat "$AV/argv")"

# --- 16. moving to a dedicated account must not duplicate root's jobs -------
#
# REV-20260801-018/-019. The first version of this guard compared the
# normalized '# Source:' PATH, and the reviewer's objection is that a real
# migration always changes that path: a delegated account cannot read a config
# under /root (0700), so the documented move puts it in /etc/zfs-snapshot-all/.
# Copy rather than move -- the more natural reflex -- and two paths then
# describe one workload, the guard says "unrelated", and every send/prune/
# monitor runs twice.
#
# So the property under test is now workload overlap, not pathname equality.
# gencron_as_target is stubbed: what is under test is the comparison, not
# gen-cron.
DUP="$WORK/dupguard"; mkdir -p "$DUP/bin"
_dup_crontab_from() {   # <file holding root's crontab>
    cat > "$DUP/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && exit 0
[ "\$1" = "-l" ] && cat "$1"
exit 0
EOF
    chmod +x "$DUP/bin/crontab"
}

# The reviewer's exact regression case: different config paths, same jobs.
cat > "$DUP/root.cron" <<'EOF'
# BEGIN zfs-backup-managed
# Source: /root/scripts/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m "automated_hourly_" "tank/a" 2>>/root/scripts/cron.log
9 * * * * /root/scripts/zfs-snapshot-all/delsnaps.sh "tank/a" "automated_hourly" -H24 2>>/root/scripts/cron.log
# END zfs-backup-managed
EOF
cat > "$DUP/proposal.txt" <<'EOF'
# BEGIN zfs-backup-managed
# Source: /etc/zfs-snapshot-all/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "automated_hourly_" "tank/a" 2>>/home/zfsbackup/cron.log
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "tank/a" "automated_hourly" -H24 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
_dup_crontab_from "$DUP/root.cron"
: > "$DUP/etc-jobs.conf"

out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/proposal.txt'; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"2 job line(s) overlap"*) true ;; *) false ;; esac \
   && case "$out" in *"migrate-to-account"*) true ;; *) false ;; esac; then
    ok "dup-guard: a DIFFERENT config path with the same jobs is still refused"
else
    bad "dup-guard: a DIFFERENT config path with the same jobs is still refused" "rc=$rc out=$out"
fi

# ...and the refusal must NAME the overlapping lines. An operator who cannot see
# which jobs collide cannot decide anything about them.
case "$out" in
    *"snapsend.sh"*"tank/a"*) ok "dup-guard: the overlapping job lines are printed" ;;
    *) bad "dup-guard: the overlapping job lines are printed" "$out" ;;
esac

# Two collectors on one host with genuinely disjoint jobs is a real deployment,
# not an accident, and must stay possible.
cat > "$DUP/disjoint.txt" <<'EOF'
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "automated_hourly_" "tank/OTHER" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
# NARROWED per REV-20260801-021: this guard answering "not a duplicate" does NOT
# authorise the install. Whether the install would DELETE what the target runs is
# a different question -- assert_target_block_not_clobbered, section 26.
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/disjoint.txt'; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "dup-guard: disjoint jobs are not a DUPLICATE (says nothing about clobbering)" \
                || bad "dup-guard: disjoint jobs are not a DUPLICATE (says nothing about clobbering)" "rc=$rc out=$out"

# The same path with the same jobs was always caught and must stay caught.
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/proposal.txt'; }; assert_no_foreign_managed_block '/root/scripts/jobs.conf'" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "dup-guard: the same config path with the same jobs is still refused" \
                || bad "dup-guard: the same config path with the same jobs is still refused" "rc=$rc out=$out"

# Staying as root is the normal case and must not be blocked by its own block.
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/proposal.txt'; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "dup-guard: root installing over its own block is untouched" \
                || bad "dup-guard: root installing over its own block is untouched" "rc=$rc out=$out"

# A proposal that cannot be rendered leaves overlap UNKNOWN. Fail closed rather
# than read an empty render as "nothing overlaps" (REV-20260801-019 point 5).
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { return 1; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"could not be rendered"*) true ;; *) false ;; esac; then
    ok "dup-guard: an unrenderable proposal fails closed"
else
    bad "dup-guard: an unrenderable proposal fails closed" "rc=$rc out=$out"
fi

# An unreadable root crontab is not an empty one -- same rule as the preview.
cat > "$DUP/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && exit 0
echo "crontab: cannot open spool: Permission denied" >&2
exit 1
EOF
chmod +x "$DUP/bin/crontab"
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/proposal.txt'; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"unreadable crontab is not an empty one"*) true ;; *) false ;; esac; then
    ok "dup-guard: an unreadable root crontab fails closed"
else
    bad "dup-guard: an unreadable root crontab fails closed" "rc=$rc out=$out"
fi

# "no crontab for X" is the one benign failure and must NOT abort.
cat > "$DUP/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && exit 0
echo "no crontab for root" >&2
exit 1
EOF
chmod +x "$DUP/bin/crontab"
out=$( PATH="$DUP/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$DUP/proposal.txt'; }; assert_no_foreign_managed_block '$DUP/etc-jobs.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "dup-guard: 'no crontab' is benign, not a refusal" \
                || bad "dup-guard: 'no crontab' is benign, not a refusal" "rc=$rc out=$out"

# job_identity must strip exactly WHO runs a line and nothing that decides WHAT
# it does. Retention flags in particular have to survive: if two different
# ladders fingerprinted the same, a real difference would read as a duplicate.
ja=$(printf '%s\n' '9 * * * * /root/scripts/zfs-snapshot-all/delsnaps.sh "t/a" "p" -H24 2>>/root/scripts/cron.log' \
     | bash -c "source '$ZFSBACKUP'; job_identity")
jb=$(printf '%s\n' '9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "t/a" "p" -H24 2>>/home/zfsbackup/cron.log' \
     | bash -c "source '$ZFSBACKUP'; job_identity")
jc=$(printf '%s\n' '9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "t/a" "p" -H48 2>>/home/zfsbackup/cron.log' \
     | bash -c "source '$ZFSBACKUP'; job_identity")
[ "$ja" = "$jb" ] && ok "job-identity: the same job under two owners fingerprints identically" \
                  || bad "job-identity: the same job under two owners fingerprints identically" "a=$ja b=$jb"
[ "$ja" != "$jc" ] && ok "job-identity: a different retention flag is a different job" \
                   || bad "job-identity: a different retention flag is a different job" "a=$ja c=$jc"

# --- 17. the dedicated account must be able to READ the config --------------
#
# gen-cron.sh runs AS that account. The default config path is
# $SCRIPT_DIR/jobs.<host>.conf, i.e. /root/scripts/... on a Proxmox host, and
# /root is 0700 -- found on metropolis pve1, 2026-08-01. The install would have
# failed AFTER the preview was shown and accepted, which is the worst moment.
RD="$WORK/readable"; mkdir -p "$RD/bin"
# The stub answers for `runuser --user <u> -- test -r <file>`: readable only if
# the path is under $RD/ok.
cat > "$RD/bin/runuser" <<EOF
#!/bin/bash
f="\${!#}"
case "\$f" in "$RD/ok/"*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$RD/bin/runuser"
mkdir -p "$RD/ok"; : > "$RD/ok/reachable.conf"; : > "$RD/unreachable.conf"

out=$( PATH="$RD/bin:$PATH" LOCAL_USER="zfsbackup" bash -c "source '$ZFSBACKUP'; assert_config_readable_by_target '$RD/unreachable.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"cannot read"*) true ;; *) false ;; esac \
   && case "$out" in *"/etc/zfs-snapshot-all/"*) true ;; *) false ;; esac; then
    ok "readable: an unreadable config is refused, and a working location is named"
else
    bad "readable: an unreadable config is refused, and a working location is named" "rc=$rc out=$out"
fi

out=$( PATH="$RD/bin:$PATH" LOCAL_USER="zfsbackup" bash -c "source '$ZFSBACKUP'; assert_config_readable_by_target '$RD/ok/reachable.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "readable: a config the account can open passes" \
                || bad "readable: a config the account can open passes" "rc=$rc out=$out"

# As root the question does not arise, and the check must not invent one.
out=$( PATH="$RD/bin:$PATH" LOCAL_USER="" bash -c "source '$ZFSBACKUP'; assert_config_readable_by_target '$RD/unreachable.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "readable: root is not asked whether it can read its own config" \
                || bad "readable: root is not asked whether it can read its own config" "rc=$rc out=$out"

# --- 18. the dedicated account runs ITS OWN checkout ------------------------
#
# /root is 0700 on a Proxmox host, so a delegated account cannot read
# /root/scripts/zfs-snapshot-all at all -- neither gen-cron.sh nor the
# snapget.sh/delsnaps.sh the generated lines would name. deploy.sh
# --backup-user provisions $HOME/zfs-snapshot-all for that reason. Found live on
# metropolis pve1, 2026-08-01: the install failed AFTER the preview was
# accepted, and only the crontab rollback kept it from being a mess.
OWN="$WORK/owncheckout"; mkdir -p "$OWN/bin" "$OWN/home/zfs-snapshot-all"
: > "$OWN/home/zfs-snapshot-all/gen-cron.sh"
cat > "$OWN/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "acct:x:1001:1001::$OWN/home:/bin/bash"
exit 0
EOF
cat > "$OWN/bin/runuser" <<EOF
#!/bin/bash
# test -r answers honestly; anything else records argv and succeeds
if [ "\$4" = "test" ]; then [ -r "\$6" ]; exit \$?; fi
: > "$OWN/argv"; for a in "\$@"; do printf '%s\n' "\$a" >> "$OWN/argv"; done
exit 0
EOF
chmod +x "$OWN/bin/getent" "$OWN/bin/runuser"

( LOCAL_USER="acct"; GENCRON="/root/scripts/zfs-snapshot-all/gen-cron.sh"; PATH="$OWN/bin:$PATH"
  gencron_as_target -c /etc/x.conf --install ) >/dev/null 2>&1
if grep -qxF "$OWN/home/zfs-snapshot-all/gen-cron.sh" "$OWN/argv" 2>/dev/null \
   && ! grep -q "/root/scripts" "$OWN/argv" 2>/dev/null; then
    ok "own-checkout: the account's own gen-cron.sh is run, never root's"
else
    bad "own-checkout: the account's own gen-cron.sh is run, never root's" "$(cat "$OWN/argv" 2>/dev/null)"
fi

# Missing checkout: refuse and say how to provision it, rather than failing
# later inside gen-cron with a permissions error nobody can read.
rm -f "$OWN/home/zfs-snapshot-all/gen-cron.sh"
out=$( LOCAL_USER="acct"; GENCRON="/root/x.sh"; PATH="$OWN/bin:$PATH"; gencron_as_target -c /etc/x.conf 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"--backup-user=acct"*) true ;; *) false ;; esac; then
    ok "own-checkout: a missing account checkout is refused with the command that fixes it"
else
    bad "own-checkout: a missing account checkout is refused with the command that fixes it" "rc=$rc out=$out"
fi

# --- 19. rewrites must not silently re-mode the config ----------------------
#
# The rewrite idiom is `tmp=$(mktemp); ...; mv -f "$tmp" "$file"`, and mktemp
# creates 0600. Every section removal therefore re-moded the config to
# root-only. On a collector with a dedicated account that is fatal and nearly
# invisible: gen-cron runs AS the account and reports "Permission denied" on a
# config in a world-readable directory, several steps after whatever last
# rewrote it. Found on metropolis pve1, 2026-08-01, after chmod'ing the file by
# hand twice and watching it go back to 600 both times.
MODE="$WORK/mode"; mkdir -p "$MODE"
printf '[dataset:a/b]\n\t# managed-by: zfs-backup.sh client=modetest\n\tnotify = x\n[dataset:keep/me]\n\t# managed-by: zfs-backup.sh client=modetest2\n\tnotify = y\n' > "$MODE/cfg.conf"
chmod 0644 "$MODE/cfg.conf"
remove_managed_sections "$MODE/cfg.conf" "modetest" "a/b"
got=$(stat -c %a "$MODE/cfg.conf")
if [ "$got" = 644 ] && grep -q 'keep/me' "$MODE/cfg.conf" && ! grep -q 'dataset:a/b' "$MODE/cfg.conf"; then
    ok "mode: removing a section keeps the config readable and removes the right one"
else
    bad "mode: removing a section keeps the config readable and removes the right one" "mode=$got"
fi
# A deliberately tight mode must survive too -- this PRESERVES, it does not
# impose a policy of its own. Asserted as "unchanged" rather than as a literal:
# MSYS cannot represent 0600 at all (chmod 600 reads back as 644), so a literal
# would be testing the filesystem. The same limitation means the ORIGINAL defect
# is invisible on Windows -- there every file is already 644 and the mktemp
# rewrite loses nothing. On Linux, where the live obligations run, it bites.
chmod 0600 "$MODE/cfg.conf"
mode_before=$(stat -c %a "$MODE/cfg.conf")
remove_managed_sections "$MODE/cfg.conf" "modetest2" "keep/me"
mode_after=$(stat -c %a "$MODE/cfg.conf")
[ "$mode_before" = "$mode_after" ] && ok "mode: whatever the mode was, a rewrite keeps it" \
                 || bad "mode: whatever the mode was, a rewrite keeps it" "przed=$mode_before po=$mode_after"

# --- 20. the account's logrotate must cover what the account's cron writes ---
#
# contract:account-paths. Every generated job line redirects into $CRON_LOG,
# which for a non-root target is $HOME/cron.log. deploy.sh's account stanza
# listed only git-pull.log and zfs-snapshot-stats.log -- correct while the
# account only ever ran git-pull and receive-side work, wrong the moment a
# managed cron block can be installed FOR the account. Found on metropolis
# pve1, 2026-08-01, while planning the migration of root's block: root's
# equivalent log was 250 KB after one day. An unrotated log alerts nobody; it
# just fills the filesystem months later.
# NOT named DEPLOY: zfs-backup.sh sets that itself, and this suite sources it,
# so an env override would be silently clobbered by the code under test.
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
acct_stanza=$(sed -n '/^\$LOGROTATE_MARKER -- managed by deploy.sh/,/^}/p' "$DEPLOY_SRC" \
              | grep -A6 'HOMEDIR/')
if printf '%s' "$acct_stanza" | grep -q 'HOMEDIR/cron\.log'; then
    ok "logrotate: the account stanza rotates \$HOME/cron.log"
else
    bad "logrotate: the account stanza rotates \$HOME/cron.log" "$acct_stanza"
fi

# Root's stanza and the account's must rotate the same THREE logical files.
# They differ only in location and ownership; a file appearing in one and not
# the other is the drift this contract exists to catch.
for log in cron.log git-pull.log zfs-snapshot-stats.log; do
    r=$(grep -c "^/root/scripts/$log\$" "$DEPLOY_SRC")
    a=$(grep -c "^\\\$HOMEDIR/$log\$" "$DEPLOY_SRC")
    [ "$r" -ge 1 ] && [ "$a" -ge 1 ] \
        && ok "logrotate: $log is rotated for both root and the account" \
        || bad "logrotate: $log is rotated for both root and the account" "root=$r konto=$a"
done

# A changed stanza that keeps its marker is invisible: deploy.sh reports
# "already current" and no existing host ever gets the fix. Pin the bump.
if grep -q 'LOGROTATE_MARKER="# zfs-snapshot-all \$USERNAME logrotate v2"' "$DEPLOY_SRC"; then
    ok "logrotate: the account stanza marker was bumped past v1"
else
    bad "logrotate: the account stanza marker was bumped past v1" \
        "$(grep -n 'USERNAME logrotate' "$DEPLOY_SRC")"
fi


# --- 21. host-level jobs are tool-owned state, not a remembered exception ----
#
# REV-20260801-020 F2. The digest is deliberately one-per-host and is never
# provisioned to a delegated account, so when the collector block moves those
# lines have nowhere to go. The first attempt parked them in root's crontab as
# ordinary unmanaged lines; the reviewer's objection is that this splits one
# deployment between tool-owned and human-remembered state -- a second
# migration would duplicate them, and no preview could show the whole change.
HB="$WORK/hostblock"; mkdir -p "$HB"
cat > "$HB/cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
1 * * * * something
# END zfs-backup-managed
EOF
printf '0 7 * * * /root/scripts/alert-digest.sh\n' > "$HB/lines"

( source "$ZFSBACKUP"; set_host_block "$HB/cron" "$HB/lines" ) >/dev/null 2>&1
n=$(grep -c 'BEGIN zfs-backup-host' "$HB/cron")
if [ "$n" -eq 1 ] && grep -q 'alert-digest.sh' "$HB/cron" && grep -q 'check-pool-capacity' "$HB/cron"; then
    ok "host-block: inserted once, and the unmanaged lines around it are untouched"
else
    bad "host-block: inserted once, and the unmanaged lines around it are untouched" "$(cat "$HB/cron")"
fi

# Idempotent: running it again must REPLACE the block, not stack a second one.
# A migration that ran twice is exactly how the reviewer expected duplicates.
( source "$ZFSBACKUP"; set_host_block "$HB/cron" "$HB/lines" ) >/dev/null 2>&1
( source "$ZFSBACKUP"; set_host_block "$HB/cron" "$HB/lines" ) >/dev/null 2>&1
n=$(grep -c 'BEGIN zfs-backup-host' "$HB/cron"); d=$(grep -c 'alert-digest.sh' "$HB/cron")
if [ "$n" -eq 1 ] && [ "$d" -eq 1 ]; then
    ok "host-block: repeated writes replace the block instead of accumulating"
else
    bad "host-block: repeated writes replace the block instead of accumulating" "bloki=$n digest=$d"
fi

# CONTRACT CHANGED, REV-20260802-034 F1. An empty line set used to REMOVE the
# block, which was right while this script owned it alone. It no longer does:
# deploy.sh puts the updater, the capacity check and the account auto-pull in
# the same block, and "this migration rescued nothing" must not be allowed to
# mean "that block should go".
: > "$HB/empty"
cp "$HB/cron" "$HB/cron.before"
( source "$ZFSBACKUP"; set_host_block "$HB/cron" "$HB/empty" ) >/dev/null 2>&1
if cmp -s "$HB/cron.before" "$HB/cron"; then
    ok "host-block: an empty contribution leaves the block exactly as it was"
else
    bad "host-block: an empty contribution leaves the block exactly as it was" "$(diff "$HB/cron.before" "$HB/cron")"
fi

# THE DEPLOYED SHAPE, which the old fixture did not model: the reviewer's point
# was that leaving check-pool-capacity LOOSE made wholesale replacement look
# harmless. Since 2026-08-02 the host block really contains three lines that
# belong to deploy.sh, and the migration arrives carrying only the digest.
cat > "$HB/real" <<'EOF'
# BEGIN zfs-backup-host (host-level jobs kept by zfs-backup.sh -- do not hand-edit)
15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update >>/root/scripts/git-pull.log 2>&1
0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log
# END zfs-backup-host
# BEGIN zfs-backup-managed
1 * * * * something
# END zfs-backup-managed
EOF
( source "$ZFSBACKUP"; set_host_block "$HB/real" "$HB/lines" ) >/dev/null 2>&1
u=$(grep -c 'update-control.sh --self-update' "$HB/real")
c=$(grep -c 'check-pool-capacity' "$HB/real")
d=$(grep -c 'alert-digest' "$HB/real")
j=$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$HB/real" | grep -cE '^[0-9*]')
if [ "$u" = 1 ] && [ "$c" = 1 ] && [ "$d" = 1 ] && [ "$j" = 3 ]; then
    ok "host-block: a migration carrying one line does not evict deploy.sh's two"
else
    bad "host-block: a migration carrying one line does not evict deploy.sh's two"         "updater=$u capacity=$c digest=$d w bloku=$j"
fi
# ...and doing it twice converges.
cp "$HB/real" "$HB/real.once"
( source "$ZFSBACKUP"; set_host_block "$HB/real" "$HB/lines" ) >/dev/null 2>&1
if cmp -s "$HB/real.once" "$HB/real"; then
    ok "host-block: repeating that migration is idempotent"
else
    bad "host-block: repeating that migration is idempotent" "$(diff "$HB/real.once" "$HB/real")"
fi

# The markers carry '(', ')' and '--'. A sed address would silently fail to
# match those rather than error, so the removal is done with awk and a literal
# string compare -- pin that it really matches.
grep -q '(' <<<"$( source "$ZFSBACKUP"; printf '%s' "$HOST_BEGIN" )" \
    && ok "host-block: the marker really does contain regex metacharacters" \
    || bad "host-block: the marker really does contain regex metacharacters" "marker has no parens"

# --- 22. the migration discovers capabilities instead of documenting them ----
#
# REV-20260801-020 F1/F3: a competent Linux/ZFS administrator should not have to
# know pair/join order, repository layout or which lines belong outside the
# managed block. The verb has to find those things itself.
CAP="$WORK/caps"; mkdir -p "$CAP/bin"
cat > "$CAP/jobs.conf" <<'EOF'
[template:t]
	send_schedule = 1 * * * *
[dataset:tank/a]
	use_template = t
[dataset:hdd/vm-disks/vm-100-disk-0]
	use_template = t
[prune:tank/a]
	retain = -H24
EOF
got=$( source "$ZFSBACKUP"; config_datasets "$CAP/jobs.conf" | tr '\n' ' ' )
case "$got" in
    *"tank/a"*"hdd/vm-disks/vm-100-disk-0"*|*"hdd/vm-disks/vm-100-disk-0"*"tank/a"*)
        ok "capabilities: the dataset set is read from the config, not from the operator" ;;
    *)  bad "capabilities: the dataset set is read from the config, not from the operator" "got=$got" ;;
esac

# zfs allow reports ancestor grants when asked about a leaf, so parsing the
# leaf's output is enough. A grant that is missing even one verb is not a grant:
# 'bookmark' was absent for weeks once and disabled a whole fallback silently.
cat > "$CAP/bin/zfs" <<'EOF'
#!/bin/bash
# $1 = allow, $2 = dataset
case "$2" in
  tank/full)    echo "---- Permissions on tank ----"
                echo "Local+Descendent permissions:"
                echo "	user zfsbackup bookmark,canmount,create,destroy,hold,mount,receive,release,rollback,send,snapshot" ;;
  tank/partial) echo "---- Permissions on tank ----"
                echo "Local+Descendent permissions:"
                echo "	user zfsbackup create,mount,send,snapshot" ;;
  *)            : ;;
esac
exit 0
EOF
chmod +x "$CAP/bin/zfs"

( PATH="$CAP/bin:$PATH"; source "$ZFSBACKUP"; target_can_zfs zfsbackup tank/full "snapshot,destroy,hold,release,mount" ) >/dev/null 2>&1
[ $? -eq 0 ] && ok "capabilities: a full delegation passes" \
             || bad "capabilities: a full delegation passes" "rejected a complete grant"

( PATH="$CAP/bin:$PATH"; source "$ZFSBACKUP"; target_can_zfs zfsbackup tank/partial "snapshot,destroy,hold,release,mount" ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "capabilities: a delegation missing 'destroy' is refused" \
             || bad "capabilities: a delegation missing 'destroy' is refused" "accepted a partial grant"

( PATH="$CAP/bin:$PATH"; source "$ZFSBACKUP"; target_can_zfs zfsbackup tank/none "snapshot,destroy,hold,release,mount" ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "capabilities: no delegation at all is refused" \
             || bad "capabilities: no delegation at all is refused" "accepted an absent grant"

# Migrating onto an account that ALREADY runs a managed block would replace jobs
# that are live under that account -- refuse before anything is rendered.
MIG="$WORK/migonto"; mkdir -p "$MIG/bin"
cat > "$MIG/bin/crontab" <<'EOF'
#!/bin/bash
if [ "$1" = "-u" ]; then
    echo "# BEGIN zfs-backup-managed"
    echo "5 * * * * already-here"
    echo "# END zfs-backup-managed"
    exit 0
fi
echo "# BEGIN zfs-backup-managed"
echo "# Source: /root/scripts/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "1 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh x"
echo "# END zfs-backup-managed"
exit 0
EOF
cat > "$MIG/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$MIG/home:/bin/bash"
exit 0
EOF
cat > "$MIG/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
chmod +x "$MIG/bin/crontab" "$MIG/bin/getent" "$MIG/bin/id"
mkdir -p "$MIG/home/zfs-snapshot-all"; : > "$MIG/home/zfs-snapshot-all/gen-cron.sh"
out=$( PATH="$MIG/bin:$PATH" bash -c "source '$ZFSBACKUP'; runuser_test_r() { return 0; }; runuser_test_x() { return 0; }; cmd_migrate_to_account zfsbackup --yes" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"ALREADY has a managed block"*) true ;; *) false ;; esac; then
    ok "migrate-to-account: refuses an account that already runs a managed block"
else
    bad "migrate-to-account: refuses an account that already runs a managed block" "rc=$rc out=$out"
fi


# --- 23. remove-client acts on the CONFIGURED account's crontab -------------
#
# REV-20260801-019, additional note. The fix for this landed twice: 9af0003 put
# read_server_conf into cmd_final_catchup, 39e610f moved it to
# cmd_remove_client where it was meant to go. Text-pattern patching modified the
# wrong occurrence and nothing caught it, so the reviewer asked for a test that
# pins BOTH halves -- remove-client targeting the right crontab, and
# final-catchup being left alone.
#
# Why it matters: without LOCAL_USER, every crontab operation in remove-client
# silently targets ROOT. On a collector with a dedicated account that means
# reading the wrong crontab and comparing against the wrong '# Source:'.
RC="$WORK/removeclient"; mkdir -p "$RC/bin" "$RC/clients"
cat > "$RC/bin/crontab" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$RC/calls"
echo "# BEGIN zfs-backup-managed"
echo "# Source: /somewhere/else.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "1 * * * * x"
echo "# END zfs-backup-managed"
exit 0
EOF
chmod +x "$RC/bin/crontab"
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=zfsbackup\n' "$RC" > "$RC/server.conf"
: > "$RC/jobs.conf"
printf 'STATE=active\nMANAGED_DATASETS="tank/a"\nCRON_CONFIG=%s/jobs.conf\n' "$RC" > "$RC/clients/c1.conf"
: > "$RC/calls"

out=$( PATH="$RC/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RC/server.conf'; CLIENTS_DIR='$RC/clients'
    cmd_remove_client c1" 2>&1 ); rc=$?

# It must have stopped at the config-vs-installed mismatch -- that is the guard
# that fired live on 2026-08-01 and exposed the missing read_server_conf.
if [ "$rc" -ne 0 ] && case "$out" in *"would DELETE every job"*) true ;; *) false ;; esac; then
    ok "remove-client: a config that does not match the installed block still stops it"
else
    bad "remove-client: a config that does not match the installed block still stops it" "rc=$rc out=$out"
fi

# The point of the test: which crontab it asked. Every call must name the
# account; a bare '-l' here would be root's.
if grep -q -- '-u zfsbackup -l' "$RC/calls" && ! grep -qx -- '-l' "$RC/calls"; then
    ok "remove-client: the configured account's crontab is the one consulted"
else
    bad "remove-client: the configured account's crontab is the one consulted" "$(cat "$RC/calls")"
fi

# With no LOCAL_USER in the server config the same run must target root, and
# must not invent an account from somewhere else.
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=\n' "$RC" > "$RC/server.conf"
: > "$RC/calls"
out=$( PATH="$RC/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RC/server.conf'; CLIENTS_DIR='$RC/clients'
    cmd_remove_client c1" 2>&1 ) || :
if grep -qx -- '-l' "$RC/calls" && ! grep -q -- '-u ' "$RC/calls"; then
    ok "remove-client: with no dedicated account it targets root, as before"
else
    bad "remove-client: with no dedicated account it targets root, as before" "$(cat "$RC/calls")"
fi

# The other half of the same review note: final-catchup must NOT have gained a
# read_server_conf. It resolves the account from the peer manifest
# (PEER_SAVED_LOCAL_USER), and read_server_conf RESETS LOCAL_USER and
# CRON_CONFIG before sourcing the server file -- so calling it there would
# discard what the client record said. That is precisely the edit 9af0003 made
# by accident.
fc_body=$(awk '/^cmd_final_catchup\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
if [ -n "$fc_body" ] && ! printf '%s\n' "$fc_body" | grep -q 'read_server_conf'; then
    ok "final-catchup: still resolves the client itself, with no read_server_conf"
else
    bad "final-catchup: still resolves the client itself, with no read_server_conf" \
        "$(printf '%s\n' "$fc_body" | grep -n 'read_server_conf')"
fi

# And the guard behind that reasoning: read_server_conf really does clear the
# two variables before sourcing, so "it would be harmless there" is false.
rsc=$(awk '/^read_server_conf\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
if printf '%s\n' "$rsc" | grep -q 'LOCAL_USER=""' && printf '%s\n' "$rsc" | grep -q 'CRON_CONFIG=""'; then
    ok "read_server_conf: resets before sourcing, so where it is called matters"
else
    bad "read_server_conf: resets before sourcing, so where it is called matters" "$rsc"
fi


# --- 23b. remove-client, last client: a failed config-publish refuses closed,
# does not call --unpair, and does not mark the client removed -------------
#
# REV-20260804-041: found by review -- the last-client branch (REV-20260804-039
# F2, section 39e below) removed the zfs-backup-managed cron block via the
# shared writer, then WARNED (and continued into --unpair and STATE=removed)
# if the config-file swap that follows it failed. That converts a genuinely
# recoverable partial commit (cron side already done, idempotent to retry)
# into a client record that falsely claims removal is complete, with no way
# to retry it (remove-client's own guards key off state this write is about
# to overwrite).
#
# cron_block_remove is function-overridden to a no-op success here -- this
# section is about what happens to the SURROUNDING transaction when the
# publish step fails, not about re-proving cron_block_remove's own
# correctness (REV-036's pause suite already does that).
RL="$WORK/removelast"; mkdir -p "$RL/bin" "$RL/clients"
cat > "$RL/jobs.conf" <<'EOF'
[defaults]
	host_label = testhost

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_

[dataset:tank/onlyclient]
	# managed-by: zfs-backup.sh client=lastclient
	use_template = standard_hourly
EOF
cat > "$RL/bin/crontab" <<EOF
#!/bin/bash
echo "# BEGIN zfs-backup-managed"
echo "# Source: $RL/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "1 * * * * x"
echo "# END zfs-backup-managed"
exit 0
EOF
chmod +x "$RL/bin/crontab"
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=\n' "$RL" > "$RL/server.conf"
printf 'STATE=active\nPEER_HOST=peer.example\nMANAGED_DATASETS="tank/onlyclient"\nCRON_CONFIG=%s/jobs.conf\n' "$RL" > "$RL/clients/lastclient.conf"

# Force the publish step (mv workfile -> CRON_CONFIG) to fail: a stub `mv`
# that fails ONLY the exact "swap the .zfsbackup-work.* tempfile onto
# jobs.conf" call and delegates everything else to the real mv.
cat > "$RL/bin/mv" <<EOF
#!/bin/bash
if [ "\$#" -ge 2 ]; then
    dst="\${@: -1}"; src="\${@: -2:1}"
    case "\$src" in
        *.zfsbackup-work.*) case "\$dst" in "$RL/jobs.conf") echo "mv: simulated failure for the test" >&2; exit 1 ;; esac ;;
    esac
fi
exec /bin/mv "\$@"
EOF
chmod +x "$RL/bin/mv"

# A marker file, not a text-in-output check: `bash "$DEPLOY" ...` against
# /bin/false or /bin/true proves nothing about whether it ran (neither
# prints its own args), and a real deploy.sh stub is the only way to know
# for certain --unpair was never invoked.
cat > "$RL/deploy_marker.sh" <<EOF
#!/bin/bash
touch "$RL/DEPLOY_WAS_CALLED"
exit 0
EOF
chmod +x "$RL/deploy_marker.sh"

before_conf=$(cat "$RL/clients/lastclient.conf")
before_jobsconf=$(cat "$RL/jobs.conf")

out=$( PATH="$RL/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RL/server.conf'; CLIENTS_DIR='$RL/clients'; DEPLOY='$RL/deploy_marker.sh'
    cron_block_remove() { CRON_CHANGED=1; return 0; }
    cmd_remove_client lastclient
" 2>&1 ); rc=$?

if [ "$rc" -ne 0 ]; then
    ok "remove-client last-client, publish fails: command exits non-zero"
else
    bad "remove-client last-client, publish fails: command exits non-zero" "rc=$rc out=$out"
fi
if [ ! -e "$RL/DEPLOY_WAS_CALLED" ]; then
    ok "remove-client last-client, publish fails: deploy.sh --unpair is not reached"
else
    bad "remove-client last-client, publish fails: deploy.sh --unpair is not reached" "marker file exists -- deploy.sh was invoked"
fi
if [ "$(cat "$RL/clients/lastclient.conf")" = "$before_conf" ]; then
    ok "remove-client last-client, publish fails: client record is untouched (not marked removed)"
else
    bad "remove-client last-client, publish fails: client record is untouched (not marked removed)" "$(cat "$RL/clients/lastclient.conf")"
fi
if [ "$(cat "$RL/jobs.conf")" = "$before_jobsconf" ]; then
    ok "remove-client last-client, publish fails: the old config is left in place (mixed state, not silently swapped)"
else
    bad "remove-client last-client, publish fails: the old config is left in place (mixed state, not silently swapped)" "$(cat "$RL/jobs.conf")"
fi
if printf '%s' "$out" | grep -qF "ALREADY been removed" && printf '%s' "$out" | grep -qF "could not be updated to match"; then
    ok "remove-client last-client, publish fails: the diagnostic names the exact mixed state"
else
    bad "remove-client last-client, publish fails: the diagnostic names the exact mixed state" "$out"
fi

# Retry after the publish problem is fixed: same stubbed crontab (still
# needed for assert_cron_config_matches_installed), but the REAL mv this
# time -- a fresh bin dir rather than removing the stub from $RL/bin, so
# nothing here depends on cleanup order.
mkdir -p "$RL/bin2"
cp "$RL/bin/crontab" "$RL/bin2/crontab"
out2=$( PATH="$RL/bin2:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RL/server.conf'; CLIENTS_DIR='$RL/clients'; DEPLOY='$RL/deploy_marker.sh'
    cron_block_remove() { CRON_CHANGED=1; return 0; }
    cmd_remove_client lastclient
" 2>&1 ); rc2=$?
if [ "$rc2" -eq 0 ] && grep -q 'STATE=removed' "$RL/clients/lastclient.conf" \
   && ! grep -q '\[dataset:' "$RL/jobs.conf" && [ -e "$RL/DEPLOY_WAS_CALLED" ]; then
    ok "remove-client last-client: retry after the publish problem is fixed completes cleanly"
else
    bad "remove-client last-client: retry after the publish problem is fixed completes cleanly" "rc=$rc2 out=$out2"
fi

# --- 24. preflight can render before phase 2 has moved anything -------------
#
# Found by the FIRST live preflight, metropolis pve1, 2026-08-01. Phase 1 has to
# render the block as the account, but on the normal host that render depends on
# phase 2's work: the config still sits under /root, which the account cannot
# read. The check reported every other gap correctly and then aborted with
# "gen-cron.sh could not render the block" -- so the one host it was written for
# was the one host it could not finish on.
#
# Phase 1 now renders from a throwaway readable copy, exactly as the hand
# procedure did. The real config is still MOVED and never copied, which is the
# property REV-20260801-018 turns on.
PF="$WORK/preflight"; mkdir -p "$PF/bin" "$PF/home/zfs-snapshot-all"
cat > "$PF/jobs.conf" <<'EOF'
[template:t]
	send_schedule = 1 * * * *
[dataset:tank/a]
	use_template = t
EOF
cat > "$PF/rendered.txt" <<'EOF'
# BEGIN zfs-backup-managed
# Source: /throwaway/tmpdir/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "automated_hourly_" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$PF/bin/crontab" <<EOF
#!/bin/bash
if [ "\$1" = "-u" ]; then exit 0; fi
echo "# BEGIN zfs-backup-managed"
echo "# Source: $PF/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"automated_hourly_\" \"tank/a\" 2>>/root/scripts/cron.log"
echo "# END zfs-backup-managed"
exit 0
EOF
cat > "$PF/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$PF/home:/bin/bash"
exit 0
EOF
cat > "$PF/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
cat > "$PF/bin/zfs" <<'EOF'
#!/bin/bash
echo "---- Permissions on tank ----"
echo "Local+Descendent permissions:"
echo "	user zfsbackup bookmark,canmount,create,destroy,hold,mount,receive,release,rollback,send,snapshot"
exit 0
EOF
chmod +x "$PF/bin/crontab" "$PF/bin/getent" "$PF/bin/id" "$PF/bin/zfs"
: > "$PF/home/zfs-snapshot-all/gen-cron.sh"

# runuser_test_r: the account CAN read its checkout and CANNOT read the config
# -- the real shape on a Proxmox host, where /root is 0700.
out=$( PATH="$PF/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { case \"\$2\" in *jobs.conf) return 1 ;; *) return 0 ;; esac; }
    runuser_test_x() { return 0; }
    gencron_as_target() {
        # Honest stub: gen-cron runs AS the account, so rendering the ORIGINAL
        # config -- the one under /root that the account cannot open -- must
        # fail. Only the staged readable copy may succeed. Stubbing this as
        # 'always works' is what let the first version of this test pass
        # against the very bug it was written for.
        local c=''; while [ \$# -gt 0 ]; do [ \"\$1\" = -c ] && c=\"\$2\"; shift; done
        [ \"\$c\" = '$PF/jobs.conf' ] && return 1
        cat '$PF/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --preflight" 2>&1 ); rc=$?

if [ "$rc" -eq 0 ] && case "$out" in *"preflight czysty"*) true ;; *) false ;; esac; then
    ok "preflight: finishes even though the account cannot read the config yet"
else
    bad "preflight: finishes even though the account cannot read the config yet" "rc=$rc out=$out"
fi

# The move must be announced as something the run will do, not as a gap the
# operator has to close -- otherwise a clean host reports itself blocked.
case "$out" in
    *"[ plan ]"*"jobs.conf"*) ok "preflight: the config move is planned work, not a blocking gap" ;;
    *) bad "preflight: the config move is planned work, not a blocking gap" "$out" ;;
esac

# And the render must never be mistaken for a licence to copy: /etc/... is where
# the config ENDS UP, and the preview has to say so rather than naming the
# throwaway the render was read from (REV-20260801-015 section 1 -- a preview
# that differs from the install is worse than no preview).
out2=$( PATH="$PF/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { case \"\$2\" in *jobs.conf) return 1 ;; *) return 0 ;; esac; }
    runuser_test_x() { return 0; }
    gencron_as_target() {
        local c=''; while [ \$# -gt 0 ]; do [ \"\$1\" = -c ] && c=\"\$2\"; shift; done
        [ \"\$c\" = '$PF/jobs.conf' ] && return 1
        cat '$PF/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --yes" 2>&1 ) || :
if case "$out2" in *"/etc/zfs-snapshot-all/jobs.conf --"*) true ;; *) false ;; esac \
   && case "$out2" in *"/throwaway/tmpdir"*) false ;; *) true ;; esac; then
    ok "preflight: the preview names the config's FINAL path, not the throwaway"
else
    bad "preflight: the preview names the config's FINAL path, not the throwaway" "$out2"
fi


# --- 25. the rollback reports what it actually did --------------------------
#
# Found by the live rollback test on metropolis pve1, 2026-08-01. The account's
# crontab was made unwritable to force a failure; the run correctly restored
# root's crontab byte for byte, and then said:
#
#     !!!   'zfsbackup' crontab NOT restored -- restore by hand from /tmp/...
#     FATAL: ... -- both crontabs restored, root runs its jobs again
#
# Both sentences were defensible on their own and together they were useless.
# The account's crontab had never been written, so there was nothing to
# restore -- but the rollback tried anyway, failed for the same reason the
# install had failed, and raised an alarm about a file that was never in danger.
# Meanwhile the FATAL asserted a clean rollback instead of reporting one.
RB="$WORK/rollback"; mkdir -p "$RB/bin" "$RB/home/zfs-snapshot-all" "$RB/locks"
# REV-20260802-034 F2/F3: migrate-to-account's crontab writes now go through
# lib-cron.sh's per-user lock (exec {fd}>lockfile; flock -w timeout). Production
# hosts have real flock -- deploy.sh already refuses to run without it -- but
# this dev machine's git-bash does not carry the binary, so these bash -c
# sandboxes need the same portable stand-in test/cron/run.sh already built:
# mutex on the lock file's path (resolved through /proc/self/fd) via `mkdir`,
# which is atomic on every filesystem this suite runs on. Not a
# reimplementation of flock(2) -- just enough to prove the lock is taken and
# released around these calls.
if ! command -v flock >/dev/null 2>&1; then
cat > "$RB/bin/flock" <<'EOF'
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
if [ "$mode" = unlock ]; then rmdir "$lockdir" 2>/dev/null; exit 0; fi
if [ -z "$timeout" ]; then mkdir "$lockdir" 2>/dev/null && exit 0; exit 1; fi
deadline=$(( $(date +%s%N) + timeout * 1000000000 ))
while :; do
    mkdir "$lockdir" 2>/dev/null && exit 0
    [ "$(date +%s%N)" -ge "$deadline" ] && exit 1
    sleep 0.05
done
EOF
chmod +x "$RB/bin/flock"
fi
cat > "$RB/jobs.conf" <<'EOF'
[template:t]
	send_schedule = 1 * * * *
[dataset:tank/a]
	use_template = t
EOF
cat > "$RB/rendered.txt" <<'EOF'
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "x_" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
# STATEFUL, not a fixed echo: cron_replace_all's write goes through
# lib-cron.sh's cron_write, which reads back after writing to catch a lying
# crontab(1) -- a stub that always echoes the same seeded text regardless of
# what was written would make every write look like a lie. root's crontab
# lives in a file and reflects whatever was last installed into it; the
# account side stays a fixed empty answer, since gencron_as_target is stubbed
# below to fail before it would ever touch the account's real crontab.
cat > "$RB/root.cron" <<EOF
# BEGIN zfs-backup-managed
# Source: $RB/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m "x_" "tank/a" 2>>/root/scripts/cron.log
0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log
# END zfs-backup-managed
EOF
cat > "$RB/bin/crontab" <<EOF
#!/bin/bash
if [ "\$1" = "-u" ]; then
    [ "\$3" = "-l" ] && exit 0
    exit 0
fi
if [ "\$1" = "-l" ]; then
    cat "$RB/root.cron"
    exit 0
fi
cat "\$1" > "$RB/root.cron"
exit 0
EOF
cat > "$RB/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$RB/home:/bin/bash"
exit 0
EOF
cat > "$RB/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
cat > "$RB/bin/zfs" <<'EOF'
#!/bin/bash
echo "---- Permissions on tank ----"
echo "	user zfsbackup bookmark,canmount,create,destroy,hold,mount,receive,release,rollback,send,snapshot"
exit 0
EOF
chmod +x "$RB/bin/crontab" "$RB/bin/getent" "$RB/bin/id" "$RB/bin/zfs"
: > "$RB/home/zfs-snapshot-all/gen-cron.sh"

# The account CAN read the config here, so no config move happens and the test
# stays entirely inside the crontab logic. The render succeeds; the --install
# fails, which is the shape the live test produced.
out=$( PATH="$RB/bin:$PATH" CRON_LOCK_DIR="$RB/locks" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    gencron_as_target() {
        for a in \"\$@\"; do [ \"\$a\" = --install ] && return 1; done
        cat '$RB/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --yes" 2>&1 ); rc=$?

if [ "$rc" -ne 0 ] && case "$out" in *"Rolled back completely"*) true ;; *) false ;; esac; then
    ok "rollback: a complete rollback is reported as complete"
else
    bad "rollback: a complete rollback is reported as complete" "rc=$rc out=$out"
fi

# The crontab that was never written must be described as such, not raised as a
# failed restore.
if case "$out" in *"'zfsbackup' crontab was never written"*) true ;; *) false ;; esac \
   && case "$out" in *"NOT RESTORED"*) false ;; *) true ;; esac; then
    ok "rollback: a crontab that was never written is not reported as unrestored"
else
    bad "rollback: a crontab that was never written is not reported as unrestored" "$out"
fi

# Root's WAS written, so its restore must be stated -- silence here would leave
# the operator unable to tell a restored crontab from an untouched one.
case "$out" in
    *"root's crontab restored"*) ok "rollback: the side that was written reports its restore" ;;
    *) bad "rollback: the side that was written reports its restore" "$out" ;;
esac

# And the opposite direction: when the rollback itself fails, the message must
# say so instead of claiming success. Root's crontab write now fails on restore.
# Same statefulness, and the rollback RESTORE (crontab "$rootcron", root's
# ORIGINAL content from before the forward write) must fail this time -- the
# scenario is "the rollback itself cannot complete". A write that fails must
# not silently update root.cron, or the read-back a later call performs would
# see the failed write's content instead of proving nothing changed.
cat > "$RB/root.cron" <<EOF
# BEGIN zfs-backup-managed
# Source: $RB/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m "x_" "tank/a" 2>>/root/scripts/cron.log
# END zfs-backup-managed
EOF
cat > "$RB/bin/crontab" <<EOF
#!/bin/bash
if [ "\$1" = "-u" ]; then exit 0; fi
if [ "\$1" = "-l" ]; then
    cat "$RB/root.cron"
    exit 0
fi
if [ -n "\${MTA_FAIL_RESTORE:-}" ]; then exit 1; fi
cat "\$1" > "$RB/root.cron"
exit 0
EOF
chmod +x "$RB/bin/crontab"
out=$( PATH="$RB/bin:$PATH" CRON_LOCK_DIR="$RB/locks" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    gencron_as_target() {
        for a in \"\$@\"; do [ \"\$a\" = --install ] && { export MTA_FAIL_RESTORE=1; return 1; }; done
        cat '$RB/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --yes" 2>&1 ) || :
if case "$out" in *"needs a human NOW"*) true ;; *) false ;; esac; then
    ok "rollback: a rollback that did NOT complete says so instead of claiming success"
else
    bad "rollback: a rollback that did NOT complete says so instead of claiming success" "$out"
fi

# ---- 25b. F3: root's own crontab write goes through the shared, verified path
#
# REV-20260802-034 F3. Before this, migrate-to-account wrote root's crontab
# with a bare `crontab "$rootnew"` -- rc=0 was taken as success, full stop. If
# crontab(1) silently stored something OTHER than what it was given (a
# truncated write, a spool quirk), the migration would proceed believing root's
# block was removed when it might not have been. cron_replace_all's read-back
# now catches exactly that, on the very first mutation of the transaction.
cat > "$RB/root.cron" <<EOF
# BEGIN zfs-backup-managed
# Source: $RB/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead
7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m "x_" "tank/a" 2>>/root/scripts/cron.log
# END zfs-backup-managed
EOF
cat > "$RB/bin/crontab" <<EOF
#!/bin/bash
if [ "\$1" = "-u" ]; then exit 0; fi
if [ "\$1" = "-l" ]; then cat "$RB/root.cron"; exit 0; fi
cat "\$1" > "$RB/root.cron"
echo "# tampered by crontab(1)" >> "$RB/root.cron"
exit 0
EOF
chmod +x "$RB/bin/crontab"
out=$( PATH="$RB/bin:$PATH" CRON_LOCK_DIR="$RB/locks" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    gencron_as_target() { cat '$RB/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --yes" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"could not write root's crontab"*) true ;; *) false ;; esac \
   && case "$out" in *"reading it back gave something else"*) true ;; *) false ;; esac; then
    ok "F3: a root crontab write that reads back wrong is refused, not accepted on rc=0"
else
    bad "F3: a root crontab write that reads back wrong is refused, not accepted on rc=0" "rc=$rc out=$out"
fi
# Nothing else was attempted: the account was never touched, no config move
# survives, because this is the FIRST mutation of the transaction.
case "$out" in
    *"nothing else was attempted"*) ok "F3: ...and nothing else in the transaction was attempted" ;;
    *) bad "F3: ...and nothing else in the transaction was attempted" "$out" ;;
esac

# --- 26. an install must not delete jobs the target runs today --------------
#
# REV-20260801-021 F1, and the reviewer's own reproduction shape. The overlap
# guard allows a target running DISJOINT jobs, which is correct for that guard
# in isolation -- two collectors on one host is a real deployment. It is not
# sufficient on its own, because gen-cron.sh --install REPLACES the target's
# single managed block and the proposal is rendered only from the config being
# installed. So the disjoint block is not merged; it is deleted. Silently,
# right after the overlap guard said the two workloads were unrelated.
#
#   root managed block:       jobs for tank/a
#   zfsbackup managed block:  disjoint jobs for tank/b
#   install as zfsbackup:     tank/b stops running, nothing says so
CL="$WORK/clobber"; mkdir -p "$CL/bin"
cat > "$CL/target.cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "b_" "tank/b" 2>>/home/zfsbackup/cron.log
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "tank/b" "b" -H24 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CL/proposal.txt" <<'EOF'
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "a_" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CL/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && { cat "$CL/target.cron"; exit 0; }
cat "$CL/target.cron"
exit 0
EOF
chmod +x "$CL/bin/crontab"
: > "$CL/new.conf"

out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac \
   && case "$out" in *"tank/b"*) true ;; *) false ;; esac; then
    ok "clobber: disjoint jobs already running in the target are not silently replaced"
else
    bad "clobber: disjoint jobs already running in the target are not silently replaced" "rc=$rc out=$out"
fi

# Re-installing the SAME jobs is an idempotent retry, not a deletion, and must
# stay possible -- otherwise no config could ever be re-installed.
cp "$CL/target.cron" "$CL/same.cron"
cat > "$CL/proposal-same.txt" <<'EOF'
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "b_" "tank/b" 2>>/home/zfsbackup/cron.log
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "tank/b" "b" -H24 2>>/home/zfsbackup/cron.log
0 7 * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "c_" "tank/c" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-same.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "clobber: a proposal that keeps every current job (and adds one) is allowed" \
                || bad "clobber: a proposal that keeps every current job (and adds one) is allowed" "rc=$rc out=$out"

# Unknown proposal means unknown deletions -- fail closed, same rule as the
# overlap guard.
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { return 1; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"could not be rendered"*) true ;; *) false ;; esac; then
    ok "clobber: an unrenderable proposal fails closed"
else
    bad "clobber: an unrenderable proposal fails closed" "rc=$rc out=$out"
fi

# A target with no managed block at all has nothing to lose.
printf '0 8 * * * /root/scripts/check-pool-capacity.sh\n' > "$CL/target.cron"
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "clobber: a target with no managed block passes" \
                || bad "clobber: a target with no managed block passes" "rc=$rc out=$out"

# REV-20260804-042 Gate G, found live: an endpoint switch (set-endpoint +
# activate-client) changes the literal host:port in a client's pull line's
# -A "acct@host:path" argument, which used to look exactly like "a foreign
# job disappearing" to this guard and FATAL-refused every real
# re-activation after a route change -- the documented relocation feature
# never actually worked.
#
# REV-20260804-043 (P1 correction): the first fix (2e02a7d) matched on
# HostKeyAlias alone, shared by every job belonging to one client -- a
# client with two datasets could lose one of them silently as long as the
# OTHER one still appeared under the new endpoint. Fixed to normalize ONLY
# the host between "acct@" and the following ":" and compare the rest of
# each line verbatim (endpoint_normalized_identity). The cases below match
# the reviewer's own acceptance criteria.
cat > "$CL/target.cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-labgateg -A "acct@192.168.28.151:tank/src" "tank/dst" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF

# Criterion 1: a one-job endpoint change for the same relationship passes.
cat > "$CL/proposal-endpoint-switch.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-labgateg -A "acct@10.99.99.2:tank/src" "tank/dst" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-endpoint-switch.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "clobber: a one-job endpoint change for the same relationship passes" \
                || bad "clobber: a one-job endpoint change for the same relationship passes" "rc=$rc out=$out"

# Criterion 5: a different client's removed job continues to refuse.
cat > "$CL/proposal-other-client.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-someoneelse -A "acct@10.1.2.3:tank/other" "tank/otherdst" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-other-client.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac \
   && case "$out" in *"zfs-client-labgateg"*) true ;; *) false ;; esac; then
    ok "clobber: a different client's removed job continues to refuse"
else
    bad "clobber: a different client's removed job continues to refuse" "rc=$rc out=$out"
fi

# REV-20260804-043's own counterexample: one client, two datasets, both
# sharing the same HostKeyAlias. The target currently runs both.
cat > "$CL/target-multi.cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@old:tank/a" "tank/a" 2>>/home/zfsbackup/cron.log
2 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@old:tank/b" "tank/b" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CL/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && { cat "$CL/target-multi.cron"; exit 0; }
cat "$CL/target-multi.cron"
exit 0
EOF
chmod +x "$CL/bin/crontab"

# Criterion 2: only tank/a survives under the new endpoint -- tank/b
# disappearing must still refuse, exactly the case the coarse alias match
# missed.
cat > "$CL/proposal-multi-partial.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@new:tank/a" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-multi-partial.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac \
   && case "$out" in *"tank/b"*) true ;; *) false ;; esac; then
    ok "clobber: same client, one of two datasets dropped under the new endpoint still refuses"
else
    bad "clobber: same client, one of two datasets dropped under the new endpoint still refuses" "rc=$rc out=$out"
fi

# Criterion 3: both jobs for the same client survive, only the endpoint
# changed on both -- passes.
cat > "$CL/proposal-multi-full.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@new:tank/a" "tank/a" 2>>/home/zfsbackup/cron.log
2 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@new:tank/b" "tank/b" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-multi-full.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "clobber: same client, both datasets survive an endpoint switch, passes" \
                || bad "clobber: same client, both datasets survive an endpoint switch, passes" "rc=$rc out=$out"

# Criterion 4: the SOURCE dataset path changing (not just the endpoint) for
# an otherwise identical job must not be silently classified as an
# endpoint-only update.
cat > "$CL/target-srcchange.cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@old:tank/a" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CL/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && { cat "$CL/target-srcchange.cron"; exit 0; }
cat "$CL/target-srcchange.cron"
exit 0
EOF
chmod +x "$CL/bin/crontab"
cat > "$CL/proposal-srcchange.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -O HostKeyAlias=zfs-client-alpha -A "acct@new:tank/DIFFERENT" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-srcchange.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac \
    && ok "clobber: a source dataset change alongside the endpoint is not disguised as endpoint-only" \
    || bad "clobber: a source dataset change alongside the endpoint is not disguised as endpoint-only" "rc=$rc out=$out"

# --- 27. only RECOGNISED host-level lines may be kept behind ----------------
#
# REV-20260801-021, separate observation. "the account's render does not
# reproduce it" is not the same as "it is host-level". Keeping every dropped
# line means an unrecognised send or prune gets quietly parked in root's
# crontab -- ownership split in half with nobody deciding it, which is what the
# host block was introduced to prevent.
OR="$WORK/orphan"; mkdir -p "$OR/bin" "$OR/home/zfs-snapshot-all"
cat > "$OR/jobs.conf" <<'EOF'
[template:t]
	send_schedule = 1 * * * *
[dataset:tank/a]
	use_template = t
EOF
cat > "$OR/rendered.txt" <<'EOF'
# BEGIN zfs-backup-managed
7 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "a_" "tank/a" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
_or_crontab() {   # <extra root job line>
    cat > "$OR/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && exit 0
if [ "\$1" = "-l" ]; then
    echo "# BEGIN zfs-backup-managed"
    echo "# Source: $OR/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    echo "7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"a_\" \"tank/a\" 2>>/root/scripts/cron.log"
    echo "$1"
    echo "# END zfs-backup-managed"
    exit 0
fi
exit 0
EOF
    chmod +x "$OR/bin/crontab"
}
cat > "$OR/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$OR/home:/bin/bash"
exit 0
EOF
cat > "$OR/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
cat > "$OR/bin/zfs" <<'EOF'
#!/bin/bash
echo "	user zfsbackup bookmark,canmount,create,destroy,hold,mount,receive,release,rollback,send,snapshot"
exit 0
EOF
chmod +x "$OR/bin/getent" "$OR/bin/id" "$OR/bin/zfs"
: > "$OR/home/zfs-snapshot-all/gen-cron.sh"

# The digest is the one recognised host-level job: kept, and the run proceeds.
_or_crontab '0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log'
out=$( PATH="$OR/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    gencron_as_target() { cat '$OR/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --preflight" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"linie ogolnohostowe do zachowania: 1"*) true ;; *) false ;; esac; then
    ok "orphans: the digest is recognised as host-level and kept"
else
    bad "orphans: the digest is recognised as host-level and kept" "rc=$rc out=$out"
fi

# A dropped SEND line is not host-level. It must stop the migration by name
# rather than be filed away in root's crontab.
_or_crontab '3 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m "z_" "tank/zzz" 2>>/root/scripts/cron.log'
out=$( PATH="$OR/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    gencron_as_target() { cat '$OR/rendered.txt'; }
    cmd_migrate_to_account zfsbackup --preflight" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"belong to nobody"*) true ;; *) false ;; esac \
   && case "$out" in *"tank/zzz"*) true ;; *) false ;; esac; then
    ok "orphans: an unrecognised dropped job stops the migration and is named"
else
    bad "orphans: an unrecognised dropped job stops the migration and is named" "rc=$rc out=$out"
fi

# --- 28. the missing-config refusal must say how much depends on it ---------
#
# The pve2 shape: 14 live job lines whose `# Source:` names a file that is not
# there. Regenerating is impossible and inventing an empty config would delete
# the block, so the verb refuses -- and the NUMBER is the whole point of the
# refusal, because it is what tells the operator how much is riding on a file
# nobody has.
#
# Measured on metropolis pve2, 2026-08-01: the message read "while  cron line(s)
# depend on it" and printed `grep: /tmp/tmp.XXXX: No such file or directory` on
# stderr. The crontab copy had been removed one line ABOVE the die whose message
# greps it -- the same shape as the orphan-count bug in section 27's neighbour,
# and the second time this exact mistake reached a host.
MC="$WORK/missingcfg"; mkdir -p "$MC/bin" "$MC/home/zfs-snapshot-all"
cat > "$MC/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && exit 0
if [ "\$1" = "-l" ]; then
    echo "# BEGIN zfs-backup-managed"
    echo "# Source: $MC/gone/jobs.pve2.v4.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        echo "\$i * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"a_\" \"tank/\$i\" 2>>/root/scripts/cron.log"
    done
    echo "# END zfs-backup-managed"
    exit 0
fi
exit 0
EOF
cat > "$MC/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$MC/home:/bin/bash"
exit 0
EOF
cat > "$MC/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
chmod +x "$MC/bin/crontab" "$MC/bin/getent" "$MC/bin/id"
: > "$MC/home/zfs-snapshot-all/gen-cron.sh"

out=$( PATH="$MC/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    runuser_test_r() { return 0; }
    runuser_test_x() { return 0; }
    cmd_migrate_to_account zfsbackup --preflight" 2>&1 ); rc=$?

[ "$rc" -ne 0 ] && ok "missing-config: the verb refuses rather than inventing a config" \
                || bad "missing-config: the verb refuses rather than inventing a config" "rc=$rc out=$out"

case "$out" in
    *"while 14 cron line(s) depend on it"*)
        ok "missing-config: ...and says how many live lines depend on the file" ;;
    *)  bad "missing-config: ...and says how many live lines depend on the file" "$out" ;;
esac

# The count came from a file that must still exist when the message is built.
# Asserting on the absence of the error is what would have caught this on pve2.
case "$out" in
    *"No such file or directory"*)
        bad "missing-config: ...without greping a file it already deleted" "$out" ;;
    *)  ok "missing-config: ...without greping a file it already deleted" ;;
esac

# And it points at the tool that can rebuild it, rather than leaving the
# operator to work out that such a tool exists.
case "$out" in
    *cron2conf*) ok "missing-config: ...and names cron2conf.sh as the way out" ;;
    *)           bad "missing-config: ...and names cron2conf.sh as the way out" "$out" ;;
esac

# --- 29. a comma-separated section names SEVERAL datasets -------------------
#
# `[prune:a,b,c]` is one section naming three datasets and gen-cron.sh has
# always accepted it. The capability probe treated the whole string as ONE
# dataset name, handed it to `zfs allow`, got a failure, and reported every one
# of those datasets missing -- printing the comma-joined blob where a dataset
# name belongs.
#
# Found on metropolis pve2, 2026-08-01, whose config has two such sections. The
# damage is not only the false alarm: a garbled entry sitting next to the real
# ones destroys the operator's ability to read the true list at all.
CD="$WORK/commadata"; mkdir -p "$CD"
cat > "$CD/jobs.conf" <<'EOF'
[dataset:tank/one]
	use_template = t
[prune:tank/two,tank/three]
	use_template = t
[prune:tank/four, tank/five]
	use_template = t
[prune-bookmarks:tank/six]
	schedule = 0 4 * * *
EOF
got=$( bash -c "source '$ZFSBACKUP'; config_datasets '$CD/jobs.conf'" | tr '\n' ' ' )
check_eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want[$3] got[$2]"; }
# sort -u, so the order is lexicographic: five before four.
check_eq "commas: every dataset in a comma list is its own entry" \
         "$got" "tank/five tank/four tank/one tank/three tank/two "

# Whitespace after a comma is a human writing a list, not a dataset whose name
# starts with a space -- and a leading space would make `zfs allow` treat the
# name as an option. Asserted by counting entries that still contain a space,
# which is the thing that would actually break, rather than by matching a
# position in the joined string.
dirty=$( bash -c "source '$ZFSBACKUP'; config_datasets '$CD/jobs.conf'" | grep -c '[[:space:]]' )
check_eq "commas: no entry carries leftover whitespace" "$dirty" "0"

# prune-bookmarks is deliberately NOT a source of delegation checks today (it
# needs different verbs); pinning that so a future change is a decision rather
# than an accident.
case "$got" in
    *tank/six*) bad "commas: prune-bookmarks is not silently folded in" "$got" ;;
    *)          ok "commas: prune-bookmarks is not silently folded in" ;;
esac

# --- 30. the preflight must name a command that exists ----------------------
#
# The quiesce gap advised `deploy.sh --join <pakiet> --allow-quiesce`, which
# grants a PAIRED PEER. Following it would have provisioned a peering
# relationship the operator did not want and still produced no grant for the
# host's own account. The local route landed in 3831509 and this message was
# left pointing at the old one -- a fix is not delivered until the thing that
# tells people about it agrees.
# Since REV-20260801-027 there are TWO quiesce gaps -- helper unreachable, and
# helper reachable but whitelist too narrow -- and BOTH have to name the local
# route with the derived list.
# Since the owner picked option (b) (2026-08-02) the corrective command lives in
# ONE remediation block rather than being repeated inside each gap. What matters
# is which list it names -- see section 34.
rem=$(sed -n '/^capability_remediation()/,/^}/p' "$ZFSBACKUP")
case "$rem" in
    *'--backup-user=%s --datasets="%s"'*) ok "advice: the remediation block names the local grant command" ;;
    *) bad "advice: the remediation block names the local grant command" "$rem" ;;
esac
case "$rem" in
    *"--join"*) bad "advice: ...and does not send the operator to --join" "$rem" ;;
    *)          ok "advice: ...and does not send the operator to --join" ;;
esac
case "$rem" in
    *'--datasets="..."'*) bad "advice: ...and leaves no placeholder" "$rem" ;;
    *)                    ok "advice: ...and leaves no placeholder" ;;
esac

# --- 31. the account must be able to RUN the block it is given --------------
#
# metropolis pve2, 2026-08-01, and the most expensive defect of the day. Its
# config was rebuilt by cron2conf.sh from the live crontab, so it faithfully
# carried root's paths as an EXPLICIT `[defaults] repo_dir`. gen-cron.sh
# normally DERIVES the repo directory from where it lives -- the account's own
# checkout -- but an explicit config field beats the derivation, so the account
# got a block naming /root/scripts/zfs-snapshot-all/*.sh. /root is 0700. Every
# line died with exit 126 and the host had no working backup job at all.
#
# The migration could not see it BY CONSTRUCTION: job_identity() strips the
# script directory on purpose, because that is the part that legitimately
# changes when ownership moves. So the workload comparison said "identical",
# correctly, about a block that could not execute. Two different questions.
#
# It is also why the per-line check said rc=0: the generated cron idiom ends in
# `rm -f "$e"`, so the LINE succeeds whatever the job did.
RB="$WORK/runnable"; mkdir -p "$RB/bin" "$RB/root-only" "$RB/home/zfs-snapshot-all"
for s in snapsend delsnaps check-snap-age; do
    printf '#!/bin/sh\nexit 0\n' > "$RB/home/zfs-snapshot-all/$s.sh"
    chmod +x "$RB/home/zfs-snapshot-all/$s.sh"
    printf '#!/bin/sh\nexit 0\n' > "$RB/root-only/$s.sh"
done
# Not executable by anyone but the owner -- stands in for a script under /root.
chmod 0700 "$RB/root-only"/*.sh

cat > "$RB/good.block" <<EOF
# BEGIN zfs-backup-managed
7 * * * * $RB/home/zfs-snapshot-all/snapsend.sh -m "a_" "tank/a" 2>>/home/x/cron.log
9 * * * * $RB/home/zfs-snapshot-all/delsnaps.sh "tank/a" "a" -H24 2>>/home/x/cron.log
# END zfs-backup-managed
EOF
cat > "$RB/bad.block" <<EOF
# BEGIN zfs-backup-managed
7 * * * * $RB/home/zfs-snapshot-all/snapsend.sh -m "a_" "tank/a" 2>>/home/x/cron.log
9 * * * * $RB/root-only/delsnaps.sh "tank/a" "a" -H24 2>>/home/x/cron.log
# END zfs-backup-managed
EOF

# runuser_test_x is the seam: stub it to answer for a hypothetical account
# rather than needing a second real user on the box.
out=$( bash -c "
    source '$ZFSBACKUP'
    # Path-based, not mode-based: chmod 0700 does not survive on every
    # filesystem this suite runs on, and a probe that quietly answers 'yes'
    # everywhere would make both cases below pass for the wrong reason.
    runuser_test_x() { case \"\$2\" in */root-only/*) return 1 ;; *) return 0 ;; esac; }
    assert_block_runnable_by zfsbackup '$RB/good.block'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "runnable: a block naming the account's own scripts passes" \
                || bad "runnable: a block naming the account's own scripts passes" "rc=$rc out=$out"

out=$( bash -c "
    source '$ZFSBACKUP'
    # Path-based, not mode-based: chmod 0700 does not survive on every
    # filesystem this suite runs on, and a probe that quietly answers 'yes'
    # everywhere would make both cases below pass for the wrong reason.
    runuser_test_x() { case \"\$2\" in */root-only/*) return 1 ;; *) return 0 ;; esac; }
    assert_block_runnable_by zfsbackup '$RB/bad.block'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"cannot execute"*) true ;; *) false ;; esac; then
    ok "runnable: a block naming a script the account cannot execute is refused"
else
    bad "runnable: a block naming a script the account cannot execute is refused" "rc=$rc out=$out"
fi
case "$out" in
    *"$RB/root-only/delsnaps.sh"*) ok "runnable: ...and the refusal names the exact script" ;;
    *) bad "runnable: ...and the refusal names the exact script" "$out" ;;
esac
# The reachable one in the same block must NOT be listed -- an operator reading
# a list of "broken" paths that includes working ones cannot act on it.
case "$out" in
    *"$RB/home/zfs-snapshot-all/snapsend.sh"*)
        bad "runnable: ...and does not also name the scripts that are fine" "$out" ;;
    *)  ok "runnable: ...and does not also name the scripts that are fine" ;;
esac
# The likely cause is named, because the operator has to know what to change.
case "$out" in
    *repo_dir*) ok "runnable: ...and points at the config field that usually causes it" ;;
    *)          bad "runnable: ...and points at the config field that usually causes it" "$out" ;;
esac

# The migration must ASK the question, not just have a function able to answer
# it. Asserted on the call site, which is what was actually missing.
grep -q 'assert_block_runnable_by "\$acct" "\$newblock"' "$ZFSBACKUP" \
    && ok "runnable: migrate-to-account asks it before touching anything" \
    || bad "runnable: migrate-to-account asks it before touching anything" "brak wywolania"

# And the rendering side pins REPO_DIR, so the account's block names the
# account's checkout whatever the config says. Belt and braces on purpose: the
# check above catches it, this stops it happening.
env_block=$(sed -n '/local -a envv=(/,/^    )/p' "$ZFSBACKUP")
case "$env_block" in
    *'REPO_DIR=$home/zfs-snapshot-all'*) ok "runnable: gencron_as_target pins REPO_DIR to the account's checkout" ;;
    *) bad "runnable: gencron_as_target pins REPO_DIR to the account's checkout" "$env_block" ;;
esac

# --- 32. capabilities come from the JOBS, not from a section type -----------
#
# REV-20260801-026. The probe asked one fixed set -- snapshot,destroy,hold,
# release,mount -- of every dataset a config mentioned. pve2 showed both ways
# that is wrong:
#
#   TOO WEAK    a receive target needs receive/create/rollback/canmount and
#               none of them were asked, so an account could pass preflight and
#               fail at 04:00 on "cannot receive: permission denied";
#   TOO STRONG  a `[prune:]` carrying `prune = no` is a MONITOR line. It
#               destroys nothing and needs nothing, yet was reported as a gap,
#               sending the operator to widen a grant for a job that only reads.
#
# So the requirement is derived from the rendered block -- the command lines
# that will actually run.
CAPB="$WORK/caps"; mkdir -p "$CAPB"
cat > "$CAPB/block.txt" <<'EOF'
# BEGIN zfs-backup-managed
37 * * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapsend.sh -m "h_" -v 3 "tank/a,tank/b" 2>"$e"; rc=$?
0 4 * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapsend.sh -m "d_" -e -v 3 "tank/a" "tank/backups/here" 2>"$e"; rc=$?
1 5 * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapget.sh -m "p_" "far:tank/x" "tank/pulled" 2>"$e"; rc=$?
9 9 * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapsend.sh -m "r_" "tank/remote-src" "root@far:tank/b" 2>"$e"; rc=$?
51 * * * * e=$(mktemp); /home/z/zfs-snapshot-all/delsnaps.sh -G -R "tank/backups" "automated_" -H24 2>"$e"; rc=$?
30 4 * * * e=$(mktemp); /home/z/zfs-snapshot-all/delsnaps.sh -B -R "tank/bm" "tgt-" -d30 2>"$e"; rc=$?
31 4 * * * e=$(mktemp); /home/z/zfs-snapshot-all/delsnaps.sh -B -R "root@far:tank/bm" "tgt-" -d30 2>"$e"; rc=$?
*/15 * * * * d=$(/home/z/zfs-snapshot-all/check-snap-age.sh "tank/a" "automated_hourly" 90m 3h 2>&1); rc=$?
# END zfs-backup-managed
EOF
caps=$( bash -c "source '$ZFSBACKUP'; block_capabilities '$CAPB/block.txt'" )
capof() { printf '%s\n' "$caps" | awk -F'\t' -v d="$1" '$1==d{print $2}'; }

# A LOCAL receive target -- the thing that was never asked about.
check_eq "caps: a local receive target needs the receive-side verbs" \
         "$(capof tank/backups/here)" "receive,create,mount,canmount,rollback"
# snapget's arg2 is the LOCAL base (the pull-flip design), and it receives too.
check_eq "caps: a pull job's local base needs the receive-side verbs" \
         "$(capof tank/pulled)" "receive,create,mount,canmount,rollback"
# A send needs bookmark, or the bookmark-backed continuation is silently lost.
check_eq "caps: a sending source needs send and bookmark, not just snapshot" \
         "$(capof tank/a)" "snapshot,hold,release,send,bookmark"
# ...and a snapshot-only dataset must NOT be asked for send/bookmark it will
# never use. Over-asking is how an operator gets told to widen a grant for
# nothing.
check_eq "caps: a snapshot-only dataset is not asked for send or bookmark" \
         "$(capof tank/b)" "snapshot,hold,release"
# Bookmark prune: F2. Excluding the section type was not fail-closed.
check_eq "caps: a local bookmark prune needs bookmark and destroy" \
         "$(capof tank/bm)" "bookmark,destroy"
# ...but a REMOTE bookmark scope is not a local dataset at all: what it needs is
# ssh and a grant on the far side, which this verb does not answer (F2, second
# half).
check_eq "caps: a remote bookmark scope produces no local requirement" \
         "$(capof root@far:tank/bm)" ""
# Same rule for a remote send destination and a remote pull source.
check_eq "caps: a remote send destination produces no local requirement" \
         "$(capof root@far:tank/b)" ""
check_eq "caps: a remote pull source produces no local requirement" \
         "$(capof far:tank/x)" ""
# And the source of a remote send still needs its send-side verbs locally.
check_eq "caps: the SOURCE of a remote send still needs send locally" \
         "$(capof tank/remote-src)" "snapshot,hold,release,send,bookmark"
# A monitor reads. It needs nothing, and must not appear at all.
check_eq "caps: a read-only monitor contributes no requirement" \
         "$(printf '%s\n' "$caps" | grep -c check-snap-age)" "0"

# ---- and the preflight must REFUSE, naming the exact command ---------------
CP="$WORK/capspre"; mkdir -p "$CP/bin" "$CP/home/zfs-snapshot-all"
cat > "$CP/jobs.conf" <<'EOF'
[template:t]
	send_schedule = 1 * * * *
[dataset:tank/a]
	use_template = t
EOF
cat > "$CP/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = passwd ] && echo "zfsbackup:x:1001:1001::$CP/home:/bin/bash"
exit 0
EOF
cat > "$CP/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
cat > "$CP/bin/crontab" <<EOF
#!/bin/bash
echo "crontab \$*" >> "$CP/crontab-calls"
[ "\$1" = "-u" ] && exit 0
if [ "\$1" = "-l" ]; then
    echo "# BEGIN zfs-backup-managed"
    echo "# Source: $CP/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    echo "1 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"d_\" \"tank/a\" \"tank/backups/here\" 2>>/root/scripts/cron.log"
    echo "# END zfs-backup-managed"
    exit 0
fi
exit 0
EOF
chmod +x "$CP/bin/getent" "$CP/bin/id" "$CP/bin/crontab"
: > "$CP/home/zfs-snapshot-all/gen-cron.sh"
cat > "$CP/rendered.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /home/zfsbackup/zfs-snapshot-all/snapsend.sh -m "d_" "tank/a" "tank/backups/here" 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF

# `zfs allow` answering with the OLD fixed five: enough for the old probe,
# nowhere near enough to receive.
mk_zfs() {   # <perms>
    cat > "$CP/bin/zfs" <<EOF
#!/bin/bash
echo "	user zfsbackup $1"
exit 0
EOF
    chmod +x "$CP/bin/zfs"
}
run_cp() {
    : > "$CP/crontab-calls"
    PATH="$CP/bin:$PATH" bash -c "
        source '$ZFSBACKUP'
        runuser_test_r() { return 0; }
        runuser_test_x() { return 0; }
        gencron_as_target() { cat '$CP/rendered.txt'; }
        cmd_migrate_to_account zfsbackup --preflight" 2>&1
}

mk_zfs "snapshot,destroy,hold,release,mount"
out=$(run_cp); rc=$?
[ "$rc" -ne 0 ] && ok "caps-pre: an account that cannot RECEIVE fails preflight" \
                || bad "caps-pre: an account that cannot RECEIVE fails preflight" "rc=$rc out=$out"
case "$out" in
    *"tank/backups/here (receive,create,mount,canmount,rollback)"*)
        ok "caps-pre: ...and names the dataset with the verbs it is missing them for" ;;
    *)  bad "caps-pre: ...and names the dataset with the verbs it is missing them for" "$out" ;;
esac
# F3: the exact command, not a placeholder to be rebuilt by hand.
# Both gaps in one command, space separated, ready to paste.
case "$out" in
    *'--datasets="tank/a tank/backups/here"'*) ok "caps-pre: ...and prints the exact corrective command" ;;
    *) bad "caps-pre: ...and prints the exact corrective command" "$out" ;;
esac
case "$out" in
    *'--datasets="..."'*) bad "caps-pre: ...with no placeholder left in it" "$out" ;;
    *)                    ok "caps-pre: ...with no placeholder left in it" ;;
esac
# F1's other half: a send source missing `bookmark` is a real gap too.
case "$out" in
    *"tank/a (snapshot,hold,release,send,bookmark)"*)
        ok "caps-pre: a source without bookmark is reported, not silently accepted" ;;
    *)  bad "caps-pre: a source without bookmark is reported, not silently accepted" "$out" ;;
esac
# Nothing may be touched by a preflight that refuses.
inst=$(grep -c . "$CP/crontab-calls" 2>/dev/null || echo 0)
case "$(cat "$CP/crontab-calls" 2>/dev/null)" in
    *"crontab -u zfsbackup "[!-]*|*"crontab /"*)
        bad "caps-pre: a refusing preflight installs nothing" "$(cat "$CP/crontab-calls")" ;;
    *)  ok "caps-pre: a refusing preflight installs nothing" ;;
esac
[ -f "$CP/jobs.conf" ] && ok "caps-pre: ...and the config is still where it was" \
                       || bad "caps-pre: ...and the config is still where it was" "config zniknal"

# The full delegated set passes, so the refusal above is about the missing
# verbs and not about the probe refusing everything.
mk_zfs "snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark"
out=$(run_cp); rc=$?
[ "$rc" -eq 0 ] && ok "caps-pre: the documented delegated set passes" \
                || bad "caps-pre: the documented delegated set passes" "rc=$rc out=$out"

# --- 33. quiesce is checked per JOB, against the real helper -----------------
#
# REV-20260801-027. `target_can_quiesce` proves the account can INVOKE the
# helper. That is not "the whitelist covers every guest the -q jobs will touch",
# and treating the first as evidence of the second let a partial grant pass
# preflight -- to be discovered by cron, after the migration, on the first
# uncovered VM.
#
# Note what is NOT stubbed here: the helper query itself. The review asked for
# the real scope parser and the real helper boundary, so the stub is a HELPER
# (a script answering like the real one, per guest), not a function returning
# one blanket verdict.
QS="$WORK/qscope"; mkdir -p "$QS/bin"
cat > "$QS/block.txt" <<'EOF'
# BEGIN zfs-backup-managed
11 0 * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapsend.sh -m "d_" -v 3 -q auto "tank/vm-100-disk-0,tank/vm-102-disk-0" 2>"$e"; rc=$?
37 * * * * e=$(mktemp); /home/z/zfs-snapshot-all/snapsend.sh -m "h_" -v 3 "tank/vm-100-disk-0" 2>"$e"; rc=$?
51 * * * * e=$(mktemp); /home/z/zfs-snapshot-all/delsnaps.sh "tank/vm-100-disk-0" "d" -D7 2>"$e"; rc=$?
EOF
echo '# END zfs-backup-managed' >> "$QS/block.txt"

# Only guest 100 is on this whitelist. 102 is refused exactly as the real
# helper refuses -- exit 2, message on stderr, nothing on stdout.
cat > "$QS/bin/helper" <<'STUB'
#!/bin/sh
case "$1" in
  status)
    [ -z "${2:-}" ] && { echo "OK account=test"; exit 0; }
    case "$2" in
      100) echo "id=100 kind=qemu running=yes frozen=no"; exit 0 ;;
      104) echo "id=104 kind=qemu running=no frozen=unknown"; exit 0 ;;
      105) echo "id=105 kind=absent running=no frozen=unknown"; exit 0 ;;
    esac
    echo "zfs-quiesce-helper: guest $2 is not on the quiesce whitelist" >&2; exit 2 ;;
esac
exit 2
STUB
chmod +x "$QS/bin/helper"

qs_run() {   # <helper path> -> the scope check, with runuser/sudo collapsed away
    bash -c "
        source '$ZFSBACKUP'
        QUIESCE_HELPER_PATH='$1'
        runuser() { shift 2; shift; \"\$@\"; }     # runuser --user X -- cmd...
        sudo() { shift; \"\$@\"; }                  # sudo -n cmd...
        for d in \$(block_quiesce_scope '$QS/block.txt'); do
            if qscope_covered test \"\$d\"; then echo \"ok \$d\"; else echo \"BRAK \$d\"; fi
        done" 2>&1
}

scope=$( bash -c "source '$ZFSBACKUP'; block_quiesce_scope '$QS/block.txt'" | tr '\n' ' ' )
check_eq "qscope: only the -q job's sources are in scope" \
         "$scope" "tank/vm-100-disk-0 tank/vm-102-disk-0 "

out=$(qs_run "$QS/bin/helper")
case "$out" in
    *"ok tank/vm-100-disk-0"*) ok "qscope: the guest the whitelist covers passes" ;;
    *) bad "qscope: the guest the whitelist covers passes" "$out" ;;
esac
case "$out" in
    *"BRAK tank/vm-102-disk-0"*) ok "qscope: the guest it does NOT cover is a gap" ;;
    *) bad "qscope: the guest it does NOT cover is a gap" "$out" ;;
esac

# The review's acceptance case: a grant covering both must pass, so the refusal
# above is about coverage and not about the probe refusing everything.
cat > "$QS/bin/helper-both" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -z "${2:-}" ] && { echo "OK account=test"; exit 0; }
          echo "id=$2 kind=qemu running=yes frozen=no"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$QS/bin/helper-both"
out=$(qs_run "$QS/bin/helper-both")
case "$out" in
    *BRAK*) bad "qscope: a grant covering both sources passes" "$out" ;;
    *)      ok "qscope: a grant covering both sources passes" ;;
esac

# "Nothing to quiesce" must stay acceptable, or every stopped VM becomes a
# blocked migration -- the too-strong half of REV-026, in a new place.
one=$( bash -c "
    source '$ZFSBACKUP'
    QUIESCE_HELPER_PATH='$QS/bin/helper'
    runuser() { shift 2; shift; \"\$@\"; }
    sudo() { shift; \"\$@\"; }
    for d in tank/vm-104-disk-0 tank/vm-105-disk-0 tank/not-a-guest; do
        if qscope_covered test \"\$d\"; then echo \"ok \$d\"; else echo \"BRAK \$d\"; fi
    done" 2>&1 | grep -c '^ok ' )
check_eq "qscope: stopped, absent and non-guest datasets are all acceptable" "$one" "3"

# A job WITHOUT -q contributes nothing, and neither does a prune or a monitor.
case "$scope" in
    *delsnaps*) bad "qscope: a prune is not a quiesce source" "$scope" ;;
    *)          ok "qscope: a prune is not a quiesce source" ;;
esac

# Under -r/-R the guests live in the CHILDREN; the named parent matches no guest
# at all, so a pool-wide job would otherwise look like it quiesces nothing.
cat > "$QS/rec.txt" <<'EOF'
# BEGIN zfs-backup-managed
11 0 * * * /home/z/zfs-snapshot-all/snapsend.sh -m "d_" -r -q auto "tank/data" 2>>/dev/null
# END zfs-backup-managed
EOF
cat > "$QS/bin/zfs" <<'STUB'
#!/bin/sh
for a in "$@"; do last=$a; done
echo "$last"
echo "$last/vm-108-disk-0"
STUB
chmod +x "$QS/bin/zfs"
rscope=$( PATH="$QS/bin:$PATH" bash -c "source '$ZFSBACKUP'; block_quiesce_scope '$QS/rec.txt'" | tr '\n' ' ' )
case "$rscope" in
    *vm-108-disk-0*) ok "qscope: -r expands to the children, where the guests are" ;;
    *) bad "qscope: -r expands to the children, where the guests are" "$rscope" ;;
esac

# Remote quiesce is granted on the SOURCE host. It must be reported, not passed
# silently and not failed locally (point 4).
cat > "$QS/rem.txt" <<'EOF'
# BEGIN zfs-backup-managed
5 * * * * /home/z/zfs-snapshot-all/snapget.sh -m "p_" -q auto "far:tank/x" "tank/pulled" 2>>/dev/null
# END zfs-backup-managed
EOF
bash -c "source '$ZFSBACKUP'; block_has_remote_quiesce '$QS/rem.txt'" \
    && ok "qscope: a remote -q job is recognised as remote" \
    || bad "qscope: a remote -q job is recognised as remote" "nie rozpoznane"
remscope=$( bash -c "source '$ZFSBACKUP'; block_quiesce_scope '$QS/rem.txt'" )
check_eq "qscope: ...and contributes no LOCAL dataset to check" "$remscope" ""

# The guest-id mapping is COPIED from lib-zfs-snap.sh rather than sourced, so it
# can drift. Pinned against the original on the shapes that matter.
LIBQ="$REPO/lib-zfs-snap.sh"
drift=0
for n in hdd/data/vm-107-disk-2 hdd/lxc/subvol-102-disk-0 rpool/data/nested/vm-100-disk-0 \
         vm-101-disk-0 rpool/data/vm-12345-disk-0 rpool/data hdd/mssql hdd/data/vm-107-disk; do
    a=$( bash -c "source '$ZFSBACKUP'; qscope_guest_id '$n' || echo NONE" )
    b=$( bash -c "VERBOSE=0; SSH_OPTS=(); source '$LIBQ' 2>/dev/null; quiesce_guest_id '$n' || echo NONE" )
    [ "$a" = "$b" ] || { drift=1; echo "     drift: $n -> [$a] vs [$b]"; }
done
[ "$drift" -eq 0 ] && ok "qscope: the copied guest-id mapping still agrees with lib-zfs-snap.sh" \
                   || bad "qscope: the copied guest-id mapping still agrees with lib-zfs-snap.sh" "patrz wyzej"

# --- 34. one remediation block, and a second look before committing ---------
#
# Owner decision 2026-08-02, option (b): the privileged grant stays a separate,
# deliberate command -- the migration prints ONE ordered block instead of
# assembling it for the operator, and re-checks the capabilities immediately
# before writing the crontabs.
#
# The list the block names is a CORRECTNESS question, not an ergonomic one.
# install_quiesce_grant REWRITES /etc/zfs-quiesce-allow/<account> from whatever
# --datasets it is handed, so a command listing only the GAPS would silently
# revoke quiesce for every guest that already had it. The first version of that
# message (REV-027, the same evening) printed exactly the gaps -- following it
# on a host where one guest was uncovered and three were fine would have taken
# the three away.
RM="$WORK/remedy"; mkdir -p "$RM"
cat > "$RM/block.txt" <<'EOF'
# BEGIN zfs-backup-managed
11 0 * * * /home/z/zfs-snapshot-all/snapsend.sh -m "d_" -q auto "tank/vm-100-disk-0,tank/vm-102-disk-0" 2>>/dev/null
51 * * * * /home/z/zfs-snapshot-all/delsnaps.sh "tank/vm-100-disk-0" "d" -D7 2>>/dev/null
# END zfs-backup-managed
EOF
cat > "$RM/helper" <<'STUB'
#!/bin/sh
case "$1" in
  status) [ -z "${2:-}" ] && { echo "OK"; exit 0; }
          [ "$2" = 100 ] && { echo "id=100 kind=qemu running=yes frozen=no"; exit 0; }
          echo "guest $2 is not on the quiesce whitelist" >&2; exit 2 ;;
esac
exit 2
STUB
chmod +x "$RM/helper"

# zfs allow: everything granted, so the ONLY gap is the quiesce whitelist. That
# isolates the question -- does the block name the gap, or the whole set?
cat > "$RM/zfs" <<'STUB'
#!/bin/sh
echo "	user zfsbackup snapshot,destroy,send,receive,create,mount,rollback,hold,release,canmount,bookmark"
exit 0
STUB
chmod +x "$RM/zfs"

out=$( PATH="$RM:$PATH" bash -c "
    source '$ZFSBACKUP'
    QUIESCE_HELPER_PATH='$RM/helper'
    runuser() { shift 2; shift; \"\$@\"; }
    sudo() { shift; \"\$@\"; }
    capability_survey zfsbackup '$RM/block.txt' || :
    echo \"MISSING_Q=\$CAP_MISSING_Q_N\"
    echo \"ALL=\$CAP_ALL\"
    capability_remediation zfsbackup" 2>&1 )

case "$out" in
    *"MISSING_Q=1"*) ok "remedy: exactly one guest is missing from the whitelist" ;;
    *) bad "remedy: exactly one guest is missing from the whitelist" "$out" ;;
esac

# THE point of this section: the printed command names BOTH datasets, although
# only one is a gap.
case "$out" in
    *'--datasets="tank/vm-100-disk-0 tank/vm-102-disk-0" --add-quiesce'*)
        ok "remedy: the command names the FULL set, not just the gap" ;;
    *)  bad "remedy: the command names the FULL set, not just the gap" "$out" ;;
esac
# ...and says why, because an operator who trims it back to the gap undoes the
# very thing the full list is protecting.
# The text has to match the primitive it prints. It said "PRZEPISYWANA"
# (rewritten) after --add-quiesce made the command additive -- true of the flag
# it no longer names, and exactly the sentence that would make an operator
# think unrelated grants are at risk (REV-20260802-029, separate defect).
case "$out" in
    *ZACHOWUJE*) ok "remedy: ...and says the command PRESERVES existing entries" ;;
    *) bad "remedy: ...and says the command PRESERVES existing entries" "$out" ;;
esac
case "$out" in
    *PRZEPISYWANA*) bad "remedy: ...and no longer claims the list is overwritten" "$out" ;;
    *) ok "remedy: ...and no longer claims the list is overwritten" ;;
esac
# One block, two steps, in order.
case "$out" in
    *"# 1."*"deploy.sh"*"# 2."*"migrate-to-account"*)
        ok "remedy: it is one ordered block -- grant, then migrate" ;;
    *)  bad "remedy: it is one ordered block -- grant, then migrate" "$out" ;;
esac

# A clean survey emits no gaps at all, so the block is only ever printed when
# there is something to do.
out2=$( PATH="$RM:$PATH" bash -c "
    source '$ZFSBACKUP'
    QUIESCE_HELPER_PATH='$RM/helper'
    runuser() { shift 2; shift; \"\$@\"; }
    sudo() { shift; \"\$@\"; }
    cat > '$RM/h2' <<'S2'
#!/bin/sh
case \"\$1\" in status) [ -z \"\${2:-}\" ] && { echo OK; exit 0; }; echo \"id=\$2 kind=qemu running=yes frozen=no\"; exit 0 ;; esac
exit 2
S2
    chmod +x '$RM/h2'; QUIESCE_HELPER_PATH='$RM/h2'
    capability_survey zfsbackup '$RM/block.txt' && echo CLEAN" 2>&1 )
case "$out2" in
    *CLEAN*) ok "remedy: a fully granted account surveys clean" ;;
    *) bad "remedy: a fully granted account surveys clean" "$out2" ;;
esac

# ---- the second look -------------------------------------------------------
#
# This is the load-bearing half of option (b). The operator leaves, runs the
# grant in another window, and comes back; what they actually ran is not
# knowable from here -- a narrower list, a different account, a typo. Phase 1
# validated a state that no longer has to be the state at commit time.
sur=$(grep -c 'capability_survey "\$acct" "\$newblock"' "$ZFSBACKUP")
[ "$sur" -ge 2 ] && ok "second-look: the survey is asked twice, not once" \
                 || bad "second-look: the survey is asked twice, not once" "wywolan: $sur"

# It must sit BEFORE the first crontab write, or it is not a guard.
lsur=$(grep -n 'if ! capability_survey "\$acct" "\$newblock"; then' "$ZFSBACKUP" | cut -d: -f1)
lcron=$(grep -n 'if ! cron_replace_all root "\$rootnew"; then' "$ZFSBACKUP" | cut -d: -f1)
if [ -n "$lsur" ] && [ -n "$lcron" ] && [ "$lsur" -lt "$lcron" ]; then
    ok "second-look: it runs before the first crontab is written"
else
    bad "second-look: it runs before the first crontab is written" "survey=$lsur crontab=$lcron"
fi

# And a failure there must put the config back -- phase 2 has already moved it
# by that point, so leaving it moved would strand the host between two states.
back=$(sed -n '/if ! capability_survey "\$acct" "\$newblock"; then/,/^    fi/p' "$ZFSBACKUP")
case "$back" in
    *'mv -f "$target_cfg" "$cfg"'*) ok "second-look: a refusal there moves the config back" ;;
    *) bad "second-look: a refusal there moves the config back" "$back" ;;
esac
case "$back" in
    *capability_remediation*) ok "second-look: ...and reprints what to do about it" ;;
    *) bad "second-look: ...and reprints what to do about it" "$back" ;;
esac

# --- 35. migrate-to-account refuses while either crontab is paused ----------
#
# REV-20260803-036 F5 follow-up: this verb commits through cron_replace_all,
# the one primitive deliberately left unguarded by cron_paused_guard (guarding
# it unconditionally would make deploy.sh --pause refuse itself, since pause
# and resume both commit through it too). Left unchecked here, migrating
# during an operator's own maintenance window would silently install an
# active managed block over -- or next to -- a paused one, undoing the pause
# exactly like the ordinary writers F5 already guards.
PM="$WORK/pausedmig"; mkdir -p "$PM/bin"
cat > "$PM/bin/getent" <<'EOF'
#!/bin/bash
[ "$1" = passwd ] && echo "zfsbackup:x:1001:1001::/home/zfsbackup:/bin/bash"
exit 0
EOF
cat > "$PM/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo 0; exit 0; }
echo root
EOF
chmod +x "$PM/bin/getent" "$PM/bin/id"

# 35a: root's crontab is the --fullcron placeholder (a single line).
cat > "$PM/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && exit 0
echo "# zfs-snapshot-all: PAUSED by deploy.sh --pause at 2026-01-01 00:00:00 UTC -- run: deploy.sh --resume"
exit 0
EOF
chmod +x "$PM/bin/crontab"
out=$( PATH="$PM/bin:$PATH" bash -c "source '$ZFSBACKUP'; cmd_migrate_to_account zfsbackup --yes" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"currently paused"*"deploy.sh --resume"*) true ;; *) false ;; esac; then
    ok "migrate-to-account: refuses while root is --fullcron paused"
else
    bad "migrate-to-account: refuses while root is --fullcron paused" "rc=$rc out=$out"
fi

# 35b: root's crontab is NOT fullcron-paused, but its own managed block is
# (block mode) -- the more common real shape, since block mode is the
# default. Same refusal, same reason.
cat > "$PM/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && exit 0
echo "# BEGIN zfs-backup-managed"
echo "# ZSA-PAUSED by deploy.sh --pause at 2026-01-01 00:00:00 UTC -- run: deploy.sh --resume"
echo "#ZSA-PAUSED## Source: /etc/zfs-snapshot-all/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "#ZSA-PAUSED#7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"automated_hourly_\" \"tank/a\" 2>>/root/scripts/cron.log"
echo "# END zfs-backup-managed"
exit 0
EOF
chmod +x "$PM/bin/crontab"
out=$( PATH="$PM/bin:$PATH" bash -c "source '$ZFSBACKUP'; cmd_migrate_to_account zfsbackup --yes" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"currently paused"*"deploy.sh --resume"*) true ;; *) false ;; esac; then
    ok "migrate-to-account: refuses while root's managed block is (block-mode) paused"
else
    bad "migrate-to-account: refuses while root's managed block is (block-mode) paused" "rc=$rc out=$out"
fi

# 35c: neither side paused -- the guard must not fire on the ordinary case
# (an unpaused managed block, same shape minus the pause header/prefixes).
# Expected to fail LATER, for an unrelated reason (no readable config/checkout
# in this minimal stub) -- the only thing asserted here is that it gets PAST
# the pause check, i.e. never mentions "currently paused".
cat > "$PM/bin/crontab" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && exit 0
echo "# BEGIN zfs-backup-managed"
echo "# Source: /etc/zfs-snapshot-all/jobs.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "7 * * * * /root/scripts/zfs-snapshot-all/snapsend.sh -m \"automated_hourly_\" \"tank/a\" 2>>/root/scripts/cron.log"
echo "# END zfs-backup-managed"
exit 0
EOF
chmod +x "$PM/bin/crontab"
out=$( PATH="$PM/bin:$PATH" bash -c "source '$ZFSBACKUP'; cmd_migrate_to_account zfsbackup --yes" 2>&1 ) || :
case "$out" in
    *"currently paused"*) bad "migrate-to-account: an ordinary (unpaused) managed block is not refused by the pause check" "$out" ;;
    *) ok "migrate-to-account: an ordinary (unpaused) managed block is not refused by the pause check" ;;
esac

# --- 36. resolve_mode_datasets (REV-20260802-033 slice 6) -------------------
#
# Fetches a MODE-based client's committed scope file + T3 hash sidecar over
# ssh, verifies the hash, reads the scope (lib-scope.sh), and walks each root
# via a remote `zfs list -r`, filtering through scope_includes -- all fully
# stubbable by faking `ssh` itself, since every remote call this function
# makes goes through it.
MDS="$WORK/modedatasets"; mkdir -p "$MDS/bin"

# REV-20260804-037: found live -- the fetch used to key off $LOAD_LABEL
# (peer_label($PEER_HOST), how THIS side names its OWN local files about
# the relationship) instead of $COLLECTOR_LABEL (this collector's own
# hostname, the label the PEER actually named its committed scope file
# under -- deploy.sh's do_pair/do_join `my_label`). LOAD_LABEL and
# COLLECTOR_LABEL are deliberately given DIFFERENT values below and the
# stub is strict about which one appears in the fetch path -- a loose
# glob (matching any "cat ...scope*") would have passed against the
# reviewed bug too, which is exactly why the bug went uncaught here until
# a real second host disagreed about its own hostname.
mds_ssh_stub() {   # <scope-body> <zfslist-body>
    cat > "$MDS/bin/ssh" <<EOF
#!/bin/bash
cmd="\${@: -1}"
case "\$cmd" in
    *cat*mycollector.scope.sha256*) cat '$MDS/hash' ;;
    *cat*mycollector.scope*)        cat '$MDS/scope' ;;
    *cat*.scope*)
        echo "stub: fetch used the wrong label (expected mycollector.*, got: \$cmd)" >&2
        exit 1
        ;;
    *zfs\ list*)          cat '$MDS/zfslist' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$MDS/bin/ssh"
}

mds_env='LOAD_LABEL=testlabel COLLECTOR_LABEL=mycollector LOAD_KEYFILE=/dev/null LOAD_PORT=22 LOAD_ALIAS=a LOAD_ALIAS_KH=/dev/null LOAD_ACCOUNT=zfsbackup LOAD_HOST=peer.example'

cat > "$MDS/scope" <<'EOF'
[dataset:tank/data]
	include_parent = no
	include_children = yes
EOF
sha256sum "$MDS/scope" | awk '{print $1}' > "$MDS/hash"
printf 'tank/data\ntank/data/child1\ntank/data/child2\n' > "$MDS/zfslist"
mds_ssh_stub

out=$( PATH="$MDS/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    $mds_env
    PEER_SAVED_MODE=backup PEER_SAVED_DATASETS=''
    resolve_mode_datasets
    echo \"RESULT=[\$PEER_SAVED_DATASETS]\"
" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"RESULT=[tank/data/child1 tank/data/child2]"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: fetches, verifies the hash, and resolves the real leaf list"
else
    bad "resolve_mode_datasets: fetches, verifies the hash, and resolves the real leaf list" "rc=$rc out=$out"
fi

# A no-op for a legacy (--peer-datasets) client: PEER_SAVED_DATASETS is
# already non-empty, so no ssh call should even happen.
out=$( PATH="$MDS/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    $mds_env
    PEER_SAVED_MODE=backup PEER_SAVED_DATASETS='tank/already'
    resolve_mode_datasets
    echo \"RESULT=[\$PEER_SAVED_DATASETS]\"
" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"RESULT=[tank/already]"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: a no-op when PEER_SAVED_DATASETS is already set"
else
    bad "resolve_mode_datasets: a no-op when PEER_SAVED_DATASETS is already set" "rc=$rc out=$out"
fi

# A no-op for a dataset-list client entirely (PEER_SAVED_MODE unset).
out=$( PATH="$MDS/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    $mds_env
    PEER_SAVED_DATASETS='tank/x'
    resolve_mode_datasets
    echo \"RESULT=[\$PEER_SAVED_DATASETS]\"
" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"RESULT=[tank/x]"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: a no-op when PEER_SAVED_MODE is unset (legacy client)"
else
    bad "resolve_mode_datasets: a no-op when PEER_SAVED_MODE is unset (legacy client)" "rc=$rc out=$out"
fi

# T3: a scope file that does not match its own hash sidecar (edited since
# the last --commit-scope, or committed differently) must refuse, not
# silently generate jobs for a scope nobody actually granted from.
printf 'notthehash\n' > "$MDS/hash"
out=$( PATH="$MDS/bin:$PATH" bash -c "source '$ZFSBACKUP'; $mds_env PEER_SAVED_MODE=backup PEER_SAVED_DATASETS=''; resolve_mode_datasets" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"does not match the hash"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: refuses on a scope/hash mismatch (T3)"
else
    bad "resolve_mode_datasets: refuses on a scope/hash mismatch (T3)" "rc=$rc out=$out"
fi
sha256sum "$MDS/scope" | awk '{print $1}' > "$MDS/hash"   # restore for the next cases

# No hash sidecar at all: --draft-scope ran but --commit-scope never did.
mds_ssh_nohash() {
    cat > "$MDS/bin/ssh" <<EOF
#!/bin/bash
cmd="\${@: -1}"
case "\$cmd" in
    *cat*.scope.sha256*) exit 1 ;;
    *cat*.scope*)        cat '$MDS/scope' ;;
    *zfs\ list*)          cat '$MDS/zfslist' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$MDS/bin/ssh"
}
mds_ssh_nohash
out=$( PATH="$MDS/bin:$PATH" bash -c "source '$ZFSBACKUP'; $mds_env PEER_SAVED_MODE=backup PEER_SAVED_DATASETS=''; resolve_mode_datasets" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"has --commit-scope run"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: refuses when --commit-scope has not run yet on the peer"
else
    bad "resolve_mode_datasets: refuses when --commit-scope has not run yet on the peer" "rc=$rc out=$out"
fi
mds_ssh_stub   # restore for the next case

# No scope file at all: --draft-scope has not run yet.
mds_ssh_noscope() {
    cat > "$MDS/bin/ssh" <<EOF
#!/bin/bash
exit 1
EOF
    chmod +x "$MDS/bin/ssh"
}
mds_ssh_noscope
out=$( PATH="$MDS/bin:$PATH" bash -c "source '$ZFSBACKUP'; $mds_env PEER_SAVED_MODE=backup PEER_SAVED_DATASETS=''; resolve_mode_datasets" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"has --draft-scope run"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: refuses when --draft-scope has not run yet on the peer"
else
    bad "resolve_mode_datasets: refuses when --draft-scope has not run yet on the peer" "rc=$rc out=$out"
fi

# --- 37. add-client --mode= validation (REV-20260802-033 slice 6) -----------
# Only the local (pre-network) refusal paths are testable here -- an ACCEPTED
# --mode= still goes on to call deploy.sh --pair for real, same reason the
# existing --bandwidth cases above only test rejection.
mode_rc() { ( cmd_add_client "modeclient" --lan=10.0.0.1 "$@" ) >/dev/null 2>&1; echo $?; }
[ "$(mode_rc --mode=bogus)" != 0 ] \
    && ok "add-client: --mode must be backup or sync" \
    || bad "add-client: --mode must be backup or sync" "accepted a bogus mode"
[ "$(mode_rc --mode=backup --datasets="tank/x")" != 0 ] \
    && ok "add-client: --mode and --datasets are refused together" \
    || bad "add-client: --mode and --datasets are refused together" "accepted both"
[ "$(mode_rc --mode=sync --target=tank/y)" != 0 ] \
    && ok "add-client: --mode=sync refuses an explicit --target" \
    || bad "add-client: --mode=sync refuses an explicit --target" "accepted both"
[ "$(mode_rc)" != 0 ] \
    && ok "add-client: neither --datasets nor --mode is refused" \
    || bad "add-client: neither --datasets nor --mode is refused" "accepted neither"

# --- 38. endpoint model (REV-20260802-033 slice 7 / F4) ---------------------
#
# Owner decisions 13-14: set-endpoint is conditional on the address actually
# changing, never a mandatory step after relocation. Two small, concrete
# defects matched that requirement's failure mode and were fixed here rather
# than a state-machine rewrite -- the seed/set-endpoint/verify-endpoint/
# activate-client machine already implemented 13-14 structurally (a routed-
# VPN relocation with an unchanged host:port never forces a set-endpoint call,
# since nothing but an explicit --lan=/--vpn= mutates the record).

# 38a. The post-seed hint used to read "then set-endpoint/verify-endpoint" as
# a fixed two-step sequence -- exactly the failure mode F4 names ("makes an
# administrator invent or repeat an address that did not change"). Pinned as
# a source grep because completing a real seed needs a live deploy.sh --pair
# (see file header) -- this only pins the wording, not the seed flow itself.
if grep -q 'skip straight to verify-endpoint' "$ZFSBACKUP" \
   && ! grep -q 'then set-endpoint/verify-endpoint' "$ZFSBACKUP"; then
    ok "seed: the next-step hint no longer presents set-endpoint as mandatory"
else
    bad "seed: the next-step hint no longer presents set-endpoint as mandatory" "old wording still present or new wording missing"
fi

# 38b. verify-endpoint used to discard snapget.sh's stderr (2>/dev/null),
# which silently swallowed the one diagnostic that distinguishes a source-IP/
# firewall restriction from every other failure (lib-zfs-snap.sh's "CONNECTION-
# level failure" message, F4's "source-IP restrictions... clearly reported").
# Stubbing snapget.sh itself (not ssh) is enough: cmd_verify_endpoint's own
# redirect handling is what is under test, not the connection.
VE="$WORK/verifyendpoint"; mkdir -p "$VE/clients" "$VE/peerstate" "$VE/keys"

printf '10.5.5.5 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' \
    > "$VE/keys/10.5.5.5_known_hosts"

cat > "$VE/peerstate/10.5.5.5.conf" <<'EOF'
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_DATASETS="tank/data/ds1"
EOF

cat > "$VE/clients/vetest.conf" <<'EOF'
CLIENT_NAME=vetest
PEER_HOST=10.5.5.5
STATE=seed_complete
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.5.5.5
ENDPOINT_LAN_PORT=22
EOF

VESTUB="$VE/snapget_fail.sh"
cat > "$VESTUB" <<'EOF'
#!/bin/bash
echo "2026-08-03 22:00:00 - Cannot reach zfsbackup@10.5.5.5 over ssh (exit 255) while listing the snapshots of 'tank/data/ds1' -- a CONNECTION-level failure (authentication, host key, network or DNS), NOT an empty dataset." >&2
exit 1
EOF
chmod +x "$VESTUB"

out=$( ( CLIENTS_DIR="$VE/clients" PEER_STATE_DIR="$VE/peerstate" PEER_KEY_DIR="$VE/keys" SNAPGET="$VESTUB"
         cmd_verify_endpoint vetest ) 2>&1 ); rc=$?
if [ "$rc" != 0 ] && case "$out" in *"CONNECTION-level failure"*) true ;; *) false ;; esac; then
    ok "verify-endpoint: a connectivity failure's stderr diagnostic reaches the operator (F4)"
else
    bad "verify-endpoint: a connectivity failure's stderr diagnostic reaches the operator (F4)" "rc=$rc out=$out"
fi

# 38c. U9: when the CURRENT endpoint does not answer, verify-endpoint tries
# each ENDPOINT_KNOWN candidate before giving up -- and promotes whichever one
# answers to ACTIVE_ENDPOINT, since it just proved itself. The stub picks its
# behaviour off which host it was called against, so both current and known
# addresses can be exercised in one client without touching real ssh.
printf '10.5.6.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' \
    > "$VE/keys/10.5.6.1_known_hosts"

cat > "$VE/peerstate/10.5.6.1.conf" <<'EOF'
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_DATASETS="tank/data/ds1"
EOF

cat > "$VE/clients/vefallback.conf" <<'EOF'
CLIENT_NAME=vefallback
PEER_HOST=10.5.6.1
STATE=seed_complete
ACTIVE_ENDPOINT=10.5.6.6:22
ENDPOINT_KNOWN=10.5.6.7:22
EOF

VESTUB2="$VE/snapget_fallback.sh"
cat > "$VESTUB2" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *10.5.6.6:*) echo "current endpoint unreachable" >&2; exit 255 ;;
        *10.5.6.7:*) echo "PLAN=INCREMENTAL base=x src=tank/data/ds1 tgt=tank/backups/lbl/tank/data/ds1"; exit 0 ;;
    esac
done
echo "unexpected args: $*" >&2
exit 1
EOF
chmod +x "$VESTUB2"

out=$( ( CLIENTS_DIR="$VE/clients" PEER_STATE_DIR="$VE/peerstate" PEER_KEY_DIR="$VE/keys" SNAPGET="$VESTUB2"
         cmd_verify_endpoint vefallback ) 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"promoting it to the active endpoint"*) true ;; *) false ;; esac; then
    ok "verify-endpoint: falls back to a known candidate when the current endpoint does not answer (U9)"
else
    bad "verify-endpoint: falls back to a known candidate when the current endpoint does not answer (U9)" "rc=$rc out=$out"
fi
promoted=$(grep '^ACTIVE_ENDPOINT=' "$VE/clients/vefallback.conf" 2>/dev/null | tail -1 || true)
if case "$promoted" in *"10.5.6.7:22"*) true ;; *) false ;; esac; then
    ok "verify-endpoint: the working candidate is promoted to ACTIVE_ENDPOINT"
else
    bad "verify-endpoint: the working candidate is promoted to ACTIVE_ENDPOINT" "$promoted"
fi
knownafter=$(grep '^ENDPOINT_KNOWN=' "$VE/clients/vefallback.conf" 2>/dev/null | tail -1 || true)
if case "$knownafter" in *"10.5.6.6:22"*) true ;; *) false ;; esac; then
    ok "verify-endpoint: the address that stopped answering becomes a known candidate in turn"
else
    bad "verify-endpoint: the address that stopped answering becomes a known candidate in turn" "$knownafter"
fi

# 38d. When NEITHER the current endpoint nor any known candidate answers,
# verify-endpoint refuses and names every address it tried.
cat > "$VE/clients/venone.conf" <<'EOF'
CLIENT_NAME=venone
PEER_HOST=10.5.6.1
STATE=seed_complete
ACTIVE_ENDPOINT=10.5.6.6:22
ENDPOINT_KNOWN=10.5.6.9:22
EOF
VESTUB3="$VE/snapget_none.sh"
cat > "$VESTUB3" <<'EOF'
#!/bin/bash
echo "nope" >&2
exit 255
EOF
chmod +x "$VESTUB3"
out=$( ( CLIENTS_DIR="$VE/clients" PEER_STATE_DIR="$VE/peerstate" PEER_KEY_DIR="$VE/keys" SNAPGET="$VESTUB3"
         cmd_verify_endpoint venone ) 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] \
   && case "$out" in *"10.5.6.6:22"*) true ;; *) false ;; esac \
   && case "$out" in *"10.5.6.9:22"*) true ;; *) false ;; esac \
   && case "$out" in *"set-endpoint"*) true ;; *) false ;; esac; then
    ok "verify-endpoint: refuses and names every tried address when none answer"
else
    bad "verify-endpoint: refuses and names every tried address when none answer" "rc=$rc out=$out"
fi

# --- 39. sync mode: path mapping + cluster-membership refusal (slice 8) -----
#
# REV-20260802-033 F3 "required sync mapping": sync reproduces the source's
# own path exactly, with no per-client namespace -- snapget_local_base/
# client_local_path are the one place that decision is made; emit_client_sections
# and every interactive command read it from there rather than re-deciding.

# 39a. snapget_local_base / client_local_path
out=$( ( PEER_SAVED_MODE=sync PEER_SAVED_TARGET=hdd/backups LOAD_LABEL=pve2
         echo "base=[$(snapget_local_base)]"
         echo "path=[$(client_local_path tank/data/ds1)]" ) )
if case "$out" in *"base=[]"*"path=[tank/data/ds1]"*) true ;; *) false ;; esac; then
    ok "sync: local base is empty, local path equals the source path exactly"
else
    bad "sync: local base is empty, local path equals the source path exactly" "$out"
fi
out=$( ( PEER_SAVED_MODE=backup PEER_SAVED_TARGET=hdd/backups LOAD_LABEL=pve2
         echo "base=[$(snapget_local_base)]"
         echo "path=[$(client_local_path tank/data/ds1)]" ) )
if case "$out" in *"base=[hdd/backups/pve2]"*"path=[hdd/backups/pve2/tank/data/ds1]"*) true ;; *) false ;; esac; then
    ok "backup: local base and local path are unchanged (namespaced under target/label)"
else
    bad "backup: local base and local path are unchanged (namespaced under target/label)" "$out"
fi

# 39b. emit_client_sections in sync mode: one [dataset:] and one [prune:] per
# source dataset, header equal to the source path (no shared base to strip),
# recursive=no on each prune (no shared recursive parent exists to sweep --
# see the prune-scope-race comment in emit_client_sections itself).
EC1="$WORK/emit_sync.conf"
: > "$EC1"
out=$( ( PEER_SAVED_MODE=sync PEER_SAVED_TARGET="" LOAD_LABEL=pve9 \
         LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.9.9.9 LOAD_FLAGS="-K /dev/null" \
         PEER_SAVED_DATASETS="rpool/data/vm-100-disk-0 hdd/LXC/103" PROFILE_GFS=1
         emit_client_sections "$EC1" synctest
         echo "managed=[${managed[*]}]"
         echo "prune_scope=[$prune_scope]" ) 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF '[dataset:rpool/data/vm-100-disk-0]' "$EC1" \
   && grep -qF '[dataset:hdd/LXC/103]' "$EC1" \
   && grep -qF '[prune:rpool/data/vm-100-disk-0]' "$EC1" \
   && grep -qF '[prune:hdd/LXC/103]' "$EC1" \
   && grep -qF 'recursive    = no' "$EC1" \
   && ! grep -qF 'recursive    = yes' "$EC1" \
   && case "$out" in *"managed=[rpool/data/vm-100-disk-0 hdd/LXC/103]"*) true ;; *) false ;; esac \
   && case "$out" in *"prune_scope=[rpool/data/vm-100-disk-0 hdd/LXC/103]"*) true ;; *) false ;; esac; then
    ok "emit_client_sections (sync): per-dataset [dataset:]/[prune:] at the bare source path, recursive=no"
else
    bad "emit_client_sections (sync): per-dataset [dataset:]/[prune:] at the bare source path, recursive=no" "rc=$rc out=$out file=$(cat "$EC1")"
fi

# 39c. is_previously_managed must treat a multi-entry MANAGED_PRUNE_SCOPE
# (one path per dataset, as sync now records) as a LIST, not one exact-match
# string -- a single-entry backup-mode value still has to keep working.
CF7="$WORK/jobs.syncprune.conf"
cat > "$CF7" <<'EOF'
[dataset:rpool/data/vm-100-disk-0]
	notify = a
[dataset:hdd/LXC/103]
	notify = b
EOF
out=$( bash -c "source '$ZFSBACKUP'; MANAGED_PRUNE_SCOPE='rpool/data/vm-100-disk-0 hdd/LXC/103'; remove_managed_sections '$CF7' synctest rpool/data/vm-100-disk-0 hdd/LXC/103" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '[dataset:rpool/data/vm-100-disk-0]' "$CF7" && ! grep -qF '[dataset:hdd/LXC/103]' "$CF7"; then
    ok "is_previously_managed: a multi-entry MANAGED_PRUNE_SCOPE is read as a list (sync back-compat)"
else
    bad "is_previously_managed: a multi-entry MANAGED_PRUNE_SCOPE is read as a list (sync back-compat)" "rc=$rc out=$out file=$(cat "$CF7" 2>/dev/null)"
fi

# 39d. add-client --mode=sync refuses at enrolment when the peer looks like a
# member of the SAME PVE cluster (U8) -- checked via PVE_NODES_DIR, overridden
# here instead of the real /etc/pve/nodes so this needs no real cluster.
U8="$WORK/u8nodes"; mkdir -p "$U8/pve2"
out=$( ( PVE_NODES_DIR="$U8"; cmd_add_client u8client --lan=pve2 --mode=sync ) 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"SAME PVE cluster"*) true ;; *) false ;; esac; then
    ok "add-client --mode=sync refuses a peer that looks like a same-cluster node (U8)"
else
    bad "add-client --mode=sync refuses a peer that looks like a same-cluster node (U8)" "rc=$rc out=$out"
fi
# A peer with no matching node directory is not refused BY THIS CHECK -- it
# still goes on to call deploy.sh --pair for real (same reason section 37
# only tests refusal paths), so success here just means U8 did not fire.
out=$( ( PVE_NODES_DIR="$U8"; cmd_add_client u8client2 --lan=notacluster.example --mode=sync ) 2>&1 ); rc=$?
if case "$out" in *"SAME PVE cluster"*) false ;; *) true ;; esac; then
    ok "add-client --mode=sync does not refuse a peer with no matching node directory"
else
    bad "add-client --mode=sync does not refuse a peer with no matching node directory" "rc=$rc out=$out"
fi

# --- 40. add-client --join-remotely pass-through (REV-20260802-033 slice 9) -
#
# This file does not reimplement deploy.sh's scp/ssh/ssh-t orchestration
# (do_pair does that -- see test/join/run.sh for the package-field half of
# it); the ONLY thing to pin here is that add-client forwards the flag
# through to deploy.sh --pair, and only when it was actually given. DEPLOY is
# overridden the same way SNAPGET already is in sections 38/39 -- a plain
# global reassigned in a subshell.
JR="$WORK/joinremote"; mkdir -p "$JR/clients"
JRDEPLOY="$JR/deploy_stub.sh"
cat > "$JRDEPLOY" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$JR/args.out"
exit 0
EOF
chmod +x "$JRDEPLOY"

out=$( ( CLIENTS_DIR="$JR/clients" DEPLOY="$JRDEPLOY"
         cmd_add_client jrtest --lan=10.7.7.7 --datasets="tank/a" --target=tank/backups --join-remotely ) 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -qF -- "--join-remotely" "$JR/args.out"; then
    ok "add-client --join-remotely: forwarded to deploy.sh --pair"
else
    bad "add-client --join-remotely: forwarded to deploy.sh --pair" "rc=$rc out=$out args=$(cat "$JR/args.out" 2>/dev/null)"
fi

out2=$( ( CLIENTS_DIR="$JR/clients" DEPLOY="$JRDEPLOY"
          cmd_add_client jrtest2 --lan=10.7.7.8 --datasets="tank/a" --target=tank/backups ) 2>&1 ); rc2=$?
if [ "$rc2" -eq 0 ] && ! grep -qF -- "--join-remotely" "$JR/args.out"; then
    ok "add-client without --join-remotely: deploy.sh --pair is not passed the flag"
else
    bad "add-client without --join-remotely: deploy.sh --pair is not passed the flag" "rc=$rc2 args=$(cat "$JR/args.out" 2>/dev/null)"
fi

# --- 41. role-naming corrections (REV-20260802-033 slice 10) --------------
#
# U9 confirmed in code that the machine relocated in these three messages
# is the collector (this host), never "the source" -- but two of the three
# still said "the source" for the OTHER party (the peer SSH connects to),
# right next to a correct "this collector" a few words earlier. That is
# the same failure mode in a subtler shape: a reader who just parsed
# "the collector relocates" then hits "the source" again has no textual
# signal it now means the far end, not the same machine renamed back.
# Pinned as source greps (like 38a) because exercising these end to end
# needs a live seed/final-catchup/verify-endpoint cycle -- see file header.

if grep -q 'If SSH now reaches the peer at a DIFFERENT host or port' "$ZFSBACKUP" \
   && ! grep -q 'If SSH now reaches the source at a DIFFERENT host or port' "$ZFSBACKUP"; then
    ok "seed hint: the far end is named 'the peer', not 'the source'"
else
    bad "seed hint: the far end is named 'the peer', not 'the source'" "old wording still present or new wording missing"
fi

if grep -q "If the peer is still reachable at the SAME host:port" "$ZFSBACKUP" \
   && ! grep -q "If the source is still reachable at the SAME host:port" "$ZFSBACKUP"; then
    ok "final-catchup hint: the far end is named 'the peer', not 'the source'"
else
    bad "final-catchup hint: the far end is named 'the peer', not 'the source'" "old wording still present or new wording missing"
fi

if grep -q "If the peer has a genuinely new address" "$ZFSBACKUP" \
   && ! grep -q "If the source has a genuinely new address" "$ZFSBACKUP"; then
    ok "verify-endpoint failure: the far end is named 'the peer', not 'the source'"
else
    bad "verify-endpoint failure: the far end is named 'the peer', not 'the source'" "old wording still present or new wording missing"
fi

# --- 41b. ensure_alias_known_hosts: the alias file's OWNER follows its PATH -
# (found live twice: 2026-08-01 and again 2026-08-06 during REV-045 slice 4).
# $user chose ~account/.ssh as the destination, so $user must own the result;
# keying the chown on $LOCAL_USER left root:root 0600 in the account's own
# ~/.ssh whenever the calling flow had not run read_server_conf -- and every
# account-side pull then failed host key verification with the correct pinned
# key sitting right there, unreadable.
AKH_HOME="$WORK/akh-home"; mkdir -p "$AKH_HOME/.ssh"
printf 'fakehost ssh-ed25519 AAAATESTKEY\n' > "$AKH_HOME/.ssh/pairing-fakepeer_known_hosts"
akh_out="$(
    LOCAL_USER=""
    getent() { [ "$2" = "fakeacct" ] && echo "fakeacct:x:1234:1234::$AKH_HOME:/bin/bash"; }
    chown() { echo "CHOWN $*" >> "$WORK/akh-chown.log"; }
    ensure_alias_known_hosts fakepeer fakeacct 22 zfs-client-fk
)"
if [ "$akh_out" = "$AKH_HOME/.ssh/pairing-fakepeer_alias_known_hosts" ] \
        && grep -q "^CHOWN fakeacct:fakeacct $AKH_HOME/.ssh/pairing-fakepeer_alias_known_hosts$" "$WORK/akh-chown.log" 2>/dev/null; then
    ok "ensure_alias_known_hosts chowns to the PATH's account even with LOCAL_USER unset"
else
    bad "ensure_alias_known_hosts chowns to the PATH's account even with LOCAL_USER unset" "out=$akh_out" "$(cat "$WORK/akh-chown.log" 2>/dev/null)"
fi
if grep -q "^zfs-client-fk ssh-ed25519 AAAATESTKEY$" "$AKH_HOME/.ssh/pairing-fakepeer_alias_known_hosts"; then
    ok "ensure_alias_known_hosts still rewrites the pinned key under the alias"
else
    bad "ensure_alias_known_hosts still rewrites the pinned key under the alias" "$(cat "$AKH_HOME/.ssh/pairing-fakepeer_alias_known_hosts" 2>/dev/null)"
fi

# --- 42. pause-client / resume-client (REV-20260804-045, logical pause) -----
# The ONLY mutation either verb is allowed is the marker under
# $RELATIONSHIPS_DIR. Both dirs overridden into $WORK; the root gate is
# satisfied by shadowing id(1) with a function inside each subshell -- the
# gate protects /var/lib in real life, not the logic under test here.
PAUSE_CLIENTS="$WORK/pause-clients"
PAUSE_REL="$WORK/pause-relationships"
mkdir -p "$PAUSE_CLIENTS"
printf 'CLIENT_NAME=alpha\nSTATE=active\nACTIVE_ENDPOINT=10.0.0.1:22\n' > "$PAUSE_CLIENTS/alpha.conf"
printf 'CLIENT_NAME=beta\nSTATE=active\nACTIVE_ENDPOINT=10.0.0.2:22\n'  > "$PAUSE_CLIENTS/beta.conf"

run_pause() {  # <verb> <args...> -- captured subshell with overridden state
    (
        id() { echo 0; }
        CLIENTS_DIR="$PAUSE_CLIENTS"
        RELATIONSHIPS_DIR="$PAUSE_REL"
        "cmd_$1" "${@:2}"
    ) >"$WORK/pause.out" 2>&1
}

# 1. pause creates exactly one marker, with a timestamp and the reason.
if run_pause pause_client alpha --reason="disk swap" \
        && [ -f "$PAUSE_REL/alpha/paused" ] \
        && grep -q '^PAUSED_AT="' "$PAUSE_REL/alpha/paused" \
        && grep -q '^PAUSED_REASON="disk swap"' "$PAUSE_REL/alpha/paused" \
        && [ "$(find "$PAUSE_REL" -type f | wc -l)" = "1" ]; then
    ok "pause-client creates exactly one marker with timestamp and reason"
else
    bad "pause-client creates exactly one marker with timestamp and reason" "$(cat "$WORK/pause.out")" "$(find "$PAUSE_REL" 2>/dev/null)"
fi

# ...and no leftover staging file survives next to it.
if ls "$PAUSE_REL/alpha/"*.new >/dev/null 2>&1; then
    bad "pause-client leaves no staging file behind" "$(ls "$PAUSE_REL/alpha/")"
else
    ok "pause-client leaves no staging file behind"
fi

# 2. repeated pause: no-op success, marker unchanged.
before="$(cat "$PAUSE_REL/alpha/paused")"
if run_pause pause_client alpha && grep -q "already paused" "$WORK/pause.out" \
        && [ "$(cat "$PAUSE_REL/alpha/paused")" = "$before" ]; then
    ok "repeated pause-client is a no-op success, marker byte-identical"
else
    bad "repeated pause-client is a no-op success, marker byte-identical" "$(cat "$WORK/pause.out")"
fi

# 6. isolation: alpha's pause does not touch beta, and beta's own state
# machinery sees it unpaused.
if ( RELATIONSHIPS_DIR="$PAUSE_REL"; client_paused beta ); then
    bad "one paused client does not affect a second client" "beta reads as paused"
else
    ok "one paused client does not affect a second client"
fi

# status (list) marks the paused one and only it.
stat_out="$( ( CLIENTS_DIR="$PAUSE_CLIENTS"; RELATIONSHIPS_DIR="$PAUSE_REL"; cmd_status ) 2>&1 )"
if echo "$stat_out" | grep 'alpha' | grep -q 'PAUSED_LOCAL' \
        && ! echo "$stat_out" | grep 'beta' | grep -q 'PAUSED_LOCAL'; then
    ok "status list shows PAUSED_LOCAL for alpha and not for beta"
else
    bad "status list shows PAUSED_LOCAL for alpha and not for beta" "$stat_out"
fi

# 5. invalid / path-traversal labels refuse without filesystem mutation.
snap_before="$(find "$PAUSE_REL" | sort)"
for evil in "../alpha" "a/b" "" "x;rm"; do
    if run_pause pause_client "$evil"; then
        bad "pause-client refuses label '$evil'" "accepted: $(cat "$WORK/pause.out")"
    else
        ok "pause-client refuses label '$evil'"
    fi
done
if [ "$(find "$PAUSE_REL" | sort)" = "$snap_before" ]; then
    ok "refused labels caused no filesystem mutation under the state dir"
else
    bad "refused labels caused no filesystem mutation under the state dir" "$(find "$PAUSE_REL")"
fi

# pause of a name with no client record refuses (typo cannot create orphan
# state a future client would inherit).
if run_pause pause_client ghost; then
    bad "pause-client refuses a name with no client record" "accepted: $(cat "$WORK/pause.out")"
else
    ok "pause-client refuses a name with no client record"
fi

# 3. resume removes exactly that marker (and its now-empty dir).
if run_pause resume_client alpha && [ ! -e "$PAUSE_REL/alpha/paused" ] \
        && [ ! -e "$PAUSE_REL/alpha" ]; then
    ok "resume-client removes exactly the marker and its empty dir"
else
    bad "resume-client removes exactly the marker and its empty dir" "$(cat "$WORK/pause.out")" "$(find "$PAUSE_REL" 2>/dev/null)"
fi

# 4. repeated resume: no-op success.
if run_pause resume_client alpha && grep -q "not paused" "$WORK/pause.out"; then
    ok "repeated resume-client is a no-op success"
else
    bad "repeated resume-client is a no-op success" "$(cat "$WORK/pause.out")"
fi

# resume works for a label whose client record is GONE (cleanup path).
mkdir -p "$PAUSE_REL/orphan"; printf 'PAUSED_AT="x"\n' > "$PAUSE_REL/orphan/paused"
if run_pause resume_client orphan && [ ! -e "$PAUSE_REL/orphan/paused" ]; then
    ok "resume-client clears a marker whose client record no longer exists"
else
    bad "resume-client clears a marker whose client record no longer exists" "$(cat "$WORK/pause.out")"
fi

# 9/10. source pins for the halves that need a live pairing to exercise:
# add-client reports-and-clears a stale marker; remove-client clears its own.
if grep -q "does not start paused" "$ZFSBACKUP" \
        && grep -q "secretly paused" "$ZFSBACKUP"; then
    ok "add-client carries the report-and-clear rule for a stale pause marker"
else
    bad "add-client carries the report-and-clear rule for a stale pause marker" "source pin missing"
fi
if grep -q "cleared this client's PAUSED_LOCAL marker" "$ZFSBACKUP"; then
    ok "remove-client carries its own pause-state cleanup"
else
    bad "remove-client carries its own pause-state cleanup" "source pin missing"
fi

# The documented limitation is part of the surface: help and pause output
# both say a label-less manual run is NOT blocked.
if run_pause pause_client beta && grep -q "not blocked" "$WORK/pause.out" \
        && usage 2>&1 | grep -q "NOT" && usage 2>&1 | grep -qi "orchestration switch"; then
    ok "limitation (label-less manual run not blocked) is stated by pause output and --help"
else
    bad "limitation (label-less manual run not blocked) is stated by pause output and --help" "$(cat "$WORK/pause.out")"
fi
# REV-053 F2: and it must point at the control that DOES have the property,
# now that one exists. A limitation notice naming no alternative aged into a
# command telling its operator that a shipped feature is unimplemented -- and
# the runbook quoted it verbatim.
if grep -q "disable-client beta" "$WORK/pause.out" \
        && ! grep -qi "unimplemented" "$WORK/pause.out"; then
    ok "pause output points at disable-client and no longer calls it unimplemented"
else
    bad "pause output points at disable-client and no longer calls it unimplemented" "$(cat "$WORK/pause.out")"
fi
run_pause resume_client beta || :

# --- 42b. test plan A8/A11: the two baseline properties hard disable builds on
# (docs/testing/pair-pause-test-plan.md). Both are about IDENTITY and
# DURABILITY of the pause state, which is exactly what a peer-side DISABLED
# marker will later have to match.

# A8: the state is durable across a restart. The property that decides this
# is WHERE it lives: /run and /tmp are cleared on boot, /var/lib is not. A
# marker under a volatile directory would "work" in every other test here
# and silently resume every paused relationship at the next reboot.
default_rel_dir=$(bash -c "source '$ZFSBACKUP' 2>/dev/null; printf '%s' \"\$RELATIONSHIPS_DIR\"")
case "$default_rel_dir" in
    /var/lib/*) ok "A8 pause state lives under /var/lib (survives reboot), not /run or /tmp" ;;
    *) bad "A8 pause state lives under /var/lib (survives reboot), not /run or /tmp" "got: $default_rel_dir" ;;
esac

# ...and it is read from disk by a FRESH process, holding no state of its own:
# pause written by one process is seen by another that shares nothing but the
# filesystem (a restart differs from this only in taking longer).
run_pause pause_client alpha --reason="A8 durability" >/dev/null
if bash -c "source '$ZFSBACKUP' 2>/dev/null; RELATIONSHIPS_DIR='$PAUSE_REL'; client_paused alpha"; then
    ok "A8 a fresh process reads the pause state from disk, holding nothing in memory"
else
    bad "A8 a fresh process reads the pause state from disk, holding nothing in memory" "a separate process did not see the marker"
fi

# A11: an endpoint switch preserves pause identity. The label is the CLIENT
# NAME, so a relationship that moves from LAN to VPN keeps the same -L and
# the same marker path -- the address changes in src=, nothing else. This is
# the ADR-0012 identity rule ("not hostname, IP, LAN/VPN endpoint") asserted
# on the generator that actually writes the cron lines.
EP1="$WORK/emit_ep_lan.conf"; : > "$EP1"
EP2="$WORK/emit_ep_vpn.conf"; : > "$EP2"
( PEER_SAVED_MODE="" PEER_SAVED_TARGET="hdd/backups" LOAD_LABEL=10.0.0.5 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.0.0.5 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data/vm-1" PROFILE_GFS=1
  emit_client_sections "$EP1" epclient ) >/dev/null 2>&1
( PEER_SAVED_MODE="" PEER_SAVED_TARGET="hdd/backups" LOAD_LABEL=10.0.0.5 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=172.16.9.9 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data/vm-1" PROFILE_GFS=1
  emit_client_sections "$EP2" epclient ) >/dev/null 2>&1
lan_label=$(grep -c '^	pair_label   = epclient$' "$EP1")
vpn_label=$(grep -c '^	pair_label   = epclient$' "$EP2")
if [ "$lan_label" -ge 1 ] && [ "$lan_label" = "$vpn_label" ] \
        && grep -q 'src          = zfsbackup@10.0.0.5:' "$EP1" \
        && grep -q 'src          = zfsbackup@172.16.9.9:' "$EP2"; then
    ok "A11 an endpoint switch changes src= only -- pair_label (the pause identity) is unchanged"
else
    bad "A11 an endpoint switch changes src= only -- pair_label (the pause identity) is unchanged" "lan=$lan_label vpn=$vpn_label" "$(grep -E 'src|pair_label' "$EP1" "$EP2")"
fi

# ...and the marker path itself never mentions the endpoint, so no address
# change can strand or duplicate the state.
mp=$( RELATIONSHIPS_DIR="$PAUSE_REL"; pause_marker_path epclient )
case "$mp" in
    *10.0.0.5*|*172.16.9.9*) bad "A11 the marker path is keyed by relationship only, never by endpoint" "$mp" ;;
    "$PAUSE_REL/epclient/paused") ok "A11 the marker path is keyed by relationship only, never by endpoint" ;;
    *) bad "A11 the marker path is keyed by relationship only, never by endpoint" "unexpected: $mp" ;;
esac
run_pause resume_client alpha >/dev/null || :

# --- 43. disable-client / enable-client ordering (ADR-0012) ------------------
# The ADR fixes the ORDER, and the order is the safety property: disable
# pauses locally BEFORE the peer is touched (so no scheduled job can start in
# the window), enable clears the PEER first and verifies before the local
# pause lifts (so no job starts against a peer that still refuses). Every
# case below stubs the peer and asserts the sequence plus what survives a
# failure at each boundary.
DIS_CLIENTS="$WORK/dis-clients"; DIS_REL="$WORK/dis-rel"
mkdir -p "$DIS_CLIENTS"
printf 'CLIENT_NAME=dc\nSTATE=active\nPEER_HOST=10.0.0.9\nACTIVE_ENDPOINT=10.0.0.9:22\n' > "$DIS_CLIENTS/dc.conf"

# run_dis <verb> <disable_rc> <status_reply> -- captures the call sequence
run_dis() {
    local verb="$1" ctl_rc="$2" status_reply="$3"
    ( set +e
      id() { echo 0; }
      CLIENTS_DIR="$DIS_CLIENTS"; RELATIONSHIPS_DIR="$DIS_REL"
      load_client_and_connection() { . "$1"; LOAD_KEYFILE=/dev/null; LOAD_PORT=22
                                     LOAD_ALIAS=a; LOAD_ALIAS_KH=/dev/null
                                     LOAD_ACCOUNT=acct; LOAD_HOST=10.0.0.9; }
      pair_control() {
          echo "CALL $1" >> "$WORK/dis.seq"
          case "$1" in
              status) printf 'PAIR_STATE=%s\nPAIR_LABEL=dc\n' "$status_reply"; return 0 ;;
              *) return "$ctl_rc" ;;
          esac
      }
      "cmd_${verb}_client" dc
      echo "RC=$?" >> "$WORK/dis.seq" ) >"$WORK/dis.out" 2>&1
}

# 1. disable, happy path: local pause exists BEFORE the peer is asked, and
#    the peer's state is READ BACK rather than trusted from the write.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"
run_dis disable 0 DISABLED
seq_got=$(tr '\n' ' ' < "$WORK/dis.seq")
if [ -f "$DIS_REL/dc/paused" ] && [ "$seq_got" = "CALL disable CALL status RC=0 " ]; then
    ok "43 disable: local pause first, then the peer, then a read-back"
else
    bad "43 disable: local pause first, then the peer, then a read-back" "seq=[$seq_got] paused=$([ -f "$DIS_REL/dc/paused" ] && echo yes || echo NO)" "$(cat "$WORK/dis.out")"
fi

# 2. disable, peer unreachable: the local pause STAYS (the relationship is
#    stopped), the failure is named as partial, and the retry is spelled out.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"
run_dis disable 1 ACTIVE
# (no RC= line is expected on the failure paths: die exits the subshell
# before run_dis can record one, which is itself the contract -- a partial
# transition must be fatal to the command, not a warning it survives.)
if [ -f "$DIS_REL/dc/paused" ] && grep -q "PAUSED_LOCAL, peer NOT disabled" "$WORK/dis.out" \
        && grep -q "safe retry" "$WORK/dis.out"; then
    ok "43 disable: a peer failure leaves the local pause in place and says so"
else
    bad "43 disable: a peer failure leaves the local pause in place and says so" "$(cat "$WORK/dis.out")"
fi

# 3. disable, peer accepts but read-back disagrees: never reported as
#    disabled -- the operator must not act as though it is blocked.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"
run_dis disable 0 ACTIVE
if grep -q "TRANSITION_INCOMPLETE" "$WORK/dis.out" && ! grep -q "is DISABLED" "$WORK/dis.out"; then
    ok "43 disable: a read-back that disagrees is TRANSITION_INCOMPLETE, never success"
else
    bad "43 disable: a read-back that disagrees is TRANSITION_INCOMPLETE, never success" "$(cat "$WORK/dis.out")"
fi

# 4. enable, happy path: the PEER is cleared and verified BEFORE the local
#    pause lifts.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"; mkdir -p "$DIS_REL/dc"; printf 'PAUSED_AT="x"\n' > "$DIS_REL/dc/paused"
run_dis enable 0 ACTIVE
seq_got=$(tr '\n' ' ' < "$WORK/dis.seq")
if [ "$seq_got" = "CALL enable CALL status RC=0 " ] && [ ! -e "$DIS_REL/dc/paused" ]; then
    ok "43 enable: peer cleared and verified first, local pause lifted last"
else
    bad "43 enable: peer cleared and verified first, local pause lifted last" "seq=[$seq_got] paused=$([ -e "$DIS_REL/dc/paused" ] && echo STILL-THERE || echo gone)" "$(cat "$WORK/dis.out")"
fi

# 5. enable, peer refuses: the local pause must NOT lift -- otherwise a
#    scheduled job starts against a peer that still refuses, turning a
#    deliberate block into a nightly alert.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"; mkdir -p "$DIS_REL/dc"; printf 'PAUSED_AT="x"\n' > "$DIS_REL/dc/paused"
run_dis enable 1 DISABLED
if [ -f "$DIS_REL/dc/paused" ] && grep -q "STATE unchanged" "$WORK/dis.out"; then
    ok "43 enable: a peer failure leaves the local pause in place"
else
    bad "43 enable: a peer failure leaves the local pause in place" "$(cat "$WORK/dis.out")"
fi

# 6. enable, peer accepts but still reports DISABLED: same rule, and the
#    local pause stays.
: > "$WORK/dis.seq"; rm -rf "$DIS_REL"; mkdir -p "$DIS_REL/dc"; printf 'PAUSED_AT="x"\n' > "$DIS_REL/dc/paused"
run_dis enable 0 DISABLED
if [ -f "$DIS_REL/dc/paused" ] && grep -q "TRANSITION_INCOMPLETE" "$WORK/dis.out"; then
    ok "43 enable: a read-back still showing DISABLED keeps the local pause"
else
    bad "43 enable: a read-back still showing DISABLED keeps the local pause" "$(cat "$WORK/dis.out")"
fi

# 7b. A deliberate refusal is not a dead endpoint. verify-endpoint's probe is
# a data-plane command, so a DISABLED relationship refuses it at the peer --
# and blaming the address sends the operator hunting a network fault that
# does not exist. Source pin: the discrimination and the remedy must both be
# there (the live campaign hit exactly this, 2026-08-06).
if grep -q "is DISABLED at the peer, so its endpoints cannot be verified" "$ZFSBACKUP" \
        && grep -q "This is not an address problem" "$ZFSBACKUP" \
        && grep -q "Enable it first" "$ZFSBACKUP"; then
    ok "43 verify-endpoint tells a disabled relationship apart from an unreachable address"
else
    bad "43 verify-endpoint tells a disabled relationship apart from an unreachable address" "the PAIR_DISABLED discrimination is missing"
fi

# 7. An unreachable peer is never read as "active": peer_pair_state must fail
#    rather than default to a comfortable answer.
out=$( ( pair_control() { return 255; }; peer_pair_state; echo "rc=$?; state=[${PEER_PAIR_STATE:-}]" ) 2>&1 )
if case "$out" in *"rc=1; state=[]"*) true;; *) false;; esac; then
    ok "43 an unreachable peer yields no state at all, never ACTIVE"
else
    bad "43 an unreachable peer yields no state at all, never ACTIVE" "$out"
fi

# --- 44. FIELD SURVIVAL: the profile fragment is composed, not translated ----
#
# REV-20260809-082 F1. The runtime used to lift three named keys out of the
# rendered fragment and write them by hand, so any other valid profile field
# validated at the boundary and was then silently dropped. The built-in profile
# carries only use_template, which is why nothing failed.
#
# This is also the case that caught a much worse thing while it was being
# written: with profile_emit UNDEFINED -- client sections losing their entire
# policy reference -- the suite still reported 295/295. Nothing here asserted
# that a generated [dataset:] carries a use_template line at all. So this block
# pins the field, not just the extra one.
FS="$WORK/fieldsurvival"; mkdir -p "$FS/p/prof"
cp "$REPO/profiles/default/templates.conf" "$FS/p/prof/templates.conf"
cp "$REPO/profiles/default/prune.inc"      "$FS/p/prof/prune.inc"
# A second VALID dataset field the built-in profile does not carry. `recursive`
# is explicitly profile-owned (REV-073) and is not in the forbidden list, so a
# profile is entitled to set it and the runtime must carry it through.
{ cat "$REPO/profiles/default/dataset.inc"; printf 'recursive = flat\n'; } > "$FS/p/prof/dataset.inc"

EC_FS="$FS/out.conf"; : > "$EC_FS"
out=$( ( PROFILE_ROOT="$FS/p" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=pveX \
         LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.1.1.1 LOAD_FLAGS="-K /dev/null" \
         PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1
         emit_client_sections "$EC_FS" fstest ) 2>&1 ); rc=$?

# The field that was always there. Asserted because it was NOT: see the header.
if [ "$rc" -eq 0 ] && grep -q 'use_template *= *profile__prof__standard_hourly' "$EC_FS"; then
    ok "field survival: the emitted [dataset:] carries the profile's use_template at all"
else
    bad "field survival: the emitted [dataset:] carries the profile's use_template at all" "rc=$rc out=$out file=$(cat "$EC_FS")"
fi

# The field the old extractor dropped.
if grep -q '^	recursive = flat$' "$EC_FS"; then
    ok "field survival: a valid profile-owned field the extractor did not know survives"
else
    bad "field survival: a valid profile-owned field the extractor did not know survives" "$(cat "$EC_FS")"
fi

# Prune policy comes from the fragment too, not from literals in the runtime.
if grep -q 'gfs *= *yes' "$EC_FS" && grep -q 'gfs_pattern *= *automated_' "$EC_FS"; then
    ok "field survival: the [prune:] policy fields come from the profile fragment"
else
    bad "field survival: the [prune:] policy fields come from the profile fragment" "$(cat "$EC_FS")"
fi

# ...and the relationship still owns what is its: the RECURSIVE target ladder is
# written by the caller, and the profile boundary refuses it, so there is exactly
# one `recursive = yes`. (REV-20260811-102 step 3 also emits one NON-recursive
# `recursive = no` per remote source dataset -- one here for rpool/data -- which is
# a separate scope and does not double the target ladder.)
if [ "$(grep -c 'recursive    = yes' "$EC_FS")" = 1 ] \
        && [ "$(grep -c 'recursive    = no' "$EC_FS")" = 1 ]; then
    ok "field survival: prune recursion is written once, by the relationship"
else
    bad "field survival: prune recursion is written once, by the relationship" "$(grep -n recursive "$EC_FS")"
fi

# REV-20260809-082 V1. The assertions above prove the field reaches the emitted
# TEXT. They do not prove the resulting candidate is a config the real consumer
# accepts -- and "it appears in the file" is exactly the kind of appearance this
# project keeps mistaking for the property.
#
# So the same discriminating profile is composed into a COMPLETE candidate --
# [defaults], its own rendered templates, and the emitted stanzas -- and run
# through the real gen-cron.sh. No new framework: same profile, same output,
# one more boundary.
FS_CAND="$FS/candidate.conf"
( . "$REPO/lib-profile.sh"
  profile_render_templates "$FS/p/prof" prof "$FS/tpl.conf" ) || true
{
    # No [defaults] dst: this client PULLS -- the emitted section carries src --
    # and gen-cron refuses a section that resolves both.
    printf '[defaults]
	host_label = fstest

'
    cat "$FS/tpl.conf"
    printf '\n'
    cat "$EC_FS"
} > "$FS_CAND"
gen_rc=0
gen_out="$(bash "$REPO/gen-cron.sh" -c "$FS_CAND" 2>&1)" || gen_rc=$?
if [ "$gen_rc" -eq 0 ]; then
    ok "field survival: the complete candidate is accepted by the REAL gen-cron.sh"
else
    bad "field survival: the complete candidate is accepted by the REAL gen-cron.sh" "rc=$gen_rc $(printf '%s' "$gen_out" | tail -3)"
fi

# And the extra field must have MEANT something, not merely parsed. recursive =
# flat is the -R spelling in the generated transfer line; without it the line
# carries no recursion flag at all.
if printf '%s
' "$gen_out" | grep -qE 'snap(send|get)\.sh.* -R '; then
    ok "field survival: the profile's recursive=flat reaches the rendered cron line"
else
    bad "field survival: the profile's recursive=flat reaches the rendered cron line" "$(printf '%s' "$gen_out" | grep -E 'snap(send|get)' | head -2)"
fi


# --- 45. coverage overlap: one fail-closed preflight (REV-20260809-083) ------
#
# Exact-path collisions were already refused by relationship ownership. Overlap
# that is NOT an exact match was not: A owning rpool/data and B later taking
# rpool/data/vm-101 produce different section headers, so no marker check fires,
# and both then send and prune the same snapshots under different policy.
#
# The guard reads other clients' records, so these cases substitute CLIENTS_DIR.
# Without that substitution the guard silently does nothing here -- /etc/... does
# not exist on this machine -- which is why the reachability case below exists at
# all: a suite that cannot reach the guard would pass whether it worked or not.
OV="$WORK/overlap"; mkdir -p "$OV/clients"
cat > "$OV/clients/peerA.conf" <<'EOF'
CLIENT_NAME=peerA
STATE=active
MANAGED_DATASETS="tank/backups/peerA/rpool/data"
MANAGED_PRUNE_SCOPE="tank/backups/peerA"
EOF

ov_emit() {   # <client name> <datasets> -> rc, output on stdout
    # NOT one `local` statement: bash expands every word BEFORE performing any
    # of the assignments, so `wf="$OV/$nm.conf"` would see nm unset.
    local nm="$1" dss="$2"
    local wf="$OV/$nm.conf"
    : > "$wf"
    ( CLIENTS_DIR="$OV/clients" PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" \
      LOAD_LABEL="$nm" LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.2.2.2 LOAD_FLAGS="-K /dev/null" \
      PEER_SAVED_DATASETS="$dss" PROFILE_GFS=1
      emit_client_sections "$wf" "$nm" ) 2>&1
}

# 1. parent already owned, child requested.
#
# MEASURED WHILE WRITING THIS, and it corrects the review's example: in BACKUP
# mode each relationship lands under its own label directory
# (tank/backups/<label>/...), so two backup clients cannot collide by taking a
# parent and a child of the same source -- their target paths differ at the
# label. The hazard is real in SYNC mode, where client_local_path returns the
# BARE source path with no label to separate them. So this case is written in
# sync mode, which is where the failure actually lives.
cat > "$OV/clients/syncA.conf" <<'EOF'
CLIENT_NAME=syncA
STATE=active
MANAGED_DATASETS="rpool/data"
MANAGED_PRUNE_SCOPE="rpool/data"
EOF
outB="$OV/syncB.conf"; : > "$outB"
out=$( ( CLIENTS_DIR="$OV/clients" PEER_SAVED_MODE=sync PEER_SAVED_TARGET=""          LOAD_LABEL=syncB LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.3.3.3 LOAD_FLAGS="-K /dev/null"          PEER_SAVED_DATASETS="rpool/data/vm-101" PROFILE_GFS=1
         emit_client_sections "$outB" syncB ) 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *syncA*) true ;; *) false ;; esac; then
    ok "overlap (sync): a child of an owned path is refused, naming the other relationship"
else
    bad "overlap (sync): a child of an owned path is refused, naming the other relationship" "rc=$rc out=$out"
fi
rm -f "$OV/clients/syncA.conf"

# 2. child already owned, parent requested -- the other direction
cat > "$OV/clients/peerC.conf" <<'EOF'
CLIENT_NAME=peerC
STATE=active
MANAGED_DATASETS="tank/backups/peerC/rpool/data/vm-9"
MANAGED_PRUNE_SCOPE=""
EOF
out=$(ov_emit peerC2 "rpool/data"); rc=$?
# peerC2's own path is tank/backups/peerC2/rpool/data, which does NOT contain
# peerC's -- so build the colliding case explicitly instead of pretending.
cat > "$OV/clients/peerD.conf" <<'EOF'
CLIENT_NAME=peerD
STATE=active
MANAGED_DATASETS="tank/backups/peerE/rpool/data/vm-9"
MANAGED_PRUNE_SCOPE=""
EOF
out=$(ov_emit peerE "rpool/data"); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *peerD*) true ;; *) false ;; esac; then
    ok "overlap: a parent of an owned path is refused too (both directions)"
else
    bad "overlap: a parent of an owned path is refused too (both directions)" "rc=$rc out=$out"
fi

# 3. disjoint is still allowed -- the guard must not refuse ordinary additive work
rm -f "$OV/clients/peerD.conf" "$OV/clients/peerC.conf"
out=$(ov_emit peerF "rpool/lxc"); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "overlap: a disjoint source is still appendable"
else
    bad "overlap: a disjoint source is still appendable" "rc=$rc out=$out"
fi

# 4. exact-path collision still refuses.
#
# I first wrote "it always did; kept as regression" and the negative control
# disproved it: this case FAILS against the pre-guard build. The old marker
# mechanism protects sections ALREADY PRESENT in the config being edited, and
# this fixture starts from an empty working config -- so what refuses here is
# the new preflight, reading another relationship's record. Both mechanisms are
# wanted; they cover different moments.
out=$(ov_emit peerG "rpool/data"); rc=$?
cat > "$OV/clients/peerH.conf" <<'EOF'
CLIENT_NAME=peerH
STATE=active
MANAGED_DATASETS="tank/backups/peerI/rpool/data"
MANAGED_PRUNE_SCOPE=""
EOF
out=$(ov_emit peerI "rpool/data"); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "overlap: an exact-path collision is still refused"
else
    bad "overlap: an exact-path collision is still refused" "rc=$rc out=$out"
fi

# 5. the refusal happens BEFORE any mutation: the working config stays empty.
if [ ! -s "$OV/peerI.conf" ]; then
    ok "overlap: the refusal leaves the working config untouched"
else
    bad "overlap: the refusal leaves the working config untouched" "$(cat "$OV/peerI.conf")"
fi

# 6. a removed relationship owns nothing -- otherwise a torn-down pair would
#    block its own replacement forever.
cat > "$OV/clients/peerJ.conf" <<'EOF'
CLIENT_NAME=peerJ
STATE=removed
MANAGED_DATASETS="tank/backups/peerK/rpool/zzz"
MANAGED_PRUNE_SCOPE=""
EOF
out=$(ov_emit peerK "rpool/zzz"); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "overlap: a removed relationship no longer reserves its coverage"
else
    bad "overlap: a removed relationship no longer reserves its coverage" "rc=$rc out=$out"
fi


# --- 46. coverage overlap: an unreadable/unparseable record refuses, it does
#         not silently vanish (REV-20260809-084) ----------------------------
#
# coverage_conflicts() used to do `. "$f" 2>/dev/null || exit 0` per record: a
# damaged record read as "no conflict" and assert_no_coverage_overlap's own
# fail-closed diagnostic ("could not check ... refusing rather than guessing")
# was therefore unreachable for exactly the failure it names. A record that
# cannot be read is not proof it is irrelevant -- it might own the requested
# path, so the guard must refuse rather than guess.
cat > "$OV/clients/peerL.conf" <<'EOF'
CLIENT_NAME=peerL
STATE=active
MANAGED_DATASETS="rpool/unrelated
EOF
# ^ deliberately unterminated quote: `.` fails to parse this file. The naming
# of an "unrelated" path is the point -- the guard cannot know that, because it
# cannot read the record at all, so it must refuse regardless of what the
# broken record would have said if it had parsed.
out=$(ov_emit peerM "rpool/disjoint-from-everything"); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *peerL*) true ;; *) false ;; esac; then
    ok "overlap: an unparseable existing record refuses rather than being skipped"
else
    bad "overlap: an unparseable existing record refuses rather than being skipped" "rc=$rc out=$out"
fi
if [ ! -s "$OV/peerM.conf" ]; then
    ok "overlap: the unparseable-record refusal also leaves the working config untouched"
else
    bad "overlap: the unparseable-record refusal also leaves the working config untouched" "$(cat "$OV/peerM.conf")"
fi

# A record with STATE=active but no CLIENT_NAME at all parses cleanly yet
# names no relationship -- it could own anything, so it must refuse too, not
# just records that fail to source.
rm -f "$OV/clients/peerL.conf"
cat > "$OV/clients/peerN.conf" <<'EOF'
STATE=active
MANAGED_DATASETS="rpool/also-unrelated"
EOF
out=$(ov_emit peerO "rpool/disjoint-again"); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *peerN*) true ;; *) false ;; esac; then
    ok "overlap: a nameless record refuses rather than being skipped"
else
    bad "overlap: a nameless record refuses rather than being skipped" "rc=$rc out=$out"
fi
rm -f "$OV/clients/peerN.conf"

# --- 47. seed-time overlap guard: refuse BEFORE the real transfer, not just
#         at activate-client time (REV-20260809-085) -------------------------
#
# coverage_conflicts()/assert_no_coverage_overlap() only ran inside
# emit_client_sections(), reached at activate-client time. But the backup-mode
# namespace is peer_label(PEER_HOST) (LOAD_LABEL in load_client_and_
# connection), NOT the client's own name -- so two DIFFERENTLY NAMED clients
# pairing with the SAME peer land in the SAME namespace, and cmd_seed() could
# perform a REAL, non-dry-run snapget.sh receive into another relationship's
# coverage before that guard ever ran. This section drives the real cmd_seed()
# with a recording SNAPGET stub: a refused case must show ZERO invocations of
# it, proving no real transfer was attempted, not merely that it "would have
# failed anyway".
SD="$WORK/seedoverlap"; mkdir -p "$SD/clients" "$SD/peerstate" "$SD/keys"
printf '10.9.9.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' \
    > "$SD/keys/10.9.9.9_known_hosts"

SD_RECORDER="$SD/recorder.log"
SD_SNAPGET="$SD/snapget_recorder.sh"
cat > "$SD_SNAPGET" <<EOF
#!/bin/bash
echo "\$@" >> "$SD_RECORDER"
exit 0
EOF
chmod +x "$SD_SNAPGET"

# alpha: already-active relationship owning rpool/data under peer 10.9.9.9's
# namespace -- the coverage a second, differently-named relationship must not
# be allowed to write into.
cat > "$SD/clients/alpha.conf" <<'EOF'
CLIENT_NAME=alpha
PEER_HOST=10.9.9.9
STATE=active
MANAGED_DATASETS="tank/backups/10.9.9.9/rpool/data"
MANAGED_PRUNE_SCOPE="tank/backups/10.9.9.9"
EOF

sd_seed() {   # <candidate client name> <peer datasets string> -> rc, output on stdout
    local nm="$1" dss="$2"
    cat > "$SD/clients/$nm.conf" <<EOF2
CLIENT_NAME=$nm
PEER_HOST=10.9.9.9
STATE=pending_enroll
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.9.9.9
ENDPOINT_LAN_PORT=22
EOF2
    # PEER_SAVED_MODE is set purely so cmd_seed's own peer_mode check skips
    # its deploy.sh --draft-config refresh (the dataset list below is already
    # final) -- resolve_mode_datasets() itself is a no-op whenever
    # PEER_SAVED_DATASETS is already non-empty, mode or not.
    cat > "$SD/peerstate/10.9.9.9.conf" <<EOF2
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="$dss"
EOF2
    ( CLIENTS_DIR="$SD/clients" PEER_STATE_DIR="$SD/peerstate" PEER_KEY_DIR="$SD/keys" SNAPGET="$SD_SNAPGET" \
      cmd_seed "$nm" --yes ) 2>&1
}

# 1. parent already owned (rpool/data), child requested (rpool/data/vm-101).
rm -f "$SD_RECORDER"
out=$(sd_seed beta "rpool/data/vm-101"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$SD_RECORDER" ] && case "$out" in *alpha*) true ;; *) false ;; esac; then
    ok "seed overlap: child of an owned path refuses before any real transfer"
else
    bad "seed overlap: child of an owned path refuses before any real transfer" "rc=$rc out=$out recorder=$(cat "$SD_RECORDER" 2>/dev/null)"
fi

# 2. child already owned would be the mirror case; exercised instead as
#    parent-requested here (rpool, parent of alpha's rpool/data) -- both
#    directions of path_overlaps() are already pinned locally in section 45,
#    this section's job is proving the SEED-TIME wiring, not re-deriving the
#    directionality.
rm -f "$SD_RECORDER"
out=$(sd_seed gamma "rpool"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$SD_RECORDER" ] && case "$out" in *alpha*) true ;; *) false ;; esac; then
    ok "seed overlap: parent of an owned path refuses before any real transfer"
else
    bad "seed overlap: parent of an owned path refuses before any real transfer" "rc=$rc out=$out recorder=$(cat "$SD_RECORDER" 2>/dev/null)"
fi

# 3. exact-path overlap under a different client name.
rm -f "$SD_RECORDER"
out=$(sd_seed delta "rpool/data"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$SD_RECORDER" ] && case "$out" in *alpha*) true ;; *) false ;; esac; then
    ok "seed overlap: exact-path collision refuses before any real transfer"
else
    bad "seed overlap: exact-path collision refuses before any real transfer" "rc=$rc out=$out recorder=$(cat "$SD_RECORDER" 2>/dev/null)"
fi

# 4. disjoint coverage still reaches the real transfer path -- the guard must
#    not become a second reason ordinary seeds stop working.
#
# MEASURED WHILE WRITING THIS: a same-peer, same-target candidate is NOT a
# valid disjoint case here. A GFS client's real MANAGED_PRUNE_SCOPE is the
# WHOLE `target/label` subtree (line ~1170, `prune_scope="$PEER_SAVED_TARGET/
# $LOAD_LABEL"`, recursive) -- and coverage_conflicts() checks a candidate's
# requested paths against both MANAGED_DATASETS and MANAGED_PRUNE_SCOPE of
# every other active relationship. So once alpha exists, EVERY dataset under
# the SAME peer+target is covered by alpha's own prune scope, by design --
# that is one relationship per peer+target namespace under GFS, not a defect
# this section should paper over. A genuine disjoint case needs a DIFFERENT
# peer, landing in a different `target/label` subtree entirely.
printf '10.9.9.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' \
    > "$SD/keys/10.9.9.10_known_hosts"
sd_seed_other_peer() {   # <candidate client name> <peer datasets string>
    local nm="$1" dss="$2"
    cat > "$SD/clients/$nm.conf" <<EOF2
CLIENT_NAME=$nm
PEER_HOST=10.9.9.10
STATE=pending_enroll
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.9.9.10
ENDPOINT_LAN_PORT=22
EOF2
    cat > "$SD/peerstate/10.9.9.10.conf" <<EOF2
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="$dss"
EOF2
    ( CLIENTS_DIR="$SD/clients" PEER_STATE_DIR="$SD/peerstate" PEER_KEY_DIR="$SD/keys" SNAPGET="$SD_SNAPGET" \
      cmd_seed "$nm" --yes ) 2>&1
}
rm -f "$SD_RECORDER"
out=$(sd_seed_other_peer epsilon "rpool/other"); rc=$?
if [ "$rc" -eq 0 ] && [ -s "$SD_RECORDER" ] && case "$(cat "$SD_RECORDER")" in *rpool/other*) true ;; *) false ;; esac; then
    ok "seed overlap: a disjoint dataset (different peer) still reaches the real transfer"
else
    bad "seed overlap: a disjoint dataset (different peer) still reaches the real transfer" "rc=$rc out=$out recorder=$(cat "$SD_RECORDER" 2>/dev/null)"
fi


# --- 48. read_server_conf() clobbers a client's own recorded CRON_CONFIG,
#         found live during the REV-082/083/085 campaign -------------------
#
# read_server_conf() unconditionally does CRON_CONFIG="" and only refills it
# by sourcing $SERVER_CONF -- on a host with no server.conf (setup-server
# never run with an explicit --config, exactly metropolis pve1's shape),
# that reset is never undone. Both cmd_remove_client and cmd_activate_client
# source the client's OWN record first (which carries CRON_CONFIG from the
# client's own prior activation) and call read_server_conf AFTER -- so the
# recorded value was silently replaced with an empty string every time,
# regardless of what the client actually has installed.
#
# The EXISTING remove-client test (section 23) never caught this: its fixture
# gives server.conf and the client record the SAME CRON_CONFIG value, so
# clobbering it with an identical value is invisible. This section uses a
# server.conf that does not exist at all, and a client CRON_CONFIG that
# differs from any recomputed default -- the shape that actually broke live.
RSC="$WORK/readserverconf"; mkdir -p "$RSC/bin" "$RSC/clients"
cat > "$RSC/bin/crontab" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$RSC/calls"
echo "# BEGIN zfs-backup-managed"
echo "# Source: $RSC/jobs.recorded.conf -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
echo "1 * * * * x"
echo "# END zfs-backup-managed"
exit 0
EOF
chmod +x "$RSC/bin/crontab"
: > "$RSC/jobs.recorded.conf"
printf 'STATE=active\nMANAGED_DATASETS="tank/a"\nCRON_CONFIG=%s/jobs.recorded.conf\n' "$RSC" > "$RSC/clients/rc1.conf"

# No SERVER_CONF at all -- points at a path that does not exist, matching a
# host that never ran setup-server with an explicit --config.
out=$( PATH="$RSC/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RSC/no-such-server.conf'; CLIENTS_DIR='$RSC/clients'
    cmd_remove_client rc1" 2>&1 ); rc=$?
if case "$out" in *"no managed dataset list on file"*) false ;; *) true ;; esac; then
    ok "remove-client: with no server.conf, the client's own recorded CRON_CONFIG survives read_server_conf"
else
    bad "remove-client: with no server.conf, the client's own recorded CRON_CONFIG survives read_server_conf" "rc=$rc out=$out"
fi
# The recorded file must be the one actually consulted -- proven by the
# crontab stub being asked at all (any 'no managed dataset' skip means
# remove-client never got far enough to call crontab -l in the first place).
if [ -s "$RSC/calls" ]; then
    ok "remove-client: cron cleanup actually engaged the recorded CRON_CONFIG, not a skipped no-op"
else
    bad "remove-client: cron cleanup actually engaged the recorded CRON_CONFIG, not a skipped no-op" "no crontab calls recorded; out=$out"
fi

# Same defect, same fix shape, in cmd_activate_client's RE-activation path:
# a client already STATE=active has its OWN CRON_CONFIG on record from its
# FIRST activation. Re-activating (e.g. after set-endpoint) must keep writing
# to that SAME file, not silently recompute a fresh default and orphan the
# actually-installed one. Driven far enough to name the file it is about to
# validate -- it need not succeed end to end (that needs a real peer/dry-run,
# covered live) to prove WHICH path it chose.
AC="$WORK/activateclient"; mkdir -p "$AC/clients" "$AC/peerstate" "$AC/keys" "$AC/recorded-dir"
printf '10.7.7.7 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' \
    > "$AC/keys/10.7.7.7_known_hosts"
cat > "$AC/peerstate/10.7.7.7.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF
cat > "$AC/clients/reactivate.conf" <<EOF
CLIENT_NAME=reactivate
PEER_HOST=10.7.7.7
STATE=active
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.7.7.7
ENDPOINT_LAN_PORT=22
MANAGED_DATASETS=tank/backups/10.7.7.7/rpool/data
CRON_CONFIG=$AC/recorded-dir/jobs.recorded.conf
EOF
: > "$AC/recorded-dir/jobs.recorded.conf"
out=$( CLIENTS_DIR="$AC/clients" PEER_STATE_DIR="$AC/peerstate" PEER_KEY_DIR="$AC/keys" \
       SERVER_CONF="$AC/no-such-server.conf" SNAPGET=/bin/false \
       cmd_activate_client reactivate --yes 2>&1 ); rc=$?
if case "$out" in *"$AC/recorded-dir/jobs.recorded.conf"*) true ;; *) false ;; esac; then
    ok "activate-client: re-activation keeps writing to the recorded CRON_CONFIG, not a recomputed default"
else
    bad "activate-client: re-activation keeps writing to the recorded CRON_CONFIG, not a recomputed default" "rc=$rc out=$out"
fi
# And it must not have silently fallen back to the SCRIPT_DIR default path.
if case "$out" in *"$SCRIPT_DIR/jobs."*".conf"*) false ;; *) true ;; esac; then
    ok "activate-client: re-activation does not target the SCRIPT_DIR default path instead"
else
    bad "activate-client: re-activation does not target the SCRIPT_DIR default path instead" "out=$out"
fi

# --- 49. PHASE 3 / REV-20260809-089: reactivation preserves installed policy --
#
# emit_client_sections() used to remove-and-regenerate EVERY section on EVERY
# call, from whatever the active profile renders at that moment. Correct exactly
# once, at CREATE. On every later re-activation it silently discarded operator
# customization and re-derived installed policy from a profile that may have
# changed since -- breaking the one-way handoff
# (PROFILE -> generate once -> CONFIG v4 -> runtime truth), the same boundary
# REV-20260809-088 F1 drew one level up in ensure_cron_config.
#
# The nine steps below are the reviewer's required discriminating proof.
P9="$WORK/phase3"; mkdir -p "$P9/prof"
cp "$REPO/profiles/default/templates.conf" "$P9/prof/templates.conf"
cp "$REPO/profiles/default/prune.inc"      "$P9/prof/prune.inc"
cp "$REPO/profiles/default/dataset.inc"    "$P9/prof/dataset.inc"

emit9() {   # <conf> <name> <host> <is_new> [mode] [datasets]
    # MANAGED_DATASETS/MANAGED_PRUNE_SCOPE deliberately EMPTY: ownership must be
    # proven by the marker this function itself wrote, which is the harder half
    # of remove_managed_sections' own test and the one a fresh record relies on.
    ( PROFILE_ROOT="$P9" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      PEER_SAVED_MODE="${5:-backup}" PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=pve9 \
      LOAD_ACCOUNT=zfsbackup LOAD_HOST="$3" LOAD_FLAGS="-K /dev/null" \
      PEER_SAVED_DATASETS="${6:-rpool/data}" PROFILE_GFS=1 \
      MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
      emit_client_sections "$1" "$2" "$4" ) 2>&1
}

# --- backup mode: one [dataset:] + one recursive GFS ladder ---
C9="$P9/backup.conf"; DS9="tank/backups/pve9/rpool/data"; PR9="tank/backups/pve9"
: > "$C9"

# STEP 1 -- first activation creates the normal managed sections.
out=$(emit9 "$C9" c9 10.9.9.1 1); rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "[dataset:$DS9]" "$C9" && grep -qxF "[prune:$PR9]" "$C9" \
        && grep -q "src *= *zfsbackup@10.9.9.1:rpool/data" "$C9"; then
    ok "89 step 1: first activation creates the managed [dataset:] and GFS [prune:]"
else
    bad "89 step 1: first activation creates the managed [dataset:] and GFS [prune:]" "rc=$rc out=$out file=$(cat "$C9")"
fi

# STEP 2 -- customize the installed policy by hand, both section kinds.
# `recursive` is explicitly profile-owned (REV-073), so pinning it per
# relationship is a legitimate operator edit, not an abuse of the format.
sed -i "/^\[dataset:$(printf '%s' "$DS9" | sed 's,/,\\/,g')\]/,/^\[prune:/ s/^\tsrc /\trecursive    = flat\n\tsrc /" "$C9"
# Customize the TARGET prune's pattern only. The REMOTE source prune
# (REV-20260811-102 step 3) is deliberately REGENERATED on every re-activation --
# its scope embeds the endpoint, so it is topology-derived like `src` and is NOT
# preservation-safe by design -- so a hand-edit to it would (correctly) be
# discarded on the endpoint switch below and must not be part of this preservation
# assertion. Scope the sed to the target ladder's own section.
sed -i "/^\[prune:$(printf '%s' "$PR9" | sed 's,/,\\/,g')\]/,/^\[/ s/^\tgfs_pattern *=.*/\tgfs_pattern  = automated_custom_/" "$C9"
before_recursive=$(grep -c 'recursive    = flat' "$C9")
before_pattern=$(grep -c 'gfs_pattern  = automated_custom_' "$C9")

# STEP 3 -- a real endpoint change, then a real re-activation.
out=$(emit9 "$C9" c9 10.9.9.2 0); rc=$?

# STEP 4 -- the endpoint-owned field DID change.
if [ "$rc" -eq 0 ] && grep -q "src *= *zfsbackup@10.9.9.2:rpool/data" "$C9" \
        && ! grep -q "10.9.9.1" "$C9"; then
    ok "89 step 4: re-activation refreshes src to the new endpoint"
else
    bad "89 step 4: re-activation refreshes src to the new endpoint" "rc=$rc out=$out file=$(cat "$C9")"
fi

# STEP 5 -- the customized/policy fields did NOT.
if [ "$(grep -c 'recursive    = flat' "$C9")" = "$before_recursive" ] \
        && [ "$before_recursive" -ge 1 ] \
        && [ "$(grep -c 'gfs_pattern  = automated_custom_' "$C9")" = "$before_pattern" ] \
        && [ "$before_pattern" -ge 1 ]; then
    ok "89 step 5: re-activation preserves the hand-customized dataset and prune policy"
else
    bad "89 step 5: re-activation preserves the hand-customized dataset and prune policy" \
        "recursive before=$before_recursive after=$(grep -c 'recursive    = flat' "$C9") pattern before=$before_pattern after=$(grep -c 'gfs_pattern  = automated_custom_' "$C9") file=$(cat "$C9")"
fi

# The section must not have grown a second copy of itself either.
if [ "$(grep -cxF "[dataset:$DS9]" "$C9")" = 1 ] && [ "$(grep -cxF "[prune:$PR9]" "$C9")" = 1 ]; then
    ok "89 step 5b: preserving a section does not append a duplicate of it"
else
    bad "89 step 5b: preserving a section does not append a duplicate of it" "$(cat "$C9")"
fi

# STEP 6 -- edit the ACTIVE PROFILE between activations. An installed
# relationship must be independent of it: this is the one-way handoff itself.
# The drift is expressed in VALID profile fields on purpose: an invalid one
# would be refused at the profile boundary and would prove nothing about the
# handoff.
printf 'recursive = yes\n' >> "$P9/prof/dataset.inc"
sed -i 's/^gfs_pattern *=.*/gfs_pattern = automated_PROFILEDRIFT_/' "$P9/prof/prune.inc"
out=$(emit9 "$C9" c9 10.9.9.3 0); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "PROFILEDRIFT" "$C9" \
        && grep -q 'recursive    = flat' "$C9" \
        && grep -q 'gfs_pattern  = automated_custom_' "$C9" \
        && grep -q "src *= *zfsbackup@10.9.9.3:rpool/data" "$C9"; then
    ok "89 step 6: a profile edited after CREATE does not reach an installed relationship"
else
    bad "89 step 6: a profile edited after CREATE does not reach an installed relationship" "rc=$rc out=$out file=$(cat "$C9")"
fi

# ...and the preserved-plus-refreshed result is still a config the REAL consumer
# accepts, with the new endpoint actually reaching the rendered line. "The text
# looks right" is the appearance this project keeps mistaking for the property
# (REV-20260809-082 V1), so the boundary is crossed here too.
P9_CAND="$P9/candidate.conf"
( . "$REPO/lib-profile.sh"; profile_render_templates "$P9/prof" prof "$P9/tpl.conf" ) || true
{ printf '[defaults]\n\thost_label = p9test\n\n'; cat "$P9/tpl.conf"; printf '\n'; cat "$C9"; } > "$P9_CAND"
gen_rc=0; gen_out="$(bash "$REPO/gen-cron.sh" -c "$P9_CAND" 2>&1)" || gen_rc=$?
if [ "$gen_rc" -eq 0 ] && printf '%s\n' "$gen_out" | grep -q 'zfsbackup@10.9.9.3'; then
    ok "89 step 6b: the preserved+refreshed config is accepted by the REAL gen-cron.sh, carrying the new endpoint"
else
    bad "89 step 6b: the preserved+refreshed config is accepted by the REAL gen-cron.sh, carrying the new endpoint" "rc=$gen_rc $(printf '%s' "$gen_out" | tail -5)"
fi

# STEP 7 -- sync mode's OTHER prune shape: one [prune:] per dataset, at the
# same path as the [dataset:] section, which is why both halves must be owned
# before either is preserved.
S9="$P9/sync.conf"; : > "$S9"
out=$(emit9 "$S9" s9 10.9.9.1 1 sync "rpool/a rpool/b"); rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "[prune:rpool/a]" "$S9" && grep -qxF "[prune:rpool/b]" "$S9" \
        && grep -qxF "[dataset:rpool/a]" "$S9"; then
    ok "89 step 7: sync mode first activation writes one [prune:] per dataset"
else
    bad "89 step 7: sync mode first activation writes one [prune:] per dataset" "rc=$rc out=$out file=$(cat "$S9")"
fi
sed -i 's/^\tgfs_pattern *=.*/\tgfs_pattern  = sync_custom_/' "$S9"
out=$(emit9 "$S9" s9 10.9.9.4 0 sync "rpool/a rpool/b"); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'gfs_pattern  = sync_custom_' "$S9")" -ge 2 ] \
        && grep -q "src *= *zfsbackup@10.9.9.4:rpool/a" "$S9" \
        && grep -q "src *= *zfsbackup@10.9.9.4:rpool/b" "$S9" \
        && [ "$(grep -cxF "[prune:rpool/a]" "$S9")" = 1 ]; then
    ok "89 step 7b: sync mode re-activation refreshes every src and preserves every prune policy"
else
    bad "89 step 7b: sync mode re-activation refreshes every src and preserves every prune policy" "rc=$rc out=$out file=$(cat "$S9")"
fi

# First activation is UNAFFECTED -- still full generation. This is not a
# leftover: migrate-profile passes 1 deliberately, because re-deriving policy
# from the profile is that command's entire purpose.
out=$(emit9 "$C9" c9 10.9.9.5 1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "gfs_pattern *= *automated_PROFILEDRIFT_" "$C9" \
        && ! grep -q 'gfs_pattern  = automated_custom_' "$C9"; then
    ok "89 first-activation/migrate path still regenerates from the profile"
else
    bad "89 first-activation/migrate path still regenerates from the profile" "rc=$rc out=$out file=$(cat "$C9")"
fi

# Fail-closed is preserved: a section at a path this client manages that it
# does NOT own is still refused, never silently adopted by header alone.
F9="$P9/foreign.conf"
printf '\n[dataset:%s]\n\tuse_template = something_else\n\tsrc          = a@b:c\n' "$DS9" > "$F9"
out=$(emit9 "$F9" c9 10.9.9.1 0); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"looks hand-written"*) true ;; *) false ;; esac; then
    ok "89 a foreign section at a managed path is still refused, not adopted"
else
    bad "89 a foreign section at a managed path is still refused, not adopted" "rc=$rc out=$out"
fi

# An owned section with no src field cannot be refreshed -- refusing beats
# leaving the relationship silently pointing at the old endpoint.
N9="$P9/nosrc.conf"
printf '\n[dataset:%s]\n\t# managed-by: zfs-backup.sh client=c9\n\tuse_template = x\n\tflags        = -K /dev/null\n' "$DS9" > "$N9"
out=$(emit9 "$N9" c9 10.9.9.1 0); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"no 'src' field to refresh"*) true ;; *) false ;; esac; then
    ok "89 an owned section with no src refuses rather than silently keeping the old endpoint"
else
    bad "89 an owned section with no src refuses rather than silently keeping the old endpoint" "rc=$rc out=$out"
fi

# --- 50. REV-20260810-090: reactivation is independent of the profile ---------
#
# REV-089 stopped the relationship-local section body from being regenerated,
# but `cmd_activate_client()` still called `ensure_cron_config`, which still
# called `load_active_profile` unconditionally and still appended any profile
# template the installed CONFIG did not carry. So the one-way handoff still had
# two holes: an already-installed relationship could not be reactivated at all
# once its CREATE-time profile was gone or invalid (F1), and ordinary endpoint
# maintenance could silently re-introduce policy material (F2).
#
# Section 49 drove emit_client_sections() directly and kept the profile
# directory present and valid, so it could not have caught either. These cross
# the REAL cmd_activate_client()/ensure_cron_config() boundary.
AP="$WORK/profilegone"
mkdir -p "$AP/clients" "$AP/peerstate" "$AP/keys" "$AP/dir" "$AP/root/prof" "$AP/cap"
cp "$REPO/profiles/default/prune.inc"   "$AP/root/prof/prune.inc"
cp "$REPO/profiles/default/dataset.inc" "$AP/root/prof/dataset.inc"
# An extra template nothing references: the "otherwise-unused generated template
# the operator removed" of the review's proof step 4. A referenced one could not
# tell F2 apart from gen-cron simply rejecting a dangling use_template.
{ cat "$REPO/profiles/default/templates.conf"
  printf '\n[template:extra_unused]\n\tsend_schedule = 0 5 * * *\n\tprefix        = automated_extra_\n'
} > "$AP/root/prof/templates.conf"

for h in 10.7.7.8 10.7.7.9; do
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VmYWtlZmFrZWZha2VmYWtlZmFrZWZha2VmYWtl\n' "$h" \
        > "$AP/keys/${h}_known_hosts"
done
cat > "$AP/peerstate/10.7.7.8.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF

# The installed CONFIG is built by the REAL generators at their REAL first-CREATE
# setting, so the fixture is what a first activation actually leaves behind
# rather than a hand-written approximation of it.
APC="$AP/dir/jobs.conf"
printf '[defaults]\n\thost_label = aptest\n' > "$APC"
( PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
  PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=10.7.7.8 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.8 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data" MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
  ensure_cron_config "$APC" 1 1 >/dev/null 2>&1
  PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
  PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=10.7.7.8 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.8 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
  emit_client_sections "$APC" apx 1 ) >/dev/null 2>&1
# A per-relationship customization an operator might reasonably make.
sed -i '/^\tsrc          = zfsbackup@10.7.7.8/i\\trecursive    = flat' "$APC"

cat > "$AP/clients/apx.conf" <<EOF
CLIENT_NAME=apx
PEER_HOST=10.7.7.8
STATE=active
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.7.7.9
ENDPOINT_LAN_PORT=22
MANAGED_DATASETS=tank/backups/10.7.7.8/rpool/data
MANAGED_PRUNE_SCOPE=tank/backups/10.7.7.8
CRON_CONFIG=$APC
EOF

# The working copy never survives the run (it is removed on any failure and
# swapped away on success), so the dry-run stub copies it out at the one moment
# it is guaranteed to exist -- the same $SNAPGET-substitution pattern sections
# 38/39 already use to observe an interior step.
cat > "$AP/snapget-capture.sh" <<EOF
#!/usr/bin/env bash
cp -f "$AP/dir"/.zfsbackup-work.* "$AP/cap/workfile" 2>/dev/null
exit 0
EOF
chmod +x "$AP/snapget-capture.sh"

run_ap() {   # <profile-root> -> output; leaves the captured workfile in $AP/cap
    # Clear stale working copies first. cmd_activate_client removes its own on
    # every path it controls, but a die raised INSIDE ensure_cron_config (the
    # "first activation with no profile" case below) exits before that cleanup,
    # leaving one behind -- and then the capture stub's `cp` would have two
    # sources and one non-directory destination, which fails silently and makes
    # the next assertion look like a code defect.
    rm -f "$AP/cap/workfile" "$AP/dir"/.zfsbackup-work.*
    ( CLIENTS_DIR="$AP/clients" PEER_STATE_DIR="$AP/peerstate" PEER_KEY_DIR="$AP/keys" \
      SERVER_CONF="$AP/no-such-server.conf" SNAPGET="$AP/snapget-capture.sh" \
      PROFILE_ROOT="$1" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      cmd_activate_client apx --yes ) 2>&1
}

# --- F1: the CREATE-time profile is gone. Reactivation must still work. ---
mv "$AP/root/prof" "$AP/root/prof.gone"
out=$(run_ap "$AP/root")
if [ -f "$AP/cap/workfile" ] && case "$out" in *"profile 'prof'"*) false ;; *) true ;; esac; then
    ok "90 F1: reactivation gets past profile handling when the CREATE-time profile is gone"
else
    bad "90 F1: reactivation gets past profile handling when the CREATE-time profile is gone" \
        "captured=$([ -f "$AP/cap/workfile" ] && echo yes || echo NO) out=$(printf '%s' "$out" | tail -5)"
fi
# ...and it did the topology work while doing it.
if [ -f "$AP/cap/workfile" ] \
        && grep -q "src *= *zfsbackup@10.7.7.9:rpool/data" "$AP/cap/workfile" \
        && grep -q 'recursive    = flat' "$AP/cap/workfile" \
        && grep -q 'gfs_pattern' "$AP/cap/workfile"; then
    ok "90 F1: with no profile at all it still refreshes src and preserves installed policy"
else
    bad "90 F1: with no profile at all it still refreshes src and preserves installed policy" \
        "$([ -f "$AP/cap/workfile" ] && cat "$AP/cap/workfile" || echo '(no workfile captured)')"
fi
mv "$AP/root/prof.gone" "$AP/root/prof"

# A profile that is PRESENT but no longer valid is the same class of dependency
# -- an installed CONFIG must not stop being reactivatable because a file it no
# longer needs stopped parsing.
printf 'src = zfsbackup@nope:x\n' >> "$AP/root/prof/dataset.inc"
out=$(run_ap "$AP/root")
if [ -f "$AP/cap/workfile" ] && case "$out" in *"profile 'prof'"*) false ;; *) true ;; esac; then
    ok "90 F1: reactivation is unaffected by the CREATE-time profile becoming invalid"
else
    bad "90 F1: reactivation is unaffected by the CREATE-time profile becoming invalid" \
        "captured=$([ -f "$AP/cap/workfile" ] && echo yes || echo NO) out=$(printf '%s' "$out" | tail -5)"
fi
sed -i '/^src = zfsbackup@nope:x$/d' "$AP/root/prof/dataset.inc"

# --- F2: a removed, otherwise-unused generated template stays removed. ---
if grep -q "^\[template:profile__prof__extra_unused\]" "$APC"; then
    ok "90 F2 precondition: the unused namespaced template was installed at CREATE"
else
    bad "90 F2 precondition: the unused namespaced template was installed at CREATE" "$(grep -c '^\[template:' "$APC") template(s) in the fixture"
fi
awk '/^\[template:profile__prof__extra_unused\]/{skip=1;next} skip&&/^\[/{skip=0} !skip' "$APC" > "$APC.tmp" && mv "$APC.tmp" "$APC"
out=$(run_ap "$AP/root")
if [ -f "$AP/cap/workfile" ] \
        && ! grep -q "^\[template:profile__prof__extra_unused\]" "$AP/cap/workfile" \
        && case "$out" in *"added missing profile template"*) false ;; *) true ;; esac; then
    ok "90 F2: ordinary reactivation does not re-append a deliberately removed template"
else
    bad "90 F2: ordinary reactivation does not re-append a deliberately removed template" \
        "out=$(printf '%s' "$out" | grep -i template) workfile=$([ -f "$AP/cap/workfile" ] && grep -c '^\[template:' "$AP/cap/workfile" || echo none)"
fi

# The dependency is not removed, only moved to the boundary that genuinely needs
# it: a relationship that must GENERATE a section still loads the profile, and
# still fails clearly when it cannot. Otherwise F1's fix would have turned a
# loud failure into a silently policy-less CREATE.
cat > "$AP/clients/apnew.conf" <<EOF
CLIENT_NAME=apnew
PEER_HOST=10.7.7.8
STATE=endpoint_verified
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.7.7.9
ENDPOINT_LAN_PORT=22
CRON_CONFIG=$APC
EOF
mv "$AP/root/prof" "$AP/root/prof.gone"
out=$( ( CLIENTS_DIR="$AP/clients" PEER_STATE_DIR="$AP/peerstate" PEER_KEY_DIR="$AP/keys" \
         SERVER_CONF="$AP/no-such-server.conf" SNAPGET="$AP/snapget-capture.sh" \
         PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         cmd_activate_client apnew --yes ) 2>&1 ); rc=$?
mv "$AP/root/prof.gone" "$AP/root/prof"
if [ "$rc" -ne 0 ] && case "$out" in *"profile 'prof'"*) true ;; *) false ;; esac; then
    ok "90 a first activation with no profile still fails loudly at the additive boundary"
else
    bad "90 a first activation with no profile still fails loudly at the additive boundary" "rc=$rc out=$(printf '%s' "$out" | tail -5)"
fi

# --- 51. REV-20260810-091: pure reactivation creates/repairs/migrates nothing --
#
# REV-090 stopped reactivation from loading the profile and appending its
# templates, but `ensure_cron_config()` still did two policy things
# unconditionally: it re-added the CONFIG-WIDE [excluded:] retention floors (F1),
# and it refused a pre-GFS installed CONFIG outright (F2). Neither is a topology
# fact, so `needs_profile=0` did not actually mean topology-only.
#
# Both are now gated on the same needs_profile the template loop uses. The rule
# is one sentence: pure topology reactivation does not create, repair, normalize
# or migrate policy.

# --- F1: a deliberately removed CONFIG-wide [excluded:] stays removed. ---
# Reuses section 50's fixture, which is already a valid active relationship
# built by the real generators. run_ap never installs, so $APC is still the
# installed CONFIG it was.
if grep -qF "[excluded:vzdump]" "$APC"; then
    ok "91 F1 precondition: the reserved-prefix floor was installed at CREATE"
else
    bad "91 F1 precondition: the reserved-prefix floor was installed at CREATE" "$(grep -c '^\[excluded:' "$APC") excluded section(s)"
fi
awk '/^\[excluded:vzdump\]/{skip=1;next} skip&&/^\[/{skip=0} !skip' "$APC" > "$APC.tmp" && mv "$APC.tmp" "$APC"
out=$(run_ap "$AP/root")
if [ -f "$AP/cap/workfile" ] \
        && ! grep -qF "[excluded:vzdump]" "$AP/cap/workfile" \
        && grep -q "src *= *zfsbackup@10.7.7.9:rpool/data" "$AP/cap/workfile" \
        && case "$out" in *"added missing reserved-prefix protection"*) false ;; *) true ;; esac; then
    ok "91 F1: endpoint-only reactivation does not re-add a removed [excluded:] floor"
else
    bad "91 F1: endpoint-only reactivation does not re-add a removed [excluded:] floor" \
        "captured=$([ -f "$AP/cap/workfile" ] && echo yes || echo NO) out=$(printf '%s' "$out" | tail -5)"
fi
# The floor is not abolished, only moved to the boundary that creates policy: a
# genuine first activation still installs it. Otherwise F1's fix would have
# quietly dropped a real safety default instead of relocating it.
printf '[defaults]\n\thost_label = fltest\n' > "$AP/dir/floor.conf"
( PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
  ensure_cron_config "$AP/dir/floor.conf" 1 1 ) >/dev/null 2>&1
if grep -qF "[excluded:vzdump]" "$AP/dir/floor.conf"; then
    ok "91 F1: a policy-creating call still installs the reserved-prefix floors"
else
    bad "91 F1: a policy-creating call still installs the reserved-prefix floors" "$(cat "$AP/dir/floor.conf")"
fi

# --- F2: a valid pre-GFS CONFIG is refreshed, not forced through migration. ---
PG="$WORK/pregfs"; mkdir -p "$PG/dir" "$PG/cap"
PGC="$PG/dir/jobs.conf"
cat > "$PGC" <<EOF
[defaults]
	host_label = pgtest

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	prune_schedule = 21 * * * *
	pattern        = automated_hourly_
	retain         = 24

[dataset:tank/backups/10.7.7.8/rpool/data]
	# managed-by: zfs-backup.sh client=apx
	use_template = standard_hourly
	src          = zfsbackup@10.7.7.8:rpool/data
	flags        = -K /dev/null
	pair_label   = apx
	notify       = apx-data
EOF
# The fixture must be a config the real consumer accepts, or "reactivation got
# further" would prove nothing about the pre-GFS path specifically.
if bash "$REPO/gen-cron.sh" -c "$PGC" >/dev/null 2>&1; then
    ok "91 F2 precondition: the legacy pre-GFS fixture is a config real gen-cron.sh accepts"
else
    bad "91 F2 precondition: the legacy pre-GFS fixture is a config real gen-cron.sh accepts" "$(bash "$REPO/gen-cron.sh" -c "$PGC" 2>&1 | tail -3)"
fi
# Its OWN clients dir: the section-50 relationship 'apx' already owns this exact
# path, and the coverage-overlap guard (REV-083/085) would refuse a second
# relationship claiming it -- correctly, and long before the pre-GFS path this
# case is about.
mkdir -p "$PG/clients"
cat > "$PG/clients/apleg.conf" <<EOF
CLIENT_NAME=apleg
PEER_HOST=10.7.7.8
STATE=active
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=10.7.7.9
ENDPOINT_LAN_PORT=22
MANAGED_DATASETS=tank/backups/10.7.7.8/rpool/data
CRON_CONFIG=$PGC
EOF
# That section's marker names client 'apx', not 'apleg' -- rename it, so this
# relationship genuinely OWNS what it is about to preserve rather than relying
# on the MANAGED_DATASETS fallback alone.
sed -i 's|# managed-by: zfs-backup.sh client=apx|# managed-by: zfs-backup.sh client=apleg|' "$PGC"
cat > "$PG/snapget-capture.sh" <<EOF
#!/usr/bin/env bash
cp -f "$PG/dir"/.zfsbackup-work.* "$PG/cap/workfile" 2>/dev/null
exit 0
EOF
chmod +x "$PG/snapget-capture.sh"
rm -f "$PG/cap/workfile" "$PG/dir"/.zfsbackup-work.*
out=$( ( CLIENTS_DIR="$PG/clients" PEER_STATE_DIR="$AP/peerstate" PEER_KEY_DIR="$AP/keys" \
         SERVER_CONF="$AP/no-such-server.conf" SNAPGET="$PG/snapget-capture.sh" \
         PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         cmd_activate_client apleg --yes ) 2>&1 )
if [ -f "$PG/cap/workfile" ] && case "$out" in *"pre-GFS profile"*) false ;; *) true ;; esac; then
    ok "91 F2: endpoint-only reactivation of a pre-GFS config is not refused"
else
    bad "91 F2: endpoint-only reactivation of a pre-GFS config is not refused" \
        "captured=$([ -f "$PG/cap/workfile" ] && echo yes || echo NO) out=$(printf '%s' "$out" | tail -5)"
fi
if [ -f "$PG/cap/workfile" ] \
        && grep -q "src *= *zfsbackup@10.7.7.9:rpool/data" "$PG/cap/workfile" \
        && grep -q "prune_schedule = 21 \* \* \* \*" "$PG/cap/workfile" \
        && ! grep -q "profile__" "$PG/cap/workfile"; then
    ok "91 F2: it refreshes src and leaves the legacy flat-retention policy untouched"
else
    bad "91 F2: it refreshes src and leaves the legacy flat-retention policy untouched" \
        "$([ -f "$PG/cap/workfile" ] && cat "$PG/cap/workfile" || echo '(no workfile captured)')"
fi
# The refusal is retained where the hazard is real: a pre-GFS config that must
# GENERATE a section would be given the GFS ladder on top of its own flat
# retention -- the double-prune race -- so that path must still refuse.
out=$( ( PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         ensure_cron_config "$PGC" 0 1 ) 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"pre-GFS profile"*) true ;; *) false ;; esac; then
    ok "91 F2: a policy-generating call on a pre-GFS config still refuses"
else
    bad "91 F2: a policy-generating call on a pre-GFS config still refuses" "rc=$rc out=$(printf '%s' "$out" | tail -3)"
fi

# --- 52. REV-20260810-092: additive CREATE must not mutate installed global policy
#
# [excluded:] is CONFIG-WIDE. gen-cron.sh resolves every one of them into a
# single PROTECT_FLAGS fragment and pastes it onto EVERY generated prune line in
# the file. So "append a missing reserved-prefix floor" is only additive while
# nothing else is installed; into a populated CONFIG it silently rewrites the
# effective prune command of relationships that were already there -- breaking
# Gate 2's own invariant, "add one new independent relationship -> old
# relationships unchanged".
#
# Section 51's positive guard proved a policy-creating call on a FRESH fixture
# installs the floors. That cannot tell initial-config scaffolding apart from
# forbidden shared-policy mutation, because it had no established task to
# disturb. This section adds one.
GX="$WORK/gate2additive"; mkdir -p "$GX/prof"
cp "$REPO/profiles/default/templates.conf" "$GX/prof/templates.conf"
cp "$REPO/profiles/default/prune.inc"      "$GX/prof/prune.inc"
cp "$REPO/profiles/default/dataset.inc"    "$GX/prof/dataset.inc"
GXC="$GX/shared.conf"

emit_gx() {   # <client> <label> <host> -- a normal first activation into $GXC
    ( PROFILE_ROOT="$GX" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL="$2" \
      LOAD_ACCOUNT=zfsbackup LOAD_HOST="$3" LOAD_FLAGS="-K /dev/null" \
      PEER_SAVED_DATASETS="rpool/data" MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
      ensure_cron_config "$GXC" 1 1
      PROFILE_ROOT="$GX" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL="$2" \
      LOAD_ACCOUNT=zfsbackup LOAD_HOST="$3" LOAD_FLAGS="-K /dev/null" \
      PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
      emit_client_sections "$GXC" "$1" 1 ) 2>&1
}
gx_prune_line() {   # <label> -> A's rendered delsnaps line, from the REAL generator
    bash "$REPO/gen-cron.sh" -c "$GXC" 2>/dev/null | grep "delsnaps.sh" | grep -F "tank/backups/$1"
}

# STEP 1 -- relationship A created into a new shared CONFIG through the normal
# path. A brand-new CONFIG legitimately gets the CONFIG-wide safety defaults.
printf '[defaults]\n\thost_label = gxtest\n' > "$GXC"
out=$(emit_gx cliA labelA 10.8.8.1); rc=$?
if [ "$rc" -eq 0 ] && grep -qF "[excluded:vzdump]" "$GXC" && grep -qxF "[prune:tank/backups/labelA]" "$GXC"; then
    ok "92 step 1: a genuinely new CONFIG still gets the CONFIG-wide safety defaults"
else
    bad "92 step 1: a genuinely new CONFIG still gets the CONFIG-wide safety defaults" "rc=$rc out=$out file=$(cat "$GXC")"
fi

# STEP 2 -- the administrator customizes the installed global policy, keeping
# the CONFIG valid.
awk '/^\[excluded:vzdump\]/{skip=1;next} skip&&/^\[/{skip=0} !skip' "$GXC" > "$GXC.tmp" && mv "$GXC.tmp" "$GXC"

# STEP 3 -- record A's effective prune command as the REAL generator renders it.
# The assertion is on the rendered command, not on the config text: PROTECT_FLAGS
# is a generator-side concatenation, so config-level equality would not prove the
# thing Gate 2 actually promises.
a_before=$(gx_prune_line labelA)
if [ -n "$a_before" ] && case "$a_before" in *"-P vzdump"*) false ;; *) true ;; esac; then
    ok "92 step 3: with the floor removed, A's rendered prune line no longer carries it"
else
    bad "92 step 3: with the floor removed, A's rendered prune line no longer carries it" "a_before=$a_before"
fi

# STEP 4 -- a disjoint relationship B is created into the SAME populated CONFIG
# through the normal first-activation path.
out=$(emit_gx cliB labelB 10.8.8.2); rc=$?

# STEP 6 -- B is added successfully under the existing global policy.
if [ "$rc" -eq 0 ] && grep -qxF "[dataset:tank/backups/labelB/rpool/data]" "$GXC" \
        && bash "$REPO/gen-cron.sh" -c "$GXC" >/dev/null 2>&1; then
    ok "92 step 6: B is created successfully under the installed global policy"
else
    bad "92 step 6: B is created successfully under the installed global policy" "rc=$rc out=$(printf '%s' "$out" | tail -3)"
fi

# STEP 5 -- and A is untouched: the customized global state was not repaired,
# and A's effective prune command is byte-identical.
a_after=$(gx_prune_line labelA)
if ! grep -qF "[excluded:vzdump]" "$GXC" && [ "$a_after" = "$a_before" ] && [ -n "$a_after" ]; then
    ok "92 step 5: creating B neither restores the removed floor nor changes A's prune command"
else
    bad "92 step 5: creating B neither restores the removed floor nor changes A's prune command" \
        "restored=$(grep -qF '[excluded:vzdump]' "$GXC" && echo YES || echo no)
before=$a_before
after =$a_after"
fi

# ...and the operator is told, rather than left to find out from a missing pvesr
# snapshot. Inheriting the installed policy is correct; doing it silently is not.
if case "$out" in *"inherits the CONFIG-wide protection policy exactly as installed"*) true ;; *) false ;; esac; then
    ok "92 the additive CREATE says out loud which floors it is inheriting as absent"
else
    bad "92 the additive CREATE says out loud which floors it is inheriting as absent" "$(printf '%s' "$out" | tail -3)"
fi

# The explicit-migration escape hatch still lays global policy down deliberately:
# migrate-profile is previewed and confirmed, and it is the one command that
# INSTALLS the broad GFS ladder these floors exist to fence.
( PROFILE_ROOT="$GX" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
  ensure_cron_config "$GXC" 0 1 always ) >/dev/null 2>&1
if grep -qF "[excluded:vzdump]" "$GXC"; then
    ok "92 an explicit migration may still install the CONFIG-wide floors"
else
    bad "92 an explicit migration may still install the CONFIG-wide floors" "$(grep -c '^\[excluded:' "$GXC") excluded section(s)"
fi

# --- 53. Phase 4: --profile=NAME on add-client -------------------------------
#
# Goal (ACTIVE-WORK-PLAN.md Phase 4): a CREATE-time preset choice, validated
# up front, stored as provenance, consulted exactly once (first activation),
# never re-consulted on re-activation, and a zero-choice default unchanged.

# 1. An unknown profile name is refused at add-client, before any pairing --
# same pattern as the --bandwidth validation above (section 10): the check
# runs before the deploy.sh --pair call, so a subshell against a bogus /
# unreachable --lan is enough to prove refusal without a real peer.
prof_rc() { ( cmd_add_client "proftest" --lan=10.0.0.1 --datasets="tank/x" --profile="$1" ) >/dev/null 2>&1; echo $?; }
if [ "$(prof_rc "does-not-exist")" != 0 ]; then
    ok "add-client: an unknown --profile name is refused"
else
    bad "add-client: an unknown --profile name is refused" "exit 0 for --profile=does-not-exist"
fi

# 2. The default profile is accepted, and the choice is stored on the client
# record -- proven through the real add-client path (deploy.sh stubbed with a
# marker, same technique used for remove-client above) rather than asserting
# the write_client_field call was reached.
P53="$WORK/profile53"; mkdir -p "$P53/clients"
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=\n' "$P53" > "$P53/server.conf"
cat > "$P53/deploy_marker.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$P53/deploy_marker.sh"
( SERVER_CONF="$P53/server.conf" CLIENTS_DIR="$P53/clients" DEPLOY="$P53/deploy_marker.sh" \
  cmd_add_client "proftest2" --lan=10.0.0.1 --datasets="tank/x" ) >/dev/null 2>&1
if grep -q "^PROFILE=default$" "$P53/clients/proftest2.conf"; then
    ok "add-client: omitted --profile stores the zero-choice default"
else
    bad "add-client: omitted --profile stores the zero-choice default" "$(cat "$P53/clients/proftest2.conf" 2>&1)"
fi

# 3. A second, real, DIFFERENT profile name is validated and stored correctly
# -- not just "default" happening to work.
mkdir -p "$P53/profiles/altprofile"
cp "$REPO/profiles/default/templates.conf" "$REPO/profiles/default/dataset.inc" "$REPO/profiles/default/prune.inc" "$P53/profiles/altprofile/"
( SERVER_CONF="$P53/server.conf" CLIENTS_DIR="$P53/clients" DEPLOY="$P53/deploy_marker.sh" \
  PROFILE_ROOT="$P53/profiles" \
  cmd_add_client "proftest3" --lan=10.0.0.1 --datasets="tank/x" --profile=altprofile ) >/dev/null 2>&1
if grep -q "^PROFILE=altprofile$" "$P53/clients/proftest3.conf"; then
    ok "add-client: a named non-default profile is validated and stored"
else
    bad "add-client: a named non-default profile is validated and stored" "$(cat "$P53/clients/proftest3.conf" 2>&1)"
fi

# 4. apply_client_profile_choice: the wiring that turns the stored field into
# PROFILE_ACTIVE, unit-tested directly rather than through the full
# activate-client flow (which needs a live peer/manifest this suite
# deliberately does not stub -- see the file header).
#
# First activation with a chosen profile: adopted.
( PROFILE_ACTIVE=default; apply_client_profile_choice 1 altprofile; [ "$PROFILE_ACTIVE" = altprofile ] ) \
    && ok "apply_client_profile_choice: first activation adopts the stored profile" \
    || bad "apply_client_profile_choice: first activation adopts the stored profile" "not adopted"

# Re-activation: the profile field is never re-consulted, even if a client
# record happens to carry one (e.g. after this feature ships and an old
# relationship is later touched by set-endpoint) -- matches REV-20260809-089's
# one-way handoff for the profile in general.
( PROFILE_ACTIVE=default; apply_client_profile_choice 0 altprofile; [ "$PROFILE_ACTIVE" = default ] ) \
    && ok "apply_client_profile_choice: re-activation ignores the stored profile" \
    || bad "apply_client_profile_choice: re-activation ignores the stored profile" "PROFILE_ACTIVE was overwritten on a re-activation"

# Old client record, created before this field existed: PROFILE is empty on
# first activation too -- must be a no-op, not an error and not a switch to
# some other default.
( PROFILE_ACTIVE=default; apply_client_profile_choice 1 ""; [ "$PROFILE_ACTIVE" = default ] ) \
    && ok "apply_client_profile_choice: a pre-existing client record with no PROFILE field is a no-op" \
    || bad "apply_client_profile_choice: a pre-existing client record with no PROFILE field is a no-op" "PROFILE_ACTIVE changed with no chosen profile"

# --- 54. REV-20260810-095: the stored profile drives the REAL first activation -
#
# Section 53 proves add-client validates/stores the choice and unit-tests
# apply_client_profile_choice() directly. Neither crosses cmd_activate_client(),
# so neither proves the property Gate 4 exposes to the operator: a CREATE-time
# --profile choice, stored on the record, is what actually sources the candidate
# CONFIG on a real first activation. REV-089/090 already showed helper-level
# green while the caller still mishandled the profile -- so the discriminating
# test has to run the caller.
#
# Same fixture/stub strategy as section 50 (peerstate + keys + no-such-server +
# a $SNAPGET stub that copies the working copy out), with one difference that
# makes it safe on a host that HAS crontab: the stub captures the workfile and
# then exits non-zero, so cmd_activate_client dies at the "dry-run failed --
# not installing" gate, BEFORE the grant check and atomic_replace_and_install.
# The candidate CONFIG is fully rendered by then; nothing real is touched.
#
# The environment forces PROFILE_ACTIVE=default. The ONLY path by which the
# alternate profile can reach the rendered config is the record's PROFILE field
# threaded through apply_client_profile_choice() on first activation -- exactly
# the wiring under test.
PC="$WORK/profilechoice"
mkdir -p "$PC/clients" "$PC/peerstate" "$PC/keys" "$PC/dir" "$PC/cap" \
         "$PC/root/default" "$PC/root/alt"
for p in default alt; do
    cp "$REPO/profiles/default/templates.conf" "$REPO/profiles/default/dataset.inc" \
       "$REPO/profiles/default/prune.inc" "$PC/root/$p/"
done
# ALT's only difference is an observable, safe-to-render marker: the hourly
# send cadence. If the candidate carries minute 7 it came from ALT's content,
# not just ALT's namespace string.
sed -i 's/^\tsend_schedule  = 1 \* \* \* \*/\tsend_schedule  = 7 * * * */' "$PC/root/alt/templates.conf"

for h in 10.7.7.8 10.7.7.9; do
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2U\n' "$h" > "$PC/keys/${h}_known_hosts"
done
cat > "$PC/peerstate/10.7.7.8.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF
printf '[defaults]\n\thost_label = pctest\n' > "$PC/dir/jobs.conf"
cat > "$PC/snapget-capture.sh" <<EOF
#!/usr/bin/env bash
cp -f "$PC/dir"/.zfsbackup-work.* "$PC/cap/workfile" 2>/dev/null
exit 1
EOF
chmod +x "$PC/snapget-capture.sh"

pc_client() {   # <name> <PROFILE-line-or-empty>
    { printf 'CLIENT_NAME=%s\nPEER_HOST=10.7.7.8\nSTATE=endpoint_verified\n' "$1"
      printf 'ACTIVE_ENDPOINT=lan\nENDPOINT_LAN_HOST=10.7.7.9\nENDPOINT_LAN_PORT=22\n'
      [ -n "$2" ] && printf '%s\n' "$2"
      printf 'CRON_CONFIG=%s/dir/jobs.conf\n' "$PC"
    } > "$PC/clients/$1.conf"
}
pc_client apalt "PROFILE=alt"
pc_client apdef "PROFILE=default"

run_pc() {   # <client> <neuter 0|1> -> leaves the captured candidate in $PC/cap/workfile
    rm -f "$PC/cap/workfile" "$PC/dir"/.zfsbackup-work.*
    ( if [ "$2" = 1 ]; then apply_client_profile_choice() { :; }; fi
      CLIENTS_DIR="$PC/clients" PEER_STATE_DIR="$PC/peerstate" PEER_KEY_DIR="$PC/keys" \
      SERVER_CONF="$PC/no-such-server.conf" SNAPGET="$PC/snapget-capture.sh" \
      PROFILE_ROOT="$PC/root" PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_activate_client "$1" --yes ) >/dev/null 2>&1
}

# 1. First activation with PROFILE=alt: the candidate CONFIG is sourced from ALT.
run_pc apalt 0
if [ -f "$PC/cap/workfile" ] \
        && grep -qE '^\[template:profile__alt__standard_hourly\]' "$PC/cap/workfile" \
        && grep -qE 'send_schedule[[:space:]]+= 7 \* \* \* \*' "$PC/cap/workfile" \
        && grep -qE 'use_template = profile__alt__' "$PC/cap/workfile" \
        && ! grep -qE 'profile__default__' "$PC/cap/workfile"; then
    ok "95: a stored PROFILE=alt drives the real first activation's candidate CONFIG"
else
    bad "95: a stored PROFILE=alt drives the real first activation's candidate CONFIG" \
        "$([ -f "$PC/cap/workfile" ] && cat "$PC/cap/workfile" || echo '(no candidate captured)')"
fi

# ...and the ALT semantics reach the rendered cron through the REAL gen-cron.sh,
# not just the config text (REV-20260809-082 V1: "the text looks right" is the
# appearance this project keeps mistaking for the property). Render into a
# variable first: this suite runs under pipefail, so `gen-cron | grep -q` would
# report the whole pipeline as failed (gen-cron takes SIGPIPE the moment grep -q
# short-circuits on a match), which is the opposite of what the grep found.
pc_rendered="$(bash "$REPO/gen-cron.sh" -c "$PC/cap/workfile" 2>/dev/null)"
if [ -f "$PC/cap/workfile" ] && printf '%s\n' "$pc_rendered" | grep -qE '^7 \* \* \* \* '; then
    ok "95: the ALT send cadence reaches the rendered cron via the real gen-cron.sh"
else
    bad "95: the ALT send cadence reaches the rendered cron via the real gen-cron.sh" \
        "$(printf '%s\n' "$pc_rendered" | grep -E 'snapget|snapsend|^[0-9]' | head -3)"
fi

# 2. The omitted-choice path (add-client stores PROFILE=default) still resolves
# to the existing default semantics -- minute 1, default namespace, no ALT leak.
run_pc apdef 0
if [ -f "$PC/cap/workfile" ] \
        && grep -qE '^\[template:profile__default__standard_hourly\]' "$PC/cap/workfile" \
        && grep -qE 'send_schedule[[:space:]]+= 1 \* \* \* \*' "$PC/cap/workfile" \
        && ! grep -qE 'profile__alt__|= 7 \* \* \* \*' "$PC/cap/workfile"; then
    ok "95: the default (omitted-choice) profile still yields the default semantics"
else
    bad "95: the default (omitted-choice) profile still yields the default semantics" \
        "$([ -f "$PC/cap/workfile" ] && cat "$PC/cap/workfile" || echo '(no candidate captured)')"
fi

# 3. Negative control: remove the wiring (apply_client_profile_choice neutered).
# Same PROFILE=alt record, same run -- but with the setter bypassed the stored
# choice must have NO effect, so the candidate falls back to the environment's
# default profile. If this "control" still produced ALT, the assertions above
# would be proving nothing.
run_pc apalt 1
if [ -f "$PC/cap/workfile" ] \
        && grep -qE 'profile__default__' "$PC/cap/workfile" \
        && ! grep -qE 'profile__alt__|= 7 \* \* \* \*' "$PC/cap/workfile"; then
    ok "95 control: with the wiring bypassed, the stored PROFILE has no effect"
else
    bad "95 control: with the wiring bypassed, the stored PROFILE has no effect" \
        "the neutered run still carried ALT -- the positive assertions are not discriminating: $([ -f "$PC/cap/workfile" ] && grep -c profile__alt__ "$PC/cap/workfile")"
fi

# 4. Re-activation must still ignore the stored profile even now that the caller
# reads it -- the one-way handoff REV-089 drew. A STATE=active record with
# PROFILE=alt, reactivated, must NOT pull ALT policy in.
pc_client apre "PROFILE=alt"
sed -i 's/^STATE=endpoint_verified$/STATE=active/' "$PC/clients/apre.conf"
# reactivation needs the section already owned/installed; point it at a config
# that carries a default-profile section this client owns.
PRE="$PC/dir/jobs-apre.conf"
printf '[defaults]\n\thost_label = pctest\n' > "$PRE"
( PROFILE_ROOT="$PC/root" PROFILE_ACTIVE=default PROFILE_LOADED="" \
  PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=10.7.7.8 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.8 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
  ensure_cron_config "$PRE" 1 1 >/dev/null 2>&1
  PROFILE_ROOT="$PC/root" PROFILE_ACTIVE=default PROFILE_LOADED="" \
  PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=10.7.7.8 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.8 LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
  emit_client_sections "$PRE" apre 1 ) >/dev/null 2>&1
sed -i "s#^CRON_CONFIG=.*#CRON_CONFIG=$PRE#; s#^ENDPOINT_LAN_HOST=.*#ENDPOINT_LAN_HOST=10.7.7.9#" "$PC/clients/apre.conf"
printf 'MANAGED_DATASETS=tank/backups/10.7.7.8/rpool/data\nMANAGED_PRUNE_SCOPE=tank/backups/10.7.7.8\n' >> "$PC/clients/apre.conf"
rm -f "$PC/cap/workfile" "$PC/dir"/.zfsbackup-work.*
( CLIENTS_DIR="$PC/clients" PEER_STATE_DIR="$PC/peerstate" PEER_KEY_DIR="$PC/keys" \
  SERVER_CONF="$PC/no-such-server.conf" SNAPGET="$PC/snapget-capture.sh" \
  PROFILE_ROOT="$PC/root" PROFILE_ACTIVE=default PROFILE_LOADED="" \
  cmd_activate_client apre --yes ) >/dev/null 2>&1
if [ -f "$PC/cap/workfile" ] && ! grep -qE 'profile__alt__|= 7 \* \* \* \*' "$PC/cap/workfile"; then
    ok "95: re-activation still ignores the stored profile (one-way handoff intact)"
else
    bad "95: re-activation still ignores the stored profile (one-way handoff intact)" \
        "$([ -f "$PC/cap/workfile" ] && grep -c profile__alt__ "$PC/cap/workfile" || echo '(no candidate captured)')"
fi

# --- 55. REV-20260811-102 step 3 (owner Q4): assert_source_prune_grant fail-closed ---
#
# Before a collector-scheduled REMOTE source prune is installed, the relationship's
# delegated identity must already hold `destroy` on the source (delsnaps' zfs
# destroy). This must FAIL CLOSED -- refuse rather than install a job that fails,
# and never widen the grant. Stub `zfs allow` output over ssh; no real host.
SPG="$WORK/srcgrant"; mkdir -p "$SPG/bin"
cat > "$SPG/bin/ssh" <<'EOF'
#!/bin/sh
# the remote command is the tail; find which dataset zfs allow was asked about
case "$*" in
  *"tank/ok"*)        printf '%b' '---- Permissions on tank/ok ----\nLocal+Descendent permissions:\n\tuser zfsbackup snapshot,destroy,send,hold,release,bookmark\n' ;;
  *"tank/nodestroy"*) printf '%b' '---- Permissions on tank/nodestroy ----\nLocal+Descendent permissions:\n\tuser zfsbackup snapshot,send,hold,release\n' ;;
  # REV-20260812-111 A: everything the source prune itself needs, but no
  # `bookmark` -- the shape deploy.sh warns about and the shape measured live
  # on 2026-08-12, where the transfer still exits 0 and only warns.
  *"tank/nobookmark"*) printf '%b' '---- Permissions on tank/nobookmark ----\nLocal+Descendent permissions:\n\tuser zfsbackup snapshot,destroy,send,hold,release\n' ;;
  *"tank/sshfail"*)   exit 255 ;;
  *) : ;;
esac
EOF
chmod +x "$SPG/bin/ssh"
spg() { ( PATH="$SPG/bin:$PATH"; assert_source_prune_grant zfsbackup 10.0.0.9 22 /dev/null zfs-client-x /dev/null "$@" ) >/dev/null 2>&1; }
spg tank/ok           && ok "55 grant with destroy on the source passes"        || bad "55 grant with destroy on the source passes" ""
spg tank/nodestroy    && bad "55 missing destroy FAILS CLOSED" "returned 0"      || ok "55 missing destroy FAILS CLOSED (refuse, no widening)"
spg tank/sshfail      && bad "55 an ssh/zfs-allow failure FAILS CLOSED" "rc=0"   || ok "55 an ssh/zfs-allow failure FAILS CLOSED"
spg tank/ok tank/nodestroy && bad "55 one missing-destroy dataset among many FAILS CLOSED" "" || ok "55 one missing-destroy dataset among many FAILS CLOSED"
# the refusal names 'destroy' and does not propose widening beyond it.
msg="$( ( PATH="$SPG/bin:$PATH"; assert_source_prune_grant zfsbackup 10.0.0.9 22 /dev/null zfs-client-x /dev/null tank/nodestroy ) 2>&1 )"
{ printf '%s' "$msg" | grep -qi "does not hold 'destroy'" && ! printf '%s' "$msg" | grep -qiw 'mount'; } \
    && ok "55 the refusal names destroy and proposes no mount/widening" \
    || bad "55 the refusal names destroy and proposes no mount/widening" "$(printf '%s' "$msg"|tail -1)"

# REV-20260812-111 A: `destroy` alone is not enough. A source the identity can
# prune but cannot bookmark activates looking healthy and carries no continuity
# insurance -- refuse at activation, not at 03:00 on the night the common base
# ages out. Discriminating pair: the ONLY difference between tank/ok and
# tank/nobookmark is the bookmark permission, so a check that ignored it would
# pass both.
spg tank/nobookmark && bad "55 REV-111: destroy without bookmark FAILS CLOSED" "returned 0" \
                    || ok "55 REV-111: destroy without bookmark FAILS CLOSED"
spg tank/ok         && ok "55 REV-111: the same source WITH bookmark still passes (control)" \
                    || bad "55 REV-111: the same source WITH bookmark still passes (control)" ""
spg tank/ok tank/nobookmark && bad "55 REV-111: one un-bookmarkable source among many FAILS CLOSED" "" \
                            || ok "55 REV-111: one un-bookmarkable source among many FAILS CLOSED"
msg="$( ( PATH="$SPG/bin:$PATH"; assert_source_prune_grant zfsbackup 10.0.0.9 22 /dev/null zfs-client-x /dev/null tank/nobookmark ) 2>&1 )"
{ printf '%s' "$msg" | grep -qi "NOT 'bookmark'" \
  && printf '%s' "$msg" | grep -qi 'commit-scope' \
  && ! printf '%s' "$msg" | grep -qi 'zfs allow -u'; } \
    && ok "55 REV-111: the refusal names bookmark, points at --commit-scope, widens nothing" \
    || bad "55 REV-111: the refusal names bookmark, points at --commit-scope, widens nothing" "$(printf '%s' "$msg"|tail -1)"

# --- 56. REV-20260811-102 step 3: REMOTE source prune emission (pull relationship) ---
#
# emit_client_sections must also bound the tool-owned automated_ snapshots on the
# REMOTE source, over the same pinned SSH, with the INDEPENDENT (REV-106) source
# family, NON-recursive, and fully REGENERATED per activation so an endpoint switch
# moves it. Uses a FRESH profile dir (NOT the shared P9, which an earlier test
# deliberately contaminates with `recursive = yes` to prove reactivation ignores a
# changed profile) + emit9-style harness, with the SSH connection vars set so
# ssh_flags render realistically and gen-cron accepts the result.
P56="$WORK/step3prof"; mkdir -p "$P56/prof"
cp "$REPO/profiles/default/templates.conf" "$P56/prof/templates.conf"
cp "$REPO/profiles/default/prune.inc"      "$P56/prof/prune.inc"
cp "$REPO/profiles/default/dataset.inc"    "$P56/prof/dataset.inc"
emit_src3() {   # <conf> <name> <host> <is_new>
    ( PROFILE_ROOT="$P56" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=pve9 \
      LOAD_ACCOUNT=zfsbackup LOAD_HOST="$3" LOAD_PORT=22 LOAD_KEYFILE=/dev/null \
      LOAD_ALIAS=pve9alias LOAD_ALIAS_KH=/dev/null LOAD_FLAGS="-K /dev/null" \
      PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 \
      MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
      emit_client_sections "$1" "$2" "$4" ) 2>&1
}
S3="$WORK/step3.conf"; : > "$S3"
out=$(emit_src3 "$S3" s3c 10.7.7.1 1); rc=$?
# emission: remote source [prune:account@host:ds], non-recursive, with ssh_flags
if [ "$rc" -eq 0 ] \
        && grep -qxF '[prune:zfsbackup@10.7.7.1:rpool/data]' "$S3" \
        && awk '/^\[prune:zfsbackup@10.7.7.1:rpool\/data\]/{f=1;next} /^\[/{f=0} f' "$S3" | grep -q 'recursive    = no' \
        && awk '/^\[prune:zfsbackup@10.7.7.1:rpool\/data\]/{f=1;next} /^\[/{f=0} f' "$S3" | grep -q 'ssh_flags    = -K /dev/null'; then
    ok "56 step3: a remote source [prune:account@host:ds] is emitted, non-recursive, with ssh_flags"
else
    bad "56 step3: a remote source [prune:account@host:ds] is emitted, non-recursive, with ssh_flags" "rc=$rc file=$(cat "$S3")"
fi
# the source prune uses the INDEPENDENT src_ family, not the target's
if awk '/^\[prune:zfsbackup@10.7.7.1:rpool\/data\]/{f=1;next} /^\[/{f=0} f' "$S3" | grep -q 'use_template = profile__prof__src_keep_' \
        && grep -q '^\[template:profile__prof__src_keep_hourly\]' "$S3"; then
    ok "56 step3: the source prune references the INDEPENDENT src_ template family"
else
    bad "56 step3: the source prune references the INDEPENDENT src_ template family" "$(grep -E '^\[template:|use_template' "$S3")"
fi
# the SOURCE templates carry NO monitor_ fields (remote scope: check-snap-age is
# local-only and gen-cron would reject monitor on a remote scope)
src_hourly="$(awk '/^\[template:profile__prof__src_keep_hourly\]/{f=1;next} /^\[/{f=0} f' "$S3")"
if [ -n "$src_hourly" ] && ! printf '%s' "$src_hourly" | grep -q 'monitor_'; then
    ok "56 step3: the SOURCE template family drops monitor_ fields (valid on a remote scope)"
else
    bad "56 step3: the SOURCE template family drops monitor_ fields" "src_hourly=[$src_hourly]"
fi
# the COMPLETE config -- [defaults], the profile's rendered target templates, and
# the emitted stanzas (which already carry the src_ templates + the source prune) --
# is accepted by the REAL gen-cron.sh AND renders a delsnaps line against the remote
# source scope. Assembled the same way as the field-survival render test, because
# emit_client_sections alone does not write [defaults] or the TARGET templates
# (ensure_cron_config does that first in the real flow).
( PROFILE_ROOT="$P56" profile_render_templates "$P56/prof" prof "$WORK/s3tpl.conf" ) || true
{ printf '[defaults]\n\thost_label = pve9\n\n'; cat "$WORK/s3tpl.conf"; cat "$S3"; } > "$WORK/s3full.conf"
s3_render="$(bash "$REPO/gen-cron.sh" -c "$WORK/s3full.conf" 2>"$WORK/s3.err")"; s3_rc=$?
if [ "$s3_rc" -eq 0 ]; then
    ok "56 step3: the complete config with the remote source prune is accepted by the REAL gen-cron.sh"
else
    bad "56 step3: the complete config with the remote source prune is accepted by the REAL gen-cron.sh" "$(tail -3 "$WORK/s3.err")"
fi
if printf '%s\n' "$s3_render" | grep -q 'delsnaps\.sh.*"zfsbackup@10.7.7.1:rpool/data" "automated_"'; then
    ok "56 step3: the rendered cron prunes the remote source scope with pattern automated_"
else
    bad "56 step3: the rendered cron prunes the remote source scope with pattern automated_" "$(printf '%s\n' "$s3_render" | grep delsnaps)"
fi
# endpoint switch MOVES the source prune to the new endpoint (its scope is
# topology-derived), leaving no stale [prune:<old account@host>] behind.
out=$(emit_src3 "$S3" s3c 10.7.7.2 0); rc=$?
if [ "$rc" -eq 0 ] \
        && grep -qxF '[prune:zfsbackup@10.7.7.2:rpool/data]' "$S3" \
        && ! grep -qF '[prune:zfsbackup@10.7.7.1:rpool/data]' "$S3"; then
    ok "56 step3: an endpoint switch moves the source prune, leaving no stale-endpoint scope"
else
    bad "56 step3: an endpoint switch moves the source prune, leaving no stale-endpoint scope" "rc=$rc file=$(cat "$S3")"
fi

# REV-20260811-107: re-activation must MOVE only topology (scope + ssh_flags) and
# PRESERVE the installed source-retention POLICY -- CONFIG v4 is runtime truth after
# CREATE, source and target independently editable. Discriminating regression:
R7="$WORK/step3rev107.conf"; : > "$R7"
srcsec() { awk -v h="[prune:$1]" '$0==h{f=1;next} /^\[/{f=0} f' "$R7"; }
emit_src3b() { emit_src3 "$R7" r7c "$1" "$2" >/dev/null 2>&1; }   # writes into $R7
emit_src3b 10.9.9.1 1   # CREATE at endpoint 1
# admin edits SOURCE retention ONLY: drop weekly+monthly from the source prune's
# use_template (a 6H/2D-style shortening), leaving TARGET at the full profile ladder.
sed -i '/^\[prune:zfsbackup@10.9.9.1:rpool\/data\]/,/^\[/{s/\(use_template = profile__prof__src_keep_hourly,profile__prof__src_keep_daily\),profile__prof__src_keep_weekly,profile__prof__src_keep_monthly/\1/}' "$R7"
before_src="$(srcsec 'zfsbackup@10.9.9.1:rpool/data' | grep use_template)"
emit_src3b 10.9.9.2 0   # ordinary endpoint change / re-activation
after_src="$(srcsec 'zfsbackup@10.9.9.2:rpool/data' | grep use_template)"
after_sshf="$(srcsec 'zfsbackup@10.9.9.2:rpool/data' | grep ssh_flags)"
# emit_src3 uses LOAD_LABEL=pve9, so the TARGET prune scope is tank/backups/pve9
after_tgt="$(srcsec 'tank/backups/pve9' | grep use_template)"
# 1. the edited SOURCE policy survived the endpoint change (NOT regenerated)
if [ "$after_src" = "	use_template = profile__prof__src_keep_hourly,profile__prof__src_keep_daily" ]; then
    ok "56/107: re-activation PRESERVES the edited source retention (policy not regenerated)"
else
    bad "56/107: re-activation PRESERVES the edited source retention (policy not regenerated)" "before=[$before_src] after=[$after_src]"
fi
# 2. only topology moved: new scope + no stale endpoint + refreshed ssh_flags
if grep -qxF '[prune:zfsbackup@10.9.9.2:rpool/data]' "$R7" \
        && ! grep -qF '10.9.9.1' "$R7" \
        && printf '%s' "$after_sshf" | grep -q 'HostKeyAlias='; then
    ok "56/107: re-activation moves ONLY topology (scope + ssh_flags) to the new endpoint"
else
    bad "56/107: re-activation moves ONLY topology (scope + ssh_flags) to the new endpoint" "$(cat "$R7")"
fi
# 3. TARGET retention is untouched throughout
if [ "$after_tgt" = "	use_template = profile__prof__keep_hourly,profile__prof__keep_daily,profile__prof__keep_weekly,profile__prof__keep_monthly" ]; then
    ok "56/107: TARGET retention is unchanged by the source edit + re-activation"
else
    bad "56/107: TARGET retention is unchanged by the source edit + re-activation" "after=[$after_tgt]"
fi
# the flow reads SOURCE_PRUNE_EMITTED_DS to grant-check exactly the emitted datasets
out=$( ( PROFILE_ROOT="$P56" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=pve9 \
         LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.3 LOAD_PORT=22 LOAD_KEYFILE=/dev/null \
         LOAD_ALIAS=a LOAD_ALIAS_KH=/dev/null LOAD_FLAGS="-K /dev/null" \
         PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE=""
         emit_client_sections "$WORK/step3b.conf" s3d 1 >/dev/null 2>&1
         echo "EMITTED=[${SOURCE_PRUNE_EMITTED_DS[*]}]" ) 2>&1 )
case "$out" in
    *"EMITTED=[rpool/data]"*) ok "56 step3: emit records the source datasets for the flow's fail-closed grant check" ;;
    *) bad "56 step3: emit records the source datasets for the flow's fail-closed grant check" "$out" ;;
esac

fi   # === end of full-suite-only sections; the retention group below is L0-targetable ===

# ============================================================================
# RETENTION GROUP (REV-102 / REV-108 / REV-110 source-retention audit).
# Self-contained: builds its own profile fixture here, so `--section retention`
# never depends on state produced by the skipped sections above (REV-109 4.3).
# Runs both standalone (targeted) and as part of the full suite.
# ============================================================================
RP56="$WORK/retprof"; mkdir -p "$RP56/prof"
cp "$REPO/profiles/default/templates.conf" "$RP56/prof/templates.conf"
cp "$REPO/profiles/default/prune.inc"      "$RP56/prof/prune.inc"
cp "$REPO/profiles/default/dataset.inc"    "$RP56/prof/dataset.inc"

# --- 57. REV-20260811-102 step 5: audit-source-retention (read-only, no silent repair) ---
#
# Relationships installed BEFORE step 3 have a [dataset:]/[prune:target] but no
# bounded source [prune:account@host:ds]. The audit must, read-only, name exactly
# those and NOT touch the config; and report nothing once the source prune exists.
# read_server_conf and load_client_and_connection carry endpoint machinery this unit
# does not exercise, so they are stubbed to the fixture endpoint.
A5="$WORK/audit5"; mkdir -p "$A5/clients"
cat > "$A5/clients/c1.conf" <<'EOF'
CLIENT_NAME=c1
STATE=active
PEER_SAVED_DATASETS=rpool/data
PEER_SAVED_MODE=backup
PEER_SAVED_TARGET=tank/backups
EOF
# a config that pulls rpool/data but carries NO source prune for it. The audit keys the
# source scope off the INSTALLED [dataset:] src, so the header path must match
# client_local_path = PEER_SAVED_TARGET/LOAD_LABEL/ds = tank/backups/c1/rpool/data.
cat > "$A5/jobs.conf" <<'EOF'
[defaults]
	host_label = h
[dataset:tank/backups/c1/rpool/data]
	# managed-by: zfs-backup.sh client=c1
	use_template = profile__default__standard_hourly
	src          = zfsbackup@10.5.5.5:rpool/data
	flags        = -K /dev/null
	pair_label   = c1
	notify       = c1-data
[prune:tank/backups/c1]
	# managed-by: zfs-backup.sh client=c1
	use_template = profile__default__keep_hourly
	gfs          = yes
	gfs_pattern  = automated_
	recursive    = yes
	pair_label   = c1
	notify       = c1
EOF
# F3: the audit decides "bounded" from EFFECTIVE retention -- the config rendered
# through gen-cron -- not from a [prune:] header. A gen-cron stub lets this test
# control exactly what the render contains for the source scope, so the decision rule
# (delsnaps-for-scope present?) is exercised directly, including the case where the
# header exists but resolves to no bounded prune. The real-gen-cron delsnaps ARGUMENT
# format the audit greps for is separately pinned by section 56.
GC5="$A5/gencron-stub.sh"
cat > "$GC5" <<'EOF'
#!/usr/bin/env bash
# ignores its -c arg; emits whatever render fixture the test staged
cat "$GENCRON_RENDER"
EOF
chmod +x "$GC5"
A5_RENDER="$A5/render.crontab"
audit5() {  # runs the read-only audit against the fixture, render controlled by $A5_RENDER
    GENCRON_RENDER="$A5_RENDER" bash -c "source '$ZFSBACKUP'
        read_server_conf() { CRON_CONFIG='$A5/jobs.conf'; }
        load_client_and_connection() { LOAD_ACCOUNT=zfsbackup; LOAD_HOST=10.5.5.5; LOAD_PORT=22; LOAD_KEYFILE=/dev/null; LOAD_ALIAS=a; LOAD_ALIAS_KH=/dev/null; LOAD_LABEL=c1; }
        GENCRON='$GC5' CLIENTS_DIR='$A5/clients' SCRIPT_DIR='$A5' cmd_audit_source_retention" 2>&1
}
# render fixture WITHOUT a delsnaps for the source scope (unbounded / pre-step-3)
: > "$A5_RENDER"
md5_before="$(md5sum "$A5/jobs.conf" | awk '{print $1}')"
out="$(audit5)"; rc=$?
md5_after="$(md5sum "$A5/jobs.conf" | awk '{print $1}')"
# 1. names the missing source prune, counts it, and is read-only (no mutation)
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -qE 'bez ograniczonej retencji zrodla: +1' \
        && printf '%s' "$out" | grep -qF '[prune:zfsbackup@10.5.5.5:rpool/data]' \
        && printf '%s' "$out" | grep -qi 'TYLKO-DO-ODCZYTU' \
        && [ "$md5_before" = "$md5_after" ]; then
    ok "57 step5: audit names the missing source retention and does NOT touch the config"
else
    bad "57 step5: audit names the missing source retention and does NOT touch the config" "rc=$rc md5eq=$([ "$md5_before" = "$md5_after" ] && echo y || echo N) out=$out"
fi
# 2. F3 NEGATIVE CONTROL: add the exact [prune:<scope>] HEADER to the config, but the
#    render STILL emits no delsnaps for that scope (header present, effectively
#    unbounded). The audit must NOT report it safe -- header existence is not proof.
cat >> "$A5/jobs.conf" <<'EOF'
[prune:zfsbackup@10.5.5.5:rpool/data]
	# managed-by: zfs-backup.sh client=c1
	use_template = profile__default__src_keep_hourly
	recursive    = no
	ssh_flags    = -K /dev/null
	pair_label   = c1
	notify       = c1-src-data
EOF
out="$(audit5)"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -qE 'bez ograniczonej retencji zrodla: +1' \
        && ! printf '%s' "$out" | grep -qi 'nic do dodania'; then
    ok "57 step5 (F3): a [prune:] header that renders no bounded delsnaps is NOT reported safe"
else
    bad "57 step5 (F3): a [prune:] header that renders no bounded delsnaps is NOT reported safe" "rc=$rc out=$out"
fi
# 3. F3 RESIDUAL negative control: the render carries a `delsnaps -B` BOOKMARK cleanup
#    for the exact scope. It mentions delsnaps + the scope but deletes bookmarks, not
#    the managed automated_hourly_ snapshots -> audit must STILL report missing.
printf '31 4 * * * e=$(mktemp); /x/delsnaps.sh -B -K /dev/null "zfsbackup@10.5.5.5:rpool/data" "automated_" -d30 2>"$e"\n' > "$A5_RENDER"
out="$(audit5)"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -qE 'bez ograniczonej retencji zrodla: +1' \
        && ! printf '%s' "$out" | grep -qi 'nic do dodania'; then
    ok "57 step5 (F3res): a bookmark-only (delsnaps -B) job for the scope is NOT bounded"
else
    bad "57 step5 (F3res): a bookmark-only (delsnaps -B) job for the scope is NOT bounded" "rc=$rc out=$out"
fi
# 4. F3 RESIDUAL negative control: the render prunes an UNRELATED prefix (manual_) at
#    the exact scope. It bounds a different family, not automated_hourly_ -> still missing.
printf '30 * * * * e=$(mktemp); /x/delsnaps.sh -K /dev/null -G "zfsbackup@10.5.5.5:rpool/data" "manual_" -H24 2>"$e"\n' > "$A5_RENDER"
out="$(audit5)"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -qE 'bez ograniczonej retencji zrodla: +1' \
        && ! printf '%s' "$out" | grep -qi 'nic do dodania'; then
    ok "57 step5 (F3res): a snapshot prune of an unrelated prefix is NOT bounded"
else
    bad "57 step5 (F3res): a snapshot prune of an unrelated prefix is NOT bounded" "rc=$rc out=$out"
fi
# 5. bounded: a snapshot prune whose pattern COVERS the managed automated_hourly_
#    family with finite retention -> audit reports nothing to add (idempotent).
printf '0 * * * * /x/snapget.sh -m "automated_hourly_" -A -L c1 "zfsbackup@10.5.5.5:rpool/data" tank/backups/c1/rpool/data\n30 * * * * e=$(mktemp); /x/delsnaps.sh -K /dev/null -G "zfsbackup@10.5.5.5:rpool/data" "automated_" -H24 -D7 2>"$e"\n' > "$A5_RENDER"
out="$(audit5)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'nic do dodania'; then
    ok "57 step5: audit reports nothing to add once a managed-prefix bounded prune renders (idempotent)"
else
    bad "57 step5: audit reports nothing to add once a managed-prefix bounded prune renders" "rc=$rc out=$out"
fi

# --- 57b. F4/F5: --apply is a NARROW retrofit (add only missing source retention),
#     proven against a REAL profile + REAL gen-cron, with the grant gate and install
#     stubbed. Build a valid pre-step-3 "installed" config by generating a full client
#     config and stripping its source prune, then --apply must re-add ONLY the source
#     prune while leaving [dataset:] src (topology) and target prune byte-identical. ---
AP="$WORK/apply5"; mkdir -p "$AP/clients"
# generate a full valid client config (dataset + target prune + source prune + templates)
( PROFILE_ROOT="$RP56" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
  PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=pve9 \
  LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.1 LOAD_PORT=22 LOAD_KEYFILE=/dev/null \
  LOAD_ALIAS=a LOAD_ALIAS_KH=/dev/null LOAD_FLAGS="-K /dev/null" \
  PEER_SAVED_DATASETS="rpool/data" PROFILE_GFS=1 MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
  emit_client_sections "$AP/full.conf" apc 1 ) >/dev/null 2>&1
( PROFILE_ROOT="$RP56" profile_render_templates "$RP56/prof" prof "$AP/tpl.conf" ) || true
# assemble the "installed" config, then STRIP the source prune section + its src_
# templates to simulate a relationship installed BEFORE step 3
{ printf '[defaults]\n\thost_label = pve9\n\n'; cat "$AP/tpl.conf"; cat "$AP/full.conf"; } > "$AP/installed.raw"
awk '
  /^\[prune:zfsbackup@/{skip=1}
  /^\[template:profile__prof__src_/{skip=1}
  /^\[/{ if ($0 !~ /^\[prune:zfsbackup@/ && $0 !~ /^\[template:profile__prof__src_/) skip=0 }
  !skip{print}
' "$AP/installed.raw" > "$AP/jobs.conf"
cat > "$AP/clients/apc.conf" <<'EOF'
CLIENT_NAME=apc
STATE=active
PEER_SAVED_DATASETS=rpool/data
PEER_SAVED_MODE=backup
PEER_SAVED_TARGET=tank/backups
EOF
inst_src_before="$(awk '/^\[dataset:/{f=1} /^\[prune:/{f=0} f&&/src /' "$AP/jobs.conf")"
apply5() {  # <grantrc> <loaded-host> : runs --apply with a controllable endpoint + grant
    local grantrc="$1" loadhost="$2"
    ( PROFILE_ROOT="$RP56" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
      bash -c "source '$ZFSBACKUP'
        read_server_conf() { CRON_CONFIG='$AP/jobs.conf'; }
        load_client_and_connection() { LOAD_ACCOUNT=zfsbackup; LOAD_HOST=$loadhost; LOAD_PORT=22; LOAD_KEYFILE=/dev/null; LOAD_ALIAS=a; LOAD_ALIAS_KH=/dev/null; LOAD_FLAGS='-K /dev/null'; LOAD_LABEL=pve9; PEER_SAVED_MODE=backup; PEER_SAVED_TARGET='tank/backups'; }
        assert_source_prune_grant() { return $grantrc; }
        show_activation_proposal() { return 0; }
        assert_cron_config_matches_installed() { return 0; }
        assert_no_foreign_managed_block() { return 0; }
        assert_target_block_not_clobbered() { return 0; }
        assert_config_readable_by_target() { return 0; }
        atomic_replace_and_install() { cp \"\$2\" \"\$1\"; }
        GENCRON='$REPO/gen-cron.sh' PROFILE_ROOT='$RP56' PROFILE_ACTIVE=prof PROFILE_LOADED='' \
          CLIENTS_DIR='$AP/clients' SCRIPT_DIR='$AP' cmd_audit_source_retention --apply --yes" 2>&1 )
}
# 4. F5 REFUSAL: endpoints agree, but the grant check fails -> non-zero, byte-identical
md5_ap_before="$(md5sum "$AP/jobs.conf" | awk '{print $1}')"
out="$(apply5 1 10.7.7.1)"; rc=$?
md5_ap_after="$(md5sum "$AP/jobs.conf" | awk '{print $1}')"
if [ "$rc" -ne 0 ] && [ "$md5_ap_before" = "$md5_ap_after" ]; then
    ok "57b step5 (F5): --apply with a failing grant check installs nothing (config byte-identical)"
else
    bad "57b step5 (F5): --apply with a failing grant check installs nothing" "rc=$rc md5eq=$([ "$md5_ap_before" = "$md5_ap_after" ] && echo y || echo N) out=$out"
fi
# 5. F4 DISCRIMINATING REGRESSION: the client's current endpoint (10.9.9.9) DIFFERS
#    from the installed [dataset:] src (10.7.7.1). The retrofit must NOT opportunistically
#    repair topology -- it refuses, names the mismatch, and changes nothing.
md5_ap_before="$(md5sum "$AP/jobs.conf" | awk '{print $1}')"
out="$(apply5 0 10.9.9.9)"; rc=$?
md5_ap_after="$(md5sum "$AP/jobs.conf" | awk '{print $1}')"
if [ "$rc" -ne 0 ] \
        && [ "$md5_ap_before" = "$md5_ap_after" ] \
        && printf '%s' "$out" | grep -qiE 'disagree|reconcile'; then
    ok "57b step5 (F4): --apply refuses when client endpoint disagrees with installed src (no topology repair)"
else
    bad "57b step5 (F4): --apply refuses when client endpoint disagrees with installed src" "rc=$rc md5eq=$([ "$md5_ap_before" = "$md5_ap_after" ] && echo y || echo N) out=$out"
fi
# 6. F4 SUCCESS: endpoints agree, grant OK -> a bounded source prune is ADDED at the
#    INSTALLED endpoint, and the [dataset:] src (topology) is byte-identical (NOT rewritten)
out="$(apply5 0 10.7.7.1)"; rc=$?
inst_src_after="$(awk '/^\[dataset:/{f=1} /^\[prune:/{f=0} f&&/src /' "$AP/jobs.conf")"
new_render="$(bash "$REPO/gen-cron.sh" -c "$AP/jobs.conf" 2>/dev/null)"
if [ "$rc" -eq 0 ] \
        && grep -qF '[prune:zfsbackup@10.7.7.1:rpool/data]' "$AP/jobs.conf" \
        && printf '%s\n' "$new_render" | grep -q 'delsnaps\.sh.*"zfsbackup@10.7.7.1:rpool/data"' \
        && [ "$inst_src_after" = "$inst_src_before" ] \
        && printf '%s' "$inst_src_before" | grep -qF '10.7.7.1'; then
    ok "57b step5 (F4): --apply adds a bounded source prune and leaves [dataset:] src topology byte-identical"
else
    bad "57b step5 (F4): --apply adds a bounded source prune and leaves [dataset:] src topology byte-identical" \
        "rc=$rc src_before=[$inst_src_before] src_after=[$inst_src_after] hassrcprune=$(grep -cF '[prune:zfsbackup@10.7.7.1:rpool/data]' "$AP/jobs.conf")"
fi

# --- 58. REV-20260811-108: the audit must NOT take source-retention ownership of a
#     PASSIVE external-snapshot relationship (installed transfer flags carry -e). Such a
#     relationship consumes externally-owned snapshots; adding a source prune would take
#     destructive ownership. It must be reported as intentionally outside ownership,
#     never entered into the "missing" set, and --apply must leave it byte-identical
#     with no destroy-grant requirement. ---
A8="$WORK/audit8"; mkdir -p "$A8/clients"
cat > "$A8/clients/p1.conf" <<'EOF'
CLIENT_NAME=p1
STATE=active
PEER_SAVED_DATASETS=rpool/data
PEER_SAVED_MODE=backup
PEER_SAVED_TARGET=tank/backups
EOF
GC8="$A8/gencron-stub.sh"; cp "$GC5" "$GC8" 2>/dev/null || { printf '#!/usr/bin/env bash\ncat "$GENCRON_RENDER"\n' > "$GC8"; }
chmod +x "$GC8"
A8_RENDER="$A8/render.crontab"; : > "$A8_RENDER"   # no source delsnaps rendered
# passive [dataset:] -- transfer flags carry -e -- and NO source prune
write_a8() {  # <flags line value>
    cat > "$A8/jobs.conf" <<EOF
[defaults]
	host_label = h
[dataset:tank/backups/p1/rpool/data]
	# managed-by: zfs-backup.sh client=p1
	use_template = profile__default__standard_hourly
	src          = zfsbackup@10.6.6.6:rpool/data
	flags        = $1
	pair_label   = p1
	notify       = p1-data
[prune:tank/backups/p1]
	# managed-by: zfs-backup.sh client=p1
	use_template = profile__default__keep_hourly
	gfs          = yes
	gfs_pattern  = automated_
	recursive    = yes
	pair_label   = p1
	notify       = p1
EOF
}
audit8() {  # <--apply?> : runs the audit against the passive fixture
    GENCRON_RENDER="$A8_RENDER" bash -c "source '$ZFSBACKUP'
        read_server_conf() { CRON_CONFIG='$A8/jobs.conf'; }
        load_client_and_connection() { LOAD_ACCOUNT=zfsbackup; LOAD_HOST=10.6.6.6; LOAD_PORT=22; LOAD_KEYFILE=/dev/null; LOAD_ALIAS=a; LOAD_ALIAS_KH=/dev/null; LOAD_LABEL=p1; }
        assert_source_prune_grant() { echo GRANT-CALLED >&2; return 0; }
        GENCRON='$GC8' CLIENTS_DIR='$A8/clients' SCRIPT_DIR='$A8' cmd_audit_source_retention ${1:-}" 2>&1
}
# 1. passive (-e) relationship is reported outside ownership, NOT missing, read-only
write_a8 "-e -K /dev/null"
md5_before="$(md5sum "$A8/jobs.conf" | awk '{print $1}')"
out="$(audit8)"; rc=$?
md5_after="$(md5sum "$A8/jobs.conf" | awk '{print $1}')"
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -q 'pasywne (-e, poza wlasnoscia):      1' \
        && printf '%s' "$out" | grep -q 'bez ograniczonej retencji zrodla:   0' \
        && printf '%s' "$out" | grep -qi 'poza wlasnoscia retencji zrodla' \
        && [ "$md5_before" = "$md5_after" ]; then
    ok "58 REV-108: a passive (-e) source is reported outside ownership, not missing (read-only)"
else
    bad "58 REV-108: a passive (-e) source is reported outside ownership, not missing" "rc=$rc md5eq=$([ "$md5_before" = "$md5_after" ] && echo y || echo N) out=$out"
fi
# 2. --apply on a passive-only config touches nothing and never invokes the grant check
md5_before="$(md5sum "$A8/jobs.conf" | awk '{print $1}')"
out="$(audit8 --apply)"; rc=$?
md5_after="$(md5sum "$A8/jobs.conf" | awk '{print $1}')"
if [ "$rc" -eq 0 ] \
        && [ "$md5_before" = "$md5_after" ] \
        && ! printf '%s' "$out" | grep -q 'GRANT-CALLED'; then
    ok "58 REV-108: --apply leaves a passive relationship byte-identical, no destroy-grant check"
else
    bad "58 REV-108: --apply leaves a passive relationship byte-identical, no destroy-grant check" "rc=$rc md5eq=$([ "$md5_before" = "$md5_after" ] && echo y || echo N) out=$out"
fi
# 3. NEGATIVE CONTROL (evidence #4): the SAME fixture WITHOUT -e is a managed relationship
#    and IS flagged missing -- proving the -e flag is the discriminator, not the shape.
write_a8 "-K /dev/null"
out="$(audit8)"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -q 'pasywne (-e, poza wlasnoscia):      0' \
        && printf '%s' "$out" | grep -q 'bez ograniczonej retencji zrodla:   1' \
        && printf '%s' "$out" | grep -qF '[prune:zfsbackup@10.6.6.6:rpool/data]'; then
    ok "58 REV-108: the same relationship WITHOUT -e is managed and flagged missing (discriminator control)"
else
    bad "58 REV-108: the same relationship WITHOUT -e is managed and flagged missing" "rc=$rc out=$out"
fi

# --- 59. REV-20260811-110: managed-prefix lookup must be relationship-EXACT ---
#
# managed_source_prefix_for_scope must associate a scope with ITS OWN snapget -m prefix
# via an exact quoted-argument match, not a substring test. Two neighbouring scopes
# where one is a textual prefix of the other (rpool/data vs rpool/data2) must not
# cross-associate -- with the colliding neighbour rendered FIRST, a substring test
# deterministically picks the wrong prefix. Pure helper-level check (L0).
R110="$WORK/rev110.render"
cat > "$R110" <<'EOF'
0 * * * * /x/snapget.sh -m "other_" -A -L b "zfsbackup@10.5.5.5:rpool/data2" tank/backups/b/rpool/data2
0 * * * * /x/snapget.sh -m "automated_hourly_" -A -L a "zfsbackup@10.5.5.5:rpool/data" tank/backups/a/rpool/data
30 * * * * e=$(mktemp); /x/delsnaps.sh -G "zfsbackup@10.5.5.5:rpool/data2" "other_" -H24 2>"$e"
EOF
p_data="$( ( source "$ZFSBACKUP"; managed_source_prefix_for_scope "$R110" "zfsbackup@10.5.5.5:rpool/data" ) )"
p_data2="$( ( source "$ZFSBACKUP"; managed_source_prefix_for_scope "$R110" "zfsbackup@10.5.5.5:rpool/data2" ) )"
if [ "$p_data" = "automated_hourly_" ] && [ "$p_data2" = "other_" ]; then
    ok "59 REV-110: each scope is associated with its OWN -m prefix (exact, not substring)"
else
    bad "59 REV-110: each scope is associated with its OWN -m prefix (exact, not substring)" "data=[$p_data] data2=[$p_data2]"
fi
# evidence #5: a delsnaps that bounds ONLY the neighbour (data2/other_) must NOT make the
# requested relationship (data/automated_hourly_) safe; data2 itself IS bounded.
data_bounded=no; data2_bounded=no
( source "$ZFSBACKUP"; source_scope_is_bounded "$R110" "zfsbackup@10.5.5.5:rpool/data" ) && data_bounded=yes
( source "$ZFSBACKUP"; source_scope_is_bounded "$R110" "zfsbackup@10.5.5.5:rpool/data2" ) && data2_bounded=yes
if [ "$data_bounded" = no ] && [ "$data2_bounded" = yes ]; then
    ok "59 REV-110: a prune bounding only the neighbour does not make the requested relationship safe"
else
    bad "59 REV-110: a prune bounding only the neighbour does not make the requested relationship safe" "data_bounded=$data_bounded data2_bounded=$data2_bounded"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
