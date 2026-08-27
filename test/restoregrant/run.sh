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
REL="$TMPD/rel"; GRANTS="$TMPD/grants"; BIN="$TMPD/bin"
mkdir -p "$REL/lab1" "$REL/other" "$GRANTS" "$BIN"

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

d()  { PAIR_GATE_STATE_DIR="$REL" RESTORE_GRANT_DIR="$GRANTS" bash "$DEPLOY" "$@" 2>&1; }
dr() { PATH="$BIN:$PATH" PAIR_GATE_STATE_DIR="$REL" RESTORE_GRANT_DIR="$GRANTS" bash "$DEPLOY" "$@" 2>&1; }
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
parse() {   # <label> <answer> -> the modes, or "NO"
    ( set -u
      log(){ :; }
      eval "$(sed -n '/^restore_grant_parse() {/,/^}/p' "$RESTORE")"
      restore_grant_parse "$1" "$2" 2>/dev/null || printf 'NO' )
}
require() {   # <label> <answer> <mode> -> "OK" or the refusal text
    ( set -u
      log(){ shift; printf '%s\n' "$*"; }
      eval "$(sed -n '/^restore_grant_parse() {/,/^}/p;/^restore_grant_require() {/,/^}/p' "$RESTORE")"
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


echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
