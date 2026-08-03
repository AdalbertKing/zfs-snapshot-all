#!/bin/bash
# Tests for deploy.sh's remote_scope_stage() -- the draft/edit/check substage
# --join-remotely's scope editor runs over ssh -t (REV-20260804-037 F1).
#
# F1: the old inline command joined draft and editor with a bare ';' (the
# editor opened even after a failed draft, which could itself create an
# empty/partial scope file at a path the generator then refuses to
# overwrite) and discarded the draft's stderr (2>/dev/null) -- the one
# diagnostic that explains why. $remote_ok was set right after --join and
# never revisited, so a failed editor only warned while the final summary
# still called the scope "edited".
#
# This is ordinary shell control flow over an already-pinned link, not the
# zfs allow/unallow trust semantics this project deliberately leaves to live
# verification only (do_pair/do_join's real useradd/zfs-allow actions still
# have no local test, by that same established choice -- see test/join/
# run.sh's own header). remote_scope_stage() was extracted to its own
# function specifically so this piece does NOT have to make that trade:
# `ssh` is stubbed to run the generated remote-command string against a
# local "fake remote" directory instead of a real host, same extraction
# technique test/draftscope/run.sh already uses for do_draft_scope.
#
#   ./test/joinremote/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
[ -r "$DEPLOY_SRC" ] || { echo "cannot read deploy.sh at $DEPLOY_SRC" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

eval "$(sed -n '/^remote_scope_stage() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F remote_scope_stage >/dev/null; then
    echo "FATAL: could not extract remote_scope_stage from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
    exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# case <name> -- fresh "fake remote" directory + PATH with a stub ssh that
# runs the remote-command string against it via bash -c, instead of over a
# real network. remote_scope_stage's own -o/-p ssh options are simply
# ignored by the stub, same as any other test stubbing ssh in this repo.
FAKE=""
new_case() {
    FAKE="$TMPD/$1"; mkdir -p "$FAKE/bin"
    cat > "$FAKE/bin/ssh" <<EOF
#!/bin/bash
cmd="\${@: -1}"
cd "$FAKE" && bash -c "\$cmd"
EOF
    chmod +x "$FAKE/bin/ssh"
    export PATH="$FAKE/bin:$PATH"
}

# stub_deploy <draft-behavior> <check-behavior> -- a fake ./deploy.sh in the
# fake remote dir. draft-behavior: ok (creates the scope file) | fail.
# check-behavior: ok | fail | skip (never reached, left unset).
stub_deploy() {
    local draft="$1" check="${2:-skip}"
    cat > "$FAKE/deploy.sh" <<EOF
#!/bin/bash
case "\$1" in
    --draft-scope=*)
        if [ "$draft" = ok ]; then
            echo "SCOPE_CONTENT" > "$FAKE/scope.file"
            exit 0
        else
            echo "stub: draft-scope deliberately failing" >&2
            exit 1
        fi
        ;;
    --commit-scope-check=*)
        if [ "$check" = ok ]; then exit 0; else echo "stub: commit-scope-check deliberately failing" >&2; exit 1; fi
        ;;
    *) echo "stub deploy.sh: unexpected args: \$*" >&2; exit 9 ;;
esac
EOF
    chmod +x "$FAKE/deploy.sh"
}

# stub_editor <rc> -- $EDITOR exits <rc>; when rc=0 it also creates the scope
# file (simulating a real edit) so the post-editor check has something to
# validate, matching what vi would leave behind.
stub_editor() {
    local rc="$1"
    cat > "$FAKE/bin/fake-editor" <<EOF
#!/bin/bash
[ "$rc" -eq 0 ] && echo "EDITED_CONTENT" > "\$1"
exit $rc
EOF
    chmod +x "$FAKE/bin/fake-editor"
    export EDITOR="$FAKE/bin/fake-editor"
}

RESTORE_PATH="$PATH"
RESTORE_EDITOR="${EDITOR:-}"
restore_env() { export PATH="$RESTORE_PATH"; export EDITOR="$RESTORE_EDITOR"; }

# ---------------------------------------------------------------------------
# 1. Forced draft failure does not invoke the editor and does not create a
#    scope file -- the exact defect F1 names (the old bare ';' opened the
#    editor regardless).
# ---------------------------------------------------------------------------
new_case draft-fails
stub_deploy fail
stub_editor 0   # would succeed if wrongly invoked -- proves it was NOT called
out=$(remote_scope_stage mylabel fakehost 22 "$FAKE/scope.file" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$FAKE/scope.file" ]; then
    ok "draft failure: stage returns 2 and no scope file is created"
else
    bad "draft failure: stage returns 2 and no scope file is created" "rc=$rc" "$out" "exists=$([ -e "$FAKE/scope.file" ] && echo yes || echo no)"
fi
if printf '%s' "$out" | grep -qF "stub: draft-scope deliberately failing"; then
    ok "draft failure: the draft's own stderr reaches the operator (not discarded)"
else
    bad "draft failure: the draft's own stderr reaches the operator (not discarded)" "$out"
fi
restore_env

# ---------------------------------------------------------------------------
# 2. Existing scope file: draft is skipped entirely, editor opens directly --
#    no destructive regeneration of a file the operator may already be
#    mid-edit on (this is also what makes retrying after a fixed 2/3/4
#    failure safe: the second run does not re-draft over the first attempt).
# ---------------------------------------------------------------------------
new_case existing-scope
stub_deploy fail ok   # if draft were wrongly invoked, this proves it by failing the whole run
mkdir -p "$(dirname "$FAKE/scope.file")"
echo "PRE_EXISTING" > "$FAKE/scope.file"
stub_editor 0
out=$(remote_scope_stage mylabel fakehost 22 "$FAKE/scope.file" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "existing scope file found"; then
    ok "existing scope: draft is skipped, editor runs directly, stage succeeds"
else
    bad "existing scope: draft is skipped, editor runs directly, stage succeeds" "rc=$rc" "$out"
fi
restore_env

# ---------------------------------------------------------------------------
# 3. Editor exit non-zero: stage returns 3, does not claim success.
# ---------------------------------------------------------------------------
new_case editor-fails
stub_deploy ok
stub_editor 1
out=$(remote_scope_stage mylabel fakehost 22 "$FAKE/scope.file" 2>&1); rc=$?
if [ "$rc" -eq 3 ] && ! printf '%s' "$out" | grep -qi "ready for.*commit"; then
    ok "editor failure: stage returns 3 and never claims the scope is ready"
else
    bad "editor failure: stage returns 3 and never claims the scope is ready" "rc=$rc" "$out"
fi
restore_env

# ---------------------------------------------------------------------------
# 4. Editor exits zero but --commit-scope-check fails afterward: stage
#    returns 4, does not claim success -- this is the exact "false success"
#    shape F1 named (a file that LOOKS edited but does not actually parse).
# ---------------------------------------------------------------------------
new_case check-fails
stub_deploy ok fail
stub_editor 0
out=$(remote_scope_stage mylabel fakehost 22 "$FAKE/scope.file" 2>&1); rc=$?
if [ "$rc" -eq 4 ] && ! printf '%s' "$out" | grep -qi "ready for.*commit"; then
    ok "post-editor check failure: stage returns 4 and never claims the scope is ready"
else
    bad "post-editor check failure: stage returns 4 and never claims the scope is ready" "rc=$rc" "$out"
fi
restore_env

# ---------------------------------------------------------------------------
# 5. Complete success: draft creates the file, editor edits it, check passes
#    -- stage returns 0 and says so.
# ---------------------------------------------------------------------------
new_case complete-success
stub_deploy ok ok
stub_editor 0
out=$(remote_scope_stage mylabel fakehost 22 "$FAKE/scope.file" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "ready for local --commit-scope=mylabel" \
   && [ -f "$FAKE/scope.file" ]; then
    ok "complete success: stage returns 0, names the exact next command, scope file exists"
else
    bad "complete success: stage returns 0, names the exact next command, scope file exists" "rc=$rc" "$out"
fi
restore_env

# ---------------------------------------------------------------------------
# 6. Structural pin: do_pair's own summary names all four scope_rc outcomes
#    distinctly (this is the half of F1 -- accurate final guidance per
#    reached state -- that a stubbed remote_scope_stage call alone cannot
#    prove, since do_pair() itself needs root before reaching this code;
#    see test/join/run.sh's header for why do_pair/do_join's real actions
#    have no local test in this project).
# ---------------------------------------------------------------------------
if grep -qE 'case "\$scope_rc" in' "$DEPLOY_SRC" \
   && grep -qF 'Draft NIE powiodl sie' "$DEPLOY_SRC" \
   && grep -qF 'Sesja edytora na $PEER_HOST zakonczyla sie niezerowo' "$DEPLOY_SRC" \
   && grep -qF 'NIE przeszedl --commit-scope-check' "$DEPLOY_SRC" \
   && grep -qF 'Zakres zredagowany zdalnie i zweryfikowany' "$DEPLOY_SRC"; then
    ok "do_pair: the final summary names a distinct recovery step for each of scope_rc 0/2/3/4"
else
    bad "do_pair: the final summary names a distinct recovery step for each of scope_rc 0/2/3/4" \
        "one or more expected strings missing from $DEPLOY_SRC"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
