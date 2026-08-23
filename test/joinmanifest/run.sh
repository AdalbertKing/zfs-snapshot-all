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
eval "$(sed -n '/^join_scope_enumerate() {/,/^}/p' "$DEPLOY_SRC")"
eval "$(sed -n '/^join_scope_summary() {/,/^}/p' "$DEPLOY_SRC")"
eval "$(sed -n '/^join_human_bytes() {/,/^}/p' "$DEPLOY_SRC")"
# join_scope_enumerate is absent from any deploy.sh older than REV #117 F2, and
# running THIS suite against such a copy is the documented way to show the F2
# cases failing on the reviewed base:
#
#     DEPLOY_SRC=/path/to/old/deploy.sh ./test/joinmanifest/run.sh
#
# So a missing extraction is fatal for the repo's own deploy.sh and merely
# noted for an overridden one -- otherwise the control aborts before reaching
# the cases it exists to demonstrate.
for fn in join_scope_is_committed guided_join_scope join_scope_summary join_human_bytes; do
    declare -F "$fn" >/dev/null && continue
    echo "FATAL: could not extract $fn from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
    exit 1
done
if ! declare -F join_scope_enumerate >/dev/null; then
    if [ "$DEPLOY_SRC" = "$REPO/deploy.sh" ]; then
        echo "FATAL: could not extract join_scope_enumerate from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
        exit 1
    fi
    echo "NOTE $DEPLOY_SRC predates join_scope_enumerate -- running the F2 cases against it as a control"
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
# EXITS, like the real one. A stub that merely returns turns every refusal in
# guided_join_scope into another turn of its `while :` loop, so a test for
# "this must refuse" hangs instead of failing -- which is how this line was
# found. Each case below runs the function in a command substitution, so the
# exit is contained to that subshell.
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }
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

# ---------------------------------------------------------------------------
# A CONTROLLABLE ZFS. The consent preview and the grant both measure the pool,
# and REV #117 F2 is entirely about what happens when that measurement fails or
# moves. None of it is reachable without being able to make `zfs` misbehave on
# demand, so the inventory, each read's exit status, and a drift point between
# the preview and the grant are all knobs here.
# ---------------------------------------------------------------------------
ZFS_LOG="$GUIDED/zfs.calls"; : > "$ZFS_LOG"
ZFS_LISTR_COUNT="$GUIDED/listr.count"; : > "$ZFS_LISTR_COUNT"
SCOPE_READ_RC=0; ZFS_LIST_RC=0; ZFS_LISTR_RC=0; ZFS_GET_RC=0
ZFS_GET_USED=1024
ZFS_INVENTORY=$'tank/data\ntank/data/a\ntank/data/b'
ZFS_INVENTORY_DRIFT="$ZFS_INVENTORY"
ZFS_DRIFT_AFTER=0          # 0 = the pool never moves
SCOPE_ROOTS=()
scope_read() { SCOPE_ROOTS=(tank/data); SCOPE_ERR="scope stub refused"; return "$SCOPE_READ_RC"; }
scope_includes() { return 0; }
zfs() {
    local sub="$1"; shift
    printf '%s %s\n' "$sub" "$*" >> "$ZFS_LOG"
    case "$sub" in
        list)
            local rec=0 a n
            for a in "$@"; do [ "$a" = "-r" ] && rec=1; done
            if [ "$rec" -eq 0 ]; then
                [ "$ZFS_LIST_RC" -eq 0 ] || return "$ZFS_LIST_RC"
                printf '%s\n' "${*: -1}"
                return 0
            fi
            [ "$ZFS_LISTR_RC" -eq 0 ] || return "$ZFS_LISTR_RC"
            n=$(( $(cat "$ZFS_LISTR_COUNT" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "$ZFS_LISTR_COUNT"
            if [ "$ZFS_DRIFT_AFTER" -gt 0 ] && [ "$n" -gt "$ZFS_DRIFT_AFTER" ]; then
                printf '%s\n' "$ZFS_INVENTORY_DRIFT"
            else
                printf '%s\n' "$ZFS_INVENTORY"
            fi
            ;;
        get)
            [ "$ZFS_GET_RC" -eq 0 ] || return "$ZFS_GET_RC"
            printf '%s\n' "$ZFS_GET_USED"
            ;;
        allow|unallow) return 0 ;;
    esac
    return 0
}
zfs_allow_count() { grep -c '^allow ' "$ZFS_LOG" 2>/dev/null || true; }
zfs_reset() { : > "$ZFS_LOG"; : > "$ZFS_LISTR_COUNT"; ZFS_DRIFT_AFTER=0
              SCOPE_READ_RC=0; ZFS_LIST_RC=0; ZFS_LISTR_RC=0; ZFS_GET_RC=0; }

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
out="$(guided_join_scope pve1 <<< '3' 2>&1)"; rc=$?
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
out="$(VISUAL="$EDITOR_STUB" guided_join_scope pve1 <<< $'e\n3' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$GUIDED_CALLS")" = $'edit\ncheck\ncommit' ] \
        && grep -qF '# edited' "$SCOPE" && join_scope_is_committed pve1; then
    ok "guided join: edit returns to preview/accept, validates, then commits"
else
    bad "guided join: edit returns to preview/accept, validates, then commits" "rc=$rc calls=$(cat "$GUIDED_CALLS") out=$out"
fi


# ---------------------------------------------------------------------------
# WHAT THE OPERATOR ACCEPTED MUST BE WHAT GETS GRANTED  (REV #117 F2)
#
# The hotfix asks the operator to type the dataset COUNT to accept a join. That
# only means anything if the number is (a) measured, not guessed after a failed
# read, and (b) binding on the grant that follows. Neither held: the preview
# turned a failed scope_read into a successful "0 0 0", skipped any root whose
# `zfs list` failed, and read a failed `zfs get used` as zero bytes -- every one
# of them shrinking the number in the direction that buys consent too cheaply.
# do_commit_scope then re-enumerated the pool on its own and granted whatever it
# found.
#
# These four cases drive the WHOLE verb -- guided_join_scope calling the REAL
# do_commit_scope -- and the assertion that matters is the same in all of them:
# how many times `zfs allow` ran. A refusal that still delegated is not a
# refusal, and no amount of correct log wording substitutes for that count.
# ---------------------------------------------------------------------------
eval "$(sed -n '/^do_commit_scope() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F do_commit_scope >/dev/null; then
    echo "FATAL: could not extract do_commit_scope from $DEPLOY_SRC" >&2
    exit 1
fi

COMMIT_MPATH="$GUIDED/manifest"
COMMIT_SCOPE_HOLD_TAG="zsa-inflight"
ALLOW_QUIESCE=0
PEER_JOIN_GRANTED_DATASETS=""
PEER_JOIN_ACCOUNT_UID=""
do_commit_scope_check() {
    COMMIT_SCOPE_MPATH="$COMMIT_MPATH"
    COMMIT_SCOPE_SFILE="$(peer_scope_path "$1")"
    COMMIT_SCOPE_ACCOUNT="zfsbackup-pve1"
    # The real one calls scope_read here, and do_commit_scope on any deploy.sh
    # older than REV #117 F2 depends on that side effect for SCOPE_ROOTS. A stub
    # that skipped it made the old code refuse for a reason of the stub's own
    # making -- a contaminated control, which reads exactly like a pass.
    scope_read "$COMMIT_SCOPE_SFILE" || return 1
    printf 'check\n' >> "$GUIDED_CALLS"
    return 0
}
commit_scope_dataset_held() { return 1; }
install_quiesce_grant() { :; }
id() { return 1; }   # no live delegated account exists in this root-free suite

join_case_reset() {
    zfs_reset
    rm -f "$SCOPE" "$HASH"
    : > "$GUIDED_CALLS"
    printf 'PEER_JOIN_GRANTED_DATASETS=""\n' > "$COMMIT_MPATH"
    PEER_JOIN_GRANTED_DATASETS=""
}

# 1. `t` -- the old accept token -- must no longer buy anything.
join_case_reset
out="$(guided_join_scope pve1 <<< 't' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(zfs_allow_count)" -eq 0 ]         && ! grep -q '^commit$' "$GUIDED_CALLS" && ! join_scope_is_committed pve1; then
    ok "consent: 't' no longer accepts -- no commit, no zfs allow"
else
    bad "consent: 't' no longer accepts -- no commit, no zfs allow"         "rc=$rc allow=$(zfs_allow_count) calls=$(cat "$GUIDED_CALLS")" "out=$out"
fi

# 2. The exact count DOES accept, and grants exactly those datasets.
join_case_reset
out="$(guided_join_scope pve1 <<< '3' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(zfs_allow_count)" -eq 3 ] && join_scope_is_committed pve1         && grep -q 'tank/data tank/data/a tank/data/b' "$COMMIT_MPATH"; then
    ok "consent: the exact count accepts and delegates exactly those 3 datasets"
else
    bad "consent: the exact count accepts and delegates exactly those 3 datasets"         "rc=$rc allow=$(zfs_allow_count) manifest=$(cat "$COMMIT_MPATH")" "out=$out"
fi

# 3. A measurement that failed must refuse, not present a smaller scope. One
#    case per read the preview makes -- each was its own fail-open.
for probe in scope_read zfs_list zfs_get; do
    join_case_reset
    case "$probe" in
        scope_read) SCOPE_READ_RC=1 ;;
        zfs_list)   ZFS_LIST_RC=1 ;;
        zfs_get)    ZFS_GET_RC=1 ;;
    esac
    # The scope file must exist, or do_draft_scope's stub would be the thing
    # under test rather than the measurement.
    printf '[dataset:tank/data]\ninclude_parent = no\ninclude_children = yes\n' > "$SCOPE"
    out="$(guided_join_scope pve1 <<< '3' 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$(zfs_allow_count)" -eq 0 ] && ! join_scope_is_committed pve1             && printf '%s' "$out" | grep -q 'refusing to ask for consent'; then
        ok "consent: a failed $probe refuses instead of showing a smaller scope"
    else
        bad "consent: a failed $probe refuses instead of showing a smaller scope"             "rc=$rc allow=$(zfs_allow_count)" "out=$out"
    fi
done
zfs_reset

# 4. Inventory drift between the question and the grant. Two shapes, because
#    checking only the count would miss the second: the pool can change
#    membership without changing size.
join_case_reset
ZFS_DRIFT_AFTER=2   # preview reads twice; the grant's read is the third
ZFS_INVENTORY_DRIFT=$'tank/data\ntank/data/a\ntank/data/b\ntank/data/c'
out="$(guided_join_scope pve1 <<< '3' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(zfs_allow_count)" -eq 0 ]         && printf '%s' "$out" | grep -q 'accepted 3 dataset'; then
    ok "consent: a dataset appearing after acceptance stops the grant"
else
    bad "consent: a dataset appearing after acceptance stops the grant"         "rc=$rc allow=$(zfs_allow_count)" "out=$out"
fi

join_case_reset
ZFS_DRIFT_AFTER=2
ZFS_INVENTORY_DRIFT=$'tank/data\ntank/data/a\ntank/data/c'
out="$(guided_join_scope pve1 <<< '3' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(zfs_allow_count)" -eq 0 ]         && printf '%s' "$out" | grep -q 'not the ones the operator accepted'; then
    ok "consent: a swapped dataset with the same count stops the grant"
else
    bad "consent: a swapped dataset with the same count stops the grant"         "rc=$rc allow=$(zfs_allow_count)" "out=$out"
fi
zfs_reset

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
