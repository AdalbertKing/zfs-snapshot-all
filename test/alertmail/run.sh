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

# shellcheck disable=SC1091
. "$SCRIPT_DIR/../harness.sh"
for fn in mta_present mta_name mail_queue_depth alert_delivery_verdict alert_delivery_probe; do
    eval "$(product_fn "$DEPLOY_SRC" "$fn")"
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
# This runs the REAL shipped script, not a grep of deploy.sh: the file deploy.sh
# installs (hostscripts/alert-digest.sh) is copied beside its alert-env.sh and
# the queue redirected into a temp dir and mail(1) stubbed. The day check is
# neutralised by pinning it to whatever today is -- an earlier hand-run of this
# control returned 0 and looked like a pass purely because the date had rolled
# past the heartbeat day and the branch never executed at all.
# ---------------------------------------------------------------------------
# THE SCRIPT IS A FILE, AND THE FILE IS WHAT RUNS (2026-09-03). Until this
# date the digest was an unquoted heredoc in deploy.sh, and this section began
# with three guards that only made sense for a heredoc: no comment may carry a
# backtick or a '$' (it would run at install time -- REV-20260902-133 found
# `Doba:` executing as root), no single quote may be backslash-escaped, and a
# rendering under a sentinel executable named `Doba:` must call nothing and
# print nothing. hostscripts/alert-digest.sh is copied, never expanded, so
# those properties hold by construction; what is pinned instead is that the
# generation is GONE from deploy.sh and that deploy.sh installs the file it
# ships (section host-scripts, below).
HS="$(dirname "$DEPLOY_SRC")/hostscripts"
_gen=$(grep -cE '^ *cat > "\$(NOTIFY|WARN|DIGEST|CAPACITY)_SCRIPT" <<' "$DEPLOY_SRC")
if [ "$_gen" -eq 0 ]; then
    ok "no host script is generated from a deploy.sh heredoc any more (REV-133's whole class)"
else
    bad "no host script is generated from a deploy.sh heredoc any more (REV-133's whole class)" "$_gen heredoc opener(s) still in $DEPLOY_SRC"
fi
# The digest under test is the shipped file beside its alert-env.sh; the conf
# lookup is pointed at nothing so a developer's /etc/zfs-alert.conf cannot leak
# into the run (the environment wins over the file either way).
export ZFS_ALERT_CONF=/dev/null
if [ ! -r "$HS/alert-digest.sh" ] || [ ! -r "$HS/alert-env.sh" ]; then
    bad "the alert-digest script and alert-env.sh ship as files in hostscripts/" \
        "missing under $HS"
elif ! grep -q 'cisza, kanal sprawny' "$HS/alert-digest.sh"; then
    bad "the shipped digest carries the weekly heartbeat" \
        "no heartbeat send found in $HS/alert-digest.sh"
else
    hb_dir=$(mktemp -d)
    cp "$HS/alert-digest.sh" "$hb_dir/digest.sh"
    cp "$HS/alert-env.sh"    "$hb_dir/alert-env.sh"
    # The quiet branch used to be reachable only on Mondays, and this suite
    # neutralised that with a sed over the day comparison -- a pin that broke
    # the moment the comparison was rewritten. ZFS_DIGEST_QUIET=daily is now
    # the supported way in, so the test uses the product's own knob instead of
    # rewriting the product. Every quiet-path run below sets it; without it the
    # case silently no-ops on six days out of seven and reports a pass.
    QUIET_ON="ZFS_DIGEST_QUIET=daily"
    if ! bash -n "$hb_dir/digest.sh" 2>/dev/null; then
        bad "the shipped digest is valid bash" "$(bash -n "$hb_dir/digest.sh" 2>&1 | head -3)"
    else
        mkdir -p "$hb_dir/bin"
        printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$hb_dir/bin/mail"
        chmod +x "$hb_dir/bin/mail"

        rm -f "$hb_dir/q" "$hb_dir/q.processing"
        hb_out=$(PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
                 env $QUIET_ON bash "$hb_dir/digest.sh" 2>&1); hb_rc=$?
        if [ "$hb_rc" -eq 0 ]; then
            ok "heartbeat: a delivered send exits 0"
        else
            bad "heartbeat: a delivered send exits 0" "rc=$hb_rc" "out: $hb_out"
        fi

        # The discriminating case. mail(1) fails; the heartbeat must say so.
        printf '#!/bin/sh\ncat >/dev/null\nexit 3\n' > "$hb_dir/bin/mail"
        rm -f "$hb_dir/q" "$hb_dir/q.processing"
        hb_out=$(PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
                 env $QUIET_ON bash "$hb_dir/digest.sh" 2>&1); hb_rc=$?
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

        # -------------------------------------------------------------------
        # THE QUIET REPORT CARRIES THE REPORT, AND ITS CADENCE IS SETTABLE.
        #
        # Owner, 2026-09-02: "Co, gdy nie ma warningow, ani alertow, czy raz w
        # tygodniu tez dostane taka statystyke? czy mozemy sparametryzowac
        # czestotliwosc maila informacyjnego?" He did not get it. The quiet mail
        # was one line and the state table plus the run figures were built after
        # the branch had already exited -- so the periodic report disappeared in
        # exactly the weeks worth reading, the ones where nothing is wrong.
        #
        # Three cases, and the two negatives are the point: "no mail arrived" is
        # not evidence of a working switch unless some other setting DOES mail.
        # -------------------------------------------------------------------
        printf '#!/bin/sh\nshift\ncat > "$HB_SENT"\nexit 0\n' > "$hb_dir/bin/mail"
        chmod +x "$hb_dir/bin/mail"
        # A log with one real run, so the table has a row to print. Written
        # here rather than reusing $_fakelog: that variable is created 140
        # lines further down, and reading it here would have silently passed
        # an empty ZFS_CRON_LOGS.
        printf '%sT08:00:00+00:00 ZFS-JOB BEGIN h daily backup (x)\n' "$(date +%Y-%m-%d)" >  "$hb_dir/qlog"
        printf '%sT08:00:06+00:00 ZFS-JOB END h daily backup (x) rc=0\n' "$(date +%Y-%m-%d)" >> "$hb_dir/qlog"
        _q_run() {  # <cadence> -> body in $hb_dir/sent, or no file at all
            rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/sent"
            HB_SENT="$hb_dir/sent" PATH="$hb_dir/bin:$PATH" \
            ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$hb_dir/qlog" \
                env ZFS_DIGEST_QUIET="$1" bash "$hb_dir/digest.sh" >/dev/null 2>&1
        }
        _today=$(printf 'mon tue wed thu fri sat sun' | cut -d' ' -f"$(date +%u)")
        _other=$(printf 'mon tue wed thu fri sat sun' | cut -d' ' -f"$(( $(date +%u) % 7 + 1 ))")

        _q_run "$_today"
        if [ -s "$hb_dir/sent" ] && grep -q 'czas ostatni' "$hb_dir/sent"; then
            ok "quiet report: on its cadence day it carries the run table, not one line"
        else
            bad "quiet report: on its cadence day it carries the run table, not one line" \
                "$(head -20 "$hb_dir/sent" 2>/dev/null || echo '<zaden mail nie wyszedl>')"
        fi

        _q_run "$_other"
        if [ ! -f "$hb_dir/sent" ]; then
            ok "quiet report: a day that is not the cadence day sends nothing"
        else
            bad "quiet report: a day that is not the cadence day sends nothing" \
                "cadence=$_other, dzis=$_today" "$(head -5 "$hb_dir/sent")"
        fi

        _q_run off
        if [ ! -f "$hb_dir/sent" ]; then
            ok "quiet report: 'off' silences it entirely"
        else
            bad "quiet report: 'off' silences it entirely" "$(head -5 "$hb_dir/sent")"
        fi

        # A MONTH IS A CADENCE TOO, AND SO IS A DAY OF THE MONTH.
        #
        # Owner, 2026-09-02: "Tych cichych bez bledow i podsumowan tygodniowych?
        # Albo miesiecznych?" The knob took weekdays, daily and off -- there was
        # no way to say "once a month". Window and cadence stay independent: a
        # monthly mail with ZFS_DIGEST_DAYS=30 is the monthly trend, a weekly one
        # with the same window is the same data read more often.
        _dom=$(date +%d); _dom="${_dom#0}"
        _other_dom=$(( _dom % 28 + 1 ))

        _q_run "$_dom"
        if [ -s "$hb_dir/sent" ]; then
            ok "quiet report: a day-of-month cadence fires on that day"
        else
            bad "quiet report: a day-of-month cadence fires on that day" "dzis=$_dom"
        fi

        _q_run "$_other_dom"
        if [ ! -f "$hb_dir/sent" ]; then
            ok "quiet report: a day-of-month cadence is silent on every other day"
        else
            bad "quiet report: a day-of-month cadence is silent on every other day" \
                "cadence=$_other_dom, dzis=$_dom"
        fi

        # On any day but the 1st the presence check alone cannot discriminate:
        # a broken `monthly` branch falls through to the unknown-value handler,
        # which is ALSO silent that day. stderr is therefore checked too -- the
        # fallthrough announces itself there, and that works every day.
        # 'monthly' is the 1st, spelled out because a bare "1" reads as a weekday
        # to half the people who will edit that file.
        _q_run monthly
        if [ "$_dom" = "1" ]; then _want=present; else _want=absent; fi
        _got=$([ -f "$hb_dir/sent" ] && echo present || echo absent)
        HB_SENT="$hb_dir/sent" PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
        ZFS_CRON_LOGS="$hb_dir/qlog" \
            env ZFS_DIGEST_QUIET=monthly bash "$hb_dir/digest.sh" 2>"$hb_dir/emo" >/dev/null
        if [ "$_got" = "$_want" ] && ! grep -q "is not a weekday" "$hb_dir/emo" 2>/dev/null; then
            ok "quiet report: 'monthly' means the 1st"
        else
            bad "quiet report: 'monthly' means the 1st" "dzis=$_dom oczekiwano=$_want bylo=$_got"
        fi

        # Days that do not occur in every month are refused, not silently
        # accepted -- a report that skips February is worse than one that will
        # not be configured that way.
        _q_run 31
        if [ -n "$(ls "$hb_dir"/*.err 2>/dev/null)" ] || true; then :; fi
        HB_SENT="$hb_dir/sent" PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
        ZFS_CRON_LOGS="$hb_dir/qlog" \
            env ZFS_DIGEST_QUIET=31 bash "$hb_dir/digest.sh" 2>"$hb_dir/e31" >/dev/null
        if grep -q 'do not occur in every month' "$hb_dir/e31" 2>/dev/null; then
            ok "quiet report: a day above 28 is named as impossible rather than accepted"
        else
            bad "quiet report: a day above 28 is named as impossible rather than accepted" \
                "$(cat "$hb_dir/e31" 2>/dev/null | head -2)"
        fi


        # A day WITH findings mails whatever the cadence says. Suppressing an
        # alert on a schedule is not a cadence, it is a lost alert.
        rm -f "$hb_dir/q.processing" "$hb_dir/sent"
        printf '%s\tALERT\tvm-100\tzadanie padlo rc=8\n' "$(date +%s)" > "$hb_dir/q"
        HB_SENT="$hb_dir/sent" PATH="$hb_dir/bin:$PATH" \
        ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$hb_dir/qlog" \
            env ZFS_DIGEST_QUIET=off bash "$hb_dir/digest.sh" >/dev/null 2>&1
        if [ -s "$hb_dir/sent" ] && grep -q 'vm-100' "$hb_dir/sent"; then
            ok "quiet cadence governs ONLY the empty mail -- a finding still goes out under 'off'"
        else
            bad "quiet cadence governs ONLY the empty mail -- a finding still goes out under 'off'" \
                "$(head -20 "$hb_dir/sent" 2>/dev/null || echo '<alert przepadl>')"
        fi


        # -------------------------------------------------------------------
        # AN EVENT NOT FROM TODAY MUST CARRY ITS DATE.
        #
        # This digest runs at 07:00 over a queue filled the day before, so it
        # almost always reports yesterday. v9 printed bare times under a header
        # stamped `Doba: <send date>`, which reads as "this is happening now".
        # Measured 2026-09-02 on pve1.kancelaria.net: a pool repaired at 17:45
        # the previous day produced a morning mail saying `Doba: 2026-09-02`
        # over `(07:01 - 16:01)`, and the owner reasonably concluded the pool
        # was still degraded. It was not -- every event predated the repair.
        printf '#!/bin/sh\ncat > "$0.out"\nexit 0\n' > "$hb_dir/bin/mail"
        chmod +x "$hb_dir/bin/mail"
        rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/bin/mail.out"
        _yd=$(date -d yesterday '+%Y-%m-%d' 2>/dev/null)
        if [ -z "$_yd" ]; then
            bad "date: this platform can express yesterday" "date -d yesterday failed"
        else
            {   printf '%s\tALERT\tpool DEGRADED: rpool\tsprzed naprawy\n' "$(date -d "$_yd 07:01" +%s)"
                printf '%s\tALERT\tpool DEGRADED: rpool\tsprzed naprawy\n' "$(date -d "$_yd 16:01" +%s)"
                printf '%s\tWARN\tdzisiejsze\tdzis\n' "$(date +%s)"
            } > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _body=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_body" | grep -qF "($_yd 07:01 - 16:01)"; then
                ok "digest: an event from another day carries that day in its range"
            else
                bad "digest: an event from another day carries that day in its range" \
                    "expected ($_yd 07:01 - 16:01)" "$_body"
            fi
            # The header must name the period the events cover, never the send
            # date -- that substitution is the whole defect.
            if printf '%s' "$_body" | grep -q "ZDARZENIA Z OKRESU $_yd 07:01" \
               && ! printf '%s' "$_body" | grep -q "Doba:"; then
                ok "digest: the header names the covered period, not the send date"
            else
                bad "digest: the header names the covered period, not the send date" "$_body"
            fi
            # THE CONTROL, and it is why the date is conditional: today's own
            # events must stay compact. A date on every row is noise, and noise
            # is how the one row that mattered gets skipped.
            if printf '%s' "$_body" | grep -qE 'x1 +dzisiejsze +\([0-9]{2}:[0-9]{2}\)'; then
                ok "digest: an event from TODAY stays time-only"
            else
                bad "digest: an event from TODAY stays time-only" "$_body"
            fi

            # ---------------------------------------------------------------
            # THE STATE BLOCK COMES FIRST, AND IS A PROBE, NOT A REPLAY.
            #
            # Owner direction 2026-09-02: state first, period report second.
            # The point is not layout -- it is that a fault repaired since the
            # events cannot present itself as current.
            _st=$(printf '%s' "$_body" | grep -n 'STAN BIEZACY' | cut -d: -f1)
            _ev=$(printf '%s' "$_body" | grep -n 'ZDARZENIA Z OKRESU' | cut -d: -f1)
            if [ -n "$_st" ] && [ -n "$_ev" ] && [ "$_st" -lt "$_ev" ]; then
                ok "digest: the current-state block precedes the event list"
            else
                bad "digest: the current-state block precedes the event list" "$_body"
            fi

            # THE FALSE-ALARM CASE, as an assertion. The queue above holds only
            # stale ALERTs and nothing is actually wrong, so the verdict must
            # read OK. This is the whole reason the block exists.
            if printf '%s' "$_body" | grep -q 'STAN: OK'; then
                ok "digest: stale ALERTs alone do not make the current state bad"
            else
                bad "digest: stale ALERTs alone do not make the current state bad" "$_body"
            fi

            # A JOB DELETED FROM CRON MUST NOT PIN THE VERDICT.
            #
            # Found by running the first build of this against pve9: a lab job
            # had failed with rc=8 the previous day and then been removed, and
            # its last run -- frozen in the log for ever -- called the host
            # broken with nothing left to fix.
            #
            # Driven for real: a log carrying only that dead job, and a crontab
            # stub that does not list it.
            _fakelog="$hb_dir/cron.log"
            {   printf '%sT10:00:00+00:00 ZFS-JOB BEGIN h zombie job (gone)\n' "$_yd"
                printf '%sT10:00:05+00:00 ZFS-JOB END h zombie job (gone) rc=8\n' "$_yd"
            } > "$_fakelog"
            printf '#!/bin/sh\nexit 0\n' > "$hb_dir/bin/crontab"
            chmod +x "$hb_dir/bin/crontab"
            rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _dead=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_dead" | grep -q 'juz nie w cronie' \
               && printf '%s' "$_dead" | grep -q 'STAN: OK'; then
                ok "digest: a job that left cron is marked, and does not make the state bad"
            else
                bad "digest: a job that left cron is marked, and does not make the state bad" "$_dead"
            fi

            # THE CONTROL: the same dead job, but still listed in cron. Now its
            # failure IS the present tense and must show.
            cat > "$hb_dir/bin/crontab" <<'CTSTUB'
#!/bin/sh
echo '0 * * * * /x/zfs-job.sh "h zombie job (gone)" -- /x/y' 
CTSTUB
            chmod +x "$hb_dir/bin/crontab"
            rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _live=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_live" | grep -q 'PADL rc=8' \
               && printf '%s' "$_live" | grep -q 'STAN: UWAGA'; then
                ok "digest: a scheduled job whose last run failed DOES make the state bad"
            else
                bad "digest: a scheduled job whose last run failed DOES make the state bad" "$_live"
            fi

            # THE OTHER CRON FORMAT, and this one shipped broken.
            #
            # v11 looked for zfs-job.sh "<label>", which is what a host
            # generated by current main runs. Production hosts still carry the
            # older INLINE form, where the label lives inside the job's own
            # echo. On those NOTHING matched and every job was reported as
            # gone -- the owner saw it on pve0.kancelaria.net minutes after
            # v11 merged. A format read off ONE host is not the estate's.
            cat > "$hb_dir/bin/crontab" <<'CTINLINE'
#!/bin/sh
echo '1 * * * * echo "$(date -Is) ZFS-JOB BEGIN h zombie job (gone)" >>/var/log/x; /opt/snapsend.sh -m "a_" "hdd/data/vm-9-disk-0,hdd/data/vm-9-disk-1"'
CTINLINE
            chmod +x "$hb_dir/bin/crontab"
            rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _inline=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if ! printf '%s' "$_inline" | grep -q 'juz nie w cronie'; then
                ok "digest: the INLINE cron format is recognised as scheduled"
            else
                bad "digest: the INLINE cron format is recognised as scheduled" "$_inline"
            fi

            # ...and the datasets come off that same line. The label carries
            # only the notify word, so the row alone cannot say which dataset
            # a job touched.
            if printf '%s' "$_inline" | grep -q 'hdd/data/vm-9-disk-0' \
               && printf '%s' "$_inline" | grep -q 'hdd/data/vm-9-disk-1'; then
                ok "digest: the state block lists the datasets the job touches"
            else
                bad "digest: the state block lists the datasets the job touches" "$_inline"
            fi

            # THE CONTROL for the dataset filter: the job's own echo text and
            # the script paths on the same line must NOT be listed. On pve0 the
            # notify label is literally "hdd/lxc", so the echo string held a
            # slash and passed every filter but the no-spaces one.
            if ! printf '%s' "$_inline" | grep -qE '^ +(/opt/|.*ZFS-JOB BEGIN)'; then
                ok "digest: echo text and script paths are not mistaken for datasets"
            else
                bad "digest: echo text and script paths are not mistaken for datasets" "$_inline"
            fi

            # THE '+' JOIN IS RENDERED AS COMMAS. gen-cron joins several
            # datasets' notify words with "+" when it merges them onto one
            # cron line (IFS=+ at gen-cron.sh:3263). The owner asked for
            # commas. Done in the digest and not in gen-cron on purpose:
            # changing the join rewrites the label in every generated cron
            # line, so every host's crontab differs at the next regeneration.
            cat > "$hb_dir/bin/crontab" <<'CTPLUS'
#!/bin/sh
echo '1 * * * * echo "$(date -Is) ZFS-JOB BEGIN h hourly backup (a+b)" >>/var/log/x; /opt/s.sh "hdd/d/a,hdd/d/b"'
CTPLUS
            chmod +x "$hb_dir/bin/crontab"
            {   printf '%sT11:00:00+00:00 ZFS-JOB BEGIN h hourly backup (a+b)\n' "$_yd"
                printf '%sT11:00:04+00:00 ZFS-JOB END h hourly backup (a+b) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/q.processing" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _plus=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            # A MULTI-DATASET JOB DROPS ITS PARENTHETICAL AND LISTS THE
            # DATASETS UNDERNEATH, EACH WITH ITS OWN FIGURES.
            #
            # Owner, 2026-09-02. The parenthetical was what pushed the columns
            # out of line: a five-dataset job rendered as "daily backup
            # (vm-103-disk-0,vm-104-disk..." and every later column on that row
            # sat four characters right of its heading. The separate
            # "Co obejmuja" section went away with the move.
            #
            # The "+" gen-cron uses to merge notify words must not survive
            # anywhere in the mail; it is still translated for the UWAGA line,
            # which names the full label.
            #
            # The names print BARE here: this job is not a send job, so it has
            # no per-dataset figures, and a column of dashes would be the noise
            # the indentation exists to remove. The names still have to appear,
            # because dropping the parenthetical took away the only other place
            # the job states its scope.
            if ! printf '%s' "$_plus" | grep -q 'hourly backup (a+b)' \
               && ! printf '%s' "$_plus" | grep -q 'hourly backup (a,b)' \
               && printf '%s' "$_plus" | grep -qE '^ +hourly backup +[0-9]' \
               && printf '%s' "$_plus" | grep -qE '^ {6}hdd/d/a$' \
               && printf '%s' "$_plus" | grep -qE '^ {6}hdd/d/b$'; then
                ok "digest: a multi-dataset job summarises on its row and lists its datasets underneath"
            else
                bad "digest: a multi-dataset job summarises on its row and lists its datasets underneath" "$_plus"
            fi

            # ...and the datasets are listed ONCE. Both blocks name the same
            # jobs, so repeating them added ~50 duplicated lines to a 149-line
            # mail on pve0 -- measured, and the reason they live in the state
            # block alone.
            _cnt=$(printf '%s\n' "$_plus" | grep -c 'hdd/d/a')
            if [ "$_cnt" = "1" ]; then
                ok "digest: a dataset is listed once, not in both blocks"
            else
                bad "digest: a dataset is listed once, not in both blocks" "count=$_cnt" "$_plus"
            fi

            # THE RUN WINDOW IS A REAL FROM-TO, MEASURED.
            #
            # It used to read "PRZEBIEGI ZADAN (2026-09-01, 2026-09-02)" --
            # two dates and a comma, which states neither a range nor a list.
            # It also hid an asymmetry: the digest runs at 07:00, so "today"
            # is a PARTIAL day and an hourly job's count is yesterday's 24
            # plus this morning's few. Printing the first and last run
            # actually counted makes that arithmetic self-evident.
            if printf '%s' "$_plus" | grep -qE 'Liczby przebiegow z okresu [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' \
               && ! printf '%s' "$_plus" | grep -q 'PRZEBIEGI ZADAN' \
               && [ "$(printf '%s' "$_plus" | grep -n 'Liczby przebiegow' | cut -d: -f1)" \
                  -lt "$(printf '%s' "$_plus" | grep -n 'ostatni przebieg' | cut -d: -f1)" ]; then
                ok "digest: the measured window is stated ABOVE the columns it describes"
            else
                bad "digest: the measured window is stated ABOVE the columns it describes" "$_plus"
            fi

            # THE TIME COLUMNS DESCRIBE ONE RUN: last, average, worst.
            #
            # An earlier round put the WINDOW TOTAL next to the rate so the
            # division could be checked on the row. The owner replaced that:
            # "Naglowek czas laczny jest bez sensu. Ma byc czas ostatni, sredni
            # i maksymalny." Twenty-seven runs summed is not a quantity anyone
            # reads, and last/average/worst is the profile an operator wants.
            #
            # The rate keeps its window basis -- przyrost is a window figure
            # too, so anything else would divide one span by another. What the
            # column no longer shows, the caption now says outright; pinning
            # both is the point, because dropping the sentence would leave a
            # rate with no stated basis, which is where this started.
            #
            # And the caption must name a divisor the READER CAN SEE. It said
            # "LACZNY czas przebiegow" for a day after the column carrying that
            # total was removed -- a basis stated in terms of a number no longer
            # on the page. Owner, 2026-09-03, reading a real digest off pve9:
            # "mail w nieaktualnym formacie". avg x count IS that total, and
            # both factors are on the row, so the arithmetic stays checkable.
            _hdr=$(printf '%s' "$_plus" | grep -m1 'czas max')
            if printf '%s' "$_hdr" | grep -qE 'przyrost +transfer +czas ostatni +czas sr\. +czas max' \
               && printf '%s' "$_plus" | grep -qF 'Transfer = przyrost / (czas sr. x przebiegow)'; then
                ok "digest: the time columns are last/average/worst, and the rate says what it divided by"
            else
                bad "digest: the time columns are last/average/worst, and the rate says what it divided by" "$_hdr"
            fi

            # AND THE FIRST COLUMN IS THE LAST RUN, not the sum.
            #
            # Every other fixture here runs its job ONCE, where the sum and the
            # last run are the same number -- so none of them can tell the two
            # apart, and a control that reverted to the total passed. Two runs
            # of different length is the smallest thing that discriminates:
            # 2s then 9s gives last=9s, average=5s, worst=9s, and a total of
            # 11s that must appear nowhere.
            cat > "$hb_dir/bin/crontab" <<'CTLAST'
#!/bin/sh
echo '0 * * * * echo "$(date -Is) ZFS-JOB BEGIN h twice job (t)" >>/var/log/x; /opt/snapsend.sh "tank/t"'
CTLAST
            chmod +x "$hb_dir/bin/crontab"
            {   printf '%sT08:00:00+00:00 ZFS-JOB BEGIN h twice job (t)\n' "$_yd"
                printf '%sT08:00:02+00:00 ZFS-JOB END h twice job (t) rc=0\n' "$_yd"
                printf '%sT09:00:00+00:00 ZFS-JOB BEGIN h twice job (t)\n' "$_yd"
                printf '%sT09:00:09+00:00 ZFS-JOB END h twice job (t) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _lst=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_lst" | grep -qE 'twice job [(]t[)].* 9s +5s +9s *$' \
               && ! printf '%s' "$_lst" | grep -qE 'twice job [(]t[)].* 11s'; then
                ok "digest: the first time column is the LAST run, not the window sum"
            else
                bad "digest: the first time column is the LAST run, not the window sum" \
                    "$(printf '%s' "$_lst" | grep -E 'twice job')"
            fi


            # THE WINDOW IS SEVEN DAYS BY DEFAULT AND SETTABLE.
            #
            # The first cut hardcoded two calendar days and said so nowhere;
            # the owner had to ask what the window was. Seven is his answer,
            # ZFS_DIGEST_DAYS is the knob. A run five days old must be counted
            # by default and must vanish when the window is narrowed to two --
            # the pair is what proves the parameter is read, not merely present.
            _old5=$(date -d '-5 days' '+%Y-%m-%d' 2>/dev/null)
            {   printf '%sT08:00:00+00:00 ZFS-JOB BEGIN h weekly job (x)\n' "$_old5"
                printf '%sT08:00:06+00:00 ZFS-JOB END h weekly job (x) rc=0\n' "$_old5"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _w7=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)

            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                ZFS_DIGEST_DAYS=2 bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _w2=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)

            if printf '%s' "$_w7" | grep -q 'weekly job (x)' \
               && ! printf '%s' "$_w2" | grep -q 'weekly job (x)'; then
                ok "digest: the window is 7 days by default and ZFS_DIGEST_DAYS narrows it"
            else
                bad "digest: the window is 7 days by default and ZFS_DIGEST_DAYS narrows it" \
                    "7d: $_w7" "2d: $_w2"
            fi

            # GZIPPED ROTATED LOGS ARE READABLE. logrotate here runs monthly
            # with compress + delaycompress, so .1 is plain and .2+ are .gz.
            # Reading only the live file under-reports silently -- measured on
            # pve0: 35 runs over two days against 155 over seven, because the
            # month had rotated the day before.
            _gz="$hb_dir/rot.log"
            {   printf '%sT09:00:00+00:00 ZFS-JOB BEGIN h gz job (y)\n' "$_old5"
                printf '%sT09:00:03+00:00 ZFS-JOB END h gz job (y) rc=0\n' "$_old5"
            } > "$_gz"
            if gzip -f "$_gz" 2>/dev/null && [ -r "$_gz.gz" ]; then
                rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
                printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
                PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_gz.gz" \
                    bash "$hb_dir/digest.sh" >/dev/null 2>&1
                _wgz=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
                if printf '%s' "$_wgz" | grep -q 'gz job (y)'; then
                    ok "digest: a gzipped rotated log is read"
                else
                    bad "digest: a gzipped rotated log is read" "$_wgz"
                fi
            else
                bad "digest: a gzipped rotated log is read" "gzip unavailable in this environment"
            fi

            # A SCHEDULED JOB WITH NO RUN IN THE WINDOW IS STILL LISTED.
            #
            # Both halves of the old mail were built from the LOG, so a job
            # that is in cron but has not run inside the window appeared in
            # neither -- absent from a report that claims to state the current
            # state, and absence is the one thing an operator cannot notice.
            # Measured on pve0 2026-09-02: 26 jobs in cron, 24 with a run in a
            # 7-day window; the two missing were annual backups, which cannot
            # appear in a week.
            #
            # It is listed and NOT judged: a yearly job absent from seven days
            # is correct, and the digest does not know each job's cadence.
            cat > "$hb_dir/bin/crontab" <<'CTIDLE'
#!/bin/sh
echo '0 4 1 1 * echo "$(date -Is) ZFS-JOB BEGIN h annual backup (z)" >>/var/log/x; /opt/s.sh "hdd/d/z"'
CTIDLE
            chmod +x "$hb_dir/bin/crontab"
            : > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _idle=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_idle" | grep -q 'annual backup (z)' \
               && printf '%s' "$_idle" | grep -q 'brak przebiegu w oknie' \
               && printf '%s' "$_idle" | grep -q 'STAN: OK'; then
                ok "digest: a scheduled job with no run in the window is listed, and not judged"
            else
                bad "digest: a scheduled job with no run in the window is listed, and not judged" "$_idle"
            fi

            # VOLUME PER JOB, and the two ways it went wrong.
            #
            # Owner asked for transfer figures 2026-09-02 and chose the target
            # side. They are not in the logs at all, so they come from ZFS:
            # a snapshot's `written` summed over the window.
            #
            # (1) mawk clamps an integer conversion at INT_MAX, so every sum
            # above ~2.1 GB printed as exactly 2147483647 -- on pve0 three
            # unrelated jobs all showed "1G" because all three were clamped.
            # This fixture is 3 GiB in one snapshot: anything that says 1G or
            # 2G is the clamp coming back.
            #
            # (2) a PRUNE job adds nothing, so summing what grew under its
            # scope credits it with another job's data.
            # The received dataset is <target>/<source>, which is what
            # snapsend.sh actually writes (snapsend.sh:2570 -- only -t makes
            # the base the target). The stub used to put the snapshot on the
            # target ROOT, which passed only while the digest summed the whole
            # root and would have hidden the pve2 defect.
            cat > "$hb_dir/bin/zfs" <<'ZFSSTUB'
#!/bin/sh
case "$*" in
  *"-t snapshot"*)
    printf 'tank/dst/tank/src@a	3221225472	9999999999
'
    printf 'tank/src@a	111	9999999999
'
    ;;
esac
exit 0
ZFSSTUB
            chmod +x "$hb_dir/bin/zfs"
            cat > "$hb_dir/bin/crontab" <<'CTVOL'
#!/bin/sh
echo '0 * * * * echo "$(date -Is) ZFS-JOB BEGIN h vol backup (v)" >>/var/log/x; /opt/snapsend.sh "tank/src" "tank/dst"'
echo '5 * * * * echo "$(date -Is) ZFS-JOB BEGIN h vol prune (v)" >>/var/log/x; /opt/delsnaps.sh "tank/dst" "a_"'
CTVOL
            chmod +x "$hb_dir/bin/crontab"
            {   printf '%sT10:00:00+00:00 ZFS-JOB BEGIN h vol backup (v)\n' "$_yd"
                printf '%sT10:00:02+00:00 ZFS-JOB END h vol backup (v) rc=0\n' "$_yd"
                printf '%sT10:05:00+00:00 ZFS-JOB BEGIN h vol prune (v)\n' "$_yd"
                printf '%sT10:05:01+00:00 ZFS-JOB END h vol prune (v) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _vol=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_vol" | grep -qE 'vol backup [(]v[)].* 3\.00G'; then
                ok "digest: a 3 GiB volume reports as 3G (mawk INT_MAX clamp)"
            else
                bad "digest: a 3 GiB volume reports as 3G (mawk INT_MAX clamp)" "$_vol"
            fi
            if printf '%s' "$_vol" | grep -qE 'vol prune [(]v[)].*  -( |$)'; then
                ok "digest: a prune job is credited with no volume"
            else
                bad "digest: a prune job is credited with no volume" "$_vol"
            fi

            # PER-DATASET TIMES COME FROM THE ENGINE LOG, OR NOT AT ALL.
            #
            # The job markers carry ONE BEGIN/END for the whole job, so a
            # per-dataset duration looks impossible -- but the engines log each
            # transfer separately, and RECV CMD names the TARGET dataset, which
            # is the side "written" is measured on. Both halves therefore key on
            # the same name.
            #
            # This is the discriminating pair. Only send jobs have those blocks:
            # measured on pve0, 139 job runs and 18 transfers, because snapshot
            # and prune jobs transfer nothing. Their dataset rows must show a
            # volume and a DASH for time -- splitting the job's duration evenly
            # across its datasets would look measured and be invented.
            cat > "$hb_dir/bin/zfs" <<'ZFSDS'
#!/bin/sh
# 1.06 M each, chosen so the roundings DISAGREE: 1.1 + 1.1 = 2.2 while the
# exact sum (2.12 M) prints as 2.1. Round numbers close either way and would
# make the control below prove nothing.
case "$*" in
  *"-t snapshot"*)
    printf 'tgt/pool/hdd/d/a@s	1111491	9999999999
'
    printf 'tgt/pool/hdd/d/b@s	1111491	9999999999
'
    ;;
esac
exit 0
ZFSDS
            chmod +x "$hb_dir/bin/zfs"
            cat > "$hb_dir/bin/crontab" <<'CTDS'
#!/bin/sh
echo '0 * * * * echo "$(date -Is) ZFS-JOB BEGIN h ds backup (a+b)" >>/var/log/x; /opt/snapsend.sh "hdd/d/a,hdd/d/b" "tgt/pool"'
CTDS
            chmod +x "$hb_dir/bin/crontab"
            # Only dataset a has a transfer block; b was up to date that run.
            {   printf '%sT10:00:00+00:00 ZFS-JOB BEGIN h ds backup (a+b)\n' "$_yd"
                printf '%s 10:00:01 - EXECUTING TRANSFER:\n' "$_yd"
                printf '%s 10:00:01 - RECV CMD: zfs recv -F -s -u tgt/pool/hdd/d/a\n' "$_yd"
                printf '%s 10:00:09 - Transfer completed successfully\n' "$_yd"
                printf '%sT10:00:20+00:00 ZFS-JOB END h ds backup (a+b) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _dsr=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            # 8 s of transfer for a, and it must NOT be the job's 20 s.
            if printf '%s' "$_dsr" | grep -qE '^ {6}hdd/d/a .* 1\.06M .* 8s +8s +8s *$'; then
                ok "digest: a dataset with a transfer block carries its OWN time, not the job's"
            else
                bad "digest: a dataset with a transfer block carries its OWN time, not the job's" \
                    "$(printf '%s' "$_dsr" | grep -E 'hdd/d/[ab]')"
            fi
            if printf '%s' "$_dsr" | grep -qE '^ {6}hdd/d/b .* 1\.06M .* - +- +- *$'; then
                ok "digest: a dataset the engine never transferred gets a volume and NO invented time"
            else
                bad "digest: a dataset the engine never transferred gets a volume and NO invented time" \
                    "$(printf '%s' "$_dsr" | grep -E 'hdd/d/[ab]')"
            fi

            # ONE UNIT PER JOB, TWO DECIMALS.
            #
            # The bytes always summed exactly -- measured on pve0, the job total
            # and the sum of its datasets were the same 260980736 -- but each
            # value was rounded to its OWN unit before printing, so 211M + 37M
            # read as 248 under a total of 249, and a large job mixed units (42G
            # beside 467M) which no precision makes addable at all.
            #
            # Owner chose one unit per job. A round with ONE decimal derived the
            # job figure from the sum of the PRINTED rows so the column closed to
            # the last digit; he then asked for two decimals and the measurement
            # back -- "To nie apteka tylko raport". At two decimals the residue
            # is under 0.01 of a unit, so what is pinned here is the SHAPE:
            # shared unit, two decimals, total within a hundredth of the rows.
            # Digit-exact equality is deliberately NOT the contract any more.
            _sum=$(printf '%s
' "$_dsr" | awk '
                /^      [a-z]/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+[BKMGT]$/) { v = $i; sub(/[BKMGT]$/, "", v); s += v; break } }
                END { printf "%.2f", s }')
            _job=$(printf '%s
' "$_dsr" | awk '/^  ds backup / { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+[BKMGT]$/) { v = $i; sub(/[BKMGT]$/, "", v); printf "%.2f", v; exit } }')
            _close=$(awk -v a="$_sum" -v b="$_job" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d <= 0.011) ? "ok" : "off" }')
            if [ -n "$_job" ] && [ "$_close" = "ok" ] \
               && printf '%s' "$_dsr" | grep -qE '^ {6}hdd/d/a .* [0-9]+\.[0-9]{2}M '; then
                ok "digest: dataset rows share the job unit and carry two decimals"
            else
                bad "digest: dataset rows share the job unit and carry two decimals" \
                    "zadanie=$_job suma wierszy=$_sum" "$(printf '%s' "$_dsr" | grep -E 'ds backup|hdd/d/[ab]')"
            fi


            # TWO JOBS IN ONE LOG, OVERLAPPING. THE DISCRIMINATING CASE.
            #
            # Measured on pve0, 2026-09-02: jobs owned by the same account write
            # to the SAME cron.log and overlap, so that log holds two consecutive
            # ZFS-JOB BEGIN lines with no END between them. The engine's transfer
            # lines carry no job identity, so the first cut -- which bracketed
            # them between BEGIN and END -- credited them to whichever BEGIN it
            # had seen last. In a delivered mail that read as 17 transfers per
            # dataset instead of 27, three of the missing ones attributed to a
            # job that never writes to that target, and a "pozostale" remainder
            # inflated from 48s to 14m42s so the column would still close.
            #
            # Here the interloper's BEGIN sits BETWEEN the real job's BEGIN and
            # its transfer. Bracketing gives the transfer to the interloper;
            # keying on the dataset gives it to the job that owns the target.
            cat > "$hb_dir/bin/crontab" <<'CTLAP'
#!/bin/sh
echo '0 * * * * echo "$(date -Is) ZFS-JOB BEGIN h lap send (a)" >>/var/log/x; /opt/snapsend.sh "hdd/d/a,hdd/d/b" "tgt/pool"'
echo '1 * * * * echo "$(date -Is) ZFS-JOB BEGIN h lap other (z)" >>/var/log/x; /opt/snapsend.sh "hdd/d/z" "other/pool"'
CTLAP
            chmod +x "$hb_dir/bin/crontab"
            cat > "$hb_dir/bin/zfs" <<'ZFSLAP'
#!/bin/sh
case "$*" in
  *"-t snapshot"*)
    printf 'tgt/pool/hdd/d/a@s	4194304	9999999999
'
    printf 'tgt/pool/hdd/d/b@s	1048576	9999999999
'
    ;;
esac
exit 0
ZFSLAP
            chmod +x "$hb_dir/bin/zfs"
            {   printf '%sT10:00:00+00:00 ZFS-JOB BEGIN h lap send (a)\n' "$_yd"
                printf '%sT10:00:01+00:00 ZFS-JOB BEGIN h lap other (z)\n' "$_yd"
                printf '%s 10:00:02 - EXECUTING TRANSFER:\n' "$_yd"
                printf '%s 10:00:02 - RECV CMD: zfs recv -F -s -u tgt/pool/hdd/d/a\n' "$_yd"
                printf '%s 10:00:07 - Transfer completed successfully\n' "$_yd"
                printf '%sT10:00:08+00:00 ZFS-JOB END h lap other (z) rc=0\n' "$_yd"
                printf '%sT10:00:30+00:00 ZFS-JOB END h lap send (a) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _lap=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            # 5 s of transfer, on the job that owns tgt/pool -- not on the one
            # whose BEGIN happens to be the most recent.
            if printf '%s' "$_lap" | grep -qE '^ {6}hdd/d/a .* 4\.00M .* 5s +5s +5s *$'; then
                ok "digest: an overlapping job's BEGIN does not steal another job's transfer"
            else
                bad "digest: an overlapping job's BEGIN does not steal another job's transfer" \
                    "$(printf '%s' "$_lap" | grep -E 'lap (send|other)')"
            fi


            # The separate scope section is gone: its datasets are now rows of
            # the table itself, which is what made it redundant.
            if ! printf '%s' "$_dsr" | grep -q 'Co obejmuja'; then
                ok "digest: the separate scope section is gone -- the datasets are rows now"
            else
                bad "digest: the separate scope section is gone -- the datasets are rows now" "$_dsr"
            fi

            # A RUN THAT SKIPPED IS NOT A RUN THAT WORKED.
            #
            # snapsend.sh locks per DATASET, not per snapshot family, and the
            # loser exits ZERO. For the same job overlapping itself that is
            # right. For two DIFFERENT families it silently drops a snapshot
            # while still reporting rc=0, so the run table counts it as a
            # success.
            #
            # Measured on pve0, 2026-09-01 22:00: the daily and monthly jobs
            # fire in the same minute on hdd/lxc, the daily one lost the lock on
            # TWO datasets, and the only trace was a stats line nobody reads.
            # It surfaced 33 hours later as 57 queued "getting stale" warnings.
            #
            # The pair matters: a block that never appears would pass the first
            # assertion for the wrong reason.
            _stats="$hb_dir/stats.log"
            printf '{"time":"%sT20:00:02Z","script":"snapsend.sh","dataset":"hdd/lxc/subvol-105-disk-0","status":"skipped_lock","duration_s":0}\n' "$_yd" > "$_stats"
            printf '{"time":"%sT20:00:03Z","script":"snapsend.sh","dataset":"hdd/lxc/other","status":"success","duration_s":2}\n' "$_yd" >> "$_stats"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
            ZFS_STATS_LOGS="$_stats" bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _skp=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_skp" | grep -q 'POMINIETE PRZEZ BLOKADE' \
               && printf '%s' "$_skp" | grep -q 'hdd/lxc/subvol-105-disk-0' \
               && ! printf '%s' "$_skp" | grep -q 'hdd/lxc/other'; then
                ok "digest: a run skipped on the lock is named, and only that run"
            else
                bad "digest: a run skipped on the lock is named, and only that run" \
                    "$(printf '%s' "$_skp" | grep -A3 'POMINIETE' || echo '<bloku nie ma>')"
            fi

            # ...and it stays out of the way when nothing was skipped.
            printf '{"time":"%sT20:00:03Z","script":"snapsend.sh","dataset":"hdd/lxc/other","status":"success","duration_s":2}\n' "$_yd" > "$_stats"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
            ZFS_STATS_LOGS="$_stats" bash "$hb_dir/digest.sh" >/dev/null 2>&1
            if ! grep -q 'POMINIETE PRZEZ BLOKADE' "$hb_dir/bin/mail.out" 2>/dev/null; then
                ok "digest: no skipped run, no block about skipped runs"
            else
                bad "digest: no skipped run, no block about skipped runs" \
                    "$(grep -A3 'POMINIETE' "$hb_dir/bin/mail.out")"
            fi


            # A TIER IS NOT ITS WHOLE SCOPE.
            #
            # Rendered on pve1, 2026-09-02: five snapshot jobs over rpool/data,
            # and EVERY ONE of them reported 494G -- the volume summed every
            # snapshot under the scope regardless of which job had made it. Same
            # family of defect as the prune credited with 525 GB. The job's own
            # snapshot family comes off its cron line (-m "automated_hourly_"),
            # so the tiers stop overlapping.
            #
            # Two jobs, one dataset, one snapshot each: 1M and 2M. Either job
            # reporting 3M is the bug.
            cat > "$hb_dir/bin/zfs" <<'ZFSFAM'
#!/bin/sh
case "$*" in
  *"-t snapshot"*)
    printf 'tank/d@automated_hourly_1	1048576	9999999999
'
    printf 'tank/d@automated_daily_1	2097152	9999999999
'
    ;;
esac
exit 0
ZFSFAM
            chmod +x "$hb_dir/bin/zfs"
            cat > "$hb_dir/bin/crontab" <<'CTFAM'
#!/bin/sh
echo '0 * * * * echo "$(date -Is) ZFS-JOB BEGIN h hh snap (d)" >>/var/log/x; /opt/snapsend.sh -m "automated_hourly_" -r "tank/d"'
echo '9 0 * * * echo "$(date -Is) ZFS-JOB BEGIN h dd snap (d)" >>/var/log/x; /opt/snapsend.sh -m "automated_daily_" -r "tank/d"'
CTFAM
            chmod +x "$hb_dir/bin/crontab"
            {   printf '%sT10:00:00+00:00 ZFS-JOB BEGIN h hh snap (d)\n' "$_yd"
                printf '%sT10:00:02+00:00 ZFS-JOB END h hh snap (d) rc=0\n' "$_yd"
                printf '%sT10:09:00+00:00 ZFS-JOB BEGIN h dd snap (d)\n' "$_yd"
                printf '%sT10:09:02+00:00 ZFS-JOB END h dd snap (d) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _fam=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_fam" | grep -qE 'hh snap [(]d[)].* 1\.00M ' \
               && printf '%s' "$_fam" | grep -qE 'dd snap [(]d[)].* 2\.00M ' \
               && ! printf '%s' "$_fam" | grep -q ' 3\.00M '; then
                ok "digest: each snapshot tier counts only its OWN family, not the whole scope"
            else
                bad "digest: each snapshot tier counts only its OWN family, not the whole scope" \
                    "$(printf '%s' "$_fam" | grep -E 'snap [(]d[)]')"
            fi

            # AND TWO JOBS SHARING A TARGET DO NOT SHARE THEIR BYTES.
            #
            # The family filter separates TIERS. It does not separate two jobs
            # that write the same family into the same target root -- and that
            # is the ordinary shape of a collector. Measured on pve2, where four
            # jobs land in hdd/backups/pve2: "daily backup (BIM server)" and
            # "daily backup (root)" both reported 732.77M, each credited with the
            # other's bytes, and "hourly backup (nextcloud)" -- whose prefix is
            # the broad "automated_" -- was credited with 259.32G, the entire
            # backup pool for a week.
            #
            # A job owns <target>/<source> for each of its sources, and nothing
            # else. 2M and 1M must stay 2M and 1M; 3M anywhere is the bug.
            cat > "$hb_dir/bin/zfs" <<'ZFSSHARE'
#!/bin/sh
case "$*" in
  *"-t snapshot"*)
    printf 'tgt/pool/hdd/d/a@automated_daily_1	2097152	9999999999
'
    printf 'tgt/pool/hdd/d/b@automated_daily_1	1048576	9999999999
'
    ;;
esac
exit 0
ZFSSHARE
            chmod +x "$hb_dir/bin/zfs"
            cat > "$hb_dir/bin/crontab" <<'CTSHARE'
#!/bin/sh
echo '0 1 * * * echo "$(date -Is) ZFS-JOB BEGIN h aa job (a)" >>/var/log/x; /opt/snapsend.sh -m "automated_daily_" "hdd/d/a" "tgt/pool"'
echo '0 2 * * * echo "$(date -Is) ZFS-JOB BEGIN h bb job (b)" >>/var/log/x; /opt/snapsend.sh -m "automated_daily_" "hdd/d/b" "tgt/pool"'
CTSHARE
            chmod +x "$hb_dir/bin/crontab"
            {   printf '%sT01:00:00+00:00 ZFS-JOB BEGIN h aa job (a)\n' "$_yd"
                printf '%sT01:00:02+00:00 ZFS-JOB END h aa job (a) rc=0\n' "$_yd"
                printf '%sT02:00:00+00:00 ZFS-JOB BEGIN h bb job (b)\n' "$_yd"
                printf '%sT02:00:02+00:00 ZFS-JOB END h bb job (b) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _shr=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_shr" | grep -qE 'aa job [(]a[)].* 2\.00M ' \
               && printf '%s' "$_shr" | grep -qE 'bb job [(]b[)].* 1\.00M ' \
               && ! printf '%s' "$_shr" | grep -q ' 3\.00M '; then
                ok "digest: two jobs sharing a target are not credited with each other's bytes"
            else
                bad "digest: two jobs sharing a target are not credited with each other's bytes" \
                    "$(printf '%s' "$_shr" | grep -E '(aa|bb) job')"
            fi

            # A PRUNE IS NOT A CLAIMANT.
            #
            # The ambiguity guard refuses per-dataset times when two jobs could
            # have written the same dataset. It counted PRUNE jobs too, and a
            # prune over the receive root claims every dataset under it: on pve2
            # "gfs prune (backups)" covers hdd/backups, so every dataset row on
            # that host lost its times to a guard with nothing to guard against.
            # A prune lands no bytes and cannot be the author of a transfer.
            cat > "$hb_dir/bin/crontab" <<'CTPRUNE'
#!/bin/sh
echo '0 1 * * * echo "$(date -Is) ZFS-JOB BEGIN h pp send (a)" >>/var/log/x; /opt/snapsend.sh -m "automated_daily_" "hdd/d/a" "tgt/pool"'
echo '0 5 * * * /opt/zfs-job.sh "h pp prune (all)" -- /opt/delsnaps.sh "tgt/pool" "automated_daily" -D7'
CTPRUNE
            chmod +x "$hb_dir/bin/crontab"
            cat > "$hb_dir/bin/zfs" <<'ZFSPRUNE'
#!/bin/sh
case "$*" in
  *"-t snapshot"*)
    printf 'tgt/pool/hdd/d/a@automated_daily_1	2097152	9999999999
'
    ;;
esac
exit 0
ZFSPRUNE
            chmod +x "$hb_dir/bin/zfs"
            {   printf '%sT01:00:00+00:00 ZFS-JOB BEGIN h pp send (a)\n' "$_yd"
                printf '%s 01:00:01 - EXECUTING TRANSFER:\n' "$_yd"
                printf '%s 01:00:01 - RECV CMD: zfs recv -F -s -u tgt/pool/hdd/d/a\n' "$_yd"
                printf '%s 01:00:07 - Transfer completed successfully\n' "$_yd"
                printf '%sT01:00:20+00:00 ZFS-JOB END h pp send (a) rc=0\n' "$_yd"
            } > "$_fakelog"
            rm -f "$hb_dir/q" "$hb_dir/bin/mail.out"
            printf '%s\tWARN\tcos\tszczegol\n' "$(date +%s)" > "$hb_dir/q"
            PATH="$hb_dir/bin:$PATH" ZFS_ALERT_QUEUE="$hb_dir/q" ZFS_CRON_LOGS="$_fakelog" \
                bash "$hb_dir/digest.sh" >/dev/null 2>&1
            _prn=$(cat "$hb_dir/bin/mail.out" 2>/dev/null)
            if printf '%s' "$_prn" | grep -qE '^ {6}hdd/d/a .* 6s +6s +6s *$'; then
                ok "digest: a prune over the receive root does not suppress a dataset's times"
            else
                bad "digest: a prune over the receive root does not suppress a dataset's times" \
                    "$(printf '%s' "$_prn" | grep -E 'pp send|hdd/d/a')"
            fi


            # AND A RATE NEEDS SOMETHING TO HAVE MOVED. A local snapshot job
            # carries nothing across a link and its duration is the second the
            # snapshot took, not the hour the data was written over. Dividing
            # one by the other produced "494G/s" on pve1 -- not so much wrong as
            # meaningless.
            if printf '%s' "$_fam" | grep -qE 'hh snap [(]d[)].* 1\.00M +- ' ; then
                ok "digest: a job with no target gets no transfer rate"
            else
                bad "digest: a job with no target gets no transfer rate" \
                    "$(printf '%s' "$_fam" | grep -E 'snap [(]d[)]')"
            fi

            # THE CAPTION TRACKS THE ROWS, whichever way that falls.
            #
            # It used to be pinned as a pair -- present here, absent there --
            # and the "absent" half stopped being reachable when the owner chose
            # to expand EVERY job rather than only multi-dataset ones. A test
            # that pins an unreachable state is a test that fails for being
            # right, so what is pinned now is the invariant surviving both
            # rules: the caption is there exactly when an indented row is.
            _ind=$(printf '%s\n' "$_fam" | grep -c '^      ' || true)
            _cap=$(printf '%s\n' "$_fam" | grep -c 'Wiersze wciete' || true)
            if { [ "$_ind" -gt 0 ] && [ "$_cap" -gt 0 ]; } || { [ "$_ind" -eq 0 ] && [ "$_cap" -eq 0 ]; }; then
                ok "digest: the indented-rows caption is present exactly when rows are indented"
            else
                bad "digest: the indented-rows caption is present exactly when rows are indented" \
                    "wierszy wcietych=$_ind podpisow=$_cap"
            fi

            # ...and the table still stands off from the prose above it. The
            # blank line used to hang off the LAST caption line, so on a host
            # with nothing indented it vanished with the caption and the header
            # sat flush against the sentence before it. It belongs to the table.
            if printf '%s' "$_fam" | grep -B1 'zadanie  *ostatni przebieg' | head -1 | grep -qE '^[[:space:]]*$'; then
                ok "digest: a blank line separates the caption from the table, caption or not"
            else
                bad "digest: a blank line separates the caption from the table, caption or not" \
                    "$(printf '%s' "$_fam" | grep -B2 'zadanie  *ostatni przebieg')"
            fi


            # ...and the negative control: the multi-dataset render DOES carry
            # it. Without this pair, deleting the caption outright would pass.
            if printf '%s' "$_dsr" | grep -q 'Wiersze wciete'; then
                ok "digest: the caption IS present when the table has indented rows"
            else
                bad "digest: the caption IS present when the table has indented rows" "$_dsr"
            fi



            rm -f "$hb_dir/bin/zfs"
        fi
    fi
    rm -rf "$hb_dir"
fi


# ---------------------------------------------------------------------------
# HOST HEALTH v4: pool state and stalled transfers.
#
# Same file, same finding class as everything above -- a claim of health the
# evidence does not support, in two shapes this estate has ALREADY paid for:
#   * pve1's rpool sat DEGRADED for weeks with zero alerts, because capacity
#     was checked daily and health was checked nowhere;
#   * a hung transfer never exits, so the job-level alert (which fires on a
#     non-zero EXIT) is structurally silent about it. The progress data layer
#     exists precisely so something can notice; this is the something.
#
# Runs the REAL shipped script (hostscripts/check-pool-capacity.sh, zpool/zfs
# stubbed, notify captured). The negative controls matter as much as the
# positives: an ONLINE pool, a live transfer and a FINISHED old record must
# stay silent -- an alert that fires either way teaches people to filter it.
# ---------------------------------------------------------------------------
if [ ! -r "$HS/check-pool-capacity.sh" ]; then
    bad "the capacity script ships as a file in hostscripts/" "missing under $HS"
else
    hv_dir=$(mktemp -d)
    cp "$HS/check-pool-capacity.sh" "$hv_dir/check.sh"
    cp "$HS/alert-env.sh"           "$hv_dir/alert-env.sh"
    mkdir -p "$hv_dir/bin" "$hv_dir/prog"
    cat > "$hv_dir/bin/zpool" <<'ST'
#!/bin/bash
case "$*" in
  "list -H o name"*|"list -H -o name") echo rpool; echo hdd ;;
  *"-o capacity"*) echo "42%" ;;
  *"-o health rpool") echo "$HV_RPOOL_HEALTH" ;;
  *"-o health hdd") echo ONLINE ;;
  "status rpool") echo "  state: $HV_RPOOL_HEALTH"; echo "  scan: resilver in progress" ;;
esac
ST
    printf '#!/bin/bash\nexit 0\n' > "$hv_dir/bin/zfs"
    printf '#!/bin/bash\nprintf "%%s\n" "$1" >> "$NLOG"\n' > "$hv_dir/bin/notify.sh"
    chmod +x "$hv_dir/bin/"*
    hv_now=$(date +%s)
    printf '{"dataset":"hdd/x@s","label":"pve2","state":"running","updated_epoch":%s}\n' $((hv_now-3600)) > "$hv_dir/prog/dead.json"
    printf '{"dataset":"hdd/y@s","label":"pve2","state":"running","updated_epoch":%s}\n' $((hv_now-10))   > "$hv_dir/prog/live.json"
    printf '{"dataset":"hdd/z@s","label":"pve2","state":"ok","updated_epoch":%s}\n'      $((hv_now-9000)) > "$hv_dir/prog/done.json"

    : > "$hv_dir/alerts"
    HV_RPOOL_HEALTH=DEGRADED NLOG="$hv_dir/alerts" PATH="$hv_dir/bin:$PATH" \
        ZFS_NOTIFY_SCRIPT="$hv_dir/bin/notify.sh" ZFS_PROGRESS_DIR="$hv_dir/prog" \
        bash "$hv_dir/check.sh" >/dev/null 2>&1
    if grep -q "rpool.*DEGRADED" "$hv_dir/alerts"; then
        ok "health: a DEGRADED pool is a finding"
    else
        bad "health: a DEGRADED pool is a finding" "alerty: $(cat "$hv_dir/alerts")"
    fi
    if grep -q "hdd/x@s.*bez pulsu" "$hv_dir/alerts"; then
        ok "health: a running record with no heartbeat for 30+ min is a finding"
    else
        bad "health: a running record with no heartbeat for 30+ min is a finding" "alerty: $(cat "$hv_dir/alerts")"
    fi
    if ! grep -qE "hdd/y@s|hdd/z@s|'hdd'" "$hv_dir/alerts"; then
        ok "health: a live transfer, a finished record and an ONLINE pool stay silent"
    else
        bad "health: a live transfer, a finished record and an ONLINE pool stay silent" "alerty: $(cat "$hv_dir/alerts")"
    fi

    : > "$hv_dir/alerts"
    HV_RPOOL_HEALTH=ONLINE NLOG="$hv_dir/alerts" PATH="$hv_dir/bin:$PATH" \
        ZFS_NOTIFY_SCRIPT="$hv_dir/bin/notify.sh" ZFS_PROGRESS_DIR="$hv_dir/empty" \
        bash "$hv_dir/check.sh" >/dev/null 2>&1
    if [ ! -s "$hv_dir/alerts" ]; then
        ok "health: a fully healthy host emits nothing at all"
    else
        bad "health: a fully healthy host emits nothing at all" "alerty: $(cat "$hv_dir/alerts")"
    fi

    # ---- THE PROBE ITSELF (advisory on PR #131) ---------------------------
    # The assertion directly above is what made these necessary: "a healthy host
    # emits nothing" and "the probe failed" produced the SAME output, so the
    # suite could not tell them apart and neither could the operator. A check
    # whose failure is silence is a check that is not running.
    hv_probe() {   # <zpool stub body> -> alerts produced
        cat > "$hv_dir/bin/zpool" <<ST
#!/bin/bash
$1
ST
        chmod +x "$hv_dir/bin/zpool"
        : > "$hv_dir/alerts"
        HV_RPOOL_HEALTH=ONLINE NLOG="$hv_dir/alerts" PATH="$hv_dir/bin:$PATH" \
            ZFS_NOTIFY_SCRIPT="$hv_dir/bin/notify.sh" ZFS_PROGRESS_DIR="$hv_dir/empty" \
            bash "$hv_dir/check.sh" >/dev/null 2>&1
        cat "$hv_dir/alerts"
    }

    # 1. enumeration fails outright
    a="$(hv_probe 'echo "cannot open ZFS" >&2; exit 1')"
    printf '%s' "$a" | grep -q 'sonda pul.*PADLA' \
        && ok "probe: a FAILED pool enumeration is a finding, not silence" \
        || bad "probe: a failed pool enumeration is a finding" "alerty: ${a:-<cisza>}"

    # 2. enumeration succeeds and reports no pools at all
    a="$(hv_probe 'case "$*" in *"-o name") exit 0 ;; *) exit 0 ;; esac')"
    printf '%s' "$a" | grep -q 'ZERO pul' \
        && ok "probe: ZERO imported pools is a finding of its own, not 'nothing to check'" \
        || bad "probe: zero imported pools is a finding" "alerty: ${a:-<cisza>}"

    # 3. enumeration works, the probe SUCCEEDS but answers nothing for one pool.
    #    Distinct from case 5 below, where the probe fails outright: an empty
    #    answer and a non-zero status are two different silences, and the
    #    operator is told which one happened.
    a="$(hv_probe 'case "$*" in
  *"-o name") echo rpool; echo hdd ;;
  *"-o capacity"*) echo "42%" ;;
  *"-o health rpool") exit 0 ;;
  *"-o health hdd") echo ONLINE ;;
esac')"
    { printf '%s' "$a" | grep -q "nie odczytano stanu puli 'rpool'" \
      && ! printf '%s' "$a" | grep -q "puli 'hdd'"; } \
        && ok "probe: an unreadable HEALTH is a finding for THAT pool, and the readable one stays silent" \
        || bad "probe: an unreadable health is a finding for that pool" "alerty: ${a:-<cisza>}"

    # 4. same for capacity: rc=0 with nothing to parse
    a="$(hv_probe 'case "$*" in
  *"-o name") echo rpool ;;
  *"-o capacity"*) exit 0 ;;
  *"-o health"*) echo ONLINE ;;
esac')"
    printf '%s' "$a" | grep -q "nie odczytano pojemnosci puli 'rpool'" \
        && ok "probe: an unreadable CAPACITY is a finding, not a shell error and no alert" \
        || bad "probe: an unreadable capacity is a finding" "alerty: ${a:-<cisza>}"

    # 5. THE PROBE SUCCEEDED is a different question from THE OUTPUT LOOKS
    #    RIGHT. A command that prints the single most reassuring word on the
    #    host and then exits non-zero has established nothing.
    a="$(hv_probe 'case "$*" in
  *"-o name") echo rpool ;;
  *"-o capacity"*) echo "42%" ;;
  *"-o health"*) echo ONLINE; exit 1 ;;
esac')"
    printf '%s' "$a" | grep -q "sonda stanu puli 'rpool'.*PADLA" \
        && ok "probe: health printing ONLINE and then FAILING is a probe failure, not ONLINE" \
        || bad "probe: health printing ONLINE and then failing is a probe failure" "alerty: ${a:-<cisza>}"

    # 6. ...and the same for capacity, where the status used to be lost to a
    #    pipe: `zpool ... | tr -d '%'` reports tr's status, never zpool's.
    a="$(hv_probe 'case "$*" in
  *"-o name") echo rpool ;;
  *"-o capacity"*) echo "42%"; exit 1 ;;
  *"-o health"*) echo ONLINE ;;
esac')"
    printf '%s' "$a" | grep -q "sonda pojemnosci puli 'rpool'.*PADLA" \
        && ok "probe: capacity printing 42% and then FAILING is a probe failure, not a reading" \
        || bad "probe: capacity printing 42% and then failing is a probe failure" "alerty: ${a:-<cisza>}"

    # 7. CONTROL: with every probe answering, the healthy host is still silent.
    #    Without this the four above would pass just as well against a script
    #    that alerts unconditionally -- which is the other way to be useless.
    a="$(hv_probe 'case "$*" in
  *"-o name") echo rpool ;;
  *"-o capacity"*) echo "42%" ;;
  *"-o health"*) echo ONLINE ;;
esac')"
    [ -z "$a" ] \
        && ok "probe control: when every probe answers and all is well, still nothing is emitted" \
        || bad "probe control: a healthy host stays silent" "alerty: $a"

    rm -rf "$hv_dir"
fi

# ---------------------------------------------------------------------------
# host-scripts: deploy.sh INSTALLS the files it ships, and "current" is the
# file (2026-09-03). host_script_ensure replaced four heredoc installers whose
# "already current" was a version marker somebody had to remember to bump --
# and on 2026-09-02 did not, so both live hosts kept alert-digest.sh v9 through
# thirteen merged revisions. Now current means byte-identical to the checkout
# and executable when it should be; anything else is upgraded on a plain run
# and only REPORTED under --check-only. Lifted from the real deploy.sh, run
# against a throwaway target; the discriminating control is main, where the
# function does not exist (product_fn ends the suite) and four heredoc
# openers remain (the count above).
# ---------------------------------------------------------------------------
. "$SCRIPT_DIR/../harness.sh"
hs_run() {   # <CHECK_ONLY> <target> [args of host_script_ensure after the target...]
    ( set -u
      _DEPLOY_DIR="$(dirname "$DEPLOY_SRC")"; CHECK_ONLY="$1"; PROBLEMS=0
      die() { echo "FATAL: $*" >&2; exit 1; }
      log() { echo ">>> $*"; }; warn() { echo "!!! $*" >&2; PROBLEMS=$((PROBLEMS+1)); }
      HOST_SCRIPTS_DIR="$_DEPLOY_DIR/hostscripts"
      eval "$(product_fn "$DEPLOY_SRC" host_script_ensure)"
      host_script_ensure notify-warn.sh "$2" 0755 "lost" "wrong" ) 2>&1
}
hs_dir=$(mktemp -d); hs_t="$hs_dir/notify-warn.sh"
out=$(hs_run 0 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$HS/notify-warn.sh" "$hs_t" && [ -x "$hs_t" ] \
   && printf '%s' "$out" | grep -q "installed $hs_t from hostscripts/notify-warn.sh"; then
    ok "host-scripts: a missing target is installed byte-identical to hostscripts/ and executable"
else
    bad "host-scripts: a missing target is installed byte-identical to hostscripts/ and executable" "rc=$rc" "$out"
fi
out=$(hs_run 0 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "already current, leaving it alone" \
   && ! printf '%s' "$out" | grep -q "installed"; then
    ok "host-scripts: an identical, executable target is left alone"
else
    bad "host-scripts: an identical, executable target is left alone" "rc=$rc" "$out"
fi
printf '#!/bin/bash\n# notify-warn.sh v7 -- the marker an old install carried\necho old\n' > "$hs_t"; chmod 755 "$hs_t"
out=$(hs_run 1 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "present but not the checkout's copy (wrong)" \
   && grep -q '^echo old$' "$hs_t"; then
    ok "host-scripts: --check-only reports an old copy and writes nothing"
else
    bad "host-scripts: --check-only reports an old copy and writes nothing" "rc=$rc" "$out" "$(head -3 "$hs_t")"
fi
out=$(hs_run 0 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$HS/notify-warn.sh" "$hs_t" \
   && printf '%s' "$out" | grep -q "is not the checkout's copy -- upgrading (wrong)"; then
    ok "host-scripts: a plain run upgrades an old copy to the shipped file (no marker to bump)"
else
    bad "host-scripts: a plain run upgrades an old copy to the shipped file (no marker to bump)" "rc=$rc" "$out"
fi
chmod 644 "$hs_t"
out=$(hs_run 1 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "present but not the checkout's copy"; then
    ok "host-scripts: identical content that is not executable is not current (the file must RUN)"
else
    bad "host-scripts: identical content that is not executable is not current (the file must RUN)" "rc=$rc" "$out"
fi
out=$(hs_run 0 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && [ -x "$hs_t" ] && printf '%s' "$out" | grep -q "installed $hs_t"; then
    ok "host-scripts: ...and a plain run reinstalls it executable"
else
    bad "host-scripts: ...and a plain run reinstalls it executable" "rc=$rc" "$out"
fi
rm -f "$hs_t"
out=$(hs_run 1 "$hs_t"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$hs_t missing -- lost" && [ ! -e "$hs_t" ]; then
    ok "host-scripts: --check-only names a missing script and what is lost without it"
else
    bad "host-scripts: --check-only names a missing script and what is lost without it" "rc=$rc" "$out"
fi
out=$( ( set -u
      _DEPLOY_DIR="$hs_dir/nowhere"; CHECK_ONLY=0
      die() { echo "FATAL: $*" >&2; exit 1; }
      log() { echo ">>> $*"; }; warn() { echo "!!! $*" >&2; }
      HOST_SCRIPTS_DIR="$_DEPLOY_DIR/hostscripts"
      eval "$(product_fn "$DEPLOY_SRC" host_script_ensure)"
      host_script_ensure notify-warn.sh "$hs_t" 0755 "lost" "wrong"; echo REACHED ) 2>&1 ); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "this checkout is incomplete" && ! printf '%s' "$out" | grep -q REACHED && [ ! -e "$hs_t" ]; then
    ok "host-scripts: a checkout without hostscripts/ is refused before anything is written"
else
    bad "host-scripts: a checkout without hostscripts/ is refused before anything is written" "rc=$rc" "$out"
fi
# The shipped scripts source alert-env.sh from beside themselves, loudly.
mkdir -p "$hs_dir/alone"; cp "$HS/notify-fail.sh" "$hs_dir/alone/notify-fail.sh"
out=$(ZFS_ALERT_QUEUE="$hs_dir/q" bash "$hs_dir/alone/notify-fail.sh" job detail 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "cannot source alert-env.sh next to this script" && [ ! -e "$hs_dir/q" ]; then
    ok "host-scripts: notify-fail.sh without its alert-env.sh refuses by name instead of guessing its config"
else
    bad "host-scripts: notify-fail.sh without its alert-env.sh refuses by name instead of guessing its config" "rc=$rc" "$out"
fi
cp "$HS/alert-env.sh" "$hs_dir/alone/alert-env.sh"
out=$(ZFS_ALERT_CONF=/dev/null ZFS_ALERT_MODE=daily ZFS_ALERT_QUEUE="$hs_dir/q" ZFS_ALERT_STATE_DIR="$hs_dir/st" \
      bash "$hs_dir/alone/notify-fail.sh" job detail 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -s "$hs_dir/q" ] && grep -q 'job' "$hs_dir/q"; then
    ok "host-scripts: ...and with it beside, the same file queues the finding (env wins over the conf)"
else
    bad "host-scripts: ...and with it beside, the same file queues the finding (env wins over the conf)" "rc=$rc" "$out" "$(cat "$hs_dir/q" 2>/dev/null)"
fi
rm -rf "$hs_dir"

# ---------------------------------------------------------------------------
# U35 BEZPIECZNIK POJEMNOSCI (hostscripts/capacity-guard.sh, wlasciciel 2026-10-20;
# fail-closed po GitHub #655, 2026-10-20).
# Prawdziwy skrypt, zpool/zfs zastapione: kazde zfs destroy obniza zajetosc o GS_STEP.
# Wlasnosc z ZARZADZANYCH linii crona (katalog crontabow podstawiony), nie z nazwy.
# Sprawdza: wylaczony domyslnie; tylko rodziny z jawnego wzorca lokalnej linii
# delsnaps (nie __replicate_, vzdump, reczne, outsider_automated_*, nie dataset bez
# linii, nie wzorzec ""); nie pod hold; najnowsza w datasecie zostaje; baza z zakladki
# #tgt- zostaje; zrodlo transferu bez zakladki -> zablokowane; N najnowszych w
# rodzinie; od najdrobniejszego szczebla i najstarszej, stop ponizej celu; KAZDY blad
# odczytu (crontaby, zfs list migawek/zakladek, zly wiersz, nieznana linia transferu,
# brak wlasnosci) -> 0 usuniec, rc 1, alert; kolejnosc ustawien env > settings > conf.
# ---------------------------------------------------------------------------
gs_dir=$(mktemp -d); mkdir -p "$gs_dir/bin" "$gs_dir/cron" "$gs_dir/peers"
cp "$HS/capacity-guard.sh" "$gs_dir/guard.sh"; cp "$HS/alert-env.sh" "$gs_dir/alert-env.sh"
cat > "$gs_dir/bin/zpool" <<'ST'
#!/bin/bash
gs_capmode() {   # <tryb> <wartosc dobra>
    case "$1" in
      fail)  echo "95%"; exit 1 ;;     # czesciowe wyjscie i kod bledu
      nan)   echo "NaN"; exit 0 ;;
      empty) echo ""; exit 0 ;;
      *)     echo "$2" ;;
    esac
}
case "$*" in
  "list -H -o name")
      [ -n "${GS_POOLS_FAIL:-}" ] && { echo tank; exit 1; }
      [ -n "${GS_POOLS_EMPTY:-}" ] && exit 0
      echo tank; [ -n "${GS_TWO:-}" ] && echo zbad; exit 0 ;;
  "list -H -o capacity zbad") gs_capmode "${GS_ZBAD_MODE:-fail}" "95%" ;;
  "list -H -o capacity tank")
      if [ -n "${GS_TANK_MODE:-}" ]; then gs_capmode "$GS_TANK_MODE" "$(cat "$GS_DIR/cap")%"
      elif [ -n "${GS_BADCAP:-}" ] && [ -s "$GS_DIR/destroyed" ]; then echo "-"; else echo "$(cat "$GS_DIR/cap")%"; fi ;;
  "sync tank") [ -n "${GS_FAIL_SYNC:-}" ] && exit 1; : ;;
esac
ST
cat > "$gs_dir/bin/zfs" <<'ST'
#!/bin/bash
echo "zfs $*" >> "$GS_DIR/calls"
case "$*" in
  *"-t snapshot"*) [ -n "${GS_FAIL_SNAPS:-}" ] && { echo "cannot iterate" >&2; cat "$GS_DIR/snaps" | head -2; exit 1; }; cat "$GS_DIR/snaps" ;;
  *"-t bookmark"*) [ -n "${GS_FAIL_MARKS:-}" ] && { echo "cannot iterate" >&2; exit 1; }; cat "$GS_DIR/marks" 2>/dev/null ;;
  destroy*) echo "$2" >> "$GS_DIR/destroyed"; echo $(( $(cat "$GS_DIR/cap") - GS_STEP )) > "$GS_DIR/cap" ;;
esac
ST
printf '#!/bin/bash\nprintf "%%s\n%%s\n" "$1" "$2" >> "$GS_DIR/mail"\n' > "$gs_dir/bin/notify"
chmod +x "$gs_dir/bin/"* "$gs_dir/guard.sh"
gs_snaps() {   # name creation userrefs guid
    printf 'tank/a@automated_hourly_0\t50\t1\t1000\n'
    printf 'tank/a@automated_hourly_1\t100\t0\t1001\ntank/a@automated_hourly_2\t200\t0\t1002\ntank/a@automated_hourly_3\t300\t0\t1003\ntank/a@automated_hourly_4\t400\t0\t1004\n'
    printf 'tank/a@automated_daily_1\t150\t0\t1011\ntank/a@automated_daily_2\t250\t0\t1012\ntank/a@automated_daily_3\t350\t0\t1013\n'
    printf 'tank/a@__replicate_101_0_1\t10\t0\t1021\ntank/a@vzdump\t20\t0\t1022\ntank/a@reczna\t5\t0\t1023\n'
    printf 'tank/a@outsider_automated_hourly_001\t1\t0\t1031\ntank/a@outsider_automated_hourly_002\t2\t0\t1032\ntank/a@outsider_automated_hourly_003\t3\t0\t1033\n'
    printf 'tank/b@pve9_automated_hourly_1\t60\t0\t2001\ntank/b@pve9_automated_hourly_2\t70\t0\t2002\ntank/b@pve9_automated_hourly_3\t80\t0\t2003\n'
    printf 'tank/c@automated_hourly_1\t30\t0\t3001\ntank/c@automated_hourly_2\t31\t0\t3002\ntank/c@automated_hourly_3\t32\t0\t3003\ntank/c@automated_hourly_4\t33\t0\t3004\n'
}
GS_J='/r/zfs-job.sh "h prune" --log=/l --notify=/n --detail=8 --'
gs_cron() {   # [extra managed lines...] -> crontab "root" with the standard ownership lines
    {
        echo "# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)"
        echo "21 * * * * $GS_J /r/delsnaps.sh -L x \"tank/a\" \"automated_hourly\" -H24"
        echo "22 1 * * * $GS_J /r/delsnaps.sh -L x -P \"vzdump:2\" \"tank/a\" \"automated_daily\" -D30"
        echo "23 * * * * $GS_J /r/delsnaps.sh \"tank/b\" \"pve9_automated_hourly\" -H24"
        echo "24 * * * * $GS_J /r/delsnaps.sh -R -L y \"tank/c\" \"\" -H24"
        echo "25 * * * * $GS_J /r/delsnaps.sh -L z -K /k \"root@far:tank/c\" \"automated_hourly\" -H24"
        for l in "$@"; do echo "$l"; done
        echo "# END zfs-backup-managed"
        echo "26 * * * * /r/delsnaps.sh \"tank/c\" \"automated_hourly\" -H1"   # poza blokiem: nie nasza
    } > "$gs_dir/cron/root"
}
gs_run() {   # <cap> <step> <settings guard> [args] -> rc; destroyed/mail/out in $gs_dir
    rm -f "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/calls"; echo "$1" > "$gs_dir/cap"
    [ -s "$gs_dir/snaps" ] || gs_snaps > "$gs_dir/snaps"
    printf '[capacity]\nguard = %s\nguard_at = 89\nguard_target = 85\nguard_min_keep = %s\n' "$3" "${GS_KEEP:-2}" > "$gs_dir/settings.ini"
    local cap="$1" step="$2"; shift 3
    ( [ -n "${GS_ENV_KEEP:-}" ] || unset ZFS_GUARD ZFS_GUARD_AT ZFS_GUARD_TARGET ZFS_GUARD_MIN_KEEP
      PATH="$gs_dir/bin:$PATH" GS_DIR="$gs_dir" GS_STEP="$step" SETTINGS_FILE="$gs_dir/settings.ini" \
      ZFS_ALERT_CONF="${GS_CONF:-/dev/null}" ZFS_GUARD_CRONTABS="${GS_CRON:-$gs_dir/cron}" ZFS_GUARD_PEERS="$gs_dir/peers" \
      ZFS_NOTIFY_SCRIPT="$gs_dir/bin/notify" ZFS_GUARD_LOCK="$gs_dir/lock" bash "$gs_dir/guard.sh" "$@" ) > "$gs_dir/out" 2>&1
}
gs_none() { [ ! -s "$gs_dir/destroyed" ]; }
gs_tag() { printf '%s\0%s' "$1" "${2:-}" | md5sum | cut -c1-8; }   # jak bookmark_target_tag silnika
gs_cron
gs_snaps > "$gs_dir/snaps"; : > "$gs_dir/marks"

gs_run 95 3 off; gs_rc=$?
if [ "$gs_rc" -eq 0 ] && gs_none && [ ! -s "$gs_dir/mail" ]; then
    ok "capacity-guard: guard = off (domyslnie) -- przy 95% nic nie usuwa i nie wysyla"
else
    bad "capacity-guard: off" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/out" 2>/dev/null)"
fi
gs_run 92 3 on; gs_rc=$?
gs_got="$(tr '\n' ' ' < "$gs_dir/destroyed" 2>/dev/null)"
if [ "$gs_rc" -eq 0 ] && [ "$gs_got" = 'tank/b@pve9_automated_hourly_1 tank/a@automated_hourly_1 tank/a@automated_hourly_2 ' ] \
   && grep -q 'wyczyścił pulę tank (83%)' "$gs_dir/mail"; then
    ok "capacity-guard: od najdrobniejszego szczebla i najstarszej, stop ponizej celu (92 -> 83%), mail z lista; hold, __replicate_, vzdump, reczne i 2 najnowsze nietkniete"
else
    bad "capacity-guard: kolejnosc i stop" "rc=$gs_rc" "got: $gs_got" "$(cat "$gs_dir/out" "$gs_dir/mail" 2>/dev/null)"
fi
gs_run 99 1 on; gs_rc=$?
gs_got="$(tr '\n' ' ' < "$gs_dir/destroyed" 2>/dev/null)"
if [ "$gs_rc" -eq 1 ] && [ "$gs_got" = 'tank/b@pve9_automated_hourly_1 tank/a@automated_hourly_1 tank/a@automated_hourly_2 tank/a@automated_daily_1 ' ] \
   && grep -q 'NIE zwolnił puli tank' "$gs_dir/mail" && ! grep -qE '__replicate_|vzdump|reczna|outsider|tank/c@|@automated_hourly_[034]$|@automated_daily_[23]$|pve9_automated_hourly_[23]$' "$gs_dir/destroyed"; then
    ok "capacity-guard: wyczerpanie -- 4 kandydatow, alert 'NIE zwolnil', rc 1; outsider_automated_*, dataset bez jawnego wzorca (tank/c: \"\", zdalna linia, linia poza blokiem) nietkniete"
else
    bad "capacity-guard: wyczerpanie kandydatow" "rc=$gs_rc" "got: $gs_got" "$(cat "$gs_dir/out" "$gs_dir/mail" 2>/dev/null)"
fi
gs_run 92 3 off --plan; gs_rc=$?
if [ "$gs_rc" -eq 0 ] && gs_none && grep -q 'usuwałby' "$gs_dir/out" && grep -q 'tank/a@automated_daily_1' "$gs_dir/out" && ! grep -qE 'outsider|tank/c@' "$gs_dir/out"; then
    ok "capacity-guard: --plan pokazuje kolejnosc i nic nie usuwa (takze przy guard = off); obcych nie ma na liscie"
else
    bad "capacity-guard: --plan" "rc=$gs_rc" "$(cat "$gs_dir/out" "$gs_dir/destroyed" 2>/dev/null)"
fi

# ---- najnowsza w datasecie i baza transferu ----
# tank/a: najnowsza w datasecie to reczna (500) -- hourly_4 nie jest najnowsza;
# keep=1. Bez zrodla transferu: hourly_1..3 i daily_1..2 do usuniecia.
gs_snaps > "$gs_dir/snaps"; printf 'tank/a@reczna_nowa\t500\t0\t1099\n' >> "$gs_dir/snaps"
GS_KEEP=1 gs_run 99 1 on; gs_rc=$?
if ! grep -q 'reczna_nowa' "$gs_dir/destroyed" 2>/dev/null && grep -q 'tank/a@automated_hourly_3' "$gs_dir/destroyed" \
   && ! grep -q 'tank/a@automated_hourly_4' "$gs_dir/destroyed"; then
    ok "capacity-guard: keep=1 -- najnowsza w rodzinie zostaje, starsze ida; obca nowsza migawka w datasecie nietknieta"
else
    bad "capacity-guard: keep=1 / najnowsza w datasecie" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/out" 2>/dev/null)"
fi
# tank/a jest lokalnym ZRODLEM kopii (dwa szczeble, jeden cel) -> jedna zakladka
# o DOKLADNEJ nazwie celu (tank/back/tank/a). Baza = hourly_3 (creation 300):
# wszystko od niej w gore zostaje, starsze ida (keep=1).
gs_snaps > "$gs_dir/snaps"
gs_cron "31 * * * * $GS_J /r/snapget.sh -m \"automated_hourly_\" -L x \"tank/a\" \"tank/back\"" \
        "32 1 * * * $GS_J /r/snapget.sh -m \"automated_daily_\" -q auto,degrade -L x \"tank/a\" \"tank/back\" 2>>/l"
printf 'tank/a#tgt-%s\t1003\t300\n' "$(gs_tag tank/back/tank/a)" > "$gs_dir/marks"
GS_KEEP=1 gs_run 99 1 on; gs_rc=$?
if ! grep -qE 'tank/a@automated_(hourly_3|daily_3)$' "$gs_dir/destroyed" && grep -q 'tank/a@automated_hourly_2$' "$gs_dir/destroyed" \
   && grep -q 'tank/a@automated_daily_2$' "$gs_dir/destroyed"; then
    ok "capacity-guard: zrodlo kopii -- zakladka o nazwie celu; baza (hourly_3) i nowsze zostaja, starsze ida; dwa szczeble do tego samego celu = jedna zakladka"
else
    bad "capacity-guard: baza z zakladki" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/out" 2>/dev/null)"
fi
# Brak zakladki TEGO celu, za to osierocona zakladka innego -- nie zastepuje jej:
# baza nieznana -> tank/a zablokowany, tank/b dalej czyszczony.
printf 'tank/a#tgt-deadbeef\t1001\t100\n' > "$gs_dir/marks"
gs_run 99 1 on; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && ! grep -q '^tank/a@' "$gs_dir/destroyed" && grep -q 'tank/b@pve9_automated_hourly_1' "$gs_dir/destroyed" \
   && grep -q 'Zablokowane datasety' "$gs_dir/mail" && grep -q "tank/a: brak zakładki #tgt-$(gs_tag tank/back/tank/a) dla celu tank/back" "$gs_dir/mail"; then
    ok "capacity-guard: zrodlo kopii bez SWOJEJ zakladki (osierocona innego celu nie liczy sie) -- zablokowany, powod w alercie"
else
    bad "capacity-guard: zrodlo bez zakladki" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
fi
# Dwa rozne cele, zakladka tylko jednego -> zablokowany (cel push: pool/x/tank/a).
gs_cron "31 * * * * $GS_J /r/snapget.sh -m \"automated_hourly_\" \"tank/a\" \"tank/back\"" \
        "33 * * * * $GS_J /r/snapsend.sh -m \"automated_hourly_\" -K /k \"tank/a\" \"u@far:pool/x\""
printf 'tank/a#tgt-%s\t1003\t300\n' "$(gs_tag tank/back/tank/a)" > "$gs_dir/marks"
gs_run 99 1 on; gs_rc=$?
if ! grep -q '^tank/a@' "$gs_dir/destroyed" && grep -q 'dla celu u@far:pool/x' "$gs_dir/mail"; then
    ok "capacity-guard: dwa cele, zakladka tylko jednego -- zablokowany"
else
    bad "capacity-guard: dwa cele" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" 2>/dev/null)"
fi
# ...z obiema zakladkami (push skladany jako pool/x/tank/a, -j w nazwie) -- czysci.
gs_cron "31 * * * * $GS_J /r/snapget.sh -m \"automated_hourly_\" \"tank/a\" \"tank/back\"" \
        "33 * * * * $GS_J /r/snapsend.sh -m \"automated_hourly_\" -j drugi -K /k \"tank/a\" \"u@far:pool/x\""
printf 'tank/a#tgt-%s\t1003\t300\ntank/a#tgt-%s\t1003\t300\n' "$(gs_tag tank/back/tank/a)" "$(gs_tag pool/x/tank/a drugi)" > "$gs_dir/marks"
GS_KEEP=1 gs_run 99 1 on; gs_rc=$?
if grep -q 'tank/a@automated_hourly_2$' "$gs_dir/destroyed" && ! grep -q 'tank/a@automated_hourly_3$' "$gs_dir/destroyed"; then
    ok "capacity-guard: dwa cele z dwiema zakladkami (nazwa z celu i -j) -- czysci ponizej bazy"
else
    bad "capacity-guard: dwa cele z zakladkami" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
fi
# Transfer atomowy (-r): silnik nie zapisuje zakladki -> zablokowany.
gs_cron "31 * * * * $GS_J /r/snapget.sh -m \"automated_hourly_\" -r \"tank/a\" \"tank/back\""
gs_run 99 1 on; gs_rc=$?
if ! grep -q '^tank/a@' "$gs_dir/destroyed" && grep -q 'tank/a: transfer atomowy' "$gs_dir/mail"; then
    ok "capacity-guard: zrodlo transferu atomowego (-r) -- zablokowany"
else
    bad "capacity-guard: -r" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" 2>/dev/null)"
fi

# Zrodlo PULL dla zdalnego kolektora: brak linii transferu, jest zakres peera.
gs_cron; : > "$gs_dir/marks"
printf '[dataset:tank/a]\ninclude_parent = yes\ninclude_children = yes\n' > "$gs_dir/peers/pve10.scope"
gs_run 99 1 on; gs_rc=$?
if ! grep -q '^tank/a@' "$gs_dir/destroyed" && grep -q 'tank/a: udostępniony peerowi pve10 bez zakładki' "$gs_dir/mail"; then
    ok "capacity-guard: zakres peera (zdalny kolektor ciagnie tank/a) bez zakladki -- zablokowany"
else
    bad "capacity-guard: zakres peera bez zakladki" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" 2>/dev/null)"
fi
printf 'tank/a#tgt-feedbeef\t1002\t200\n' > "$gs_dir/marks"
GS_KEEP=1 gs_run 99 1 on; gs_rc=$?
if grep -q 'tank/a@automated_hourly_1$' "$gs_dir/destroyed" && ! grep -q 'tank/a@automated_hourly_2$' "$gs_dir/destroyed"; then
    ok "capacity-guard: zakres peera z zakladka -- czysci, baza peera (hourly_2) zostaje"
else
    bad "capacity-guard: zakres peera z zakladka" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" 2>/dev/null)"
fi
rm -f "$gs_dir/peers/pve10.scope"
# Zakladka #tgt- chroni swoja migawke zawsze, takze bez wykrytego zrodla.
printf 'tank/b#tgt-12345678\t2001\t60\n' > "$gs_dir/marks"
gs_run 99 1 on; gs_rc=$?
if ! grep -q 'tank/b@pve9_automated_hourly_1' "$gs_dir/destroyed" && grep -q 'tank/a@automated_hourly_1' "$gs_dir/destroyed"; then
    ok "capacity-guard: migawka wskazana przez zakladke #tgt- zostaje nawet bez linii transferu"
else
    bad "capacity-guard: zakladka bez zrodla" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" 2>/dev/null)"
fi

# ---- fail-closed: kazdy blad odczytu = 0 usuniec, rc 1, alert ----
gs_failclosed() {   # <name> <expected text in mail>
    if [ "$gs_rc" -eq 1 ] && gs_none && ! grep -q '^zfs destroy' "$gs_dir/calls" 2>/dev/null && grep -q 'NIE zadziałał' "$gs_dir/mail" && grep -qF "$2" "$gs_dir/mail"; then
        ok "capacity-guard: fail-closed -- $1"
    else
        bad "capacity-guard: fail-closed -- $1" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
    fi
}
gs_cron; gs_snaps > "$gs_dir/snaps"; : > "$gs_dir/marks"
GS_FAIL_SNAPS=1 gs_run 99 1 on; gs_rc=$?;            gs_failclosed "zfs list migawek zawodzi (czesciowy wynik)" "zfs list migawek"
GS_FAIL_MARKS=1 gs_run 99 1 on; gs_rc=$?;            gs_failclosed "zfs list zakladek zawodzi" "zfs list zakładek"
printf 'tank/a@automated_hourly_9\tjutro\t0\t1\n' >> "$gs_dir/snaps"
gs_run 99 1 on; gs_rc=$?;                            gs_failclosed "zly format creation" "zły wiersz migawki"
gs_snaps > "$gs_dir/snaps"; printf 'tank/a@automated_hourly_9\t900\t\t1\n' >> "$gs_dir/snaps"
gs_run 99 1 on; gs_rc=$?;                            gs_failclosed "brak userrefs" "zły wiersz migawki"
gs_snaps > "$gs_dir/snaps"
GS_CRON="$gs_dir/nie-ma" gs_run 99 1 on; gs_rc=$?;   gs_failclosed "brak katalogu crontabow" "nie da się czytać"
gs_cron "31 * * * * $GS_J /r/snapget.sh -Y \"tank/a\" \"tank/back\""
gs_run 99 1 on; gs_rc=$?;                            gs_failclosed "niezrozumiana linia transferu" "nieznana opcja"
{ echo "# BEGIN zfs-backup-managed"; echo "24 * * * * $GS_J /r/delsnaps.sh -R \"tank/a\" \"\" -H24"; echo "# END zfs-backup-managed"; } > "$gs_dir/cron/root"
gs_run 99 1 on; gs_rc=$?;                            gs_failclosed "brak wlasnosci (tylko wzorzec \"\")" "nie wiem, które migawki są nasze"
gs_cron

# ---- kolejnosc ustawien: env > settings.ini > zfs-alert.conf > domyslne ----
printf 'ZFS_GUARD=on\nZFS_GUARD_AT=50\nZFS_GUARD_TARGET=40\nZFS_GUARD_MIN_KEEP=7\n' > "$gs_dir/legacy-on.conf"
printf 'ZFS_GUARD=off\n' > "$gs_dir/legacy-off.conf"
GS_CONF="$gs_dir/legacy-on.conf" gs_run 95 3 off; gs_rc=$?
if gs_none && [ ! -s "$gs_dir/mail" ]; then
    ok "capacity-guard: legacy conf ZFS_GUARD=on + F10 guard = off -- NIE kasuje (settings.ini wygrywa z conf)"
else
    bad "capacity-guard: legacy on + F10 off" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/out" 2>/dev/null)"
fi
GS_CONF="$gs_dir/legacy-off.conf" gs_run 92 3 on; gs_rc=$?
if [ -s "$gs_dir/destroyed" ]; then
    ok "capacity-guard: legacy conf off + F10 on -- dziala (settings.ini wygrywa z conf)"
else
    bad "capacity-guard: legacy off + F10 on" "rc=$gs_rc" "$(cat "$gs_dir/out" 2>/dev/null)"
fi
GS_ENV_KEEP=1 ZFS_GUARD=off GS_CONF="$gs_dir/legacy-on.conf" gs_run 95 3 on; gs_rc=$?
if gs_none; then ok "capacity-guard: env ZFS_GUARD=off wygrywa z F10 on i conf on"
else bad "capacity-guard: env off" "$(cat "$gs_dir/destroyed" 2>/dev/null)"; fi
GS_ENV_KEEP=1 ZFS_GUARD=on gs_run 92 3 off; gs_rc=$?
if [ -s "$gs_dir/destroyed" ]; then ok "capacity-guard: env ZFS_GUARD=on wygrywa z F10 off"
else bad "capacity-guard: env on" "$(cat "$gs_dir/out" 2>/dev/null)"; fi
GS_CONF="$gs_dir/legacy-on.conf" gs_run 60 3 off --plan
if grep -q 'czyści od 89% do 85%, zostaje 2 ' "$gs_dir/out"; then
    ok "capacity-guard: guard_at/guard_target/guard_min_keep z F10 wygrywaja z conf (50/40/7)"
else
    bad "capacity-guard: progi settings > conf" "$(head -2 "$gs_dir/out")"
fi
GS_ENV_KEEP=1 ZFS_GUARD_AT=70 ZFS_GUARD_TARGET=60 ZFS_GUARD_MIN_KEEP=3 GS_CONF="$gs_dir/legacy-on.conf" gs_run 60 3 off --plan
if grep -q 'czyści od 70% do 60%, zostaje 3 ' "$gs_dir/out"; then
    ok "capacity-guard: env wygrywa z F10 i conf dla guard_at/guard_target/guard_min_keep"
else
    bad "capacity-guard: progi env > settings" "$(head -2 "$gs_dir/out")"
fi
# ---- REV-20261021-155 F1: progi spoza zakresu = 0 usuniec, rc 1, alert z nazwa ----
gs_badcfg() {   # <nazwa> <oczekiwany tekst> -- po gs_run
    if [ "$gs_rc" -eq 1 ] && gs_none && ! grep -q '^zfs ' "$gs_dir/calls" 2>/dev/null && grep -qF "$2" "$gs_dir/mail" 2>/dev/null; then
        ok "capacity-guard: zle ustawienie -- $1: nic nie usuwa, nie wylicza puli, alert z nazwa"
    else
        bad "capacity-guard: zle ustawienie -- $1" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/calls" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
    fi
}
gs_cron; gs_snaps > "$gs_dir/snaps"; : > "$gs_dir/marks"
GS_ENV_KEEP=1 ZFS_GUARD_AT=0 ZFS_GUARD_TARGET=0 gs_run 99 1 on; gs_rc=$?;    gs_badcfg "env 0/0" "guard_at='0' (50-99)"
GS_ENV_KEEP=1 ZFS_GUARD_AT=49 gs_run 99 1 on; gs_rc=$?;                     gs_badcfg "env guard_at=49 (dolna granica-1)" "guard_at='49'"
GS_ENV_KEEP=1 ZFS_GUARD_AT=100 gs_run 99 1 on; gs_rc=$?;                    gs_badcfg "env guard_at=100 (gorna granica+1)" "guard_at='100'"
GS_ENV_KEEP=1 ZFS_GUARD_TARGET=39 gs_run 99 1 on; gs_rc=$?;                 gs_badcfg "env guard_target=39" "guard_target='39'"
GS_ENV_KEEP=1 ZFS_GUARD_AT=85 ZFS_GUARD_TARGET=85 gs_run 99 1 on; gs_rc=$?; gs_badcfg "guard_target == guard_at" "nie jest poniżej guard_at='85'"
GS_KEEP=0 gs_run 99 1 on; gs_rc=$?;                                         gs_badcfg "settings guard_min_keep=0" "guard_min_keep='0' (1-100)"
GS_KEEP=101 gs_run 99 1 on; gs_rc=$?;                                       gs_badcfg "settings guard_min_keep=101" "guard_min_keep='101'"
GS_KEEP=x gs_run 99 1 on; gs_rc=$?;                                         gs_badcfg "settings guard_min_keep nie-liczba" "guard_min_keep='x'"
printf 'ZFS_GUARD_TARGET=0\n' > "$gs_dir/legacy-bad.conf"
printf '[capacity]\nguard = on\n' > "$gs_dir/settings-on.ini"
( unset ZFS_GUARD ZFS_GUARD_AT ZFS_GUARD_TARGET ZFS_GUARD_MIN_KEEP; rm -f "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/calls"; echo 99 > "$gs_dir/cap"
  PATH="$gs_dir/bin:$PATH" GS_DIR="$gs_dir" GS_STEP=1 SETTINGS_FILE="$gs_dir/settings-on.ini" ZFS_ALERT_CONF="$gs_dir/legacy-bad.conf" \
  ZFS_GUARD_CRONTABS="$gs_dir/cron" ZFS_GUARD_PEERS="$gs_dir/peers" ZFS_NOTIFY_SCRIPT="$gs_dir/bin/notify" ZFS_GUARD_LOCK="$gs_dir/lock" \
  bash "$gs_dir/guard.sh" ) > "$gs_dir/out" 2>&1; gs_rc=$?;                   gs_badcfg "zfs-alert.conf guard_target=0" "guard_target='0'"
GS_ENV_KEEP=1 ZFS_GUARD_AT=abc gs_run 99 1 on; gs_rc=$?;                    gs_badcfg "env guard_at nie-liczba (nie wraca do 89)" "guard_at='abc'"
GS_ENV_KEEP=1 ZFS_GUARD=ON gs_run 99 1 on; gs_rc=$?;                        gs_badcfg "guard='ON' (tylko on/off)" "guard = 'ON'"
# Zla wartosc z env NIE jest zastepowana poprawna z settings.ini (89).
GS_ENV_KEEP=1 ZFS_GUARD_AT=0 gs_run 99 1 on; gs_rc=$?;                      gs_badcfg "env 0 przy poprawnym settings 89 -- env wygrywa i odmawia" "guard_at='0'"
# Granice poprawne: 50/40/1 i 99/98/100 -- przyjete (--plan liczy).
GS_ENV_KEEP=1 ZFS_GUARD_AT=50 ZFS_GUARD_TARGET=40 ZFS_GUARD_MIN_KEEP=1 gs_run 60 1 on --plan; gs_rc=$?
gs_lo=$gs_rc; grep -q 'czyści od 50% do 40%, zostaje 1 ' "$gs_dir/out"; gs_lo2=$?
GS_ENV_KEEP=1 ZFS_GUARD_AT=99 ZFS_GUARD_TARGET=98 ZFS_GUARD_MIN_KEEP=100 gs_run 60 1 on --plan; gs_rc=$?
if [ "$gs_lo" -eq 0 ] && [ "$gs_lo2" -eq 0 ] && [ "$gs_rc" -eq 0 ] && grep -q 'czyści od 99% do 98%, zostaje 100 ' "$gs_dir/out"; then
    ok "capacity-guard: granice poprawne (50/40/1 i 99/98/100) przyjete"
else
    bad "capacity-guard: granice poprawne" "lo=$gs_lo/$gs_lo2 hi=$gs_rc" "$(head -3 "$gs_dir/out")"
fi

# ---- REV-20261021-155 F2: nieudany zpool sync / nieczytelna zajetosc = twardy stop ----
GS_FAIL_SYNC=1 gs_run 99 1 on; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && [ "$(grep -c . "$gs_dir/destroyed")" -eq 1 ] && grep -q 'ZATRZYMANY' "$gs_dir/mail" && grep -q 'zpool sync tank zawiódł' "$gs_dir/mail" \
   && grep -q "$(cat "$gs_dir/destroyed")" "$gs_dir/mail"; then
    ok "capacity-guard: zpool sync zawodzi po pierwszym usunieciu -- drugi kandydat nietkniety, rc 1, alert z usunieta"
else
    bad "capacity-guard: zpool sync zawodzi" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
fi
GS_BADCAP=1 gs_run 99 1 on; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && [ "$(grep -c . "$gs_dir/destroyed")" -eq 1 ] && grep -q 'nieczytelna' "$gs_dir/mail"; then
    ok "capacity-guard: zajetosc po usunieciu nieczytelna -- stop po pierwszym, rc 1, alert"
else
    bad "capacity-guard: nieczytelna zajetosc" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
fi
gs_run 92 3 on; gs_rc=$?
if [ "$gs_rc" -eq 0 ] && [ "$(grep -c . "$gs_dir/destroyed")" -eq 3 ] && grep -q 'wyczyścił pulę tank (83%)' "$gs_dir/mail"; then
    ok "capacity-guard: kontrola zdrowa -- sync dziala, stop ponizej celu (3 usuniecia, 83%)"
else
    bad "capacity-guard: kontrola zdrowa" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/out" 2>/dev/null)"
fi

# ---- REV-20261021-156: odczyt zajetosci i wykrycie pul ----
gs_cron; gs_snaps > "$gs_dir/snaps"; : > "$gs_dir/marks"
for gs_m in fail nan empty; do
    GS_TANK_MODE=$gs_m gs_run 95 1 on; gs_rc=$?
    if [ "$gs_rc" -eq 1 ] && gs_none && ! grep -q '^zfs ' "$gs_dir/calls" 2>/dev/null && grep -q 'nie widzi puli tank' "$gs_dir/mail"; then
        ok "capacity-guard: zajetosc puli nieczytelna ($gs_m) -- nie 'ponizej progu': rc 1, 0 wywolan zfs, alert dla tej puli"
    else
        bad "capacity-guard: zajetosc nieczytelna ($gs_m)" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/calls" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
    fi
done
GS_TANK_MODE=fail gs_run 95 1 off --plan; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && grep -q 'Pula tank: NIE da się odczytać zajętości' "$gs_dir/out" && [ ! -s "$gs_dir/mail" ]; then
    ok "capacity-guard: --plan przy nieczytelnej zajetosci -- rc 1, wpis, bez alertu"
else
    bad "capacity-guard: --plan nieczytelna zajetosc" "rc=$gs_rc" "$(cat "$gs_dir/out" "$gs_dir/mail" 2>/dev/null)"
fi
GS_TWO=1 gs_run 92 3 on; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && [ -s "$gs_dir/destroyed" ] && ! grep -qv '^tank/' "$gs_dir/destroyed" && ! grep -q 'zbad' "$gs_dir/calls" \
   && grep -q 'nie widzi puli zbad' "$gs_dir/mail" && grep -q 'wyczyścił pulę tank' "$gs_dir/mail"; then
    ok "capacity-guard: dwie pule, druga nieczytelna -- pierwsza czyszczona, w drugiej 0 wywolan zfs, rc 1, alert dla drugiej"
else
    bad "capacity-guard: dwie pule" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/calls" "$gs_dir/mail" 2>/dev/null)"
fi
gs_run 80 3 on; gs_rc=$?
if [ "$gs_rc" -eq 0 ] && gs_none && [ ! -s "$gs_dir/mail" ]; then
    ok "capacity-guard: zajetosc czytelna ponizej guard_at (80 < 89) -- nic, rc 0, bez alertu"
else
    bad "capacity-guard: ponizej progu" "rc=$gs_rc" "$(cat "$gs_dir/destroyed" "$gs_dir/mail" 2>/dev/null)"
fi
GS_POOLS_FAIL=1 gs_run 95 1 on; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && ! grep -q '^zfs ' "$gs_dir/calls" 2>/dev/null && grep -q 'zpool list zawodzi' "$gs_dir/mail"; then
    ok "capacity-guard: wykrycie pul zawodzi (czesciowe wyjscie) -- rc 1, 0 wywolan zfs, alert"
else
    bad "capacity-guard: wykrycie pul zawodzi" "rc=$gs_rc" "$(cat "$gs_dir/calls" "$gs_dir/mail" "$gs_dir/out" 2>/dev/null)"
fi
GS_POOLS_FAIL=1 gs_run 95 1 off --plan; gs_rc=$?
if [ "$gs_rc" -eq 1 ] && [ ! -s "$gs_dir/mail" ] && grep -q 'zpool list nie działa' "$gs_dir/out"; then
    ok "capacity-guard: --plan przy bledzie wykrycia pul -- rc 1, wpis, bez alertu"
else
    bad "capacity-guard: --plan wykrycie pul" "rc=$gs_rc" "$(cat "$gs_dir/out" "$gs_dir/mail" 2>/dev/null)"
fi
GS_POOLS_EMPTY=1 gs_run 95 1 on; gs_rc=$?
if [ "$gs_rc" -eq 0 ] && ! grep -q '^zfs ' "$gs_dir/calls" 2>/dev/null && [ ! -s "$gs_dir/mail" ] && grep -q 'brak pul ZFS' "$gs_dir/out"; then
    ok "capacity-guard: pusta lista pul przy kodzie 0 -- host bez pul: rc 0, bez alertu, wpis"
else
    bad "capacity-guard: pusta lista pul" "rc=$gs_rc" "$(cat "$gs_dir/out" "$gs_dir/mail" 2>/dev/null)"
fi

printf '[capacity]\n' > "$gs_dir/settings-empty.ini"
( unset ZFS_GUARD ZFS_GUARD_AT ZFS_GUARD_TARGET ZFS_GUARD_MIN_KEEP
  PATH="$gs_dir/bin:$PATH" GS_DIR="$gs_dir" SETTINGS_FILE="$gs_dir/settings-empty.ini" ZFS_ALERT_CONF="$gs_dir/legacy-on.conf" \
  ZFS_GUARD_CRONTABS="$gs_dir/cron" ZFS_GUARD_PEERS="$gs_dir/peers" ZFS_GUARD_LOCK="$gs_dir/lock" bash "$gs_dir/guard.sh" --plan ) > "$gs_dir/out" 2>&1
if grep -q 'bezpiecznik on (czyści od 50% do 40%, zostaje 7 ' "$gs_dir/out"; then
    ok "capacity-guard: bez wartosci w F10 obowiazuje conf (on, 50/40/7) -- conf > domyslne"
else
    bad "capacity-guard: conf > domyslne" "$(head -2 "$gs_dir/out")"
fi
rm -rf "$gs_dir"

# ---------------------------------------------------------------------------
# U50 STRAZNIK PODEJRZANEGO PRZYROSTU (hostscripts/growth-guard.sh, wlasciciel 2026-10-21).
# Prawdziwy skrypt, zfs zastapiony: listy datasetow i migawek z plikow, oszacowania
# `zfs send -nP` / `-nPc` z tabeli rozmiarow. Norma: 100 MiB/h; najnowszy przyrost zmieniany
# per przypadek. Tylko alarm -- skrypt nigdy nie wola zfs destroy.
# ---------------------------------------------------------------------------
gw_dir=$(mktemp -d); mkdir -p "$gw_dir/bin" "$gw_dir/cron" "$gw_dir/state"
cp "$HS/growth-guard.sh" "$gw_dir/guard.sh"; cp "$HS/alert-env.sh" "$gw_dir/alert-env.sh"
cat > "$gw_dir/bin/zfs" <<'ST'
#!/bin/bash
echo "zfs $*" >> "$GW_DIR/calls"
case "$1 $2" in
  "list -H")
    last="${*: -1}"
    case "$*" in
      *"-o name,compression"*)
        [ -n "${GW_FAIL_DS:-}" ] && { echo "cannot open" >&2; exit 1; }
        if [[ "$*" == *" -r "* ]]; then awk -F'\t' -v r="$last" '$1 == r || index($1, r "/") == 1' "$GW_DIR/ds"
        else awk -F'\t' -v r="$last" '$1 == r' "$GW_DIR/ds"; fi ;;
      *"-t snapshot"*)
        [ -n "${GW_FAIL_SNAPS:-}" ] && { echo "cannot iterate" >&2; exit 1; }
        awk -F'\t' -v d="$last" 'index($1, d "@") == 1' "$GW_DIR/snaps" ;;
    esac ;;
  "send -nP")
    shift 2; c=0; [ "$1" = "-c" ] && { c=1; shift; }
    [ -n "${GW_FAIL_SEND:-}" ] && { echo "cannot estimate" >&2; exit 1; }
    a="$2"; b="$3"
    v=$(awk -v a="$a" -v b="$b" -v c="$c" '$1 == a && $2 == b { print (c ? $4 : $3); exit }' "$GW_DIR/sizes")
    printf 'incremental\t%s\t%s\t%s\nsize\t%s\n' "$a" "$b" "$v" "$v" ;;
  destroy*) echo "DESTROY $*" >> "$GW_DIR/destroyed" ;;
esac
exit 0
ST
printf '#!/bin/bash\nprintf "%%s\n%%s\n" "$1" "$2" >> "$GW_DIR/mail"\n' > "$gw_dir/bin/notify"
chmod +x "$gw_dir/bin/"* "$gw_dir/guard.sh"
GW_J='/r/zfs-job.sh "h prune" --log=/l --notify=/n --detail=8 --'
{
    echo "# BEGIN zfs-backup-managed"
    echo "21 * * * * $GW_J /r/delsnaps.sh -L x \"tank/d\" \"automated_hourly\" -H24"
    echo "22 * * * * $GW_J /r/delsnaps.sh -R -L y \"tank/off\" \"automated_hourly\" -H24"
    echo "# END zfs-backup-managed"
} > "$gw_dir/cron/root"
printf 'tank/d\tlz4\ntank/off\toff\ntank/x\tlz4\n' > "$gw_dir/ds"
GW_M=1048576
gw_data() {   # <L ostatniego MiB> <C ostatniego MiB> [liczba przyrostow, domyslnie 5]
    local n="${3:-5}" i
    : > "$gw_dir/snaps"; : > "$gw_dir/sizes"
    for ds in tank/d tank/off tank/x; do
        for i in $(seq 0 "$n"); do printf '%s@s%s\t%s\t%s\n' "$ds" "$i" "$((7000 + i))" "$((i * 3600))" >> "$gw_dir/snaps"; done
        for i in $(seq 1 "$n"); do
            if [ "$i" -eq "$n" ]; then L=$(($1 * GW_M)); C=$(($2 * GW_M)); else L=$((100 * GW_M)); C=$((50 * GW_M)); fi
            printf '%s@s%s %s@s%s %s %s\n' "$ds" "$((i - 1))" "$ds" "$i" "$L" "$C" >> "$gw_dir/sizes"
        done
    done
}
gw_run() {   # <settings alert> [args] -> rc; mail/out/calls in $gw_dir
    rm -f "$gw_dir/mail" "$gw_dir/calls" "$gw_dir/destroyed"
    printf '[growth]\nalert = %s\n' "$1" > "$gw_dir/settings.ini"; shift
    [ -n "${GW_KEEP_STATE:-}" ] || rm -rf "$gw_dir/state"
    ( [ -n "${GW_ENV_KEEP:-}" ] || unset ZFS_GROWTH_ALERT ZFS_GROWTH_FACTOR ZFS_GROWTH_MIN_MIB ZFS_GROWTH_MAX_RATIO_PCT ZFS_GROWTH_DAYS
      PATH="$gw_dir/bin:$PATH" GW_DIR="$gw_dir" SETTINGS_FILE="$gw_dir/settings.ini" ZFS_ALERT_CONF="${GW_CONF:-/dev/null}" \
      ZFS_GUARD_CRONTABS="$gw_dir/cron" ZFS_GROWTH_STATE="$gw_dir/state" ZFS_NOTIFY_SCRIPT="$gw_dir/bin/notify" \
      ZFS_GROWTH_LOCK="${GW_LOCK:-$gw_dir/lock}" TMPDIR="${GW_TMP:-${TMPDIR:-/tmp}}" bash "$gw_dir/guard.sh" "$@" ) > "$gw_dir/out" 2>&1
}
gw_nosend() { ! grep -q '^zfs send' "$gw_dir/calls" 2>/dev/null; }

gw_data 2000 2000
gw_run off; gw_rc=$?
if [ "$gw_rc" -eq 0 ] && [ ! -s "$gw_dir/calls" ] && [ ! -s "$gw_dir/mail" ]; then
    ok "growth-guard: alert = off (domyslnie) -- nic nie liczy, nic nie wysyla"
else
    bad "growth-guard: off" "rc=$gw_rc" "$(cat "$gw_dir/calls" "$gw_dir/out" 2>/dev/null)"
fi
gw_data 110 55
gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 0 ] && [ ! -s "$gw_dir/mail" ] && grep -q '^zfs send' "$gw_dir/calls"; then
    ok "growth-guard: zwykly przyrost (110 MiB/h przy normie 100) -- bez alarmu"
else
    bad "growth-guard: zwykly przyrost" "rc=$gw_rc" "$(cat "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
fi
gw_data 2000 2000
gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 1 ] && grep -q 'PODEJRZANY PRZYROST' "$gw_dir/mail" && grep -q 'tank/d: najnowszy przyrost 2000 MiB (do tank/d@s5), tempo 20.0x normy, kompresja przyrostu 1.00' "$gw_dir/mail" \
   && [ ! -s "$gw_dir/destroyed" ]; then
    ok "growth-guard: skok x20, niekompresowalny, ponad min_mib -- ALARM z datasetem, rozmiarem, tempem, kompresja; nic nie usuniete"
else
    bad "growth-guard: skok niekompresowalny" "rc=$gw_rc" "$(cat "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
fi
GW_KEEP_STATE=1 gw_run on; gw_rc=$?
if [ ! -s "$gw_dir/mail" ]; then
    ok "growth-guard: ten sam alarm drugi raz (ta sama migawka) -- bez drugiego maila"
else
    bad "growth-guard: powtorka alarmu" "$(cat "$gw_dir/mail")"
fi
gw_data 2000 800
gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 0 ] && [ ! -s "$gw_dir/mail" ]; then
    ok "growth-guard: skok x20, ale kompresja 2.50 (konwersja baz) -- bez alarmu"
else
    bad "growth-guard: skok kompresowalny" "rc=$gw_rc" "$(cat "$gw_dir/mail" 2>/dev/null)"
fi
gw_data 900 900
gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 0 ] && [ ! -s "$gw_dir/mail" ]; then
    ok "growth-guard: skok x9 niekompresowalny, ale ponizej min_mib (900 < 1024) -- bez alarmu"
else
    bad "growth-guard: ponizej min_mib" "rc=$gw_rc" "$(cat "$gw_dir/mail" 2>/dev/null)"
fi
gw_data 2000 2000 3
gw_run on --plan; gw_rc=$?
if [ "$gw_rc" -eq 0 ] && grep -q 'tank/d: brak normy -- 3 przyrost' "$gw_dir/out" && ! grep -q 'ALARM' "$gw_dir/out"; then
    ok "growth-guard: za malo historii (3 przyrosty) -- brak normy, bez alarmu, powod w --plan"
else
    bad "growth-guard: za malo historii" "rc=$gw_rc" "$(cat "$gw_dir/out" 2>/dev/null)"
fi
gw_data 2000 2000
gw_run off --plan; gw_rc=$?
if grep -q 'tank/off: pominięty -- compression=off' "$gw_dir/out" && ! grep -q 'tank/x' "$gw_dir/out" && ! grep -q 'tank/x' "$gw_dir/calls" \
   && grep -q 'tank/d: .* -- ALARM' "$gw_dir/out" && [ ! -s "$gw_dir/mail" ]; then
    ok "growth-guard: --plan (takze przy off) -- compression=off pominiety z powodem, dataset bez linii retencji nie badany, bez maila"
else
    bad "growth-guard: --plan / zakres" "rc=$gw_rc" "$(cat "$gw_dir/out" "$gw_dir/calls" 2>/dev/null)"
fi
for gw_f in SEND SNAPS DS; do
    ( export "GW_FAIL_$gw_f=1"; gw_run on ); gw_rc=$?
    if [ "$gw_rc" -eq 1 ] && grep -q 'NIE działa w całości' "$gw_dir/mail" && ! grep -q 'w porządku' "$gw_dir/out"; then
        ok "growth-guard: blad zfs ($gw_f) -- rc 1, alert 'strażnik nie działa', bez cichego 'w porzadku'"
    else
        bad "growth-guard: blad zfs ($gw_f)" "rc=$gw_rc" "$(cat "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
    fi
done
gw_data 2000 2000; printf 'tank/d@zle\tabc\t99999\n' >> "$gw_dir/snaps"
gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 1 ] && grep -q 'zły wiersz migawki w tank/d' "$gw_dir/mail"; then
    ok "growth-guard: zly wiersz migawki -- rc 1, alert"
else
    bad "growth-guard: zly wiersz" "rc=$gw_rc" "$(cat "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
fi
gw_data 2000 2000
for gw_b in "ZFS_GROWTH_FACTOR=1:factor='1'" "ZFS_GROWTH_MIN_MIB=0:min_mib='0'" "ZFS_GROWTH_MAX_RATIO_PCT=99:max_ratio_pct='99'" \
            "ZFS_GROWTH_DAYS=1:days='1'" "ZFS_GROWTH_FACTOR=x:factor='x'" "ZFS_GROWTH_ALERT=ON:alert = 'ON'"; do
    gw_v="${gw_b%%:*}"; gw_t="${gw_b#*:}"
    ( export GW_ENV_KEEP=1 "$gw_v"; gw_run on ); gw_rc=$?
    if [ "$gw_rc" -eq 1 ] && [ ! -s "$gw_dir/calls" ] && grep -qF "$gw_t" "$gw_dir/mail"; then
        ok "growth-guard: zle ustawienie ${gw_v} -- nic, rc 1, alert z nazwa"
    else
        bad "growth-guard: zle ustawienie ${gw_v}" "rc=$gw_rc" "$(cat "$gw_dir/calls" "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
    fi
done
printf 'ZFS_GROWTH_ALERT=on\n' > "$gw_dir/legacy-on.conf"
GW_CONF="$gw_dir/legacy-on.conf" gw_run off; gw_rc=$?
if [ ! -s "$gw_dir/calls" ]; then ok "growth-guard: zfs-alert.conf on + F10 off -- nic (settings.ini wygrywa)"
else bad "growth-guard: conf on + F10 off" "$(cat "$gw_dir/calls")"; fi
( export GW_ENV_KEEP=1 ZFS_GROWTH_ALERT=on; gw_run off ); gw_rc=$?
if grep -q 'PODEJRZANY PRZYROST' "$gw_dir/mail" 2>/dev/null; then ok "growth-guard: env on wygrywa z F10 off"
else bad "growth-guard: env on" "$(cat "$gw_dir/out" 2>/dev/null)"; fi
gw_data 2000 2000
GW_LOCK="$gw_dir/nie-ma/g.lock" gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 1 ] && [ ! -s "$gw_dir/calls" ] && grep -q 'strażnik przyrostu NIE działa' "$gw_dir/mail" && grep -q 'nie-ma/g.lock' "$gw_dir/mail"; then
    ok "growth-guard: pliku blokady nie da sie otworzyc -- rc 1, zero wywolan zfs, alert ze sciezka"
else
    bad "growth-guard: blokada" "rc=$gw_rc" "$(cat "$gw_dir/calls" "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
fi
GW_TMP="$gw_dir/nie-ma-tmp" gw_run on; gw_rc=$?
if [ "$gw_rc" -eq 1 ] && [ ! -s "$gw_dir/calls" ] && grep -q 'nie-ma-tmp' "$gw_dir/mail"; then
    ok "growth-guard: mktemp zawodzi -- rc 1, zero wywolan zfs, alert z TMPDIR"
else
    bad "growth-guard: mktemp" "rc=$gw_rc" "$(cat "$gw_dir/calls" "$gw_dir/mail" "$gw_dir/out" 2>/dev/null)"
fi
rm -rf "$gw_dir"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
