#!/bin/bash
# Tests for deploy.sh --join's handling of the pairing package (wsad).
#
# Covers REV-20260729-001 F1: the package crosses a trust boundary by
# definition -- --join runs as root on a host that has no relationship with the
# sender yet -- and it used to be consumed with `. peer.conf`, which executes
# rather than reads. These cases build hostile packages and assert that each is
# refused BEFORE anything persistent happens.
#
# No root, no ZFS, no network: every case goes through `deploy.sh
# --join-check`, which validates a package and changes nothing. That is what
# makes this testable at all -- the validation lives inside --join, which
# demands root, and a test that has to run as root is a test where a mistake
# creates a real account on a real host.
#
#   ./test/join/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY="${DEPLOY:-$REPO/deploy.sh}"
[ -r "$DEPLOY" ] || { echo "cannot find deploy.sh at $DEPLOY" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

# The canary. If a package ever executes, this file appears -- and its absence
# is asserted after every single case, not just the injection ones.
CANARY="$WORK/PWNED"

ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# mkpkg <dir> -> builds <dir>/wsad.tgz from <dir>/peer.conf + <dir>/pubkey.pub
mkpkg() { tar -C "$1" -czf "$1/wsad.tgz" peer.conf pubkey.pub; }

good_conf() {
    cat <<EOF
# wsad parowania
PEER_CONF_ROLE=pull
PEER_CONF_DATASETS="tank/a tank/b"
PEER_CONF_TARGET=tank/backups
PEER_CONF_AS=delegated
PEER_CONF_ACCOUNT=zfsbackup-pve1
PEER_CONF_PORT=22
PEER_CONF_INITIATOR_LABEL=pve1
EOF
}
GOODKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhkVkBbh0x3swx+VYH6OxhCRGRSjQ3PcZ+3LGt5URPn pairing-test'

# case <name> <expected-substring-in-error> -- package is already at $D/wsad.tgz
expect_reject() {
    local name="$1" want="$2" out rc before after leaked
    before="$(tmp_names)"
    out="$(bash "$DEPLOY" --join-check="$D/wsad.tgz" 2>&1)"; rc=$?
    after="$(tmp_names)"
    leaked="$(comm -13 <(printf '%s
' "$before") <(printf '%s
' "$after") | tr '
' ' ')"
    leaked="${leaked% }"
    if [ "$rc" -eq 0 ]; then
        bad "$name" "expected rejection, got exit 0"; return
    fi
    if ! printf '%s' "$out" | grep -qF -- "$want"; then
        bad "$name" "wanted error containing: $want" "got: $(printf '%s' "$out" | tail -2)"; return
    fi
    if [ -e "$CANARY" ]; then
        bad "$name" "REJECTED BUT THE PACKAGE STILL EXECUTED -- canary $CANARY exists"
        rm -f "$CANARY"; return
    fi
    if printf '%s' "$out" | grep -q 'unbound variable'; then
        bad "$name" "rejected, but the cleanup trap itself failed: $(printf '%s' "$out" | grep 'unbound variable' | head -1)"
        return
    fi
    if [ -n "$leaked" ]; then
        bad "$name" "rejected, but left behind: $leaked"; return
    fi
    ok "$name"
}

# "Failure removes the temporary directory" is a claim, so it gets checked --
# per invocation, by exact name, in expect_reject above.
#
# Twice now this assertion has been weaker than it looked. First it did not
# exist at all, and the trap referenced a function-local variable the EXIT
# handler could not see, so every rejected package leaked while all 32
# assertions passed. Then it counted `find -newer "$WORK"` at the end of the
# run -- but each new_case creates a directory inside $WORK and moves its
# mtime, so a leak from an early case is older than the final marker and drops
# out of the count. It only caught the original bug because that one leaked in
# every case, including the last. Exact names taken immediately before and
# after each invocation answer the question directly and cannot drift.
tmp_names() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | sort; }

# Not `command -v python3`: on Windows that resolves to a Microsoft Store stub
# which is on PATH, exits non-zero and prints an ad. Ask for the module we need.
find_python() {
    local p
    for p in python3 python; do
        if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import tarfile' >/dev/null 2>&1; then
            printf '%s' "$p"; return 0
        fi
    done
    return 1
}
PY="$(find_python || true)"

new_case() { D="$WORK/$1"; mkdir -p "$D"; good_conf > "$D/peer.conf"; printf '%s\n' "$GOODKEY" > "$D/pubkey.pub"; }

# ---------------------------------------------------------------------------
# F1's headline: command execution through `source`
# ---------------------------------------------------------------------------
new_case inject-semicolon
{ good_conf; echo "PEER_CONF_EXTRA=x; touch $CANARY"; } > "$D/peer.conf"
mkpkg "$D"
expect_reject "inject/semicolon command" "unknown key"

new_case inject-substitution
{ good_conf | grep -v INITIATOR; printf 'PEER_CONF_INITIATOR_LABEL=$(touch %s)\n' "$CANARY"; } > "$D/peer.conf"
mkpkg "$D"
expect_reject "inject/command substitution" "backtick"

new_case inject-backtick
{ good_conf | grep -v TARGET; printf 'PEER_CONF_TARGET=`touch %s`\n' "$CANARY"; } > "$D/peer.conf"
mkpkg "$D"
expect_reject "inject/backtick" "backtick"

new_case inject-newline-in-value
{ good_conf | grep -v ACCOUNT; printf 'PEER_CONF_ACCOUNT="zfsbackup\nPEER_JOIN_EVIL=1"\n'; } > "$D/peer.conf"
mkpkg "$D"
expect_reject "inject/backslash in value" "backslash"

# ---------------------------------------------------------------------------
# Archive shape
# ---------------------------------------------------------------------------
new_case member-traversal
mkdir -p "$D/etc"; echo payload > "$D/etc/payload"
tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub --transform 's|^etc/payload|../../etc/cron.d/payload|' etc/payload 2>/dev/null \
  || tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub etc/payload
expect_reject "archive/path traversal or extra member" "exactly the two expected members"

new_case member-extra
echo extra > "$D/extra.sh"
tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub extra.sh
expect_reject "archive/extra member" "exactly the two expected members"

new_case member-absolute
tar -C "$D" -czf "$D/wsad.tgz" -P "$D/peer.conf" "$D/pubkey.pub" 2>/dev/null
expect_reject "archive/absolute paths" "exactly the two expected members"

new_case member-duplicate
tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub peer.conf
expect_reject "archive/duplicate member" "exactly the two expected members"

new_case member-symlink
# Skipped rather than silently passed where symlinks cannot be created (Git
# Bash on Windows without the privilege). An earlier version of this case let
# `ln -s` fail, tarred nothing, and still reported PASS -- a test that passes
# for the wrong reason is worse than one that is honestly absent.
rm -f "$D/peer.conf"
if ln -s /etc/passwd "$D/peer.conf" 2>/dev/null; then
    tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub
    expect_reject "archive/symlink member" "symlink"
else
    echo "SKIP archive/symlink member (this system will not create symlinks)"
fi

new_case member-missing
tar -C "$D" -czf "$D/wsad.tgz" peer.conf
expect_reject "archive/missing member" "exactly the two expected members"

# Entry TYPES. The name check above cannot see these -- both members are named
# correctly -- and a check on the unpacked RESULT is too late by construction:
# a FIFO or device node has already been created by root, and a hard link
# arrives as an ordinary regular file that nothing on disk can tell apart.
new_case member-hardlink
rm -f "$D/pubkey.pub"; ln "$D/peer.conf" "$D/pubkey.pub"
tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub
expect_reject "archive/hard-linked member" "hard link"

new_case member-fifo
rm -f "$D/peer.conf"
if mkfifo "$D/peer.conf" 2>/dev/null; then
    tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub
    expect_reject "archive/FIFO member" "FIFO"
else
    echo "SKIP archive/FIFO member (this system will not create FIFOs)"
fi

# tar names a directory member with a trailing slash, so the NAME check refuses
# it before the type check ever sees it. Asserting the message that actually
# fires, not the one the code could also have produced: the type check keeps the
# 'd' arm for a header crafted without that slash.
new_case member-directory
rm -f "$D/peer.conf"; mkdir -p "$D/peer.conf"
tar -C "$D" -czf "$D/wsad.tgz" peer.conf pubkey.pub
expect_reject "archive/directory member" "exactly the two expected members"

# A device node needs root to create on disk, but not to put in a tar header --
# python's tarfile writes the header directly, so the case runs unprivileged.
new_case member-device
if [ -n "$PY" ]; then
    "$PY" - "$D" <<'PYEOF'
import sys, tarfile, os
d = sys.argv[1]
with tarfile.open(os.path.join(d, "wsad.tgz"), "w:gz") as t:
    t.add(os.path.join(d, "peer.conf"), arcname="peer.conf")
    info = tarfile.TarInfo("pubkey.pub")
    info.type, info.devmajor, info.devminor, info.mode = tarfile.CHRTYPE, 1, 3, 0o666
    t.addfile(info)
PYEOF
    expect_reject "archive/device-node member" "device node"
else
    echo "SKIP archive/device-node member (no python to build the header)"
fi

# ---------------------------------------------------------------------------
# Size bounds: two correctly named members can still be a decompression bomb.
# ---------------------------------------------------------------------------
new_case member-oversize
if [ -n "$PY" ]; then
    "$PY" - "$D" <<'PYEOF'
import sys, tarfile, io, os
d = sys.argv[1]
with tarfile.open(os.path.join(d, "wsad.tgz"), "w:gz") as t:
    t.add(os.path.join(d, "pubkey.pub"), arcname="pubkey.pub")
    # Highly compressible, so the PACKAGE stays small and only the DECLARED
    # size gives it away -- which is the point: refuse before expanding.
    blob = b"A" * (4 * 1024 * 1024)
    info = tarfile.TarInfo("peer.conf"); info.size = len(blob)
    t.addfile(info, io.BytesIO(blob))
PYEOF
    expect_reject "archive/oversize member is refused before expanding" "over the"
else
    echo "SKIP archive/oversize member (no python to build the header)"
fi

# ---------------------------------------------------------------------------
# peer.conf schema
# ---------------------------------------------------------------------------
new_case key-unknown
{ good_conf; echo 'PEER_CONF_SOMETHING=1'; } > "$D/peer.conf"; mkpkg "$D"
expect_reject "schema/unknown key" "unknown key"

new_case key-duplicate
{ good_conf; echo 'PEER_CONF_ROLE=push'; } > "$D/peer.conf"; mkpkg "$D"
expect_reject "schema/duplicate key" "twice"

new_case key-missing
good_conf | grep -v PEER_CONF_TARGET > "$D/peer.conf"; mkpkg "$D"
expect_reject "schema/missing required key" "missing PEER_CONF_TARGET"

new_case value-not-assignment
{ good_conf; echo 'this is not an assignment'; } > "$D/peer.conf"; mkpkg "$D"
expect_reject "schema/not KEY=VALUE" "not a KEY=VALUE"

new_case role-invalid
good_conf | sed 's/^PEER_CONF_ROLE=.*/PEER_CONF_ROLE=sideways/' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid role" "must be 'pull' or 'push'"

new_case as-invalid
good_conf | sed 's/^PEER_CONF_AS=.*/PEER_CONF_AS=superuser/' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid as" "must be 'root' or 'delegated'"

new_case port-invalid
good_conf | sed 's/^PEER_CONF_PORT=.*/PEER_CONF_PORT=70000/' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid port" "1..65535"

new_case account-invalid
good_conf | sed 's|^PEER_CONF_ACCOUNT=.*|PEER_CONF_ACCOUNT=../../root|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid account" "not a valid account name"

new_case target-invalid
good_conf | sed 's|^PEER_CONF_TARGET=.*|PEER_CONF_TARGET=/absolute/path|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid target" "not a valid ZFS dataset name"

new_case dataset-invalid
good_conf | sed 's|^PEER_CONF_DATASETS=.*|PEER_CONF_DATASETS="tank/a ../etc"|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid dataset in list" "not a valid ZFS dataset name"

new_case label-invalid
good_conf | sed 's|^PEER_CONF_INITIATOR_LABEL=.*|PEER_CONF_INITIATOR_LABEL=../evil|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/invalid label" "not a valid label"

# A character allow-list is not a grammar. These pass every character test and
# are still wrong: 'zfs list -H -o name -o' reads the value as an OPTION, and
# dot segments are navigation rather than names.
new_case target-option-like
good_conf | sed 's|^PEER_CONF_TARGET=.*|PEER_CONF_TARGET=-o|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/option-like target" "not a valid ZFS dataset name"

new_case dataset-option-like
good_conf | sed 's|^PEER_CONF_DATASETS=.*|PEER_CONF_DATASETS="tank/a -o"|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/option-like dataset in list" "not a valid ZFS dataset name"

new_case target-leading-dot
good_conf | sed 's|^PEER_CONF_TARGET=.*|PEER_CONF_TARGET=.pool/x|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/leading-dot pool" "not a valid ZFS dataset name"

new_case target-dot-segment
good_conf | sed 's|^PEER_CONF_TARGET=.*|PEER_CONF_TARGET=tank/./child|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/dot segment in target" "not a valid ZFS dataset name"

new_case pull-no-datasets
good_conf | sed 's|^PEER_CONF_DATASETS=.*|PEER_CONF_DATASETS=""|' > "$D/peer.conf"; mkpkg "$D"
expect_reject "value/pull with no datasets" "nothing to delegate"

# ---------------------------------------------------------------------------
# pubkey.pub
# ---------------------------------------------------------------------------
new_case pubkey-two-keys
printf '%s\n%s\n' "$GOODKEY" "$GOODKEY" > "$D/pubkey.pub"; mkpkg "$D"
expect_reject "pubkey/two keys" "exactly one public key"

new_case pubkey-options-prefix
printf 'command="touch %s" %s\n' "$CANARY" "$GOODKEY" > "$D/pubkey.pub"; mkpkg "$D"
expect_reject "pubkey/authorized_keys options prefix" "options prefix"

new_case pubkey-garbage
printf 'not a key at all\n' > "$D/pubkey.pub"; mkpkg "$D"
expect_reject "pubkey/not a key" "does not start with a public key type"

# ---------------------------------------------------------------------------
# The positive case. Everything above proves things are refused; this proves a
# legitimate package is still accepted and read as the same values --pair put
# in it. Without it, "reject everything" would score 25/25.
# ---------------------------------------------------------------------------
new_case good
mkpkg "$D"
good_out="$(bash "$DEPLOY" --join-check="$D/wsad.tgz" 2>&1)"; good_rc=$?
if [ "$good_rc" -ne 0 ]; then
    bad "good/accepted" "a legitimate package was rejected" "$(printf '%s' "$good_out" | tail -2)"
else
    ok "good/accepted"
fi
check_val() {
    if printf '%s' "$good_out" | grep -qE "^ +$1 +$2\$"; then
        ok "good/$1 normalised"
    else
        bad "good/$1 normalised" "wanted '$1 = $2'" "$(printf '%s' "$good_out" | grep -- "$1" || echo '(absent)')"
    fi
}
check_val PEER_CONF_ROLE             pull
check_val PEER_CONF_AS               delegated
check_val PEER_CONF_ACCOUNT          zfsbackup-pve1
check_val PEER_CONF_TARGET           tank/backups
check_val PEER_CONF_PORT             22
check_val PEER_CONF_INITIATOR_LABEL  pve1
# The one value --pair writes wrapped in quotes: the parser must hand back the
# list, not the quotes.
check_val PEER_CONF_DATASETS         "tank/a tank/b"

# The accepted package must clean up too -- the success path has its own exit,
# and "it worked" is not a reason to leave a directory behind.
before="$(tmp_names)"
bash "$DEPLOY" --join-check="$D/wsad.tgz" >/dev/null 2>&1
after="$(tmp_names)"
leaked="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"
if [ -z "${leaked// /}" ]; then
    ok "good/leaves no temp directory either"
else
    bad "good/leaves no temp directory either" "left behind: $leaked"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
