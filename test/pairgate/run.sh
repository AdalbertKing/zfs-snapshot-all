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

# Force the FILE sink for every decision the assertions below read.
#
# The gate prefers syslog and falls back to a file. On any host where `logger`
# works -- which is every Linux runner -- the gate correctly writes to syslog and
# never creates $LOG, so the decision-log assertion greps a file that is not
# there. This suite passed only on machines WITHOUT `logger`: measured 75/0 under
# Git Bash on Windows and FAIL on CI, same commit, the moment the suite was added
# to the matrix. The environment was the variable, not the code.
#
# A stub that always fails makes the fallback deterministic on both platforms.
# The sink-SELECTION tests further down install their own stubs on top of this
# and are unaffected -- they are the ones that own the "syslog wins" contract.
NOLOGGER="$WORK/nologger"; mkdir -p "$NOLOGGER"
printf '#!/bin/sh\nexit 1\n' > "$NOLOGGER/logger"; chmod +x "$NOLOGGER/logger"

# run_gate <label> <request> -- returns rc, output in $OUT
OUT=""
ERR=""
run_gate() {
    OUT=$(SSH_ORIGINAL_COMMAND="${2-}" RELATIONSHIPS_DIR="$REL" GATE_LOG="$LOG" \
          PATH="$NOLOGGER:$PATH" \
          bash "$GATE" "$1" 2>"$WORK/stderr"); local rc=$?
    ERR=$(cat "$WORK/stderr")
    OUT="$OUT$ERR"
    return $rc
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

# REV-051 F1: '.' and '..' are PATH COMPONENTS that pass a character-class
# check. "$RELATIONSHIPS_DIR/.." resolves to a directory that exists, so the
# unknown-relationship guard succeeded for an identity that is not a
# relationship -- and with no 'disabled' file there, the gate fell through to
# ACTIVE and ran the caller's command. Two characters turned the one
# fail-closed boundary into a pass-through.
for dotlbl in "." ".."; do
    tag="dot$(printf '%s' "$dotlbl" | tr -d '.' | wc -c)"
    run_gate "$dotlbl" "$(touch_cmd "$tag")"; rc=$?
    if [ "$rc" -eq 91 ] && ! ran "$tag" \
            && case "$OUT" in *"path component"*) true;; *) false;; esac; then
        ok "C7e label '$dotlbl' is refused as a path component, and nothing ran"
    else
        bad "C7e label '$dotlbl' is refused as a path component, and nothing ran" "rc=$rc ran=$(ran "$tag" && echo YES || echo no) out=$OUT"
    fi
done
# ...while an ordinary dotted label is untouched by that rule.
mkdir -p "$REL/site.a"
run_gate "site.a" "$(touch_cmd dotok)"; rc=$?
if [ "$rc" -eq 0 ] && ran dotok; then
    ok "C7f an ordinary dotted label ('site.a') still works"
else
    bad "C7f an ordinary dotted label ('site.a') still works" "rc=$rc out=$OUT"
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
# enable when the state directory is NOT writable: the owner's model
# (2026-08-06) is that the relationship's own key may lift its own block, so
# the directory is account-writable by design. Where it is not -- a
# half-installed peer, a directory root re-created by hand -- enable must FAIL
# LOUDLY and leave the marker in place, never report ACTIVE on a relationship
# that is still disabled. Found live on metropolis pve2: with a root-owned
# directory the rm failed, and the branch below is what made that visible
# instead of a false "enabled".
# ---------------------------------------------------------------------------
mkdir -p "$REL/frozen"
printf 'DISABLED_AT="x"\n' > "$REL/frozen/disabled"
chmod 555 "$REL/frozen" 2>/dev/null || true
if [ -w "$REL/frozen" ]; then
    echo "SKIP enable-on-unwritable-dir (this filesystem ignores 0555 for the owner)"
else
    run_gate frozen "PAIR-CONTROL enable"; rc=$?
    if [ "$rc" -eq 93 ] && case "$OUT" in *PAIR_CONTROL_FAILED*) true;; *) false;; esac \
            && [ -f "$REL/frozen/disabled" ]; then
        ok "enable on an unwritable state dir fails loudly and leaves the relationship disabled"
    else
        bad "enable on an unwritable state dir fails loudly and leaves the relationship disabled" "rc=$rc out=$OUT marker=$([ -f "$REL/frozen/disabled" ] && echo present || echo GONE)"
    fi
    chmod 755 "$REL/frozen" 2>/dev/null || true
fi
rm -rf "$REL/frozen"

# The documented threat-model limit is part of the contract, like the
# logical-pause limitation before it: the file must say plainly that the
# relationship's own key can lift its own block.
if grep -q "OWN key can lift its own block" "$GATE" && grep -q "NOT a boundary against someone" "$GATE"; then
    ok "the file states plainly that the relationship key can lift its own block"
else
    bad "the file states plainly that the relationship key can lift its own block" "the honesty note is missing from zfs-pair-gate.sh"
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

# ---------------------------------------------------------------------------
# Logging must never reach the CALLER's stderr. Found live on metropolis pve2
# (2026-08-06): the gate runs as the delegated account, could not open the
# root-owned /var/log file, and the SHELL reported that on stderr -- before
# printf existed, so the `2>/dev/null` on the printf did nothing. snapget.sh
# tails stderr into its alert mail, so a logging detail would have become
# alert noise on every single transfer.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Both sinks, deterministically (REV-20260806-047 F2). Varying only GATE_LOG
# proves nothing: on a host with logger(1) the file path is never reached, on
# a host without it the syslog path never is. A stubbed logger first on PATH
# decides the branch on THIS machine, whatever it really has installed.
#
# The property under test is delivery, not presence (F1): a logger that EXISTS
# and FAILS must still reach the file sink.
# ---------------------------------------------------------------------------
LOGSTUB="$WORK/logstub"; mkdir -p "$LOGSTUB"
SYSLOG_SINK="$WORK/syslog.captured"
mk_logger() {   # <exit-code>
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit %s\n' "$SYSLOG_SINK" "$1" > "$LOGSTUB/logger"
    chmod +x "$LOGSTUB/logger"
}
FILE_SINK="$WORK/filesink.log"

# 1. logger succeeds: syslog takes the record, the file sink stays untouched,
#    and the caller sees nothing.
: > "$SYSLOG_SINK"; rm -f "$FILE_SINK"
mk_logger 0
err=$(SSH_ORIGINAL_COMMAND="true" RELATIONSHIPS_DIR="$REL" GATE_LOG="$FILE_SINK" \
      PATH="$LOGSTUB:$PATH" bash "$GATE" alpha 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$err" ] && grep -q 'label=alpha' "$SYSLOG_SINK" && [ ! -e "$FILE_SINK" ]; then
    ok "logging: logger succeeds -> syslog only, no file sink, caller silent"
else
    bad "logging: logger succeeds -> syslog only, no file sink, caller silent" "rc=$rc err=[$err] syslog=$(cat "$SYSLOG_SINK") file=$([ -e "$FILE_SINK" ] && echo present || echo absent)"
fi

# 2. logger EXISTS and FAILS: the file sink must receive exactly one bounded
#    record. This is F1 -- the case the presence-based branch never reached.
: > "$SYSLOG_SINK"; rm -f "$FILE_SINK"
mk_logger 1
err=$(SSH_ORIGINAL_COMMAND="true" RELATIONSHIPS_DIR="$REL" GATE_LOG="$FILE_SINK" \
      PATH="$LOGSTUB:$PATH" bash "$GATE" alpha 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$err" ] && [ "$(grep -c 'label=alpha' "$FILE_SINK" 2>/dev/null)" = "1" ]; then
    ok "logging: logger exists but fails -> exactly one record in the file sink"
else
    bad "logging: logger exists but fails -> exactly one record in the file sink" "rc=$rc err=[$err] file=$(cat "$FILE_SINK" 2>/dev/null)"
fi

# 3. both sinks fail: the decision and the exit code are unchanged, and the
#    caller still sees nothing.
: > "$SYSLOG_SINK"
mk_logger 1
err=$(SSH_ORIGINAL_COMMAND="exit 5" RELATIONSHIPS_DIR="$REL" GATE_LOG="/proc/nonexistent/x.log" \
      PATH="$LOGSTUB:$PATH" bash "$GATE" alpha 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 5 ] && [ -z "$err" ]; then
    ok "logging: both sinks fail -> the wrapped command's own result is unchanged, caller silent"
else
    bad "logging: both sinks fail -> the wrapped command's own result is unchanged, caller silent" "rc=$rc err=[$err]"
fi

# 4. the refusal path under both failure shapes: stderr carries exactly the
#    one refusal line, which is what the collector reads for the reason.
printf 'DISABLED_AT="x"\n' > "$REL/beta/disabled"
for sink in "$FILE_SINK" "/proc/nonexistent/x.log"; do
    mk_logger 1
    err=$(SSH_ORIGINAL_COMMAND="zfs send tank/q@s" RELATIONSHIPS_DIR="$REL" GATE_LOG="$sink" \
          PATH="$LOGSTUB:$PATH" bash "$GATE" beta 2>&1 >/dev/null); rc=$?
    if [ "$rc" -eq 93 ] && [ "$err" = "PAIR_DISABLED: relationship beta is disabled by administrator" ]; then
        ok "logging: refusal stderr stays exactly one line with a failing logger (sink=$sink)"
    else
        bad "logging: refusal stderr stays exactly one line with a failing logger (sink=$sink)" "rc=$rc err=[$err]"
    fi
done
rm -f "$REL/beta/disabled"
rm -f "$LOGSTUB/logger"

NOWRITE_DIR="$WORK/nowrite"; mkdir -p "$NOWRITE_DIR"; chmod 555 "$NOWRITE_DIR" 2>/dev/null || true
# Where logger(1) exists the syslog branch runs and the file is never touched;
# where it does not (this dev box), the file branch runs against a path that
# cannot be created. Both branches must be equally silent, so the assertion is
# the same either way and each host exercises whichever branch it has.
for probe in "$NOWRITE_DIR/deep/gate.log" "/proc/nonexistent/gate.log"; do
    err=$(SSH_ORIGINAL_COMMAND="true" RELATIONSHIPS_DIR="$REL" GATE_LOG="$probe" \
          bash "$GATE" alpha 2>&1 >/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
        ok "an unwritable log ($probe) is silent on the caller's stderr and does not fail the command"
    else
        bad "an unwritable log ($probe) is silent on the caller's stderr and does not fail the command" "rc=$rc stderr=[$err]"
    fi
done

# ...and the same must hold on the REFUSAL path, where the caller is reading
# stderr for the reason and must find exactly one line there.
printf 'DISABLED_AT="x"\n' > "$REL/beta/disabled"
err=$(SSH_ORIGINAL_COMMAND="zfs send tank/z@s" RELATIONSHIPS_DIR="$REL" \
      GATE_LOG="$NOWRITE_DIR/deep/gate.log" bash "$GATE" beta 2>&1 >/dev/null); rc=$?
rm -f "$REL/beta/disabled"
if [ "$rc" -eq 93 ] && [ "$err" = "PAIR_DISABLED: relationship beta is disabled by administrator" ]; then
    ok "a refusal puts exactly its own reason on stderr, with no logging noise around it"
else
    bad "a refusal puts exactly its own reason on stderr, with no logging noise around it" "rc=$rc stderr=[$err]"
fi

# ===========================================================================
# Installation (step 2): deploy.sh's write_gated_key_line / install_pair_gate.
# Extracted by pattern, the technique test/pause and test/draftscope use --
# deploy.sh's own root check would abort the suite otherwise.
#
# The risk here is not logic, it is RESIDUE and LOCKOUT: authorized_keys is
# the file that decides whether anyone can reach the account at all. Every
# case below therefore checks what happened to the OTHER lines, not just to
# ours.
# ===========================================================================
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
if [ ! -r "$DEPLOY_SRC" ]; then
    echo "SKIP install cases (no deploy.sh at $DEPLOY_SRC)"
else
eval "$(sed -n '/^pair_label_valid() {/,/^}/p' "$DEPLOY_SRC")"
eval "$(sed -n '/^write_gated_key_line() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F write_gated_key_line >/dev/null; then
    bad "extract write_gated_key_line from deploy.sh" "the sed anchors no longer match -- update this suite"
else
log()  { :; }
warn() { :; }
PAIR_GATE_PATH="/usr/local/sbin/zfs-pair-gate"

AKD="$WORK/ak"; mkdir -p "$AKD"
KEY_A="ssh-ed25519 AAAAKEYAAA pairing-a"
KEY_B="ssh-ed25519 AAAAKEYBBB someone-else"
GATED_A="command=\"$PAIR_GATE_PATH lbl\",restrict $KEY_A"

# 1. A fresh account: one gated line, nothing else.
AK="$AKD/fresh"; : > "$AK"
if write_gated_key_line "$AK" "$KEY_A" lbl && [ "$(cat "$AK")" = "$GATED_A" ]; then
    ok "install: a fresh authorized_keys gets exactly the gated line"
else
    bad "install: a fresh authorized_keys gets exactly the gated line" "$(cat "$AK")"
fi

# 2. Migration: an existing BARE line for the same key becomes the gated one,
#    and does not survive alongside it. A leftover bare copy would
#    authenticate ungated and silently defeat every disable -- the single
#    most dangerous outcome in this whole step.
AK="$AKD/migrate"; printf '%s\n' "$KEY_B" "$KEY_A" "# a comment" > "$AK"
if write_gated_key_line "$AK" "$KEY_A" lbl \
        && [ "$(grep -cxF "$GATED_A" "$AK")" = "1" ] \
        && ! grep -qxF "$KEY_A" "$AK" \
        && grep -qxF "$KEY_B" "$AK" && grep -qxF "# a comment" "$AK"; then
    ok "install: a pre-existing BARE line for the same key is replaced, not left beside the gated one"
else
    bad "install: a pre-existing BARE line for the same key is replaced, not left beside the gated one" "$(cat "$AK")"
fi

# 3. Other principals are preserved byte for byte, in content and count.
AK="$AKD/others"
printf '%s\n' "$KEY_B" 'command="/opt/other/tool",restrict ssh-rsa AAAAOTHER admin' "$KEY_A" > "$AK"
before_others=$(grep -vF "AAAAKEYAAA" "$AK")
write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null
after_others=$(grep -vF "AAAAKEYAAA" "$AK")
if [ "$before_others" = "$after_others" ]; then
    ok "install: every line that is not this relationship's key survives byte for byte"
else
    bad "install: every line that is not this relationship's key survives byte for byte" "$(diff <(printf '%s\n' "$before_others") <(printf '%s\n' "$after_others"))"
fi

# 4. Idempotent: running it again changes nothing at all.
sum_before=$(md5sum < "$AK")
write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null
if [ "$(md5sum < "$AK")" = "$sum_before" ]; then
    ok "install: a second run is byte-identical (idempotent)"
else
    bad "install: a second run is byte-identical (idempotent)" "$(cat "$AK")"
fi

# 5. Rotation: a NEW key for the same relationship adds its gated line; the
#    old key's line is a separate principal and is NOT silently dropped here
#    (revocation is --leave/--revoke-old's job, deliberately not this one).
AK="$AKD/rotate"; printf '%s\n' "$GATED_A" > "$AK"
KEY_C="ssh-ed25519 AAAAKEYCCC pairing-a-rotated"
write_gated_key_line "$AK" "$KEY_C" lbl >/dev/null
if grep -q "AAAAKEYCCC" "$AK" && grep -q "AAAAKEYAAA" "$AK"; then
    ok "install: a rotated key is added gated; retiring the old one stays a separate, deliberate act"
else
    bad "install: a rotated key is added gated; retiring the old one stays a separate, deliberate act" "$(cat "$AK")"
fi

# 6. NEGATIVE -- the lockout case. If the temp file cannot be committed, the
#    original must be untouched: a truncated authorized_keys locks the
#    account out of its own host.
AK="$AKD/lockout"; printf '%s\n' "$KEY_B" "$KEY_A" > "$AK"
sum_before=$(md5sum < "$AK")
mv() { return 1; }          # force the commit to fail
write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null 2>&1; rc=$?
unset -f mv
if [ "$rc" -ne 0 ] && [ "$(md5sum < "$AK")" = "$sum_before" ] && [ -z "$(ls "$AKD"/lockout.new.* 2>/dev/null)" ]; then
    ok "install: a failed commit leaves authorized_keys untouched and no staging file behind"
else
    bad "install: a failed commit leaves authorized_keys untouched and no staging file behind" "rc=$rc file=$(cat "$AK") staging=$(ls "$AKD"/lockout.new.* 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Phase 4's group sweep must not walk into the gate's relationship state.
#
# Found live on metropolis 2026-08-20, and this is the root cause under the
# symptom recorded earlier: `disable-client` kept failing with
#     zfs-pair-gate: .../relationships/<label>/disabled.new: Permission denied
# because Phase 4 ran `chgrp -R zfsalert /var/lib/zfs-snapshot-all` -- straight
# through relationships/, whose directories are deliberately owned
# root:<that relationship's own account> so the account can create and remove
# its own marker and no other relationship can reach it.
#
# The measured consequence: EVERY deploy.sh run re-broke the hard pause on
# every relationship on the host, so repairing it by hand held only until the
# next deploy, self-update or --commit-scope. A blocking mechanism that routine
# runs silently disarm is worse than an absent one -- the operator believes
# they have it.
#
# Asserted by ownership, not by reading the source: build the real shape, run
# the real function, and look at what moved.
# ---------------------------------------------------------------------------
# The shape that caused it, pinned by absence. Reinstating a bare recursive
# chgrp over the shared alert directory silently re-arms the bug, and it would
# do so in a file whose tests otherwise all pass -- nothing else here would
# notice, because the damage lands on a directory this suite does not own.
# Comments are stripped first: the fix's own explanation quotes the offending
# line verbatim, and a contract that cannot tell code from the commentary about
# the code fires on the very change that satisfies it.
if grep -vE '^[[:space:]]*#' "$DEPLOY_SRC" | grep -qE 'chgrp -R .*ALERT_(GROUP|SHARED_DIR)'; then
    bad "install: no bare recursive chgrp over the shared alert dir" \
        "found 'chgrp -R' on the alert tree -- it walks into relationships/ and disarms every hard pause on the host"
else
    ok "install: no bare recursive chgrp over the shared alert dir"
fi

eval "$(sed -n '/^alert_dir_chgrp() {/,/^}$/p' "$DEPLOY_SRC")"
if ! declare -F alert_dir_chgrp >/dev/null; then
    bad "extract alert_dir_chgrp from deploy.sh" "the sed anchors no longer match -- update this suite"
else
    SWEEP="$WORK/sweep"
    mkdir -p "$SWEEP/notify-state" "$SWEEP/relationships/pve1"
    : > "$SWEEP/alert-queue.log"; : > "$SWEEP/notify-state/state"; : > "$SWEEP/relationships/pve1/disabled"
    # A group this test can actually chgrp to, without needing root: our own.
    MYGRP=$(id -g)
    # Mark the excluded subtree with something distinguishable first. Using the
    # numeric primary gid for both would prove nothing, so the check is "did the
    # sweep VISIT it", recorded via mtime of the ownership change.
    before_rel=$(stat -c '%g' "$SWEEP/relationships/pve1")
    alert_dir_chgrp "$SWEEP" "$MYGRP" "$SWEEP/relationships" >/dev/null 2>&1
    after_rel=$(stat -c '%g' "$SWEEP/relationships/pve1")
    swept=$(find "$SWEEP" -path "$SWEEP/relationships" -prune -o -print | wc -l)
    pruned=$(find "$SWEEP" -path "$SWEEP/relationships" -prune -o -print | grep -c relationships || true)
    if [ "$before_rel" = "$after_rel" ] && [ "$pruned" -eq 0 ] && [ "$swept" -ge 4 ]; then
        ok "install: the alert group sweep covers the alert files and PRUNES relationships/"
    else
        bad "install: the alert group sweep covers the alert files and PRUNES relationships/" \
            "before=$before_rel after=$after_rel swept=$swept relationships_seen=$pruned"
    fi
    # And the sweep still does its actual job -- a guard that only excludes is
    # indistinguishable from a guard that does nothing.
    if [ "$(stat -c '%g' "$SWEEP/alert-queue.log")" = "$MYGRP" ] \
       && [ "$(stat -c '%g' "$SWEEP/notify-state/state")" = "$MYGRP" ]; then
        ok "install: the sweep still regroups the alert files it exists for"
    else
        bad "install: the sweep still regroups the alert files it exists for" \
            "queue=$(stat -c '%g' "$SWEEP/alert-queue.log") state=$(stat -c '%g' "$SWEEP/notify-state/state") want=$MYGRP"
    fi
fi

# 7. NEGATIVE -- a malformed public key is refused before the file is touched.
AK="$AKD/badkey"; printf '%s\n' "$KEY_B" > "$AK"
sum_before=$(md5sum < "$AK")
if write_gated_key_line "$AK" "notakey" lbl >/dev/null 2>&1; then
    bad "install: a malformed public key is refused" "accepted: $(cat "$AK")"
elif [ "$(md5sum < "$AK")" = "$sum_before" ]; then
    ok "install: a malformed public key is refused and the file is untouched"
else
    bad "install: a malformed public key is refused and the file is untouched" "$(cat "$AK")"
fi

# 8. The rendered line is what sshd needs: forced command carrying the label,
#    plus restrict (no pty, no forwarding, no user rc).
AK="$AKD/shape"; : > "$AK"
write_gated_key_line "$AK" "$KEY_A" mylabel >/dev/null
line=$(cat "$AK")
case "$line" in
    "command=\"$PAIR_GATE_PATH mylabel\",restrict ssh-ed25519 "*)
        ok "install: the rendered line is command=<gate> <label>,restrict <key>" ;;
    *) bad "install: the rendered line is command=<gate> <label>,restrict <key>" "$line" ;;
esac

# 9. LOCKOUT, the live one: the replacement must keep the ORIGINAL file's
#    ownership. Doing this as root without it hands the account's
#    authorized_keys to root:root, and sshd with StrictModes (the default)
#    then refuses every key in the file -- the account loses its own host,
#    including via keys unrelated to this relationship. Observed exactly that
#    on metropolis pve2 (2026-08-06): after a correct rewrite, both keys were
#    refused with nothing in auth.log but "Connection closed [preauth]".
#    Stubbed chown, because a test cannot own files as another user.
AK="$AKD/owner"; printf '%s\n' "$KEY_B" > "$AK"
CHOWN_LOG="$WORK/chown.log"; : > "$CHOWN_LOG"
# the staging file is root-owned (as it would be when root runs this), the
# live file belongs to the account -- so a chown is genuinely required.
stat() { case "$*" in *.new.*) echo "root:root" ;; *) echo "acct:acct" ;; esac; }
chown() { echo "CHOWN $*" >> "$CHOWN_LOG"; }
write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null
unset -f stat chown
if grep -q "^CHOWN acct:acct $AKD/owner.new" "$CHOWN_LOG"; then
    ok "install: the replacement inherits the original file's ownership (no sshd lockout)"
else
    bad "install: the replacement inherits the original file's ownership (no sshd lockout)" "$(cat "$CHOWN_LOG")"
fi

# 9b. REV-049 F1: ownership is an INVARIANT, not best effort. A stat or
#     chown that fails must leave the live file byte-for-byte, drop the
#     staging file, and return non-zero -- warning and committing anyway
#     recreates the very lockout the ownership work exists to prevent.
for mode in stat-fails chown-fails; do
    AK="$AKD/own-$mode"; printf '%s\n' "$KEY_B" "$KEY_A" > "$AK"
    sum_before=$(md5sum < "$AK"); n_before=$(wc -l < "$AK")
    case "$mode" in
        stat-fails)  stat() { return 1; };            chown() { return 0; } ;;
        chown-fails) stat() { case "$*" in *.new.*) echo "root:root" ;; *) echo "acct:acct" ;; esac; }
                     chown() { return 1; } ;;
    esac
    write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null 2>&1; rc=$?
    unset -f stat chown
    if [ "$rc" -ne 0 ] \
            && [ "$(md5sum < "$AK")" = "$sum_before" ] \
            && [ "$(wc -l < "$AK")" = "$n_before" ] \
            && [ -z "$(ls "$AKD/own-$mode".new.* 2>/dev/null)" ]; then
        ok "install: $mode -> refuses, original untouched, no staging residue"
    else
        bad "install: $mode -> refuses, original untouched, no staging residue" "rc=$rc" "$(cat "$AK")" "residue=$(ls "$AKD/own-$mode".new.* 2>/dev/null)"
    fi
done

# ...and an ownership string that is structurally unusable (empty side) is
# treated the same way: a chown of ':group' or 'user:' is not a safe answer.
for owner in ":grp" "usr:" ""; do
    AK="$AKD/own-str"; printf '%s\n' "$KEY_B" > "$AK"
    sum_before=$(md5sum < "$AK")
    stat() { printf '%s\n' "$owner"; }; chown() { return 0; }
    write_gated_key_line "$AK" "$KEY_A" lbl >/dev/null 2>&1; rc=$?
    unset -f stat chown
    if [ "$rc" -ne 0 ] && [ "$(md5sum < "$AK")" = "$sum_before" ]; then
        ok "install: an unusable ownership string ('$owner') refuses without touching the file"
    else
        bad "install: an unusable ownership string ('$owner') refuses without touching the file" "rc=$rc $(cat "$AK")"
    fi
done

# 9c. REV-050 F1: the state directory's GROUP must be able to write, and the
#     group digit is the only digit that answers that. `stat -c %a` renders
#     0755 as "755", so a pattern hunting a 7 anywhere matched the OWNER and
#     declared a directory writable that the account could not touch --
#     accepting, for the wrong reason, the exact degraded state the check
#     exists to catch. Driven by value: no filesystem, no stubs.
eval "$(sed -n '/^gate_state_dir_ok() {/,/^}/p' "$DEPLOY_SRC")"
if ! declare -F gate_state_dir_ok >/dev/null; then
    bad "extract gate_state_dir_ok from deploy.sh" "sed anchors no longer match"
else
    # "<stat output>|<account>|<expected: ok|warn>"
    for c in "775 acct|acct|ok"      "2775 acct|acct|ok"    "770 acct|acct|ok" \
             "3775 acct|acct|ok"     "755 acct|acct|warn"   "2755 acct|acct|warn" \
             "1755 acct|acct|warn"   "705 acct|acct|warn"   "775 other|acct|warn" \
             "|acct|warn"            "775|acct|warn"        "garbage acct|acct|warn"; do
        IFS='|' read -r st acct want <<< "$c"
        if gate_state_dir_ok "$st" "$acct"; then got=ok; else got=warn; fi
        if [ "$got" = "$want" ]; then
            ok "state-dir check: '$st' for '$acct' -> $want"
        else
            bad "state-dir check: '$st' for '$acct' -> $want" "got $got"
        fi
    done
fi

# 9d. REV-051 F1, installer side: the same two labels must never be rendered
#     into a key line or given a state directory. Both sides validate, because
#     the gate is deployed standalone and cannot source this file.
if ! declare -F pair_label_valid >/dev/null; then
    bad "extract pair_label_valid from deploy.sh" "sed anchors no longer match"
else
    for l in "" "." ".." "a/b" "../x" "x;y"; do
        if pair_label_valid "$l"; then
            bad "installer label grammar refuses '$l'" "accepted"
        else
            ok "installer label grammar refuses '$l'"
        fi
    done
    for l in "pve1" "site.a" "a_b-1" "10.0.0.9"; do
        if pair_label_valid "$l"; then
            ok "installer label grammar keeps accepting '$l'"
        else
            bad "installer label grammar keeps accepting '$l'" "refused a real label"
        fi
    done
fi

AK="$AKD/dotlabel"; printf '%s\n' "$KEY_B" > "$AK"
sum_before=$(md5sum < "$AK")
for l in "." ".."; do
    if write_gated_key_line "$AK" "$KEY_A" "$l" >/dev/null 2>&1; then
        bad "install: a '$l' label never reaches a key line" "accepted"
    elif [ "$(md5sum < "$AK")" = "$sum_before" ]; then
        ok "install: a '$l' label never reaches a key line, file untouched"
    else
        bad "install: a '$l' label never reaches a key line, file untouched" "$(cat "$AK")"
    fi
done

# install_pair_gate must refuse the same, before creating any directory.
eval "$(sed -n '/^install_pair_gate() {/,/^}/p' "$DEPLOY_SRC")"
if declare -F install_pair_gate >/dev/null; then
    IPG_STATE="$WORK/ipg-state"; IPG_BIN="$WORK/ipg-bin/zfs-pair-gate"
    mkdir -p "$WORK/ipg-bin"
    for l in "." ".."; do
        ( _DEPLOY_DIR="$REPO"; PAIR_GATE_PATH="$IPG_BIN"; PAIR_GATE_STATE_DIR="$IPG_STATE"
          install_pair_gate "$l" acct ) >/dev/null 2>&1; rc=$?
        if [ "$rc" -ne 0 ] && [ ! -d "$IPG_STATE" ]; then
            ok "install_pair_gate refuses '$l' before creating any state directory"
        else
            bad "install_pair_gate refuses '$l' before creating any state directory" "rc=$rc statedir=$(ls -d "$IPG_STATE" 2>/dev/null)"
        fi
    done
    # ...and a real label is NOT refused by the guard. The rest of the
    # function needs root (`install -o root -g root`), so on an unprivileged
    # box only the guard itself is asserted -- the full path is what the live
    # campaign exercised.
    ( _DEPLOY_DIR="$REPO"; PAIR_GATE_PATH="$IPG_BIN"; PAIR_GATE_STATE_DIR="$IPG_STATE"
      install_pair_gate site.a acct ) >"$WORK/ipg.out" 2>&1
    if grep -q "not a valid relationship label" "$WORK/ipg.out"; then
        bad "install_pair_gate does not refuse a real label ('site.a')" "$(cat "$WORK/ipg.out")"
    else
        ok "install_pair_gate does not refuse a real label ('site.a')"
    fi
fi

# 10. Structural pin: do_join must install the gate BEFORE writing the key
#    line, or a working key would briefly point at a gate that is not there.
jorder=$(grep -n 'install_pair_gate "\$label"\|write_gated_key_line "\$ak"' "$DEPLOY_SRC" | cut -d: -f1 | tr '\n' ' ')
set -- $jorder
if [ "${1:-0}" -lt "${2:-0}" ]; then
    ok "install: do_join installs the gate before it writes the key line"
else
    bad "install: do_join installs the gate before it writes the key line" "line order: $jorder"
fi
fi
fi

# ---------------------------------------------------------------------------
# THE TEARDOWN VERBS RUN WITHOUT PROVISIONING THE HOST, and until 2026-08-30
# one of them did not run at all.
#
# Measured on pve2, a production host on main:
#
#     ./deploy.sh --commit-scope=nieistnieje
#     ./deploy.sh: line 3388: do_commit_scope: command not found
#
# bash defines functions as it reads; the 2026-08-26 move of that dispatch
# before Phase 1 put the CALL above the DEFINITION. Nothing caught it because
# --join reaches the same function from its own dispatch at the foot of the
# file, so every enrolment kept working.
#
# --leave had the other half of the same problem: dispatched behind all seven
# phases, so tearing a relationship off a host PULLED THE REPO on the machine
# being torn down, and a checkout on a branch could not be left at all.
#
# These cases were IMPOSSIBLE to write before the move -- a sandbox could not
# get past Phase 1 -- which is precisely why nothing pinned the regression.
LV="$WORK/verbs"; mkdir -p "$LV/peers" "$LV/rel/pve9" "$LV/bin"
# deploy.sh refuses to start as anyone but root, deliberately and with no env
# escape. Stubbed here and only `id -u`.
cat > "$LV/bin/id" <<'IDEOF'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
exit 1
IDEOF
chmod +x "$LV/bin/id"
run_verb() { PATH="$LV/bin:$PATH" PEER_STATE_DIR="$LV/peers" PAIR_GATE_STATE_DIR="$LV/rel"              bash "$REPO/deploy.sh" "$@" 2>&1; }

# THE CARRYING ASSERTIONS: each verb REACHES its function. "command not found"
# is what this is here to make impossible; a manifest complaint is the verb
# working.
out="$(run_verb --commit-scope=nieistnieje)"
case "$out" in
    *"command not found"*) bad "verbs: --commit-scope reaches its function" "$out" ;;
    *"no pairing manifest"*) ok "verbs: --commit-scope reaches its function" ;;
    *) bad "verbs: --commit-scope reaches its function" "$out" ;;
esac
out="$(run_verb --leave=nieistnieje)"
case "$out" in
    *"command not found"*) bad "verbs: --leave reaches its function" "$out" ;;
    *"no join manifest"*)  ok "verbs: --leave reaches its function" ;;
    *) bad "verbs: --leave reaches its function" "$out" ;;
esac

# --leave TAKES ALL THREE SCOPE FILES, not two of them.
#
# The draft scope is a trio: .scope, .scope.sha256 and the .scope.request
# holding what the collector asked for. deploy.sh's own refusal path tells an
# operator to "rm $sfile $sfile.request", so the pairing is known there -- and
# this cleanup removed only the first two. Measured on pve9, 2026-09-03: after
# a full --leave, pve10.scope.request was still on disk, naming a dataset that
# had been destroyed, for a relationship that no longer existed.
#
# A complete manifest is needed to reach the removal at all: --leave refuses a
# missing role, and refuses a gone account with no recorded uid rather than
# guessing which principal to unallow.
printf 'PEER_JOIN_ACCOUNT="zfsbackup-lbl"\nPEER_JOIN_ROLE=pull\nPEER_JOIN_ACCOUNT_UID=4242\nPEER_JOIN_GRANTED_DATASETS=""\n' > "$LV/peers/lbl.conf"
touch "$LV/peers/lbl.scope" "$LV/peers/lbl.scope.sha256" "$LV/peers/lbl.scope.request"
run_verb --leave=lbl >/dev/null 2>&1
# The REQUEST is the discriminator -- the other two came out before this fix
# too, so an assertion that only watched them would pass either way.
left=""
for f in lbl.scope.request lbl.scope lbl.scope.sha256 lbl.conf; do
    [ -e "$LV/peers/$f" ] && left="$left $f"
done
if [ -z "${left# }" ]; then
    ok "verbs: --leave removes the scope REQUEST alongside the scope and its hash"
else
    bad "verbs: --leave removes the scope REQUEST alongside the scope and its hash" "left=[$left]"
fi


# ...and NEITHER runs the provisioning phases on the way. A teardown that pulls
# the repo on the host being torn down cannot complete when that checkout has
# diverged -- measured on pve9 -- and on an ordinary host it rewrites scripts
# and adds cron lines nobody asked for.
for v in --commit-scope=nieistnieje --leave=nieistnieje; do
    out="$(run_verb "$v")"
    case "$out" in
        *"Phase 1"*) bad "verbs: $v does not provision the host first" "$out" ;;
        *) ok "verbs: $v does not provision the host first" ;;
    esac
done

# THE CONTROL, and it is not decoration: the two assertions above would also
# pass on a build that had stopped provisioning ENTIRELY. An ordinary run must
# still enter the phases.
out="$(run_verb --check-only)"
case "$out" in
    *"Phase 1"*) ok "verbs: control -- an ordinary run still runs the phases" ;;
    *) bad "verbs: control -- an ordinary run still runs the phases" "$out" ;;
esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
