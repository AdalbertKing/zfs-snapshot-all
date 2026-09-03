#!/bin/bash
# Tests for deploy.sh --draft-scope's inventory/generation logic (REV-20260802-033
# slice 4): given a real ZFS pool layout, does the generated scope file activate
# the right defaults (non-system datasets one level below each pool) and list
# the complete inventory as comments.
#
# No root: the manifest/path preflight (do_draft_scope_check) is exercised via
# --draft-scope-check in test/join/run.sh instead. What only a real host could
# otherwise prove -- the actual `zpool list`/`zfs list` walk -- is exercised
# here against STUBBED zpool/zfs binaries, on the basis that this generator's
# own logic (pool iteration, system-name filtering, sorting, text formatting)
# is a plain text transformation, not the security-sensitive `zfs allow`/
# `unallow`/`holds` semantics do_commit_scope's grant loop deliberately leaves
# to live verification only (see docs/internal/reviews/responses/REV-20260802-033.md).
#
#   ./test/draftscope/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
[ -r "$DEPLOY_SRC" ] || { echo "cannot read deploy.sh at $DEPLOY_SRC" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin" "$TMPD/peers"

PASS=0; FAIL=0
check() {   # <desc> <want> <got>
    local d="$1" w="$2" g="$3"
    if [ "$g" = "$w" ]; then echo "PASS $d"; PASS=$((PASS+1))
    else echo "FAIL $d"; echo "     want: [$w]"; echo "     got:  [$g]"; FAIL=$((FAIL+1)); fi
}
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; echo "     $2"; FAIL=$((FAIL+1)); }

# ---- stub zpool/zfs: a fixed two-pool layout -------------------------------
# rpool: ROOT (system, excluded), data + olds (real candidates)
# hdd:   swap (system, excluded), LXC (real candidate)
cat > "$TMPD/bin/zpool" <<'EOF'
#!/bin/bash
# list -H -o name
printf 'hdd\nrpool\n'
EOF
cat > "$TMPD/bin/zfs" <<'EOF'
#!/bin/bash
fields="" pool="" type=""
while [ $# -gt 0 ]; do
    case "$1" in
        list) shift ;;
        -H|-r) shift ;;
        -o) fields="$2"; shift 2 ;;
        -t) type="$2"; shift 2 ;;
        -d) shift 2 ;;
        --) shift; pool="$1"; shift ;;
        *) shift ;;
    esac
done
if [ "$type" = "snapshot" ]; then
    case "$pool" in
        rpool) printf 'rpool/data@automated_hourly_2026-08-02_16-00-00\nrpool/data@automated_hourly_2026-08-02_17-00-00\nrpool/data@vzdump\n' ;;
        hdd)   printf 'hdd/LXC@__replicate_100-0_1785679201__\nhdd/LXC@__migration__\n' ;;
    esac
    exit 0
fi
case "$fields" in
    name)
        case "$pool" in
            rpool) printf 'rpool\nrpool/olds\nrpool/data\nrpool/ROOT\n' ;;
            hdd)   printf 'hdd\nhdd/swap\nhdd/LXC\n' ;;
            # A leaf answers with only itself; a container answers with its
            # children too. That difference is exactly what the draft reads to
            # decide include_parent, so the stub has to make it.
            rpool/data) printf 'rpool/data\n' ;;
            rpool/olds) printf 'rpool/olds\n' ;;
            hdd/LXC)    printf 'hdd/LXC\nhdd/LXC/subvol-100-disk-0\n' ;;
            *) : ;;
        esac
        ;;
    name,type,used,refer,mountpoint)
        case "$pool" in
            rpool) printf 'rpool\tfilesystem\t120G\t96K\tnone\nrpool/data\tfilesystem\t40G\t96K\t/rpool/data\nrpool/ROOT\tfilesystem\t8G\t96K\tnone\n' ;;
            hdd)   printf 'hdd\tfilesystem\t500G\t96K\tnone\nhdd/LXC\tfilesystem\t80G\t96K\t/hdd/LXC\nhdd/swap\tvolume\t8G\t8G\t-\n' ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$TMPD/bin/zpool" "$TMPD/bin/zfs"
export PATH="$TMPD/bin:$PATH"

export PEER_STATE_DIR="$TMPD/peers"

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }
# The extracted block reads the manifest through record_load, as deploy.sh
# does; test/harness.sh loads the libraries lifted product code may call, from
# the tree DEPLOY_SRC comes from.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../harness.sh"
product_libs "$(dirname "$DEPLOY_SRC")"

# Extracted by pattern, not line number -- survives the file growing around
# it. Range: PEER_STATE_DIR's own default declaration through the end of
# do_draft_scope, which covers peer_label/peer_manifest_path/peer_scope_path,
# the system-name census, do_draft_scope_check and do_draft_scope itself.
eval "$(sed -n '/^PEER_STATE_DIR="\${PEER_STATE_DIR/,/^# do_join_check/p' "$DEPLOY_SRC" | sed '$d')"
if ! declare -F do_draft_scope >/dev/null; then
    echo "FATAL: could not extract do_draft_scope from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
    exit 1
fi
case "$PEER_STATE_DIR" in
    "$TMPD"/*) : ;;
    *) echo "FATAL: PEER_STATE_DIR resolved to '$PEER_STATE_DIR', not the test's throwaway dir -- refusing to run the rest of this suite" >&2; exit 1 ;;
esac

seed_manifest() {   # <label>
    cat > "$TMPD/peers/$1.conf" <<EOF
PEER_JOIN_ROLE="pull"
PEER_JOIN_AS="delegated"
PEER_JOIN_ACCOUNT="zfsbackup-pve1"
EOF
}

# ---- A. the golden layout ----------------------------------------------------
seed_manifest demo
out=$(do_draft_scope demo 2>&1); rc=$?
check "A1 do_draft_scope succeeds" "0" "$rc"
sfile="$TMPD/peers/demo.scope"
check "A2 the scope file exists" "0" "$([ -e "$sfile" ]; echo $?)"

check "A3 rpool/data is active" "1" "$(grep -c '^\[dataset:rpool/data\]$' "$sfile")"
check "A4 rpool/olds is active" "1" "$(grep -c '^\[dataset:rpool/olds\]$' "$sfile")"
check "A5 hdd/LXC is active" "1" "$(grep -c '^\[dataset:hdd/LXC\]$' "$sfile")"
check "A6 exactly 3 active stanzas (system datasets excluded)" "3" "$(grep -c '^\[dataset:' "$sfile")"
check "A7 rpool/ROOT is NOT an active stanza" "0" "$(grep -c '^\[dataset:rpool/ROOT\]$' "$sfile")"
check "A8 hdd/swap is NOT an active stanza" "0" "$(grep -c '^\[dataset:hdd/swap\]$' "$sfile")"
check "A9 pool roots are not active stanzas" "0" \
      "$(grep -cE '^\[dataset:(rpool|hdd)\]$' "$sfile")"

# Each active stanza carries the F2 owner-decision defaults exactly.
# include_parent states the intent that matches the dataset's SHAPE. The branch
# default selects nothing at all for a leaf, so the guided join refuses with
# "selects nothing that exists on this host" and the operator has to hand-edit one
# line -- on the very path issue #9 says needs no hand editing. Measured live on
# pve2, 2026-08-14. A container keeps the branch default; a leaf includes itself.
# Asserted as a PAIR, because a draft that wrote `yes` everywhere would be just as
# wrong and would pass a single-sided check.
check "A10 a leaf drafts include_parent = yes (rpool/data)" "1" \
      "$(awk '/^\[dataset:rpool\/data\]$/{f=1;next} /^\[dataset:/{f=0} f&&/^include_parent = yes$/{c++} END{print c+0}' "$sfile")"
check "A10b a container keeps include_parent = no (hdd/LXC)" "1" \
      "$(awk '/^\[dataset:hdd\/LXC\]$/{f=1;next} /^\[dataset:/{f=0} f&&/^include_parent = no$/{c++} END{print c+0}' "$sfile")"
check "A11 include_children = yes appears once per active stanza" "3" \
      "$(grep -c '^include_children = yes$' "$sfile")"

# The full inventory is present, INCLUDING the system datasets and pool
# roots -- excluded from the active defaults, never hidden from the operator.
check "A12 inventory lists rpool/ROOT (commented)" "1" \
      "$(grep -c '^# rpool/ROOT' "$sfile")"
check "A13 inventory lists hdd/swap (commented)" "1" \
      "$(grep -c '^# hdd/swap' "$sfile")"
check "A14 inventory lists the pool roots too" "1" "$(grep -c '^# rpool	' "$sfile")"

check "A15 account is reported in the header" "1" \
      "$(grep -c '^# Account: zfsbackup-pve1$' "$sfile")"
check "A16 label appears in the commit-scope hint" "1" \
      "$(grep -c 'deploy.sh --commit-scope=demo' "$sfile")"

# The file is DATA: no marker this project's other writers would mistake for
# a managed cron block, and no shell metacharacter sequence that would do
# anything if some future caller ever got this wrong and sourced it.
check "A17 no BEGIN/END cron markers leak into the scope file" "0" \
      "$(grep -cE '^# (BEGIN|END) ' "$sfile")"
# World-readable: a future collector-side fetch (slice 6) reads this file
# over ssh as the delegated account, not as root and not as whoever ran
# --draft-scope. /etc/zfs-snapshot-all/peers/ is 755 on a real host (world
# executable+readable, verified live on pve2), so the FILE's own mode is
# what actually gates this -- mktemp's default 600 would otherwise make the
# file unreadable to anyone else despite the readable directory.
stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
_probe="$TMPD/permprobe"; : > "$_probe"; chmod 600 "$_probe"
if [ "$(stat_mode "$_probe")" != "600" ]; then
    echo "SKIP A18 the scope file is world-readable (0644) -- this filesystem does not track file mode bits, verify on a real Linux host"
else
    check "A18 the scope file is world-readable (0644)" "644" "$(stat_mode "$sfile")"
fi
rm -f "$_probe"

# ENROLMENT-AGREED-2026-08-02 T5: a census of snapshot name families seen on
# this host, printed as comments so an operator editing the file can see
# what actually exists instead of guessing. Purely informational -- the
# fixture data below deliberately covers all three shapes T5/U6 discuss
# (this project's own automated_* dated names, Proxmox's epoch-stamped
# __replicate_, and bare vzdump/__migration__ with no timestamp at all).
check "A19 dated automated_ snapshots collapse to one family, counted" "1" \
      "$(grep -cE '^# automated_hourly_ +2 snapshot\(s\)$' "$sfile")"
check "A20 a bare family name with no timestamp survives verbatim (vzdump)" "1" \
      "$(grep -cE '^# vzdump +1 snapshot\(s\)$' "$sfile")"
check "A21 a bare family name with no timestamp survives verbatim (__migration__)" "1" \
      "$(grep -cE '^# __migration__ +1 snapshot\(s\)$' "$sfile")"
check "A22 an epoch-stamped family is still recognisable" "1" \
      "$(grep -cE '^# __replicate_100-0_ +1 snapshot\(s\)$' "$sfile")"

# ---- B. a second draft against the same label refuses (do_draft_scope_check
# already covers this via --draft-scope-check in test/join/run.sh; asserted
# again here to prove do_draft_scope itself, not just the check function,
# never silently overwrites an existing file it did not just create). -------
out=$(do_draft_scope demo 2>&1); rc=$?
check "B1 a second draft for the same label is refused" "1" "$rc"
case "$out" in *"already exists"*) ok "B2 ...named as already existing" ;;
  *) bad "B2 ...named as already existing" "$out" ;; esac

# ---- C. a host with only system datasets and pool roots has nothing to
# activate by default -- refused, not a silently empty file. ---------------
cat > "$TMPD/bin/zfs" <<'EOF'
#!/bin/bash
fields="" pool=""
while [ $# -gt 0 ]; do
    case "$1" in
        list) shift ;;
        -H|-r) shift ;;
        -o) fields="$2"; shift 2 ;;
        -d) shift 2 ;;
        --) shift; pool="$1"; shift ;;
        *) shift ;;
    esac
done
case "$fields" in
    name) [ "$pool" = rpool ] && printf 'rpool\nrpool/ROOT\n' ;;
    name,type,used,refer,mountpoint) [ "$pool" = rpool ] && printf 'rpool\tfilesystem\t120G\t96K\tnone\nrpool/ROOT\tfilesystem\t8G\t96K\tnone\n' ;;
esac
exit 0
EOF
cat > "$TMPD/bin/zpool" <<'EOF'
#!/bin/bash
printf 'rpool\n'
EOF
seed_manifest onlysystem
out=$(do_draft_scope onlysystem 2>&1); rc=$?
check "C1 nothing to activate by default is refused" "1" "$rc"
case "$out" in *"nothing to activate"*) ok "C2 ...named plainly, not a generic failure" ;;
  *) bad "C2 ...named plainly, not a generic failure" "$out" ;; esac
check "C3 no scope file was left behind by the refused draft" "1" \
      "$([ -e "$TMPD/peers/onlysystem.scope" ]; echo $?)"

# ---- D. --draft-config suggests the TYPED recursion field, not a flag ------
#
# REV-20260807-054 acceptance condition 5. Scope of this check, stated plainly:
# it is a STATIC read of deploy.sh, not an execution of --draft-config. That
# path needs a real pairing (saved peer, key, manifest) which is exactly why it
# has no behavioural suite today -- see the note on [file:zfs-backup.sh] in
# test/deps.conf. So this proves the generator no longer TELLS an operator to
# write `flags = -R`; it does not prove the emitted file parses.
#
# Worth having anyway: the old prose was advice to write a config that
# gen-cron.sh now refuses outright, and a draft that hands someone a rejected
# config is a support call, not a typo.
DEPLOY_SRC="${DEPLOY_SRC:-$DIR/../../deploy.sh}"

if grep -q "recursive    = flat" "$DEPLOY_SRC"; then
    ok "D1 --draft-config offers the typed 'recursive' field"
else
    bad "D1 --draft-config offers the typed 'recursive' field" "no 'recursive    = flat' line in $DEPLOY_SRC"
fi

# The exact shape being outlawed: telling the operator that a -R placed in
# 'flags' covers the subtree. Narrow on purpose -- deploy.sh still documents
# -r/-R for HAND-WRITTEN snapsend/delsnaps cron lines further down, and those
# are still correct; it is only the CONFIG advice that changed.
if grep -qE "'-R' we flags|-R\" we flags|we flags obejmie" "$DEPLOY_SRC"; then
    bad "D2 no leftover advice to put -R in a config's 'flags'" \
        "$(grep -nE "'-R' we flags|-R\" we flags|we flags obejmie" "$DEPLOY_SRC")"
else
    ok "D2 no leftover advice to put -R in a config's 'flags'"
fi

# ---- E. named is wanted (LAB6-F1, 2026-08-21) --------------------------------
# When the active stanzas come from an EXPLICIT REQUEST, the container
# heuristic must not fire: the operator typed the name, and a draft whose own
# text says "the data on the thing you named stays behind" is how LAB6 R1's
# tree kept its file out of a signed, green-reporting backup. hdd/LXC is the
# stub's container (it has a child), so the estate draft gives it
# include_parent = no -- the REQUEST draft must give it yes.
rm -f "$TMPD/peers/req.scope" "$TMPD/peers/req.scope.sha256" 2>/dev/null
cat > "$TMPD/peers/req.conf" <<EOF
PEER_JOIN_ROLE="pull"
PEER_JOIN_AS="delegated"
PEER_JOIN_ACCOUNT="zfsbackup-pve1"
PEER_JOIN_DATASETS="hdd/LXC"
EOF
out=$(do_draft_scope req 2>&1); rc=$?
check "E1 a request-derived draft succeeds" "0" "$rc"
stanza=$(awk '/^\[dataset:hdd\/LXC\]/{f=1;next} f&&/^include_parent/{print $3; exit}' "$TMPD/peers/req.scope")
check "E2 a REQUESTED container includes itself (named is wanted)" "yes" "$stanza"

# Positive control: the estate draft keeps the branch heuristic -- same
# container, no request, include_parent = no. Without this, E2 would also pass
# if the heuristic were simply deleted.
stanza=$(awk '/^\[dataset:hdd\/LXC\]/{f=1;next} f&&/^include_parent/{print $3; exit}' "$TMPD/peers/demo.scope")
check "E3 control: the estate draft still treats a container as a branch" "no" "$stanza"

# ---- the draft records WHAT IT WAS BUILT FROM --------------------------------
#
# A draft is reused on a later --join rather than rebuilt, so the request it
# answered has to travel with it. Without that, a draft built when the collector
# named nothing -- a proposal covering the whole estate -- is reused against a
# request naming one dataset, and the acceptance screen shows a one-dataset ask
# above a nine-dataset grant. Measured on pve9, 2026-08-29.
#
# A sidecar rather than a header line: the scope file is hashed and enumerated,
# and a comment inside it would have to be excluded from both.
# The request travels in the MANIFEST, not the environment: do_draft_scope
# declares PEER_JOIN_DATASETS local and sources the manifest over it, so an
# exported variable would be silently discarded -- the first cut of this test
# did exactly that and took the whole suite down with a die().
cat > "$TMPD/peers/stamp.conf" <<EOF
PEER_JOIN_ROLE="pull"
PEER_JOIN_AS="delegated"
PEER_JOIN_ACCOUNT="zfsbackup-pve1"
PEER_JOIN_DATASETS="hdd/LXC"
EOF
out=$(do_draft_scope stamp 2>&1); rc=$?
check "the stamped draft succeeds" "0" "$rc"
check "THE DRAFT RECORDS THE REQUEST BESIDE IT" "0" "$([ -f "$TMPD/peers/stamp.scope.request" ]; echo $?)"
check "...and it holds what the collector asked for" "hdd/LXC" "$(cat "$TMPD/peers/stamp.scope.request" 2>/dev/null)"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
