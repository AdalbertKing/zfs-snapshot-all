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

# --- --suites: the machine-readable form the CI gate consumes ----------------
# The gate greps this output for its own matrix name, so the contract is: bare
# suite names, one per line, and nothing else. A stray heading would be matched
# by grep -x and run a suite the change never touched; worse, a missing __ALL__
# on an unresolved file would SKIP one it did. Both are pinned here.
OUT="$(run_impact "$FIX/basic.conf" --suites -f snapsend.sh)"
check "--suites prints the bare suite name" "snapsend" "$OUT"
check "--suites emits no human headings (manual/contract excluded too)" "0" \
      "$(echo "$OUT" | grep -cE 'CHANGED|SUITES TO RUN|MANUAL|CONTRACT|manual-thing|a-contract')"

OUT="$(run_impact "$FIX/basic.conf" --suites -f README.md)"
check "--suites prints nothing for a file carrying no suite obligation" "" "$OUT"

OUT="$(run_impact "$FIX/basic.conf" --suites -f brand-new.sh)"
check "--suites falls back to __ALL__ on an undeclared shell file (never a silent skip)" "__ALL__" "$OUT"

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

# REV-20260809-082 F2. A SOURCE edge that exists in the code must exist in the
# graph. B1 made zfs-backup.sh source lib-profile.sh, so a change to the profile
# boundary can now break the runtime -- but the graph routed such a change only
# to `profiles`, and the runtime suite that would have caught it was never
# selected.
#
# Asserted against the RESOLVED PLAN, through the real `-f` interface, never
# against deps.conf text. The first version tried `--for`/`--suites-for`, which
# impact.sh does not have, and fell through a `|| true` to grepping the
# declaration -- so it proved the file had been edited and would have passed even
# if resolution stopped selecting the suite entirely (REV-20260809-082 V2). The
# fallback I added to make the test robust is exactly what made it measure the
# wrong thing.
plan="$("$IMPACT" -f lib-profile.sh 2>&1)"
check "a lib-profile.sh change resolves to the profiles suite" "1"       "$(printf '%s
' "$plan" | grep -c 'test/profiles/run.sh')"
check "a lib-profile.sh change ALSO resolves to the runtime suite that consumes it" "1"       "$(printf '%s
' "$plan" | grep -c 'test/zfsbackup/run.sh')"

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

# --- summary -----------------------------------------------------------------
echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
