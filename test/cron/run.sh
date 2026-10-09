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

# ---- O. foreign and malformed markers stop the write ------------------------
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

# ---- S. the lock descriptor is closed without composing a command -----------
#
# Both closes were `eval "exec $fd>&-"` until 2026-09-03: a command assembled
# from text and handed to eval, for a descriptor bash closes directly with
# `exec {fd}>&-` -- the same form that opened it. S1 is the discriminator (red
# on the eval form: 2). S2-S4 pin what the form change must keep: the
# descriptor is open while the lock is held, gone after release, and so is the
# bookkeeping entry. S5 covers the other close, on the refused acquire: a
# writer that lost the contention must not keep a descriptor on the lock file.
n_eval=$(grep -c '^[[:space:]]*eval[[:space:]]' "$LIB")
check "S1 lib-cron.sh composes no command from text (eval sites)" "0" "$n_eval"
# The probe is a CHILD process writing to the inherited descriptor. Not
# `{ : >&"$fd"; } 2>/dev/null` in this shell: bash parks the group's saved
# stderr on the lowest free descriptor >= 10 for the duration of the group,
# which is exactly the number the lock just gave back -- the first version of
# this probe reported "still open" against a descriptor /proc showed closed.
fd_open() { bash -c ': >&"$1"' _ "$1" 2>/dev/null; }
cron_lock_acquire closeuser || bad "S2 acquire for the close probe" "$CRON_ERR"
s_fd="${CRON_LOCK_FD[closeuser]:-}"
if [ -n "$s_fd" ] && fd_open "$s_fd"; then ok "S2 the lock descriptor is open while the lock is held"
else bad "S2 the lock descriptor is open while the lock is held" "fd=[$s_fd]"; fi
cron_lock_release closeuser
if [ -n "$s_fd" ] && fd_open "$s_fd"; then bad "S3 release closes the descriptor" "fd $s_fd is still open"
else ok "S3 release closes the descriptor"; fi
check "S4 ...and drops the bookkeeping entry" "" "${CRON_LOCK_FD[closeuser]:-}"
if [ -d /proc/$$/fd ]; then
    rm -f "$BARRIER_HELD" "$BARRIER_GO"
    bash "$TMPD/holder.sh" &
    hpid=$!
    while [ ! -e "$BARRIER_HELD" ]; do sleep 0.05; done
    s_before=$(ls /proc/$$/fd | wc -l)
    CRON_LOCK_TIMEOUT=1 cron_lock_acquire heldsvc
    rc=$?
    s_after=$(ls /proc/$$/fd | wc -l)
    : > "$BARRIER_GO"
    wait "$hpid" 2>/dev/null
    check "S5 a refused acquire leaves no descriptor behind (refused)" "1" "$rc"
    check "S5 ...open descriptors before and after" "$s_before" "$s_after"
else
    echo "SKIP S5 no /proc/\$\$/fd on this machine"
fi

# ---- T. cron_replace_all_impl: the whole-crontab primitive ------------------
#
# Some intermediate states are not one named block -- e.g. "a whole crontab
# minus one collector block" -- so the tool needs a primitive that replaces
# everything, through the shared read-back (the caller holds the lock; the lock
# path itself is section U), and still refusing a target whose markers are
# malformed (F4): installing an already-broken layout would make the FIRST
# ordinary block write after it guess where somebody else's lines start.
seed '# old content' '1 * * * * old-job'
printf '%s\n' '# new content' '2 * * * * new-job' > "$TMPD/replace-in"
cron_replace_all_impl "$ME" "$TMPD/replace-in"
check "T1 rc" "0" "$?"
check "T2 the crontab is exactly the given file" "0" \
      "$(diff -q "$TMPD/replace-in" "$(tab)" >/dev/null; echo $?)"

# Read-back still catches a lying crontab(1) -- this primitive is not a
# shortcut around the write/read-back path, it is the same path.
CRONTAB_MODE=liar
printf '%s\n' '3 * * * * liar-job' > "$TMPD/replace-in2"
cron_replace_all_impl "$ME" "$TMPD/replace-in2"
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
cron_replace_all_impl "$ME" "$TMPD/replace-bad"
check "T5 a target with malformed markers is refused" "1" "$?"
case "$CRON_ERR" in *"nest or overlap"*) ok "T6 ...named as a marker problem" ;;
  *) bad "T6 ...named as a marker problem" "$CRON_ERR" ;; esac
check "T7 ...and nothing was written" "0" \
      "$(diff -q <(printf '%s\n' "$before") "$(tab)" >/dev/null; echo $?)"

# An unreadable source file is refused before anything is touched.
before=$(cat "$(tab)")
cron_replace_all_impl "$ME" "$TMPD/does-not-exist"
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

# X1: every line that RUNS an engine goes through the envelope, and carries a
# label. Counted, not grepped for presence: one wrapped line out of two would
# pass a presence check and leave the other mute.
#
# THE MARKERS ARE NO LONGER IN THE LINE. Since 2026-08-30 the envelope is
# zfs-job.sh -- 336 characters repeated in every job had put an ordinary host
# at 890 of cron's 1000-byte limit -- so BEGIN/END are written at RUN time.
# What the line can still be asked is that every engine job is wrapped; that
# the markers and the rc actually appear is asserted by EXECUTION in X6 below,
# which is a stronger claim than the grep it replaces.
x_wrapped=$(printf '%s\n' "$X_OUT" | grep -cE '/zfs-job[.]sh "[^"]+" ')
check "X1 every engine job line goes through the envelope, with a label" \
      "jobs=2 wrapped=2" \
      "jobs=$x_jobs wrapped=$x_wrapped"

# X2: the line hands the envelope everything it needs -- where to log, whom to
# call, how much detail. Without any one of them the envelope silently falls
# back to ITS OWN defaults, which are derived from where it sits and are not
# necessarily this config's paths: the job would run and its record would go
# somewhere nobody is reading.
x_flags=$(printf '%s\n' "$X_OUT" | grep -cE ' --log=[^ ]+ --notify=[^ ]+ --detail=[0-9]+ -- ')
check "X2 the envelope is told the log, the notify script and the detail depth" \
      "2" "$x_flags"

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
# against a mktemp that FAILS, since a probe under a working mktemp passes for
# every shape and so proves nothing.
#
# THE ENVELOPE IS A SCRIPT NOW, so the line is regenerated with REPO_DIR
# pointing at a directory holding the REAL zfs-job.sh beside a stub engine.
# That is closer to the intent this case always had than the sed it replaces:
# swapping the engine path textually only ever existed to leave the rest of the
# line untouched, and a sed that stops matching leaves the whole thing running
# against nothing -- engine=0, markers=0, silently, which is the exact
# signature X6 exists to catch. It has now caught it twice, both times as its
# own harness rotting rather than the code.
X_W="$TMPD/x-work"; mkdir -p "$X_W/bin" "$X_W/repo"
printf '#!/usr/bin/env bash\nexit 1\n' > "$X_W/bin/mktemp"; chmod +x "$X_W/bin/mktemp"
printf '#!/usr/bin/env bash\necho \"engine ran\" >&2\nexit 0\n' > "$X_W/repo/snapsend.sh"
chmod +x "$X_W/repo/snapsend.sh"
cp "$REPO/zfs-job.sh" "$X_W/repo/zfs-job.sh"; chmod +x "$X_W/repo/zfs-job.sh"
X_LOG="$X_W/cron.log"

X_OUT6=$(REPO_DIR="$X_W/repo" NOTIFY_SCRIPT=/bin/true WARN_SCRIPT=/bin/true DIGEST_SCRIPT=none \
         CRON_LOG="$X_LOG" bash "$GEN" -c "$TMPD/x.conf" 2>&1)
x_line=$(printf '%s\n' "$X_OUT6" | grep 'snapsend.sh' | head -1 |
         sed -e 's|^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* ||')
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

# X8/X9: exit 75 is a WARNING, not a failure (owner, 2026-10-06). The engines
# exit 75 when the previous run still holds the lock; the REAL zfs-job.sh must
# call notify-warn.sh (beside notify-fail.sh, the default) and NOT the failure
# script -- and a real failure must still go to the failure script only.
X_N="$X_W/notes"; mkdir -p "$X_N"
printf '#!/bin/sh\necho "FAIL|$1" >> %s/calls\n' "$X_N" > "$X_N/notify-fail.sh"
printf '#!/bin/sh\necho "WARN|$1" >> %s/calls\n' "$X_N" > "$X_N/notify-warn.sh"
printf '#!/bin/sh\necho "skipping this run" >&2\nexit "$1"\n' > "$X_N/engine.sh"
chmod +x "$X_N/notify-fail.sh" "$X_N/notify-warn.sh" "$X_N/engine.sh"
: > "$X_N/calls"
bash "$REPO/zfs-job.sh" "lbl" --log="$X_N/log" --notify="$X_N/notify-fail.sh" -- "$X_N/engine.sh" 75
check "X8 exit 75 calls notify-warn.sh beside the notify script, never notify-fail" \
      "WARN|lbl -- skipped, the previous run still holds the lock" "$(cat "$X_N/calls")"
check "X8b ...and the END marker still records the real status" \
      "1" "$(grep -c 'ZFS-JOB END lbl rc=75' "$X_N/log")"
: > "$X_N/calls"
bash "$REPO/zfs-job.sh" "lbl" --log="$X_N/log" --notify="$X_N/notify-fail.sh" -- "$X_N/engine.sh" 1
check "X9 control: exit 1 still goes to notify-fail.sh only" "FAIL|lbl" "$(cat "$X_N/calls")"

# ===========================================================================
# MIR. SYNC IS A MIRROR (owner 2026-10-06). A pull tier carrying -M makes the
# target hold what the source holds, so the generator drops that tier's own
# target prune and keeps its monitor; a [prune:] ladder with prune = no is a
# monitor-only section. -M on a push or with recursive = atomic is refused.
MIR="$TMPD/mirror"; mkdir -p "$MIR"
mir_conf() {   # <dataset flags> <extra dataset lines> -> $MIR/c.conf
    cat > "$MIR/c.conf" <<EOF
[defaults]
	host_label = m
[template:flat_hourly]
	send_schedule  = 31 * * * *
	prune_schedule = 21 * * * *
	pattern        = -
	retain         = -H168
	monitor_warn   = 3h
	monitor_crit   = 5h
[dataset:hdd/x]
	use_template = flat_hourly
	src          = zb@10.0.0.1:hdd/x
	flags        = $1
$2
EOF
}
mir_conf "-e -M" ""
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/c.conf" 2>&1); mrc=$?
check "MIR1 a mirrored pull renders, rc=0" "0" "$mrc"
check "MIR2 ...its pull line carries -M" "1" "$(printf '%s\n' "$mo" | grep -c 'snapget.sh -m "" -e -M ')"
check "MIR3 ...and NO target prune line (the mirror is the retention)" "0" "$(printf '%s\n' "$mo" | grep -c 'delsnaps.sh')"
check "MIR4 ...while the monitor stays" "1" "$(printf '%s\n' "$mo" | grep -c 'check-snap-age.sh')"
mir_conf "-e" ""
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/c.conf" 2>&1)
check "MIR5 control: the same tier WITHOUT -M keeps its target prune" "1" "$(printf '%s\n' "$mo" | grep -c 'delsnaps.sh')"
mir_conf "-e -M" "	recursive    = atomic"
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/c.conf" 2>&1); mrc=$?
case "$mrc:$mo" in
    0:*) bad "MIR6 -M with recursive = atomic is refused" "$mo" ;;
    *"cannot go with recursive = atomic"*) ok "MIR6 -M with recursive = atomic is refused" ;;
    *) bad "MIR6 -M with recursive = atomic is refused" "$mo" ;;
esac
sed -i 's#^\tsrc          = zb@10.0.0.1:hdd/x$#\tdst          = zb@10.0.0.1:hdd/y#' "$MIR/c.conf"
sed -i '/^\trecursive    = atomic$/d' "$MIR/c.conf"
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/c.conf" 2>&1); mrc=$?
case "$mrc:$mo" in
    0:*) bad "MIR7 -M on a PUSH section is refused (snapsend.sh has no -M)" "$mo" ;;
    *"is a PULL option"*) ok "MIR7 -M on a PUSH section is refused (snapsend.sh has no -M)" ;;
    *) bad "MIR7 -M on a PUSH section is refused (snapsend.sh has no -M)" "$mo" ;;
esac
cat > "$MIR/p.conf" <<'EOF'
[defaults]
	host_label = m
[template:k1]
	pattern = automated_hourly
	keep = 24
	prune_schedule = 21 * * * *
	monitor_warn = 90m
	monitor_crit = 150m
[template:k2]
	pattern = automated_daily
	keep = 7
	prune_schedule = 31 1 * * *
[prune:hdd/x]
	use_template = k1,k2
	gfs = yes
	gfs_pattern = automated_
	prune = no
	recursive = no
	notify = x
EOF
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/p.conf" 2>&1); mrc=$?
# This shape was test/negative/gfs-empty-ladder until 2026-10-06 (refused). Its
# stated worry -- a -G line with no retain flags -- still holds: MIR9 pins that
# no delsnaps line is emitted at all. What changed is that the section is now
# legitimate: a mirrored sync landing whose ladder only carries monitors.
check "MIR8 a ladder with prune = no is a monitor-only section: rc=0" "0" "$mrc"
check "MIR9 ...no delsnaps -G line" "0" "$(printf '%s\n' "$mo" | grep -c 'delsnaps.sh')"
check "MIR10 ...the tier that carries a monitor still monitors" "1" "$(printf '%s\n' "$mo" | grep -c 'check-snap-age.sh')"
sed -i '/monitor_warn = 90m/d; /monitor_crit = 150m/d' "$MIR/p.conf"
mo=$(REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$MIR/p.conf" 2>&1); mrc=$?
case "$mrc:$mo" in
    0:*) bad "MIR11 a prune = no section with no monitor on ANY tier is still refused" "$mo" ;;
    *"on any tier -- the section would emit nothing at all"*) ok "MIR11 a prune = no section with no monitor on ANY tier is still refused" ;;
    *) bad "MIR11 a prune = no section with no monitor on ANY tier is still refused" "$mo" ;;
esac

# ===========================================================================
# FOR. FOREIGN SNAPSHOTS ARE PRUNED LIKE OUR OWN (U4, owner 2026-10-06: "obce
# migawki powinny byc ciete jak wlasne"). prune_foreign = yes on a landing:
# the FINEST tier's line drops its pattern (delsnaps then takes every snapshot
# not protected) and protects every OTHER family pruned on that path with
# :all, plus the replica families with :2. The other tiers are untouched; a
# GFS ladder is the carrier when there is one; a remote [prune:] refuses.
FOR="$TMPD/foreign"; mkdir -p "$FOR"
for_conf() {   # <dataset extra lines> <extra sections> -> $FOR/c.conf
    cat > "$FOR/c.conf" <<EOF
[defaults]
	host_label = f
[template:hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	keep           = 24
[template:daily]
	send_schedule  = 11 1 * * *
	prefix         = automated_daily_
	prune_schedule = 31 1 * * *
	pattern        = automated_daily
	keep           = 7
[dataset:tank/b/rpool/vm]
	use_template = daily,hourly
	src          = zb@10.0.0.1:rpool/vm
	pair_label   = r1
$1
$2
EOF
}
for_run() { REPO_DIR=/R NOTIFY_SCRIPT=/N WARN_SCRIPT=/W DIGEST_SCRIPT=none CRON_LOG=/L "$GEN" -c "$FOR/c.conf" 2>&1; }
for_conf "	prune_foreign = yes" ""
fo=$(for_run); frc=$?
check "FOR1 a prune_foreign landing renders, rc=0" "0" "$frc"
check "FOR2 ...the FINEST tier (hourly, listed second) loses its pattern and protects the daily family and replica_:2" "1" \
      "$(printf '%s\n' "$fo" | grep -c 'delsnaps.sh -L r1 -P "automated_daily:all" -P "replica_:2" "tank/b/rpool/vm" "" -H24')"
check "FOR3 ...the daily tier keeps its own line, pattern and count" "1" \
      "$(printf '%s\n' "$fo" | grep -c 'delsnaps.sh -L r1 "tank/b/rpool/vm" "automated_daily" -D7')"
check "FOR4 ...and nothing else prunes there" "2" "$(printf '%s\n' "$fo" | grep -c 'delsnaps.sh')"
for_conf "" ""
fo=$(for_run)
check "FOR5 control: without the field the hourly line keeps its pattern and carries no extra -P" "1" \
      "$(printf '%s\n' "$fo" | grep -c 'delsnaps.sh -L r1 "tank/b/rpool/vm" "automated_hourly" -H24')"
for_conf "	prune_foreign = yes" "[replica:usb]
	source   = tank/b/rpool/vm
	dst      = usb/rep
	schedule = 30 2 * * *
	prefix   = kopia_
	media    = removable
[excluded:vzdump]
	keep = 2"
fo=$(for_run)
check "FOR6 a [replica:] prefix in the config is protected :2 too, and the [excluded:] floor still rides every line after it" "1" \
      "$(printf '%s\n' "$fo" | grep -c '"automated_daily:all" -P "kopia_:2" -P "replica_:2" -P "vzdump:2" "tank/b/rpool/vm" "" -H24')"
cat > "$FOR/c.conf" <<'EOF'
[defaults]
	host_label = f
[template:hourly]
	send_schedule  = 1 * * * *
	prefix         = automated_hourly_
	pattern        = automated_hourly
	retain         = -H24
[template:daily]
	send_schedule  = 11 1 * * *
	prefix         = automated_daily_
	pattern        = automated_daily
	retain         = -D7
[dataset:tank/b/rpool/vm]
	use_template = hourly,daily
	src          = zb@10.0.0.1:rpool/vm
	pair_label   = r1
[prune:tank/b/rpool/vm]
	use_template   = hourly,daily
	gfs            = yes
	gfs_pattern    = automated_
	prune_schedule = 21 * * * *
	pair_label     = r1
	prune_foreign  = yes
EOF
fo=$(for_run)
check "FOR7 a GFS ladder is the carrier: no pattern, replica_:2, the same rungs" "1" \
      "$(printf '%s\n' "$fo" | grep -c 'delsnaps.sh -G -L r1 -P "replica_:2" "tank/b/rpool/vm" "" -H24 -D7')"
cat > "$FOR/c.conf" <<'EOF'
[defaults]
	host_label = f
[template:t]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
[prune:zb@10.0.0.1:rpool/vm]
	use_template  = t
	prune_foreign = yes
EOF
fo=$(for_run); frc=$?
case "$frc:$fo" in
    0:*) bad "FOR8 prune_foreign on a REMOTE scope is refused (foreign snapshots there belong to the source)" "$fo" ;;
    *"prune_foreign = yes on a REMOTE scope"*) ok "FOR8 prune_foreign on a REMOTE scope is refused (foreign snapshots there belong to the source)" ;;
    *) bad "FOR8 prune_foreign on a REMOTE scope is refused" "$fo" ;;
esac

# K3 (2026-10-06): a [prune:] section accepts prune_schedule_<tier> and each
# tier's line runs at ITS OWN spread minute; a tier without the field keeps its
# template's schedule (control).
cat > "$FOR/c.conf" <<'EOF'
[defaults]
	host_label = f
[template:src_hourly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
[template:src_daily]
	prune_schedule = 31 1 * * *
	pattern        = automated_daily
	retain         = -D7
[prune:zb@10.0.0.1:rpool/vm]
	use_template   = src_hourly,src_daily
	prune_schedule_src_hourly = 5 * * * *
	ssh_flags      = -p 22
EOF
fo=$(for_run); frc=$?
check "SPK1 a [prune:] with prune_schedule_<tier> renders, rc=0" "0" "$frc"
check "SPK2 ...the hourly source prune runs at its own spread minute" "1" "$(printf '%s\n' "$fo" | grep -c '^5 \* \* \* \* .*delsnaps.sh .*"automated_hourly" -H24')"
check "SPK3 ...the daily one, given no field, keeps its template's schedule" "1" "$(printf '%s\n' "$fo" | grep -c '^31 1 \* \* \* .*delsnaps.sh .*"automated_daily" -D7')"

# ON-INSERT (2026-10-07, owner: "replika ma swoj harmonogram ... after connect"):
# a replica with no time renders as a COMMENT carrying the job -- cron never
# fires it, run-replicas (the udev rule's verb) does. A real schedule keeps its
# ordinary line (control); anything else is still linted.
oi_conf() {   # <schedule>
    cat > "$FOR/c.conf" <<EOF
[defaults]
	host_label = f
[replica:usb1]
	source   = tank/data
	dst      = usb/rep
	schedule = $1
	prefix   = replica_
	media    = removable
EOF
}
oi_conf on-insert
fo=$(for_run); frc=$?
check "ONI1 schedule = on-insert renders, rc=0" "0" "$frc"
check "ONI2 ...as ONE '#on-insert' comment line carrying the bracketed replica job" "1" \
      "$(printf '%s\n' "$fo" | grep -c '^#on-insert /R/zfs-job.sh "f replica copy (usb1)" .*zfs-media-gate.sh attach usb usb1 ')"
check "ONI3 ...and no line cron would fire for it" "0" \
      "$(printf '%s\n' "$fo" | grep -E '^[0-9*@]' | grep -c 'replica copy (usb1)')"
oi_conf "30 2 * * *"
fo=$(for_run)
check "ONI4 control: a real schedule keeps its ordinary cron line" "1" \
      "$(printf '%s\n' "$fo" | grep -c '^30 2 \* \* \* /R/zfs-job.sh "f replica copy (usb1)"')"
oi_conf "on-insertx"
fo=$(for_run); frc=$?
check "ONI5 any other word is still linted as a cron schedule and refused" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"

# REPLICA STALENESS (2026-10-08, owner: two weekly replicas and a monthly one --
# a threshold per medium by hand?). Not by hand: derived from the schedule,
# overridable in the section; on-insert only when the section says so. A
# removable medium is watched by the gate's age, a fixed one by check-snap-age
# on the copy itself.
rm_conf() {   # <name> <schedule> <media line or empty> <extra lines>
    cat > "$FOR/c.conf" <<EOF
[defaults]
	host_label = f
[replica:$1]
	source   = tank/a,tank/b
	dst      = usb/rep
	schedule = $2
	prefix   = replica_
$3
$4
EOF
}
rm_conf wk "30 3 * * 0" "" ""
fo=$(for_run)
check "RMON1 a FIXED weekly replica is watched by check-snap-age on the copy, 9d/14d from its schedule" "1" \
      "$(printf '%s\n' "$fo" | grep -c '^\*/15 \* \* \* \* d=\$(/R/check-snap-age\.sh -L wk "usb/rep/tank/a,usb/rep/tank/b" "replica_" 9d 14d ')"
rm_conf mo "30 4 1 * *" "	media    = removable" ""
fo=$(for_run)
check "RMON2 a REMOVABLE monthly one by the gate's age, 35d/45d" "1" \
      "$(printf '%s\n' "$fo" | grep -c '^\*/15 \* \* \* \* d=\$(/R/zfs-media-gate\.sh age "usb" "mo" --warn 35d --crit 45d ')"
rm_conf dy "30 2 * * *" "	media    = removable" ""
fo=$(for_run)
check "RMON3 ...a daily one 2d/4d" "1" "$(printf '%s\n' "$fo" | grep -c -- '--warn 2d --crit 4d')"
rm_conf oi on-insert "	media    = removable" ""
fo=$(for_run)
check "RMON4 an on-insert replica WITHOUT thresholds has no monitor line" "0" "$(printf '%s\n' "$fo" | grep -c 'zfs-media-gate\.sh age')"
rm_conf oi on-insert "	media    = removable" "	monitor_warn = 10d
	monitor_crit = 16d"
fo=$(for_run)
check "RMON5 ...WITH them it is watched, at exactly those" "1" "$(printf '%s\n' "$fo" | grep -c -- 'age "usb" "oi" --warn 10d --crit 16d')"
check "RMON6 ...rc 1 warns (getting stale), rc 2 alerts (stale), rc>=3 is a broken monitor" "1" \
      "$(printf '%s\n' "$fo" | grep 'age "usb" "oi"' | grep -c '/W "f replica getting stale (oi)".*/N "f replica stale (oi)".*/N "f replica monitor BROKEN (oi)"')"
rm_conf oi on-insert "	media    = removable" "	monitor_warn = 10d"
fo=$(for_run); frc=$?
check "RMON7 monitor_warn without monitor_crit is refused" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"
rm_conf oi on-insert "	media    = removable" "	monitor_warn = 14d
	monitor_crit = 9d"
fo=$(for_run); frc=$?
check "RMON8 warn not below crit is refused where it is written, not at run time" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"
rm_conf oi on-insert "	media    = removable" "	monitor_warn = 9dd
	monitor_crit = 14d"
fo=$(for_run); frc=$?
check "RMON9 a threshold with two units (9dd) is refused" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"
rm_conf wk "30 3 * * 0" "" "	monitor = no"
fo=$(for_run); frc=$?
check "RMON10 monitor = no (what cron2conf writes for a replica found without one) switches the derived monitor off" "0:0" \
      "$frc:$(printf '%s\n' "$fo" | grep -c 'check-snap-age')"
rm_conf wk "30 3 * * 0" "" "	monitor = no
	monitor_warn = 9d
	monitor_crit = 14d"
fo=$(for_run); frc=$?
check "RMON11 ...and refuses to be combined with thresholds" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"

# PASSIVE REPLICA (owner note 20, 2026-10-08): a replica of a relationship's
# copies takes no snapshots of its own -- replica_ on a landing was discarded by
# the next pull (P-0). passive = yes: snapget -e (no -m), the gate's family and
# the fixed-media monitor's pattern are "-" (any snapshot).
pv_conf() {   # <media line or empty> <extra lines>
    cat > "$FOR/c.conf" <<EOF
[defaults]
	host_label = f
[replica:pv]
	source   = tank/a
	dst      = usb/rep
	schedule = 30 2 * * *
	passive  = yes
$1
$2
EOF
}
pv_conf "	media    = removable" ""
fo=$(for_run); frc=$?
check "PRV1 passive = yes with no prefix renders, rc=0" "0" "$frc"
check "PRV2 ...the engine runs -e -M with no -m (no snapshot of its own)" "1" \
      "$(printf '%s\n' "$fo" | grep 'replica copy (pv)' | grep -c '/R/snapget\.sh -e -M "tank/a" "usb/rep"')"
check "PRV3 ...the gate is told any family: --source tank/a --prefix - (attach and detach)" "2" \
      "$(printf '%s\n' "$fo" | grep 'replica copy (pv)' | grep -o -- '--source tank/a --prefix -' | grep -c .)"
pv_conf "" ""
fo=$(for_run)
check "PRV4 a FIXED passive replica's monitor reads any snapshot on the copy (pattern '-')" "1" \
      "$(printf '%s\n' "$fo" | grep -c '^\*/15 \* \* \* \* d=\$(/R/check-snap-age\.sh -L pv "usb/rep/tank/a" "-" 2d 4d ')"
pv_conf "" "	prefix   = replica_"
fo=$(for_run); frc=$?
check "PRV5 passive = yes together with a prefix is refused (say one of them)" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"
oi_conf "30 2 * * *"
fo=$(for_run)
check "PRV6 control: a replica with a prefix still stamps its own family (-m \"replica_\" -M)" "1" \
      "$(printf '%s\n' "$fo" | grep 'replica copy (usb1)' | grep -c 'snapget\.sh -m "replica_" -M')"

# DISKS BY GUID AND ON-INSERT PER REPLICA (P5, owner 2026-10-09). media_guids goes to
# the gate's ATTACH only (--guids), never to detach (cron's 1000 bytes); on_insert =
# yes on a scheduled replica adds a commented '#on-insert' copy of its line for
# run-replicas --on-insert; bad GUIDs and GUIDs on a fixed medium are refused.
pv_conf "	media    = removable" "	media_guids = 111,222
	on_insert = yes"
fo=$(for_run); frc=$?
check "PRG1 media_guids + on_insert render, rc=0" "0" "$frc"
check "PRG2 ...attach is told --guids 111,222, detach is not" "1:0" \
      "$(printf '%s\n' "$fo" | grep -v '^#on-insert' | grep 'replica copy (pv)' | grep -o 'attach [^;]*' | grep -c -- '--guids 111,222'):$(printf '%s\n' "$fo" | grep -v '^#on-insert' | grep 'replica copy (pv)' | grep -o 'detach [^;]*' | grep -c -- '--guids')"
check "PRG3 ...the scheduled line stays and a '#on-insert' copy is added" "1:1" \
      "$(printf '%s\n' "$fo" | grep -c '^30 2 \* \* \* .*replica copy (pv)'):$(printf '%s\n' "$fo" | grep -c '^#on-insert .*replica copy (pv)')"
pv_conf "	media    = removable" ""
fo=$(for_run)
check "PRG4 control: without on_insert there is no '#on-insert' copy, without media_guids no --guids" "0:0" \
      "$(printf '%s\n' "$fo" | grep -c '^#on-insert .*replica copy (pv)'):$(printf '%s\n' "$fo" | grep -c -- '--guids')"
pv_conf "	media    = removable" "	media_guids = 11x"
fo=$(for_run); frc=$?
check "PRG5 media_guids that is not digits is refused" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"
pv_conf "" "	media_guids = 111"
fo=$(for_run); frc=$?
check "PRG6 media_guids on a FIXED replica is refused (no gate reads it)" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"

# ===========================================================================
# Y. A MERGED PRUNE LINE MUST NOT BORROW SOMEBODY ELSE'S NAME
#
# Inline prune entities are grouped so that datasets sharing a schedule, a
# family, a retention and a scope become ONE delsnaps.sh call. The render then
# takes the notify label from members[0] and drops the rest.
#
# Measured on pve9, 2026-08-25, two prod relationships on one collector: four
# merged prune lines, every one announcing itself as "(p1-at)" -- including the
# ones sweeping p2's dataset. A failure pruning p2 would have sent an operator
# to look at p1. The file already carries this exact argument for `recursive`
# ("merging ... would silently give one of them the wrong scope"); notify was
# the field it forgot.
#
# The config below is the shape that produced it: two relationships, same tier,
# same retention, different notify.
YD="$TMPD/mergelabel"; mkdir -p "$YD"
cat > "$YD/jobs.conf" <<'YCONF'
[defaults]
	host_label = ytest

[template:hourly]
	send_schedule  = 37 * * * *
	prefix         = automated_hourly_
	notify_word    = snapshot
	prune_schedule = 51 * * * *
	pattern        = automated_hourly
	keep           = 24

[dataset:tank/a/tank/src]
	use_template = hourly
	src          = acct@10.0.0.1:tank/src
	recursive    = flat
	pair_label   = r1
	notify       = r1-at

[dataset:tank/b/tank/src]
	use_template = hourly
	src          = acct@10.0.0.2:tank/src
	recursive    = flat
	pair_label   = r2
	notify       = r2-at
YCONF

y_render()  { bash "$1" -c "$YD/jobs.conf" 2>/dev/null; }
y_count()   { printf '%s\n' "$1" | grep -c "delsnaps.sh"; }
y_wrong()   { printf '%s\n' "$1" | grep "delsnaps.sh" | grep -c 'tank/b/tank/src[^|]*(r1-at)'; }
y_merged()  { printf '%s\n' "$1" | grep "delsnaps.sh" | grep -c 'tank/a/tank/src,tank/b/tank/src'; }

y_new="$(y_render "$GEN")"
check "Y1: two relationships get two prune lines, not one shared one" \
      "lines=2 merged=0" "lines=$(y_count "$y_new") merged=$(y_merged "$y_new")"

check "Y2: no prune line sweeps one relationship's dataset under another's name" \
      "wrong=0" "wrong=$(y_wrong "$y_new")"

# CONTROL: the datasets of ONE relationship must still merge. Without this, Y1
# would pass against a build that stopped grouping altogether -- which would
# turn every collector's prune section into one line per dataset.
cat > "$YD/same.conf" <<'YCONF'
[defaults]
	host_label = ytest

[template:hourly]
	send_schedule  = 37 * * * *
	prefix         = automated_hourly_
	notify_word    = snapshot
	prune_schedule = 51 * * * *
	pattern        = automated_hourly
	keep           = 24

[dataset:tank/a/tank/src]
	use_template = hourly
	src          = acct@10.0.0.1:tank/src
	recursive    = flat
	pair_label   = r1
	notify       = r1-at

[dataset:tank/a/tank/src2]
	use_template = hourly
	src          = acct@10.0.0.1:tank/src2
	recursive    = flat
	pair_label   = r1
	notify       = r1-at
YCONF
y_same="$(bash "$GEN" -c "$YD/same.conf" 2>/dev/null)"
check "Y3 control: datasets of the SAME relationship still merge into one call" \
      "lines=1" "lines=$(printf '%s\n' "$y_same" | grep -c delsnaps.sh)"

# ============================================================================
# Z -- settings.ini: THE FILE THE READER HAS BEEN READING SINCE NOBODY HAD ONE.
#
# settings_get has looked in /etc/zfs-snapshot-all/settings.ini since 2026-08-26.
# No host had the file, so its two keys -- `catchup_max_age` and `quiesce` --
# existed only in the code that looked for them. Owner direction, 2026-08-27:
# the file must exist, and it must say what a failed freeze now does.
#
# Tested as a ROUND TRIP, deliberately: the writer's output is fed back to
# settings_get, the real reader, instead of being grepped for the strings this
# suite expects. A template that documented a key the parser cannot parse would
# pass every grep and fail every host.
# ============================================================================
ZD="$TMPD/settingsini"
mkdir -p "$ZD"

( source "$LIB" >/dev/null 2>&1
  settings_write_default "$ZD/etc/settings.ini" ) \
  && ok "Z1 the writer creates the file" \
  || bad "Z1 the writer creates the file" "settings_write_default returned non-zero"

# Z2 -- it NEVER overwrites. This runs from every deploy, and the file exists to
# be hand-edited; a writer that refreshed it would silently discard the edit.
printf 'catchup_max_age = 42\n' > "$ZD/etc/settings.ini"
if ( source "$LIB" >/dev/null 2>&1; settings_write_default "$ZD/etc/settings.ini" ); then
    bad "Z2 an existing file is never overwritten" "the writer reported success on an existing path"
else
    ok "Z2 an existing file is never overwritten"
fi
z_kept="$( source "$LIB" >/dev/null 2>&1
           SETTINGS_FILE="$ZD/etc/settings.ini" settings_get catchup_max_age 1800 )"
check "Z2b ...and the hand-edited value survives it" "42" "$z_kept"

# Back to a fresh template for the round trip.
rm -f "$ZD/etc/settings.ini"
( source "$LIB" >/dev/null 2>&1; settings_write_default "$ZD/etc/settings.ini" ) >/dev/null 2>&1

# Z3 -- readable by somebody who is not root. gen-cron.sh and zfs-backup.sh read
# this file AS THE DELEGATED ACCOUNT, and an unreadable settings file does not
# fail: settings_get falls back to the built-in default, silently. Mode is the
# only thing standing between an edited policy and a silently ignored one.
z_mode="$(ls -l "$ZD/etc/settings.ini" | cut -c1-10)"
case "$z_mode" in
    -rw-r--r--) ok "Z3 the file is world-readable, so a non-root reader gets what it says" ;;
    *)          bad "Z3 the file is world-readable, so a non-root reader gets what it says" "mode=$z_mode" ;;
esac

# Z4 -- A FRESH FILE CHANGES NOTHING. Every key in the template is commented, so
# a host that has just been deployed behaves exactly as it did before it had the
# file. This is the assertion that lets Phase 2a run on production unattended.
z_q="$( source "$LIB" >/dev/null 2>&1
        SETTINGS_FILE="$ZD/etc/settings.ini" settings_get quiesce "BUILTIN" )"
check "Z4 a fresh file leaves quiesce at the built-in default" "BUILTIN" "$z_q"
z_c="$( source "$LIB" >/dev/null 2>&1
        SETTINGS_FILE="$ZD/etc/settings.ini" settings_get catchup_max_age 1800 )"
check "Z4b ...and catchup_max_age too" "1800" "$z_c"

# Z5 -- POSITIVE CONTROL, and the one that makes Z4 mean something: uncommenting
# the documented line must actually take effect. Without this pair, a template
# whose `quiesce` line was misspelled -- or commented in a way settings_get could
# not later parse -- would pass Z4 for the wrong reason.
sed -i 's/^#quiesce = auto$/quiesce = auto,strict/' "$ZD/etc/settings.ini"
z_q2="$( source "$LIB" >/dev/null 2>&1
         SETTINGS_FILE="$ZD/etc/settings.ini" settings_get quiesce "BUILTIN" )"
check "Z5 uncommenting the documented quiesce line takes effect" "auto,strict" "$z_q2"
sed -i 's/^#catchup_max_age = 1800$/catchup_max_age = 900/' "$ZD/etc/settings.ini"
z_c2="$( source "$LIB" >/dev/null 2>&1
         SETTINGS_FILE="$ZD/etc/settings.ini" settings_get catchup_max_age 1800 )"
check "Z5b ...and so does catchup_max_age" "900" "$z_c2"

# Z6 -- what the template SAYS about the value it documents. The whole point of
# the file is that an operator reads it before uncommenting, and the one thing
# they must not miss is that `quiesce` here reaches the tier that deliberately
# has none. Checked as a property of the shipped text, not of a fixture copy.
z_text="$( rm -f "$ZD/fresh.ini"
           source "$LIB" >/dev/null 2>&1
           settings_write_default "$ZD/fresh.ini" >/dev/null 2>&1
           cat "$ZD/fresh.ini" )"
case "$z_text" in
    *HOURLY*) ok "Z6 the template warns that this key reaches the hourly tier" ;;
    *)        bad "Z6 the template warns that this key reaches the hourly tier" "no mention of the hourly tier" ;;
esac
case "$z_text" in
    *",strict"*) ok "Z6b ...and names ',strict' as the way to refuse a failed freeze" ;;
    *)           bad "Z6b ...and names ',strict' as the way to refuse a failed freeze" "no mention of ,strict" ;;
esac
# The value the engines now use by default, stated in the file an operator reads.
case "$z_text" in
    *_crash_*) ok "Z6c ...and says a degraded snapshot is named '_crash_'" ;;
    *)         bad "Z6c ...and says a degraded snapshot is named '_crash_'" "no mention of the marker" ;;
esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
