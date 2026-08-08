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


# --- long options (Stage 2.3) ------------------------------------------------

# understands <engine> <label> <args...>
# Stronger than accepts(): the spelling must be RECOGNISED, not merely
# un-refused-for-recursion. Without this, "--recursive=atomic is a declaration"
# passes against a version that has no long options at all, because its
# complaint is an unknown-option error rather than a recursion error.
understands() {
    local engine="$1" label="$2"; shift 2
    local out
    out="$(bash "$REPO/$engine" "$@" tank/src tank/dst 2>&1)"
    case "$out" in
        *"illegal option"*|*"Nieznana opcja"*|*"unknown option"*)
            bad "$engine: $label" "spelling not recognised: $(printf '%s' "$out" | grep -iE 'illegal|Nieznana|unknown' | head -1)" ;;
        *"recursion declared more than once"*|*"mutually exclusive"*)
            bad "$engine: $label" "refused a single declaration" ;;
        *) ok "$engine: $label" ;;
    esac
}

for engine in snapsend.sh snapget.sh; do
    refuses "$engine" "--recursive=ture is refused, naming the value" "got 'ture'" --recursive=ture
    refuses "$engine" "bare --recursive is refused"        "needs a mode" --recursive
    refuses "$engine" "an unknown long option is refused"  "unknown option" --nonsense

    understands "$engine" "--recursive=atomic is a declaration" --recursive=atomic
    understands "$engine" "--recursive=flat is a declaration"   --recursive=flat
    understands "$engine" "--recursive=no is a declaration"     --recursive=no

    # THE case REV-20260807-060 A4 caught in my first design: if --recursive=no
    # were argv erasure, this would collapse silently to -r.
    refuses "$engine" "--recursive=no -r is refused, not collapsed to -r"             "declared more than once" --recursive=no -r
    refuses "$engine" "mixed short and long forms are two declarations"             "declared more than once" -r --recursive=atomic
    refuses "$engine" "the same long form twice is two declarations"             "declared more than once" --recursive=atomic --recursive=atomic

    # getopts equivalence: the pre-pass must know which letters take an
    # argument, or a MESSAGE that looks like a flag becomes a declaration.
    understands "$engine" "-m --recursive=flat is a message, not a declaration" -m --recursive=flat

    # Both of getopts' stop rules.
    accepts "$engine" "after -- a long form is data"        -- --recursive=flat
    accepts "$engine" "after a positional a long form is data" tank/first --recursive=flat
done

# --- delsnaps / check-snap-age: one case branch, extracted --------------------
#
# These two die on a missing dependency (flock, zfs) BEFORE reaching their
# argument loop, so running them proves nothing about parsing on a machine
# without those tools -- a bare invocation "accepts" a typo just as happily as
# the real spelling. The loop is therefore extracted and exercised on its own.
argloop() {   # <script> <var> <args...> -> the variable's value, or UNKNOWN-REJECTED
    local src="$1" var="$2"; shift 2
    local start end body
    start="$(grep -n '^while \[ "\$#" -gt 0 \]; do' "$REPO/$src" | head -1 | cut -d: -f1)"
    end="$(awk -v s="$start" 'NR>=s && /^done$/ {print NR; exit}' "$REPO/$src")"
    body="$(sed -n "${start},${end}p" "$REPO/$src")"
    (
        set -u
        RECURSE=false; recurse=false; DRY_RUN=false; CLEARCUT=false
        VERBOSE=false; PAIR_LABEL=""
        usage() { echo UNKNOWN-REJECTED; exit 7; }
        die()   { echo UNKNOWN-REJECTED; exit 7; }
        set -- "$@"
        eval "$body" || exit $?
        eval "printf '%s
' \"\$$var\""
    ) 2>/dev/null
}

for pair in "delsnaps.sh recurse" "check-snap-age.sh RECURSE"; do
    set -- $pair; src="$1"; var="$2"
    got="$(argloop "$src" "$var" --recursive)"
    case "$got" in
        true) ok "$src: --recursive sets recursion" ;;
        *)    bad "$src: --recursive sets recursion" "got '$got'" ;;
    esac
    got="$(argloop "$src" "$var" -R)"
    case "$got" in
        true) ok "$src: -R still sets recursion" ;;
        *)    bad "$src: -R still sets recursion" "got '$got'" ;;
    esac
    got="$(argloop "$src" "$var")"
    case "$got" in
        false) ok "$src: no flag leaves recursion off" ;;
        *)     bad "$src: no flag leaves recursion off" "got '$got'" ;;
    esac
    # A typo must NOT quietly enable recursion -- the failure that would matter.
    got="$(argloop "$src" "$var" --recursiv)"
    case "$got" in
        true) bad "$src: a typo does not enable recursion" "--recursiv set it" ;;
        *)    ok "$src: a typo does not enable recursion" ;;
    esac
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
