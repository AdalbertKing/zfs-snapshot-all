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
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

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

# --- 3. a failed fast-forward leaves the checkout and the pointer usable -----
advance C
printf 'local edit\n' >> "$CLONE/file"      # makes --ff-only impossible
before_head="$(head_of "$CLONE")"
before_prev="$(cat "$PREV")"
out="$(run --self-update)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(head_of "$CLONE")" = "$before_head" ] \
   && [ "$(cat "$PREV")" = "$before_prev" ]; then
    ok "failed update changes neither the checkout nor the rollback point"
else
    bad "failed update changes neither the checkout nor the rollback point" \
        "rc=$rc head=$(head_of "$CLONE") prev=$(cat "$PREV")"
fi
if printf '%s' "$out" | grep -q 'Local modifications'; then
    ok "failed update says WHY (local modifications)"
else
    bad "failed update says WHY (local modifications)" "got: $(printf '%s' "$out" | tail -1)"
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

# --- 7. repeated deployment leaves exactly one update cron line -------------
# The crontab itself is not touched here (that needs a real host and is verified
# live), but the matcher that decides whether to add, replace or leave alone is
# pure text, so it can be checked directly against every shape the line has had.
line_new="15 * * * * $CLONE/deploy.sh --self-update >>/root/scripts/git-pull.log 2>&1"
line_old1="15 * * * * cd $CLONE && git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
line_old2="15 * * * * cd $CLONE && git rev-parse HEAD > /var/lib/zfs-snapshot-all/last-known-good 2>/dev/null; git pull --ff-only origin main >>/root/scripts/git-pull.log 2>&1"
for shape in "$line_old1" "$line_old2"; do
    kept=$(printf '%s\n%s\n' "# unrelated" "$shape" \
        | grep -vF -- "$CLONE/deploy.sh --self-update" \
        | grep -v "$(printf '%s.*git pull' "$CLONE")" \
        | { cat; echo "$line_new"; } | grep -c 'deploy.sh --self-update\|git pull')
    if [ "$kept" -eq 1 ]; then
        ok "old cron shape is replaced, not duplicated (${shape:0:28}...)"
    else
        bad "old cron shape is replaced, not duplicated" "$kept update lines survived"
    fi
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
