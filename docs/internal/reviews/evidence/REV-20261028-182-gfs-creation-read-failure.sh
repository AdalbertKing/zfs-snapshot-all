#!/bin/bash
# Exact-blob negative control for REV-20261028-182. Uses only a stub zfs.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-5f28bd0f0e0067926e2f33f905831285a86e4893}"

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

work="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" || exit 2
git -C "$TARGET_REPO" show "$TARGET_SHA:delsnaps.sh" > "$work/delsnaps.sh" || exit 2
chmod +x "$work/delsnaps.sh"

cat > "$work/bin/zfs" <<'STUB'
#!/bin/bash
case "$1" in
    list) printf '%s\n' 'tank/data@one'; exit 0 ;;
    get) exit 7 ;;
    holds) exit 1 ;;
    destroy) printf '%s\n' "$*" >> "$TRACE_FILE"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$work/bin/zfs"
: > "$work/destroy.log"

set +e
out="$(PATH="$work/bin:$PATH" TRACE_FILE="$work/destroy.log" \
    bash "$work/delsnaps.sh" -G 'tank/data' '' -H1 2>&1)"
rc=$?
set -e

destroy_count="$(wc -l < "$work/destroy.log" | tr -d ' ')"
printf 'sha=%s delsnaps_rc=%s destroy_count=%s\n' "$TARGET_SHA" "$rc" "$destroy_count"
[ -s "$work/destroy.log" ] && sed 's/^/destroy_call=/' "$work/destroy.log"

if [ "$rc" -eq 0 ] || [ "$destroy_count" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    echo 'FAIL: unreadable GFS creation metadata did not fail closed before destroy'
    exit 1
fi

echo 'PASS: unreadable GFS creation metadata returns nonzero and performs no destroy'
