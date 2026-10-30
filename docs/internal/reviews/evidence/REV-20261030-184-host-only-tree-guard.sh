#!/bin/bash
# Exact-head negative control for REV-20261030-184. Uses the cron fixture stubs
# only; it does not contact a host or execute ZFS.
set -u

TARGET_REPO="${TARGET_REPO:-.}"
TARGET_SHA="${TARGET_SHA:-3e6ba19963a310b73590813654427178017a79c8}"

git -C "$TARGET_REPO" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null || {
    echo "ERROR: $TARGET_SHA is not a commit in $TARGET_REPO" >&2
    exit 2
}

work="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tree" || exit 2
git -C "$TARGET_REPO" archive "$TARGET_SHA" | tar -x -C "$work/tree" || exit 2

# Inject one assertion into the existing safe fixture harness, immediately
# after its account-qualified remote control and before PG22. This calls the
# real pg_tree helper and therefore the target's actual zfs-job.sh.
python3 - "$work/tree/test/cron/run.sh" "$TARGET_SHA" <<'PY' || exit 2
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
needle = 'check "PG22 a remote tree that cannot be listed: runs unchanged and WARNs"'
probe = r'''_rev184_wrapped="$(pg_tree snapget.sh -s -m p_ -R pveA:tank/data)"
_rev184_lists="$(grep -c -- 'ConnectTimeout=10 pveA zfs list -H -o name -r -- .tank/data.$' "$PG/ssh.log")"
printf 'sha=%s\nwrapped=%s\nremote_tree_lists=%s\n' \
       '__TARGET_SHA__' "$_rev184_wrapped" "$_rev184_lists"
if [ "$_rev184_lists" -ne 1 ] || ! printf '%s\n' "$_rev184_wrapped" | grep -q -- ' -X '; then
    echo 'FAIL: host-only remote tree bypassed the PVE guest guard'
    exit 97
fi
echo 'PASS: host-only remote tree was inspected and guarded'
'''.replace('__TARGET_SHA__', sys.argv[2] if len(sys.argv) > 2 else 'unknown')
if s.count(needle) != 1:
    raise SystemExit('ERROR: PG22 insertion anchor is not unique')
p.write_text(s.replace(needle, probe + needle, 1))
PY

set +e
(cd "$work/tree" && bash test/cron/run.sh)
rc=$?
set -e
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -eq 97 ] && exit 1
echo "ERROR: fixture harness exited $rc" >&2
exit 2
