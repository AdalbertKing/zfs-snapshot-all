#!/bin/bash
# Unit tests for test/harness.sh -- the helpers every suite that lifts product
# code by anchor goes through. Two things are pinned here, because they are
# the whole reason the file exists:
#
#   product_fn <file> <name>   lifts exactly the function asked for, and a
#                              MISSING anchor is a FATAL for the SUITE -- not
#                              for the command substitution the caller wrapped
#                              it in. Every caller writes `eval "$(product_fn
#                              ...)"`; an `exit` inside that substitution ends
#                              the substitution alone, the eval sees an empty
#                              string, and the suite goes on to measure a
#                              stub or a `command not found` in place of the
#                              product. That silent shape is the one the
#                              helper replaces, so it is the one this suite
#                              reproduces as its negative control.
#   product_libs [<tree>]      sources the libraries lifted code may call,
#                              from the tree under test, skipping what that
#                              tree does not have.
#
# Everything that must END a shell runs in a child bash, so this suite is
# never the shell that ends. Runs anywhere: no root, no ZFS.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR/../harness.sh"
[ -r "$HARNESS" ] || { echo "cannot read $HARNESS" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# A stand-in product file: one one-liner, one multi-line function, and a
# comment line that mentions a function name without defining it.
cat > "$TMPD/product.sh" <<'PRODUCT'
#!/bin/bash
# helper: gamma() is documented here and defined nowhere
alpha() { echo "A:$1"; }

beta() {
    local x="$1"
    case "$x" in
        one) echo "B1" ;;
        *)   echo "B?" ;;
    esac
}
PRODUCT

# ---- 1. product_fn lifts what it is asked for -------------------------------
out=$(bash -c '. "$1"; eval "$(product_fn "$2" alpha)"; alpha x' _ "$HARNESS" "$TMPD/product.sh" 2>&1)
if [ "$out" = "A:x" ]; then ok "H1 product_fn lifts a one-line function and it runs"
else bad "H1 product_fn lifts a one-line function and it runs" "$out"; fi

out=$(bash -c '. "$1"; eval "$(product_fn "$2" beta)"; beta one; beta two; declare -F alpha >/dev/null && echo LEAK' _ "$HARNESS" "$TMPD/product.sh" 2>&1)
if [ "$out" = "B1
B?" ]; then ok "H2 product_fn lifts a multi-line function whole, and only that one"
else bad "H2 product_fn lifts a multi-line function whole, and only that one" "$out"; fi

# ---- 2. a missing anchor is a FATAL for the SUITE ---------------------------
#
# The shape every caller uses: eval of a command substitution. The child
# script prints REACHED after the eval; a suite that continues past a missing
# function would print it and go on measuring something else.
cat > "$TMPD/suite-subst.sh" <<'SUITE'
. "$HARNESS"
eval "$(product_fn "$PRODUCT" gamma)"
echo REACHED
SUITE
out=$(HARNESS="$HARNESS" PRODUCT="$TMPD/product.sh" bash "$TMPD/suite-subst.sh" 2>"$TMPD/err"); rc=$?
if [ "$rc" -ne 0 ] && [ "$out" != "REACHED" ]; then
    ok "H3 a missing anchor inside eval \"\$(product_fn ...)\" ends the suite (rc=$rc), nothing after it runs"
else
    bad "H3 a missing anchor inside eval \"\$(product_fn ...)\" ends the suite, nothing after it runs" "rc=$rc out=[$out]"
fi
if grep -q 'FATAL: could not extract gamma from' "$TMPD/err"; then
    ok "H3 ...and the FATAL names the function and the file"
else
    bad "H3 ...and the FATAL names the function and the file" "$(cat "$TMPD/err")"
fi
# The comment line mentioning gamma() must not have been lifted as a body.
if ! grep -q 'documented here' "$TMPD/err" && [ "$out" != "REACHED" ]; then
    ok "H3 ...a comment that mentions the name is not an anchor"
else
    bad "H3 ...a comment that mentions the name is not an anchor" "out=[$out]"
fi

# Deeper: from a subshell inside a function inside a command substitution --
# the restoregrant shape. $$ is still the suite from any depth.
cat > "$TMPD/suite-deep.sh" <<'SUITE'
. "$HARNESS"
probe() { ( set -u; eval "$(product_fn "$PRODUCT" gamma)"; echo INNER ); }
r=$(probe)
echo "REACHED:$r"
SUITE
out=$(HARNESS="$HARNESS" PRODUCT="$TMPD/product.sh" bash "$TMPD/suite-deep.sh" 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ "$out" != "REACHED:INNER" ] && [ "$out" != "REACHED:" ]; then
    ok "H4 ...from a subshell in a function in a substitution, the suite still ends (rc=$rc)"
else
    bad "H4 ...from a subshell in a function in a substitution, the suite still ends" "rc=$rc out=[$out]"
fi

# The suite's EXIT trap still runs, so a suite ended this way cleans up.
cat > "$TMPD/suite-trap.sh" <<'SUITE'
. "$HARNESS"
trap 'echo CLEANED >&3' EXIT
eval "$(product_fn "$PRODUCT" gamma)"
echo REACHED
SUITE
out=$(HARNESS="$HARNESS" PRODUCT="$TMPD/product.sh" bash "$TMPD/suite-trap.sh" 3>&1 1>/dev/null 2>&1)
if [ "$out" = "CLEANED" ]; then ok "H5 ...and the suite's EXIT trap runs on the way out"
else bad "H5 ...and the suite's EXIT trap runs on the way out" "got=[$out]"; fi

# Called at top level (no substitution) the FATAL is an ordinary exit 1 --
# nothing else to end.
out=$(bash -c '. "$1"; product_fn "$2" gamma; echo REACHED' _ "$HARNESS" "$TMPD/product.sh" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then ok "H6 at top level a missing anchor is exit 1, nothing after it runs"
else bad "H6 at top level a missing anchor is exit 1, nothing after it runs" "rc=$rc out=[$out]"; fi

# ---- 3. NEGATIVE CONTROL: the shape product_fn replaces continues silently --
cat > "$TMPD/suite-old.sh" <<'SUITE'
eval "$(sed -n '/^gamma() {/,/^}/p' "$PRODUCT")"
echo REACHED
SUITE
out=$(PRODUCT="$TMPD/product.sh" bash "$TMPD/suite-old.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "REACHED" ]; then
    ok "H7 control: the bare sed-and-eval shape continues past a missing anchor with rc=0 (why product_fn ends the suite)"
else
    bad "H7 control: the bare sed-and-eval shape continues past a missing anchor with rc=0" "rc=$rc out=[$out]"
fi

# ---- 4. product_libs sources what the tree has ------------------------------
mkdir -p "$TMPD/tree-full" "$TMPD/tree-empty"
echo 'LIB_RECORD_LOADED=1'  > "$TMPD/tree-full/lib-record.sh"
echo 'LIB_PAIRING_LOADED=1' > "$TMPD/tree-full/lib-pairing.sh"
out=$(bash -c '. "$1"; product_libs "$2"; echo "${LIB_RECORD_LOADED:-0}${LIB_PAIRING_LOADED:-0}"' _ "$HARNESS" "$TMPD/tree-full" 2>&1)
if [ "$out" = "11" ]; then ok "H8 product_libs sources lib-record.sh and lib-pairing.sh from the tree it is given"
else bad "H8 product_libs sources lib-record.sh and lib-pairing.sh from the tree it is given" "$out"; fi
out=$(bash -c 'set -u; . "$1"; product_libs "$2"; echo "rc=$? ${LIB_RECORD_LOADED:-0}${LIB_PAIRING_LOADED:-0}"' _ "$HARNESS" "$TMPD/tree-empty" 2>&1)
if [ "$out" = "rc=0 00" ]; then ok "H9 ...a tree without them (an older SHA) is not an error and sources nothing"
else bad "H9 ...a tree without them (an older SHA) is not an error and sources nothing" "$out"; fi
out=$(bash -c 'set -u; . "$1"; REPO="$2" product_libs; echo "${LIB_RECORD_LOADED:-0}"' _ "$HARNESS" "$TMPD/tree-full" 2>&1)
if [ "$out" = "1" ]; then ok "H10 ...and defaults to \$REPO when no tree is given"
else bad "H10 ...and defaults to \$REPO when no tree is given" "$out"; fi
out=$(bash -c 'set -u; . "$1"; unset REPO; product_libs; echo REACHED' _ "$HARNESS" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ "$out" != "REACHED" ] && printf '%s' "$out" | grep -q 'set REPO or pass the product tree'; then
    ok "H11 ...and with neither, refuses by name rather than sourcing from nowhere"
else
    bad "H11 ...and with neither, refuses by name rather than sourcing from nowhere" "rc=$rc out=[$out]"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
