#!/bin/bash
# Unit tests for lib-cron.sh -- the single crontab writer.
#
# NEVER touches a real crontab. `crontab` is a stub on PATH backed by a file per
# user, so the suite can simulate an unreadable crontab, a refusing crontab(1),
# and a crontab(1) that accepts a write and stores something else -- the three
# failure shapes the library exists to survive.
#
# Runs anywhere: no root, no ZFS, no cron daemon.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Overridable so section W can be run against an older gen-cron.sh as a
# negative control. Without this the control silently exercises the CURRENT
# file and passes for the wrong reason -- which is exactly what it did the
# first time it was written.
GEN="${GEN:-$REPO/gen-cron.sh}"
LIB="${LIB:-$REPO/lib-cron.sh}"
[ -r "$LIB" ] || { echo "cannot read lib-cron.sh at $LIB" >&2; exit 1; }

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

# ---- the crontab stub -------------------------------------------------------
#
# CRONTAB_MODE steers it:
#   ok         normal
#   unreadable `-l` fails with something that is NOT "no crontab"
#   refuse     writes fail
#   liar       writes succeed but store something else (the case that makes a
#              read-back the only honest confirmation)
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

# ---- a flock(1) shim, for THIS DEV MACHINE only -----------------------------
#
# Production hosts have real flock -- deploy.sh already refuses to run without
# it (Phase 1) -- so lib-cron.sh's locking is exercised for real on every host
# it ships to. This machine's git-bash does not carry the binary, and the
# suite still has to run here.
#
# lib-cron.sh only ever calls two shapes: `flock -w SEC fd` (acquire within a
# bound) and `flock -u fd` (release). Real flock(1) locks by fd via flock(2);
# this shim resolves the fd's target path through /proc/self/fd (present here)
# and mutexes on that path with `mkdir`, which is atomic on every filesystem
# this suite runs on. Good enough to prove lib-cron.sh's acquire/release/
# timeout contract -- it is not a reimplementation of flock(2) and must never
# be mistaken for one.
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

# Lock files live inside $TMPD, not the library's real default (/run,
# falling back to /tmp): those are SHARED, system-wide paths, and a run that
# crashed without releasing (or, on this dev machine, the mkdir-based flock
# shim above, which -- unlike real flock(2) -- does not auto-release when a
# process dies) would poison every run after it. $TMPD is fresh every time and
# is removed on exit regardless of how the run ends.
mkdir -p "$TMPD/locks"
export PATH="$TMPD/bin:$PATH" CRONTAB_DIR="$TMPD/tabs" CRONTAB_MODE=ok CRON_LOCK_DIR="$TMPD/locks"

# shellcheck disable=SC1090
source "$LIB"

ME="$(id -un)"
tab() { printf '%s' "$TMPD/tabs/$ME"; }
seed() { printf '%s\n' "$@" > "$(tab)"; }
body() { printf '%s\n' "$@" > "$TMPD/body"; printf '%s' "$TMPD/body"; }
none() { rm -f "$(tab)"; }

# ---- A. the block is created, replaced and removed in place -----------------
none
cron_block_install "$ME" zfs-backup-host "$(body '0 8 * * * capacity')" "(host-level jobs)"
check "A1 install into an empty crontab: rc" "0" "$?"
check "A1 ...creates the block" \
      "# BEGIN zfs-backup-host (host-level jobs)|0 8 * * * capacity|# END zfs-backup-host" \
      "$(tr '\n' '|' < "$(tab)" | sed 's/|$//')"

cron_block_install "$ME" zfs-backup-host "$(body '0 9 * * * capacity')"
check "A2 replacing the body keeps the block in place" \
      "# BEGIN zfs-backup-host (host-level jobs)|0 9 * * * capacity|# END zfs-backup-host" \
      "$(tr '\n' '|' < "$(tab)" | sed 's/|$//')"
check "A2 ...and the original BEGIN tail is preserved, not rewritten" "1" \
      "$(grep -c 'BEGIN zfs-backup-host (host-level jobs)' "$(tab)")"

cron_block_install "$ME" zfs-backup-host "$(body '0 9 * * * capacity')"
check "A3 an identical install is a no-op" "0" "${CRON_CHANGED}"

cron_block_remove "$ME" zfs-backup-host
check "A4 remove takes the whole block" "0" "$(grep -c 'zfs-backup-host' "$(tab)")"
cron_block_remove "$ME" zfs-backup-host
check "A5 removing an absent block is success, no change" "0" "${CRON_CHANGED}"

# ---- B. everything outside the block is preserved byte for byte -------------
#
# This is the property the whole file exists for. A human's line, another
# requester's block, and a comment must all survive a write they had nothing to
# do with.
seed \
  '# a human wrote this' \
  '30 3 * * * /usr/local/bin/whatever' \
  '# BEGIN zfs-backup-managed (generated by gen-cron.sh)' \
  '1 * * * * snapsend' \
  '# END zfs-backup-managed' \
  'MAILTO=""' \
  '0 8 * * * capacity-loose'
before=$(cat "$(tab)")
cron_block_install "$ME" zfs-backup-host "$(body '0 7 * * * digest')"
check "B1 the foreign managed block is untouched" "1" \
      "$(grep -c '^1 \* \* \* \* snapsend$' "$(tab)")"
check "B2 the human's line survives" "1" "$(grep -c 'whatever' "$(tab)")"
check "B3 the loose line survives" "1" "$(grep -c 'capacity-loose' "$(tab)")"
check "B4 MAILTO survives" "1" "$(grep -c '^MAILTO' "$(tab)")"
check "B5 nothing but the new block was added" "1" \
      "$(( $(wc -l < "$(tab)") - $(printf '%s\n' "$before" | wc -l) - 2 ))"

# ...and writing the OTHER block does not disturb this one either.
cron_block_install "$ME" zfs-backup-managed "$(body '2 * * * * snapget')"
check "B6 replacing the managed block leaves the host block alone" "1" \
      "$(grep -c '0 7 \* \* \* digest' "$(tab)")"
check "B7 ...and actually replaced the managed body" "1" \
      "$(grep -c '2 \* \* \* \* snapget' "$(tab)")"
check "B8 ...without duplicating its markers" "1" \
      "$(grep -c '^# BEGIN zfs-backup-managed' "$(tab)")"

# ---- C. malformed markers are refused, never repaired -----------------------
#
# Guessing which of two BEGIN lines is "the" block silently orphans the other;
# an unpaired marker means the block's extent is unknown, so every following
# write would be a guess about where somebody else's lines start.
seed '# BEGIN zfs-backup-host' 'a' '# END zfs-backup-host' '# BEGIN zfs-backup-host' 'b' '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "C1 two blocks of the same name: refused" "1" "$?"
case "$CRON_ERR" in *"appears exactly once"*) ok "C1 ...with a reason that names the rule" ;;
  *) bad "C1 ...with a reason that names the rule" "$CRON_ERR" ;; esac
check "C2 ...and nothing was written" "2" "$(grep -c '^# BEGIN' "$(tab)")"

seed '# BEGIN zfs-backup-host' 'a'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "C3 BEGIN without END: refused" "1" "$?"
case "$CRON_ERR" in *"never closed"*) ok "C3 ...named as never closed" ;;
  *) bad "C3 ...named as never closed" "$CRON_ERR" ;; esac

seed '# END zfs-backup-host' 'a' '# BEGIN zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "C4 END before BEGIN: refused" "1" "$?"

# A body carrying its own markers would make the NEXT locate ambiguous -- i.e.
# this write would break the guard protecting the following one.
seed 'x'
cron_block_install "$ME" zfs-backup-host "$(body '# BEGIN something' '1 * * * * job')"
check "C5 a body with marker lines is refused" "1" "$?"
case "$CRON_ERR" in *ambiguous*) ok "C5 ...because the extent would become ambiguous" ;;
  *) bad "C5 ...because the extent would become ambiguous" "$CRON_ERR" ;; esac

check "C6 an invalid block name is refused" "1" \
      "$(cron_block_install "$ME" 'bad name;rm -rf' "$(body 'x')" >/dev/null 2>&1; echo $?)"

# ---- D. an unreadable crontab is not an empty one ---------------------------
#
# The distinction the whole project keeps re-learning: "there is nothing to
# preserve" and "I cannot see what I would destroy" are different answers.
seed '0 1 * * * important'
CRONTAB_MODE=unreadable
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "D1 unreadable crontab: refused" "1" "$?"
case "$CRON_ERR" in *"not an empty one"*) ok "D1 ...and says why" ;;
  *) bad "D1 ...and says why" "$CRON_ERR" ;; esac
CRONTAB_MODE=ok
check "D2 ...and the crontab was left alone" "1" "$(grep -c important "$(tab)")"

# An ABSENT crontab, though, is genuinely empty and must work.
none
CRONTAB_MODE=ok
cron_block_install "$ME" zfs-backup-host "$(body '1 * * * * first')"
check "D3 absent crontab is treated as empty, not unreadable" "0" "$?"
check "D3 ...and the block lands" "1" "$(grep -c 'first' "$(tab)")"

# ---- E. a failed write restores the prior state -----------------------------
seed '0 1 * * * important' '# BEGIN zfs-backup-host' 'old' '# END zfs-backup-host'
CRONTAB_MODE=refuse
cron_block_install "$ME" zfs-backup-host "$(body 'new')"
rc=$?
CRONTAB_MODE=ok
check "E1 a refusing crontab(1) is a failure, not a silent skip" "1" "$rc"
# ...and it is NOT the loud one. A refused write leaves the crontab untouched,
# so there is nothing to restore; announcing a failed restore for a crontab that
# was never modified is a false emergency, and the next real one gets ignored.
check "E2 ...the prior content is intact" "1" "$(grep -c '^old$' "$(tab)")"
check "E3 ...including the unrelated line" "1" "$(grep -c important "$(tab)")"
case "$CRON_ERR" in *"was not modified"*) ok "E4 ...and says the crontab was not modified" ;;
  *) bad "E4 ...and says the crontab was not modified" "$CRON_ERR" ;; esac

# ---- F. a crontab(1) that lies is caught by reading back --------------------
#
# rc=0 is not evidence that what you asked for is what is installed. Every
# incident in this project's history that mattered was found by looking at the
# result rather than at the exit code.
seed '0 1 * * * important'
CRONTAB_MODE=liar
cron_block_install "$ME" zfs-backup-host "$(body 'new')"
rc=$?
CRONTAB_MODE=ok
# Here the crontab DID change, and the restore cannot be verified either --
# which is the one case that deserves the loud exit code and leaving the prior
# content on disk for a human.
check "F1 a write that stores something else is the LOUD failure" "2" "$rc"
case "$CRON_ERR" in *"reading it back gave something else"*) ok "F2 ...named exactly" ;;
  *) bad "F2 ...named exactly" "$CRON_ERR" ;; esac

# ---- G. read and diff -------------------------------------------------------
seed '# BEGIN zfs-backup-host' '1 * * * * a' '2 * * * * b' '# END zfs-backup-host' 'tail line'
check "G1 read returns the body without markers" "1 * * * * a|2 * * * * b" \
      "$(cron_block_read "$ME" zfs-backup-host | tr '\n' '|' | sed 's/|$//')"
check "G2 reading an absent block is empty and successful" "" \
      "$(cron_block_read "$ME" no-such-block; echo -n)"
cron_block_diff "$ME" zfs-backup-host "$(body '1 * * * * a' '2 * * * * b')" >/dev/null
check "G3 diff of an identical body reports no change" "0" "$?"
d=$(cron_block_diff "$ME" zfs-backup-host "$(body '9 * * * * c')"; echo "rc=$?")
case "$d" in *"+9 * * * * c"*) ok "G4 diff shows the incoming line" ;;
  *) bad "G4 diff shows the incoming line" "$d" ;; esac
check "G5 ...and diff changes nothing" "1" "$(grep -c '1 \* \* \* \* a' "$(tab)")"

# ---- H. the shape the existing hosts already have ---------------------------
#
# Adoption must work on the crontabs that exist TODAY, markers and all:
# metropolis pve1's root crontab is two loose lines followed by a
# zfs-backup-host block whose BEGIN carries a descriptive tail.
seed \
  '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log' \
  '15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update' \
  '# BEGIN zfs-backup-host (host-level jobs kept by zfs-backup.sh -- do not hand-edit)' \
  '0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log' \
  '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body '0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log')"
check "H1 a real-world block is matched despite its descriptive BEGIN tail" "0" "$?"
check "H2 ...the tail is kept" "1" \
      "$(grep -c 'kept by zfs-backup.sh -- do not hand-edit' "$(tab)")"
check "H3 ...the loose lines are still there (adoption is a separate decision)" "2" \
      "$(grep -cE '^(0 8|15) ' "$(tab)")"

# ---- I. how a user is addressed --------------------------------------------
#
# Load-bearing, and I nearly changed it silently while unifying the writers: the
# refactor's first version addressed root with `crontab -u root`, which is more
# literal and made twelve zfsbackup assertions pass for the wrong reason -- the
# suites emulate root as an ordinary user through a stub that only knows `-l`,
# so the strict form read an empty crontab and every diff said "no change".
#
# Pinned here so the next person to find `cron_is_self` odd reads why before
#changing it.
check "I1 my own name is self" "0" "$(cron_is_self "$ME"; echo $?)"
check "I2 root counts as self (see the comment on cron_is_self)" "0"       "$(cron_is_self root; echo $?)"
check "I3 anyone else does not" "1" "$(cron_is_self somebodyelse; echo $?)"
# ...and the addressing actually reaches the stub in that form.
none
cron_block_install "$ME" zfs-backup-host "$(body '1 * * * * self')" >/dev/null
check "I4 a self write lands in this user's crontab" "1"       "$(grep -c 'self' "$TMPD/tabs/$ME")"
cron_block_install someotheruser zfs-backup-host "$(body '1 * * * * other')" >/dev/null
check "I5 another user's write goes to THEIR crontab, not mine" "1"       "$(grep -c 'other' "$TMPD/tabs/someotheruser" 2>/dev/null || echo 0)"
check "I6 ...and did not touch mine" "0"       "$(grep -c 'other' "$TMPD/tabs/$ME")"

# ---- J. ensure_line: the shape deploy.sh's four sites had ------------------
#
# "If the crontab already mentions this script leave it alone, else append" --
# but into a managed block, and moving any loose copy in instead of letting two
# schedules run side by side.
none
cron_block_ensure_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log' '(host)'
check "J1 into an empty crontab: rc" "0" "$?"
check "J1 ...the line is inside the block" "1"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'check-pool-capacity')"

# Idempotent: running deploy.sh twice must not double anything.
cron_block_ensure_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log'
check "J2 a second identical run changes nothing" "0" "$CRON_CHANGED"
check "J2 ...and there is still exactly one copy" "1" "$(grep -c 'check-pool-capacity' "$(tab)")"

# A second, different line joins the same block instead of replacing it.
cron_block_ensure_line "$ME" zfs-backup-host 'update-control.sh --self-update'     '15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update'
check "J3 a second line joins the block" "2"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -cE '^[0-9*]')"

# Changing the line's content replaces it rather than adding a variant.
cron_block_ensure_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 9 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log'
check "J4 a changed schedule replaces, not duplicates" "1" "$(grep -c 'check-pool-capacity' "$(tab)")"
check "J4 ...with the new schedule" "1" "$(grep -c '^0 9 .*check-pool-capacity' "$(tab)")"

# ---- K. adoption: the loose line is MOVED, not left to run twice ------------
#
# This is the only part of the whole unification that touches something already
# running on a live host, so it is pinned from both directions: the loose copy
# goes, an identical managed copy exists, and nothing else moves.
seed   '# a human wrote this'   '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log'   '15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update'   '30 3 * * * /usr/local/bin/something-else'   '# BEGIN zfs-backup-managed (generated by gen-cron.sh)'   '1 * * * * snapsend'   '# END zfs-backup-managed'
cron_block_ensure_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log' '(host)'
check "K1 the loose copy is reported as adopted" "1" "$CRON_ADOPTED"
check "K2 ...and there is exactly one copy left" "1" "$(grep -c 'check-pool-capacity' "$(tab)")"
check "K3 ...inside the block" "1"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'check-pool-capacity')"
check "K4 the OTHER loose line is untouched" "1"       "$(grep -c 'update-control.sh --self-update' "$(tab)")"
check "K5 ...still outside any block" "0"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'update-control')"
check "K6 the human's line survives" "1" "$(grep -c 'something-else' "$(tab)")"
check "K7 the managed block survives" "1" "$(grep -c '^1 \* \* \* \* snapsend$' "$(tab)")"

# A line that merely LOOKS similar is not adopted: the match is the caller's own
# identifying substring, so adoption can never reach further than the detection
# deploy.sh already did before appending.
seed '0 8 * * * /usr/local/bin/my-own-capacity-check.sh'
cron_block_ensure_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh'
check "K8 an unrelated line matching neither path stays put" "1"       "$(grep -c 'my-own-capacity-check' "$(tab)")"
check "K9 ...and is not inside the block" "0"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'my-own')"

# ---- L. older spellings of the same job are normalised, not stacked --------
#
# deploy.sh's updater line has had three shapes. Leaving an obsolete one next to
# the current one would run the update twice an hour, and the previous code did
# exactly that whenever a current-shaped line already existed alongside an old
# one (its own comment records the defect).
seed   '# a human wrote this'   '15 * * * * /root/scripts/zfs-snapshot-all/deploy.sh --self-update'   '15 * * * * cd /root/scripts/zfs-snapshot-all && git pull --ff-only origin main'   '30 3 * * * /usr/local/bin/keepme'
ALSO='/root/scripts/zfs-snapshot-all/deploy.sh --self-update
cd /root/scripts/zfs-snapshot-all && git pull --ff-only origin main'
cron_block_ensure_line "$ME" zfs-backup-host 'update-control.sh --self-update'     '15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update' '(host)' "$ALSO"
check "L1 both obsolete shapes are adopted away" "2" "$CRON_ADOPTED"
check "L2 ...leaving exactly one updater line" "1"       "$(grep -cE 'self-update|git pull --ff-only' "$(tab)")"
check "L3 ...the current one" "1" "$(grep -c 'update-control.sh --self-update' "$(tab)")"
check "L4 ...inside the block" "1"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'update-control')"
check "L5 the human's line is untouched" "1" "$(grep -c keepme "$(tab)")"

# ---- M. adopt keeps a hand-tuned line's text --------------------------------
#
# "already present, leaving it alone" is a promise deploy.sh makes today, and
# moving a line into the block must not quietly break it. An operator who
# changed 08:00 to 06:00 keeps 06:00; only the line's LOCATION changes.
seed '0 6 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log'
cron_block_adopt_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log' '(host)'
check "M1 the hand-tuned schedule survives adoption" "1" "$(grep -c '^0 6 ' "$(tab)")"
check "M2 ...and the default did NOT overwrite it" "0" "$(grep -c '^0 8 ' "$(tab)")"
check "M3 ...but it now lives in the block" "1"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$(tab)" | grep -c 'check-pool-capacity')"
check "M4 ...and only once" "1" "$(grep -c 'check-pool-capacity' "$(tab)")"

# With nothing to adopt, the default is what gets installed.
none
cron_block_adopt_line "$ME" zfs-backup-host '/root/scripts/check-pool-capacity.sh'     '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log' '(host)'
check "M5 with nothing present, the default is used" "1" "$(grep -c '^0 8 ' "$(tab)")"

# ---- N. a shared block is never rebuilt from one requester's list ----------
#
# REV-20260802-034 F1. The host block has more than one requester: deploy.sh
# puts the updater, the capacity check and the account auto-pull there, while
# zfs-backup.sh's migration carries only what it rescued from the managed block.
# Handing that partial list over as the whole body deleted the rest -- silently,
# with the migration reporting success.
cat > "$TMPD/rescued" <<'EOT'
0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log
EOT
seed   '# BEGIN zfs-backup-host (host-level jobs kept by zfs-backup.sh -- do not hand-edit)'   '15 * * * * /root/.zfs-snapshot-all-update-state/update-control.sh --self-update'   '0 8 * * * /root/scripts/check-pool-capacity.sh 2>>/root/scripts/cron.log'   '# END zfs-backup-host'   '# BEGIN zfs-backup-managed (generated by gen-cron.sh)'   '1 * * * * snapsend'   '# END zfs-backup-managed'
cron_block_merge_render "$(tab)" zfs-backup-host "$TMPD/rescued" "$TMPD/merged" '(host)'
check "N1 merge render: rc" "0" "$?"
check "N2 the other requester's updater line survives" "1"       "$(grep -c 'update-control.sh --self-update' "$TMPD/merged")"
check "N3 ...and its capacity line" "1" "$(grep -c 'check-pool-capacity' "$TMPD/merged")"
check "N4 the rescued line is added" "1" "$(grep -c 'alert-digest' "$TMPD/merged")"
check "N5 three lines in the block, no more" "3"       "$(sed -n '/^# BEGIN zfs-backup-host/,/^# END zfs-backup-host/p' "$TMPD/merged" | grep -cE '^[0-9*]')"
check "N6 the managed block is untouched" "1" "$(grep -c '^1 \* \* \* \* snapsend$' "$TMPD/merged")"

# Repeating it converges rather than accumulating.
cp "$TMPD/merged" "$TMPD/again.in"
cron_block_merge_render "$TMPD/again.in" zfs-backup-host "$TMPD/rescued" "$TMPD/again" '(host)'
check "N7 a repeated merge is idempotent" "0"       "$(diff -q "$TMPD/merged" "$TMPD/again" >/dev/null; echo $?)"

# "I have nothing to add" must not mean "this block should go".
: > "$TMPD/empty"
cron_block_merge_render "$TMPD/merged" zfs-backup-host "$TMPD/empty" "$TMPD/noadd" '(host)'
check "N8 an empty contribution leaves the block alone" "0"       "$(diff -q "$TMPD/merged" "$TMPD/noadd" >/dev/null; echo $?)"

# ...and with no block and nothing to add, nothing is invented.
seed '0 1 * * * unrelated'
cron_block_merge_render "$(tab)" zfs-backup-host "$TMPD/empty" "$TMPD/none" '(host)'
check "N9 no block and nothing to add creates no block" "0"       "$(grep -c 'BEGIN zfs-backup-host' "$TMPD/none")"

# ---- O. the marker layout is checked GLOBALLY, not per name ----------------
#
# REV-20260802-034 F4. Counting only the requested name accepts a foreign block
# nested inside the target's extent, and replacing the target then deletes it
# whole -- with the write reporting success, because the result is internally
# consistent for the target name alone.
seed   '# BEGIN zfs-backup-host'   '0 8 * * * capacity'   '# BEGIN zfs-backup-managed'   '1 * * * * snapsend'   '# END zfs-backup-managed'   '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O1 a foreign block nested in the target: refused" "1" "$?"
case "$CRON_ERR" in *"may not nest or overlap"*) ok "O2 ...named as nesting" ;;
  *) bad "O2 ...named as nesting" "$CRON_ERR" ;; esac
check "O3 ...and the nested block is still there" "1" "$(grep -c 'snapsend' "$(tab)")"

seed   '# BEGIN zfs-backup-host'   '# BEGIN zfs-backup-managed'   '# END zfs-backup-host'   '# END zfs-backup-managed'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O4 interleaved markers: refused" "1" "$?"
# Caught by the nesting rule, because the second BEGIN opens while the first is
# still open -- interleaving IS an overlap. The dedicated mismatch message is
# reachable by the other shape, below.
case "$CRON_ERR" in *"nest or overlap"*) ok "O5 ...named as an overlap" ;;
  *) bad "O5 ...named as an overlap" "$CRON_ERR" ;; esac
seed '# BEGIN zfs-backup-host' 'a' '# END zfs-backup-managed'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O5b closing the wrong block: refused" "1" "$?"
case "$CRON_ERR" in *"closes while"*) ok "O5c ...named as a mismatch" ;;
  *) bad "O5c ...named as a mismatch" "$CRON_ERR" ;; esac

# An orphan belonging to somebody ELSE must stop this block's write too: the
# extent of every later write is a guess once a marker is unpaired.
seed '# END zfs-backup-managed' '# BEGIN zfs-backup-host' 'a' '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O6 a foreign orphan END: refused" "1" "$?"
seed '# BEGIN zfs-backup-managed' '# BEGIN zfs-backup-host' 'a' '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O7 a foreign block left open: refused" "1" "$?"

# Two blocks of the same FOREIGN name are equally fatal -- the guarantee is
# about the layout, not about whose block is being written.
seed   '# BEGIN zfs-backup-managed' 'a' '# END zfs-backup-managed'   '# BEGIN zfs-backup-managed' 'b' '# END zfs-backup-managed'   '# BEGIN zfs-backup-host' 'c' '# END zfs-backup-host'
cron_block_install "$ME" zfs-backup-host "$(body 'x')"
check "O8 a duplicated foreign block: refused" "1" "$?"

# ...and the ordinary shape -- several adjacent named blocks -- still works.
seed   '0 1 * * * loose-but-human'   '# BEGIN zfs-backup-host' '0 8 * * * capacity' '# END zfs-backup-host'   '# BEGIN zfs-backup-managed' '1 * * * * snapsend' '# END zfs-backup-managed'
cron_block_install "$ME" zfs-backup-host "$(body '0 8 * * * capacity' '0 7 * * * digest')"
check "O9 adjacent blocks are normal and still accepted" "0" "$?"
check "O10 ...the other block survives" "1" "$(grep -c 'snapsend' "$(tab)")"
check "O11 ...and the human's line" "1" "$(grep -c 'loose-but-human' "$(tab)")"

# ---- P. serialization: concurrent writers to the SAME crontab -----------------
#
# REV-20260802-034 F2. Read-back proves THIS write landed; it cannot prove
# nothing was lost between the read and the write. Without a shared lock, two
# processes can each read the same starting crontab and each write back a
# result that is individually correct and read-back-verified, and the SECOND
# write still erases the first's change. This is the exact race the
# single-writer refactor exists to remove, and giving it a second writer
# without a shared lock just gave the race a narrower door.
#
# The interleaving is FORCED with a barrier (mkdir/files, atomic everywhere
# this suite runs), not raced by timing: process A acquires the lock, signals
# it is INSIDE the critical section, waits for a go-ahead, then writes;
# process B is started only once A has confirmed it holds the lock, so B's
# acquire is a real, provable contention rather than a hopeful race.
seed '# untouched' '1 * * * * preexisting'
BARRIER_HELD="$TMPD/barrier-held"; BARRIER_GO="$TMPD/barrier-go"
rm -f "$BARRIER_HELD" "$BARRIER_GO"

cat > "$TMPD/writer_a.sh" <<WRITERA
#!/bin/bash
PATH="$TMPD/bin:\$PATH"
CRONTAB_DIR="$TMPD/tabs" CRON_LOCK_DIR="$TMPD/locks"
export PATH CRONTAB_DIR CRON_LOCK_DIR
source "$REPO/lib-cron.sh"
cron_lock_acquire "$ME" || { echo "A-ACQUIRE-FAILED" > "$TMPD/a-result"; exit 1; }
: > "$BARRIER_HELD"
while [ ! -e "$BARRIER_GO" ]; do sleep 0.05; done
# Do the write WHILE still holding the lock -- if B's acquire below is not
# really blocked, this sleep is where its write would land in between.
sleep 0.3
tmp=\$(mktemp)
printf '%s\n' '# untouched' '1 * * * * preexisting' '2 * * * * from-A' > "\$tmp"
cron_write "$ME" "\$tmp"
rm -f "\$tmp"
cron_lock_release "$ME"
echo "A-DONE" > "$TMPD/a-result"
WRITERA
chmod +x "$TMPD/writer_a.sh"

cat > "$TMPD/writer_b.sh" <<WRITERB
#!/bin/bash
PATH="$TMPD/bin:\$PATH"
CRONTAB_DIR="$TMPD/tabs" CRON_LOCK_DIR="$TMPD/locks"
export PATH CRONTAB_DIR CRON_LOCK_DIR
source "$REPO/lib-cron.sh"
start=\$(date +%s)
cron_block_install "$ME" zfs-backup-managed "$TMPD/b-body" >/dev/null 2>&1
end=\$(date +%s)
echo "\$((end-start))" > "$TMPD/b-wait-seconds"
echo "B-DONE" > "$TMPD/b-result"
WRITERB
chmod +x "$TMPD/writer_b.sh"
printf '3 * * * * from-B\n' > "$TMPD/b-body"

bash "$TMPD/writer_a.sh" &
apid=$!
while [ ! -e "$BARRIER_HELD" ]; do sleep 0.05; done
# A provably holds the lock now. Start B, THEN release A -- so B's
# cron_block_install has to sit through A's write, not merely start near it.
bash "$TMPD/writer_b.sh" &
bpid=$!
sleep 0.2
: > "$BARRIER_GO"
wait "$apid" "$bpid" 2>/dev/null

check "P1 writer A completed" "A-DONE" "$(cat "$TMPD/a-result" 2>/dev/null)"
check "P2 writer B completed" "B-DONE" "$(cat "$TMPD/b-result" 2>/dev/null)"
# The property the review asked for: BOTH survive. A's line into the host
# block and B's own managed block must both be present -- neither writer's
# read-modify-write window overlapped the other's.
check "P3 A's line survived" "1" "$(grep -c 'from-A' "$(tab)")"
check "P4 B's block survived" "1" "$(grep -c 'from-B' "$(tab)")"
check "P5 the line that predates both writers survived" "1" "$(grep -c 'preexisting' "$(tab)")"

# ---- Q. lock contention: a clear diagnostic, no write, no hang -------------
#
# Non-blocking with a bounded wait, then a clear diagnostic and NO write --
# never a silent, unbounded hang, and never a write that skipped the queue.
rm -f "$BARRIER_HELD" "$BARRIER_GO"
cat > "$TMPD/holder.sh" <<HOLDER
#!/bin/bash
PATH="$TMPD/bin:\$PATH"
CRON_LOCK_DIR="$TMPD/locks"
export PATH CRON_LOCK_DIR
source "$REPO/lib-cron.sh"
cron_lock_acquire heldsvc || exit 1
: > "$BARRIER_HELD"
while [ ! -e "$BARRIER_GO" ]; do sleep 0.05; done
cron_lock_release heldsvc
HOLDER
chmod +x "$TMPD/holder.sh"
bash "$TMPD/holder.sh" &
hpid=$!
while [ ! -e "$BARRIER_HELD" ]; do sleep 0.05; done
CRON_LOCK_TIMEOUT=1 cron_lock_acquire heldsvc
rc=$?
err="$CRON_ERR"
: > "$BARRIER_GO"
wait "$hpid" 2>/dev/null
check "Q1 a held lock refuses within its bounded timeout" "1" "$rc"
case "$err" in *"another writer is holding it"*) ok "Q2 ...with a diagnostic naming contention, not a generic failure" ;;
  *) bad "Q2 ...with a diagnostic naming contention, not a generic failure" "$err" ;; esac
cron_lock_release heldsvc 2>/dev/null

# ---- R. two DIFFERENT users proceed independently ---------------------------
#
# The lock is keyed by target user, so writes to unrelated crontabs never wait
# on each other -- serializing everyone against everyone would just trade one
# race for a different bottleneck.
rm -f "$BARRIER_HELD" "$BARRIER_GO"
bash "$TMPD/holder.sh" &
hpid=$!
while [ ! -e "$BARRIER_HELD" ]; do sleep 0.05; done
t0=$(date +%s%N)
cron_lock_acquire otheruser
rc=$?
t1=$(date +%s%N)
: > "$BARRIER_GO"
wait "$hpid" 2>/dev/null
cron_lock_release otheruser 2>/dev/null
check "R1 a different user's lock is unaffected: acquired" "0" "$rc"
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 2000 ]; then ok "R2 ...and immediately, not after waiting for the other user's lock"
else bad "R2 ...and immediately, not after waiting for the other user's lock" "${ms}ms"; fi

# ---- S. multi-user acquisition is deadlock-free by construction ------------
#
# Two users, taken in a DETERMINISTIC order (sorted by name) regardless of the
# order they are named in -- so a transaction naming (root, zzz) and one
# naming (zzz, root) can never form a cycle.
cron_lock_acquire_multi zzz-user aaa-user
check "S1 acquiring in reverse name order still succeeds" "0" "$?"
h1=$([ -n "${CRON_LOCK_FD[zzz-user]:-}" ] && echo held || echo NO)
h2=$([ -n "${CRON_LOCK_FD[aaa-user]:-}" ] && echo held || echo NO)
check "S2 both are actually held" "held held" "$h1 $h2"
cron_lock_release_multi zzz-user aaa-user
h1=$([ -n "${CRON_LOCK_FD[zzz-user]:-}" ] && echo 1 || echo 0)
h2=$([ -n "${CRON_LOCK_FD[aaa-user]:-}" ] && echo 1 || echo 0)
check "S3 both are released" "0 0" "$h1 $h2"

# A failed acquisition midway releases whatever it already got -- no partial
# hold left behind for the caller to leak.
rm -f "$BARRIER_HELD" "$BARRIER_GO"
cat > "$TMPD/holder2.sh" <<HOLDER2
#!/bin/bash
PATH="$TMPD/bin:\$PATH"
CRON_LOCK_DIR="$TMPD/locks"
export PATH CRON_LOCK_DIR
source "$REPO/lib-cron.sh"
cron_lock_acquire bbb-user || exit 1
: > "$BARRIER_HELD"
while [ ! -e "$BARRIER_GO" ]; do sleep 0.05; done
cron_lock_release bbb-user
HOLDER2
chmod +x "$TMPD/holder2.sh"
bash "$TMPD/holder2.sh" &
hpid=$!
while [ ! -e "$BARRIER_HELD" ]; do sleep 0.05; done
CRON_LOCK_TIMEOUT=1 cron_lock_acquire_multi aaa-user bbb-user
rc=$?
: > "$BARRIER_GO"
wait "$hpid" 2>/dev/null
check "S4 a multi-lock that cannot complete: refused" "1" "$rc"
h1=$([ -n "${CRON_LOCK_FD[aaa-user]:-}" ] && echo 1 || echo 0)
check "S5 ...and the one it DID get is released, not leaked" "0" "$h1"

# ---- T. cron_replace_all: the whole-crontab primitive -----------------------
#
# Some intermediate states are not one named block -- e.g. "a whole crontab
# minus one collector block" -- so the tool needs a primitive that replaces
# everything, still through the shared lock and the shared read-back, and
# still refusing a target whose markers are malformed (F4): installing an
# already-broken layout would make the FIRST ordinary block write after it
# guess where somebody else's lines start.
seed '# old content' '1 * * * * old-job'
printf '%s\n' '# new content' '2 * * * * new-job' > "$TMPD/replace-in"
cron_replace_all "$ME" "$TMPD/replace-in"
check "T1 rc" "0" "$?"
check "T2 the crontab is exactly the given file" "0" \
      "$(diff -q "$TMPD/replace-in" "$(tab)" >/dev/null; echo $?)"

# Read-back still catches a lying crontab(1) -- this primitive is not a
# shortcut around the write/read-back path, it is the same path.
CRONTAB_MODE=liar
printf '%s\n' '3 * * * * liar-job' > "$TMPD/replace-in2"
cron_replace_all "$ME" "$TMPD/replace-in2"
rc=$?
CRONTAB_MODE=ok
check "T3 a write that stores something else is a failure" "1" "$rc"
case "$CRON_ERR" in *"reading it back gave something else"*) ok "T4 ...named exactly" ;;
  *) bad "T4 ...named exactly" "$CRON_ERR" ;; esac

# F4's guarantee extends here: a target crontab with malformed markers is
# refused rather than installed, because the NEXT ordinary block write would
# inherit a layout it cannot safely reason about.
printf '%s\n' '# BEGIN zfs-backup-host' 'a' '# BEGIN zfs-backup-managed' 'b' '# END zfs-backup-managed' > "$TMPD/replace-bad"
before=$(cat "$(tab)")
cron_replace_all "$ME" "$TMPD/replace-bad"
check "T5 a target with malformed markers is refused" "1" "$?"
case "$CRON_ERR" in *"nest or overlap"*) ok "T6 ...named as a marker problem" ;;
  *) bad "T6 ...named as a marker problem" "$CRON_ERR" ;; esac
check "T7 ...and nothing was written" "0" \
      "$(diff -q <(printf '%s\n' "$before") "$(tab)" >/dev/null; echo $?)"

# An unreadable source file is refused before anything is touched.
before=$(cat "$(tab)")
cron_replace_all "$ME" "$TMPD/does-not-exist"
check "T8 an unreadable source file is refused" "1" "$?"
check "T9 ...and the crontab is untouched" "0" \
      "$(diff -q <(printf '%s\n' "$before") "$(tab)" >/dev/null; echo $?)"

# ---- U. the lock path is a pure function of the target user, never of the
# caller's identity or environment (REV-20260803-035) --------------------------
#
# F2's own contention tests above (P/Q/R/S) all pass CRON_LOCK_DIR identically
# to both sides of the test, so none of them could have caught this: the OLD
# default was `${CRON_LOCK_DIR:-/run}`, falling back to $TMPDIR/tmp if /run
# was not WRITABLE. Root can create files under /run; a delegated account
# normally cannot -- so in production root locked
# /run/lib-cron.<user>.lock while the account's own gen-cron.sh, writing the
# SAME user's crontab, locked /tmp/lib-cron.<user>.lock. Two different lock
# objects guarding one crontab is not a lock; it silently reopened the exact
# F2 race this file exists to close.
#
# The fix removes the fallback entirely: one fixed, deploy-managed directory
# (2775 root:zfsalert, same treatment as ALERT_SHARED_DIR), and a caller that
# cannot use it refuses rather than choosing a different namespace nobody
# else would share.

# U1: the old writability-based auto-switch is gone from the source, not just
# bypassed by whatever CRON_LOCK_DIR a test happens to export.
if grep -qE '\[ -d "\$CRON_LOCK_DIR" \] && \[ -w "\$CRON_LOCK_DIR" \] \|\|' "$REPO/lib-cron.sh"; then
    bad "U1 no caller-local writability fallback left in the lock directory" "the old auto-switch pattern is still present in lib-cron.sh"
else
    ok "U1 no caller-local writability fallback left in the lock directory"
fi

# U2: with CRON_LOCK_DIR left unset (the real default, a fixed absolute path),
# two callers that differ in every other way a real root-vs-account split
# would differ -- TMPDIR, HOME -- resolve the IDENTICAL lock path for the
# same target user. This is what the old code got wrong: the path depended on
# who was asking. cron_lock_path is a pure string function, so this is safe
# to check without touching the real filesystem.
out1=$(env -u CRON_LOCK_DIR TMPDIR="$TMPD/caller-one-tmp" HOME="$TMPD/caller-one-home" \
    bash -c "source '$REPO/lib-cron.sh'; cron_lock_path zfsbackup")
out2=$(env -u CRON_LOCK_DIR TMPDIR="$TMPD/caller-two-tmp" HOME="$TMPD/caller-two-home" \
    bash -c "source '$REPO/lib-cron.sh'; cron_lock_path zfsbackup")
check "U2 two callers with different TMPDIR/HOME resolve the SAME lock path" "$out1" "$out2"
case "$out1" in
    /var/lib/zfs-snapshot-all/locks/*) ok "U2b ...and it is the fixed, deploy-managed path, not a per-caller guess" ;;
    *) bad "U2b ...and it is the fixed, deploy-managed path, not a per-caller guess" "$out1" ;;
esac

# U3: a canonical directory that exists but is not writable refuses --
# fails closed -- rather than silently falling back to $TMPDIR or /tmp. If
# the fallback ever came back, this is the assertion that would catch it: a
# lock acquired here would land in $TMPDIR instead of failing.
UNWRITABLE_LOCKS="$TMPD/unwritable-locks"
mkdir -p "$UNWRITABLE_LOCKS"
chmod 555 "$UNWRITABLE_LOCKS" 2>/dev/null || true
if [ -w "$UNWRITABLE_LOCKS" ]; then
    echo "SKIP U3 this filesystem ignores 0555 for the owner -- verify on Linux"
else
    fallback_tmpdir="$TMPD/would-be-fallback"; mkdir -p "$fallback_tmpdir"
    out=$(CRON_LOCK_DIR="$UNWRITABLE_LOCKS" TMPDIR="$fallback_tmpdir" bash -c "
        source '$REPO/lib-cron.sh'
        cron_lock_acquire someuser
        echo \"rc=\$? err=\$CRON_ERR\"
    ")
    case "$out" in rc=1*) ok "U3 an unwritable canonical directory refuses (fails closed)" ;;
      *) bad "U3 an unwritable canonical directory refuses (fails closed)" "$out" ;; esac
    case "$out" in *"missing or not writable"*) ok "U3b ...with a diagnostic naming the real problem" ;;
      *) bad "U3b ...with a diagnostic naming the real problem" "$out" ;; esac
    if [ -z "$(find "$fallback_tmpdir" -type f 2>/dev/null)" ]; then
        ok "U3c ...and nothing was created in \$TMPDIR as a silent fallback"
    else
        bad "U3c ...and nothing was created in \$TMPDIR as a silent fallback" "$(find "$fallback_tmpdir" -type f)"
    fi
fi
chmod 755 "$UNWRITABLE_LOCKS" 2>/dev/null || true

# U4: a symlink pre-planted at the exact, predictable lock path is refused,
# not followed -- the directory is shared by more than one identity, so an
# unlocked target here is the classic /tmp-style attack surface.
SYMLINK_LOCKS="$TMPD/symlink-locks"; mkdir -p "$SYMLINK_LOCKS"
SYMLINK_TARGET="$TMPD/should-not-be-touched"
: > "$SYMLINK_TARGET"
ln -sf "$SYMLINK_TARGET" "$SYMLINK_LOCKS/lib-cron.symuser.lock" 2>/dev/null
if [ ! -L "$SYMLINK_LOCKS/lib-cron.symuser.lock" ]; then
    echo "SKIP U5 this environment cannot create a real symlink without elevation (Windows/MSYS without Developer Mode) -- verify on Linux"
    echo "SKIP U5b (same reason)"
    echo "SKIP U5c (same reason)"
else
    out=$(CRON_LOCK_DIR="$SYMLINK_LOCKS" bash -c "
        source '$REPO/lib-cron.sh'
        cron_lock_acquire symuser
        echo \"rc=\$? err=\$CRON_ERR\"
    ")
    case "$out" in rc=1*) ok "U5 a symlink at the lock path is refused" ;;
      *) bad "U5 a symlink at the lock path is refused" "$out" ;; esac
    case "$out" in *"symlink"*) ok "U5b ...named as a symlink, not a generic failure" ;;
      *) bad "U5b ...named as a symlink, not a generic failure" "$out" ;; esac
    check "U5c ...and the symlink's target is untouched" "" "$(cat "$SYMLINK_TARGET")"
fi

# ---- V. the lock FILE is shareable across the identities that share the ----
# lock DIRECTORY (found live, metropolis pve1 2026-08-06) ----------------------
#
# U fixed the lock PATH; this is the same failure one level down. The file is
# created with the CALLER's umask, and root gets there first on a fresh host
# (deploy/activate-client take the ACCOUNT's lock as root) -- a 0644
# root-owned lock file then permanently refuses the account's OWN crontab
# writes. Two identities sharing one lock object need the object itself
# group-writable; the setgid 2775 zfsalert directory already decides WHO.

# V1: acquisition leaves the lock file group-writable even under a 022 umask.
V_LOCKS="$TMPD/v-locks"; mkdir -p "$V_LOCKS"
: > "$V_LOCKS/.probe"; chmod 664 "$V_LOCKS/.probe" 2>/dev/null
probe_perms=$(stat -c '%a' "$V_LOCKS/.probe" 2>/dev/null || stat -f '%Lp' "$V_LOCKS/.probe" 2>/dev/null)
if [ "$probe_perms" != "664" ]; then
    echo "SKIP V1 this filesystem cannot represent 664 (probe shows $probe_perms) -- verify on Linux"
else
( umask 022
  CRON_LOCK_DIR="$V_LOCKS" bash -c "
    source '$REPO/lib-cron.sh'
    CRON_LOCK_DIR='$V_LOCKS'
    cron_lock_acquire vuser && cron_lock_release vuser" )
perms=$(stat -c '%a' "$V_LOCKS/lib-cron.vuser.lock" 2>/dev/null || stat -f '%Lp' "$V_LOCKS/lib-cron.vuser.lock" 2>/dev/null)
check "V1 the lock file ends group-writable under a 022 umask" "664" "$perms"
fi

# V2: a pre-fix foreign 0644-style file (simulated: unwritable) refuses with
# the one-line fix in the message, instead of a bare "could not open".
V2F="$V_LOCKS/lib-cron.v2user.lock"
: > "$V2F"; chmod 444 "$V2F" 2>/dev/null || true
if [ -w "$V2F" ]; then
    echo "SKIP V2 this filesystem ignores 0444 for the owner -- verify on Linux"
else
    out=$(CRON_LOCK_DIR="$V_LOCKS" bash -c "
        source '$REPO/lib-cron.sh'
        CRON_LOCK_DIR='$V_LOCKS'
        if cron_lock_acquire v2user; then echo ACQUIRED; else printf '%s' \"\$CRON_ERR\"; fi")
    case "$out" in
        ACQUIRED) bad "V2 an unwritable existing lock file refuses" "acquired through a file this identity cannot write" ;;
        *"chmod 664"*) ok "V2 an unwritable existing lock file refuses and names the chmod 664 fix" ;;
        *) bad "V2 an unwritable existing lock file refuses and names the chmod 664 fix" "$out" ;;
    esac
fi

echo "--------------------------------------------"
# ---- W. gen-cron.sh's OWN install lock lives where the account can reach it --
#
# Found live on pve0 2026-08-07 while bringing its uncovered guests under
# backup: `gen-cron.sh --install` defaulted its lock to /var/run, which is
# root-only -- and the managed block belongs to the DELEGATED ACCOUNT. So the
# one identity that owns what --install installs could not run it, and a single
# earlier root-side run left a 0644 root-owned file there that locked the
# account out permanently.
#
# Section V fixed the same shape for lib-cron's per-user lock. This is
# gen-cron's own, which V does not touch.
W_LOCKS="$TMPD/w-locks"; mkdir -p "$W_LOCKS" "$TMPD/w-tabs"
cat > "$TMPD/w.conf" <<'EOF'
[defaults]
	host_label = w
[template:hourly]
	send_schedule = 7 * * * *
	prefix        = automated_
[dataset:tank/w]
	use_template = hourly
EOF

# W1: with no override, the lock is created in the SHARED directory -- not in
# /var/run, and not in some per-caller path another writer would never look at.
out=$(CRONTAB_DIR="$TMPD/w-tabs" CRON_LOCK_DIR="$W_LOCKS"       REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L       "$GEN" -c "$TMPD/w.conf" --install 2>&1)
if [ -e "$W_LOCKS/gen-cron.install.lock" ]; then
    ok "W1 the install lock is created in the shared lock directory"
else
    bad "W1 the install lock is created in the shared lock directory" "$out"
fi

# W2: an existing lock this identity cannot write must say so, and must NOT
# claim another --install is running. That message sent me looking for a
# process that did not exist.
W2F="$W_LOCKS/gen-cron.install.lock"
: > "$W2F"; chmod 444 "$W2F" 2>/dev/null || true
if [ -w "$W2F" ]; then
    echo "SKIP W2 this filesystem ignores 0444 for the owner -- verify on Linux"
else
    out=$(CRONTAB_DIR="$TMPD/w-tabs" CRON_LOCK_DIR="$W_LOCKS"           REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L           "$GEN" -c "$TMPD/w.conf" --install 2>&1)
    case "$out" in
        *"already running"*) bad "W2 an unwritable lock does not claim a run is in progress" "$out" ;;
        *"chmod 664"*)       ok  "W2 an unwritable lock refuses and names the chmod 664 fix" ;;
        *)                   bad "W2 an unwritable lock refuses and names the chmod 664 fix" "$out" ;;
    esac
    chmod 664 "$W2F" 2>/dev/null || true
fi

# W4: real contention must still be refused -- the point of relaxing WHERE the
# lock lives is not to relax WHETHER it locks. A second run while the first
# holds it has to fail closed, and this time "already running" IS the truth.
W4H="$TMPD/w4.holder"
( exec 9>"$W_LOCKS/gen-cron.install.lock"; flock -n 9 && sleep 6 ) & W4PID=$!
sleep 1
out=$(CRONTAB_DIR="$TMPD/w-tabs" CRON_LOCK_DIR="$W_LOCKS"       REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L       "$GEN" -c "$TMPD/w.conf" --install 2>&1); rc=$?
wait $W4PID 2>/dev/null
if [ "$rc" -eq 0 ]; then
    bad "W4 a genuinely held lock refuses" "the second --install succeeded while the lock was held"
else
    case "$out" in
        *"already running"*) ok "W4 a genuinely held lock refuses, and here 'already running' is true" ;;
        *) bad "W4 a genuinely held lock refuses, and here 'already running' is true" "$out" ;;
    esac
fi

# W5: the override still works. It is a test/operator escape hatch, not the
# thing normal delegated operation depends on -- W1 already proved the default
# is usable, so this only pins that the hatch did not rot shut.
W5F="$TMPD/w5-elsewhere.lock"
out=$(CRONTAB_DIR="$TMPD/w-tabs" CRON_LOCK_DIR="$W_LOCKS" GEN_CRON_LOCKFILE="$W5F"       REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L       "$GEN" -c "$TMPD/w.conf" --install 2>&1)
if [ -e "$W5F" ]; then ok "W5 GEN_CRON_LOCKFILE still overrides the default"
else bad "W5 GEN_CRON_LOCKFILE still overrides the default" "$out"; fi

# W3: a missing shared directory refuses and points at deploy.sh, rather than
# silently locking somewhere else.
out=$(CRONTAB_DIR="$TMPD/w-tabs" CRON_LOCK_DIR="$TMPD/w-absent"       REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L       "$GEN" -c "$TMPD/w.conf" --install 2>&1)
case "$out" in
    *"missing or not writable"*) ok "W3 a missing lock directory refuses and names deploy.sh" ;;
    *) bad "W3 a missing lock directory refuses and names deploy.sh" "$out" ;;
esac

# ---- X. the emitted job line witnesses its own run --------------------------
#
# Found live 2026-08-17. On 2026-08-09 pve2's weekly job for CT 103 fired and
# left NO trace in ANY of this project's three instruments at once: nothing in
# cron.log, no record in the stats log (so it never reached emit_stats, which
# fires even for skipped_lock/skipped_paused), and no failure mail (rc was never
# non-zero). The dataset went 14 days without a weekly copy; check-snap-age
# going CRITICAL five days later was the only reason anyone found out.
#
# Every instrument lives INSIDE the engine, so a run that dies before the engine
# starts is invisible to all of them simultaneously. Only the cron line itself
# can witness that, which is what section X pins.

X_CONF="$TMPD/x.conf"
cat > "$X_CONF" <<'EOF'
[defaults]
	host_label = x
[template:hourly]
	send_schedule  = 7 * * * *
	prefix         = automated_
	prune_schedule = 9 * * * *
	pattern        = automated_
	retain         = -H24
	tier_label     = hourly
	monitor_warn   = 90m
	monitor_crit   = 3h
[dataset:tank/x]
	use_template = hourly
EOF

X_OUT=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L \
        "$GEN" -c "$X_CONF" 2>/dev/null)

# X0: this config emits exactly two engine lines (one backup, one prune). Pinned
# as a LITERAL, because every other assertion in this section is a count and a
# count of nothing satisfies most of them: an empty $X_OUT has no missing
# markers, no bare mktemp and no stray '%', so X1/X4/X5 all go green while
# proving nothing whatsoever. That is not hypothetical -- running section X
# against an older gen-cron.sh through $GEN did exactly this, and the four
# spurious passes looked identical to real ones.
x_jobs=$(printf '%s\n' "$X_OUT" | grep -cE '(snapsend|snapget|delsnaps)\.sh')
check "X0 the probe config really did emit its engine lines" "2" "$x_jobs"

# X1: every line that RUNS an engine carries both markers. Counted, not grepped
# for presence: a single marker on one of two job lines would pass a presence
# check and still leave the other mute.
x_begin=$(printf '%s\n' "$X_OUT" | grep -c 'ZFS-JOB BEGIN')
x_end=$(printf '%s\n' "$X_OUT" | grep -c 'ZFS-JOB END')
check "X1 every engine job line records BEGIN and END" \
      "jobs=2 begin=2 end=2" \
      "jobs=$x_jobs begin=$x_begin end=$x_end"

# X2: the END marker carries the exit code. Without rc the marker proves the
# line finished but not whether the backup did anything.
case "$X_OUT" in
    *'ZFS-JOB END x hourly backup rc=$rc'*) ok "X2 the END marker carries the exit code" ;;
    *) bad "X2 the END marker carries the exit code" "no 'END ... rc=\$rc' in the emitted block" ;;
esac

# X3: the monitor line is deliberately NOT marked. It runs every 15 minutes and
# already reports its own state through the rc arms; marking it would add ~192
# lines a day per dataset to cron.log and drown the signal X1 exists to give.
x_mon=$(printf '%s\n' "$X_OUT" | grep 'check-snap-age' | grep -c 'ZFS-JOB')
check "X3 the monitor line is deliberately left unmarked" "0" "$x_mon"

# X4: no bare `e=$(mktemp);`. When mktemp fails that leaves $e EMPTY, an empty
# redirect target makes `2>"$e"` fail, and a failed redirection means the engine
# never runs at all -- silently. That is a mechanism which reproduces the
# 2026-08-09 signature exactly (proved in X6 below).
case "$X_OUT" in
    *'e=$(mktemp);'*) bad "X4 mktemp failure cannot silently swallow the run" "bare 'e=\$(mktemp);' is back" ;;
    *) ok "X4 mktemp failure cannot silently swallow the run" ;;
esac

# X5: no unescaped '%' anywhere in the block. cron reads '%' as end-of-command
# plus stdin, so one stray format string truncates the job it appears in -- and
# the truncated line still installs cleanly and still looks right in `crontab -l`
# to anyone not counting characters.
x_pct=$(printf '%s\n' "$X_OUT" | grep -v '^#' | grep -c '%')
check "X5 no unescaped % in the emitted block" "0" "$x_pct"

# X6: the property itself, executed rather than pattern-matched -- and executed
# against a mktemp that fails, since a probe run under a WORKING mktemp passes
# for both the old and the new shape and so proves nothing.
X_W="$TMPD/x-work"; mkdir -p "$X_W/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$X_W/bin/mktemp"; chmod +x "$X_W/bin/mktemp"
printf '#!/usr/bin/env bash\necho "engine ran" >&2\nexit 0\n' > "$X_W/engine.sh"; chmod +x "$X_W/engine.sh"
X_LOG="$X_W/cron.log"

# Take the REAL emitted line, drop the 5 schedule fields, and swap ONLY the
# engine path -- so this tests what gen-cron.sh actually writes, not a
# paraphrase. Swapping the whole `snapsend.sh ... 2>"$e"` span instead would
# take the redirect out with it and the probe would measure my sed, not the
# emitted line (it did, the first time).
x_line=$(printf '%s\n' "$X_OUT" | grep 'snapsend.sh' | head -1 |
         sed -e 's|^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* ||' \
             -e "s|/R/snapsend.sh|$X_W/engine.sh|" \
             -e "s|/L|$X_LOG|g")
: > "$X_LOG"
( PATH="$X_W/bin:$PATH"; eval "$x_line" ) >/dev/null 2>&1
x_ran=$(grep -c 'engine ran' "$X_LOG" 2>/dev/null); x_ran="${x_ran:-0}"
x_marks=$(grep -c 'ZFS-JOB' "$X_LOG" 2>/dev/null); x_marks="${x_marks:-0}"
check "X6 a failing mktemp no longer swallows the run" \
      "engine=1 markers=2" "engine=$x_ran markers=$x_marks"

# X7: the positive control. The OLD shape under the IDENTICAL failure must come
# out mute -- engine never run, log empty. Without this X6 could be green
# because the stub engine is easy to run, not because the fallback works.
X_OLDLOG="$X_W/old.log"; : > "$X_OLDLOG"
x_old='e=$(mktemp); '"$X_W"'/engine.sh 2>"$e"; rc=$?; cat "$e" >>'"$X_OLDLOG"'; rm -f "$e"'
( PATH="$X_W/bin:$PATH"; eval "$x_old" ) >/dev/null 2>&1
x_old_ran=$(grep -c 'engine ran' "$X_OLDLOG" 2>/dev/null); x_old_ran="${x_old_ran:-0}"
check "X7 control: the old shape IS mute under the same failure" \
      "engine=0" "engine=$x_old_ran"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
