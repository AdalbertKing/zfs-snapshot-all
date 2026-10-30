#!/bin/bash
# release/clean-host-clone.sh (REV-20261030-185): the barrier comes before `git gc --prune=now`,
# a running writer is waited for or refused, and a failure keeps the barrier and the repo usable.
#
# Throw-away origin/clone pairs under mktemp, a stub `crontab`, no root, no network. The runner's
# cwd stays "/" so it never counts as a process working in a test repo.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd /
# as root every test repo would be "root's checkout" and the account cases would test nothing
[ "$(id -u)" != 0 ] || { echo "FAIL cleanclone must run as a non-root user"; echo "PASS=0 FAIL=1"; exit 1; }
SCRIPT="$REPO/release/clean-host-clone.sh"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; local l; for l in "$@"; do echo "     $l"; done; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
BGPIDS=()
cleanup() {
    local p
    for p in "${BGPIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
ME="$(id -un)"
REALGIT="$(command -v git)"

# stub crontab: [-u USER] -l prints the file, [-u USER] FILE installs it (lib-cron.sh drops -u for
# the calling user)
mkdir -p "$WORK/bin" "$WORK/locks"
export CRON_LOCK_DIR="$WORK/locks"
printf '%s\n' \
    '#!/bin/bash' \
    'W="'"$WORK"'"' \
    'u="$(id -un)"' \
    'if [ "${1:-}" = "-u" ]; then u="$2"; shift 2; fi' \
    '[ $# -eq 1 ] || exit 2' \
    'set -- "" "" "$1"' \
    'if [ "$3" = "-l" ]; then' \
    '  [ ! -e "$W/cron.fail" ] || { echo "crontab: permission denied" >&2; exit 1; }' \
    '  [ -f "$W/cron.$u" ] || { echo "no crontab for $u" >&2; exit 1; }' \
    '  cat "$W/cron.$u"; exit 0; fi' \
    '[ ! -e "$W/cron.wfail" ] || { echo "crontab: write refused" >&2; exit 1; }' \
    'cp "$3" "$W/cron.$u"' > "$WORK/bin/crontab"
chmod +x "$WORK/bin/crontab"
export PATH="$WORK/bin:$PATH"

A_SHA=""; B_SHA=""; OLD_SHA=""; R=""; O=""; STATE=""; HOSTDIR=""
new_host() {   # <name>: a fresh, independent origin + clone + state dir + crontab
    local n="$1" s
    HOSTDIR="$WORK/$n"; mkdir -p "$HOSTDIR"
    O="$HOSTDIR/origin.git"; R="$HOSTDIR/repo"; STATE="$HOSTDIR/state"
    s="$HOSTDIR/seed"
    git init -q --bare -b main "$O"
    git init -q -b main "$s"
    printf 'a' > "$s/tool.sh"; printf 'jobs.*.conf\n' > "$s/.gitignore"
    git -C "$s" add tool.sh .gitignore; git -C "$s" commit -q -m A
    A_SHA="$(git -C "$s" rev-parse HEAD)"
    printf 'b' > "$s/tool.sh"; git -C "$s" commit -q -a -m B
    B_SHA="$(git -C "$s" rev-parse HEAD)"
    git -C "$s" push -q "$O" main
    git clone -q "$O" "$R"
    git -C "$R" switch -q -c old
    head -c 300000 /dev/urandom > "$R/big.bin"
    git -C "$R" add big.bin; git -C "$R" commit -q -m big
    OLD_SHA="$(git -C "$R" rev-parse HEAD)"
    git -C "$R" tag t1
    git -C "$R" switch -q main
    printf 'conf-%s\n' "$n" > "$R/jobs.h.conf"; chmod 640 "$R/jobs.h.conf"
    mkdir -m 700 "$STATE"
    printf '%s\n' 'MAILTO=x' \
        "15 * * * * cd $R && git pull --ff-only origin main >>$HOSTDIR/git-pull.log 2>&1" \
        '0 1 * * * /bin/true other' > "$WORK/cron.$ME"
    cp "$WORK/cron.$ME" "$HOSTDIR/cron.seed"
}

out=""; rc=0
run_clean() { out=$(CLEAN_WAIT=${W:-5} CLEAN_POLL=1 bash "$SCRIPT" "$STATE" "$R" 2>&1); rc=$?; }
refs_left() { git -C "$R" for-each-ref --format='%(refname)' | sort | tr '\n' ' '; }
has()   { printf '%s' "$out" | grep -qF -- "$1"; }
tail5() { printf '%s\n' "$out" | tail -5; }
# t <label> <cmd...>: passes when the command succeeds; tn: when it fails
t()  { local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l" "rc=$rc" "$(tail5)"; fi; }
tn() { local l="$1"; shift; if "$@"; then bad "$l" "rc=$rc" "$(tail5)"; else ok "$l"; fi; }
rc_is()  { [ "$rc" -eq 0 ]; }
rc_not() { [ "$rc" -ne 0 ]; }
has_obj() { git -C "$R" cat-file -e "$1" 2>/dev/null; }
has_ref() { git -C "$R" show-ref -q --verify "$1"; }
head_is() { [ "$(git -C "$R" rev-parse HEAD)" = "$1" ]; }
cron_same_as_seed() { cmp -s "$WORK/cron.$ME" "$HOSTDIR/cron.seed"; }
cron_has() { grep -qF -- "$1" "$WORK/cron.$ME"; }
push_commit() {   # <content>: a new commit on origin/main, from the host's seed clone
    printf '%s' "$1" > "$HOSTDIR/seed/tool.sh"
    git -C "$HOSTDIR/seed" commit -q -a -m "c $1" && git -C "$HOSTDIR/seed" push -q "$O" main
    git -C "$HOSTDIR/seed" rev-parse HEAD
}

# ---- c1 account clone, clean run -------------------------------------------------------------
new_host c1
run_clean
t "c1 rc 0" rc_is
want="refs/heads/main refs/remotes/origin/HEAD refs/remotes/origin/main "
got="$(refs_left)"
if [ "$got" = "$want" ] || [ "$got" = "refs/heads/main refs/remotes/origin/main " ]; then
    ok "c1 only main, origin/main (and origin/HEAD) are left"
else
    bad "c1 only main, origin/main (and origin/HEAD) are left" "refs: $got" "rc=$rc" "$(tail5)"
fi
tn "c1 old history is gone from the object store" has_obj "$OLD_SHA"
t  "c1 HEAD is still B" head_is "$B_SHA"
git -C "$R" fsck --full >/dev/null 2>&1; frc=$?
if [ "$frc" -eq 0 ]; then ok "c1 fsck --full clean"; else bad "c1 fsck --full clean" "fsck rc=$frc" "$(tail5)"; fi
if [ "$(cat "$R/jobs.h.conf")" = "conf-c1" ] && [ "$(stat -c %a "$R/jobs.h.conf")" = 640 ]; then
    ok "c1 ignored host config kept (content, mode 640)"
else
    bad "c1 ignored host config kept (content, mode 640)" "mode=$(stat -c %a "$R/jobs.h.conf")" "$(tail5)"
fi
t  "c1 crontab restored byte for byte" cron_same_as_seed
tn "c1 hold removed (this run created it)" test -e "$STATE/update-hold"
C_SHA="$(push_commit c)"
git -C "$R" pull -q --ff-only origin main >/dev/null 2>&1; prc=$?
if [ "$prc" -eq 0 ] && head_is "$C_SHA"; then
    ok "c1 pull --ff-only still works and reaches C"
else
    bad "c1 pull --ff-only still works and reaches C" "pull rc=$prc" "HEAD=$(git -C "$R" rev-parse HEAD) want=$C_SHA"
fi

# ---- c2 root checkout with a rollback target ---------------------------------------------------
new_host c2
printf '%s\n' "$A_SHA" > "$STATE/previous-revision"
CLEAN_ROOT_USER=$ME run_clean
t  "c2 rc 0" rc_is
t  "c2 rollback target A still a commit" has_obj "${A_SHA}^{commit}"
tn "c2 old history gone" has_obj "$OLD_SHA"
if [ "$(tr -d '[:space:]' < "$STATE/previous-revision")" = "$A_SHA" ]; then
    ok "c2 previous-revision untouched"
else
    bad "c2 previous-revision untouched" "$(cat "$STATE/previous-revision")"
fi
tn "c2 hold absent afterwards" test -e "$STATE/update-hold"
t  "c2 root mode does not touch cron" cron_same_as_seed
if [ "$(cat "$R/jobs.h.conf")" = "conf-c2" ] && [ "$(stat -c %a "$R/jobs.h.conf")" = 640 ]; then
    ok "c2 ignored host config kept (content, mode 640)"
else
    bad "c2 ignored host config kept (content, mode 640)" "$(tail5)"
fi
C2_SHA="$(push_commit c2new)"; : > "$STATE/no-auto-apply"
uout=$(REPO_DIR="$R" UPDATE_STATE_DIR="$STATE" bash "$REPO/update-control.sh" --self-update 2>&1); urc=$?
if head_is "$C2_SHA"; then
    ok "c2 root's updater still updates the cleaned checkout"
else
    bad "c2 root's updater still updates the cleaned checkout" "updater rc=$urc" "$(printf '%s\n' "$uout" | tail -5)"
fi

# ---- c3 a hold that existed before is kept -----------------------------------------------------
new_host c3
printf 'owner hold\n' > "$STATE/update-hold"
CLEAN_ROOT_USER=$ME run_clean
t "c3 rc 0" rc_is
if [ -e "$STATE/update-hold" ] && [ "$(cat "$STATE/update-hold")" = "owner hold" ]; then
    ok "c3 the owner's hold is kept with its content"
else
    bad "c3 the owner's hold is kept with its content" "rc=$rc" "$(tail5)"
fi

# ---- c4 busy repo is refused untouched ---------------------------------------------------------
new_host c4
( cd "$R" && exec sleep 30 ) >/dev/null 2>&1 &
SP=$!; BGPIDS+=("$SP")
W=3 run_clean
kill "$SP" 2>/dev/null
t  "c4 rc != 0" rc_not
t  "c4 says still busy" has "still busy"
t  "c4 says barrier in place" has "barrier in place"
t  "c4 refs/heads/old untouched" has_ref refs/heads/old
t  "c4 old object present" has_obj "$OLD_SHA"
t  "c4 update-hold exists" test -e "$STATE/update-hold"
tn "c4 pull line removed from cron" cron_has "git pull --ff-only"
t  "c4 other cron line kept" cron_has "/bin/true other"
set -- "$STATE"/clean-host-clone.*/crontab."$ME"
if [ $# -eq 1 ] && [ -f "$1" ] && cmp -s "$1" "$HOSTDIR/cron.seed"; then
    ok "c4 exactly one saved crontab, identical to the seed"
else
    bad "c4 exactly one saved crontab, identical to the seed" "found $# : $*" "$(tail5)"
fi

# ---- c5 a writer that started before the request is waited for ---------------------------------
new_host c5
C5_SHA="$(push_commit c5new)"
( cd "$R" && sleep 3 && exec git pull -q --ff-only origin main ) >/dev/null 2>&1 &
SP=$!; BGPIDS+=("$SP")
W=20 run_clean
t  "c5 rc 0" rc_is
t  "c5 says waiting for" has "waiting for"
tn "c5 old history gone" has_obj "$OLD_SHA"
t  "c5 the updater's pull landed and survived the clean" head_is "$C5_SHA"
git -C "$R" fsck --full >/dev/null 2>&1; frc=$?
if [ "$frc" -eq 0 ]; then ok "c5 fsck --full clean"; else bad "c5 fsck --full clean" "fsck rc=$frc"; fi

# ---- c6 a process naming the repo on its command line counts as busy ---------------------------
new_host c6
bash -c "sleep 30; : $R" >/dev/null 2>&1 &
SP=$!; BGPIDS+=("$SP")
CLEAN_ROOT_USER=$ME W=3 run_clean
kill "$SP" 2>/dev/null
t "c6 rc != 0" rc_not
t "c6 says still busy" has "still busy"
t "c6 refs/heads/old untouched" has_ref refs/heads/old
# root's own crontab can still carry the old bare-pull form, which the hold does not gate
tn "c6 root's bare-pull line is off while the barrier stands" cron_has "git pull --ff-only"

# ---- c7 the hold stops root's updater (positive control of the barrier) -------------------------
new_host c7
printf 'x\n' > "$STATE/update-hold"; : > "$STATE/no-auto-apply"
push_commit new >/dev/null
uout=$(REPO_DIR="$R" UPDATE_STATE_DIR="$STATE" bash "$REPO/update-control.sh" --self-update 2>&1); urc=$?
if head_is "$B_SHA"; then
    ok "c7 update-control --self-update leaves HEAD alone while the hold exists"
else
    bad "c7 update-control --self-update leaves HEAD alone while the hold exists" "updater rc=$urc" "$(printf '%s\n' "$uout" | tail -5)"
fi
# the same call without the hold must move HEAD, else c7 above proves nothing
rm -f "$STATE/update-hold"
uout=$(REPO_DIR="$R" UPDATE_STATE_DIR="$STATE" bash "$REPO/update-control.sh" --self-update 2>&1); urc=$?
if ! head_is "$B_SHA"; then
    ok "c7 control: without the hold the same updater call does move HEAD"
else
    bad "c7 control: without the hold the same updater call does move HEAD" "updater rc=$urc" "$(printf '%s\n' "$uout" | tail -5)"
fi

# ---- c8 a failure mid-clean keeps the barrier and leaves the repo usable ------------------------
new_host c8
mkdir -p "$WORK/failbin"
printf '%s\n' '#!/bin/bash' \
    'for a in "$@"; do [ "$a" = gc ] && { echo "injected gc failure" >&2; exit 1; }; done' \
    'exec '"$REALGIT"' "$@"' > "$WORK/failbin/git"
chmod +x "$WORK/failbin/git"
CONF_BEFORE="$(cat "$R/jobs.h.conf") $(stat -c %a "$R/jobs.h.conf")"
PATH="$WORK/failbin:$PATH" run_clean
t  "c8 rc != 0" rc_not
t  "c8 says barrier in place" has "barrier in place"
t  "c8 update-hold exists" test -e "$STATE/update-hold"
tn "c8 pull line still removed" cron_has "git pull --ff-only"
t  "c8 HEAD is still B" head_is "$B_SHA"
"$REALGIT" -C "$R" fsck --full >/dev/null 2>&1; frc=$?
if [ "$frc" -eq 0 ]; then ok "c8 fsck --full clean after the failure"; else bad "c8 fsck --full clean after the failure" "fsck rc=$frc"; fi
if [ "$(cat "$R/jobs.h.conf") $(stat -c %a "$R/jobs.h.conf")" = "$CONF_BEFORE" ]; then
    ok "c8 host config unchanged"
else
    bad "c8 host config unchanged" "before: $CONF_BEFORE"
fi
sleep 1   # the work dir is named by the second
run_clean
t  "c8 recovery run rc 0" rc_is
t  "c8 recovery adopts the failed run's barrier" has "adopting the barrier"
t  "c8 recovery reopens the account's cron as it was before the first run" cron_same_as_seed
tn "c8 recovery removes the hold the first run created" test -e "$STATE/update-hold"
tn "c8 no barrier record is left" ls "$STATE"/clean-host-clone.*/barrier
tn "c8 old history gone after recovery" has_obj "$OLD_SHA"

# ---- c9 a leftover lock is refused untouched ------------------------------------------------------
new_host c9
touch "$R/.git/index.lock"
run_clean
rm -f "$R/.git/index.lock"
t "c9 rc != 0" rc_not
t "c9 says leftover lock" has "leftover lock"
t "c9 refs/heads/old untouched" has_ref refs/heads/old

# ---- c10 an unreachable rollback target is refused -----------------------------------------------
new_host c10
printf '%s\n' "$OLD_SHA" > "$STATE/previous-revision"
CLEAN_ROOT_USER=$ME run_clean
t "c10 rc != 0" rc_not
t "c10 says rollback target" has "rollback target"
t "c10 old object still present" has_obj "$OLD_SHA"

# ---- c11 a changed tracked file is refused -------------------------------------------------------
new_host c11
echo z >> "$R/tool.sh"
run_clean
t "c11 rc != 0" rc_not
t "c11 says tracked files changed" has "tracked files changed"
t "c11 refs/heads/old untouched" has_ref refs/heads/old

# ---- c12 a crontab that cannot be read (other than "no crontab") stops before any cleaning ------
new_host c12
: > "$WORK/cron.fail"
run_clean
rm -f "$WORK/cron.fail"
t "c12 rc != 0" rc_not
t "c12 says it cannot read the crontab" has "cannot read the crontab"
t "c12 refs/heads/old untouched" has_ref refs/heads/old

# ---- c13 a repo given through a symlink is still seen as busy -----------------------------------
new_host c13
ln -s "$R" "$HOSTDIR/link"
( cd "$R" && exec sleep 30 ) >/dev/null 2>&1 &
SP=$!; BGPIDS+=("$SP")
out=$(CLEAN_WAIT=3 CLEAN_POLL=1 bash "$SCRIPT" "$STATE" "$HOSTDIR/link" 2>&1); rc=$?
kill "$SP" 2>/dev/null
t "c13 rc != 0" rc_not
t "c13 says still busy" has "still busy"
t "c13 refs/heads/old untouched" has_ref refs/heads/old

# ---- c14 a failure while closing the entry points is still adopted by the next run ---------------
new_host c14
: > "$WORK/cron.wfail"
run_clean
rm -f "$WORK/cron.wfail"
t  "c14 rc != 0" rc_not
t  "c14 the hold it created stays" test -e "$STATE/update-hold"
t  "c14 refs/heads/old untouched" has_ref refs/heads/old
run_clean
t  "c14 recovery run rc 0" rc_is
t  "c14 recovery adopts the barrier" has "adopting the barrier"
t  "c14 crontab is the original" cron_same_as_seed
tn "c14 the hold the first run created is removed" test -e "$STATE/update-hold"

# ---- c15 fail, fail again (adopting), then succeed: the first run's state comes back -------------
new_host c15
PATH="$WORK/failbin:$PATH" run_clean
t  "c15 first run fails" rc_not
sleep 1
PATH="$WORK/failbin:$PATH" run_clean
t  "c15 second run adopts and fails" has "adopting the barrier"
sleep 1
run_clean
t  "c15 third run rc 0" rc_is
t  "c15 crontab is the original" cron_same_as_seed
tn "c15 the hold the first run created is removed" test -e "$STATE/update-hold"
tn "c15 no barrier record of any run is left" ls "$STATE"/clean-host-clone.*/barrier

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
