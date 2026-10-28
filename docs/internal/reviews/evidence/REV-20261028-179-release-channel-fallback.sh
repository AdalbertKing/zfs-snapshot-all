#!/bin/bash
# Executable negative control for REV-20261028-179.
# Reads exact Git blobs only. It never installs, clones, contacts a host or edits
# the target repository. Override TARGET_REPO/TARGET_SHA to check the release
# repository; defaults address the development RELEASE-OF commit.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-901e8e4b7ba5a2871ef59e29e6356b9762f2bb2f}"
DEV_URL='https://github.com/AdalbertKing/zfs-snapshot-all.git'
RELEASE_URL='https://github.com/AdalbertKing/zfsbackup.git'

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

deploy_blob="$(git -C "$TARGET_REPO" show "$TARGET_SHA:deploy.sh")" || exit 2
backup_blob="$(git -C "$TARGET_REPO" show "$TARGET_SHA:zfs-backup.sh")" || exit 2

deploy_dev=$(printf '%s\n' "$deploy_blob" | grep -F -c "REPO_URL=\"$DEV_URL\"" || true)
prepare_dev=$(printf '%s\n' "$backup_blob" | grep -F -c "url=\"$DEV_URL\"" || true)
deploy_release=$(printf '%s\n' "$deploy_blob" | grep -F -c "REPO_URL=\"$RELEASE_URL\"" || true)
prepare_release=$(printf '%s\n' "$backup_blob" | grep -F -c "url=\"$RELEASE_URL\"" || true)

printf 'sha=%s deploy_dev=%s prepare_dev=%s deploy_release=%s prepare_release=%s\n' \
    "$TARGET_SHA" "$deploy_dev" "$prepare_dev" "$deploy_release" "$prepare_release"

if [ "$deploy_dev" -gt 0 ] || [ "$prepare_dev" -gt 0 ]; then
    echo 'FAIL: a no-origin install/prepare-source fallback crosses from the release channel to the development repository'
    exit 1
fi

echo 'PASS: no executable no-origin fallback selects the development repository'

