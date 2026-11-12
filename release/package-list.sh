#!/bin/bash
# release/package-list.sh -- the files a release of <rev> ships, one path per line, sorted.
#
#   package-list.sh <dev-repo> <rev>
#
# Resolves release/MANIFEST of THAT revision: a plain line names a file, a line ending in '/'
# every file under that directory, a '!' line removes a file or directory again. publish.sh
# copies exactly this list; coverage-gate.sh compares it between two revisions (REV-20261112-195
# F4d), so both read the package the same way.
# Exit 0 = list printed; 1 = the MANIFEST is missing, names a file the revision lacks, or
# resolves to nothing (the reason on stderr).
set -u
dev="$1" rev="$2"
manifest=$(git -C "$dev" show "$rev:release/MANIFEST" 2>/dev/null) \
    || { echo "package-list: release/MANIFEST is not in $rev" >&2; exit 1; }
files=$(printf '%s\n' "$manifest" | awk '
    /^[ \t]*(#|$)/ { next }
    { sub(/[ \t]+$/, ""); print }' | while IFS= read -r line; do
        case "$line" in
            '!'*) printf -- '-%s\n' "${line#!}" ;;
            */)   git -C "$dev" ls-tree -r --name-only "$rev" -- "$line" | sed 's/^/+/' ;;
            *)    git -C "$dev" cat-file -e "$rev:$line" 2>/dev/null || { echo "!missing $line"; continue; }
                  printf '+%s\n' "$line" ;;
        esac
    done)
missing=$(printf '%s\n' "$files" | sed -n 's/^!missing //p')
[ -z "$missing" ] || { echo "package-list: MANIFEST names files that are not in $rev: $missing" >&2; exit 1; }
list=$(printf '%s\n' "$files" | awk '
    /^\+/ { keep[substr($0, 2)] = 1 }
    /^-/  { drop[substr($0, 2)] = 1 }
    END   { for (f in keep) { ok = 1; for (d in drop) if (f == d || index(f, d "/") == 1) ok = 0; if (ok) print f } }' | sort)
[ -n "$list" ] || { echo "package-list: the MANIFEST of $rev resolves to no files" >&2; exit 1; }
printf '%s\n' "$list"
