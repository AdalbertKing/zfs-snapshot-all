#!/bin/bash
# The relationship shapes the 2026-10-17 lab campaign found the restore surface
# getting wrong: a LOCAL relation restored beside itself, and a PUSH relation
# whose copy is on the other machine.
#
#   ./test/restore/localdest.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/localdest.sh    # negative control
#
# Sourced by test/restore/run.sh; separate file for the same reason as onto.sh --
# a control runs these against a mutated tree in seconds.
#
# Measured on the lab first (pve9b, pve9, main 963d7baf):
#   * the window's "obok" for a local relation composes
#     `restore L L --source=<copy> --onto=<path>` and died with "the destination
#     relationship 'L' is not one this host records";
#   * a config line `dst = acct@host:base` (push) was planned as "local push"
#     with the copy reported as BRAK, and a run went as far as the pause.
# (The same campaign saw a pre-flight refusal exit 2 over "nothing was changed".
# That status is pinned by relpolicy.sh D1 and REV-127 kept it; it is a question
# for the reviewer, not something this file changes.)

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _ld_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_ld_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    . "$_ld_dir/../harness.sh"   # product_fn
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _ld_standalone=1
fi

# ---- restore_scope_dest with a LOCAL destination relation -------------------
# restore_resolve_try is the config reader; stubbed to the rows a local relation
# (sources are paths) and a remote one (sources are acct@host:path) produce.
ld_dest() {   # <from label> <onto label> -> prints DEST entries, or DIE: <message>
    (
        log() { :; }
        die() { printf 'DIE: %s\n' "$*"; exit 1; }
        restore_resolve_try() {
            case "$2" in
                loc)  printf 'hdd/test-kreator\thdd/backups/hdd/test-kreator\n' ;;
                loc2) printf 'hdd/ct\thdd/backups/hdd/ct\n' ;;
                rem)  printf 'acct@10.0.0.9:hdd/home\thdd/backups/10.0.0.9/hdd/home\n' ;;
                *)    return 1 ;;
            esac
        }
        eval "$(product_fn "$ZB" restore_dest_peer)"
        eval "$(product_fn "$ZB" restore_scope_dest)"
        RESTORE_DEST_PEER=""
        case "$1" in
            rem) RESTORE_SCOPE_SRC=("acct@10.0.0.9:hdd/home")
                 RESTORE_ONTO_FROM=("acct@10.0.0.9:hdd/home"); RESTORE_ONTO_TO=("hdd/restore/home") ;;
            *)   RESTORE_SCOPE_SRC=("hdd/test-kreator")
                 RESTORE_ONTO_FROM=("hdd/test-kreator"); RESTORE_ONTO_TO=("hdd/restore/test-kreator") ;;
        esac
        restore_scope_dest cfg "$1" "$2"
        printf '%s\n' "${RESTORE_SCOPE_DEST[@]}"
    )
}

out="$(ld_dest loc loc)"
if [ "$out" = "hdd/restore/test-kreator" ]; then
    ok "local dest: 'restore L L --onto' lands on a LOCAL path (the window's obok)"
else
    bad "local dest: 'restore L L --onto' lands on a LOCAL path (the window's obok)" "got: $out"
fi
out="$(ld_dest loc loc2)"
case "$out" in
    *"DIE:"*"is LOCAL to this host"*) ok "local dest: another relation's copy onto a local relation is refused, and says why" ;;
    *) bad "local dest: another relation's copy onto a local relation is refused, and says why" "got: $out" ;;
esac
out="$(ld_dest loc nosuch)"
case "$out" in
    *"DIE:"*"not one this host records"*) ok "local dest: an unknown destination keeps its old refusal" ;;
    *) bad "local dest: an unknown destination keeps its old refusal" "got: $out" ;;
esac
# POSITIVE CONTROL: the remote shape is unchanged -- account@host stays on it.
out="$(ld_dest rem rem)"
if [ "$out" = "acct@10.0.0.9:hdd/restore/home" ]; then
    ok "local dest control: a remote destination keeps its account@host"
else
    bad "local dest control: a remote destination keeps its account@host" "got: $out"
fi

# ---- the hand-over report for a local restore beside itself ------------------
ld_handover() {   # <src> <dest>
    (
        log() { shift; printf '%s\n' "$*"; }
        RESTORE_SOURCE_LABEL=L; RESTORE_RELATION_LABEL=L
        RESTORE_SCOPE_SRC=("$1"); RESTORE_SCOPE_DEST=("$2"); RESTORE_LANDED=("$2")
        eval "$(product_fn "$ZB" restore_report_handover)"
        restore_report_handover
    )
}
out="$(ld_handover hdd/test-kreator hdd/restore/test-kreator-v5)"
if [ -z "$out" ]; then ok "local beside: no 'DIFFERENT machine', no move-to-client L L"
else bad "local beside: no 'DIFFERENT machine', no move-to-client L L" "got: $(printf '%s' "$out" | head -2)"; fi
# The control: a local source landed on a remote machine IS a hand-over.
out="$(ld_handover hdd/test-kreator root@pve1:rpool/elsewhere)"
case "$out" in
    *"DIFFERENT machine"*) ok "local beside control: local -> remote machine still reports the hand-over" ;;
    *) bad "local beside control: local -> remote machine still reports the hand-over" "got: $out" ;;
esac

# ---- PUSH: the copy is on the other machine ----------------------------------
LDC="$WORK/ld-push.conf"
cat > "$LDC" <<'EOF'
[defaults]
[dataset:hdd/home]
	dst          = acct@10.0.0.7:hdd/backups/10.0.0.8
	pair_label   = pushtest
[dataset:hdd/ct]
	dst          = hdd/backups
	pair_label   = loc
EOF
out="$(
    eval "$(product_fn "$(dirname "$ZB")/lib-backup-common.sh" installed_dataset_field)"
    eval "$(product_fn "$ZB" restore_relations)"
    restore_relations "$LDC"
)"
case "$out" in
    *"remote push -> acct@10.0.0.7:hdd/backups/10.0.0.8"*) ok "push: a dst with account@host is planned as REMOTE push" ;;
    *) bad "push: a dst with account@host is planned as REMOTE push" "got: $out" ;;
esac
case "$out" in
    *"local push -> hdd/backups"*) ok "push control: a local dst is still local push" ;;
    *) bad "push control: a local dst is still local push" "got: $out" ;;
esac

ld_run() {   # <copy> -> runner output, then "rc=N" and "paused=yes|no"
    (
        log() { shift; printf '%s\n' "$*"; }
        restore_one() { :; }
        restore_pause_take()    { : > "$WORK/ld-paused"; return 0; }
        restore_pause_release() { :; }
        restore_one_isolated()  { RESTORE_ONE_VERDICT="stub: no grant"; return 1; }
        rm -f "$WORK/ld-paused"
        eval "$(product_fn "$ZB" restore_run_scope)"
        RESTORE_SCOPE_SRC=("hdd/home"); RESTORE_SCOPE_COPY=("$1"); RESTORE_SCOPE_DEST=()
        restore_run_scope; echo "rc=$?"
        [ -e "$WORK/ld-paused" ] && echo paused=yes || echo paused=no
    )
}
out="$(ld_run acct@10.0.0.7:hdd/backups/10.0.0.8/hdd/home)"
case "$out" in
    *"backed up by PUSH"*"rc=1"*"paused=no"*) ok "push: a run refuses BEFORE the pause, and names --from-copy on the copy's host" ;;
    *) bad "push: a run refuses BEFORE the pause, and names --from-copy on the copy's host" "got: $out" ;;
esac

if [ "${_ld_standalone:-0}" = 1 ]; then
    echo "localdest: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
fi
