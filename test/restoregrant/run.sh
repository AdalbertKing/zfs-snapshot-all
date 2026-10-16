#!/bin/bash
# The restore grant: the fact on a machine that lets a collector overwrite it.
#
# WHY THIS EXISTS AT ALL. The owner chose the PUSH direction (2026-08-26/27:
# "Zacznij od push", "Kto zaczyna: kolektor"), so a restore is started at the
# machine holding the backups and that machine writes onto the broken one.
# Under the pull form the machine being overwritten would have been the one
# asking, and no capability to write onto another machine would ever have had to
# exist. Under push it does -- so this grant is not a belt-and-braces extra, it
# is the whole of the safety, and every assertion here is about it staying that.
#
# Runs anywhere: no root, no ZFS, no network. `id` is stubbed where a verb
# insists on root, and the two directories are pointed at a temp tree.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY="${DEPLOY:-$REPO/deploy.sh}"
GATE="${GATE:-$REPO/zfs-pair-gate.sh}"
[ -r "$DEPLOY" ] || { echo "cannot read deploy.sh at $DEPLOY" >&2; exit 1; }
[ -r "$GATE" ]   || { echo "cannot read zfs-pair-gate.sh at $GATE" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
REL="$TMPD/rel"; GRANTS="$TMPD/grants"; BIN="$TMPD/bin"; PEERS="$TMPD/peers"; ZBIN="$TMPD/zbin"
# The grant now pauses this host's relationships that write into the scope
# (zfs-backup.sh pause-writers). Their records and pause markers go to a tree
# of their own here: run as root on a lab host, the defaults are the REAL ones.
CLI="$TMPD/clients"; PSTATE="$TMPD/pausestate"
mkdir -p "$REL/lab1" "$REL/other" "$GRANTS" "$BIN" "$PEERS" "$ZBIN" "$CLI" "$PSTATE"

# The peer manifest this host wrote when it was joined. A grant reads WHO and
# WHAT from it -- the account to delegate to and the datasets the relationship
# was ever given -- so a restore cannot be granted on a wider scope than the
# backup already had. Without it the grant refuses, which is a case asserted
# further down rather than worked around here.
printf 'PEER_JOIN_ACCOUNT="zfsbackup-pve9"
PEER_JOIN_GRANTED_DATASETS="hdd/a hdd/a/child"
' > "$PEERS/lab1.conf"

# zfs, recording what it was asked to delegate. The grant issues TWO halves --
# the file and the delegation -- and a suite that stubbed only the file would
# assert the half that cannot do anything on its own.
cat > "$ZBIN/zfs" <<'ZFSSTUB'
#!/bin/sh
printf '%s
' "$*" >> "${ZFS_TRACE:-/dev/null}"
# ZFS_GONE="<dataset> ...": those datasets do not exist (`zfs list` fails on them).
# ZFS_FAIL_UNALLOW=1: every `zfs unallow` fails.
[ "$1" = unallow ] && [ -n "${ZFS_FAIL_UNALLOW:-}" ] && exit 1
# ZFS_MOUNTED="<dataset> ...": `zfs get -H -o value mounted -- X` says yes for those, no otherwise.
if [ "$1" = get ] && [ "${5:-}" = mounted ]; then
    for a in "$@"; do last="$a"; done
    for m in ${ZFS_MOUNTED:-}; do [ "$last" = "$m" ] && { echo yes; exit 0; }; done
    echo no; exit 0
fi
if [ "$1" = list ] && [ -n "${ZFS_GONE:-}" ]; then
    for a in "$@"; do for g in $ZFS_GONE; do [ "$a" = "$g" ] && exit 1; done; done
fi
exit 0
ZFSSTUB
chmod +x "$ZBIN/zfs"
export ZFS_TRACE="$TMPD/zfstrace"

# A root stub, so the privileged verbs can be exercised without being root.
# Only `id -u` is answered; everything else falls through, so the stub cannot
# quietly change some other decision this script makes.
cat > "$BIN/id" <<'IDSTUB'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
for d in /usr/bin/id /bin/id; do [ -x "$d" ] && exec "$d" "$@"; done
exit 127
IDSTUB
chmod +x "$BIN/id"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; FAIL=$((FAIL+1)); }
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

d()  { PATH="$ZBIN:$PATH" PAIR_GATE_STATE_DIR="$REL" PEER_STATE_DIR="$PEERS" RESTORE_GRANT_DIR="$GRANTS" CLIENTS_DIR="$CLI" RELATIONSHIPS_DIR="$PSTATE" bash "$DEPLOY" "$@" 2>&1; }
dr() { PATH="$BIN:$ZBIN:$PATH" PAIR_GATE_STATE_DIR="$REL" PEER_STATE_DIR="$PEERS" RESTORE_GRANT_DIR="$GRANTS" CLIENTS_DIR="$CLI" RELATIONSHIPS_DIR="$PSTATE" bash "$DEPLOY" "$@" 2>&1; }
gate() {   # <label> -> the PAIR-CONTROL status answer
    RELATIONSHIPS_DIR="$REL" RESTORE_GRANT_DIR="$GRANTS" \
        SSH_ORIGINAL_COMMAND="PAIR-CONTROL status" bash "$GATE" "$1" 2>&1
}

# ---------------------------------------------------------------------------
# 1. WHERE THE GRANT LIVES. This is the finding that shaped the whole slice and
#    it is asserted first, because everything else is worthless without it.
#
#    The design document put the grant at
#    /var/lib/zfs-snapshot-all/relationships/<label>/restore-grant and said in
#    the same paragraph that the directory is "root-owned, the account has
#    read-only access". It is neither: deploy.sh makes it root:<account> mode
#    0775 ON PURPOSE, because the owner's 2026-08-06 model lets the
#    relationship's own key lift a hard pause, and lifting it means unlinking a
#    marker INSIDE that directory.
#
#    A grant kept there could therefore be created by the collector's own
#    account -- the account this grant exists to restrain. Not a weakness in the
#    mechanism; the mechanism doing nothing whatsoever.
# ---------------------------------------------------------------------------
rgd="$(grep -m1 '^RESTORE_GRANT_DIR=' "$DEPLOY")"
pgd="$(grep -m1 '^PAIR_GATE_STATE_DIR=' "$DEPLOY")"
rgd_path="$(printf '%s' "$rgd" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
pgd_path="$(printf '%s' "$pgd" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
check "location: deploy.sh declares a grant directory" "yes" "$([ -n "$rgd_path" ] && echo yes)"
case "$rgd_path" in
    "$pgd_path"/*|"$pgd_path")
        bad "location: the grant tree is NOT inside the group-writable relationship tree" \
            "grants=$rgd_path is under relationships=$pgd_path -- the delegated account can write there" ;;
    *)  ok "location: the grant tree is NOT inside the group-writable relationship tree" ;;
esac
# ...and the gate must look in the SAME place, or the machine and the collector
# disagree about whether a grant exists.
rgd_gate="$(grep -m1 '^RESTORE_GRANT_DIR=' "$GATE" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
check "location: the gate reads the same tree deploy.sh writes" "$rgd_path" "$rgd_gate"
# NEGATIVE CONTROL for the pair above: the relationship tree really is the
# group-writable one, so the assertion is about a real hazard and not a rule
# invented to be satisfied.
if grep -q 'chmod 0775 "\$PAIR_GATE_STATE_DIR/\$label"' "$DEPLOY"; then
    ok "location: ...and the relationship tree really is group-writable (the hazard is real)"
else
    bad "location: the relationship tree is expected to be group-writable" \
        "no 'chmod 0775' on it in deploy.sh -- if that changed, re-derive this whole assertion"
fi

# ---------------------------------------------------------------------------
# 2. WHO MAY ISSUE ONE
# ---------------------------------------------------------------------------
out="$(d --allow-restore=lab1)"
if has "must run as root" "$out"; then ok "issue: a non-root caller cannot grant"
else bad "issue: a non-root caller cannot grant" "$out"; fi
# ...and the refusal says WHY root is needed here, which the generic one cannot.
if has "machine at risk issues it locally" "$out"; then
    ok "issue: ...and says why it must be local and privileged"
else bad "issue: ...and says why it must be local and privileged" "$out"; fi

out="$(dr --allow-restore=nosuchrel)"
if has "no relationship 'nosuchrel' is enrolled" "$out"; then
    ok "issue: a relationship this host never enrolled is refused"
else bad "issue: a relationship this host never enrolled is refused" "$out"; fi
[ -f "$GRANTS/nosuchrel" ] && bad "issue: ...and nothing was written" || ok "issue: ...and nothing was written"

for badlabel in '../etc' 'a b' 'x;y' ''; do
    out="$(dr --allow-restore="$badlabel")"
    if has "not a valid relationship label" "$out" || has "must run as root" "$out"; then
        ok "issue: label '$badlabel' is refused"
    else bad "issue: label '$badlabel' is refused" "$out"; fi
done
# The one that matters most of those: a traversal must not create a file
# outside the grant tree.
[ -e "$TMPD/etc" ] && bad "issue: ...and '../etc' wrote nothing outside the tree" || \
    ok "issue: ...and '../etc' wrote nothing outside the tree"

# ---------------------------------------------------------------------------
# 3. REPLACE IS NEVER IMPLIED  (owner: "REPLACE jawnie przy nadawaniu")
# ---------------------------------------------------------------------------
out="$(dr --allow-restore=lab1)"
check "replace: a plain grant permits create+rewind only" "create rewind" \
      "$(sed -n 's/^RESTORE_GRANT_MODES="\(.*\)"$/\1/p' "$GRANTS/lab1")"
if has "replace:      NO" "$out"; then ok "replace: ...and the operator is told so"
else bad "replace: ...and the operator is told so" "$out"; fi

# THE ASSERTION THIS SECTION EXISTS FOR: re-issuing must not quietly widen a
# live grant. A grant is a permission; changing what it permits is a decision,
# not a side effect of typing the command again with one more flag.
out="$(dr --allow-restore=lab1 --replace)"
if has "already exists and says" "$out"; then ok "replace: an UPGRADE of a live grant is refused"
else bad "replace: an upgrade of a live grant is refused" "$out"; fi
check "replace: ...and the grant on disk is unchanged" "create rewind" \
      "$(sed -n 's/^RESTORE_GRANT_MODES="\(.*\)"$/\1/p' "$GRANTS/lab1")"
if has "--deny-restore=lab1" "$out"; then ok "replace: ...and the refusal names the way to change it"
else bad "replace: ...and the refusal names the way to change it" "$out"; fi

# Re-issuing the SAME thing converges instead of failing -- the shape the gate's
# own `disable` verb already uses, so a retry after a lost acknowledgement is
# not a second error.
out="$(dr --allow-restore=lab1)"
if has "already says exactly this" "$out"; then ok "replace: re-issuing the same grant is a no-op success"
else bad "replace: re-issuing the same grant is a no-op success" "$out"; fi
# ...but the DELEGATION is re-applied (2026-10-15, pve9b): a scope root destroyed
# and recreated by root comes back with no `zfs allow`, and the re-issue the
# collector's repair names used to answer "nothing changed" and leave it so.
: > "$ZFS_TRACE"
out="$(ZFS_GONE=hdd/a/child dr --allow-restore=lab1)"
if grep -q -- "^allow -u zfsbackup-pve9 .* -- hdd/a$" "$ZFS_TRACE"; then
    ok "replace: ...and re-applies the delegation on the datasets present"
else bad "replace: ...and re-applies the delegation on the datasets present" "$(cat "$ZFS_TRACE")"; fi
if ! grep -q -- "^allow .* -- hdd/a/child$" "$ZFS_TRACE" && has "not here (nothing to delegate on): hdd/a/child" "$out"; then
    ok "replace: ...and names a dataset that is not there instead of failing on it"
else bad "replace: ...and names a dataset that is not there instead of failing on it" "$out"; fi

# Now the deliberate route, and the loud warning it must carry.
dr --deny-restore=lab1 >/dev/null
out="$(dr --allow-restore=lab1 --replace)"
check "replace: an explicit --replace grant permits it" "create rewind replace" \
      "$(sed -n 's/^RESTORE_GRANT_MODES="\(.*\)"$/\1/p' "$GRANTS/lab1")"
if has "REPLACE IS INCLUDED" "$out"; then ok "replace: ...and says so loudly"
else bad "replace: ...and says so loudly" "$out"; fi
if has "DESTROY data on this machine" "$out"; then
    ok "replace: ...in words that name the consequence, not the flag"
else bad "replace: ...in words that name the consequence" "$out"; fi

# ---------------------------------------------------------------------------
# 4. IT DOES NOT EXPIRE, SO IT MUST BE VISIBLE  (owner decision 3)
# ---------------------------------------------------------------------------
if grep -qE 'RESTORE_GRANT_(EXPIRES|NONCE)' "$DEPLOY"; then
    bad "durable: no expiry and no single-use token" "$(grep -nE 'RESTORE_GRANT_(EXPIRES|NONCE)' "$DEPLOY" | head -2)"
else
    ok "durable: no expiry and no single-use token"
fi
out="$(d --show-restore=lab1)"
if has "RESTORE_GRANT=present" "$out"; then ok "durable: --show-restore reports a live grant"
else bad "durable: --show-restore reports a live grant" "$out"; fi
if has "WARNING" "$out" && has "REPLACE" "$out"; then
    ok "durable: ...and a replace grant is shown as a warning, not a field"
else bad "durable: ...and a replace grant is shown as a warning" "$out"; fi
# Readable WITHOUT root. "Is anything allowed to overwrite this machine?" must
# be answerable by whoever is standing in front of it.
if has "RESTORE_GRANT=present" "$(d --show-restore=lab1)"; then
    ok "durable: ...and the question can be asked without root"
else bad "durable: ...and the question can be asked without root"; fi

# ---------------------------------------------------------------------------
# 5. TAKING IT BACK
# ---------------------------------------------------------------------------
out="$(dr --deny-restore=lab1)"
if has "TAKEN BACK" "$out"; then ok "revoke: the grant is taken back"
else bad "revoke: the grant is taken back" "$out"; fi
[ -f "$GRANTS/lab1" ] && bad "revoke: ...and the file is gone" || ok "revoke: ...and the file is gone"
if has "create rewind replace" "$out"; then
    ok "revoke: ...and the report names what it had permitted"
else bad "revoke: ...and the report names what it had permitted" "$out"; fi
out="$(dr --deny-restore=lab1)"
if has "nothing to take back" "$out"; then ok "revoke: taking back a grant that is not there is a no-op success"
else bad "revoke: taking back a grant that is not there is a no-op success" "$out"; fi
check "revoke: ...and it exits 0" "0" "$(dr --deny-restore=lab1 >/dev/null 2>&1; echo $?)"

# One relationship's grant is not another's.
dr --allow-restore=lab1 >/dev/null
out="$(d --show-restore=other)"
if has "RESTORE_GRANT=none" "$out"; then ok "scope: a grant for lab1 says nothing about 'other'"
else bad "scope: a grant for lab1 says nothing about 'other'" "$out"; fi

# ---------------------------------------------------------------------------
# 6. WHAT THE COLLECTOR SEES. The gate answers from the KEY's label, never from
#    anything the caller says, so this is also how a forgotten grant becomes
#    visible from the other end.
# ---------------------------------------------------------------------------
out="$(gate lab1)"
if has "RESTORE_GRANT=present" "$out" && has "RESTORE_GRANT_MODES=create rewind" "$out"; then
    ok "gate: PAIR-CONTROL status reports the grant"
else bad "gate: PAIR-CONTROL status reports the grant" "$out"; fi
out="$(gate other)"
if has "RESTORE_GRANT=none" "$out"; then ok "gate: ...and reports none where there is none"
else bad "gate: ...and reports none where there is none" "$out"; fi
# THE SCOPE, AS A LIST (2026-10-15, pve9): the whitelist was written `:-\ `, a
# range from ':' down to ' ', so a space failed it and every scope of MORE THAN
# ONE dataset went out as RESTORE_GRANT_DATASETS= -- which left the collector's
# replace-on-scope-root refusal with nothing to compare. A scope with a character
# outside the whitelist is still reported empty.
mkdir -p "$REL/multi" "$REL/junk"
printf 'RESTORE_GRANT_MODES="create rewind replace"\nRESTORE_GRANT_DATASETS="hdd/b/x hdd/b/x/docs hdd/b/x/mail"\n' > "$GRANTS/multi"
printf 'RESTORE_GRANT_MODES="create rewind replace"\nRESTORE_GRANT_DATASETS="hdd/b/x;rm -rf /"\n' > "$GRANTS/junk"
out="$(gate multi)"
if has "RESTORE_GRANT_DATASETS=hdd/b/x hdd/b/x/docs hdd/b/x/mail" "$out"; then
    ok "gate: a scope of several datasets is reported whole (space-separated list)"
else bad "gate: a scope of several datasets is reported whole (space-separated list)" "$out"; fi
out="$(gate junk)"
if printf '%s\n' "$out" | grep -qx "RESTORE_GRANT_DATASETS="; then
    ok "gate: ...and a scope with a character outside the whitelist is reported empty"
else bad "gate: ...and a scope with a character outside the whitelist is reported empty" "$out"; fi
rm -f "$GRANTS/multi" "$GRANTS/junk"

# A disabled relationship still answers, because a hard pause and a standing
# grant are different facts and an operator needs both.
: > "$REL/lab1/disabled"
out="$(gate lab1)"
if has "PAIR_STATE=DISABLED" "$out" && has "RESTORE_GRANT=present" "$out"; then
    ok "gate: a disabled relationship still reports its grant"
else bad "gate: a disabled relationship still reports its grant" "$out"; fi
rm -f "$REL/lab1/disabled"

# FAIL CLOSED on anything it cannot parse. The modes string is printed straight
# back to the collector and it came out of a file; a grant nobody can parse is
# not a grant, and reporting one would be this machine telling a collector it
# may overwrite it.
for junk in 'create; rm -rf /' 'CREATE REWIND' '$(id)' ''; do
    printf 'RESTORE_GRANT_MODES="%s"\n' "$junk" > "$GRANTS/lab1"
    out="$(gate lab1)"
    if has "RESTORE_GRANT=none" "$out"; then ok "gate: a malformed modes value '$junk' reads as NO grant"
    else bad "gate: a malformed modes value '$junk' reads as NO grant" "$out"; fi
done
# ...and the positive control that makes those four mean something: the same
# path with a well-formed value still reports present.
printf 'RESTORE_GRANT_MODES="create rewind"\n' > "$GRANTS/lab1"
if has "RESTORE_GRANT=present" "$(gate lab1)"; then
    ok "gate: control -- a well-formed value still reports present"
else bad "gate: control -- a well-formed value still reports present"; fi

# An unreadable grant file is also no grant. Guarded, because chmod 000 does
# not actually deny the owner on every filesystem this suite runs on (Git Bash
# over NTFS): a test that cannot create the condition must say so rather than
# assert against a condition that is not there.
chmod 000 "$GRANTS/lab1" 2>/dev/null
if [ -r "$GRANTS/lab1" ]; then
    echo "SKIP gate: an unreadable grant reads as NO grant (this filesystem ignores chmod 000)"
else
    out="$(gate lab1)"
    if has "RESTORE_GRANT=none" "$out"; then ok "gate: an unreadable grant reads as NO grant"
    else bad "gate: an unreadable grant reads as NO grant" "$out"; fi
fi
chmod 644 "$GRANTS/lab1" 2>/dev/null

# ---------------------------------------------------------------------------
# 7. THE GATE NEVER CREATES ONE. If the collector's own key could ask for a
#    grant, the grant would be the collector authorising itself, which is the
#    single thing this mechanism exists to prevent.
# ---------------------------------------------------------------------------
rm -f "$GRANTS/lab1"
for verb in "PAIR-CONTROL allow-restore" "PAIR-CONTROL grant" "PAIR-CONTROL allow-restore lab1"; do
    RELATIONSHIPS_DIR="$REL" RESTORE_GRANT_DIR="$GRANTS" \
        SSH_ORIGINAL_COMMAND="$verb" bash "$GATE" lab1 >/dev/null 2>&1
    if [ -f "$GRANTS/lab1" ]; then
        bad "gate: '$verb' must not create a grant" "it created $GRANTS/lab1"
        rm -f "$GRANTS/lab1"
    else
        ok "gate: '$verb' does not create a grant"
    fi
done
# Structural, and the one that survives a new verb being added: no write verb
# anywhere in the gate may name the grant tree.
if grep -nE '(>|>>|mkdir|touch|tee|cp |mv |chmod|chown).*RESTORE_GRANT_DIR' "$GATE" | grep -v '^\s*#' | grep -q .; then
    bad "gate: nothing in the gate writes into the grant tree" \
        "$(grep -nE '(>|>>|mkdir|touch|tee|cp |mv ).*RESTORE_GRANT_DIR' "$GATE" | head -3)"
else
    ok "gate: nothing in the gate writes into the grant tree"
fi

# ---------------------------------------------------------------------------
# 8. THE COLLECTOR'S SIDE: reading the answer, and refusing on anything unclear.
#
# This parser's input arrives from ANOTHER MACHINE over ssh, and the decision it
# produces is "may I destroy that machine's data". So every ambiguity resolves to
# NO, and the cases below are the shapes that must not be readable as a yes.
#
# The functions are lifted from the real file rather than stubbed -- the whole
# point is what the shipped code does with a hostile answer.
# ---------------------------------------------------------------------------
RESTORE="${RESTORE:-$REPO/zfs-restore.sh}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../harness.sh"
parse() {   # <label> <answer> -> the modes, or "NO"
    ( set -u
      log(){ :; }
      eval "$(product_fn "$RESTORE" restore_grant_parse)"
      restore_grant_parse "$1" "$2" 2>/dev/null || printf 'NO' )
}
require() {   # <label> <answer> <mode> -> "OK" or the refusal text
    ( set -u
      log(){ shift; printf '%s\n' "$*"; }
      eval "$(product_fn "$RESTORE" restore_grant_parse)"
      eval "$(product_fn "$RESTORE" restore_grant_require)"
      if restore_grant_require "$1" "$2" "$3" pve1; then printf 'OK'; fi )
}
GOOD="PAIR_STATE=ACTIVE
PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create rewind replace"

check "peer: a well-formed answer is read" "create rewind replace" "$(parse lab1 "$GOOD")"
# An ssh banner before the gate's own output must not break a real answer --
# and this is the positive control for every NO below.
check "peer: ...even behind an ssh banner" "create rewind replace" "$(parse lab1 "Welcome to pve1
$GOOD")"

# The refusals, each for its own reason.
check "peer: no answer at all is NOT a grant"           "NO" "$(parse lab1 "")"
check "peer: an absent grant is NOT a grant"            "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT=none")"
# THE ONE THAT MATTERS MOST: the gate derives the label from the KEY, so an
# answer about a different relationship cannot authorise this one. Without this
# check a collector holding one key could act on another relationship's grant.
check "peer: an answer about a DIFFERENT relationship is refused" "NO" "$(parse lab1 "PAIR_LABEL=other
RESTORE_GRANT=present
RESTORE_GRANT_MODES=replace")"
check "peer: two modes lines are refused, not resolved" "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create
RESTORE_GRANT_MODES=create rewind replace")"
check "peer: two label lines are refused"               "NO" "$(parse lab1 "PAIR_LABEL=lab1
PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=replace")"
check "peer: present with no modes is refused"          "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT=present")"
check "peer: modes without present is refused"          "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT_MODES=replace")"
check "peer: a shell metacharacter in modes is refused" "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=replace; rm -rf /")"
check "peer: uppercase modes are refused"               "NO" "$(parse lab1 "PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=REPLACE")"
# Indented keys are not the gate speaking: it emits at column zero, so anything
# else claiming to be a grant line is something else's output.
check "peer: indented keys are not the gate speaking"   "NO" "$(parse lab1 "  PAIR_LABEL=lab1
  RESTORE_GRANT=present
  RESTORE_GRANT_MODES=replace")"

# ---- and the decision on top of it ----------------------------------------
check "peer: a full grant authorises replace" "OK" "$(require lab1 "$GOOD" replace)"
check "peer: ...and rewind"                   "OK" "$(require lab1 "$GOOD" rewind)"
NOREP="PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create rewind"
out="$(require lab1 "$NOREP" replace)"
if has "needs 'replace'" "$out"; then ok "peer: a grant without replace does NOT authorise replace"
else bad "peer: a grant without replace does not authorise replace" "$out"; fi
check "peer: ...but it still authorises rewind" "OK" "$(require lab1 "$NOREP" rewind)"
# The remedy is a command for the OTHER machine. This side cannot grant itself
# anything, so a refusal that pointed here would be worse than useless.
if has "ON pve1" "$out"; then ok "peer: ...and the remedy names the machine that must run it"
else bad "peer: ...and the remedy names the machine that must run it" "$out"; fi
if has "--replace" "$out"; then ok "peer: ...and the exact flag it needs"
else bad "peer: ...and the exact flag it needs" "$out"; fi
# A mode this project does not define is refused rather than asked for.
out="$(require lab1 "$GOOD" obliterate)"
if has "is not a restore mode" "$out"; then ok "peer: an undefined mode is refused"
else bad "peer: an undefined mode is refused" "$out"; fi


# ---------------------------------------------------------------------------
# 9. WHAT THE RESTORE ACTUALLY RUNS, and the guard in front of it.
#
# The transport is snapsend.sh -- the push engine driven in the other direction
# (owner direction). Two things stand between "the operator picked a recovery
# point" and "the engine sends one", and both are here.
#
# `-e` is documented as "use existing LATEST snapshot", which reads like the
# engine gets no instruction about which. It filters by `-m` first and takes the
# newest survivor, so a FULL name leaves exactly one candidate. That behaviour is
# what makes a chosen recovery point expressible WITHOUT changing a frozen
# engine, so this suite pins the contract it depends on.
# ---------------------------------------------------------------------------
lift_r() { product_fn "$RESTORE" "$1"; }
pt() {   # <wanted name> <candidates> -> "OK" or the refusal text
    ( set -u
      log(){ shift; printf '%s\n' "$*"; }
      eval "$(lift_r restore_point_unique)"
      if restore_point_unique "$1" "$2"; then printf 'OK'; fi )
}
argv() {   # <mode> -> the argv, or "REFUSED"
    ( set -u
      log(){ :; }
      eval "$(lift_r restore_engine_argv)"
      if restore_engine_argv hdd/copy/vm acct@pve1:rpool/data/vm SNAPNAME "$1" >/dev/null 2>&1
      then printf '%s' "${RESTORE_ENGINE_ARGV[*]}"; else printf 'REFUSED'; fi )
}

CAND="automated_daily_2026-08-20_18-00-04
automated_daily_2026-08-22_18-00-04
automated_daily_2026-08-23_18-00-01
automated_hourly_2026-08-22_18-00-04"

check "point: a full snapshot name is unambiguous" "OK" \
      "$(pt automated_daily_2026-08-22_18-00-04 "$CAND")"
# The family prefix is what a cron job passes and what an operator might type by
# habit. For a RESTORE it is three answers, so it is refused rather than resolved
# to the newest -- the engine would silently take that one.
out="$(pt automated_daily_ "$CAND")"
if has "matches 3 snapshots" "$out"; then ok "point: a family prefix is refused, not resolved to the newest"
else bad "point: a family prefix is refused, not resolved to the newest" "$out"; fi
if has "automated_daily_2026-08-23_18-00-01" "$out"; then
    ok "point: ...and the refusal names what it matched"
else bad "point: ...and the refusal names what it matched" "$out"; fi
out="$(pt automated_daily_1999-01-01_00-00-00 "$CAND")"
if has "matches no snapshot" "$out"; then ok "point: a name that is not there is refused"
else bad "point: a name that is not there is refused" "$out"; fi
out="$(pt "" "$CAND")"
if has "no recovery point was chosen" "$out"; then ok "point: an empty choice is refused, not delegated to the engine"
else bad "point: an empty choice is refused" "$out"; fi

# THE DISCRIMINATING PAIR, and the reason this guard exists at all.
#
# snapsend selects with `grep "^$MESSAGE"` -- a REGEX. Every name this project
# generates is regex-inert, but passive relationships adopt names from foreign
# systems and a '.' matches any character. An implementation that checked
# uniqueness with `grep -F` or `=` would pass the first of these and send a
# DIFFERENT snapshot than the one chosen, which looks exactly like success.
DOTS="snap.2026
snapX2026
snap.2026b"
out="$(pt "snap.2026" "$DOTS")"
if has "matches 3 snapshots" "$out"; then ok "point: a '.' in the name is measured the way the ENGINE matches, not literally"
else bad "point: a '.' in the name is measured the way the engine matches" "$out"; fi
if has "regular expression" "$out"; then ok "point: ...and the refusal says why three, not just that it is three"
else bad "point: ...and the refusal says why three" "$out"; fi
check "point control: a name with no metacharacter is still unambiguous" "OK" \
      "$(pt snapX2026 "$DOTS")"

# ---- the command ----------------------------------------------------------
# The mode is a classification, so the flags are DERIVED from it here rather
# than supplied beside it. Two truths about one run is what that prevents.
check "argv: create sends without -f" \
      "-t -e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv create)"
check "argv: rewind sends without -f -- snapsend finds the base itself" \
      "-t -e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv rewind)"
check "argv: replace carries -f, which is what destroys the target" \
      "-f -t -e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv replace)"
check "argv: an undefined mode builds no command at all" "REFUSED" "$(argv obliterate)"
# The two invariants that hold on EVERY form: a restore never creates a snapshot
# on the copy (-e), and never lets the engine choose the point (-m).
for m in create rewind replace; do
    a="$(argv $m)"
    case "$a" in
        *"-t -e -m SNAPNAME"*) ok "argv: $m carries -e and the exact point" ;;
        *) bad "argv: $m carries -e and the exact point" "$a" ;;
    esac
done
# ...and -f appears ONLY for replace. Without this the three assertions above
# would pass against a builder that always destroyed the target.
n_f=0
for m in create rewind; do case "$(argv $m)" in *-f*) n_f=$((n_f+1)) ;; esac; done
check "argv: -f appears for replace and for nothing else" "0" "$n_f"


# ---------------------------------------------------------------------------
# 10. A WHOLE-RELATION RUN: continue past a failure, and report per dataset.
#
# Owner decision 7. The implementer recommended stopping at the first failure;
# the owner overruled, because a recovery is not a deployment -- stopping leaves
# a half-restored machine AND no information about the rest, exactly when the
# complete picture is most needed.
#
# What that obliges is what is asserted: the run continues, the report names
# datasets rather than counting them, and nine of ten does not exit 0.
#
# restore_one is stubbed per case: the subject here is the LOOP and the verdict,
# not what a single dataset does.
# ---------------------------------------------------------------------------
rs() {   # <rc list, space separated> -> "<rc>|<report>"
    ( set -u
      log(){ shift; printf '%s\n' "$*"; }
      # The isolation boundary is part of the loop under test since
      # REV-20260831-127: restore_run_scope calls restore_one THROUGH it, so
      # extracting only the loop leaves the call unresolved -- which shows up as
      # every dataset "unfit" with no reason, not as a missing-function error.
      eval "$(product_fn "$RESTORE" restore_one_isolated)"
      eval "$(product_fn "$RESTORE" restore_run_scope)"
      # The four collaborators this loop calls, stubbed for the same reason
      # restore_one is: the subject here is the LOOP and the verdict.
      #
      # restore_pause_take is the one that matters to say out loud. Since
      # 2026-08-27 a restore REFUSES when the relationship's schedule cannot be
      # stood down -- owner decision, grant and pause both -- and that
      # precondition is real, not a formality: with no stub this harness
      # produced "NOTHING was attempted" for every case, which is the guard
      # working. It is stubbed here rather than satisfied because a loop test
      # has nothing to say about it, and it IS satisfied and asserted in both
      # directions in test/restore/run.sh, where a real marker in a temp
      # RELATIONSHIPS_DIR stands the schedule down the way production does.
      restore_pause_take() { return 0; }
      restore_pause_release() { :; }
      restore_report_mount_state() { :; }
      restore_report_backup_cost() { :; }
      RESTORE_SCOPE_SRC=(); RESTORE_SCOPE_COPY=()
      k=0; for r in $1; do k=$((k+1))
          RESTORE_SCOPE_SRC+=("rpool/ds$k"); RESTORE_SCOPE_COPY+=("hdd/copy$k"); done
      RCS=($1); IDX=0
      # TWO PASSES GO THROUGH HERE NOW: the pre-flight (D, owner 2026-08-30) and
      # then the run (B). A single shared cursor was exhausted by the first pass
      # and the second read off the end of the fixture, which is a broken
      # harness, not a broken runner.
      #
      # The pre-flight always PASSES here, and that is the honest model rather
      # than a convenience: these fixtures describe what the TRANSFER does, and
      # a broken transfer is exactly the thing a pre-flight cannot predict. What
      # it predicts is unrestorability -- no snapshot, an ambiguous recovery
      # point, a missing grant, a mounted target -- and that half is asserted in
      # test/restore/relpolicy.sh with its own controls.
      restore_one() {
          if [ "${RESTORE_PREFLIGHT_ONLY:-0}" = 1 ]; then
              RESTORE_ONE_VERDICT="preflight-ok-for-$2"; return 0
          fi
          # KEYED BY DATASET, not by a cursor. Since REV-20260831-127 the
          # per-dataset step runs inside an isolation subshell, so an IDX kept
          # in this shell never advances -- and that is the property, not a
          # nuisance: one dataset's step can no longer leak state into the next.
          # The fixture names them rpool/ds1..N, so the position is IN the name.
          local k="${2##*/ds}"
          local r="${RCS[$((k - 1))]}"
          RESTORE_ONE_VERDICT="reason-for-$2"; return "$r"; }
      out="$(restore_run_scope)"; rc=$?
      printf '%s|%s' "$rc" "$out" )
}
rs_rc()  { printf '%s' "${1%%|*}"; }
rs_out() { printf '%s' "${1#*|}"; }

r="$(rs "0 0 0")"
check "run: every dataset recovered exits 0" "0" "$(rs_rc "$r")"
if has "all 3 dataset(s) in scope recovered" "$(rs_out "$r")"; then
    ok "run: ...and says so"
else bad "run: ...and says so" "$(rs_out "$r")"; fi

# THE CARRYING ASSERTION for decision 7: the dataset AFTER the failure was still
# attempted, and its result is in the report. A run that stopped would have no
# line for ds3 at all.
r="$(rs "0 1 0")"
check "run: nine of ten does not exit 0" "1" "$(rs_rc "$r")"
if has "rpool/ds3" "$(rs_out "$r")"; then
    ok "run: the run CONTINUES past a failure -- the dataset after it is still attempted"
else bad "run: the run continues past a failure" "ds3 is missing from: $(rs_out "$r")"; fi
if has "NOT DONE rpool/ds2" "$(rs_out "$r")"; then
    ok "run: ...and the one that failed is named, not counted"
else bad "run: ...and the one that failed is named" "$(rs_out "$r")"; fi
if has "PARTIAL -- 2 recovered, 1 did not" "$(rs_out "$r")"; then
    ok "run: ...and the summary says the machine is in a mixed state"
else bad "run: ...and the summary says the machine is in a mixed state" "$(rs_out "$r")"; fi
# The reason travels from the per-dataset step into the report. Without this the
# table would be two columns of names and no way to act on them.
if has "reason-for-rpool/ds2" "$(rs_out "$r")"; then
    ok "run: ...carrying the reason the step gave, not a generic failure"
else bad "run: ...carrying the reason the step gave" "$(rs_out "$r")"; fi

# Everything failed. The report is still owed -- a run that recovered nothing
# still has to hand over the map of what it tried.
r="$(rs "1 1")"
check "run: nothing recovered exits 1" "1" "$(rs_rc "$r")"
if has "NOTHING was recovered" "$(rs_out "$r")"; then
    ok "run: ...and says nothing was recovered, in those words"
else bad "run: ...and says nothing was recovered" "$(rs_out "$r")"; fi
if has "NOT DONE rpool/ds1" "$(rs_out "$r")" && has "NOT DONE rpool/ds2" "$(rs_out "$r")"; then
    ok "run: ...and still prints the per-dataset table"
else bad "run: ...and still prints the per-dataset table" "$(rs_out "$r")"; fi

# An empty scope. "Nothing matched" exiting 0 is how a mistyped scope becomes a
# recovery somebody believes happened.
r="$(rs "")"
check "run: an EMPTY scope is a refusal, not a clean run over nothing" "1" "$(rs_rc "$r")"
if has "not a completed recovery" "$(rs_out "$r")"; then
    ok "run: ...and says why, rather than exiting quietly"
else bad "run: ...and says why" "$(rs_out "$r")"; fi

# POSITIVE CONTROL for the exit-status rule: it must be capable of returning 0.
# Without this every assertion above would pass against a function that always
# failed -- which is the shape a fail-closed rewrite would most plausibly take.
check "run control: the all-recovered path really can exit 0" "0" "$(rs_rc "$(rs "0")")"

# The per-dataset step is the next slice, and its absence is STRUCTURAL rather
# than a note in a comment: a function that calls an undefined one fails at the
# moment it is first used, which for a recovery verb is the worst moment there
# is. This pair disappears on its own the day the step exists -- the second half
# is what proves the guard is about restore_one and not about refusing always.
nostep="$( set -u
  log(){ shift; printf '%s\n' "$*"; }
  eval "$(product_fn "$RESTORE" restore_run_scope)"
  RESTORE_SCOPE_SRC=(rpool/a); RESTORE_SCOPE_COPY=(hdd/a)
  restore_run_scope; printf '|%s' $? )"
if has "not built yet" "$nostep"; then ok "run: with no per-dataset step it refuses instead of calling an undefined function"
else bad "run: with no per-dataset step it refuses" "$nostep"; fi
check "run: ...and exits non-zero" "1" "${nostep##*|}"



# ---------------------------------------------------------------------------
# 11. restore_one -- the step that writes, and everything that stops it.
#
# The engine is replaced by a RECORDER: it appends its argv and exits with a
# chosen status. So every case below can assert two things at once -- the
# verdict, and whether the engine was invoked at all.
#
# `printf`, not `echo`, in that recorder. An earlier probe used echo and lost
# the `-e` from every argv it recorded, which made a correct builder look like
# it was dropping a flag. The instrument has to be measured too.
# ---------------------------------------------------------------------------
RONE="$TMPD/rone"; rm -rf "$RONE"; mkdir -p "$RONE"
{ printf '#!/bin/sh\n'
  printf 'printf "%%s " "$@" >> %s/ran; printf "\n" >> %s/ran\n' "$RONE" "$RONE"
  printf 'exit ${ENGINE_RC:-0}\n'; } > "$RONE/eng"
chmod +x "$RONE/eng"

r1() {   # <strategy> <grant answer> <point> <src> [engine rc] -> "<rc>|<verdict>|<argv>"
    : > "$RONE/ran"
    ( set -u
      log(){ shift; printf '%s\n' "$*" >&2; }
      for _fn in restore_point_unique restore_engine_argv restore_grant_parse restore_grant_require restore_scope_is_root restore_scope_root_repair restore_one; do eval "$(product_fn "$RESTORE" "$_fn")"; done
      zfs(){ case "$*" in
               *"-t snapshot"*) [ "${NOSNAP:-0}" -eq 1 ] && return 0
                                printf 'hdd/copy@automated_daily_2026-08-20_18-00-04\n'
                                printf 'hdd/copy@automated_daily_2026-08-22_18-00-04\n'
                                printf 'hdd/copy@automated_daily_2026-08-23_18-00-01\n' ;;
             esac; }
      # The answer comes from r1's OWN second argument. It used to be
      # `printf '%s' "$2"` inside the stub -- the stub's second argument, which
      # restore_one never passes (it calls `restore_grant_ask "$host"`) -- so
      # every case here ran with NO grant at all and the refusals below passed
      # for that reason, not their own (found 2026-10-15).
      _r1_grant="$2"
      restore_grant_ask(){ printf '%s' "$_r1_grant"; }
      # STUB_LIVE=1: the target answers a head GUID and "no recovery point", which
      # classifies full-live -> replace -- the only way to reach the scope guard.
      if [ "${STUB_ABSENT:-0}" -eq 1 ]; then
          restore_remote_state(){ printf 'absent'; }
          ssh(){ return 255; }
      fi
      if [ "${STUB_LIVE:-0}" -eq 1 ]; then
          restore_remote_state(){ printf '11111111111111111111'; }
          restore_remote_has_guid(){ return 1; }
          ssh(){ return 255; }   # no real host is ever asked anything
      fi
      RESTORE_ENGINE="$RONE/eng" ENGINE_RC="${5:-0}" RESTORE_LABEL=lab1 \
      RESTORE_STRATEGY="$1" RESTORE_POINT_NAME="$3" FAKE_REMOTE="${FAKE_REMOTE:-absent}" \
      restore_one hdd/copy "${4:-zfsbackup@pve1:rpool/data}" >/dev/null 2>&1
      printf '%s|%s' "$?" "$RESTORE_ONE_VERDICT" ) > "$RONE/res"
    printf '%s|%s' "$(cat "$RONE/res")" "$(tr -d '\n' < "$RONE/ran")"
}
# restore_grant_ask is stubbed to answer r1's second argument, so the harness
# can hand a different answer per case without a file.
r1x() { r1 "$1" "$2" "$3" "${4:-}" "${5:-0}"; }
GOODG="PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create rewind replace"
rc_of()   { printf '%s' "${1%%|*}"; }
verd_of() { local t="${1#*|}"; printf '%s' "${t%|*}"; }
argv_of() { printf '%s' "${1##*|}"; }

# THE MODE CLASSIFICATION IS NOT ASSERTED HERE ANY MORE, and that is deliberate.
#
# Under push the mode is decided by asking the TARGET what it holds -- one ssh,
# on the far side. A unit harness can only stub that answer, and an assertion
# over a stubbed classifier proves the stub. This suite had five such assertions
# and they were removed the day the classifier became remote.
#
# It is proven on the lab instead (pve9 -> pve1, 2026-08-27): `rewind` when the
# target's head is a snapshot the copy also holds, and `rollback` when the
# target holds something NEWER than the recovery point -- the case that would
# otherwise have asked the engine for a stream backwards in time.
#
# What stays here is everything a stub CAN honestly answer: that every refusal
# leaves the engine untouched.

# ---- THE CARRYING ASSERTIONS: every refusal leaves the engine untouched -----
# A refusal that still ran the engine would be the worst possible defect here --
# a message saying no, next to a transfer that happened.
for case_desc in \
    "no grant at all|increment|PAIR_LABEL=lab1
RESTORE_GRANT=none|" \
    "a grant without the needed mode|unproven|PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create rewind|" \
    "an ambiguous recovery point|ambiguous|$GOODG|" \
    "no strategy at all||$GOODG|" \
    "a point that matches several|increment|$GOODG|automated_daily_"
do
    d="${case_desc%%|*}"; rest="${case_desc#*|}"
    st="${rest%%|*}"; rest="${rest#*|}"
    gr="${rest%|*}"; pt="${rest##*|}"
    r="$(r1 "$st" "$gr" "$pt")"
    check "one: $d refuses" "1" "$(rc_of "$r")"
    if [ -z "$(argv_of "$r")" ]; then ok "one: ...and the engine was never invoked"
    else bad "one: $d -- the engine RAN despite the refusal" "$(argv_of "$r")"; fi
done

# ---- replace on the ROOT of the scope, and on a scope nobody reported --------
# 2026-10-15, pve9: an empty RESTORE_GRANT_SCOPE made this guard inert, and the
# gate reported every multi-dataset scope as empty -- so a replace from the
# mirror destroyed the scope root. Now an unreported scope refuses, and a root
# found in a LIST of several is still recognised. Neither may reach the engine.
r="$(STUB_LIVE=1 r1 full-live "$GOODG" automated_daily_2026-08-23_18-00-01)"
check "scope: replace with NO scope reported refuses" "1" "$(rc_of "$r")"
if has "did not report the scope" "$(verd_of "$r")"; then ok "scope: ...and says the scope was not reported"
else bad "scope: ...and says the scope was not reported" "$(verd_of "$r")"; fi
if [ -z "$(argv_of "$r")" ]; then ok "scope: ...and the engine was never invoked"
else bad "scope: unreported scope -- the engine RAN" "$(argv_of "$r")"; fi
r="$(STUB_LIVE=1 r1 full-live "$GOODG
RESTORE_GRANT_DATASETS=rpool/other rpool/data rpool/data/vm" automated_daily_2026-08-23_18-00-01)"
check "scope: replace on a root named in a LIST of several refuses" "1" "$(rc_of "$r")"
if has "ROOT of the delegated scope" "$(verd_of "$r")"; then ok "scope: ...and names it the scope root"
else bad "scope: ...and names it the scope root" "$(verd_of "$r")"; fi
if [ -z "$(argv_of "$r")" ]; then ok "scope: ...and the engine was never invoked"
else bad "scope: scope root -- the engine RAN" "$(argv_of "$r")"; fi
# A CHILD whose parent is in the scope is not a root: recreated, it comes back
# under the parent's delegation -- the way round the refusal above. It passes
# the guard and reaches the next check (the mount probe over ssh, which the
# harness cannot answer: "could not read whether ... is mounted" -> going ahead).
r="$(STUB_LIVE=1 r1 full-live "$GOODG
RESTORE_GRANT_DATASETS=rpool/data rpool/data/vm" automated_daily_2026-08-23_18-00-01 zfsbackup@pve1:rpool/data/vm)"
if has "ROOT of the delegated scope" "$(verd_of "$r")"; then
    bad "scope: a child whose parent is in the scope is NOT refused as a root" "$(verd_of "$r")"
else ok "scope: a child whose parent is in the scope is NOT refused as a root"; fi
r="$(STUB_LIVE=1 r1 full-live "$GOODG
RESTORE_GRANT_DATASETS=rpool/other rpool/data/vm" automated_daily_2026-08-23_18-00-01 zfsbackup@pve1:rpool/data/vm)"
if has "ROOT of the delegated scope" "$(verd_of "$r")"; then ok "scope: ...but a child whose parent is NOT in the scope is a root"
else bad "scope: ...but a child whose parent is NOT in the scope is a root" "$(verd_of "$r")"; fi
# CREATE onto a scope root that is GONE (2026-10-15, L2c): the account cannot
# create it -- no permission on its parent -- and the run used to send four
# creates into four "permission denied". Refused before the engine, with the
# repair; a child under a root that is in the scope is not affected.
r="$(STUB_ABSENT=1 r1 full-absent "$GOODG
RESTORE_GRANT_DATASETS=rpool/data rpool/data/vm" automated_daily_2026-08-23_18-00-01)"
check "scope: create onto a scope root that is gone refuses" "1" "$(rc_of "$r")"
if has "does not exist" "$(verd_of "$r")"; then ok "scope: ...and says the root is gone and why the account cannot make it"
else bad "scope: ...and says the root is gone and why the account cannot make it" "$(verd_of "$r")"; fi
if [ -z "$(argv_of "$r")" ]; then ok "scope: ...and the engine was never invoked"
else bad "scope: absent root -- the engine RAN" "$(argv_of "$r")"; fi
r="$(STUB_ABSENT=1 r1 full-absent "$GOODG
RESTORE_GRANT_DATASETS=rpool/data rpool/data/vm" automated_daily_2026-08-23_18-00-01 zfsbackup@pve1:rpool/data/vm)"
if [ -n "$(argv_of "$r")" ]; then ok "scope: create onto a CHILD of the scope root reaches the engine"
else bad "scope: create onto a CHILD of the scope root reaches the engine" "$(verd_of "$r")"; fi

# ---- a LOCAL target asks for no grant --------------------------------------
# The machine at risk is this one, and whoever runs this already has root on it.
# 2026-10-15: a local target is rolled back to the planner's base before the
# engine, and the result is measured by identity afterwards -- so the harness
# hands it the base (RESTORE_SRC_BASE_SNAP, what the planner sets) and a zfs
# that answers the rollback and the identity questions. LOCAL_NEWEST is what the
# source's newest snapshot reads as after the run.
r1local() {   # <strategy> [local newest snapshot] [base on the source] -> "<rc>|<verdict>|<argv>"
    : > "$RONE/ran"
    ( set -u
      log(){ shift; printf '%s\n' "$*" >&2; }
      for _fn in restore_point_unique restore_engine_argv restore_grant_parse restore_grant_require restore_scope_is_root restore_scope_root_repair restore_one; do eval "$(product_fn "$RESTORE" "$_fn")"; done
      P=automated_daily_2026-08-23_18-00-01
      zfs(){ case "$*" in
               "rollback -r "*)       printf 'ROLLBACK %s\n' "$3" >> "$RONE/ran" ;;
               *"-s createtxg"*)      printf '%s\n' "${LOCAL_NEWEST:-hdd/local/target@$P}" ;;
               *"-t snapshot"*)       printf 'hdd/copy@automated_daily_2026-08-22_18-00-04\n'
                                      printf 'hdd/copy@%s\n' "$P" ;;
               "list -H -o name "*)   printf '%s\n' "${@: -1}" ;;
               *" guid "*)            printf '111\n' ;;
               *" referenced "*)      printf '4096\n' ;;
             esac; }
      restore_grant_ask(){ printf '%s' "$2"; }
      RESTORE_ENGINE="$RONE/eng" ENGINE_RC=0 RESTORE_LABEL=lab1 \
      RESTORE_STRATEGY="$1" RESTORE_POINT_NAME="" LOCAL_NEWEST="${2:-}" \
      RESTORE_SRC_BASE_SNAP="${3-hdd/local/target@automated_daily_2026-08-22_18-00-04}" \
      restore_one hdd/copy hdd/local/target >/dev/null 2>&1
      printf '%s|%s' "$?" "$RESTORE_ONE_VERDICT" ) > "$RONE/res"
    printf '%s|%s' "$(cat "$RONE/res")" "$(tr -d '\n' < "$RONE/ran")"
}
r="$(r1local increment)"
check "one: a local target needs no grant" "0" "$(rc_of "$r")"
case "$(argv_of "$r")" in *hdd/local/target*) ok "one: ...and still reaches the engine" ;;
                          *) bad "one: ...and still reaches the engine" "$(argv_of "$r")" ;; esac
case "$(argv_of "$r")" in *"ROLLBACK hdd/local/target@automated_daily_2026-08-22_18-00-04"*) ok "one: a local target is rolled back to the base before the engine" ;;
                          *) bad "one: a local target is rolled back to the base before the engine" "$(argv_of "$r")" ;; esac
# THE 2026-10-15 DEFECT: the engine exits 0 but a newer snapshot still stands on
# the point (nothing was rolled back). That must read NOT recovered, not success.
r="$(r1local rollback hdd/local/target@automated_daily_2026-08-24_18-00-00)"
check "one: local -- engine rc 0 but a newer snapshot remains is NOT recovered (2 = changed, unfinished)" "2" "$(rc_of "$r")"
case "$(verd_of "$r")" in *"NOT at"*) ok "one: ...and the verdict says the source is NOT at the point" ;;
                          *) bad "one: ...and the verdict says the source is NOT at the point" "$(verd_of "$r")" ;; esac
# No base the planner could pin: refused before anything runs.
r="$(r1local increment "" "")"
check "one: local -- no pinned base refuses" "1" "$(rc_of "$r")"
case "$(argv_of "$r")" in "") ok "one: ...and neither a rollback nor the engine ran" ;;
                          *) bad "one: ...and neither a rollback nor the engine ran" "$(argv_of "$r")" ;; esac

# ---- a copy with nothing on it ---------------------------------------------
r="$( : > "$RONE/ran"
      ( set -u
        log(){ shift; printf '%s\n' "$*" >&2; }
        for _fn in restore_point_unique restore_engine_argv restore_grant_parse restore_grant_require restore_scope_is_root restore_scope_root_repair restore_one; do eval "$(product_fn "$RESTORE" "$_fn")"; done
        zfs(){ :; }
        restore_grant_ask(){ printf '%s' "$GOODG"; }
        RESTORE_ENGINE="$RONE/eng" RESTORE_STRATEGY=increment \
        restore_one hdd/copy zfsbackup@pve1:rpool/data >/dev/null 2>&1
        printf '%s|%s' "$?" "$RESTORE_ONE_VERDICT" )
      printf '|%s' "$(tr -d '\n' < "$RONE/ran")" )"
check "one: a copy with no snapshot at all refuses" "1" "$(rc_of "$r")"
if [ -z "$(argv_of "$r")" ]; then ok "one: ...without touching the engine"
else bad "one: ...without touching the engine" "$(argv_of "$r")"; fi

# ---------------------------------------------------------------------------
# 12. The grant pauses THIS host's own writers into the scope (2026-10-15).
#
# pve9, k2-bc restoring onto it: k2-ab's pull and prune on the same datasets
# kept running, because only the collector paused anything. Owner: nothing may
# write to a dataset being overwritten. Scope of lab1 = hdd/a hdd/a/child.
#   puller  -- managed target hdd/a                  -> paused by the grant
#   snapper -- LOCAL relationship, source hdd/a/child -> paused by the grant
#   far     -- managed target hdd/zzz                 -> untouched
#   manual  -- managed target hdd/a, ALREADY paused by the operator
#              -> left as it is, and the revocation does not resume it
# ---------------------------------------------------------------------------
rm -f "$GRANTS"/* 2>/dev/null
pw_rec() { printf 'CLIENT_NAME=%s\nSTATE=active\n%s\n' "$1" "$2" > "$CLI/$1.conf"; }
pw_rec puller  'MANAGED_DATASETS=hdd/a'
pw_rec snapper "RUX_MODE=local
REQUESTED_DATASETS=hdd/a/child"
pw_rec far     'MANAGED_DATASETS=hdd/zzz'
pw_rec manual  'MANAGED_DATASETS=hdd/a'
mkdir -p "$PSTATE/manual"; printf 'PAUSED_AT="2026-10-15 10:00:00"
PAUSED_REASON="by hand"
' > "$PSTATE/manual/paused"
pw_tag() { sed -n 's/^PAUSED_BY_GRANT="\(.*\)"$/\1/p' "$PSTATE/$1/paused" 2>/dev/null; }

out="$(dr --allow-restore=lab1)"
check "writers: the grant pauses a relationship whose target is in the scope" "lab1" "$(pw_tag puller)"
check "writers: ...and a LOCAL relationship whose source is in the scope" "lab1" "$(pw_tag snapper)"
check "writers: ...and leaves one outside the scope running" "no" "$([ -e "$PSTATE/far/paused" ] && echo yes || echo no)"
check "writers: an operator's own pause stays, untagged" "|by hand" "$(pw_tag manual)|$(sed -n 's/^PAUSED_REASON="\(.*\)"$/\1/p' "$PSTATE/manual/paused")"
check "writers: ...and the grant is written" "yes" "$([ -f "$GRANTS/lab1" ] && echo yes)"
if has "will NOT resume it" "$out"; then ok "writers: the operator is told the hand-made pause is not the grant's to lift"
else bad "writers: the operator is told the hand-made pause is not the grant's to lift" "$out"; fi

out="$(dr --deny-restore=lab1)"
check "writers: revoking resumes what the grant paused" "no|no" "$([ -e "$PSTATE/puller/paused" ] && echo yes || echo no)|$([ -e "$PSTATE/snapper/paused" ] && echo yes || echo no)"
check "writers: ...and NOT the operator's own pause" "yes" "$([ -e "$PSTATE/manual/paused" ] && echo yes || echo no)"

# A revocation that FAILED on a dataset that still exists: the collector may
# still write, so this host's jobs must not start writing too.
dr --allow-restore=lab1 >/dev/null
out="$(ZFS_FAIL_UNALLOW=1 dr --deny-restore=lab1)"; rc=$?
check "writers: a failed revocation keeps the grant's pauses" "lab1|1" "$(pw_tag puller)|$rc"
if has "STAY PAUSED" "$out"; then ok "writers: ...and says how to lift them"
else bad "writers: ...and says how to lift them" "$out"; fi
# The failed revocation above is pending (REV-20261016-147): finish it before the next grant.
dr --deny-restore=lab1 >/dev/null
# ...but a dataset that is GONE has no delegation left to revoke.
dr --allow-restore=lab1 >/dev/null
out="$(ZFS_FAIL_UNALLOW=1 ZFS_GONE="hdd/a hdd/a/child hdd/restore" dr --deny-restore=lab1)"
check "writers: a failed revocation on a dataset that is gone does not block the resume" "" "$(pw_tag puller)"
PATH="$BIN:$PATH" CLIENTS_DIR="$CLI" RELATIONSHIPS_DIR="$PSTATE" bash "$(dirname "$DEPLOY")/zfs-backup.sh" resume-writers lab1 >/dev/null 2>&1

# An unreadable record means the host cannot say who writes -- the grant must
# not be written over that silence.
rm -f "$GRANTS"/* 2>/dev/null
printf 'NOT_A_KEY=1
' > "$CLI/broken.conf"
out="$(dr --allow-restore=lab1)"; rc=$?
check "writers: an unreadable relationship record refuses the grant" "none" "$(ls "$GRANTS" 2>/dev/null | grep -q . && echo some || echo none)"
if has "could not be read" "$out"; then ok "writers: ...naming why"
else bad "writers: ...naming why" "$out"; fi
rm -f "$CLI"/*.conf; rm -rf "$PSTATE"/*

# ---------------------------------------------------------------------------
# 13. The restore namespace <pool>/restore (owner decision a, 2026-10-15).
#
# pve9 -> pve9b, `--onto hdd/restore/docs-test`: "permission denied" -- the
# account may create nothing outside the relationship's scope. The grant now
# also covers <pool>/restore, creates it when missing, records it, and the
# revocation takes the permission back without destroying anything.
# ---------------------------------------------------------------------------
rm -f "$GRANTS"/* 2>/dev/null; : > "$ZFS_TRACE"
out="$(ZFS_GONE=hdd/restore dr --allow-restore=lab1)"
trace="$(cat "$ZFS_TRACE")"
if has "create -- hdd/restore" "$trace"; then ok "namespace: a missing hdd/restore is created by the grant"
else bad "namespace: a missing hdd/restore is created by the grant" "$trace"; fi
if has "allow -u zfsbackup-pve9 receive,rollback,create,canmount,mountpoint,mount -- hdd/restore" "$trace"; then
    ok "namespace: ...and delegated to the relationship's account, mount included"
else bad "namespace: ...and delegated to the relationship's account, mount included" "$trace"; fi
check "namespace: the grant file records it" "hdd/restore" \
    "$(sed -n 's/^RESTORE_GRANT_NAMESPACES="\(.*\)"$/\1/p' "$GRANTS/lab1")"
: > "$ZFS_TRACE"
out="$(dr --allow-restore=lab1)"
if has "create -- hdd/restore" "$(cat "$ZFS_TRACE")"; then bad "namespace: an existing hdd/restore is not created again" "$(cat "$ZFS_TRACE")"
else ok "namespace: an existing hdd/restore is not created again"; fi
: > "$ZFS_TRACE"
out="$(dr --deny-restore=lab1)"
trace="$(cat "$ZFS_TRACE")"
if has "unallow -u zfsbackup-pve9 receive,rollback,create,canmount,mountpoint,mount -- hdd/restore" "$trace"; then
    ok "namespace: revoking takes the permission back"
else bad "namespace: revoking takes the permission back" "$trace"; fi
if has "destroy" "$trace"; then bad "namespace: ...and destroys nothing -- recovered data stays" "$trace"
else ok "namespace: ...and destroys nothing -- recovered data stays"; fi

# ---------------------------------------------------------------------------
# 14. P10 (owner 2026-10-15): what was mounted at grant time is mounted again on
# --deny-restore. A restore IN PLACE leaves the target unmounted and the delegated
# account cannot mount ("Insufficient privileges", pve9b); root does it here.
# ---------------------------------------------------------------------------
rm -f "$GRANTS"/* 2>/dev/null
out="$(ZFS_MOUNTED="hdd/a hdd/a/child" dr --allow-restore=lab1)"
check "mount: the grant records what is mounted in the scope" "hdd/a hdd/a/child" \
    "$(sed -n 's/^RESTORE_GRANT_MOUNTED="\(.*\)"$/\1/p' "$GRANTS/lab1")"
: > "$ZFS_TRACE"
out="$(ZFS_MOUNTED="" dr --deny-restore=lab1)"
mt="$(grep '^mount -- ' "$ZFS_TRACE" | tr '\n' '|')"
check "mount: revoking mounts again what the restore left unmounted, parent first" "mount -- hdd/a|mount -- hdd/a/child|" "$mt"
if has "mounted again: hdd/a" "$out"; then ok "mount: ...and says so"
else bad "mount: ...and says so" "$out"; fi
# Still mounted -> nothing to do; not mounted at grant time -> never mounted by the revocation.
out="$(ZFS_MOUNTED="hdd/a hdd/a/child" dr --allow-restore=lab1)"; : > "$ZFS_TRACE"
out="$(ZFS_MOUNTED="hdd/a hdd/a/child" dr --deny-restore=lab1)"
check "mount: what is still mounted is left alone" "" "$(grep '^mount -- ' "$ZFS_TRACE")"
out="$(ZFS_MOUNTED="" dr --allow-restore=lab1)"; : > "$ZFS_TRACE"
out="$(ZFS_MOUNTED="" dr --deny-restore=lab1)"
check "mount: what was NOT mounted when the grant was issued is not mounted by the revocation" "" "$(grep '^mount -- ' "$ZFS_TRACE")"


# ---------------------------------------------------------------------------
# 15. REV-20261016-147: a failed revocation is RETRIED, not forgotten.
#
# The grant used to be unlinked before `zfs unallow`; a failed unallow left no
# record, so the next --deny-restore said "nothing to take back", resumed this
# host's writers and returned 0 while the account kept its delegation. Sequence:
# allow -> unallow fails -> fails again -> succeeds. At every step: exit status,
# unallow calls attempted, grant-owned pause, operator pause, revocation record.
# ---------------------------------------------------------------------------
REVD="$GRANTS.revoking"
rm -f "$GRANTS"/* 2>/dev/null; rm -rf "$REVD" "$PSTATE"/*
pw_rec puller 'MANAGED_DATASETS=hdd/a'
pw_rec manual 'MANAGED_DATASETS=hdd/a/child'
mkdir -p "$PSTATE/manual"; printf 'PAUSED_AT="2026-10-16 10:00:00"\nPAUSED_REASON="by hand"\n' > "$PSTATE/manual/paused"
rv_state() {   # <rc> -> "rc|unallow calls|puller paused|manual paused|grant|record"
    printf '%s|%s|%s|%s|%s|%s' "$1" "$(grep -c '^unallow ' "$ZFS_TRACE")" \
        "$(pw_tag puller)" "$([ -e "$PSTATE/manual/paused" ] && echo manual || echo -)" \
        "$([ -e "$GRANTS/lab1" ] && echo grant || echo -)" "$([ -e "$REVD/lab1" ] && echo record || echo -)"
}
: > "$ZFS_TRACE"
dr --allow-restore=lab1 >/dev/null; rc=$?
check "retry: allow pauses the writer and writes the grant" "0|0|lab1|manual|grant|-" "$(rv_state $rc)"
: > "$ZFS_TRACE"
out1="$(ZFS_FAIL_UNALLOW=1 dr --deny-restore=lab1)"; rc=$?
# 3 unallows: hdd/a, hdd/a/child, hdd/restore -- all exist in the stub.
check "retry: a failed revocation -- rc 1, pauses kept, declaration gone, record kept" "1|3|lab1|manual|-|record" "$(rv_state $rc)"
if has "revoked:      receive" "$out1"; then bad "retry: ...and never claims the scope was revoked" "$out1"
else ok "retry: ...and never claims the scope was revoked"; fi
out="$(dr --allow-restore=lab1)"; rc=$?
if [ "$rc" -ne 0 ] && has "has not finished revoking" "$out" && [ ! -e "$GRANTS/lab1" ]; then
    ok "retry: a new grant is refused while the revocation is pending"
else bad "retry: a new grant is refused while the revocation is pending" "rc=$rc $out"; fi
: > "$ZFS_TRACE"
out2="$(ZFS_FAIL_UNALLOW=1 dr --deny-restore=lab1)"; rc=$?
check "retry: a second failure RETRIES the revocation and stays fail-closed" "1|3|lab1|manual|-|record" "$(rv_state $rc)"
if has "nothing to take back" "$out2"; then bad "retry: ...without the 'nothing to take back' no-op" "$out2"
else ok "retry: ...without the 'nothing to take back' no-op"; fi
: > "$ZFS_TRACE"
out3="$(dr --deny-restore=lab1)"; rc=$?
check "retry: a successful retry revokes, then resumes only the grant's pause, and clears the record" "0|3||manual|-|-" "$(rv_state $rc)"
: > "$ZFS_TRACE"
out4="$(dr --deny-restore=lab1)"; rc=$?
check "retry: a repeated denial after success is a harmless no-op" "0|0||manual|-|-" "$(rv_state $rc)"

# THE ALREADY-PUBLISHED PARTIAL STATE (criterion 4): grant file gone, no record --
# what the old code left after a failed revocation -- and the grant's pause still
# there. Absence of the file is not proof: revoke from the manifest first.
mkdir -p "$PSTATE/puller"; printf 'PAUSED_AT="x"\nPAUSED_REASON="restore grant lab1"\nPAUSED_BY_GRANT="lab1"\n' > "$PSTATE/puller/paused"
: > "$ZFS_TRACE"
out="$(ZFS_FAIL_UNALLOW=1 dr --deny-restore=lab1)"; rc=$?
check "legacy: orphaned grant pause + failed revocation -> rc 1, pause kept, revocation attempted" "1|3|lab1|manual|-|-" "$(rv_state $rc)"
: > "$ZFS_TRACE"
out="$(dr --deny-restore=lab1)"; rc=$?
check "legacy: ...and once the revocation works, the pause is resumed" "0|3||manual|-|-" "$(rv_state $rc)"
rm -f "$CLI"/*.conf; rm -rf "$PSTATE"/* "$REVD"


echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
