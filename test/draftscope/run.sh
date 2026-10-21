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
# it. Range: through the end of do_draft_scope, covering remote_scope_stage,
# the system-name census, do_draft_scope_check and do_draft_scope itself. It
# starts at whichever of two anchors the tree has: on a tree from before
# 2026-09-03 the PEER_STATE_DIR declaration, so the range also carries the
# peer_label/peer_manifest_path/peer_scope_path copies that tree keeps inside
# deploy.sh; on a current tree the remote_scope_stage header, because those
# helpers moved to lib-pairing.sh and product_libs above has sourced them.
eval "$(product_range "$DEPLOY_SRC" '^PEER_STATE_DIR="[$][{]PEER_STATE_DIR|^# remote_scope_stage <label>' '^# do_join_check' | sed '$d')"
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

# --- --draft-config/--rotate/--revoke-old WITHOUT --pair: refuse, never deploy ---
#
# These three set only their own variable; PAIR_MODE is set by --pair (and
# --unpair) alone, and do_pair -- which dispatches all three -- runs only in that
# mode. So until 2026-09-03 a command line naming one of them without --pair was
# not refused and did not draft: it fell through to the ordinary deployment path
# and ran a FULL DEPLOY, git pull included.
#
# Measured on pve9, from this project's own lab runbook, which spelled the
# documented-looking `deploy.sh --peer=X --draft-config`: it pulled the repo
# (moving HEAD under a lab that had deliberately held updates), reinstalled the
# generated scripts, touched the crontab and died in phase 8g -- never once
# saying that --draft-config had been ignored.
#
# Asserted on the PROGRAM, not on a lifted function, because the whole defect is
# where the argument check sits relative to the dispatch. Runs as a normal user:
# the old code reaches the root check (rc=1, "run as root"), the new one refuses
# at argument validation (rc=2), so the two are told apart without root.
for _pf in --draft-config --rotate --revoke-old; do
    _out=$(bash "$DEPLOY_SRC" --peer=10.0.0.1 "$_pf" 2>&1 >/dev/null); _rc=$?
    check "$_pf without --pair is REFUSED (rc=2)" "2" "$_rc"
    case "$_out" in
        *"is an option of --pair"*) check "$_pf names itself in the refusal" "0" "0" ;;
        *)                          check "$_pf names itself in the refusal" "0" "1: $_out" ;;
    esac
    case "$_out" in
        *"run as root"*) check "$_pf did NOT fall through to the deployment path" "0" "1: reached the root check" ;;
        *)               check "$_pf did NOT fall through to the deployment path" "0" "0" ;;
    esac
done

# POSITIVE CONTROL. The guard must catch the MISSING --pair, not the flag: with
# --pair the same flag passes argument validation and the program carries on
# (as a normal user it then stops at the root check, which is proof it got past).
# NEVER AS ROOT. Past the argument gate a real --pair run does Phase 1 and
# Phase 2 of a deployment BEFORE it pairs -- as root on a developer's checkout
# that is a `git fetch` into the very repository this suite is reading
# (measured 2026-09-03: FETCH_HEAD moved under a running suite). The control
# only needs the root gate to answer, so it runs as an unprivileged user when
# the suite itself is root, and is skipped with its reason when none exists.
_run_ctrl() { bash "$DEPLOY_SRC" --pair --peer=10.0.0.1 --draft-config 2>&1 >/dev/null; }
if [ "$(id -u)" -ne 0 ]; then
    _out=$(_run_ctrl); _rc=$?
elif id nobody >/dev/null 2>&1; then
    _out=$(su -s /bin/bash nobody -c "bash '$DEPLOY_SRC' --pair --peer=10.0.0.1 --draft-config 2>&1 >/dev/null"); _rc=$?
else
    _out=""; _rc=99
fi
if [ "$_rc" -eq 99 ]; then
    echo "SKIP WITH --pair control: suite runs as root and no unprivileged user exists to run it as"
else
    check "WITH --pair the flag is accepted (not rc=2)" "0" "$([ "$_rc" != 2 ]; echo $?)"
    case "$_out" in
        *"run as root"*) check "...and execution reaches past argument validation" "0" "0" ;;
        *)               check "...and execution reaches past argument validation" "0" "1: $_out" ;;
    esac
fi

# ---- U42 (owner 2026-10-20): a new account starts with NO zfs rights ------
# ZFS keeps delegations by uid; a removed account's grants pass to the next account
# with the same uid (measured live on pve11 2026-10-20: "user (unknown: 1003)" became
# "user u42new" after useradd -u 1003). The SHIPPED guard revokes exactly those.
eval "$(product_range "$DEPLOY_SRC" '^new_account_drop_inherited_grants\(\) \{' '^do_leave\(\) \{' | sed '$d')"
if declare -F new_account_drop_inherited_grants >/dev/null; then
    G42="$TMPD/u42"; mkdir -p "$G42"; : > "$G42/unallow"
    zfs() {
        case "$1" in
            list)    printf 'tank\ntank/a\ntank/b\n' ;;
            allow)   case "$2" in tank/a) printf -- '---- Permissions on tank/a ----\nLocal+Descendent permissions:\n\tuser newacct destroy,mount,snapshot\n' ;;
                                  tank/b) printf -- '---- Permissions on tank/b ----\nLocal+Descendent permissions:\n\tuser otheracct destroy\n' ;; esac ;;
            unallow) echo "$*" >> "$G42/unallow" ;;
        esac
    }
    _g42=$( { warn() { echo "WARN $*"; }; log() { :; }; new_account_drop_inherited_grants newacct; } 2>&1 )
    unset -f zfs
    if [ "$(cat "$G42/unallow")" = "unallow -u newacct tank/a" ] && case "$_g42" in *INHERITED*tank/a*) true ;; *) false ;; esac; then
        check "U42: a new account's inherited delegation (tank/a) is revoked and said; another account's (tank/b) is left alone" "0" "0"
    else
        check "U42: inherited delegation revoked" "0" "1: $(cat "$G42/unallow") / $_g42"
    fi
    # REV-20261021-163: a failed read is not "no grant". Each case in a subshell (die exits);
    # die/userdel/warn/log stubbed; G42_MODE picks the zfs result.
    # REV-20261021-165: <home> = new (empty, as useradd -m would leave it), pre (a sentinel
    # file in it -- a home left by a hand userdel, or created between a check and useradd:
    # the guard cannot tell them apart and must not try), prefail (pre + userdel itself
    # fails). userdel -r really deletes the home here, so any recursive rollback shows up
    # as a missing home. Home state -> $G42/homestate.
    g42_run() {   # <mode> [home] -> "rc|unallow calls|userdel calls|output"
        : > "$G42/unallow"; : > "$G42/userdel"
        local out rc home="$G42/home/newacct" hm="${2:-new}"
        rm -rf "$G42/home"; mkdir -p "$home"
        case "$hm" in pre|prefail|race) echo keep > "$home/SENTINEL" ;; esac
        out=$( (
            die() { echo "DIE $*"; exit 1; }; warn() { echo "WARN $*"; }; log() { :; }
            userdel() { echo "$*" >> "$G42/userdel"; [ "$hm" = prefail ] && return 1
                        [ "$1" = -r ] && rm -rf "$home"; return 0; }
            getent() { [ "$hm" = moved ] && { echo "newacct:x:1003:1003::/srv/elsewhere:/bin/bash"; return 0; }
                       echo "newacct:x:1003:1003::$home:/bin/bash"; }
            id() { [ "$1" = -u ] && { echo 1003; return 0; }; command id "$@"; }
            zfs() {
                case "$1" in
                    list)    [ "$G42_MODE" = listfail ] && return 41; printf 'tank\ntank/a\n' ;;
                    allow)   [ "$G42_MODE" = allowfail ] && [ "$2" = tank/a ] && return 42
                             case "$G42_MODE:$2" in grant*:tank/a) printf -- '---- Permissions on tank/a ----\nLocal+Descendent permissions:\n\tuser newacct destroy\n' ;; esac ;;
                    unallow) echo "$*" >> "$G42/unallow"; [ "$G42_MODE" = grantfail ] && return 1; return 0 ;;
                esac
            }
            # race: the reviewer's counterexample -- a caller that checked "no home" (0) while
            # the directory with a sentinel appeared before useradd. The first fix trusted
            # that 0 and ran userdel -r; the guard now takes no such hint at all.
            G42_MODE="$1"; if [ "$hm" = race ]; then new_account_drop_inherited_grants newacct "$home" 0; else new_account_drop_inherited_grants newacct "$home"; fi
        ) 2>&1 ); rc=$?
        if [ -e "$home/SENTINEL" ]; then echo sentinel > "$G42/homestate"
        elif [ -d "$home" ]; then echo home > "$G42/homestate"; else echo gone > "$G42/homestate"; fi
        printf '%s|%s|%s|%s' "$rc" "$(cat "$G42/unallow")" "$(cat "$G42/userdel")" "$out"
    }
    _r=$(g42_run listfail)
    case "$_r" in 1\|\|newacct\|*"DIE new account newacct"*"zfs list failed"*"removed again"*) check "U42/REV-163: zfs list fails -> stop, the new account removed again, no revoke" "0" "0" ;;
        *) check "U42/REV-163: zfs list failure" "0" "1: $_r" ;; esac
    _r=$(g42_run allowfail)
    case "$_r" in 1\|\|newacct\|*"DIE new account newacct"*"zfs allow failed"*) check "U42/REV-163: zfs allow fails -> stop, the new account removed again" "0" "0" ;;
        *) check "U42/REV-163: zfs allow failure" "0" "1: $_r" ;; esac
    _r=$(g42_run clean)
    case "$_r" in "0|||") check "U42/REV-163: clean inventory, no grant -> rc 0, nothing revoked, account kept" "0" "0" ;;
        *) check "U42/REV-163: clean inventory" "0" "1: $_r" ;; esac
    _r=$(g42_run grant)
    case "$_r" in "0|unallow -u newacct tank/a||WARN"*) check "U42/REV-163: inherited grant -> revoked, rc 0, account kept" "0" "0" ;;
        *) check "U42/REV-163: inherited grant revoked" "0" "1: $_r" ;; esac
    _r=$(g42_run grantfail)
    case "$_r" in "1|unallow -u newacct tank/a|newacct|"*"DIE new account newacct"*"zfs unallow -u 1003 tank/a"*) check "U42/REV-163: revoke fails -> stop, account removed again, the by-hand command names the uid" "0" "0" ;;
        *) check "U42/REV-163: revoke failure" "0" "1: $_r" ;; esac
    _hs() { cat "$G42/homestate"; }
    # REV-20261021-165: a home that existed before useradd survives every rollback.
    for _m in listfail allowfail grantfail; do
        _r=$(g42_run "$_m" pre)
        case "$_r" in 1\|*\|newacct\|*"left in place"*)
            if [ "$(_hs)" = sentinel ]; then check "U42/REV-165: $_m with a pre-existing home -> userdel without -r, home and its files kept" "0" "0"
            else check "U42/REV-165: $_m pre-existing home" "0" "1: home=$(_hs) $_r"; fi ;;
            *) check "U42/REV-165: $_m pre-existing home" "0" "1: home=$(_hs) $_r" ;; esac
    done
    # The rejected first fix trusted "absent before useradd": a home that appears between
    # the check and useradd was deleted. There is no check now -- an empty home (what
    # useradd -m leaves) is kept too, named in the message with the by-hand command.
    _r=$(g42_run listfail new)
    case "$_r:$(_hs)" in 1\|\|newacct\|*"rm -r $G42/home/newacct"*:home) check "U42/REV-165: even a home this run may have created is kept and named, with the by-hand rm -- no recursive rollback at all" "0" "0" ;;
        *) check "U42/REV-165: empty home kept" "0" "1: $_r home=$(_hs)" ;; esac
    _r=$(g42_run listfail race)
    case "$_r:$(_hs)" in 1\|\|newacct\|*:sentinel) check "U42/REV-165: race -- home appears between a 'no home' check and useradd -> sentinel survives, no userdel -r" "0" "0" ;;
        *) check "U42/REV-165: race (reviewer counterexample)" "0" "1: $_r home=$(_hs)" ;; esac
    _r=$(g42_run listfail moved)
    case "$_r:$(_hs)" in 1\|\|newacct\|*:home) check "U42/REV-165: passwd names another home -> plain userdel, home kept" "0" "0" ;;
        *) check "U42/REV-165: home path mismatch" "0" "1: $_r home=$(_hs)" ;; esac
    if grep -qE 'userdel -r|NEW_ACCOUNT_HOME_OURS' <(product_range "$DEPLOY_SRC" '^new_account_drop_inherited_grants\(\) \{' '^leave_ds_exists\(\) \{'); then
        check "U42/REV-165: the rollback code has no userdel -r and no ownership guess" "0" "1: found"
    else check "U42/REV-165: the rollback code has no userdel -r and no ownership guess" "0" "0"; fi
    _r=$(g42_run listfail prefail)
    case "$_r:$(_hs)" in *"run 'userdel newacct' by hand"*:sentinel)
            case "$_r" in *"userdel -r"*) check "U42/REV-165: rollback fails, pre-existing home -> hand command" "0" "1: says userdel -r: $_r" ;;
                *) check "U42/REV-165: rollback itself fails with a pre-existing home -> hand command is plain userdel, home kept" "0" "0" ;; esac ;;
        *) check "U42/REV-165: rollback failure" "0" "1: $_r home=$(_hs)" ;; esac
    # Both call sites pass the home path (for the message only).
    _pass=$(grep -c -E 'new_account_drop_inherited_grants "\$(account|USERNAME)" "(/home/\$account|\$HOMEDIR)"$' "$DEPLOY_SRC")
    if [ "$_pass" = 2 ]; then check "U42/REV-165: both call sites pass the home path to the guard" "0" "0"
    else check "U42/REV-165: call sites" "0" "1: pass=$_pass"; fi
    # Both call sites: the guard runs right after useradd, before the next mutation.
    _cs=$(grep -n -A1 'log "created isolated peer account\|log "created user \$USERNAME' "$DEPLOY_SRC" | grep -c 'new_account_drop_inherited_grants')
    if [ "$_cs" = 2 ]; then check "U42/REV-163: both post-useradd call sites call the guard on the next line" "0" "0"
    else check "U42/REV-163: call sites" "0" "1: $_cs"; fi
else
    check "U42: could not lift new_account_drop_inherited_grants from deploy.sh -- anchors changed" "0" "1"
fi

# ---- U47 (owner 2026-10-20): --unpair needs no internet --------------------
# delete-relation -> remove-client -> deploy.sh --unpair ran Phase 2's `git pull` first;
# a flaky link stopped the deletion HALFWAY (pve10 2026-09-25). The pull in Phase 2 must
# sit behind a PEER_UNPAIR guard. Shape check (top-level code, nothing to lift); the
# behaviour is proved live with github.com unresolvable (PROJECT_STATUS).
_p2=$(awk '/^log "Phase 2: deploy the repo/{f=1} f&&/git -C "\$REPO_DIR" pull --ff-only origin main/{print; exit} f' "$DEPLOY_SRC")
if printf '%s\n' "$_p2" | grep -q 'if \[ "\${PEER_UNPAIR:-0}" -eq 1 \]; then' \
   && [ "$(printf '%s\n' "$_p2" | grep -n 'PEER_UNPAIR:-0' | head -1 | cut -d: -f1)" -lt "$(printf '%s\n' "$_p2" | grep -n 'pull --ff-only origin main' | tail -1 | cut -d: -f1)" ]; then
    check "unpair: Phase 2 does not pull for --unpair (ending a relationship needs no internet, U47)" "0" "0"
else
    check "unpair: Phase 2 does not pull for --unpair (U47)" "0" "1"
fi

# ---- --unpair with NO MANIFEST: the goal state, not an error (2026-09-20) ----
#
# The incident of 2026-09-20 deleted a peer's pairing manifest and keys while the
# relationship record was still alive. The way back is "tear it down and pair
# again", and `remove-client --unpair` is the first half of it -- but do_unpair
# refused because the thing it was asked to remove was already gone, so the
# relationship could be neither removed nor repaired. Two properties are pinned:
# the run succeeds and says so, and it deletes NOTHING (those key files are keyed
# by the peer ADDRESS and a live sibling relationship may share them -- E57).
eval "$(product_range "$DEPLOY_SRC" '^unpair_assert_no_cron_users\(\)' '^# do_unpair -- end the relationship' | sed '$d')"
eval "$(product_range "$DEPLOY_SRC" '^do_unpair\(\) \{' '^    record_load manifest' | sed '$d')
    return 0
}"
if declare -F do_unpair >/dev/null && declare -F unpair_assert_no_cron_users >/dev/null; then
    check "unpair: the SHIPPED do_unpair is what is under test" "0" "0"
else
    check "unpair: could not lift do_unpair from deploy.sh -- anchors changed, update this suite" "0" "1"
fi
UP="$TMPD/unpair"; mkdir -p "$UP/keys"
PEER_KEY_DIR="$UP/keys"; PEER_HOST=10.9.9.9
for k in _ed25519 _ed25519.pub _known_hosts _alias_known_hosts; do echo k > "$UP/keys/10.9.9.9$k"; done
crontab() { cat "$UP/crontab.txt" 2>/dev/null; }     # the guard reads it; empty by default
: > "$UP/crontab.txt"
_uo=$(do_unpair 10.9.9.9 "$UP/does-not-exist.conf" 2>&1); _urc=$?
if [ "$_urc" -eq 0 ]; then
    check "unpair: a missing manifest SUCCEEDS instead of dying, so 'remove and pair again' has a road" "0" "0"
else
    check "unpair: a missing manifest SUCCEEDS instead of dying" "0" "1: rc=$_urc $_uo"
fi
case "$_uo" in
    *"nothing left to unpair"*) check "unpair: ...and it says so in words the operator can act on" "0" "0" ;;
    *)                          check "unpair: ...and it says so" "0" "1: $_uo" ;;
esac
_kept=1; for k in _ed25519 _ed25519.pub _known_hosts _alias_known_hosts; do [ -e "$UP/keys/10.9.9.9$k" ] || _kept=0; done
check "unpair: it deletes NOTHING -- address-keyed key files may belong to a live sibling relationship (E57)" "0" "$([ "$_kept" -eq 1 ]; echo $?)"
case "$_uo" in
    *"LEFT ALONE"*) check "unpair: ...and it names what it left, instead of leaving it silently" "0" "0" ;;
    *)              check "unpair: ...and it names what it left" "0" "1: $_uo" ;;
esac
# CONTROL: the cron guard still bites. A pairing whose jobs still run must not be
# waved through just because its manifest is missing.
printf 'x 10.9.9.9_ed25519 x\n' > "$UP/crontab.txt"
_uo=$( do_unpair 10.9.9.9 "$UP/does-not-exist.conf" 2>&1 ); _urc=$?
if [ "$_urc" -ne 0 ]; then
    check "unpair control: with jobs still using the peer it REFUSES, manifest or no manifest" "0" "0"
else
    check "unpair control: it waved through a peer whose jobs still run" "0" "1: $_uo"
fi
unset -f crontab

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
