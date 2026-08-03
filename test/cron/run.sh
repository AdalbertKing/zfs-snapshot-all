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

# ---- T. cron_replace_all: the whole-crontab primitive for F3 ---------------
#
# migrate-to-account's intermediate states are not one named block -- "root's
# whole crontab minus its collector block" and "the account's whole crontab
# restored to what it was" -- so it needs a primitive that replaces
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

echo "--------------------------------------------"
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
