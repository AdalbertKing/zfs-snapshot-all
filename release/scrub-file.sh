#!/bin/bash
# release/scrub-file.sh <scrub.sed> <file> -- the transformation publish.sh applies to every
# shipped file before it reaches the release repository: text files go through the scrub,
# binary (and empty) files are left alone.
#
# One definition for two readers: publish.sh runs it on the exported files, and
# coverage-gate.sh runs the copy of each revision to compute the bytes that revision shipped
# (REV-20261112-195 F4f). A change here changes what hosts receive, so the gate reads it from
# the revision it judges, not from the checkout.
grep -Iq . "$2" 2>/dev/null || exit 0
sed -i -f "$1" "$2"
