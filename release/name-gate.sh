#!/bin/bash
# release/name-gate.sh -- list the text files under <dir> that still carry a lab or customer
# address, a site or customer name, or the author's e-mail.
#
#   release/name-gate.sh <dir>      prints one path per offending file; rc 1 if any, 0 if none,
#                                   2 on a usage error or an unreadable name list
#
# Used by release/publish.sh after the scrub, and by test/release on the built release.
#
# REV-20261107-192: the NAMES are not in this file. This repository is public, and a list of
# customer names is itself the disclosure it is meant to prevent. They come from a private
# file named by $ZFS_NAME_DENYLIST: one extended regular expression per line, written without
# Polish letters; blank lines and lines starting with '#' are ignored. Without that variable
# only the public patterns below are checked and a note goes to stderr; release/publish.sh
# --push refuses to run without it.
#
# Polish letters are folded to plain ASCII first (ą->a, ł->l, ż->z, ...), so every name is
# written once, without diacritics, and matches both spellings. The fold is a byte-wise sed of
# each letter, not a bracket or iconv: it behaves the same under LC_ALL=C and any UTF-8 locale.
set -uo pipefail

[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: release/name-gate.sh <dir>" >&2; exit 2; }

# Public patterns: the lab and customer networks (rewritten by release/scrub.sed), the scrub's
# old site domain, and the author's e-mail domain. No name of a customer or a site.
FORBIDDEN='192\.168\.(28|11)\.[0-9]|10\.9[89]\.0\.[0-9]|site-a\.net|lurk\.com\.pl'

if [ -n "${ZFS_NAME_DENYLIST:-}" ]; then
    [ -f "$ZFS_NAME_DENYLIST" ] && [ -r "$ZFS_NAME_DENYLIST" ] || {
        echo "name-gate: the name list \$ZFS_NAME_DENYLIST is not a readable file" >&2; exit 2; }
    # tr: a list checked out on Windows may carry CRLF; a trailing CR would make no name match.
    names=$(tr -d '\r' < "$ZFS_NAME_DENYLIST" | grep -vE '^[[:space:]]*(#|$)' | paste -sd'|' -)
    [ -n "$names" ] || { echo "name-gate: the name list \$ZFS_NAME_DENYLIST has no entry" >&2; exit 2; }
    FORBIDDEN="$FORBIDDEN|$names"
else
    echo "name-gate: no \$ZFS_NAME_DENYLIST -- addresses checked, customer and site names NOT checked" >&2
fi

fold() {
    sed -e 's/ą/a/g; s/ć/c/g; s/ę/e/g; s/ł/l/g; s/ń/n/g; s/ó/o/g; s/ś/s/g; s/ź/z/g; s/ż/z/g' \
        -e 's/Ą/A/g; s/Ć/C/g; s/Ę/E/g; s/Ł/L/g; s/Ń/N/g; s/Ó/O/g; s/Ś/S/g; s/Ź/Z/g; s/Ż/Z/g' -- "$1"
}

found=0
# -I: text files only (binary files are left alone, as by the scrub itself).
while IFS= read -r -d '' f; do
    if fold "$f" | grep -qiE -- "$FORBIDDEN"; then
        printf '%s\n' "$f"; found=1
    fi
done < <(grep -rIlZ --exclude-dir=.git '' "$1")
exit "$found"
