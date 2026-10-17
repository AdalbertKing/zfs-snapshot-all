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
# Every call is traced (F: the remote mode must only list/get). Knobs for the
# F4 failure shapes: ZSTUB_SNAP_RC = exit status of the snapshot list AFTER it
# printed its lines (partial output + failure); ZSTUB_WALK_RC = the same for the
# -R walk; ZSTUB_JUNK = a line that is not a snapshot of the dataset.
[ -n "${ZSTUB_TRACE:-}" ] && echo "${REMOTE_HOST:+$REMOTE_HOST:}zfs $*" >> "$ZSTUB_TRACE"
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
            # F4.2 shapes of an rc-0 walk that is not complete: EMPTY prints
            # nothing, NOROOT drops the root's own line. WALK_JUNK appends a line.
            if [ -n "${ZSTUB_WALK_EMPTY:-}" ]; then :
            elif [ -n "${ZSTUB_WALK_NOROOT:-}" ]; then grep -E "^${target}/" "$Z/datasets" 2>/dev/null
            else grep -E "^${target}(/|$)" "$Z/datasets" 2>/dev/null; fi
            [ -n "${ZSTUB_WALK_JUNK:-}" ] && echo "$ZSTUB_WALK_JUNK"
            exit "${ZSTUB_WALK_RC:-0}"
        else
            grep -qxF "$target" "$Z/datasets" 2>/dev/null || exit 1
            printf '%s\n' "$target"
        fi ;;
    listsnap)
        f="$Z/snaps.$(mangle "$target")"
        [ -f "$f" ] && sed "s|^|${target}@|" "$f"
        [ -n "${ZSTUB_JUNK:-}" ] && echo "$ZSTUB_JUNK"
        exit "${ZSTUB_SNAP_RC:-0}" ;;
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

# ---- F. REV-20261017-152 round 2: remote datasets, every read checked ------
# An ssh stub on PATH: records its argv, can fail like ssh (255) or like the
# pair gate (93), optionally only from its N-th call on (a probe that succeeds,
# then a read that does not), and otherwise runs the remote command against the
# same zfs stub -- with the host's OWN data dir when $ZSTUB_ROOT/<host> exists,
# so two endpoints can answer differently. REMOTE_HOST marks remote calls in
# the zfs trace.
cat > "$TMPD/bin/ssh" <<'SSH'
#!/bin/bash
echo "SSH $*" >> "$SSH_LOG"
n=$(($(cat "$SSH_LOG.n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$SSH_LOG.n"
while [ $# -gt 0 ]; do
    case "$1" in -n) shift ;; -o|-p|-i|-c) shift 2 ;; -*) shift ;; *) break ;; esac
done
dest="$1"; shift; host="${dest#*@}"
[ -n "${SSH_HANG:-}" ] && exec sleep 30
if [ -n "${SSH_RC:-}" ] && [ "$n" -ge "${SSH_FROM:-1}" ]; then
    [ "$SSH_RC" = 93 ] && echo "PAIR_DISABLED: relationship disabled" >&2
    exit "$SSH_RC"
fi
d="$ZSTUB_DIR"; [ -d "$ZSTUB_ROOT/$host" ] && d="$ZSTUB_ROOT/$host"
REMOTE_HOST="$host" ZSTUB_DIR="$d" bash -c "$*"
SSH
chmod +x "$TMPD/bin/ssh"
export SSH_LOG="$TMPD/ssh.log" ZSTUB_TRACE="$TMPD/ztrace" ZSTUB_ROOT="$TMPD/hosts"
fresh_trace() { : > "$SSH_LOG"; rm -f "$SSH_LOG.n"; : > "$ZSTUB_TRACE"; }
only_reads() { ! grep -vE '^([^ ]+:)?zfs (list|get) ' "$ZSTUB_TRACE" | grep -q .; }

# F1 the ordinary verdicts, read over ssh: OK, stale, no-match (dataset age).
reset_world; fresh_trace
add_ds tank/vm 0; add_snap tank/vm "zsalab_1" $((1 * H))
check "F1 remote fresh snapshot -> OK" "0" "$(rc_of root@srcA:tank/vm zsalab_ 2h 4h)"
case "$(grep -c '^srcA:zfs' "$ZSTUB_TRACE")" in 0) bad "F1 the reads ran on the remote host" "$(cat "$ZSTUB_TRACE")" ;; *) ok "F1 the reads ran on the remote host" ;; esac
grep -q '^zfs ' "$ZSTUB_TRACE" && bad "F1 nothing was read locally" "$(cat "$ZSTUB_TRACE")" || ok "F1 nothing was read locally"
reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" $((5 * H))
check "F1 remote stale snapshot -> CRITICAL" "2" "$(rc_of root@srcA:tank/vm zsalab_ 2h 4h)"
reset_world; add_ds tank/vm $((3 * H)); add_snap tank/vm "__replicate_1__" 0
check "F1 remote no-match -> dataset age (WARNING)" "1" "$(rc_of root@srcA:tank/vm zsalab_ 2h 4h)"

# F2 ssh options: the same five as delsnaps, plus non-interactive and bounded.
reset_world; fresh_trace; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
rc_of -p 2222 -k /kh -c aes128-ctr -K /key -O HostKeyAlias=zfs-client-a zbk@srcA:tank/vm zsalab_ 2h 4h >/dev/null
L="$(head -1 "$SSH_LOG")"
case "$L" in
  "SSH -n -o IdentitiesOnly=yes -i /key -o HostKeyAlias=zfs-client-a -o StrictHostKeyChecking=yes "*) ok "F2 -K/-O at the front, before the built options (OpenSSH keeps the first value)" ;;
  *) bad "F2 -K/-O at the front" "$L" ;;
esac
for want in "-n" "StrictHostKeyChecking=yes" "UserKnownHostsFile=/kh" "-p 2222" "-c aes128-ctr" "BatchMode=yes" "ConnectTimeout=15" "ServerAliveInterval=15" "zbk@srcA"; do
    case "$L" in *"$want"*) ok "F2 ssh carries $want" ;; *) bad "F2 ssh carries $want" "$L" ;; esac
done

# F3 failures to ASK are UNKNOWN and say which -- never OK, never a dataset age.
for t in "255:could not reach srcA over ssh" "93:pair gate refuses"; do
    code="${t%%:*}"; why="${t#*:}"
    reset_world; fresh_trace; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
    check "F3 ssh exit $code on the probe -> UNKNOWN" "3" "$(SSH_RC=$code rc_of root@srcA:tank/vm zsalab_ 2h 4h)"
    out="$(SSH_RC=$code run root@srcA:tank/vm zsalab_ 2h 4h)"
    case "$out" in *"$why"*) ok "F3 exit $code says: $why" ;; *) bad "F3 exit $code says: $why" "$out" ;; esac
done
# probe succeeds, the snapshot list then fails (dropped link): UNKNOWN, not dataset age
reset_world; fresh_trace; add_ds tank/vm $((9 * H))
check "F3 probe OK, snapshot list fails over ssh -> UNKNOWN (not dataset-age CRITICAL)" "3" \
      "$(SSH_RC=255 SSH_FROM=2 rc_of root@srcA:tank/vm zsalab_ 2h 4h)"

# F4 failure AFTER partial output, local and remote: the lines printed before the
# failure are not trusted -- the fresh snapshot among them must not paint it OK.
for where in "tank/vm" "root@srcA:tank/vm"; do
    reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
    check "F4 snapshot list prints, then fails ($where) -> UNKNOWN" "3" "$(ZSTUB_SNAP_RC=1 rc_of "$where" zsalab_ 2h 4h)"
    out="$(ZSTUB_SNAP_RC=1 run "$where" zsalab_ 2h 4h)"
    case "$out" in *"snapshot list could not be read"*) ok "F4 ($where) says why" ;; *) bad "F4 ($where) says why" "$out" ;; esac
done
reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
check "F4 a snapshot-list line that is not this dataset's -> UNKNOWN" "3" "$(ZSTUB_JUNK='other/ds@zsalab_9' rc_of root@srcA:tank/vm zsalab_ 2h 4h)"

# F5 -R walk: its failure is UNKNOWN (it used to check no children, silently).
for where in "tank/p" "root@srcA:tank/p"; do
    reset_world; add_ds tank/p 0; add_ds tank/p/a 0; add_snap tank/p/a "zsalab_1" 0
    check "F5 -R walk fails ($where) -> UNKNOWN" "3" "$(ZSTUB_WALK_RC=1 rc_of -R "$where" zsalab_ 2h 4h)"
    out="$(ZSTUB_WALK_RC=1 run -R "$where" zsalab_ 2h 4h)"
    case "$out" in *"descendants could not be listed"*) ok "F5 ($where) says why" ;; *) bad "F5 ($where) says why" "$out" ;; esac
    check "F5 -R walk OK ($where) -> OK" "0" "$(rc_of -R "$where" zsalab_ 2h 4h)"
done

# F6 malformed epoch over ssh, absent remote dataset: UNKNOWN.
reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0; break_epoch "tank/vm@zsalab_1"
check "F6 remote unreadable snapshot creation -> UNKNOWN" "3" "$(rc_of root@srcA:tank/vm zsalab_ 2h 4h)"
reset_world
check "F6 remote dataset absent -> UNKNOWN" "3" "$(rc_of root@srcA:tank/gone zsalab_ 2h 4h)"
case "$(run root@srcA:tank/gone zsalab_ 2h 4h)" in *"does not exist"*) ok "F6 says it does not exist" ;; *) bad "F6 says it does not exist" "$(run root@srcA:tank/gone zsalab_ 2h 4h)" ;; esac

# F7 two endpoints in one run, each answering for itself; mixed verdicts keep every UNKNOWN.
reset_world; fresh_trace
mkdir -p "$ZSTUB_ROOT/srcA" "$ZSTUB_ROOT/srcB"
( ZSTUB_DIR="$ZSTUB_ROOT/srcA"; : > "$ZSTUB_DIR/datasets"; echo tank/vm >> "$ZSTUB_DIR/datasets"; echo "$NOW" > "$ZSTUB_DIR/epoch.tank_vm"
  echo zsalab_1 > "$ZSTUB_DIR/snaps.tank_vm"; echo "$((NOW - 9 * H))" > "$ZSTUB_DIR/epoch.tank_vm_zsalab_1" )
( ZSTUB_DIR="$ZSTUB_ROOT/srcB"; : > "$ZSTUB_DIR/datasets" )
out="$(run root@srcA:tank/vm,root@srcB:tank/vm zsalab_ 2h 4h)"; rc=$(rc_of root@srcA:tank/vm,root@srcB:tank/vm zsalab_ 2h 4h)
check "F7 CRITICAL on A + UNKNOWN on B -> rc CRITICAL" "2" "$rc"
case "$out" in *"CRITICAL dataset=root@srcA:tank/vm"*"UNKNOWN dataset=root@srcB:tank/vm"*) ok "F7 both findings are reported, each with its host" ;; *) bad "F7 both findings are reported, each with its host" "$out" ;; esac
rm -rf "$ZSTUB_ROOT"

# F8 names that would be shell syntax on the far side are refused before any ssh.
reset_world; fresh_trace
for e in "root@srcA:tank/vm';id;'" 'root@srcA:tank/$(id)' 'root;id@srcA:tank/vm' 'root@-oProxyCommand=x:tank/vm'; do
    check "F8 refused before any ssh: $e" "3" "$(rc_of "$e" zsalab_ 2h 4h)"
done
[ -s "$SSH_LOG" ] && bad "F8 no ssh was started" "$(cat "$SSH_LOG")" || ok "F8 no ssh was started"

# F10 a remote zfs that HANGS (sshd still answers keepalives) is bounded by a
# wall clock: UNKNOWN "timed out", not a monitor that never reports. And a
# remote host without zfs (exit 127) says so, it is not "does not exist".
if command -v timeout >/dev/null 2>&1; then
    reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
    out="$(SSH_HANG=1 CSA_SSH_TIMEOUT=2 run root@srcA:tank/vm zsalab_ 2h 4h)"; rc=$(SSH_HANG=1 CSA_SSH_TIMEOUT=2 rc_of root@srcA:tank/vm zsalab_ 2h 4h)
    check "F10 hanging remote read -> UNKNOWN" "3" "$rc"
    case "$out" in *"timed out"*) ok "F10 says it timed out" ;; *) bad "F10 says it timed out" "$out" ;; esac
else
    ok "F10 SKIP: no timeout(1) on this host (the script then relies on ssh keepalive alone)"
fi
reset_world
out="$(SSH_RC=127 run root@srcA:tank/vm zsalab_ 2h 4h)"
case "$out" in *"'zfs' was not found on srcA"*) ok "F10 remote exit 127 says zfs was not found, not 'does not exist'" ;; *) bad "F10 remote exit 127" "$out" ;; esac

# F11 REV-20261017-152 F4.1: a name READ BACK from the far side is data. A
# snapshot or a descendant that passes the old prefix check but carries a quote,
# a command separator or a command substitution must be UNKNOWN and must never
# reach a follow-up read: the ssh stub runs the command text in a real shell, so
# an injection leaves a marker. The valid controls (a snapshot name with a space,
# an ordinary child) still read normally.
MARK="$TMPD/injected"
for inj in "zsalab_'; touch $MARK; #" 'zsalab_$(touch '"$MARK"')' "zsalab_x;touch $MARK" "zsalab_\`touch $MARK\`"; do
    for where in "root@srcA:tank/vm" "tank/vm"; do
        reset_world; rm -f "$MARK"; add_ds tank/vm 0; add_snap tank/vm "zsalab_1" 0
        rc=$(ZSTUB_JUNK="tank/vm@$inj" rc_of -v "$where" zsalab_ 2h 4h)
        if [ "$rc" = 3 ] && [ ! -e "$MARK" ]; then ok "F11 snapshot '$inj' ($where) -> UNKNOWN, nothing executed"
        else bad "F11 snapshot '$inj' ($where) -> UNKNOWN, nothing executed" "rc=$rc marker=$([ -e "$MARK" ] && echo yes || echo no)"; fi
    done
    reset_world; rm -f "$MARK"; add_ds tank/p 0; add_snap tank/p "zsalab_1" 0
    out="$(ZSTUB_WALK_JUNK="tank/p/$inj" run -R root@srcA:tank/p zsalab_ 2h 4h)"; rc=$(ZSTUB_WALK_JUNK="tank/p/$inj" rc_of -R root@srcA:tank/p zsalab_ 2h 4h)
    if [ "$rc" = 3 ] && [ ! -e "$MARK" ] && printf '%s' "$out" | grep -q 'not a well-formed dataset under it'; then ok "F11 descendant 'tank/p/$inj' -> UNKNOWN, not checked, nothing executed"
    else bad "F11 descendant 'tank/p/$inj' -> UNKNOWN, nothing executed" "rc=$rc marker=$([ -e "$MARK" ] && echo yes || echo no) $out"; fi
done
reset_world; add_ds tank/vm 0; add_snap tank/vm "zsalab_with space" 0
check "F11 control: a snapshot name with a space (legal in OpenZFS) reads normally -> OK" "0" "$(rc_of root@srcA:tank/vm zsalab_ 2h 4h)"
reset_world; add_ds tank/p 0; add_ds tank/p/a 0; add_snap tank/p/a "zsalab_1" $((9 * H))
check "F11 control: an ordinary stale child is still read -> CRITICAL" "2" "$(rc_of -R root@srcA:tank/p zsalab_ 2h 4h)"

# F12 REV-20261017-152 F4.2: a COMPLETE -R walk names its root. An rc-0 answer
# that is empty or lacks the root is UNKNOWN -- it used to check no child and
# exit 0. The valid shapes stay as they were: a root-only container is OK, a
# stale child under a valid walk is CRITICAL, and CRITICAL outranks UNKNOWN.
for where in "root@srcA:tank/root" "tank/root"; do
    reset_world; add_ds tank/root 0; add_ds tank/root/a 0; add_snap tank/root/a "zsalab_1" $((9 * H))
    out="$(ZSTUB_WALK_EMPTY=1 run -R -v "$where" zsalab_ 2h 4h)"; rc=$(ZSTUB_WALK_EMPTY=1 rc_of -R "$where" zsalab_ 2h 4h)
    if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q 'does not contain the root itself'; then ok "F12 empty rc-0 walk ($where) -> UNKNOWN"
    else bad "F12 empty rc-0 walk ($where) -> UNKNOWN" "rc=$rc $out"; fi
    rc=$(ZSTUB_WALK_NOROOT=1 rc_of -R "$where" zsalab_ 2h 4h)
    check "F12 walk without its root ($where) -> UNKNOWN, even though the child it lists is stale" "3" "$rc"
    reset_world; add_ds tank/root 0
    check "F12 control: valid root-only container walk ($where) -> OK" "0" "$(rc_of -R "$where" zsalab_ 2h 4h)"
    reset_world; add_ds tank/root 0; add_ds tank/root/a 0; add_snap tank/root/a "zsalab_1" $((9 * H))
    check "F12 control: valid walk, stale child ($where) -> CRITICAL" "2" "$(rc_of -R "$where" zsalab_ 2h 4h)"
done
reset_world; add_ds tank/root 0; add_ds tank/crit 0; add_snap tank/crit "zsalab_1" $((9 * H))
out="$(ZSTUB_WALK_EMPTY=1 run -R root@srcA:tank/root,root@srcA:tank/crit zsalab_ 2h 4h)"; rc=$(ZSTUB_WALK_EMPTY=1 rc_of -R root@srcA:tank/root,root@srcA:tank/crit zsalab_ 2h 4h)
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'UNKNOWN dataset=root@srcA:tank/root'; then ok "F12 mixed: CRITICAL wins the exit code and the UNKNOWN walk is still printed"
else bad "F12 mixed CRITICAL/UNKNOWN" "rc=$rc $out"; fi

# F9 read-only: across every remote case above the zfs trace holds list/get only.
only_reads && ok "F9 the remote mode only ever ran 'zfs list' and 'zfs get'" || bad "F9 only list/get" "$(grep -vE '^([^ ]+:)?zfs (list|get) ' "$ZSTUB_TRACE")"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
