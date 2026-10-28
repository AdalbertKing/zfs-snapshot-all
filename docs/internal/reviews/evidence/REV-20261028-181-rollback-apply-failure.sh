#!/bin/bash
# Executable negative control for REV-20261028-181.
# Runs the exact update-control blob against an isolated temporary Git fixture.
# No production checkout, host, crontab or installed script is touched.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-edba2b7917cae40778908f96f8f28c3e430a2a93}"

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

work="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$work"' EXIT
repo="$work/checkout"
state="$work/state"
mkdir -p "$repo" "$state" || exit 2
chmod 700 "$state" || exit 2

git -C "$repo" init -q || exit 2
git -C "$repo" config user.name reviewer-fixture
git -C "$repo" config user.email reviewer-fixture@example.invalid

printf '#!/bin/bash\nexit "${STUB_DEPLOY_RC:-0}"\n' > "$repo/deploy.sh"
chmod +x "$repo/deploy.sh"
printf 'old\n' > "$repo/version"
git -C "$repo" add deploy.sh version
git -C "$repo" commit -qm old
old="$(git -C "$repo" rev-parse HEAD)"

printf 'new\n' > "$repo/version"
git -C "$repo" add version
git -C "$repo" commit -qm new
new="$(git -C "$repo" rev-parse HEAD)"

printf '%s\n' "$old" > "$state/previous-revision"
git -C "$TARGET_REPO" show "$TARGET_SHA:update-control.sh" > "$state/update-control.sh" || exit 2
chmod +x "$state/update-control.sh"

set +e
out="$(REPO_DIR="$repo" UPDATE_STATE_DIR="$state" STUB_DEPLOY_RC=7 \
    bash "$state/update-control.sh" --rollback 2>&1)"
rc=$?
set -e

head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
hold=0; [ -f "$state/update-hold" ] && hold=1
mixed=0; printf '%s\n' "$out" | grep -q 'host is a mixture' && mixed=1
printf 'sha=%s rollback_rc=%s head=%s target=%s before=%s hold=%s mixed_warning=%s\n' \
    "$TARGET_SHA" "$rc" "$head" "$old" "$new" "$hold" "$mixed"

if [ "$head" != "$old" ] || [ "$hold" -ne 1 ] || [ "$mixed" -ne 1 ]; then
    echo 'ERROR: fixture did not reach the intended post-reset/apply-failure state' >&2
    printf '%s\n' "$out" >&2
    exit 2
fi

if [ "$rc" -eq 0 ]; then
    echo 'FAIL: rollback reports success although re-deployment failed and the host is a version mixture'
    exit 1
fi

echo 'PASS: rollback apply failure is reported as failure while the update hold remains'
