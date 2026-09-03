# test/harness.sh -- what a suite needs in order to run PRODUCT code outside
# the program that owns it. Sourced by suites (and by the throwaway harness
# scripts some suites generate), never executed; no shebang on purpose.
#
# Why this exists (2026-09-03). Twenty suite files lift functions or line
# ranges out of zfs-backup.sh, zfs-restore.sh and deploy.sh with sed/awk and
# eval them in a shell that never sourced the program. That is the right
# shape for testing one decision in isolation -- and it means every library
# the lifted code has come to depend on must be sourced by every such suite
# by hand. lib-record.sh taught that three times in one day: rerun and
# linkfields (`record_get: command not found`), then joinmanifest and
# draftscope (`record_load: command not found`), each found by a red suite
# after the product change was already written, each fixed with its own
# copy of the same line. The list of libraries product code depends on is a
# fact about the PRODUCT and belongs in one place, so the next library costs
# one line here instead of one red suite per harness.
#
# Contract:
#
#   product_libs [<tree>]   source, from <tree> (default: $REPO), the libraries
#                           lifted product code may call. A library the tree
#                           does not have is skipped: a negative control
#                           pointed at an older SHA predates it and its lifted
#                           code cannot call it either.
#   product_fn <file> <name>
#                           the source of shell function <name> in <file>, on
#                           stdout, or a FATAL naming the anchor -- the check
#                           thirteen suites each spelled out for themselves.
#
# Every suite keeps its own die/warn/log stubs and its own ok/bad: those are
# the suite's decisions about what a refusal looks like from the outside, and
# this file has no opinion on them. lib-record.sh's one refusal calls `die`,
# so a suite that uses product_libs must define die before calling it.

product_libs() {   # [<tree>]
    local tree="${1:-${REPO:?product_libs: set REPO or pass the product tree}}"
    # lib-pairing.sh (2026-09-03): PEER_STATE_DIR/PEER_KEY_DIR and the six
    # pairing-state path helpers both programs used to carry a copy of. A
    # tree older than that has them inside the program, where a lifted range
    # that needs them already includes them.
    if [ -r "$tree/lib-pairing.sh" ]; then
        # shellcheck disable=SC1090
        . "$tree/lib-pairing.sh"
    fi
    if [ -r "$tree/lib-record.sh" ]; then
        # shellcheck disable=SC1090
        . "$tree/lib-record.sh"
    elif [ -r "$tree/lib-backup-common.sh" ] && grep -q '^record_get()' "$tree/lib-backup-common.sh"; then
        # The two-commit window on main (f1b321f..b9287e0) where the reader
        # lived inside lib-backup-common.sh: a negative control aimed there
        # still has lifted code that calls record_get.
        # shellcheck disable=SC1090
        . "$tree/lib-backup-common.sh"
    fi
    return 0
}

product_fn() {   # <file> <name> -> the function's source
    local body
    body=$(sed -n "/^$2() {/,/^}/p" "$1")
    [ -n "$body" ] || { echo "FATAL: could not extract $2 from $1 -- the sed anchors no longer match, update this suite" >&2; exit 1; }
    printf '%s\n' "$body"
}
