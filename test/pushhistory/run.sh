#!/bin/bash
# snapsend -H must not bypass the no-common-base refusal (REV-20261017-151, P0).
#
# -H used to skip that refusal, so push went on to `zfs send -R` into
# `zfs recv -F` on an EXISTING, UNRELATED target -- and a replication stream
# received with -F destroys target snapshots the source does not have. Pull
# never had the exception.
#
# Drives the REAL snapsend.sh / snapget.sh CLI, local to local, with traced
# zfs/zpool stubs and a snapshot db file (<dataset>@<snap> <guid>). Datasets
# that exist are listed in a second file. Without root, ZFS or a network.
#
#   ./test/pushhistory/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
[ -r "$SNAPSEND" ] && [ -r "$SNAPGET" ] || { echo "cannot read the engines under $REPO" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
check() {   # <name> <condition-command...>
    local name="$1"; shift
    if "$@"; then ok "$name"; else bad "$name" "rc=$rc" "--- out:" "$out" "--- trace:" "$(cat "$TRACE" 2>/dev/null)"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bin"; mkdir -p "$B"
TRACE="$WORK/trace"; SNAPDB="$WORK/snaps"; DSDB="$WORK/datasets"
export TRACE SNAPDB DSDB

cat > "$B/zfs" <<'EOF'
#!/bin/bash
echo "ZFS $*" >> "$TRACE"
last="${*: -1}"
case "$1" in
    list)
        case " $* " in
            *" -t snapshot "*)
                awk -v d="$last" 'index($1, d "@")==1 {print $1}' "$SNAPDB"; exit 0 ;;
            *" -t bookmark "*) exit 0 ;;
        esac
        grep -qxF -- "$last" "$DSDB" && { echo "$last"; exit 0; }
        exit 1 ;;
    get)
        case " $* " in
            *" guid "*) awk -v n="$last" '$1==n {print $2}' "$SNAPDB"; exit 0 ;;
            *" receive_resume_token "*) echo - ;;
            *" encryption "*) echo off ;;
            *" keystatus "*) echo available ;;
            *" mounted "*) echo no ;;
            *" written"*) echo 0 ;;
            *" canmount "*) echo noauto ;;
            *) echo - ;;
        esac
        exit 0 ;;
    send) exit 0 ;;
    recv|receive) cat >/dev/null; exit 0 ;;
    create|destroy) echo "MUTATION $*" >> "$TRACE"; exit 0 ;;
esac
exit 0
EOF
cat > "$B/zpool" <<'EOF'
#!/bin/bash
echo "ZPOOL $*" >> "$TRACE"
case " $* " in *" -o health "*) echo ONLINE ;; *) echo tank ;; esac
EOF
for _t in mbuffer zstd pigz; do printf '#!/bin/bash\ncat\n' > "$B/$_t"; done
command -v flock >/dev/null 2>&1 || printf '#!/bin/bash\nexit 0\n' > "$B/flock"
printf '#!/bin/bash\nexit 0\n' > "$B/logger"
chmod +x "$B"/*

N=0
# run <engine> <args...> -- sets rc, out; fresh trace, own lock dir
run() {
    local engine="$1"; shift
    N=$((N + 1)); mkdir -p "$WORK/lock$N"
    : > "$TRACE"
    out=$(env PATH="$B:$PATH" LOCKDIR="$WORK/lock$N" STATS_LOG="$WORK/stats" \
          NOTIFY_SCRIPT=/bin/true HOME="$WORK" RELATIONSHIPS_DIR="$WORK/rel" \
          bash "$engine" "$@" 2>&1); rc=$?
}
REFUSAL="already exists and shares no common snapshot"
sent()     { grep -q '^ZFS send' "$TRACE"; }
received() { grep -q '^ZFS recv\|^ZFS receive' "$TRACE"; }

# ---- the unrelated existing target: tank/src@new (111) vs backup/tank/src@foreign (222)
unrelated() {
    printf 'tank/src@new 111\nbackup/tank/src@foreign 222\n' > "$SNAPDB"
    printf 'tank/src\nbackup\nbackup/tank\nbackup/tank/src\n' > "$DSDB"
}

unrelated; run "$SNAPSEND" -e -N tank/src backup
check "push, no -H, unrelated target: refused, rc 1, no send, no recv" \
    bash -c "[ $rc -eq 1 ] && printf '%s' \"\$1\" | grep -q '$REFUSAL' && ! grep -q '^ZFS send' '$TRACE' && ! grep -q '^ZFS recv' '$TRACE'" _ "$out"

unrelated; run "$SNAPSEND" -H -e -N tank/src backup
check "push -H, unrelated target: refused, rc 1, the same refusal text" \
    bash -c "[ $rc -eq 1 ] && printf '%s' \"\$1\" | grep -q '$REFUSAL'" _ "$out"
check "push -H, unrelated target: NO zfs send and NO zfs recv (never reaches recv -F)" \
    bash -c "! grep -q '^ZFS send' '$TRACE' && ! grep -q '^ZFS recv' '$TRACE'"
check "push -H, unrelated target: nothing created or destroyed" \
    bash -c "! grep -q '^MUTATION' '$TRACE'"

unrelated; run "$SNAPGET" -H -e -N tank/src backup
check "pull -H, unrelated target (twin control): refused, rc 1, no send, no recv" \
    bash -c "[ $rc -eq 1 ] && printf '%s' \"\$1\" | grep -q '$REFUSAL' && ! grep -q '^ZFS send' '$TRACE' && ! grep -q '^ZFS recv' '$TRACE'" _ "$out"

# ---- absent target: -H still sends the full replication history
printf 'tank/src@new 111\n' > "$SNAPDB"
printf 'tank/src\nbackup\nbackup/tank\n' > "$DSDB"
run "$SNAPSEND" -H -e -N tank/src backup
check "push -H, ABSENT target: a full-history stream (zfs send ... -R tank/src@new) is sent and received" \
    bash -c "grep -q '^ZFS send .*-R tank/src@new' '$TRACE' && grep -q '^ZFS recv' '$TRACE' && ! printf '%s' \"\$1\" | grep -q '$REFUSAL'" _ "$out"

# ---- common base (D3 backup landing): -H with a shared @old stays incremental
printf 'tank/src@old 100\ntank/src@new 111\nbackup/tank/src@old 100\n' > "$SNAPDB"
printf 'tank/src\nbackup\nbackup/tank\nbackup/tank/src\n' > "$DSDB"
run "$SNAPSEND" -H -e -N tank/src backup
check "push -H, common base @old: not refused; an incremental from @old is sent into recv -F" \
    bash -c "! printf '%s' \"\$1\" | grep -q '$REFUSAL' && grep -q '^ZFS send .*-I tank/src@old tank/src@new\|^ZFS send .*-i tank/src@old tank/src@new' '$TRACE' && grep -q '^ZFS recv -F' '$TRACE'" _ "$out"

echo
echo "pushhistory: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
