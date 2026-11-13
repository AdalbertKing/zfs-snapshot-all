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

# 3b. REV-20261028-179: no shipped code line names the development repository -- an install or
# update default pointing there would move a host off the release channel. Comments are prose.
devrefs="$( cd "$REL" && git ls-files -- '*.sh' '*.py' | while IFS= read -r f; do
        grep -n 'AdalbertKing/zfs-snapshot-all' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
    done )"
[ -z "$devrefs" ] && ok "release channel: no shipped code line names AdalbertKing/zfs-snapshot-all" \
                  || bad "release channel: shipped code names the development repository" "$(printf '%s\n' "$devrefs" | head -5)"

# 4. the scrub: no lab/customer address or site name survives, and it did not over-reach
left="$(bash "$REPO/release/name-gate.sh" "$REL" || true)"
[ -z "$left" ] && ok "scrub: no 192.168.28./192.168.11./10.98.0./10.99.0. address, no site or customer name (also with Polish letters), no author e-mail in the release" \
               || bad "scrub: left in the release" "$left"
if grep -qF '10.*|127.*|192.168.*|169.254.*)' "$REL/deploy.sh" && grep -qF '192.168.*' "$REL/tui/new-relation.sh"; then
    ok "scrub control: the private-range globs in the code (192.168.*) are untouched"
else
    bad "scrub control: the scrub changed code it must not" "$(grep -n '169.254' "$REL/deploy.sh" | head -2)"
fi
# 4b. the name gate folds every Polish letter before matching, and takes its names from a
# PRIVATE list (REV-20261107-192: a public list of customer names is itself the disclosure).
# Everything here is synthetic: a made-up list, made-up names. Each fixture file spells one
# listed name with a different diacritic, under both the C and a UTF-8 locale; a clean Polish
# file and a binary file must not be listed.
NG="$WORK/ng"; mkdir -p "$NG"
NL="$WORK/names.txt"
printf '# synthetic test list\n\nkapelix\nborvax\nplutrix\nsmigrax\nzdzbrix\n' > "$NL"
printf '# u klienta KĄPELIX\n'     > "$NG/a.sh"
printf 'host BÓRVAX\n'             > "$NG/o.txt"
printf 'x Płutrix\n'               > "$NG/l.txt"
printf 'x Śmigrax y\n'             > "$NG/s.txt"
printf 'x źdźbrix\n'               > "$NG/q.txt"
printf 'zażółć gęślą jaźń\n'       > "$NG/clean.txt"
printf 'Kapelix\0bin\n'            > "$NG/bin.dat"
for loc in C C.UTF-8; do
    got="$(LC_ALL=$loc ZFS_NAME_DENYLIST="$NL" bash "$REPO/release/name-gate.sh" "$NG" | sed "s|^$NG/||" | sort | tr '\n' ' ')"
    if [ "$got" = "a.sh l.txt o.txt q.txt s.txt " ]; then
        ok "name gate ($loc): each Polish-letter spelling of a listed name is refused; clean Polish text and binaries pass"
    else
        bad "name gate ($loc): wrong files listed" "got: '$got'" "want: 'a.sh l.txt o.txt q.txt s.txt '"
    fi
done
# without the private list: the names are not checked (and it says so), the addresses still are
printf 'lab 192.168.28.5\n' > "$NG/ip.txt"
got="$(LC_ALL=C bash "$REPO/release/name-gate.sh" "$NG" 2>"$WORK/ng.err" | sed "s|^$NG/||" | sort | tr '\n' ' ')"
if [ "$got" = "ip.txt " ] && grep -q 'names NOT checked' "$WORK/ng.err"; then
    ok "name gate without \$ZFS_NAME_DENYLIST: addresses refused, names not checked, and it says so"
else
    bad "name gate without the list" "got: '$got'" "stderr: $(cat "$WORK/ng.err")"
fi
rm -f "$NG/ip.txt"
ZFS_NAME_DENYLIST="$WORK/nonexistent" bash "$REPO/release/name-gate.sh" "$NG" >/dev/null 2>&1; rcx=$?
printf '# only a comment\n\n' > "$WORK/empty-names.txt"
ZFS_NAME_DENYLIST="$WORK/empty-names.txt" bash "$REPO/release/name-gate.sh" "$NG" >/dev/null 2>&1; rce=$?
printf 'kapelix\n(unclosed\n' > "$WORK/bad-names.txt"
ZFS_NAME_DENYLIST="$WORK/bad-names.txt" bash "$REPO/release/name-gate.sh" "$NG" >/dev/null 2>&1; rcm=$?
[ "$rcx" = 2 ] && [ "$rce" = 2 ] && [ "$rcm" = 2 ] \
    && ok "name gate: an unreadable, empty or malformed name list is an error (rc 2), not a pass" \
    || bad "name gate: bad list" "missing rc=$rcx (want 2)" "empty rc=$rce (want 2)" "malformed rc=$rcm (want 2)"
LC_ALL=C ZFS_NAME_DENYLIST="$NL" bash "$REPO/release/name-gate.sh" "$NG" >/dev/null; rc1=$?
rm -f "$NG"/[aloqs].*; LC_ALL=C ZFS_NAME_DENYLIST="$NL" bash "$REPO/release/name-gate.sh" "$NG" >/dev/null; rc0=$?
[ "$rc1" = 1 ] && [ "$rc0" = 0 ] && ok "name gate: rc 1 when something is listed, rc 0 when nothing is" \
                                  || bad "name gate: rc" "with hits rc=$rc1 (want 1)" "clean rc=$rc0 (want 0)"
# publish --push refuses without the private list, before it reads or writes anything
out="$(ZFS_NAME_DENYLIST= bash "$REPO/release/publish.sh" HEAD "$WORK/no-such-checkout" --push 2>&1)"; rcp=$?
if [ "$rcp" -ne 0 ] && printf '%s' "$out" | grep -q 'needs the private name list' && [ ! -e "$WORK/no-such-checkout" ]; then
    ok "publish --push refuses without \$ZFS_NAME_DENYLIST, nothing written"
else
    bad "publish --push without the name list" "rc=$rcp" "$out"
fi
# a malformed private list stops even a local (no --push) publication: rc 2 is not a pass
h0=$(git -C "$REL" rev-parse HEAD)
out="$(ZFS_NAME_DENYLIST="$WORK/bad-names.txt" bash "$REPO/release/publish.sh" HEAD "$REL" 2>&1)"; rcb=$?
if [ "$rcb" -ne 0 ] && printf '%s' "$out" | grep -q 'name gate could not run' && [ "$(git -C "$REL" rev-parse HEAD)" = "$h0" ]; then
    ok "publish stops when the name gate cannot run (malformed list), no release commit"
else
    bad "publish with a malformed name list" "rc=$rcb" "$out"
fi
# The later publish --push cases test other gates: they get the synthetic list, so this one passes.
export ZFS_NAME_DENYLIST="$NL"

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

# The Reviewer's gate in front of a pushed release (PROTOCOL V3.13, Owner 2026-11-07):
# merge into dev main on green CI, the Reviewer's verdict before publication.
GATE="$REPO/release/review-gate.sh"
LED='| REV | State | Owner | Implementation | Reviewed | Response | Next |
| REV-20990101-001 | CLOSED | - | a | a | r | - |
| REV-20990101-002 | APPROVED | Reviewer | b | b | r | close |
| REV-20990101-003 | OPEN | Claude | c | c | r | implement |
| REV-20990101-004 | IMPLEMENTED | Reviewer | d | - | r | review |'
gate() { printf '%s\n' "$LED" | bash "$GATE" "$@" > "$WORK/gate.out" 2>&1; }
if ! gate && grep -q 'REV-20990101-003(OPEN|Claude)' "$WORK/gate.out" && grep -q 'REV-20990101-004(IMPLEMENTED|Reviewer)' "$WORK/gate.out"; then
    ok "gate: OPEN and IMPLEMENTED reviews refuse a release and are named"
else
    bad "gate: OPEN and IMPLEMENTED reviews refuse a release and are named" "$(cat "$WORK/gate.out")"
fi
if ! gate REV-20990101-003 && grep -q 'REV-20990101-004' "$WORK/gate.out"; then
    ok "gate: accepting one open review does not let the other through"
else
    bad "gate: accepting one open review does not let the other through" "$(cat "$WORK/gate.out")"
fi
if gate REV-20990101-003,REV-20990101-004 && [ "$(grep -c '^accepted: ' "$WORK/gate.out")" -eq 2 ]; then
    ok "gate: the Owner's named acceptance of every open review passes, one 'accepted:' line each"
else
    bad "gate: the Owner's named acceptance of every open review passes" "$(cat "$WORK/gate.out")"
fi
if printf '| REV | State |\n| REV-20990101-001 | CLOSED |\n| REV-20990101-B01 | IMPLEMENTED | Reviewer |\n' | bash "$GATE" > "$WORK/gate.out" 2>&1; then
    bad "gate: a V3.14 batch submission awaiting its verdict refuses a release" "$(cat "$WORK/gate.out")"
else
    grep -q 'REV-20990101-B01' "$WORK/gate.out" && ok "gate: a V3.14 batch submission awaiting its verdict refuses a release and is named" \
        || bad "gate: a V3.14 batch submission is named" "$(cat "$WORK/gate.out")"
fi
if ! gate REV-20990101-00 && ! gate REV-20990101-0033,REV-20990101-004; then
    ok "gate: an acceptance list matches whole REV ids only (no prefix match)"
else
    bad "gate: an acceptance list matches whole REV ids only" "$(cat "$WORK/gate.out")"
fi
if printf '| REV | State |\n| REV-20990101-001 | CLOSED |\n| REV-20990101-002 | APPROVED |\n' | bash "$GATE" >/dev/null 2>&1 \
   && ! echo 'not a ledger' | bash "$GATE" >/dev/null 2>&1; then
    ok "gate: only APPROVED/CLOSED passes; input that is not a ledger fails closed"
else
    bad "gate: only APPROVED/CLOSED passes; input that is not a ledger fails closed" ""
fi
# The review-coverage gate (REV-20261112-195 F4, round 2). A fixture dev repo with its own
# MANIFEST; the gate compares the run-time PACKAGE of the published revision with the candidate's
# and wants every difference reached by submitted ranges (`implementation:` + `<!-- base: -->`).
COV="$REPO/release/coverage-gate.sh"
CR="$WORK/covrepo"; git init -q -b main "$CR"
cw() {   # <path> <content>: write (creating directories); fails the suite on a setup error
    mkdir -p "$CR/$(dirname "$1")" && printf '%s\n' "$2" > "$CR/$1" && git -C "$CR" add -- "$1" \
        || bad "coverage fixture: could not write $1"
}
cc() { git -C "$CR" commit -qm "$1" && git -C "$CR" rev-parse HEAD; }
LH='| REV | State | Owner | Implementation | Reviewed | Response | Next |'
row() { printf '| %s | CLOSED | - | %s | %s | responses/%s.md | - |\n' "$1" "$2" "$2" "$1"; }   # <rev-id> <impl>
resp() { cw "docs/internal/reviews/responses/$1.md" "$(printf '<!-- rev: %s -->\n<!-- implementation: %s -->\n<!-- base: %s -->' "$1" "$3" "$2")"; }   # <rev-id> <base> <impl>
cov() {   # <prev> <rev> <ledger rows...>: rc in $rc, output in $WORK/cov.out
    local p="$1" r="$2"; shift 2
    printf '%s\n' "$LH" "$@" | bash "$COV" "$CR" "$p" "$r" > "$WORK/cov.out" 2>&1; rc=$?
}
cw release/MANIFEST "$(printf 'a.sh\nb.sh\nc.sh\ndocs/\n')"; cw a.sh a0; cw b.sh b0; cw c.sh c0; cw d.sh d0; cw docs/x.md x
P=$(cc "published release")

# Uncovered and covered engine change.
cw a.sh a1; A=$(cc "engine change A")
cov "$P" "$A"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh (changed' "$WORK/cov.out" && grep -q "${A:0:7}" "$WORK/cov.out" \
    && ok "coverage: an unsubmitted engine change refuses, naming the file and its commit" \
    || bad "coverage: an unsubmitted engine change refuses" "rc=$rc" "$(cat "$WORK/cov.out")"
resp REV-20990101-011 "$P" "$A"; RA=$(cc "response for A")
cov "$P" "$RA" "$(row REV-20990101-011 "$A")"
[ "$rc" -eq 0 ] && grep -q 'a.sh <- REV-20990101-011' "$WORK/cov.out" \
    && ok "coverage: a submitted range covers the change and the gate names it" \
    || bad "coverage: a submitted range covers the change" "rc=$rc" "$(cat "$WORK/cov.out")"

# F4b: an unrelated review after an unsubmitted change launders nothing.
git -C "$CR" reset -q --hard "$A"
cw c.sh c1; B=$(cc "other file B"); resp REV-20990101-012 "$A" "$B"; RB=$(cc "response for B only")
cov "$P" "$RB" "$(row REV-20990101-012 "$B")"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh' "$WORK/cov.out" && ! grep -q 'UNCOVERED c.sh' "$WORK/cov.out" \
    && ok "coverage F4b: a review of B (other file) does not cover the earlier unsubmitted change of a.sh" \
    || bad "coverage F4b: a review of B launders A" "rc=$rc" "$(cat "$WORK/cov.out")"
resp REV-20990101-013 "$P" "$B"; RB2=$(cc "batch response P..B")
cov "$P" "$RB2" "$(row REV-20990101-013 "$B")"
[ "$rc" -eq 0 ] && ok "coverage F4b: control -- one batch range P..B covers both files" \
    || bad "coverage F4b: a batch range covers both" "rc=$rc" "$(cat "$WORK/cov.out")"

# Docs only, with the setup asserted (round 2: the old fixture's docs commit never happened).
git -C "$CR" reset -q --hard "$P"
cw docs/n.md z; D=$(cc "docs only")
if git -C "$CR" diff --name-only "$P" "$D" | grep -qx 'docs/n.md'; then
    cov "$P" "$D"
    [ "$rc" -eq 0 ] && ok "coverage: a docs-only change (docs/n.md really committed) needs no submission" \
        || bad "coverage: a docs-only change needs no submission" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the docs-only commit did not record docs/n.md"
fi

# F4c: merges.
git -C "$CR" reset -q --hard "$P"
git -C "$CR" switch -q -c s1; cw docs/s1.md s1; cc "docs s1" >/dev/null
git -C "$CR" switch -q main;  cw docs/s2.md s2; cc "docs s2" >/dev/null
git -C "$CR" merge -q --no-commit s1 >/dev/null 2>&1; cw a.sh merged-only; M=$(cc "merge with an engine edit")
cov "$P" "$M"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh' "$WORK/cov.out" \
    && ok "coverage F4c: an engine edit made only inside a merge refuses" \
    || bad "coverage F4c: a merge-only engine edit" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"; git -C "$CR" branch -q -D s1
git -C "$CR" switch -q -c x1; cw a.sh x1; X1=$(cc "submitted engine X1")
git -C "$CR" switch -q main;  cw docs/y.md y; cc "docs y" >/dev/null
git -C "$CR" merge -q --no-edit x1 >/dev/null 2>&1; resp REV-20990101-014 "$P" "$X1"; MX=$(cc "response X1 after a mechanical merge")
cov "$P" "$MX" "$(row REV-20990101-014 "$X1")"
[ "$rc" -eq 0 ] && ok "coverage F4c: control -- a mechanical merge of submitted work passes" \
    || bad "coverage F4c: a mechanical merge of submitted work" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"; git -C "$CR" branch -q -D x1
cw a.sh "$(printf 'l1\nl2\nl3')"; P2=$(cc "published release 2")
git -C "$CR" switch -q -c k1; cw a.sh "$(printf 'L1\nl2\nl3')"; K1=$(cc "submitted K1")
git -C "$CR" switch -q main;  cw a.sh "$(printf 'l1\nl2\nL3')"; K2=$(cc "submitted K2")
git -C "$CR" merge -q --no-commit k1 >/dev/null 2>&1; cw a.sh "$(printf 'L1\nl2\nL3x')"
resp REV-20990101-015 "$P2" "$K1"; resp REV-20990101-016 "$P2" "$K2"; KM=$(cc "conflict resolution with an extra edit")
cov "$P2" "$KM" "$(row REV-20990101-015 "$K1")" "$(row REV-20990101-016 "$K2")"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh' "$WORK/cov.out" \
    && ok "coverage F4c: a conflict resolution no submission reached refuses, though both sides were submitted" \
    || bad "coverage F4c: an unsubmitted conflict resolution" "rc=$rc" "$(cat "$WORK/cov.out")"
cw docs/internal/reviews/responses/REV-20990101-017.md "$(printf '<!-- base: %s -->' "$K2")"; KR=$(cc "submit the resolution")
cov "$P2" "$KR" "$(row REV-20990101-015 "$K1")" "$(row REV-20990101-016 "$K2")" "$(row REV-20990101-017 "$KM")"
[ "$rc" -eq 0 ] && ok "coverage F4c: control -- the resolution submitted as K2..merge passes" \
    || bad "coverage F4c: a submitted resolution" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" branch -q -D k1

# F4d: package composition.
git -C "$CR" reset -q --hard "$P"
cw release/MANIFEST "$(printf 'a.sh\nb.sh\ndocs/\n')"; R1=$(cc "drop c.sh from the package")
cov "$P" "$R1"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED c.sh (no longer shipped' "$WORK/cov.out" \
    && ok "coverage F4d: a script dropped from the package refuses" \
    || bad "coverage F4d: a dropped script" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"
cw release/MANIFEST "$(printf 'a.sh\nb.sh\nc.sh\nd.sh\ndocs/\n')"; R2=$(cc "ship the unchanged d.sh")
cov "$P" "$R2"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED d.sh (newly shipped' "$WORK/cov.out" \
    && ok "coverage F4d: an unchanged, newly shipped script refuses" \
    || bad "coverage F4d: a newly shipped script" "rc=$rc" "$(cat "$WORK/cov.out")"
resp REV-20990101-018 "$P" "$R2"; R2R=$(cc "response for shipping d.sh")
cov "$P" "$R2R" "$(row REV-20990101-018 "$R2")"
[ "$rc" -eq 0 ] && ok "coverage F4d: control -- the submitted package change passes" \
    || bad "coverage F4d: a submitted package change" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"
cw release/MANIFEST "$(printf 'a.sh\nb.sh\nc.sh\ndocs/\n!b.sh\n')"; R3=$(cc "exclude b.sh")
cov "$P" "$R3"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED b.sh (no longer shipped' "$WORK/cov.out" \
    && ok "coverage F4d: a changed exclusion refuses" \
    || bad "coverage F4d: a changed exclusion" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"
cw release/MANIFEST "$(printf '# the same package\na.sh\nb.sh\nc.sh\ndocs/\n')"; cw docs/new.md n; R4=$(cc "manifest comment, docs file")
cov "$P" "$R4"
[ "$rc" -eq 0 ] && ok "coverage F4d: control -- a manifest edit that leaves the run-time package alone passes" \
    || bad "coverage F4d: an unchanged run-time package" "rc=$rc" "$(cat "$WORK/cov.out")"

# A range without a base covers nothing; fail closed on bad input.
git -C "$CR" reset -q --hard "$A"
cw docs/internal/reviews/responses/REV-20990101-019.md '<!-- implementation: x -->'; NB=$(cc "response without base")
cov "$P" "$NB" "$(row REV-20990101-019 "$A")"
[ "$rc" -eq 1 ] && grep -q 'covers nothing' "$WORK/cov.out" \
    && ok "coverage: a response without '<!-- base: -->' covers nothing, and the gate says so" \
    || bad "coverage: a response without base" "rc=$rc" "$(cat "$WORK/cov.out")"
printf 'not a ledger\n' | bash "$COV" "$CR" "$P" "$A" >/dev/null 2>&1; rc1=$?
printf '%s\n' "$LH" | bash "$COV" "$CR" deadbeef "$A" >/dev/null 2>&1; rc2=$?
if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    ok "coverage: no ledger, or an unknown published revision, fails closed (rc 2)"
else
    bad "coverage: no ledger, or an unknown published revision, fails closed (rc 2)" "rc1=$rc1 rc2=$rc2"
fi

# Round 3, F4e: the executable bit is part of what hosts receive. The setup is asserted: the
# same blob, only the mode differs.
git -C "$CR" reset -q --hard "$P"
git -C "$CR" update-index --chmod=+x a.sh; XM=$(cc "chmod +x a.sh only")
if [ "$(git -C "$CR" ls-tree "$P" a.sh | cut -c1-6)" = 100644 ] \
   && [ "$(git -C "$CR" ls-tree "$XM" a.sh | cut -c1-6)" = 100755 ] \
   && [ "$(git -C "$CR" rev-parse "$P:a.sh")" = "$(git -C "$CR" rev-parse "$XM:a.sh")" ]; then
    cov "$P" "$XM"
    [ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh (changed' "$WORK/cov.out" && grep -q "${XM:0:7}" "$WORK/cov.out" \
        && ok "coverage F4e: an unsubmitted mode change (same blob, 100644 -> 100755) refuses, naming its commit" \
        || bad "coverage F4e: an unsubmitted mode change" "rc=$rc" "$(cat "$WORK/cov.out")"
    resp REV-20990101-021 "$P" "$XM"; XR=$(cc "submit the mode change")
    cov "$P" "$XR" "$(row REV-20990101-021 "$XM")"
    [ "$rc" -eq 0 ] && grep -q 'a.sh <- REV-20990101-021' "$WORK/cov.out" \
        && ok "coverage F4e: control -- the submitted mode change passes" \
        || bad "coverage F4e: a submitted mode change" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the chmod commit did not change the mode alone"
fi
git -C "$CR" reset -q --hard "$P"
git -C "$CR" update-index --chmod=+x docs/x.md; XD=$(cc "chmod +x a docs file")
if [ "$(git -C "$CR" ls-tree "$XD" docs/x.md | cut -c1-6)" = 100755 ]; then
    cov "$P" "$XD"
    [ "$rc" -eq 0 ] && ok "coverage F4e: control -- a mode change of a docs file needs no submission" \
        || bad "coverage F4e: a docs mode change" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the docs chmod commit did not happen"
fi

# Round 3, F4f: the scrub rewrites shipped files after the blobs were compared. A file's state
# is its bytes AFTER its revision's scrub, so a scrub-only change is a change of a.sh.
git -C "$CR" reset -q --hard "$P"
cw a.sh 'echo BEFORE'; cw release/scrub.sed 's/BEFORE/BEFORE/g'; PS=$(cc "published: identity scrub")
cw release/scrub.sed 's/BEFORE/AFTER/g'; S1=$(cc "scrub-only change")
if [ "$(git -C "$CR" diff --name-only "$PS" "$S1")" = release/scrub.sed ]; then
    cov "$PS" "$S1"
    [ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh (changed' "$WORK/cov.out" && grep -q "${S1:0:7}" "$WORK/cov.out" \
        && ok "coverage F4f: an unsubmitted scrub change that rewrites a shipped file refuses, its blob unchanged" \
        || bad "coverage F4f: an unsubmitted scrub change" "rc=$rc" "$(cat "$WORK/cov.out")"
    resp REV-20990101-022 "$PS" "$S1"; SR=$(cc "submit the scrub change")
    cov "$PS" "$SR" "$(row REV-20990101-022 "$S1")"
    [ "$rc" -eq 0 ] && grep -q 'a.sh <- REV-20990101-022' "$WORK/cov.out" \
        && ok "coverage F4f: control -- the submitted scrub change passes" \
        || bad "coverage F4f: a submitted scrub change" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the scrub-only commit changed more than release/scrub.sed"
fi
git -C "$CR" reset -q --hard "$PS"
cw release/scrub.sed "$(printf 's/BEFORE/BEFORE/g\ns/NEVER-IN-A-SHIPPED-FILE/X/g')"; S2=$(cc "scrub rule that matches nothing")
cov "$PS" "$S2"
[ "$rc" -eq 0 ] && ok "coverage F4f: control -- a scrub change that rewrites no shipped file needs no submission" \
    || bad "coverage F4f: a scrub change with no effect" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$PS"
cw release/scrub.sed 's/BEFORE/AFTER/g'; PA=$(cc "published: a.sh ships as AFTER")
cw release/scrub-file.sh 'exit 0'; SF=$(cc "the scrub's applier stops scrubbing")
cov "$PA" "$SF"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh (changed' "$WORK/cov.out" && grep -q "${SF:0:7}" "$WORK/cov.out" \
    && ok "coverage F4f: an unsubmitted change of the scrub's applier (release/scrub-file.sh) refuses" \
    || bad "coverage F4f: an unsubmitted applier change" "rc=$rc" "$(cat "$WORK/cov.out")"

# Round 4, F4g: a resubmission of the same REV. Round 1 submits engine A; round 2 is a repair B
# of another file, its response naming the smaller range in `base:`. Narrowing `base:` alone
# made A look unsubmitted; `<!-- submitted: <base> <impl> -->` keeps round 1's own range.
resps() {   # <rev-id> <base> <impl> [<earlier-base> <earlier-impl>]...
    local id="$1" b="$2" i="$3" t; shift 3
    t=$(printf '<!-- rev: %s -->\n<!-- implementation: %s -->\n<!-- base: %s -->' "$id" "$i" "$b")
    while [ $# -ge 2 ]; do t="$t$(printf '\n<!-- submitted: %s %s -->' "$1" "$2")"; shift 2; done
    cw "docs/internal/reviews/responses/$id.md" "$t"
}
git -C "$CR" reset -q --hard "$P"
cw a.sh a2; GA=$(cc "REV round 1: engine A")
resp REV-20990101-031 "$P" "$GA"; GR1=$(cc "round 1 response")
cw c.sh c2; GU=$(cc "unrelated work U, never submitted")
cw b.sh b2; GB=$(cc "REV round 2: repair B, another file")
resps REV-20990101-031 "$GU" "$GB"; GN=$(cc "round 2 response: narrowed base only")
cov "$P" "$GN" "$(row REV-20990101-031 "$GB")"
[ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh' "$WORK/cov.out" && ! grep -q 'UNCOVERED b.sh' "$WORK/cov.out" \
    && ok "coverage F4g: control -- a narrowed base alone leaves round 1's engine A uncovered (the reported defect)" \
    || bad "coverage F4g: a narrowed base alone" "rc=$rc" "$(cat "$WORK/cov.out")"
resps REV-20990101-031 "$GU" "$GB" "$P" "$GA"; GK=$(cc "round 2 response keeps round 1's range")
cov "$P" "$GK" "$(row REV-20990101-031 "$GB")"
[ "$rc" -eq 1 ] && grep -q 'a.sh <- REV-20990101-031' "$WORK/cov.out" && grep -q 'b.sh <- REV-20990101-031' "$WORK/cov.out" \
    && grep -q 'UNCOVERED c.sh' "$WORK/cov.out" && ! grep -q 'UNCOVERED [ab].sh' "$WORK/cov.out" \
    && ok "coverage F4g: round 1 kept as 'submitted:' covers A and B; unrelated unsubmitted U between them still refuses" \
    || bad "coverage F4g: earlier range kept" "rc=$rc" "$(cat "$WORK/cov.out")"
resp REV-20990101-032 "$GR1" "$GU"; GK2=$(cc "U submitted under its own REV")
cov "$P" "$GK2" "$(row REV-20990101-031 "$GB")" "$(row REV-20990101-032 "$GU")"
[ "$rc" -eq 0 ] && ok "coverage F4g: control -- with U submitted under its own REV the release passes" \
    || bad "coverage F4g: all three submitted" "rc=$rc" "$(cat "$WORK/cov.out")"
git -C "$CR" reset -q --hard "$P"; cw a.sh a9; GX=$(cc "a.sh change on another line of work")
git -C "$CR" reset -q --hard "$GN"
resps REV-20990101-031 "$GU" "$GB" "$P" "$GX"; GF=$(cc "round 2 response names a foreign earlier range")
if ! git -C "$CR" merge-base --is-ancestor "$GX" "$GB"; then
    cov "$P" "$GF" "$(row REV-20990101-031 "$GB")"
    [ "$rc" -eq 1 ] && grep -q 'UNCOVERED a.sh' "$WORK/cov.out" && grep -q 'covers nothing' "$WORK/cov.out" \
        && ok "coverage F4g: a 'submitted:' range off this REV's line of work covers nothing, and the gate says so" \
        || bad "coverage F4g: a foreign earlier range" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the foreign range is on the implementation's line"
fi
# The same with a mode change in round 1 and a scrub change in round 2.
git -C "$CR" reset -q --hard "$PS"
git -C "$CR" update-index --chmod=+x b.sh; HA=$(cc "REV round 1: chmod +x b.sh")
resp REV-20990101-033 "$PS" "$HA"; HR1=$(cc "round 1 response")
cw release/scrub.sed 's/BEFORE/AFTER/g'; HB=$(cc "REV round 2: scrub change rewriting a.sh")
resps REV-20990101-033 "$HR1" "$HB"; HN=$(cc "round 2 response: narrowed base only")
if [ "$(git -C "$CR" ls-tree "$HA" b.sh | cut -c1-6)" = 100755 ]; then
    cov "$PS" "$HN" "$(row REV-20990101-033 "$HB")"
    [ "$rc" -eq 1 ] && grep -q 'UNCOVERED b.sh' "$WORK/cov.out" && ! grep -q 'UNCOVERED a.sh' "$WORK/cov.out" \
        && ok "coverage F4g: control -- a narrowed base alone leaves round 1's mode change uncovered" \
        || bad "coverage F4g: mode, narrowed base alone" "rc=$rc" "$(cat "$WORK/cov.out")"
    resps REV-20990101-033 "$HR1" "$HB" "$PS" "$HA"; HK=$(cc "round 2 response keeps round 1's range")
    cov "$PS" "$HK" "$(row REV-20990101-033 "$HB")"
    [ "$rc" -eq 0 ] && grep -q 'b.sh <- REV-20990101-033' "$WORK/cov.out" && grep -q 'a.sh <- REV-20990101-033' "$WORK/cov.out" \
        && ok "coverage F4g: round 1's mode change and round 2's scrub change both covered" \
        || bad "coverage F4g: mode + scrub resubmission" "rc=$rc" "$(cat "$WORK/cov.out")"
else
    bad "coverage fixture: the round-1 chmod did not happen"
fi

# publish.sh --push runs the gate on HEAD's own ledger BEFORE writing anything: when the gate
# refuses, REL gets no new commit. (When it passes, publish commits locally and the push then
# fails, because REL has no remote; that branch is not asserted here.) HEAD's own ledger decides
# which branch applies. The fixture cases above are what pin the gate itself.
before="$(git -C "$REL" rev-parse HEAD)"
out3="$(bash "$REPO/release/publish.sh" HEAD "$REL" --push 2>&1)"
if bash "$REPO/test/reviewctl.sh" --derive HEAD 2>/dev/null | bash "$GATE" >/dev/null 2>&1; then
    ok "publish --push: HEAD's ledger has a verdict for every review (gate not exercised here)"
elif printf '%s\n' "$out3" | grep -q "Reviewer's gate refused" && [ "$(git -C "$REL" rev-parse HEAD)" = "$before" ]; then
    ok "publish --push: an open review in HEAD's ledger refuses before anything is written"
else
    bad "publish --push: an open review in HEAD's ledger refuses before anything is written" "$out3"
fi
# Reviewer F3 (PR #1127): an Owner override is never pushed without its audit record.
# Deterministic: a throw-away worktree of this repo at HEAD whose ledger is a fixture with
# exactly one open review, and release clones with a disposable local bare origin.
DEVW="$WORK/dev"
if git -C "$REPO" worktree add -q --detach "$DEVW" HEAD 2>/dev/null; then
    # PROTOCOL V4.4: the ledger is derived, so a fixture state is made of ARTIFACTS. The real
    # reviews are taken out of the throw-away commit first, so the fixture is the whole state,
    # as the hand-written fixture ledger used to be.
    git -C "$DEVW" rm -rq --ignore-unmatch docs/internal/reviews/responses docs/internal/reviews/closures
    git -C "$DEVW" ls-files 'docs/internal/reviews/REV-*.md' | while IFS= read -r f; do git -C "$DEVW" rm -q "$f"; done
    mkdir -p "$DEVW/docs/internal/reviews/responses"
    printf '<!-- rev: REV-20990101-003 -->\n<!-- verdict: CHANGES-REQUIRED -->\n<!-- reviewed-implementation: - -->\n\n# t\n' \
        > "$DEVW/docs/internal/reviews/REV-20990101-003.md"
    # A stale ledger committed by hand (force-added past .gitignore) that claims the review is
    # closed. The gates derive; they must never read this file (V4.4). With the pre-V4.4 publish
    # the f3/f3b cases below fail, because that publish read exactly this file.
    printf '%s\n' '# REVIEW_LEDGER' '' '| REV | State | Owner | Implementation | Reviewed | Response | Next |' \
        '|---|---|---|---|---|---|---|' '| REV-20990101-003 | CLOSED | - | - | - | - | - |' \
        > "$DEVW/docs/internal/reviews/REVIEW_LEDGER.md"
    git -C "$DEVW" add -f docs/internal/reviews/REVIEW_LEDGER.md
    git -C "$DEVW" add -A docs/internal/reviews
    git -C "$DEVW" commit -qm "fixture: one open review" && devrev="$(git -C "$DEVW" rev-parse HEAD)"
    if bash "$DEVW/test/reviewctl.sh" --derive "$devrev" 2>/dev/null | grep -q '^| REV-20990101-003 | OPEN | Claude |'; then
        ok "publish fixture: the derived state of the fixture commit is exactly one open review (control)"
    else
        bad "publish fixture: one open review" "$(bash "$DEVW/test/reviewctl.sh" --derive "$devrev" 2>&1 | tail -5)"
    fi
    # <dir> [published-rev] -> release clone with a bare local origin. With a revision, the
    # pushed start commit carries it as RELEASE-OF: what hosts received last (round 2, F4a).
    mkrel() {
        git init -q --bare "$1.git"
        git init -q -b main "$1"
        if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$1/RELEASE-OF" && git -C "$1" add RELEASE-OF; fi
        git -C "$1" commit -q --allow-empty -m start
        git -C "$1" remote add origin "$1.git" && git -C "$1" push -q origin main
    }
    # The coverage gate compares with the published release; the parent of the fixture commit,
    # so the only change in between is the ledger, not a run-time file.
    mkrel "$WORK/f3" "$(git -C "$DEVW" rev-parse "$devrev^")"
    start="$(git -C "$WORK/f3.git" rev-parse main)"
    bash "$DEVW/release/publish.sh" "$devrev" "$WORK/f3" >/dev/null 2>&1      # run 1: commit, no push
    out4="$(bash "$DEVW/release/publish.sh" "$devrev" "$WORK/f3" --push --accept-open-review=REV-20990101-003 2>&1)"; rc4=$?
    if [ "$rc4" -ne 0 ] && printf '%s\n' "$out4" | grep -q "does not record the Owner's override" \
       && [ "$(git -C "$WORK/f3.git" rev-parse main)" = "$start" ]; then
        ok "publish: a second run with --push and an override does not push the earlier, unaudited commit"
    else
        bad "publish: a second run with --push and an override does not push the earlier, unaudited commit" "rc=$rc4" "$out4"
    fi
    mkrel "$WORK/f3b" "$(git -C "$DEVW" rev-parse "$devrev^")"
    out5="$(bash "$DEVW/release/publish.sh" "$devrev" "$WORK/f3b" --push --accept-open-review=REV-20990101-003 2>&1)"; rc5=$?
    if [ "$rc5" -eq 0 ] && git -C "$WORK/f3b.git" log -1 --format=%B main | grep -q '^accepted: REV-20990101-003 '; then
        ok "publish: an override with a new release commit pushes, and the pushed commit records 'accepted: REV-...'"
    else
        bad "publish: an override with a new release commit pushes and records it" "rc=$rc5" "$out5"
    fi
    # Round 2, F4a: the baseline is the PUBLISHED release, not the checkout's working RELEASE-OF.
    # d0: a ledger with nothing open; d1: an unsubmitted run-time change; d2: its submission.
    git -C "$DEVW" rm -q docs/internal/reviews/REV-20990101-003.md
    git -C "$DEVW" commit -qm "fixture: nothing open" && d0="$(git -C "$DEVW" rev-parse HEAD)"
    printf '# r195 fixture: an unsubmitted run-time change\n' >> "$DEVW/zfs-job.sh"
    git -C "$DEVW" commit -qam "fixture: run-time change" && d1="$(git -C "$DEVW" rev-parse HEAD)"
    f4a_refused() {   # <dir> <rc> <out> <origin main before>
        [ "$2" -ne 0 ] && printf '%s\n' "$3" | grep -q 'UNCOVERED zfs-job.sh' \
            && [ "$(git -C "$1.git" rev-parse main)" = "$4" ]
    }
    mkrel "$WORK/f4a" "$d0"; st="$(git -C "$WORK/f4a.git" rev-parse main)"
    bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4a" >/dev/null 2>&1      # prepare, no push
    o="$(bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4a" --push 2>&1)"; r=$?
    if f4a_refused "$WORK/f4a" "$r" "$o" "$st"; then
        ok "publish F4a: prepare without --push, then --push -- still refused against the PUBLISHED release, nothing pushed"
    else
        bad "publish F4a: prepare then push launders the change" "rc=$r" "$o"
    fi
    mkrel "$WORK/f4b" "$d0"; st="$(git -C "$WORK/f4b.git" rev-parse main)"
    bash "$DEVW/release/publish.sh" "$d0" "$WORK/f4b" >/dev/null 2>&1
    bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4b" >/dev/null 2>&1
    o="$(bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4b" --push 2>&1)"; r=$?
    if f4a_refused "$WORK/f4b" "$r" "$o" "$st"; then
        ok "publish F4a: several prepared local commits -- all checked from the published release, refused"
    else
        bad "publish F4a: several prepared commits" "rc=$r" "$o"
    fi
    mkrel "$WORK/f4c"; st="$(git -C "$WORK/f4c.git" rev-parse main)"
    o="$(bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4c" --push 2>&1)"; r=$?
    git init -q -b main "$WORK/f4n" && git -C "$WORK/f4n" commit -q --allow-empty -m start
    on="$(bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4n" --push 2>&1)"; rn=$?
    if [ "$r" -ne 0 ] && printf '%s\n' "$o" | grep -q 'has no RELEASE-OF' \
       && [ "$(git -C "$WORK/f4c.git" rev-parse main)" = "$st" ] \
       && [ "$rn" -ne 0 ] && printf '%s\n' "$on" | grep -q 'what hosts received last is unknown'; then
        ok "publish F4a: an unknown published baseline (no RELEASE-OF on origin, no origin at all) refuses"
    else
        bad "publish F4a: an unknown published baseline" "rc=$r $o" "rc=$rn $on"
    fi
    # A release checkout BEHIND its origin (someone published since it was cloned) is refused
    # before the gates, not by a rejected push at the end (1.0.21, 2026-11-13).
    mkrel "$WORK/f4s" "$d0"
    git clone -q -b main "$WORK/f4s.git" "$WORK/f4s2" && git -C "$WORK/f4s2" commit -q --allow-empty -m newer \
        && git -C "$WORK/f4s2" push -q origin main
    st="$(git -C "$WORK/f4s.git" rev-parse main)"
    o="$(bash "$DEVW/release/publish.sh" "$d1" "$WORK/f4s" --push 2>&1)"; r=$?
    if [ "$r" -ne 0 ] && printf '%s\n' "$o" | grep -q 'is behind (or off) its origin/main' \
       && ! printf '%s\n' "$o" | grep -q 'reviewctl: derived' \
       && [ "$(git -C "$WORK/f4s.git" rev-parse main)" = "$st" ]; then
        ok "publish: a release checkout behind its origin is refused before the gates, nothing pushed"
    else
        bad "publish: a release checkout behind its origin" "rc=$r" "$o"
    fi
    mkdir -p "$DEVW/docs/internal/reviews/responses"
    printf '<!-- rev: REV-20990101-005 -->\n<!-- response-status: IMPLEMENTED -->\n<!-- implementation: %s -->\n<!-- base: %s -->\n' "$d1" "$d0" \
        > "$DEVW/docs/internal/reviews/responses/REV-20990101-005.md"
    printf '<!-- rev: REV-20990101-005 -->\n<!-- verdict: APPROVED -->\n<!-- reviewed-implementation: %s -->\n\n# t\n' "$d1" \
        > "$DEVW/docs/internal/reviews/REV-20990101-005.md"
    git -C "$DEVW" add -A docs/internal/reviews && git -C "$DEVW" commit -qm "fixture: submitted" && d2="$(git -C "$DEVW" rev-parse HEAD)"
    mkrel "$WORK/f4d" "$d0"
    bash "$DEVW/release/publish.sh" "$d2" "$WORK/f4d" >/dev/null 2>&1      # prepared first, as in F4a
    o="$(bash "$DEVW/release/publish.sh" "$d2" "$WORK/f4d" --push 2>&1)"; r=$?
    if [ "$r" -eq 0 ] && [ "$(git -C "$WORK/f4d.git" show main:RELEASE-OF)" = "$d2" ] \
       && printf '%s\n' "$o" | grep -q 'zfs-job.sh <- REV-20990101-005'; then
        ok "publish F4a: control -- the submitted change pushes, and the gate names the REV that covers it"
    else
        bad "publish F4a: a submitted change pushes" "rc=$r" "$o"
    fi
    # Round 3, F4f, through the real prepare/push path: a scrub-only change rewrites every
    # shipped text file (it appends a line), and no submission covers it.
    printf '%s\n' '$a\' '# r195 scrub-only change' >> "$DEVW/release/scrub.sed"
    git -C "$DEVW" commit -qam "fixture: scrub-only change" && d3="$(git -C "$DEVW" rev-parse HEAD)"
    mkrel "$WORK/f4s" "$d2"; st="$(git -C "$WORK/f4s.git" rev-parse main)"
    bash "$DEVW/release/publish.sh" "$d3" "$WORK/f4s" >/dev/null 2>&1      # prepare, no push
    o="$(bash "$DEVW/release/publish.sh" "$d3" "$WORK/f4s" --push 2>&1)"; r=$?
    if f4a_refused "$WORK/f4s" "$r" "$o" "$st" \
       && [ "$(tail -1 "$WORK/f4s/zfs-job.sh")" = '# r195 scrub-only change' ]; then
        ok "publish F4f: a scrub-only change that rewrites the prepared zfs-job.sh is refused at --push, nothing pushed"
    else
        bad "publish F4f: a scrub-only change reaches the release" "rc=$r" "$o"
    fi
    git -C "$DEVW" reset -q --hard "$d2"
    printf '%s\n' 's/r195-NEVER-IN-A-SHIPPED-FILE/x/g' >> "$DEVW/release/scrub.sed"
    git -C "$DEVW" commit -qam "fixture: a scrub rule with no effect" && d4="$(git -C "$DEVW" rev-parse HEAD)"
    mkrel "$WORK/f4t" "$d2"
    o="$(bash "$DEVW/release/publish.sh" "$d4" "$WORK/f4t" --push 2>&1)"; r=$?
    if [ "$r" -eq 0 ] && [ "$(git -C "$WORK/f4t.git" show main:RELEASE-OF)" = "$d4" ]; then
        ok "publish F4f: control -- a scrub change that rewrites nothing pushes"
    else
        bad "publish F4f: a scrub change with no effect" "rc=$r" "$o"
    fi
    # V4.4: a candidate whose own generator refuses its artifacts is refused -- never an empty
    # ledger that the gate would read as "nothing open".
    git -C "$DEVW" reset -q --hard "$d2"
    printf '<!-- rev: REV-20990101-006 -->\n<!-- response-status: IMPLEMENTED -->\n<!-- implementation: %s -->\n\n# t\n' \
        0000000000000000000000000000000000000000 > "$DEVW/docs/internal/reviews/responses/REV-20990101-006.md"
    git -C "$DEVW" add -A docs/internal/reviews && git -C "$DEVW" commit -qm "fixture: broken artifacts" && d5="$(git -C "$DEVW" rev-parse HEAD)"
    mkrel "$WORK/f4u" "$d2"; st="$(git -C "$WORK/f4u.git" rev-parse main)"
    o="$(bash "$DEVW/release/publish.sh" "$d5" "$WORK/f4u" --push 2>&1)"; r=$?
    if [ "$r" -ne 0 ] && printf '%s\n' "$o" | grep -q 'cannot derive the review state' \
       && [ "$(git -C "$WORK/f4u.git" rev-parse main)" = "$st" ]; then
        ok "publish V4.4: a candidate whose artifacts do not derive is refused, nothing pushed (fail closed)"
    else
        bad "publish V4.4: underivable candidate" "rc=$r" "$o"
    fi
    git -C "$REPO" worktree remove --force "$DEVW" 2>/dev/null
else
    bad "publish F3 cases" "could not create a throw-away worktree of $REPO"
fi

if bash "$REPO/release/publish.sh" HEAD "$REL" --bogus >/dev/null 2>&1; then
    bad "publish: an unknown option is refused" ""
else
    ok "publish: an unknown option is refused"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
