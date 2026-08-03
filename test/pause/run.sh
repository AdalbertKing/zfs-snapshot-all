#!/bin/bash
# Tests for deploy.sh --pause/--resume: stop and later restore every crontab
# this host manages, for a maintenance window (disk swap, a live migration
# off this host) where new snapshots on a pvesr-replicated dataset are
# actively unwelcome, not merely unhelpful -- see the functions' own header
# in deploy.sh for the incident this answers.
#
# No root, no ZFS, no live deploy.sh invocation (that would hit the script's
# own root check): the functions under test (pause_state_path,
# detect_delegated_account, pause_targets, do_pause[_one], do_resume[_one])
# only ever call lib-cron.sh primitives plus plain bash, so they are
# extracted from deploy.sh by pattern (not line number, so this survives the
# file growing around them) and sourced alongside lib-cron.sh and its own
# crontab(1)/flock(1) stubs -- same technique test/cron/run.sh already uses.
#
#   ./test/pause/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-cron.sh}"
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
[ -r "$LIB" ] || { echo "cannot read lib-cron.sh at $LIB" >&2; exit 1; }
[ -r "$DEPLOY_SRC" ] || { echo "cannot read deploy.sh at $DEPLOY_SRC" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin" "$TMPD/tabs"

PASS=0; FAIL=0
check() {   # <desc> <want> <got>
    local d="$1" w="$2" g="$3"
    if [ "$g" = "$w" ]; then echo "PASS $d"; PASS=$((PASS+1))
    else echo "FAIL $d"; echo "     want: [$w]"; echo "     got:  [$g]"; FAIL=$((FAIL+1)); fi
}
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; echo "     $2"; FAIL=$((FAIL+1)); }

# ---- the crontab stub (verbatim shape from test/cron/run.sh) ---------------
cat > "$TMPD/bin/crontab" <<'EOF'
#!/bin/bash
d="${CRONTAB_DIR:?}"; mode="${CRONTAB_MODE:-ok}"
u="$(id -un)"
if [ "${1:-}" = "-u" ]; then u="$2"; shift 2; fi
f="$d/$u"
if [ "${1:-}" = "-l" ]; then
    [ "$mode" = unreadable ] && { echo "crontab: cannot read from database" >&2; exit 1; }
    [ -f "$f" ] || { echo "no crontab for $u" >&2; exit 1; }
    cat "$f"; exit 0
fi
[ "$mode" = refuse ] && { echo "crontab: errors in crontab file" >&2; exit 1; }
if [ "$mode" = liar ]; then cat "${1:?}" > "$f"; echo "# something else" >> "$f"; exit 0; fi
cat "${1:?}" > "$f"; exit 0
EOF
chmod +x "$TMPD/bin/crontab"

# ---- flock(1) shim, same as test/cron/run.sh -- see that file's own comment
if ! command -v flock >/dev/null 2>&1; then
cat > "$TMPD/bin/flock" <<'EOF'
#!/bin/bash
mode="" timeout="" fd=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) timeout="$2"; shift 2 ;;
        -u) mode="unlock"; shift ;;
        -n) mode="${mode:-nonblock}"; shift ;;
        -x|-s) shift ;;
        *) fd="$1"; shift ;;
    esac
done
path=$(readlink /proc/self/fd/"$fd" 2>/dev/null) || exit 1
lockdir="${path}.lockdir"
if [ "$mode" = unlock ]; then rmdir "$lockdir" 2>/dev/null; exit 0; fi
if [ -z "$timeout" ]; then
    mkdir "$lockdir" 2>/dev/null && exit 0
    exit 1
fi
deadline=$(( $(date +%s%N) + timeout * 1000000000 ))
while :; do
    mkdir "$lockdir" 2>/dev/null && exit 0
    [ "$(date +%s%N)" -ge "$deadline" ] && exit 1
    sleep 0.05
done
EOF
chmod +x "$TMPD/bin/flock"
fi

mkdir -p "$TMPD/locks"
export PATH="$TMPD/bin:$PATH"
export CRONTAB_DIR="$TMPD/tabs"
export CRON_LOCK_DIR="$TMPD/locks"
export PAUSE_STATE_DIR="$TMPD/pause-state"
export CRONTAB_MODE=ok
ME="$(id -un)"

# shellcheck disable=SC1090
source "$LIB"

# deploy.sh's own trivial helpers, reproduced rather than sourcing deploy.sh
# itself: the real file has a top-level `[ "$(id -u)" -eq 0 ] || die "run as
# root"` that would abort this suite before the functions under test are even
# reached. PROBLEMS is warn()'s side effect in deploy.sh; declared so `set -u`
# does not trip on it.
PROBLEMS=0
log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; PROBLEMS=$((PROBLEMS + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }
BACKUP_USER=""

# Extracted by pattern, not line number, from the real deploy.sh -- so this
# suite tracks the actual shipped code and cannot silently start testing a
# stale copy if the surrounding file grows.
eval "$(sed -n '/^PAUSE_STATE_DIR="\${PAUSE_STATE_DIR/,/^# do_revoke_old/p' "$DEPLOY_SRC" | sed '$d')"
if ! declare -F do_resume >/dev/null; then
    echo "FATAL: could not extract the pause/resume functions from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
    exit 1
fi
# The extraction re-declares PAUSE_STATE_DIR with deploy.sh's own default
# fallback syntax (${PAUSE_STATE_DIR:-/root/...}) -- since the env already
# exported our throwaway path, that expression just keeps it. Asserted once,
# loudly, so a future refactor of that line cannot silently start writing
# into a real host's /root without any test noticing.
case "$PAUSE_STATE_DIR" in
    "$TMPD"/*) : ;;
    *) echo "FATAL: PAUSE_STATE_DIR resolved to '$PAUSE_STATE_DIR', not the test's throwaway dir -- refusing to run the rest of this suite" >&2; exit 1 ;;
esac

seed() {   # <user> <line>...
    local user="$1"; shift
    printf '%s\n' "$@" > "$TMPD/tabs/$user"
}
tab() { printf '%s' "$TMPD/tabs/$1"; }

# ---- A. a plain pause/resume round trip -------------------------------------
seed "$ME" '# untouched header' '1 * * * * real-job-a' '2 * * * * real-job-b'
out=$(do_pause_one "$ME" 2>&1); rc=$?
check "A1 do_pause_one succeeds" "0" "$rc"
check "A2 the crontab now holds only the pause placeholder" "1" "$(grep -c "$PAUSE_MARKER" "$(tab "$ME")")"
check "A3 ...and nothing of the original job lines" "0" "$(grep -c 'real-job-a' "$(tab "$ME")")"
state=$(pause_state_path "$ME")
check "A4 a saved-state file exists" "0" "$([ -e "$state" ]; echo $?)"
check "A5 ...and it is exactly the original crontab" "0" \
      "$(printf '%s\n' '# untouched header' '1 * * * * real-job-a' '2 * * * * real-job-b' | cmp -s - "$state"; echo $?)"

out=$(do_resume_one "$ME" 2>&1); rc=$?
check "A6 do_resume_one succeeds" "0" "$rc"
check "A7 the crontab is restored exactly" "0" \
      "$(printf '%s\n' '# untouched header' '1 * * * * real-job-a' '2 * * * * real-job-b' | cmp -s - "$(tab "$ME")"; echo $?)"
check "A8 the saved-state file is gone after a successful resume" "1" "$([ -e "$state" ]; echo $?)"

# ---- B. pausing twice is refused, not silently overwritten -----------------
seed "$ME" '3 * * * * second-round'
do_pause_one "$ME" >/dev/null 2>&1
out=$(do_pause_one "$ME" 2>&1); rc=$?
check "B1 a second pause is refused" "1" "$rc"
case "$out" in *"already paused"*) ok "B2 ...named as already paused, not a generic failure" ;;
  *) bad "B2 ...named as already paused, not a generic failure" "$out" ;; esac
check "B3 the saved state still holds the ORIGINAL content, not the placeholder" "0" \
      "$(printf '%s\n' '3 * * * * second-round' | cmp -s - "$(pause_state_path "$ME")"; echo $?)"
do_resume_one "$ME" >/dev/null 2>&1

# ---- C. resuming with nothing paused is refused ----------------------------
out=$(do_resume_one "$ME" 2>&1); rc=$?
check "C1 resuming with nothing paused is refused" "1" "$rc"
case "$out" in *"nothing paused"*) ok "C2 ...named as nothing paused" ;;
  *) bad "C2 ...named as nothing paused" "$out" ;; esac

# ---- D. a manual edit made DURING the pause window is never silently
# discarded by --resume -- it is exactly the kind of operator action this
# tool must not clobber. ----
seed "$ME" '4 * * * * before-pause'
do_pause_one "$ME" >/dev/null 2>&1
printf '%s\n' '# an operator typed this by hand during the window' '5 * * * * emergency-job' > "$(tab "$ME")"
out=$(do_resume_one "$ME" 2>&1); rc=$?
check "D1 resume refuses when the crontab no longer looks like the placeholder" "1" "$rc"
case "$out" in *"manual edit"*) ok "D2 ...named as a possible manual edit, not a generic failure" ;;
  *) bad "D2 ...named as a possible manual edit, not a generic failure" "$out" ;; esac
check "D3 the manual edit is left exactly as it was" "0" \
      "$(printf '%s\n' '# an operator typed this by hand during the window' '5 * * * * emergency-job' | cmp -s - "$(tab "$ME")"; echo $?)"
check "D4 the saved pre-pause state is still there, not discarded either" "0" \
      "$([ -e "$(pause_state_path "$ME")" ]; echo $?)"
rm -f "$(pause_state_path "$ME")"

# ---- E. a write that fails read-back (liar mode) never reports a pause,
# and never creates a saved-state file an operator could mistake for a real
# backup of a crontab that, in fact, never actually got blanked correctly. ---
seed "$ME" '6 * * * * pre-liar'
CRONTAB_MODE=liar
out=$(do_pause_one "$ME" 2>&1); rc=$?
CRONTAB_MODE=ok
check "E1 a write that fails read-back is refused" "1" "$rc"
check "E2 no saved-state file is created on a failed pause" "1" "$([ -e "$(pause_state_path "$ME")" ]; echo $?)"

# ---- F. do_pause/do_resume: BOTH root's crontab and the named delegated
# account's, one failure never stopping the other. -----------------------
seed "$ME" '# root' '7 * * * * root-job'
seed "acct-user" '# acct' '8 * * * * acct-job'
BACKUP_USER="acct-user"
# do_pause always targets "root" literally (see pause_targets) -- this test
# runs as $ME, not literally root, so it exercises the OTHER crontab
# (acct-user) for real and root's through the same code path but against a
# crontab this stub has never seeded; that is fine, it proves the loop
# processes BOTH names, not that "root" here is a privileged account.
out=$(do_pause 2>&1); rc=$?
check "F1 do_pause pauses the named account" "0" "$([ -e "$(pause_state_path "acct-user")" ]; echo $?)"
check "F2 ...and its crontab now holds only the placeholder" "1" "$(grep -c "$PAUSE_MARKER" "$(tab "acct-user")")"
out=$(do_resume 2>&1); rc=$?
check "F3 do_resume restores the named account" "0" \
      "$(printf '%s\n' '# acct' '8 * * * * acct-job' | cmp -s - "$(tab "acct-user")"; echo $?)"
[ -e "$(pause_state_path root)" ] && rm -f "$(pause_state_path root)"
[ -e "$(pause_state_path "acct-user")" ] && rm -f "$(pause_state_path "acct-user")"

# ---- G. no delegated account named or found: warns, still pauses root -----
BACKUP_USER=""
seed "$ME" '# root only' '9 * * * * root-job2'
out=$(do_pause 2>&1)
case "$out" in *"only root's crontab will be paused"*) ok "G1 no account found/given: warns plainly" ;;
  *) bad "G1 no account found/given: warns plainly" "$out" ;; esac
do_resume >/dev/null 2>&1
rm -f "$(pause_state_path root)" 2>/dev/null

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
