#!/bin/bash
# Unit tests for lib-scope.sh -- the scope file's grammar, reader and decision.
#
# No ZFS, no root, no peer: the reader takes a file and the decision takes a
# dataset NAME. That is deliberate -- the whole point of splitting scope out is
# that "what do we replicate" is a decision, and decisions are testable without
# a hypervisor.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-scope.sh}"
[ -r "$LIB" ] || { echo "cannot read lib-scope.sh at $LIB" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIB"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
F="$TMPD/scope.conf"

PASS=0; FAIL=0
check() { local d="$1" w="$2" g="$3"
    if [ "$g" = "$w" ]; then echo "PASS $d"; PASS=$((PASS+1))
    else echo "FAIL $d"; echo "     want: [$w]"; echo "     got:  [$g]"; FAIL=$((FAIL+1)); fi; }
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; echo "     $2"; FAIL=$((FAIL+1)); }
w()   { printf '%s\n' "$@" > "$F"; }
# The refusal must name a line: the operator is going back into an editor, and
# "invalid config" is not a place to put a cursor.
refuses() {   # <desc> <expected fragment>
    if scope_read "$F"; then bad "$1" "przyjete, a nie powinno"; return; fi
    case "$SCOPE_ERR" in
        *"$2"*) case "$SCOPE_ERR" in line*|*"line "*) ok "$1" ;;
                  *) bad "$1" "brak numeru linii: $SCOPE_ERR" ;; esac ;;
        *) bad "$1" "$SCOPE_ERR" ;;
    esac
}

# ---- A. the shape the source will generate ---------------------------------
w \
 '# Full ZFS inventory -- informational, copy entries up as needed.' \
 '# [dataset:rpool/data/vm-100-disk-0]' \
 '#   include_parent = yes' \
 '' \
 '[dataset:rpool/data]' \
 '    include_parent   = no' \
 '    include_children = yes' \
 '' \
 '[dataset:hdd/LXC]' \
 '    include_parent   = no' \
 '    include_children = yes' \
 '    exclude_tree     = hdd/LXC/scratch'
scope_read "$F"
check "A1 the generated shape parses" "0" "$?"
check "A2 both roots, in file order" "rpool/data hdd/LXC" "${SCOPE_ROOTS[*]}"
check "A3 commented inventory is inert" "no" "${SCOPE_PARENT[rpool/data]}"
check "A4 exclusions are collected" "hdd/LXC/scratch" "${SCOPE_EXCLUDE_TREE[hdd/LXC]}"

# Defaults are the review's: a root is a container, its children are the payload.
w '[dataset:rpool/data]'
scope_read "$F"
check "A5 a bare section defaults to no parent, yes children" "no/yes" \
      "${SCOPE_PARENT[rpool/data]}/${SCOPE_CHILDREN[rpool/data]}"

# ---- B. what it refuses, and why --------------------------------------------
w '[dataset:rpool/data]' 'include_parent = maybe'
refuses "B1 a value that is neither yes nor no" "expected yes or no"
w '[dataset:rpool/data]' 'include_parent ='
refuses "B2 a BLANK value is a question nobody answered, not a default" "blank"
w '[dataset:rpool/data]' 'retention = 7d'
refuses "B3 an unknown key" "unknown key"
w '[template:standard]' 'x = 1'
refuses "B4 a section kind that belongs to the collector" "only [dataset:"
w '[dataset:rpool/data]' '[dataset:rpool/data]'
refuses "B5 the same section twice" "appears twice"
w 'include_parent = no'
refuses "B6 a key before any section" "before any"
w '[dataset:rpool/data]' 'this is not a setting'
refuses "B7 a line that is neither header nor key = value" "neither a section header"
w '[dataset:-rpool/data]'
refuses "B8 a dataset name that would be read as an option" "not a valid dataset name"
w '[dataset:rpool/../etc]'
refuses "B9 a dot segment" "not a valid dataset name"
w '[dataset:rpool/data]' 'exclude = ../elsewhere'
refuses "B10 an exclusion that is not a dataset name" "not a valid dataset name"
w '[dataset:rpool/data]' 'exclude ='
refuses "B11 a blank exclusion" "blank"
printf '[dataset:rpool/data]\r\n' > "$F"
refuses "B12 CRLF is reported, not silently stripped" "carriage return"

# Everything commented out is not an empty selection, it is a mistake: nothing
# would be replicated and no job installed. (DEPLOY-UX-AGREED-POSITION §12.)
w '# [dataset:rpool/data]' '#   include_children = yes'
if scope_read "$F"; then bad "B13 a file selecting nothing is refused" "przyjete"
else case "$SCOPE_ERR" in *"selects nothing"*) ok "B13 a file selecting nothing is refused" ;;
       *) bad "B13 a file selecting nothing is refused" "$SCOPE_ERR" ;; esac; fi

# The typo that would otherwise be found from a backup containing too much.
w '[dataset:rpool/data]' 'exclude_tree = rpool/dat/typo'
refuses "B14 an exclusion outside every root" "lies outside"
# ...and "under" is component-wise, never a string prefix.
w '[dataset:rpool/data]' 'exclude = rpool/data2/x'
refuses "B15 rpool/data2 is NOT under rpool/data" "lies outside"

# ---- C. the decision --------------------------------------------------------
w \
 '[dataset:rpool/data]' \
 '  include_parent   = no' \
 '  include_children = yes' \
 '  exclude          = rpool/data/vm-999-disk-0' \
 '  exclude_tree     = rpool/data/scratch'
scope_read "$F" || bad "C0 fixture parses" "$SCOPE_ERR"
inc() { scope_includes "$1" && echo yes || echo no; }
check "C1 the root itself is not sent (include_parent=no)" "no"  "$(inc rpool/data)"
check "C2 a child is"                                     "yes" "$(inc rpool/data/vm-100-disk-0)"
check "C3 a grandchild is"                                "yes" "$(inc rpool/data/a/b)"
check "C4 the excluded leaf is not"                       "no"  "$(inc rpool/data/vm-999-disk-0)"
check "C5 a sibling of the excluded leaf is"              "yes" "$(inc rpool/data/vm-998-disk-0)"
check "C6 the excluded subtree's root is not"             "no"  "$(inc rpool/data/scratch)"
check "C7 ...nor anything under it"                       "no"  "$(inc rpool/data/scratch/deep/one)"
check "C8 an unrelated pool is not"                       "no"  "$(inc hdd/other)"
check "C9 a name that merely shares a prefix is not"      "no"  "$(inc rpool/data2/x)"

# exclude is EXACTLY one dataset: its children are still in scope. That is the
# difference from exclude_tree, and it is the whole reason there are two words
# instead of one regex (U5).
check "C10 exclude takes the dataset only, not its children" "yes" \
      "$(inc rpool/data/vm-999-disk-0/child)"

# include_parent=yes sends the root as well.
w '[dataset:rpool/data]' 'include_parent = yes' 'include_children = no'
scope_read "$F"
check "C11 include_parent=yes sends the root" "yes" "$(inc rpool/data)"
check "C12 ...and include_children=no stops at it" "no" "$(inc rpool/data/vm-100-disk-0)"

# The most specific root wins, so a branch can be carved out of a wider one.
w \
 '[dataset:rpool]'      '  include_children = yes' \
 '[dataset:rpool/data]' '  include_children = no'
scope_read "$F"
check "C13 the most specific root decides" "no" "$(inc rpool/data/vm-100-disk-0)"
check "C14 ...and the wider one still covers its own" "yes" "$(inc rpool/other/x)"

# --- D. dataset_list_split -- the ONE list grammar ---------------------------
# The comma is the package convention, and that is MEASURED, not chosen: both
# engines (snapsend.sh:1905, snapget.sh:1913), delsnaps.sh:942,
# check-snap-age.sh:314, gen-cron.sh (four sites), lib-profile.sh and
# cron2conf.sh all split a user-supplied dataset list on ','.
#
# What diverged was the relationship path: `deploy.sh --peer-datasets` documented
# "A B" because that is how PEER_SAVED_DATASETS is STORED ("${arr[*]}" out, an
# unquoted `for` back in). An internal representation had leaked into the
# user-facing grammar, so one package took commas from one command and spaces
# from the next -- and the one-command remote form took exactly ONE dataset and
# had no list grammar at all.
#
# Permissive on input, canonical on output. Accepting whitespace too is not a
# second convention: the stored form and every manifest already on disk must
# keep parsing.
dsplit() { dataset_list_split "$1" | tr '\n' '|'; }

check "D1 comma is the convention"                  "a|b|"      "$(dsplit 'a,b')"
check "D2 spaces after commas are trimmed"          "a|b|"      "$(dsplit 'a, b')"
check "D3 empty items are dropped"                  "a|b|"      "$(dsplit 'a,,b')"
check "D4 the stored space form still parses"       "a|b|"      "$(dsplit 'a b')"
check "D5 mixed separators mean the same thing"     "a|b|c|"    "$(dsplit 'a b,c')"
check "D6 surrounding whitespace is trimmed"        "a|b|"      "$(dsplit '  a  ,  b  ')"
check "D7 a single dataset is a one-item list"      "hdd/x|"    "$(dsplit 'hdd/x')"
check "D8 an empty list is empty, not one blank"    ""          "$(dsplit '')"
check "D9 a lone separator yields nothing"          ""          "$(dsplit ' , ')"
# D10 is the one a probe caught: printf '%s' without a trailing newline made
# `read` discard the final item, so 'a,b' silently became just 'a'. A list
# grammar that drops the last dataset is worse than no list grammar.
check "D10 the LAST item is never dropped"          "one|two|three|" "$(dsplit 'one,two,three')"


echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
