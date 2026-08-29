#!/bin/bash
# zfs-media-gate.sh -- the import/export bracket around a replica onto removable
# media.
#
# WHAT THIS CAN HONESTLY COVER. `zpool` and `zfs` are stubbed, so what is
# asserted is the DECISION LOGIC -- which branch is taken, what exit status it
# carries, and above all which pools get exported and which do not. That ZFS
# imports and exports as expected is a property of ZFS and belongs on a host
# with a real removable disk; the live half is recorded in PROJECT_STATUS.
#
# The assertion that matters most is the one about NOT exporting: a pool this
# run did not import belongs to whoever did, and exporting it would pull the
# floor out from under them. That is checked here in both directions, because a
# guard that only ever sees the safe case is not a guard.
#
# Runs anywhere: no root, no ZFS, no pools.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="${GATE:-$REPO/zfs-media-gate.sh}"
[ -r "$GATE" ] || { echo "cannot read zfs-media-gate.sh at $GATE" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
BIN="$TMPD/bin"; STATE="$TMPD/state"; mkdir -p "$BIN" "$STATE"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; FAIL=$((FAIL+1)); }
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# The stubs. POOLS lists what is currently imported; IMPORTABLE lists what
# `zpool import` would find; EXPORTED records every export actually attempted,
# which is how the "only what we took" rule is checked rather than assumed.
cat > "$BIN/zpool" <<'ZP'
#!/bin/sh
# The name is the LAST argument, not $4 -- `zpool list -H -o name POOL` puts
# "name" there. The first version of this stub read $4 and reported every pool
# as absent, which made five assertions fail in ways that looked like code bugs.
for a in "$@"; do last="$a"; done
# `zpool get -H -o value guid POOL`. POOL_GUID lets a test put a DIFFERENT disk
# of the same name in the slot, which is what separates "our interrupted run"
# from "we still owe an export on another medium".
case "$1 $2" in
  "get -H")
      # The property is an argument, not a position: guid and failmode both
      # arrive as `zpool get -H -o value <prop> <pool>`.
      for a in "$@"; do
          [ "$a" = failmode ] && { echo "${POOL_FAILMODE:-continue}"; exit 0; }
      done
      echo "${POOL_GUID:-11111111}"; exit 0 ;;
  "list -H")
      for p in $POOLS; do [ "$p" = "$last" ] && exit 0; done; exit 1 ;;
esac
case "$1" in
  import)
      [ -z "${2:-}" ] && { for p in $IMPORTABLE; do echo "  pool: $p"; done; exit 0; }
      for p in $IMPORTABLE; do
          if [ "$p" = "$2" ]; then echo "$2" >> "$IMPORTED_LOG"; exit 0; fi
      done
      exit 1 ;;
  export)
      echo "$2" >> "$EXPORTED_LOG"
      # A pull-while-imported does not make export FAIL -- it makes it never
      # return. Slept, so the real `timeout` in the gate is what is under test.
      [ -n "${EXPORT_HANGS:-}" ] && sleep 5
      [ -n "${EXPORT_FAILS:-}" ] && exit 1
      exit 0 ;;
esac
exit 0
ZP
cat > "$BIN/zfs" <<'ZF'
#!/bin/sh
for a in "$@"; do last="$a"; done
case "$*" in
  *"list -H -o name"*)
      for d in $DATASETS; do [ "$d" = "$last" ] && exit 0; done; exit 1 ;;
esac
exit 0
ZF
chmod +x "$BIN/zpool" "$BIN/zfs"

export IMPORTED_LOG="$TMPD/imported" EXPORTED_LOG="$TMPD/exported"
export POOLS IMPORTABLE DATASETS EXPORT_FAILS="" POOL_GUID POOL_FAILMODE EXPORT_HANGS
: > "$IMPORTED_LOG"; : > "$EXPORTED_LOG"

g() { PATH="$BIN:$PATH" MEDIA_STATE_DIR="$STATE" bash "$GATE" "$@" 2>&1; }

# ---------------------------------------------------------------------------
# 1. The refusals that happen before anything is touched
# ---------------------------------------------------------------------------
POOLS="hdd"; IMPORTABLE=""; DATASETS="hdd"
out="$(g)"; check "cli: no arguments is a usage error" "2" "$?"
out="$(g attach)"; check "cli: a verb alone is not enough" "2" "$?"
out="$(g nosuchverb p l)"
has "unknown verb" "$out" && ok "cli: an unknown verb is refused" || bad "cli: an unknown verb is refused" "$out"
out="$(g attach "zly/pool" lab)"
has "not a valid pool name" "$out" && ok "cli: a pool name with a slash is refused" || bad "cli: a pool name with a slash is refused" "$out"
out="$(g attach pool "zla/etykieta")"
has "not a valid label" "$out" && ok "cli: a label with a slash is refused" || bad "cli: a label with a slash is refused" "$out"

# ---------------------------------------------------------------------------
# 2. THE MEDIUM IS AWAY -- the whole point: this is not an error
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
POOLS="hdd"; IMPORTABLE=""; DATASETS="hdd"
out="$(g attach rotpool rep)"; rc=$?
check "away: attach exits 1, the caller's signal to skip" "1" "$rc"
has "SKIPPED" "$out" && ok "away: ...and says SKIPPED, not failed" || bad "away: ...and says SKIPPED, not failed" "$out"
has "nothing is wrong" "$out" && ok "away: ...and says so in as many words" || bad "away: ...and says so in as many words" "$out"
check "away: nothing was exported" "" "$(cat "$EXPORTED_LOG")"

# THE LINE AN OPERATOR READS MOST OFTEN. detach sits OUTSIDE the generated
# `if`, so it runs on every night the disk is in a safe -- far more often than
# on any night it is plugged in. It used to answer that with "leaving 'rotpool'
# imported: this run did not import it", because it asked who owned the pool
# before asking whether the pool was there at all.
#
# It is not a cosmetic slip. It names the one state in which unplugging the
# disk corrupts the replica, so it teaches whoever reads the log that the real
# warning means nothing. Found live on pve0, 2026-08-29.
out="$(g detach rotpool rep)"; rc=$?
check "away: detach exits 0" "0" "$rc"
check "away: nothing was exported by detach either" "" "$(cat "$EXPORTED_LOG")"
has "not imported" "$out" && ok "AWAY: DETACH SAYS THE POOL IS NOT IMPORTED" || bad "AWAY: DETACH SAYS THE POOL IS NOT IMPORTED" "$out"
has "leaving" "$out" && bad "AWAY: AND DOES NOT CLAIM IT LEFT ONE IMPORTED" "$out" || ok "AWAY: AND DOES NOT CLAIM IT LEFT ONE IMPORTED"

# ---------------------------------------------------------------------------
# 3. THE MEDIUM IS HERE -- imported by us, and given back
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"; : > "$IMPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; DATASETS="hdd rotpool/replica"
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "here: attach exits 0" "0" "$rc"
check "here: ...having imported it" "rotpool" "$(cat "$IMPORTED_LOG")"
has "will export it again" "$out" && ok "here: ...and says it will put it back" || bad "here: ...and says it will put it back" "$out"

POOLS="hdd rotpool"   # it is imported now
out="$(g detach rotpool rep)"; rc=$?
check "here: detach exits 0" "0" "$rc"
check "here: ...and EXPORTED the pool it imported" "rotpool" "$(cat "$EXPORTED_LOG")"
has "can be unplugged" "$out" && ok "here: ...and says the disk can be pulled" || bad "here: ...and says the disk can be pulled" "$out"

# ---------------------------------------------------------------------------
# 4. ONLY WHAT WE TOOK -- the assertion this file exists for
#
# A pool that was ALREADY imported when attach ran belongs to whoever imported
# it. Exporting it would pull the floor out from under them.
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
POOLS="hdd rotpool"; IMPORTABLE=""; DATASETS="hdd rotpool/replica"
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "not ours: attach still exits 0 -- the medium IS usable" "0" "$rc"
has "ALREADY imported" "$out" && ok "not ours: ...and says it did not import it" || bad "not ours: ...and says it did not import it" "$out"

out="$(g detach rotpool rep)"; rc=$?
check "not ours: detach exits 0" "0" "$rc"
check "NOT OURS: THE POOL WAS NOT EXPORTED" "" "$(cat "$EXPORTED_LOG")"
has "not this run's call" "$out" && ok "not ours: ...and says whose call it was not" || bad "not ours: ...and says whose call it was not" "$out"

# ---------------------------------------------------------------------------
# 5. The wrong medium in the slot -- NOT a skip
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; DATASETS="hdd"     # pool imports, dataset absent
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "wrong medium: exits 2, not 1 -- a human is needed" "2" "$rc"
has "wrong one" "$out" && ok "wrong medium: ...and says it is the wrong disk, not an absent one" || bad "wrong medium: ...and says it is the wrong disk, not an absent one" "$out"
check "wrong medium: ...and the pool it imported is put back" "rotpool" "$(cat "$EXPORTED_LOG")"

# ---------------------------------------------------------------------------
# 6. Two disks with the same name -- rotated media usually share one
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
: > "$IMPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool rotpool"; DATASETS="hdd"
out="$(g attach rotpool rep)"; rc=$?
check "ambiguous: exits 2 rather than choosing" "2" "$rc"
has "will not choose for you" "$out" && ok "ambiguous: ...and says it will not pick" || bad "ambiguous: ...and says it will not pick" "$out"
check "ambiguous: nothing was imported" "" "$(cat "$IMPORTED_LOG")"

# ---------------------------------------------------------------------------
# 7. An export that FAILS must be loud -- last moment before the disk is pulled
# ---------------------------------------------------------------------------
POOLS="hdd"; IMPORTABLE="rotpool"; DATASETS="hdd rotpool/replica"
out="$(g attach rotpool rep --dataset rotpool/replica)"
POOLS="hdd rotpool"; EXPORT_FAILS=1
out="$(g detach rotpool rep)"; rc=$?
check "export fails: exits 2" "2" "$rc"
has "DO NOT UNPLUG" "$out" && ok "export fails: ...and says DO NOT UNPLUG THE DISK" || bad "export fails: ...and says DO NOT UNPLUG THE DISK" "$out"
EXPORT_FAILS=""

# ---------------------------------------------------------------------------
# 8. REV-20260829-123 F2 -- a successful import whose ownership cannot be
#    recorded must NOT report success.
#
# Without the marker, detach reads the pool as somebody else's, leaves it
# imported and exits 0 -- so a successful bracket would end with a pool active
# while the job says it is done, exactly when an operator believes the disk is
# safe to unplug. Both compensating outcomes are covered, because the one that
# cannot put the pool back is the one that must shout.
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; DATASETS="hdd rotpool/replica"
UNWRITABLE="$TMPD/nope/deeper"
: > "$TMPD/nope"          # a FILE where the state dir would have to be
out="$(PATH="$BIN:$PATH" MEDIA_STATE_DIR="$UNWRITABLE" bash "$GATE" attach rotpool rep --dataset rotpool/replica 2>&1)"; rc=$?
check "F2: an import whose ownership cannot be recorded is NOT success" "2" "$rc"
has "will not proceed" "$out" && ok "F2: ...and says why it stops" || bad "F2: ...and says why it stops" "$out"
check "F2: ...and the pool it imported is exported again" "rotpool" "$(cat "$EXPORTED_LOG")"
has "as it was before this run" "$out" && ok "F2: ...and says the machine was put back" || bad "F2: ...and says the machine was put back" "$out"

# ...and when the compensating export ALSO fails, the disk must not be pulled.
: > "$EXPORTED_LOG"
EXPORT_FAILS=1
out="$(PATH="$BIN:$PATH" MEDIA_STATE_DIR="$UNWRITABLE" EXPORT_FAILS=1 bash "$GATE" attach rotpool rep --dataset rotpool/replica 2>&1)"; rc=$?
check "F2: ...and if it cannot be exported either, still nonzero" "2" "$rc"
has "DO NOT UNPLUG" "$out" && ok "F2: ...carrying DO NOT UNPLUG" || bad "F2: ...carrying DO NOT UNPLUG" "$out"
EXPORT_FAILS=""

# ---------------------------------------------------------------------------
# G. THE GENERATED LINE, RUN WHOLE
#
# Everything above tests the gate. Nothing above tested the CRON LINE the
# generator wraps around it, and that gap hid two defects that a passing suite
# happily shipped:
#
#   * the bracket was emitted as a bare `if ...; fi; detach` sequence into a
#     slot job_cron_line builds for ONE command (`CMD 2>"$e"; rc=$?`), so both
#     halves of the wrapper bound to `detach` alone. The engine's stderr missed
#     the log and went to cron's own stderr, and a failed transfer reported
#     success. Measured on pve0: engine rc=1, line rc=0;
#   * the gate was handed the LANDING path, which the engine creates, so a
#     freshly prepared disk was refused as the wrong medium on its first sync.
#
# So this section renders the real line with the real generator and RUNS it,
# stubbing only the gate and the engine so their statuses can be dictated.
# ---------------------------------------------------------------------------
GEN="${GEN:-$REPO/gen-cron.sh}"
STUB="$TMPD/stubrepo"; mkdir -p "$STUB"
cat > "$STUB/zfs-media-gate.sh" <<'SG'
#!/bin/bash
case "$1" in
  attach) echo "GATE-ATTACH" >&2; exit "${STUB_ATTACH_RC:-0}" ;;
  detach) echo "GATE-DETACH" >&2; exit "${STUB_DETACH_RC:-0}" ;;
esac
exit 0
SG
cat > "$STUB/snapsend.sh" <<'SE'
#!/bin/bash
echo "ENGINE-RAN" >&2
exit "${STUB_ENGINE_RC:-0}"
SE
cat > "$STUB/notify.sh" <<'SN'
#!/bin/bash
echo "NOTIFIED" >> "$NOTIFY_LOG"
SN
chmod +x "$STUB"/*.sh

cat > "$TMPD/media.conf" <<'MC'
[defaults]
	host_label = lab

[template:hourly]
	send_schedule  = 5 * * * *
	prefix         = automated_hourly_
	notify_word    = replica
	prune_schedule = 35 * * * *
	pattern        = automated_hourly
	keep           = 24

[dataset:tank/a]
	use_template = hourly
	notify       = a
	dst          = rotpool/replica
	media        = removable
MC

CRONOUT="$(REPO_DIR="$STUB" CRON_LOG="$TMPD/cron.log" NOTIFY_SCRIPT="$STUB/notify.sh" \
           bash "$GEN" -c "$TMPD/media.conf" 2>&1 | grep 'zfs-media-gate.sh attach' | head -1)"
[ -n "$CRONOUT" ] && ok "G: the generator emits a bracketed line for media=removable" \
                  || bad "G: the generator emits a bracketed line for media=removable"

# The gate is handed the BASE the admin prepares, never the leaf the engine makes.
# The needle carries no leading dashes: `has` is a plain case-glob, not getopt,
# and the first cut of this passed "--" as the needle, matching every time.
has "dataset rotpool/replica;" "$CRONOUT" \
    && ok "G: THE GATE CHECKS THE BASE, NOT THE LANDING PATH" \
    || bad "G: THE GATE CHECKS THE BASE, NOT THE LANDING PATH" "$CRONOUT"

# Strip the five schedule fields; what is left is exactly what cron runs.
LINE="$(printf '%s\n' "$CRONOUT" | sed -E 's/^([^ ]+ ){5}//')"

# Sets LINE_RC and LINE_LOG in the caller.
runline() {   # <attach rc> <engine rc> <detach rc>
    : > "$TMPD/cron.log"; : > "$TMPD/notify.log"
    STUB_ATTACH_RC="$1" STUB_ENGINE_RC="$2" STUB_DETACH_RC="$3" \
    NOTIFY_LOG="$TMPD/notify.log" bash -c "$LINE" >/dev/null 2>&1
    LINE_LOG="$(cat "$TMPD/cron.log" 2>/dev/null)"
    LINE_NOTIFIED="$(cat "$TMPD/notify.log" 2>/dev/null)"
    # NOT the shell's exit status. The wrapper ends in `rm -f "$e"`, so the
    # line itself always exits 0 and cron's own status is meaningless here --
    # what decides whether anyone is told is the `rc` job_cron_line captures
    # from the command and writes into the log. Asserting $? instead was this
    # section's first mistake, and it made all four cases look identical.
    LINE_RC="$(printf '%s' "$LINE_LOG" | grep -o 'rc=[0-9][0-9]*' | tail -1 | cut -d= -f2)"
}

# 1. THE DISK IS IN A SAFE. The one silence this field exists to buy.
runline 1 0 0
check "G1: disk away -> the job records success" "0" "$LINE_RC"
check "G1: ...and nobody is mailed" "" "$LINE_NOTIFIED"

# 2. THE DISK IS IN AND THE TRANSFER FAILED. This must NOT be silent -- it is
#    the defect the live run found: engine 1, line 0.
runline 0 1 0
check "G2: THE ENGINE'S FAILURE IS THE LINE'S FAILURE" "1" "$LINE_RC"
has "ENGINE-RAN" "$LINE_LOG" && ok "G2: ...and the engine's stderr reached the job log" \
                             || bad "G2: ...and the engine's stderr reached the job log" "$LINE_LOG"
[ -n "$LINE_NOTIFIED" ] && ok "G2: ...and somebody is mailed" \
                        || bad "G2: ...and somebody is mailed"

# 3. THE WRONG DISK IS IN THE SLOT. Not an absent medium; it alerts.
runline 2 0 0
check "G3: the wrong medium alerts rather than skipping" "2" "$LINE_RC"

# 4. THE TRANSFER WORKED BUT THE POOL WOULD NOT EXPORT. DO NOT UNPLUG.
runline 0 0 2
check "G4: a stuck export is reported, not swallowed" "2" "$LINE_RC"

# 5. Everything worked.
runline 0 0 0
check "G5: a clean run is clean" "0" "$LINE_RC"

# ---------------------------------------------------------------------------
# H. THE ANCHOR AND THE THING THAT PRUNES IT
#
# `record_send_bookmark` leaves one tgt-<hash> bookmark on the SOURCE. For a
# removable replica that bookmark is the entire feature: after the collector's
# retention has eaten the last common snapshot, it is the only thing left
# anchoring an incremental send, and the media lab measured exactly that.
#
# -B exists to prune bookmarks nobody refreshed. A disk in a safe is refreshed
# only when it is plugged in, so to -B a quarterly medium and a decommissioned
# VM look identical. Two things had to be true and neither was:
#
#   * a pause must stop it -- bookmark prune was the ONE prune shape that never
#     emitted -L, so the shape that destroys anchors was the shape that ignored
#     the pause. Its tuple gained pair_label and three readers were left one
#     name short, which does not fail: `read` puts the remainder in the LAST
#     name, so the label was glued onto ssh_flags and rendered as a port;
#   * the generator must SAY when a prune scope covers a removable source. It
#     warns; it does not refuse and does not silently exclude, because which
#     disks rotate how often is the administrator's fact, not the generator's.
# ---------------------------------------------------------------------------
mkconf() {   # <file> <media|-> <bm-scope> <bm-pattern> <recursive 0|1> <pair_label|->
    {
        printf '[defaults]\n\thost_label = lab\n\n'
        printf '[template:hourly]\n\tsend_schedule  = 5 * * * *\n'
        printf '\tprefix         = automated_hourly_\n\tnotify_word    = snapshot\n'
        printf '\tprune_schedule = 35 * * * *\n\tpattern        = automated_hourly\n\tkeep           = 24\n\n'
        printf '[dataset:tank/a]\n\tuse_template = hourly\n\tnotify       = a\n'
        printf '\tdst          = rotpool/replica\n'
        [ "$2" != "-" ] && printf '\tmedia        = %s\n' "$2"
        [ "$6" != "-" ] && printf '\tpair_label   = %s\n' "$6"
        printf '\n[prune-bookmarks:%s]\n\tschedule   = 45 4 * * *\n\tage        = -d30\n' "$3"
        printf '\tpattern    = %s\n\tnotify     = bookmarks\n\tssh_flags  = -p 2222\n' "$4"
        [ "$5" = "1" ] && printf '\trecursive  = yes\n'
        [ "$6" != "-" ] && printf '\tpair_label = %s\n' "$6"
    } > "$1"
}
gen() {   # <conf> -> stdout in GEN_OUT, stderr in GEN_ERR
    GEN_OUT="$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT \
                   -u CRON_LOG -u DIGEST_SCHEDULE bash "$GEN" -c "$1" 2>"$TMPD/gen.err")"
    GEN_ERR="$(cat "$TMPD/gen.err")"
}
warned() { case "$GEN_ERR" in *"anchor bookmark that replica depends on"*) return 0 ;; *) return 1 ;; esac; }

# H1. The collision itself.
mkconf "$TMPD/h1.conf" removable tank/a "tgt-" 0 -
gen "$TMPD/h1.conf"
warned && ok "H1: A PRUNE SCOPE OVER A REMOVABLE SOURCE IS REPORTED" \
        || bad "H1: A PRUNE SCOPE OVER A REMOVABLE SOURCE IS REPORTED" "$GEN_ERR"
case "$GEN_ERR" in
    *"FULL re-seed"*) ok "H1: ...naming the consequence, not just the overlap" ;;
    *) bad "H1: ...naming the consequence, not just the overlap" "$GEN_ERR" ;;
esac
case "$GEN_ERR" in
    *"nothing has been excluded for you"*) ok "H1: ...and saying it decided nothing on the admin's behalf" ;;
    *) bad "H1: ...and saying it decided nothing on the admin's behalf" "$GEN_ERR" ;;
esac
[ -n "$GEN_OUT" ] && ok "H1: ...and the config is still generated -- a warning, not a refusal" \
                  || bad "H1: ...and the config is still generated -- a warning, not a refusal"

# H2/H3/H4. THE NEGATIVE SIDE. A guard that only ever fires is not a guard.
mkconf "$TMPD/h2.conf" - tank/a "tgt-" 0 -
gen "$TMPD/h2.conf"
warned && bad "H2: an ordinary target is NOT warned about" "$GEN_ERR" \
       || ok "H2: an ordinary target is NOT warned about"

mkconf "$TMPD/h3.conf" removable tank/a "automated_" 0 -
gen "$TMPD/h3.conf"
warned && bad "H3: a pattern that cannot match tgt- is NOT warned about" "$GEN_ERR" \
       || ok "H3: a pattern that cannot match tgt- is NOT warned about"

mkconf "$TMPD/h4.conf" removable tank "tgt-" 0 -
gen "$TMPD/h4.conf"
warned && bad "H4: a PARENT scope without recursive does not reach the child" "$GEN_ERR" \
       || ok "H4: a PARENT scope without recursive does not reach the child"

# H5. ...but with recursive it does, and that is the shape a real config uses.
mkconf "$TMPD/h5.conf" removable tank "tgt-" 1 -
gen "$TMPD/h5.conf"
warned && ok "H5: a recursive parent scope DOES reach the child" \
        || bad "H5: a recursive parent scope DOES reach the child" "$GEN_ERR"

# H6/H7. The tuple readers. Measured on the rendered line, because that is where
# the glued field showed itself: `-p 2222relacja1` as a port.
mkconf "$TMPD/h6.conf" removable tank/a "tgt-" 0 relacja1
gen "$TMPD/h6.conf"
BMLINE="$(printf '%s\n' "$GEN_OUT" | grep -o 'delsnaps\.sh -B[^|]*' | head -1)"
case "$BMLINE" in
    *"-L relacja1"*) ok "H6: BOOKMARK PRUNE CARRIES -L, SO THE PAUSE REACHES IT" ;;
    *) bad "H6: BOOKMARK PRUNE CARRIES -L, SO THE PAUSE REACHES IT" "$BMLINE" ;;
esac
case "$BMLINE" in
    *"-p 2222 "*) ok "H7: ...and ssh_flags survive intact, with no field glued on" ;;
    *) bad "H7: ...and ssh_flags survive intact, with no field glued on" "$BMLINE" ;;
esac

# ---------------------------------------------------------------------------
# I. REV-20260829-124 F1 -- THE INTERRUPTED RUN
#
# Every case above looks at one run in isolation. This one is a LIFECYCLE: our
# attach succeeds, the run dies before detach (kill, reboot, overlapping retry),
# and a later run finds the pool already imported.
#
# `attach` used to open its already-imported branch with `rm -f "$OURS"`, on the
# reasoning that a pool already imported was somebody else's decision. True
# exactly once -- when we never imported it. After our OWN interrupted run the
# marker is the only fact saying the pool is ours to put away, and deleting it
# turned a package-owned import into an apparently foreign one: the following
# detach reported success without exporting, and so did every retry after it.
# The disk stayed live indefinitely while the job said it was safe to unplug.
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"; : > "$IMPORTED_LOG"
rm -f "$STATE/rep.imported-by-us" 2>/dev/null || :
POOLS="hdd"; IMPORTABLE="rotpool"; DATASETS="hdd rotpool/replica"; POOL_GUID=11111111

# 1. our attach, which imports it and takes ownership
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "I: our attach imports it" "0" "$rc"
[ -f "$STATE/rep.imported-by-us" ] && ok "I: ...and records ownership" || bad "I: ...and records ownership"

# 2. ...and now the run DIES. No detach. The pool stays imported.
POOLS="hdd rotpool"; IMPORTABLE=""

# 3. the retry finds it imported. The marker must survive.
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "I: the retry's attach still exits 0" "0" "$rc"
[ -f "$STATE/rep.imported-by-us" ] \
    && ok "I1: THE OWNERSHIP MARKER SURVIVES THE RETRY" \
    || bad "I1: THE OWNERSHIP MARKER SURVIVES THE RETRY"
has "interrupted before it could export" "$out" \
    && ok "I2: ...and the run says WHY it still owns it" \
    || bad "I2: ...and the run says WHY it still owns it" "$out"

# 4. and this time detach must actually export.
: > "$EXPORTED_LOG"
out="$(g detach rotpool rep)"; rc=$?
check "I: the retry's detach exits 0" "0" "$rc"
check "I3: THE POOL IS EXPORTED, NOT LEFT LIVE" "rotpool" "$(cat "$EXPORTED_LOG")"
[ -f "$STATE/rep.imported-by-us" ] \
    && bad "I4: ...and the marker is cleared only AFTER that export" "marker still there" \
    || ok "I4: ...and the marker is cleared only AFTER that export"

# 5. THE OTHER SIDE. A foreign import with no marker of ours is still foreign.
: > "$EXPORTED_LOG"
rm -f "$STATE/rep.imported-by-us" 2>/dev/null || :
POOLS="hdd rotpool"; IMPORTABLE=""
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "I5: a foreign import is still recognised as foreign" "0" "$rc"
has "ALREADY imported" "$out" && ok "I5: ...and says so" || bad "I5: ...and says so" "$out"
out="$(g detach rotpool rep)"; rc=$?
check "I5: AND IS STILL NOT EXPORTED" "" "$(cat "$EXPORTED_LOG")"

# 6. A marker we cannot match to the pool in the slot. Rotated media share a
#    name, so this is a DIFFERENT disk while we still owe an export on another.
#    Fail closed: exporting would hit the wrong disk, and clearing the marker
#    would throw away the only record that an export is owed.
: > "$EXPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; POOL_GUID=11111111
g attach rotpool rep --dataset rotpool/replica >/dev/null 2>&1
POOLS="hdd rotpool"; IMPORTABLE=""; POOL_GUID=99999999    # a different disk, same name
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "I6: AN UNMATCHABLE MARKER FAILS CLOSED" "2" "$rc"
check "I6: ...exporting nothing" "" "$(cat "$EXPORTED_LOG")"
[ -f "$STATE/rep.imported-by-us" ] \
    && ok "I6: ...and keeping the evidence that an export is still owed" \
    || bad "I6: ...and keeping the evidence that an export is still owed"

# I7. THE HALF THAT WAS MISSING, and the reviewer was right that its absence made
#     I6 prove less than it looked like it proved.
#
#     `detach` runs OUTSIDE the generated bracket's `if` -- deliberately, so a
#     failed transfer still puts the pool back. So the run does not stop at
#     attach's refusal: detach executes two statements later, on the very medium
#     attach just refused. It used to ask only whether the marker FILE existed,
#     and would therefore export that wrong disk and delete the marker recording
#     what we still owe an export on. The refusal was undone by the next line.
#
#     Driven through the REAL gate, both verbs, with the wrong medium still in
#     the slot -- not through the bracket's stubs, which cannot show an export
#     that should not have happened.
: > "$EXPORTED_LOG"
out="$(g detach rotpool rep)"; rc=$?
check "I7: DETACH REFUSES THE MEDIUM ATTACH JUST REFUSED" "2" "$rc"
check "I7: ...AND EXPORTS NOTHING" "" "$(cat "$EXPORTED_LOG")"
[ -f "$STATE/rep.imported-by-us" ] \
    && ok "I7: ...and the ownership marker SURVIVES the refusal" \
    || bad "I7: ...and the ownership marker SURVIVES the refusal" "it was deleted"
has "does not match the pool currently imported" "$out" \
    && ok "I7: ...saying which guid it holds and which it found" \
    || bad "I7: ...saying which guid it holds and which it found" "$out"

# I8. The medium was pulled while we still held it. Nothing can be exported --
#     the pool went with the disk -- but an unclean removal is exactly the event
#     that can leave that copy needing a scrub, and nothing else would mention
#     it. The marker is still cleared, or every later run would fail closed for
#     a disk that no longer exists.
: > "$EXPORTED_LOG"
POOLS="hdd"; IMPORTABLE=""; POOL_GUID=11111111
printf 'pool=rotpool\nguid=11111111\n' > "$STATE/rep.imported-by-us"
out="$(g detach rotpool rep)"; rc=$?
check "I8: a medium pulled while held is not an error" "0" "$rc"
has "removed without a detach" "$out" \
    && ok "I8: ...but it IS said out loud" \
    || bad "I8: ...but it IS said out loud" "$out"
[ -f "$STATE/rep.imported-by-us" ] \
    && bad "I8: ...and the marker is cleared, or every later run fails closed" "still there" \
    || ok "I8: ...and the marker is cleared, or every later run fails closed"

rm -f "$STATE/rep.imported-by-us" 2>/dev/null || :
POOL_GUID=11111111

# ---------------------------------------------------------------------------
# J. WHAT A MEDIUM PULLED MID-RUN DOES, and why detach must be bounded
#
# Measured on pve9, 2026-08-29, by actually pulling the device out from under a
# running kernel (`echo 1 > /sys/block/sdX/device/delete`, which is as close to a
# yanked cable as a VM gets):
#
#   * pulled between runs, pool exported     no harm
#   * pulled with the pool imported, idle    `zpool export` sat in
#                                            uninterruptible sleep for ELEVEN
#                                            MINUTES, unkillable; re-inserting
#                                            the disk did not free it, because
#                                            the kernel gave it a NEW device node
#   * pulled DURING a 300 MB write           the whole HOST went unreachable and
#                                            needed a hard reset
#
# The third is arithmetic, not fragility: zfs_txg_timeout was 5s and
# zfs_dirty_data_max 393 MB on that host, so the entire payload was in RAM with
# nowhere to go when the vdev vanished.
#
# What makes the second one a PACKAGE problem rather than a ZFS one: `detach`
# runs OUTSIDE the generated bracket's `if`, so a cron job that meets it hangs
# forever -- holding its flock, refusing every later run as contended, and never
# alerting, because a job that never exits never reports a status.
# ---------------------------------------------------------------------------
: > "$EXPORTED_LOG"
POOLS="hdd rotpool"; IMPORTABLE=""; DATASETS="hdd rotpool/replica"; POOL_GUID=11111111
printf 'pool=rotpool\nguid=11111111\n' > "$STATE/rep.imported-by-us"
EXPORT_HANGS=1
out="$(MEDIA_EXPORT_TIMEOUT=1 g detach rotpool rep)"; rc=$?
EXPORT_HANGS=""
check "J1: AN EXPORT THAT NEVER RETURNS IS ABANDONED, NOT WAITED ON" "2" "$rc"
has "DO NOT UNPLUG" "$out" && ok "J1: ...still saying DO NOT UNPLUG" \
                           || bad "J1: ...still saying DO NOT UNPLUG" "$out"
has "did not finish within" "$out" && ok "J1: ...and that it was a timeout, not a refusal" \
                                   || bad "J1: ...and that it was a timeout, not a refusal" "$out"
has "pulled DURING a run" "$out" && ok "J1: ...naming the cause an operator can act on" \
                                 || bad "J1: ...naming the cause an operator can act on" "$out"
rm -f "$STATE/rep.imported-by-us" 2>/dev/null || :

# J2. failmode. Warned on import, never rewritten: it is a property of the
#     administrator's pool, and silently changing how someone else's data behaves
#     under failure is not this tool's call.
: > "$EXPORTED_LOG"; : > "$IMPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; POOL_FAILMODE=wait
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
check "J2: a wait-failmode medium still imports" "0" "$rc"
has "failmode=wait" "$out" && ok "J2: ...but the foot-gun is named" \
                           || bad "J2: ...but the foot-gun is named" "$out"
has "zpool set failmode=continue" "$out" && ok "J2: ...with the command that changes it" \
                                         || bad "J2: ...with the command that changes it" "$out"
POOLS="hdd rotpool"; IMPORTABLE=""
g detach rotpool rep >/dev/null 2>&1

# J3. THE NEGATIVE SIDE. A pool already set to continue is not nagged about it.
: > "$IMPORTED_LOG"
POOLS="hdd"; IMPORTABLE="rotpool"; POOL_FAILMODE=continue
out="$(g attach rotpool rep --dataset rotpool/replica)"; rc=$?
has "failmode=wait" "$out" && bad "J3: a pool already on continue is NOT nagged" "$out" \
                           || ok "J3: a pool already on continue is NOT nagged"
POOLS="hdd rotpool"; IMPORTABLE=""
g detach rotpool rep >/dev/null 2>&1
POOL_FAILMODE=""

# K. THE SENTENCE FOR THE PERSON STANDING AT THE MACHINE.
#
# Nothing in software can make a surprise removal safe -- the lab spent three
# host resets establishing that, and upstream OpenZFS has open issues for it.
# What CAN be done is to say which side of the window you are on, in words, so
# that "is it safe to pull this?" has an answer that is not a guess.
: > "$EXPORTED_LOG"
POOLS="hdd rotpool"; IMPORTABLE=""; DATASETS="hdd rotpool/replica"
out="$(g status rotpool rep --dataset rotpool/replica)"
has "DO NOT UNPLUG" "$out" && ok "K: an IMPORTED medium says DO NOT UNPLUG" \
                           || bad "K: an IMPORTED medium says DO NOT UNPLUG" "$out"
has "hang this host" "$out" && ok "K: ...and what pulling it now would cost" \
                            || bad "K: ...and what pulling it now would cost" "$out"
POOLS="hdd"; IMPORTABLE="rotpool"
out="$(g status rotpool rep --dataset rotpool/replica)"
has "SAFE TO UNPLUG" "$out" && ok "K: A MEDIUM WHOSE POOL IS NOT IMPORTED SAYS SAFE TO UNPLUG" \
                            || bad "K: A MEDIUM WHOSE POOL IS NOT IMPORTED SAYS SAFE TO UNPLUG" "$out"
has "DO NOT UNPLUG" "$out" && bad "K: ...and does NOT also say the opposite" "$out" \
                           || ok "K: ...and does NOT also say the opposite"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
