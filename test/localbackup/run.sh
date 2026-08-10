#!/bin/bash
# Tests for zfs-backup.sh `local-backup` -- the Phase 5 slice-1 high-level LOCAL
# backup PLANNING command. Pure/text: no ZFS, no network, no crontab. The command
# validates source/target, picks a preset, renders a candidate CONFIG v4 through
# the real gen-cron.sh, and STOPS before install -- so everything it does is
# checkable here.
#
#   ./test/localbackup/run.sh
#
# What is pinned:
#   * overlap refuses in every direction (target under source, source under
#     target, equal) -- a backup may not land inside its own source;
#   * remote (':') source/target refused -- this verb is LOCAL only;
#   * missing --source/--target, and an unknown --profile, refuse;
#   * a valid plan renders the candidate CONFIG + cron through the REAL
#     gen-cron.sh, carrying the default profile's namespaced templates and a
#     local dst= send (no ':');
#   * same-pool prints one factual note; a cross-pool plan does not;
#   * planning installs NOTHING -- a crontab stub on PATH is never called.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-backup.sh at $ZB" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# A crontab stub that records any call: planning must never reach it.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/crontab" <<EOF
#!/bin/sh
echo "crontab called: \$*" >> "$WORK/crontab-calls"
exit 0
EOF
chmod +x "$WORK/bin/crontab"

# shellcheck disable=SC1090
source "$ZB"

# run_lb <args...> -> output; SERVER_CONF points nowhere, PROFILE_ROOT is the real
# built-in profiles dir, crontab is stubbed on PATH.
run_lb() {
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
      cmd_local_backup "$@" ) 2>&1
}

# ---- overlap refuses, all three directions ----
for pair in "rpool/data|rpool/data/backups|target-under-source" \
            "rpool/data/sub|rpool/data|source-under-target" \
            "rpool/data|rpool/data|equal"; do
    IFS='|' read -r s t label <<<"$pair"
    out="$(run_lb --source="$s" --target="$t")"; rc=$?
    if [ "$rc" -ne 0 ] && case "$out" in *overlap*) true ;; *) false ;; esac; then
        ok "overlap/$label refuses"
    else
        bad "overlap/$label refuses" "rc=$rc out=$(printf '%s' "$out" | tail -1)"
    fi
done

# ---- remote (':') is refused: this verb is local only. A bare host:path reaches
# the LOCAL-only guard; a user@host:path is caught earlier by the character check
# (the '@'), so both forms of a remote address are refused, with the ':' form
# getting the guard's clearer message. ----
out="$(run_lb --source="remotehost:rpool/data" --target=hdd/backups)"; rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"LOCAL only"*) true ;; *) false ;; esac; then
    ok "remote/host-colon-path refused by the LOCAL-only guard"
else
    bad "remote/host-colon-path refused by the LOCAL-only guard" "rc=$rc out=$(printf '%s' "$out" | tail -1)"
fi
out="$(run_lb --source="user@host:rpool/data" --target=hdd/backups)"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "remote/user-at-host refused (character check)" \
    || bad "remote/user-at-host refused (character check)" "exit 0 for a user@host source"

# ---- missing arguments refuse ----
out="$(run_lb --target=hdd/backups)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--source'; } \
    && ok "args/missing-source refuses" || bad "args/missing-source refuses" "rc=$rc"
out="$(run_lb --source=rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--target'; } \
    && ok "args/missing-target refuses" || bad "args/missing-target refuses" "rc=$rc"

# ---- unknown profile refuses (via load_active_profile -> profile_validate_dir) ----
out="$(run_lb --source=rpool/data --target=hdd/backups --profile=does-not-exist)"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "profile/unknown refuses" \
    || bad "profile/unknown refuses" "exit 0 for a missing profile; out=$(printf '%s' "$out" | tail -1)"

# ---- a valid cross-pool plan renders the candidate + cron and installs nothing --
out="$(run_lb --source=rpool/data --target=hdd/backups)"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q 'dst          = hdd/backups' \
        && printf '%s\n' "$out" | grep -q 'use_template = profile__default__standard_hourly' \
        && printf '%s\n' "$out" | grep -q '^\[prune:hdd/backups\]'; then
    ok "plan/candidate-config carries the local dataset, dst, default profile and GFS prune"
else
    bad "plan/candidate-config carries the local dataset, dst, default profile and GFS prune" \
        "rc=$rc out=$(printf '%s' "$out" | grep -E '\[dataset|\[prune|dst|use_template' | head)"
fi
# the RENDERED cron must carry a real local snapsend send (dst, no ':') via the
# real gen-cron.sh -- rendered into a variable first (this suite runs pipefail).
if printf '%s\n' "$out" | grep -qE 'snapsend\.sh -m "automated_hourly_" "rpool/data" "hdd/backups"'; then
    ok "plan/rendered-cron has a local snapsend send (dst, no colon)"
else
    bad "plan/rendered-cron has a local snapsend send (dst, no colon)" \
        "$(printf '%s\n' "$out" | grep -E 'snapsend|snapget' | head -1)"
fi
# cross-pool: no same-pool note
if printf '%s\n' "$out" | grep -q 'dziela pule'; then
    bad "plan/cross-pool has no same-pool note" "note printed for different pools"
else
    ok "plan/cross-pool has no same-pool note"
fi

# ---- same-pool prints exactly one factual note, still plans ----
out="$(run_lb --source=rpool/data --target=rpool/backups)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'dziela pule')" -eq 1 ]; then
    ok "plan/same-pool prints one factual note and still plans"
else
    bad "plan/same-pool prints one factual note and still plans" \
        "rc=$rc notes=$(printf '%s\n' "$out" | grep -c 'dziela pule')"
fi

# ---- planning installed NOTHING: the crontab stub was never called ----
if [ ! -e "$WORK/crontab-calls" ]; then
    ok "plan/installs-nothing (crontab never invoked across every plan above)"
else
    bad "plan/installs-nothing (crontab never invoked across every plan above)" \
        "crontab calls: $(cat "$WORK/crontab-calls")"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
