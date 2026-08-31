#!/bin/bash
# `restore_remote_off_point`: did the target actually land on the recovery point?
#
#   ./test/restore/offpoint.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/offpoint.sh   # negative control
#
# Sourced by test/restore/run.sh.
#
# The logic lives inside an ssh payload, so `ssh` is stubbed to run that payload
# LOCALLY against a stubbed `zfs`. That way the case exercises the real script
# text rather than a description of it -- which matters here, because the defect
# this file exists for was in what the payload ASKED, not in how it was called.
#
# FOUND ON THE LAB, 2026-08-31, by a campaign aimed at something else. Two
# datasets landed exactly on the recovery point -- newest snapshot IS the point,
# deleted files back -- and the run reported `CHANGED AND UNFINISHED ... they
# need a person`, exit 2, because `written@point` read 8192. The loudest alarm
# this tool has, raised over a successful recovery.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _op_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_op_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _op_standalone=1
fi

OP="$WORK/offpoint"; mkdir -p "$OP/bin"

# The stubbed `zfs`, driven by files:
#   $OP/list      datasets, one per line
#   $OP/snaps     "<dataset>@<snap> <guid> <createtxg>", in createtxg order
#   $OP/written   optional "<dataset> <bytes>" -- present ONLY so a probe that
#                 still asks for it can be caught doing so
cat > "$OP/bin/zfs" <<'ZSTUB'
#!/bin/bash
case "$*" in
    *"-t snapshot"*)
        d="${!#}"
        grep -E "^${d}@" "$OP/snaps" 2>/dev/null | awk '{print $1}'
        exit 0 ;;
    "get -Hp -o value guid "*)
        s="${!#}"
        g="$(awk -v s="$s" '$1==s{print $2; exit}' "$OP/snaps" 2>/dev/null)"
        [ -n "$g" ] && printf '%s\n' "$g" || printf -- '-\n'
        exit 0 ;;
    "get -Hp -o value written@"*)
        # A probe that reaches this line is asking the accounting question.
        echo "WRITTEN-WAS-ASKED" >> "$OP/asked"
        d="${!#}"
        awk -v d="$d" '$1==d{print $2; exit}' "$OP/written" 2>/dev/null || echo 0
        exit 0 ;;
    "list -H -o name"*)
        cat "$OP/list" 2>/dev/null
        exit 0 ;;
esac
exit 0
ZSTUB
chmod +x "$OP/bin/zfs"

op_run() {   # <point> <expected guid> -> what the probe reports
    local point="$1" want="$2"
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'export OP=%q\n' "$OP"
        printf 'export PATH=%q:$PATH\n' "$OP/bin"
        echo 'SSH_OPTS=()'
        # Run the payload locally instead of connecting. The payload is the LAST
        # argument, which is the whole point of stubbing at this boundary.
        echo 'ssh() { local s="${!#}"; bash -c "$s"; }'
        awk -v want="restore_remote_off_point() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        printf 'restore_remote_off_point acct@host rpool/data %q "" %q\n' "$point" "$want"
    } > "$t"
    : > "$OP/asked"
    bash "$t" 2>&1
    rm -f "$t"
}

printf 'rpool/data\n' > "$OP/list"
printf 'rpool/data 8192\n' > "$OP/written"

# ---- the target IS at the point ---------------------------------------------
printf 'rpool/data@p 111 10\n' > "$OP/snaps"
out="$(op_run p "$(printf '	111')")"
if [ -z "$out" ]; then ok "offpoint: a target whose newest snapshot IS the point reports nothing"
else bad "offpoint: a target whose newest snapshot IS the point reports nothing" "$out"; fi

# THE CARRYING ASSERTION. `written@` is 8192 in the fixture above -- the exact
# number the lab produced over a SUCCESSFUL recovery. A probe that consults it
# fails the case above; this one says why, so the next reader does not have to
# rediscover which question was wrong.
if [ -s "$OP/asked" ]; then
    bad "offpoint: ...WITHOUT ASKING written@, WHICH THE RESTORE ITSELF DISTURBS" "the probe asked for written@"
else
    ok "offpoint: ...WITHOUT ASKING written@, WHICH THE RESTORE ITSELF DISTURBS"
fi

# ---- the snapshot is not there ----------------------------------------------
printf 'rpool/data@inny 999 10\n' > "$OP/snaps"
out="$(op_run p "$(printf '	111')")"
case "$out" in
    *"does not have that snapshot"*) ok "offpoint: a target without the point says so" ;;
    *) bad "offpoint: a target without the point says so" "$out" ;;
esac

# ---- same NAME, different snapshot ------------------------------------------
# The distinction this file spends most of its length on, applied to the check
# that closes the run: a name is not an identity.
printf 'rpool/data@p 222 10\n' > "$OP/snaps"
out="$(op_run p "$(printf '	111')")"
case "$out" in
    *"DIFFERENT one"*) ok "offpoint: A SNAPSHOT WITH THE RIGHT NAME AND THE WRONG GUID IS NOT THE POINT" ;;
    *) bad "offpoint: A SNAPSHOT WITH THE RIGHT NAME AND THE WRONG GUID IS NOT THE POINT" "$out" ;;
esac

# ---- something sits on top ---------------------------------------------------
printf 'rpool/data@p 111 10\nrpool/data@nowszy 333 20\n' > "$OP/snaps"
out="$(op_run p "$(printf '	111')")"
case "$out" in
    *"sitting on top of p"*) ok "offpoint: a snapshot newer than the point is reported" ;;
    *) bad "offpoint: a snapshot newer than the point is reported" "$out" ;;
esac

# ---- no guid to compare against ---------------------------------------------
# The caller may not have one. Then the name has to do, and the check is weaker
# rather than absent -- said out loud so nobody reads silence as proof.
printf 'rpool/data@p 111 10\n' > "$OP/snaps"
out="$(op_run p '')"
if [ -z "$out" ]; then ok "offpoint: with no expected guid it still passes a target at the point"
else bad "offpoint: with no expected guid it still passes a target at the point" "$out"; fi

# ---- RECURSIVE: EACH DATASET AGAINST ITS OWN IDENTITY (REV-20260831-129) ----
# A snapshot's guid belongs to that dataset's snapshot. The first version of this
# probe took ONE expected guid and applied it to every dataset the recursive
# enumeration found, so a perfectly valid child was reported as "the right name,
# a different snapshot" -- turning every successful recursive restore into a
# report that it needs a human. Comparing a child's identity with its parent's is
# a category error, not a strict check.
printf 'rpool/data
rpool/data/child
' > "$OP/list"
printf 'rpool/data@p 111 10
rpool/data/child@p 222 10
' > "$OP/snaps"
MAP="$(printf '	111
/child	222
')"
out="$(op_run p "$MAP")"
if [ -z "$out" ]; then ok "offpoint: A VALID CHILD IS CHECKED AGAINST ITS OWN GUID, NOT THE PARENT'S"
else bad "offpoint: A VALID CHILD IS CHECKED AGAINST ITS OWN GUID, NOT THE PARENT'S" "$out"; fi

# ...and the protection stays: a child with the right name and the wrong guid,
# measured against ITS OWN expected identity, is still refused.
printf 'rpool/data@p 111 10
rpool/data/child@p 999 10
' > "$OP/snaps"
out="$(op_run p "$MAP")"
case "$out" in
    *"child has a snapshot NAMED p but a DIFFERENT one"*) ok "offpoint: ...while a child with the wrong guid is still caught" ;;
    *) bad "offpoint: ...while a child with the wrong guid is still caught" "$out" ;;
esac

# A dataset the recovery never included has no entry in the table, so it is not
# this check's business -- reporting it would be a false alarm about something
# the run did not touch.
printf 'rpool/data
rpool/data/child
rpool/data/obcy
' > "$OP/list"
printf 'rpool/data@p 111 10
rpool/data/child@p 222 10
' > "$OP/snaps"
out="$(op_run p "$MAP")"
case "$out" in
    *obcy*) bad "offpoint: ...and a dataset outside the recovery is not reported" "$out" ;;
    *) ok "offpoint: ...and a dataset outside the recovery is not reported" ;;
esac
printf 'rpool/data
' > "$OP/list"

if [ "${_op_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
