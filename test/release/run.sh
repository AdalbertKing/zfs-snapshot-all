#!/bin/bash
# The public release (release/MANIFEST, release/publish.sh): what github.com/AdalbertKing/zfsbackup
# gets is complete, carries no lab or customer addresses, and points nowhere outside itself.
#
# Publishes HEAD into a throw-away git repo and reads the result -- the same tree a host would
# clone. Text tools and git only: no ZFS, no root, no network.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; local l; for l in "$@"; do echo "     $l"; done; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REL="$WORK/rel"
git init -q -b main "$REL" && git -C "$REL" -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
head_sha="$(git -C "$REPO" rev-parse HEAD)"

# 1. it publishes, and the tree is the manifest's
out="$(bash "$REPO/release/publish.sh" HEAD "$REL" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$REL/zfs-backup.sh" ] && [ -f "$REL/tui/zfs-tui.py" ] && [ -d "$REL/docs/en" ]; then
    ok "publish: HEAD publishes into a fresh release repo (rc 0, package files present)"
else
    bad "publish: HEAD publishes" "rc=$rc" "$(printf '%s\n' "$out" | tail -3)"
fi
leaked=""
for p in test docs/internal docs/project .github/workflows .claude CLAUDE.md AGENTS.md release tui/lang/build.py tui/lang/en.extra.json; do
    [ -e "$REL/$p" ] && leaked="$leaked $p"
done
[ -z "$leaked" ] && ok "publish: nothing from outside the package (tests, reviews, project docs, build tools)" \
                 || bad "publish: files outside the package reached the release" "$leaked"

# 2. every sibling script a shipped file sources or calls is shipped too. The candidates are the
#    dev repo's own top-level and tui/hostscripts files; a shipped file naming one of them on a
#    non-comment line needs it at run time.
missing=""
cands="$(cd "$REPO" && git ls-files -- '*.sh' '*.py' | grep -v '^test/' | grep -v '^release/')"
while IFS= read -r f; do
    case "$f" in *.sh|*.py) ;; *) continue ;; esac
    body="$(grep -vE '^[[:space:]]*#' "$REL/$f")"
    while IFS= read -r c; do
        b="$(basename "$c")"
        [ "$b" = "$(basename "$f")" ] && continue
        printf '%s\n' "$body" | grep -qF "$b" || continue
        [ -e "$REL/$c" ] || missing="$missing $f->$c"
    done <<< "$cands"
done < <(cd "$REL" && git ls-files)
[ -z "$missing" ] && ok "closure: every script a shipped file names on a code line is in the release" \
                  || bad "closure: shipped files name scripts the release does not carry" "$missing"

# 3. no shipped code line points into test/
# Shell: any non-comment line. Python: only a string literal that starts a path with test/ --
# prose in a docstring is not a reference.
refs="$( cd "$REL" && {
    git ls-files -- '*.sh' | while IFS= read -r f; do
        grep -nE '(^|[ "/$({])test/[a-z]' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
    done
    git ls-files -- '*.py' | while IFS= read -r f; do
        grep -nE "[\"']\.?/?test/[a-z]" "$f" | sed "s|^|$f:|"
    done; } )"
[ -z "$refs" ] && ok "no shipped code line points into test/" || bad "shipped code points into test/" "$(printf '%s\n' "$refs" | head -5)"

# 4. the scrub: no lab/customer address or site name survives, and it did not over-reach
left="$(grep -rIliE '192\.168\.(28|11)\.[0-9]|10\.98\.0\.[0-9]|metropolis' "$REL" --exclude-dir=.git || true)"
[ -z "$left" ] && ok "scrub: no 192.168.28./192.168.11./10.98.0. address and no site name in the release" \
               || bad "scrub: left in the release" "$left"
if grep -qF '10.*|127.*|192.168.*|169.254.*)' "$REL/deploy.sh" && grep -qF '192.168.*' "$REL/tui/new-relation.sh"; then
    ok "scrub control: the private-range globs in the code (192.168.*) are untouched"
else
    bad "scrub control: the scrub changed code it must not" "$(grep -n '169.254' "$REL/deploy.sh" | head -2)"
fi

# 5. the release README and RELEASE-OF
if grep -qF 'github.com/AdalbertKing/zfsbackup.git' "$REL/README.md" && ! grep -qF 'test/README.md' "$REL/README.md"; then
    ok "README: the release README (clone URL of zfsbackup, no link to the dev-only tests)"
else
    bad "README: not the release one" "$(head -3 "$REL/README.md")"
fi
[ "$(cat "$REL/RELEASE-OF" 2>/dev/null)" = "$head_sha" ] && ok "RELEASE-OF names the full development SHA" \
    || bad "RELEASE-OF" "$(cat "$REL/RELEASE-OF" 2>/dev/null)" "want $head_sha"

# 5a. the public face: the community files are there, and every relative link in them resolves in
#     the release tree itself (a link into test/ or docs/project/ would be dead for the world)
face_missing=""
for p in README.md README.pl.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE docs/tutorial/index.html          .github/FUNDING.yml .github/ISSUE_TEMPLATE/bug_report.md .github/pull_request_template.md; do
    [ -f "$REL/$p" ] || face_missing="$face_missing $p"
done
dead=""
for f in README.md README.pl.md CHANGELOG.md CONTRIBUTING.md SECURITY.md; do
    [ -f "$REL/$f" ] || continue
    while IFS= read -r l; do
        l="${l%%#*}"
        [ -n "$l" ] && [ ! -e "$REL/$l" ] && dead="$dead $f->$l"
    done < <(grep -oE '\]\([^)]+\)' "$REL/$f" | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^[a-z]+:')
done
if [ -z "$face_missing" ] && [ -z "$dead" ]; then
    ok "public face: README.pl.md, CHANGELOG, CONTRIBUTING, SECURITY, tutorial, FUNDING and templates shipped; every relative link resolves"
else
    bad "public face" "missing:${face_missing:- none}" "dead links:${dead:- none}"
fi

# 5b. file modes come from the dev tree (cron calls the scripts directly): every listed file
#     carries the same mode in the release index as in HEAD -- not what the filesystem says
modes_bad="$(git -C "$REPO" ls-tree -r HEAD | awk -F'\t' '{ split($1, a, " "); print a[1] "\t" $2 }' | sort > "$WORK/dev.modes"
             git -C "$REL" ls-files -s | awk -F'\t' '{ split($1, a, " "); print a[1] "\t" $2 }' | sort > "$WORK/rel.modes"
             join -t "$(printf '\t')" -1 2 -2 2 <(sort -t "$(printf '\t')" -k2 "$WORK/dev.modes") <(sort -t "$(printf '\t')" -k2 "$WORK/rel.modes") \
                 | awk -F'\t' '$2 != $3 { print $1 " dev=" $2 " release=" $3 }')"
nx="$(git -C "$REL" ls-files -s -- zfs-backup.sh deploy.sh gen-cron.sh zfs-job.sh | awk '$1 == "100755"' | wc -l | tr -d ' ')"
if [ -z "$modes_bad" ] && [ "$nx" = 4 ]; then
    ok "modes: every shipped file has its dev-tree mode (zfs-backup.sh, deploy.sh, gen-cron.sh, zfs-job.sh executable)"
else
    bad "modes: the release index lost executable bits" "$(printf '%s\n' "$modes_bad" | head -5)" "executable among the four: $nx"
fi

# 5c. a host's own files in the checkout (jobs.<host>.conf, a backup of it, a cron dump) stay
# ignored, so update-control's "is the checkout clean" check passes on a real host; a shipped
# file is still tracked (control).
touch "$REL/jobs.pve2.conf" "$REL/jobs.pve2.conf.bak" "$REL/cron.txt"
dirty="$(git -C "$REL" status --porcelain --untracked-files=all)"
if [ -z "$dirty" ] && git -C "$REL" ls-files --error-unmatch zfs-backup.sh .gitignore >/dev/null 2>&1; then
    ok "gitignore: a host's own files stay untracked-and-ignored; shipped files and .gitignore are tracked"
else
    bad "gitignore: the checkout is not clean with host files in it" "$dirty"
fi
rm -f "$REL/jobs.pve2.conf" "$REL/jobs.pve2.conf.bak" "$REL/cron.txt"

# 6. publishing the same revision again commits nothing; history only grows
n1="$(git -C "$REL" rev-list --count HEAD)"
out2="$(bash "$REPO/release/publish.sh" HEAD "$REL" 2>&1)"
n2="$(git -C "$REL" rev-list --count HEAD)"
if [ "$n1" = "$n2" ] && printf '%s\n' "$out2" | grep -q 'no commit'; then
    ok "publish: the same revision twice makes no second commit"
else
    bad "publish: republishing changed the history" "$n1 -> $n2" "$out2"
fi
if ! grep -vE '^[[:space:]]*#' "$REPO/release/publish.sh" | grep -qE -- '--force|push -f'; then
    ok "publish.sh never force-pushes"
else
    bad "publish.sh mentions a force push" "$(grep -nE -- '--force|push -f' "$REPO/release/publish.sh")"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
