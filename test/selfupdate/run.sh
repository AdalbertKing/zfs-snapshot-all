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
UPDATE_CONTROL="${UPDATE_CONTROL:-$REPO/update-control.sh}"
[ -r "$UPDATE_CONTROL" ] || { echo "cannot find update-control.sh at $UPDATE_CONTROL" >&2; exit 1; }
. "$SCRIPT_DIR/../harness.sh"   # product_fn, for section 28's twins
TWINS_BASELINE="${TWINS_BASELINE:-$SCRIPT_DIR/controller-twins.sha256}"
BLESS_TWINS=0
for a in "$@"; do
    case "$a" in
        --bless-twins) BLESS_TWINS=1 ;;
        *) echo "unknown option $a (expected --bless-twins)" >&2; exit 1 ;;
    esac
done

# Simulates exactly what deploy.sh's Phase 7 does: sed-template the two
# placeholders and drop the result into the (throwaway) state dir, outside the
# (throwaway) checkout -- so tests 16-19 below can prove the wrapper enforces
# the hold/rollback/resume contract independent of whatever deploy.sh in the
# checkout does or does not know about it (REV-20260730-001 F1).
deploy_wrapper() {
    local repo_dir="$1" state_dir="$2"
    mkdir -p "$state_dir"
    sed -e "s#__REPO_DIR__#$repo_dir#g" -e "s#__UPDATE_STATE_DIR__#$state_dir#g" \
        "$UPDATE_CONTROL" > "$state_dir/update-control.sh"
    chmod +x "$state_dir/update-control.sh"
}

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

# NOT chmod-based: deploy.sh always runs as root, and root ignores DAC
# permission bits entirely (confirmed live on pve0/pve1 2026-07-30 -- a
# `chmod 0500` write-failure case reported a FALSE FAIL there because root
# happily wrote into a directory it supposedly had no permission bits for).
# `chattr +i` (the ext2/3/4 immutable attribute) is enforced at the VFS layer
# regardless of DAC/capabilities, so it is the only portable way to make even
# root's own write genuinely fail.
CAN_IMMUTABLE=0
_ip="$WORK/.immutable-probe"; mkdir -p "$_ip"
if command -v chattr >/dev/null 2>&1 && chattr +i "$_ip" 2>/dev/null; then
    touch "$_ip/probe-file" 2>/dev/null || CAN_IMMUTABLE=1
    chattr -i "$_ip" 2>/dev/null
fi
rm -rf "$_ip" 2>/dev/null

[ "$CAN_SYMLINK" -eq 1 ]   || echo "NOTE: this environment cannot create real symlinks -- F1 symlink-rejection cases will SKIP" >&2
[ "$CAN_CHMOD" -eq 1 ]     || echo "NOTE: this environment does not enforce real permission bits -- F1's group/world-writable case will SKIP" >&2
[ "$CAN_IMMUTABLE" -eq 1 ] || echo "NOTE: this environment cannot make a directory immutable (chattr +i) -- F2's write-failure case will SKIP" >&2

# EVERY SANDBOX REPO NOW SHIPS A STUB deploy.sh.
#
# Since 2026-09-02 a successful change of revision APPLIES itself: update-
# control.sh runs $REPO_DIR/deploy.sh so the scripts generated from its
# heredocs (alert-digest.sh and friends) follow the checkout. Without a
# deploy.sh in the sandbox every scenario would exercise the "missing" branch
# instead of the real one, and --resume-updates would restore its hold on an
# apply that never had a chance to succeed.
#
# The delimiter is QUOTED. Unquoted, every $( ) below expands in THIS shell at
# fixture-writing time, and the stub ships with the suite runner's own paths
# baked in -- the same defect class test/alertmail guards for in deploy.sh.
#
# The marker path comes from the stub's OWN location rather than $REPO_DIR:
# the deployed wrapper keeps REPO_DIR as a shell variable and never exports
# it, so a stub keyed on the environment writes nowhere useful. It is written
# OUTSIDE the checkout as well -- a file inside would leave the repo dirty and
# the next self-update would refuse to fast-forward, which is a property of
# the product worth not breaking by accident in a fixture.
write_stub_deploy() {   # <dir>
    cat > "$1/deploy.sh" <<'STUB'
#!/bin/bash
# stub deploy.sh -- records that the apply step ran, and with what arguments
_d=$(cd "$(dirname "$0")" && pwd)
echo "applied $(git -C "$_d" rev-parse --short HEAD 2>/dev/null) args:$*" >> "${_d}-applied"
exit ${STUB_DEPLOY_RC:-0}
STUB
    chmod +x "$1/deploy.sh"
}

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
        && echo X > main_file && echo O > other_file && write_stub_deploy "$s" \
        && git add main_file other_file deploy.sh && git commit -qm X \
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
  echo A > file; write_stub_deploy "$seed"; git add file deploy.sh; git commit -qm A
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
        *"$STATE/update-control.sh --self-update"*) return 0 ;;
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
# `chattr +i`, not chmod: deploy.sh always runs as root, and root ignores its
# own DAC permission bits, so a chmod-based "unwritable directory" is not
# actually unwritable to the process under test (confirmed live on pve0/pve1,
# 2026-07-30 -- this case false-FAILed there before the fix, because root
# wrote into the "read-only" directory anyway). The immutable attribute is
# enforced below the permission-bit layer and blocks root too, so it is the
# only portable way to make write_state_file's mktemp genuinely fail -- the
# acceptance criterion is that B is never activated without a durably
# recorded A.
if [ "$CAN_IMMUTABLE" -eq 1 ]; then
    pair=$(mk_scenario f2write); F2_CLONE=${pair#*|}
    S15="$WORK/state-f2write"; mkdir -p "$S15"; chattr +i "$S15" 2>/dev/null
    before_head="$(head_of "$F2_CLONE")"
    out="$(REPO_DIR="$F2_CLONE" ALERT_SHARED_DIR="$S15" UPDATE_STATE_DIR="$S15" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
    chattr -i "$S15" 2>/dev/null
    if [ "$rc" -ne 0 ] && [ "$(head_of "$F2_CLONE")" = "$before_head" ]; then
        ok "F2: a write failure on the state dir refuses to activate B (checkout unchanged)"
    else
        bad "F2: a write failure on the state dir refuses to activate B" \
            "rc=$rc head_before=$before_head head_after=$(head_of "$F2_CLONE")"
    fi
else
    skip "F2: a write failure on the state dir refuses to activate B" \
        "this environment cannot make a directory immutable (chattr +i not supported/available, e.g. Windows/MSYS or a non-ext filesystem) -- verify on a Linux host with ext2/3/4"
fi

# --- 16. REV-20260730-001 F1: a deployed wrapper enforces an existing hold --
# even though the fixture's deploy.sh is only a stub -- the exact independence
# the finding requires: the enforcement point must not depend on what is
# checked out in $REPO_DIR.
pair=$(mk_scenario f1wrap); F1WRAP_ORIGIN=${pair%%|*}; F1WRAP_CLONE=${pair#*|}
S16="$WORK/state-f1wrap"
deploy_wrapper "$F1WRAP_CLONE" "$S16"
printf 'held for test\n' > "$S16/update-hold"
before_head="$(head_of "$F1WRAP_CLONE")"
out="$(bash "$S16/update-control.sh" --self-update 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(head_of "$F1WRAP_CLONE")" = "$before_head" ] && printf '%s' "$out" | grep -qi 'HELD'; then
    ok "F1: the deployed wrapper honors an existing hold with no deploy.sh present in the checkout"
else
    bad "F1: the deployed wrapper honors an existing hold with no deploy.sh present in the checkout" \
        "rc=$rc head_before=$before_head head_after=$(head_of "$F1WRAP_CLONE") out_tail=$(printf '%s' "$out" | tail -1)"
fi

# --- 17. F1: resume via the wrapper advances the checkout, same independence -
out="$(bash "$S16/update-control.sh" --resume-updates 2>&1)"; rc=$?
Y_expected="$(git -C "$F1WRAP_ORIGIN" rev-parse main)"
if [ "$rc" -eq 0 ] && [ ! -e "$S16/update-hold" ] && [ "$(head_of "$F1WRAP_CLONE")" = "$Y_expected" ]; then
    ok "F1: --resume-updates via the deployed wrapper removes the hold and advances"
else
    bad "F1: --resume-updates via the deployed wrapper removes the hold and advances" \
        "rc=$rc hold=$([ -e "$S16/update-hold" ] && echo present || echo gone) head=$(head_of "$F1WRAP_CLONE") wanted=$Y_expected"
fi

# --- 18. F1: rollback via the wrapper works the same way -- same independence
out="$(bash "$S16/update-control.sh" --rollback 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$S16/update-hold" ] && [ "$(head_of "$F1WRAP_CLONE")" = "$before_head" ]; then
    ok "F1: --rollback via the deployed wrapper moves the checkout back and re-holds"
else
    bad "F1: --rollback via the deployed wrapper moves the checkout back and re-holds" \
        "rc=$rc hold=$([ -e "$S16/update-hold" ] && echo present || echo gone) head=$(head_of "$F1WRAP_CLONE") wanted=$before_head"
fi

# --- 19. F2: emergency_disable falls back to disabling the wrapper itself ---
# when the hold file cannot be written at all. `source`d (guarded by the
# BASH_SOURCE == $0 check in update-control.sh) so the function can be called
# directly rather than needing to engineer a real mid-update write failure.
#
# `bash -c 'commands'` (no arg0) leaves $0 as the literal string "bash",
# different from BASH_SOURCE[0] (the wrapper's real path) -- which is exactly
# what lets `source` skip the dispatch guard at the bottom of update-control.sh
# instead of hitting its `die "usage: ..."` branch. `emergency_disable` itself
# uses "$SELF" (= BASH_SOURCE[0], set once near the top of update-control.sh),
# NOT "$0", for exactly this reason: an earlier version used "$0" here, and a
# live run on pve0 (2026-07-30) caught the consequence for real -- with $0
# left as the literal "bash", the crontab-removal fallback ran
# `grep -vF "bash"` against the live crontab and silently dropped the
# unrelated `SHELL=/bin/bash` header line (restored by hand immediately
# after). BASH_SOURCE[0] is always bash's own resolved path to whatever file
# is currently being read, sourced or executed alike, so it does not have
# this ambiguity.
if [ "$CAN_IMMUTABLE" -eq 1 ]; then
    S19="$WORK/state-f2disable"; mkdir -p "$S19"
    deploy_wrapper "$F1WRAP_CLONE" "$S19"
    wrapper19="$S19/update-control.sh"
    chattr +i "$S19" 2>/dev/null
    out="$(REPO_DIR="$F1WRAP_CLONE" UPDATE_STATE_DIR="$S19" bash -c "source '$wrapper19'; emergency_disable 'test reason'" 2>&1)"; rc=$?
    perm_after=$(stat -c '%a' "$wrapper19" 2>/dev/null)
    chattr -i "$S19" 2>/dev/null
    chmod 0755 "$wrapper19" 2>/dev/null
    if [ "$rc" -eq 0 ] && [ "$perm_after" = "0" ]; then
        ok "F2: emergency_disable falls back to disabling the wrapper when the hold write itself fails"
    else
        bad "F2: emergency_disable falls back to disabling the wrapper when the hold write itself fails" \
            "rc=$rc wrapper_perm=$perm_after out_tail=$(printf '%s' "$out" | tail -1)"
    fi
else
    skip "F2: emergency_disable falls back to disabling the wrapper" \
        "this environment cannot make a directory immutable (chattr +i not supported/available) -- verify on a Linux host with ext2/3/4"
fi

# --- 20. F2 test debt (REV-20260730-002): an atomic-RENAME-only failure -----
# distinct from a mktemp/write failure (case 15's `chattr +i` on the whole
# directory blocks BOTH the temp-file create and the final rename, so it
# cannot tell which one actually failed). `chattr +i` on the pre-existing
# DESTINATION FILE, not the directory, isolates exactly the rename: the
# directory stays writable, so mktemp and the write into the tempfile both
# succeed, and only `mv -f tmp dst` fails -- confirmed live on pve0 first
# (2026-07-30): `mv` reports "Operation not permitted" against an immutable
# destination while a plain new file in the same directory writes fine.
#
# This directly tests `write_state_file()`, the shared primitive every
# do_self_update/do_rollback/do_resume_updates state transition goes through,
# rather than one specific caller -- the reviewer's own closure note accepted
# this class of coverage ("code inspection shows these paths converge on the
# tested primitives") as sufficient for the non-blocking P2 debt, while still
# naming the primitive itself as untested in isolation from a directory-wide
# failure. Proves two things atomically: the call reports failure, AND the
# pre-existing content is completely undisturbed (the tempfile never replaces
# it) -- a half-written destination would be worse than an honest failure.
if [ "$CAN_IMMUTABLE" -eq 1 ]; then
    S20="$WORK/state-f2rename"; mkdir -p "$S20"
    wrapper20="$S20/update-control.sh"
    sed -e "s#__REPO_DIR__#/nonexistent#g" -e "s#__UPDATE_STATE_DIR__#$S20#g" "$UPDATE_CONTROL" > "$wrapper20"
    dst20="$S20/update-hold"
    printf 'original content\n' > "$dst20"
    chattr +i "$dst20" 2>/dev/null
    out="$(REPO_DIR=/nonexistent UPDATE_STATE_DIR="$S20" bash -c "source '$wrapper20'; write_state_file '$dst20' 'new content'" 2>&1)"; rc=$?
    chattr -i "$dst20" 2>/dev/null
    content_after="$(cat "$dst20" 2>/dev/null)"
    leftover_tmp="$(find "$S20" -maxdepth 1 -name '.tmp.*' 2>/dev/null | wc -l)"
    if [ "$rc" -ne 0 ] && [ "$content_after" = "original content" ] && printf '%s' "$out" | grep -qi rename; then
        ok "F2 test debt: an atomic-rename-only failure (dir writable, destination immutable) is refused and leaves the destination untouched"
    else
        bad "F2 test debt: an atomic-rename-only failure is refused and leaves the destination untouched" \
            "rc=$rc content_after=$content_after leftover_tmp=$leftover_tmp out_tail=$(printf '%s' "$out" | tail -1)"
    fi
    rm -f "$S20"/.tmp.* 2>/dev/null
else
    skip "F2 test debt: an atomic-rename-only failure is refused" \
        "this environment cannot make a file immutable (chattr +i not supported/available) -- verify on a Linux host with ext2/3/4"
fi


# --- 21. PULLING THE CODE IS NOT DEPLOYING IT ------------------------------
#
# Measured on pve0 and pve1, 2026-09-02: both checkouts sat on the current main
# and both hosts were still mailing alert-digest.sh v9, thirteen versions back.
# Four of the scripts a host RUNS are generated from deploy.sh heredocs and
# installed into /root/scripts -- they are not files in the repo, so a
# fast-forward cannot touch them, and nothing re-ran deploy.sh. deploy.sh
# --check-only had been reporting it on each host for weeks, to nobody.
#
# A successful change of revision now applies itself. The fixture's stub
# deploy.sh records each invocation next to the checkout.
pair=$(mk_scenario apply); APPLY_ORIGIN=${pair%%|*}; APPLY_CLONE=${pair#*|}
S21="$WORK/state-apply"; mkdir -p "$S21"; chmod 700 "$S21"
rm -f "$APPLY_CLONE-applied"
out="$(REPO_DIR="$APPLY_CLONE" UPDATE_STATE_DIR="$S21" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$APPLY_CLONE-applied" ]; then
    ok "apply: a successful fast-forward re-runs deploy.sh so generated scripts follow the checkout"
else
    bad "apply: a successful fast-forward re-runs deploy.sh so generated scripts follow the checkout" \
        "rc=$rc marker=$([ -s "$APPLY_CLONE-applied" ] && echo present || echo absent)" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi

# --- 22. AN APPLY THAT FAILS IS NOT AN UPDATED HOST ------------------------
#
# The discriminating case. The checkout advances either way; the return code
# has to report whether the HOST moved, because a host whose generated scripts
# did not install is exactly the state this whole change exists to end.
# Reporting 0 for it would be the fail-open shape this project keeps finding.
pair=$(mk_scenario applyfail); AF_ORIGIN=${pair%%|*}; AF_CLONE=${pair#*|}
S22="$WORK/state-applyfail"; mkdir -p "$S22"; chmod 700 "$S22"
af_wanted="$(git -C "$AF_ORIGIN" rev-parse main)"
out="$(REPO_DIR="$AF_CLONE" UPDATE_STATE_DIR="$S22" STUB_DEPLOY_RC=7 \
       bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(head_of "$AF_CLONE")" = "$af_wanted" ] \
   && printf '%s' "$out" | grep -q 'may still be running the previous generated scripts'; then
    ok "apply: deploy.sh failing makes --self-update fail, even though the checkout advanced"
else
    bad "apply: deploy.sh failing makes --self-update fail, even though the checkout advanced" \
        "rc=$rc head=$(head_of "$AF_CLONE") wanted=$af_wanted" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi

# --- 23. THE OPT-OUT IS HONOURED, AND SAYS WHAT IT COSTS -------------------
#
# A host may legitimately want to track the repository without applying it.
# The negative control for case 21: without this file the same scenario runs
# deploy.sh, so "no marker" here means the file was read, not that the apply
# path is simply broken.
pair=$(mk_scenario applyoff); AO_ORIGIN=${pair%%|*}; AO_CLONE=${pair#*|}
S23="$WORK/state-applyoff"; mkdir -p "$S23"; chmod 700 "$S23"
: > "$S23/no-auto-apply"
rm -f "$AO_CLONE-applied"
out="$(REPO_DIR="$AO_CLONE" UPDATE_STATE_DIR="$S23" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$AO_CLONE-applied" ] \
   && printf '%s' "$out" | grep -q 'no-auto-apply'; then
    ok "apply: no-auto-apply skips the deploy and still reports success"
else
    bad "apply: no-auto-apply skips the deploy and still reports success" \
        "rc=$rc marker=$([ -e "$AO_CLONE-applied" ] && echo present || echo absent)" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi

# --- 24. A ROLLBACK RE-GENERATES AT THE OLD REVISION -----------------------
#
# The mirrored half of the same defect, and the more dangerous one: a rollback
# that reset the checkout while leaving the NEWER generated scripts installed
# tells the operator the host is back on the old code when it is not.
pair=$(mk_scenario applyback); AB_ORIGIN=${pair%%|*}; AB_CLONE=${pair#*|}
S24="$WORK/state-applyback"; mkdir -p "$S24"; chmod 700 "$S24"
REPO_DIR="$AB_CLONE" UPDATE_STATE_DIR="$S24" bash "$DEPLOY" --self-update >/dev/null 2>&1
rm -f "$AB_CLONE-applied"
out="$(REPO_DIR="$AB_CLONE" UPDATE_STATE_DIR="$S24" bash "$DEPLOY" --rollback 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$AB_CLONE-applied" ]; then
    ok "apply: a rollback re-runs deploy.sh at the revision it rolled back TO"
else
    bad "apply: a rollback re-runs deploy.sh at the revision it rolled back TO" \
        "rc=$rc marker=$([ -s "$AB_CLONE-applied" ] && echo present || echo absent)" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi

# --- 25. A CRONTAB CHANGED BY THE APPLY LEAVES ITS PRE-IMAGE --------------
#
# This is deploy.sh running unattended as root, and this tool has wiped a
# crontab before (2026-08, recorded in the deploy facade notes). The recovery
# material has to exist BEFORE anyone reads the warning, so the pre-image is
# written first and the warning names the restore command.
pair=$(mk_scenario applycron); AC_ORIGIN=${pair%%|*}; AC_CLONE=${pair#*|}
S25="$WORK/state-applycron"; mkdir -p "$S25"; chmod 700 "$S25"
acbin="$WORK/bin-applycron"; mkdir -p "$acbin"
# A crontab(1) whose output CHANGES between the two reads -- the situation the
# pre-image exists for, without touching this machine's real crontab.
cat > "$acbin/crontab" <<'CRONSTUB'
#!/bin/sh
n=$(cat /tmp/.zfsapplycron 2>/dev/null || echo 0)
echo $((n + 1)) > /tmp/.zfsapplycron
[ "$n" = "0" ] && { echo "0 5 * * * before-line"; exit 0; }
echo "0 5 * * * after-line"
CRONSTUB
chmod +x "$acbin/crontab"; rm -f /tmp/.zfsapplycron
out="$(PATH="$acbin:$PATH" REPO_DIR="$AC_CLONE" UPDATE_STATE_DIR="$S25" \
       bash "$DEPLOY" --self-update 2>&1)"; rc=$?
_pre=$(ls "$S25"/crontab.pre-* 2>/dev/null | head -1)
if [ -n "$_pre" ] && grep -q 'before-line' "$_pre" \
   && printf '%s' "$out" | grep -q 'crontab CHANGED'; then
    ok "apply: a crontab changed by the deploy leaves a restorable pre-image"
else
    bad "apply: a crontab changed by the deploy leaves a restorable pre-image" \
        "pre=${_pre:-<brak>} out_tail=$(printf '%s' "$out" | tail -2)"
fi
rm -f /tmp/.zfsapplycron

# --- 26. A RECORDED GRANT LIST IS PASSED BACK ON THE NEXT APPLY ------------
#
# Measured live on pve9/pve9b/pve10 (owner's fleet, 2026-09-03): every hourly
# --self-update calls deploy.sh bare, so Phase 8g always fell through to the
# hardcoded Proxmox default ("rpool/data rpool/ROOT/pve-1") -- which does not
# exist on a host whose only pool is "hdd", FATAL every single run since the
# delegated-account migration (2026-08-01). Whatever an operator once typed by
# hand ("--grant-datasets=hdd") was never remembered for the next apply.
#
# $GRANT_DATASETS_FILE is deploy.sh's own record of the last list it actually
# granted something with; apply_repo_to_host now reads it back and passes it
# on, so the SAME list survives every future bare self-update.
pair=$(mk_scenario applygrant); AG_ORIGIN=${pair%%|*}; AG_CLONE=${pair#*|}
S26="$WORK/state-applygrant"; mkdir -p "$S26"; chmod 700 "$S26"
printf 'hdd\n' > "$S26/grant-datasets"
rm -f "$AG_CLONE-applied"
out="$(REPO_DIR="$AG_CLONE" UPDATE_STATE_DIR="$S26" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$AG_CLONE-applied" ] && grep -qF 'args:--grant-datasets=hdd' "$AG_CLONE-applied"; then
    ok "apply: a recorded grant-datasets file is passed back to deploy.sh as --grant-datasets="
else
    bad "apply: a recorded grant-datasets file is passed back to deploy.sh as --grant-datasets=" \
        "rc=$rc applied=$(cat "$AG_CLONE-applied" 2>/dev/null)" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi

# --- 27. ...AND WITHOUT ONE, NOTHING IS INVENTED ---------------------------
#
# Negative control for 26: no grant-datasets file at all -- the ordinary case
# on every host until it first records one -- must call deploy.sh with no
# --grant-datasets, exactly as before this change. A stub that always passed
# something (even blank) would not discriminate the mechanism above.
pair=$(mk_scenario applygrantoff); AH_ORIGIN=${pair%%|*}; AH_CLONE=${pair#*|}
S27="$WORK/state-applygrantoff"; mkdir -p "$S27"; chmod 700 "$S27"
rm -f "$AH_CLONE-applied"
out="$(REPO_DIR="$AH_CLONE" UPDATE_STATE_DIR="$S27" bash "$DEPLOY" --self-update 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$AH_CLONE-applied" ] && ! grep -q -- '--grant-datasets' "$AH_CLONE-applied"; then
    ok "apply: with no recorded grant-datasets file, deploy.sh is called exactly as before (no invented flag)"
else
    bad "apply: with no recorded grant-datasets file, deploy.sh is called exactly as before (no invented flag)" \
        "rc=$rc applied=$(cat "$AH_CLONE-applied" 2>/dev/null)" \
        "out_tail=$(printf '%s' "$out" | tail -2)"
fi


echo "--------------------------------------------"
# --- 28. THE BOOTSTRAP-FALLBACK TWINS ARE IN LOCKSTEP, MEASURED --------------
#
# deploy.sh carries a copy of nine update-control.sh functions: the fallback
# that runs before the controller has been deployed, or after it was removed
# (REV-20260730-001 F2). deps.conf said "kept in lockstep by hand -- there is
# no source edge" and nothing measured that. Measured 2026-09-03: six were
# identical, two differed only by line continuations and by which program the
# resume hint names, and emergency_disable differs in BEHAVIOUR on purpose
# (the controller can chmod 000 itself; deploy.sh must not, it is the whole
# fleet's deployment tool). So:
#
#   * the twinned set is DERIVED from the two files, as test/twins does;
#   * every twin but emergency_disable must be IDENTICAL after normalisation
#     (comments and blank lines out, continuations joined, whitespace
#     squeezed) and ONE documented substitution: the fallback says
#     `bash $REPO_DIR/deploy.sh` where the controller says `$SELF`, because
#     the fallback has no self to name;
#   * emergency_disable is pinned per side, twins-style: a change on one side
#     is red until reviewed and blessed (--bless-twins), and its two
#     structural facts are asserted outright: the fallback has no chmod step,
#     the controller's chmod step comes BEFORE its crontab step.
norm_twin() {   # <file> <fn> -> normalised body on stdout
    product_fn "$1" "$2" \
        | sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ba}' \
        | grep -vE '^[[:space:]]*(#|$)' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
twin_names_of() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$1" | sed 's/() {$//' | sort -u; }
# log/warn/die are each program's own voice, not update logic: the controller
# prefixes with its own name, deploy.sh with its. Out of the contract by name.
CTWINS="$(comm -12 <(twin_names_of "$DEPLOY") <(twin_names_of "$UPDATE_CONTROL") | grep -vxE 'log|warn|die')"
_nct=$(printf '%s\n' "$CTWINS" | grep -c .)
if [ "$_nct" -ge 9 ]; then ok "28a the fallback twins are derived from both files ($_nct names, the nine of REV-001 included)"
else bad "28a the fallback twins are derived from both files" "only $_nct names -- the derivation, not the files, changed"; fi

for fn in $CTWINS; do
    [ "$fn" = emergency_disable ] && continue
    d_body=$(norm_twin "$DEPLOY" "$fn" | sed 's#bash \$REPO_DIR/deploy\.sh#$SELF#g')
    c_body=$(norm_twin "$UPDATE_CONTROL" "$fn")
    if [ "$d_body" = "$c_body" ]; then
        ok "28b $fn: the fallback copy in deploy.sh is the controller's, modulo the program the hint names"
    else
        bad "28b $fn: the fallback copy in deploy.sh is the controller's, modulo the program the hint names" \
            "$(diff <(printf '%s\n' "$d_body") <(printf '%s\n' "$c_body") | head -8)"
    fi
done

ed_d=$(norm_twin "$DEPLOY" emergency_disable); ed_c=$(norm_twin "$UPDATE_CONTROL" emergency_disable)
if ! printf '%s\n' "$ed_d" | grep -q 'chmod 000'; then ok "28c the fallback's emergency_disable never chmods deploy.sh (the fleet's deployment tool)"
else bad "28c the fallback's emergency_disable never chmods deploy.sh (the fleet's deployment tool)" "$ed_d"; fi
_chmod_at=$(printf '%s\n' "$ed_c" | grep -n 'chmod 000 "\$SELF"' | head -1 | cut -d: -f1)
_cron_at=$(printf '%s\n' "$ed_c" | grep -n 'crontab -l' | head -1 | cut -d: -f1)
if [ -n "$_chmod_at" ] && [ -n "$_cron_at" ] && [ "$_chmod_at" -lt "$_cron_at" ]; then
    ok "28d the controller's emergency_disable disables ITSELF before it touches the crontab"
else
    bad "28d the controller's emergency_disable disables ITSELF before it touches the crontab" "chmod at line ${_chmod_at:-none}, crontab at ${_cron_at:-none}"
fi
h_d=$(printf '%s\n' "$ed_d" | sha256sum | cut -c1-64); h_c=$(printf '%s\n' "$ed_c" | sha256sum | cut -c1-64)
if [ "$BLESS_TWINS" -eq 1 ]; then
    { echo "# emergency_disable, pinned per side after review: <deploy.sh sha256> <update-control.sh sha256>"
      echo "# The two bodies differ ON PURPOSE (see test/selfupdate/run.sh section 28). Regenerate: ./test/selfupdate/run.sh --bless-twins"
      echo "emergency_disable $h_d $h_c"; } > "$TWINS_BASELINE" && echo "blessed $TWINS_BASELINE"
fi
read -r _ want_d want_c < <(grep '^emergency_disable ' "$TWINS_BASELINE" 2>/dev/null || echo "x - -")
if [ "$h_d" = "$want_d" ] && [ "$h_c" = "$want_c" ]; then
    ok "28e emergency_disable unchanged on both sides since the last review"
elif [ "$h_d" != "$want_d" ] && [ "$h_c" != "$want_c" ]; then
    bad "28e emergency_disable changed on BOTH sides" "confirm the two edits are the same decision, then: ./test/selfupdate/run.sh --bless-twins"
elif [ "$h_d" != "$want_d" ]; then
    bad "28e emergency_disable changed in deploy.sh ONLY" "does the controller need the same change? if not, say why, then --bless-twins"
else
    bad "28e emergency_disable changed in update-control.sh ONLY" "does the fallback in deploy.sh need the same change? if not, say why, then --bless-twins"
fi

# --- 29. A DIRECT deploy.sh RUN TAKES THE RECORDED GRANT LIST TOO --------------
#
# PR #292 taught the controller to pass grant-datasets back as
# --grant-datasets= on the hourly apply. A bare `bash deploy.sh` typed at the
# console still used the hardcoded Proxmox default and died in Phase 8g on a
# host whose pool is `hdd` (LAB-DRAFT-CONFIG-WYNIK-2026-09-03, pve9, with a
# correct grant-datasets on disk). The choice is made ABOVE the root gate and
# logged, which is what makes it measurable here as a non-root run that then
# stops at "run as root": the log line is the evidence, its absence the control.
G="$WORK/grant-direct"; mkdir -p "$G/state"; chmod 700 "$G/state"
printf 'hdd/lab hdd/other\n' > "$G/state/grant-datasets"
out="$(UPDATE_STATE_DIR="$G/state" bash "$DEPLOY" 2>&1)"; rc=$?
if printf '%s' "$out" | grep -qF "grant-datasets: using the list recorded at $G/state/grant-datasets (hdd/lab hdd/other)"; then
    ok "29a a bare run with a recorded list says it is using it, before the root gate"
else
    bad "29a a bare run with a recorded list says it is using it, before the root gate" "rc=$rc" "$(printf '%s' "$out" | tail -3)"
fi
out="$(UPDATE_STATE_DIR="$G/state" bash "$DEPLOY" --grant-datasets=tank/x 2>&1)"
if ! printf '%s' "$out" | grep -qF "grant-datasets: using the list recorded"; then
    ok "29b an explicit --grant-datasets wins over the recorded list"
else
    bad "29b an explicit --grant-datasets wins over the recorded list" "$(printf '%s' "$out" | grep -F 'grant-datasets:')"
fi
rm -f "$G/state/grant-datasets"
out="$(UPDATE_STATE_DIR="$G/state" bash "$DEPLOY" 2>&1)"
if ! printf '%s' "$out" | grep -qF "grant-datasets: using the list recorded"; then
    ok "29c no recorded file: the built-in default stands, silently, as before"
else
    bad "29c no recorded file: the built-in default stands, silently, as before" "$(printf '%s' "$out" | grep -F 'grant-datasets:')"
fi
: > "$G/state/grant-datasets"
out="$(UPDATE_STATE_DIR="$G/state" bash "$DEPLOY" 2>&1)"
if ! printf '%s' "$out" | grep -qF "grant-datasets: using the list recorded"; then
    ok "29d an EMPTY recorded file is not a list: the default stands"
else
    bad "29d an EMPTY recorded file is not a list: the default stands" "$(printf '%s' "$out" | grep -F 'grant-datasets:')"
fi

# --- A HELD HOST DOES NOT PULL, SO --rollback ACTUALLY ROLLS BACK -----------
#
# update-control.sh honours the hold at its own front door. deploy.sh's phase 2
# did not: it pulled main into the checkout on every direct run and only
# NOTICED the hold ~800 lines later, where it merely warns.
#
# do_rollback is built out of exactly those pieces -- reset the checkout, write
# the hold, then run deploy.sh to regenerate the host's scripts at that
# revision -- so phase 2 pulled main straight back over the reset, inside the
# same command. Measured on pve10 2026-09-04:
#
#   >>> rolled back 8ee40ef7 -> bd23bcc8
#   >>> Phase 2 ... already a git repo, pulling...
#   Updating bd23bcc8..8e8cbe68
#
# The host finished NEWER than it started while the hold file claimed it was
# parked at bd23bcc8: the rollback and its own safety net both reported success
# about a state that did not exist.
#
# The gate is lifted verbatim from deploy.sh and run with a `git` that records
# what it was asked to do, so this asserts the DECISION, not the wording.
mkdir -p "$WORK/hg"
hold_gate() {   # <hold present: 0|1> -> stdout of the gate; git calls in $WORK/hg/calls
    : > "$WORK/hg/calls"
    if [ "$1" = 1 ]; then printf 'lab, 2026-09-04\n' > "$WORK/hg/hold"; else rm -f "$WORK/hg/hold"; fi
    local t; t=$(mktemp)
    { echo 'set -u'
      echo 'log()  { echo "LOG: $*"; }'
      echo 'warn() { echo "WARN: $*"; }'
      echo 'die()  { echo "DIE: $*"; exit 1; }'
      echo 'read_state_file() { cat "$1" 2>/dev/null; }'
      printf 'REPO_DIR=%q\nREPO_URL=%q\nUPDATE_HOLD_FILE=%q\nCALLS=%q\n' \
             "$WORK/hg/repo" "https://example.invalid/r.git" "$WORK/hg/hold" "$WORK/hg/calls"
      # Records every invocation; answers the two reads the block makes.
      cat <<'STUB'
git() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
        *"remote get-url"*) echo "https://example.invalid/r.git" ;;
        *"rev-parse"*)      echo "deadbee" ;;
    esac
    return 0
}
STUB
      echo 'gate() {'
      awk '/# A HOLD STOPS THIS PULL/{f=1} f{print} f&&/^    fi$/{exit}' "$DEPLOY"
      echo '}'
      echo 'gate'; } > "$t"
    bash "$t" 2>&1; rm -f "$t"
}

out="$(hold_gate 1)"
if ! grep -q -- 'pull --ff-only' "$WORK/hg/calls" \
   && printf '%s' "$out" | grep -q 'NOT pulling'; then
    ok "hold: phase 2 does NOT pull while updates are held"
else
    bad "hold: phase 2 does NOT pull while updates are held" \
        "out=$out calls=$(cat "$WORK/hg/calls")"
fi

# THE POSITIVE CONTROL, and the reason the assertion above means anything: a
# gate that never pulls would pass it just as well.
out="$(hold_gate 0)"
if grep -q -- 'pull --ff-only origin main' "$WORK/hg/calls"; then
    ok "no hold: phase 2 pulls exactly as before"
else
    bad "no hold: phase 2 pulls exactly as before" \
        "out=$out calls=$(cat "$WORK/hg/calls")"
fi

# PLACEMENT IS THE WHOLE FINDING, in both checkouts -- root's and the delegated
# account's. The account copy is what its cron runs; pulling it under a hold
# would leave one host running two revisions.
_g1=$(grep -n 'A HOLD STOPS THIS PULL' "$DEPLOY" | head -1 | cut -d: -f1)
_p1=$(grep -n 'is already a git repo, pulling' "$DEPLOY" | sed -n 1p | cut -d: -f1)
_g2=$(grep -n 'NOT pulling \$ACCOUNT_REPO_DIR either' "$DEPLOY" | head -1 | cut -d: -f1)
_p2=$(grep -n 'is already a git repo, pulling' "$DEPLOY" | sed -n 2p | cut -d: -f1)
if [ -n "$_g1" ] && [ -n "$_p1" ] && [ "$_g1" -lt "$_p1" ]; then
    ok "hold: the gate precedes root's pull in the file"
else
    bad "hold: the gate precedes root's pull in the file" "gate=$_g1 pull=$_p1"
fi
if [ -n "$_g2" ] && [ -n "$_p2" ] && [ "$_g2" -lt "$_p2" ]; then
    ok "hold: the account checkout is gated too"
else
    bad "hold: the account checkout is gated too" "gate=$_g2 pull=$_p2"
fi

echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
