#!/bin/bash
# Exactly ONE recursion declaration per invocation (Stage 2.2).
#
# Runs the REAL engines, no extraction: the property under test is that the
# refusal happens while parsing arguments, before any dependency, dataset or
# SSH work -- which is also why this needs neither root nor ZFS. If the check
# ever drifted below the dependency probes these cases would start failing on
# a machine without zfs, which is the right way round.
#
# What this is NOT: a test that recursion WORKS. -r and -R behaviour on real
# pools belongs to test/scenarios and the remote campaign. This pins argument
# normalisation only, and per docs/design/stage2-engine-contract.md that is a
# property no live host can strengthen.
# Negative control: point RECURSION_REPO at a directory holding the OLD
# engines. That directory must also contain lib-*.sh -- the engines source the
# library from beside themselves, and without it they die before parsing, so
# every case "fails" for a reason that has nothing to do with the rule. The
# first run of this control did exactly that and appeared to prove that -r -R
# used to be accepted, which is the opposite of the truth.
#
#   mkdir /tmp/old && cp lib-*.sh /tmp/old/
#   git show <base>:snapsend.sh > /tmp/old/snapsend.sh
#   git show <base>:snapget.sh  > /tmp/old/snapget.sh
#   RECURSION_REPO=/tmp/old ./test/recursion/run.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${RECURSION_REPO:-$(cd "$DIR/../.." && pwd)}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

# refuses <engine> <label> <expected-substring> <args...>
# Asserts a NONZERO exit AND the expected wording. Exit code alone is not
# enough here: every one of these invocations would fail anyway on a host with
# no zfs, so "it exited nonzero" proves nothing about the rule.
refuses() {
    local engine="$1" label="$2" want="$3"; shift 3
    local out rc
    out="$(bash "$REPO/$engine" "$@" tank/src tank/dst 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then bad "$engine: $label" "exited 0"; return; fi
    case "$out" in
        *"$want"*) ok "$engine: $label" ;;
        *) bad "$engine: $label" "wanted '$want', got: $(printf '%s' "$out" | grep -i '^Error' | head -1)" ;;
    esac
}

# accepts <engine> <label> <args...>
# A single declaration must NOT be refused for declaring recursion. It will
# still fail later (no zfs, no such dataset) and that is fine -- what must not
# appear is a recursion-declaration error.
accepts() {
    local engine="$1" label="$2"; shift 2
    local out
    out="$(bash "$REPO/$engine" "$@" tank/src tank/dst 2>&1)"
    case "$out" in
        *"recursion declared more than once"*|*"mutually exclusive"*)
            bad "$engine: $label" "refused a single declaration: $(printf '%s' "$out" | grep -i '^Error' | head -1)" ;;
        *) ok "$engine: $label" ;;
    esac
}

for engine in snapsend.sh snapget.sh; do
    # The mistake people actually make. It was already refused before Stage 2.2
    # -- the stage 2 contract claimed otherwise and the claim was wrong, which
    # is why these two cases are pinned rather than assumed.
    refuses "$engine" "-r -R is refused"            "mutually exclusive" -r -R
    refuses "$engine" "-R -r is refused (either order)" "mutually exclusive" -R -r

    # The rule Stage 2.2 actually adds: the DECLARATION is what may not repeat,
    # regardless of whether repeating it would have changed anything.
    refuses "$engine" "-r -r is refused although it agrees with itself" \
            "declared more than once" -r -r
    refuses "$engine" "-R -R is refused although it agrees with itself" \
            "declared more than once" -R -R

    # The refusal has to quote what was written, or the operator reading a cron
    # mail cannot tell which of several flags to remove.
    out="$(bash "$REPO/$engine" -r -r tank/src tank/dst 2>&1)"
    case "$out" in
        *"(-r -r)"*) ok "$engine: the refusal quotes the spellings it saw" ;;
        *) bad "$engine: the refusal quotes the spellings it saw" "$(printf '%s' "$out" | grep -i '^Error' | head -1)" ;;
    esac

    # Exactly one declaration, in every legal spelling, stays legal.
    accepts "$engine" "a single -r is accepted" -r
    accepts "$engine" "a single -R is accepted" -R
    accepts "$engine" "no declaration at all is accepted" -m test_

    # A recursion letter appearing as an OPTION-ARGUMENT is data, not a
    # declaration. This is the same class of bug the generator had before
    # REV-054: walking flags without knowing which letters take an argument.
    accepts "$engine" "-m -r is a message, not a declaration" -m -r
    accepts "$engine" "-m -r -r is a message plus ONE declaration" -m -r -r

    # ...and the same letters, one of them genuinely a declaration, still
    # count once.
    accepts "$engine" "-m -R -r is a message plus ONE declaration" -m -R -r
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
