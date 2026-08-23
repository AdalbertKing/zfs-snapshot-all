#!/bin/bash
# Tests for deploy.sh's alert-delivery audit (REV-20260806-046) -- the
# mta_present/mta_name/mail_queue_depth/alert_delivery_verdict quartet that
# decides whether "this host's alerts can leave the building" counts against
# --check-only's exit code.
#
# The review's finding class is FALSE HEALTH: a verdict that reports a host
# able to send mail when the evidence it measured proves no such thing.
# Three concrete shapes, all pinned here:
#   F2  queue unreadable (unsupported MTA, failed postqueue, garbage output)
#       used to log() and return 0 -- "audit clean" on a host nobody inspected;
#   F1  an empty queue used to print "this host can send" -- a delivery claim
#       derived from the absence of queued work;
#   F3  a drained queue after the test mail used to read as "dispatched" --
#       true only of the LOCAL queue, silent about the relay/recipient.
#
# Functions are extracted from deploy.sh by sed pattern (the technique of
# test/pause, test/draftscope, test/joinmanifest -- deploy.sh's root check
# would otherwise abort the suite). mta_present() inspects absolute paths
# (/usr/sbin/sendmail), so cases override it per-scenario; everything that
# resolves through PATH (mail, postqueue, exim4, postconf) is stubbed with a
# per-case stub directory. Each case runs in a subshell with PROBLEMS=0 so
# the suite can assert the return code AND the PROBLEMS accounting agree with
# the emitted wording -- acceptance criterion 9 of the review.
#
# Run against an older deploy.sh (to show a case failing on the reviewed
# base): DEPLOY_SRC=/path/to/old/deploy.sh ./test/alertmail/run.sh
#
#   ./test/alertmail/run.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SRC="${DEPLOY_SRC:-$REPO/deploy.sh}"
[ -r "$DEPLOY_SRC" ] || { echo "cannot read deploy.sh at $DEPLOY_SRC" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

for fn in mta_present mta_name mail_queue_depth alert_delivery_verdict alert_delivery_probe; do
    eval "$(sed -n "/^$fn() {/,/^}/p" "$DEPLOY_SRC")"
    if ! declare -F "$fn" >/dev/null; then
        echo "FATAL: could not extract $fn from $DEPLOY_SRC -- the sed anchors no longer match, update this suite" >&2
        exit 1
    fi
done

# deploy.sh's own log/warn, verbatim: warn() must keep incrementing PROBLEMS,
# because that increment IS the audit result the review is about.
eval "$(grep -E '^(log|warn)\(\)' "$DEPLOY_SRC")"
declare -F warn >/dev/null || { echo "FATAL: could not extract warn() from $DEPLOY_SRC" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# A stub PATH: only what a case puts there resolves. `mail` is a no-op
# accepting stdin; postqueue/exim4/postconf are (re)written per case.
STUB="$TMPD/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$STUB/mail"
chmod +x "$STUB"/*
# mail_queue_depth's real pipeline needs awk; keep it reachable next to the
# stubs, or a missing awk would fake the exact "emits nothing" result the
# failed-postqueue case is trying to prove.
AWKDIR="$(dirname "$(command -v awk)")"

# run_verdict <mta_present_rc> <queue_depth_output> -- runs the verdict in a
# subshell with PROBLEMS=0, stubbed mta_present and mail_queue_depth, and
# reports "rc=<rc> problems=<n>" on stdout; the verdict's own output goes to
# $TMPD/out. queue_depth_output "NONE" means emit nothing (unreadable).
run_verdict() {
    local mp_rc="$1" qd="$2"
    (
        PROBLEMS=0
        eval "mta_present() { return $mp_rc; }"
        if [ "$qd" = "NONE" ]; then
            mail_queue_depth() { :; }
        else
            eval "mail_queue_depth() { printf '%s\n' \"$qd\"; }"
        fi
        PATH="$STUB" alert_delivery_verdict >"$TMPD/out" 2>&1
        echo "rc=$? problems=$PROBLEMS"
    )
}

# ---------------------------------------------------------------------------
# Baseline hard failures: missing pieces stay loud. (Review criterion 3.)
# ---------------------------------------------------------------------------
R=$( (
    PROBLEMS=0
    PATH="$TMPD/nowhere" alert_delivery_verdict >"$TMPD/out" 2>&1
    echo "rc=$? problems=$PROBLEMS"
) )
if [ "$R" = "rc=1 problems=2" ] && grep -q "no 'mail' command" "$TMPD/out"; then
    ok "no mail(1) at all: hard failure, PROBLEMS incremented"
else
    bad "no mail(1) at all: hard failure, PROBLEMS incremented" "got: $R" "$(cat "$TMPD/out")"
fi

R=$(run_verdict 1 "NONE")
if [ "$R" = "rc=1 problems=2" ] && grep -q "no MTA provides sendmail" "$TMPD/out"; then
    ok "mail(1) present but no MTA: hard failure, PROBLEMS incremented"
else
    bad "mail(1) present but no MTA: hard failure, PROBLEMS incremented" "got: $R" "$(cat "$TMPD/out")"
fi

R=$(run_verdict 0 "3")
if [ "$R" = "rc=1 problems=2" ] && grep -q "STUCK IN THE QUEUE" "$TMPD/out"; then
    ok "3 messages queued: hard failure, PROBLEMS incremented"
else
    bad "3 messages queued: hard failure, PROBLEMS incremented" "got: $R" "$(cat "$TMPD/out")"
fi

# ---------------------------------------------------------------------------
# F2: unverifiable queue state must NOT end as audit clean. The reviewed base
# log()ged and returned 0 here -- these three cases fail on it.
# ---------------------------------------------------------------------------
R=$(run_verdict 0 "NONE")
if [ "${R%% *}" = "rc=1" ] && [ "${R##* }" != "problems=0" ] && grep -qi "UNVERIFIED" "$TMPD/out"; then
    ok "F2: unreadable queue (unsupported MTA) is non-clean and says UNVERIFIED"
else
    bad "F2: unreadable queue (unsupported MTA) is non-clean and says UNVERIFIED" "got: $R" "$(cat "$TMPD/out")"
fi
if grep -qi "can send" "$TMPD/out"; then
    bad "F2: unreadable queue makes no positive delivery claim" "output claims 'can send': $(cat "$TMPD/out")"
else
    ok "F2: unreadable queue makes no positive delivery claim"
fi

R=$(run_verdict 0 "mailq: command garbage")
if [ "${R%% *}" = "rc=1" ] && [ "${R##* }" != "problems=0" ]; then
    ok "F2: non-numeric queue output fails closed (no arithmetic error read as empty)"
else
    bad "F2: non-numeric queue output fails closed (no arithmetic error read as empty)" "got: $R" "$(cat "$TMPD/out")"
fi

# mail_queue_depth itself: a postqueue that FAILS must emit nothing (unknown),
# not fall through awk's END{print 0} and report an empty queue.
printf '#!/bin/sh\nexit 69\n' > "$STUB/postqueue"; chmod +x "$STUB/postqueue"
Q=$(PATH="$STUB:$AWKDIR" mail_queue_depth)
if [ -z "$Q" ]; then
    ok "F2: mail_queue_depth emits nothing when postqueue itself fails"
else
    bad "F2: mail_queue_depth emits nothing when postqueue itself fails" "emitted: '$Q'"
fi

# ---------------------------------------------------------------------------
# F1: an empty queue with no fresh probe is READY/UNVERIFIED, never a
# delivery claim. The reviewed base printed "this host can send" here --
# the review's concrete counterexample is exactly this state with outbound
# 25 walled off. Wording is part of the contract: the case greps for it.
# ---------------------------------------------------------------------------
R=$(run_verdict 0 "0")
if [ "$R" = "rc=0 problems=0" ]; then
    ok "F1: empty queue, no probe: still audit-clean (prerequisites are OK)"
else
    bad "F1: empty queue, no probe: still audit-clean (prerequisites are OK)" "got: $R" "$(cat "$TMPD/out")"
fi
if grep -qi "can send" "$TMPD/out"; then
    bad "F1: empty queue makes no positive delivery claim" "output claims 'can send': $(cat "$TMPD/out")"
else
    ok "F1: empty queue makes no positive delivery claim"
fi
if grep -qi "UNVERIFIED" "$TMPD/out"; then
    ok "F1: empty queue names delivery as unverified, not merely omits the claim"
else
    bad "F1: empty queue names delivery as unverified, not merely omits the claim" "$(cat "$TMPD/out")"
fi

# ...and a postqueue that works keeps counting correctly, both shapes.
printf '#!/bin/sh\necho "Mail queue is empty"\n' > "$STUB/postqueue"
Q=$(PATH="$STUB:$AWKDIR" mail_queue_depth)
if [ "$Q" = "0" ]; then
    ok "F2 control: healthy empty postfix queue still reads as 0"
else
    bad "F2 control: healthy empty postfix queue still reads as 0" "emitted: '$Q'"
fi
printf '#!/bin/sh\nprintf -- "-- 5 Kbytes in 2 Requests.\\n"\n' > "$STUB/postqueue"
Q=$(PATH="$STUB:$AWKDIR" mail_queue_depth)
if [ "$Q" = "2" ]; then
    ok "F2 control: non-empty postfix queue still counts (2 requests -> 2)"
else
    bad "F2 control: non-empty postfix queue still counts (2 requests -> 2)" "emitted: '$Q'"
fi
rm -f "$STUB/postqueue"

# ---------------------------------------------------------------------------
# F3: the active probe. Submission status is checked (was fire-and-forget on
# the reviewed base), and a drained queue is claimed as LOCAL dispatch only
# -- the base said "the MTA accepted and dispatched it", which a smarthost
# bounce five seconds later would make false.
# ---------------------------------------------------------------------------
# run_probe <mail_rc> <q_before> <q_after> -- q values "NONE" emit nothing.
# mail_queue_depth consumes one line of $TMPD/qseq per call, so before/after
# can differ, exactly as two real queue looks straddling the send would.
run_probe() {
    local mail_rc="$1" qb="$2" qa="$3"
    printf '%s\n%s\n' "$qb" "$qa" > "$TMPD/qseq"
    (
        PROBLEMS=0
        eval "mail() { cat >/dev/null; return $mail_rc; }"
        sleep() { :; }
        mail_queue_depth() {
            local v; v=$(head -n1 "$TMPD/qseq"); sed -i '1d' "$TMPD/qseq"
            [ "$v" = "NONE" ] || printf '%s\n' "$v"
        }
        alert_delivery_probe "ops@example.invalid" >"$TMPD/out" 2>&1
        echo "rc=$? problems=$PROBLEMS"
    )
}

R=$(run_probe 1 "0" "0")
if [ "${R%% *}" = "rc=1" ] && [ "${R##* }" != "problems=0" ] && grep -q "NOT ACCEPTED" "$TMPD/out"; then
    ok "F3: mail(1) exiting non-zero is a failure, not a shrug toward the inbox"
else
    bad "F3: mail(1) exiting non-zero is a failure, not a shrug toward the inbox" "got: $R" "$(cat "$TMPD/out")"
fi

R=$(run_probe 0 "0" "1")
if [ "${R%% *}" = "rc=1" ] && [ "${R##* }" != "problems=0" ] && grep -q "STILL QUEUED" "$TMPD/out"; then
    ok "F3: a message still queued after the send stays a warned failure"
else
    bad "F3: a message still queued after the send stays a warned failure" "got: $R" "$(cat "$TMPD/out")"
fi

R=$(run_probe 0 "0" "0")
if [ "$R" = "rc=0 problems=0" ] && grep -q "LEFT THIS MTA" "$TMPD/out" \
        && grep -qi "not independently verified" "$TMPD/out"; then
    ok "F3: a drained queue is claimed as local dispatch, bounded explicitly"
else
    bad "F3: a drained queue is claimed as local dispatch, bounded explicitly" "got: $R" "$(cat "$TMPD/out")"
fi
if grep -qiE "accepted and dispatched|delivery works|can send" "$TMPD/out"; then
    bad "F3: a drained queue makes no end-to-end delivery claim" "$(cat "$TMPD/out")"
else
    ok "F3: a drained queue makes no end-to-end delivery claim"
fi

R=$(run_probe 0 "0" "NONE")
if [ "$R" = "rc=0 problems=0" ] && grep -q "no verdict on dispatch" "$TMPD/out"; then
    ok "F3: unreadable queue after the send stays bounded to 'mail(1) accepted it'"
else
    bad "F3: unreadable queue after the send stays bounded to 'mail(1) accepted it'" "got: $R" "$(cat "$TMPD/out")"
fi

R=$(run_probe 0 "0" "sendmail: garbage")
if [ "${R%% *}" = "rc=0" ] && grep -q "no verdict on dispatch" "$TMPD/out"; then
    ok "F3: non-numeric queue output after the send reads as unreadable, not drained"
else
    bad "F3: non-numeric queue output after the send reads as unreadable, not drained" "got: $R" "$(cat "$TMPD/out")"
fi

# ---------------------------------------------------------------------------
# The operator guides QUOTE this verdict. A quote is an assertion, and this
# one went stale twice: REV-046 removed "this host can send" from the code,
# and both deployment guides kept printing it to the reader for a day --
# then REV-053 caught the same class again in the pause runbook. So the
# healthy-branch wording is pinned against the docs that reproduce it, not
# just against the code.
#
# Deliberately narrow: it checks the ONE line the guides quote verbatim, and
# only in the files that quote it. A general "docs must not contain stale
# strings" rule would need a list of every retired message, which nobody
# would maintain.
# ---------------------------------------------------------------------------
verdict_line=$(sed -n 's/.*log "  \(alert delivery: \$(mta_name) present, no queued mail[^"]*\)".*/\1/p' "$DEPLOY_SRC" | head -1)
verdict_doc=${verdict_line/\$(mta_name)/postfix}
if [ -z "$verdict_line" ]; then
    bad "the healthy verdict line can be located in deploy.sh" "sed pattern no longer matches -- update this check with the wording"
else
    for guide in "$REPO/docs/WDROZENIE-PROXMOX.md" "$REPO/docs/DEPLOYMENT-PROXMOX.md"; do
        name=$(basename "$guide")
        [ -r "$guide" ] || { echo "SKIP $name not present"; continue; }
        if ! grep -q "alert delivery: postfix present" "$guide"; then
            echo "SKIP $name no longer quotes the alert-delivery verdict"
        elif grep -qF "$verdict_doc" "$guide"; then
            ok "$name quotes the alert-delivery verdict exactly as deploy.sh emits it"
        else
            bad "$name quotes the alert-delivery verdict exactly as deploy.sh emits it" \
                "code:  $verdict_doc" "docs:  $(grep -m1 'alert delivery: postfix present' "$guide")"
        fi
    done
fi


# ---------------------------------------------------------------------------
# THE WEEKLY HEARTBEAT MUST FAIL CLOSED.
#
# Same finding class as the rest of this file: a claim of health the evidence
# does not support. The heartbeat exists for exactly one reason -- to prove the
# alert channel still carries on a week with nothing to report -- so a send that
# never left the host must not exit 0. The first cut piped into mail and then
# ran an unconditional exit 0, which meant a broken MTA produced a cheerful
# "channel fine" while nothing was delivered.
#
# This runs the REAL generated script, not a grep of deploy.sh. The heredoc body
# is extracted and expanded exactly as deploy.sh expands it, then executed with
# the queue redirected into a temp dir and mail(1) stubbed. The day check is
# neutralised by pinning it to whatever today is -- an earlier hand-run of this
# control returned 0 and looked like a pass purely because the date had rolled
# past the heartbeat day and the branch never executed at all.
# ---------------------------------------------------------------------------
hb_body=$(sed -n '/^    cat > "\$DIGEST_SCRIPT" <<EOF$/,/^EOF$/p' "$DEPLOY_SRC" | sed '1d;$d')
if [ -z "$hb_body" ]; then
    bad "the alert-digest heredoc can be extracted from deploy.sh" \
        "sed anchors no longer match -- update this suite"
elif ! printf '%s\n' "$hb_body" | grep -q 'cisza, kanal sprawny'; then
    bad "the extracted digest carries the weekly heartbeat" \
        "no heartbeat send found in the extracted body"
else
    hb_dir=$(mktemp -d)
    DIGEST_SCRIPT_MARKER="# alert-digest.sh test" \
    ALERT_ENV_PREAMBLE="" NOTIFY_EMAIL="root" \
        eval "cat > '$hb_dir/digest.sh' <<EOF
$hb_body
EOF"
    # Pin the heartbeat day to today so the branch always runs. Without this the
    # case silently no-ops on six days out of seven and reports a pass.
    sed -i "s/\"\$(date +%u)\" = \"[0-9]\"/\"\$(date +%u)\" = \"$(date +%u)\"/" "$hb_dir/digest.sh"
    if ! grep -q "= \"$(date +%u)\"" "$hb_dir/digest.sh"; then
        bad "the heartbeat day check can be pinned for the test" \
            "the day comparison in the generated script no longer matches the sed"
    elif ! bash -n "$hb_dir/digest.sh" 2>/dev/null; then
        bad "the extracted digest is valid bash" "$(bash -n "$hb_dir/digest.sh" 2>&1 | head -3)"
    else
        mkdir -p "$hb_dir/bin"
        printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$hb_dir/bin/mail"
        chmod +x "$hb_dir/bin/mail"

        rm -f "$hb_dir/q" "$hb_dir/q.processing"
        hb_out=$(PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
                 bash "$hb_dir/digest.sh" 2>&1); hb_rc=$?
        if [ "$hb_rc" -eq 0 ]; then
            ok "heartbeat: a delivered send exits 0"
        else
            bad "heartbeat: a delivered send exits 0" "rc=$hb_rc" "out: $hb_out"
        fi

        # The discriminating case. mail(1) fails; the heartbeat must say so.
        printf '#!/bin/sh\ncat >/dev/null\nexit 3\n' > "$hb_dir/bin/mail"
        rm -f "$hb_dir/q" "$hb_dir/q.processing"
        hb_out=$(PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
                 bash "$hb_dir/digest.sh" 2>&1); hb_rc=$?
        if [ "$hb_rc" -ne 0 ]; then
            ok "heartbeat: a send that failed does NOT report success"
        else
            bad "heartbeat: a send that failed does NOT report success" \
                "mail(1) exited 3 and the digest still exited 0 -- the pulse is fail-open" \
                "out: $hb_out"
        fi
        if printf '%s' "$hb_out" | grep -q "NOT proven"; then
            ok "heartbeat: a failed send names the channel as unproven"
        else
            bad "heartbeat: a failed send names the channel as unproven" \
                "nothing on stderr told cron what broke" "out: $hb_out"
        fi
    fi
    rm -rf "$hb_dir"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
