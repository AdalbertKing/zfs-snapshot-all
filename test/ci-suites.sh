#!/bin/bash
# The suites CI can run, derived from test/deps.conf -- never a second list.
#
# tests.yml used to carry the names inline, under a comment promising they were
# "exactly the suites whose deps.conf entry says `needs = nothing`". They were
# not: seven were listed, twenty-nine qualify, and nothing checked the promise.
# The twenty-two that fell out of CI did not stop being run -- they moved onto
# the implementer's machine, serially, on the slowest platform available, where
# one suite costs 13-25 minutes against seconds on a CI runner. That is the cost
# of a hand-maintained duplicate of a field that already exists.
#
# So the list is COMPUTED here and consumed by both the workflow and
# impact.sh --verify. A suite joins CI by declaring `needs = nothing`, which is
# the same act as telling the graph what it needs. There is no second place to
# update and therefore nothing that can drift.
#
# Usage:
#   ./test/ci-suites.sh          one name per line
#   ./test/ci-suites.sh --json   JSON array, for a GitHub Actions matrix
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

names=$(awk '
    /^\[suite:/ {
        name = $0
        sub(/^\[suite:/, "", name)
        sub(/\].*$/,    "", name)
        next
    }
    # Only the bare "nothing". A suite needing git, root, ZFS or a second host
    # states so in this field, and must not be swept into a bash-only gate.
    /^needs[ \t]*=[ \t]*nothing[ \t]*$/ { if (name != "") print name; name = "" }
' test/deps.conf | sort -u)

[ -n "$names" ] || { echo "ci-suites: no suite declares 'needs = nothing' -- deps.conf parse failed" >&2; exit 1; }

if [ "${1:-}" = "--json" ]; then
    printf '['
    sep=""
    for n in $names; do printf '%s"%s"' "$sep" "$n"; sep=","; done
    printf ']\n'
else
    printf '%s\n' $names
fi
