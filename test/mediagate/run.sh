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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
