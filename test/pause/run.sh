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

# ---- mktemp shim: inert unless MKTEMP_FAIL_AFTER_FILE points at a counter
# file, in which case it decrements that counter on every call and fails once
# it reaches zero. This is how F2's "abort leaves nothing committed" claim
# gets proven rather than just asserted: force a resource failure partway
# through a multi-block operation and show the live crontab never changed.
REAL_MKTEMP="$(command -v mktemp)"
{
    printf '#!/bin/bash\nREAL_MKTEMP=%q\n' "$REAL_MKTEMP"
    cat <<'EOF'
cf="${MKTEMP_FAIL_AFTER_FILE:-}"
if [ -n "$cf" ] && [ -f "$cf" ]; then
    remaining=$(cat "$cf" 2>/dev/null || echo -1)
    if [ "$remaining" -le 0 ]; then
        echo "mktemp: simulated failure (test)" >&2
        exit 1
    fi
    echo $((remaining - 1)) > "$cf"
fi
exec "$REAL_MKTEMP" "$@"
EOF
} > "$TMPD/bin/mktemp"
chmod +x "$TMPD/bin/mktemp"

mkdir -p "$TMPD/locks"
export PATH="$TMPD/bin:$PATH"
export CRONTAB_DIR="$TMPD/tabs"
export CRON_LOCK_DIR="$TMPD/locks"
export PAUSE_STATE_DIR="$TMPD/pause-state"
# detect_delegated_account() scans this glob for a real, already-provisioned
# account. Left at deploy.sh's own default, section G's "no account
# found/given" case scans this machine's REAL /home -- which finds nothing
# on a clean box but finds a real account on every one of this project's own
# production hosts, silently turning that scenario into an untested no-op
# there (found running this suite directly on all four hosts, 2026-08-03).
# Pointed at a path that can never match, so the scenario is deterministic
# regardless of what host this suite happens to run on.
export PAUSE_ACCOUNT_SCAN_GLOB="$TMPD/no-such-home/*/zfs-snapshot-all"
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
#
# The end anchor is an EXPLICIT terminator in deploy.sh. It used to be
# `# do_revoke_old` -- the next comment that happened to follow the family.
# When the family moved above the phases (2026-08-20) that adjacency vanished
# and the extraction quietly swallowed the rest of the file, dispatch
# included, surfacing as `PAUSE_MODE: unbound variable` far from its cause.
_pause_src=$(sed -n '/^PAUSE_STATE_DIR="\${PAUSE_STATE_DIR/,/^# END --pause\/--resume family/p' "$DEPLOY_SRC" | sed '$d')
# Over-extraction is exactly what this file could not see before, so name it
# directly instead of inferring it from whatever breaks downstream: the family
# is constants and function definitions, and must carry no dispatch of its own.
case "$_pause_src" in
    *'if [ "$PAUSE_MODE" -eq 1 ]'*)
        echo "FATAL: the extraction reached deploy.sh's --pause dispatch, so it took more than the pause/resume family -- fix the end anchor rather than letting the extra code run here" >&2
        exit 1 ;;
esac
eval "$_pause_src"
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

# ---- F. do_pause/do_resume under --fullcron: BOTH root's crontab and the
# named delegated account's, one failure never stopping the other. ----------
FULLCRON_MODE=1
seed "$ME" '# root' '7 * * * * root-job'
seed "acct-user" '# acct' '8 * * * * acct-job'
BACKUP_USER="acct-user"
# do_pause always targets "root" literally (see pause_targets) -- this test
# runs as $ME, not literally root, so it exercises the OTHER crontab
# (acct-user) for real and root's through the same code path but against a
# crontab this stub has never seeded; that is fine, it proves the loop
# processes BOTH names, not that "root" here is a privileged account.
out=$(do_pause 2>&1); rc=$?
check "F1 do_pause (--fullcron) pauses the named account" "0" "$([ -e "$(pause_state_path "acct-user")" ]; echo $?)"
check "F2 ...and its crontab now holds only the placeholder" "1" "$(grep -c "$PAUSE_MARKER" "$(tab "acct-user")")"
out=$(do_resume 2>&1); rc=$?
check "F3 do_resume restores the named account" "0" \
      "$(printf '%s\n' '# acct' '8 * * * * acct-job' | cmp -s - "$(tab "acct-user")"; echo $?)"
[ -e "$(pause_state_path root)" ] && rm -f "$(pause_state_path root)"
[ -e "$(pause_state_path "acct-user")" ] && rm -f "$(pause_state_path "acct-user")"
FULLCRON_MODE=0

# ---- G. no delegated account named or found: warns, still pauses root -----
BACKUP_USER=""
seed "$ME" '# root only' '9 * * * * root-job2'
FULLCRON_MODE=1
out=$(do_pause 2>&1)
case "$out" in *"only root's crontab will be paused"*) ok "G1 no account found/given: warns plainly" ;;
  *) bad "G1 no account found/given: warns plainly" "$out" ;; esac
do_resume >/dev/null 2>&1
rm -f "$(pause_state_path root)" 2>/dev/null
FULLCRON_MODE=0

# ---- H. block mode (the new default): a plain round trip on one managed
# block, with a foreign line outside it left completely alone. ---------------
block_text() {   # <name> <line>...  -- prints the crontab text to stdout
    local name="$1"; shift
    printf '# a human line above the block\n'
    printf '# BEGIN %s (generated -- do not hand-edit)\n' "$name"
    printf '%s\n' "$@"
    printf '# END %s\n' "$name"
    printf '# a human line below the block\n'
}
seed_block() { local user="$1" name="$2"; shift 2; block_text "$name" "$@" > "$TMPD/tabs/$user"; }   # <user> <name> <line>...
seed_block "$ME" zfs-backup-managed '10 * * * * snap-job-a' '11 * * * * snap-job-b'
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "H1 do_pause_blocks_one succeeds" "0" "$rc"
check "H2 the human line above the block survives untouched" "1" \
      "$(grep -c '^# a human line above the block$' "$(tab "$ME")")"
check "H3 the human line below the block survives untouched" "1" \
      "$(grep -c '^# a human line below the block$' "$(tab "$ME")")"
check "H4 both job lines are now commented, prefixed, findable" "2" \
      "$(grep -cE "^${PAUSE_LINE_PREFIX}[0-9]+ \* \* \* \* snap-job" "$(tab "$ME")")"
check "H5 the raw active job lines are gone" "0" \
      "$(grep -cE '^[0-9]+ \* \* \* \* snap-job' "$(tab "$ME")")"
check "H6 the block still has its BEGIN/END markers" "0" \
      "$(cron_block_locate "$(tab "$ME")" zfs-backup-managed; echo $?)"
out=$(do_resume_blocks_one "$ME" 2>&1); rc=$?
check "H7 do_resume_blocks_one succeeds" "0" "$rc"
check "H8 the crontab is restored byte for byte" "0" \
      "$(block_text zfs-backup-managed '10 * * * * snap-job-a' '11 * * * * snap-job-b' | cmp -s - "$(tab "$ME")"; echo $?)"

# ---- I. a second block-mode pause on an already-paused block is refused ----
seed_block "$ME" zfs-backup-managed '12 * * * * snap-job-c'
do_pause_blocks_one "$ME" >/dev/null 2>&1
before=$(cat "$(tab "$ME")")
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "I1 a second pause on the same block reports failure" "1" "$rc"
case "$out" in *"already paused"*) ok "I2 ...named as already paused" ;;
  *) bad "I2 ...named as already paused" "$out" ;; esac
check "I3 the crontab is unchanged by the refused second pause" "0" \
      "$(printf '%s\n' "$before" | cmp -s - "$(tab "$ME")"; echo $?)"
do_resume_blocks_one "$ME" >/dev/null 2>&1

# ---- J. a line added INSIDE the block during the pause window is kept on
# resume, not silently dropped -- block mode never discards, only strips its
# own prefix off lines it recognises as its own. -----------------------------
seed_block "$ME" zfs-backup-managed '13 * * * * snap-job-d'
do_pause_blocks_one "$ME" >/dev/null 2>&1
# hand-edit: insert a line with no pause prefix, inside the still-paused
# block, right before its END marker -- rebuilt line by line rather than
# sed -i (not portable across the sed variants this suite might run under).
_edited=$(mktemp)
while IFS= read -r _l; do
    [ "$_l" = "# END zfs-backup-managed" ] && printf "# an operator's own line, added mid-window\n" >> "$_edited"
    printf '%s\n' "$_l" >> "$_edited"
done < "$(tab "$ME")"
mv "$_edited" "$(tab "$ME")"
out=$(do_resume_blocks_one "$ME" 2>&1); rc=$?
check "J1 resume still succeeds with a foreign line present" "0" "$rc"
case "$out" in *"kept 1 line"*"not ours"*) ok "J2 ...and reports the kept line" ;;
  *) bad "J2 ...and reports the kept line" "$out" ;; esac
check "J3 the operator's line survives in the resumed block" "1" \
      "$(grep -c "operator's own line" "$(tab "$ME")")"
check "J4 the real job line is also restored, unprefixed" "1" \
      "$(grep -c '^13 \* \* \* \* snap-job-d$' "$(tab "$ME")")"

# ---- K. two managed blocks in the same crontab: both paused and resumed,
# independently, in one call. -------------------------------------------------
{ printf '# BEGIN zfs-backup-host (host jobs -- do not hand-edit)\n'
  printf '15 * * * * /root/scripts/update-control.sh --self-update\n'
  printf '# END zfs-backup-host\n'
  printf '# BEGIN zfs-backup-managed (generated -- do not hand-edit)\n'
  printf '20 * * * * snap-job-e\n'
  printf '# END zfs-backup-managed\n'
} > "$TMPD/tabs/$ME"
before=$(cat "$TMPD/tabs/$ME")
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "K1 do_pause_blocks_one succeeds on two blocks" "0" "$rc"
check "K2 both blocks now show the paused header" "2" "$(grep -c "$PAUSE_BLOCK_MARKER" "$(tab "$ME")")"
out=$(do_resume_blocks_one "$ME" 2>&1); rc=$?
check "K3 do_resume_blocks_one succeeds on two blocks" "0" "$rc"
check "K4 the crontab is restored exactly" "0" "$(printf '%s\n' "$before" | cmp -s - "$(tab "$ME")"; echo $?)"

# ---- L. an empty managed block is a no-op, not an error --------------------
{ printf '# BEGIN zfs-backup-managed (generated -- do not hand-edit)\n'
  printf '# END zfs-backup-managed\n'
} > "$TMPD/tabs/$ME"
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "L1 an empty block reports nothing paused" "1" "$rc"
case "$out" in *"empty"*) ok "L2 ...named as empty, not a generic failure" ;;
  *) bad "L2 ...named as empty, not a generic failure" "$out" ;; esac

# ---- M. no managed blocks at all: refused, points at --fullcron -----------
seed "$ME" '# nothing but a human job' '30 * * * * whatever'
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "M1 no managed blocks: reports failure" "1" "$rc"
case "$out" in *"no managed blocks"*"--fullcron"*) ok "M2 ...and suggests --fullcron" ;;
  *) bad "M2 ...and suggests --fullcron" "$out" ;; esac

# ---- N. do_pause()'s default (no --fullcron) drives block mode for BOTH
# root and the named account, each with its own managed block. ---------------
seed_block "$ME" zfs-backup-host '40 * * * * root-block-job'
seed_block "acct-user" zfs-backup-managed '41 * * * * acct-block-job'
BACKUP_USER="acct-user"
out=$(do_pause 2>&1); rc=$?
check "N1 do_pause (default) leaves no --fullcron saved state" "1" "$([ -e "$(pause_state_path "acct-user")" ]; echo $?)"
check "N2 ...but the account's block is paused" "1" "$(grep -c "$PAUSE_BLOCK_MARKER" "$(tab "acct-user")")"
out=$(do_resume 2>&1); rc=$?
check "N3 do_resume (default) resumes the account's block" "1" \
      "$(grep -c '^41 \* \* \* \* acct-block-job$' "$(tab "acct-user")")"
BACKUP_USER=""

# ---- O. REV-20260803-036 F1: an uncreatable pause-state directory refuses
# cleanly, before the crontab is ever touched, and leaves no state artifact. -
seed "$ME" '# O before' '50 * * * * o-job'
before_O=$(cat "$(tab "$ME")")
blocker="$TMPD/o-blocker-file"
: > "$blocker"
SAVED_PSD="$PAUSE_STATE_DIR"
PAUSE_STATE_DIR="$blocker/cannot-create-under-a-file"
out=$(do_pause_one "$ME" 2>&1); rc=$?
check "O1 an uncreatable state dir refuses the pause" "1" "$rc"
case "$out" in *"pause-state directory"*) ok "O2 ...named as the state-dir problem" ;;
  *) bad "O2 ...named as the state-dir problem" "$out" ;; esac
check "O3 the crontab is completely untouched" "0" \
      "$(printf '%s\n' "$before_O" | cmp -s - "$(tab "$ME")"; echo $?)"
PAUSE_STATE_DIR="$SAVED_PSD"

# ---- P. F1: if the crontab write itself fails AFTER the resume state was
# already durably committed, that state is rolled back -- never left behind
# falsely claiming the user is paused. ---------------------------------------
seed "$ME" '# P before' '51 * * * * p-job'
CRONTAB_MODE=liar
out=$(do_pause_one "$ME" 2>&1); rc=$?
CRONTAB_MODE=ok
check "P1 a write that fails read-back is refused" "1" "$rc"
check "P2 no resume-state file is left behind" "1" "$([ -e "$(pause_state_path "$ME")" ]; echo $?)"
check "P3 no placeholder-state file is left behind" "1" "$([ -e "$(pause_placeholder_path "$ME")" ]; echo $?)"

# ---- Q. F3: --resume refuses when the placeholder line is still present but
# something has been APPENDED after it. A substring grep would have accepted
# this and silently discarded the appended line; the byte-exact compare must
# not. ------------------------------------------------------------------------
seed "$ME" '# Q before' '52 * * * * q-job'
do_pause_one "$ME" >/dev/null 2>&1
ph_text=$(cat "$(tab "$ME")")
printf '%s\n%s\n' "$ph_text" '5 * * * * emergency-job-added-during-the-window' > "$(tab "$ME")"
out=$(do_resume_one "$ME" 2>&1); rc=$?
check "Q1 resume refuses a placeholder with an appended line" "1" "$rc"
case "$out" in *"byte-for-byte"*) ok "Q2 ...named as an exact-shape mismatch" ;;
  *) bad "Q2 ...named as an exact-shape mismatch" "$out" ;; esac
check "Q3 the appended emergency line survives" "1" \
      "$(grep -c 'emergency-job-added-during-the-window' "$(tab "$ME")")"
check "Q4 the saved pre-pause state is still there" "0" "$([ -e "$(pause_state_path "$ME")" ]; echo $?)"
rm -f "$(pause_state_path "$ME")" "$(pause_placeholder_path "$ME")"

# ---- R. F4: a foreign block that merely matches the marker GRAMMAR (not
# this package's registry) is never touched by default --pause. -------------
{ printf '# BEGIN certbot (managed by some other tool)\n'
  printf '30 2 * * * /usr/bin/certbot renew --quiet\n'
  printf '# END certbot\n'
  printf '# BEGIN zfs-backup-managed (generated -- do not hand-edit)\n'
  printf '55 * * * * r-job\n'
  printf '# END zfs-backup-managed\n'
} > "$TMPD/tabs/$ME"
before_R_certbot=$(sed -n '/^# BEGIN certbot/,/^# END certbot/p' "$TMPD/tabs/$ME")
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "R1 do_pause_blocks_one succeeds" "0" "$rc"
check "R2 the foreign certbot block is byte-identical" "0" \
      "$(printf '%s\n' "$before_R_certbot" | cmp -s - <(sed -n '/^# BEGIN certbot/,/^# END certbot/p' "$(tab "$ME")"); echo $?)"
check "R3 the certbot job line is NOT commented out" "1" \
      "$(grep -c '^30 2 \* \* \* /usr/bin/certbot renew --quiet$' "$(tab "$ME")")"
check "R4 our own block WAS paused" "1" "$(grep -c "$PAUSE_BLOCK_MARKER" "$(tab "$ME")")"
do_resume_blocks_one "$ME" >/dev/null 2>&1

# ---- S. F5: once a block is paused, an ORDINARY writer (the same
# cron_block_ensure_line gen-cron.sh/deploy.sh's other call sites use) is
# refused, not able to silently reconstruct an active block behind the
# pause's back. ---------------------------------------------------------------
seed_block "$ME" zfs-backup-managed '60 * * * * s-job'
do_pause_blocks_one "$ME" >/dev/null 2>&1
paused_snapshot_S=$(cat "$(tab "$ME")")
# NOT `out=$(...)`: that runs in a subshell, and CRON_ERR is a plain global --
# an assignment made inside a command substitution's subshell never reaches
# the parent shell, so checking $CRON_ERR afterward would silently see
# whatever it held before this call (same class of bug as `die` inside a
# $( ) losing its own diagnostic). Call it directly instead.
CRON_ERR=""
cron_block_ensure_line "$ME" zfs-backup-managed "s-job" "61 * * * * s-job-REACTIVATED" >/dev/null 2>&1; rc=$?
check "S1 an ordinary ensure_line write is refused while paused" "1" "$rc"
check "S2 CRON_ERR names the pause" "1" "$(printf '%s' "$CRON_ERR" | grep -c 'currently paused')"
check "S3 the crontab is untouched -- still in its paused shape" "0" \
      "$(printf '%s\n' "$paused_snapshot_S" | cmp -s - "$(tab "$ME")"; echo $?)"
do_resume_blocks_one "$ME" >/dev/null 2>&1

# ---- T. F5: a --fullcron-paused crontab (no blocks at all, just the
# placeholder) also refuses an ordinary block INSTALL -- appending a new
# active block next to the placeholder must not be possible either. ---------
seed "$ME" '# T before' '62 * * * * t-job'
do_pause_one "$ME" >/dev/null 2>&1
placeholder_snapshot_T=$(cat "$(tab "$ME")")
newbody_T=$(mktemp)
printf '63 * * * * t-job-REACTIVATED\n' > "$newbody_T"
out=$(cron_block_install "$ME" zfs-backup-managed "$newbody_T" 2>&1); rc=$?
rm -f "$newbody_T"
check "T1 an ordinary block install is refused against a fullcron-paused crontab" "1" "$rc"
check "T2 the crontab is still exactly the fullcron placeholder" "0" \
      "$(printf '%s\n' "$placeholder_snapshot_T" | cmp -s - "$(tab "$ME")"; echo $?)"
do_resume_one "$ME" >/dev/null 2>&1

# ---- U. F2 (mixed): one block already paused, the other not -- the doable
# one still gets paused. Not a transaction abort: an already-paused block is
# a legitimate skip, not a failure. -------------------------------------------
{ printf '# BEGIN zfs-backup-host (host jobs)\n'
  printf '%s at 2020-01-01 00:00:00 UTC -- run: deploy.sh --resume\n' "$PAUSE_BLOCK_MARKER"
  printf '%s70 * * * * already-paused-job\n' "$PAUSE_LINE_PREFIX"
  printf '# END zfs-backup-host\n'
  printf '# BEGIN zfs-backup-managed (generated)\n'
  printf '71 * * * * u-job\n'
  printf '# END zfs-backup-managed\n'
} > "$TMPD/tabs/$ME"
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
check "U1 the operation succeeds overall" "0" "$rc"
check "U2 the already-paused block's OWN header is untouched (old timestamp)" "1" \
      "$(grep -c '2020-01-01 00:00:00 UTC' "$(tab "$ME")")"
check "U3 the not-yet-paused block IS now paused (2 headers total)" "2" \
      "$(grep -c "$PAUSE_BLOCK_MARKER" "$(tab "$ME")")"
do_resume_blocks_one "$ME" >/dev/null 2>&1

# ---- V. F2: a forced failure processing the SECOND block aborts the WHOLE
# operation -- the crontab is left completely untouched, not partially
# paused. Proven by forcing mktemp to fail exactly where block 2's own
# processing would begin: block 1's full pipeline (cron_read's own internal
# mktemp for its stderr file, then body/newbody/staged) is 5 calls; the 6th
# call is the first one block 2 makes. If a future refactor changes that
# count, this either still fails before the single commit (V1-V3 still hold,
# just for a less precisely targeted reason) or stops failing at all, which
# V1 catches directly. -------------------------------------------------------
{ printf '# BEGIN zfs-backup-host (host jobs)\n'
  printf '80 * * * * v-host-job\n'
  printf '# END zfs-backup-host\n'
  printf '# BEGIN zfs-backup-managed (generated)\n'
  printf '81 * * * * v-managed-job\n'
  printf '# END zfs-backup-managed\n'
} > "$TMPD/tabs/$ME"
before_V=$(cat "$TMPD/tabs/$ME")
echo 5 > "$TMPD/mktemp-fail-after"
export MKTEMP_FAIL_AFTER_FILE="$TMPD/mktemp-fail-after"
out=$(do_pause_blocks_one "$ME" 2>&1); rc=$?
unset MKTEMP_FAIL_AFTER_FILE
rm -f "$TMPD/mktemp-fail-after"
check "V1 the operation reports failure" "1" "$rc"
check "V2 the crontab is completely untouched (both blocks still active)" "0" \
      "$(printf '%s\n' "$before_V" | cmp -s - "$(tab "$ME")"; echo $?)"
check "V3 no pause header appears anywhere" "0" "$(grep -c "$PAUSE_BLOCK_MARKER" "$(tab "$ME")")"

# ============================================================================
# A DECISION IS NOT A PROVISIONING RUN.
#
# `--pause` was moved above Phase 1 because a maintenance window "has no business
# pulling the repo, rewriting notify-fail.sh or reinstalling cron lines". Nothing
# pinned that, so `--commit-scope` -- which is a decision about PERMISSIONS --
# still sat at the dispatch near the foot of the file, after Phase 7.
#
# Measured on a PRODUCTION host, 2026-08-26: `deploy.sh --commit-scope=pve9`, run
# to answer a permission question, added
#
#     0 8 * * * /root/scripts/check-pool-capacity.sh
#
# to root's crontab. The line is harmless. An operator being surprised by it is
# not, and the next such verb would land the same way with nothing to catch it.
#
# So the ORDER is the assertion, checked in the file rather than by running a
# verb that needs root, ZFS and a live manifest. Structural, and exact: the
# dispatch line must come before the first phase that touches the host.
# ============================================================================
DEPLOY_SH="$REPO/deploy.sh"
first_phase_line="$(grep -n 'log "Phase 1: dependencies"' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
if [ -n "$first_phase_line" ]; then
    check "order: deploy.sh still has a first phase to compare against" "0" "0"
else
    check "order: deploy.sh still has a first phase to compare against" "0" "1"
fi
for verb in PAUSE_MODE RESUME_MODE COMMIT_SCOPE_MODE; do
    vline="$(grep -n "^if \[ \"\\\$$verb\" -eq 1 \]; then" "$DEPLOY_SH" | head -1 | cut -d: -f1)"
    if [ -n "$vline" ] && [ -n "$first_phase_line" ] && [ "$vline" -lt "$first_phase_line" ]; then
        check "order: $verb is dispatched BEFORE the first host phase" "0" "0"
    else
        check "order: $verb is dispatched BEFORE the first host phase" "0" \
              "1 (dispatch=${vline:-none} phase1=$first_phase_line)"
    fi
done
# The negative half: --join is NOT expected here, and saying so keeps the
# assertion honest. Enrolling a host legitimately provisions it, so a build that
# hoisted every verb above the phases would be wrong in the other direction.
jline="$(grep -n '^if \[ "\$JOIN_MODE" -eq 1 \]; then' "$DEPLOY_SH" | tail -1 | cut -d: -f1)"
if [ -n "$jline" ] && [ "$jline" -gt "$first_phase_line" ]; then
    check "order: --join still runs AFTER the phases, because enrolling provisions" "0" "0"
else
    check "order: --join still runs AFTER the phases, because enrolling provisions" "0" \
          "1 (join=${jline:-none} phase1=$first_phase_line)"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
