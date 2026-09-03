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

# Hermetic ssh. This suite's header promises "no network", but several SUT
# functions shell out to `ssh`, and the fixtures point them at unroutable
# addresses (peer.example, 10.x, 192.168.x). A bare ssh to one of those does not
# fail fast: on a CI runner the SYN goes nowhere and the call blocks on the
# kernel's connect timeout (~127s each, since most call sites carry no explicit
# ConnectTimeout). That is what made this leg take 34 minutes on CI while it
# finishes in a few on a laptop, where ssh to the same dead address returns
# almost at once. A global stub makes any UNSTUBBED ssh fail immediately with
# 255 -- "could not connect", the exact result an unreachable host produces,
# only without the wait. Tests that need ssh to behave differently prepend their
# own stub (13 of them do), which still wins on PATH; nothing here can rely on a
# bare ssh SUCCEEDING, because no fixture address is reachable. Exported so the
# `( ... )` subshells and `bash -c` re-sources below inherit it.
_GLOBAL_STUBBIN="$WORK/_ssh_stub"; mkdir -p "$_GLOBAL_STUBBIN"
printf '#!/bin/sh\nexit 255\n' > "$_GLOBAL_STUBBIN/ssh"
chmod +x "$_GLOBAL_STUBBIN/ssh"
export PATH="$_GLOBAL_STUBBIN:$PATH"

# profile_release_tmp: this suite SOURCES zfs-backup.sh, so any profile it loads
# in this very shell (rather than in one of the `( ... )` subshells below) is
# this shell's to release -- zfs-backup.sh arms its own EXIT trap only in the
# shell that rendered the profile, and will not displace the trap of a consumer
# that sourced it. Defined later in the file; by EXIT it exists.
trap 'profile_release_tmp; rm -rf "$WORK"' EXIT
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
    ""|retention|57|58|59|102|108|110|122) ;;
    *) echo "unknown --section '$ONLY_SECTION' (known: retention | 57 | 58 | 59 | 102 | 108 | 110 | 122)" >&2; exit 2 ;;
esac

# Everything from here to the retention group is full-suite-only: skipped under a
# targeted --section run. The retention group (below the matching `fi`) is self-
# contained and always eligible.
# The profile-fixture helpers live ABOVE the full-suite-only guard, because the
# self-contained group below it calls them. They were inside it until
# 2026-08-27, so every targeted `--section` run died at the first call with
# `mkprof_copy: command not found` and never reached the sections it had been
# asked for -- the L0 execution REV-109 built, silently unusable.

mkprof_copy() {   # <target profile, without the .conf>
    mkdir -p "$(dirname "$1")"
    cp "$REPO/profiles/default.conf" "$1.conf"
}
mkprof_add() {    # <target profile dir> <section header> <line>
    awk -v want="$2" -v add="$3" '
        { print }
        $0 == want && !done { print add; done=1 }
    ' "$1.conf" > "$1.conf.new" && mv "$1.conf.new" "$1.conf"
}

if [ -z "$ONLY_SECTION" ]; then

# --- 1. client_name_valid ----------------------------------------------------
for good in pve2 metropolis-pve1 client.1 a_b; do
    if client_name_valid "$good"; then ok "client_name_valid accepts '$good'"; else bad "client_name_valid accepts '$good'" "rejected"; fi
done
for bad_name in "" "pve2/x" "pve2 x" 'pve2;rm' "pve2\`id\`"; do
    if client_name_valid "$bad_name"; then bad "client_name_valid rejects '$bad_name'" "accepted"; else ok "client_name_valid rejects '$bad_name'"; fi
done

# --- 1b. simple two-server public flow ---------------------------------------
# add-client's ordinary form accepts --host and injects mode=backup itself.
# This drives the real command function with only deploy.sh stubbed: no root,
# network or ZFS, but the exact package-building arguments and durable client
# record are observed.
SF="$WORK/simpleflow"; mkdir -p "$SF/clients" "$SF/relationships" "$SF/pve-nodes"
SF_DEPLOY="$SF/deploy-stub.sh"
cat > "$SF_DEPLOY" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SIMPLE_FLOW_PAIR_LOG"
exit 0
EOF
chmod +x "$SF_DEPLOY"
export SIMPLE_FLOW_PAIR_LOG="$SF/pair.log"
out="$( (
    profile_validate_file() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
    CLIENTS_DIR="$SF/clients"
    RELATIONSHIPS_DIR="$SF/relationships"
    PVE_NODES_DIR="$SF/pve-nodes"
    DEPLOY="$SF_DEPLOY"
    cmd_add_client pve2 --host=192.168.28.8:22 --target=hdd/backups
) 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
        && grep -q -- '--peer=192.168.28.8' "$SF/pair.log" \
        && grep -q -- '--mode=backup' "$SF/pair.log" \
        && grep -q '^STATE=pending_enroll$' "$SF/clients/pve2.conf" \
        && grep -qF 'ACTIVE_ENDPOINT=192.168.28.8:22' "$SF/clients/pve2.conf"; then
    ok "simple flow: add-client --host defaults to backup and writes pending relationship"
else
    bad "simple flow: add-client --host defaults to backup and writes pending relationship" "rc=$rc out=$out pair=$(cat "$SF/pair.log" 2>/dev/null) record=$(cat "$SF/clients/pve2.conf" 2>/dev/null)"
fi

# A NAME MUST BE REUSABLE AFTER THE RELATIONSHIP IS REMOVED.
#
# Found live on 2026-08-23 while running the four-command trial of issue #9 a
# second time. remove-client deliberately KEEPS the client record and appends
# STATE=removed -- that file is the relationship's own history. add-client
# refused on the file's mere EXISTENCE, so after a completely clean teardown
# (cron gone, config sections gone, keys gone, peer account deleted, zero zfs
# allow entries) the very next step of the documented lifecycle refused, and
# told the operator to run "remove-client" -- the command they had just run,
# which would have changed nothing.
#
# Every other scanner in zfs-backup.sh already skips STATE=removed records.
# These cases pin add-client agreeing with them, and pin the two halves that
# must NOT change: a live record still refuses, and the archived tombstone is
# not visible to anything globbing *.conf.
sf_live_conf="$SF/clients/pve2.conf"
printf 'STATE=removed\nREMOVED_AT="2026-08-23 09:46:13"\n' >> "$sf_live_conf"
: > "$SF/pair.log"
out="$( (
    profile_validate_file() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
    CLIENTS_DIR="$SF/clients"
    RELATIONSHIPS_DIR="$SF/relationships"
    PVE_NODES_DIR="$SF/pve-nodes"
    DEPLOY="$SF_DEPLOY"
    cmd_add_client pve2 --host=192.168.28.8:22 --target=hdd/backups
) 2>&1)"; rc=$?
sf_arch=$(ls "$SF/clients"/pve2.conf.removed-* 2>/dev/null | head -1)
if [ "$rc" -eq 0 ] && [ -n "$sf_arch" ]         && grep -q '^STATE=pending_enroll$' "$sf_live_conf"         && ! grep -q '^STATE=removed$' "$sf_live_conf"         && grep -q '^STATE=removed$' "$sf_arch"; then
    ok "lifecycle: a name whose relationship was removed can be used again"
else
    bad "lifecycle: a name whose relationship was removed can be used again"         "rc=$rc arch=${sf_arch:-BRAK}" "out=$out"
fi

# The tombstone is ARCHIVED, not deleted -- and must not be picked up as a live
# record by anything scanning "$CLIENTS_DIR"/*.conf.
sf_confs=$(ls "$SF/clients"/*.conf 2>/dev/null | wc -l)
if [ "$sf_confs" -eq 1 ] && [ -s "${sf_arch:-/nonexistent}" ]; then
    ok "lifecycle: the removed record is archived out of the *.conf namespace, not deleted"
else
    bad "lifecycle: the removed record is archived out of the *.conf namespace, not deleted"         "plikow *.conf=$sf_confs archiwum=${sf_arch:-BRAK}"
fi

# The other half. CONTRACT CHANGE 2026-08-24 (issue #9: "rerun resumes from
# durable state"): repeating add-client on a relationship that already exists
# is no longer a refusal by itself -- an interrupted flow must be replayable
# from step 1. What it still must not do is REDEFINE a live relationship, so
# the refusal moved from "the record exists" to "the record says something
# else", and both halves are asserted here.
addc() {   # <host> <target> -> combined output, rc in $rc
    out="$( (
        profile_validate_file() { return 0; }
        read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
        CLIENTS_DIR="$SF/clients"
        RELATIONSHIPS_DIR="$SF/relationships"
        PVE_NODES_DIR="$SF/pve-nodes"
        DEPLOY="$SF_DEPLOY"
        cmd_add_client pve2 --host="$1" --target="$2"
    ) 2>&1)"; rc=$?
}

addc 192.168.28.8:22 hdd/backups
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "nothing to create"; then
    ok "lifecycle: an IDENTICAL add-client rerun resumes instead of refusing"
else
    bad "lifecycle: an IDENTICAL add-client rerun resumes instead of refusing" "rc=$rc out=$out"
fi

addc 192.168.28.99:22 hdd/backups
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "already exists"         && printf '%s' "$out" | grep -q "pending_enroll"         && printf '%s' "$out" | grep -q "DIFFERENT"; then
    ok "lifecycle: a rerun REDEFINING a live relationship still refuses, naming its state"
else
    bad "lifecycle: a rerun REDEFINING a live relationship still refuses, naming its state" "rc=$rc out=$out"
fi

# A PINNED HOST KEY MUST BE FILED UNDER THE NAME ssh ACTUALLY ASKS FOR.
#
# With HostKeyAlias set, OpenSSH looks the key up under the alias ALONE -- it
# does not append the port the way it does for a real hostname. This function
# used to write "[alias]:port" whenever the port was not 22, so every endpoint
# on a non-default port failed "Host key verification failed" with the correct
# key sitting in the file. Port 22 was unaffected, which is why it survived
# until an endpoint switch to another port was tried (issue #9, second path,
# live on 2026-08-23).
#
# Asserted with ssh-keygen -F -- OpenSSH own known_hosts matcher, doing the
# same bare-name lookup ssh does. Grepping for a bracket would only pin the
# current spelling; this pins the property, and it fails on the old code
# because ssh-keygen genuinely cannot find a bracketed entry by bare name.
akh_dir="$WORK/aliaskh"; mkdir -p "$akh_dir"
akh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhkVkBbh0x3swx+notarealkey"
for akh_port in 22 2222; do
    printf 'peer.example %s\n' "$akh_key" > "$akh_dir/pv_known_hosts"
    akh_out=$( PEER_KEY_DIR="$akh_dir" LOCAL_USER="" ensure_alias_known_hosts pv "" "$akh_port" zfs-client-trial 2>/dev/null )
    if [ -z "$akh_out" ] || [ ! -s "$akh_out" ]; then
        bad "host key: a pinned alias is written for port $akh_port" "ensure_alias_known_hosts gave: ${akh_out:-BRAK}"
    elif ssh-keygen -F zfs-client-trial -f "$akh_out" >/dev/null 2>&1; then
        ok "host key: ssh own matcher finds the pinned alias on port $akh_port"
    else
        bad "host key: ssh own matcher finds the pinned alias on port $akh_port" "ssh-keygen -F nie znalazl w: $(cat "$akh_out")"
    fi
done



pair_lines_before=$(wc -l < "$SF/pair.log")
out="$( (
    profile_validate_file() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
    CLIENTS_DIR="$SF/clients-invalid"
    DEPLOY="$SF_DEPLOY"
    cmd_add_client badhost --host='bad;host' --target=hdd/backups
) 2>&1)"; rc=$?
pair_lines_after=$(wc -l < "$SF/pair.log")
if [ "$rc" -ne 0 ] && [ "$pair_lines_before" = "$pair_lines_after" ] \
        && printf '%s' "$out" | grep -q 'invalid endpoint host'; then
    ok "simple flow: an unsafe --host fails before pairing (no command-substitution fail-open)"
else
    bad "simple flow: an unsafe --host fails before pairing (no command-substitution fail-open)" "rc=$rc before=$pair_lines_before after=$pair_lines_after out=$out"
fi

# Stub only the child-process boundary used by cmd_activate. Each simulated
# low-level command commits the same durable state fact as its real counterpart,
# so the orchestrator must choose the correct next step by rereading the file.
simple_flow_activate() {   # <client-file> <requested-host?>
    local record="$1" host="${2:-}" logf="$3"
    (
        CLIENTS_DIR="$(dirname "$record")"
        activation_step() {
            local resume="$1"; shift
            printf '%s\n' "$*" >> "$logf"
            local cmd="$1"; shift
            local STATE="" ACTIVE_ENDPOINT=""; . "$record"
            case "$cmd" in
                final-catchup)
                    printf 'FINAL_CATCHUP_ENDPOINT=%s\nFINAL_CATCHUP_EPOCH=%s\n' \
                        "$ACTIVE_ENDPOINT" "$(date '+%s')" >> "$record" ;;
                set-endpoint)
                    local arg new=""
                    for arg in "$@"; do case "$arg" in --host=*) new="${arg#*=}" ;; esac; done
                    printf 'ACTIVE_ENDPOINT=%s\nSTATE=seed_complete\n' "$new" >> "$record" ;;
                verify-endpoint)
                    printf 'STATE=endpoint_verified\nENDPOINT_VERIFIED_FOR=%s\n' "$ACTIVE_ENDPOINT" >> "$record" ;;
                activate-client)
                    printf 'STATE=active\nINSTALLED_ENDPOINT=%s\n' "$ACTIVE_ENDPOINT" >> "$record" ;;
                *) return 99 ;;
            esac
        }
        if [ -n "$host" ]; then
            cmd_activate pve2 --host="$host" --yes
        else
            cmd_activate pve2 --yes
        fi
    )
}

cat > "$SF/clients/pve2.conf" <<'EOF'
CLIENT_NAME=pve2
PEER_HOST=192.168.28.8
ACTIVE_ENDPOINT=192.168.28.8:22
STATE=seed_complete
EOF
: > "$SF/activate-lan-vpn.log"
out="$(simple_flow_activate "$SF/clients/pve2.conf" vpn.example:2222 "$SF/activate-lan-vpn.log" 2>&1)"; rc=$?
want=$'final-catchup pve2 --yes\nset-endpoint pve2 --host=vpn.example:2222\nverify-endpoint pve2\nactivate-client pve2 --yes'
got="$(cat "$SF/activate-lan-vpn.log")"
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ] \
        && grep -q '^STATE=active$' "$SF/clients/pve2.conf" \
        && grep -q '^INSTALLED_ENDPOINT=vpn.example:2222$' "$SF/clients/pve2.conf"; then
    ok "simple flow: activate LAN-to-VPN owns catch-up, switch, verify and install"
else
    bad "simple flow: activate LAN-to-VPN owns catch-up, switch, verify and install" "rc=$rc got=[$got] out=$out record=$(cat "$SF/clients/pve2.conf")"
fi

before="$(cat "$SF/activate-lan-vpn.log")"
out="$(simple_flow_activate "$SF/clients/pve2.conf" vpn.example:2222 "$SF/activate-lan-vpn.log" 2>&1)"; rc=$?
after="$(cat "$SF/activate-lan-vpn.log")"
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then
    ok "simple flow: repeating completed activate is a no-op (no duplicate steps)"
else
    bad "simple flow: repeating completed activate is a no-op (no duplicate steps)" "rc=$rc before=[$before] after=[$after] out=$out"
fi

cat > "$SF/clients/pve2.conf" <<'EOF'
CLIENT_NAME=pve2
PEER_HOST=192.168.28.8
ACTIVE_ENDPOINT=192.168.28.8:22
STATE=seed_complete
EOF
: > "$SF/activate-same.log"
out="$(simple_flow_activate "$SF/clients/pve2.conf" "" "$SF/activate-same.log" 2>&1)"; rc=$?
got="$(cat "$SF/activate-same.log")"
want=$'verify-endpoint pve2\nactivate-client pve2 --yes'
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    ok "simple flow: same-endpoint activate skips catch-up/switch and completes"
else
    bad "simple flow: same-endpoint activate skips catch-up/switch and completes" "rc=$rc got=[$got] out=$out"
fi

if activation_is_new_relationship endpoint_verified "" \
        && ! activation_is_new_relationship endpoint_verified "192.168.28.8:22" \
        && ! activation_is_new_relationship active "192.168.28.8:22"; then
    ok "simple flow: endpoint re-verification does not regenerate installed policy as a new relationship"
else
    bad "simple flow: endpoint re-verification does not regenerate installed policy as a new relationship" "new/reactivation discriminator is wrong"
fi

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

# --- 3b. peer_manifest_path parity with deploy.sh (audit C1, 2026-08-21) -----
# The trust-mirror family is deliberately duplicated deploy.sh <-> zfs-backup.sh
# with no source edge -- and peer_manifest_path had slipped out of BOTH the
# deps.conf enumeration and this parity suite. The comparison is BEHAVIORAL,
# not textual: the first version of this pin diffed the source text and
# promptly failed on formatting (one-liner here, wrapped there) -- pinning
# whitespace is not the contract, where the manifest LIVES is.
dp_pmp_out=$(env PEER_STATE_DIR=/PIN bash -c '
    eval "$(sed -n "/^peer_manifest_path() {/,/^}/p" "$1")"
    peer_manifest_path some-label' _ "$(dirname "$ZFSBACKUP")/deploy.sh")
zb_pmp_out=$(PEER_STATE_DIR=/PIN peer_manifest_path some-label)
if [ -n "$zb_pmp_out" ] && [ "$zb_pmp_out" = "$dp_pmp_out" ]; then
    ok "peer_manifest_path: both programs resolve the same manifest path"
else
    bad "peer_manifest_path: both programs resolve the same manifest path"         "zb=[$zb_pmp_out] dp=[$dp_pmp_out]"
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
out=$( MANAGED_DATASETS='' MANAGED_PRUNE_SCOPE='' remove_managed_sections "$CF5" newclient tank/handwritten 2>&1 ); rc=$?
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
out=$( MANAGED_DATASETS='tank/legacy/pve2/data' MANAGED_PRUNE_SCOPE='' remove_managed_sections "$CF6" pve2 tank/legacy/pve2/data 2>&1 ); rc=$?
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
out=$( MANAGED_DATASETS='' MANAGED_PRUNE_SCOPE='' remove_managed_sections "$CF7" thisclient tank/shared 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"looks hand-written"*) true ;; *) false ;; esac; then
    ok "remove_managed_sections refuses a header match whose marker names a different client"
else
    bad "remove_managed_sections refuses a header match whose marker names a different client" "rc=$rc out=$out"
fi

# --- 5b. teardown must also strip the REMOTE source prune -------------------
# Found live (pve1<->pve2, 2026-08-14). remove-client stripped the client's
# [dataset:] and target [prune:] sections but left the remote source prune --
# a [prune:<account@host:ds>] section it had written itself. MANAGED_DATASETS and
# MANAGED_PRUNE_SCOPE both record TARGET paths, and a source scope is an endpoint,
# so remove_managed_sections was never told about it.
#
# The consequence was not a leftover line but a LOOP: the next step regenerated
# cron from the uncleaned config and reinstalled the job, then --unpair refused
# because of the line the removal had just recreated. The documented remedy could
# not be followed either -- strip the section, and if it was the last rule,
# gen-cron refuses to install an empty ruleset.
#
# Pinned as a PAIR: the client's own remote prune goes, a foreign one stays. A
# teardown that removed every remote prune would pass the first half and quietly
# delete another client's source retention.
CF5B="$WORK/jobs.srcprune.conf"
cat > "$CF5B" <<'EOF'
[defaults]
	host_label = x

[dataset:hdd/backups/pve2/rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	src = zfsbackup-pve2@10.0.0.2:rpool/data

[prune:hdd/backups/pve2]
	# managed-by: zfs-backup.sh client=pve2
	pattern = automated_
	retain = -H24

[prune:zfsbackup-pve2@10.0.0.2:rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	pattern = automated_
	retain = -H24

[prune:zfsbackup-other@10.0.0.9:tank/x]
	# managed-by: zfs-backup.sh client=other
	pattern = automated_
	retain = -H24
EOF

# The capture half had the same same-statement `local ... marker=...$name`
# defect as removal, but its ordinary caller also had `name=pve2` in scope and
# therefore hid it. Deliberately give the CALLER the wrong name: only the
# function argument may choose which policy is preserved.
name="other"
capture_client_remote_source_prunes "$CF5B" "pve2"
unset name
if [ -n "${SOURCE_PRUNE_PRESERVED[rpool/data]+present}" ] \
   && [ -z "${SOURCE_PRUNE_PRESERVED[tank/x]+present}" ] \
   && printf '%s\n' "${SOURCE_PRUNE_PRESERVED[rpool/data]}" \
        | grep -qF '# managed-by: zfs-backup.sh client=pve2'; then
    ok "capture source prune uses its argument, not a different caller-scope name"
else
    bad "capture source prune uses its argument, not a different caller-scope name" \
        "keys=${!SOURCE_PRUNE_PRESERVED[*]}"
fi

remove_managed_sections "$CF5B" "pve2" "hdd/backups/pve2/rpool/data" "hdd/backups/pve2"
remove_client_remote_source_prunes "$CF5B" "pve2"
if ! grep -q '^\[prune:zfsbackup-pve2@10.0.0.2:rpool/data\]$' "$CF5B" \
   && grep -q '^\[prune:zfsbackup-other@10.0.0.9:tank/x\]$' "$CF5B" \
   && ! grep -q '^\[dataset:hdd/backups/pve2/rpool/data\]$' "$CF5B"; then
    ok "teardown strips the client's own remote source prune and leaves a foreign one"
else
    bad "teardown strips the client's own remote source prune and leaves a foreign one" "$(grep '^\[' "$CF5B" | tr '\n' ' ')"
fi

# --- Batch B: the account is an explicit per-relationship choice -------------
#
# Owner decision (2026-08-19): the account a relationship's jobs run as is stated
# on the command, not resolved from a host-wide file. --local-user=NAME delegates
# to any account (root, zfsbackup, bkp, ...); OMITTING it means root. There is no
# server.conf account, no adopted account, no guessing -- the choice travels WITH
# the relationship (manifest + client record). This replaced the earlier
# "resolve/adopt/refuse" contract, whose magic was exactly what the account
# refactor removed.
#
# The cases assert the rule as a set: root by default, any account by name, root
# by name, and an invalid name refused -- because a build that only handles one
# of them passes some and fails the rest.
BB="$WORK/batchb"; mkdir -p "$BB"
cat > "$BB/deploy.sh" <<'EOF'
#!/bin/bash
# Records what add-client asked deploy.sh --pair for, so the ACCOUNT that reaches
# the pairing (keys, host key, target delegation) is asserted rather than assumed.
printf '%s\n' "$*" > "$BB_PAIRLOG"
exit 0
EOF
chmod +x "$BB/deploy.sh"

# Extra arguments are passed as ARGUMENTS to bash -c, not spliced into its script
# text. Splicing looked equivalent and was not: an argument like
# `--local-user=2bad; rm -rf /` -- which is precisely one of the cases under test
# -- stops being one word the moment it is pasted into a script body, so the
# invalid-name case never reached the code it was written to exercise, and the
# override case lost its quoting too. The two failures that caught this were mine,
# in the harness, not in the product.
# Each case below is an independent "command one" on a fresh collector, so the
# collector is reset here rather than in individual cases. Sharing one client name
# across the four without resetting is what made cases 2 and 5 fail: case 1 created
# bbc, so every later case died on "client 'bbc' already exists" long before it
# reached the account logic it was written to exercise -- and cases 3/3b passed only
# because case 3 happened to clear the directory first. That is a harness fault that
# reports as a product fault, which is the expensive kind.
bb_add() {   # <stub LOCAL_USER value> [extra add-client args...]
    local acct="$1"; shift
    rm -f "$BB/pair.log"
    rm -rf "$BB/clients"
    BB_PAIRLOG="$BB/pair.log" bash -c '
        source "$1" 2>/dev/null
        DEPLOY="$2"; CLIENTS_DIR="$3"
        acct="$4"; shift 4
        read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="$acct"; }
        cmd_add_client bbc --host=10.9.9.9:22 --target=tank/bb "$@"
    ' _ "$ZFSBACKUP" "$BB/deploy.sh" "$BB/clients" "$acct" "$@" 2>&1
}

# 1. NO --local-user: the jobs run as ROOT. Bare add-client passes NO account to
#    the pairing whatever a server.conf might hold -- root is the honest default,
#    named nowhere and guessed nowhere -- and still creates the client.
out="$(bb_add zfsbackup)"
if [ -f "$BB/pair.log" ] && ! grep -q -- '--local-user=' "$BB/pair.log" 2>/dev/null && [ -d "$BB/clients" ]; then
    ok "Batch B: bare add-client runs as root (no --local-user passed) and still creates the client"
else
    bad "Batch B: bare add-client runs as root (no --local-user passed) and still creates the client" \
        "pair args: $(cat "$BB/pair.log" 2>/dev/null) out: $(printf '%s' "$out" | tail -1)"
fi

# 2. EXPLICIT OVERRIDE beats the configured value -- the expert escape hatch the
#    contract keeps.
out="$(bb_add zfsbackup --local-user=otheracct)"
if grep -q -- '--local-user=otheracct' "$BB/pair.log" 2>/dev/null; then
    ok "Batch B: --local-user overrides the configured account"
else
    bad "Batch B: --local-user overrides the configured account" "pair args: $(cat "$BB/pair.log" 2>/dev/null)"
fi

# 3. ARBITRARY account: any name is delegated and passed through (created if new).
#    The package is not limited to one blessed account -- this is what makes
#    --local-user=NAME a real choice rather than a root/zfsbackup toggle.
out="$(bb_add "" --local-user=bkp)"
if grep -q -- '--local-user=bkp' "$BB/pair.log" 2>/dev/null && [ -d "$BB/clients" ]; then
    ok "Batch B: --local-user=bkp delegates the jobs to an arbitrary account"
else
    bad "Batch B: --local-user=bkp delegates the jobs to an arbitrary account" \
        "pair args: $(cat "$BB/pair.log" 2>/dev/null) out: $(printf '%s' "$out" | tail -1)"
fi

# 3b. ROOT IS STILL REACHABLE, but only by saying so. Without this the guard above
#     would be indistinguishable from "root is now forbidden", which is not the
#     contract -- root must stop being a DEFAULT, not stop being possible.
out="$(bb_add "" --local-user=root)"
if [ -f "$BB/pair.log" ] && ! grep -q -- '--local-user=' "$BB/pair.log"; then
    ok "Batch B: --local-user=root is accepted and passes no account through (root by choice)"
else
    bad "Batch B: --local-user=root is accepted and passes no account through (root by choice)" \
        "pair args: $(cat "$BB/pair.log" 2>/dev/null) out: $(printf '%s' "$out" | tail -1)"
fi

# 4. INVALID ACCOUNT NAME refuses on the spot rather than reaching deploy.sh with
#    something that cannot be a user.
rm -f "$BB/pair.log"
out="$(bb_add zfsbackup --local-user='2bad; rm -rf /')"
if printf '%s' "$out" | grep -q 'is not a valid account name' && [ ! -f "$BB/pair.log" ]; then
    ok "Batch B: an invalid account name refuses before pairing"
else
    bad "Batch B: an invalid account name refuses before pairing" "$(printf '%s' "$out" | tail -1)"
fi

# PR #14 F1. The expert fallback is conditional because every client shares one
# managed cron block. An unconditional "then remove the block" stops the jobs of
# every client whose rules remain in the config.
unpair_body=$(awk '/^unpair_assert_no_cron_users\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$REPO/deploy.sh")
if printf '%s\n' "$unpair_body" | grep -qF "On the collector, use 'zfs-backup.sh remove-client <name>'" \
   && printf '%s\n' "$unpair_body" | grep -qF "If any dataset/prune/monitor rules remain" \
   && printf '%s\n' "$unpair_body" | grep -qF "Only if zero rules remain" \
   && ! printf '%s\n' "$unpair_body" | grep -qF "FIRST, then remove the managed block"; then
    ok "unpair remedy reinstalls remaining clients and removes the whole block only at zero rules"
else
    bad "unpair remedy reinstalls remaining clients and removes the whole block only at zero rules" \
        "$(printf '%s\n' "$unpair_body" | tail -12)"
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
out="$( PATH="$STUBDIR:$PATH" assert_cron_config_matches_installed "$REPO/jobs.pve0.v4.conf" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "assert_cron_config_matches_installed: same file, relative source resolved against \$SCRIPT_DIR, passes"
else
    bad "assert_cron_config_matches_installed: same file, relative source resolved against \$SCRIPT_DIR, passes" "rc=$rc out=$out"
fi

out="$( PATH="$STUBDIR:$PATH" assert_cron_config_matches_installed "/root/other/jobs.pve0.v4.conf" 2>&1 )"; rc=$?
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
out="$( PATH="$STUBDIR:$PATH" assert_cron_config_matches_installed "/anything.conf" 2>&1 )"; rc=$?
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
alias_out=$( PEER_KEY_DIR="$KHDIR" ensure_alias_known_hosts 192.168.11.11 '' 22 zfs-client-pve2 )
if [ -f "$alias_out" ] && grep -q '^zfs-client-pve2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest$' "$alias_out"         && ssh-keygen -F zfs-client-pve2 -f "$alias_out" >/dev/null 2>&1; then
    ok "ensure_alias_known_hosts (port 22) writes an alias-keyed known_hosts under the STABLE alias, and ssh can find it"
else
    bad "ensure_alias_known_hosts (port 22) writes an alias-keyed known_hosts under the STABLE alias" "alias_out=$alias_out content=$(cat "$alias_out" 2>&1)"
fi

# THIS ASSERTION USED TO REQUIRE THE OPPOSITE, AND IT WAS WRONG.
#
# It demanded '[alias]:2222' for a non-default port -- the notation known_hosts
# uses for a real HOSTNAME on a non-default port. But when HostKeyAlias is set,
# OpenSSH looks the key up under the alias ALONE and never appends the port, so
# the pinned key was filed under a name ssh does not ask for and every
# non-default-port endpoint failed "Host key verification failed" with the
# right key in the file. Port 22 was unaffected, so nothing noticed until an
# endpoint switch to another port was tried live (issue #9, 2026-08-23):
#
#   bracketed entry, real connection to :2222   -> Host key verification failed
#   same key, same port, entry without the port -> connects, reads the scope
#
# The old case tested the SPELLING and passed while the product could not
# connect. Both cases now ask ssh-keygen -F -- OpenSSH's own known_hosts
# matcher, doing the same bare-name lookup ssh does -- so what is pinned is
# that ssh can FIND the key, for either port.
alias_out2=$( PEER_KEY_DIR="$KHDIR" ensure_alias_known_hosts 192.168.11.11 '' 2222 zfs-client-pve2 )
if [ -f "$alias_out2" ] && ssh-keygen -F zfs-client-pve2 -f "$alias_out2" >/dev/null 2>&1; then
    ok "ensure_alias_known_hosts (non-default port): ssh's own matcher finds the pinned alias"
else
    bad "ensure_alias_known_hosts (non-default port): ssh's own matcher finds the pinned alias" "alias_out2=$alias_out2 content=$(cat "$alias_out2" 2>&1)"
fi

rc=0
out="$( PEER_KEY_DIR="$KHDIR" ensure_alias_known_hosts nosuchclient '' 22 zfs-client-nope 2>&1 )" || rc=$?
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

out="$( ACTIVE_ENDPOINT=vpn ENDPOINT_VPN_HOST=10.8.0.11 ENDPOINT_VPN_PORT=2222; active_endpoint_host_port 2>&1 )"
if [ "$out" = "10.8.0.11 2222" ]; then
    ok "active_endpoint_host_port resolves a LEGACY (slot-named) endpoint's host/port"
else
    bad "active_endpoint_host_port resolves a LEGACY (slot-named) endpoint's host/port" "out=$out"
fi

# REV-20260802-033 U9: a new-shape record carries the literal "host:port" in
# ACTIVE_ENDPOINT directly, no slot indirection -- distinguished from the
# legacy shape purely by the presence of ':' (never valid in a bare hostname).
out="$( ACTIVE_ENDPOINT=10.8.0.11:2222; active_endpoint_host_port 2>&1 )"
if [ "$out" = "10.8.0.11 2222" ]; then
    ok "active_endpoint_host_port resolves a NEW-shape (literal host:port) endpoint (U9)"
else
    bad "active_endpoint_host_port resolves a NEW-shape (literal host:port) endpoint (U9)" "out=$out"
fi

out="$( ACTIVE_ENDPOINT=10.8.0.11:2222 LOAD_HOST=10.8.0.11 LOAD_PORT=2222; endpoint_display 2>&1 )"
if [ "$out" = "10.8.0.11:2222" ]; then
    ok "endpoint_display shows a bare host:port for a new-shape record (nothing extra to add)"
else
    bad "endpoint_display shows a bare host:port for a new-shape record" "out=$out"
fi
out="$( ACTIVE_ENDPOINT=vpn LOAD_HOST=10.8.0.11 LOAD_PORT=2222; endpoint_display 2>&1 )"
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

# The digest is not a relationship's job and gen-cron no longer writes one.
#
# This test used to assert the opposite -- that `digest_script=none` suppressed
# the line and the default emitted exactly one -- and that contract is what left
# pve9 silent on 2026-08-22: 15 findings queued since the previous day with
# `alert-digest` in ZERO crontabs. There is ONE digest per host, run by root,
# reading the queue BOTH accounts write; a delegated account correctly declines
# it. On a host whose only relationship lives in that account, nobody is left to
# schedule it. The digest moved to deploy.sh's `zfs-backup-host` block, beside
# the capacity check and the auto-pull, where it does not depend on who owns a
# relationship. So: NO digest line from the generator, whatever digest_script
# says -- including the default, which is the case that used to emit one.
for dsv in none "" /root/scripts/alert-digest.sh; do
    n=$(DIGEST_SCRIPT="$dsv" bash "$REPO/gen-cron.sh" -c "$PROF/gen.conf" 2>&1 | grep -c "alert-digest")
    [ "$n" = 0 ] || break
done
if [ "$n" = 0 ]; then
    ok "local-user: gen-cron emits no digest line at all (it is a host-level job now)"
else
    bad "local-user: gen-cron emits no digest line at all (it is a host-level job now)"         "digest_script='$dsv' wyemitowal $n linii"
fi

# ...and deploy.sh is the one that installs it, into the host block, by ADOPT --
# so a host with no relationship in root's crontab still gets a digest, and a
# host that already had a loose line keeps its schedule instead of gaining a
# second line. Source-grep: the behaviour is a cron write on a live host.
if grep -q 'cron_block_adopt_line root "\$CRON_HOST_BLOCK" "\$DIGEST_SCRIPT"' "$REPO/deploy.sh"; then
    ok "digest is installed as a host-level job by deploy.sh (adopt, not ensure)"
else
    bad "digest is installed as a host-level job by deploy.sh (adopt, not ensure)"         "brak cron_block_adopt_line dla DIGEST_SCRIPT w deploy.sh"
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

out=$( PATH="$SRC/bin:$PATH" LOCAL_USER="" ensure_cron_config "$SRC/gone.conf" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SRC/gone.conf" ]    && case "$out" in *"replace 2 live cron line"*) true ;; *) false ;; esac; then
    ok "src-guard: refuses to create the config the installed block came from, and counts what is at stake"
else
    bad "src-guard: refuses to create the config the installed block came from, and counts what is at stake" "rc=$rc created=$([ -e "$SRC/gone.conf" ] && echo tak || echo nie) out=$out"
fi

# A DIFFERENT path is not the claimed one, so creating it stays allowed --
# otherwise a host could never gain a second config at all.
out=$( PATH="$SRC/bin:$PATH" LOCAL_USER="" ensure_cron_config "$SRC/other.conf" 2>&1 ); rc=$?
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
# Truncate at the ENGINE's own redirect, not at the first ' 2>' on the line:
# since the ZFS-JOB markers landed, the wrapper carries an earlier
# ' 2>/dev/null' inside e=$(mktemp ...), and cutting there leaves the BEGIN
# label as the last quoted field -- so this read the notify label as the local
# base and compared it against a dataset path.
gencron_base=$(bash "$REPO/gen-cron.sh" -c "$WORK/parity.conf" 2>/dev/null | awk '/snapget/{sub(/ 2>"[$]e".*/,""); n=split($0,a,"\""); print a[n-1]; exit}')
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
   && case "$out" in *"clear root's managed block"*) true ;; *) false ;; esac; then
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
     | job_identity)
jb=$(printf '%s\n' '9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "t/a" "p" -H24 2>>/home/zfsbackup/cron.log' \
     | job_identity)
jc=$(printf '%s\n' '9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh "t/a" "p" -H48 2>>/home/zfsbackup/cron.log' \
     | job_identity)
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

out=$( PATH="$RD/bin:$PATH" LOCAL_USER="zfsbackup" assert_config_readable_by_target "$RD/unreachable.conf" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"cannot read"*) true ;; *) false ;; esac \
   && case "$out" in *"/etc/zfs-snapshot-all/"*) true ;; *) false ;; esac; then
    ok "readable: an unreadable config is refused, and a working location is named"
else
    bad "readable: an unreadable config is refused, and a working location is named" "rc=$rc out=$out"
fi

out=$( PATH="$RD/bin:$PATH" LOCAL_USER="zfsbackup" assert_config_readable_by_target "$RD/ok/reachable.conf" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "readable: a config the account can open passes" \
                || bad "readable: a config the account can open passes" "rc=$rc out=$out"

# As root the question does not arise, and the check must not invent one.
out=$( PATH="$RD/bin:$PATH" LOCAL_USER="" assert_config_readable_by_target "$RD/unreachable.conf" 2>&1 ); rc=$?
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
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\n' "$RC" > "$RC/server.conf"
: > "$RC/jobs.conf"
# The account is a field of the RELATIONSHIP record now, not server.conf.
printf 'STATE=active\nMANAGED_DATASETS="tank/a"\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=zfsbackup\n' "$RC" > "$RC/clients/c1.conf"
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

# The point of the test: which crontab it asked. The account comes from the
# RELATIONSHIP record (LOCAL_USER=zfsbackup); every call must name it, a bare
# '-l' would be root's.
if grep -q -- '-u zfsbackup -l' "$RC/calls" && ! grep -qx -- '-l' "$RC/calls"; then
    ok "remove-client: the relationship's recorded account is the crontab consulted"
else
    bad "remove-client: the relationship's recorded account is the crontab consulted" "$(cat "$RC/calls")"
fi

# A relationship recorded with NO account (root) targets root's crontab, and
# invents no account from server.conf or anywhere else.
printf 'STATE=active\nMANAGED_DATASETS="tank/a"\nCRON_CONFIG=%s/jobs.conf\n' "$RC" > "$RC/clients/c1.conf"
: > "$RC/calls"
out=$( PATH="$RC/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$RC/server.conf'; CLIENTS_DIR='$RC/clients'
    cmd_remove_client c1" 2>&1 ) || :
if grep -qx -- '-l' "$RC/calls" && ! grep -q -- '-u ' "$RC/calls"; then
    ok "remove-client: a relationship recorded as root targets root, inventing no account"
else
    bad "remove-client: a relationship recorded as root targets root, inventing no account" "$(cat "$RC/calls")"
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

# And the guard behind that reasoning: read_server_conf really does clear its
# OWN fields before sourcing, so "it would be harmless there" is false. Since
# the 2026-08-17 restore split the function BODY lives in lib-backup-common.sh
# (shared with zfs-restore.sh).
#
# BOTH HALVES are pinned now, and the second half is the one that cost a bug.
# It used to clear LOCAL_USER as well -- left over from when the account was a
# host-wide setting, which setup-server stopped recording. The loader was wiping
# a variable the file it sources never contains, silently discarding a decision
# its CALLER had made. Two commands worked around that, which made it look
# deliberate; a third (local-backup, 2026-08-21) did not know to, and shipped a
# --local-user that parsed, set the variable, and lost it a hundred lines later.
#
# The reasoning above is unchanged: CRON_CONFIG is still cleared, so calling
# this in final-catchup would still discard what the client record said. What
# changed is that it no longer clears state it does not own.
rsc=$(awk '/^read_server_conf\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$(dirname "$ZFSBACKUP")/lib-backup-common.sh")
if printf '%s\n' "$rsc" | grep -q 'CRON_CONFIG=""' \
   && printf '%s\n' "$rsc" | grep -q 'DEFAULT_TARGET=""' \
   && ! printf '%s\n' "$rsc" | grep -q 'LOCAL_USER=""'; then
    ok "read_server_conf: clears its OWN fields before sourcing, and only those"
else
    bad "read_server_conf: clears its OWN fields before sourcing, and only those" "$rsc"
fi

# PR #14 F2. Exercise the PUBLIC command, not its helpers in isolation. This is
# deliberately a multi-client config: removing pve2 must delete all three shapes
# it owns (dataset, target prune, remote source prune), publish the surviving
# config, and reinstall a cron representation that still contains other.
RMC="$WORK/removeclient-multiclient"; mkdir -p "$RMC/clients" "$RMC/relationships/pve2"
cat > "$RMC/jobs.conf" <<'EOF'
[defaults]
	host_label = collector

[dataset:hdd/backups/pve2/rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	use_template = standard_hourly

[prune:hdd/backups/pve2]
	# managed-by: zfs-backup.sh client=pve2
	use_template = standard_hourly

[prune:zfsbackup-pve2@10.0.0.2:rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	use_template = source_standard_hourly

[dataset:hdd/backups/other/tank/x]
	# managed-by: zfs-backup.sh client=other
	use_template = standard_hourly

[prune:hdd/backups/other]
	# managed-by: zfs-backup.sh client=other
	use_template = standard_hourly

[prune:zfsbackup-other@10.0.0.3:tank/x]
	# managed-by: zfs-backup.sh client=other
	use_template = source_standard_hourly
EOF
printf 'STATE=active\nPEER_HOST=10.0.0.2\nMANAGED_DATASETS="hdd/backups/pve2/rpool/data"\nMANAGED_PRUNE_SCOPE="hdd/backups/pve2"\nCRON_CONFIG=%s/jobs.conf\n' "$RMC" \
    > "$RMC/clients/pve2.conf"
cat > "$RMC/gen-cron-ok.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$RMC/deploy-marker.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$RMC/deploy.calls"
exit 0
EOF
chmod +x "$RMC/gen-cron-ok.sh" "$RMC/deploy-marker.sh"

out=$( bash -c "
    source '$ZFSBACKUP'
    CLIENTS_DIR='$RMC/clients'; RELATIONSHIPS_DIR='$RMC/relationships'
    GENCRON='$RMC/gen-cron-ok.sh'; DEPLOY='$RMC/deploy-marker.sh'
    read_server_conf() { LOCAL_USER=''; }
    assert_cron_config_matches_installed() { :; }
    assert_no_foreign_managed_block() { :; }
    atomic_replace_and_install() {
        local realfile=\"\$1\" workfile=\"\$2\"
        awk '/^\\[(dataset|prune):/{print \"JOB \" \$0}' \"\$workfile\" > '$RMC/installed.jobs'
        /bin/mv -f \"\$workfile\" \"\$realfile\"
    }
    cmd_remove_client pve2
" 2>&1 ); rc=$?

if [ "$rc" -eq 0 ]; then
    ok "remove-client public command: multi-client teardown completes"
else
    bad "remove-client public command: multi-client teardown completes" "rc=$rc out=$out"
fi
if ! grep -qF 'client=pve2' "$RMC/jobs.conf" \
   && ! grep -qE '^\[(dataset|prune):.*pve2' "$RMC/jobs.conf"; then
    ok "remove-client public command: own dataset, target prune, and remote source prune are gone"
else
    bad "remove-client public command: own dataset, target prune, and remote source prune are gone" \
        "$(grep -E '^\[|managed-by:' "$RMC/jobs.conf")"
fi
if grep -qF '[dataset:hdd/backups/other/tank/x]' "$RMC/jobs.conf" \
   && grep -qF '[prune:hdd/backups/other]' "$RMC/jobs.conf" \
   && grep -qF '[prune:zfsbackup-other@10.0.0.3:tank/x]' "$RMC/jobs.conf" \
   && grep -qF 'client=other' "$RMC/jobs.conf"; then
    ok "remove-client public command: foreign config survives"
else
    bad "remove-client public command: foreign config survives" \
        "$(grep -E '^\[|managed-by:' "$RMC/jobs.conf")"
fi
if grep -qF 'JOB [dataset:hdd/backups/other/tank/x]' "$RMC/installed.jobs" \
   && grep -qF 'JOB [prune:hdd/backups/other]' "$RMC/installed.jobs" \
   && grep -qF 'JOB [prune:zfsbackup-other@10.0.0.3:tank/x]' "$RMC/installed.jobs" \
   && ! grep -qF 'pve2' "$RMC/installed.jobs"; then
    ok "remove-client public command: reinstall retains only the foreign jobs"
else
    bad "remove-client public command: reinstall retains only the foreign jobs" \
        "$(cat "$RMC/installed.jobs" 2>/dev/null)"
fi
if grep -qxF -- '--unpair --peer=10.0.0.2' "$RMC/deploy.calls" \
   && grep -q '^STATE=removed$' "$RMC/clients/pve2.conf"; then
    ok "remove-client public command: unpairs and records removal only after publish"
else
    bad "remove-client public command: unpairs and records removal only after publish" \
        "deploy=$(cat "$RMC/deploy.calls" 2>/dev/null) record=$(tr '\n' ' ' < "$RMC/clients/pve2.conf")"
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

# --- A RETENTION EDIT IS THE SAME JOB, NOT A DELETION ----------------------
#
# Measured on a live pair, pve9 -> pve10, 2026-09-03. An operator edits
# `retain` in the installed config and re-activates; the guard refuses, and
# tells them to "move the other workload out of this account first". There is
# no other workload. The job it names is the very one being edited.
#
# That blocks a workflow REV-20260811-107 explicitly APPROVED. Its finding F1
# is this operator, in these words: "Administrator edits only remote SOURCE
# retention in canonical CONFIG to 6H/2D because the production source is
# space-constrained", followed by an ordinary reactivation. REV-107 made the
# COMPOSITION preserve that edit -- proven live, the re-render did carry it --
# and its evidence was a unit suite, so nothing ever put the INSTALL guard on
# that path. Preserved and then refused at the door.
#
# It is also the architecture the tree states elsewhere: audit-source-retention
# calls the installed config "runtime truth". A guard that refuses to install
# what the config says is refusing to let the truth take effect.
#
# The exemption is deliberately the narrowest one that helps: the SAME line,
# byte for byte, except for the retention flags. Job name (which carries host,
# template and client label), script, ssh flags, -P reservations, dataset and
# pattern must all still match.
CLR="$WORK/clobber-retention"; mkdir -p "$CLR/bin"; : > "$CLR/new.conf"
cat > "$CLR/target-retention.cron" <<'EOF'
# BEGIN zfs-backup-managed
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh -R -L c1 "acct@h:tank/b" "automated_daily" -D7 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CLR/proposal-retention.txt" <<'EOF'
# BEGIN zfs-backup-managed
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh -R -L c1 "acct@h:tank/b" "automated_daily" -D3 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
cat > "$CLR/bin/crontab" <<EOF
#!/bin/bash
cat "$CLR/target-retention.cron"
exit 0
EOF
chmod +x "$CLR/bin/crontab"

out=$( PATH="$CLR/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CLR/proposal-retention.txt'; }; assert_target_block_not_clobbered '$CLR/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "clobber: a hand-edited RETENTION is the same job, and the install is not refused"
else
    bad "clobber: a hand-edited RETENTION is the same job, and the install is not refused" "rc=$rc out=$out"
fi

# ...and it does not pass QUIETLY. Retention is how much history exists; the
# guard's whole promise is that nothing about a backup changes without being
# said out loud. Excused, then named -- both values, so the operator reading
# the confirmation sees 7 -> 3 and not just an absence of complaint.
if case "$out" in *"-D7"*) true ;; *) false ;; esac \
   && case "$out" in *"-D3"*) true ;; *) false ;; esac \
   && case "$out" in *[Rr]"etention"*) true ;; *) false ;; esac; then
    ok "clobber: the excused retention change is reported, naming the old and new value"
else
    bad "clobber: the excused retention change is reported, naming the old and new value" "out=$out"
fi

# NEGATIVE CONTROL, and the one that keeps the exemption honest: a line that
# genuinely DISAPPEARS is still a deletion. Same crontab, but the proposal
# drops the job instead of re-stating it with another retention. If this ever
# passes, the normalizer above has stopped comparing anything that matters.
cat > "$CLR/proposal-retention-gone.txt" <<'EOF'
# BEGIN zfs-backup-managed
9 * * * * /home/zfsbackup/zfs-snapshot-all/delsnaps.sh -R -L c1 "acct@h:tank/OTHER" "automated_daily" -D3 2>>/home/zfsbackup/cron.log
# END zfs-backup-managed
EOF
out=$( PATH="$CLR/bin:$PATH" LOCAL_USER="zfsbackup" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CLR/proposal-retention-gone.txt'; }; assert_target_block_not_clobbered '$CLR/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac; then
    ok "clobber: a job on a DIFFERENT dataset is still a deletion, retention normalizer or not"
else
    bad "clobber: a job on a DIFFERENT dataset is still a deletion, retention normalizer or not" "rc=$rc out=$out"
fi

# THE NORMALIZER IS NARROW, and this is the claim its comment makes: a flag is
# only a retention flag when it is a whole argument. Two datasets whose NAMES
# contain the text -- tank/rack-D7 and tank/rack-D3 -- are different datasets,
# and a guard that confused them would excuse a real deletion.
out=$( bash -c "source '$ZFSBACKUP'; printf %s 'a \"tank/rack-D7\" -D7 b' | retention_normalized_identity" 2>&1 )
if [ "$out" = 'a "tank/rack-D7" -D<N> b' ]; then
    ok "clobber: the retention normalizer leaves a dataset NAME containing -D7 alone"
else
    bad "clobber: the retention normalizer leaves a dataset NAME containing -D7 alone" "out=$out"
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

# THE SAME PROPERTY, IN THE SHAPE gen-cron.sh ACTUALLY EMITS TODAY.
#
# The cases above are written against `-A "acct@host:path"`. gen-cron.sh has
# not emitted that for a long time: `-A` is the AUTOTUNE flag now and the
# endpoint is a positional argument. Measured on a line taken verbatim from a
# live crontab, the old normalizer substituted NOTHING -- so the endpoint-switch
# exemption existed as code and was dead, and every switch after cron was
# installed was refused as if the relationship's own jobs were a foreign
# workload. The fixtures passed the whole time, because they were hand-written
# in a shape the product had stopped producing.
#
# Live on 2026-08-23 (issue #9, second path), isolated by a control:
#   activate --host=<same endpoint>    -> EXIT=0
#   activate --host=<other host:port>  -> EXIT=1, "2 job line(s) would be DELETED"
#
# Three things the old fixtures could not see: the positional endpoint, the
# port in its own -p flag, and delsnaps.sh's REMOTE source-prune line (the call
# site's comment claimed delsnaps.sh lines have no endpoint to switch, which
# stopped being true when managed source retention gained a remote form).
cat > "$CL/target-real.cron" <<'EOF'
0 8 * * * /root/scripts/check-pool-capacity.sh
# BEGIN zfs-backup-managed
1 * * * * /root/scripts/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -R -K /root/.ssh/pairing/k_ed25519 -k /root/.ssh/pairing/k_alias_known_hosts -O HostKeyAlias=zfs-client-pve2prod -p 22 -A -L pve2prod "zfsbackup-pve9@192.168.28.8:hdd/lab9src" "hdd/tgt" 2>"$e"
21 * * * * /root/scripts/zfs-snapshot-all/delsnaps.sh -G -R -K /root/.ssh/pairing/k_ed25519 -O HostKeyAlias=zfs-client-pve2prod -p 22 "zfsbackup-pve9@192.168.28.8:hdd/lab9src" "automated_" -H24 2>"$e"
# END zfs-backup-managed
EOF
cat > "$CL/bin/crontab" <<EOF
#!/bin/bash
[ "\$1" = "-u" ] && { cat "$CL/target-real.cron"; exit 0; }
cat "$CL/target-real.cron"
exit 0
EOF
chmod +x "$CL/bin/crontab"

# Both lines move to a different HOST and a different PORT -- the switch that
# was impossible.
cat > "$CL/proposal-real-switch.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /root/scripts/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -R -K /root/.ssh/pairing/k_ed25519 -k /root/.ssh/pairing/k_alias_known_hosts -O HostKeyAlias=zfs-client-pve2prod -p 2222 -A -L pve2prod "zfsbackup-pve9@pve2-prod:hdd/lab9src" "hdd/tgt" 2>"$e"
21 * * * * /root/scripts/zfs-snapshot-all/delsnaps.sh -G -R -K /root/.ssh/pairing/k_ed25519 -O HostKeyAlias=zfs-client-pve2prod -p 2222 "zfsbackup-pve9@pve2-prod:hdd/lab9src" "automated_" -H24 2>"$e"
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="root" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-real-switch.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "clobber: an endpoint switch in TODAY'S line shape (host+port, snapget and remote prune) passes" \
                || bad "clobber: an endpoint switch in TODAY'S line shape (host+port, snapget and remote prune) passes" "rc=$rc out=$out"

# Fail-closed control in the same shape: the endpoint moves AND the remote
# prune job disappears. The surviving line must not excuse the missing one.
cat > "$CL/proposal-real-lost.txt" <<'EOF'
# BEGIN zfs-backup-managed
1 * * * * /root/scripts/zfs-snapshot-all/snapget.sh -m "automated_hourly_" -R -K /root/.ssh/pairing/k_ed25519 -k /root/.ssh/pairing/k_alias_known_hosts -O HostKeyAlias=zfs-client-pve2prod -p 2222 -A -L pve2prod "zfsbackup-pve9@pve2-prod:hdd/lab9src" "hdd/tgt" 2>"$e"
# END zfs-backup-managed
EOF
out=$( PATH="$CL/bin:$PATH" LOCAL_USER="root" bash -c \
       "source '$ZFSBACKUP'; gencron_as_target() { cat '$CL/proposal-real-lost.txt'; }; assert_target_block_not_clobbered '$CL/new.conf'" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"would be DELETED"*) true ;; *) false ;; esac \
   && case "$out" in *delsnaps.sh*) true ;; *) false ;; esac; then
    ok "clobber: a job that really disappears is still refused, even while the endpoint moves"
else
    bad "clobber: a job that really disappears is still refused, even while the endpoint moves" "rc=$rc out=$out"
fi

# THE EXEMPTION MUST BE ALIVE, not merely present. This is what nothing checked:
# if the generated line shape drifts again so the normalizer stops matching, it
# goes quiet instead of failing, and every endpoint switch starts refusing.
# THE ONLY VERSION OF THIS TEST THAT CANNOT ROT: both sides are rendered by the
# REAL gen-cron.sh, from two configs that differ ONLY in the endpoint.
#
# Every previous attempt at this property -- including my own first one, hours
# earlier the same day -- fed the guard lines a human typed. That is how the
# exemption died unnoticed for months, and it is how the FIRST fix for it still
# failed live: the hand-written fixture carried "-p 22" on both sides, and
# gen-cron.sh emits no -p flag at all for port 22. So the real comparison was
# "-p <PORT>" against nothing, and the guard went on calling the relationship's
# own job a deletion.
#
# gen-cron.sh is a pure text tool (no root, no ZFS, no network), so rendering
# it here costs nothing and removes the human from the loop entirely.
EPC="$WORK/endpointcfg"; mkdir -p "$EPC"
ep_conf() {   # <outfile> <flags-tail>
    cat > "$1" <<CONF
[defaults]
	host_label = pve9

[template:t_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup

[dataset:hdd/tgt/hdd/src]
	use_template = t_hourly
	src          = acct@$2:hdd/src
	flags        = -K /k -k /kh -O HostKeyAlias=zfs-client-x$3
	recursive    = flat
	pair_label   = x
	notify       = x-src
CONF
}
ep_conf "$EPC/lan.conf"  "192.168.28.8" ""
ep_conf "$EPC/prod.conf" "peer-prod"    " -p 2222"
ep_lan=$(  bash "$REPO/gen-cron.sh" -c "$EPC/lan.conf"  2>/dev/null | grep -E '^[0-9*]' )
ep_prod=$( bash "$REPO/gen-cron.sh" -c "$EPC/prod.conf" 2>/dev/null | grep -E '^[0-9*]' )
if [ -z "$ep_lan" ] || [ -z "$ep_prod" ]; then
    bad "clobber: gen-cron.sh renders both endpoint variants for the exemption test"         "lan=${ep_lan:-BRAK} prod=${ep_prod:-BRAK}"
else
    # The premise this test exists to defend, asserted rather than assumed:
    # the port-22 rendering carries NO -p flag, so the exemption has to cope
    # with a token that is present on one side and absent on the other.
    if printf '%s
' "$ep_lan" | grep -q -- ' -p '; then
        bad "clobber: gen-cron.sh omits -p for port 22 (premise of the exemption test)"             "lan line unexpectedly carries -p: $ep_lan"
    else
        ok "clobber: gen-cron.sh omits -p for port 22, so the exemption must handle an ABSENT flag"
    fi
    n_lan=$(  printf '%s
' "$ep_lan"  | bash -c "source '$ZFSBACKUP'; endpoint_normalized_identity" )
    n_prod=$( printf '%s
' "$ep_prod" | bash -c "source '$ZFSBACKUP'; endpoint_normalized_identity" )
    if [ "$n_lan" = "$n_prod" ]; then
        ok "clobber: two REAL gen-cron.sh renderings differing only in endpoint normalize identically"
    else
        bad "clobber: two REAL gen-cron.sh renderings differing only in endpoint normalize identically"             "lan : $n_lan" "prod: $n_prod"
    fi
    # And the exemption must still be ALIVE -- it has to actually rewrite the
    # emitted shape, not silently match nothing.
    if [ "$n_prod" != "$ep_prod" ]; then
        ok "clobber: endpoint_normalized_identity actually rewrites a line in the emitted shape"
    else
        bad "clobber: endpoint_normalized_identity actually rewrites a line in the emitted shape"             "nic nie podmienil -- wyjatek jest martwy" "in : $ep_prod"
    fi
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
got=$( config_datasets "$CD/jobs.conf" | tr '\n' ' ' )
check_eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want[$3] got[$2]"; }
# sort -u, so the order is lexicographic: five before four.
check_eq "commas: every dataset in a comma list is its own entry" \
         "$got" "tank/five tank/four tank/one tank/three tank/two "

# Whitespace after a comma is a human writing a list, not a dataset whose name
# starts with a space -- and a leading space would make `zfs allow` treat the
# name as an option. Asserted by counting entries that still contain a space,
# which is the thing that would actually break, rather than by matching a
# position in the joined string.
dirty=$( config_datasets "$CD/jobs.conf" | grep -c '[[:space:]]' )
check_eq "commas: no entry carries leftover whitespace" "$dirty" "0"

# prune-bookmarks is deliberately NOT a source of delegation checks today (it
# needs different verbs); pinning that so a future change is a decision rather
# than an accident.
case "$got" in
    *tank/six*) bad "commas: prune-bookmarks is not silently folded in" "$got" ;;
    *)          ok "commas: prune-bookmarks is not silently folded in" ;;
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
out=$( PATH="$MDS/bin:$PATH"; eval "$mds_env"; SCOPE_ROOTS='' SCOPE_ERR='' PEER_SAVED_MODE=backup PEER_SAVED_DATASETS='' resolve_mode_datasets 2>&1 ); rc=$?
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
out=$( PATH="$MDS/bin:$PATH"; eval "$mds_env"; SCOPE_ROOTS='' SCOPE_ERR='' PEER_SAVED_MODE=backup PEER_SAVED_DATASETS='' resolve_mode_datasets 2>&1 ); rc=$?
# Wording changed 2026-08-17 (lab3 F1): the refusal now names whose move it is
# and gives the exact source-side command, instead of only asking a question.
if [ "$rc" -ne 0 ] && case "$out" in *"GRANTED nothing yet"*"--commit-scope"*) true ;; *) false ;; esac; then
    ok "resolve_mode_datasets: refuses when --commit-scope has not run yet on the peer"
else
    bad "resolve_mode_datasets: refuses when --commit-scope has not run yet on the peer" "rc=$rc out=$out"
fi
mds_ssh_stub   # restore for the next case

# Nothing fetchable from the peer. This block asserted the wrong thing twice
# over, and the way it did so is worth keeping.
#
# It used to be TWO cases: "no manifest -> the JOIN is missing" and "manifest
# present -> --draft-scope is missing", split by the presence of
# peers/<addr>.conf HERE. Both passed. Both were green while the code was
# wrong, because the sandbox could CREATE a state the real system never
# produces: the collector writes that file itself at --pair time, so on any
# real host it is always present, the "no manifest" branch was unreachable, and
# every actual failure got the --draft-scope advice -- the exact wrong advice
# the split had been added to stop giving.
#
# A test can be perfectly correct about a scenario that does not exist. These
# two were.
#
# Measured on metropolis 2026-08-20: a pair whose SOURCE provably had no
# manifest and no zfsbackup-<label> account still produced "the pairing
# manifest is here, so the join completed".
#
# There is no local fact that proves a remote join completed -- the join runs
# over there, and nothing comes back until a scope can be read, which is the
# thing that just failed. So one case now, and it asserts that the refusal
# names both possibilities and claims neither.
mds_ssh_noscope() {
    cat > "$MDS/bin/ssh" <<EOF
#!/bin/bash
exit 1
EOF
    chmod +x "$MDS/bin/ssh"
}
mds_ssh_noscope
MDS_PEERS="$MDS/peers"; mkdir -p "$MDS_PEERS"

# With the manifest present -- the state EVERY real host is in -- the refusal
# must still offer the join as the first thing to check.
printf 'PEER_JOIN_ROLE="pull"
' > "$MDS_PEERS/peer.example.conf"
out=$( PATH="$MDS/bin:$PATH"; eval "$mds_env"; PEER_STATE_DIR="$MDS_PEERS" SCOPE_ROOTS='' SCOPE_ERR='' PEER_SAVED_MODE=backup PEER_SAVED_DATASETS='' resolve_mode_datasets 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]    && case "$out" in *"did the JOIN complete"*) true ;; *) false ;; esac    && case "$out" in *"draft-scope"*) true ;; *) false ;; esac    && case "$out" in *"so the join completed"*) false ;; *) true ;; esac; then
    ok "resolve_mode_datasets: a failed fetch names BOTH causes and claims neither"
else
    bad "resolve_mode_datasets: a failed fetch names BOTH causes and claims neither" "rc=$rc out=$out"
fi
rm -f "$MDS_PEERS/peer.example.conf"

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
# Omitted mode/datasets is the normal backup path now; section 1b drives that
# accepted case through a stubbed deploy.sh and asserts --mode=backup exactly.

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
# REWRITTEN for issue #9, not loosened. The old assertion pinned the improved
# WORDING of a hint that recited the low-level sequence: it checked that
# set-endpoint was presented as conditional rather than mandatory. Issue #9
# removes that sequence from the ordinary path altogether, so a hint phrased
# "conditionally" is no longer the contract -- naming exactly ONE next command is.
# The property is therefore stated positively (the hint names `activate`) AND
# negatively (it recites none of the expert verbs), because a hint that added
# `activate` while still listing the others would satisfy either half alone.
seed_hint="$(sed -n "/client '\$name' seed complete/,/^}/p" "$ZFSBACKUP")"
if printf '%s' "$seed_hint" | grep -q 'activate \$name' \
   && ! printf '%s' "$seed_hint" | grep -qE 'set-endpoint|verify-endpoint|final-catchup|activate-client'; then
    ok "seed: the next-step hint names exactly one next command and recites no expert verbs"
else
    bad "seed: the next-step hint names exactly one next command and recites no expert verbs" "old wording still present or new wording missing"
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
         ssh() { return 0; }
         load_ssh_opts() { LOAD_SSH_OPTS=(); }
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
out=$( MANAGED_DATASETS='' MANAGED_PRUNE_SCOPE='rpool/data/vm-100-disk-0 hdd/LXC/103' remove_managed_sections "$CF7" synctest rpool/data/vm-100-disk-0 hdd/LXC/103 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '[dataset:rpool/data/vm-100-disk-0]' "$CF7" && ! grep -qF '[dataset:hdd/LXC/103]' "$CF7"; then
    ok "is_previously_managed: a multi-entry MANAGED_PRUNE_SCOPE is read as a list (sync back-compat)"
else
    bad "is_previously_managed: a multi-entry MANAGED_PRUNE_SCOPE is read as a list (sync back-compat)" "rc=$rc out=$out file=$(cat "$CF7" 2>/dev/null)"
fi

# 39d. add-client --mode=sync refuses at enrolment when the peer looks like a
# member of the SAME PVE cluster (U8) -- checked via PVE_NODES_DIR, overridden
# here instead of the real /etc/pve/nodes so this needs no real cluster.
U8="$WORK/u8nodes"; mkdir -p "$U8/pve2"
out=$( ( PVE_NODES_DIR="$U8"; read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }; cmd_add_client u8client --lan=pve2 --mode=sync ) 2>&1 ); rc=$?
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
         read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
         cmd_add_client jrtest --lan=10.7.7.7 --datasets="tank/a" --target=tank/backups --join-remotely ) 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -qF -- "--join-remotely" "$JR/args.out"; then
    ok "add-client --join-remotely: forwarded to deploy.sh --pair"
else
    bad "add-client --join-remotely: forwarded to deploy.sh --pair" "rc=$rc out=$out args=$(cat "$JR/args.out" 2>/dev/null)"
fi

out2=$( ( CLIENTS_DIR="$JR/clients" DEPLOY="$JRDEPLOY"
          read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
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

# Same rewrite, same reason: the VOCABULARY rule survives issue #9 even though the
# sentence carrying it did not. Pinning a whole sentence made the rule hostage to
# any rewording; pinning the words keeps the property that actually matters -- a
# reader who has just been told about "the collector" must not meet "the source"
# and have to guess which machine it means.
if printf '%s' "$seed_hint" | grep -q 'the peer' \
   && ! printf '%s' "$seed_hint" | grep -q 'the source'; then
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

# 7a. Every ssh in zfs-backup.sh must be bounded on BOTH failure modes a dead
# peer produces: ConnectTimeout for one that never answers the SYN (measured:
# ~130s to a black-holed address, and the reason a single leaked fixture ssh
# turned this very suite's leg into 34 minutes), and ServerAlive* for one that
# goes silent AFTER connecting. Counted per option, so a NEW ssh added without
# either trips it. Fails on the pre-fix tree (9 BatchMode vs 1 ConnectTimeout).
_bm=$(grep -c 'o BatchMode=yes' "$ZFSBACKUP")
_ct=$(grep -c 'o ConnectTimeout=' "$ZFSBACKUP")
_sa=$(grep -c 'o ServerAliveInterval=' "$ZFSBACKUP")
if [ "$_bm" -gt 0 ] && [ "$_bm" -eq "$_ct" ] && [ "$_bm" -eq "$_sa" ]; then
    ok "every BatchMode ssh in zfs-backup.sh carries ConnectTimeout + ServerAlive ($_bm groups)"
else
    bad "every BatchMode ssh in zfs-backup.sh carries ConnectTimeout + ServerAlive" \
        "BatchMode=$_bm ConnectTimeout=$_ct ServerAlive=$_sa -- an unbounded ssh hangs on a dead peer"
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

# A profile is ONE file since 2026-08-25, so a fixture that wants a variant of
# the built-in copies profile.conf and appends into the right section instead of
# editing one of three files. `mkprof_add <dir> <section> <lines...>` appends the
# lines directly after that section header, which is where an operator would put
# them and where the splitter expects them.

FS="$WORK/fieldsurvival"; mkdir -p "$FS/p/prof"
mkprof_copy "$FS/p/prof"
# A second VALID dataset field the built-in profile does not carry.
#
# THIS USED TO BE `recursive`, on the grounds that REV-20260808-076 said
# "recursion remains profile-owned" and the forbidden list did not carry it. It
# is `media` since 2026-08-31, and the swap is the point rather than a
# workaround: that sentence was written when the design had NO relation-level
# recursion, and the owner revision it describes had just removed one. Today
# `--recursive=flat|atomic` is back on the relationship, recorded in the client
# record, and written into the section by emit_client_sections -- so a profile
# setting it made the section carry the field TWICE and gen-cron refused the
# whole config. The reason THIS fixture never saw that is worth keeping: it
# enrols a NON-recursive relationship, so the caller writes no recursive line
# and the collision has nothing to collide with.
#
# `media` is now the only other field a [dataset] fragment may carry: everything
# else is identity, link, scope, topology, or has a [template:] layer and
# belongs there. That is a narrow surface, and it is the honest one -- the
# fragment's job is to point at templates, not to carry policy.
mkprof_add "$FS/p/prof" '[dataset]' '\tmedia = removable'

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
if grep -q '^	media = removable$' "$EC_FS"; then
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
  _t=$(mktemp); _d=$(mktemp); _p=$(mktemp); _e=$(mktemp); _L=$(mktemp)
  bash "$REPO/gen-cron.sh" --dump-tier-letters > "$_L"
  profile_split_one_file "$FS/p/prof.conf" "$_t" "$_d" "$_p" "$_e"
  profile_render_templates "$_t" prof "$FS/tpl.conf" "" "$_L" ) || true
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

# And the extra field must have MEANT something, not merely parsed. `media =
# removable` brackets the generated line with the media gate -- import the pool
# before the write, export it after -- so its absence is visible in the rendered
# output rather than only in the config text.
if printf '%s
' "$gen_out" | grep -q 'zfs-media-gate.sh attach' \
   && printf '%s
' "$gen_out" | grep -q 'zfs-media-gate.sh detach'; then
    ok "field survival: the profile's media=removable reaches the rendered cron line"
else
    bad "field survival: the profile's media=removable reaches the rendered cron line" "$(printf '%s' "$gen_out" | grep -E 'snap(send|get)' | head -2)"
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
         ssh() { return 0; }; load_ssh_opts() { LOAD_SSH_OPTS=(); }
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
    ( ssh() { return 0; }; load_ssh_opts() { LOAD_SSH_OPTS=(); }
      CLIENTS_DIR="$SD/clients" PEER_STATE_DIR="$SD/peerstate" PEER_KEY_DIR="$SD/keys" SNAPGET="$SD_SNAPGET" \
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
    ( ssh() { return 0; }; load_ssh_opts() { LOAD_SSH_OPTS=(); }
      CLIENTS_DIR="$SD/clients" PEER_STATE_DIR="$SD/peerstate" PEER_KEY_DIR="$SD/keys" SNAPGET="$SD_SNAPGET" \
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
mkprof_copy "$P9/prof"

# THE SOURCE MUST ANSWER, and until 2026-08-22 these cases relied on it not
# answering. LOAD_HOST is an unroutable test address and ssh was never stubbed,
# so sync mode's passive/active decision ran through a probe that could not
# reach anything -- and passed because "unreachable" silently read as "no family
# here". That is exactly the fail-open the tri-state probe removed, so the moment
# it refused instead of guessing, five cases went red. They had been green for
# the wrong reason, which is the worst way for a test to be green.
#
# The stub answers on purpose now. EMIT9_SSH_RC picks WHAT it answers:
#   0 + no output   = reachable, no family (the shape these cases assumed)
#   0 + a snapshot  = reachable, family present
#   255             = unreachable, which must refuse
EMIT9_SSH_RC=0
EMIT9_SSH_OUT=""
emit9() {   # <conf> <name> <host> <is_new> [mode] [datasets]
    # MANAGED_DATASETS/MANAGED_PRUNE_SCOPE deliberately EMPTY: ownership must be
    # proven by the marker this function itself wrote, which is the harder half
    # of remove_managed_sections' own test and the one a fresh record relies on.
    ( ssh() { [ -n "$EMIT9_SSH_OUT" ] && printf '%s\n' "$EMIT9_SSH_OUT"; return "$EMIT9_SSH_RC"; }
      load_ssh_opts() { LOAD_SSH_OPTS=(); }
      PROFILE_ROOT="$P9" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
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
#
# The customized value is NOT an arbitrary marker string. Step 6b below feeds
# the result to the REAL gen-cron.sh, which requires every contributing tier's
# 'pattern' to start with 'gfs_pattern' -- otherwise the ladder cannot see the
# snapshots whose retention counts it was handed. The profile's keep_* tiers all
# use pattern = automated_hourly, so narrowing the ladder to that same series is
# both a realistic operator edit and a legal one. It is still plainly distinct
# from the profile default (automated_) and from the drift marker
# (automated_PROFILEDRIFT_), which is all the preservation assertion needs.
# A marker chosen only for looking custom (this was automated_custom_ until
# 2026-08-20) describes a ladder blind to its own tiers, and step 6b would be
# asserting that gen-cron.sh accepts a config that silently prunes nothing.
# Step 7's sync marker stays arbitrary on purpose: that config is never handed
# to gen-cron.sh, so nothing there depends on it describing a coherent ladder.
sed -i "/^\[prune:$(printf '%s' "$PR9" | sed 's,/,\\/,g')\]/,/^\[/ s/^\tgfs_pattern *=.*/\tgfs_pattern  = automated_hourly/" "$C9"
before_recursive=$(grep -c 'recursive    = flat' "$C9")
before_pattern=$(grep -c 'gfs_pattern  = automated_hourly' "$C9")

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
        && [ "$(grep -c 'gfs_pattern  = automated_hourly' "$C9")" = "$before_pattern" ] \
        && [ "$before_pattern" -ge 1 ]; then
    ok "89 step 5: re-activation preserves the hand-customized dataset and prune policy"
else
    bad "89 step 5: re-activation preserves the hand-customized dataset and prune policy" \
        "recursive before=$before_recursive after=$(grep -c 'recursive    = flat' "$C9") pattern before=$before_pattern after=$(grep -c 'gfs_pattern  = automated_hourly' "$C9") file=$(cat "$C9")"
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
# handoff. `recursive` was that field until 2026-08-31, when it became one of
# the invalid ones -- recursion is the relationship's topology and a profile
# setting it made the emitted section carry the field twice. `media` is what a
# [dataset] fragment may still carry besides use_template.
mkprof_add "$P9/prof" '[dataset]' '\tmedia = removable'
sed -i 's/^\tgfs_pattern *=.*/\tgfs_pattern  = automated_PROFILEDRIFT_/' "$P9/prof.conf"
out=$(emit9 "$C9" c9 10.9.9.3 0); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "PROFILEDRIFT" "$C9" \
        && grep -q 'recursive    = flat' "$C9" \
        && grep -q 'gfs_pattern  = automated_hourly' "$C9" \
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
( . "$REPO/lib-profile.sh"
  _t=$(mktemp); _d=$(mktemp); _p=$(mktemp); _e=$(mktemp); _L=$(mktemp)
  bash "$REPO/gen-cron.sh" --dump-tier-letters > "$_L"
  profile_split_one_file "$P9/prof.conf" "$_t" "$_d" "$_p" "$_e"
  profile_render_templates "$_t" prof "$P9/tpl.conf" "" "$_L" ) || true
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
        && ! grep -q 'gfs_pattern  = automated_hourly' "$C9"; then
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
mkdir -p "$AP/clients" "$AP/peerstate" "$AP/keys" "$AP/dir" "$AP/root" "$AP/cap"
mkprof_copy "$AP/root/prof"
# An extra template nothing references: the "otherwise-unused generated template
# the operator removed" of the review's proof step 4. A referenced one could not
# tell F2 apart from gen-cron simply rejecting a dangling use_template.
printf '\n[template:extra_unused]\n\tsend_schedule = 0 5 * * *\n\tprefix        = automated_extra_\n' >> "$AP/root/prof.conf"

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
mv "$AP/root/prof.conf" "$AP/root/prof.gone"
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
mv "$AP/root/prof.gone" "$AP/root/prof.conf"

# A profile that is PRESENT but no longer valid is the same class of dependency
# -- an installed CONFIG must not stop being reactivatable because a file it no
# longer needs stopped parsing.
mkprof_add "$AP/root/prof" '[dataset]' '	src = zfsbackup@nope:x'
out=$(run_ap "$AP/root")
if [ -f "$AP/cap/workfile" ] && case "$out" in *"profile 'prof'"*) false ;; *) true ;; esac; then
    ok "90 F1: reactivation is unaffected by the CREATE-time profile becoming invalid"
else
    bad "90 F1: reactivation is unaffected by the CREATE-time profile becoming invalid" \
        "captured=$([ -f "$AP/cap/workfile" ] && echo yes || echo NO) out=$(printf '%s' "$out" | tail -5)"
fi
sed -i '/^	src = zfsbackup@nope:x$/d' "$AP/root/prof.conf"

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
mv "$AP/root/prof.conf" "$AP/root/prof.gone"
out=$( ( CLIENTS_DIR="$AP/clients" PEER_STATE_DIR="$AP/peerstate" PEER_KEY_DIR="$AP/keys" \
         SERVER_CONF="$AP/no-such-server.conf" SNAPGET="$AP/snapget-capture.sh" \
         PROFILE_ROOT="$AP/root" PROFILE_ACTIVE=prof PROFILE_LOADED="" \
         cmd_activate_client apnew --yes ) 2>&1 ); rc=$?
mv "$AP/root/prof.gone" "$AP/root/prof.conf"
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
	retain         = -H24

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
mkprof_copy "$GX/prof"
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
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\nLOCAL_USER=zfsbackup\n' "$P53" > "$P53/server.conf"
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
mkdir -p "$P53/profiles"
cp "$REPO/profiles/default.conf" "$P53/profiles/altprofile.conf"
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
mkdir -p "$PC/clients" "$PC/peerstate" "$PC/keys" "$PC/dir" "$PC/cap" "$PC/root"
for p in default alt; do
    cp "$REPO/profiles/default.conf" "$PC/root/$p.conf"
done
# ALT's only difference is an observable, safe-to-render marker: the hourly
# send cadence. If the candidate carries minute 7 it came from ALT's content,
# not just ALT's namespace string.
sed -i 's/^\tsend_schedule  = 1 \* \* \* \*/\tsend_schedule  = 7 * * * */' "$PC/root/alt.conf"

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
# CONTRACT CHANGE 2026-08-24 (schedule stagger): the MINUTE is no longer the
# profile's to decide -- relationships are spread across the clock so they stop
# firing in one bucket, and the chosen minute is written into the section. What
# the profile still owns, and what this therefore asserts, is the CADENCE: the
# remaining four cron fields must arrive from the ALT template untouched. The
# assertion was rewritten rather than deleted, because the property it was built
# for (profile semantics reach the real gen-cron output, not just the config
# text) is exactly the property that must survive the stagger.
pc_rendered="$(bash "$REPO/gen-cron.sh" -c "$PC/cap/workfile" 2>/dev/null)"
pc_send_line="$(printf '%s
' "$pc_rendered" | grep -E 'snapget|snapsend' | grep -v delsnaps | head -1)"
pc_cadence="$(printf '%s' "$pc_send_line" | awk '{print $2, $3, $4, $5}')"
pc_minute="$(printf '%s' "$pc_send_line" | awk '{print $1}')"
if [ -n "$pc_send_line" ] && [ "$pc_cadence" = "* * * *" ]         && printf '%s' "$pc_minute" | grep -qE '^[0-9]+$'; then
    ok "95: the ALT send cadence reaches the rendered cron via the real gen-cron.sh"
else
    bad "95: the ALT send cadence reaches the rendered cron via the real gen-cron.sh"         "cadence='$pc_cadence' minute='$pc_minute' line='$pc_send_line'"
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

# --- 55c. REV-20260812-111 B: atomic -r + managed source retention is refused ---
#
# An atomic (-r) relationship keeps NO bookmark -- both engines gate the bookmark
# path on RECURSIVE -ne 1 -- so combining it with managed source retention builds a
# relationship guaranteed to stop permanently once retention outruns the target
# (measured, REV-102 campaign legs B3/B4). The high-level layer never emits
# `recursive = atomic`, so the check reads the CANDIDATE about to be installed
# rather than trusting what this run generated.
ATOM="$WORK/atomicrec"; mkdir -p "$ATOM"
cat > "$ATOM/cand.conf" <<'EOF'
[dataset:tank/bk/plain]
	src          = zfsbackup@10.0.0.9:tank/plain
	recursive    = no

[dataset:tank/bk/flat]
	src          = zfsbackup@10.0.0.9:tank/flat
	recursive    = flat

[dataset:tank/bk/atomic]
	src          = zfsbackup@10.0.0.9:tank/atomic
	recursive    = atomic

[dataset:tank/bk/silent]
	src          = zfsbackup@10.0.0.9:tank/silent
EOF
ana() { ( assert_no_atomic_with_source_retention "$ATOM/cand.conf" "$@" ) >/dev/null 2>&1; }
ana tank/bk/plain  && ok "55c REV-111B: recursive = no passes"        || bad "55c REV-111B: recursive = no passes" ""
ana tank/bk/silent && ok "55c REV-111B: an absent recursive field passes (default no)" \
                   || bad "55c REV-111B: an absent recursive field passes (default no)" ""
# The discriminating control: flat is ALSO recursive, and it is explicitly allowed
# because -R keeps per-dataset bookmarks (measured, leg B5). A guard that refused
# "any recursion" would fail this and would be wrong.
ana tank/bk/flat   && ok "55c REV-111B: recursive = flat passes -- -R keeps bookmark insurance" \
                   || bad "55c REV-111B: recursive = flat passes -- -R keeps bookmark insurance" ""
ana tank/bk/atomic && bad "55c REV-111B: recursive = atomic FAILS CLOSED" "returned 0" \
                   || ok "55c REV-111B: recursive = atomic FAILS CLOSED"
ana tank/bk/plain tank/bk/atomic && bad "55c REV-111B: one atomic among many FAILS CLOSED" "" \
                                 || ok "55c REV-111B: one atomic among many FAILS CLOSED"
msg="$( ( assert_no_atomic_with_source_retention "$ATOM/cand.conf" tank/bk/atomic ) 2>&1 )"
{ printf '%s' "$msg" | grep -qi "recursive = atomic" \
  && printf '%s' "$msg" | grep -qi "recursive = flat" \
  && printf '%s' "$msg" | grep -qi "nothing was changed"; } \
    && ok "55c REV-111B: the refusal names the conflict, both resolutions, and that nothing changed" \
    || bad "55c REV-111B: the refusal names the conflict, both resolutions, and that nothing changed" "$(printf '%s' "$msg"|tail -1)"

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
mkprof_copy "$P56/prof"
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
# One file now: split it, then render the templates half. The renderer takes a
# templates FILE, not a profile directory.
( PROFILE_ROOT="$P56"
  _t=$(mktemp); _d=$(mktemp); _p=$(mktemp); _e=$(mktemp); _L=$(mktemp)
  bash "$REPO/gen-cron.sh" --dump-tier-letters > "$_L"
  profile_split_one_file "$P56/prof.conf" "$_t" "$_d" "$_p" "$_e"
  profile_render_templates "$_t" prof "$WORK/s3tpl.conf" "" "$_L" ) || true
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
mkprof_copy "$RP56/prof"

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
( PROFILE_ROOT="$RP56"
  _t=$(mktemp); _d=$(mktemp); _p=$(mktemp); _e=$(mktemp); _L=$(mktemp)
  bash "$REPO/gen-cron.sh" --dump-tier-letters > "$_L"
  profile_split_one_file "$RP56/prof.conf" "$_t" "$_d" "$_p" "$_e"
  profile_render_templates "$_t" prof "$AP/tpl.conf" "" "$_L" ) || true
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

# --- 60. rendered profile artifacts must not be left in $TMPDIR ---------------
#
# load_active_profile allocates three mktemp files and, until this section
# existed, never removed them. Measured on pve0 2026-08-14: 1824 rendered-profile
# copies in /tmp, ~1800 per full run of THIS suite, because the suite drives its
# profile loads inside `( ... )` subshells and each one leaked its three.
#
# The check is hermetic rather than a /tmp diff: every case runs with TMPDIR
# pointed at its own empty directory, so "left nothing behind" is `ls` on that
# directory and cannot be confused by another process's temporary files. mktemp
# honours TMPDIR, which is what makes the isolation real.
#
# TMPDIR is EXPORTED, not merely assigned. mktemp is an external binary and reads
# it from the environment, so a plain `TMPDIR=...` in the subshell leaves it
# writing to the real /tmp and every case here passes for the wrong reason. The
# positive control below is what caught that while this section was written.
LK="$WORK/leak"
mkdir -p "$LK/root" "$LK/tmp"
mkprof_copy "$LK/root/prof"
# A profile that is COMPLETE (so it gets past the completeness check and reaches
# lib-profile.sh's own mktemp'd schema dump) but INVALID: `src` is
# relationship-owned and refused at the profile boundary.
mkprof_copy "$LK/root/bad"
mkprof_add "$LK/root/bad" '[dataset]' '	src = zfsbackup@nope:x'

lk_env() {   # <profile name> <command...>  -- PROFILE_ROOT is always $LK/root
    local prof="$1"; shift
    PROFILE_ROOT="$LK/root" PROFILE_ACTIVE="$prof" PROFILE_LOADED="" GENCRON="$REPO/gen-cron.sh" \
    PEER_SAVED_MODE=backup PEER_SAVED_TARGET="tank/backups" LOAD_LABEL=10.7.7.8 \
    LOAD_ACCOUNT=zfsbackup LOAD_HOST=10.7.7.8 LOAD_FLAGS="-K /dev/null" \
    PEER_SAVED_DATASETS="rpool/data" MANAGED_DATASETS="" MANAGED_PRUNE_SCOPE="" \
    PROFILE_GFS=1 "$@"
}
lk_conf() { printf '[defaults]\n\thost_label = lktest\n' > "$1"; }

# Guard the harness itself. Every case below hides the body's output, so a body
# that never ran would leave an empty TMPDIR and pass -- which is exactly what
# the first version of this section did (lk_env passed the profile root on to
# the command as an argument, so nothing was ever emitted). Prove ONCE, loudly,
# that this env really drives a profile load and a real emission.
lk_conf "$LK/probe.conf"
lk_env prof emit_client_sections "$LK/probe.conf" lkp 1 >/dev/null 2>&1
if grep -q 'profile__prof__' "$LK/probe.conf"; then
    ok "60: harness control -- lk_env really loads the profile and emits from it"
else
    bad "60: harness control -- lk_env really loads the profile and emits from it" \
        "no profile__prof__ section in the emitted config; every case below would pass vacuously"
fi

# 1. the ordinary path: one load, one emission, nothing left behind.
lk_conf "$LK/one.conf"
n="$(rm -rf "$LK/tmp/one"; mkdir -p "$LK/tmp/one"
     ( export TMPDIR="$LK/tmp/one"; lk_env prof emit_client_sections "$LK/one.conf" lkc 1 ) >/dev/null 2>&1
     find "$LK/tmp/one" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: a profile-loading run leaves no file in TMPDIR"
else
    bad "60: a profile-loading run leaves no file in TMPDIR" "$n entr(ies) left: $(ls -1 "$LK/tmp/one" | tr '\n' ' ')"
fi

# 2. POSITIVE CONTROL. The same body with the release defeated must leave the
#    rendered artifacts behind -- otherwise case 1 proves only that the check
#    cannot see.
#
#    The count is derived, not typed. It was the literal 3, and the day the
#    profile gained a FOURTH rendered artifact (the shared [excluded:] sections,
#    which compose differently from templates and so cannot share their file)
#    this control failed for a reason that had nothing to do with leaking. A
#    control that has to be edited whenever the thing it watches grows will
#    eventually be edited without being understood.
n="$(rm -rf "$LK/tmp/ctl"; mkdir -p "$LK/tmp/ctl"
     ( export TMPDIR="$LK/tmp/ctl"
       profile_release_tmp() { :; }; _profile_arm_release() { :; }
       lk_env prof emit_client_sections "$LK/one.conf" lkc 1 ) >/dev/null 2>&1
     find "$LK/tmp/ctl" -mindepth 1 | wc -l | tr -d ' ')"
want_leak="$(grep -cE '^[[:space:]]*PROFILE_[A-Z_]+FILE=\$\(mktemp\)' "$REPO/zfs-backup.sh")"
if [ "$n" = "$want_leak" ] && [ "$want_leak" -gt 0 ]; then
    ok "60: control -- with the release defeated the same run leaks every rendered artifact ($want_leak) (the check discriminates)"
else
    bad "60: control -- with the release defeated the same run leaks every rendered artifact" "left=$n, artefaktow renderowania=$want_leak"
fi

# 3. TWO loads in one shell. A trap alone cannot fix this: it fires once, on the
#    LAST allocation, and the first three would survive. Pins the release that
#    load_active_profile does before it re-renders.
lk_conf "$LK/two.conf"
n="$(rm -rf "$LK/tmp/two"; mkdir -p "$LK/tmp/two"
     ( export TMPDIR="$LK/tmp/two"
       lk_env prof ensure_cron_config "$LK/two.conf" 1 1
       lk_env prof emit_client_sections "$LK/two.conf" lkc 1 ) >/dev/null 2>&1
     find "$LK/tmp/two" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: two loads in one shell leave nothing (the re-render releases the first set)"
else
    bad "60: two loads in one shell leave nothing" "$n entr(ies) left: $(ls -1 "$LK/tmp/two" | tr '\n' ' ')"
fi

# 4. The `die` path. zfs-backup.sh dies in several places after these files are
#    allocated, so a delete at the end of the happy path would not have been a
#    fix at all. `die` exits, which is what the EXIT trap is for.
n="$(rm -rf "$LK/tmp/die"; mkdir -p "$LK/tmp/die"
     ( export TMPDIR="$LK/tmp/die"
       lk_env prof load_active_profile
       die "simulated post-load failure" ) >/dev/null 2>&1
     find "$LK/tmp/die" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: a die() after the profile is loaded still leaves nothing"
else
    bad "60: a die() after the profile is loaded still leaves nothing" "$n entr(ies) left: $(ls -1 "$LK/tmp/die" | tr '\n' ' ')"
fi

# 5. lib-profile.sh's own mktemp'd schema dump, on the path that FAILS
#    validation -- the branch where a leak would be easiest to miss, because the
#    run is already on its way to dying.
n="$(rm -rf "$LK/tmp/inv"; mkdir -p "$LK/tmp/inv"
     ( export TMPDIR="$LK/tmp/inv"
       lk_env bad load_active_profile ) >/dev/null 2>&1
     find "$LK/tmp/inv" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: a profile REFUSED by the boundary leaves no schema dump behind (lib-profile.sh)"
else
    bad "60: a profile REFUSED by the boundary leaves no schema dump behind" "$n entr(ies) left: $(ls -1 "$LK/tmp/inv" | tr '\n' ' ')"
fi
# and the refusal is the reason it stopped, not some unrelated failure. Without
# this, a typo in the fixture path makes case 5 pass by dying at the
# completeness check, before lib-profile.sh's mktemp is ever reached -- which is
# how the first version of it passed.
out="$( ( lk_env bad load_active_profile ) 2>&1 )"
if printf '%s' "$out" | grep -q "relationship-owned"; then
    ok "60: control -- that profile is refused for the boundary reason, not an unrelated one"
else
    bad "60: control -- that profile is refused for the boundary reason" "out=$out"
fi

# 6. A real EXECUTED invocation, not a sourced function: the process lifetime a
#    host actually sees, ending the way most of this script's failures end --
#    in die().
#
#    migrate-profile on a LEGACY config (standard_hourly still carrying
#    prune_schedule) is the cheap one: it loads the profile, and with stdin at
#    /dev/null the confirmation prompt reads EOF and it dies, well before
#    anything installs. No --yes, so it cannot reach a crontab.
mkdir -p "$LK/clients"
cat > "$LK/legacy.conf" <<'EOF'
[defaults]
	host_label = lktest

[template:standard_hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	notify_word    = backup
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
EOF
rm -rf "$LK/tmp/exec"; mkdir -p "$LK/tmp/exec"
xout="$(TMPDIR="$LK/tmp/exec" PROFILE_ROOT="$LK/root" PROFILE_ACTIVE=prof \
        CRON_CONFIG="$LK/legacy.conf" CLIENTS_DIR="$LK/clients" SERVER_CONF="$LK/no-such.conf" \
        bash "$ZFSBACKUP" migrate-profile </dev/null 2>&1)"
n="$(find "$LK/tmp/exec" -mindepth 1 | wc -l | tr -d ' ')"
# the discriminator: it must have ENTERED the migration, not returned early on
# "already on the standard GFS profile" with no profile ever loaded.
if [ "$n" = 0 ] && ! printf '%s' "$xout" | grep -q 'already on the standard GFS profile'; then
    ok "60: an executed zfs-backup.sh invocation that dies leaves nothing in TMPDIR"
else
    bad "60: an executed zfs-backup.sh invocation that dies leaves nothing in TMPDIR" \
        "$n entr(ies) left: $(ls -1 "$LK/tmp/exec" | tr '\n' ' ')" "out=$xout"
fi

# 7. Arming is decided by BASHPID, never by `trap -p`.
#
#    Measured on bash 5.1.4: inside a subshell `trap -p EXIT` reports an
#    ANCESTOR's action string although that trap is not armed there. The first
#    version of the fix used `trap -p` to avoid clobbering a foreign owner,
#    therefore read this suite's own parent trap in every subshell, declined to
#    arm, and leaked exactly as before. This pins the discriminator: a subshell
#    running under an ancestor EXIT trap must STILL release.
n="$(rm -rf "$LK/tmp/anc"; mkdir -p "$LK/tmp/anc"
     ( export TMPDIR="$LK/tmp/anc"
       trap 'echo ancestor-action >/dev/null' EXIT   # armed in THIS shell...
       ( lk_env prof load_active_profile )           # ...but not in this one
     ) >/dev/null 2>&1
     find "$LK/tmp/anc" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: a subshell under an ancestor EXIT trap still releases (BASHPID, not trap -p)"
else
    bad "60: a subshell under an ancestor EXIT trap still releases (BASHPID, not trap -p)" \
        "$n entr(ies) left: $(ls -1 "$LK/tmp/anc" | tr '\n' ' ')"
fi
# and the ancestor's own trap is untouched: it is still what runs at ITS exit,
# not something the profile load replaced.
out="$( ( trap 'echo ANCESTOR-RAN' EXIT
          ( export TMPDIR="$LK/tmp/anc"; lk_env prof load_active_profile ) >/dev/null 2>&1
          : ) 2>&1 )"
if [ "$out" = "ANCESTOR-RAN" ]; then
    ok "60: control -- the ancestor's EXIT trap still runs at its own exit"
else
    bad "60: control -- the ancestor's EXIT trap still runs at its own exit" "out=$out"
fi

# 8. The release reports a failure it cannot fix instead of swallowing it
#    (REV-20260813-119 F1.4): a file it cannot remove must be named and must
#    make the helper return non-zero.
#
#    Staged as a non-empty DIRECTORY rather than a mode-protected file: `rm -f`
#    refuses a directory for root and non-root alike, and for the same reason on
#    every filesystem, so this exercises the reporting branch in the suite's real
#    environment (the PVE hosts run these as root) instead of skipping there --
#    and it does not depend on chmod meaning anything, which it does not under
#    Git Bash on Windows.
UD="$LK/undel"; mkdir -p "$UD/keeps-it-non-empty"
out="$( PROFILE_TPL_FILE="$UD" PROFILE_DS_FILE="" PROFILE_PRUNE_FILE="" \
        profile_release_tmp 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$UD" && [ -d "$UD" ]; then
    ok "60: a removal it cannot do is reported with the path and returns non-zero"
else
    bad "60: a removal it cannot do is reported with the path and returns non-zero" "rc=$rc out=$out"
fi
# control: the same helper on a removable file is silent and succeeds -- so the
# assertion above is about the failure, not about the helper always complaining.
: > "$LK/removable"
out="$( PROFILE_TPL_FILE="$LK/removable" PROFILE_DS_FILE="" PROFILE_PRUNE_FILE="" \
        profile_release_tmp 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$LK/removable" ]; then
    ok "60: control -- a removable file is removed silently with status 0"
else
    bad "60: control -- a removable file is removed silently with status 0" "rc=$rc out=$out exists=$([ -e "$LK/removable" ] && echo y || echo n)"
fi

# 9. A PARTIAL allocation must leave nothing (REV PR#15 F1).
#
#    Arming after the third mktemp meant a failure at allocation 2 or 3 exited
#    with everything already allocated still on disk and no trap to reach it.
#    Measured on the reviewed head: failing the second render allocation left one
#    file behind.
#
#    The counter lives in a FILE and outside TMPDIR: each allocation happens in
#    its own $( ) subshell, so a shell variable resets every call and the
#    injection would silently never fire -- a 0-file result that proves nothing.
cat > "$LK/partial.sh" <<'EOF'
source "$ZB" 2>/dev/null
mktemp() {
    local n
    n=$(( $(cat "$NFILE") + 1 ))
    echo "$n" > "$NFILE"
    # allocation 3 overall = the second RENDER allocation, after lib-profile.sh's
    # validation dump. That is where the leak was measured.
    [ "$n" = 3 ] && return 1
    command mktemp -p "$TMPDIR"
}
PROFILE_ROOT="$PR" PROFILE_ACTIVE=prof PROFILE_LOADED="" GENCRON="$GC" \
    load_active_profile
EOF
rm -rf "$LK/tmp/part"; mkdir -p "$LK/tmp/part"; echo 0 > "$LK/partn"
pout="$(TMPDIR="$LK/tmp/part" NFILE="$LK/partn" ZB="$ZFSBACKUP" PR="$LK/root" GC="$REPO/gen-cron.sh" \
        bash "$LK/partial.sh" 2>&1)"; prc=$?
n="$(find "$LK/tmp/part" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$n" = 0 ]; then
    ok "60: a failed allocation part-way through leaves nothing behind"
else
    bad "60: a failed allocation part-way through leaves nothing behind" \
        "$n entr(ies) left: $(ls -1 "$LK/tmp/part" | tr '\n' ' ')"
fi
# control: the injection really fired and really stopped the load. Without this,
# a fixture that never reaches three allocations passes the case vacuously.
if [ "$(cat "$LK/partn")" = 3 ] && [ "$prc" -ne 0 ]; then
    ok "60: control -- the allocation failure was injected and did stop the load"
else
    bad "60: control -- the allocation failure was injected and did stop the load" \
        "calls=$(cat "$LK/partn") rc=$prc out=$pout"
fi

# 10/11. Sourcing must not silently delete the CALLER's own EXIT trap (F2).
#
#    Case 7 above pins the subshell direction: an ancestor's reported trap must
#    not stop a subshell from arming. This is the other direction, and replacing
#    unconditionally got it wrong -- a consumer that sources this file and loads
#    a profile in its OWN shell had its cleanup discarded. In the host shell the
#    `trap -p` report IS authoritative (that is what PROFILE_HOST_PID decides),
#    so the foreign action can be composed rather than clobbered.
cat > "$LK/hosttrap.sh" <<'EOF'
trap 'echo FOREIGN-RAN' EXIT
source "$ZB" 2>/dev/null
PROFILE_ROOT="$PR" PROFILE_ACTIVE=prof PROFILE_LOADED="" GENCRON="$GC" \
    load_active_profile >/dev/null 2>&1
echo BODY-DONE
EOF
rm -rf "$LK/tmp/host"; mkdir -p "$LK/tmp/host"
out="$(TMPDIR="$LK/tmp/host" ZB="$ZFSBACKUP" PR="$LK/root" GC="$REPO/gen-cron.sh" \
       bash "$LK/hosttrap.sh" 2>&1)"
n="$(find "$LK/tmp/host" -mindepth 1 | wc -l | tr -d ' ')"
if printf '%s' "$out" | grep -q 'FOREIGN-RAN' && [ "$n" = 0 ]; then
    ok "60: sourcing keeps the caller's own EXIT trap AND still releases"
else
    bad "60: sourcing keeps the caller's own EXIT trap AND still releases" \
        "out=$out left=$n"
fi

#    An action containing a single quote is the case a naive un-escape corrupts.
#    `trap -p` prints the action single-quoted with embedded quotes written as
#    '\'', and undoing that is a pattern context where a lone backslash escapes
#    the next character instead of matching one. Getting it wrong hands the shell
#    an unbalanced string and the caller's handler dies at exit with
#    "unexpected EOF" -- worse than the loss it was meant to prevent.
cat > "$LK/hostquote.sh" <<'EOF'
trap 'echo "it'"'"'s-here"' EXIT
source "$ZB" 2>/dev/null
PROFILE_ROOT="$PR" PROFILE_ACTIVE=prof PROFILE_LOADED="" GENCRON="$GC" \
    load_active_profile >/dev/null 2>&1
EOF
rm -rf "$LK/tmp/hq"; mkdir -p "$LK/tmp/hq"
out="$(TMPDIR="$LK/tmp/hq" ZB="$ZFSBACKUP" PR="$LK/root" GC="$REPO/gen-cron.sh" \
       bash "$LK/hostquote.sh" 2>&1)"
if [ "$out" = "it's-here" ]; then
    ok "60: a caller action containing a quote is composed back intact"
else
    bad "60: a caller action containing a quote is composed back intact" "out=$out"
fi

# --- 61. setup-server records no account -- the account is per-relationship --
#
# Owner decision (2026-08-19): the account a relationship's jobs run as is stated
# on the command at add-client/deploy (--local-user, else root) and travels with
# the relationship. setup-server therefore writes only DEFAULT_TARGET and
# CRON_CONFIG -- NEVER LOCAL_USER, whatever --local-user it was handed.
# --local-user here is only a convenience that pre-CREATES a delegated account
# while bootstrapping the host; it records nothing. This replaced the earlier
# "setup-server records the host's one account" contract, whose recording is
# exactly what the account refactor removed.
SS="$WORK/setupserver"; mkdir -p "$SS/bin" "$SS/etc"
cat > "$SS/bin/zfs" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SS/bin/zfs"
cat > "$SS/deploy.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SS/deploy.log"
exit 0
EOF
chmod +x "$SS/deploy.sh"
: > "$SS/deploy.log"
out=$( PATH="$SS/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$SS/etc/zfs-backup.conf'
    DEPLOY='$SS/deploy.sh'
    ensure_cron_config() { :; }
    assert_config_readable_by_target() { :; }
    cmd_setup_server --target=tank/backups --config='$SS/jobs.conf' --local-user=root
" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^LOCAL_USER=' "$SS/etc/zfs-backup.conf" 2>/dev/null; then
    ok "61a: setup-server writes no LOCAL_USER even with --local-user=root -- the account is a relationship fact"
else
    bad "61a: setup-server writes no LOCAL_USER even with --local-user=root -- the account is a relationship fact" \
        "rc=$rc out=$out conf=$(cat "$SS/etc/zfs-backup.conf" 2>/dev/null)"
fi
if ! grep -q -- '--backup-user' "$SS/deploy.log" 2>/dev/null; then
    ok "61b: root is a decision, not a delegation -- no account is bootstrapped for it"
else
    bad "61b: root is a decision, not a delegation -- no account is bootstrapped for it" \
        "deploy args: $(cat "$SS/deploy.log" 2>/dev/null)"
fi

# 61c. --local-user=NAME pre-creates a delegated account (deploy --backup-user)
#      as a bootstrap convenience, but STILL records no host-wide account -- who
#      runs a relationship's jobs is that relationship's choice, not a file's.
rm -f "$SS/etc/zfs-backup.conf"; : > "$SS/deploy.log"
out=$( PATH="$SS/bin:$PATH" bash -c "
    source '$ZFSBACKUP'
    SERVER_CONF='$SS/etc/zfs-backup.conf'
    DEPLOY='$SS/deploy.sh'
    ensure_cron_config() { :; }
    assert_config_readable_by_target() { :; }
    cmd_setup_server --target=tank/backups --config='$SS/jobs.conf' --local-user=bkp
" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -q -- '--backup-user=bkp' "$SS/deploy.log" 2>/dev/null \
   && ! grep -q '^LOCAL_USER=' "$SS/etc/zfs-backup.conf" 2>/dev/null; then
    ok "61c: setup-server --local-user=bkp bootstraps the account but records no host-wide account"
else
    bad "61c: setup-server --local-user=bkp bootstraps the account but records no host-wide account" \
        "rc=$rc deploy=$(cat "$SS/deploy.log" 2>/dev/null) conf=$(cat "$SS/etc/zfs-backup.conf" 2>/dev/null)"
fi

# --- 62. P5: a sync relationship may not quietly take more than was asked -----
# Campaign finding P5 (docs/LAB5-POPRAWKI.md): one sync enrolment naming ONE
# dataset replicated THREE, one of them another relationship's. The chain is
# structural -- rux drops the dataset half of --source before add-client, so the
# source drafts its scope from an empty request, and an empty request drafts the
# whole pool inventory. Nothing downstream compared the two, because
# rux_verify_requested_scope asks only whether the request is COVERED (it is;
# the scope is wider), and wider is the direction that hurts: sync writes every
# dataset to the same path here.
#
# These assertions pin the comparison itself, not the enrolment chain that
# produces it -- that chain needs two live hosts and a committed scope file, and
# is the zfsbackup-live-pair manual obligation.

# 62a. the request is respected: itself and its children are not "extra"
out=$( RUX_SOURCE="src.example:tank/lab" \
       PEER_SAVED_DATASETS="tank/lab tank/lab/a tank/lab/a/b" \
       bash -c "source '$ZFSBACKUP'; sync_scope_extra_datasets" 2>&1 )
if [ -z "$out" ]; then
    ok "62a: sync scope check treats the requested dataset and its children as requested"
else
    bad "62a: sync scope check treats the requested dataset and its children as requested" "extra=[$out]"
fi

# 62b. THE BUG. The measured shape: asked for one, scope resolved to three.
out=$( RUX_SOURCE="src.example:hdd/lab4/src" \
       PEER_SAVED_DATASETS="hdd/lab4/src hdd/other rpool/ROOT/pve-1" \
       bash -c "source '$ZFSBACKUP'; sync_scope_extra_datasets" 2>&1 )
if [ "$out" = "hdd/other rpool/ROOT/pve-1" ]; then
    ok "62b: sync scope check names exactly the datasets outside the request"
else
    bad "62b: sync scope check names exactly the datasets outside the request" "extra=[$out]"
fi

# 62c. a prefix is not a parent -- tank/lab must not swallow tank/labour.
# Without the '/' in the pattern this is the classic unanchored-match bug that
# -X already cost this project once (see project_exclude_and_skip_parent).
out=$( RUX_SOURCE="src.example:tank/lab" \
       PEER_SAVED_DATASETS="tank/lab tank/labour" \
       bash -c "source '$ZFSBACKUP'; sync_scope_extra_datasets" 2>&1 )
if [ "$out" = "tank/labour" ]; then
    ok "62c: sync scope check anchors on the path boundary, not the string prefix"
else
    bad "62c: sync scope check anchors on the path boundary, not the string prefix" "extra=[$out]"
fi

# 62d. no recorded request (plain `add-client --mode=sync`) -> nothing to
#      compare, and the check invents nothing. The list is still LOGGED; that is
#      resolve_mode_datasets' job and is asserted separately at 62g.
out=$( RUX_SOURCE="" \
       PEER_SAVED_DATASETS="tank/a tank/b" \
       bash -c "source '$ZFSBACKUP'; sync_scope_extra_datasets" 2>&1 )
if [ -z "$out" ]; then
    ok "62d: with no recorded request the check declines to invent one"
else
    bad "62d: with no recorded request the check declines to invent one" "extra=[$out]"
fi

# 62e. --yes REFUSES a wider scope, and the refusal names the extras.
out=$( RUX_SOURCE="src.example:hdd/lab4/src" \
       PEER_SAVED_DATASETS="hdd/lab4/src hdd/other" \
       PEER_HOST="192.168.28.99" \
       bash -c "source '$ZFSBACKUP'; assert_sync_scope_within_request 1 seed" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'hdd/other' \
   && printf '%s' "$out" | grep -q 'Nothing was transferred'; then
    ok "62e: --yes refuses a scope wider than the request, and says which datasets"
else
    bad "62e: --yes refuses a scope wider than the request, and says which datasets" "rc=$rc out=$out"
fi

# 62f. WITHOUT --yes the same scope passes this gate. Deliberate, and the
#      difference is the whole design: an interactive run prints `Zrodla:` and
#      demands a `t`, so an operator who READS a wider list may still consent to
#      it (adopting an existing broader grant is a real thing to want). --yes has
#      no reader. Refusing both would be us overruling a decision that was made;
#      refusing neither is what shipped the bug.
out=$( RUX_SOURCE="src.example:hdd/lab4/src" \
       PEER_SAVED_DATASETS="hdd/lab4/src hdd/other" \
       PEER_HOST="192.168.28.99" \
       bash -c "source '$ZFSBACKUP'; assert_sync_scope_within_request 0 seed" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "62f: without --yes the gate defers to the interactive confirmation"
else
    bad "62f: without --yes the gate defers to the interactive confirmation" "rc=$rc out=$out"
fi

# 62g. the resolved list is logged UNCONDITIONALLY. Source-grep, because the
#      producer needs ssh and a committed scope file to run. The point is the
#      placement: cmd_seed's own `Zrodla:` line sits inside `if [ "$yes" -ne 1 ]`,
#      so before this the list was invisible on exactly the runs that had no
#      human to see it.
rmd=$(awk '/^resolve_mode_datasets\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
if printf '%s\n' "$rmd" | grep -q 'log "scope on \$LOAD_HOST resolves to'; then
    ok "62g: resolve_mode_datasets logs the resolved dataset list unconditionally"
else
    bad "62g: resolve_mode_datasets logs the resolved dataset list unconditionally" "$rmd"
fi

# 62h. both consumers gate. seed moves the data once; activate is what makes an
#      unrequested dataset keep arriving every hour. One without the other
#      leaves a reachable path -- activate runs directly on a seeded client.
for fn in cmd_seed cmd_activate_client; do
    body=$(awk -v F="$fn" 'index($0, F "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
    if printf '%s\n' "$body" | grep -q 'assert_sync_scope_within_request "\$yes"'; then
        ok "62h: $fn gates on the requested sync scope"
    else
        bad "62h: $fn gates on the requested sync scope" "not found in $fn"
    fi
done

# --- 63. the extracted decision layer: which config, and as which account ----
# Five commands used to answer these two questions for themselves. The answers
# had diverged in ways nothing could see, and both of the last two days' live
# bugs came out of that: read_server_conf clearing LOCAL_USER (two callers
# worked around it, the third did not know to), and P10 (two callers resolve the
# config with no adoption step and no flag to aim them).
#
# These assertions pin two separate things, and the difference matters:
#   63a-63f  the LADDERS themselves, so a future edit cannot quietly reorder one
#   63g-63h  that each command still asks for the SAME ladder it asked for
#            before the extraction -- this commit moves the decision, it does
#            not change any answer.
ctx() {   # <policy> <x-config> <x-user> <r-config> <r-user> [env assignments...]
    local pol="$1" xc="$2" xu="$3" rc="$4" ru="$5"; shift 5
    env "$@" bash -c "
        source '$ZFSBACKUP'
        crontab_for_target() { printf '%s\n' \"\${FAKE_CRONTAB:-}\"; }
        default_cron_config() { echo /etc/zfs-snapshot-all/jobs.HOST.conf; }
        # Per-account managed blocks. FAKE_BLOCK_<account>=<config>; an account
        # with no variable has no managed block, which is what the real
        # cron_source_for_user signals with a non-zero return.
        cron_source_for_user() {
            local v=\"FAKE_BLOCK_\$1\"
            [ -n \"\${!v:-}\" ] || return 1
            printf '%s' \"\${!v}\"
        }
        cron_known_accounts() { printf '%s\n' \${FAKE_ACCOUNTS:-root}; }
        cron_context_resolve '$pol' '$xc' '$xu' '$rc' '$ru'
        printf '%s|%s\n' \"\$CRON_CTX_FILE\" \"\$CRON_CTX_USER\"
    " 2>&1
}

# 63a. the config ladder, top rung: an explicit --config outranks everything.
got=$(ctx adopt /explicit.conf "" /recorded.conf "" CRON_CONFIG=/server.conf)
if [ "$got" = "/explicit.conf|" ]; then
    ok "63a: an explicit --config outranks the record and server.conf"
else
    bad "63a: an explicit --config outranks the record and server.conf" "got=$got"
fi

# 63b. the record outranks server.conf. This is the rung whose ABSENCE was the
#      2026-08-09 metropolis bug: read_server_conf blanked the recorded value and
#      remove-client then read the client as "never activated".
got=$(ctx adopt "" "" /recorded.conf "" CRON_CONFIG=/server.conf)
if [ "$got" = "/recorded.conf|" ]; then
    ok "63b: a value recorded with the relationship outranks server.conf"
else
    bad "63b: a value recorded with the relationship outranks server.conf" "got=$got"
fi

# 63c. policy 'adopt' takes the '# Source:' of the block ALREADY INSTALLED
#      rather than defaulting. A crontab has ONE managed block, so defaulting
#      instead would DELETE every job the installed file describes.
got=$(ctx adopt "" "" "" "" FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.HOST.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.HOST.v4.conf|" ]; then
    ok "63c: policy 'adopt' adopts the installed block's source instead of defaulting"
else
    bad "63c: policy 'adopt' adopts the installed block's source instead of defaulting" "got=$got"
fi

# 63d. policy 'host' is GONE. It was recorded -> server.conf -> host default
#      with no adoption, three callers used it, and none of them meant to: it
#      was not a decision, it was the absence of one, and it is what P10
#      measured. An unknown policy must be refused, not silently treated as
#      one of the survivors -- otherwise removing it would be a no-op for any
#      caller that still asked for it.
out=$(ctx host "" "" "" "")
if printf '%s' "$out" | grep -q "unknown policy 'host'"; then
    ok "63d: policy 'host' is gone, and asking for it is refused rather than ignored"
else
    bad "63d: policy 'host' is gone, and asking for it is refused rather than ignored" "got=$out"
fi

# 63e. policy 'record' leaves an unrecorded config EMPTY. remove-client keys its
#      whole cron-cleanup branch on that emptiness meaning "never activated";
#      a default here would have teardown rewrite a config it never installed.
got=$(ctx record "" "" "" "" "FAKE_CRONTAB=# Source: /whatever.conf -- x")
if [ "$got" = "|" ]; then
    ok "63e: policy 'record' returns nothing rather than inventing a config"
else
    bad "63e: policy 'record' returns nothing rather than inventing a config" "got=$got"
fi

# 63f. the ACCOUNT ladder: record, then the manifest, then root -- and never
#      server.conf, which is why LOCAL_USER=... is set in the environment here
#      and still does not win. The account is a fact of the RELATIONSHIP.
got=$(ctx adopt "" "" "" acctfromrecord PEER_SAVED_LOCAL_USER=acctfrommanifest)
[ "$got" = "/etc/zfs-snapshot-all/jobs.HOST.conf|acctfromrecord" ] \
    && ok "63f: the account comes from the record when it has one" \
    || bad "63f: the account comes from the record when it has one" "got=$got"
got=$(ctx adopt "" "" "" "" PEER_SAVED_LOCAL_USER=acctfrommanifest)
[ "$got" = "/etc/zfs-snapshot-all/jobs.HOST.conf|acctfrommanifest" ] \
    && ok "63f: it falls back to the pairing manifest when the record predates the field" \
    || bad "63f: it falls back to the pairing manifest when the record predates the field" "got=$got"

# 63g. Every config writer goes through the one decision layer. A writer that
#      re-derives its own answer is the exact shape this extraction removed.
#
#      ASSERTED PER FUNCTION, not by equal counts. Equal counts were a proxy that
#      held only while writers were the sole callers of the resolver, and it
#      stopped holding on 2026-08-29 when list-replicas -- a READER -- had to
#      resolve too, so that a front end is shown the same config an install would
#      write. The proxy then failed for a case that is correct, which is how a
#      tripwire gets loosened to go green. Checking the real property instead
#      makes it stronger: a reader may resolve without writing, but no writer may
#      write without resolving.
writer_gap=$(awk '
    /^[a-z_]+\(\) \{/ { fn=$1; has_w=0; has_r=0; next }
    /^\}/ { if (fn != "" && has_w && !has_r) print fn; fn=""; next }
    fn != "" && /^[ \t]*atomic_replace_and_install / { has_w=1 }
    fn != "" && /^[ \t]*cron_context_resolve [a-z]/  { has_r=1 }
' "$ZFSBACKUP")
if [ -z "$writer_gap" ]; then
    ok "63g: EVERY function that installs a config also resolved the context first"
else
    bad "63g: EVERY function that installs a config also resolved the context first" \
        "writes without resolving: $(printf '%s' "$writer_gap" | tr '\n' ' ')"
fi
# ...and the counts stay pinned on top of it, because the property above cannot
# see a writer that resolves in a HELPER it calls -- correct, but no longer the
# one decision layer. A new number here is a prompt to look, not a failure to
# paper over.
writers=$(grep -c '^\s*atomic_replace_and_install ' "$ZFSBACKUP")
resolvers=$(grep -c '^\s*cron_context_resolve [a-z]' "$ZFSBACKUP")
# 9 writers / 12 resolvers, MEASURED on the merged tree rather than carried over
# from either side. main had reached 8/11 and this branch adds set-bandwidth,
# which rewrites every active relationship of one pair in a single transaction:
# 9. The resolver count moves with it because a writer that does not resolve is
# a writer aimed at a guessed config.
#
# The numbers are pinned rather than merely compared so that ADDING a config
# writer forces this line to be edited -- which is the moment to prove the new
# writer is aimed at a config instead of guessing one. Bumping it is the
# acknowledgement, not a formality. Equality between the two was never the
# property: the gap is READERS (list-replicas, run-replicas,
# install-media-trigger) which resolve the same config an install would write,
# so that what they show or run is what cron would.
# 13 since 2026-09-02: purge-replica-copy joined that reader set. It resolves
# the config to learn WHERE the copy lives and never writes it back, which is
# why the writer count is unchanged -- and it is the acknowledgement this
# pinned number exists to force.
if [ "$writers" -eq 9 ] && [ "$resolvers" -eq 13 ]; then
    ok "63g: all six config writers resolve through cron_context_resolve"
else
    bad "63g: all six config writers resolve through cron_context_resolve" \
        "atomic_replace_and_install call sites=$writers cron_context_resolve call sites=$resolvers"
fi

# 63h. and each one asks for the policy it asked for BEFORE the extraction.
#      This is the assertion that makes "no behaviour change" checkable rather
#      than asserted: get one of these wrong and a command silently changes
#      which file it writes.
while read -r fn want; do
    body=$(awk -v F="$fn" 'index($0, F "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
    # Matched on the VARIABLE, not through a pipe. `printf | grep -q` over a
    # 45 KB body races: grep -q exits on the first match and printf takes EPIPE
    # on the rest -- "write error: Broken pipe" on the runner, never here. The
    # body was byte-identical to the commit where this last passed, so what
    # failed was the harness, not its subject. A case match has no pipe.
    case "$body" in
        *"cron_context_resolve $want "*)
            ok "63h: $fn uses policy '$want'" ;;
        *)
            bad "63h: $fn uses policy '$want'" \
                "$(printf '%s\n' "$body" | grep -n 'cron_context_resolve' || echo 'no call at all')" ;;
    esac
done <<'POLICIES'
cmd_local_backup adopt
cmd_activate_client adopt
cmd_migrate_profile aim
cmd_audit_source_retention aim
cmd_remove_client record
POLICIES

# --- 64. P10 closed: aim it, or be told you have not ------------------------
# Measured on pve2 and pve1 (2026-08-21): root's crontab runs the lab from
# jobs.<host>.conf while the delegated account runs production from
# jobs.<host>.v4.conf. `audit-source-retention` reported "1 active pull
# dataset, nothing to add" -- describing the lab, never opening production.
# It was not wrong about anything it looked at. It looked at one of two.
#
# The shape of the fix matters: it does NOT pick. Picking would be the same
# mistake with better odds. It refuses, names both, and offers two ways to say
# which -- which is why the flags had to come with it.

# 64a. THE MEASURED CASE. Two accounts, two blocks, nothing says which.
out=$(ctx aim "" "" "" "" \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.pve2.conf \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve2.v4.conf)
if printf '%s' "$out" | grep -q 'more than one account' \
   && printf '%s' "$out" | grep -q 'jobs.pve2.conf' \
   && printf '%s' "$out" | grep -q 'jobs.pve2.v4.conf' \
   && printf '%s' "$out" | grep -q 'Nothing was read and nothing was changed'; then
    ok "64a: two accounts with managed blocks and no aim -> refuses, naming BOTH"
else
    bad "64a: two accounts with managed blocks and no aim -> refuses, naming BOTH" "got=$out"
fi

# 64b. --local-user answers it. The refusal has to be answerable or it is just
#      a wall; this is the half that makes 64a a question.
got=$(ctx aim "" zfsbackup "" "" \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.pve2.conf \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve2.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve2.v4.conf|zfsbackup" ]; then
    ok "64b: --local-user aims it at that account's own block"
else
    bad "64b: --local-user aims it at that account's own block" "got=$got"
fi

# 64b2. --local-user=root is an ANSWER, not an absence. This is the one the
#       refusal itself recommends -- "use root's own jobs with --local-user=root"
#       -- and until 2026-08-21 it landed straight back in the refusal, because
#       the parsers blanked a literal "root" to "" and the resolver could no
#       longer tell it from silence. A guard whose printed remedy it rejects is
#       a dead end, which is worse than no guard: it stops the work AND misleads
#       about how to continue. Found live on pve2 and pve1 by exit code -- the
#       output looked like a clean audit, and only `echo $?` disagreed.
got=$(ctx aim "" root "" "" \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.pve2.conf \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve2.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve2.conf|" ]; then
    ok "64b2: --local-user=root escapes the refusal that recommends it, and picks root's block"
else
    bad "64b2: --local-user=root escapes the refusal that recommends it, and picks root's block" "got=$got"
fi

# 64b3. And the parsers must not blank it before the resolver ever sees it --
#       source-grep, because that is where the defect lived, not in the resolver.
for fn in cmd_migrate_profile cmd_audit_source_retention; do
    body=$(awk -v F="$fn" 'index($0, F "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
    if ! printf '%s\n' "$body" | grep -q 'local_user_arg="" ;;'; then
        ok "64b3: $fn passes an explicit root through instead of blanking it"
    else
        bad "64b3: $fn passes an explicit root through instead of blanking it" \
            "still blanks root before the resolver can see it"
    fi
done

# 64c. --config answers it too, and wins outright -- no crontab is consulted.
got=$(ctx aim /etc/mine.conf "" "" "" \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.pve2.conf \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve2.v4.conf)
if [ "$got" = "/etc/mine.conf|" ]; then
    ok "64c: --config answers it without consulting any crontab"
else
    bad "64c: --config answers it without consulting any crontab" "got=$got"
fi

# 64d. ONE account with a block is not ambiguous -- it adopts and says so.
#      Without this the refusal would fire on every single-relationship host,
#      which is most of them, and the fix would be worse than the defect.
got=$(ctx aim "" "" "" "" \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve9.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve9.conf|zfsbackup" ]; then
    ok "64d: a single managed block is adopted, account and all, with no refusal"
else
    bad "64d: a single managed block is adopted, account and all, with no refusal" "got=$got"
fi

# 64e. NO managed block anywhere -- a fresh host -- still falls back to the
#      default. A first install must not be blocked by a check about second
#      relationships.
got=$(ctx aim "" "" "" "" "FAKE_ACCOUNTS=root zfsbackup")
if [ "$got" = "/etc/zfs-snapshot-all/jobs.HOST.conf|" ]; then
    ok "64e: a host with no managed block at all still gets the default"
else
    bad "64e: a host with no managed block at all still gets the default" "got=$got"
fi

# 64f. a RELATIONSHIP knows its own account, so the ambiguity check must not
#      fire for it: activate-client on a two-relationship host is normal.
got=$(ctx adopt "" "" "" zfsbackup \
      "FAKE_ACCOUNTS=root zfsbackup" \
      FAKE_BLOCK_root=/etc/zfs-snapshot-all/jobs.pve2.conf \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve2.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve2.v4.conf|zfsbackup" ]; then
    ok "64f: a recorded account is an answer, so a relationship never sees the refusal"
else
    bad "64f: a recorded account is an answer, so a relationship never sees the refusal" "got=$got"
fi

# 64g. both orphan commands now take the two flags. Source-grep, because
#      reaching their parsers needs a config, a crontab and a peer.
for fn in cmd_migrate_profile cmd_audit_source_retention; do
    body=$(awk -v F="$fn" 'index($0, F "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
    if printf '%s\n' "$body" | grep -q -- '--config=\*)' \
       && printf '%s\n' "$body" | grep -q -- '--local-user=\*)'; then
        ok "64g: $fn accepts --config and --local-user"
    else
        bad "64g: $fn accepts --config and --local-user" "not both found in $fn"
    fi
done

# 64h. Where the candidate accounts come from -- and this assertion is the one
#      that was WRONG, caught live on pve2 rather than by CI.
#
#      It used to pin "our own records only, never /home or passwd", on the
#      reasoning that an account exists for reasons unrelated to this project
#      and claiming one because it has a home directory is a local fact standing
#      in for a decision. That reasoning is still right -- /home and passwd are
#      still not read. The PREMISE was wrong: it assumed every account running
#      our jobs got there through a relationship. Production on this fleet did
#      not; those are plain local jobs older than the relationship model, named
#      by no record of ours. So on the very host P10 was measured against, the
#      refusal did not fire and the tool called root "the only account".
#
#      The crontab spool answers "who has a crontab" and nothing more; the
#      CALLER filters on our own block marker, so an unrelated account cannot be
#      claimed -- it would have to be running a block we wrote.
body=$(awk 'index($0,"cron_known_accounts() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
if printf '%s\n' "$body" | grep -q 'CLIENTS_DIR' \
   && printf '%s\n' "$body" | grep -q 'PEER_STATE_DIR' \
   && printf '%s\n' "$body" | grep -q 'CRON_SPOOL_DIRS' \
   && ! printf '%s\n' "$body" | grep -qE '/home|/etc/passwd|getent'; then
    ok "64h: candidates come from our records AND the crontab spool, never /home or passwd"
else
    bad "64h: candidates come from our records AND the crontab spool, never /home or passwd" "$body"
fi

# 64i. An account with a crontab but NO managed block of ours is not a
#      candidate for anything. The spool is where the names come from; our own
#      marker is what makes one ours. Without this, adding the spool would have
#      turned every unrelated cron user into an ambiguity and the refusal would
#      fire on hosts that have no second relationship at all.
got=$(ctx aim "" "" "" "" \
      "FAKE_ACCOUNTS=root someunrelateduser zfsbackup" \
      FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve9.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve9.conf|zfsbackup" ]; then
    ok "64i: a crontab without one of our blocks is not treated as a second relationship"
else
    bad "64i: a crontab without one of our blocks is not treated as a second relationship" "got=$got"
fi

# 64z. THE LAB6 R1 REGRESSION -- the one that reached production before any
#      test did. Policy 'adopt' (a RELATIONSHIP command), nobody named an
#      account, and another account carries the only managed block on the
#      host. The answer must be ROOT and root's own resolution -- never the
#      other account. On live pve1 (2026-08-21) the pre-fix resolver adopted
#      production's zfsbackup here, and a fresh lab enrolment installed its
#      cron lines into the production account's crontab and v4 config, with
#      root-owned key paths that would have failed at :01. Reverted live in
#      minutes. This is the fourth defect a live host found after green CI,
#      and the third my own test had pinned as correct behaviour (64d).
#
#      Stated once, asserted here: for a relationship, "nobody named an
#      account" IS the answer; a host-wide fact must never become a
#      relationship's identity.
got=$(ctx adopt "" "" "" ""       "FAKE_ACCOUNTS=root zfsbackup"       FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve1.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.HOST.conf|" ]; then
    ok "64z: a fresh relationship with no account resolves to ROOT, never to whoever else has jobs"
else
    bad "64z: a fresh relationship with no account resolves to ROOT, never to whoever else has jobs" "got=$got"
fi

# 64z2. Positive control: the SAME shape under policy 'aim' still aims -- the
#       host-scoped commands keep their P10 behaviour, the fence is the policy.
got=$(ctx aim "" "" "" ""       "FAKE_ACCOUNTS=root zfsbackup"       FAKE_BLOCK_zfsbackup=/etc/zfs-snapshot-all/jobs.pve1.v4.conf)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve1.v4.conf|zfsbackup" ]; then
    ok "64z2: control -- the same shape under 'aim' still aims at the single block"
else
    bad "64z2: control -- the same shape under 'aim' still aims at the single block" "got=$got"
fi

# --- 65. the signed scope is the contract (owner decision A, LAB6-F1) --------
# LAB6 R1 measured the split this closes: the request named hdd/lab6/tree, the
# auto-draft carried include_children=yes, the source SIGNED four datasets --
# and the job replicated two. tree/a and tree/b had a signed grant, zero
# snapshots, and every report was green. When a committed scope exists it now
# supersedes the recorded request for every relationship kind; a legacy
# relationship with no committed scope keeps its recorded list, because there
# is no signed contract to supersede it with.
rmd_env() {   # <scope-exists 0|1> <saved-datasets> <scope-body-file> -> "list|recursive-roots"
    local sx="$1" sd="$2" sc="$3"
    local SB="$WORK/rmd-stub"; mkdir -p "$SB"
    cat > "$SB/ssh" <<'EOS'
#!/bin/sh
case "$*" in
  *"test -s"*) exit ${SCOPE_EXISTS:-1} ;;
  *"zfs list"*) printf '%s
' "tank/x" "tank/x/kid" ;;
esac
EOS
    chmod +x "$SB/ssh"
    PATH="$SB:$PATH" SCOPE_EXISTS="$sx" ZB="$ZFSBACKUP" SD="$sd" SCOPEF="$sc" bash -c '
        source "$ZB"
        LOAD_KEYFILE=/dev/null LOAD_PORT=22 LOAD_ALIAS=a LOAD_ALIAS_KH=/dev/null
        LOAD_ACCOUNT=u LOAD_HOST=h COLLECTOR_LABEL=me
        fetch_committed_scope() { cat "$SCOPEF" > "$1"; }
        PEER_SAVED_MODE=""
        PEER_SAVED_DATASETS="$SD"
        resolve_mode_datasets >/dev/null 2>&1             && printf "%s|%s" "$PEER_SAVED_DATASETS" "${PEER_SAVED_RECURSIVE_ROOTS:-}"
    '
}
SOLID="$WORK/scope-solid"; NARROW="$WORK/scope-narrow"
cat > "$SOLID" <<'EOS'
[dataset:tank/x]
include_parent = yes
include_children = yes
EOS
cat > "$NARROW" <<'EOS'
[dataset:tank/x]
include_parent = yes
include_children = yes
exclude = tank/x/kid
EOS

got=$(rmd_env 1 "tank/x" "$SOLID")
if [ "$got" = "tank/x|" ]; then
    ok "65a: no committed scope -> the recorded request stays the contract (legacy)"
else
    bad "65a: no committed scope -> the recorded request stays the contract (legacy)" "got=[$got]"
fi

# 65b. A SOLID signed root stays ONE entry, marked recursive -- the ENGINE
#      re-expands it on the source at every run (snapget -R does a remote
#      zfs list -r before each transfer), so a child created tomorrow joins
#      at the next cron tick. The owner rejected the frozen-enumeration
#      boundary in exactly those words; this is the assertion that holds him
#      to getting what he asked for.
got=$(rmd_env 0 "tank/x" "$SOLID")
if [ "$got" = "tank/x|tank/x" ]; then
    ok "65b: a solid signed root collapses to one RECURSIVE entry (engine expands at run time)"
else
    bad "65b: a solid signed root collapses to one RECURSIVE entry (engine expands at run time)" "got=[$got]"
fi

# 65c. A hand-NARROWED root cannot ride engine recursion (the engine would
#      take the whole subtree, excludes and all), so it enumerates now and is
#      NOT marked -- its membership honestly freezes at activation, and
#      resolve says so in its log.
got=$(rmd_env 0 "tank/x" "$NARROW")
if [ "$got" = "tank/x|" ]; then
    ok "65c: a hand-narrowed root enumerates without the recursive marker"
else
    bad "65c: a hand-narrowed root enumerates without the recursive marker" "got=[$got]"
fi

got=$(rmd_env 0 "" "$SOLID")
if [ "$got" = "|" ]; then
    ok "65d: empty request without mode stays a no-op"
else
    bad "65d: empty request without mode stays a no-op" "got=[$got]"
fi

# --- 66. one config = one account (LAB6-F2) ----------------------------------
# Measured on pve1: a bkpsvc relationship's activation resolved to the HOST
# default jobs.pve1.conf -- the same file root's R1 renders from. A config
# renders WHOLE into one account's crontab (single-writer design, no
# per-section account filter), so sharing the file means the next
# regeneration for EITHER account installs BOTH relationships' jobs under
# itself -- one of them on keys it cannot read. Only withheld consent stopped
# it; these assertions make the stop structural.
ctx2() {   # <x-config> <x-user> [env...] -> "file|user" or the refusal
    local xc="$1" xu="$2"; shift 2
    env "$@" ZB="$ZFSBACKUP" XC="$xc" XU="$xu" bash -c '
        source "$ZB"
        cron_known_accounts() { printf "%s
" root bkpsvc; }
        cron_source_for_user() { [ "$1" = root ] && { echo /etc/zfs-snapshot-all/jobs.pve1.conf; return 0; }; return 1; }
        hostname() { echo pve1; }
        cron_context_resolve adopt "$XC" "$XU" "" ""             && printf "%s|%s" "$CRON_CTX_FILE" "$CRON_CTX_USER"
    ' 2>&1
}

# 66a. a non-root account with nothing recorded gets its OWN default file.
got=$(ctx2 "" bkpsvc)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve1.bkpsvc.conf|bkpsvc" ]; then
    ok "66a: a delegated account defaults to its own jobs.<host>.<account>.conf"
else
    bad "66a: a delegated account defaults to its own jobs.<host>.<account>.conf" "got=$got"
fi

# 66b. root keeps the historical bare name -- fleet compatibility.
got=$(ctx2 "" root)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve1.conf|" ]; then
    ok "66b: root keeps the historical jobs.<host>.conf"
else
    bad "66b: root keeps the historical jobs.<host>.conf" "got=$got"
fi

# 66c. EXPLICITLY naming another account's live config is refused, not obeyed
#      -- the flag names a file, but the file already answers to somebody.
out=$(ctx2 /etc/zfs-snapshot-all/jobs.pve1.conf bkpsvc)
if printf '%s' "$out" | grep -q "already drives root's managed crontab block"    && printf '%s' "$out" | grep -q 'Nothing was read and nothing was changed'; then
    ok "66c: another account's config is refused even when named explicitly"
else
    bad "66c: another account's config is refused even when named explicitly" "got=$out"
fi

# 66d. the SAME account's own file passes -- the guard is about crossing
#      accounts, not about files having owners.
got=$(ctx2 /etc/zfs-snapshot-all/jobs.pve1.conf root)
if [ "$got" = "/etc/zfs-snapshot-all/jobs.pve1.conf|" ]; then
    ok "66d: an account naming its own config passes the ownership guard"
else
    bad "66d: an account naming its own config passes the ownership guard" "got=$got"
fi

# --- 67. the family probe is ONE function, depth-aware (LAB6-F4, two rounds) --
# Round one made the seed passive when the source already carries an
# automated_* family. Round two -- caught by the clean pass itself -- was the
# probe's DEPTH: -d 1 on a RECURSIVE root reads "fresh" when the family lives
# only on descendants (the measured chain shape: R3 stamps tree/child deep
# inside, the chain root is never snapshotted), so the seed re-stamped all six
# datasets; and the emit-time passivity probe had the same blind spot, which
# meant fixing the seed alone would have flipped the CRON line active instead.
# One helper now: -r for recursive roots, -d 1 for enumerated datasets, used by
# the seed, the catch-up and the emit-time decision alike.

# 67a. recursive root, family only on a descendant -> the probe SEES it.
fam_probe() {   # <recursive-roots> -> PASYWNY|AKTYWNY
    local SB="$WORK/fam-stub"; mkdir -p "$SB"
    cat > "$SB/ssh" <<'EOS'
#!/bin/sh
case "$*" in
  *" -r "*) printf '%s
' "tank/mid/deep@automated_hourly_x" ;;
  *" -d 1 "*) : ;;
esac
EOS
    chmod +x "$SB/ssh"
    PATH="$SB:$PATH" RR="$1" ZB="$ZFSBACKUP" bash -c '
        source "$ZB"
        LOAD_KEYFILE=/k LOAD_ALIAS=a LOAD_ALIAS_KH=/kh LOAD_PORT=22 LOAD_ACCOUNT=u LOAD_HOST=h
        PEER_SAVED_RECURSIVE_ROOTS="$RR"
        source_family_exists tank/mid && echo PASYWNY || echo AKTYWNY'
}
got=$(fam_probe tank/mid)
[ "$got" = PASYWNY ]     && ok "67a: a recursive root sees a family living only on its descendants"     || bad "67a: a recursive root sees a family living only on its descendants" "got=$got"

# 67b. the SAME topology, enumerated root -> -d 1, correctly blind to the
#      descendant (its children are separate list entries probed on their own).
got=$(fam_probe "")
[ "$got" = AKTYWNY ]     && ok "67b: an enumerated dataset keeps the -d 1 probe (children probed separately)"     || bad "67b: an enumerated dataset keeps the -d 1 probe (children probed separately)" "got=$got"

# 67c. every consumer goes through the ONE helper -- copies of this probe drift
#      exactly like everything else this campaign measured. Source-grep: one
#      implementation, and no caller keeps a private "-t snapshot" probe.
#
# This used to allow a SECOND, looser query: activate-client's dry-run had its
# own newest-matching-snapshot lookup, excused here as answering WHICH rather
# than WHETHER. LAB6 pass 7 F-2 measured what that excuse cost. The copy
# hardcoded -d 1 while the helper follows the recursion contract, so on the
# chain-middle shape (family only on descendants) ONE activation run said
# "already carries an automated_* family -- PASSIVE" and then "no snapshot
# reachable" about the same dataset, and the relationship could not be
# activated although its installed line was healthy. WHICH and WHETHER are the
# same lookup: the helper now returns the newest match and existence is "did it
# return anything", so there is one implementation for both questions.
#
# The implementation is the single remote `zfs list -H -t snapshot` in the file.
# TWO probe implementations now, and they answer questions on opposite sides:
# source_family_newest asks a REMOTE source over ssh, local_newest_snapshot asks
# this collector's own copy (move-to-client's guid proof, 2026-08-29). The
# remote one cannot serve the local case -- it always opens ssh to
# LOAD_ACCOUNT@LOAD_HOST. Both are NAMED functions with their callers counted
# below, so a third, hand-rolled one still trips this.
n_impl=$(grep -c 'zfs list -H -t snapshot' "$ZFSBACKUP")
n_local=$(grep -c 'local_newest_snapshot "\$' "$ZFSBACKUP")
# The old idiom must be gone entirely, not merely reduced -- a lingering
# `grep -q '@automated_'` would be a second existence test with its own depth.
n_inline=$(grep -c "grep -q '@automated_'" "$ZFSBACKUP")
# seed, catch-up, emit-time passivity -- unchanged, still through the wrapper.
n_calls=$(grep -c 'source_family_exists "\$' "$ZFSBACKUP")
# the wrapper itself, plus activate-client's rehearsal (the ex-copy).
n_newest=$(grep -c 'source_family_newest "\$' "$ZFSBACKUP")
if [ "$n_impl" -eq 2 ] && [ "$n_local" -eq 1 ] && [ "$n_inline" -eq 0 ] &&    [ "$n_calls" -eq 3 ] && [ "$n_newest" -eq 2 ]; then
    ok "67c: one probe implementation, every consumer through it (seed, catch-up, emit, activation rehearsal)"
else
    bad "67c: one probe implementation, every consumer through it (seed, catch-up, emit, activation rehearsal)"         "impl=$n_impl local-callers=$n_local inline=$n_inline exists-callers=$n_calls newest-callers=$n_newest"
fi

# 67c2. the activation rehearsal specifically: it must not re-derive the depth.
#       F-2's copy was invisible to 67c above because it looked like a
#       different question; what made it wrong was `-d 1` written out by hand
#       in a block whose installed line carries -R. Pin the absence.
#       Comments are stripped first: the block explains the old `-d 1` in prose
#       on purpose, and a test that cannot tell the explanation from the code
#       would forbid writing down why.
dryrun_block=$(awk '/dry-run test of each dataset/{f=1} f{print} f&&/^    if \[ "\$failed"/{exit}' "$ZFSBACKUP"     | grep -v '^[[:space:]]*#')
if printf '%s
' "$dryrun_block" | grep -q -- '-d 1'; then
    bad "67c2: the activation rehearsal does not hardcode a probe depth"         "'-d 1' still appears in the dry-run block"
else
    ok "67c2: the activation rehearsal does not hardcode a probe depth"
fi

# 67d. both transfer sites still carry the passive branch itself.
for fn in cmd_seed cmd_final_catchup; do
    body=$(awk -v F="$fn" 'index($0, F "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$ZFSBACKUP")
    # 2026-08-23: the family root is profile-derived now (profile_family_root),
    # so the branch adopts with -m "$seed_root" -e instead of the automated_
    # literal this test used to pin. The question is unchanged: the branch
    # must still exist and still adopt (-e) under the family name.
    if printf '%s
' "$body" | grep -q 'seed_flags=(-m "\$seed_root" -e)'; then
        ok "67d: $fn seeds passively when the family exists"
    else
        bad "67d: $fn seeds passively when the family exists" "brak galezi w $fn"
    fi
done

# 67e. the engine half (owner-authorized unfreeze, snapget v2.70): an
#      under -R -e ANY member with no matching family (the recv -p path
#      containers, and equally a bare root whose family lives in its
#      descendants) is scaffolding -- skipped with a log, never a failure --
#      and an aggregate guard fails the run only when NOTHING in the whole
#      expansion had a family. A plainly named dataset (no -R) keeps the hard
#      error. Source-grep of the frozen file; the live proof is the chain's
#      R2 running green.
SG="$(dirname "$ZFSBACKUP")/snapget.sh"
if grep -q 'scaffolding under -R -e, skipped' "$SG"    && grep -q 'ADOPT_SKIPPED' "$SG"    && grep -q 'No matching family anywhere under the requested root' "$SG"    && grep -q 'log 0 "No source snapshots found"' "$SG"; then
    ok "67e: snapget skips family-less expanded children under -e, roots still fail hard"
else
    bad "67e: snapget skips family-less expanded children under -e, roots still fail hard"         "$(grep -c 'scaffolding, skipped' "$SG") skip / $(grep -c 'REQUESTED_ROOTS' "$SG") roots"
fi

# 63i. an unknown policy is refused rather than silently treated as one of them.
out=$(ctx nonsense "" "" "" ""); rc=$?
if printf '%s' "$out" | grep -q "unknown policy"; then
    ok "63i: an unknown policy is refused by name"
else
    bad "63i: an unknown policy is refused by name" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
# 68. THE PROBE MUST NOT ANSWER A QUESTION IT COULD NOT ASK.
#
# Found on review and measured live 2026-08-22 on the LAB6 chain, with a working
# positive control:
#
#   live channel, dataset WITH a family    -> exists: yes
#   live channel, dataset with no family   -> exists: no
#   SAME dataset with a family, host down  -> exists: no    <-- the defect
#
# The seed call site reads "no family" as licence for an ACTIVE seed, which
# stamps snapshots on a source this relationship may not own. That is how
# LAB6-F4's damage begins: the chain middle gets re-stamped, its owner's GFS
# ladder destroys its own base, and the pulls wedge on a GUID refusal. So an
# unreachable source must be its own answer, and every caller must refuse on it.
#
# Behavioural, not a source-grep: ssh is stubbed per case and the real functions
# run. 67c/67c2 pin the SHAPE; these pin what it DOES.
probe_case() {   # <family-stub-body> <scope-stub-body> -> "<exists-rc> <scope-rc>"
    (
        source "$ZFSBACKUP"
        # One stub, two questions: it dispatches on the remote command the way
        # the real sshd would, so each function gets its own answer and the
        # cases below can vary them independently.
        __fam="$1"; __scope="$2"
        ssh() {
            case "$*" in
                *"zfs list"*) eval "$__fam" ;;
                *"test -s"*)  eval "$__scope" ;;
                *) return 127 ;;
            esac
        }
        load_ssh_opts() { LOAD_SSH_OPTS=(); }
        peer_scope_granted_hash_path() { echo /tmp/whatever.sha256; }
        LOAD_ACCOUNT=probe; LOAD_HOST=probe.invalid; COLLECTOR_LABEL=probe
        PEER_SAVED_RECURSIVE_ROOTS=""
        source_family_exists rpool/x; e=$?
        has_committed_scope; s=$?
        echo "$e $s"
    ) 2>/dev/null
}

# 68a. POSITIVE CONTROL -- the source answers and there IS a family / a sidecar.
got=$(probe_case 'printf "rpool/x@automated_hourly_2026-01-01_00-00-00	1735689600
"; return 0' 'return 0')
if [ "$got" = "0 0" ]; then
    ok "68a: source answers, family present + scope signed -> 0 0"
else
    bad "68a: source answers, family present + scope signed -> 0 0" "dostalem: $got"
fi

# 68b. NEGATIVE CONTROL -- the source answers, and the answer is "nothing here".
#      An existing dataset with no snapshots is rc 0 + empty output; a missing
#      sidecar is `test -s` exiting 1. Both are real answers, both may continue.
got=$(probe_case 'return 0' 'return 1')
if [ "$got" = "1 1" ]; then
    ok "68b: source answers 'nothing here' -> 1 1 (no family, no scope)"
else
    bad "68b: source answers 'nothing here' -> 1 1 (no family, no scope)" "dostalem: $got"
fi

# 68c. THE DEFECT -- ssh's own failure status. Must differ from 68b.
got=$(probe_case 'return 255' 'return 255')
if [ "$got" = "2 2" ]; then
    ok "68c: SSH transport error -> 2 2 (unknown), NOT confused with 'nothing here'"
else
    bad "68c: SSH transport error -> 2 2 (unknown), NOT confused with 'nothing here'"         "dostalem: $got -- rowne 68b znaczy, ze martwe lacze nadal mowi 'nie ma rodziny'"
fi

# 68e. The other way to get no output: the remote `zfs list` itself failed --
#      dataset gone, or the delegated account cannot see it. Also not evidence
#      of an empty family, and also not a licence to seed actively.
got=$(probe_case 'return 1' 'return 0')
case "$got" in
    "2 "*) ok "68e: remote 'zfs list' failure -> unknown, not 'no family'" ;;
    *)     bad "68e: remote 'zfs list' failure -> unknown, not 'no family'" "dostalem: $got" ;;
esac

# 68f. THE ONE THAT MATTERS: SSH error -> refusal, and no fallback to the
#      recorded dataset list. 68c proves the probe returns 2; this proves what
#      the consumer DOES with it, which is the property the fix exists for.
#      `has_committed_scope || return 0` used to mean a dead link downgraded the
#      relationship out of THE SIGNED SCOPE IS THE CONTRACT (#101) and back to
#      whatever list was on file -- silently, and with the run continuing.
#
#      Paired with its own control: a source that genuinely has no sidecar must
#      STILL continue on the recorded list, because that is the legacy path and
#      breaking it would be a different bug wearing this fix's clothes.
resolve_case() {   # <scope-stub-body> -> "<rc>"
    (
        source "$ZFSBACKUP"
        __scope="$1"
        ssh() { case "$*" in *"test -s"*) eval "$__scope" ;; *) return 0 ;; esac; }
        load_ssh_opts() { LOAD_SSH_OPTS=(); }
        peer_scope_granted_hash_path() { echo /tmp/whatever.sha256; }
        LOAD_ACCOUNT=probe; LOAD_HOST=probe.invalid; COLLECTOR_LABEL=probe
        PEER_SAVED_MODE=""
        PEER_SAVED_DATASETS="rpool/stara rpool/lista"
        resolve_mode_datasets
        echo "rc=$?"
    ) 2>&1
}

got=$(resolve_case 'return 255')
if printf '%s' "$got" | grep -q "rc=0"; then
    bad "68f: SSH 255 -> resolve_mode_datasets REFUSES (no fallback to the recorded list)"         "wrocilo rc=0 -- martwe lacze przeszlo jako 'brak podpisu' i lista zostala uzyta"
elif printf '%s' "$got" | grep -qi "cannot reach"; then
    ok "68f: SSH 255 -> resolve_mode_datasets REFUSES (no fallback to the recorded list)"
else
    bad "68f: SSH 255 -> resolve_mode_datasets REFUSES (no fallback to the recorded list)"         "odmowilo, ale nie tym powodem: $got"
fi

# 68g. CONTROL for 68f -- a real "no sidecar here" must still continue on the
#      recorded list, or 68f would pass for the wrong reason (everything dies).
got=$(resolve_case 'return 1')
if printf '%s' "$got" | grep -q "rc=0"; then
    ok "68g: no sidecar (a real answer) -> still continues on the recorded list"
else
    bad "68g: no sidecar (a real answer) -> still continues on the recorded list" "$got"
fi

# 68d. and the callers must REFUSE rather than pick a default. The behaviour is
#      a die() inside a long command, so "every call site handles it" is the one
#      thing a source-grep is the right instrument for.
# Three consumers refuse outright -- the emit-time passivity decision and the
# two seed sites (seed, final-catchup) -- and the activation rehearsal reports
# its own UNKNOWN rather than reusing the "no snapshot reachable" wording, since
# the two need different fixes. Counted, so adding a consumer without an
# unknown branch fails here rather than at 3am on someone's chain middle.
n_die=$(grep -c 'die_probe_unknown "\$' "$ZFSBACKUP")
n_rehearsal=$(grep -c 'UNKNOWN (passive)' "$ZFSBACKUP")
n_scope=$(grep -c 'has signed a scope for this relationship' "$ZFSBACKUP")
if [ "$n_die" -eq 3 ] && [ "$n_rehearsal" -eq 1 ] && [ "$n_scope" -eq 1 ]; then
    ok "68d: all five consumers (3 refusals, rehearsal, committed-scope) branch on unknown"
else
    bad "68d: all five consumers (3 refusals, rehearsal, committed-scope) branch on unknown"         "die=$n_die rehearsal=$n_rehearsal scope=$n_scope"
fi

# ---------------------------------------------------------------------------
# THE GATE. Everything that asserts must appear ABOVE this line.
#
# Section 68 was appended BELOW it (2026-08-22) and the reviewer caught what
# that cost: the runner has `set -u` but not `set -e`, and bad() ends in
# FAIL=$((FAIL+1)), an arithmetic assignment that succeeds. So an assertion
# placed after the gate could raise FAIL and the process would still exit 0 --
# CI green, test failing, nobody the wiser. The test that was written to stop a
# fail-open was itself failing open.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# A PROMPT AFTER AN ssh CALL MUST STILL BE ANSWERABLE.
#
# ssh without -n reads its stdin to EOF and hands it to the remote command. No
# call in zfs-backup.sh wants that, but every one of them ATE whatever the
# operator's stdin held -- so `seed` and `activate`, which both resolve the
# peer's scope over ssh before asking for confirmation, could never be answered
# from a pipe. They refused with "not confirmed" no matter what was fed in.
# On a terminal it works, so it only ever appeared once something was scripted.
# Found running issue #9's four-command trial, 2026-08-23; measured on pve9:
#
#     printf 'ZOSTALO\n' | { ssh root@peer true; read -r x; echo "[${x:-PUSTO}]"; }
#       -> [PUSTO]
#
# Two checks, because neither alone is enough:
#   1. behavioural -- drive a real function that calls ssh, then read. The ssh
#      stub reproduces the documented behaviour (drain stdin unless -n), which
#      is what the live measurement above showed;
#   2. completeness -- every ssh invocation in the file carries -n. Deliberately
#      syntactic: the property IS the flag, and case 1 can only ever cover the
#      one call site it drives.
# ---------------------------------------------------------------------------
ssh_stdin_probe=$( printf 'ODPOWIEDZ\n' | (
    source "$ZFSBACKUP" 2>/dev/null
    # Stands in for ssh(1): consumes stdin exactly when -n is absent.
    ssh() {
        local a keep_stdin=1
        for a in "$@"; do [ "$a" = "-n" ] && keep_stdin=0; done
        [ "$keep_stdin" -eq 1 ] && cat >/dev/null
        return 0
    }
    load_ssh_opts() { LOAD_SSH_OPTS=(-o BatchMode=yes); }
    LOAD_ACCOUNT=acct; LOAD_HOST=peer; COLLECTOR_LABEL=x
    peer_scope_granted_hash_path() { echo /tmp/nic; }
    has_committed_scope >/dev/null 2>&1
    read -r answer
    printf '%s' "${answer:-PUSTO}"
) )
if [ "$ssh_stdin_probe" = "ODPOWIEDZ" ]; then
    ok "ssh: a prompt after an ssh call still receives the operator's answer"
else
    bad "ssh: a prompt after an ssh call still receives the operator's answer" \
        "przeczytano: ${ssh_stdin_probe:-NIC} -- ssh zjadl stdin, monit bedzie nieodpowiadalny"
fi

# ONE exemption, keyed on an explicit marker, not on judgement: the
# stdin-carrier variant exists because --grant-remotely pipes the scope stanza
# into `cat > file` on the source, and -n there writes an EMPTY scope -- the
# 2026-08-23 sweep did exactly that and killed the automatic enrolment for a
# few hours (the empty-scope grammar guard kept it fail-closed). The marker
# must appear on the offending line itself; an unmarked -n-less ssh still fails.
ssh_no_n=$(grep -nE '(^|[^a-z_])ssh ' "$ZFSBACKUP" \
           | grep -v '^\s*[0-9]*:\s*#' \
           | grep -vE 'ssh -n ' \
           | grep -vE '\.ssh|ssh_opts|ssh_flags|SSH_OPTS|known_hosts|ssh-keygen|root-ssh|ssh\(1\)|stdin-carrier|# ')
if [ -z "$ssh_no_n" ]; then
    ok "ssh: every invocation in zfs-backup.sh passes -n"
else
    bad "ssh: every invocation in zfs-backup.sh passes -n" \
        "bez -n:" "$(printf '%s' "$ssh_no_n" | cut -c1-140)"
fi
# The carrier itself must exist and must NOT have -n -- a future sweep that
# "fixes" it recreates the empty-scope breakage, so its shape is pinned.
if grep -q 'rux_root_ssh_in()' "$ZFSBACKUP"    && ! sed -n '/^rux_root_ssh_in()/,/^}/p' "$ZFSBACKUP" | grep -qE 'ssh -n '; then
    ok "ssh: the stdin-carrier variant exists and does NOT pass -n"
else
    bad "ssh: the stdin-carrier variant exists and does NOT pass -n"         "$(sed -n '/^rux_root_ssh_in()/,/^}/p' "$ZFSBACKUP" | grep 'ssh ' | head -1)"
fi

# ===========================================================================
# 96. migrate-profile takes a DESTINATION (2026-08-25)
#
# The destination used to be hardcoded: legacy flat-per-tier -> the standard
# GFS ladder. With `default`, `passive` and `prod` as real profiles, "put this
# host on profile X" was an ordinary operation with no command behind it.
#
# The sharp edge is GFS -> FLAT. A GFS ladder sits at the PARENT of the
# datasets, so the path-driven remove_managed_sections cannot reach it -- and
# the entire ladder branch lives inside `if PROFILE_GFS`, so migrating TO a
# flat profile would never have run the removal either. The old ladder would
# have survived next to the new per-tier prune: two pruners, same snapshots,
# same host. That is the property these assertions exist for.
#
# The fixture is built BY the tool: migrate to `default` first (which creates
# the ladder), then to `prod` (which must remove it). Hand-writing the "already
# on default" config would have been writing my own expectation into the input.
# ===========================================================================
MP="$WORK/migrateprofile"
rm -rf "$MP"; mkdir -p "$MP/clients" "$MP/peerstate" "$MP/keys" "$MP/dir" \
                       "$MP/root" "$MP/bin"
cp "$REPO/profiles/default.conf" "$MP/root/default.conf"
cp "$REPO/profiles/prod.conf"    "$MP/root/prod.conf"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$MP/bin/crontab"
chmod +x "$MP/bin/crontab"
for h in 10.9.9.8 10.9.9.9; do
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2U\n' "$h" > "$MP/keys/${h}_known_hosts"
done
cat > "$MP/peerstate/10.9.9.8.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/dir/jobs.conf\n' "$MP" > "$MP/server.conf"
printf '[defaults]\n\thost_label = mptest\n' > "$MP/dir/jobs.conf"
# NO PROFILE line: a record predating the field, which is exactly the legacy
# host this command was written for -- and the honest starting point, since a
# record already naming the destination is (correctly) a no-op.
{ printf 'CLIENT_NAME=mpc\nPEER_HOST=10.9.9.8\nSTATE=active\n'
  printf 'ACTIVE_ENDPOINT=10.9.9.9:22\n'
  printf 'MANAGED_DATASETS=tank/backups/10.9.9.8/rpool/data\n'
  printf 'CRON_CONFIG=%s/dir/jobs.conf\n' "$MP"
} > "$MP/clients/mpc.conf"

# The stubs are the transport and the crontab, never the shape under test:
# atomic_replace_and_install still PUBLISHES (so the record update and the
# second-run no-op are exercised for real), and the gen-cron validation of the
# migrated config inside cmd_migrate_profile is left completely alone.
# assert_source_prune_grant opens SSH to a peer that does not exist here; it has
# its own coverage under REV-102 and says nothing about which profile won.
mp_run() {   # <args...> -> rc, and the migrated config lands in $MP/dir/jobs.conf
    ( PATH="$MP/bin:$PATH"
      atomic_replace_and_install() { cp -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }
      assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }
      assert_config_readable_by_target() { :; }
      assert_source_prune_grant() { :; }
      assert_no_atomic_with_source_retention() { :; }
      CLIENTS_DIR="$MP/clients" PEER_STATE_DIR="$MP/peerstate" PEER_KEY_DIR="$MP/keys" \
      SERVER_CONF="$MP/server.conf" PROFILE_ROOT="$MP/root" \
      PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_migrate_profile --config="$MP/dir/jobs.conf" --yes "$@" ) 2>&1
}
mp_ladder() { grep -cE '^\[prune:tank/backups' "$MP/dir/jobs.conf"; }

# --- step 1: onto `default`. This is the ORIGINAL migration, unchanged, and
#     it is also how the fixture for step 2 gets built.
mp_out="$(mp_run --profile=default)"; mp_rc=$?
if [ "$mp_rc" -eq 0 ] && [ "$(mp_ladder)" -ge 1 ] \
   && grep -qE '^\[template:profile__default__' "$MP/dir/jobs.conf"; then
    ok "96a: migrate-profile --profile=default installs the GFS ladder (original behaviour)"
else
    bad "96a: migrate-profile --profile=default installs the GFS ladder" \
        "rc=$mp_rc ladder=$(mp_ladder)
$(printf '%s' "$mp_out" | tail -3)"
fi

# --- step 2: onto `prod`, which is FLAT. The ladder must GO.
mp_out="$(mp_run --profile=prod)"; mp_rc=$?
if [ "$mp_rc" -eq 0 ] && [ "$(mp_ladder)" -eq 0 ]; then
    ok "96b: GFS -> flat REMOVES the old ladder (it sits at the parent path, out of reach of a path sweep)"
else
    bad "96b: GFS -> flat removes the old ladder" \
        "rc=$mp_rc ladder=$(mp_ladder)
$(grep -nE '^\[prune:' "$MP/dir/jobs.conf" || echo 'no prune sections at all')"
fi

# ...and the destination's own templates arrived, while the source profile's
# are gone. An orphan [template:] is not cosmetic: it is a schedule definition
# sitting in a live config that nothing references, which is exactly what the
# hardcoded four-name removal existed to prevent for the one case it knew.
if grep -qE '^\[template:profile__prod__' "$MP/dir/jobs.conf" \
   && ! grep -qE '^\[template:profile__default__' "$MP/dir/jobs.conf"; then
    ok "96c: the destination's templates arrive and the source profile's orphans are swept"
else
    bad "96c: the destination's templates arrive and the source profile's orphans are swept" \
        "$(grep -E '^\[template:' "$MP/dir/jobs.conf" | tr '\n' ' ')"
fi

# ...and the result is a config the REAL gen-cron accepts. "The text looks
# right" is the appearance this project keeps mistaking for the property.
if bash "$REPO/gen-cron.sh" -c "$MP/dir/jobs.conf" >/dev/null 2>&1; then
    ok "96d: the migrated config renders through the real gen-cron.sh"
else
    bad "96d: the migrated config renders through the real gen-cron.sh" \
        "$(bash "$REPO/gen-cron.sh" -c "$MP/dir/jobs.conf" 2>&1 | tail -3)"
fi

# --- the record follows the config. PROFILE is create-time provenance that
#     seed_profile_context still reads: a record left saying `default` on a
#     host now running `prod` sends the next seed at the wrong family root.
# The LAST assignment of that field, which is what a `.`-sourced record actually
# means -- not the last LINE of the file. The digest is appended after PROFILE,
# so the literal tail check started failing for a reason unrelated to what this
# assertion is about.
if [ "$(grep '^PROFILE=' "$MP/clients/mpc.conf" | tail -1)" = "PROFILE=prod" ]; then
    ok "96e: the client record is moved to the destination profile, last-assignment-wins"
else
    bad "96e: the client record is moved to the destination profile" \
        "$(grep '^PROFILE=' "$MP/clients/mpc.conf" | tr '\n' ' ')"
fi

# --- running it again is a NO-OP, and this is why the record had to move: the
#     old "is standard_hourly flat?" test would call an already-migrated prod
#     host un-migrated and rewrite it on every run, forever.
mp_before="$(md5sum < "$MP/dir/jobs.conf")"
mp_out="$(mp_run --profile=prod)"; mp_rc=$?
if [ "$mp_rc" -eq 0 ] && [ "$(md5sum < "$MP/dir/jobs.conf")" = "$mp_before" ] \
   && printf '%s' "$mp_out" | grep -q "already on profile 'prod'"; then
    ok "96f: a second migration to the same profile is a no-op that says so"
else
    bad "96f: a second migration to the same profile is a no-op that says so" \
        "rc=$mp_rc changed=$([ "$(md5sum < "$MP/dir/jobs.conf")" = "$mp_before" ] && echo no || echo YES)
$(printf '%s' "$mp_out" | tail -2)"
fi

# --- CONTROL: a profile that does not exist is refused BEFORE anything moves.
#     Without this, every assertion above would also pass against a build that
#     silently ignored --profile and always did `default`.
mp_before="$(md5sum < "$MP/dir/jobs.conf")"
mp_out="$(mp_run --profile=nosuchprofile)"; mp_rc=$?
if [ "$mp_rc" -ne 0 ] && [ "$(md5sum < "$MP/dir/jobs.conf")" = "$mp_before" ] \
   && printf '%s' "$mp_out" | grep -q "nosuchprofile"; then
    ok "96g control: an unknown --profile is refused by name, with nothing touched"
else
    bad "96g control: an unknown --profile is refused by name, with nothing touched" \
        "rc=$mp_rc: $(printf '%s' "$mp_out" | tail -2)"
fi

# --- THE CANDIDATE CONFIG DOES NOT SURVIVE A REFUSAL.
#
# Every transactional command removes its own working copy on each of its OWN
# failure paths. None of them can reach a die() raised inside a function they
# called -- the shell exits from under the caller, and .zfsbackup-work.XXXXXX
# stays next to the live config at mode 0644. Same leak class as the 1824
# rendered profile copies found in pve0's /tmp, and it lands in exactly the
# directory an operator opens when something has just gone wrong.
#
# Forced with today's other change: a config fencing a family MORE WEAKLY than
# the profile requires is refused from inside ensure_cron_config. That is a real
# refusal on a real path, not a stub raised to make a point.
# A LEGACY config, deliberately: standard_hourly still carries prune_schedule.
# That shape reaches the working-copy stage on the PRE-CHANGE build too, so the
# negative control for this assertion fails because the file was left behind and
# not because an option was not recognised. Measured on HEAD: 1 leftover.
# It also fences vzdump MORE WEAKLY than the profile requires.
{ printf '[defaults]\n\thost_label = mptest\n\n'
  printf '[template:standard_hourly]\n\tsend_schedule = 1 * * * *\n\tprune_schedule = 21 * * * *\n\tkeep = 24\n\n'
  printf '[excluded:vzdump]\n\tkeep = 1\n'
} > "$MP/dir/leak.conf"
mp_leak_out="$( ( PATH="$MP/bin:$PATH"
      atomic_replace_and_install() { cp -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
      assert_source_prune_grant() { :; }; assert_no_atomic_with_source_retention() { :; }
      CLIENTS_DIR="$MP/clients" PEER_STATE_DIR="$MP/peerstate" PEER_KEY_DIR="$MP/keys" \
      SERVER_CONF="$MP/server.conf" PROFILE_ROOT="$MP/root" \
      PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_migrate_profile --config="$MP/dir/leak.conf" --yes ) 2>&1 )"
mp_leak_rc=$?
mp_left="$(find "$MP/dir" -maxdepth 1 -name '.zfsbackup-work.*' 2>/dev/null | wc -l)"
if [ "$mp_leak_rc" -ne 0 ] && [ "$mp_left" -eq 0 ] \
   && printf '%s' "$mp_leak_out" | grep -q 'protects it LESS'; then
    ok "96k: a die() from inside a callee does not leave the candidate config behind"
else
    bad "96k: a die() from inside a callee does not leave the candidate config behind" \
        "rc=$mp_leak_rc leftovers=$mp_left" "$(printf '%s' "$mp_leak_out" | tail -1)"
fi

# CONTROL: the net must not eat a candidate that was PUBLISHED. Releasing a path
# that has become the live config would be a disaster dressed as a cleanup, so
# the successful migration above has to have left a readable config behind.
if [ -s "$MP/dir/jobs.conf" ] && grep -q '^\[defaults\]' "$MP/dir/jobs.conf"; then
    ok "96l control: a published config is not swept by the same net"
else
    bad "96l control: a published config is not swept by the same net" \
        "$(ls -l "$MP/dir/jobs.conf" 2>&1)"
fi

# --- A FLAT PROFILE IS NOT THE FROZEN ONE.
#
# Found by 96h, not by reading: migrating back out of `prod` was refused with
# "uses the pre-GFS profile (standard_* still carries prune_schedule)" -- naming
# a family the file does not contain. detect_profile_gfs answers a SHAPE
# question ("do the tiers prune themselves?"), and that is true of the frozen
# pre-GFS family AND of any modern flat profile. The refusal that read it is
# about a NAME: the bare standard_* family written before profiles were
# namespaced.
#
# The consequence was not limited to migration. Probed directly: a config
# generated from `prod` accepts its FIRST client and REFUSES the second, so
# `prod` was a one-relationship-per-host profile -- which would have surfaced on
# a live collector, on the second relationship, months from now.
FZ="$WORK/frozenshape"; rm -rf "$FZ"; mkdir -p "$FZ/root" "$FZ/bin"
cp "$REPO/profiles/prod.conf" "$FZ/root/prod.conf"; cp "$REPO/profiles/default.conf" "$FZ/root/default.conf"
printf '#!/bin/sh\nexit 0\n' > "$FZ/bin/crontab"; chmod +x "$FZ/bin/crontab"
fz_gen() {   # <config> <profile> -> rc
    ( PATH="$FZ/bin:$PATH"; PROFILE_ROOT="$FZ/root"; PROFILE_ACTIVE="$2"; PROFILE_LOADED=""
      ensure_cron_config "$1" 0 1 always ) >/dev/null 2>&1
}
printf '[defaults]\n\thost_label = fz\n' > "$FZ/jobs.conf"
fz_gen "$FZ/jobs.conf" prod
fz_first=$(grep -cE '^\[template:profile__prod__' "$FZ/jobs.conf")
fz_gen "$FZ/jobs.conf" prod; fz_rc2=$?
if [ "$fz_first" -ge 1 ] && [ "$fz_rc2" -eq 0 ]; then
    ok "96i: a host already on a FLAT profile accepts a second relationship"
else
    bad "96i: a host already on a FLAT profile accepts a second relationship" \
        "first generation wrote $fz_first template(s); second returned $fz_rc2"
fi

# CONTROL, and the reason 96i is not simply the guard switched off: the GENUINE
# frozen family must still be refused. Without this, deleting the check outright
# would pass 96i.
printf '[defaults]\n\thost_label = fz\n\n[template:standard_hourly]\n\tsend_schedule = 1 * * * *\n\tprune_schedule = 21 * * * *\n\tkeep = 24\n' > "$FZ/legacy.conf"
if ! fz_gen "$FZ/legacy.conf" default; then
    ok "96j control: a GENUINE pre-GFS config is still refused (the guard is narrowed, not removed)"
else
    bad "96j control: a genuine pre-GFS config is still refused" "it was accepted"
fi

# --- CONTROL: --profile really selects. Migrating BACK to default must put the
#     ladder back; if the flag were ignored, 96b would pass for the wrong reason
#     on a build that simply never emits a ladder.
mp_out="$(mp_run --profile=default)"; mp_rc=$?
if [ "$mp_rc" -eq 0 ] && [ "$(mp_ladder)" -ge 1 ] \
   && grep -qE '^\[template:profile__default__' "$MP/dir/jobs.conf" \
   && ! grep -qE '^\[template:profile__prod__' "$MP/dir/jobs.conf"; then
    ok "96h control: migrating BACK to a GFS profile restores the ladder and sweeps prod's templates"
else
    bad "96h control: migrating back to a GFS profile restores the ladder" \
        "rc=$mp_rc ladder=$(mp_ladder) tpl=$(grep -cE '^\[template:profile__prod__' "$MP/dir/jobs.conf")"
fi

# --- ONE SHELL, SEVERAL RECORDS: NO FIELD MAY SURVIVE INTO THE NEXT ONE.
#
# REV F3. A client record is a `.`-sourced file, so a field a record does NOT
# carry keeps whatever the previous record left behind. cmd_migrate_profile
# sources every record in one shell, three times over.
#
# Record A carries PROFILE=prod; record B is older and has no PROFILE field at
# all. After `. A` then `. B`, B still reads prod -- a false "already on
# profile" in the precheck, and a record that silently never gets its PROFILE
# written in the post-install loop.
#
# This is the same defect the tree fixed for BANDWIDTH, and the comment in
# load_client_and_connection names migrate-profile as a caller that needs the
# reset. These loops were written without it. The `( : )` beside each source
# reads like a subshell and is a shellcheck no-op -- which is how I made the
# mistake in the first place.
LK="$WORK/leakrecords"; rm -rf "$LK"; mkdir -p "$LK"
# EXCLUDE_1 rides along because it is the field that proved the first fix
# wrong. That fix reset a hand-picked list of names -- the ones I could see --
# and a NUMBERED field cannot be enumerated ahead of time at all. On pve9 an
# EXCLUDE_1 from an old, already-REMOVED record reached an active one and the
# proposed cron line grew a `-X skip` the relationship had never asked for.
printf 'CLIENT_NAME=a\nSTATE=active\nPROFILE=prod\nEXCLUDE_1=skip\n' > "$LK/a.conf"
printf 'CLIENT_NAME=b\nSTATE=active\n'                              > "$LK/b.conf"

leak_probe() {   # <reader> [field] -> what b ends up seeing in that field
    local fld="${2:-PROFILE}"
    ( PROFILE=""; EXCLUDE_1=""
      $1 "$LK/a.conf"; $1 "$LK/b.conf"
      eval "printf '%s' \"\${$fld:-<empty>}\"" )
}
if [ "$(leak_probe migrate_read_record)" = "<empty>" ]; then
    ok "96r: a record without PROFILE does not inherit the previous record's"
else
    bad "96r: a record without PROFILE does not inherit the previous record's" \
        "b saw PROFILE='$(leak_probe migrate_read_record)'"
fi

if [ "$(leak_probe migrate_read_record EXCLUDE_1)" = "<empty>" ]; then
    ok "96r2: a NUMBERED field does not survive either -- the reset is not a list of names"
else
    bad "96r2: a numbered field does not survive either" \
        "b saw EXCLUDE_1='$(leak_probe migrate_read_record EXCLUDE_1)'"
fi

# CONTROL, and the reason 96r is not vacuous: the PLAIN source really does leak.
# Without this the assertion would pass against any reader at all, including one
# that never read the field.
plain_source() { . "$1"; }
if [ "$(leak_probe plain_source)" = "prod" ]; then
    ok "96s control: the plain source leaks it, so 96r is testing something"
else
    bad "96s control: the plain source leaks it" \
        "b saw '$(leak_probe plain_source)' -- expected the leak"
fi

# --- THE DIGEST MUST NOTICE THE RENDERER, NOT ONLY THE FILE.
#
# REV F2b. The first digest covered profile.conf and gen-cron's tier-letter
# table -- the operator's file, and the table that turns `keep = 24` into -H24.
# Both real, both insufficient: change HOW a profile is rendered (the
# namespacing, the fragment split, the keep translation) and the installed
# CONFIG changes while neither input moves. Same digest, different policy, and
# migrate-profile answering "nothing to migrate".
#
# PROFILE_RENDER_SCHEMA is a number a human bumps, not a hash of lib-profile.sh,
# because only a human knows whether the OUTPUT changed -- a hash would move on
# a comment edit and migrate the whole fleet for nothing.
dg_at() {   # <schema value> -> digest
    ( PROFILE_ROOT="$REPO/profiles"; PROFILE_ACTIVE=prod
      PROFILE_RENDER_SCHEMA="$1"; profile_digest )
}
dg_a="$(dg_at 1)"; dg_b="$(dg_at 1)"; dg_c="$(dg_at 99)"
if [ -n "$dg_a" ] && [ "$dg_a" = "$dg_b" ] && [ "$dg_a" != "$dg_c" ]; then
    ok "96y: the digest moves when the RENDERER's version moves, and not otherwise"
else
    bad "96y: the digest moves when the renderer's version moves" \
        "same-input='$dg_a' vs '$dg_b'; bumped='$dg_c'"
fi

# --- CREATE MUST NOT SUCCEED WITHOUT SOURCE RETENTION.
#
# REV F1, second round, and the reviewer was right about the first one. I
# replaced a die() with a log-and-continue and argued that gen-cron was the
# backstop -- it validates the candidate and rejects a [prune:] with no
# use_template. But that branch writes NO SECTION AT ALL, and gen-cron cannot
# reject a section that was never written. The relationship would have been
# created, stamped four families on the source, and bounded none of them.
#
# The argument was wrong, not the code around it. These two assertions exist so
# that the argument cannot be made again without failing.
# A LOADED PROFILE WHOSE ARTIFACTS ARE GONE IS A STALE STATE, NOT A VERDICT.
#
# This one cost three attempts. The suite renders profiles inside subshells; a
# subshell's EXIT trap releases the temps and clears ITS copy of the variables,
# while the parent keeps PROFILE_LOADED=1 and paths to files that no longer
# exist. I first read that as "no retention" and skipped silently, then as "no
# retention" and refused -- both wrong, because the profile is fine and only the
# rendering is missing. Repair the state: re-render once, non-fatally, and ask
# again.
# The verdict is formed INSIDE the subshell, because the re-rendered fragment is
# a temp owned by that shell and its EXIT trap releases it on the way out. The
# first version of this assertion returned the PATH and tested -s in the parent,
# where the file was already gone -- the very phenomenon under test, one level
# up, catching the test that was written for it.
st_frag="$( ( PROFILE_ROOT="$REPO/profiles"; PROFILE_ACTIVE=default
              PROFILE_LOADED=1
              PROFILE_PRUNE_FILE=/nonexistent-prune
              PROFILE_DS_FILE=/nonexistent-ds
              profile_reload_if_stale
              f="$(profile_retention_fragment)" && [ -s "$f" ] && printf 'RENDERED' ) )"
if [ "$st_frag" = "RENDERED" ]; then
    ok "96z: a stale profile state is re-rendered, not mistaken for an empty policy"
else
    bad "96z: a stale profile state is re-rendered" "got '${st_frag:-<nothing>}', expected RENDERED"
fi

# CONTROL: a profile that genuinely cannot be validated must still resolve to
# nothing, or 96z would be indistinguishable from "always re-render and hope".
st_none="$( ( PROFILE_ROOT="$WORK/no-such-profile-root"; PROFILE_ACTIVE=ghost
              PROFILE_LOADED=1
              PROFILE_PRUNE_FILE=/nonexistent-prune
              PROFILE_DS_FILE=/nonexistent-ds
              profile_reload_if_stale
              f="$(profile_retention_fragment)" && [ -s "$f" ] && printf 'RENDERED' ) 2>/dev/null )"
if [ -z "$st_none" ]; then
    ok "96z2 control: an unvalidatable profile still resolves to nothing"
else
    bad "96z2 control: an unvalidatable profile still resolves to nothing" "got '$st_none'"
fi

SR="$WORK/srfailclosed"; rm -rf "$SR"; mkdir -p "$SR"
printf '[defaults]\n\thost_label = sr\n' > "$SR/jobs.conf"
sr_before="$(md5sum < "$SR/jobs.conf")"

# A profile that is LOADED but whose rendered artifacts are unreadable -- the
# stale-temp case that made me soften this in the first place. It must refuse,
# not carry on: on a create path both readings ("declares nothing" and "cannot
# see it") are reasons to stop before publishing.
sr_create="$( ( PROFILE_LOADED=1
                PROFILE_ACTIVE=srprof
                PROFILE_PRUNE_FILE="$SR/gone-prune"
                PROFILE_DS_FILE="$SR/gone-ds"
                LOAD_HOST=10.4.4.4
                SOURCE_PRUNE_EMITTED_DS=()
                emit_remote_source_prune "$SR/jobs.conf" srclient "# managed-by: zfs-backup.sh client=srclient" tank/src
              ) 2>&1 )"
sr_rc=$?
if [ "$sr_rc" -ne 0 ] && [ "$(md5sum < "$SR/jobs.conf")" = "$sr_before" ] \
   && printf '%s' "$sr_create" | grep -q 'bound none of them'; then
    ok "96v: CREATE refuses when no retention fragment resolves, and writes nothing"
else
    bad "96v: CREATE refuses when no retention fragment resolves" \
        "rc=$sr_rc changed=$([ "$(md5sum < "$SR/jobs.conf")" = "$sr_before" ] && echo no || echo YES)" \
        "$(printf '%s' "$sr_create" | tail -1)"
fi

# The retrofit verb ONLY ever creates, so reporting success while adding nothing
# is the same fail-open wearing an audit's clothes. It used to `return 0`.
sr_apply="$( ( PROFILE_LOADED=1
               PROFILE_ACTIVE=srprof
               PROFILE_PRUNE_FILE="$SR/gone-prune"
               PROFILE_DS_FILE="$SR/gone-ds"
               SOURCE_PRUNE_EMITTED_DS=()
               emit_missing_source_prune "$SR/jobs.conf" srclient "acct@10.4.4.4:tank/src"
             ) 2>&1 )"
sr_arc=$?
if [ "$sr_arc" -ne 0 ] && printf '%s' "$sr_apply" | grep -q 'Refusing to report success'; then
    ok "96w: audit --apply refuses rather than reporting success while adding nothing"
else
    bad "96w: audit --apply refuses rather than reporting success while adding nothing" \
        "rc=$sr_arc" "$(printf '%s' "$sr_apply" | tail -1)"
fi

# CONTROL: with a READABLE fragment the same call must go through, or 96v/96w
# would pass against a build that refused source retention outright -- which is
# the defect this whole finding is about, inverted.
printf '\tuse_template = t1\n' > "$SR/real-ds"
: > "$SR/real-prune"
printf '[template:t1]\n\tprune_schedule = 9 * * * *\n\tpattern = automated_\n\tretain = -H24\n' > "$SR/tpl"
sr_ok="$( ( PROFILE_LOADED=1
            PROFILE_ACTIVE=srprof
            PROFILE_TPL_FILE="$SR/tpl"
            PROFILE_PRUNE_FILE="$SR/real-prune"
            PROFILE_DS_FILE="$SR/real-ds"
            LOAD_HOST=10.4.4.4
            SOURCE_PRUNE_EMITTED_DS=()
            emit_remote_source_prune "$SR/jobs.conf" srclient "# managed-by: zfs-backup.sh client=srclient" tank/src
          ) 2>&1 )"
if [ "$(grep -c '^\[prune:[^]]*@' "$SR/jobs.conf")" -ge 1 ]; then
    ok "96x control: a readable fragment still produces the source prune section"
else
    bad "96x control: a readable fragment still produces the source prune section" \
        "$(printf '%s' "$sr_ok" | tail -1)"
fi

# --- A FLAT PROFILE MUST BOUND THE FAMILIES IT CREATES ON THE SOURCE.
#
# REV F1, and it was measured on a PRODUCTION host while the lab ran: pve1
# carried 33 automated_hourly_, 9 automated_daily_, 3 automated_weekly_ and
# 3 automated_monthly_ snapshots, against ZERO [prune:account@host:...]
# sections in the collector's config.
#
# An active pull CREATES those four families on the source with `snapget -m`.
# The inline prune from [dataset:] bounds only the collector's COPY. Both remote
# source emitters were gated on `PROFILE_GFS -eq 1`, false for every flat
# profile, so `prod` stamped snapshots on a production host and pruned none of
# them there -- REV-20260811-102's original defect, one profile shape over.
#
# The gate asked about SHAPE. What matters is whether the profile has retention
# to express: a ladder profile keeps it in [prune], a flat one in the tiers its
# [dataset] references. Both are fragments carrying use_template.
echo 'PROFILE=default' >> "$MP/clients/mpc.conf"
printf '[defaults]\n\thost_label = mptest\n' > "$MP/dir/src.conf"
( PATH="$MP/bin:$PATH"
  atomic_replace_and_install() { cp -f "$2" "$1"; }
  assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
  assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
  assert_source_prune_grant() { :; }; assert_no_atomic_with_source_retention() { :; }
  CLIENTS_DIR="$MP/clients" PEER_STATE_DIR="$MP/peerstate" PEER_KEY_DIR="$MP/keys" \
  SERVER_CONF="$MP/server.conf" PROFILE_ROOT="$MP/root" \
  PROFILE_ACTIVE=default PROFILE_LOADED="" \
  cmd_migrate_profile --config="$MP/dir/src.conf" --yes --profile=prod ) >/dev/null 2>&1

if [ "$(grep -c '^\[prune:[^]]*@' "$MP/dir/src.conf")" -ge 1 ] \
   && [ "$(grep -c '^\[template:profile__prod__src_' "$MP/dir/src.conf")" -eq 4 ]; then
    ok "96o: a FLAT profile emits remote source retention for every family it creates"
else
    bad "96o: a FLAT profile emits remote source retention for every family it creates" \
        "remote prune sections=$(grep -c '^\[prune:[^]]*@' "$MP/dir/src.conf") src templates=$(grep -c '^\[template:profile__prod__src_' "$MP/dir/src.conf")"
fi

# ...and a SOURCE template must not carry the creation half of its tier. A flat
# tier is self-contained -- it creates AND prunes -- so copying it verbatim would
# put send_schedule and prefix into a section whose whole job is a remote prune.
# A ladder profile's prune tiers never carry them, which is why this could not
# have been noticed before `prod`.
if ! sed -n '/^\[template:profile__prod__src_/,/^\[/p' "$MP/dir/src.conf" \
        | grep -qE '^[[:space:]]*(send_schedule|prefix)[[:space:]]*='; then
    ok "96p: a derived SOURCE template carries retention only, never creation"
else
    bad "96p: a derived SOURCE template carries retention only, never creation" \
        "$(sed -n '/^\[template:profile__prod__src_/,/^\[/p' "$MP/dir/src.conf" | grep -E 'send_schedule|prefix' | head -2)"
fi

# CONTROL: the result must still render. "The text looks right" is the
# appearance this project keeps mistaking for the property, and a source prune
# built from the wrong fragment is exactly how the empty-ladder defect showed
# up -- as a gen-cron rejection.
if bash "$REPO/gen-cron.sh" -c "$MP/dir/src.conf" >/dev/null 2>&1; then
    ok "96q control: the config carrying flat source retention renders"
else
    bad "96q control: the config carrying flat source retention renders" \
        "$(bash "$REPO/gen-cron.sh" -c "$MP/dir/src.conf" 2>&1 | tail -2)"
fi

# LAST IN THIS GROUP ON PURPOSE: the two assertions below move the client
# record's PROFILE, and 96f/96h read it. Placed earlier, they turned 96h into a
# silent no-op that still reported rc=0 -- a test passing because it did
# nothing.
# --- A FLAT PROFILE ON A **FRESH** CONFIG EMITS NO LADDER.
#
# FOUND ON LIVE INFRASTRUCTURE, not here: pve9, 2026-08-25, the first `prod`
# relationship ever created.
#
#     gen-cron.sh: error: [prune:hdd/prodlab-k1/192.168.28.9] has no use_template
#
# PROFILE_GFS is detect_profile_gfs' answer about the INSTALLED CONFIG. A fresh
# config says nothing, so it defaults to "ladder", and a flat profile's ladder
# was planned, emitted, and rejected for having no use_template -- `prod` could
# not create its FIRST relationship. The assertions above missed it because they
# exercise ensure_cron_config (templates, the frozen-shape refusal); the ladder
# is emitted by emit_client_sections, one layer further in.
#
# The fix asks the only question that cannot be wrong: does the profile being
# WRITTEN carry a prune fragment at all. `prod` does not -- its tiers prune
# their own families -- so there is nothing to put in a ladder and emitting one
# is a defect by construction.
# The record's profile is the no-op test (96f), so it has to be set AWAY from
# the destination or this assertion measures nothing. Last assignment wins.
printf '[defaults]\n\thost_label = mptest\n' > "$MP/dir/fresh.conf"
echo 'PROFILE=default' >> "$MP/clients/mpc.conf"
mp_fresh_out="$( ( PATH="$MP/bin:$PATH"
      atomic_replace_and_install() { cp -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
      assert_source_prune_grant() { :; }; assert_no_atomic_with_source_retention() { :; }
      CLIENTS_DIR="$MP/clients" PEER_STATE_DIR="$MP/peerstate" PEER_KEY_DIR="$MP/keys" \
      SERVER_CONF="$MP/server.conf" PROFILE_ROOT="$MP/root" \
      PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_migrate_profile --config="$MP/dir/fresh.conf" --yes --profile=prod ) 2>&1 )"
mp_fresh_rc=$?
# The LADDER only: a header with no '@' in it. Remote source retention is also a
# [prune:] section (account@host:dataset), and counting both made this assertion
# fail the moment F1 gave flat profiles the source prune they owed -- for a
# reason that had nothing to do with what it tests.
if [ "$mp_fresh_rc" -eq 0 ] \
   && [ "$(grep -c '^\[prune:[^]@]*\]' "$MP/dir/fresh.conf")" -eq 0 ] \
   && bash "$REPO/gen-cron.sh" -c "$MP/dir/fresh.conf" >/dev/null 2>&1; then
    ok "96m: a FLAT profile on a fresh config emits no ladder and the result renders"
else
    bad "96m: a FLAT profile on a fresh config emits no ladder and the result renders" \
        "rc=$mp_fresh_rc ladder_sections=$(grep -c '^\[prune:[^]@]*\]' "$MP/dir/fresh.conf")" \
        "$(printf '%s' "$mp_fresh_out" | tail -2)"
fi

# CONTROL: the same fresh-config path with a LADDER profile must still produce
# one. Without this, 96m would pass against a build that simply stopped emitting
# [prune:] sections altogether.
printf '[defaults]\n\thost_label = mptest\n' > "$MP/dir/freshg.conf"
echo 'PROFILE=prod' >> "$MP/clients/mpc.conf"
( PATH="$MP/bin:$PATH"
  atomic_replace_and_install() { cp -f "$2" "$1"; }
  assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
  assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
  assert_source_prune_grant() { :; }; assert_no_atomic_with_source_retention() { :; }
  CLIENTS_DIR="$MP/clients" PEER_STATE_DIR="$MP/peerstate" PEER_KEY_DIR="$MP/keys" \
  SERVER_CONF="$MP/server.conf" PROFILE_ROOT="$MP/root" \
  PROFILE_ACTIVE=default PROFILE_LOADED="" \
  cmd_migrate_profile --config="$MP/dir/freshg.conf" --yes --profile=default ) >/dev/null 2>&1
if [ "$(grep -c '^\[prune:' "$MP/dir/freshg.conf")" -ge 1 ]; then
    ok "96n control: a LADDER profile on a fresh config still emits its ladder"
else
    bad "96n control: a LADDER profile on a fresh config still emits its ladder" \
        "$(grep -cE '^\[' "$MP/dir/freshg.conf") sections, none of them prune"
fi

# --- AN EDITED PROFILE MUST BE APPLIABLE. A NAME IS NOT A VERSION.
#
# REV F2. profiles/prod.conf opens with a promise: "an operator changes
# a retention here and nowhere else". migrate-profile decided "already there"
# from the record's PROFILE string alone, so the promise was false in exactly
# the case that matters -- edit keep = 7 to keep = 10, re-run the command, get
# "nothing to migrate", and the installed cron still carries -D7.
#
# The digest covers the operator's file AND the renderer's tier-letter table,
# because `keep = 24` becomes `-H24` through that table: a table change alters
# the installed policy without touching a byte of the profile, and a digest over
# the file alone would call that unchanged.
ED="$WORK/editedprofile"; rm -rf "$ED"; mkdir -p "$ED/clients" "$ED/peerstate" "$ED/keys" "$ED/dir" "$ED/root" "$ED/bin"
cp "$REPO/profiles/prod.conf" "$ED/root/prod.conf"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$ED/bin/crontab"
chmod +x "$ED/bin/crontab"
for h in 10.9.9.8 10.9.9.9; do
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2U\n' "$h" > "$ED/keys/${h}_known_hosts"
done
cat > "$ED/peerstate/10.9.9.8.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/dir/jobs.conf\n' "$ED" > "$ED/server.conf"
printf '[defaults]\n\thost_label = edtest\n' > "$ED/dir/jobs.conf"
{ printf 'CLIENT_NAME=edc\nPEER_HOST=10.9.9.8\nSTATE=active\n'
  printf 'ACTIVE_ENDPOINT=10.9.9.9:22\n'
  printf 'MANAGED_DATASETS=tank/backups/10.9.9.8/rpool/data\n'
  printf 'CRON_CONFIG=%s/dir/jobs.conf\n' "$ED"
} > "$ED/clients/edc.conf"

ed_run() {
    ( PATH="$ED/bin:$PATH"
      atomic_replace_and_install() { cp -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
      assert_source_prune_grant() { :; }; assert_no_atomic_with_source_retention() { :; }
      CLIENTS_DIR="$ED/clients" PEER_STATE_DIR="$ED/peerstate" PEER_KEY_DIR="$ED/keys" \
      SERVER_CONF="$ED/server.conf" PROFILE_ROOT="$ED/root" \
      PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_migrate_profile --config="$ED/dir/jobs.conf" --yes --profile=prod ) 2>&1
}
ed_daily() { awk '/^\[template:profile__prod__daily\]/{f=1;next} /^\[/{f=0} f&&/retain/{sub(/.*=[ \t]*/,"");print;exit}' "$ED/dir/jobs.conf"; }

ed_run >/dev/null 2>&1
ed_first="$(ed_daily)"

# The no-op is real and must stay real: an UNCHANGED profile still says so.
ed_out="$(ed_run)"
if printf '%s' "$ed_out" | grep -q 'nothing to migrate'; then
    ok "96t control: an UNCHANGED profile is still a no-op"
else
    bad "96t control: an unchanged profile is still a no-op" "$(printf '%s' "$ed_out" | tail -2)"
fi

# Now the operator edits the one file they are told to edit.
sed -i 's/^\tkeep           = 7$/\tkeep           = 10/' "$ED/root/prod.conf"
ed_out="$(ed_run)"
ed_second="$(ed_daily)"
if ! printf '%s' "$ed_out" | grep -q 'nothing to migrate' \
   && [ "$ed_first" = "-D7" ] && [ "$ed_second" = "-D10" ]; then
    ok "96u: editing a retention in the profile is applied, not answered with 'nothing to migrate'"
else
    bad "96u: editing a retention in the profile is applied" \
        "before='$ed_first' after='$ed_second'" "$(printf '%s' "$ed_out" | tail -2)"
fi

# ===========================================================================
# TWO ROOTS: what we ship, and what this host decided.
#
#   <package>/profiles/            factory. Replaced wholesale by `git pull`,
#                                  so a host must never edit it -- the next
#                                  update would take the edit away in silence.
#   /etc/zfs-snapshot-all/profiles local. Sits beside clients/, peers/ and the
#                                  config these profiles generate, and survives
#                                  every update because nothing in the checkout
#                                  points at it.
#
# "Never carried to GitHub" is a consequence of the LOCATION, not a rule anyone
# has to remember: /etc is not in the checkout, so no gesture -- not `git add
# .`, not a stray commit -- can take a local profile upstream.
#
# The fleet decided this rather than convention: pve1 carries FOUR copies of the
# package (root's, the delegated account's, and two in /tmp). A profiles.local/
# beside the checkout would exist once per copy, and "where are this host's
# profiles" would depend on which account ran the command.
UR="$WORK/userroot"; rm -rf "$UR"; mkdir -p "$UR"
sed 's/^\tkeep           = 7$/\tkeep           = 99/' "$REPO/profiles/prod.conf" > "$UR/prod.conf"

pr_file() { ( PROFILE_USER_ROOT="$UR"; profile_file "$1" 2>/dev/null ); }

if [ "$(pr_file prod)" = "$UR/prod.conf" ]; then
    ok "96A roots: a name present in BOTH resolves to the host's own copy"
else
    bad "96A roots: a name present in both resolves to the host's copy" "got '$(pr_file prod)'"
fi

# CONTROL: a name the host does NOT override still resolves to the factory one.
# Without this, the assertion above would pass against a build that always
# answered with the user root, override or not.
if [ "$(pr_file default)" = "$REPO/profiles/default.conf" ]; then
    ok "96A roots control: a name the host does not override still comes from the package"
else
    bad "96A roots control: a name the host does not override comes from the package" "got '$(pr_file default)'"
fi

# A PROFILE IS A FILE, SO ITS NAME IS A FILE NAME.
#
# The first resolver appended `.conf` to any argument without a '/', so
# `--profile=firma.conf` went looking for firma.conf.conf and only the
# extension-less shorthand worked. That is the opposite of the instruction it
# was written for -- "profil to plik, mozemy podac jego nazwe" -- and the
# shorthand is the alias, not the interface.
cp "$REPO/profiles/prod.conf" "$UR/firma.conf"
nm_case() { ( PROFILE_USER_ROOT="$UR"; profile_file "$1" ); }

if [ "$(nm_case firma.conf)" = "$UR/firma.conf" ]; then
    ok "96B name: a FILE NAME from the host's directory resolves to that file"
else
    bad "96B name: a file name from the host's directory resolves to that file" "got '$(nm_case firma.conf)'"
fi

if [ "$(nm_case default.conf)" = "$REPO/profiles/default.conf" ]; then
    ok "96B name: a FILE NAME from the package resolves to that file"
else
    bad "96B name: a file name from the package resolves to that file" "got '$(nm_case default.conf)'"
fi

if [ "$(nm_case /tmp/somewhere/else.conf)" = "/tmp/somewhere/else.conf" ]; then
    ok "96B name: an explicit path is taken as given, with nothing searched"
else
    bad "96B name: an explicit path is taken as given" "got '$(nm_case /tmp/somewhere/else.conf)'"
fi

# CONTROL: the extension-less shorthand still works, because every existing
# client record, test and habit says --profile=default. Without this the three
# above would pass against a build that simply stopped resolving names.
if [ "$(nm_case default)" = "$REPO/profiles/default.conf" ]; then
    ok "96B control: the extension-less shorthand still resolves"
else
    bad "96B control: the extension-less shorthand still resolves" "got '$(nm_case default)'"
fi

# ...and the NAME used for namespacing drops the extension either way, or a
# profile addressed by file name would namespace its templates as
# profile__firma.conf__hourly.
if [ "$(profile_name_of "$UR/firma.conf")" = "firma" ] && [ "$(profile_name_of firma)" = "firma" ]; then
    ok "96B name: the template namespace is the bare name, however the profile was addressed"
else
    bad "96B name: the template namespace is the bare name" \
        "path='$(profile_name_of "$UR/firma.conf")' bare='$(profile_name_of firma)'"
fi

# ...and the digest follows the resolution, or an override would be invisible to
# migrate-profile -- the whole point of today's F2b.
d_fac="$( ( PROFILE_USER_ROOT="$WORK/nonexistent"; PROFILE_ACTIVE=prod; profile_digest ) )"
d_loc="$( ( PROFILE_USER_ROOT="$UR";              PROFILE_ACTIVE=prod; profile_digest ) )"
if [ -n "$d_fac" ] && [ "$d_fac" != "$d_loc" ]; then
    ok "96A roots: the digest follows the resolved directory, so an override is not silent"
else
    bad "96A roots: the digest follows the resolved directory" "factory='$d_fac' local='$d_loc'"
fi


# ===========================================================================
# THIS HOST'S DEFAULTS: settings.ini
#
# For the handful of things that are neither policy nor topology. A profile says
# what to keep; a relationship says where from and where to; neither can say "on
# this machine a catch-up older than half an hour is too stale to reuse" -- that
# is a property of the host and its link.
#
# Until now such values lived only in environment variables with built-in
# defaults, which means they were settable by whoever remembered to export them
# and by nobody else.
#
# NOT a second place to say what a profile already says. The tier holds a
# decision, this file holds the default for when a tier is silent -- the same
# layering server.conf's DEFAULT_TARGET already uses. A per-profile settings
# file would rebuild the two-sources-of-truth problem this tree spent a day
# removing from the bandwidth manifest; the profile IS the per-profile file.
# ===========================================================================
SI="$WORK/settings"; rm -rf "$SI"; mkdir -p "$SI"
printf '# komentarz\ncatchup_max_age = 3600   # i komentarz w linii\npusty =\n' > "$SI/settings.ini"

si_read() { ( SETTINGS_FILE="$1"; settings_get "$2" "$3" ); }

if [ "$(si_read "$SI/settings.ini" catchup_max_age 1800)" = "3600" ]; then
    ok "settings: a value is read from the file, and a trailing comment is not part of it"
else
    bad "settings: a value is read from the file without its trailing comment" \
        "got '$(si_read "$SI/settings.ini" catchup_max_age 1800)'"
fi

# A key written with nothing after it means "I meant to set this" and getting
# the built-in silently would hide the mistake -- the same rule the config
# grammar already applies to blank fields. Falling back is what it does; the
# point of pinning it is that the behaviour is CHOSEN, not accidental.
if [ "$(si_read "$SI/settings.ini" pusty 1800)" = "1800" ]; then
    ok "settings: a key present but blank falls back rather than resolving to nothing"
else
    bad "settings: a key present but blank falls back" "got '$(si_read "$SI/settings.ini" pusty 1800)'"
fi

if [ "$(si_read "$SI/settings.ini" nie_ma 1800)" = "1800" ] \
   && [ "$(si_read "$SI/nie-ma-pliku.ini" catchup_max_age 1800)" = "1800" ]; then
    ok "settings control: an absent key and an absent FILE both give the built-in default"
else
    bad "settings control: an absent key and an absent file give the built-in default" \
        "key='$(si_read "$SI/settings.ini" nie_ma 1800)' file='$(si_read "$SI/nie-ma-pliku.ini" catchup_max_age 1800)'"
fi

# PRECEDENCE, end to end through the real assignment rather than through the
# reader alone: environment, then file, then built-in. The environment wins
# because that is what the suites use to pin a value -- a host file that could
# override a test would make the test a liar.
# unset FIRST: this suite sources zfs-backup.sh at the top, so CATCHUP_MAX_AGE
# is already 1800 in the parent and a subshell inherits it. ${VAR:-...} then
# keeps the inherited value -- correct behaviour, since an inherited variable IS
# the environment layer, but it left the test unable to observe the file layer
# it was written for.
si_env() { ( unset CATCHUP_MAX_AGE; export SETTINGS_FILE="$1"; [ -n "$2" ] && export CATCHUP_MAX_AGE="$2"
             . "$ZFSBACKUP" >/dev/null 2>&1 || true; printf '%s' "${CATCHUP_MAX_AGE:-BRAK}" ) }
si_a="$(si_env "$SI/settings.ini" 99)"
si_b="$(si_env "$SI/settings.ini" "")"
si_c="$(si_env "$SI/nie-ma-pliku.ini" "")"
if [ "$si_a" = "99" ] && [ "$si_b" = "3600" ] && [ "$si_c" = "1800" ]; then
    ok "settings: precedence is environment, then the host file, then the built-in"
else
    bad "settings: precedence is environment, then the host file, then the built-in" \
        "env='$si_a' file='$si_b' builtin='$si_c'"
fi

# NOTE ON WHERE THIS LIVES: test/linkfields lifts code fragments out of the
# files under test and runs them in a temp script -- it never sources
# zfs-backup.sh. Written there, every assertion below "passed" because
# cmd_set_bandwidth did not exist: rc was 127, the config was untouched, and the
# control read that as correct refusal. A test that cannot call the thing it
# names is not a weak test, it is a false one.
# --- 15. ONE TRANSACTION FOR THE WHOLE PAIR ---------------------------------
#
# REV F4b, owner's choice between the two shapes: the cap change becomes a
# single previewed transaction over every relationship of the pair, rather than
# the runtime learning to read the manifest (which would have meant CONFIG is no
# longer the runtime truth).
#
# The defect being closed: the cap belongs to the PAIR and lives in the pairing
# manifest, but an ACTIVE relationship carries it MATERIALISED in its [dataset:]
# section and in the installed cron line. Rewriting the manifest alone left the
# two disagreeing until somebody re-activated each relationship by hand,
# remembering to, one at a time.
SB="$WORK/setbw"; rm -rf "$SB"; mkdir -p "$SB/clients" "$SB/peerstate" "$SB/dir" "$SB/bin"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$SB/bin/crontab"
chmod +x "$SB/bin/crontab"
printf 'PEER_SAVED_LOCAL_USER=root\nPEER_SAVED_BANDWIDTH=2M\n' > "$SB/peerstate/10.5.5.5.conf"
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/dir/jobs.conf\n' "$SB" > "$SB/server.conf"

# TWO relationships across ONE link -- the shape the whole finding is about.
{ printf '[defaults]\n\thost_label = sbtest\n\n'
  printf '[template:hourly]\n\tsend_schedule  = 7 * * * *\n\tprefix         = automated_hourly_\n'
  printf '\tnotify_word    = snapshot\n\tprune_schedule = 27 * * * *\n\tpattern        = automated_hourly\n\tkeep           = 24\n\n'
  for n in one two; do
    printf '[dataset:tank/backups/%s/tank/src]\n' "$n"
    printf '\t# managed-by: zfs-backup.sh client=%s\n' "$n"
    printf '\tuse_template = hourly\n\tsrc          = acct@10.5.5.5:tank/src\n'
    printf '\tbandwidth    = 2M\n\trecursive    = flat\n\tpair_label   = %s\n\tnotify       = %s-at\n\n' "$n" "$n"
  done
} > "$SB/dir/jobs.conf"
for n in one two; do
  { printf 'CLIENT_NAME=%s\nPEER_HOST=10.5.5.5\nSTATE=active\n' "$n"
    printf 'MANAGED_DATASETS=tank/backups/%s/tank/src\n' "$n"
    printf 'CRON_CONFIG=%s/dir/jobs.conf\n' "$SB"
  } > "$SB/clients/$n.conf"
done

sb_run() {   # <rate or -> -> rc
    local arg="--bandwidth=$1"; [ "$1" = "-" ] && arg="--bandwidth="
    ( PATH="$SB/bin:$PATH"
      atomic_replace_and_install() { mv -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
      show_activation_proposal() { :; }
      CLIENTS_DIR="$SB/clients" PEER_STATE_DIR="$SB/peerstate" SERVER_CONF="$SB/server.conf" \
      cmd_set_bandwidth --peer=10.5.5.5 "$arg" --config="$SB/dir/jobs.conf" --yes ) >/dev/null 2>&1
}
# Either spelling: the fixture writes an ALIGNED `bandwidth    = 2M`, while a
# field this tool INSERTS is single-spaced (`bandwidth = 8M`). Pinning one of
# them made two assertions fail for a reason unrelated to what they test.
sb_capn()     { grep -cE "^	bandwidth[ 	]*= $1\$" "$SB/dir/jobs.conf"; }
sb_caps()     { sb_capn 8M; }
sb_manifest() { grep -m1 '^PEER_SAVED_BANDWIDTH=' "$SB/peerstate/10.5.5.5.conf" | cut -d= -f2-; }

sb_run 8M
{ [ "$(sb_caps)" -eq 2 ] && [ "$(sb_manifest)" = "8M" ]; } \
    && ok "pair-tx: one command moves BOTH relationships and the manifest together" \
    || bad "pair-tx: one command moves both relationships and the manifest" \
           "sections at 8M=$(sb_caps) manifest='$(sb_manifest)'"

# Removing a cap must take the LINE with it, not leave a stale one throttling
# the link -- set_or_remove, not update.
sb_run -
{ [ "$(grep -c '^	bandwidth' "$SB/dir/jobs.conf")" -eq 0 ] && [ -z "$(sb_manifest)" ]; } \
    && ok "pair-tx: an empty rate removes the field from every section and empties the manifest" \
    || bad "pair-tx: an empty rate removes the field everywhere" \
           "bandwidth lines left=$(grep -c '^	bandwidth' "$SB/dir/jobs.conf") manifest='$(sb_manifest)'"

# (a) A MANIFEST THAT DOES NOT CARRY THE KEY YET.
#
# The first cut only REWROTE an existing PEER_SAVED_BANDWIDTH= line. A manifest
# predating the field -- or written by an older deploy.sh -- kept no cap at all
# while the CONFIG got one, and `mv` reported success either way. My own test
# could not see it, because its fixture always started with the key present.
# That is the more useful half of this assertion: a fixture that always contains
# the thing under test cannot fail.
printf 'PEER_SAVED_LOCAL_USER=root\n' > "$SB/peerstate/10.5.5.5.conf"
sb_run 8M
{ [ "$(sb_caps)" -eq 2 ] && [ "$(sb_manifest)" = "8M" ]; } \
    && ok "pair-tx: the cap is APPENDED to a manifest that had no such key" \
    || bad "pair-tx: the cap is appended to a manifest that had no such key" \
           "sections at 8M=$(sb_caps) manifest='$(sb_manifest)'"

# (b) A FORCED FAILURE OF THE MANIFEST PUBLISH.
#
# The first cut warned and exited zero, leaving the jobs on the new cap and the
# manifest on the old -- the exact divergence this command exists to end, moved
# later in the sequence. "One transaction" has to mean the failure case too.
printf 'PEER_SAVED_LOCAL_USER=root\nPEER_SAVED_BANDWIDTH=2M\n' > "$SB/peerstate/10.5.5.5.conf"
rm -f "$SB/reinstalled-from"
sb_run 2M
sb_out="$( ( PATH="$SB/bin:$PATH"
             # Fail ONLY the manifest rename, by its destination. Matching the
             # last argument, because atomic_replace_and_install's own mv is
             # stubbed below and must keep working.
             mv() { local last="${!#}"; case "$last" in *peerstate*) return 1 ;; esac; command mv "$@"; }
             atomic_replace_and_install() { command mv -f "$2" "$1"; }
             assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
             assert_target_block_not_clobbered() { :; }; assert_config_readable_by_target() { :; }
             show_activation_proposal() { :; }
             # The CRONTAB is the third element of the declared transaction and
             # the first version of this control did not look at it -- it checked
             # config and manifest and stubbed this to a bare `return 0`, so
             # "everything agrees" was asserted about two thirds of the claim.
             # Record what the reinstall would have rendered FROM: the rollback
             # restores the config first and reinstalls from it, so this file
             # ends up holding the OLD cap if, and only if, both steps ran.
             gencron_as_target() {
                 case " $* " in
                     *" --install "*) grep -m1 "^	bandwidth" "$SB/dir/jobs.conf" > "$SB/reinstalled-from" 2>/dev/null || : ;;
                 esac
                 return 0
             }
             CLIENTS_DIR="$SB/clients" PEER_STATE_DIR="$SB/peerstate" SERVER_CONF="$SB/server.conf" \
             cmd_set_bandwidth --peer=10.5.5.5 --bandwidth=8M --config="$SB/dir/jobs.conf" --yes ) 2>&1 )"
sb_rc=$?
{ [ "$sb_rc" -ne 0 ] \
  && [ "$(sb_capn 2M)" -eq 2 ] \
  && [ "$(sb_manifest)" = "2M" ] \
  && grep -q '2M' "$SB/reinstalled-from" 2>/dev/null; } \
    && ok "pair-tx: a manifest publish failure ROLLS BACK -- config, crontab and manifest all stay on the old cap, rc is non-zero" \
    || bad "pair-tx: a manifest publish failure rolls back" \
           "rc=$sb_rc sections at 2M=$(sb_capn 2M) manifest='$(sb_manifest)' crontab-from='$(cat "$SB/reinstalled-from" 2>/dev/null | tr -d "\t")'" \
           "$(printf '%s' "$sb_out" | tail -1)"

# CONTROL: a peer with no pairing manifest is refused, and nothing moves --
# without it the assertions above would pass against a build that rewrites
# sections for any string at all.
cp "$SB/dir/jobs.conf" "$SB/before.conf"
( PATH="$SB/bin:$PATH"
  CLIENTS_DIR="$SB/clients" PEER_STATE_DIR="$SB/peerstate" SERVER_CONF="$SB/server.conf" \
  cmd_set_bandwidth --peer=10.9.9.9 --bandwidth=4M --config="$SB/dir/jobs.conf" --yes ) >/dev/null 2>&1
sb_rc=$?
{ [ "$sb_rc" -ne 0 ] && cmp -s "$SB/before.conf" "$SB/dir/jobs.conf"; } \
    && ok "pair-tx control: an unpaired peer is refused and the config is untouched" \
    || bad "pair-tx control: an unpaired peer is refused and the config is untouched" "rc=$sb_rc"


# ============================================================================
# 122. REV-20260827-122 F1 -- a profile given BY PATH must have its own
#      templates replaced, and the RENDERED retention must change with them.
#
# The removal loop interpolated $target_profile raw. Given `--profile=/tmp/x.conf`
# -- a form the same function accepts a few lines earlier -- it searched for
#     [template:profile__/tmp/x.conf__...]
# while the renderer had written
#     [template:profile__x__...]
# so no old template was removed. ensure_cron_config is ADDITIVE, so the old
# templates then suppressed the append of the edited policy: the candidate
# installed cleanly carrying the OLD retention, and the client record was
# stamped with the NEW digest afterwards. A second run reads that digest and
# takes the "nothing to migrate" path forever.
#
# So the assertion is the RENDERED cron line, not the config fragment and not
# the record: the reviewer's criterion 5 says so, and it is the right axis
# anyway -- the fragment and the record were both already "correct" while the
# crontab enforced something else. That gap IS the defect.
#
# Self-contained (REV-109 4.3): its own fixture, its own profile copy, nothing
# inherited from the sections above.
# ============================================================================
M122="$WORK/rev122"
rm -rf "$M122"; mkdir -p "$M122/clients" "$M122/peerstate" "$M122/keys" "$M122/dir" \
                         "$M122/root" "$M122/bin" "$M122/custom"
# A profile the operator keeps OUTSIDE the package tree and names by full path.
# d30 is the honest choice: one tier, one counter, so the rendered retention is
# a single unambiguous flag and a change to it cannot hide behind a ladder.
cp "$REPO/profiles/d30.conf" "$M122/custom/mine.conf"
cp "$REPO/profiles/default.conf" "$M122/root/default.conf"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$M122/bin/crontab"
chmod +x "$M122/bin/crontab"
for h in 10.9.9.8 10.9.9.9; do
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2U\n' "$h" > "$M122/keys/${h}_known_hosts"
done
cat > "$M122/peerstate/10.9.9.8.conf" <<EOF
PEER_SAVED_ACCOUNT=zfsbackup
PEER_SAVED_TARGET=tank/backups
PEER_SAVED_MODE=backup
PEER_SAVED_DATASETS="rpool/data"
EOF
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/dir/jobs.conf\n' "$M122" > "$M122/server.conf"
printf '[defaults]\n\thost_label = r122\n' > "$M122/dir/jobs.conf"
{ printf 'CLIENT_NAME=r122c\nPEER_HOST=10.9.9.8\nSTATE=active\n'
  printf 'ACTIVE_ENDPOINT=10.9.9.9:22\n'
  printf 'MANAGED_DATASETS=tank/backups/10.9.9.8/rpool/data\n'
  printf 'CRON_CONFIG=%s/dir/jobs.conf\n' "$M122"
} > "$M122/clients/r122c.conf"

m122_run() {   # <args...> -> rc; the migrated config lands in $M122/dir/jobs.conf
    ( PATH="$M122/bin:$PATH"
      atomic_replace_and_install() { cp -f "$2" "$1"; }
      assert_cron_config_matches_installed() { :; }
      assert_no_foreign_managed_block() { :; }
      assert_target_block_not_clobbered() { :; }
      assert_config_readable_by_target() { :; }
      assert_source_prune_grant() { :; }
      assert_no_atomic_with_source_retention() { :; }
      CLIENTS_DIR="$M122/clients" PEER_STATE_DIR="$M122/peerstate" PEER_KEY_DIR="$M122/keys" \
      SERVER_CONF="$M122/server.conf" PROFILE_ROOT="$M122/root" \
      PROFILE_ACTIVE=default PROFILE_LOADED="" \
      cmd_migrate_profile --config="$M122/dir/jobs.conf" --yes "$@" ) 2>&1
}
# THE RENDERED retention: the installed config driven through the REAL generator,
# which is what the host would actually run. Not the [template:] fragment.
m122_retain() {
    REPO_DIR=/REPO NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=/D CRON_LOG=/L \
        bash "$REPO/gen-cron.sh" -c "$M122/dir/jobs.conf" 2>/dev/null \
        | grep -oE ' -D[0-9]+' | tr -d ' ' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# --- step 1: migrate onto the custom profile, BY PATH.
m122_out="$(m122_run --profile=$M122/custom/mine.conf)"; m122_rc=$?
_g="$m122_rc"
if [ "$_g" = "0" ]; then ok "122a: a profile named by absolute path migrates at all"; else bad "122a: a profile named by absolute path migrates at all" "want [0] got [$_g]"; fi
_g="$(m122_retain)"
if [ "$_g" = "-D30" ]; then ok "122b: ...and renders the retention that profile declares"; else bad "122b: ...and renders the retention that profile declares" "want [-D30] got [$_g]"; fi
# The template family carries the CANONICAL name, never the path -- that is the
# identity the removal in step 2 has to match.
if grep -qE '^\[template:profile__mine__' "$M122/dir/jobs.conf"; then
    ok "122c: ...under the canonical namespace 'mine', not the path"
else
    bad "122c: ...under the canonical namespace 'mine', not the path" \
        "$(grep -oE '^\[template:[^]]+\]' "$M122/dir/jobs.conf" | head -3)"
fi

# --- step 2: EDIT the profile and migrate again with the same path.
#     This is the whole finding. On b0a3a289b7bfd2a9e89b8de75c5d600e382f6c0d the
#     rendered retention stays -D30 while the run reports success.
sed -i 's/^\tkeep           = 30$/\tkeep           = 10/' "$M122/custom/mine.conf"
grep -q 'keep           = 10' "$M122/custom/mine.conf" \
    && ok "122d: the fixture edit landed (keep 30 -> 10)" \
    || bad "122d: the fixture edit landed" "$(grep -n 'keep' "$M122/custom/mine.conf" | head -2)"

m122_out="$(m122_run --profile=$M122/custom/mine.conf)"; m122_rc=$?
_g="$m122_rc"
if [ "$_g" = "0" ]; then ok "122e: re-migrating an EDITED profile given by path succeeds"; else bad "122e: re-migrating an EDITED profile given by path succeeds" "want [0] got [$_g]"; fi
# THE CARRYING ASSERTION.
_g="$(m122_retain)"
if [ "$_g" = "-D10" ]; then ok "122f: ...and the RENDERED retention actually changes to the edited value"; else bad "122f: ...and the RENDERED retention actually changes to the edited value" "want [-D10] got [$_g]"; fi
# ...and the old family is gone rather than sitting beside the new one. An
# orphan [template:] is a schedule definition in a live config that nothing
# references -- and here it was the thing suppressing the new policy.
n122="$(grep -cE '^\[template:profile__mine__daily\]' "$M122/dir/jobs.conf")"
_g="$n122"
if [ "$_g" = "1" ]; then ok "122g: ...exactly one 'daily' template, not the old one plus the new"; else bad "122g: ...exactly one 'daily' template, not the old one plus the new" "want [1] got [$_g]"; fi

# --- step 3: criterion 4 -- an unchanged file is the REAL no-op path, and it is
#     only meaningful because step 2 proved the policy really moved first.
m122_out="$(m122_run --profile=$M122/custom/mine.conf)"; m122_rc=$?
_g="$m122_rc"
if [ "$_g" = "0" ]; then ok "122h: a third run with the unchanged file exits 0"; else bad "122h: a third run with the unchanged file exits 0" "want [0] got [$_g]"; fi
case "$m122_out" in
    *"nothing to migrate"*) ok "122i: ...and takes the no-op path by saying so" ;;
    *) bad "122i: ...and takes the no-op path by saying so" "$(printf '%s' "$m122_out" | tail -2)" ;;
esac
_g="$(m122_retain)"
if [ "$_g" = "-D10" ]; then ok "122j: ...leaving the edited retention in place"; else bad "122j: ...leaving the edited retention in place" "want [-D10] got [$_g]"; fi

# THE INSTALLED BLOCK'S SOURCE IS CHECKED BEFORE IT IS REPLACED.
#
# There is one managed block per crontab, so whichever config last rendered it
# owns the whole thing -- and a command resolving to a different config replaces
# every job the first one installed, including ones it has never heard of.
#
# Measured on pve9, 2026-08-29: three replica jobs installed from
# /root/replab.conf vanished when remove-client ran and resolved elsewhere.
# Nothing said a word; they were noticed only because a hash in an unrelated
# audit line was the one from before they existed.
#
# Asserted structurally -- the guard is wired into the single door every writer
# goes through -- and that is what this can honestly claim. Its runtime behaviour
# was checked on the lab: installing from /root/other.conf over a block rendered
# from /root/replab.conf printed both paths and what would be lost.
if grep -q '^warn_if_block_has_other_source()' "$ZFSBACKUP"; then
    ok "block-source guard: the check exists"
else
    bad "block-source guard: the check exists"
fi
_air="$(awk '/^atomic_replace_and_install\(\)/,/^}/' "$ZFSBACKUP")"
case "$_air" in
    *warn_if_block_has_other_source*)
        ok "BLOCK-SOURCE GUARD: CALLED FROM THE ONE DOOR EVERY WRITER USES" ;;
    *)  bad "BLOCK-SOURCE GUARD: CALLED FROM THE ONE DOOR EVERY WRITER USES" \
            "atomic_replace_and_install does not call it, so a writer could replace a foreign block silently" ;;
esac
# It must compare with the SAME normaliser the missing-config guard uses, or the
# two would disagree about what "a different file" means.
case "$(awk '/^warn_if_block_has_other_source\(\)/,/^}/' "$ZFSBACKUP")" in
    *normalize_cron_source*) ok "block-source guard: shares the path normaliser" ;;
    *) bad "block-source guard: shares the path normaliser" ;;
esac


# --- LEGACY EXCLUSION FIELDS IN A CLIENT RECORD ------------------------------
#
# The exclusion fields were renamed on 2026-09-01. The CLI and CONFIG halves of
# that rename fail LOUDLY on the old spelling -- unknown option, unknown field.
# The RECORD half would not have: the readers look the new names up by name, so
# an old record comes back with no exclusions at all and the next re-activation
# drops every -X and -E the relationship was enrolled with, silently.
#
# Zero such records existed on any of the five hosts when the rename landed, so
# this refusal should never fire in practice. That is precisely why it is
# asserted rather than argued: "should never" is a claim about a measurement
# somebody took once, not a property of the code.
LEG="$WORK/legacy"; mkdir -p "$LEG"
leg_load() {   # <record lines...> -> the loader's output
    local f="$LEG/rec.conf"; : > "$f"
    printf 'PEER_HOST=10.0.0.1\n' > "$f"
    local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
    ( peer_label() { echo lab; }; peer_manifest_path() { echo /nonexistent; }
      load_client_and_connection "$f" ) 2>&1
}
for spec in 'EXCLUDE_SNAP_1=vzdump|EXCLUDE_FAMILY_1' 'EXCLUDE_1=-swap$|EXCLUDE_CHILD_1'; do
    fld="${spec%%|*}"; want="${spec##*|}"
    out="$(leg_load "$fld")"
    if case "$out" in *"legacy field '${fld%%=*}'"*) true ;; *) false ;; esac \
       && case "$out" in *"$want"*) true ;; *) false ;; esac; then
        ok "legacy record field ${fld%%=*} is refused, naming its replacement"
    else
        bad "legacy record field ${fld%%=*} is refused, naming its replacement" "$out"
    fi
done

# The control the two negatives above cannot give: a guard that refused every
# EXCLUDE_* would pass both and break every record written since the rename.
# These must reach the manifest check, i.e. get PAST the guard.
for fld in 'EXCLUDE_FAMILY_1=vzdump' 'EXCLUDE_CHILD_1=-swap$'; do
    out="$(leg_load "$fld")"
    case "$out" in
        *"legacy field"*) bad "control: ${fld%%=*} is NOT refused" "the guard is too wide: $out" ;;
        *) ok "control: ${fld%%=*} passes the guard" ;;
    esac
done

# ...and a record with no exclusions at all, the commonest shape on the estate.
out="$(leg_load)"
case "$out" in
    *"legacy field"*) bad "control: a record with no exclusions passes the guard" "$out" ;;
    *) ok "control: a record with no exclusions passes the guard" ;;
esac



# --- purge-replica-copy: the OTHER half of remove-replica --------------------
#
# remove-replica ends by saying the copy on the medium was not touched, and for
# a long time nothing in the package could touch it. Measured 2026-09-02 during
# a lab teardown: 645M of replica sat on a disk with no verb able to name it.
#
# What is asserted here is DECISION LOGIC -- zfs and zpool are stubbed, as they
# are for the gate's own suite. That ZFS destroys what it is told belongs on a
# host with a real disk.
PRC="$WORK/purgereplica"; mkdir -p "$PRC/bin"
# Set HERE, not only in prc_run's env: prc_gate writes the gate stub with an
# unquoted heredoc, so these expand at WRITE time. Left unset they tripped
# set -u, the stub was never written, and the wrong-medium case silently
# exercised the previous stub instead -- a test that passed the wrong thing.
PRC_LOG="$PRC/calls.log"; PRC_GONE_A="$PRC/gone_a"; PRC_GONE_B="$PRC/gone_b"
export PRC_LOG PRC_GONE_A PRC_GONE_B
cat > "$PRC/bin/zpool" <<'EOF'
#!/bin/bash
[ "$1" = "import" ] && { printf '   pool: repl\n     id: 1\n  state: ONLINE\n'; exit 0; }
exit 0
EOF
chmod +x "$PRC/bin/zpool"
# The medium holds two children under the marker dataset, plus the marker.
cat > "$PRC/bin/zfs" <<'EOF'
#!/bin/bash
case "$*" in
  *"list -H -o name -d 1 repl/replica"*)
      printf 'repl/replica\nrepl/replica/tank/a\nrepl/replica/tank/b\n'; exit 0 ;;
  *"list -H -o used"*)      printf '10M\n'; exit 0 ;;
  *"list -H -t snapshot"*)  printf 'x@1\nx@2\n'; exit 0 ;;
  *"list -H -o name repl/replica/tank/a"*) [ -f "$PRC_GONE_A" ] && exit 1; printf 'repl/replica/tank/a\n'; exit 0 ;;
  *"list -H -o name repl/replica/tank/b"*) [ -f "$PRC_GONE_B" ] && exit 1; printf 'repl/replica/tank/b\n'; exit 0 ;;
  *"destroy -r repl/replica/tank/a"*) : > "$PRC_GONE_A"; echo "$*" >> "$PRC_LOG"; exit 0 ;;
  *"destroy -r repl/replica/tank/b"*) : > "$PRC_GONE_B"; echo "$*" >> "$PRC_LOG"; exit 0 ;;
  *destroy*)                echo "$*" >> "$PRC_LOG"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$PRC/bin/zfs"
prc_gate() {   # <status-rc>
    cat > "$PRC/bin/zfs-media-gate.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$PRC_LOG"
[ "\$1" = "status" ] && exit $1
exit 0
EOF
    chmod +x "$PRC/bin/zfs-media-gate.sh"
}
prc_run() {   # <config> <args...>
    local cfg="$1"; shift
    PATH="$PRC/bin:$PATH" bash -c "
        source '$ZFSBACKUP'
        SCRIPT_DIR='$PRC/bin'
        cron_target_user() { echo root; }
        cron_context_resolve() { CRON_CTX_FILE='$cfg'; }
        cmd_purge_replica_copy $*
    " 2>&1
}
: > "$PRC/calls.log"; rm -f "$PRC/gone_a" "$PRC/gone_b"
cat > "$PRC/jobs.conf" <<'EOF'
[replica:weekly]
	source    = tank/a,tank/b
	dst       = repl/replica
	prefix    = replica_
EOF

# 1. WITHOUT --yes IT DESTROYS NOTHING, and says what it would take.
prc_gate 0
out=$(prc_run "$PRC/jobs.conf" weekly); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'repl/replica/tank/a' \
   && printf '%s' "$out" | grep -q 'plan only' \
   && ! grep -q 'destroy' "$PRC/calls.log"; then
    ok "purge-replica-copy: without --yes it lists the victims and destroys nothing"
else
    bad "purge-replica-copy: without --yes it lists the victims and destroys nothing" "rc=$rc" "$out"
fi

# 2. THE MARKER DATASET SURVIVES. It is what the gate identifies the disk by;
#    taking it would leave a medium nothing can recognise -- a worse state than
#    the one being cleaned up.
if printf '%s' "$out" | grep -q 'repl/replica itself is KEPT' \
   && ! printf '%s' "$out" | grep -qE '^>>>   repl/replica  '; then
    ok "purge-replica-copy: the marker dataset is named as kept, not listed as a victim"
else
    bad "purge-replica-copy: the marker dataset is named as kept, not listed as a victim" "$out"
fi

# 3. A WRONG MEDIUM IS REFUSED. This is the one mistake that cannot be taken
#    back, and the gate is the only thing that can tell "not imported" from
#    "imported, but this is somebody else's disk".
: > "$PRC/calls.log"
prc_gate 2
out=$(prc_run "$PRC/jobs.conf" weekly --yes); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'WRONG medium' \
   && ! grep -q 'destroy' "$PRC/calls.log"; then
    ok "purge-replica-copy: a wrong medium is refused and nothing is destroyed"
else
    bad "purge-replica-copy: a wrong medium is refused and nothing is destroyed" "rc=$rc" "$out"
fi

# 4. WITH --yes IT DESTROYS THE CHILDREN, and only them.
: > "$PRC/calls.log"; rm -f "$PRC/gone_a" "$PRC/gone_b"
prc_gate 0
out=$(prc_run "$PRC/jobs.conf" weekly --yes); rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q 'destroy -r repl/replica/tank/a' "$PRC/calls.log" \
   && grep -q 'destroy -r repl/replica/tank/b' "$PRC/calls.log" \
   && ! grep -qE 'destroy -r repl/replica$' "$PRC/calls.log"; then
    ok "purge-replica-copy: --yes destroys the per-source children and not the marker"
else
    bad "purge-replica-copy: --yes destroys the per-source children and not the marker" "rc=$rc" "$(cat "$PRC/calls.log")"
fi

# 5. NO SECTION AND NO --dst IS A REFUSAL, NOT A GUESS.
#    This is the order that actually happens: the job is removed first and the
#    copy is noticed later, by which time nothing records the destination. A
#    command that guessed which dataset on the disk was ours would eventually
#    guess wrong on a disk holding more than one thing.
: > "$PRC/calls.log"
printf '[defaults]\n' > "$PRC/empty.conf"
out=$(prc_run "$PRC/empty.conf" weekly --yes); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'will not guess' \
   && ! grep -q 'destroy' "$PRC/calls.log"; then
    ok "purge-replica-copy: with no section and no --dst it refuses rather than guessing"
else
    bad "purge-replica-copy: with no section and no --dst it refuses rather than guessing" "rc=$rc" "$out"
fi

# 6. ...and --dst alone is enough to work without the config.
: > "$PRC/calls.log"; rm -f "$PRC/gone_a" "$PRC/gone_b"
out=$(prc_run "$PRC/empty.conf" weekly --dst=repl/replica --yes); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'destroy -r repl/replica/tank/a' "$PRC/calls.log"; then
    ok "purge-replica-copy: --dst alone works when the section is already gone"
else
    bad "purge-replica-copy: --dst alone works when the section is already gone" "rc=$rc" "$(cat "$PRC/calls.log")"
fi


# --- --source-profile: asymmetric retention ---------------------------------
#
# Owner, 2026-09-03: a source short of disk under a collector with plenty --
# "jestem zmuszony przycinac retencje w zrodle szybciej, ale na celu chce
# utrzymac pelny profil, bo to backup w koncu".
#
# Two SHIPPED profiles, not fixtures, and they are the owner's own case:
# d7h24 and d30h24 keep the SAME families (automated_hourly, automated_daily)
# for different lengths, while d30 keeps daily ONLY. So the legitimate
# asymmetry and the refused one are both real files a person could name.
SP="$WORK/sourceprofile"
rm -rf "$SP"; mkdir -p "$SP/root"
cp "$REPO"/profiles/d7h24.conf "$REPO"/profiles/d30h24.conf "$REPO"/profiles/d30.conf "$SP/root/"

sp_run() {   # <target-profile> <source-profile or ""> <extra shell>
    PROFILE_ROOT="$SP/root" bash -c "
        source '$ZFSBACKUP'
        PROFILE_ROOT='$SP/root'
        PROFILE_ACTIVE='$1'; load_active_profile
        SRC_PROFILE_NAME='$2'
        source_profile_prepare '$1'
        $3
    " 2>&1
}

# 1. THE OWNER'S CASE RENDERS, and renders something DIFFERENT from the target.
#    A run that merely exits 0 proves nothing here: the whole feature is that
#    the two sides stop being copies of each other, so the discriminator is
#    that the two fragments differ.
out=$(sp_run d30h24 d7h24 'diff -q "$(profile_retention_fragment)" "$(source_retention_fragment)" >/dev/null && echo SAME || echo DIFFERENT'); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "DIFFERENT" ]; then
    ok "--source-profile: a shorter source ladder under a longer target renders a DIFFERENT source fragment"
else
    bad "--source-profile: a shorter source ladder under a longer target renders a DIFFERENT source fragment" "rc=$rc" "$out"
fi

# 2. POSITIVE CONTROL FOR 1. Without the flag the two are the SAME file --
#    the owner's stated condition, and the behaviour every existing
#    relationship depends on. If this said DIFFERENT, test 1 would be
#    measuring nothing but its own noise.
out=$(sp_run d30h24 '' 'diff -q "$(profile_retention_fragment)" "$(source_retention_fragment)" >/dev/null && echo SAME || echo DIFFERENT')
if [ "$out" = "SAME" ]; then
    ok "--source-profile omitted: the source fragment IS the target fragment, unchanged"
else
    bad "--source-profile omitted: the source fragment IS the target fragment, unchanged" "$out"
fi

# 3. NAMING THE SAME PROFILE ON BOTH SIDES collapses to that same path rather
#    than staging a needless second copy of it.
out=$(sp_run d30h24 d30h24 'printf "[%s]" "$SRC_PROFILE_NAME"')
if [ "$out" = "[]" ]; then
    ok "--source-profile equal to --profile collapses to the no-asymmetry path"
else
    bad "--source-profile equal to --profile collapses to the no-asymmetry path" "$out"
fi

# 4. A DIFFERENT FAMILY IS REFUSED. d30 prunes automated_daily only; against a
#    target that also carries hourly, the source's hourly snapshots would never
#    be pruned -- and because delsnaps matching nothing exits 0, the nightly
#    job would report success while the disk filled. Fail-open, silently. This
#    refusal is the reason the feature is safe to ship at all.
out=$(sp_run d30h24 d30 'echo REACHED'); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'different snapshot FAMILY' \
   && ! printf '%s' "$out" | grep -q 'REACHED'; then
    ok "--source-profile: a profile pruning a different FAMILY is refused before anything renders"
else
    bad "--source-profile: a profile pruning a different FAMILY is refused before anything renders" "rc=$rc" "$out"
fi

# 5. THE REMOTE HALF IS CREATE-TIME, like --profile beside it.
#    REV-20260811-107 preserves a source retention the admin edited by hand.
#    If a re-activation restaged the recorded preset, it would render straight
#    over that edit -- the operator would lose their change to a re-activation
#    performed for some unrelated reason. is_new=0 must stage nothing.
out=$(PROFILE_ROOT="$SP/root" bash -c "
    source '$ZFSBACKUP'
    PROFILE_ROOT='$SP/root'; PROFILE_ACTIVE=d30h24; load_active_profile
    SOURCE_PROFILE=d7h24
    apply_client_profile_choice 0 d30h24
    printf '[%s]' \"\$SRC_PROFILE_NAME\"" 2>&1)
if [ "$out" = "[]" ]; then
    ok "activate-client: a RE-activation does not restage the recorded source profile"
else
    bad "activate-client: a RE-activation does not restage the recorded source profile" "$out"
fi

# 6. POSITIVE CONTROL FOR 5: the FIRST activation does stage it. Otherwise 5
#    would pass just as well against a feature that never works at all.
out=$(PROFILE_ROOT="$SP/root" bash -c "
    source '$ZFSBACKUP'
    PROFILE_ROOT='$SP/root'; PROFILE_ACTIVE=d30h24; load_active_profile
    SOURCE_PROFILE=d7h24
    apply_client_profile_choice 1 d30h24
    printf '[%s]' \"\$SRC_PROFILE_NAME\"" 2>&1)
if [ "$out" = "[d7h24]" ]; then
    ok "activate-client: the FIRST activation stages the recorded source profile"
else
    bad "activate-client: the FIRST activation stages the recorded source profile" "$out"
fi

# 7. add-client RECORDS the field...
mkdir -p "$SP/clients"
printf '#!/bin/bash\nexit 0\n' > "$SP/deploy_marker.sh"; chmod +x "$SP/deploy_marker.sh"
printf 'DEFAULT_TARGET=tank/backups\nCRON_CONFIG=%s/jobs.conf\n' "$SP" > "$SP/server.conf"
( SERVER_CONF="$SP/server.conf" CLIENTS_DIR="$SP/clients" DEPLOY="$SP/deploy_marker.sh" \
  PROFILE_ROOT="$SP/root"
  cmd_add_client "spc"  --lan=10.0.0.1 --datasets="tank/x" --profile=d30h24 --source-profile=d7h24
  cmd_add_client "spc2" --lan=10.0.0.2 --datasets="tank/x" --profile=d30h24 ) >/dev/null 2>&1
if grep -q '^SOURCE_PROFILE=d7h24$' "$SP/clients/spc.conf"; then
    ok "add-client: --source-profile is recorded in the client record"
else
    bad "add-client: --source-profile is recorded in the client record" "$(cat "$SP/clients/spc.conf" 2>&1)"
fi

# 8. ...and writes NO field at all without it. An empty SOURCE_PROFILE= would
#    read the same to the code, but a record that grew a line it never had is
#    a record whose meaning has to be re-derived by whoever reads it next. The
#    absent field IS the contract: same preset on both sides.
#
#    RUN IN THE SAME PROCESS AS 7, deliberately. SRC_PROFILE_NAME is a global,
#    and the first cut of this test used a fresh subshell -- which passed while
#    a second add-client in one process was in fact inheriting the first one's
#    --source-profile. A subshell per call tests the shell, not the code.
if [ -f "$SP/clients/spc2.conf" ] && ! grep -q 'SOURCE_PROFILE' "$SP/clients/spc2.conf"; then
    ok "add-client without --source-profile writes no SOURCE_PROFILE line at all"
else
    bad "add-client without --source-profile writes no SOURCE_PROFILE line at all" "$(cat "$SP/clients/spc2.conf" 2>&1)"
fi

# 9. A TYPO DIES AT ENROLMENT, before any pairing or key exchange -- the same
#    boundary --profile rides, and for the reason written above it: an
#    operator who mistypes one of two profile names on one line should not
#    find out at the first activate-client on a live host.
#    The refusal must NAME THE FLAG. load_active_profile's own message says
#    "profile 'x': ..." which is true and useless when two were passed.
out=$( SERVER_CONF="$SP/server.conf" CLIENTS_DIR="$SP/clients" DEPLOY="$SP/deploy_marker.sh" \
       PROFILE_ROOT="$SP/root" \
       cmd_add_client "sptypo" --lan=10.0.0.3 --datasets="tank/x" --profile=d30h24 --source-profile=nosuchprofile 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "source-profile='nosuchprofile'" \
   && [ ! -f "$SP/clients/sptypo.conf" ]; then
    ok "add-client: a typo'd --source-profile is refused by name and leaves no record"
else
    bad "add-client: a typo'd --source-profile is refused by name and leaves no record" "rc=$rc" "$out"
fi

# 10. ...and so does a FAMILY mismatch. This is the mistake most likely to
#     follow a typo -- a real profile, wrong ladder -- and the one that fails
#     OPEN if it survives to the source's nightly prune.
out=$( SERVER_CONF="$SP/server.conf" CLIENTS_DIR="$SP/clients" DEPLOY="$SP/deploy_marker.sh" \
       PROFILE_ROOT="$SP/root" \
       cmd_add_client "spfam" --lan=10.0.0.4 --datasets="tank/x" --profile=d30h24 --source-profile=d30 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'different snapshot FAMILY' \
   && [ ! -f "$SP/clients/spfam.conf" ]; then
    ok "add-client: a source profile of a different FAMILY is refused at enrolment"
else
    bad "add-client: a source profile of a different FAMILY is refused at enrolment" "rc=$rc" "$out"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
