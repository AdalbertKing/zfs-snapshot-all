#!/bin/bash
# Tests for test/impact.sh -- the "what do I have to test?" resolver.
#
# No root, no ZFS, no network: this reads config files and prints plans.
#
# Two kinds of case here. Most run against small fixture graphs, so a change in
# the real deps.conf never breaks them. The last block deliberately does the
# opposite and runs --verify against the REAL tree: that assertion is the whole
# anti-drift mechanism, and a fixture cannot stand in for it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMPACT="${IMPACT:-$REPO/test/impact.sh}"
FIX="$SCRIPT_DIR/fixtures"

[ -x "$IMPACT" ] || { echo "cannot find executable impact.sh at $IMPACT" >&2; exit 1; }

PASS=0
FAIL=0

# One place that knows how to strip the ANSI bold: the escape has now been
# mangled twice by edits that reached through another tool.
strip_ansi() { sed 's/\[[0-9;]*m//g'; }

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"; PASS=$((PASS + 1))
    else
        echo "FAIL $label"; echo "     expected: [$expected]"; echo "     actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# Strip the ANSI bold the headings use, so assertions match plain text.
run_impact() { IMPACT_CONF="$1" "$IMPACT" "${@:2}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

echo "=== impact.sh tests ==="

# --- resolution --------------------------------------------------------------

OUT="$(run_impact "$FIX/basic.conf" -f snapsend.sh)"
check "a changed file names its own suite" "1" \
      "$(echo "$OUT" | grep -c 'test/snapsend/run.sh')"
check "a changed file names its manual obligation" "1" \
      "$(echo "$OUT" | grep -c 'manual-thing')"
check "a changed file names its contract" "1" \
      "$(echo "$OUT" | grep -c 'a-contract')"

# The transitive edge is the one worth pinning: it is derived from the code
# (snapsend.sh sources lib-zfs-snap.sh), not declared, so a refactor that moves
# the source line silently changes the answer.
OUT="$(run_impact "$FIX/basic.conf" -f lib-zfs-snap.sh)"
check "changing the lib pulls in its consumers' suites" "1" \
      "$(echo "$OUT" | grep -c 'test/snapsend/run.sh')"
check "changing the lib pulls in the consumers' manual obligations" "1" \
      "$(echo "$OUT" | grep -c 'manual-thing')"

OUT="$(run_impact "$FIX/basic.conf" -f README.md)"
check "a non-shell file with no obligations resolves to nothing" "1" \
      "$(echo "$OUT" | grep -c 'Nothing in the graph is affected')"

OUT="$(run_impact "$FIX/basic.conf" -f brand-new.sh)"
check "an undeclared shell file is reported, not silently ignored" "1" \
      "$(echo "$OUT" | grep -c 'NOT IN THE GRAPH')"

# --- parsing -----------------------------------------------------------------
# A wrapped prose line containing '=' (e.g. "canmount=on") must extend the
# previous field, not start a new one. Getting this wrong truncates exactly the
# explanation an operator needs, and does it silently.
OUT="$(run_impact "$FIX/basic.conf" -f snapsend.sh)"
check "a wrapped line containing '=' continues the field" "1" \
      "$(echo "$OUT" | grep -c 'tail of the sentence survives')"

# A directory section ("test/fixtures/") has to cover files beneath it: the
# golden files ARE the gen-cron test, and enumerating them would go stale.
OUT="$(run_impact "$FIX/prefix.conf" -f some/dir/whatever.conf)"
check "a directory section covers files beneath it" "1"       "$(echo "$OUT" | grep -c 'test/run.sh')"
OUT="$(run_impact "$FIX/prefix.conf" -f other/thing.conf)"
check "a path outside every directory section still resolves to nothing" "1"       "$(echo "$OUT" | grep -c 'Nothing in the graph is affected')"

# --- drift detection ---------------------------------------------------------
# Each fixture below is a graph that is wrong in exactly one way.

verify_rc() { IMPACT_CONF="$1" "$IMPACT" --verify >/dev/null 2>&1; echo $?; }

check "verify rejects a one-sided contract membership" "1" "$(verify_rc "$FIX/asymmetric.conf")"
OUT="$(run_impact "$FIX/asymmetric.conf" --verify)"
check "verify names the asymmetric contract" "1" "$(echo "$OUT" | grep -c 'ASYMMETRIC')"

check "verify rejects a reference to an undeclared suite" "1" "$(verify_rc "$FIX/unknown-suite.conf")"

check "verify rejects a section for a file that does not exist" "1" "$(verify_rc "$FIX/missing-file.conf")"

# --- the real graph ----------------------------------------------------------
# Deliberately not a fixture: this is the assertion that keeps deps.conf honest
# as the tree changes. If it fails, the graph is stale -- that is the finding,
# not a broken test.
check "the REAL deps.conf is consistent with the REAL tree" "0"       "$("$IMPACT" --verify >/dev/null 2>&1; echo $?)"

OUT="$("$IMPACT" --graph)"
check "the graph renders as mermaid" "1" "$(echo "$OUT" | grep -c '^graph LR')"
check "the graph includes contract nodes" "1" \
      "$(echo "$OUT" | grep -c 'contract: recv-side-creation')"

# Mermaid node ids may only hold word characters. A path-derived id like
# "F_test/impact/run_sh" parses as a link and silently breaks the whole
# diagram -- the file still appears in the source, so it is easy to miss.
check "graph node ids are mermaid-safe" "0" \
      "$("$IMPACT" --graph | grep -cE '^  [A-Za-z]_[A-Za-z0-9_]*[/.]')"
# Match the node DECLARATION, not every mention: the same id also appears on
# each edge line, so a bare name count is not a fact about the graph.
check "a path-named file still gets a node" "1" \
      "$("$IMPACT" --graph | grep -c 'F_test_impact_run_sh(\[')"

# Derived from the graph, not hardcoded: a count literal here would have to be
# edited every time a suite is added, and the version that goes stale is the
# assertion, not the code.
OUT="$("$IMPACT" --all 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
check "--all lists every declared suite" "$(grep -c '^\[suite:' "$REPO/test/deps.conf")" \
      "$(echo "$OUT" | grep -cE '^  (sudo )?\./test/')"

# docs/PROJECT_STATUS.md is the shared current-state document, and the reviewer
# reads it from GitHub rather than from the session that wrote it. Whether its
# prose is still TRUE is a judgement no test can make -- that is why
# `project-status` is a manual obligation. But whether it still knows about every
# suite is mechanical, and a suite the status doc has never heard of is a
# reviewer being told the coverage is smaller than it is.
# Matched as a TABLE ROW, not as a bare mention: `zfsbackup` is also the name of
# the delegated account, so a loose grep found the suite in a sentence about
# something else entirely and passed while the table was still empty.
missing=""
for s in $(grep '^\[suite:' "$REPO/test/deps.conf" | sed 's/\[suite://;s/\]//'); do
    grep -q -- "^| \`$s\` |" "$REPO/docs/PROJECT_STATUS.md" || missing="$missing $s"
done
check "every declared suite appears in PROJECT_STATUS.md" "" "$missing"


# --- the freshness invariant, at the lifecycle boundary ----------------------
#
# REV-20260807-068 F1. The gate used to name the last behaviour-changing COMMIT,
# which cannot be checked before that commit exists -- so run as a pre-stage
# gate it reported clean and blessed a commit that landed stale. I cited exactly
# such a run in eea6339 while producing a stale tree.
#
# Each case is a throwaway git repo holding a COPY OF THE SCRIPT UNDER TEST, so
# the script's own $REPO resolves to that repo with no override, and the same
# construction runs the negative control against the old implementation:
#
#   IMPACT_UNDER_TEST=/path/to/old/impact.sh ./test/impact/run.sh
UNDER_TEST="${IMPACT_UNDER_TEST:-$IMPACT}"
FRESH_TMP="$(mktemp -d)"; trap 'rm -rf "$FRESH_TMP"' EXIT

# fresh_world <name> -> $FW, a git repo whose status marker is current
fresh_world() {
    FW="$FRESH_TMP/$1"; rm -rf "$FW"; mkdir -p "$FW/test" "$FW/docs"
    cp "$UNDER_TEST" "$FW/test/impact.sh"; chmod +x "$FW/test/impact.sh"
    printf 'echo original\n' > "$FW/engine.sh"
    cat > "$FW/test/deps.conf" <<'EOF'
[file:engine.sh]
suites    = only
manual    = project-status

[suite:only]
cmd   = ./test/only.sh
needs = nothing
EOF
    printf '# status\n\n| `only` | 1/1 | x |\n' > "$FW/docs/PROJECT_STATUS.md"
    git -C "$FW" init -q >/dev/null 2>&1
    git -C "$FW" config user.email t@t; git -C "$FW" config user.name t
    # Stage FIRST. Since REV-068 round 3 the marker is derived from the index,
    # so refreshing before anything is staged has nothing to hash and refuses.
    git -C "$FW" add -A >/dev/null 2>&1
    # Run from INSIDE the world. The pre-REV-068 gate resolves git against the
    # CURRENT DIRECTORY, not $REPO, so invoking it from the real repo made it
    # measure the real repo -- the marker "is not a commit in this repository"
    # while the world was perfectly consistent.
    if ! (cd "$FW" && ./test/impact.sh --refresh-status) >/dev/null 2>&1; then
        # The script under test predates --refresh-status: give it the marker
        # IT understands, naming the base commit, so the cases measure the
        # PROPERTY rather than the absence of a marker.
        #
        # Without this the control was worthless and actively misleading: every
        # case came back NOT-CLEAN because the old gate found no marker at all,
        # so the pending-change case "passed" against the old implementation and
        # appeared to show there was nothing to fix.
        git -C "$FW" commit -qm base >/dev/null 2>&1
        printf '<!-- status-covers-commit: %s -->
' "$(git -C "$FW" rev-parse --short HEAD)"             >> "$FW/docs/PROJECT_STATUS.md"
        git -C "$FW" add -A >/dev/null 2>&1; git -C "$FW" commit -qm marker >/dev/null 2>&1
        return
    fi
    git -C "$FW" add -A >/dev/null 2>&1; git -C "$FW" commit -qm base >/dev/null 2>&1
}

# fresh_says -> the freshness section's verdict: CLEAN or NOT-CLEAN
fresh_says() {
    local out
    out="$( (cd "$FW" && ./test/impact.sh --verify) 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    # Read ONLY the freshness section: the throwaway repo has no reviews, so the
    # protocol check fails there for reasons unrelated to this property.
    out="$(printf '%s\n' "$out" | awk '/PROJECT_STATUS.md still describes/{f=1;next} /^== /{f=0} f')"
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then echo CLEAN; else echo NOT-CLEAN; fi
}

G() { git -C "$FW" "$@" >/dev/null 2>&1; }
IMP() { (cd "$FW" && ./test/impact.sh "$@"); }

fresh_world clean
check "freshness: an up-to-date staged status on a clean tree is accepted" "CLEAN" "$(fresh_says)"

# THE DECISIVE CASE (REV-068 round 2). Stage the behaviour change, refresh the
# status into the WORKING TREE, and do not stage it. The working tree is
# self-consistent, so a worktree-based gate says clean -- and the commit that
# follows records the NEW behaviour with the OLD status.
fresh_world split
printf 'echo CHANGED
' > "$FW/engine.sh"
G add engine.sh
IMP --refresh-status >/dev/null 2>&1
check "freshness: staged change + UNSTAGED refreshed status is refused" "NOT-CLEAN" "$(fresh_says)"
# ...and the reason it must be refused, demonstrated rather than argued: commit
# exactly what was staged and the committed tree is stale.
G commit -qm "what the gate was asked to bless"
check "freshness: ...because committing exactly that leaves a stale tree" "NOT-CLEAN" "$(fresh_says)"

# Staging the refreshed status is what completes the sequence.
fresh_world sequence
printf 'echo CHANGED
' > "$FW/engine.sh"
G add engine.sh
IMP --refresh-status >/dev/null 2>&1
G add docs/PROJECT_STATUS.md
check "freshness: staging the refreshed status makes it clean" "CLEAN" "$(fresh_says)"
G commit -qm staged
check "freshness: and the tree it committed is clean" "CLEAN" "$(fresh_says)"

# The verdict is about what the next commit RECORDS. An unstaged working-tree
# edit is not in that commit, so it must not make the gate fail.
#
# This REVERSES a case pinned in the previous round, which asserted that any
# pending working-tree change was unclean. That was the wrong invariant: it
# fails on edits the commit will not contain, and -- far worse -- it passed the
# split above, which the commit WILL contain.
fresh_world unstaged
printf 'echo CHANGED
' > "$FW/engine.sh"
check "freshness: an UNSTAGED watched edit is not part of the next commit" "CLEAN" "$(fresh_says)"

# Moving the index after a clean verification invalidates it.
fresh_world mutated
printf 'echo ONE
' > "$FW/engine.sh"
G add engine.sh
IMP --refresh-status >/dev/null 2>&1
G add docs/PROJECT_STATUS.md
check "freshness: clean after staging the refresh" "CLEAN" "$(fresh_says)"
printf 'echo TWO
' > "$FW/engine.sh"
G add engine.sh
check "freshness: staging a further watched change invalidates it" "NOT-CLEAN" "$(fresh_says)"

# The watched SET comes from the staged deps.conf: a config change that brings a
# new file under the obligation is itself part of what is about to land.
fresh_world configchange
printf 'echo other
' > "$FW/other.sh"
printf '
[file:other.sh]
suites    = only
manual    = project-status
' >> "$FW/test/deps.conf"
G add other.sh test/deps.conf
check "freshness: a staged deps.conf that widens the watched set is seen" "NOT-CLEAN" "$(fresh_says)"

# A tree entry is <mode> <object> <path>. Changing ONLY the staged executable
# bit changes the prospective commit while leaving the blob identical, so a
# digest over object ids alone stays equal and reports clean -- then the commit
# records a behaviour-relevant change the status never covered.
#
# Not academic: a wrong mode bit on a new suite happened earlier the same night,
# and 100755 -> 100644 on a production script means it simply stops running.
fresh_world modebit
G update-index --chmod=+x engine.sh
check "freshness: a staged MODE-ONLY change is seen (REV-068 round 4)" "NOT-CLEAN" "$(fresh_says)"
IMP --refresh-status >/dev/null 2>&1
G add docs/PROJECT_STATUS.md
check "freshness: refreshing after a mode-only change restores clean" "CLEAN" "$(fresh_says)"
G commit -qm modebit
check "freshness: and the tree it committed is clean" "CLEAN" "$(fresh_says)"

# The property REV-061 asked for must survive two redesigns.
fresh_world committed
printf 'echo CHANGED
' > "$FW/engine.sh"
G add -A; G commit -qm later
check "freshness: a committed watched change without a refresh is still stale" "NOT-CLEAN" "$(fresh_says)"

# An unwatched file must not demand a refresh, or the gate becomes noise -- and
# the first response to noise is to stop reading it.
fresh_world unrelated
printf 'nothing to do with behaviour
' > "$FW/README"
G add -A
check "freshness: an unwatched file does not demand a refresh" "CLEAN" "$(fresh_says)"


# --- the engine freeze (Stage 3) ---------------------------------------------
#
# A freeze that is a sentence in a document is a wish. These cases pin the
# mechanism: a frozen file cannot change silently, and the only thing that lifts
# the refusal is a named review that exists and is still open.
#
# Same construction as the freshness cases -- a throwaway repo holding a COPY of
# the script under test -- so IMPACT_UNDER_TEST runs the control.
freeze_world() {
    fresh_world "fz-$1"
    mkdir -p "$FW/docs/project" "$FW/docs/internal/reviews/closures"
    printf 'echo engine\n' > "$FW/engine.sh"
    G add engine.sh
    cat > "$FW/docs/project/ENGINE-FREEZE.md" <<'EOF'
# Engine freeze

<!-- frozen: engine.sh 100644 0000000000000000000000000000000000000000 -->
<!-- unfreeze: - -->
EOF
    G add docs/project/ENGINE-FREEZE.md
    IMP --refreeze >/dev/null 2>&1
    G add docs/project/ENGINE-FREEZE.md
    IMP --refresh-status >/dev/null 2>&1
    G add docs/PROJECT_STATUS.md
    G commit -qm frozen
}

# freeze_says -> CLEAN or NOT-CLEAN, reading ONLY the freeze section
freeze_msg() {
    ( cd "$FW" && ./test/impact.sh --verify ) 2>&1 | strip_ansi | awk '/frozen engine files/{f=1;next} /^== /{f=0} f' 
}
freeze_says() {
    # The verdict is the REFUSAL marker, not "did it print anything". An
    # authorised change prints "authorised by REV-..." and is CLEAN; the first
    # version of this helper treated ANY output as a refusal, so the authorised
    # case failed while the mechanism under test was working correctly.
    case "$(freeze_msg)" in
        *FROZEN.*) echo NOT-CLEAN ;;
        *)         echo CLEAN ;;
    esac
}
set_unfreeze() {   # <value>
    awk -v v="$1" '/^<!-- unfreeze: /{ print "<!-- unfreeze: " v " -->"; next } { print }' \
        "$FW/docs/project/ENGINE-FREEZE.md" > "$FW/.u" && mv "$FW/.u" "$FW/docs/project/ENGINE-FREEZE.md"
    G add docs/project/ENGINE-FREEZE.md
}
make_review() {    # <rev> <authorised-paths|-> [closed]
    {
      printf '<!-- rev: %s -->
<!-- verdict: CHANGES-REQUIRED -->
<!-- reviewed-implementation: - -->
' "$1" 
      [ "$2" = "-" ] || printf '<!-- authorizes-frozen: %s -->
' "$2" 
    } > "$FW/docs/internal/reviews/$1.md"
    [ "${3:-}" = closed ] && printf '<!-- rev: %s -->
<!-- closed-by: x -->
' "$1" > "$FW/docs/internal/reviews/closures/$1.md" 
    G add docs/internal/reviews
    return 0
}


# The frozen set is DERIVED from the freeze document, not restated here.
# REV-20260808-070 F1 rejected a hand-narrowed list once already; a second
# hand-kept list living in the test would be the same defect in test clothing.
FROZEN_PATHS="$(grep -oE '^<!-- frozen: [^ ]+ ' "$REPO/docs/project/ENGINE-FREEZE.md" | sed -e 's|^<!-- frozen: ||' -e 's| $||')"
check "freeze: the approved five files are the frozen set" "5" "$(printf '%s
' $FROZEN_PATHS | grep -c .)"
for f in snapsend.sh snapget.sh delsnaps.sh check-snap-age.sh lib-zfs-snap.sh; do
    check "freeze: $f is in the frozen set" "1" "$(printf '%s
' $FROZEN_PATHS | grep -cx "$f")"
done

# REV-20260808-070 F3: the freeze document is executable policy, so a change to
# it must route to the suite that tests its semantics.
check "freeze: a change to ENGINE-FREEZE.md routes to the impact suite" "1" "$("$IMPACT" -f docs/project/ENGINE-FREEZE.md 2>&1 | strip_ansi | grep -c 'test/impact/run.sh')"

freeze_world clean
check "freeze: an unchanged frozen file is clean" "CLEAN" "$(freeze_says)"

# THE mechanism. Without this the freeze is a document nobody enforces.
freeze_world changed
printf 'echo CHANGED\n' > "$FW/engine.sh"; G add engine.sh
check "freeze: a staged change to a frozen file is refused" "NOT-CLEAN" "$(freeze_says)"
# This suite has only check(); ok/bad belong to the other suites, and calling
# them here is a command-not-found that asserts nothing.
check "freeze: the refusal names the file" "1"       "$(freeze_msg | grep -c 'engine.sh')"

# A mode-only change is a change: same reasoning as REV-20260807-068 round 4.
freeze_world modeonly
G update-index --chmod=+x engine.sh
check "freeze: a mode-only change to a frozen file is refused" "NOT-CLEAN" "$(freeze_says)"

# The refusal lifts only for a review that EXISTS...
freeze_world ghost
printf 'echo CHANGED\n' > "$FW/engine.sh"; G add engine.sh
set_unfreeze REV-20260808-999
check "freeze: naming a review that does not exist does not authorise it" "NOT-CLEAN" "$(freeze_says)"

freeze_world open
printf 'echo CHANGED\n' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-900 engine.sh
set_unfreeze REV-20260808-900
check "freeze: an OPEN review authorises the change" "CLEAN" "$(freeze_says)"

# ...and is not already answered. A closed review cannot authorise new work.
freeze_world closed
printf 'echo CHANGED\n' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-901 engine.sh closed
set_unfreeze REV-20260808-901
check "freeze: a CLOSED review does not authorise new work" "NOT-CLEAN" "$(freeze_says)"


# REV-20260808-070 F2, the decisive regression. Before this the gate asked only
# "is some review open", so any unrelated open thread could be named to wave an
# arbitrary engine edit through -- weaker than the freeze document claimed.
freeze_world wrongpath
printf 'echo other
' > "$FW/other.sh"; G add other.sh
printf 'echo CHANGED
' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-903 other.sh
set_unfreeze REV-20260808-903
check "freeze: a review authorising a DIFFERENT path does not authorise this one" "NOT-CLEAN" "$(freeze_says)"
check "freeze: the refusal names the unauthorised path" "1" "$(freeze_msg | grep -c 'engine.sh')"

freeze_world nomarker
printf 'echo CHANGED
' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-904 -
set_unfreeze REV-20260808-904
check "freeze: an open review with NO authorizes-frozen marker does not authorise" "NOT-CLEAN" "$(freeze_says)"

freeze_world multi
printf 'echo CHANGED
' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-905 "other.sh engine.sh"
set_unfreeze REV-20260808-905
check "freeze: a marker listing several paths covers the changed one" "CLEAN" "$(freeze_says)"

# Re-taking the baseline is the documented way out, and it resets the
# authorisation so it cannot be left standing.
freeze_world retake
printf 'echo CHANGED\n' > "$FW/engine.sh"; G add engine.sh
make_review REV-20260808-902 engine.sh
set_unfreeze REV-20260808-902
IMP --refreeze >/dev/null 2>&1; G add docs/project/ENGINE-FREEZE.md
check "freeze: --refreeze accepts the new baseline" "CLEAN" "$(freeze_says)"
check "freeze: --refreeze resets the authorisation" "1"       "$(grep -c '^<!-- unfreeze: - -->' "$FW/docs/project/ENGINE-FREEZE.md")"

# A file outside the freeze must not be caught by it, or the freeze becomes a
# tax on the work it was scoped to leave alone.
freeze_world other
printf 'echo other\n' > "$FW/other.sh"; G add other.sh
check "freeze: an unfrozen file is not caught by the freeze" "CLEAN" "$(freeze_says)"
# --- summary -----------------------------------------------------------------
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
