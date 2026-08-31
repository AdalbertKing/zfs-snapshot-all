#!/bin/bash
# `restore_remote_ahead`: does the target differ from the recovery point?
#
#   ./test/restore/ahead.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/ahead.sh   # negative control
#
# Sourced by test/restore/run.sh. `ssh` is stubbed to run the payload locally
# against a stubbed `zfs`, so the cases exercise the real script text -- the
# defect was in what the payload asked, not in how it was called.
#
# THE ANSWER DECIDES WHETHER A ROLLBACK RUNS. Said "no" wrongly and the target
# never goes back in time, while the engine reports success over it.
#
# FOUND ON THE LAB, 2026-08-31, during an `--at` run to a historical point. An
# idle dataset carried two hourly snapshots on top of the recovery point and
# `written@point` = 0. It classified as `increment`, no rollback ran, and only
# the final verification caught that the recovery had done nothing at all.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _ah_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_ah_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _ah_standalone=1
fi

AH="$WORK/ahead"; mkdir -p "$AH/bin"

# $AH/written  "<dataset> <bytes|-|empty>"
# $AH/snaps    "<dataset>@<snap> <creation>"   -- the point included
cat > "$AH/bin/zfs" <<'ZSTUB'
#!/bin/bash
case "$*" in
    "get -Hp -o value written@"*)
        d="${!#}"
        v="$(awk -v d="$d" '$1==d{print $2; exit}' "$AH/written" 2>/dev/null)"
        printf '%s\n' "$v"
        exit 0 ;;
    "get -Hp -o value creation "*)
        s="${!#}"
        awk -v s="$s" '$1==s{print $2; exit}' "$AH/snaps" 2>/dev/null
        exit 0 ;;
    *"-t snapshot"*)
        d="${!#}"
        grep -E "^${d}@" "$AH/snaps" 2>/dev/null | awk '{print $2}' | sort -n
        exit 0 ;;
    "list -H -o name"*)
        printf 'rpool/data\n'
        exit 0 ;;
esac
exit 0
ZSTUB
chmod +x "$AH/bin/zfs"

ah_run() {
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'export AH=%q\n' "$AH"
        printf 'export PATH=%q:$PATH\n' "$AH/bin"
        echo 'SSH_OPTS=()'
        echo 'ssh() { local s="${!#}"; bash -c "$s"; }'
        awk -v want="restore_remote_ahead() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        echo 'restore_remote_ahead acct@host rpool/data p ""'
    } > "$t"
    bash "$t" 2>&1
    rm -f "$t"
}

# ---- bytes written since the point: reported, as it always was --------------
# The case the previous version existed for. Files deleted from a live
# filesystem with no snapshot taken since: nothing is newer, so nothing is
# "ahead", and only `written` sees it.
printf 'rpool/data 4096\n' > "$AH/written"
printf 'rpool/data@p 100\n'  > "$AH/snaps"
out="$(ah_run)"
case "$out" in
    *rpool/data*) ok "ahead: bytes written since the point are reported" ;;
    *) bad "ahead: bytes written since the point are reported" "got: '$out'" ;;
esac

# ---- THE CARRYING ASSERTION -------------------------------------------------
# Zero bytes written, but a snapshot sits on top. An idle dataset under an
# hourly schedule is exactly this, which is most of an estate most of the time.
# Missing it means no rollback runs and the target never goes back in time.
printf 'rpool/data 0\n' > "$AH/written"
printf 'rpool/data@p 100\nrpool/data@nowszy 200\n' > "$AH/snaps"
out="$(ah_run)"
case "$out" in
    *rpool/data*) ok "ahead: A SNAPSHOT NEWER THAN THE POINT COUNTS EVEN WHEN NOTHING WAS WRITTEN" ;;
    *) bad "ahead: A SNAPSHOT NEWER THAN THE POINT COUNTS EVEN WHEN NOTHING WAS WRITTEN" "got: '$out' -- no rollback would run and the recovery would do nothing" ;;
esac

# ---- genuinely at the point: silent -----------------------------------------
printf 'rpool/data 0\n' > "$AH/written"
printf 'rpool/data@p 100\n' > "$AH/snaps"
out="$(ah_run)"
if [ -z "$out" ]; then ok "ahead: a target at the point with nothing on top says nothing"
else bad "ahead: a target at the point with nothing on top says nothing" "got: '$out'"; fi

# ---- an OLDER snapshot is not newer -----------------------------------------
# Guards the comparison's direction: `>` and not `!=`.
printf 'rpool/data 0\n' > "$AH/written"
printf 'rpool/data@starszy 50\nrpool/data@p 100\n' > "$AH/snaps"
out="$(ah_run)"
if [ -z "$out" ]; then ok "ahead: a snapshot OLDER than the point is not 'newer'"
else bad "ahead: a snapshot OLDER than the point is not 'newer'" "got: '$out'"; fi

# ---- the point is not there at all ------------------------------------------
# Nothing to compare against. Saying "differs" here would send a rollback at a
# point the target does not have.
printf 'rpool/data -\n' > "$AH/written"
printf 'rpool/data@inny 100\n' > "$AH/snaps"
out="$(ah_run)"
if [ -z "$out" ]; then ok "ahead: with no such snapshot there is nothing to differ from"
else bad "ahead: with no such snapshot there is nothing to differ from" "got: '$out'"; fi

if [ "${_ah_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
