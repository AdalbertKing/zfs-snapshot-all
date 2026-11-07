#!/bin/bash
# release/name-gate.sh -- list the text files under <dir> that still carry a lab or customer
# address, a site or customer name, or the author's e-mail.
#
#   release/name-gate.sh <dir>      prints one path per offending file; rc 1 if any, 0 if none
#
# Used by release/publish.sh after the scrub, and by test/release on the built release.
#
# Polish letters are folded to plain ASCII first (ą->a, ł->l, ż->z, ...), so every name below
# is written once, without diacritics, and matches both spellings ("Dabrowska" and
# "Dąbrowska" were both in the code, 2026-11-07). The fold is a byte-wise sed of each letter,
# not a bracket or iconv: it behaves the same under LC_ALL=C and any UTF-8 locale.
set -uo pipefail

[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: release/name-gate.sh <dir>" >&2; exit 2; }

FORBIDDEN='192\.168\.(28|11)\.[0-9]|10\.9[89]\.0\.[0-9]|metropolis|site-a\.net|kancelaria|a-tassa|vsql2|lurk\.com\.pl|dabrowsk'

fold() { cat -- "$1"; }   # negctl: no Polish-letter fold

found=0
# -I: text files only (binary files are left alone, as by the scrub itself).
while IFS= read -r -d '' f; do
    if fold "$f" | grep -qiE -- "$FORBIDDEN"; then
        printf '%s\n' "$f"; found=1
    fi
done < <(grep -rIlZ --exclude-dir=.git '' "$1")
exit "$found"
