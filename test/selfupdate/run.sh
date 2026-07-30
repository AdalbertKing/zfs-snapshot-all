#!/bin/bash
# Tests for deploy.sh --self-update / --rollback / --resume-updates.
#
# Covers REV-20260729-003 F1: the previous implementation was one cron line that
# wrote the CURRENT revision to "last-known-good" every hour, so an hour after a
# bad update the recorded rollback point was the bad revision itself -- and a
# `git reset --hard` was undone by the next hourly pull anyway.
#
# No root, no ZFS, no network: a throwaway origin repo and clone are built in
# $TMPDIR, and REPO_DIR/UPDATE_STATE_DIR/ALERT_SHARED_DIR are pointed at them.
# The update path exits before every deployment phase, which is what makes this
# testable at all -- and is itself a property worth having, since cron runs it
# hourly and a rollback has to work when the thing being rolled back is broken.
#
#   ./test/selfupdate/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY="${DEPLOY:-$REPO/deploy.sh}"
[ -r "$DEPLOY" ] || { echo "cannot find deploy.sh at $DEPLOY" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP $1"; shift; [ $# -gt 0 ] && printf '  %s\n' "$@"; SKIP=$((SKIP+1)); }

# Some of the REV-20260729-004 (F1/F2) cases below need REAL symlinks and REAL
# POSIX permission-bit enforcement to mean anything. This dev box is Windows
# git-bash/MSYS: `ln -s` silently copies the target instead of linking, and
# `chmod` on the NTFS-backed filesystem does not change what stat reports.
# Probe both up front and SKIP (not fake-pass) whatever cannot be exercised
# for real here -- these must be re-run on a real Linux host (pve0/pve1, or
# any host in the fleet) before the corresponding finding can be called
# verified there too.
CAN_SYMLINK=0
_lp="$WORK/.symlink-probe"
ln -s /nonexistent "$_lp" 2>/dev/null
[ -L "$_lp" ] && CAN_SYMLINK=1
rm -f "$_lp"

CAN_CHMOD=0
_cp="$WORK/.chmod-probe"; mkdir -p "$_cp"
chmod 0700 "$_cp" 2>/dev/null
[ "$(stat -c '%a' "$_cp" 2>/dev/null)" = "700" ] && CAN_CHMOD=1
rmdir "$_cp" 2>/dev/null
[ "$CAN_SYMLINK" -eq 1 ] || echo "NOTE: this environment cannot create real symlinks -- F1 symlink-rejection cases will SKIP" >&2
[ "$CAN_CHMOD" -eq 1 ]  || echo "NOTE: this environment does not enforce real permission bits -- F1/F2 permission cases will SKIP" >&2

# Builds a fresh throwaway bare origin + clone, isolated from the shared
# CLONE/STATE narrative below, sitting at commit X with a real update (Y)
# already pushed and waiting -- so a self-update is always available without
# disturbing the numbered cases that share $CLONE/$PREV/$HOLD. Two tracked
# files (main_file, other_file) so a test can dirty one without the other
# being touched by the incoming commit -- the exact gap F3 named. Echoes
# "<origin>|<clone>".
mk_scenario() {
    local tag="$1" o s c
    o="$WORK/f-origin-$tag"; s="$WORK/f-seed-$tag"; c="$WORK/f-clone-$tag"
    git init -q --bare "$o"
    mkdir -p "$s"
    ( cd "$s" && git init -q && git config user.email t@t && git config user.name t \
        && git config core.autocrlf false \
        && echo X > main_file && echo O > other_file \
        && git add main_file other_file && git commit -qm X \
        && git branch -M main && git remote add origin "$o" && git push -q origin main ) >/dev/null 2>&1
    git -C "$o" symbolic-ref HEAD refs/heads/main
    git -c core.autocrlf=false clone -q -b main "$o" "$c" >/dev/null 2>&1
    ( cd "$c" && git config user.email t@t && git config user.name t )
    ( cd "$s" && echo Y >> main_file && git add main_file && git commit -qm Y && git push -q origin main ) >/dev/null 2>&1
    printf '%s|%s' "$o" "$c"
}

ORIGIN="$WORK/origin"
CLONE="$WORK/clone"
STATE="$WORK/state"
mkdir -p "$STATE"

git init -q --bare "$ORIGIN"
seed="$WORK/seed"; mkdir -p "$seed"
(
  cd "$seed"
  git init -q; git config user.email t@t; git config user.name t
  git config core.autocrlf false   # keeps a Windows dev box from printing CRLF warnings
  echo A > file; git add file; git commit -qm A
  git branch -M main; git remote add origin "$ORIGIN"; git push -q origin main
)
# -b main, and the bare repo's HEAD moved to match: `git init --bare` defaults
# HEAD to refs/heads/master on this git, so a plain clone of a main-only repo
# checks nothing out and every later rev-parse fails on an empty branch. That
# cost a debugging round -- the symptom was "fatal: ambiguous argument 'HEAD'"
# from the code under test, which looked like the code's fault and was not.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
# -c core.autocrlf=false at CLONE time, not afterwards. Setting it after the
# checkout leaves a worktree whose files have CRLF and whose blobs have LF --
# permanently "modified", so every --ff-only fails and case 2 collapses. That is
# the same CRLF trap this project has hit before, walked into here by a change
# whose only purpose was to silence a warning.
git -c core.autocrlf=false clone -q -b main "$ORIGIN" "$CLONE"
( cd "$CLONE"; git config user.email t@t; git config user.name t )

# The three env overrides are why this is runnable without touching a live host.
#
# The canary: if deploy.sh ever demands root for these modes again, every case
# below would "pass" by never running. That is not hypothetical -- the first
# version of this suite reported PASS on cases 1 and 2 while nothing had
# executed at all. Refuse to keep score in that state.
run() {
    local out rc
    out="$(REPO_DIR="$CLONE" ALERT_SHARED_DIR="$STATE" UPDATE_STATE_DIR="$STATE" \
           bash "$DEPLOY" "$@" 2>&1)"; rc=$?
    if printf '%s' "$out" | grep -q 'run as root'; then
        echo "ABORT: deploy.sh $* refused to run unprivileged -- this suite would score itself on nothing" >&2
        exit 2
    fi
    printf '%s' "$out"
    return "$rc"
}
head_of()  { git -C "$1" rev-parse HEAD; }
advance()  { ( cd "$seed" && echo "$1" >> file && git add file && git commit -qm "$1" && git push -q origin main ); }

PREV="$STATE/previous-revision"
HOLD="$STATE/update-hold"

# --- 1. A == origin/main: the rollback pointer must not be consumed ----------
A="$(head_of "$CLONE")"
run --self-update >/dev/null
if [ ! -e "$PREV" ]; then
    ok "no-op update records nothing"
else
    bad "no-op update records nothing" "previous-revision was created: $(cat "$PREV")"
fi

# Repeat with a pointer already present: a no-op must leave it alone. This is
# the actual bug -- the old line overwrote it every hour, so the useful target
# survived at most sixty minutes.
printf 'sentinel-value\n' > "$PREV"
run --self-update >/dev/null
if [ "$(cat "$PREV")" = "sentinel-value" ]; then
    ok "no-op update leaves an existing rollback point untouched"
else
    bad "no-op update leaves an existing rollback point untouched" "became: $(cat "$PREV")"
fi
rm -f "$PREV"

# --- 2. A -> B: pointer holds A, checkout becomes B -------------------------
advance B
B_expected="$(git -C "$ORIGIN" rev-parse main)"
run --self-update >/dev/null
if [ "$(head_of "$CLONE")" = "$B_expected" ] && [ "$(cat "$PREV")" = "$A" ]; then
    ok "real update activates B and records A"
else
    bad "real update activates B and records A" \
        "head: $(head_of "$CLONE")" "wanted: $B_expected" "recorded: $(cat "$PREV" 2>/dev/null)"
fi

# --- 3. a dirty worktree leaves the checkout and the pointer usable ---------
# Since REV-20260729-004 F3, this now gets caught by the explicit
# `git status --porcelain` check BEFORE any merge is attempted (the case this
# edits happens to touch the same file the incoming commit changes, but F3's
# check does not care which file -- see cases 9/10 below for the two shapes
# the OLD --ff-only-failure-only check missed entirely).
advance C
printf 'local edit\n' >> "$CLONE/file"      # dirties the worktree
before_head="$(head_of "$CLONE")"
before_prev="$(cat "$PREV")"
out="$(run --self-update)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(head_of "$CLONE")" = "$before_head" ] \
   && [ "$(cat "$PREV")" = "$before_prev" ]; then
    ok "dirty worktree leaves neither the checkout nor the rollback point changed"
else
    bad "dirty worktree leaves neither the checkout nor the rollback point changed" \
        "rc=$rc head=$(head_of "$CLONE") prev=$(cat "$PREV")"
fi
if printf '%s' "$out" | grep -qi 'not clean'; then
    ok "dirty worktree refusal says WHY (not clean)"
else
    bad "dirty worktree refusal says WHY (not clean)" "got: $(printf '%s' "$out" | tail -1)"
fi
git -C "$CLONE" checkout -q -- file        # clean up so the next case can run
run --self-update >/dev/null               # now at C
C_head="$(head_of "$CLONE")"

# --- 4. rollback B -> A creates a hold --------------------------------------
target="$(cat "$PREV")"
out="$(run --rollback)"
if [ "$(head_of "$CLONE")" = "$target" ] && [ -e "$HOLD" ]; then
    ok "rollback moves the checkout back and creates a hold"
else
    bad "rollback moves the checkout back and creates a hold" \
        "head=$(head_of "$CLONE") wanted=$target hold=$([ -e "$HOLD" ] && echo yes || echo no)"
fi
if printf '%s' "$out" | grep -q -- '--resume-updates'; then
    ok "rollback tells the operator how to resume"
else
    bad "rollback tells the operator how to resume" "got: $(printf '%s' "$out" | tail -1)"
fi

# --- 5. while held, the hourly run must NOT undo the rollback ---------------
# This is the second half of the finding: without a hold, sixty minutes later
# cron pulls the bad revision straight back and the rollback never happened.
held_head="$(head_of "$CLONE")"
run --self-update >/dev/null
if [ "$(head_of "$CLONE")" = "$held_head" ]; then
    ok "an hourly run while held does not restore the rolled-back revision"
else
    bad "an hourly run while held does not restore the rolled-back revision" \
        "moved to $(head_of "$CLONE")"
fi

# --- 6. resume removes the hold and updates deliberately --------------------
out="$(run --resume-updates)"
if [ ! -e "$HOLD" ] && [ "$(head_of "$CLONE")" = "$C_head" ]; then
    ok "resume removes the hold and advances to origin/main"
else
    bad "resume removes the hold and advances to origin/main" \
        "hold=$([ -e "$HOLD" ] && echo present || echo gone) head=$(head_of "$CLONE") wanted=$C_head"
fi

# --- 7. cron-line matcher: normalizes every known shape to ONE current line -
# REV-20260729-004 F4: the old matcher checked `grep -qF -- "--self-update"`
# GLOBALLY with no $REPO_DIR anchor, so (a) an unrelated line for a different
# program/repo that merely contained that substring made the whole check pass
# without looking at this repo at all, and (b) once a current-shaped line
# existed anywhere, an old duplicate alongside it was left in place forever
# (the first matching branch always won). This mirrors deploy.sh's
# is_this_repo_updater_line() exactly -- keep both in sync if either changes.
is_this_repo_updater_line() {
    case "$1" in
        *"$CLONE/deploy.sh --self-update"*) return 0 ;;
        *"cd $CLONE"*"git pull --ff-only origin main"*) return 0 ;;
    esac
    return 1
}
normalize_counts() {
    # Lines on stdin -> "match_count exact_count" against $line_new.
    local m=0 e=0 l
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        if is_this_repo_updater_line "$l"; then
            m=$((m + 1))
            [ "$l" = "$line_new" ] && e=$((e + 1))
        fi
    done
    echo "$m $e"
}
normalize_lines() {
    # Lines on stdin -> every non-matching line, then exactly one $line_new --
    # the same shape deploy.sh's Phase 7 pipes into `crontab -`.
    local l
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        is_this_repo_updater_line "$l" || printf '%s\n' "$l"
    done
    echo "$line_new"
}
check_counts() {
    local desc="$1" want_m="$2" want_e="$3"; shift 3
    local got got_m got_e
    got=$(printf '%s\n' "$@" | normalize_counts)
    got_m=${got% *}; got_e=${got#* }
    if [ "$got_m" = "$want_m" ] && [ "$got_e" = "$want_e" ]; then
        ok "$desc"
    else
        bad "$desc" "got match=$got_m exact=$got_e, wanted match=$want_m exact=$want_e"
    fi
}
check_normalizes_to_one() {
    local desc="$1"; shift
    local kept
    kept=$(printf '%s\n' "$@" | normalize_lines | grep -c 'deploy\.sh --self-update\|git pull --ff-only origin main')
    if [ "$kept" -eq 1 ]; then
        ok "$desc"
    else
        bad "$desc" "$kept updater-shaped line(s) survived normalization"
    fi
}

line_new="15 * * * * $CLONE/deploy.sh --self-update >>/root/scripts/git-pull.log 2>&1"
line_old1="15 * * * * cd $CLONE && git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
line_old2="15 * * * * cd $CLONE && git rev-parse HEAD > /var/lib/zfs-snapshot-all/last-known-good 2>/dev/null; git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
line_unrelated="15 * * * * /root/scripts/some-other-project/run.sh --self-update >>/root/scripts/other.log 2>&1"

check_counts "no existing line -- nothing matches"                                    0 0
check_counts "one current line -- already normalized"                                 1 1 "$line_new"
check_counts "one old (bare git pull) line -- matches, not exact"                      1 0 "$line_old1"
check_counts "one old (rev-parse-then-pull) line -- matches, not exact"                1 0 "$line_old2"
check_counts "current + old together -- BOTH match (old is not left behind)"          2 1 "$line_new" "$line_old1"
check_counts "two current lines -- both match, both exact (a duplicate is detected)"   2 2 "$line_new" "$line_new"
check_counts "an unrelated --self-update line for another repo does not match"         0 0 "$line_unrelated"
check_counts "unrelated line coexists with this repo's old line -- only ours matches"  1 0 "$line_unrelated" "$line_old1"

check_normalizes_to_one "old (bare git pull) shape is replaced, not duplicated"          "$line_old1"
check_normalizes_to_one "old (rev-parse-then-pull) shape is replaced, not duplicated"    "$line_old2"
check_normalizes_to_one "current + old together normalize to exactly one line"          "$line_new" "$line_old1"
check_normalizes_to_one "two current duplicates normalize to exactly one line"          "$line_new" "$line_new"

# --- 8. `set -u` canary for the whole top of the script ---------------------
# Every case above passes ALERT_SHARED_DIR in the environment, so the code path
# that computes the state directory from its DEFAULT was never executed -- and a
# reference to a variable defined further down the file therefore shipped, making
# every plain `deploy.sh` invocation die on "ALERT_SHARED_DIR: unbound
# variable". bash -n cannot see it and no suite ran deploy.sh without overrides.
#
# So: run with only REPO_DIR set and assert nothing is unbound. The run itself is
# expected to fail (the default state dir is not writable unprivileged); what is
# asserted is HOW it fails.
out="$(REPO_DIR="$CLONE" bash "$DEPLOY" --self-update 2>&1)"
if printf '%s' "$out" | grep -q 'unbound variable'; then
    bad "no unbound variable with defaults in play" "$(printf '%s' "$out" | grep 'unbound variable' | head -1)"
else
    ok "no unbound variable with defaults in play"
fi
# Same question for a plain run, which reaches further into the file than any
# other case here does before it needs root.
out="$(REPO_DIR="$CLONE" bash "$DEPLOY" --check-only 2>&1)"
if printf '%s' "$out" | grep -q 'unbound variable'; then
    bad "no unbound variable on a plain --check-only" "$(printf '%s' "$out" | grep 'unbound variable' | head -1)"
else
    ok "no unbound variable on a plain --check-only"
fi

# --- 9. F3: an untracked file blocks --self-update --------------------------
# The old code only ran `git status --porcelain` implicitly via --ff-only's
# own refusal, which does NOT cover an untracked file with no path collision
# against the incoming commit -- git happily fast-forwards past it.
pair=$(mk_scenario f3a); F3A_CLONE=${pair#*|}
S9="$WORK/state-f3a"; mkdir -p "$S9"
before_head="$(head_of "$F3A_CLONE")"
echo "untracked junk" > "$F3A_CLONE/untracked.txt"
out="$(REPO_DIR="$F3A_CLONE" ALERT_SHARED_DIR="$S9" UPDATE_STATE_DIR="$S9" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(head_of "$F3A_CLONE")" = "$before_head" ] && [ ! -e "$S9/previous-revision" ]; then
    ok "F3: an untracked file blocks --self-update (real update available)"
else
    bad "F3: an untracked file blocks --self-update" \
        "rc=$rc head_before=$before_head head_after=$(head_of "$F3A_CLONE") prev=$([ -e "$S9/previous-revision" ] && echo present || echo absent)"
fi

# --- 10. F3: a local edit in a file the incoming commit never touches -------
# The exact gap the reviewer named: commit Y only changes main_file, so a
# local edit in other_file does not collide with the fast-forward's own diff
# and old `--ff-only` would apply it silently, leaving the edit in place.
pair=$(mk_scenario f3b); F3B_CLONE=${pair#*|}
S10="$WORK/state-f3b"; mkdir -p "$S10"
before_head="$(head_of "$F3B_CLONE")"
echo "unrelated local edit" >> "$F3B_CLONE/other_file"
out="$(REPO_DIR="$F3B_CLONE" ALERT_SHARED_DIR="$S10" UPDATE_STATE_DIR="$S10" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(head_of "$F3B_CLONE")" = "$before_head" ] && [ ! -e "$S10/previous-revision" ]; then
    ok "F3: a local edit in a file the incoming commit never touches blocks --self-update"
else
    bad "F3: a local edit in a file the incoming commit never touches blocks --self-update" \
        "rc=$rc head_before=$before_head head_after=$(head_of "$F3B_CLONE") prev=$([ -e "$S10/previous-revision" ] && echo present || echo absent)"
fi

# --- 11. F1: a symlinked UPDATE_STATE_DIR is refused, not followed ----------
if [ "$CAN_SYMLINK" -eq 1 ]; then
    pair=$(mk_scenario f1dir); F1DIR_CLONE=${pair#*|}
    real_target="$WORK/f1dir-real-target"; mkdir -p "$real_target"
    state_link="$WORK/f1dir-state-link"
    ln -s "$real_target" "$state_link"
    out="$(REPO_DIR="$F1DIR_CLONE" ALERT_SHARED_DIR="$state_link" UPDATE_STATE_DIR="$state_link" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$real_target/previous-revision" ] && printf '%s' "$out" | grep -qi symlink; then
        ok "F1: a symlinked UPDATE_STATE_DIR is refused, not followed"
    else
        bad "F1: a symlinked UPDATE_STATE_DIR is refused, not followed" \
            "rc=$rc out_tail=$(printf '%s' "$out" | tail -1)"
    fi
else
    skip "F1: a symlinked UPDATE_STATE_DIR is refused" \
        "this environment's ln -s does not create real symlinks (Windows/MSYS) -- verify on a Linux host"
fi

# --- 12. F1: a symlinked previous-revision is refused, target untouched -----
if [ "$CAN_SYMLINK" -eq 1 ]; then
    pair=$(mk_scenario f1prev); F1PREV_CLONE=${pair#*|}
    S12="$WORK/state-f1prev"; mkdir -p "$S12"
    victim="$WORK/f1prev-victim"; echo "do not touch" > "$victim"
    ln -s "$victim" "$S12/previous-revision"
    before_head="$(head_of "$F1PREV_CLONE")"
    out="$(REPO_DIR="$F1PREV_CLONE" ALERT_SHARED_DIR="$S12" UPDATE_STATE_DIR="$S12" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$(head_of "$F1PREV_CLONE")" = "$before_head" ] && [ "$(cat "$victim")" = "do not touch" ]; then
        ok "F1: a symlinked previous-revision is refused, victim file untouched"
    else
        bad "F1: a symlinked previous-revision is refused, victim file untouched" \
            "rc=$rc victim=$(cat "$victim" 2>/dev/null) head_after=$(head_of "$F1PREV_CLONE")"
    fi
else
    skip "F1: a symlinked previous-revision is refused" \
        "this environment's ln -s does not create real symlinks (Windows/MSYS) -- verify on a Linux host"
fi

# --- 13. F1: a symlinked update-hold is refused, target untouched ----------
if [ "$CAN_SYMLINK" -eq 1 ]; then
    pair=$(mk_scenario f1hold); F1HOLD_CLONE=${pair#*|}
    S13="$WORK/state-f1hold"; mkdir -p "$S13"
    victim2="$WORK/f1hold-victim"; echo "do not touch either" > "$victim2"
    ln -s "$victim2" "$S13/update-hold"
    out="$(REPO_DIR="$F1HOLD_CLONE" ALERT_SHARED_DIR="$S13" UPDATE_STATE_DIR="$S13" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$(cat "$victim2")" = "do not touch either" ]; then
        ok "F1: a symlinked update-hold is refused, victim file untouched"
    else
        bad "F1: a symlinked update-hold is refused, victim file untouched" \
            "rc=$rc victim=$(cat "$victim2" 2>/dev/null)"
    fi
else
    skip "F1: a symlinked update-hold is refused" \
        "this environment's ln -s does not create real symlinks (Windows/MSYS) -- verify on a Linux host"
fi

# --- 14. F1: a group/world-writable UPDATE_STATE_DIR is refused ------------
if [ "$CAN_CHMOD" -eq 1 ]; then
    pair=$(mk_scenario f1perm); F1PERM_CLONE=${pair#*|}
    S14="$WORK/state-f1perm"; mkdir -p "$S14"; chmod 0777 "$S14"
    before_head="$(head_of "$F1PERM_CLONE")"
    out="$(REPO_DIR="$F1PERM_CLONE" ALERT_SHARED_DIR="$S14" UPDATE_STATE_DIR="$S14" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    chmod 0700 "$S14" 2>/dev/null
    if [ "$rc" -ne 0 ] && [ "$(head_of "$F1PERM_CLONE")" = "$before_head" ] && printf '%s' "$out" | grep -qi writable; then
        ok "F1: a group/world-writable UPDATE_STATE_DIR is refused"
    else
        bad "F1: a group/world-writable UPDATE_STATE_DIR is refused" \
            "rc=$rc out_tail=$(printf '%s' "$out" | tail -1)"
    fi
else
    skip "F1: a group/world-writable UPDATE_STATE_DIR is refused" \
        "this environment's chmod does not enforce real POSIX mode bits (Windows/MSYS) -- verify on a Linux host"
fi

# --- 15. F2: a state-write failure refuses to activate B --------------------
# 0500 passes the group/other-writable check (F1's own guard) but leaves even
# the owner unable to create a file in the directory, forcing write_state_file's
# mktemp to fail realistically -- the acceptance criterion is that B is never
# activated without a durably recorded A.
if [ "$CAN_CHMOD" -eq 1 ]; then
    pair=$(mk_scenario f2write); F2_CLONE=${pair#*|}
    S15="$WORK/state-f2write"; mkdir -p "$S15"; chmod 0500 "$S15"
    before_head="$(head_of "$F2_CLONE")"
    out="$(REPO_DIR="$F2_CLONE" ALERT_SHARED_DIR="$S15" UPDATE_STATE_DIR="$S15" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    chmod 0700 "$S15" 2>/dev/null
    if [ "$rc" -ne 0 ] && [ "$(head_of "$F2_CLONE")" = "$before_head" ]; then
        ok "F2: a write failure on the state dir refuses to activate B (checkout unchanged)"
    else
        bad "F2: a write failure on the state dir refuses to activate B" \
            "rc=$rc head_before=$before_head head_after=$(head_of "$F2_CLONE")"
    fi
else
    skip "F2: a write failure on the state dir refuses to activate B" \
        "this environment's chmod does not enforce real POSIX mode bits (Windows/MSYS) -- verify on a Linux host"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
