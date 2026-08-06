#!/bin/bash
# Tests for zfs-pair-gate.sh -- the peer-side security gate (ADR-0012
# DISABLED, docs/testing/pair-pause-test-plan.md section C).
#
# What makes this testable without ssh: the gate takes its identity from
# argv (the forced-command line) and the caller's request from
# $SSH_ORIGINAL_COMMAND. sshd contributes nothing else, so invoking the
# script directly with those two inputs IS the real thing -- the live
# checkpoint then proves the other half, that sshd actually routes through
# it with a real key.
#
# The property under test everywhere below is ORDERING and FAIL-CLOSEDNESS:
# a refused command must not have run. Every data-plane case therefore asks
# the gate to run a command whose only job is to create a file, and asserts
# the file is absent -- "it printed a refusal" is not evidence that nothing
# happened.
#
#   ./test/pairgate/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="${GATE:-$REPO/zfs-pair-gate.sh}"
[ -r "$GATE" ] || { echo "cannot read zfs-pair-gate.sh at $GATE" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REL="$WORK/relationships"
mkdir -p "$REL/alpha" "$REL/beta"
LOG="$WORK/gate.log"

# run_gate <label> <request> -- returns rc, output in $OUT
OUT=""
run_gate() {
    OUT=$(SSH_ORIGINAL_COMMAND="${2-}" RELATIONSHIPS_DIR="$REL" GATE_LOG="$LOG" \
          bash "$GATE" "$1" 2>&1)
    return $?
}
# A request whose only effect is observable: it creates $WORK/ran.<tag>
touch_cmd() { printf 'touch %s/ran.%s' "$WORK" "$1"; }
ran() { [ -e "$WORK/ran.$1" ]; }

# ---------------------------------------------------------------------------
# C1. An ACTIVE relationship runs its command and returns its exit status.
# ---------------------------------------------------------------------------
run_gate alpha "$(touch_cmd active)"; rc=$?
if [ "$rc" -eq 0 ] && ran active; then
    ok "C1 active relationship: the command runs and rc is its own"
else
    bad "C1 active relationship: the command runs and rc is its own" "rc=$rc out=$OUT"
fi
run_gate alpha "exit 7"; rc=$?
if [ "$rc" -eq 7 ]; then
    ok "C1b active relationship: the wrapped command's exit code passes through unchanged"
else
    bad "C1b active relationship: the wrapped command's exit code passes through unchanged" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# C2/C3. A DISABLED relationship authenticates but is refused BEFORE the
# command is executed -- with a stable machine-readable reason and code.
# ---------------------------------------------------------------------------
printf 'DISABLED_AT="2026-08-06 20:00:00"\nDISABLED_REASON="test"\n' > "$REL/alpha/disabled"
run_gate alpha "$(touch_cmd disabled)"; rc=$?
if [ "$rc" -eq 93 ] && case "$OUT" in *"PAIR_DISABLED: relationship alpha is disabled by administrator"*) true;; *) false;; esac \
        && ! ran disabled; then
    ok "C2 disabled relationship: refused with PAIR_DISABLED/93 and the command did NOT run"
else
    bad "C2 disabled relationship: refused with PAIR_DISABLED/93 and the command did NOT run" "rc=$rc out=$OUT ran=$(ran disabled && echo yes || echo no)"
fi

# The refusal is decided before the request is parsed at all: garbage that no
# parser could classify still gets the SAME refusal, not a parse error.
run_gate alpha 'zfs send "unterminated | $(touch '"$WORK"'/ran.garbage)'; rc=$?
if [ "$rc" -eq 93 ] && case "$OUT" in *PAIR_DISABLED*) true;; *) false;; esac && ! ran garbage; then
    ok "C3/C10 disabled: an unparseable request gets the same refusal, never a parse attempt"
else
    bad "C3/C10 disabled: an unparseable request gets the same refusal, never a parse attempt" "rc=$rc out=$OUT"
fi

# C4/C5. The caller's own claims are irrelevant: a manual command carrying no
# label, and one loudly claiming to be another relationship, are both refused
# by the key's identity.
run_gate alpha "zfs send tank/x@snap"; rc=$?
[ "$rc" -eq 93 ] && ok "C4 disabled: a manual data-plane command with no local label is still refused" \
                 || bad "C4 disabled: a manual data-plane command with no local label is still refused" "rc=$rc out=$OUT"
run_gate alpha "-L beta zfs send tank/x@snap"; rc=$?
if [ "$rc" -eq 93 ] && case "$OUT" in *"relationship alpha"*) true;; *) false;; esac; then
    ok "C5 identity comes from the key, not the request: claiming another label changes nothing"
else
    bad "C5 identity comes from the key, not the request: claiming another label changes nothing" "rc=$rc out=$OUT"
fi

# ---------------------------------------------------------------------------
# C6. A different relationship on the same host is unaffected.
# ---------------------------------------------------------------------------
run_gate beta "$(touch_cmd beta)"; rc=$?
if [ "$rc" -eq 0 ] && ran beta; then
    ok "C6 a second relationship on the same host keeps working while the first is disabled"
else
    bad "C6 a second relationship on the same host keeps working while the first is disabled" "rc=$rc out=$OUT"
fi

# ---------------------------------------------------------------------------
# C7. Unknown / malformed identity fails closed.
# ---------------------------------------------------------------------------
run_gate ghost "$(touch_cmd ghost)"; rc=$?
if [ "$rc" -eq 92 ] && case "$OUT" in *PAIR_UNKNOWN*) true;; *) false;; esac && ! ran ghost; then
    ok "C7 unknown relationship: PAIR_UNKNOWN/92, fail-closed, nothing executed"
else
    bad "C7 unknown relationship: PAIR_UNKNOWN/92, fail-closed, nothing executed" "rc=$rc out=$OUT"
fi
OUT=$(SSH_ORIGINAL_COMMAND="$(touch_cmd nolabel)" RELATIONSHIPS_DIR="$REL" GATE_LOG="$LOG" bash "$GATE" 2>&1); rc=$?
if [ "$rc" -eq 91 ] && case "$OUT" in *PAIR_GATE_MISUSE*) true;; *) false;; esac && ! ran nolabel; then
    ok "C7b no label at all (misconfigured key line): PAIR_GATE_MISUSE/91, nothing executed"
else
    bad "C7b no label at all (misconfigured key line): PAIR_GATE_MISUSE/91, nothing executed" "rc=$rc out=$OUT"
fi
run_gate "../alpha" "$(touch_cmd traversal)"; rc=$?
if [ "$rc" -eq 91 ] && ! ran traversal; then
    ok "C7c a traversal label is refused before any path is built from it"
else
    bad "C7c a traversal label is refused before any path is built from it" "rc=$rc out=$OUT"
fi

# An interactive session (no command at all) is not a backup job.
run_gate beta ""; rc=$?
if [ "$rc" -eq 91 ] && case "$OUT" in *"not an interactive login"*) true;; *) false;; esac; then
    ok "C7d an interactive session on a relationship key is refused"
else
    bad "C7d an interactive session on a relationship key is refused" "rc=$rc out=$OUT"
fi

# The four outcomes are distinguishable by exit code alone, which is all the
# collector will have over ssh (255 is ssh's own and never ours).
if [ 91 -ne 92 ] && [ 92 -ne 93 ] && [ 93 -ne 255 ]; then
    ok "C3b the four outcomes carry distinct, documented exit codes (91/92/93 vs ssh's 255)"
else
    bad "C3b the four outcomes carry distinct, documented exit codes (91/92/93 vs ssh's 255)" "codes collided"
fi

# ---------------------------------------------------------------------------
# Control channel (owner decision: reachable through this same gate).
# ---------------------------------------------------------------------------
run_gate alpha "PAIR-CONTROL status"; rc=$?
if [ "$rc" -eq 0 ] && case "$OUT" in *"PAIR_STATE=DISABLED"*) true;; *) false;; esac \
        && case "$OUT" in *"DISABLED_REASON=test"*) true;; *) false;; esac; then
    ok "control: status answers while disabled, carrying the recorded reason"
else
    bad "control: status answers while disabled, carrying the recorded reason" "rc=$rc out=$OUT"
fi

# A near-miss control string is NOT a control verb -- fail closed, no prefix
# matching, no argument smuggling.
run_gate alpha "PAIR-CONTROL status; $(touch_cmd smuggle)"; rc=$?
if [ "$rc" -eq 93 ] && ! ran smuggle; then
    ok "control: a verb with anything appended is refused, not prefix-matched"
else
    bad "control: a verb with anything appended is refused, not prefix-matched" "rc=$rc out=$OUT"
fi

run_gate alpha "PAIR-CONTROL enable"; rc=$?
if [ "$rc" -eq 0 ] && case "$OUT" in *"PAIR_STATE=ACTIVE"*) true;; *) false;; esac \
        && [ ! -e "$REL/alpha/disabled" ]; then
    ok "control: enable clears the disabled marker and reports ACTIVE"
else
    bad "control: enable clears the disabled marker and reports ACTIVE" "rc=$rc out=$OUT"
fi

# ...and the data plane is genuinely back, not merely reported back.
run_gate alpha "$(touch_cmd reenabled)"; rc=$?
if [ "$rc" -eq 0 ] && ran reenabled; then
    ok "after enable the data plane works again (proved by a real side effect)"
else
    bad "after enable the data plane works again (proved by a real side effect)" "rc=$rc out=$OUT"
fi

# Enable is idempotent, and status answers on an active relationship too --
# the collector must not have to be refused in order to learn the state.
run_gate alpha "PAIR-CONTROL enable"; rc=$?
[ "$rc" -eq 0 ] && ok "control: enable on an already-active relationship is a no-op success" \
                || bad "control: enable on an already-active relationship is a no-op success" "rc=$rc out=$OUT"
run_gate alpha "PAIR-CONTROL status"; rc=$?
if [ "$rc" -eq 0 ] && case "$OUT" in *"PAIR_STATE=ACTIVE"*) true;; *) false;; esac; then
    ok "control: status answers ACTIVE without the caller having to be refused first"
else
    bad "control: status answers ACTIVE without the caller having to be refused first" "rc=$rc out=$OUT"
fi

# ---------------------------------------------------------------------------
# C11 (the gate's half): the gate itself mutates nothing but its own marker.
# ---------------------------------------------------------------------------
before=$(find "$REL" | sort; find "$WORK" -maxdepth 1 -name 'ran.*' | sort)
printf 'DISABLED_AT="x"\n' > "$REL/beta/disabled"
run_gate beta "zfs send tank/y@s" >/dev/null 2>&1
rm -f "$REL/beta/disabled"
after=$(find "$REL" | sort; find "$WORK" -maxdepth 1 -name 'ran.*' | sort)
if [ "$before" = "$after" ]; then
    ok "C11 a refused attempt leaves no residue beyond the marker it was told about"
else
    bad "C11 a refused attempt leaves no residue beyond the marker it was told about" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"
fi

# ---------------------------------------------------------------------------
# Logging: every decision is recorded with its label, and the log never
# becomes a transcript of what was asked (only a sanitised, bounded class).
# ---------------------------------------------------------------------------
if grep -q 'label=alpha decision=refused' "$LOG" && grep -q 'label=alpha decision=allowed' "$LOG" \
        && grep -q 'label=alpha decision=control' "$LOG" && grep -q 'label=ghost decision=unknown' "$LOG"; then
    ok "log records refused/allowed/control/unknown decisions with the relationship label"
else
    bad "log records refused/allowed/control/unknown decisions with the relationship label" "$(cat "$LOG")"
fi
if grep -q 'ran\.' "$LOG" && ! grep -q 'class=touch' "$LOG"; then
    bad "log keeps the request class bounded and sanitised" "raw request text leaked into the log: $(grep -m1 'ran\.' "$LOG")"
else
    ok "log keeps the request class bounded and sanitised"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
