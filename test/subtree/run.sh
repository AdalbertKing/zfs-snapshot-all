#!/bin/bash
# validate_subtree -- the check that proves a RECURSIVE transfer landed on every
# descendant, not just on the root.
#
# It exists because a live campaign measured `zfs recv` of a -R stream skipping
# a descendant whose local state could not accept the increment, landing
# everything else, and exiting 0. The run then reported success while one child
# had silently stopped being backed up.
#
# The first implementation of that check was itself fail-open in two ways, both
# found by review with executable discriminators, and both pinned here:
#
#   1. an inventory error (ssh/zfs) returned "all good" instead of refusing;
#   2. membership was a SUBSTRING test, so `pool/t/a@s3-extra` was accepted as
#      proof that `pool/t/a@s3` exists.
#
# The function is extracted and run against stubbed `zfs`/`ssh`, because the
# question is its logic, not whether this machine has ZFS.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${SUBTREE_REPO:-$(cd "$DIR/../.." && pwd)}"
. "$DIR/../harness.sh"   # product_fn -- from THIS checkout, whichever tree SUBTREE_REPO names

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

# Runs validate_subtree from ONE engine with stubs.
#   $1 engine file, $2 label, $3 expected rc, $4 source listing, $5 target
#   listing, $6 "src_fail"|"tgt_fail"|"" to make an inventory call fail
probe() {
    local engine="$1" label="$2" want_rc="$3" src_list="$4" tgt_list="$5" mode="${6:-}"
    local tmp; tmp=$(mktemp) || return 1
    {
        echo 'set -u'
        echo 'log() { :; }'
        echo 'dataset_excluded() { return 1; }'
        echo 'SSH_OPTS=()'
        printf 'SRC_LIST=%q\n' "$src_list"
        printf 'TGT_LIST=%q\n' "$tgt_list"
        printf 'MODE=%q\n' "$mode"
        # The engines ask for the SOURCE over ssh (pull) or locally (push), and
        # for the TARGET the other way round. Both stubs answer from the same
        # two variables and honour MODE, so one harness covers both directions.
        cat <<'STUB'
# Both stubs answer from the same two listings and decide by which dataset the
# call names, so ONE harness covers both directions: snapget asks ssh for the
# source and zfs for the target, snapsend does the opposite.
_answer() {
    case "$*" in
        *pool/src*) [ "$MODE" = src_fail ] && return 1; printf '%s
' "$SRC_LIST"; return 0 ;;
        *)          [ "$MODE" = tgt_fail ] && return 1; printf '%s
' "$TGT_LIST"; return 0 ;;
    esac
}
zfs() { _answer "$@"; }
ssh() { _answer "$@" || return 255; }
STUB
        # The function itself, lifted verbatim from the engine under test.
        product_fn "$REPO/$engine" validate_subtree
        echo 'validate_subtree pool/src pool/tgt s3 acct host; echo "rc=$?"'
    } > "$tmp"
    local out; out=$(bash "$tmp" 2>&1); rm -f "$tmp"
    local rc="${out##*rc=}"
    if [ "$rc" = "$want_rc" ]; then ok "$engine: $label"; else bad "$engine: $label" "wanted rc=$want_rc, got: $out"; fi
}

FULL_SRC='pool/src@s3
pool/src/a@s3
pool/src/b@s3'
FULL_TGT='pool/tgt@s3
pool/tgt/a@s3
pool/tgt/b@s3'
MISSING_TGT='pool/tgt@s3
pool/tgt/b@s3'
# The discriminator for substring membership: the child carries a snapshot whose
# name STARTS WITH the one being proven. Only an exact-line test refuses this.
PREFIX_TGT='pool/tgt@s3
pool/tgt/a@s3-extra
pool/tgt/b@s3'

for e in snapget.sh snapsend.sh; do
    probe "$e" "a complete subtree passes"                       0 "$FULL_SRC"    "$FULL_TGT"
    probe "$e" "a descendant that did not receive is refused"    1 "$FULL_SRC"    "$MISSING_TGT"
    probe "$e" "'@s3-extra' does not satisfy '@s3'"              1 "$FULL_SRC"    "$PREFIX_TGT"
    probe "$e" "a source inventory failure fails CLOSED"         1 "$FULL_SRC"    "$FULL_TGT"   src_fail
    probe "$e" "a target inventory failure fails CLOSED"         1 "$FULL_SRC"    "$FULL_TGT"   tgt_fail
done

echo "--------------------------------------------"
echo "subtree: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
