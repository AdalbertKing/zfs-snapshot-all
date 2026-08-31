#!/bin/bash
# Relation-level restore failure policy -- D + B, on the runner the public verb
# actually goes through.
#
#   ./test/restore/relpolicy.sh                                      # standalone
#   ZB=/path/to/mutated/zfs-restore.sh ./test/restore/relpolicy.sh   # negative control
#
# Sourced by test/restore/run.sh as its last section, so the default battery and
# its case count are unchanged.
#
# WHICH RUNNER, AND WHY IT MATTERS. There are two destructive paths in
# zfs-restore.sh: `restore_run_scope` -> `restore_one`, which every public form
# of the verb goes through, and `restore_replace_internal`, the older
# single-dataset engine whose own header says it has NO public door. The first
# version of this policy was written around the second one. Its cases passed and
# its negative controls discriminated -- and none of it was reachable from
# `restore`. A control proves that a case measures the function it names; it
# cannot notice that nobody calls that function. So these cases drive
# `restore_run_scope` and stub `restore_one`, and this paragraph is here so the
# next person does not have to rediscover which of the two is the live one.
#
# It is a separate FILE because a negative control has to run these cases against
# a deliberately broken tree, at least twice -- once with the pre-flight pass
# removed, once with the continue-past-failure loop removed. The planner battery
# takes over ten minutes on the implementer's box, so folding the control into it
# is how a control quietly stops being run. Here it costs seconds, which is the
# only cost at which a control actually gets run.

if ! declare -F ok >/dev/null 2>&1; then
    set -u
    _rp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="${REPO:-$(cd "$_rp_dir/../.." && pwd)}"
    ZB="${ZB:-$REPO/zfs-restore.sh}"
    [ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
    WORK="${WORK:-$(mktemp -d)}"; trap 'rm -rf "$WORK"' EXIT
    PASS=0; FAIL=0
    ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
    bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }
    _rp_standalone=1
fi

# ---------------------------------------------------------------------------
# RELATION-LEVEL FAILURE POLICY -- D + B (owner's decision, 2026-08-30)
#
#   D  pre-flight the WHOLE scope; refuse before the first mutation if any
#      dataset cannot be restored, naming EVERY one that failed;
#   B  then execute, and do not stop at a failure -- give back what can be
#      given back, and keep "untouched" apart from "changed and unfinished".
#
# What is tested here is the POLICY, so the per-dataset step is stubbed: these
# cases decide what happens AROUND it, and stubbing it is what lets a failure be
# CHOSEN rather than contrived. restore_one's own behaviour is covered by the
# 190-odd cases above.
RP="$WORK/relpolicy"; mkdir -p "$RP"

# Drive the policy with a stubbed restore_one whose answer per dataset is read
# from a table: <dataset>=<rc>. Pre-flight and execution are distinguished by
# RESTORE_PREFLIGHT_ONLY, exactly as the real one distinguishes them.
run_policy() {   # <preflight table> <exec table> <dataset...>
    local pf="$1" ex="$2"; shift 2
    local t; t=$(mktemp)
    {
        echo 'set -u'
        printf 'PF=%q\n' "$pf"
        printf 'EX=%q\n' "$ex"
        echo 'log() { shift; printf "%s\n" "$*" >&2; }'
        echo 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        # The collaborators restore_run_scope calls around the loop. Each one
        # ANNOUNCES itself, so a case can assert on the ORDER of events and not
        # only on the final text -- "the pre-flight ran before the pause" is not
        # visible in a verdict line.
        cat <<'STUB'
restore_pause_take()          { printf 'pause: take %s\n' "${1:-}" >&2; return 0; }
restore_pause_release()       { printf 'pause: release\n' >&2; }
restore_report_mount_state()  { :; }
restore_report_handover()     { :; }
restore_report_backup_cost()  { :; }
restore_one() {
    local ds="$2" tbl
    # Recorded only during EXECUTION, the way the real one does it: the
    # pre-flight returns at the boundary before anything is rolled back, so it
    # has nothing to record. A stub that recorded in both passes would count
    # every dataset twice and make the E3 case measure the stub.
    [ "${RESTORE_PREFLIGHT_ONLY:-0}" = 1 ] || RESTORE_ROLLED_BACK+=("rolled:$ds")
    # EVERY execution is recorded, not only a failing one. An earlier stub
    # printed only on refusal, which made "no dataset was executed" pass against
    # a tree with no pre-flight at all whenever the execution table was clean --
    # an assertion that cannot fail is not an assertion.
    if [ "${RESTORE_PREFLIGHT_ONLY:-0}" = 1 ]; then
        tbl="$PF"
    else
        tbl="$EX"; printf 'exec: %s\n' "$ds" >&2
    fi
    local rc=0
    while IFS='=' read -r k v; do
        [ "$k" = "$ds" ] && rc="$v"
    done < "$tbl"
    RESTORE_ONE_VERDICT="stub verdict for $ds (rc=$rc)"
    # TWO CONTROL-FLOW SHAPES, because the real one has two. `die` in this tree
    # is `exit 1`, and a stub that can only RETURN cannot express the refusal
    # that ends the process -- which is exactly how REV-20260831-127 F1 survived
    # a green suite. `die` and `die2` are the exiting shapes; `die2` exits after
    # the dataset has already been touched.
    case "$rc" in
        die)  RESTORE_ONE_VERDICT="late pre-mutation refusal for $ds"
              die "FATAL: late pre-mutation refusal for $ds" ;;
        die2) RESTORE_ONE_CHANGED=1
              RESTORE_ONE_VERDICT="broke after destruction began on $ds"
              die "FATAL: broke after destruction began on $ds" ;;
    esac
    return "$rc"
}
STUB
        awk -v want="restore_one_isolated() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        awk -v want="restore_run_scope() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
        echo 'RESTORE_SCOPE_SRC=(); RESTORE_SCOPE_COPY=(); RESTORE_SCOPE_DEST=()'
        local d
        for d in "$@"; do
            printf 'RESTORE_SCOPE_SRC+=(%q); RESTORE_SCOPE_COPY+=(%q); RESTORE_SCOPE_DEST+=(%q)\n' "$d" "copy/$d" "$d"
        done
        echo 'restore_run_scope; _rc=$?'
        # Printed by the HARNESS, not by the product: the array is what the
        # boundary hands back, and asserting on it must not need a probe line
        # shipped in the verb itself.
        echo 'for e in ${RESTORE_ROLLED_BACK[@]+"${RESTORE_ROLLED_BACK[@]}"}; do echo "rolled-entry: $e"; done'
        echo 'exit $_rc'
    } > "$t"
    # RETURNED, not assigned to a global: the caller reads this through
    # `out="$(run_policy ...)"`, which is a SUBSHELL -- a variable set here would
    # never reach it. Same trap as unwrap_media_bracket in cron2conf.sh, whose
    # header records it for the same reason.
    bash "$t" 2>&1
    local rc=$?
    rm -f "$t"
    return "$rc"
}

# D1 -- one bad dataset in five refuses the whole run BEFORE anything runs.
printf 'a=0\nb=0\nc=1\nd=0\ne=0\n' > "$RP/pf"
printf 'a=0\nb=0\nc=0\nd=0\ne=0\n' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c d e)"; rc=$?
case "$rc" in
    2) ok "D1: one unrestorable dataset refuses the whole relation" ;;
    *) bad "D1: one unrestorable dataset refuses the whole relation" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"REFUSED before anything was touched"*) ok "D1: ...before anything is touched, in those words" ;;
    *) bad "D1: ...before anything is touched, in those words" "$out" ;;
esac
# THE CARRYING ASSERTION: restore_one must not have been ENTERED for real.
# Asserted from the stub's own execution record, so a tree that skipped
# pre-flight and simply ran all five cleanly fails here.
case "$out" in
    *"exec: "*) bad "D1: ...and no dataset was executed" "$out" ;;
    *) ok "D1: ...and no dataset was executed" ;;
esac
# AND THE SCHEDULE IS PUT BACK. The pre-flight runs INSIDE the pause -- owner
# decision 2026-08-27, a restore does not start while the schedule is live, and
# a pre-flight is the restore starting. So the refusal owes a release: a
# relationship left paused is a backup that silently stops, and this run refused
# precisely because nothing should change.
case "$out" in
    *"pause: take"*) ok "D1: ...inside the pause, as the schedule rule requires" ;;
    *) bad "D1: ...inside the pause, as the schedule rule requires" "$out" ;;
esac
case "$out" in
    *"pause: release"*) ok "D1: ...and the schedule is released again on the refusal" ;;
    *) bad "D1: ...and the schedule is released again on the refusal" "$out" ;;
esac

# D2 -- EVERY bad one is named, not just the first. An operator fixing them one
# round-trip at a time is an operator who stops trusting the tool.
printf 'a=0\nb=1\nc=1\nd=0\ne=1\n' > "$RP/pf"
out="$(run_policy "$RP/pf" "$RP/ex" a b c d e)"
n=0
# Matched against the REFUSAL list, not the whole output: a tree with no
# pre-flight prints every dataset in an ordinary verdict line too, and a check
# that cannot tell those apart passes against the very tree it exists to catch.
for x in b c e; do case "$out" in *"UNFIT    $x   "*) n=$((n+1)) ;; esac; done
if [ "$n" -eq 3 ]; then ok "D2: all three unrestorable datasets are named, not just the first"
else bad "D2: all three unrestorable datasets are named, not just the first" "named $n of 3" "$out"; fi
case "$out" in
    *"3 of 5"*) ok "D2: ...and the count says how many of how many" ;;
    *) bad "D2: ...and the count says how many of how many" "$out" ;;
esac

# B1 -- a clean scope runs every dataset.
printf 'a=0\nb=0\nc=0\n' > "$RP/pf"
printf 'a=0\nb=0\nc=0\n' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"; rc=$?
case "$rc$out" in
    0*"all 3 dataset(s) in scope recovered"*) ok "B1: a scope that passes pre-flight restores every dataset" ;;
    *) bad "B1: a scope that passes pre-flight restores every dataset" "rc=$rc" "$out" ;;
esac

# B2 -- THE CARRYING ASSERTION FOR B. A failure on the middle dataset must NOT
# stop the ones after it: that is the whole difference between this policy and
# "stop at the first failure".
printf 'a=0\nb=0\nc=0\n' > "$RP/pf"
printf 'a=0\nb=1\nc=0\n' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"; rc=$?
case "$out" in
    *"exec: c"*) ok "B2: A FAILURE MID-SCOPE DOES NOT STOP THE REST" ;;
    *) bad "B2: A FAILURE MID-SCOPE DOES NOT STOP THE REST" "$out" ;;
esac
case "$rc" in
    1) ok "B2: ...and the run still reports failure" ;;
    *) bad "B2: ...and the run still reports failure" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"NOT DONE b"*) ok "B2: ...naming the one that failed before destruction as untouched" ;;
    *) bad "B2: ...naming the one that failed before destruction as untouched" "$out" ;;
esac
case "$out" in
    *"PARTIAL -- 2 recovered"*) ok "B2: ...and the summary counts two recovered of three" ;;
    *) bad "B2: ...and the summary counts two recovered of three" "$out" ;;
esac

# B3 -- 'changed' is NOT the same as 'untouched', and outranks it. A dataset
# whose destruction began and whose transfer then broke is the only state that
# needs a human, and it must not be buried in a count with the ones the run
# never began. restore_one says which of the two it was in its exit status: 2
# once it has touched the target, 1 while it still has not.
printf 'a=0\nb=2\nc=0\n' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"; rc=$?
case "$out" in
    *"CHANGED  b"*) ok "B3: a half-destroyed dataset is called out separately" ;;
    *) bad "B3: a half-destroyed dataset is called out separately" "$out" ;;
esac
case "$out" in
    *"CHANGED AND UNFINISHED"*) ok "B3: ...in words that say it needs a person" ;;
    *) bad "B3: ...in words that say it needs a person" "$out" ;;
esac
case "$rc" in
    2) ok "B3: ...and it outranks an ordinary failure in the exit status" ;;
    *) bad "B3: ...and it outranks an ordinary failure in the exit status" "rc=$rc" "$out" ;;
esac
# The other two datasets still ran: 'changed' changes the verdict, not the policy.
case "$out" in
    *"exec: c"*) ok "B3: ...while the rest of the scope still ran" ;;
    *) bad "B3: ...while the rest of the scope still ran" "$out" ;;
esac

# E -- THE EXITING PRIMITIVE (REV-20260831-127 F1). The relation controller can
# only classify a status it is GIVEN, and `die` in this tree is `exit 1`. Before
# the isolation boundary a single late refusal took the whole run with it: the
# datasets after it were never attempted and no summary was printed at all.
#
# 'c' is the sentinel. Its presence is the entire finding.
printf 'a=0
b=0
c=0
' > "$RP/pf"
printf 'a=0
b=die
c=0
' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"; rc=$?
case "$out" in
    *"exec: c"*) ok "E1: A DATASET THAT EXITS DOES NOT TAKE THE RELATION WITH IT" ;;
    *) bad "E1: A DATASET THAT EXITS DOES NOT TAKE THE RELATION WITH IT" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"per-dataset result"*) ok "E1: ...and the summary is still printed" ;;
    *) bad "E1: ...and the summary is still printed" "$out" ;;
esac
case "$out" in
    *"NOT DONE b"*) ok "E1: ...naming the one that exited as untouched" ;;
    *) bad "E1: ...naming the one that exited as untouched" "$out" ;;
esac
# The reason has to survive the process that died with it, or the operator gets
# "no reason recorded" while the real one scrolled past on stderr.
case "$out" in
    *"late pre-mutation refusal for b"*) ok "E1: ...and its reason survives the process that carried it" ;;
    *) bad "E1: ...and its reason survives the process that carried it" "$out" ;;
esac
case "$rc" in
    1) ok "E1: ...and the relation reports an ordinary failure" ;;
    *) bad "E1: ...and the relation reports an ordinary failure" "rc=$rc" "$out" ;;
esac

# E2 -- an exit AFTER the destruction began must NOT be demoted to untouched.
# `die` carries exit 1 and no idea of what it had already done; the flag does.
printf 'a=0
b=die2
c=0
' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"; rc=$?
case "$out" in
    *"CHANGED  b"*) ok "E2: an exit after the first mutation is still CHANGED, not untouched" ;;
    *) bad "E2: an exit after the first mutation is still CHANGED, not untouched" "$out" ;;
esac
case "$rc" in
    2) ok "E2: ...and it still outranks an ordinary failure" ;;
    *) bad "E2: ...and it still outranks an ordinary failure" "rc=$rc" "$out" ;;
esac
case "$out" in
    *"exec: c"*) ok "E2: ...while the rest of the scope still ran" ;;
    *) bad "E2: ...while the rest of the scope still ran" "$out" ;;
esac

# E3 -- THE ISOLATION BOUNDARY MUST NOT RE-EXPORT WHAT IT INHERITED.
# restore_one appends to RESTORE_ROLLED_BACK, the boundary carries that array out
# and the parent appends what it gets. A subshell inherits the parent's copy, so
# without emptying it first every dataset hands back everything the ones before
# it added: three datasets produce six entries, not three.
#
# Measured on the lab, 2026-08-31: a three-dataset rewind printed the first
# dataset's entry three times under "what this costs the backup" -- a report an
# operator has to act on, listing snapshots that are named more than once.
printf 'a=0
b=0
c=0
' > "$RP/pf"
printf 'a=0
b=0
c=0
' > "$RP/ex"
out="$(run_policy "$RP/pf" "$RP/ex" a b c)"
n="$(printf '%s
' "$out" | grep -c 'rolled-entry:')"
if [ "$n" -eq 3 ]; then ok "E3: three datasets record THREE entries, not six"
else bad "E3: three datasets record THREE entries, not six" "got $n" "$out"; fi

if [ "${_rp_standalone:-0}" = 1 ]; then
    echo "--------------------------------------------"
    echo "PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ]
fi
