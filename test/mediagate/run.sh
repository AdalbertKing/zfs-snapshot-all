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
case "$1 $2" in
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
export POOLS IMPORTABLE DATASETS EXPORT_FAILS=""
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
