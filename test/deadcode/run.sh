#!/bin/bash
# test/deadcode -- a product function nobody calls is a second copy waiting to
# drift, not a reserve. Found three in one afternoon (2026-09-03): a peer_label
# mirror in clean-relationships.sh never called in any revision, config_datasets
# in zfs-backup.sh kept as "the tested definition" of a grammar that lives,
# tested, in lib-scope.sh, and restore_replace_internal in zfs-restore.sh, an
# older destructive wrapper whose header still promised a door that had been
# open for four days. Each was documented; none was called. This suite makes
# "defined and never named" a failure with a name, across every script the
# package ships, so the next copy does not wait a month for someone to look.
#
# The rule: for every `name() {` at column 0 in a product script, some other
# non-comment line of SOME product script must name it. Tests do not count --
# a function only a test calls is exactly the shape relpolicy.sh recorded
# (cases green, nothing reachable). Indirect dispatch ("$fn") would defeat the
# grep; the tree has none today, and a future one is named here by adding the
# function to ALLOW with its reason, which this suite also checks still exists.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
PRODUCT="${PRODUCT:-$REPO}"     # another tree for a negative control
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

# name<TAB>reason. A reason is mandatory: an allowlist without one is a way to
# silence the suite, not a decision.
ALLOW='release_orphaned_holds	clean-relationships.sh: unreachable by design, the plug-in point for the reviewer-permitted relational lookup of the real target (its own comment says so)'

# dead_functions <dir> -> "file: fn" per line, allowlist applied
dead_functions() {
    local dir="$1" f fn n files=() allowed
    for f in "$dir"/*.sh "$dir"/hostscripts/*.sh; do [ -f "$f" ] && files+=("$f"); done
    [ ${#files[@]} -gt 0 ] || { echo "no product scripts under $dir" >&2; return 2; }
    allowed=$(printf '%s\n' "$ALLOW" | cut -f1)
    for f in "${files[@]}"; do
        for fn in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$f" | tr -d '()' | sort -u); do
            printf '%s\n' "$allowed" | grep -qx "$fn" && continue
            # lines naming it outside comments, across every product file; the
            # definition line is one of them, so a live function has >= 2.
            n=$(grep -vhE '^[[:space:]]*#' "${files[@]}" | grep -cE "(^|[^A-Za-z0-9_])$fn([^A-Za-z0-9_]|$)")
            [ "$n" -ge 2 ] || echo "${f#$dir/}: $fn"
        done
    done
}

# --- 1. the detector itself, on a fixture whose answer is known ---------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/a.sh" <<'FX'
#!/bin/bash
live() { echo live; }
dead() { echo dead; }
# dead is mentioned here, in a comment, which is not a call
also_dead_only_in_string() { :; }
main() { live; }
main
FX
cat > "$T/b.sh" <<'FX'
#!/bin/bash
cross() { :; }
FX
cat > "$T/c.sh" <<'FX'
#!/bin/bash
cross      # named from another file: live
FX
got=$(dead_functions "$T" | sort | tr '\n' '|')
[ "$got" = "a.sh: also_dead_only_in_string|a.sh: dead|" ] \
    && ok "fixture: exactly the two uncalled functions are named, with their file" \
    || bad "fixture: exactly the two uncalled functions are named, with their file" "got: $got"
case "$got" in *"live"*|*"main"*|*"cross"*) bad "fixture: a called function is not reported" "$got" ;; *) ok "fixture: a called function is not reported, a cross-file caller counts" ;; esac
case "$got" in *"a.sh: dead|"*) ok "fixture: a name that appears only in a comment is still dead" ;; *) bad "fixture: a name that appears only in a comment is still dead" "$got" ;; esac
# the allowlist is applied by exact name, so `dead` allowed leaves `also_dead_only_in_string`
got=$(ALLOW='dead	fixture reason' dead_functions "$T" | tr '\n' '|')
[ "$got" = "a.sh: also_dead_only_in_string|" ] \
    && ok "fixture: an allowlisted name is skipped, by exact name only" \
    || bad "fixture: an allowlisted name is skipped, by exact name only" "got: $got"

# --- 2. the allowlist cannot rot or go silent ---------------------------------
rot=""
while IFS=$'\t' read -r fn reason; do
    [ -n "$fn" ] || continue
    [ -n "$reason" ] || rot="$rot $fn(no-reason)"
    grep -qE "^$fn\(\)" "$PRODUCT"/*.sh "$PRODUCT"/hostscripts/*.sh 2>/dev/null || rot="$rot $fn(not-defined)"
done <<< "$ALLOW"
[ -z "$rot" ] && ok "allowlist: every entry names a function that exists and carries a reason" \
              || bad "allowlist: every entry names a function that exists and carries a reason" "$rot"

# --- 3. the real tree ---------------------------------------------------------
n=$(cat "$PRODUCT"/*.sh "$PRODUCT"/hostscripts/*.sh 2>/dev/null | grep -cE '^[A-Za-z_][A-Za-z0-9_]*\(\)')
[ "$n" -ge 500 ] && ok "tree: the scan saw the whole product ($n function definitions)" \
                 || bad "tree: the scan saw the whole product" "only $n definitions -- wrong PRODUCT dir?"
got=$(dead_functions "$PRODUCT" | sort)
[ -z "$got" ] && ok "tree: every product function outside the allowlist is named by another line of the product" \
              || bad "tree: every product function outside the allowlist is named by another line of the product" "defined and never called:" "$got"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
