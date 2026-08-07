#!/bin/bash
# Regression tests for check-snap-age.sh (REV-20260807-056).
#
# Deterministic by construction: `zfs` is a stub on PATH whose answers come from
# files this script writes, and every timestamp is computed as an offset from
# ONE captured NOW. Nothing here needs root, ZFS, or luck with the clock -- a
# suite that sleeps to age a snapshot fails on a slow machine and gets muted.
#
# The stub answers exactly the three calls the script makes:
#   zfs list -H -o name -t filesystem,volume <ds>        does it exist
#   zfs list -H -o name -s creation -t snapshot <ds>     its snapshots
#   zfs list -H -o name -t filesystem,volume -r <ds>     subtree walk
#   zfs get -H -p -o value creation <ds|snap>            a timestamp
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="${CHK:-$DIR/../../check-snap-age.sh}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want='$2' got='$3'"; fi; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
NOW=$(date +%s)

cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/bash
# Data files: $Z/datasets (one name per line), $Z/snaps.<mangled ds> (snapshot
# names, oldest first), $Z/epoch.<mangled thing> (a creation value, or the
# literal MISSING to make the read fail).
Z="$ZSTUB_DIR"
mangle() { printf '%s' "$1" | tr '/@' '__'; }
mode=""; recurse=0; target=""; prop=""
while [ $# -gt 0 ]; do
    case "$1" in
        list) mode=list; shift ;;
        get)  mode=get; shift ;;
        -H|-p) shift ;;
        -o) [ "$mode" = get ] && shift 2 || shift 2 ;;
        -s) shift 2 ;;
        -t) case "$2" in snapshot) mode="${mode}snap" ;; esac; shift 2 ;;
        -r) recurse=1; shift ;;
        creation) prop=creation; shift ;;
        *) target="$1"; shift ;;
    esac
done
case "$mode" in
    list)
        if [ "$recurse" = 1 ]; then
            grep -E "^${target}(/|$)" "$Z/datasets" 2>/dev/null
        else
            grep -qxF "$target" "$Z/datasets" 2>/dev/null || exit 1
            printf '%s\n' "$target"
        fi ;;
    listsnap)
        f="$Z/snaps.$(mangle "$target")"
        [ -f "$f" ] && sed "s|^|${target}@|" "$f"
        exit 0 ;;
    get)
        f="$Z/epoch.$(mangle "$target")"
        [ -f "$f" ] || exit 1
        v="$(cat "$f")"
        [ "$v" = MISSING ] && exit 1
        printf '%s\n' "$v" ;;
esac
exit 0
STUB
chmod +x "$TMPD/bin/zfs"
export ZSTUB_DIR="$TMPD/z"
export PATH="$TMPD/bin:$PATH"

reset_world() { rm -rf "$ZSTUB_DIR"; mkdir -p "$ZSTUB_DIR"; : > "$ZSTUB_DIR/datasets"; }
mangle() { printf '%s' "$1" | tr '/@' '__'; }
add_ds()    { echo "$1" >> "$ZSTUB_DIR/datasets"; echo "$((NOW - $2))" > "$ZSTUB_DIR/epoch.$(mangle "$1")"; }
add_snap()  { echo "$2" >> "$ZSTUB_DIR/snaps.$(mangle "$1")"; echo "$((NOW - $3))" > "$ZSTUB_DIR/epoch.$(mangle "$1@$2")"; }
break_epoch(){ echo MISSING > "$ZSTUB_DIR/epoch.$(mangle "$1")"; }

H=3600
run() { "$CHK" "$@" 2>&1; }
rc_of() { "$CHK" "$@" >/dev/null 2>&1; echo $?; }

# ---- A. the new rule: age comes from the dataset when nothing matches -------
# warn=2h crit=4h throughout, so the bands are unambiguous.
for t in "A1-below-warn:1:0:OK" "A2-between:3:1:WARNING" "A3-above-crit:5:2:CRITICAL"; do
    name="${t%%:*}"; rest="${t#*:}"; age="${rest%%:*}"; rest="${rest#*:}"
    wantrc="${rest%%:*}"; wantlabel="${rest##*:}"
    reset_world
    add_ds tank/fresh $((age * H))
    add_snap tank/fresh "__replicate_1__" $((age * H))   # exists, does not match
    check "$name rc" "$wantrc" "$(rc_of -v tank/fresh automated_ 2h 4h)"
    out="$(run -v tank/fresh automated_ 2h 4h)"
    case "$out" in "$wantlabel"*) ok "$name label=$wantlabel" ;; *) bad "$name label=$wantlabel" "$out" ;; esac
    case "$out" in *"age measured from dataset creation"*) ok "$name states provenance" ;;
      *) bad "$name states provenance" "$out" ;; esac
done

# A4: a matching snapshot still wins -- an OLD dataset with a FRESH backup is OK.
# Without this the new rule could quietly replace the old one instead of
# covering the gap in it.
reset_world
add_ds tank/old $((100 * H))
add_snap tank/old "automated_now" $((1 * H))
check "A4 fresh matching snapshot beats old dataset" "0" "$(rc_of tank/old automated_ 2h 4h)"

# ---- B. the same ladder for explicit and discovered datasets ---------------
reset_world
add_ds tank/p 0
add_ds tank/p/child $((5 * H))
add_snap tank/p/child "vzdump-1" $((5 * H))
check "B1 discovered descendant uses the ladder" "2" "$(rc_of -R tank/p automated_ 2h 4h)"
check "B2 explicit target uses the same ladder" "2" "$(rc_of tank/p/child automated_ 2h 4h)"

# B3: container leniency is untouched -- a node with NO snapshots at all, found
# by -R, stays silent however old it is.
reset_world
add_ds tank/c $((500 * H))
add_ds tank/c/leaf $((500 * H))
add_snap tank/c/leaf "automated_x" 0
check "B3 empty container node still SKIPs" "0" "$(rc_of -R tank/c automated_ 2h 4h)"
case "$(run -v -R tank/c automated_ 2h 4h)" in
  *"SKIP dataset=tank/c "*) ok "B3 says it skipped it" ;;
  *) bad "B3 says it skipped it" "$(run -v -R tank/c automated_ 2h 4h)" ;;
esac

# B4: an EXPLICIT dataset with no snapshots at all is still judged, not skipped.
reset_world
add_ds tank/never $((500 * H))
check "B4 explicit dataset with no snapshots at all is judged" "2" "$(rc_of tank/never automated_ 2h 4h)"

# ---- C. unreadable timestamps are UNKNOWN, never a fabricated age ----------
reset_world
add_ds tank/badcreate $((5 * H))
add_snap tank/badcreate "vzdump-1" $((5 * H))
break_epoch tank/badcreate
check "C1 unreadable dataset creation -> UNKNOWN" "3" "$(rc_of tank/badcreate automated_ 2h 4h)"
case "$(run tank/badcreate automated_ 2h 4h)" in
  *"creation time could not be read"*) ok "C1 says why" ;; *) bad "C1 says why" "$(run tank/badcreate automated_ 2h 4h)" ;;
esac

# C2 is the pre-existing bug REV-056 §5 required closing in the same change:
# the MATCHING-snapshot path had the same unguarded arithmetic, so a failed
# read became an age of the whole Unix epoch and a CRITICAL nobody measured.
reset_world
add_ds tank/badsnap 0
add_snap tank/badsnap "automated_x" 0
break_epoch "tank/badsnap@automated_x"
check "C2 unreadable SNAPSHOT creation -> UNKNOWN (was a fabricated CRITICAL)" "3" \
      "$(rc_of tank/badsnap automated_ 2h 4h)"
out="$(run tank/badsnap automated_ 2h 4h)"
case "$out" in *"could not be read"*) ok "C2 says why" ;; *) bad "C2 says why" "$out" ;; esac
case "$out" in *CRITICAL*) bad "C2 does not report a fabricated CRITICAL" "$out" ;;
  *) ok "C2 does not report a fabricated CRITICAL" ;; esac

# ---- D. aggregate semantics across a mixed run -----------------------------
# CRITICAL outranks UNKNOWN; UNKNOWN outranks WARNING. Unchanged by this work,
# and worth pinning precisely because the new UNKNOWN path feeds into it.
reset_world
add_ds tank/okd 0;    add_snap tank/okd "automated_x" 0
add_ds tank/warn $((3 * H)); add_snap tank/warn "vzdump-1" $((3 * H))
add_ds tank/unk $((3 * H));  add_snap tank/unk "vzdump-1" $((3 * H)); break_epoch tank/unk
check "D1 WARNING + UNKNOWN -> UNKNOWN wins" "3" "$(rc_of tank/warn,tank/unk automated_ 2h 4h)"
add_ds tank/crit $((9 * H)); add_snap tank/crit "vzdump-1" $((9 * H))
check "D2 CRITICAL + UNKNOWN -> CRITICAL wins" "2" "$(rc_of tank/crit,tank/unk automated_ 2h 4h)"
check "D3 OK alone stays OK" "0" "$(rc_of tank/okd automated_ 2h 4h)"

# ---- E. cron silence ------------------------------------------------------
# Below warn, a fresh dataset must print NOTHING without -v: the daily digest
# is the thing this whole change exists to keep honest.
reset_world
add_ds tank/quiet 0
add_snap tank/quiet "vzdump-1" 0
out="$(run tank/quiet automated_ 2h 4h)"
check "E1 below-warn is silent without -v" "" "$out"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
