#!/bin/bash
# The frozen engines compose no command from text. Until 2026-09-03 they did,
# in six places: tune_probe_stream's sampled send (three evals on a command
# string inside its sh -c snippet), announce_transfer_size's local dry run
# (`eval "$dry"`, in both engines) and snapsend's received-subtree canmount
# (`eval "$canmount_cmd"`). Each was a string built for ssh and then executed
# in the engine's own shell for the local case. Owner direction of 2026-09-03
# ("odmrożenie silników pod sześć eval"): the string is only for ssh now; the
# local side runs code.
#
# Pure text, no ZFS: the engines' functions are lifted by anchor and run
# against a stub `zfs` that records what it was asked to do. The live proof
# (a real transfer with a tty, a real -r receive, a real -A probe) is the lab
# in docs/discussions/LAB-ENGINE-EVAL-2026-09-03.md.
#
#   test/evalfree/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSEND="${SNAPSEND:-$REPO/snapsend.sh}"
SNAPGET="${SNAPGET:-$REPO/snapget.sh}"
LIBZFS="${LIBZFS:-$REPO/lib-zfs-snap.sh}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../harness.sh"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# ---- 1. the count: no eval in any frozen engine file -------------------------
# Comment lines mentioning the word are not sites. On the tree before the
# change: snapsend 2, snapget 1, lib-zfs-snap 3.
for f in "$SNAPSEND" "$SNAPGET" "$LIBZFS" "$(dirname "$SNAPSEND")/delsnaps.sh" "$(dirname "$SNAPSEND")/check-snap-age.sh"; do
    n=$(grep -v '^[[:space:]]*#' "$f" | grep -c '\beval\b')
    if [ "$n" -eq 0 ]; then ok "count: $(basename "$f") composes no command from text (0 eval sites)"
    else bad "count: $(basename "$f") composes no command from text (0 eval sites)" "$n site(s):" "$(grep -v '^[[:space:]]*#' "$f" | grep -n '\beval\b' | head -3)"; fi
done

# ---- 2. announce_transfer_size: the local dry run is words, not a string ----
#
# The function returns before doing anything unless stderr is a terminal, so
# the probe runs under script(1) to get one. The stub `zfs` records its argv
# and answers a size line; the send command carries a name with shell syntax
# in it. With eval (main) the substitution RUNS and leaves a marker; with the
# word split it reaches the stub as a name, like any other word.
mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ZFS_LOG"
echo "size 4096"
STUB
chmod +x "$TMPD/bin/zfs"
if ! command -v script >/dev/null 2>&1; then
    echo "SKIP announce: no script(1) to lend the probe a terminal"
else
    for eng in "$SNAPSEND" "$SNAPGET"; do
        name=$(basename "$eng")
        cat > "$TMPD/probe-$name.sh" <<PROBE
set -u
log() { shift; printf '%s\n' "\$*"; }
SSH_OPTS=()
$(product_fn "$eng" human_bytes)
$(product_fn "$eng" announce_transfer_size)
announce_transfer_size 'zfs send -X y tank/a@s\$(touch "\$MARKER")' "" ""
PROBE
        : > "$TMPD/zfs-$name.log"; rm -f "$TMPD/marker-$name"
        out=$(ZFS_LOG="$TMPD/zfs-$name.log" MARKER="$TMPD/marker-$name" PATH="$TMPD/bin:$PATH" \
              script -qec "bash '$TMPD/probe-$name.sh'" /dev/null 2>&1 | tr -d '\r')
        if grep -q 'about to move' <<< "$out"; then
            ok "announce/$name: the dry run answered and the size was announced"
        else
            bad "announce/$name: the dry run answered and the size was announced" "$out"
        fi
        if grep -qxF 'send -nP -X y tank/a@s$(touch "$MARKER")' "$TMPD/zfs-$name.log"; then
            ok "announce/$name: zfs got -nP spliced in and every other word verbatim, the shell syntax included"
        else
            bad "announce/$name: zfs got -nP spliced in and every other word verbatim, the shell syntax included" "$(cat "$TMPD/zfs-$name.log")"
        fi
        if [ ! -e "$TMPD/marker-$name" ]; then
            ok "announce/$name: nothing inside the name was executed (no eval)"
        else
            bad "announce/$name: nothing inside the name was executed (no eval)" "marker exists: the dry run went through eval"
        fi
    done
fi

# ---- 3. the received subtree's canmount: code locally, the same text for ssh --
cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/bash
case "$1" in
  list) printf '%s\n' "$ZFS_LISTING" ;;
  set)  printf '%s\n' "$*" >> "$ZFS_LOG" ;;
esac
STUB
run_local() {
    ( set -u
      eval "$(product_fn "$SNAPSEND" canmount_noauto_subtree)"
      canmount_noauto_subtree "$1" )
}
run_remote_text() {   # what ssh would run, executed by a plain sh
    ( set -u
      eval "$(product_fn "$SNAPSEND" canmount_noauto_subtree_cmd)"
      sh -c "$(canmount_noauto_subtree_cmd "$1")" )
}
export ZFS_LISTING=$'hdd/bk/vm\nhdd/bk/vm/disk 0\nhdd/bk/vm/disk-1'
want=$'set canmount=noauto hdd/bk/vm\nset canmount=noauto hdd/bk/vm/disk 0\nset canmount=noauto hdd/bk/vm/disk-1'
: > "$TMPD/set-local.log"
ZFS_LOG="$TMPD/set-local.log" PATH="$TMPD/bin:$PATH" run_local "hdd/bk/vm"
if [ "$(cat "$TMPD/set-local.log")" = "$want" ]; then
    ok "canmount: the local code sets noauto on every listed filesystem, a name with a space included"
else
    bad "canmount: the local code sets noauto on every listed filesystem, a name with a space included" "$(cat "$TMPD/set-local.log")"
fi
: > "$TMPD/set-remote.log"
ZFS_LOG="$TMPD/set-remote.log" PATH="$TMPD/bin:$PATH" run_remote_text "hdd/bk/vm"
if [ "$(cat "$TMPD/set-remote.log")" = "$want" ]; then
    ok "canmount: the text ssh carries does the same on the same listing (the two spellings agree)"
else
    bad "canmount: the text ssh carries does the same on the same listing (the two spellings agree)" "$(cat "$TMPD/set-remote.log")"
fi
# And the text is still what the remote side has always been sent.
txt=$( eval "$(product_fn "$SNAPSEND" canmount_noauto_subtree_cmd)"; canmount_noauto_subtree_cmd "hdd/bk/vm" )
if [ "$txt" = "zfs list -H -o name -t filesystem -r 'hdd/bk/vm' 2>/dev/null | while IFS= read -r d; do zfs set canmount=noauto \"\$d\" 2>/dev/null; done" ]; then
    ok "canmount: the remote one-liner is byte-identical to the one the engine shipped before"
else
    bad "canmount: the remote one-liner is byte-identical to the one the engine shipped before" "$txt"
fi
# transfer_data must call the pair, not a string of its own.
if grep -q 'canmount_noauto_subtree "\$tgt_dataset"' "$SNAPSEND" && grep -q 'canmount_noauto_subtree_cmd "\$tgt_dataset"' "$SNAPSEND" && ! grep -q 'canmount_cmd=' "$SNAPSEND"; then
    ok "canmount: transfer_data calls the code locally and the text over ssh, and no canmount_cmd string remains"
else
    bad "canmount: transfer_data calls the code locally and the text over ssh, and no canmount_cmd string remains" "$(grep -n 'canmount_noauto_subtree\|canmount_cmd' "$SNAPSEND" | head -5)"
fi

# ---- 4. tune_probe_stream: the sampled send is a function in the snippet -----
body=$(product_fn "$LIBZFS" tune_probe_stream | grep -v '^[[:space:]]*#')
if printf '%s' "$body" | grep -q 'h() { zfs send "\$snap"' && ! printf '%s' "$body" | grep -q '\beval\b'; then
    ok "probe: tune_probe_stream samples through a shell function, not an eval'd command string"
else
    bad "probe: tune_probe_stream samples through a shell function, not an eval'd command string" "$(printf '%s' "$body" | grep -n 'eval\|H=' | head -3)"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
