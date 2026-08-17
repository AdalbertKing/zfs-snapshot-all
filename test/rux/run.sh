#!/bin/bash
# Tests for zfs-backup.sh's RUX layer -- the unified remote deployment UX
# (docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md, Owner decision,
# status MUST DO). Pure/text: add-client's own network/SSH work is reached
# through a stubbed deploy.sh (same pattern test/zfsbackup/run.sh already
# uses), and the seed/activate stages are stubbed directly, since RUX's own
# contract is ORCHESTRATION -- which existing lifecycle calls happen, in what
# order, from what state -- not a second proof of the engine underneath.
#
#   ./test/rux/run.sh
#
# Pins, RUX-1 (parser + read-only planner):
#   local --source (no ':') reaches cmd_local_backup UNCHANGED
#   remote backup form (--source=HOST:DATASET --target=X) parses correctly
#   remote sync form (--source=HOST:DATASET --mode=sync) parses to identity
#   ambiguous/invalid source syntax refuses
#   no --install leaves both hosts untouched (no CLIENTS_DIR write, no DEPLOY call)
# Pins, RUX-2/RUX-3 (orchestration through the existing lifecycle):
#   fresh remote relationship: add-client (with the right args) -> seed -> activate
#   existing matching relationship is recognized and resumed, not re-enrolled
#   conflicting relationship facts refuse
#   an existing relationship not created by RUX (no RUX_SOURCE) refuses rather
#     than silently adopting it
#   ambiguous host (two existing relationships) refuses and asks for --name
#   the source-side granted scope is verified against the requested dataset
#     before seeding; a mismatch refuses with the exact reason
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-backup.sh at $ZB" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'profile_release_tmp 2>/dev/null; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# shellcheck disable=SC1090
source "$ZB"

# ------------------------------------------------------------------------------
# 1. Local --source is untouched: rux_entry must reach cmd_local_backup with
#    the ORIGINAL argument vector for anything without ':' in --source.
out="$( ( CLIENTS_DIR="$WORK/1/clients"
    rux_entry --source=rpool/data --target=hdd/backup
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "local-backup: source 'rpool/data' does not exist"; then
    ok "1. local --source (no ':') reaches cmd_local_backup unchanged"
else
    bad "1. local --source (no ':') reaches cmd_local_backup unchanged" "rc=$rc out=$out"
fi

# 2. Bare --target with no --source at all: same local refusal as before RUX.
out="$( ( CLIENTS_DIR="$WORK/2/clients"
    rux_entry --target=hdd/backup
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--source=<dataset>\[,<dataset>\.\.\.\] is required'; then
    ok "2. bare --target with no --source: unchanged local refusal"
else
    bad "2. bare --target with no --source: unchanged local refusal" "rc=$rc out=$out"
fi

# ------------------------------------------------------------------------------
# 3. Remote backup form: plan parses host/dataset/target correctly, touches
#    nothing (no CLIENTS_DIR write, since this run has no --install).
out="$( ( CLIENTS_DIR="$WORK/3/clients"
    rux_entry --source=pve2:rpool/data --target=hdd/backup
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -q 'remote source:.*pve2:rpool/data' \
        && printf '%s' "$out" | grep -q 'mode:.*backup' \
        && printf '%s' "$out" | grep -q 'local target:.*hdd/backup' \
        && [ ! -d "$WORK/3/clients" ]; then
    ok "3. remote backup form parses host/dataset/target, no --install touches nothing"
else
    bad "3. remote backup form parses host/dataset/target, no --install touches nothing" "rc=$rc out=$out"
fi

# 4. Remote sync form: parses to identity mapping (no target line, mode=sync).
out="$( ( CLIENTS_DIR="$WORK/4/clients"
    rux_entry --source=pve1:hdd/backup --mode=sync
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -q 'remote source:.*pve1:hdd/backup' \
        && printf '%s' "$out" | grep -q "mode:.*sync (identity-preserving -- lands at 'hdd/backup'" \
        && ! printf '%s' "$out" | grep -q 'local target:' \
        && [ ! -d "$WORK/4/clients" ]; then
    ok "4. remote sync form parses to identity mapping, no --install touches nothing"
else
    bad "4. remote sync form parses to identity mapping, no --install touches nothing" "rc=$rc out=$out"
fi

# ------------------------------------------------------------------------------
# 5. Ambiguous/invalid source syntax refuses.
for bad_source in "pve2:" ":rpool/data" "pve2:rpool/data:extra"; do
    out="$( ( CLIENTS_DIR="$WORK/5/clients"
        rux_entry --source="$bad_source" --target=hdd/backup
    ) 2>&1 )"; rc=$?
    # "pve2:rpool/data:extra" is accepted (host=pve2, dataset=rpool/data:extra) --
    # a dataset name may legally contain ':' in ZFS; only genuinely EMPTY host
    # or dataset refuses. Adjust expectation for that one case.
    case "$bad_source" in
        "pve2:rpool/data:extra")
            if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'pve2:rpool/data:extra'; then
                ok "5. --source='$bad_source' splits on the FIRST ':' (documented convention)"
            else
                bad "5. --source='$bad_source' splits on the FIRST ':' (documented convention)" "rc=$rc out=$out"
            fi
            ;;
        *)
            if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not a valid HOST:DATASET'; then
                ok "5. --source='$bad_source' refuses (empty host or dataset)"
            else
                bad "5. --source='$bad_source' refuses (empty host or dataset)" "rc=$rc out=$out"
            fi
            ;;
    esac
done

# 6. --mode must be 'sync' for a remote source; anything else refuses.
out="$( ( CLIENTS_DIR="$WORK/6/clients"
    rux_entry --source=pve2:rpool/data --target=hdd/backup --mode=backup
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "mode must be 'sync'"; then
    ok "6. --mode=backup on a remote source refuses (only --mode=sync is meaningful here)"
else
    bad "6. --mode=backup on a remote source refuses (only --mode=sync is meaningful here)" "rc=$rc out=$out"
fi

# 7. --mode=sync + --target refuses (identity mapping, no second target answer).
out="$( ( CLIENTS_DIR="$WORK/7/clients"
    rux_entry --source=pve1:hdd/backup --mode=sync --target=x
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'do not also pass --target'; then
    ok "7. --mode=sync + --target refuses"
else
    bad "7. --mode=sync + --target refuses" "rc=$rc out=$out"
fi

# 8. Backup form with no --target and no --mode=sync refuses.
out="$( ( CLIENTS_DIR="$WORK/8/clients"
    rux_entry --source=pve2:rpool/data
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--target=DATASET is required'; then
    ok "8. remote backup form with no --target refuses"
else
    bad "8. remote backup form with no --target refuses" "rc=$rc out=$out"
fi

# 9. Unknown option on the remote path refuses (not silently swallowed --
#    the remote branch never delegates the raw argv, so it must validate
#    strictly itself).
out="$( ( CLIENTS_DIR="$WORK/9/clients"
    rux_entry --source=pve2:rpool/data --target=hdd/backup --frobnicate
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'unknown option --frobnicate'; then
    ok "9. unknown option on the remote path refuses"
else
    bad "9. unknown option on the remote path refuses" "rc=$rc out=$out"
fi

# ------------------------------------------------------------------------------
# Shared fixture for the --install (orchestration) tests: a deploy.sh stub
# that records every call, and stand-in seed/activate functions so RUX's own
# contract (which calls happen, in what order, from what state) is checked
# without re-proving the engine underneath (already covered by
# test/zfsbackup/run.sh / test/localbackup/run.sh).
mkdir -p "$WORK/inst"
INST_DEPLOY="$WORK/inst/deploy-stub.sh"
cat > "$INST_DEPLOY" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$INST_PAIR_LOG"
exit 0
EOF
chmod +x "$INST_DEPLOY"
export INST_PAIR_LOG="$WORK/inst/pair.log"

# 10. Fresh remote relationship, backup mode: add-client gets --datasets (the
#     requested dataset, not deferred discovery) and --target; RUX_SOURCE/
#     TARGET/MODE are recorded; seed then activate run, in order, exactly once.
: > "$INST_PAIR_LOG"
out="$( (
    profile_validate_dir() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
    CLIENTS_DIR="$WORK/10/clients"; mkdir -p "$CLIENTS_DIR"
    RELATIONSHIPS_DIR="$WORK/10/relationships"
    DEPLOY="$INST_DEPLOY"
    cmd_seed()     { echo "SEED $*" >> "$WORK/10/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/10/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] \
        && grep -q -- '--peer-datasets=rpool/data' "$INST_PAIR_LOG" \
        && grep -q -- '--target=hdd/backup' "$INST_PAIR_LOG" \
        && grep -q -- '--peer=pve2' "$INST_PAIR_LOG" \
        && grep -q -- '--join-remotely' "$INST_PAIR_LOG" \
        && grep -qF 'RUX_SOURCE=pve2:rpool/data' "$WORK/10/clients/pve2.conf" \
        && grep -qF 'RUX_TARGET=hdd/backup' "$WORK/10/clients/pve2.conf" \
        && [ "$(cat "$WORK/10/order")" = "$(printf 'SEED pve2 --yes\nACTIVATE pve2 --yes')" ]; then
    ok "10. fresh remote backup relationship: add-client(--datasets,--target) -> seed -> activate, in order"
else
    bad "10. fresh remote backup relationship: add-client(--datasets,--target) -> seed -> activate, in order" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null) record=$(cat "$WORK/10/clients/pve2.conf" 2>/dev/null) order=$(cat "$WORK/10/order" 2>/dev/null)"
fi

# 11. Fresh remote relationship, sync mode: add-client gets --mode=sync, no
#     --datasets, no --target.
: > "$INST_PAIR_LOG"
out="$( (
    profile_validate_dir() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
    CLIENTS_DIR="$WORK/11/clients"; mkdir -p "$CLIENTS_DIR"
    RELATIONSHIPS_DIR="$WORK/11/relationships"
    DEPLOY="$INST_DEPLOY"
    cmd_seed()     { echo "SEED $*" >> "$WORK/11/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/11/order"; }
    rux_entry --source=pve1:hdd/backup --mode=sync --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] \
        && grep -q -- '--mode=sync' "$INST_PAIR_LOG" \
        && ! grep -q -- '--datasets=' "$INST_PAIR_LOG" \
        && ! grep -q -- '--target=' "$INST_PAIR_LOG" \
        && grep -qF 'RUX_SOURCE=pve1:hdd/backup' "$WORK/11/clients/pve1.conf" \
        && grep -qF 'RUX_MODE=sync' "$WORK/11/clients/pve1.conf"; then
    ok "11. fresh remote sync relationship: add-client(--mode=sync), no --datasets/--target"
else
    bad "11. fresh remote sync relationship: add-client(--mode=sync), no --datasets/--target" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null) record=$(cat "$WORK/11/clients/pve1.conf" 2>/dev/null)"
fi

# 12. Relationship name derives from the host (peer_label) when --name is
#     omitted, and a valid IPv4 host is used as-is (already a legal name).
: > "$INST_PAIR_LOG"
( profile_validate_dir() { return 0; }
  read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER="zfsbackup"; }
  CLIENTS_DIR="$WORK/12/clients"; mkdir -p "$CLIENTS_DIR"
  RELATIONSHIPS_DIR="$WORK/12/relationships"
  DEPLOY="$INST_DEPLOY"
  cmd_seed()     { :; }
  cmd_activate() { :; }
  rux_entry --source=192.168.28.9:rpool/data --target=hdd/backup --install --yes
) > /dev/null 2>&1
if [ -f "$WORK/12/clients/192.168.28.9.conf" ]; then
    ok "12. relationship name derives from the host when --name is omitted"
else
    bad "12. relationship name derives from the host when --name is omitted" "no such client record; dir=$(ls "$WORK/12/clients" 2>&1)"
fi

# 13. An already-active/pending relationship for the SAME host+dataset+target
#     is RESUMED (no second add-client call), and re-run is idempotent.
: > "$INST_PAIR_LOG"
mkdir -p "$WORK/13/clients"
cat > "$WORK/13/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=seed_complete
RUX_SOURCE=pve2:rpool/data
RUX_TARGET=hdd/backup
RUX_MODE=
EOF
out="$( (
    CLIENTS_DIR="$WORK/13/clients"
    DEPLOY="$INST_DEPLOY"
    cmd_seed()     { echo "SEED $*" >> "$WORK/13/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/13/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] \
        && [ ! -s "$INST_PAIR_LOG" ] \
        && [ "$(cat "$WORK/13/order")" = "ACTIVATE pve2 --yes" ]; then
    ok "13. matching existing relationship is resumed (no re-enrolment), seed_complete skips straight to activate"
else
    bad "13. matching existing relationship is resumed (no re-enrolment), seed_complete skips straight to activate" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null) order=$(cat "$WORK/13/order" 2>/dev/null)"
fi

# 14. Conflicting relationship facts (same host, different target) refuse
#     rather than silently mutating/adopting it. No add-client, seed or
#     activate call happens.
: > "$INST_PAIR_LOG"
mkdir -p "$WORK/14/clients"
cat > "$WORK/14/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=active
RUX_SOURCE=pve2:rpool/data
RUX_TARGET=hdd/backup
RUX_MODE=
EOF
out="$( (
    CLIENTS_DIR="$WORK/14/clients"
    DEPLOY="$INST_DEPLOY"
    cmd_seed()     { echo "SEED $*" >> "$WORK/14/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/14/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/OTHER --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] \
        && printf '%s' "$out" | grep -q 'conflicts with this request' \
        && [ ! -s "$INST_PAIR_LOG" ] \
        && [ ! -e "$WORK/14/order" ]; then
    ok "14. conflicting relationship facts (same host, different target) refuse, nothing runs"
else
    bad "14. conflicting relationship facts (same host, different target) refuse, nothing runs" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null) order=$(cat "$WORK/14/order" 2>/dev/null)"
fi

# 15. A relationship found by host match that was NOT created through RUX (no
#     RUX_SOURCE recorded -- e.g. legacy `deploy`/`add-client`) refuses rather
#     than silently adopting it.
mkdir -p "$WORK/15/clients"
cat > "$WORK/15/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=active
EOF
out="$( (
    CLIENTS_DIR="$WORK/15/clients"
    DEPLOY="$INST_DEPLOY"
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not created through this unified entry point'; then
    ok "15. an existing non-RUX relationship for the same host refuses rather than adopting it"
else
    bad "15. an existing non-RUX relationship for the same host refuses rather than adopting it" "rc=$rc out=$out"
fi

# 16. Ambiguous host: two existing relationships already point at the same
#     host -- refuses and asks for --name, both without --install (plan) and
#     with --install.
mkdir -p "$WORK/16/clients"
cat > "$WORK/16/clients/a.conf" <<EOF
CLIENT_NAME=a
PEER_HOST=pve2
STATE=active
EOF
cat > "$WORK/16/clients/b.conf" <<EOF
CLIENT_NAME=b
PEER_HOST=pve2
STATE=active
EOF
out="$( ( CLIENTS_DIR="$WORK/16/clients"
    rux_entry --source=pve2:rpool/data --target=hdd/backup
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- 'pass --name=NAME'; then
    ok "16. ambiguous host (two existing relationships) refuses and asks for --name"
else
    bad "16. ambiguous host (two existing relationships) refuses and asks for --name" "rc=$rc out=$out"
fi
out="$( ( CLIENTS_DIR="$WORK/16/clients"
    rux_entry --source=pve2:rpool/data --target=hdd/backup --name=a
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'relationship name:.*a$'; then
    ok "16b. --name=a disambiguates and selects the named relationship"
else
    bad "16b. --name=a disambiguates and selects the named relationship" "rc=$rc out=$out"
fi

# ------------------------------------------------------------------------------
# 17. rux_verify_requested_scope: the request is checked against the scope the
#     source actually COMMITTED, fetched over the pairing channel -- never
#     against the collector-side manifest. The manifest's PEER_SAVED_DATASETS
#     records the REQUEST (written at --pair time from --datasets), so the old
#     shape of this test compared the request with itself and could not fail
#     for the reason it claimed to pin. Found live 2026-08-17 (lab3): the check
#     passed while the source had granted NOTHING, and the seed died on a raw
#     'cannot create snapshots: permission denied'. The grant-missing branch
#     itself (no sha256 sidecar -> refuse naming deploy.sh --commit-scope) lives
#     in fetch_committed_scope and was proven live on pve1<->pve2 the same day;
#     here the fetch is stubbed with a scope FILE, so what this pins is the
#     comparison semantics: lib-scope's real scope_read/scope_includes against
#     the fetched content, and the refusal happening BEFORE cmd_seed.
mkdir -p "$WORK/17/clients" "$WORK/17/peers"
cat > "$WORK/17/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=pending_enroll
RUX_SOURCE=pve2:rpool/data
RUX_TARGET=hdd/backup
RUX_MODE=
EOF
label=$(peer_label pve2)
# The manifest exists (join ran) and, as in the real defect, records the
# REQUEST -- the check must NOT be able to satisfy itself from it.
cat > "$WORK/17/peers/$label.conf" <<EOF
PEER_SAVED_DATASETS="rpool/data"
EOF
cat > "$WORK/17/committed.scope" <<EOF
[dataset:rpool/other]
include_parent = yes
include_children = yes
EOF
out="$( (
    CLIENTS_DIR="$WORK/17/clients"
    PEER_STATE_DIR="$WORK/17/peers"
    load_client_and_connection() { LOAD_HOST=pve2; }
    fetch_committed_scope() { cat "$WORK/17/committed.scope" > "$1"; }
    cmd_seed()     { echo "SEED $*" >> "$WORK/17/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/17/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] \
        && printf '%s' "$out" | grep -q "not covered by the scope 'pve2' actually COMMITTED" \
        && [ ! -e "$WORK/17/order" ]; then
    ok "17. request outside the COMMITTED scope refuses before seeding (manifest echo cannot satisfy it)"
else
    bad "17. request outside the COMMITTED scope refuses before seeding (manifest echo cannot satisfy it)" \
        "rc=$rc out=$out order=$(cat "$WORK/17/order" 2>/dev/null)"
fi

# 18. Same fixture, but the COMMITTED scope covers the request via a parent
#     stanza -- seeding proceeds.
mkdir -p "$WORK/18/clients" "$WORK/18/peers"
cat > "$WORK/18/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=pending_enroll
RUX_SOURCE=pve2:rpool/data
RUX_TARGET=hdd/backup
RUX_MODE=
EOF
cat > "$WORK/18/peers/$label.conf" <<EOF
PEER_SAVED_DATASETS="rpool/data"
EOF
cat > "$WORK/18/committed.scope" <<EOF
[dataset:rpool]
include_parent = yes
include_children = yes
EOF
out="$( (
    CLIENTS_DIR="$WORK/18/clients"
    PEER_STATE_DIR="$WORK/18/peers"
    load_client_and_connection() { LOAD_HOST=pve2; }
    fetch_committed_scope() { cat "$WORK/18/committed.scope" > "$1"; }
    cmd_seed()     { echo "SEED $*" >> "$WORK/18/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/18/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/18/order")" = "$(printf 'SEED pve2 --yes\nACTIVATE pve2 --yes')" ]; then
    ok "18. request covered by a parent stanza in the COMMITTED scope proceeds to seed/activate"
else
    bad "18. request covered by a parent stanza in the COMMITTED scope proceeds to seed/activate" \
        "rc=$rc out=$out order=$(cat "$WORK/18/order" 2>/dev/null)"
fi

# 19. --local-user=NAME is threaded through to add-client on a fresh
#     enrolment (found live, 2026-08-16: a collector with no server.conf
#     LOCAL_USER had no way to name a delegated account through RUX at all).
: > "$INST_PAIR_LOG"
out="$( (
    profile_validate_dir() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER=""; }
    CLIENTS_DIR="$WORK/19/clients"; mkdir -p "$CLIENTS_DIR"
    RELATIONSHIPS_DIR="$WORK/19/relationships"
    DEPLOY="$INST_DEPLOY"
    cmd_seed()     { :; }
    cmd_activate() { :; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --local-user=zfsbackup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grep -q -- '--local-user=zfsbackup' "$INST_PAIR_LOG"; then
    ok "19. --local-user=NAME is threaded through to add-client on fresh enrolment"
else
    bad "19. --local-user=NAME is threaded through to add-client on fresh enrolment" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null)"
fi

# 20. Without --local-user, a collector with no server.conf account still
#     refuses cleanly (add-client's own Batch B guard, reached unchanged --
#     RUX must not paper over it by defaulting to root).
: > "$INST_PAIR_LOG"
out="$( (
    profile_validate_dir() { return 0; }
    read_server_conf() { DEFAULT_TARGET=""; LOCAL_USER=""; }
    CLIENTS_DIR="$WORK/20/clients"; mkdir -p "$CLIENTS_DIR"
    RELATIONSHIPS_DIR="$WORK/20/relationships"
    DEPLOY="$INST_DEPLOY"
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no delegated backup account configured' && [ ! -s "$INST_PAIR_LOG" ]; then
    ok "20. no --local-user and no server.conf account: add-client's own refusal reaches the operator unchanged"
else
    bad "20. no --local-user and no server.conf account: add-client's own refusal reaches the operator unchanged" \
        "rc=$rc out=$out pair=$(cat "$INST_PAIR_LOG" 2>/dev/null)"
fi

# ------------------------------------------------------------------------------
# 21-24. --grant-remotely (OWNER-GRANT-REMOTELY-2026-08-17). Pure/text: the
# root-ssh-touching internals are stubbed; what is pinned is the ORCHESTRATION
# CONTRACT -- when the grant step runs, what stops it, and that verification
# still runs afterwards with its own authority.

# 21. With the flag, the grant step runs BEFORE verification and before the
#     lifecycle -- order, not presence (a grant after seed would be the
#     unsafe implementation that still shows both lines).
mkdir -p "$WORK/21/clients" "$WORK/21/peers"
cat > "$WORK/21/clients/pve2.conf" <<EOF
CLIENT_NAME=pve2
PEER_HOST=pve2
STATE=pending_enroll
RUX_SOURCE=pve2:rpool/data
RUX_TARGET=hdd/backup
RUX_MODE=
EOF
cat > "$WORK/21/peers/$label.conf" <<EOF
PEER_SAVED_DATASETS="rpool/data"
EOF
out="$( (
    CLIENTS_DIR="$WORK/21/clients"
    PEER_STATE_DIR="$WORK/21/peers"
    rux_grant_remotely() { echo "GRANT $3" >> "$WORK/21/order"; }
    load_client_and_connection() { LOAD_HOST=pve2; }
    fetch_committed_scope() { printf '[dataset:rpool/data]\ninclude_parent = yes\ninclude_children = yes\n' > "$1"; }
    cmd_seed()     { echo "SEED $*" >> "$WORK/21/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/21/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --grant-remotely --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/21/order")" = "$(printf 'GRANT rpool/data\nSEED pve2 --yes\nACTIVATE pve2 --yes')" ]; then
    ok "21. --grant-remotely: grant runs first, then seed/activate -- order pinned"
else
    bad "21. --grant-remotely: grant runs first, then seed/activate -- order pinned" \
        "rc=$rc out=$out order=$(cat "$WORK/21/order" 2>/dev/null)"
fi

# 22. WITHOUT the flag the grant step never runs -- the default path stays
#     two-touch (U10-shaped), byte-for-byte the pre-flag behaviour.
mkdir -p "$WORK/22/clients" "$WORK/22/peers"
cp "$WORK/21/clients/pve2.conf" "$WORK/22/clients/pve2.conf"
cp "$WORK/21/peers/$label.conf" "$WORK/22/peers/$label.conf"
out="$( (
    CLIENTS_DIR="$WORK/22/clients"
    PEER_STATE_DIR="$WORK/22/peers"
    rux_grant_remotely() { echo "GRANT $3" >> "$WORK/22/order"; }
    load_client_and_connection() { LOAD_HOST=pve2; }
    fetch_committed_scope() { printf '[dataset:rpool/data]\ninclude_parent = yes\ninclude_children = yes\n' > "$1"; }
    cmd_seed()     { echo "SEED $*" >> "$WORK/22/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/22/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/22/order")" = "$(printf 'SEED pve2 --yes\nACTIVATE pve2 --yes')" ]; then
    ok "22. without --grant-remotely no grant step runs -- the default stays two-touch"
else
    bad "22. without --grant-remotely no grant step runs -- the default stays two-touch" \
        "rc=$rc out=$out order=$(cat "$WORK/22/order" 2>/dev/null)"
fi

# 23. A remote grant does NOT bypass verification: the fetched committed
#     scope still decides, and a grant that somehow committed something else
#     is refused AFTER the grant step, BEFORE seeding.
mkdir -p "$WORK/23/clients" "$WORK/23/peers"
cp "$WORK/21/clients/pve2.conf" "$WORK/23/clients/pve2.conf"
cp "$WORK/21/peers/$label.conf" "$WORK/23/peers/$label.conf"
out="$( (
    CLIENTS_DIR="$WORK/23/clients"
    PEER_STATE_DIR="$WORK/23/peers"
    rux_grant_remotely() { echo "GRANT $3" >> "$WORK/23/order"; }
    load_client_and_connection() { LOAD_HOST=pve2; }
    fetch_committed_scope() { printf '[dataset:rpool/OTHER]\ninclude_parent = yes\ninclude_children = yes\n' > "$1"; }
    cmd_seed()     { echo "SEED $*" >> "$WORK/23/order"; }
    cmd_activate() { echo "ACTIVATE $*" >> "$WORK/23/order"; }
    rux_entry --source=pve2:rpool/data --target=hdd/backup --grant-remotely --install --yes
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] \
        && printf '%s' "$out" | grep -q "not covered by the scope 'pve2' actually COMMITTED" \
        && [ "$(cat "$WORK/23/order")" = "GRANT rpool/data" ]; then
    ok "23. verification keeps its authority after a remote grant -- a mismatched commit still refuses before seed"
else
    bad "23. verification keeps its authority after a remote grant -- a mismatched commit still refuses before seed" \
        "rc=$rc out=$out order=$(cat "$WORK/23/order" 2>/dev/null)"
fi

# 24. rux_grant_remotely itself: a pre-existing draft selecting something
#     DIFFERENT refuses even under the flag -- force is not permission to
#     overwrite another operator's pending decision. Root-ssh is stubbed at
#     the rux_root_ssh seam; the probe order (channel, committed?, repo,
#     draft) is the real function's.
out="$( (
    COLLECTOR_LABEL=colhost
    rux_root_ssh() {   # <host> <port> <cmd...>
        shift 2
        case "$*" in
            true) return 0 ;;
            *"test -s"*) return 1 ;;                       # nothing committed yet
            *"test -x"*) return 0 ;;                       # deploy.sh found
            *"cat -- "*) printf '[dataset:rpool/SOMETHING_ELSE]\ninclude_parent = no\ninclude_children = yes\n'; return 0 ;;
            *) echo "UNEXPECTED rux_root_ssh: $*" >&2; return 9 ;;
        esac
    }
    rux_grant_remotely pve2 22 rpool/data
) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not permission to overwrite" ; then
    ok "24. --grant-remotely refuses to replace a differing pre-existing draft"
else
    bad "24. --grant-remotely refuses to replace a differing pre-existing draft" "rc=$rc out=$out"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
