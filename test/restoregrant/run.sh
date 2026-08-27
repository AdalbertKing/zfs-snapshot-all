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
lift_r() { sed -n "/^$1() {/,/^}/p" "$RESTORE"; }
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
      "-e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv create)"
check "argv: rewind sends without -f -- snapsend finds the base itself" \
      "-e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv rewind)"
check "argv: replace carries -f, which is what destroys the target" \
      "-f -e -m SNAPNAME hdd/copy/vm acct@pve1:rpool/data/vm" "$(argv replace)"
check "argv: an undefined mode builds no command at all" "REFUSED" "$(argv obliterate)"
# The two invariants that hold on EVERY form: a restore never creates a snapshot
# on the copy (-e), and never lets the engine choose the point (-m).
for m in create rewind replace; do
    a="$(argv $m)"
    case "$a" in
        *"-e -m SNAPNAME"*) ok "argv: $m carries -e and the exact point" ;;
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
      eval "$(sed -n '/^restore_run_scope() {/,/^}/p' "$RESTORE")"
      RESTORE_SCOPE_SRC=(); RESTORE_SCOPE_COPY=()
      k=0; for r in $1; do k=$((k+1))
          RESTORE_SCOPE_SRC+=("rpool/ds$k"); RESTORE_SCOPE_COPY+=("hdd/copy$k"); done
      RCS=($1); IDX=0
      restore_one() { local r="${RCS[$IDX]}"; IDX=$((IDX+1))
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
  eval "$(sed -n '/^restore_run_scope() {/,/^}/p' "$RESTORE")"
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
      eval "$(sed -n '/^restore_point_unique() {/,/^}/p;/^restore_engine_argv() {/,/^}/p;/^restore_grant_parse() {/,/^}/p;/^restore_grant_require() {/,/^}/p;/^restore_one() {/,/^}/p' "$RESTORE")"
      zfs(){ case "$*" in
               *"-t snapshot"*) [ "${NOSNAP:-0}" -eq 1 ] && return 0
                                printf 'hdd/copy@automated_daily_2026-08-20_18-00-04\n'
                                printf 'hdd/copy@automated_daily_2026-08-22_18-00-04\n'
                                printf 'hdd/copy@automated_daily_2026-08-23_18-00-01\n' ;;
             esac; }
      restore_grant_ask(){ printf '%s' "$2"; }
      RESTORE_ENGINE="$RONE/eng" ENGINE_RC="${5:-0}" RESTORE_LABEL=lab1 \
      RESTORE_STRATEGY="$1" RESTORE_POINT_NAME="$3" \
      restore_one hdd/copy "${4:-zfsbackup@pve1:rpool/data}" >/dev/null 2>&1
      printf '%s|%s' "$?" "$RESTORE_ONE_VERDICT" ) > "$RONE/res"
    printf '%s|%s' "$(cat "$RONE/res")" "$(tr -d '\n' < "$RONE/ran")"
}
# restore_grant_ask is stubbed to echo its SECOND argument, so the harness can
# hand a different answer per case without a file. The real one takes one.
r1x() { r1 "$1" "$2" "$3" "${4:-}" "${5:-0}"; }
GOODG="PAIR_LABEL=lab1
RESTORE_GRANT=present
RESTORE_GRANT_MODES=create rewind replace"
rc_of()   { printf '%s' "${1%%|*}"; }
verd_of() { local t="${1#*|}"; printf '%s' "${t%|*}"; }
argv_of() { printf '%s' "${1##*|}"; }

# ---- the three modes reach the engine with the flags their classification says
r="$(r1 full-absent "$GOODG" "" )"
check "one: full-absent classifies as create" "0" "$(rc_of "$r")"
case "$(argv_of "$r")" in
    "-e -m automated_daily_2026-08-23_18-00-01 hdd/copy zfsbackup@pve1:rpool/data "*)
        ok "one: ...and the engine is called with -e and the exact point, no -f" ;;
    *) bad "one: ...and the engine is called with -e and the exact point, no -f" "$(argv_of "$r")" ;;
esac
r="$(r1 increment "$GOODG" "")"
check "one: a proven common base classifies as rewind" "0" "$(rc_of "$r")"
case "$(argv_of "$r")" in *-f*) bad "one: ...and rewind does NOT carry -f" "$(argv_of "$r")" ;;
                          *)    ok "one: ...and rewind does NOT carry -f" ;; esac
r="$(r1 unproven "$GOODG" "")"
check "one: an UNPROVEN base classifies as replace, not rewind" "0" "$(rc_of "$r")"
case "$(argv_of "$r")" in -f*) ok "one: ...and replace carries -f, which is what destroys the target" ;;
                          *)   bad "one: ...and replace carries -f" "$(argv_of "$r")" ;; esac

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

# ---- a LOCAL target asks for no grant --------------------------------------
# The machine at risk is this one, and whoever runs this already has root on it.
r="$(r1 increment "" "" hdd/local/target)"
check "one: a local target needs no grant" "0" "$(rc_of "$r")"
case "$(argv_of "$r")" in *hdd/local/target*) ok "one: ...and still reaches the engine" ;;
                          *) bad "one: ...and still reaches the engine" "$(argv_of "$r")" ;; esac

# ---- the engine's own failure ----------------------------------------------
r="$(r1 increment "$GOODG" "" zfsbackup@pve1:rpool/data 1)"
check "one: a failing engine is a failing dataset" "1" "$(rc_of "$r")"
if has "the engine failed" "$(verd_of "$r")"; then
    ok "one: ...and the verdict says so without paraphrasing the engine"
else bad "one: ...and the verdict says so" "$(verd_of "$r")"; fi

# ---- a copy with nothing on it ---------------------------------------------
r="$( : > "$RONE/ran"
      ( set -u
        log(){ shift; printf '%s\n' "$*" >&2; }
        eval "$(sed -n '/^restore_point_unique() {/,/^}/p;/^restore_engine_argv() {/,/^}/p;/^restore_grant_parse() {/,/^}/p;/^restore_grant_require() {/,/^}/p;/^restore_one() {/,/^}/p' "$RESTORE")"
        zfs(){ :; }
        restore_grant_ask(){ printf '%s' "$GOODG"; }
        RESTORE_ENGINE="$RONE/eng" RESTORE_STRATEGY=increment \
        restore_one hdd/copy zfsbackup@pve1:rpool/data >/dev/null 2>&1
        printf '%s|%s' "$?" "$RESTORE_ONE_VERDICT" )
      printf '|%s' "$(tr -d '\n' < "$RONE/ran")" )"
check "one: a copy with no snapshot at all refuses" "1" "$(rc_of "$r")"
if [ -z "$(argv_of "$r")" ]; then ok "one: ...without touching the engine"
else bad "one: ...without touching the engine" "$(argv_of "$r")"; fi


echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
