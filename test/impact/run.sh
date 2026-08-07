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
        git -C "$FW" add -A >/dev/null 2>&1; git -C "$FW" commit -qm base >/dev/null 2>&1
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

fresh_world clean
check "freshness: an up-to-date status on a clean tree is accepted" "CLEAN" "$(fresh_says)"

# THE FINDING. Marker current at HEAD, a watched behaviour file edited but not
# yet committed. The gate must refuse to certify freshness: the commit about to
# be made would leave the document describing a tree that is gone.
fresh_world pending
printf 'echo CHANGED\n' > "$FW/engine.sh"
check "freshness: a PENDING watched change is not clean (REV-068 F1)" "NOT-CLEAN" "$(fresh_says)"

fresh_world staged
printf 'echo CHANGED\n' > "$FW/engine.sh"
git -C "$FW" add engine.sh >/dev/null 2>&1
check "freshness: staging the change does not launder it" "NOT-CLEAN" "$(fresh_says)"

# The property REV-061 asked for must survive the redesign.
fresh_world committed
printf 'echo CHANGED\n' > "$FW/engine.sh"
git -C "$FW" add -A >/dev/null 2>&1; git -C "$FW" commit -qm later >/dev/null 2>&1
check "freshness: a committed watched change without a refresh is still stale" "NOT-CLEAN" "$(fresh_says)"

# Refreshing is what makes it clean, and it stays clean ACROSS the commit --
# the whole point of a content digest.
fresh_world cycle
printf 'echo CHANGED\n' > "$FW/engine.sh"
(cd "$FW" && ./test/impact.sh --refresh-status) >/dev/null 2>&1
check "freshness: refresh-status makes a pending change clean BEFORE the commit" "CLEAN" "$(fresh_says)"
git -C "$FW" add -A >/dev/null 2>&1; git -C "$FW" commit -qm refreshed >/dev/null 2>&1
check "freshness: and it is still clean AFTER that commit" "CLEAN" "$(fresh_says)"

# An unwatched file must not demand a refresh, or the gate becomes noise -- and
# the first response to noise is to stop reading it.
fresh_world unrelated
printf 'nothing to do with behaviour\n' > "$FW/README"
check "freshness: an unwatched file does not demand a refresh" "CLEAN" "$(fresh_says)"
# --- summary -----------------------------------------------------------------
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
