#!/bin/bash
# Executable negative control for REV-20261028-180.
# Reads one exact Git blob and executes only restore_live_guard with shell
# stubs. It never invokes ZFS, qm, pct, a restore engine, SSH or a host.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-901e8e4b7ba5a2871ef59e29e6356b9762f2bb2f}"

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

blob="$(git -C "$TARGET_REPO" show "$TARGET_SHA:zfs-restore.sh")" || exit 2
guard="$(printf '%s\n' "$blob" | sed -n '/^restore_live_guard() {/,/^}/p')"
[ -n "$guard" ] || { echo 'ERROR: restore_live_guard not found' >&2; exit 2; }

# Give the extracted function exactly the one external reader it needs to parse
# the two-line zfs stub response. In particular this PATH contains neither qm
# nor pct even when the reproducer itself runs on a Proxmox host.
stub_path="$(mktemp -d)" || exit 2
trap 'rm -rf "$stub_path"' EXIT
ln -s "$(command -v sed)" "$stub_path/sed" || exit 2

run_case() { # <qm|pct> <missing|error>
    local kind="$1" outcome="$2" dataset
    case "$kind" in
        qm)  dataset='rpool/data/vm-106-disk-0' ;;
        pct) dataset='rpool/data/subvol-107-disk-0' ;;
        *) return 2 ;;
    esac
    KIND="$kind" OUTCOME="$outcome" DATASET="$dataset" PATH="$stub_path" \
        /bin/bash -c "$guard
log() { :; }
zfs() {
    [ \"\$1\" = get ] || { echo \"MUTATION: zfs \$*\" >&2; return 99; }
    printf '%s\\n%s\\n' '-' '-'
}
if [ \"\$OUTCOME\" = error ]; then
    if [ \"\$KIND\" = qm ]; then qm() { return 255; }; else pct() { return 255; }; fi
fi
RESTORE_ONE_VERDICT=''
restore_live_guard \"\$DATASET\" rewind
rc=\$?
printf '%s-%s rc=%s verdict=<%s>\\n' \"\$KIND\" \"\$OUTCOME\" \"\$rc\" \"\$RESTORE_ONE_VERDICT\"
[ \"\$rc\" -ne 0 ] && [ -n \"\$RESTORE_ONE_VERDICT\" ]"
}

failed=0
for kind in qm pct; do
    for outcome in missing error; do
        run_case "$kind" "$outcome" || failed=1
    done
done

if [ "$failed" -ne 0 ]; then
    echo 'FAIL: an unavailable local Proxmox guest-state probe is accepted as safe'
    exit 1
fi

echo 'PASS: unavailable local Proxmox guest-state probes fail closed'
