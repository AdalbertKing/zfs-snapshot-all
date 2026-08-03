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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
