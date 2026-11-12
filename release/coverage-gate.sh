#!/bin/bash
# release/coverage-gate.sh -- every change a release makes to what hosts run was submitted for
# review (REV-20261112-195 F4).
#
#   coverage-gate.sh <dev-repo> <published-rev> <rev> < REVIEW_LEDGER.md (of <rev>)
#
# review-gate.sh judges the rows the ledger HAS. A change nobody submitted has no row, so it
# passed by absence: 1.0.19 published the bookmark-wins engine change that way (2026-11-12).
# This gate asks the other question, about the PACKAGE, not about commits:
#
#   For every shipped run-time file whose state differs between <published-rev> (what hosts
#   received last) and <rev> -- changed, newly shipped, or no longer shipped -- the way from the
#   old state to the new one must be made of SUBMITTED steps.
#
# A submission is a ledger row whose response names its range: `implementation:` (the row's
# Implementation column) and `<!-- base: <sha> -->` in the response file. It covers a file only
# where its own range changed that file: the file's state at <base> -> its state at <impl>.
# A resubmission of the same REV names its new, smaller range in `base:` and keeps every earlier
# one as `<!-- submitted: <base> <impl> -->` (round 4, F4g): narrowing `base:` alone would make
# the earlier submitted work look unsubmitted. An earlier range counts only when its <impl> is
# an ancestor of the row's implementation, and it covers only what its own <base>..<impl>
# changed. That it is this REV's earlier range is what the Reviewer checks in the response.
# A file's STATE in a revision is what hosts receive from that revision's publish: its tree
# mode (executable bit, symlink) and the hash of its bytes AFTER that revision's scrub
# (`release/scrub.sed`, applied by that revision's `release/scrub-file.sh`), or "not shipped"
# when the file is outside that revision's package. A mode change is a state change (round 3,
# F4e); so is a scrub change that alters the bytes of a shipped file, although its source blob
# is unchanged (F4f). A scrub change that alters no shipped file changes no state.
# A file is covered when a chain of such steps leads from its published state to its state in
# <rev>. So:
#   - a review of other files does not cover an earlier change to this one, whatever the
#     ancestry (round 2, F4b);
#   - a run-time edit made only by a merge is a state no submission reached, and is refused;
#     a mechanical merge of submitted work reproduces a submitted state and passes (F4c);
#   - adding a file to the package or dropping it is a state change like any other (F4d);
#   - an unsubmitted chmod, or an unsubmitted scrub change that rewrites a shipped file, is a
#     state no submission reached (F4e, F4f).
# Docs, Markdown and repository metadata are not run-time and are not compared.
# Exit 0 = covered; 1 = refused, every uncovered file named; 2 = could not run.
set -u

here=$(cd "$(dirname "$0")" && pwd)
dev="$1" prev="$2" rev="$3"
ledger=$(cat)
printf '%s\n' "$ledger" | grep -q '^| REV' || { echo "coverage-gate: the input is not a REVIEW_LEDGER.md (no REV rows)" >&2; exit 2; }
git -C "$dev" cat-file -e "$prev^{commit}" 2>/dev/null || { echo "coverage-gate: the published release's revision '$prev' is not a commit of $dev" >&2; exit 2; }
git -C "$dev" cat-file -e "$rev^{commit}" 2>/dev/null || { echo "coverage-gate: '$rev' is not a commit of $dev" >&2; exit 2; }
prev=$(git -C "$dev" rev-parse "$prev^{commit}"); rev=$(git -C "$dev" rev-parse "$rev^{commit}")

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
NOT_RUNTIME='^docs/|\.md$|^LICENSE$|^\.gitattributes$|^\.github/'
pkg() {   # <commit>: the run-time part of its package, into $tmp/pkg.<commit>
    [ -f "$tmp/pkg.$1" ] && return 0
    bash "$here/package-list.sh" "$dev" "$1" > "$tmp/all.$1" || return 1
    grep -vE "$NOT_RUNTIME" "$tmp/all.$1" > "$tmp/pkg.$1" || :
}
xform() {   # <commit>: that revision's scrub into $tmp/sed.<commit>, its applier into $tmp/sf.<commit>
    [ -f "$tmp/sf.$1" ] && return 0
    if git -C "$dev" cat-file -e "$1:release/scrub.sed" 2>/dev/null; then
        git -C "$dev" show "$1:release/scrub.sed" > "$tmp/sed.$1" || return 1
    else
        : > "$tmp/sed.$1"          # no scrub in that revision: nothing rewritten
    fi
    if git -C "$dev" cat-file -e "$1:release/scrub-file.sh" 2>/dev/null; then
        git -C "$dev" show "$1:release/scrub-file.sh" > "$tmp/sf.$1" || return 1
    else                           # before scrub-file.sh existed, publish.sh did this inline
        printf '%s\n' 'grep -Iq . "$2" 2>/dev/null || exit 0' 'sed -i -f "$1" "$2"' > "$tmp/sf.$1"
    fi
}
state() {   # <commit> <path>: "<mode>:<hash of the shipped bytes>", "-" when not in its package,
            # "!" when it cannot be computed
    grep -qxF -- "$2" "$tmp/pkg.$1" || { echo -; return 0; }
    local m t o
    read -r m t o _ < <(git -C "$dev" ls-tree "$1" -- "$2")
    [ -n "${o:-}" ] || { echo '!'; return 0; }
    if [ "$t" = blob ]; then
        xform "$1" && git -C "$dev" cat-file blob "$o" > "$tmp/f" \
            && bash "$tmp/sf.$1" "$tmp/sed.$1" "$tmp/f" && o=$(git hash-object "$tmp/f") \
            || { echo '!'; return 0; }
    fi
    echo "$m:$o"
}
st() {   # <var> <commit> <path>: state into <var>; rc 2 for the whole gate when it cannot be read
    local v
    v=$(state "$2" "$3")
    [ "$v" != '!' ] || { echo "coverage-gate: cannot compute the shipped state of $3 at ${2:0:12}" >&2; exit 2; }
    printf -v "$1" '%s' "$v"
}
pkg "$prev" || { echo "coverage-gate: cannot read the package of the published revision" >&2; exit 2; }
pkg "$rev"  || { echo "coverage-gate: cannot read the package of $rev" >&2; exit 2; }

# The submissions: rows whose implementation is in <rev>'s history and not yet published, and
# whose response names a base that is an ancestor of that implementation.
subs=()
while IFS='|' read -r _ r _ _ impl _ resp _; do
    r=${r// /}; impl=${impl// /}; resp=${resp// /}
    case "$r" in REV-*) ;; *) continue ;; esac
    case "$impl" in ''|*[!0-9a-f]*) continue ;; esac
    git -C "$dev" cat-file -e "$impl^{commit}" 2>/dev/null || continue
    git -C "$dev" merge-base --is-ancestor "$impl" "$rev" || continue
    git -C "$dev" merge-base --is-ancestor "$impl" "$prev" && continue
    base=$(git -C "$dev" show "$rev:docs/internal/reviews/$resp" 2>/dev/null \
           | sed -n 's/^<!-- base: \([0-9a-f]\{7,40\}\) -->[[:space:]]*$/\1/p' | head -1)
    if [ -z "$base" ] || ! git -C "$dev" cat-file -e "$base^{commit}" 2>/dev/null \
       || ! git -C "$dev" merge-base --is-ancestor "$base" "$impl"; then
        echo "coverage-gate: note: $r names no usable '<!-- base: <sha> -->' in $resp, so it covers nothing" >&2
        continue
    fi
    base=$(git -C "$dev" rev-parse "$base^{commit}")
    pkg "$base" && pkg "$impl" || { echo "coverage-gate: cannot read the package of $r's range" >&2; exit 2; }
    subs+=("$r $base $impl")
    # Earlier rounds of the same REV (round 4, F4g): each `<!-- submitted: <base> <impl> -->`
    # keeps its own range. It counts only when both commits exist, its base is an ancestor of
    # its implementation and that implementation is an ancestor of the current one; a line that
    # fails these covers nothing and is reported. An already published range is skipped.
    while read -r eb ei; do
        if ! git -C "$dev" cat-file -e "$eb^{commit}" 2>/dev/null \
           || ! git -C "$dev" cat-file -e "$ei^{commit}" 2>/dev/null \
           || ! git -C "$dev" merge-base --is-ancestor "$eb" "$ei" \
           || ! git -C "$dev" merge-base --is-ancestor "$ei" "$impl"; then
            echo "coverage-gate: note: $r: 'submitted: ${eb:0:12} ${ei:0:12}' is not an earlier range of $impl, so it covers nothing" >&2
            continue
        fi
        git -C "$dev" merge-base --is-ancestor "$ei" "$prev" && continue
        eb=$(git -C "$dev" rev-parse "$eb^{commit}"); ei=$(git -C "$dev" rev-parse "$ei^{commit}")
        pkg "$eb" && pkg "$ei" || { echo "coverage-gate: cannot read the package of $r's earlier range" >&2; exit 2; }
        subs+=("$r $eb $ei")
    done < <(git -C "$dev" show "$rev:docs/internal/reviews/$resp" 2>/dev/null \
             | sed -n 's/^<!-- submitted: \([0-9a-f]\{7,40\}\) \([0-9a-f]\{7,40\}\) -->[[:space:]]*$/\1 \2/p')
done <<< "$ledger"

uncovered=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    st v0 "$prev" "$p"; st vr "$rev" "$p"
    [ "$v0" = "$vr" ] && continue
    # Reachable states from the published one, one submitted step at a time.
    reach=" $v0 "; by=""; grew=1
    while [ "$grew" -eq 1 ]; do
        grew=0
        for s in ${subs[@]+"${subs[@]}"}; do
            read -r sr sb si <<< "$s"
            st a "$sb" "$p"; st b "$si" "$p"
            [ "$a" != "$b" ] || continue
            case "$reach" in *" $a "*) ;; *) continue ;; esac
            case "$reach" in *" $b "*) continue ;; esac
            reach="$reach$b "; by="$by $sr"; grew=1
        done
    done
    case "$reach" in
        *" $vr "*) echo "coverage-gate: $p <-$by" ;;
        *)  uncovered=$((uncovered + 1))
            case "$v0:$vr" in
                -:*) what="newly shipped" ;;
                *:-) what="no longer shipped" ;;
                *)   what="changed" ;;
            esac
            {
                echo "coverage-gate: UNCOVERED $p ($what since the published release) -- no submitted range leads to its state in ${rev:0:12}"
                git -C "$dev" log --format='    %h %s' "$prev..$rev" -- "$p" release/MANIFEST release/scrub.sed release/scrub-file.sh
            } >&2 ;;
    esac
done < <(sort -u "$tmp/pkg.$prev" "$tmp/pkg.$rev")

if [ "$uncovered" -gt 0 ]; then
    echo "coverage-gate: $uncovered shipped file(s) differ from the published release ($(git -C "$dev" rev-parse --short "$prev")) in a state no review submission reached -- refusing to publish. Submit the change (a response with 'implementation:' and '<!-- base: <sha> -->', or a V3.14 batch), then publish again." >&2
    exit 1
fi
exit 0
