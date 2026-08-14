#!/bin/bash
# Tests for deploy.sh's verify_join_manifest() -- the read-back check
# do_join() runs both on its manifest temp file (before it is trusted) and
# again on the final path (after the atomic rename), REV-20260804-038.
#
# F1 of that review: the live campaign's first mode-based --join hit an
# unbound-variable abort mid-heredoc (the missing PEER_CONF_MODE local, fixed
# separately in 0131c74) and left a ZERO-BYTE manifest on disk -- yet
# do_join() still printed "Join zakonczony" and only the exit code disagreed.
# A real account and trusted key existed with no durable relationship record.
# do_join()'s own render/write/chmod/rename sequence still needs root (the
# account/key mutations that precede it do), so it has no local test here, by
# the same established choice as every other do_join()/do_pair() real action
# (see test/join/run.sh's own header). verify_join_manifest() itself is pure
# read-back comparison against explicit arguments, extracted the same way
# remote_scope_stage() was for REV-20260804-037 F1 -- exactly the boundary
# that makes this piece testable without root at all.
#
#   ./test/joinmanifest/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
[ -r "$DEPLOY_SRC" ] || { echo "cannot read deploy.sh at $DEPLOY_SRC" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

eval "$(sed -n '/^verify_join_manifest() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F verify_join_manifest >/dev/null; then
    echo "FATAL: could not extract verify_join_manifest from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
    exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# A correctly rendered manifest, matching what do_join() itself writes.
GOOD="$TMPD/good.conf"
cat > "$GOOD" <<'EOF'
# peer pairing manifest (join side) -- managed by deploy.sh --join, do not edit by hand
PEER_JOIN_ROLE="pull"
PEER_JOIN_AS="delegated"
PEER_JOIN_MODE="backup"
PEER_JOIN_DATASETS=""
PEER_JOIN_TARGET="tank/backups"
PEER_JOIN_ACCOUNT="zfsbackup-pve1"
PEER_JOIN_FINGERPRINT="SHA256:abc123"
EOF

if verify_join_manifest "$GOOD" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    ok "a correctly rendered manifest verifies against the exact values it was rendered from"
else
    bad "a correctly rendered manifest verifies against the exact values it was rendered from" "expected success"
fi

# The remote-origin fields, when present.
REMOTE="$TMPD/remote.conf"
cat > "$REMOTE" <<'EOF'
PEER_JOIN_ROLE="pull"
PEER_JOIN_AS="delegated"
PEER_JOIN_MODE="sync"
PEER_JOIN_DATASETS=""
PEER_JOIN_TARGET=""
PEER_JOIN_ACCOUNT="zfsbackup-pve1"
PEER_JOIN_FINGERPRINT="SHA256:def456"
PEER_JOIN_REMOTE="yes"
PEER_JOIN_REMOTE_FROM="pve1"
PEER_JOIN_REMOTE_AT="2026-08-04 01:00:00"
PEER_JOIN_REMOTE_SESSION="root@pve2"
EOF
if verify_join_manifest "$REMOTE" pull delegated sync "" zfsbackup-pve1 SHA256:def456 yes; then
    ok "a remote-origin manifest verifies including PEER_JOIN_REMOTE=yes"
else
    bad "a remote-origin manifest verifies including PEER_JOIN_REMOTE=yes" "expected success"
fi

# ---------------------------------------------------------------------------
# The exact live incident: a manifest that renders empty (a set -u abort
# mid-heredoc left nothing on disk before do_join()'s own chmod ran). Every
# field reads back blank -- must be refused, not treated as "close enough".
# ---------------------------------------------------------------------------
EMPTY="$TMPD/empty.conf"
: > "$EMPTY"
if verify_join_manifest "$EMPTY" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    bad "an empty manifest (the live incident's own shape) is refused, not treated as valid" "verify_join_manifest returned success against a 0-byte file"
else
    ok "an empty manifest (the live incident's own shape) is refused, not treated as valid"
fi

# A single wrong field (fingerprint) -- must refuse. Proves the check
# compares EVERY field, not just presence/absence.
WRONGFP="$TMPD/wrongfp.conf"
cp "$GOOD" "$WRONGFP"
sed -i 's/SHA256:abc123/SHA256:WRONG/' "$WRONGFP"
if verify_join_manifest "$WRONGFP" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    bad "a manifest with one wrong field (fingerprint) is refused" "verify_join_manifest returned success despite a fingerprint mismatch"
else
    ok "a manifest with one wrong field (fingerprint) is refused"
fi

# A wrong account -- the identity field a hostile or stale package could
# most plausibly disagree with.
WRONGACCT="$TMPD/wrongacct.conf"
cp "$GOOD" "$WRONGACCT"
sed -i 's/zfsbackup-pve1/zfsbackup-someoneelse/' "$WRONGACCT"
if verify_join_manifest "$WRONGACCT" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    bad "a manifest naming the wrong account is refused" "verify_join_manifest returned success despite an account mismatch"
else
    ok "a manifest naming the wrong account is refused"
fi

# A file that does not exist at all.
if verify_join_manifest "$TMPD/does-not-exist.conf" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    bad "a missing manifest file is refused" "verify_join_manifest returned success against a nonexistent path"
else
    ok "a missing manifest file is refused"
fi

# A legacy-shaped manifest (no PEER_JOIN_REMOTE field at all, want_remote="")
# still verifies -- REMOTE_JOIN is optional, absence is the expected legacy
# shape, not a mismatch.
LEGACY="$TMPD/legacy.conf"
cp "$GOOD" "$LEGACY"
if verify_join_manifest "$LEGACY" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    ok "a legacy manifest with no PEER_JOIN_REMOTE field verifies when none was expected"
else
    bad "a legacy manifest with no PEER_JOIN_REMOTE field verifies when none was expected" "expected success"
fi

# ---------------------------------------------------------------------------
# REV-20260804-040: PEER_JOIN_ACCOUNT_UID, the durable principal binding
# --leave uses instead of ever scanning `zfs allow` for "the first unknown
# uid" (REV-20260804-039 F3's own first, wrong attempt at this -- caught by
# review before it shipped as accepted, not live, but the same class of bug).
# ---------------------------------------------------------------------------
WITHUID="$TMPD/withuid.conf"
cp "$GOOD" "$WITHUID"
printf 'PEER_JOIN_ACCOUNT_UID="1001"\n' >> "$WITHUID"
if verify_join_manifest "$WITHUID" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 "" 1001; then
    ok "a manifest with the recorded uid verifies when the expected uid matches"
else
    bad "a manifest with the recorded uid verifies when the expected uid matches" "expected success"
fi

if verify_join_manifest "$WITHUID" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 "" 9999; then
    bad "a manifest with a mismatched recorded uid is refused" "verify_join_manifest returned success despite a uid mismatch (1001 recorded, 9999 expected)"
else
    ok "a manifest with a mismatched recorded uid is refused"
fi

# A legacy manifest (no PEER_JOIN_ACCOUNT_UID field at all) still verifies
# when no uid is expected either -- absence is the expected legacy shape.
if verify_join_manifest "$GOOD" pull delegated backup tank/backups zfsbackup-pve1 SHA256:abc123 ""; then
    ok "a legacy manifest with no PEER_JOIN_ACCOUNT_UID field verifies when no uid was expected"
else
    bad "a legacy manifest with no PEER_JOIN_ACCOUNT_UID field verifies when no uid was expected" "expected success"
fi

# ---------------------------------------------------------------------------
# Simple join orchestration: a single --join owns draft -> preview/edit ->
# commit, while a byte-identical completed scope makes a rerun a no-op.
# Extract only the two orchestration helpers; account/key/ZFS mutations remain
# outside this root-free suite and are represented by the existing stubs.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^join_scope_is_committed() {/,/^}/p' "$DEPLOY_SRC")"
eval "$(sed -n '/^guided_join_scope() {/,/^}/p' "$DEPLOY_SRC")"
eval "$(sed -n '/^deploy_exit_cleanup() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F join_scope_is_committed >/dev/null || ! declare -F guided_join_scope >/dev/null; then
    echo "FATAL: could not extract guided join helpers from $DEPLOY_SRC" >&2
    exit 1
fi

out="$( (
    JOIN_WORKDIR="$TMPD/cleanup-work"; mkdir -p "$JOIN_WORKDIR"
    JOIN_RERUN_NEEDED=1
    JOIN_RERUN_COMMAND='./deploy.sh --join=/root/pve1-package.tgz'
    trap deploy_exit_cleanup EXIT
    false
) 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] \
        && [ "$(printf '%s\n' "$out" | grep -c '^PONOW DOKLADNIE:')" -eq 1 ] \
        && printf '%s' "$out" | grep -qF 'PONOW DOKLADNIE: ./deploy.sh --join=/root/pve1-package.tgz' \
        && [ ! -e "$TMPD/cleanup-work" ]; then
    ok "guided join: an interrupted run prints exactly one full rerun command and cleans its workdir"
else
    bad "guided join: an interrupted run prints exactly one full rerun command and cleans its workdir" "rc=$rc out=$out"
fi

GUIDED="$TMPD/guided"; mkdir -p "$GUIDED"
GUIDED_CALLS="$GUIDED/calls"; : > "$GUIDED_CALLS"
peer_scope_path() { echo "$GUIDED/$1.scope"; }
peer_scope_granted_hash_path() { echo "$GUIDED/$1.scope.sha256"; }
log() { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die() { printf 'FATAL %s\n' "$*" >&2; return 1; }
do_draft_scope() {
    printf '[dataset:tank/data]\ninclude_parent = no\ninclude_children = yes\n' > "$(peer_scope_path "$1")"
    printf 'draft\n' >> "$GUIDED_CALLS"
}
do_commit_scope_check() { printf 'check\n' >> "$GUIDED_CALLS"; return 0; }
do_commit_scope() {
    local s; s=$(peer_scope_path "$1")
    sha256sum -- "$s" | awk '{print $1}' > "$(peer_scope_granted_hash_path "$1")"
    printf 'commit\n' >> "$GUIDED_CALLS"
}

SCOPE="$(peer_scope_path pve1)"; HASH="$(peer_scope_granted_hash_path pve1)"
printf '[dataset:tank/data]\ninclude_parent = no\ninclude_children = yes\n' > "$SCOPE"
sha256sum -- "$SCOPE" | awk '{print $1}' > "$HASH"
: > "$GUIDED_CALLS"
out="$(guided_join_scope pve1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$GUIDED_CALLS" ] && printf '%s' "$out" | grep -q 'already committed'; then
    ok "guided join: a completed byte-identical scope makes package resubmission a no-op"
else
    bad "guided join: a completed byte-identical scope makes package resubmission a no-op" "rc=$rc calls=$(cat "$GUIDED_CALLS") out=$out"
fi

rm -f "$SCOPE" "$HASH"; : > "$GUIDED_CALLS"
out="$(guided_join_scope pve1 <<< 't' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$GUIDED_CALLS")" = $'draft\ncommit' ] \
        && join_scope_is_committed pve1; then
    ok "guided join: one acceptance drafts and commits the proposed source scope"
else
    bad "guided join: one acceptance drafts and commits the proposed source scope" "rc=$rc calls=$(cat "$GUIDED_CALLS") out=$out"
fi

rm -f "$HASH"; : > "$GUIDED_CALLS"
EDITOR_STUB="$GUIDED/editor.sh"
cat > "$EDITOR_STUB" <<'EOF'
#!/bin/bash
printf '# edited\n' >> "$1"
printf 'edit\n' >> "$GUIDED_CALLS"
EOF
chmod +x "$EDITOR_STUB"; export GUIDED_CALLS
out="$(VISUAL="$EDITOR_STUB" guided_join_scope pve1 <<< $'e\nt' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$GUIDED_CALLS")" = $'edit\ncheck\ncommit' ] \
        && grep -qF '# edited' "$SCOPE" && join_scope_is_committed pve1; then
    ok "guided join: edit returns to preview/accept, validates, then commits"
else
    bad "guided join: edit returns to preview/accept, validates, then commits" "rc=$rc calls=$(cat "$GUIDED_CALLS") out=$out"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
