#!/bin/bash
# Tests for `zfs-backup.sh restore --plan` -- Phase 7 slice 1, the READ-ONLY
# restore planner.
#
#   ./test/restore/run.sh
#
# Pure/text: a stubbed `zfs` on PATH, no real ZFS, no network, no crontab. The
# stub also records every invocation, so "this command only reads" is asserted
# rather than asserted-in-a-comment.
#
# The pair that carries the whole slice is the creation-vs-name pair. The planner
# exists because nobody can currently say what would be restored, and a planner
# that reported the timestamp embedded in the snapshot NAME would answer that
# question with a story instead of a fact. So one fixture has a snapshot whose
# name disagrees with its ZFS `creation`, and one has a snapshot where they agree;
# an implementation that read the name passes neither, and an implementation that
# warned unconditionally passes the first and fails the second.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-backup.sh at $ZB" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

mkdir -p "$WORK/bin"
# zfs stub. Records every call; answers snapshot listings from $WORK/snaps.<key>.
# Deliberately answers ONLY `list` -- any other subcommand is recorded and fails,
# so a write would be both visible and fatal.
cat > "$WORK/bin/zfs" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/zfs-calls"
case " \$1 " in
  " list ") ;;
  *) echo "stub: refusing non-list zfs call: \$*" >&2; exit 9 ;;
esac
# REV-20260812-113 F1: the stub now REQUIRES the explicit depth selector. The
# permissive version answered any listing shape, which is what let an unproven
# selector reach a live host in the first place. Drop \`-d 1\` from the planner and
# every snapshot assertion below goes red instead of silently passing.
case " \$* " in
  *" -t snapshot "*)
      case " \$* " in
        *" -d 1 "*) ;;
        *) echo "stub: snapshot listing without an explicit depth selector: \$*" >&2; exit 1 ;;
      esac ;;
esac
for a in "\$@"; do ds="\$a"; done
key=\$(printf '%s' "\$ds" | tr '/' '_')
if [ -f "$WORK/snaps.\$key" ]; then cat "$WORK/snaps.\$key"; exit 0; fi
exit 1
EOF
chmod +x "$WORK/bin/zfs"

# shellcheck disable=SC1090
source "$ZB"

run() {   # <config> args...
    local cfg="$1"; shift
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" \
      cmd_restore --config="$cfg" "$@" ) 2>&1
}

mkcfg() {   # <file> <body...>
    # Capture the path BEFORE shifting: after the shift $1 is the body, and
    # writing to "$1" then means writing to a file named by the config text.
    # That bug made several assertions below pass for the wrong reason before it
    # was caught -- fixtures need the same suspicion as product code.
    local f="$1"; shift
    printf '[defaults]\n\thost_label = t\n' > "$f"
    printf '%b' "$@" >> "$f"
}

# ---- the verb is deliberately narrow -----------------------------------------
cfg="$WORK/basic.conf"
mkcfg "$cfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n'

out="$(run "$cfg")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'only --plan is implemented'; } \
    && ok "restore without --plan refuses and names the later verb" \
    || bad "restore without --plan refuses and names the later verb" "rc=$rc"

out="$(run "$cfg" --plan --bogus)"; rc=$?
[ "$rc" -ne 0 ] && ok "an unknown option refuses" || bad "an unknown option refuses" "rc=$rc"

out="$( ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" cmd_restore --plan ) 2>&1 )"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'no cron config known'; } \
    && ok "no config and no server.conf refuses rather than guessing" \
    || bad "no config and no server.conf refuses rather than guessing" "rc=$rc"

empty="$WORK/empty.conf"; mkcfg "$empty" '\n'
out="$(run "$empty" --plan)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'nothing to restore from'; } \
    && ok "a config describing no relationship says so instead of printing an empty plan" \
    || bad "a config describing no relationship says so instead of printing an empty plan" "rc=$rc"

# ---- where the copy actually lives -------------------------------------------
# local push: snapsend recreates the source path UNDER the target, so the copy of
# rpool/data backed up to hdd/store is hdd/store/rpool/data. Getting this wrong
# would send an operator looking in the wrong place during a recovery.
out="$(run "$cfg" --plan)"
printf '%s' "$out" | grep -q 'hdd/store/rpool/data' \
    && ok "local push: the copy path nests the source under the target" \
    || bad "local push: the copy path nests the source under the target" "$(printf '%s' "$out"|grep -i kopia)"

pull="$WORK/pull.conf"
mkcfg "$pull" '\n[dataset:hdd/mirror]\n\tsrc          = zfsbackup@10.0.0.9:tank/x\n'
out="$(run "$pull" --plan)"
{ printf '%s' "$out" | grep -q 'zfsbackup@10.0.0.9:tank/x' && printf '%s' "$out" | grep -qE 'Kopia:[[:space:]]+hdd/mirror$'; } \
    && ok "remote pull: the local dataset IS the copy, the remote is the source" \
    || bad "remote pull: the local dataset IS the copy, the remote is the source" "$(printf '%s' "$out"|grep -iE 'zrodlo|kopia')"

# ---- THE PAIR: creation, never the name --------------------------------------
# name says 2026-01-01 03:00:00, ZFS creation says 2026-06-15 12:00:00.
printf 'hdd/store/rpool/data@automated_hourly_2026-01-01_03-00-00\t%s\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q '2026-06-15 12:00:00' \
  && printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a snapshot whose name lies is shown at its REAL creation time, and flagged" \
    || bad "a snapshot whose name lies is shown at its REAL creation time, and flagged" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# negative control: name and creation agree -> the same code path must stay quiet.
# Without this, an implementation that flagged every snapshot would pass above.
printf 'hdd/store/rpool/data@automated_hourly_2026-06-15_12-00-00\t%s\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q '2026-06-15 12:00:00' \
  && ! printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a snapshot whose name agrees with creation is NOT flagged (control)" \
    || bad "a snapshot whose name agrees with creation is NOT flagged (control)" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# a snapshot carrying no timestamp in its name at all must not be flagged either.
printf 'hdd/store/rpool/data@manual-before-upgrade\t%s\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q 'manual-before-upgrade' && ! printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a name with no embedded timestamp is listed, not flagged" \
    || bad "a name with no embedded timestamp is listed, not flagged" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# ---- honest about an absent copy ---------------------------------------------
rm -f "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
printf '%s' "$out" | grep -qi 'BRAK' \
    && ok "a copy that does not exist is reported as nothing to restore from" \
    || bad "a copy that does not exist is reported as nothing to restore from" ""

# ---- the filter ---------------------------------------------------------------
two="$WORK/two.conf"
mkcfg "$two" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\n[dataset:rpool/other]\n\tdst          = hdd/store\n'
out="$(run "$two" --plan --dataset=rpool/other)"
{ printf '%s' "$out" | grep -q 'rpool/other' && ! printf '%s' "$out" | grep -qE 'Zrodlo:[[:space:]]+rpool/data$'; } \
    && ok "--dataset selects one relationship" || bad "--dataset selects one relationship" "$(printf '%s' "$out"|grep -i zrodlo)"
out="$(run "$two" --plan --dataset=rpool/nosuch)"
printf '%s' "$out" | grep -qi 'Nic nie pasuje' \
    && ok "a filter that matches nothing says so instead of printing an empty plan" \
    || bad "a filter that matches nothing says so instead of printing an empty plan" ""

# ---- READ-ONLY, asserted from the recorded calls ------------------------------
# Every zfs invocation across every run above must be a `list`. The stub fails any
# other subcommand, so a write would also have been fatal -- this checks the record
# as well, because a future change could reach ZFS through some other path.
if [ -f "$WORK/zfs-calls" ] && grep -qv '^list ' "$WORK/zfs-calls" 2>/dev/null; then
    bad "read-only: every zfs call was a list" "$(grep -v '^list ' "$WORK/zfs-calls" | head -3)"
else
    ok "read-only: every zfs call across every plan was a list"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
